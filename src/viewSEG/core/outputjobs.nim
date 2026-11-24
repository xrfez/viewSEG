## Writes one loaded seismic file as SEG-Y or SEG-D, trace by trace, with the
## edits set on it. A background job (`outputWork`): the source is never
## modified. Samples are one trace at a time. With no sort key, only a bounded
## block of indices is held; a SEG-D sort holds one record; only a SEG-Y sort
## holds an index of the whole file. A later window calls `outputWork` once
## per file. A folder of files calls `writeOutput` from its own job, so
## both stay one writer.
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
## are the writer's template (`like:`). When a survey join or a station move
## changed those keys, every path writes the session's positions
## (`writeSessionPositions`, on unless the caller keeps the file's own).
## The note is written after the writer closes, and counts only traces that
## were written: all of them when every position was stored, the ones the
## format has a place for when some were not, and none when nothing was
## stored. SEG-D's template writer keeps each record whole and in input
## order, so a sort that would cross records, or a killed trace left out, is
## written from the trace keys instead, and the result says so. With the
## tick on, that path writes the file's own header positions, not the
## session's. Display-only gain is never applied.
##
## An open vibrator signature file written as SEG-D, with no option that
## changes samples or which traces are written, is written by the library's
## SEG-D writer instead: the file is read again through `fs` and the shot
## block and channel types are the library's. Positions a survey join filled
## into the keys are not in those bytes, and the result says so. Any such
## option keeps the keys writer. The note says the signature file's own
## header block is not carried, and the position tick is the same as for any
## other file.
##
## `correlation` set: each written trace is correlated with that loaded
## reference into the listen time, and the writer is opened with that sample
## count. SEG-Y samples are IEEE float32, whatever the source format. A
## reference auxiliary is shifted by its lag first. Time shift,
## polarity, an own filter and the plot's filters are applied after that, on
## the listen-length trace, in the order a plain write applies them. The
## reference and its spectrum are prepared once. None leaves every sample as
## it is written today. A reference the correlation job would refuse is
## refused before any byte is written, in that job's words. The result's
## lines then include that job's notes for this file. A trace that could
## not be read is written as zeros, and the result says how many.

import std/[math, options, os, random, sets, strutils, times]
import parseSEG
import parseSEG/model/traceindex
import processSEG
import correlatejobs, edits, filesystem, jobs, panels, processing, reader, signatures, sorting,
  vendormaps

const
  TraceBlock = 64 ## traces read, then written, between two cancel checks
  HeaderNotCarried* =
    "The signature file's own header block is not carried when traces are changed."
  SurveyJoinedNotWritten* =
    "Survey positions joined to this file are not written: the file's own header block is kept."
    ## A survey join filled positions into the keys; the file's own header block is what is written.
  PositionsNotWritten* =
    "The session's positions were not written: the file's own headers were kept."
  PositionsUnstored* =
    "Survey and moved positions could not be written in this format."
    ## Every joined or moved position of a written trace had no slot, or did not fit.
  OwnPositionsWritten* =
    "The file's own positions were written from its header keys."
    ## The keys path, with the tick on: geometry came from the file's own headers.

type
  OutputFormat* = enum
    ## The standard of the file to write.
    ofSegy = "SEG-Y"
    ofSegd = "SEG-D"

  OutputCorrelation* = object
    ## A loaded reference, the sweep `correlateWork` takes, and the auxiliary
    ## traces that hold one. None on `OutputOptions` leaves every sample as
    ## it is written today.
    reference*: seq[float32]
    referenceDtMs*: float64
    referenceTraces*: seq[int]

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
    writeSessionPositions*: bool = true
      ## A survey join or a station move is written into the headers, on every
      ## path. Off: the file's own positions are written, and the result says so.
    correlation*: Option[OutputCorrelation]
      ## None: the samples written today. Set: correlate each trace with this
      ## reference, into the listen time. Correlated samples are IEEE float32
      ## in the source's amplitude units (an arrival shaped like the sweep
      ## with amplitude a correlates to a peak of a). Positions are written
      ## by the same rule as any other Output, not as the correlation job's
      ## in-memory file.

  OutputResult* = object
    ## What the write did. `ok` false: `reason` is a sentence for the user.
    ok*: bool
    written*: int
    dropped*: int
    lines*: seq[string] ## writer's diagnostics; correlation notes when correlating
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

proc canonPath*(path: string): string =
  ## Absolute path, with the parent folder's links resolved, as
  ## `refuseDestination` uses. A missing file's parent is resolved, so a
  ## path under a linked folder is still seen as inside it. Reads the file
  ## system: not for the UI thread.
  canon(path)

proc pathsEqual*(a, b: string): bool =
  ## Whether `a` and `b` are the same path. On Windows the comparison
  ## ignores case.
  samePath(a, b)

proc pathInside*(path, folder: string): bool =
  ## Whether `path` is `folder` or lies inside it. On Windows the comparison
  ## ignores case.
  insideFolder(path, folder)

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

func positionsWritten*(n: int): string =
  ## The note when every joined or moved position of a written trace was stored.
  "Survey and moved positions were written into the headers (" & $n & " traces changed)."

func positionsWherePlace*(n: int): string =
  ## The note when some of those positions were stored and some were not.
  "Survey and moved positions were written where the format has a place for them (" &
    $n & " traces changed)."

func sessionPositions(file: SeismicFile): tuple[any: bool; changed: int] =
  ## Whether the session's keys hold positions that did not come from the
  ## file's own headers, and how many traces a join or a move changed.
  if not file.hasKeys: return
  var changed = 0
  for groups in file.index.joinedTraces:
    if groups.card > 0: inc changed
  (file.index.joined or changed > 0, changed)

type
  WrittenPositions = object
    n: int
    sourceXy, receiverXy, sourceZ, receiverZ, derived: int
    sourceStation, receiverStation: int
  GapCounts = object
    n: array[8, int]
    unnamed: bool

const GapKind = [
  "source X/Y", "receiver X/Y", "source elevation", "receiver elevation",
  "midpoint", "offset", "source station", "receiver station"]

func writtenPositions(file: SeismicFile; edits: FileEdits; dropKilled: bool): WrittenPositions =
  ## Position groups on traces that are written, not on a killed trace left out.
  if not file.hasKeys: return
  let marks = file.index.joinedTraces
  for t in 0 ..< file.len:
    if dropKilled and edits.has(teKilled, t): continue
    if t >= marks.len: continue
    let g = marks[t]
    var any = false
    if jgSourceXy in g:
      inc result.sourceXy
      any = true
    if jgReceiverXy in g:
      inc result.receiverXy
      any = true
    if jgSourceZ in g:
      inc result.sourceZ
      any = true
    if jgReceiverZ in g:
      inc result.receiverZ
      any = true
    if jgDerived in g:
      inc result.derived
      any = true
    if jgSourceStation in g:
      inc result.sourceStation
      any = true
    if jgReceiverStation in g:
      inc result.receiverStation
      any = true
    if any: inc result.n

func messageOf(line: string): string =
  let at = line.find("]:")
  if at >= 0: line[at + 2 .. ^1].strip()
  else:
    let colon = line.find(": ")
    if colon >= 0: line[colon + 2 .. ^1] else: line

func intAfter(line: string; at: int): int =
  var i = at
  while i < line.len and line[i] == ' ': inc i
  var n = 0
  var any = false
  while i < line.len and line[i] in {'0'..'9'}:
    any = true
    n = n * 10 + (ord(line[i]) - ord('0'))
    inc i
  if any and n > 0: n else: 1

func gapsNoted(line, msg: string): int =
  const inMark = "; not written in "
  let inAt = line.find(inMark)
  if inAt >= 0: return intAfter(line, inAt + inMark.len)
  if line.find("not written:") >= 0:
    const comma = ", in "
    let at = line.find(comma)
    if at >= 0: return intAfter(line, at + comma.len)
  if line.find("do not fit") >= 0: return intAfter(msg, 0)
  1

func addGap(g: var GapCounts; line: string) =
  if line.find("; not written") < 0 and line.find("not written:") < 0 and
      line.find("do not fit") < 0:
    return
  let msg = messageOf(line)
  let n = gapsNoted(line, msg)
  let colon = msg.find(": ")
  if colon > 0 and not msg.startsWith("not written"):
    let kind = msg[0 ..< colon].strip()
    for i, name in GapKind:
      if kind == name:
        g.n[i] += n
        return
  g.unnamed = true

func positionSentence(w: WrittenPositions; gaps: GapCounts): string =
  ## What to say after close. "" when no written trace carried a position.
  if w.n == 0: return ""
  var groups = 0
  var full = 0
  template cover(need: int; ok: bool) =
    if need > 0:
      inc groups
      if ok: inc full
  cover(w.sourceXy, gaps.n[0] >= w.sourceXy)
  cover(w.receiverXy, gaps.n[1] >= w.receiverXy)
  cover(w.sourceZ, gaps.n[2] >= w.sourceZ)
  cover(w.receiverZ, gaps.n[3] >= w.receiverZ)
  cover(w.derived, gaps.n[4] >= w.derived and gaps.n[5] >= w.derived)
  cover(w.sourceStation, gaps.n[6] >= w.sourceStation)
  cover(w.receiverStation, gaps.n[7] >= w.receiverStation)
  if groups == 0: return ""
  if full == groups: return PositionsUnstored
  var anyGap = gaps.unnamed
  if not anyGap:
    for c in gaps.n:
      if c > 0: anyGap = true
  if anyGap: return positionsWherePlace(w.n)
  positionsWritten(w.n)

func withOwnGeometry(session, own: TraceKeys): TraceKeys =
  ## `session` with the position fields of the file's own header keys.
  result = session
  result.srcX = own.srcX
  result.srcY = own.srcY
  result.srcZ = own.srcZ
  result.rcvX = own.rcvX
  result.rcvY = own.rcvY
  result.rcvZ = own.rcvZ
  result.offset = own.offset
  result.cmpX = own.cmpX
  result.cmpY = own.cmpY
  result.srcLine = own.srcLine
  result.srcPoint = own.srcPoint
  result.srcIndex = own.srcIndex
  result.rcvLine = own.rcvLine
  result.rcvPoint = own.rcvPoint
  result.rcvIndex = own.rcvIndex
  result.component = own.component

proc openHeaderKeys(file: SeismicFile; source: string): SeismicFile =
  ## The file's own header keys. A file in memory is copied; its path is not
  ## opened. A disk file is read through `fs` first.
  let opts = OpenOptions(vendors: currentVendors())
  if file.inMemory:
    let n = file.mappedSize
    if n < 0 or n > int64(high(int)):
      raise newException(ValueError, "The file is too large to read its own positions.")
    var bytes = file.copyBytes(0, int(n))
    result = openSeismicBytes(bytes, source, keys = false, opts = opts)
  else:
    fs.mappedRead(source)
    result = openSeismic(source, keys = false, opts = opts)

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

func changesTraces(opts: OutputOptions): bool =
  ## Whether an option that changes samples or which traces are written is on.
  ## The flag counts, not whether a trace is actually different.
  opts.correlation.isSome or opts.sortKeys.len > 0 or opts.dropKilled or
    opts.applyReversals or opts.applyShifts or opts.applyOwnFilters or
    opts.applyProcessing

proc writePart(path: string; bytes: openArray[byte]) =
  ## Writes `bytes` into the empty part file `path`, through `fs`.
  var f: File
  if not fs.open(f, path, fmWrite):
    raise newException(IOError, extractFilename(path) & " cannot be written.")
  try:
    if bytes.len > 0 and fs.writeBuffer(f, path, unsafeAddr bytes[0], bytes.len) != bytes.len:
      raise newException(IOError, extractFilename(path) & " was not written whole.")
  finally:
    close(f)

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

proc writeOutput*(ctx: JobContext; file: ptr SeismicFile; source, dest: string;
    opts: OutputOptions; edits: FileEdits; openPaths: seq[string]; sink: OutputSink;
    report: proc (done, total: int): bool {.gcsafe.}; signature = SignatureFacts()) =
  ## Writes `file` to `dest` on `ctx`'s thread, as `outputWork` does.
  ## `report` is told traces handled of the file's traces, the same numbers
  ## `progress` is told, and false from it cancels. The caller names the
  ## phase. The library path names the write of the part file, so a cancel
  ## asked as those bytes are written is seen before the rename.
  ## `sink.result` is set before this returns, fails or is cancelled. A
  ## cancel is looked for at each record and each block of traces, and after
  ## a signature file's own bytes are written; either that or a failure
  ## removes the part file and says so.
  ## The destination name is never touched.
  if sink != nil: sink.result = OutputResult(path: dest, lines: @[])
  var claimed = false
  var part = ""
  var lines: seq[string] = @[]
  var headerKeys: SeismicFile
  var openedHeader = false
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
      var correlating = false
      var listen = 0
      var recordSamples = 0
      var lag = 0
      var outUs = 0.0
      var refs = initHashSet[int]()
      var odd = initHashSet[int]()
      var plan: CorrelationPlan[float32]
      var ws = initWorkspace()
      var corrDst: seq[float32] = @[]
      var corrKeys: seq[TraceKeys] = @[]
      var corrCounts: seq[int] = @[]
      var corrMeta: ChunkMeta
      var corrDtMs = 0.0
      if opts.correlation.isSome:
        if file == nil or not file[].isOpen:
          raise newException(ValueError, "The source file is not open.")
        if file[].len == 0:
          raise newException(ValueError, "The file has no traces.")
        if not file[].hasKeys:
          if not file[].inMemory: fs.mappedRead(source, headers = true)
          file[].ensureKeys()
        var loaded = opts.correlation.get
        let ready = listenShape(file, loaded.reference, loaded.referenceDtMs)
        refs = referenceSet(file[].len, loaded.referenceTraces)
        listen = ready.listen
        recordSamples = ready.samples
        for t in ready.odd: odd.incl(t)
        lag = wholeSamples(-AuxLeadMs, ready.dtMs)
        if opts.format == ofSegd: outUs = wholeMicroseconds(ready.dtMs)
        let pilot = initPilot(loaded.reference, loaded.referenceDtMs)
        plan = initCorrelationPlan(float32, pilot, ready.dtMs, recordSamples)
        ws.reserve(plan.workspaceSize)
        corrDst = newSeq[float32](listen)
        corrKeys = @[initTraceKeys()]
        corrCounts = @[recordSamples]
        corrMeta = initChunkMeta(rowsOf(corrKeys, corrCounts), ready.dtMs)
        corrDtMs = ready.dtMs
        correlating = true
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
      let segdOut = outKind == skSegd
      if signature.isSignature and segdOut and not changesTraces(opts):
        # `index.joined` is set only when a join changed the keys, the same
        # fact a finished join keeps once positions were filled in.
        if file[].index.joined: lines.add SurveyJoinedNotWritten
        if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
        let carried = signatureSegdBytes(source, signature)
        if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
        ctx.setPhase "writing the signature file"
        writePart(part, carried)
        if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
        if not fs.moveNoReplace(part, dest):
          let kept = "The file appeared while writing; the output is kept as " & part & "."
          if sink != nil:
            sink.result = OutputResult(ok: false, written: n, lines: lines, path: part,
              reason: kept)
          claimed = false
          raise newException(ValueError, kept)
        claimed = false
        if sink != nil:
          sink.result = OutputResult(ok: true, written: n, lines: lines, path: dest)
        return
      if srcKind notin {skSegy, skSegd, skSeg2}:
        abort(sink, dest, part, claimed, "The file is not SEG-Y, SEG-D or SEG-2.", false)
      let byEntry = srcKind == skSegd
      let splitRecords = outKind == skSegd
      if not file[].hasKeys and (opts.sortKeys.len > 0 or (splitRecords and not byEntry)):
        if not file[].inMemory: fs.mappedRead(source, headers = true)
        file[].ensureKeys()
      var dropped = 0
      var written = 0
      var unread = 0
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
        if not file[].inMemory: fs.mappedRead(source, headers = true)
        file[].ensureKeys()
      if not like:
        lines.add "Headers were built from the trace keys. Template headers were not copied."
      if signature.isSignature and segdOut and changesTraces(opts):
        lines.add HeaderNotCarried
      let positions = sessionPositions(file[])
      let carryPositions = like and opts.writeSessionPositions and positions.any
      if like and not opts.writeSessionPositions and positions.any:
        lines.add PositionsNotWritten
      if not like and not opts.writeSessionPositions and positions.any:
        headerKeys = openHeaderKeys(file[], source)
        openedHeader = true
      var samples = newSeq[float32]()
      let dtMs = if correlating: corrDtMs else: file[].sampleIntervalUs(0) / 1000.0
      var correlatedOver: seq[HeaderOverride] = @[]
      if correlating and not segdOut:
        correlatedOver = @[headerOverride("trace.correlated", CorrelatedYes)]
      block writing:
        var w: SeismicWriter
        if like:
          if correlating and segdOut:
            w = openSeismicWriter(part, file[], segdFormat = tf8058)
          elif correlating:
            w = openSeismicWriter(part, file[], segyFormat = st5)
          else:
            w = openSeismicWriter(part, like = file[])
        elif segdOut:
          var count = int(file[].traceEntry(head).numSamples)
          if correlating: count = listen
          else:
            for i in 0 ..< n:
              if opts.dropKilled and edits.has(teKilled, i): continue
              let c = int(file[].traceEntry(i).numSamples)
              if c != count:
                abort(sink, dest, part, claimed,
                  "SEG-D output needs one sample count; this file has more than one.", false)
          var o = SegdOutputOptions(sampleIntervalUs: file[].sampleIntervalUs(head),
            numSamples: count)
          if correlating: o.sampleIntervalUs = outUs
          let t0 = file[].traceKeys(head).time
          if not t0.isNaN: o.time = t0
          w = openSeismicWriter(part, o)
        else:
          w = openSeismicWriter(part, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
        var readLog: DiagLog
        template writeOne(t: int) =
          readLog = DiagLog()
          let x = if correlating: file[].readTraces(t .. t, readLog)
                  else: file[].readTraces(t .. t)
          if correlating and readLog.len > 0: inc unread
          let cols = x.shape[1]
          samples.setLen cols
          for j in 0 ..< cols: samples[j] = x[0, j]
          # A kill is only applied by leaving the trace out. A killed trace
          # that is kept is written like any other, options applied. With
          # no option on, the samples stay as read (no key lookup, so a
          # file opened without keys still writes).
          if correlating:
            let have = samples.len
            if have < recordSamples:
              samples.setLen recordSamples
              for j in have ..< recordSamples: samples[j] = 0
            elif have > recordSamples:
              samples.setLen recordSamples
            let status = file[].traceKeys(t).status
            let aux = status == tsAuxiliary
            let isOdd = t in odd
            let isRef = t in refs
            if aux and isRef and not isOdd and lag != 0: timeShift(samples, lag)
            # A dead seismic trace stays dead. correlateInto then writes zeros,
            # as the correlation job does; marking it live would correlate it.
            if status == tsDead or (aux and (not isRef or isOdd)):
              corrKeys[0].status = tsDead
            else: corrKeys[0].status = tsLive
            plan.correlateInto(rowBlock(samples, 1, recordSamples),
              rowBlock(corrDst, 1, listen), corrMeta, ws)
            if not (aux and not isRef and not isOdd):
              for j in 0 ..< listen: samples[j] = corrDst[j]
            # Edits below see the listen length, as a plain write of the
            # correlated file does. A shift or a filter before correlation
            # is not that result.
            samples.setLen(listen)
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
            if correlating:
              # A file cut while it is open refuses a template header read.
              # The samples are already in hand (zeros when the read failed):
              # write those from the keys, which do not touch the map.
              var stored = false
              try:
                if carryPositions:
                  w.writeTrace(file[], t, toOpenArray(samples, 0, listen - 1),
                    keys = file[].traceKeys(t), overrides = correlatedOver)
                else:
                  w.writeTrace(file[], t, toOpenArray(samples, 0, listen - 1),
                    overrides = correlatedOver)
                stored = true
              except SegTruncatedError:
                discard
              if not stored:
                var keys = file[].traceKeys(t)
                let channel = if keys.status == tsAuxiliary: sctOther else: sctSeismic
                if segdOut: keys.intervalUs = outUs
                w.writeTrace(keys, toOpenArray(samples, 0, listen - 1),
                  overrides = correlatedOver, channelType = channel)
            elif carryPositions:
              w.writeTrace(file[], t, samples, keys = file[].traceKeys(t))
            else:
              w.writeTrace(file[], t, samples)
          else:
            var keys = file[].traceKeys(t)
            if openedHeader:
              var own: array[1, TraceKeys]
              headerKeys.traceKeysInto([t], own)
              keys = withOwnGeometry(keys, own[0])
            let channel = if keys.status == tsAuxiliary: sctOther else: sctSeismic
            if correlating:
              if segdOut: keys.intervalUs = outUs
              w.writeTrace(keys, toOpenArray(samples, 0, listen - 1),
                overrides = correlatedOver, channelType = channel)
            else:
              w.writeTrace(keys, samples, channelType = channel)
          inc written
        template writeList(list: openArray[int]) =
          if list.len > 0:
            if stopAsked(ctx): abort(sink, dest, part, claimed, "Cancelled.", true)
            if not file[].inMemory: fs.mappedRead(source)
            for t in list: writeOne(t)
            if report == nil or not report(written + dropped, n):
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
        if openedHeader:
          lines.add OwnPositionsWritten
        elif opts.writeSessionPositions and positions.any:
          var gaps: GapCounts
          for d in log: addGap(gaps, $d)
          let sentence = positionSentence(writtenPositions(file[], edits, opts.dropKilled), gaps)
          if sentence.len > 0: lines.add sentence
        for d in log: lines.add($d)
        if correlating:
          let loaded = opts.correlation.get
          let ready = listenShape(file, loaded.reference, loaded.referenceDtMs)
          var delayed = 0
          for t in loaded.referenceTraces:
            if file[].traceKeys(t).status == tsAuxiliary and t notin ready.odd:
              inc delayed
          let leadSamples = abs(wholeSamples(-AuxLeadMs, ready.dtMs))
          # A cut found while writing refuses a later header read. The notes
          # that can still be built are kept; the unread count does not depend
          # on that read.
          try:
            for line in correlationLines(file, file[].len, ready.listen, loaded.reference.len,
                float64(ready.listen) * ready.dtMs,
                float64(loaded.reference.len) * ready.dtMs, ready.dtMs, delayed,
                leadSamples, ready.padded, ready.cut, refs, ready.odd):
              lines.add line
          except SegTruncatedError:
            discard
          if unread == 1:
            lines.add "1 trace could not be read and is written as zeros."
          elif unread > 1:
            lines.add($unread & " traces could not be read and are written as zeros.")
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
  finally:
    if openedHeader: headerKeys.close()

proc outputWork*(file: ptr SeismicFile; source, dest: string; opts: OutputOptions;
    edits: FileEdits; openPaths: seq[string]; sink: OutputSink;
    signature = SignatureFacts()): JobWork =
  ## Writes `file` to `dest` on a job thread. `file` stays open until the
  ## job ends (submit it with `outputSpec`). `sink.result` is set before the
  ## job returns, fails or is cancelled. A cancel is looked for at each
  ## record and each block of traces, and after a signature file's own bytes
  ## are written; either that or a failure removes the part file and says so.
  ## The destination name is never touched.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "writing"
    {.cast(gcsafe).}:
      writeOutput(ctx, file, source, dest, opts, edits, openPaths, sink,
        proc (done, total: int): bool {.gcsafe.} = ctx.progress(done, total), signature)
