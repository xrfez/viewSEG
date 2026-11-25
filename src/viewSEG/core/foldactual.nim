## The fold of the traces recorded in the seismic files the Files window lists, counted over
## the bins of a grid that is already laid (`surveyGrid`, as `core/foldjobs` lays it for the
## pre-plot), for the map's "Actual fold" and "Fold difference" layers.
##
## `actualInputs` takes what the job needs from the app on the UI thread: each listed seismic
## file's path and size, the traces its edits kill, the project's survey (a pointer: the
## caller keeps the survey alive until the job has ended, as `AppState.holdSurvey` does), its
## join options and station moves. `countActual` is the job's part: it opens each file for
## its keys (the index cache is read when it is current), gives it the project's join and
## moves in memory only (`joinOwnFile`: a file is never written), and counts its live traces
## that are not killed into the bin their midpoint falls in. Each trace goes the way the
## library's `addFold` takes it: a trace that is not live (dead, auxiliary) is left out, then
## one the user killed, then one with no midpoint and no source and receiver coordinates,
## then one outside the grid; the rest is counted once in its bin.
##
## The files are read several at a time on the item pool. An item's result is plain data (its
## own tallies and the bins it fills, as a sparse list in bin order); the job's thread adds
## them into the one dense count in file order, so the counts are the same on any number of
## threads. The survey and the edits are reached read-only through the pointer the job keeps
## alive until every item has returned; no `ref` is shared between threads. A file that cannot
## be read or has no keys is skipped with the reason and the count goes on; a file that gives
## no positions and that the survey does not place is counted as such (`unplaced`), not
## dropped silently. A cancel stops the count and leaves nothing.

import std/[algorithm, hashes, math, os, times]
import arraymancer/tensor
import parseSEG
import processSEG/qc/fold
import processSEG/stack/binning
import edits, filejobs, filekinds, filelist, filesystem, itempool, jobs, join, session, state,
  stationmoves, surveyjobs, threads

const
  ActualKinds* = {fkSegy, fkSegd, fkSeg2}
    ## the kinds of file whose traces are counted (a signature file is decoded elsewhere)
  NoSeismicFiles* = "No seismic files are listed in the Files window."
  Listing* = "The Files window is still listing the folder."
  SurveyLoading* = "The project's survey is still loading."
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

  ActualInputs* = object
    ## What the count needs, copied on the UI thread. `survey` is read, never changed: the
    ## caller keeps it alive until the job's work has returned.
    key*: string ## names the files, their sizes and times, the edits and the moves
    files*: seq[ActualFile]
    survey*: ptr SurveyGeometry
    options*: JoinOptions
    moves*: StationMoves
    tableOnly*: bool
    cacheDir*: string

  ActualPart* = object
    ## What reading one file came to. `skip`: the file could not be read, or has no keys.
    skip*: string
    traces*, notLive*, killed*, noCoordinates*, outside*, binned*: int
    unplaced*: bool
      ## the file has live traces and none has a position: the survey did not place them
    bins*, counts*: seq[int32] ## the bins the file fills, ascending, and its traces in each

  ActualTally* = object
    ## What the count came to over all the files.
    files*: int    ## files read
    traces*, notLive*, killed*, noCoordinates*, outside*, binned*: int
    unplaced*: int ## files read that gave no position
    skipped*: seq[tuple[path, why: string]]

  ActualItems = object
    inp: ptr ActualInputs
    grid: Binning

static:
  doAssert plainData(ActualPart)

func finite(x: float64): bool {.inline.} = x.classify notin {fcNan, fcInf, fcNegInf}

func binOfTrace(grid: Binning; k: TraceKeys): int {.inline.} =
  ## The bin of trace `k`, -1 when it falls in none, -2 when it has no midpoint and no
  ## source and receiver coordinates (what the library's `addFold` decides).
  var (x, y) = (k.cmpX, k.cmpY)
  if not (finite(x) and finite(y)):
    if not (finite(k.srcX) and finite(k.srcY) and finite(k.rcvX) and finite(k.rcvY)):
      return -2
    (x, y) = ((k.srcX + k.rcvX) * 0.5, (k.srcY + k.rcvY) * 0.5)
  grid.binAt(x, y)

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

proc readActual(it: ItemContext; a: ptr ActualItems; i: int): ActualPart {.nimcall, gcsafe.} =
  ## Opens file `i`, joins the project's survey and moves to its keys in memory, and counts
  ## its traces into the grid's bins. The file is closed before this returns; a cancel is raised.
  template f: untyped = a.inp.files[i]
  var s: Session = nil
  try:
    {.cast(gcsafe).}:
      s = openKeys(f.path, a.inp.cacheDir, it)
      if s.file.kind == skUnknown: result.skip = "not a SEG-Y, SEG-D or SEG-2 file"
      elif s.file.index.keys.len == 0: result.skip = "has no trace keys"
      else:
        let file = s.filePtr
        let progress = proc (done, total: int): bool {.gcsafe, raises: [].} = not it.cancelled
        discard joinOwnFile(file, a.inp.survey, a.inp.options, a.inp.moves, a.inp.tableOnly,
          progress)
        let n = file[].len
        var keys = newSeq[TraceKeys](min(n, KeysChunk))
        var bins = newSeqOfCap[int32](n)
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
              if bin == -2: inc result.noCoordinates
              elif bin < 0: inc result.outside
              else:
                inc result.binned
                bins.add int32(bin)
          t += m
        result.traces = n
        result.unplaced = result.noCoordinates > 0 and result.binned + result.outside == 0
        bins.sort()
        for b in bins:
          if result.bins.len > 0 and result.bins[^1] == b: inc result.counts[^1]
          else:
            result.bins.add b
            result.counts.add 1
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except JobCancelledError:
    raise
  except CatchableError as e:
    result = ActualPart(skip: if e.msg.len > 0: e.msg else: $e.name)
  finally:
    s = nil
    clearCycleRoots()

proc countActual*(ctx: JobContext; inp: ptr ActualInputs; grid: Binning;
    actual: var FoldMap): ActualTally =
  ## Counts the traces of `inp`'s files into `actual` (a fold map over `grid`, empty), adding
  ## each file's bins in file order. Worker-only. A cancel raises `JobCancelledError`; `actual`
  ## is then partly filled, and the caller drops it.
  let total = inp.files.len
  ctx.setPhase "counting " & $total & (if total == 1: " file" else: " files")
  var args = ActualItems(inp: inp, grid: grid)
  var sizes = newSeq[int64](total)
  for i, f in inp.files: sizes[i] = max(0'i64, f.size)
  var tally = ActualTally()
  var cells = actual.fold # the map's own counts (a tensor shares its storage)
  let raw = cast[ptr UncheckedArray[int32]](cells.unsafe_raw_offset(aligned = false))
  proc take(i: int; outcome: sink ItemOutcome[ActualPart]) {.closure, gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase "counting " & inp.files[i].path.extractFilename
    if not outcome.ok:
      if outcome.failure.cancelled: raise newException(JobCancelledError, "cancelled")
      let e = outcome.failure
      tally.skipped.add (path: inp.files[i].path, why: if e.msg.len > 0: e.msg else: e.name)
      return
    template r: untyped = outcome.value
    if r.skip.len > 0:
      tally.skipped.add (path: inp.files[i].path, why: r.skip)
      return
    inc tally.files
    if r.unplaced: inc tally.unplaced
    tally.traces += r.traces
    tally.notLive += r.notLive
    tally.killed += r.killed
    tally.noCoordinates += r.noCoordinates
    tally.outside += r.outside
    tally.binned += r.binned
    for k, bin in r.bins: raw[bin] += r.counts[k]
  let ran = ctx.parallelItems(total, addr args, readActual, take,
    ItemOptions(cost: sizes, budget: actualBudget))
  if ran.taken < total: raise newException(JobCancelledError, "cancelled")
  tally

# ---------------------------------------------------------------- the inputs --

func seismicEntries(st: AppState): seq[int] =
  ## The indices of the Files window's seismic entries that can be counted.
  for i, e in st.fileList.entries:
    if e.kind in ActualKinds: result.add i

func actualReason*(st: AppState): string =
  ## Why the recorded fold cannot be counted now; "" when it can.
  if st.projectSurveyLoading: SurveyLoading
  elif st.fileList.scanning: Listing
  elif st.seismicEntries.len == 0: NoSeismicFiles
  else: ""

func movesKey(moves: StationMoves): string =
  for i in 0 ..< moves.len:
    let m = moves[i]
    result.add $m.station.line & "," & $m.station.point & "," & $m.station.index & "," &
      $m.x & "," & $m.y & "," & $m.elev & "," & $m.fromTime & ";"

func projectMoves(st: AppState): StationMoves =
  if st.inProject: st.project.doc.stationMoves else: StationMoves()

proc actualStamp*(st: AppState): int =
  ## A number that changes when anything `actualInputs` reads changes; cheap, so the window
  ## asks each frame and builds the inputs only when it moved.
  var h: Hash = 0
  h = h !& hash(st.fileList.entriesRev) !& hash(st.fileList.gen) !& hash(st.fileList.recursive) !&
    hash(st.fileList.scanning) !& hash(st.survey.revision) !&
    hash(cast[int](st.projectSurvey)) !& hash(st.projectSurveyLoading) !&
    hash(st.projectTableOnly) !& hash(st.fileList.entries.len)
  for i in st.seismicEntries:
    let e = st.editsAt(st.fileList.entries[i].path)
    h = h !& hash(e.revision) !& hash(e.shown.lists[teKilled].len)
  h = h !& hash(st.projectMoves.movesKey)
  if st.inProject: h = h !& hash($st.project.doc.options)
  !$h

proc actualInputs*(st: AppState): ref ActualInputs =
  ## What the count needs from `st`: every seismic file of the Files window's list (its
  ## subfolders' files when it lists them), the edits' kills, the project's survey, join
  ## options and moves. The key names them all.
  result = new ActualInputs
  result.cacheDir = st.indexCache
  result.survey = st.projectSurvey
  result.moves = st.projectMoves
  result.tableOnly = st.projectTableOnly
  if st.inProject and not result.survey.isNil: result.options = st.project.doc.options
  var key = "files:" & $st.fileList.recursive & ";"
  for i in st.seismicEntries:
    let e = st.fileList.entries[i]
    var f = ActualFile(path: e.path, size: e.size)
    let edits = st.editsAt(e.path)
    f.kills = edits.shown.lists[teKilled]
    f.kills.sort()
    key.add e.path & "|" & $e.size & "|" & $e.modified.toUnix & "|" & $hash(f.kills) & ";"
    result.files.add f
  key.add "survey:" & $cast[int](result.survey) & "|" & $result.tableOnly & "|" &
    (if result.survey.isNil: "" else: $result.options) & ";moves:" & result.moves.movesKey
  result.key = key
