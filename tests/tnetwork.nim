## A network drive that is slow, stops answering or goes away, through the
## file-system seam (`tests/utils/faultyfs`): a folder whose listing hangs, a
## file whose open hangs, a read that hangs and a drive that fails mid-read
## each leave every call the UI thread makes quick, another file can be shown
## meanwhile, a cancel is taken at once, the quit ends within a second, and
## nothing the UI thread calls reaches the file system.
##
## Seen to fail: with the watch's `dirExists` back under its lock,
## `watchStatsOutsideItsLock` found `watchOpen` held as long as the stat hung
## (60 s, the fault's limit); with `tend` not called from `drainInbox`,
## `aHungOpenIsLeft` never showed the second file (the lane stayed with the
## hung open).
##
## Under ThreadSanitizer only thread leaks are reported: the threads left in
## the hung drive, by design.
##
## Runs alone: it bounds the time the UI thread's calls take (50 ms) and the
## quit (1.5 s).

import std/[monotimes, os, strutils, times]
import viewSEG/core/[inbox, state, watch]
import utils/[faultyfs, fixtures, waiting]

const Budget = initDuration(milliseconds = 50) ## a frame's work, at most

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

template quick(body: untyped): Duration =
  ## How long `body` took.
  let t0 = getMonoTime()
  body
  getMonoTime() - t0

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc tilesOf(st: AppState): int = st.tiles(st.findPanel(MainPanel)).len

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc look(st: var AppState; first, last: float64) =
  var v = fitAll(st.main.layout, 800, 600)
  v.traces = Span(lo: first - 0.5, hi: last + 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

proc silent() =
  ## As much time on the seam's clock as a drive that stopped answering
  ## takes to be said not to answer.
  advanceFsClock(StallAfter + initDuration(seconds = 1))

install()

withFixtures fx:
  let far = fx.dir / "far"     # the network drive
  let near = fx.dir / "near"   # a local disk
  createDir(far)
  createDir(near)
  let survey = fx.surveySegy
  copyFile(survey, far / "a.sgy")
  copyFile(fx.wideShotSegy, far / "c.sgy") # 2000 traces: views apart need reads of their own
  copyFile(survey, near / "b.sgy")

  block watchStatsOutsideItsLock:
    # A new listing makes the watch stat its folder: a folder that does not
    # answer must not hold the lock the UI thread takes in `watchOpen`.
    var st = initAppState() # (marks this thread the UI thread)
    let box = initInbox()
    var w = newFolderWatch(box.poster, initDuration(milliseconds = 10))
    fault(far, fkHang, {foStat, foList})
    w.watch(1, @[far], @[])
    doAssert waitUntil(hung() >= 1), "the watch's stat hangs"
    let t = quick: w.watchOpen(@[far / "a.sgy"])
    doAssert t < Budget, "watchOpen waited " & $t & " for a stat"
    doAssert w.lookingFor() > initDuration(), "a look under way"
    let s = quick: w.stop(getMonoTime() + initDuration(milliseconds = 300))
    doAssert s < initDuration(seconds = 1), "stop waited " & $s
    release(far)
    doAssert waitUntil(hung() == 0)
    st.shutdown()

  block aHungOpenIsLeft:
    # The open of a file on the drive hangs; the user picks a local file:
    # it is shown, and the hung open's late file is dropped.
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    fault(far / "a.sgy", fkHang, {foStat})
    var t = quick: st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "a.sgy")
    doAssert t < Budget
    doAssert waitUntil(hung() == 1), "the open hangs"
    silent()
    var stuck = NoJob
    for j in st.jobs.active:
      if "a.sgy" in j.spec.title: stuck = j.id
    doAssert st.jobs.info(stuck).get.notAnsweringFor > initDuration(), "said not to answer"
    t = quick: st.apply Command(kind: ckShowFile, panel: MainPanel, path: near / "b.sgy")
    doAssert t < Budget
    var worst = initDuration()
    doAssert waitUntil((block:
      let d = quick: discard st.drainInbox()
      worst = max(worst, d)
      st.shownPath == near / "b.sgy" and st.main.laidOut)), "the local file is shown"
    doAssert worst < Budget, "a frame's inbox took " & $worst
    doAssert st.jobs.info(stuck).get.state == jsCancelled and st.jobs.info(stuck).get.abandoned
    # The drive answers again: the open comes back late and is dropped.
    release(far / "a.sgy")
    doAssert waitUntil(hung() == 0)
    sleep 100
    discard st.drainInbox()
    doAssert st.shownPath == near / "b.sgy"
    doAssert st.sessions.len == 1, "the late open is dropped: " & $st.sessions.len
    doAssert not st.log.has("Opened a.sgy")
    st.shutdown()

  block aHungListing:
    # Listing the drive's folder hangs: the listing says it does not answer,
    # cancel takes it out, and another folder lists meanwhile.
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    fault(far, fkHang, {foList})
    st.apply Command(kind: ckBrowse, paths: @[far])
    doAssert waitUntil(hung() == 1), "the listing hangs"
    let scan = st.fileList.job
    silent()
    doAssert st.jobs.info(scan).get.notAnsweringFor > initDuration()
    let t = quick: st.apply Command(kind: ckCancelJob, job: scan)
    doAssert t < Budget
    doAssert st.settle(not st.fileList.scanning), "cancel takes the listing out"
    doAssert st.jobs.info(scan).get.state == jsCancelled
    st.apply Command(kind: ckBrowse, paths: @[near])
    doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 1),
      "another folder lists meanwhile"
    release(far)
    doAssert waitUntil(hung() == 0)
    st.shutdown()

  block aDriveThatFails:
    # A file is shown, then its drive goes away: nothing more is read of it,
    # the plot keeps what it showed, and the log says why.
    var st = initAppState(watchEvery = initDuration(seconds = 30))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "c.sgy")
    doAssert st.settle(st.main.laidOut)
    st.look(0, 99)
    doAssert st.settle(st.tilesOf > 0)
    fault(far, fkFail)
    st.look(1000, 1099)
    doAssert st.settle(st.log.has("c.sgy cannot be read now", sevWarning))
    doAssert st.tilesOf > 0, "the plot keeps its tiles"
    # A read that fails in the map itself: the reader says so and goes on.
    release(far)
    fault(far, fkFail, {foMapped})
    st.look(1500, 1599)
    doAssert st.settle(st.log.has("Cannot read c.sgy", sevError))
    release(far)
    st.look(600, 699)
    let before = st.tilesTaken
    doAssert st.settle(st.tilesTaken > before), "read again once the drive is back"
    st.shutdown()

  block quitWithin:
    # Everything hangs at once: an open, a read, the listing, the watch and
    # the folder the settings go to. The quit ends within a second.
    let config = fx.dir / "config"
    createDir(config)
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    st.keepSettingsIn(config, LoadedSettings(saveable: true))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "c.sgy")
    doAssert st.settle(st.main.laidOut)
    st.apply Command(kind: ckBrowse, paths: @[near])
    doAssert st.settle(not st.fileList.scanning)
    fault(far, fkHang)
    fault(near, fkHang, {foStat, foList})
    fault(config, fkHang)
    st.look(1000, 1099) # the reader's stat hangs
    st.apply Command(kind: ckOpen, paths: @[far / "a.sgy"]) # the open hangs
    var s = st.settings
    s.theme = "changed"
    st.apply Command(kind: ckSettings, settings: s)
    doAssert waitUntil(hung() >= 3), "the read, the open and the watch hang: " & $hung()
    let t = quick:
      let ended = st.shutdown()
      doAssert not ended, "something was left"
    echo "quit with an open, a read and the watch hung: ", t.inMilliseconds, " ms"
    doAssert t < initDuration(milliseconds = 1500), "the quit took " & $t
    releaseAll() # the stuck threads come back and end on their own
    doAssert waitUntil(hung() == 0)
    sleep 50

  block noUiCalls:
    doAssert uiCalls().len == 0, "the UI thread called the file system:\n" &
      uiCalls().join("\n")

echo "tnetwork: ok"
