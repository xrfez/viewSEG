## An open file and what the viewer keeps of it.
##
## A `Session` is made on a job thread (`filejobs.openSession`), moved to the
## UI thread through the inbox, and kept by `AppState`, which gives it a
## `SessionId` and the survey-wide number of its first trace. Its fields do not
## change after that, apart from the file being closed and its records'
## check against a loaded relation file (`setChecks`). What the Headers
## window's Summary and File headers tabs show of the file (`facts`,
## `core/headers`) is read with it, on the same thread.
##
## Trace ids are survey-wide: `base + index`. Bases are never reused, so an id
## kept by a view never names a trace of a file opened later.

import std/[os, strutils, times]
import parseSEG
import filesystem, headers, records

export headers, records

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

const NoSession* = SessionId(0)

func `==`*(a, b: SessionId): bool {.borrow.}
func `$`*(id: SessionId): string = "file " & $int(id)

proc newSession*(path: string; file: sink SeismicFile; size = -1'i64;
    modified = Time()): Session =
  ## A session for `file`, opened from `path`, with its gathers and the
  ## record list's rows, its coordinates and what the Headers window shows of
  ## it (`facts`); `size` and `modified` are the file's as it was opened. On
  ## the thread that opened the file: the file's own headers are read from
  ## its map here (`fs.mappedRead`), so a drive that does not answer holds
  ## this thread, never the UI's, and one that fails leaves them unread, said
  ## in `facts.problems`.
  result = Session(path: path, file: file, size: size, modified: modified)
  result.gathers = result.file.gathers
  result.records = recordRows(result.file, result.gathers)
  result.columns = columnsOf(result.records)
  var readable = true
  try:
    fs.mappedRead(path, headers = true)
  except OSError as e:
    readable = false
    var msg = e.msg # its first line: the system's words
    let cut = msg.find('\n')
    if cut >= 0: msg.setLen cut
    result.facts.problems.add "the file's headers cannot be read now (" & msg & "): its " &
      "drive went away or fails; open the file again once it answers"
  try:
    let sum = result.file.summary
    result.crs = FileCrs(units: sum.coordinateUnits, format: sum.crsFormat)
    if readable and sum.crsFormat != ctNone: result.crs.text = result.file.crsText
  except CatchableError:
    discard # a file whose summary cannot be made says nothing of its coordinates
  var problems = move result.facts.problems
  result.facts = fileFacts(result.file, headers = readable)
  problems.add result.facts.problems
  result.facts.problems = move problems

proc register*(s: Session; id: SessionId; base: int) =
  ## Gives `s` its id and the survey-wide id of its first trace (`AppState`
  ## does this when it adopts the session).
  s.id = id
  s.base = base

func id*(s: Session): SessionId {.inline.} = s.id
func base*(s: Session): int {.inline.} = s.base
  ## The survey-wide id of trace 0.
func path*(s: Session): lent string {.inline.} = s.path
func name*(s: Session): string = s.path.extractFilename
  ## The file's name, for messages and titles.
func file*(s: Session): lent SeismicFile {.inline.} = s.file
func gathers*(s: Session): lent seq[Gather] {.inline.} = s.gathers
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
