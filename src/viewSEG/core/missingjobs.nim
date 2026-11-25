## Background jobs that open seismic files for their trace keys and count the
## stations the survey's relation records call for that the files do not hold
## (`missingreport`).
##
## `scanMissing` is the work: the caller lists the paths and passes the folder
## they sit under, so a path in a message is relative to that folder, and the
## imported survey's relations (`SurveyGeometry`, or nil). The job does not
## look at app state and does not change the relations. One file's keys are
## in memory at a time for each thread the item pool gives the job (several
## files are open at once). Each file's shot gathers are checked on the thread that read
## it; what a file adds to the scan (its own `StationTally`, its receivers and the sources
## they recorded, its unmatched gathers) is added on the job's thread in file order, so
## the report is the same on any number of threads. The receiver side keeps, for each
## receiver station of the whole scan, only the source stations it recorded, a bit for
## each source station of the scan (`IdSet`), and checks each receiver once when every
## file is read. The File tab runs it on one path, the Folder tab on the paths
## `folderScan` lists (subfolders only when asked).
##
## A file that cannot be opened, or that has no trace keys, is skipped and
## the scan goes on. A path already scanned (compared normalised) is not
## scanned again. A gather whose template record cannot be told is not
## counted: it is listed in `unmatched` with the reason. No survey (nil, or
## no relations) fails the job with one sentence (`NoSurvey`). A cancel,
## also while the receivers are checked, leaves the sink untouched.
##
## What a file is (`reportside.reportSide`, the one rule: the kind of recording the file
## is treated as, the one the user set in the Files window or else the one told from the
## file; stations are by line and point): a shot gather is checked against its X record,
## receivers expected; a receiver gather (a receiver's record sliced by shot) against the
## O record of its receiver, shots expected. A continuous receiver recording is not
## checked (`notChecked`), nor is a file whose kind cannot be told (one receiver and one
## source) and was not set. A scan of shot gathers and receiver gathers together is not
## calculated: the result says so (`mixed`, `sides`) and holds no figures. Every trace of
## one receiver station, in any file and any number of gathers (one for each shot slice),
## is one check, so a receiver side's `records` are receivers checked, and its `Missing`
## for a source is the receivers that lack it.
##
## Several X records at a shot's source station: the record number does not
## pick one (`recordCompleteness` would). The shot is checked against each, a
## template shared by several records (a reshoot of one patch) once, and takes
## the one that shares the most stations with the data, then the one that lacks
## the fewest; a tie on both between different templates is listed in
## `unmatched` (`SeveralFit`).
##
## A receiver is checked here rather than by `recordCompleteness`: its
## template is every source its O records call for (two O records of one
## receiver are one template), so no record number ever picks between them.
## The O records are the loaded ones, or, when none are loaded, the ones
## `receiverRelations` derives from the X records, both stored as
## source-domain records (the receiver as the record's source, the sources as
## its receivers). A receiver is its line and point: traces of it with index 0
## and index 1 are one receiver, and the index splits it only where the survey
## has the point at several indices.

import std/[atomics, bitops, math, options, os, sets, strutils, tables]
import parseSEG
import processSEG/qc/record
import processSEG/survey/relwalk
import filejobs, filesystem, jobs, missingreport, recordingkind, settings,
  relationcheck, reportside, session, threads

const
  NoSurvey* = "Import a survey with relation records (X records) first."
  Listing* = "Listing the folder."
  CannotList* = "The folder could not be listed."
  TraceChunk = 256 ## traces between cancel checks inside one gather

type
  MissingJobResult* = object
    ## What the scan did. `ok` false: `reason` is a sentence for the user,
    ## and the reports are empty. A cancel does not fill this. `shot` counts
    ## receiver stations of shot gathers, `receiver` source stations of
    ## receiver gathers; a side with no record has `stats.records` 0.
    ok*: bool
    shot*, receiver*: StationReport
    notChecked*: seq[tuple[path, why: string]]
      ## files left out on purpose (a continuous receiver recording)
    skipped*: seq[tuple[path, why: string]] ## relative to the folder, and why
    unmatched*: seq[tuple[path: string; record: int64; why: string]]
      ## A gather not checked: path relative to the folder, the header record
      ## number (−1 when it has none), and why.
    sides*: SideCounts
      ## the files of the scan that were shot gathers, receiver gathers, or could not be told
    taken*: string
      ## not empty when files whose kind cannot be told were taken for a side, and which
      ## (`reportside.takenNote`)
    mixed*: string
      ## not empty when the files are of both kinds: nothing is calculated, and this says
      ## so (`reportside.mixedNote`); the reports above are empty
    reason*: string

  ScanNote* = ref object
    ## Set by `folderScan`: the list stopped at the file limit.
    capped*: bool

  MissingSink* = ref object
    ## Filled when the job ends, except when it is cancelled. Read it after
    ## the job is no longer running.
    result*: MissingJobResult

proc missingSpec*(folder: string; paths: openArray[string]): JobSpec =
  ## The job that scans `paths` under `folder`: background, reading each
  ## path. The file list is the caller's (this job does not list a folder).
  let name = folder.extractFilename
  JobSpec(title: if name.len == 0: "Missing traces" else: "Missing traces in " & name,
    lane: jlBackground, reads: @paths)

func hasRelations(g: SurveyGeometry): bool =
  g.relationCount(rdSource) > 0 or g.relationCount(rdReceiver) > 0

proc relTo(folder, path: string): string =
  ## `path` relative to `folder`, or `path` when it is not under that folder.
  if folder.len == 0: return path
  var base = folder
  while base.len > 1 and base.endsWith(DirSep): base.setLen(base.len - 1)
  let prefix = base & DirSep
  if path.startsWith(prefix): return path[prefix.len .. ^1]
  if path == base: return path.extractFilename
  try: relativePath(path, base)
  except ValueError: path

proc highestRecord(g: SurveyGeometry): int64 =
  for r in g.records(rdSource):
    if r > result: result = r

proc receiverRelationsOf(g: SurveyGeometry; first: int64): seq[SpsRelation] =
  ## The receiver-domain relations as source-domain X records, numbered from
  ## `first`, so `recordCompleteness` can read them. Loaded O records are
  ## used as they are; otherwise they are derived from the X records.
  if g.relationCount(rdReceiver) > 0:
    var n = 0
    for rec in g.records(rdReceiver):
      let id = first + int64(n)
      inc n
      for run in g.relationRuns(rec, rdReceiver):
        if run.stations <= 0 or run.toChannel < run.fromChannel: continue
        var r = initSpsRelation()
        r.recordType = 'X'
        r.fieldRecord = id
        (r.srcLine, r.srcPoint, r.srcIndex) =
          (run.fixed.line, run.fixed.point, int(run.fixed.index))
        r.fromChannel = run.fromChannel
        r.toChannel = run.toChannel
        r.channelIncrement = max(int(run.channelStep), 1)
        (r.rcvLine, r.fromReceiver, r.toReceiver, r.rcvIndex) =
          (run.line, run.firstPoint, run.lastPoint, int(run.index))
        result.add r
  else:
    result = g.receiverRelations(first, 'X')

proc beat[C: JobContext | ItemContext](ctx: C; n: int) =
  ## A cancel check every `TraceChunk` traces of a gather, so a long file
  ## stops before its completeness is computed.
  var i = 0
  while i < n:
    ctx.checkCancelled()
    i += TraceChunk

proc openKeys[C: JobContext | ItemContext](path, cacheDir: string; ctx: C): Session =
  ## The file at `path`, keys only, closed by the caller. A cancel during
  ## the open is `SegCancelledError`. An unmapped read that fails (`fkIo`)
  ## raises here, before the file is opened. A current index cache in
  ## `cacheDir` is read instead of walking the headers; a walk saves one.
  ## A save that fails is ignored: the scan still has the keys.
  fs.unmappedFail(path)
  let index = indexCacheFile(cacheDir, path)
  let cached = index.len > 0 and fs.fileExists(index)
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try: fs.mappedRead(path)
    except CatchableError: discard
    ctx.progress(done, total)
  result = openSession(path, progress, if cached: index else: "")
  if index.len == 0 or result.file.kind == skUnknown or result.file.fromCache or
      result.file.demuxPath.len > 0: return
  try:
    fs.createDir(cacheDir)
    {.cast(gcsafe).}:
      result.file.saveIndex(index)
  except ValueError, IOError, OSError:
    discard

type
  IdSet* = object
    ## Numbers from 0 up, a bit each: a set takes one bit for each number up to the
    ## highest it holds, so a receiver's sources take an eighth of a byte each.
    bits: seq[uint64]

func incl*(s: var IdSet; id: int) =
  ## Adds `id` (0 or more), growing the set to it.
  let word = id shr 6
  if word >= s.bits.len: s.bits.setLen(word + 1)
  s.bits[word] = s.bits[word] or (1'u64 shl (id and 63))

func contains*(s: IdSet; id: int): bool =
  ## Whether `id` is in the set.
  let word = id shr 6
  word < s.bits.len and (s.bits[word] and (1'u64 shl (id and 63))) != 0

func byteSize*(s: IdSet): int =
  ## The bytes the set's bits take.
  s.bits.len * sizeof(uint64)

func meets(a, b: IdSet): bool =
  ## Whether `a` and `b` hold a number in common.
  for i in 0 ..< min(a.bits.len, b.bits.len):
    if (a.bits[i] and b.bits[i]) != 0: return true
  false

type
  ReceiverAt = object
    ## One receiver station (line and point) of the data: the source stations
    ## it holds traces of (by number, `ReceiverMerge.sourceIds`), a set for each
    ## receiver index its traces have, the first file it is in, and the record
    ## number it was first seen with, for Unmatched.
    station: StationKey ## line and point; index 0
    heard: seq[tuple[index: int16; sources: IdSet]]
    firstFile: int
    firstRecord: int64

  ReceiverFile = object
    ## A file of receiver data: its receivers (by number in `ReceiverMerge.list`),
    ## the first one, and all of them only when there are several.
    path: string ## relative to the folder
    first: int ## −1: none yet
    more: IdSet

  ReceiverMerge = object
    ## The receiver side of the data, by receiver station, over every file of a
    ## scan. A source station is kept as a number (`sourceIds`), so a receiver
    ## holds a bit for each source of the scan, whatever its number of traces and
    ## files, and a file a bit for each receiver only when it holds several.
    at: Table[StationKey, int]
    list: seq[ReceiverAt]
    sourceIds: Table[StationKey, int32]
    files: seq[ReceiverFile]

proc initReceiverMerge(): ReceiverMerge =
  ReceiverMerge(at: initTable[StationKey, int](), sourceIds: initTable[StationKey, int32]())

proc addFile(m: var ReceiverMerge; path: string): int =
  ## The number of a file of receiver data, or of an open one.
  result = m.files.len
  m.files.add ReceiverFile(path: path, first: -1)

type
  PartReceiver = object
    ## A receiver station of one file: the first record it was seen with, and for each
    ## receiver index its traces have, the source stations it recorded there (bits over
    ## `ReceiverPart.sources`).
    station: StationKey
    firstRecord: int64
    heard: seq[tuple[index: int16; sources: IdSet]]

  ReceiverPart = object
    ## What one file of receiver data adds to a `ReceiverMerge`: its receivers in the
    ## order its traces first name them, and the source stations they name, in that
    ## order. `hasFile`: a gather of the file was read, so it is a file of the merge
    ## even when none of its traces has a receiver station.
    hasFile: bool
    receivers: seq[PartReceiver]
    sources: seq[StationKey]

proc addPart(m: var ReceiverMerge; path: string; part: ReceiverPart) =
  ## Adds a file's receivers, each as the traces that name it would be added one by one.
  if not part.hasFile: return
  let file = m.addFile(path)
  var ids = newSeq[int32](part.sources.len)
  for i, source in part.sources:
    var id = m.sourceIds.getOrDefault(source, -1)
    if id < 0:
      id = int32(m.sourceIds.len)
      m.sourceIds[source] = id
    ids[i] = id
  for pr in part.receivers:
    var slot = m.at.getOrDefault(pr.station, -1)
    if slot < 0:
      slot = m.list.len
      m.at[pr.station] = slot
      m.list.add ReceiverAt(station: pr.station, firstFile: file, firstRecord: pr.firstRecord)
    template f: untyped = m.files[file]
    if f.first < 0: f.first = slot
    elif f.first != slot:
      if f.more.bits.len == 0: f.more.incl f.first
      f.more.incl slot
    for h in pr.heard:
      var at = -1
      for i, mine in m.list[slot].heard:
        if mine.index == h.index: at = i
      if at < 0:
        at = m.list[slot].heard.len
        m.list[slot].heard.add (index: h.index, sources: IdSet())
      for w, word in h.sources.bits:
        var bits = word
        while bits != 0:
          let b = countTrailingZeroBits(bits)
          m.list[slot].heard[at].sources.incl int(ids[w * 64 + b])
          bits = bits and (bits - 1)

func isHeard(m: ReceiverMerge; r: ReceiverAt; source: StationKey;
    indices: openArray[int16]): bool =
  ## Whether the receiver recorded `source` at one of the receiver `indices`.
  ## A source is its line and point, whatever index the template or the headers give.
  let id = m.sourceIds.getOrDefault(stationKey(source.line, source.point, 0), -1)
  if id >= 0:
    for h in r.heard:
      if h.index in indices and int(id) in h.sources: return true
  false

proc checkReceiver(tally: var StationTally; m: ReceiverMerge; r: ReceiverAt;
    records: openArray[ORecord]; indices: openArray[int16]) =
  ## Adds one check of receiver `r` to `tally`: the template is every source
  ## the `records` call for (several O records of one receiver are one
  ## template), present when the receiver recorded it at one of `indices`.
  let calls = calledSources(records)
  var c = RecordCompleteness(fieldRecord: float64(r.firstRecord), source: r.station,
    hasSource: true, recordMatch: rmSourceStation, traceMatch: tmStation, xpsRecord: -1)
  for s in calls:
    inc c.expected
    if m.isHeard(r, s, indices): inc c.present
    else: c.missingStations.add s
  c.missing = c.missingStations.len
  tally.addGather(calls, c)

proc checkReceivers(tally: var StationTally; m: ReceiverMerge; g: SurveyGeometry;
    ctx: JobContext; unmatched: var seq[tuple[path: string; record: int64; why: string]]):
    int =
  ## Checks each receiver of `m` once against its O records in `g`, and gives the
  ## number of files that hold a receiver checked. The receiver index
  ## splits a receiver into several checks only where the survey has its point at
  ## several indices. A receiver not checked is listed in `unmatched` under the
  ## first file it is in.
  var checked = IdSet()
  for slot, r in m.list:
    ctx.checkCancelled()
    var data: seq[int16] = @[]
    for h in r.heard: data.add h.index
    let records = g.oRecordsAt(r.station)
    var indices: seq[int16] = @[]
    for rec in records:
      if rec.index notin indices: indices.add rec.index
    let path = m.files[r.firstFile].path
    if r.heard.len == 0:
      unmatched.add (path: path, record: r.firstRecord, why: NoSourceStation)
    elif records.len == 0:
      unmatched.add (path: path, record: r.firstRecord, why: NoORecord)
    elif indices.len == 1:
      tally.checkReceiver(m, r, records, data)
      checked.incl slot
    else:
      for i in data:
        var chosen: seq[ORecord] = @[]
        for rec in records:
          if rec.index == i: chosen.add rec
        if i == 0:
          unmatched.add (path: path, record: r.firstRecord, why: UnknownIndex)
        elif chosen.len == 0:
          unmatched.add (path: path, record: r.firstRecord, why: NoORecord)
        else:
          tally.checkReceiver(m, r, chosen, [i])
          checked.incl slot
  for f in m.files:
    if (if f.more.bits.len > 0: f.more.meets(checked) else: f.first >= 0 and f.first in checked):
      inc result

proc fail(sink: MissingSink; why: string; skipped: seq[tuple[path, why: string]]) =
  if sink != nil:
    sink.result = MissingJobResult(ok: false, reason: why, skipped: skipped)
  raise newException(ValueError, why)

proc checkShot[C: JobContext | ItemContext](tally: var StationTally; g: SurveyGeometry;
    rows: TraceRows; path: string; ctx: C; unmatched: var seq[tuple[path: string; record: int64;
        why: string]]):
    bool =
  ## Checks one shot against its X record and adds it to `tally`, or lists it in
  ## `unmatched`; true when it was checked.
  let (checked, why) = g.shotCheck(rows, ctx)
  if why.len > 0:
    unmatched.add (path: path, record: fieldId(checked), why: why)
  else:
    tally.addGather(g.templateStations(checked.xpsRecord), checked)
  why.len == 0

type
  MissingShared = object
    ## What every item of a batch reads and never writes: the files of the batch (and
    ## their paths relative to the folder), the cache folder, the kinds the user set,
    ## and the rules for files whose kind cannot be told.
    paths, rels: seq[string]
    cacheDir: string
    forced: Table[string, RecordingKind]
    untold: UntoldKind
    folderRun: bool
    round: int ## 0: the files; 1: those whose kind cannot be told, as `takenAs`
    takenAs: ReportSide
    lead: int ## items before this one are padding, already counted: not read

  MissingItems = object
    ## The items' arguments. The survey is reached through a pointer the job keeps
    ## alive until the batch has returned, and is only read.
    shared: MissingShared
    relations: ptr SurveyGeometry
    mixed: Atomic[bool]
      ## set by the job once the files taken are of both sides: what the gathers of the
      ## files still to be taken would add is dropped, so they are not read

  MissingFile = object
    ## What reading one file came to: its side, and what its gathers add to the scan
    ## (the shot side's figures, the receiver side's stations, unmatched gathers). The
    ## job adds them in file order. `skip`: the file could not be read or has no keys;
    ## `gatherSkip`: a gather could not be checked (what came before it stays).
    classified: bool
    skip, gatherSkip: string
    side: ReportSide
    why: string
    untoldTaken: bool ## the folder's choice for a file that cannot be told was applied
    deferred: bool ## the file cannot be told: its gathers were left unread
    anyShot: bool
    shot: StationTally
    part: ReceiverPart
    unmatched: seq[tuple[path: string; record: int64; why: string]]

static:
  doAssert plainData(MissingShared) and plainData(MissingFile)

var gatherFiles*: Atomic[int]
  ## Files whose gathers were read since the program started. Read only by tests.

var missingBudget* = 256'i64 shl 20
  ## Most bytes of files in hand at once. The first file not yet taken runs whatever its
  ## size. Set only by tests.

proc notePart(part: var ReceiverPart; slotOf: var Table[StationKey, int];
    sourceOf: var Table[StationKey, int32]; k: TraceKeys) =
  ## Adds a trace that has a receiver station to `part`, as `add` does a merge.
  let station = stationKey(k.rcvLine, k.rcvPoint, 0)
  var slot = slotOf.getOrDefault(station, -1)
  if slot < 0:
    slot = part.receivers.len
    slotOf[station] = slot
    part.receivers.add PartReceiver(station: station, firstRecord: wholeRecord(k.record))
  if hasStation(k.srcLine, k.srcPoint):
    let source = stationKey(k.srcLine, k.srcPoint, 0)
    var id = sourceOf.getOrDefault(source, -1)
    if id < 0:
      id = int32(part.sources.len)
      part.sources.add source
      sourceOf[source] = id
    let index = max(k.rcvIndex, 0'i16)
    var at = -1
    for i, h in part.receivers[slot].heard:
      if h.index == index: at = i
    if at < 0:
      at = part.receivers[slot].heard.len
      part.receivers[slot].heard.add (index: index, sources: IdSet())
    part.receivers[slot].heard[at].sources.incl int(id)

proc readItem(it: ItemContext; a: ptr MissingItems; i: int): MissingFile {.nimcall, gcsafe.} =
  ## Opens file `i` for its keys, tells its side, and checks its gathers: the shot
  ## side's against the survey, the receiver side's gathered by receiver station. An
  ## error after the side is told is `gatherSkip`, with what was gathered before it; a
  ## cancel is raised. The file is closed before this returns.
  template sh: untyped = a.shared
  if i < sh.lead: return
  let path = sh.paths[i]
  let rel = sh.rels[i]
  result.shot = initTally(ssReceivers)
  var s: Session = nil
  try:
    {.cast(gcsafe).}:
      s = openKeys(path, sh.cacheDir, it)
      if s.file.kind == skUnknown: result.skip = "not a SEG-Y, SEG-D or SEG-2 file"
      elif s.file.index.keys.len == 0: result.skip = "has no trace keys"
      else:
        var fileSide: FileSide
        if sh.round == 1:
          fileSide = (sh.takenAs, "")
        else:
          let isForced = forcedPath(path) in sh.forced
          let kind = if isForced: some(sh.forced[forcedPath(path)])
            else: autoKindOf(s, path, proc () {.gcsafe.} = it.checkCancelled())
          var whole = initStations()
          for k in s.file.index.keys: whole.note(k)
          fileSide = reportSide(kind, isForced, whole)
          if fileSide.side == rsCannotTell and sh.untold != ukNotChecked:
            # the user's choice for the files that cannot be told
            let chosen = if sh.untold == ukShot: rsShot else: rsReceiver
            fileSide = (chosen, "")
            result.untoldTaken = true
        (result.classified, result.side, result.why) = (true, fileSide.side, fileSide.why)
        if sh.round == 0 and fileSide.side == rsCannotTell and sh.folderRun:
          result.deferred = true
        elif fileSide.side in {rsShot, rsReceiver} and not a.mixed.load(moAcquire):
          # (a folder of both sides is not calculated; the job drops what a file adds
          # once both are seen)
          discard gatherFiles.fetchAdd(1, moRelaxed)
          var slotOf = initTable[StationKey, int]()
          var sourceOf = initTable[StationKey, int32]()
          for g in s.gathers:
            if g.traces.len == 0: continue
            beat(it, g.traces.len)
            if fileSide.side == rsShot:
              if result.shot.checkShot(a.relations[], s.file.rowsOf(g.traces), rel, it,
                  result.unmatched):
                result.anyShot = true
            else:
              result.part.hasFile = true
              var stations = 0
              for t in g.traces:
                let k = s.file.index.keys[t]
                if k.status != tsAuxiliary and hasStation(k.rcvLine, k.rcvPoint):
                  result.part.notePart(slotOf, sourceOf, k)
                  inc stations
              if stations == 0:
                let k = s.file.index.keys[g.traces.a]
                result.unmatched.add (path: rel, record: wholeRecord(k.record),
                  why: NoReceiverStation)
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except JobCancelledError:
    raise
  except CatchableError as e:
    let why = if e.msg.len > 0: e.msg else: $e.name
    if result.classified: result.gatherSkip = why else: result.skip = why
  finally:
    s = nil
    clearCycleRoots()

proc scanMissing*(folder: string; paths: seq[string]; relations: ref SurveyGeometry;
    target: MissingSink; cacheDir = ""; forced = initTable[string, RecordingKind]();
    receivers: ref SurveyGeometry = nil; receiversDerived = false;
    untold = ukNotChecked; folderRun = false): JobWork =
  ## The work of a job that scans `paths` (relative to `folder` in messages)
  ## against `relations` and fills `target` (`missingSpec` is the spec to
  ## submit it with). Worker-only. A cancel raises `JobCancelledError` and
  ## leaves `target` as it was. `cacheDir` is the index cache folder: a current
  ## cache is read instead of walking the file, and a walk saves one.
  ## "" leaves the cache alone. `forced` holds the kind the user set for a file in the
  ## Files window, by the path normalised (`normalizedPath`): it replaces the kind told
  ## from the file. `receivers` holds the O records the receiver gathers are checked
  ## against (a loaded O file's, or those derived from the X records, `receiversDerived`);
  ## nil: the O records of `relations`, else derived here from its X records. `forced` is
  ## keyed by `forcedPath` (the canonical path). Files whose kind cannot be told are taken
  ## for what `untold` says; with "not checked" and `folderRun`, for the side of the files
  ## that are told when all of those are of one (`takenNote` says so), else left out.
  ## Up to the item pool's threads of files are open at once, one file's keys each; their
  ## results are added to the scan in file order, so the report is the same on any number.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if relations == nil or not relations[].hasRelations:
      fail(target, NoSurvey, @[])
    var skipped: seq[tuple[path, why: string]] = @[]
    var notChecked: seq[tuple[path, why: string]] = @[]
    var unmatched: seq[tuple[path: string; record: int64; why: string]] = @[]
    let oSource = if receivers != nil and receivers[].relationCount(rdReceiver) > 0: receivers
      else: relations
    let derived = receiversDerived or oSource[].relationCount(rdReceiver) == 0
    var shot = initTally(ssReceivers)
    var recv = initTally(ssSources, derived)
    var merge = initReceiverMerge()
    var counts: SideCounts
    var takenAs = rsCannotTell
    var deferred: seq[tuple[path, why: string]] = @[]
    var taken = 0
    proc readFiles(list: seq[string]; round: int; lead = 0) {.gcsafe.} =
      ## Reads each of `list` (a batch of items) and adds it to the scan, in order. The
      ## `lead` items before it are done already (the bar goes on from there).
      var args = MissingItems(relations: unsafeAddr relations[], shared: MissingShared(
        paths: newSeq[string](lead) & list, cacheDir: cacheDir, forced: forced, untold: untold,
        folderRun: folderRun, round: round, takenAs: takenAs, lead: lead))
      var sizes = newSeq[int64](lead + list.len)
      args.shared.rels = newSeq[string](lead)
      for i, path in list:
        args.shared.rels.add relTo(folder, path)
        try:
          sizes[lead + i] = max(0'i64, fs.getFileSize(path))
        except OSError:
          discard # the item says why it cannot be read
      proc take(i: int; outcome: sink ItemOutcome[MissingFile]) {.closure, gcsafe.} =
        if i < lead: return
        let rel = args.shared.rels[i]
        if round == 0: ctx.setPhase "reading " & list[i].extractFilename
        ctx.checkCancelled()
        if not outcome.ok:
          if outcome.failure.cancelled: raise newException(JobCancelledError, "cancelled")
          let e = outcome.failure
          skipped.add (path: rel, why: if e.msg.len > 0: e.msg else: e.name)
          return
        template r: untyped = outcome.value
        if r.skip.len > 0: skipped.add (path: rel, why: r.skip)
        if not r.classified: return
        if r.untoldTaken:
          takenAs = if untold == ukShot: rsShot else: rsReceiver
          inc taken
        if r.deferred:
          # taken for the side of the files that are told, when all are of one
          deferred.add (path: list[i - lead], why: r.why)
          return
        counts.note r.side
        if counts.isMixed: args.mixed.store(true, moRelease)
        case r.side
        of rsNotGather, rsCannotTell:
          notChecked.add (path: rel, why: r.why)
        of rsShot, rsReceiver:
          # (a mix is not calculated: once both sides are seen, only the files are counted)
          if counts.isMixed: return
          if r.gatherSkip.len > 0: skipped.add (path: rel, why: r.gatherSkip)
          unmatched.add r.unmatched
          if r.side == rsShot:
            shot.merge r.shot
            if r.anyShot: shot.noteFile()
          else:
            merge.addPart(rel, r.part)
      let total = lead + list.len
      ctx.setPhase "scanning " & $list.len & (if list.len == 1: " file" else: " files")
      if lead > 0: discard ctx.progress(int64(lead) * 1000, int64(total) * 1000)
      let ran = ctx.parallelItems(total, addr args, readItem, take,
        ItemOptions(cost: sizes, budget: missingBudget))
      if ran.taken < total: raise newException(JobCancelledError, "cancelled")
    try:
      var list: seq[string] = @[]
      var seen = initHashSet[string]()
      for path in paths:
        if not seen.containsOrIncl(path.normalizedPath): list.add path
      let uniqueCount = list.len
      if list.len > 0: readFiles(list, 0)
      if deferred.len > 0:
        # the files that cannot be told: the side of those that are, when all are of one
        let one = unanimousSide(counts)
        if one == rsCannotTell:
          counts.untold += deferred.len
          for d in deferred:
            notChecked.add (path: relTo(folder, d.path), why: d.why)
        else:
          takenAs = one
          taken = deferred.len
          list = @[]
          for d in deferred: list.add d.path
          deferred.setLen 0
          readFiles(list, 1, uniqueCount - list.len)
      if merge.list.len > 0 and not counts.isMixed:
        ctx.setPhase "checking the receivers"
        let rels = oSource[].receiverRelationsOf(oSource[].highestRecord + 1)
        var receiver = initSurveyGeometry()
        receiver.addSps(SpsFile(relations: rels), rdSource)
        for _ in 1 .. checkReceivers(recv, merge, receiver, ctx, unmatched): recv.noteFile()
      ctx.setPhase "reporting"
      ctx.checkCancelled()
      clearCycleRoots()
      if target != nil:
        target.result = MissingJobResult(ok: true, sides: counts, skipped: skipped,
          notChecked: notChecked, taken: takenNote(taken, takenAs, untold != ukNotChecked))
        if counts.isMixed:
          target.result.mixed = mixedNote(counts)
        else:
          target.result.shot = shot.report
          target.result.receiver = recv.report
          target.result.unmatched = unmatched
    except JobCancelledError:
      raise
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except CatchableError as e:
      fail(target, if e.msg.len > 0: e.msg else: $e.name, skipped)

proc folderScan*(folder: string; subfolders: bool; cacheDir: string;
    relations: ref SurveyGeometry; sink: MissingSink; note: ScanNote = nil;
    forced = initTable[string, RecordingKind](); receivers: ref SurveyGeometry = nil;
    receiversDerived = false; untold = ukNotChecked): JobWork =
  ## The work of a job that lists the seismic files of `folder`, its
  ## subfolders only when `subfolders`, and scans them as `scanMissing` does.
  ## `note.capped` says the list stopped at the file limit.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase Listing
    var capped = false
    var paths: seq[string] = @[]
    try:
      paths = listedNames(@[folder], subfolders, capped,
        proc (found: int): bool {.gcsafe, raises: [].} = ctx.progress(int64(found), 0))
    except OSError:
      raise newException(ValueError, CannotList)
    if note != nil: note.capped = capped
    ctx.checkCancelled()
    let scan = scanMissing(folder, paths, relations, sink, cacheDir, forced, receivers,
      receiversDerived, untold, true)
    scan(ctx)
