## An SPS file of receiver-domain (O) records made from the X records of the
## imported survey, on a job (`oFileWork`).
##
## X records say, per shot record, which receiver stations recorded it. O
## records say the same per receiver: which source points it recorded.
## `deriveOFile` takes them from parseSEG's `receiverRelations` and writes
## them in the revision, line ending and H records of the X file they come
## from. O records hold one trace per source and receiver station: the
## channels of a station's further components are not in them, and
## `OFileSummary` counts what that leaves out. The file is written through a
## temporary file beside it, then renamed; the source files are never opened
## for writing (`refusedTarget`).

import std/[os, sets, strutils]
import parseSEG
import filesystem, jobs, shotlogsps

const
  OFileExt* = ".ops"
    ## The extension parseSEG gives O records: it reads such a file's records as receiver gathers.
  HeadBytes = 256 * 1024

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
      ## station: O records have no place for them
    shared*: int
      ## pairs the X records give twice, through channels two runs cover or in two files,
      ## written once
    widened*: bool ## written as SPS 2.1: the numbers did not fit the X file's SPS 1.0
    extraGathers*: int
      ## gathers made beyond one per receiver: a receiver with more traces than the
      ## channel columns hold takes one more for each further run
    error*: string ## why nothing was written; "" when the file was

  OFileSink* = ref object
    ## Filled when the job ends. Read it after the job is no longer running.
    sources*: seq[string] ## the X files, in the order of the survey; the first gives the layout
    dest*: string
    summary*: OFileSummary

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

proc readHead(path: string): SpsFile {.raises: [IOError].} =
  ## The first records of the SPS file `path`, read as a file of their own: its
  ## revision, line ending and H records.
  var f: File = nil
  if not fs.open(f, path, fmRead):
    raise newException(IOError, "cannot read " & path)
  var text = newString(HeadBytes)
  var n = 0
  try:
    n = fs.readBuffer(f, path, addr text[0], text.len)
  finally:
    close(f)
  text.setLen(n)
  if n == text.len and n == HeadBytes:
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

type PairKey = (float64, float64, int16, float64, float64, int16)

func pairKey(src, rcv: StationKey): PairKey =
  (src.line, src.point, src.index, rcv.line, rcv.point, rcv.index)

proc mergedX(gs: openArray[ref SurveyGeometry]): tuple[g: SurveyGeometry; shared: int] =
  ## The X relations of every geometry in one, a pair that an earlier one
  ## has left out (counted in `shared`). Field records are numbered on after the
  ## ones before, so two files' records do not meet.
  var rels: seq[SpsRelation]
  var seen = initHashSet[PairKey]()
  var offset = 0'i64
  for g in gs:
    var fresh = initHashSet[PairKey]()
    var highest = 0'i64
    for rec in g[].records(rdSource):
      highest = max(highest, rec)
      for run in g[].relationRuns(rec, rdSource):
        var first = -1
        proc flush(last: int) =
          if first >= 0:
            var r = initSpsRelation()
            r.fieldRecord = rec + offset
            (r.srcLine, r.srcPoint, r.srcIndex) =
              (run.fixed.line, run.fixed.point, int(run.fixed.index))
            r.fromChannel = run.fromChannel + int64(first) * run.channelStep
            r.toChannel = run.fromChannel + int64(last) * run.channelStep +
              int64(run.components) - 1
            r.channelIncrement = int(run.channelStep)
            (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) =
              (run.line, run.station(first).point, run.station(last).point, int(run.index))
            rels.add r
            first = -1
        for i in 0 ..< run.stations:
          let k = pairKey(run.fixed, run.station(i))
          if k in seen:
            inc result.shared
            flush(i - 1)
          else:
            fresh.incl k
            if first < 0: first = i
        flush(run.stations - 1)
    seen.incl fresh
    offset += highest
  result.g = initSurveyGeometry()
  result.g.multiComponent = gs[0][].multiComponent
  result.g.addSps(SpsFile(relations: rels), rdSource)

proc deriveOFile*(g: SurveyGeometry; head: SpsFile; shared = 0):
    tuple[file: SpsFile; summary: OFileSummary] =
  ## The O records of `g`'s X relations, in a file that has `head`'s revision,
  ## line ending and H records, and what they leave out. `shared` counts pairs
  ## already left out of `g` because another file gave them.
  let rev = if head.revision == spsAuto: sps21 else: head.revision
  var file = SpsFile(name: head.name, revision: rev,
    revisionDeclared: head.revisionDeclared, crlf: head.crlf, headers: head.headers,
    relations: g.receiverRelations(1, 'O'), finalNewline: true)
  var s = OFileSummary(records: file.relations.len, revision: rev,
    headers: head.headers.len, shared: shared)
  var gathers = initHashSet[int64]()
  for r in file.relations:
    gathers.incl r.fieldRecord
    s.pairs += int(r.toChannel - r.fromChannel + 1)
  s.receivers = gathers.len
  s.sources = file.relations.countSources
  var x = 0
  var channels = 0
  for rec in g.records(rdSource):
    for run in g.relationRuns(rec, rdSource):
      x += run.stations
      channels += run.stations * run.components
  s.components = channels - x
  s.shared += max(x - s.pairs, 0)
  (file, s)

proc deriveOFile*(gs: openArray[ref SurveyGeometry]; head: SpsFile):
    tuple[file: SpsFile; summary: OFileSummary] =
  ## `deriveOFile` of the X relations of every geometry of `gs` together.
  if gs.len == 1:
    result = deriveOFile(gs[0][], head)
  else:
    let m = mergedX(gs)
    result = deriveOFile(m.g, head, m.shared)

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

proc fitted(rels: openArray[SpsRelation]; maxChannel: int64):
    tuple[rels: seq[SpsRelation]; extra: int] =
  ## `rels` with their traces numbered from 1 in each gather, and a receiver whose
  ## traces would pass `maxChannel` given a further gather (the same receiver, its
  ## next traces numbered from 1), the runs cut where they must be. Gathers are
  ## numbered on from 1 as the receivers come.
  var gather = 0'i64
  var next = 1'i64
  var last = -1'i64
  for r in rels:
    if r.fieldRecord != last:
      last = r.fieldRecord
      inc gather
      next = 1
    let n = r.toChannel - r.fromChannel + 1
    let step = if n > 1: (r.toReceiver - r.fromReceiver) / float64(n - 1) else: 0.0
    var done = 0'i64
    while done < n:
      if next > maxChannel:
        inc gather
        inc result.extra
        next = 1
      let take = min(maxChannel - next + 1, n - done)
      var p = r
      p.fieldRecord = gather
      p.fromChannel = next
      p.toChannel = next + take - 1
      if done > 0: p.fromReceiver = r.fromReceiver + float64(done) * step
      if done + take < n: p.toReceiver = r.fromReceiver + float64(done + take - 1) * step
      result.rels.add p
      next += take
      done += take

proc firstError(log: DiagLog; rev: SpsRevision): string =
  ## The first problem of the writer, naming the O record (not the X record the
  ## writer's words are for).
  for d in log:
    if d.severity in {sevError, sevFatal}:
      let what = if d.msg.startsWith("X."): d.msg[2 .. ^1] else: d.msg
      return SizeError & $rev & " columns (line " & $(d.loc.record + 1) & "): " & what

proc renderOFile*(file: SpsFile; s: var OFileSummary): string =
  ## The text of `file`'s O records in the revision of `s`, or, when its numbers do
  ## not fit SPS 1.0, in SPS 2.1; a receiver with more traces than the channel
  ## columns hold is given further gathers. Updates `s`; its `error` says why
  ## when the text is "".
  let first = s.revision
  for rev in [first, sps21]:
    let cut = fitted(file.relations, MaxChannel[rev])
    var f = file
    f.relations = cut.rels
    let t = spsText(f, SpsWriteOptions(revision: rev))
    if not t.log.hasErrors:
      s.records = cut.rels.len
      s.extraGathers = cut.extra
      s.widened = rev != first
      s.revision = rev
      s.error = ""
      return t.text
    s.error = firstError(t.log, rev)
    if first == sps21: break

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
        let head = readHead(sink.sources[0])
        ctx.checkCancelled()
        ctx.setPhase("Deriving the O records")
        let made = deriveOFile(gs, head)
        s = made.summary
        ctx.checkCancelled()
        ctx.setPhase("Writing")
        let text = renderOFile(made.file, s)
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
  if s.shared > 0:
    result.add " " & plural(s.shared, "pair", "pairs") &
      " that the X records give twice (through channels two runs share, or in two files) " &
      "are written once."
  if s.widened:
    result.add " It is written as SPS 2.1: the numbers do not fit SPS 1.0."
  if s.extraGathers > 0:
    result.add " " & plural(s.extraGathers, "gather was", "gathers were") &
      " added: a receiver's traces do not fit the channel columns in one."
  result.add " The file is not imported: add it in the Import survey window to use it."
