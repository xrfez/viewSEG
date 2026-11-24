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
##
## A session derived from a file on disk (a correlated record) keeps that
## file's path in `origin` and a virtual key in `path`, set by `asDerived`
## before it is adopted. The key is `correlatedPath` of the file on disk: the
## same for that file every time, and not a path any file system can name.
## Readers and jobs still hold, read and close by `path`. `diskPath` is the
## file on disk.
##
## A correlated view is derived the same way, and does not own a second file.
## `asCorrelatedView` keeps the raw session open and shares one `CorrelateView`.
## `file` and `filePtr` are that raw file. `facts` report the listen time
## (sample count, interval and trace length). The record length stays the raw
## header's. Header rows of the binary and general header are marked stored;
## their values stay the raw file's, including its stored sample count. `close`
## of the view does not close the raw file. `close` of the raw file is refused
## while a view of it exists: close the view first, as a derived view is closed
## before its origin.

import std/[atomics, math, os, strutils, times]
import parseSEG
import correlateview, filesystem, headers, records, sigtypes

export headers, records, sigtypes

type
  SessionId* = distinct int
    ## Names an open file; never reused. `NoSession` (0) names none.

  ViewHold = object
    ## One correlated view's count against the raw session it reads. Destroying
    ## the view drops the count, so the raw file can be closed afterwards.
    raw: Session
    released: bool

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
    origin: string
      ## the path of the file this session was derived from; empty for a file on disk
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
    leapRead: int
      ## the leap-table generation the keys were read under; -1 when it changed
      ## during the read, so the post queues a re-read
    zeroKept: int
      ## traces with field record number 0 kept with the record before them
    signature: SignatureFacts
      ## a vibrator controller's signature file decoded in memory: what is known of it beyond
      ## the SEG-Y (`kind` `sgNone` for any other file)
    view: ref CorrelateView
      ## the shared correlated view; nil when this session is not one
    listenSamples: int
      ## listen-time samples; 0 when this session is not a correlated view
    listenDtMs: float64
      ## listen-time sample interval, ms; 0 when this session is not one
    originSession: Session
      ## the raw session a correlated view reads; nil otherwise
    openViews: Atomic[int]
      ## correlated views that still read this raw file; raised when a view
      ## is opened and lowered when that view is closed or destroyed, which
      ## may be another thread
    hold: ViewHold
      ## this view's count in the raw session's `openViews`

proc `=destroy`(h: ViewHold)
proc `=wasMoved`(h: var ViewHold)
proc `=copy`(dest: var ViewHold; src: ViewHold) {.error.}
proc `=dup`(src: ViewHold): ViewHold {.error.}

proc `=wasMoved`(h: var ViewHold) =
  ## The count stays with the hold that was moved to. The source must not
  ## drop it when it is destroyed.
  h.released = true
  h.raw = nil

proc dropOpenView(raw: Session) =
  ## One view stopped reading `raw`. A count already at zero is put back,
  ## so a second drop cannot drive it negative.
  if raw.isNil: return
  let prev = raw.openViews.fetchSub(1, moAcquireRelease)
  if prev <= 0:
    discard raw.openViews.fetchAdd(1, moRelease)

proc `=destroy`(h: ViewHold) =
  ## Drops the count when the view is discarded without `close`.
  if not h.released: dropOpenView(h.raw)
  `=destroy`(h.raw)

template releaseHold(h: var ViewHold) =
  if not h.released:
    dropOpenView(h.raw)
    h.released = true
    h.raw = nil

const NoSession* = SessionId(0)

const CorrelateSuffix = "correlated\0"
  ## Ends a derived session's path. No file system allows a name to end in
  ## NUL, so the key cannot be a real path. The word sits before the NUL, so
  ## a C string of the key does not name the file on disk.

func correlatedPath*(raw: string): string {.inline.} =
  ## The virtual key of a session derived from the file at `raw`: stable for
  ## that file, and not a path any file system can name. Built here only.
  raw & CorrelateSuffix

func diskOf*(path: string): string {.inline.} =
  ## The file on disk a path names. A derived session's virtual key is
  ## stripped of its suffix; any other path is returned as given.
  if path.endsWith(CorrelateSuffix): path[0 ..< path.len - CorrelateSuffix.len]
  else: path

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
        if k(t).status != tsAuxiliary:
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
    # A file already in memory has no map: asking about `path` would hand a
    # virtual key to the file system when this session is derived.
    if signature.kind == sgNone and not result.file.inMemory:
      fs.mappedRead(path, headers = true)
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

proc asDerived*(s: Session) =
  ## Records `s.path` as the file this session was derived from and retargets
  ## `path` to `correlatedPath` of that file. Call after `newSession`, which
  ## reads the file on disk under the path it was given. A session that
  ## already has an origin is left as it is.
  if s.origin.len > 0: return
  s.origin = s.path
  s.path = correlatedPath(s.origin)

proc markStoredHeaders(facts: var FileFacts) =
  ## Binary and general-header rows are the raw file's. `facts.rows` groups
  ## them by `blockName` (`binary`, `gh1`, ...). Their descriptions say stored,
  ## so a listen count is not read as the stored sample count. SEG-D general
  ## headers are per record and are not in `facts.rows`; the summary's record
  ## length is that header fact.
  for row in facts.rows.mitems:
    if (row.blockName == "binary" or row.blockName.startsWith("gh")) and
        not row.description.startsWith("Stored: "):
      row.description = "Stored: " & row.description

proc applyListenFacts(facts: var FileFacts; listen: int; dtMs: float64) =
  ## Summary and channel-set sample counts become the listen time. The record
  ## length stays the raw header's. Binary and general-header rows are marked
  ## stored; their values are left as the raw file stored them.
  let us = dtMs * 1000.0
  facts.summary.samplesPerTrace = listen
  facts.summary.sampleIntervalUs = us
  for c in facts.channelSets.mitems:
    c.samplesPerTrace = listen
    c.sampleIntervalUs = us
    if c.startTimeMs.isNaN: c.endTimeMs = float64(listen) * dtMs
    else: c.endTimeMs = c.startTimeMs + float64(listen) * dtMs
  markStoredHeaders(facts)

proc viewReady(view: CorrelateView): bool =
  view.listenSamples > 0 and view.dtMs > 0 and not view.dtMs.isNaN and view.dtMs != Inf

proc asCorrelatedView*(raw: Session; view: CorrelateView): Session =
  ## A derived session that is `raw`'s file seen at `view`'s listen time.
  ## The raw file stays open: this session does not own a copy of it, and
  ## `file` / `filePtr` are that file. `facts` report the listen sample count,
  ## interval and trace length. The record length stays the raw header's.
  ## Binary and general-header rows are marked stored; their values stay
  ## `raw`'s, including the stored sample count. Raises `ValueError` when `raw`
  ## is closed, is itself a view, or `view` was not built.
  if raw.isNil or not raw.file.isOpen:
    raise newException(ValueError, "the file is not open.")
  if not raw.view.isNil:
    raise newException(ValueError, "a correlated view is not a raw file.")
  if not viewReady(view):
    raise newException(ValueError, "the correlated view was not built.")
  let onDisk = if raw.origin.len > 0: raw.origin else: raw.path
  if view.path.len > 0 and view.path != raw.path and view.path != onDisk:
    raise newException(ValueError, "the correlated view is of another file.")
  result = Session(path: correlatedPath(onDisk), origin: onDisk,
    gathers: raw.gathers, records: raw.records, columns: raw.columns,
    size: raw.size, modified: raw.modified, checkedAgainst: raw.checkedAgainst,
    crs: raw.crs, facts: raw.facts, keysRevision: raw.keysRevision,
    leapRead: raw.leapRead, zeroKept: raw.zeroKept, signature: raw.signature,
    listenSamples: view.listenSamples, listenDtMs: view.dtMs, originSession: raw)
  result.view = new CorrelateView
  result.view[] = view
  discard raw.openViews.fetchAdd(1, moRelease)
  result.hold.raw = raw
  applyListenFacts(result.facts, view.listenSamples, view.dtMs)

proc dropView(s: Session) =
  releaseHold(s.hold)
  s.view = nil
  s.originSession = nil
  s.listenSamples = 0
  s.listenDtMs = 0

proc close*(s: Session): bool =
  ## Closes `s`. A correlated view drops its hold and does not close the raw
  ## file. A raw file that still has a view is left open (false): close the
  ## view first. Idempotent. A nil session is already closed.
  if s.isNil: return true
  if not s.view.isNil:
    dropView(s)
    return true
  if s.openViews.load(moAcquire) > 0: return false
  if s.file.isOpen: s.file.close()
  true

proc register*(s: Session; id: SessionId; base: int) =
  ## Gives `s` its id and the survey-wide id of its first trace (`AppState`
  ## does this when it adopts the session).
  s.id = id
  s.base = base

func signature*(s: Session): lent SignatureFacts {.inline.} = s.signature
  ## What is known of a signature file beyond its in-memory SEG-Y.
func traceNames*(s: Session): seq[string] =
  ## A signature file's name of each trace, in the file's order; empty for any other file.
  for t in s.signature.traces: result.add t.short & "\t" & t.name

func isSignature*(s: Session): bool {.inline.} = s.signature.kind != sgNone
  ## Whether the file is a vibrator controller's signature file, decoded in memory.

func id*(s: Session): SessionId {.inline.} = s.id
func base*(s: Session): int {.inline.} = s.base
  ## The survey-wide id of trace 0.
func path*(s: Session): lent string {.inline.} = s.path
func origin*(s: Session): lent string {.inline.} = s.origin
  ## The path of the file this session was derived from; empty for a file on disk.
func derived*(s: Session): bool {.inline.} = s.origin.len > 0
  ## Whether this session was derived from a file on disk.
func isCorrelatedView*(s: Session): bool {.inline.} =
  ## Whether `s` is a correlated view of a raw file that stays open.
  not s.isNil and not s.view.isNil
func correlatedView*(s: Session): ref CorrelateView {.inline.} =
  ## The shared view, or nil when `s` is not a correlated view.
  if s.isNil: nil else: s.view
func listenSamples*(s: Session): int {.inline.} =
  ## Listen-time samples; 0 when `s` is not a correlated view.
  if s.isNil: 0 else: s.listenSamples
func listenDtMs*(s: Session): float64 {.inline.} =
  ## Listen-time sample interval, ms; 0 when `s` is not a correlated view.
  if s.isNil: 0 else: s.listenDtMs
func diskPath*(s: Session): string {.inline.} =
  ## The file on disk: the origin when this session was derived from one,
  ## otherwise its path.
  if s.origin.len > 0: s.origin else: s.path
func name*(s: Session): string = s.diskPath.extractFilename
  ## The file's name, for messages and titles: the file on disk, never a
  ## derived session's virtual key.
func file*(s: Session): lent SeismicFile {.inline.} =
  ## The open file. A correlated view's is the raw session's, not a copy.
  if not s.originSession.isNil: return s.originSession.file
  s.file
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
func leapRead*(s: Session): int {.inline.} = s.leapRead
  ## The leap-table generation the keys were read under; -1 when it changed
  ## during the read.

proc noteLeapRead*(s: Session; gen: int) =
  ## Records the generation `openSession` saw while it read the keys.
  s.leapRead = gen

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

func len*(s: Session): int {.inline.} =
  ## The number of traces.
  if s.originSession.isNil: s.file.len else: s.originSession.file.len
func size*(s: Session): int64 {.inline.} = s.size
  ## The file's size in bytes when it was opened; -1 when not known.
func modified*(s: Session): Time {.inline.} = s.modified
  ## The file's modification time when it was opened.

func traceIds*(s: Session): Slice[int] {.inline.} =
  ## The survey-wide ids of the file's traces.
  s.base ..< s.base + s.len

func contains*(s: Session; trace: int): bool {.inline.} =
  ## Whether survey-wide trace id `trace` is one of this file's.
  trace in s.traceIds

proc filePtr*(s: Session): ptr SeismicFile {.inline.} =
  ## The file, for a worker that reads it while the UI thread keeps the
  ## session (and closes it only once no job uses it). A correlated view's
  ## pointer is the raw session's file, which that view keeps alive.
  if s.originSession.isNil: addr s.file else: addr s.originSession.file
