## A loaded file is never changed: every fixture (the survey and each of its
## planted defects, the SPS files, both SEG-D records, the pilot, parseSEG's
## demo files, and two damaged files) is opened, shown gather by gather,
## zoomed, panned, box-zoomed, sent back, given every display gain, reversed
## polarity and other header rows, read to the newest tile, closed, and then
## opened again from the index cache. Each file's bytes and modification time
## are then as they were, and its folder holds the same files, of the same
## sizes, and nothing else.
##
## Seen to fail: with the open job marking the seismic file used instead of
## its index cache (`setLastModificationTime(path, ...)` in `openWork`), the
## second round found the modification times of the files moved.

import std/[algorithm, os, strutils, times]
import viewSEG/core/state
import utils/[fixtures, waiting]

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc listing(dir: string): seq[(string, int64)] =
  ## The files directly in `dir`, with their sizes, by name.
  for kind, path in walkDir(dir):
    if kind == pcFile: result.add (path.extractFilename, getFileSize(path))
  result.sort()

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc answered(st: AppState): bool =
  ## Nothing more to read for the view on screen: its tile came, or the
  ## panel has nothing to read.
  let p = st.main
  p.pending.isEmpty or (st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending)

proc view(st: var AppState; v: Viewport; remember = false) =
  st.apply Command(kind: ckView, panel: MainPanel, view: v, remember: remember)

proc display(st: var AppState; d: DisplaySettings) =
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

var driven, tiled = 0 # gathers worked with; of them, the ones with samples to show

proc drive(st: var AppState) =
  ## What a user does with a record in the plot, through the commands the
  ## plot window issues.
  let lay = st.main.layout
  let lim = limitsOf(lay)
  var v = fitAll(lay, 640, 480)
  st.view(v)
  doAssert st.settle(st.answered)
  inc driven
  if lay.traces > 0 and lay.samples > 0:
    doAssert st.tiles(0).len > 0, "nothing read"
    inc tiled
  v = v.zoomed(3, v.centre, BothAxes, lim)
  st.view(v, remember = true)
  v = v.stepped(0.3, 0.2, lim)
  st.view(v, remember = true)
  v = v.boxed(DataPoint(x: v.traces.lo, tMs: v.timeMs.lo), v.centre, BothAxes, lim)
  st.view(v, remember = true)
  st.apply Command(kind: ckBack, panel: MainPanel)
  var d = st.main.layers[0].display
  for g in [dgNone, dgTraceBalance, dgAgc, dgAuto]:
    d.gain = g
    st.display(d)
  d.reversed = not d.reversed
  st.display(d)
  st.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: false,
    fields: @[hfRecord, hfChannel, hfOffset]))
  st.view(fitAll(lay, 640, 480), remember = true)
  doAssert st.settle(st.answered)
  st.apply Command(kind: ckHeader, panel: MainPanel, header: HeaderChoice(auto: true))

proc showAll(st: var AppState; path: string) =
  ## Opens `path`, shows each of its gathers and works with it, then closes it.
  let name = path.extractFilename
  st.apply Command(kind: ckOpen, paths: @[path])
  doAssert st.settle(st.jobs.active.len == 0), "the open of " & name & " never ended"
  if st.sessions.len == 0: return # not a seismic file: said in the log
  let s = st.sessions[0]
  for g in 0 ..< s.gathers.len:
    if g > 0: st.apply Command(kind: ckGather, panel: MainPanel, gather: g)
    doAssert st.settle(st.main.laidOut), name & ": gather " & $g & " never laid out"
    st.drive()
  st.apply Command(kind: ckClose, file: s.id)
  doAssert st.settle(st.sessions.len == 0 and st.jobs.active.len == 0),
    name & " never closed"
  doAssert st.jobs.held(s.path) == 0

withFixtures fx:
  var files: seq[string]
  for d in PlantedDefect:
    files.add fx.surveySegy(d)
  let sps = fx.surveySps()
  files.add [sps.s, sps.r, sps.x]
  files.add [fx.twoSetSegd(), fx.threeComponentSegd(), fx.pilotSegy()]
  for name in demoFileNames:
    files.add fx.demoFile(name)
  let cut = fx.dir / "cut.sgy"
  writeFile(cut, readFile(fx.surveySegy())[0 ..< SurveyTraces div 2 * (240 + 4 * Samples)])
  let stub = fx.dir / "stub.sgd"
  writeFile(stub, readFile(fx.twoSetSegd())[0 ..< 2000])
  files.add [cut, stub]
  # Modification times are compared exactly: give every file one well in the
  # past, so that a write within this second would show.
  let past = getTime() - initDuration(hours = 1)
  for f in files:
    setLastModificationTime(f, past)
  var before: seq[Snapshot]
  for f in files:
    before.add snapshot(f)
  let folder = listing(fx.dir)
  let cache = fx.dir / "cache" / "index" # a folder of its own: not in the listing
  var st = initAppState(indexCache = cache)
  for round in 1 .. 2: # the second opens from the index cache
    for f in files:
      st.showAll(f)
    for i, f in files:
      let now = snapshot(f)
      doAssert now.bytes == before[i].bytes, "round " & $round & ": " & f.extractFilename &
        " was written"
      doAssert now.time == before[i].time, "round " & $round & ": the modification time of " &
        f.extractFilename & " moved"
    doAssert listing(fx.dir) == folder, "round " & $round & ": the folder changed: " &
      $listing(fx.dir)
  var cached = 0
  for e in st.log:
    if "(index from the cache)" in e.text: inc cached
  doAssert cached > 0, "the second round read no index cache"
  echo "tunchanged: ", files.len, " files, ", driven, " gathers worked with, ", tiled,
    " of them read"
  doAssert tiled >= 2 * (PlantedDefect.high.ord + 1) * Shots, $tiled
  st.shutdown()
