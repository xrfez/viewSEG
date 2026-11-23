## Writes one loaded seismic file as SEG-Y or SEG-D, trace by trace, with the
## edits set on it. A background job (`outputWork`): the source is never
## modified. Samples are one trace at a time. With no sort key, only a bounded
## block of indices is held; a SEG-D sort holds one record; only a SEG-Y sort
## holds an index of the whole file. A later window calls it once per file.
##
## An existing destination is refused, never overwritten, and the destination
## name is never created here. The writer is given a part file in that
## folder (`<name>.part-<random>`, created exclusively so it is ours). When
## the writer finishes, `fs.moveNoReplace` moves the part onto the
## destination, and fails without touching it when that name exists by then.
## A cancel or a failure drops the writer and removes only the part file
## (and the writer's own temporary file); the destination name is not touched.
##
## With no option on, samples are the source's decoded samples and headers
## are the writer's template (`like:`). SEG-D's template writer keeps each
## record whole and in input order, so a sort that would cross records, or a
## killed trace left out, is written from the trace keys instead, and the
## result says so. Display-only gain is never applied.

import std/[math, os, random, strutils, times]
import parseSEG
import edits, filesystem, jobs, panels, processing, reader, sorting

const TraceBlock = 64 ## traces read, then written, between two cancel checks

type
  OutputFormat* = enum
    ## The standard of the file to write.
    ofSegy = "SEG-Y"
    ofSegd = "SEG-D"

  OutputOptions* = object
    ## What to apply while writing one file. Display-only gain is never applied.
    format*: OutputFormat
    applyReversals*: bool   ## reversed traces written reversed
    applyShifts*: bool
      ## Shifted traces are written shifted, same length, zeros where no sample exists.
    dropKilled*: bool
      ## Killed traces left out. A killed trace that is kept is written like
      ## any other, with the chosen options applied: a kill only drops.
    applyOwnFilters*: bool
    applyProcessing*: bool
    processing*: Processing ## the plot's filters, when `applyProcessing`
    sortKeys*: seq[SortKey] ## empty: the file's order

  OutputResult* = object
    ## What the write did. `ok` false: `reason` is a sentence for the user.
    ok*: bool
    written*: int
    dropped*: int
    lines*: seq[string] ## the writer's diagnostics, and a note when records bound a sort
    path*: string
    reason*: string
    removed*: bool      ## a partial file of ours was removed

  OutputSink* = ref object
    ## Filled when the job ends, including when it fails or is cancelled.
    ## Read it after the job is no longer running.
    result*: OutputResult

proc outputSpec*(source, dest: string): JobSpec =
  ## The job that writes `source` to `dest`: background, reading `source`,
  ## needing `dest` to itself. The file must stay open until the job ends
  ## (`reads` keeps a close from taking it).
  JobSpec(title: "Write " & extractFilename(dest), lane: jlBackground, reads: @[source],
    exclusive: @[dest])

proc canon(path: string): string =
  ## Absolute path, with the parent folder's links resolved. `absolutePath`
  ## does not resolve a missing file, so a destination under a symlinked
  ## folder would not be seen as inside an open file's folder.
  let parent = path.parentDir
  let name = path.extractFilename
  let folder = if parent.len == 0: "." else: parent
  try:
    let expanded = fs.expandFilename(folder)
    if name.len == 0: expanded.normalizedPath
    else: (expanded / name).normalizedPath
  except OSError, ValueError:
    try: absolutePath(path).normalizedPath
    except OSError, ValueError: path.normalizedPath

proc samePath(a, b: string): bool =
  when defined(windows): cmpIgnoreCase(a, b) == 0
  else: a == b

proc insideFolder(path, folder: string): bool =
  if folder.len == 0: return false
  if samePath(path, folder): return true
  let prefix = if folder.endsWith(DirSep): folder else: folder & DirSep
  when defined(windows): path.toLowerAscii.startsWith(prefix.toLowerAscii)
  else: path.startsWith(prefix)

proc refuseDestination*(dest: string; openPaths: openArray[string]): string =
  ## "" when `dest` may be written. A path equal to an open source file, or
  ## inside the folder of one, is refused: a sentence says which.
  if dest.len == 0: return "No destination was given."
  let to = canon(dest)
  for raw in openPaths:
    if raw.len == 0: continue
    let open = canon(raw)
    if samePath(to, open):
      return "The destination is an open file (" & extractFilename(open) & ")."
    if insideFolder(to, open.parentDir):
      return "The destination is inside the folder of an open file (" &
        extractFilename(open) & ")."

proc kindOf(format: OutputFormat): SeismicKind =
  if format == ofSegy: skSegy else: skSegd

proc recordKey(file: SeismicFile; trace: int): int64 =
  ## The field-record number, from the keys (0 when it is not set).
  let r = file.traceKeys(trace).record
  if r.isNaN: 0 else: int64(round(r))

proc boundary(file: SeismicFile; trace: int; byEntry, segdOut: bool): int64 =
  ## The record a cancel check stops at. A SEG-D source uses the entry's
  ## record (no keys). A SEG-Y file written as SEG-D uses the field record.
  ## A SEG-Y file written as itself is one record, so the block check is enough.
  if byEntry: int64(file.traceEntry(trace).record)
  elif segdOut: recordKey(file, trace)
  else: 0

proc claimPart(dest: string): string =
  ## An empty file next to `dest`, `<dest>.part-<random>`, created exclusively
  ## so it is ours. "" when every name tried already exists.
  const hex = "0123456789abcdef"
  var rng = initRand(getTime().toUnix * 1_000_000_007 + getTime().nanosecond +
    int64(getCurrentProcessId()) * 7919)
  for attempt in 0 ..< 16:
    var name = dest & ".part-"
    for k in 0 ..< 12: name.add hex[rng.rand(15)]
    if fs.createExclusive(name): return name
  ""

proc dropOurs(part: string): bool =
  ## Removes `part` and the writer's temporary file next to it
  ## (`<part>.<random>.tmp`). Never a destination name: `part` is a file this
  ## job created. True when `part` is gone.
  if part.len == 0: return false
  result = fs.tryRemoveFile(part)
  let folder = part.parentDir
  let dir = if folder.len == 0: "." else: folder
  let prefix = extractFilename(part) & "."
  try:
    for kind, path in fs.walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}: continue
      let name = extractFilename(path)
      if name.startsWith(prefix) and name.endsWith(".tmp"):
        discard fs.tryRemoveFile(path)
  except OSError:
    discard

proc abort(sink: OutputSink; dest, part: string; claimed: bool; why: string; cancel: bool) =
  ## Ends the job. When `claimed`, removes only `part` (ours); `dest` is never
  ## touched.
  var removed = false
  if claimed: removed = dropOurs(part)
  var reason = why
  if removed: reason.add " The partial file was removed."
  elif claimed: reason.add " The partial file could not be removed."
  if sink != nil:
    sink.result.ok = false
    sink.result.path = dest
    sink.result.reason = reason
    sink.result.removed = removed
    if sink.result.lines.len == 0: sink.result.lines = @[]
  if cancel: raise newException(JobCancelledError, reason)
  raise newException(ValueError, reason)

proc stopAsked(ctx: JobContext): bool {.inline.} = ctx.cancelled

proc outputWork*(file: ptr SeismicFile; source, dest: string; opts: OutputOptions;
    edits: FileEdits; openPaths: seq[string]; sink: OutputSink): JobWork =
  ## Writes `file` to `dest` on a job thread. `file` stays open until the
  ## job ends (submit it with `outputSpec`). `sink.result` is set before the
  ## job returns, fails or is cancelled. A cancel is looked for at each
  ## record and each block of traces; either that or a failure removes the
  ## part file and says so. The destination name is never touched.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "writing"
    if sink != nil: sink.result = OutputResult(path: dest, lines: @[])
    var claimed = false
    var part = ""
    var lines: seq[string] = @[]
    try:
      {.cast(gcsafe).}:
        var opens = openPaths
        opens.add source
        if file != nil and file[].path.len > 0: opens.add file[].path
        let refused = refuseDestination(dest, opens)
        if refused.len > 0: abort(sink, dest, part, false, refused, false)
        if fs.dirExists(dest):
          abort(sink, dest, part, false, "The destination is a folder.", false)
        if fs.fileExists(dest):
          abort(sink, dest, part, false, "The destination already exists.", false)
        part = claimPart(dest)
        if part.len == 0:
          abort(sink, dest, part, false, "The destination's folder has no free name.", false)
        claimed = true
        if file == nil or not file[].isOpen:
          abort(sink, dest, part, claimed, "The source file is not open.", false)
        let n = file[].len
        if n == 0: abort(sink, dest, part, claimed, "The file has no traces.", false)
        let outKind = kindOf(opts.format)
        let srcKind = file[].kind
        if srcKind notin {skSegy, skSegd, skSeg2}:
          abort(sink, dest, part, claimed, "The file is not SEG-Y, SEG-D or SEG-2.", false)
        let byEntry = srcKind == skSegd
        let splitRecords = outKind == skSegd
        if not file[].hasKeys and (opts.sortKeys.len > 0 or (splitRecords and not byEntry)):
          fs.mappedRead(source, headers = true)
          file[].ensureKeys()
        var dropped = 0
        var written = 0
        let segdOut = outKind == skSegd
        var records = 0
        var rec = int64(-1)
        var firstKept = -1
        for i in 0 ..< n:
          if opts.dropKilled and edits.has(teKilled, i):
            inc dropped
            continue
          if firstKept < 0: firstKept = i
          if segdOut:
            let r = boundary(file[], i, byEntry, true)
            if records == 0 or r != rec:
              inc records
              rec = r
        if firstKept < 0:
          if sink != nil: sink.result.dropped = dropped
          abort(sink, dest, part, claimed, "Nothing to write: every trace was left out.", false)
        template sortInto(traces: var seq[int]): bool =
          var changed = false
          if opts.sortKeys.len > 0 and traces.len > 1:
            var perm: seq[int] = @[]
            let rows = file[].rowsOf(traces)
            let stop = proc (): bool {.gcsafe, raises: [].} = ctx.cancelled
            if not sortRowsInto(rows, opts.sortKeys, perm, stop):
              abort(sink, dest, part, claimed, "The sort was stopped.", true)
            for k, row in perm:
              if row != k: changed = true
            var next = newSeq[int](traces.len)
            for k, row in perm: next[k] = traces[row]
            traces = next
          changed
        var head = firstKept
        var sameOrder = opts.sortKeys.len == 0 and dropped == 0
        if segdOut and opts.sortKeys.len > 0:
          var crosses = false
          var identity = dropped == 0
          var prevLast = -1
          var recTraces: seq[int] = @[]
          var recId = int64(-1)
          var firstRecord = true
          for i in 0 ..< n:
            if opts.dropKilled and edits.has(teKilled, i): continue
            let r = boundary(file[], i, byEntry, true)
            if recTraces.len > 0 and r != recId:
              if sortInto(recTraces): identity = false
              if firstRecord: head = recTraces[0]
              firstRecord = false
              if prevLast >= 0:
                var edge = @[prevLast, recTraces[0]]
                if sortInto(edge): crosses = true
              prevLast = recTraces[^1]
              recTraces.setLen 0
            if recTraces.len == 0: recId = r
            recTraces.add i
          if recTraces.len > 0:
            if sortInto(recTraces): identity = false
            if firstRecord: head = recTraces[0]
            if prevLast >= 0:
              var edge = @[prevLast, recTraces[0]]
              if sortInto(edge): crosses = true
          sameOrder = identity
          if crosses:
            lines.add "The sort crosses records, so it was applied within each record. " &
              "SEG-D records stay in input order."
        # SEG-Y's template writer allows any order and a missing trace. SEG-D's
        # does not: a record must be written whole, in input order.
        let like = srcKind == outKind and (srcKind == skSegy or (sameOrder and dropped == 0))
        if not file[].hasKeys and (opts.sortKeys.len > 0 or not like or opts.applyReversals or
            opts.applyShifts or opts.applyOwnFilters or opts.applyProcessing):
          fs.mappedRead(source, headers = true)
          file[].ensureKeys()
        if not like:
          lines.add "Headers were built from the trace keys. Template headers were not copied."
        var samples = newSeq[float32]()
        let dtMs = file[].sampleIntervalUs(0) / 1000.0
        block writing:
          var w: SeismicWriter
          if like:
            w = openSeismicWriter(part, like = file[])
          elif segdOut:
            var count = int(file[].traceEntry(head).numSamples)
            for i in 0 ..< n:
              if opts.dropKilled and edits.has(teKilled, i): continue
              let c = int(file[].traceEntry(i).numSamples)
              if c != count:
                abort(sink, dest, part, claimed,
                  "SEG-D output needs one sample count; this file has more than one.", false)
            var o = SegdOutputOptions(sampleIntervalUs: file[].sampleIntervalUs(head),
              numSamples: count)
            let t0 = file[].traceKeys(head).time
            if not t0.isNaN: o.time = t0
            w = openSeismicWriter(part, o)
          else:
            w = openSeismicWriter(part, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
          template writeOne(t: int) =
            let x = file[].readTraces(t .. t)
            let cols = x.shape[1]
            samples.setLen cols
            for j in 0 ..< cols: samples[j] = x[0, j]
            # A kill is only applied by leaving the trace out. A killed trace
            # that is kept is written like any other, options applied. With
            # no option on, the samples stay as read (no key lookup, so a
            # file opened without keys still writes).
            let reversed = opts.applyReversals and edits.effectivelyReversed(t)
            let shiftMs = if opts.applyShifts: edits.shiftOf(t) else: 0.0
            if reversed or shiftMs != 0.0 or opts.applyOwnFilters or opts.applyProcessing:
              var own = OwnFilter()
              if opts.applyOwnFilters or opts.applyProcessing:
                let listed = edits.plotFiltersIn(t .. t)
                if listed.len > 0: own = listed[0].filter
              applyPreparedTrace(samples, file[].traceKeys(t), dtMs, reversed, shiftMs,
                opts.processing, opts.applyProcessing, own, opts.applyOwnFilters)
            if like:
              w.writeTrace(file[], t, samples)
            else:
              let keys = file[].traceKeys(t)
              let channel = if keys.status == tsAuxiliary: sctOther else: sctSeismic
              w.writeTrace(keys, samples, channelType = channel)
            inc written
          template writeList(list: openArray[int]) =
            if list.len > 0:
              if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
              fs.mappedRead(source)
              for t in list: writeOne(t)
              if not ctx.progress(written + dropped, n):
                abort(sink, dest, part, claimed, "Cancelled.", true)
          template flush(batch: var seq[int]) =
            if segdOut and opts.sortKeys.len > 0: discard sortInto(batch)
            var at = 0
            while at < batch.len:
              let last = min(batch.len, at + TraceBlock)
              writeList(toOpenArray(batch, at, last - 1))
              at = last
            batch.setLen 0
          if opts.sortKeys.len > 0 and not segdOut:
            var whole = newSeqOfCap[int](n - dropped)
            for i in 0 ..< n:
              if opts.dropKilled and edits.has(teKilled, i): continue
              whole.add i
            discard sortInto(whole)
            flush(whole)
          else:
            var batch: seq[int] = @[]
            var batchRec = int64(-1)
            let holdRecord = segdOut and opts.sortKeys.len > 0
            for i in 0 ..< n:
              if opts.dropKilled and edits.has(teKilled, i): continue
              let r = if segdOut: boundary(file[], i, byEntry, true) else: int64(0)
              let newRecord = segdOut and batch.len > 0 and r != batchRec
              if newRecord or (batch.len == TraceBlock and not holdRecord):
                flush(batch)
                if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
              if batch.len == 0: batchRec = r
              batch.add i
            if batch.len > 0: flush(batch)
          if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
          let log = w.close()
          for d in log: lines.add($d)
          if not fs.moveNoReplace(part, dest):
            let kept = "The file appeared while writing; the output is kept as " & part & "."
            if sink != nil:
              sink.result = OutputResult(ok: false, written: written, dropped: dropped,
                lines: lines, path: part, reason: kept)
            claimed = false # the part file is the kept output, not a partial to drop
            raise newException(ValueError, kept)
          claimed = false
          if sink != nil:
            sink.result = OutputResult(ok: true, written: written, dropped: dropped,
              lines: lines, path: dest)
    except JobCancelledError as e:
      if sink != nil and sink.result.reason.len == 0:
        abort(sink, dest, part, claimed, e.msg, true)
      raise
    except CatchableError as e:
      if sink != nil and sink.result.reason.len == 0:
        abort(sink, dest, part, claimed, e.msg, false)
      raise
