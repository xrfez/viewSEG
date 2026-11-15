## Reading ahead on a slow drive, through the file-system seam
## (`tests/utils/faultyfs`), counted, not timed, so that a loaded machine
## does not change the result:
##
## - **Panning.** A drive whose every read (a prefetch chunk) is a round trip
##   the test grants, two between key presses: a view a hundred traces wide
##   is panned half a view a step, thirty steps. On a drive that answers at
##   once the panel reads as it always did; on one whose round trips take
##   300 ms (`fs.now`) it finds it slow, reads three views ahead in reads of
##   256 traces, and the view is on hand at more steps, with fewer round
##   trips.
## - **Stepping through a folder.** Five files on a drive whose every call
##   takes 200 ms: the calls the user waits for between a step and the new
##   file's first tile, with "Prepare the next file" off and on. On, the
##   next file was opened while the one before was shown, so the step waits
##   only for the reads of its samples.
##
## The numbers are printed (before, after). Seen to fail: with the read
## timing not taken in (`timeRead` left out of `drainInbox`), the slow drive
## read as the fast one and `panning` failed; with `takePrepared` dropping
## every file, `stepping` failed.

import std/[importutils, monotimes, os, strutils, times]
import viewSEG/core/state {.all.}

privateAccess(AppState)
import utils/[faultyfs, fixtures, waiting]

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc mainTiles(st: AppState): lent seq[Tile] = st.tiles(st.findPanel(MainPanel))

proc viewOf(st: AppState; first, last: float64): Viewport =
  result = fitAll(st.main.layout, 800, 600)
  result.traces = Span(lo: first - 0.5, hi: last + 0.5)

proc onHand(st: AppState; v: Viewport): bool =
  ## Whether a tile taken in holds `v` at the resolution it needs.
  for t in st.mainTiles:
    if t.request.covers(st.main.layout, v): return true
  false

proc answered(st: AppState): bool =
  ## The request sent last has its tile.
  for t in st.mainTiles:
    if t.request.gen == st.main.pending.gen: return true
  false

proc quiet(st: var AppState) =
  ## Until the reads granted are made, and the reader waits for the drive
  ## again or has nothing left to read.
  discard st.settle((permitsLeft() == 0 and hung() >= 1) or (st.answered and hung() == 0))
  for _ in 0 ..< 20:
    discard st.drainInbox()
    sleep 1

proc pan(far: string; delay: Duration): tuple[waits, trips, requests: int; slow: bool] =
  ## Thirty half-view steps over a 2000-trace record whose every chunk read
  ## is a round trip taking `delay`, two of them between steps.
  var st = initAppState(watchEvery = initDuration(seconds = 60))
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "wide.sgy")
  doAssert st.settle(st.main.laidOut)
  st.apply Command(kind: ckView, panel: MainPanel, view: st.viewOf(0, 99))
  doAssert st.settle(st.answered and st.onHand(st.viewOf(0, 99)))
  fault(far, fkPermits, {foMapped}, delay)
  resetCounts()
  let gen0 = st.main.requestGen
  for step in 1 .. 30:
    let v = st.viewOf(float64(50 * step), float64(50 * step + 99))
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    for _ in 0 ..< 5: discard st.drainInbox()
    if not st.onHand(v): inc result.waits
    grant(2) # the round trips the drive makes before the next key press
    st.quiet()
  result.trips = calls(foMapped, far)
  result.requests = int(st.main.requestGen - gen0)
  result.slow = st.slowDrive(MainPanel)
  releaseAll()
  release(far)
  discard st.shutdown()

proc stepping(far: string; prepare: bool): tuple[calls: int; prepared: int] =
  ## Steps through the five files; per step, the calls on the new file
  ## between the step and its first tile.
  var st = initAppState(indexCache = far / ("cache-" & $prepare),
    watchEvery = initDuration(seconds = 60))
  var s = st.settings
  s.files.prepareNext = prepare
  st.apply Command(kind: ckSettings, settings: s)
  st.apply Command(kind: ckBrowse, paths: @[far / "folder"], showFirst: true)
  doAssert st.settle(not st.fileList.scanning and st.main.laidOut)
  st.apply Command(kind: ckView, panel: MainPanel, view: st.viewOf(0, 99)) # the plot's size
  doAssert st.settle(st.answered)
  fault(far, fkSlow, {foStat, foOpen, foRead, foMapped}, initDuration(milliseconds = 200))
  for i in 1 ..< 5:
    let path = far / "folder" / ("shot" & $i & ".sgy")
    st.apply Command(kind: ckPrepare, panel: MainPanel, path: path) # as the Files window does
    if prepare:
      doAssert st.settle(not st.prepared.session.isNil), "shot" & $i & " prepared"
      inc result.prepared
    resetCounts()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.shownFile(st.findPanel(MainPanel)) >= 0 and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].path == path and st.main.laidOut and
      st.mainTiles.len > 0 and st.answered), "shot" & $i & " shown"
    for op in FsOp: result.calls += calls(op, path)
  release(far)
  discard st.shutdown()

install()

withFixtures fx:
  let far = fx.dir / "far"
  createDir(far / "folder")
  copyFile(fx.wideShotSegy, far / "wide.sgy")
  for i in 0 ..< 5:
    copyFile(fx.wideShotSegy, far / "folder" / ("shot" & $i & ".sgy"))

  block panning:
    let fast = pan(far, initDuration())
    let slow = pan(far, initDuration(milliseconds = 300))
    echo "panning, 30 half-view steps, 2 round trips a step: as before (a drive that " &
      "answers at once): ", fast.waits, " steps waited, ", fast.trips, " round trips, ",
      fast.requests, " requests; slow drive (300 ms a round trip): ", slow.waits,
      " steps waited, ", slow.trips, " round trips, ", slow.requests, " requests"
    doAssert not fast.slow and slow.slow, "the slow drive is found slow"
    doAssert slow.waits < fast.waits, "fewer waits on the slow drive"
    doAssert slow.trips < fast.trips, "fewer round trips"

  block steppingThroughAFolder:
    let off = stepping(far, prepare = false)
    let on = stepping(far, prepare = true)
    echo "stepping through 4 files (200 ms a call): calls waited for after each step, in all: ",
      "without preparing ", off.calls, " (", off.calls * 200, " ms), with ", on.calls, " (",
      on.calls * 200, " ms; ", on.prepared, " files prepared)"
    doAssert on.prepared == 4
    doAssert on.calls < off.calls, "preparing the next file saves waits"

  doAssert uiCalls().len == 0, uiCalls().join("\n")
echo "tslowdrive: ok"
