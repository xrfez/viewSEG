## An open file and what the viewer keeps of it.
##
## A `Session` is made on a job thread (`filejobs.openSession`), moved to the
## UI thread through the inbox, and kept by `AppState`, which gives it a
## `SessionId` and the survey-wide number of its first trace. Its fields do not
## change after that, apart from the file being closed, its records'
## check against a loaded relation file (`setChecks`) and the revision of
## its keys after a join (`setKeysRevision`). What the Headers window's
## Summary and File headers tabs show of the file (`facts`, `core/headers`)
## is read with it, on the same thread.
##
## Trace ids are survey-wide: `base + index`. Bases are never reused, so an id
## kept by a view never names a trace of a file opened later.

import std/[math, os, strutils, times]
import parseSEG
import filesystem, headers, records, sigtypes

export headers, records, sigtypes

type
  SessionId* = distinct int
    ## Names an open file; never reused. `NoSession` (0) names none.

  FileCrs* = object
    ## What a file's headers say of its coordinates, read on the open job (a
    ## file on a network drive may hang a read: never on the UI thread).
    units*: CoordinateUnits
      ## parseSEG's `summary.coordinateUnits`
    format*: CrsTextFormat
      ## the format of `text`; `ctNone` when the file gives none
    text*: string
      ## its coordinate reference system, as stored (`crsText`)
    measurement*: int16
      ## the binary header's measurement system (SEG-Y): 1 metres, 2 feet,
      ## 0 not given; the unit trace offsets are in
    lengthUnit*: string
      ## the unit of length that CRS names for its grid (parseSEG's
      ## `parseCrsText`: its projection's parameters, "US survey foot",
      ## "metre"), as written; "" when it names none

  Session* {.acyclic.} = ref object
    ## An open seismic file. A `ref`, so that workers can hold a stable
    ## `ptr SeismicFile` into it (docs/architecture.md, "Threads"); only the
    ## UI thread holds the `ref` itself once it is adopted.
    id: SessionId
    base: int
    path: string
    file: SeismicFile
    gathers: seq[Gather]
    records: seq[RecordRow]
    columns: set[RecordColumn]
    size: int64 ## the file's size when it was opened; -1 when not known
    modified: Time ## its modification time then
    checkedAgainst: string ## the relation file its records were checked against; "" none
    crs: FileCrs ## what its headers say of its coordinates
    facts: FileFacts ## its summary and file headers, for the Headers window
    keysRevision: int
      ## its keys' revision (parseSEG's `keysRevision`) as the UI thread knows it
    zeroKept: int
      ## traces with field record number 0 kept with the record before them
    signature: SignatureFacts
      ## a vibrator controller's signature file decoded in memory: what is known of it beyond
      ## the SEG-Y (`kind` `sgNone` for any other file)

const NoSession* = SessionId(0)

func `==`*(a, b: SessionId): bool {.borrow.}
func `$`*(id: SessionId): string = "file " & $int(id)

func lengthUnitOf*(c: CoordinateReference): string =
  ## The unit of length a CRS's projection gives its grid parameters in (the
  ## false easting and northing, as a rule: "US survey foot", "metre"), as
  ## written; "" when no parameter names one. Angles and scale factors are
  ## passed by.
  for p in c.projection.parameters:
    let u = p.unit.strip
    let low = u.toLowerAscii
    if u.len > 0 and "degree" notin low and "radian" notin low and "grad" notin low and
        "unity" notin low and "second" notin low and "minute" notin low and
        low notin ["dms", "deg", "°", "1"]:
      return u

proc keepZeroRecords(f: SeismicFile; gathers: var seq[Gather]): int =
  ## A SEG-Y file gathered by field record number: a run of traces whose field record number
  ## is 0 (not a number: "not set") that directly follows a record of another number joins
  ## that record, and the gather is counted again, when every trace of the run is
  ## auxiliary by its identification code (a vibrator's force trace, say) or the run's shot
  ## time equals the previous record's and is set. Otherwise it stays a record of its own,
  ## as before. Returns the traces so kept. A file whose first traces are 0, or whose every
  ## number is 0, is left as it is; so is one gathered by ensemble, receiver or offset.
  if f.kind != skSegy or f.index.keys.len != f.len or
      int(f.index.segy.binary.traceSorting) in [2, 3, 4, 6, 7, 8, 9]: return
  template k(t: int): untyped = f.index.keys[t]
  var kept: seq[Gather] = @[]
  for g in gathers:
    var joins = false
    if kept.len > 0 and k(g.traces.a).record == 0 and k(kept[^1].traces.a).record != 0:
      var allAux = true
      for t in g.traces:
        if not f.auxLike(k(t)):
          allAux = false
          break
      let (now, before) = (k(g.traces.a).time, k(kept[^1].traces.a).time)
      joins = allAux or (now == before and not now.isNaN and now != 0)
    if joins:
      result += g.traces.len
      kept[^1] = f.index.classify(kept[^1].traces.a .. g.traces.b)
    else: kept.add g
  if result > 0: gathers = kept

proc newSession*(path: string; file: sink SeismicFile; size = -1'i64;
    modified = Time(); choice = OpenChoice(); signature = SignatureFacts()): Session =
  ## A session for `file`, opened from `path`, with its gathers and the
  ## record list's rows, its coordinates and what the Headers window shows of
  ## it (`facts`, with how it was opened with `choice`); `size` and
  ## `modified` are the file's as it was opened. On
  ## the thread that opened the file: the file's own headers are read from
  ## its map here (`fs.mappedRead`), so a drive that does not answer holds
  ## this thread, never the UI's, and one that fails leaves them unread, said
  ## in `facts.problems`. A signature file (`signature.kind` not `sgNone`) is decoded in
  ## memory: `path` is still the user's file, `size` and `modified` its own, and the
  ## memory file's bytes are not mapped from `path`.
  result = Session(path: path, file: file, size: size, modified: modified, signature: signature)
  result.gathers = result.file.gathers
  result.zeroKept = keepZeroRecords(result.file, result.gathers)
  result.records = recordRows(result.file, result.gathers)
  if signature.kind != sgNone:
    # every trace of a signature file counts as auxiliary (`auxLike`)
    for r in result.records.mitems:
      (r.seismic, r.dead, r.aux) = (0, 0, r.traces)
  var anySeismic = false
  for r in result.records:
    if r.seismic > 0: anySeismic = true
  if result.records.len > 0 and not anySeismic:
    # The header's count of data traces per ensemble names seismic traces; a file of
    # auxiliary traces only has none to miss.
    for r in result.records.mitems: r.declared = -1
  result.columns = columnsOf(result.records)
  var readable = true
  try:
    if signature.kind == sgNone: fs.mappedRead(path, headers = true) # (a memory file has no map)
  except OSError as e:
    readable = false
    var msg = e.msg # its first line: the system's words
    let cut = msg.find('\n')
    if cut >= 0: msg.setLen cut
    result.facts.problems.add "the file's headers cannot be read now (" & msg & "): its " &
      "drive went away or fails; open the file again once it answers"
  result.keysRevision = result.file.keysRevision
  try:
    let sum = result.file.summary
    result.crs = FileCrs(units: sum.coordinateUnits, format: sum.crsFormat,
      measurement: result.file.index.segy.binary.measurementSystem)
    if readable and sum.crsFormat != ctNone:
      result.crs.text = result.file.crsText
      result.crs.lengthUnit = lengthUnitOf(result.file.crs)
  except CatchableError:
    discard # a file whose summary cannot be made says nothing of its coordinates
  var problems = move result.facts.problems
  result.facts = fileFacts(result.file, headers = readable)
  problems.add result.facts.problems
  result.facts.problems = move problems
  if readable: result.facts.opened = openFacts(result.file, choice, size)
  else: result.facts.opened = OpenFacts(choice: choice, kind: result.file.kind,
    detected: result.file.kind)

proc register*(s: Session; id: SessionId; base: int) =
  ## Gives `s` its id and the survey-wide id of its first trace (`AppState`
  ## does this when it adopts the session).
  s.id = id
  s.base = base

func signature*(s: Session): lent SignatureFacts {.inline.} = s.signature
  ## What is known of a signature file beyond its in-memory SEG-Y.
func traceNames*(s: Session): seq[string] =
  ## A signature file's name of each trace, in the file's order; empty for any other file.
  for t in s.signature.traces: result.add t.name

func isSignature*(s: Session): bool {.inline.} = s.signature.kind != sgNone
  ## Whether the file is a vibrator controller's signature file, decoded in memory.

func auxLike*(s: Session; k: TraceKeys): bool {.inline.} =
  ## Whether viewSEG treats the trace as auxiliary: its status says so, or the file is a
  ## signature file, all of whose traces are (a `.vib`'s codes above 22 read back with
  ## status unknown, which would count them as seismic data).
  s.file.auxLike(k) or s.signature.kind != sgNone

func id*(s: Session): SessionId {.inline.} = s.id
func base*(s: Session): int {.inline.} = s.base
  ## The survey-wide id of trace 0.
func path*(s: Session): lent string {.inline.} = s.path
func name*(s: Session): string = s.path.extractFilename
  ## The file's name, for messages and titles.
func file*(s: Session): lent SeismicFile {.inline.} = s.file
func zeroKept*(s: Session): int {.inline.} = s.zeroKept
  ## Traces with field record number 0 that were kept with the record before them.
func gathers*(s: Session): lent seq[Gather] {.inline.} = s.gathers
func noSeismic*(s: Session): bool =
  ## Whether the file holds traces but no seismic one (all are auxiliary).
  if s.records.len == 0: return false
  for r in s.records:
    if r.seismic > 0: return false
  true

func records*(s: Session): lent seq[RecordRow] {.inline.} = s.records
  ## One row per gather, for the record list.
func recordColumns*(s: Session): set[RecordColumn] {.inline.} = s.columns
  ## The record list's columns some row has a value for.
func crs*(s: Session): lent FileCrs {.inline.} = s.crs
  ## What the file's headers say of its coordinates: units and CRS text.
func facts*(s: Session): lent FileFacts {.inline.} = s.facts
  ## What the Headers window shows of the file: its summary and file headers.
func checkedAgainst*(s: Session): lent string {.inline.} = s.checkedAgainst
  ## The relation file the records' planned stations come from; "" for none.
func keysRevision*(s: Session): int {.inline.} = s.keysRevision
  ## The revision of the file's keys (parseSEG's `keysRevision`) when it was
  ## opened, or after the join that changed them last: what a layer or a
  ## check made from the keys is compared with. Kept here, so the UI thread
  ## never reads the file's own, which a join's step changes on its job.

proc setKeysRevision*(s: Session; revision: int) =
  ## A join changed the file's keys: their revision is now `revision`.
  s.keysRevision = revision

proc setChecks*(s: Session; against: string; planned, missing: openArray[int];
    unlisted: openArray[int] = []; duplicates: openArray[int] = []) =
  ## The records checked against relation file `against` (its name): per
  ## gather, the stations planned, those with no trace, the traces at
  ## stations the plan does not list and the stations recorded twice (-1 for
  ## a record the file does not plan; `unlisted` and `duplicates` may be
  ## empty: not counted). An `against` of "" clears the check. Lists of
  ## another length than the records change nothing.
  if against.len == 0:
    s.checkedAgainst = ""
    for r in s.records.mitems:
      (r.planned, r.plannedMissing, r.unlisted, r.duplicates) = (-1, -1, -1, -1)
  elif planned.len == s.records.len and missing.len == s.records.len:
    s.checkedAgainst = against
    for i, r in s.records.mpairs:
      (r.planned, r.plannedMissing) = (planned[i], missing[i])
      r.unlisted = if unlisted.len == s.records.len: unlisted[i] else: -1
      r.duplicates = if duplicates.len == s.records.len: duplicates[i] else: -1

func len*(s: Session): int {.inline.} = s.file.len
  ## The number of traces.
func size*(s: Session): int64 {.inline.} = s.size
  ## The file's size in bytes when it was opened; -1 when not known.
func modified*(s: Session): Time {.inline.} = s.modified
  ## The file's modification time when it was opened.

func traceIds*(s: Session): Slice[int] {.inline.} =
  ## The survey-wide ids of the file's traces.
  s.base ..< s.base + s.file.len

func contains*(s: Session; trace: int): bool {.inline.} =
  ## Whether survey-wide trace id `trace` is one of this file's.
  trace in s.traceIds

proc filePtr*(s: Session): ptr SeismicFile {.inline.} =
  ## The file, for a worker that reads it while the UI thread keeps the
  ## session (and closes it only once no job uses it).
  addr s.file
