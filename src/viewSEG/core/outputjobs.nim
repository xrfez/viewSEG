## Writes one loaded seismic file as SEG-Y or SEG-D, trace by trace, with the
## edits set on it. A background job (`outputWork`): the source is never
## modified, and one block of traces is in memory at a time. A later window
## calls it once per file.
##
## The destination is created exclusively (`fs.createExclusive`). An existing
## path is refused, never overwritten. The writer puts its bytes in a
## temporary file and renames that onto the destination when it finishes, so
## the empty file made here is replaced only by a complete one. A cancel or
## a failure drops the writer (no rename) and removes that file.
##
## With no option on, samples are the source's decoded samples and headers
## are the writer's template (`like:`). SEG-D's template writer keeps each
## record whole and in input order, so a sort that would cross records, or a
## killed trace left out, is written from the trace keys instead, and the
## result says so. Display-only gain is never applied.

import std/[math, os, strutils]
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
    dropKilled*: bool       ## killed traces left out; otherwise written as recorded
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
    removed*: bool      ## a partial destination was removed

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

proc abort(sink: OutputSink; dest: string; claimed: bool; why: string; cancel: bool) =
  var removed = false
  if claimed: removed = fs.tryRemoveFile(dest)
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
  ## record and each block of traces; either that or a failure removes a
  ## partial destination and says so.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "writing"
    if sink != nil: sink.result = OutputResult(path: dest, lines: @[])
    var claimed = false
    var lines: seq[string] = @[]
    try:
      {.cast(gcsafe).}:
        var opens = openPaths
        opens.add source
        if file != nil and file[].path.len > 0: opens.add file[].path
        let refused = refuseDestination(dest, opens)
        if refused.len > 0: abort(sink, dest, false, refused, false)
        if fs.dirExists(dest):
          abort(sink, dest, false, "The destination is a folder.", false)
        if fs.fileExists(dest):
          abort(sink, dest, false, "The destination already exists.", false)
        if not fs.createExclusive(dest):
          abort(sink, dest, false, "The destination already exists.", false)
        claimed = true
        if file == nil or not file[].isOpen:
          abort(sink, dest, claimed, "The source file is not open.", false)
        let n = file[].len
        if n == 0: abort(sink, dest, claimed, "The file has no traces.", false)
        let outKind = kindOf(opts.format)
        let srcKind = file[].kind
        if srcKind notin {skSegy, skSegd, skSeg2}:
          abort(sink, dest, claimed, "The file is not SEG-Y, SEG-D or SEG-2.", false)
        let byEntry = srcKind == skSegd
        let splitRecords = outKind == skSegd
        if not file[].hasKeys and (opts.sortKeys.len > 0 or (splitRecords and not byEntry)):
          fs.mappedRead(source, headers = true)
          file[].ensureKeys()
        var dropped = 0
        var groups: seq[seq[int]] = @[]
        var rec = int64(-1)
        for i in 0 ..< n:
          if opts.dropKilled and edits.has(teKilled, i):
            inc dropped
            continue
          let r = if splitRecords: boundary(file[], i, byEntry, true) else: 0
          if groups.len == 0 or r != rec:
            groups.add @[]
            rec = r
          groups[^1].add i
        var order: seq[int] = @[]
        if opts.sortKeys.len > 0:
          for g in groups.mitems:
            if g.len > 1:
              var perm: seq[int] = @[]
              let rows = file[].rowsOf(g)
              if not sortRowsInto(rows, opts.sortKeys, perm):
                abort(sink, dest, claimed, "The sort was stopped.", true)
              var next = newSeq[int](g.len)
              for k, row in perm: next[k] = g[row]
              g = next
        for g in groups: order.add g
        if order.len == 0:
          abort(sink, dest, claimed, "Nothing to write: every trace was left out.", false)
        let segdOut = outKind == skSegd
        var sameOrder = order.len == n
        if sameOrder:
          for i, t in order:
            if t != i: sameOrder = false
        # SEG-Y's template writer allows any order and a missing trace. SEG-D's
        # does not: a record must be written whole, in input order.
        let like = srcKind == outKind and (srcKind == skSegy or (sameOrder and dropped == 0))
        if not file[].hasKeys and (opts.sortKeys.len > 0 or not like or opts.applyReversals or
            opts.applyOwnFilters or opts.applyProcessing):
          fs.mappedRead(source, headers = true)
          file[].ensureKeys()
        if segdOut and opts.sortKeys.len > 0 and order.len > 1:
          var perm: seq[int] = @[]
          let rows = file[].rowsOf(order)
          if sortRowsInto(rows, opts.sortKeys, perm):
            var crosses = false
            for i, row in perm:
              if order[row] != order[i]: crosses = true
            if crosses:
              lines.add "The sort crosses records, so it was applied within each record. " &
                "SEG-D records stay in input order."
        if not like:
          lines.add "Headers were built from the trace keys. Template headers were not copied."
        var samples = newSeq[float32]()
        let dtMs = file[].sampleIntervalUs(0) / 1000.0
        block writing:
          var w: SeismicWriter
          if like:
            w = openSeismicWriter(dest, like = file[])
          elif segdOut:
            var count = int(file[].traceEntry(order[0]).numSamples)
            for t in order:
              let c = int(file[].traceEntry(t).numSamples)
              if c != count:
                abort(sink, dest, claimed,
                  "SEG-D output needs one sample count; this file has more than one.", false)
            var o = SegdOutputOptions(sampleIntervalUs: file[].sampleIntervalUs(order[0]),
              numSamples: count)
            let t0 = file[].traceKeys(order[0]).time
            if not t0.isNaN: o.time = t0
            w = openSeismicWriter(dest, o)
          else:
            w = openSeismicWriter(dest, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
          var at = 0
          var seen = int64(-1)
          while at < order.len:
            let r = boundary(file[], order[at], byEntry, segdOut)
            if r != seen:
              seen = r
              if stopAsked(ctx): abort(sink, dest, claimed, "Cancelled.", true)
            var last = at
            while last < order.len and last - at < TraceBlock and
                boundary(file[], order[last], byEntry, segdOut) == r:
              inc last
            if stopAsked(ctx): abort(sink, dest, claimed, "Cancelled.", true)
            fs.mappedRead(source)
            for t in order[at ..< last]:
              let x = file[].readTraces(t .. t)
              let cols = x.shape[1]
              samples.setLen cols
              for j in 0 ..< cols: samples[j] = x[0, j]
              # A killed trace kept in the file is written as recorded: not blanked,
              # and not run through the other options. With no option on, the
              # samples stay as read (no key lookup, so a file opened without
              # keys still writes).
              if not edits.has(teKilled, t):
                let reversed = opts.applyReversals and edits.effectivelyReversed(t)
                if reversed or opts.applyOwnFilters or opts.applyProcessing:
                  var own = OwnFilter()
                  if opts.applyOwnFilters or opts.applyProcessing:
                    let listed = edits.plotFiltersIn(t .. t)
                    if listed.len > 0: own = listed[0].filter
                  applyPreparedTrace(samples, file[].traceKeys(t), dtMs, reversed,
                    opts.processing, opts.applyProcessing, own, opts.applyOwnFilters)
              if like:
                w.writeTrace(file[], t, samples)
              else:
                let keys = file[].traceKeys(t)
                let channel = if keys.status == tsAuxiliary: sctOther else: sctSeismic
                w.writeTrace(keys, samples, channelType = channel)
            at = last
            if not ctx.progress(at + dropped, n):
              abort(sink, dest, claimed, "Cancelled.", true)
          if stopAsked(ctx): abort(sink, dest, claimed, "Cancelled.", true)
          let log = w.close()
          claimed = false # the writer replaced the claim with the finished file
          for d in log: lines.add($d)
          if sink != nil:
            sink.result = OutputResult(ok: true, written: order.len, dropped: dropped,
              lines: lines, path: dest)
    except JobCancelledError as e:
      if sink != nil and sink.result.reason.len == 0:
        abort(sink, dest, claimed, e.msg, true)
      raise
    except CatchableError as e:
      if sink != nil and sink.result.reason.len == 0:
        abort(sink, dest, claimed, e.msg, false)
      raise
