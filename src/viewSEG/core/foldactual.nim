## The fold of the traces recorded in the seismic files the Files window lists, counted over
## the bins of a grid that is already laid (`surveyGrid`, as `core/foldjobs` lays it for the
## pre-plot), for the map's "Actual fold" and "Fold difference" layers.
##
## `actualInputs` takes what the job needs from the app on the UI thread: each listed seismic
## file's path and size, the traces its edits kill, the join options (the project's, else the
## session's) and the station moves. The survey that places the traces is the one the grid is
## laid from: the survey files loaded on the map, in a project and outside one (the job builds
## it, `foldjobs`); when a project's stored survey is another, the totals say the map's was
## used (`ActualInputs.otherSurvey`). `countActual` is the job's part: it opens each file for
## its keys (the index cache is read when it is current), joins that survey and the moves to
## them in memory only (`joinOwnFile`: a file is never written), and counts its live traces
## that are not killed into the bin their midpoint falls in. Each trace goes the way the
## library's `addFold` takes it: a trace that is not live (dead, auxiliary) is left out, then
## one the user killed, then one with no midpoint and no source and receiver coordinates,
## then one outside the grid; the rest is counted once in its bin.
##
## The files are read several at a time on the item pool. An item's result is plain data (its
## own tallies and the bins it fills, as a sparse list in bin order); the job's thread adds
## them into the one dense count in file order, so the counts are the same on any number of
## threads. The survey and the inputs are reached read-only through pointers the job keeps
## alive until every item has returned; no `ref` is shared between threads. A file listed twice
## (the same file reached through a linked folder) is counted once; copies of one recording
## (a converted copy beside its original) are two files, and counted twice. A file that cannot
## be read or has no keys is skipped with the reason and the count goes on; a file that gives
## no positions and that the survey does not place is counted as such (`unplaced`), not
## dropped silently. A cancel stops the count and leaves nothing.

import std/[algorithm, hashes, math, os, sets, times]
import arraymancer/tensor
import parseSEG
import processSEG/qc/fold
import processSEG/stack/binning
import edits, filejobs, filekinds, filelist, filesystem, foldsplit, itempool, jobs, join, project,
  session, state, stationmoves, survey, surveyjobs, threads

export foldsplit

const
  ActualKinds* = {fkSegy, fkSegd, fkSeg2}
    ## the kinds of file whose traces are counted (a signature file is decoded elsewhere)
  NoSeismicFiles* = "No seismic files are listed in the Files window."
  Listing* = "The Files window is still listing the folder."
  KeysChunk = 65_536 ## traces whose keys are read at a time
  CancelEvery = 4096 ## traces between cancel checks

var actualBudget* = 256'i64 shl 20
  ## Most bytes of files in hand at once. The first file not yet taken runs whatever its size.
  ## Set only by tests.

type
  ActualFile* = object
    path*: string
    size*: int64
    kills*: seq[int] ## the file's killed traces, ascending
    id*: string
      ## names the file as listed and edited: its path, size, modification time (as finely as
      ## the file system gives it) and kills; a count keeps its part by it (`core/foldjobs`)

  ActualInputs* = object
    ## What the count needs, copied on the UI thread.
    key*: string          ## names the files (sizes, times, edits), the options and the moves
    join*: string         ## names the options and the moves: what each file's part needs as well
    files*: seq[ActualFile]
    options*: JoinOptions ## how the survey is joined to the files' keys
    moves*: StationMoves
    otherSurvey*: bool
      ## the project's stored survey is not the one on the map (the map's places the traces)
    cacheDir*: string

  ActualPart* = object
    ## What reading one file came to. `skip`: the file could not be read, or has no keys.
    skip*: string
    traces*, notLive*, killed*, noCoordinates*, outside*, binned*: int
    noSource*: int             ## of `noCoordinates`: a receiver position and no source
    unplaced*: bool
      ## the file has live traces and none has a position: the survey did not place them
    bins*, counts*: seq[int32] ## the bins the file fills, ascending, and its traces in each
    noClass*, noSector*: int
      ## with a restriction: of `binned`, the traces in no offset class and in no azimuth sector
      ## (`FoldSplit`; each counts only when it is defined)
    classStarts*: seq[int32]
      ## with a restriction: `classes + 1` places in `classBins`, where each class's run starts
    classBins*, classCounts*: seq[int32]
      ## with a restriction: the bins each class or sector fills, ascending in each run, and
      ## its traces in each

  ActualTally* = object
    ## What the count came to over all the files.
    files*: int              ## files read
    traces*, notLive*, killed*, noCoordinates*, outside*, binned*: int
    noSource*: int           ## of `noCoordinates`: a receiver position and no source
    noClass*, noSector*: int ## with a restriction: of `binned`, the traces in none (`ActualPart`)
    unplaced*: int           ## files read that gave no position
    duplicates*: int         ## files listed twice (one reached through a link), counted once
    skipped*: seq[tuple[path, why: string]]

  ActualItems = object
    inp: ptr ActualInputs
    survey: ptr SurveyGeometry
    grid: Binning
    split: FoldSplit ## read only by the items
    order: seq[int]  ## the files read, by item

static:
  doAssert plainData(ActualPart)

func finite(x: float64): bool {.inline.} = x.classify notin {fcNan, fcInf, fcNegInf}

func binOfTrace(grid: Binning; k: TraceKeys): int {.inline.} =
  ## The bin of trace `k`, -1 when it falls in none, -2 when it has no midpoint and no
  ## source and receiver coordinates (what the library's `addFold` decides), -3 when of those
  ## it has the receiver's alone.
  var (x, y) = (k.cmpX, k.cmpY)
  if not (finite(x) and finite(y)):
    let receiver = finite(k.rcvX) and finite(k.rcvY)
    if not (finite(k.srcX) and finite(k.srcY) and receiver):
      return if receiver and not (finite(k.srcX) or finite(k.srcY)): -3 else: -2
    (x, y) = ((k.srcX + k.rcvX) * 0.5, (k.srcY + k.rcvY) * 0.5)
  grid.binAt(x, y)

proc fillPart*(part: var ActualPart; bins: var seq[int32]; classKeys: var seq[int64];
    classes: int) =
  ## Sets the sparse lists of `part` from the bin of each counted trace (`bins`) and, with a
  ## restriction of `classes` classes, from `classKeys` (`class shl 32 or bin` of each trace
  ## that is in one). Both are sorted here.
  bins.sort()
  for b in bins:
    if part.bins.len > 0 and part.bins[^1] == b: inc part.counts[^1]
    else:
      part.bins.add b
      part.counts.add 1
  if classes > 0:
    classKeys.sort()
    part.classStarts = newSeq[int32](classes + 1)
    var last = -1'i64
    for key in classKeys:
      let (cls, bin) = (int(key shr 32), int32(key and 0xFFFF_FFFF'i64))
      if key == last: inc part.classCounts[^1]
      else:
        part.classBins.add bin
        part.classCounts.add 1
        inc part.classStarts[cls + 1]
        last = key
    for c in 0 ..< classes: part.classStarts[c + 1] += part.classStarts[c]

proc openKeys(path, cacheDir: string; it: ItemContext): Session =
  ## The file at `path`, keys only, closed by the caller. A current index cache in `cacheDir`
  ## is read instead of walking the headers; a walk saves one (a failed save is ignored).
  fs.unmappedFail(path)
  let index = indexCacheFile(cacheDir, path)
  let cached = index.len > 0 and fs.fileExists(index)
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try: fs.mappedRead(path)
    except CatchableError: discard
    it.progress(done, total)
  result = openSession(path, progress, if cached: index else: "")
  if index.len == 0 or result.file.kind == skUnknown or result.file.fromCache or
      result.file.demuxPath.len > 0: return
  try:
    fs.createDir(cacheDir)
    {.cast(gcsafe).}:
      result.file.saveIndex(index)
  except ValueError, IOError, OSError:
    discard

proc readActual(it: ItemContext; a: ptr ActualItems; k: int): ActualPart {.nimcall, gcsafe.} =
  ## Opens the file of item `k`, joins the survey and the moves to its keys in memory, and counts
  ## its traces into the grid's bins. The file is closed before this returns; a cancel is raised.
  template f: untyped = a.inp.files[a.order[k]]
  var s: Session = nil
  try:
    {.cast(gcsafe).}:
      s = openKeys(f.path, a.inp.cacheDir, it)
      if s.file.kind == skUnknown: result.skip = "not a SEG-Y, SEG-D or SEG-2 file"
      elif s.file.index.keys.len == 0: result.skip = "has no trace keys"
      else:
        let file = s.filePtr
        let progress = proc (done, total: int): bool {.gcsafe, raises: [].} = not it.cancelled
        discard joinOwnFile(file, a.survey, a.inp.options, a.inp.moves, false, progress)
        let n = file[].len
        var keys = newSeq[TraceKeys](min(n, KeysChunk))
        var bins = newSeqOfCap[int32](n)
        var classKeys: seq[int64] = @[]
        template split: untyped = a.split
        var (t, nextKill) = (0, 0)
        while t < n:
          let m = min(keys.len, n - t)
          file[].traceKeysInto(t ..< t + m, keys.toOpenArray(0, m - 1))
          for j in 0 ..< m:
            let at = t + j
            if at mod CancelEvery == 0: it.checkCancelled()
            while nextKill < f.kills.len and f.kills[nextKill] < at: inc nextKill
            if keys[j].status notin {tsLive, tsUnknown}: inc result.notLive
            elif nextKill < f.kills.len and f.kills[nextKill] == at: inc result.killed
            else:
              let bin = a.grid.binOfTrace(keys[j])
              if bin <= -2:
                inc result.noCoordinates
                if bin == -3: inc result.noSource
              elif bin < 0: inc result.outside
              else:
                inc result.binned
                bins.add int32(bin)
                if split.offsetClasses > 0:
                  let cls = split.offsetClassOf(keys[j])
                  if cls >= 0: classKeys.add (int64(cls) shl 32) or int64(bin)
                  else: inc result.noClass
                if split.sectors >= 2:
                  let cls = split.sectorOf(keys[j])
                  if cls >= 0:
                    classKeys.add (int64(split.offsetClasses + cls) shl 32) or int64(bin)
                  else: inc result.noSector
          t += m
        result.traces = n
        result.unplaced = result.noCoordinates > 0 and result.binned + result.outside == 0
        result.fillPart(bins, classKeys, split.classes)
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except JobCancelledError:
    raise
  except CatchableError as e:
    result = ActualPart(skip: if e.msg.len > 0: e.msg else: $e.name)
  finally:
    s = nil
    clearCycleRoots()

proc add(tally: var ActualTally; raw, all: ptr UncheckedArray[int32]; pick: int; path: string;
    r: ActualPart) =
  ## Adds what file `path` came to: into `raw` the bins of class `pick` (-1: of all the file's
  ## traces), and, when `all` is not nil, into `all` those of all of them.
  if r.skip.len > 0:
    tally.skipped.add (path: path, why: r.skip)
    return
  inc tally.files
  if r.unplaced: inc tally.unplaced
  tally.traces += r.traces
  tally.notLive += r.notLive
  tally.killed += r.killed
  tally.noCoordinates += r.noCoordinates
  tally.noSource += r.noSource
  tally.outside += r.outside
  tally.binned += r.binned
  tally.noClass += r.noClass
  tally.noSector += r.noSector
  if pick < 0:
    for k, bin in r.bins: raw[bin] += r.counts[k]
  else:
    for k, bin in r.bins: all[bin] += r.counts[k]
    if r.classStarts.len > pick + 1:
      for k in r.classStarts[pick] ..< r.classStarts[pick + 1]:
        raw[r.classBins[k]] += r.classCounts[k]

proc countActual*(ctx: JobContext; inp: ptr ActualInputs; known: openArray[ptr ActualPart];
    survey: ptr SurveyGeometry; grid: Binning; split: FoldSplit; actual: var FoldMap;
    totals: var seq[int32]; fresh: var seq[ActualPart]): ActualTally =
  ## Counts the traces of `inp`'s files into `actual` (a fold map over `grid`, empty), adding
  ## each file's bins in file order; `survey` (nil: none) places traces by their stations.
  ## With a restriction (`split.active`) each file's part also holds its traces per class or
  ## sector; with one drawn (`split.drawn`) `actual` gets only that class's traces and `totals`
  ## (made here, one per bin) all of them.
  ## File `i` is not read again when `known[i]` is not nil (`known` may be shorter): that is
  ## its part as an earlier count read it, with the same inputs and grid, read through its
  ## address (the caller keeps it alive and unchanged until the work is back). `fresh` gets,
  ## for each file, the part read here (an empty part for one taken from `known`).
  ## Worker-only. A cancel raises `JobCancelledError`; `actual` is then partly filled, and the
  ## caller drops it.
  let total = inp.files.len
  var args = ActualItems(inp: inp, survey: survey, grid: grid, split: split)
  # a file reached twice (a linked folder among the subfolders) is counted once
  ctx.setPhase "looking for files listed twice"
  var twice = newSeq[bool](total)
  var seen = initHashSet[string]()
  for i in 0 ..< total:
    if i mod 256 == 0: ctx.checkCancelled()
    var real = inp.files[i].path
    try: real = fs.expandFilename(real)
    except OSError: discard
    if seen.containsOrIncl(real): twice[i] = true
  for i in 0 ..< total:
    if not twice[i] and (i >= known.len or known[i].isNil): args.order.add i
  let reads = args.order.len
  ctx.setPhase "counting " & $reads & (if reads == 1: " file" else: " files")
  var sizes = newSeq[int64](reads)
  for k, i in args.order: sizes[k] = max(0'i64, inp.files[i].size)
  var got = newSeq[ActualPart](total)
  # a file listed twice is never read: its part says so, so no count keeps it as a part
  for i in 0 ..< total:
    if twice[i]: got[i] = ActualPart(skip: "listed twice")
  proc take(k: int; outcome: sink ItemOutcome[ActualPart]) {.closure, gcsafe.} =
    ctx.checkCancelled()
    let i = args.order[k]
    ctx.setPhase "counting " & inp.files[i].path.extractFilename
    if outcome.ok: got[i] = move outcome.value
    elif outcome.failure.cancelled: raise newException(JobCancelledError, "cancelled")
    else:
      let e = outcome.failure
      got[i] = ActualPart(skip: if e.msg.len > 0: e.msg else: e.name)
  let ran = ctx.parallelItems(reads, addr args, readActual, take,
    ItemOptions(cost: sizes, budget: actualBudget))
  if ran.taken < reads: raise newException(JobCancelledError, "cancelled")
  var cells = actual.fold # the map's own counts (a tensor shares its storage)
  let raw = cast[ptr UncheckedArray[int32]](cells.unsafe_raw_offset(aligned = false))
  var all: ptr UncheckedArray[int32] = nil
  let pick = if split.drawn: split.slot else: -1
  if pick >= 0:
    totals = newSeq[int32](grid.len)
    all = cast[ptr UncheckedArray[int32]](addr totals[0])
  for i in 0 ..< total:
    if twice[i]: inc result.duplicates
    elif i < known.len and not known[i].isNil:
      result.add(raw, all, pick, inp.files[i].path, known[i][])
    else: result.add(raw, all, pick, inp.files[i].path, got[i])
  fresh = move got

# ---------------------------------------------------------------- the inputs --

func seismicEntries(st: AppState): seq[int] =
  ## The indices of the Files window's seismic entries that can be counted. By index: a `for`
  ## over the entries of `fileList` (a `lent` call) copies them all first.
  for i in 0 ..< st.fileList.entries.len:
    if st.fileList.entries[i].kind in ActualKinds: result.add i

func anySeismic(st: AppState): bool =
  ## Whether the Files window lists a seismic file that can be counted (the first one, in
  ## a folder of recordings, decides it).
  for i in 0 ..< st.fileList.entries.len:
    if st.fileList.entries[i].kind in ActualKinds: return true

func actualReason*(st: AppState): string =
  ## Why the recorded fold cannot be counted now; "" when it can.
  if st.fileList.scanning: Listing
  elif not st.anySeismic: NoSeismicFiles
  else: ""

func movesKey(moves: StationMoves): string =
  for i in 0 ..< moves.len:
    let m = moves[i]
    result.add $m.station.line & "," & $m.station.point & "," & $m.station.index & "," &
      $m.x & "," & $m.y & "," & $m.elev & "," & $m.fromTime & ";"

func joinOptions(st: AppState): JoinOptions =
  ## The project's join options, else the session's.
  if st.inProject: st.project.doc.options else: st.settings.join

proc otherSurvey(st: AppState): bool =
  ## Whether the project has a stored survey and a survey file on the map is neither one of
  ## its copies nor one of their originals.
  if not (st.inProject and st.project.doc.hasSurvey): return false
  var own: HashSet[string]
  for c in st.project.doc.survey:
    own.incl normalizedPath(st.project.dir.partOf(c.copy))
    if c.original.absolute.len > 0: own.incl normalizedPath(c.original.absolute)
  for i in 0 ..< st.survey.layers.len:
    template l: untyped = st.survey.layers[i]
    if l.origin == loSurveyFile and normalizedPath(l.path) notin own: return true

proc actualStamp*(st: AppState): int =
  ## A number that changes when anything `actualInputs` reads changes; cheap (revisions only,
  ## whatever the number of files), so the window asks each frame and builds the inputs only
  ## when it moved: the file list's entries, every file's edits, the project (its options and
  ## the station moves), the session's join options outside one, and the survey.
  var h: Hash = 0
  h = h !& hash(st.fileList.entriesRev) !& hash(st.fileList.gen) !& hash(st.fileList.recursive) !&
    hash(st.fileList.scanning) !& hash(st.fileList.entries.len) !& hash(st.editsRevision) !&
    hash(st.survey.revision) !& hash(st.inProject) !& hash(st.project.revision) !&
    hash(st.vendorGen)
  if not st.inProject: h = h !& hash($st.settings.join)
  !$h

func killsId*(kills: openArray[int]): string =
  ## Names a sorted list of kills in a file's `id`: the indices themselves when there are at most
  ## 64 (two lists never share a name), else their count and a hash.
  if kills.len <= 64:
    result = "k"
    for k in kills: result.add "," & $k
  else:
    result = $kills.len & "," & $hash(@kills)

proc actualInputs*(st: AppState): ref ActualInputs =
  ## What the count needs from `st`: every seismic file of the Files window's list (its
  ## subfolders' files when it lists them), the edits' kills, the join options and the station
  ## moves. The key names them all; the survey is named by the fold's own key.
  result = new ActualInputs
  result.cacheDir = st.indexCache
  result.moves = st.project.doc.stationMoves
  result.options = st.joinOptions
  result.otherSurvey = st.otherSurvey
  var key = "files:" & $st.fileList.recursive & ";"
  for i in st.seismicEntries:
    template e: untyped = st.fileList.entries[i]
    var f = ActualFile(path: e.path, size: e.size)
    let edits = st.editsAt(e.path)
    f.kills = edits.shown.lists[teKilled]
    f.kills.sort()
    f.id = e.path & "|" & $e.size & "|" & $e.modified.toUnix & "." & $e.modified.nanosecond &
      "|" & killsId(f.kills)
    key.add f.id & ";"
    result.files.add f
  result.join = "options:" & $result.options & ";moves:" & result.moves.movesKey &
    ";vendors:" & $st.vendorGen
  key.add result.join & ";other:" & $result.otherSurvey
  result.key = key
