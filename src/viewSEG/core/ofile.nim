## An SPS file of receiver-domain (O) records made from the X records of the
## imported survey, on a job (`oFileWork`).
##
## X records say, per shot record, which receiver stations recorded it. O
## records say the same per receiver: which source points it recorded.
## `deriveOFile` takes them from parseSEG's `receiverRelations` and writes
## them in the revision, line ending and H records of the X file they come
## from. Several X files give what one file of all their X records gives: each
## file's field records are numbered on after the ones before, so a shot point
## shot again in another file is one more trace, as in one file. O records hold
## one trace per source and receiver station: the channels of a station's
## further components are not in them, and `OFileSummary` counts what that
## leaves out. A receiver gather is never cut in two: one with more traces than
## the channel columns hold is an error. The file is written through a
## temporary file beside it, then renamed; the source files are never opened
## for writing (`refusedTarget`).
##
## Memory: with one X file, the job holds the O records, parseSEG's index of the
## X records by receiver line (an entry per X record) with the sources of the
## largest receiver line, and the file's text. Several files add one copy of
## their X records, merged; nothing is held per source and receiver pair.

import std/[os, sets, strutils]
import parseSEG
import filesystem, jobs, shotlogsps

const
  OFileExt* = ".ops"
    ## The extension parseSEG gives O records: it reads such a file's records as receiver gathers.
  HeadChunk = 64 * 1024
  MergeChunk = 4096                ## X records added to a merged geometry at a time
  HeadTail = 8 * 1024              ## records read past the H records, to tell the revision
  MaxHeadBytes* = 64 * 1024 * 1024 ## the H records of an SPS file are not longer than this

type
  OFileSummary* = object
    ## What was written, and what O records cannot say of the X records.
    file*: string   ## the file written; "" until it is
    records*: int   ## O records
    receivers*: int ## gathers: one per receiver station
    sources*: int   ## distinct source points among the traces
    pairs*: int     ## source and receiver pairs written (the gathers' traces)
    revision*: SpsRevision
    headers*: int   ## H records copied from the X file
    components*: int
      ## channels of a station beyond its first, in X records that cover several per
      ## station (summed over the X files): O records have no place for them
    overlapped*: int
      ## stations of X records left out because another X record of the same field
      ## record, before them, gives their channels
    widened*: bool ## written as SPS 2.1: the numbers did not fit the X file's SPS 1.0
    error*: string ## why nothing was written; "" when the file was

  OFileSink* = ref object
    ## Filled when the job ends. Read it after the job is no longer running.
    sources*: seq[string] ## the X files, in the order of the survey; the first gives the layout
    dest*: string
    summary*: OFileSummary

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func stationWords(line, point: float64; index: int): string =
  ## "line 100, point 105", with the index when it is one of several.
  func num(x: float64): string =
    if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)
  result = "line " & num(line) & ", point " & num(point)
  if index > 1: result.add ", index " & $index

proc readHead*(path: string; limit = MaxHeadBytes): SpsFile {.raises: [IOError].} =
  ## The head of the SPS file `path`, read as a file of its own: its revision, line
  ## ending and H records. It is read in chunks up to the first record that is not an
  ## H or C record, and a little further (so the revision is known from records when
  ## no H record says), never the whole file. H records past `limit` bytes are an error.
  var f: File = nil
  if not fs.open(f, path, fmRead):
    raise newException(IOError, "cannot read " & path)
  var text = ""
  var buf = newString(HeadChunk)
  var scanned = 0 # the start of the first line not looked at
  var body = -1 # the start of the first line that is not an H or C record
  var eof = false
  try:
    while not eof:
      let n = fs.readBuffer(f, path, addr buf[0], HeadChunk)
      eof = n < HeadChunk
      if n > 0: text.add buf.substr(0, n - 1)
      while body < 0:
        let nl = text.find('\n', scanned)
        if nl < 0: break
        if text[scanned] notin {'H', 'C', '\r', '\n'}: body = scanned
        else: scanned = nl + 1
      if body >= 0 and text.len - body >= HeadTail: break
      if body < 0 and text.len > limit:
        raise newException(IOError, "the H records of " & path & " run past " &
          $(limit div (1024 * 1024)) & " MiB")
  finally:
    close(f)
  if not eof:
    let cut = text.rfind('\n')
    if cut >= 0: text.setLen(cut + 1)
  try:
    result = parseSps(text, path, SpsOptions(keepRaw: false, keepNames: false))
  except CatchableError as e:
    raise newException(IOError, "cannot read the records of " & path & ": " & e.msg)

func pointKey(line, point: float64; index: int): (int64, int64, int) =
  (int64(round(line * 100)), int64(round(point * 100)), index)

proc countSources(rels: openArray[SpsRelation]): int =
  var seen = initHashSet[(int64, int64, int)]()
  for r in rels:
    let n = r.toChannel - r.fromChannel
    let step = if n > 0: (r.toReceiver - r.fromReceiver) / float64(n) else: 0.0
    for i in 0'i64 .. n:
      seen.incl pointKey(r.rcvLine, r.fromReceiver + float64(i) * step, r.rcvIndex)
  seen.len

proc xCounts(g: SurveyGeometry): tuple[stations, channels: int] =
  ## The stations of `g`'s X records, and their channels (several per station in
  ## X records that cover a station's components).
  for rec in g.records(rdSource):
    for run in g.relationRuns(rec, rdSource):
      result.stations += run.stations
      result.channels += run.stations * run.components

proc mergedX(gs: openArray[ref SurveyGeometry]): SurveyGeometry =
  ## The X relations of every geometry of `gs` in one, as one file of all their X
  ## records gives them: each geometry's field records numbered on after the ones
  ## before (two files' records do not meet), each X record as its geometry holds
  ## it. Only a station's first component is kept (O records have no other), so
  ## geometries with and without several components per station merge alike; a
  ## record whose X records share channels is taken channel by channel, each
  ## channel's station as its own geometry decides. Added a few records at a time:
  ## nothing but the merged geometry grows with the survey.
  result = initSurveyGeometry()
  var total = 0
  for g in gs: total += g[].relationCount(rdSource)
  result.reserveRelations(total, rdSource)
  var part = SpsFile()
  template take(r: SpsRelation) =
    part.relations.add r
    if part.relations.len >= MergeChunk:
      result.addSps(part, rdSource)
      part.relations.setLen 0
  var next = 0'i64 # the number the next geometry's first record takes
  for g in gs:
    var first = 0'i64
    var started = false
    var last = next - 1
    for rec in g[].records(rdSource): # (ascending)
      if not started: (first, started) = (rec, true)
      last = rec - first + next
      if g[].relationsDisjoint(rec, rdSource):
        for run in g[].relationRuns(rec, rdSource):
          var r = initSpsRelation()
          r.fieldRecord = last
          (r.srcLine, r.srcPoint, r.srcIndex) =
            (run.fixed.line, run.fixed.point, int(run.fixed.index))
          r.fromChannel = run.fromChannel
          r.toChannel = run.fromChannel + int64(run.stations - 1) * run.channelStep
          r.channelIncrement = int(run.channelStep)
          (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) =
            (run.line, run.firstPoint, run.lastPoint, int(run.index))
          take r
      else:
        for (channel, rel) in g[].relations(rec, rdSource):
          if rel.component <= 1:
            var r = initSpsRelation()
            r.fieldRecord = last
            (r.srcLine, r.srcPoint, r.srcIndex) =
              (rel.source.line, rel.source.point, int(rel.source.index))
            (r.fromChannel, r.toChannel, r.channelIncrement) = (channel, channel, 1)
            (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) = (rel.receiver.line,
              rel.receiver.point, rel.receiver.point, int(rel.receiver.index))
            take r
    next = last + 1
  if part.relations.len > 0: result.addSps(part, rdSource)

proc oFileOf(g: SurveyGeometry; head: SpsFile; stations, channels: int):
    tuple[file: SpsFile; summary: OFileSummary] =
  ## `deriveOFile` of `g`, whose X files have `stations` stations in their X
  ## records and `channels` channels.
  let rev = if head.revision == spsAuto: sps21 else: head.revision
  var file = SpsFile(name: head.name, revision: rev,
    revisionDeclared: head.revisionDeclared, crlf: head.crlf, headers: head.headers,
    relations: g.receiverRelations(1, 'O'), finalNewline: true)
  var s = OFileSummary(records: file.relations.len, revision: rev,
    headers: head.headers.len, components: channels - stations)
  var gathers = initHashSet[int64]()
  for r in file.relations:
    gathers.incl r.fieldRecord
    s.pairs += int(r.toChannel - r.fromChannel + 1)
  s.receivers = gathers.len
  s.sources = file.relations.countSources
  s.overlapped = max(stations - s.pairs, 0)
  (file, s)

proc deriveOFile*(g: SurveyGeometry; head: SpsFile):
    tuple[file: SpsFile; summary: OFileSummary] =
  ## The O records of `g`'s X relations, in a file that has `head`'s revision,
  ## line ending and H records, and what they leave out.
  let c = xCounts(g)
  oFileOf(g, head, c.stations, c.channels)

proc deriveOFile*(gs: openArray[ref SurveyGeometry]; head: SpsFile):
    tuple[file: SpsFile; summary: OFileSummary] =
  ## `deriveOFile` of the X relations of every geometry of `gs`, as of one file
  ## that holds all their X records, one geometry's after the other's.
  var stations, channels = 0
  for g in gs:
    let c = xCounts(g[])
    stations += c.stations
    channels += c.channels
  if gs.len == 1: oFileOf(gs[0][], head, stations, channels)
  else: oFileOf(mergedX(gs), head, stations, channels)

proc refusedTarget*(dest: string; sources: openArray[string]): string =
  ## Why `dest` may not be written: it is one of `sources` (the survey's files
  ## and the open files), by name, or, when it exists, the same file as one of
  ## them (a link, a hard link); "" when it may. Pass canonical paths. A source
  ## that cannot be looked at decides nothing by itself.
  let name = dest.extractFilename
  if name.len == 0: return "no file name was given"
  let exists = fs.fileExists(dest)
  for p in sources:
    var same = p == dest
    if not same and exists:
      try:
        same = sameFile(p, dest)
      except OSError:
        discard
    if same:
      return name & " is one of the survey's own files or an open file; choose another name"
  ""

const
  MaxChannel = [sps10: 9999'i64, sps21: 99999'i64] ## traces of a gather the columns hold
  SizeError = "an O record does not fit the SPS "

func mostTraces(rels: openArray[SpsRelation]): tuple[traces: int64; at: int] =
  ## The traces of the receiver gather that has most (traces are numbered from 1 in
  ## each gather), and the index in `rels` of an O record of it; -1 for none.
  result = (0'i64, -1)
  for i, r in rels:
    if r.toChannel > result.traces: result = (r.toChannel, i)

proc firstError(log: DiagLog; rev: SpsRevision): string =
  ## The first problem of the writer, naming the O record (not the X record the
  ## writer's words are for).
  for d in log:
    if d.severity in {sevError, sevFatal}:
      let what = if d.msg.startsWith("X."): d.msg[2 .. ^1] else: d.msg
      return SizeError & $rev & " columns (line " & $(d.loc.record + 1) & "): " & what

proc renderOFile*(file: SpsFile; s: var OFileSummary): string =
  ## The text of `file`'s O records in the revision of `s`, or, when its numbers do
  ## not fit SPS 1.0, in SPS 2.1. Updates `s`. "" when they do not fit SPS 2.1
  ## either: `s.error` then names the receiver with more traces than a gather
  ## holds, or the O record that does not fit.
  let most = mostTraces(file.relations)
  if most.traces > MaxChannel[sps21]:
    let r = file.relations[most.at]
    s.error = "the receiver at " & stationWords(r.srcLine, r.srcPoint, r.srcIndex) &
      " recorded " & $most.traces & " traces, and an SPS 2.1 gather holds at most " &
      $MaxChannel[sps21]
    return ""
  let first = s.revision
  for rev in [first, sps21]:
    if most.traces <= MaxChannel[rev]:
      let t = spsText(file, SpsWriteOptions(revision: rev))
      if not t.log.hasErrors:
        s.widened = rev != first
        s.revision = rev
        s.error = ""
        return t.text
      s.error = firstError(t.log, rev)
    if first == sps21: break
  ""

proc oFileSpec*(dest: string): JobSpec =
  ## The job that writes `dest`: background, needing `dest` to itself and reading the X file.
  JobSpec(title: "Generate O file " & dest.extractFilename, lane: jlBackground,
    exclusive: @[dest])

proc oFileWork*(gs: seq[ref SurveyGeometry]; sink: OFileSink): JobWork =
  ## Writes the O records of the X relations `gs` (those of the files `sink.sources`) to
  ## `sink.dest` on a job thread. `sink.summary` is set before the job
  ## returns; its `error` is empty when the file was written. A file already
  ## at `dest` is replaced, whole or not at all; a cancel leaves it as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      var s = OFileSummary()
      try:
        ctx.setPhase("Reading the X file's headers")
        let head = if sink.sources.len > 0: readHead(sink.sources[0]) else: SpsFile()
        ctx.checkCancelled()
        ctx.setPhase("Deriving the O records")
        let made = deriveOFile(gs, head)
        s = made.summary
        ctx.checkCancelled()
        ctx.setPhase("Writing")
        let text = if made.file.relations.len > 0: renderOFile(made.file, s) else: ""
        if s.error.len > 0: discard
        elif text.len == 0:
          s.error = "the survey has no X records to take O records from"
        else:
          ctx.checkCancelled()
          s.error = writeBeside(sink.dest, text, replace = true)
          if s.error.len == 0: s.file = sink.dest
      except JobCancelledError:
        sink.summary = s
        raise
      except CatchableError as e:
        s.error = if e.msg.len > 0: e.msg else: "the O file could not be made"
      sink.summary = s

func oFileSentences*(s: OFileSummary; name: string; sources: openArray[string]): string =
  ## What was written, and what it leaves out, in sentences; with how to use it.
  result = "Wrote " & plural(s.records, "O record", "O records") & " to " & name & ": " &
    plural(s.receivers, "receiver", "receivers") & ", " &
    plural(s.sources, "source point", "source points") & ", " &
    plural(s.pairs, "source and receiver pair", "source and receiver pairs") &
    ", made from the X records of " & sources.join(", ") & " in its SPS revision " & $s.revision &
        " with " &
    plural(s.headers, "H record", "H records") & "."
  if s.components > 0:
    result.add " O records have no component: " & plural(s.components, "channel", "channels") &
      " beyond each station's first are not in the file."
  if s.overlapped > 0:
    result.add " " & plural(s.overlapped, "station", "stations") &
      " of X records are left out: an X record of the same field record before them gives " &
      "their channels."
  if s.widened:
    result.add " It is written as SPS 2.1: the numbers do not fit SPS 1.0."
  result.add " The file is not imported: add it in the Import survey window to use it."
