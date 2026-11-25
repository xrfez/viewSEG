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
    file*: string    ## the file written; "" until it is
    records*: int    ## O records
    receivers*: int  ## gathers: one per receiver station
    sources*: int    ## distinct source points among the traces
    pairs*: int      ## source and receiver pairs written (the gathers' traces)
    revision*: SpsRevision
    headers*: int    ## H records copied from the X file
    components*: int
      ## channels of a station beyond its first, in X records that cover several per
      ## station: O records have no place for them
    shared*: int
      ## pairs the X records give twice through channels two runs cover, written once
    noStations*: int ## X records without receiver stations
    error*: string ## why nothing was written; "" when the file was

  OFileSink* = ref object
    ## Filled when the job ends. Read it after the job is no longer running.
    source*, dest*: string
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

proc deriveOFile*(g: SurveyGeometry; head: SpsFile): tuple[file: SpsFile; summary: OFileSummary] =
  ## The O records of `g`'s X relations, in a file that has `head`'s revision,
  ## line ending and H records, and what they leave out.
  let rev = if head.revision == spsAuto: sps21 else: head.revision
  var file = SpsFile(name: head.name, revision: rev,
    revisionDeclared: head.revisionDeclared, crlf: head.crlf, headers: head.headers,
    relations: g.receiverRelations(1, 'O'), finalNewline: true)
  var s = OFileSummary(records: file.relations.len, revision: rev,
    headers: head.headers.len)
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
      if run.stations <= 0 or run.toChannel < run.fromChannel:
        inc s.noStations
      else:
        x += run.stations
        channels += run.stations * run.components
  s.components = channels - x
  s.shared = max(x - s.pairs, 0)
  (file, s)

proc refusedTarget*(dest: string; sources: openArray[string]): string =
  ## Why `dest` may not be written: it is one of `sources` (the survey's files
  ## and the open files); "" when it may. Paths are compared as given, so pass
  ## them canonical.
  let name = dest.extractFilename
  if name.len == 0: return "no file name was given"
  for p in sources:
    if p == dest:
      return name & " is one of the survey's own files or an open file; choose another name"
  ""

proc firstError(log: DiagLog): string =
  for d in log:
    if d.severity in {sevError, sevFatal}: return d.msg

proc oFileSpec*(dest: string): JobSpec =
  ## The job that writes `dest`: background, needing `dest` to itself and reading the X file.
  JobSpec(title: "Generate O file " & dest.extractFilename, lane: jlBackground,
    exclusive: @[dest])

proc oFileWork*(g: ref SurveyGeometry; sink: OFileSink): JobWork =
  ## Writes the O records of `g` (the X file `sink.source`'s relations) to
  ## `sink.dest` on a job thread. `sink.summary` is set before the job
  ## returns; its `error` is empty when the file was written. A file already
  ## at `dest` is replaced, whole or not at all; a cancel leaves it as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      var s = OFileSummary()
      try:
        ctx.setPhase("Reading the X file's headers")
        let head = readHead(sink.source)
        ctx.checkCancelled()
        ctx.setPhase("Deriving the O records")
        let made = deriveOFile(g[], head)
        s = made.summary
        ctx.checkCancelled()
        ctx.setPhase("Writing")
        let t = spsText(made.file)
        if t.log.hasErrors:
          s.error = "an O record does not fit the columns: " & firstError(t.log)
        elif t.text.len == 0:
          s.error = "the survey has no X records to take O records from"
        else:
          ctx.checkCancelled()
          s.error = writeBeside(sink.dest, t.text, replace = true)
          if s.error.len == 0: s.file = sink.dest
      except JobCancelledError:
        sink.summary = s
        raise
      except CatchableError as e:
        s.error = if e.msg.len > 0: e.msg else: "the O file could not be made"
      sink.summary = s

func oFileSentences*(s: OFileSummary; name, source: string): string =
  ## What was written, and what it leaves out, in sentences; with how to use it.
  result = "Wrote " & plural(s.records, "O record", "O records") & " to " & name & ": " &
    plural(s.receivers, "receiver", "receivers") & ", " &
    plural(s.sources, "source point", "source points") & ", " &
    plural(s.pairs, "source and receiver pair", "source and receiver pairs") &
    ", made from the X records of " & source & " in its SPS revision " & $s.revision & " with " &
    plural(s.headers, "H record", "H records") & "."
  if s.components > 0:
    result.add " O records have no component: " & plural(s.components, "channel", "channels") &
      " beyond each station's first are not in the file."
  if s.shared > 0:
    result.add " " & plural(s.shared, "pair", "pairs") &
      " that the X records give through channels two runs share are written once."
  if s.noStations > 0:
    result.add " " & plural(s.noStations, "X record has", "X records have") &
      " no receiver stations and give no O record."
  result.add " The file is not imported: add it in the Imported Survey window to use it."
