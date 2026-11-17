## A network drive that stops answering, in the running frontend, headless,
## through the file-system seam (`tests/utils/faultyfs`): a read that hangs
## says so in the plot after a while ("Reading a.sgy: not answering for
## 4 s"), the plot keeps its picture, Cancel stops waiting and Retry reads
## again once the drive answers; an open that hangs says so above the plot
## that stays, and Cancel takes it out; a listing that hangs says so in the
## Files window, and another file is shown meanwhile; a drive that goes
## away leaves the picture with a message; the window keeps drawing frames
## through it all, nothing it calls reaches the file system, and the quit
## with everything hung ends within a second and a half.
##
## Seen to fail: with the plot's line of what does not answer not drawn
## (`drawWaiting` returning at once), it "stopped before read hangs".
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves network-hang.png there (the plot saying
## its read does not answer).
##
## Runs alone: it bounds the time between frames while the drive hangs
## (0.5 s) and the quit (1.5 s).

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[faultyfs, fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc shownPath(f: FrameInfo): string =
  let i = f.core.shownFile(f.core.findPanel(MainPanel))
  if i >= 0: f.core.sessions[i].path else: ""

proc main(f: FrameInfo): lent Panel = f.core.panels[f.core.findPanel(MainPanel)]

proc wait(f: FrameInfo): Waiting = f.core.waiting(f.core.findPanel(MainPanel))

proc tiles(f: FrameInfo): int = f.core.tiles(f.core.findPanel(MainPanel)).len

proc viewOf(f: FrameInfo; first, last: float64): Viewport =
  result = fitAll(f.main.layout, f.main.view.columns, f.main.view.rows)
  result.traces = Span(lo: first - 0.5, hi: last + 0.5)

proc silent() = advanceFsClock(StallAfter + initDuration(seconds = 1))

proc main*() =

  install()

  withFixtures fx:
    let far = fx.dir / "far"
    let near = fx.dir / "near"
    createDir(far)
    createDir(near)
    copyFile(fx.wideShotSegy, far / "a.sgy")
    copyFile(fx.surveySegy, far / "c.sgy")
    copyFile(fx.surveySegy, near / "b.sgy")
    var
      stage = 0
      waited = 0
      at: Vec2
      reached: seq[string]
      lines: seq[Message]
      said: seq[string]
      lastFrame = MonoTime()
      worstGap = initDuration()
      hanging = false
      stoppedAt = MonoTime()
      tilesBefore = 0
      advanced = false
      saved = false
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    let start = getMonoTime()
    proc next(f: FrameInfo; what: string) =
      reached.add what
      inc stage
      waited = 0
      advanced = false
    proc silentOnce(least: int) =
      ## Once `least` calls hang: the seam's clock moved on, so they have not
      ## answered for a while.
      if not advanced and hung() >= least:
        silent()
        advanced = true
    proc click(f: FrameInfo; mark: string): bool =
      ## Clicks the middle of `mark` over a few frames; true once released.
      if waited == 1:
        at = f.markOf(mark).centre
        f.moveMouse(at)
      if waited == 3: f.pressMouse(at, true)
      if waited == 5: f.pressMouse(at, false)
      waited > 5
    proc onFrame(f: FrameInfo) =
      inc waited
      let now = getMonoTime()
      if hanging and lastFrame != MonoTime(): worstGap = max(worstGap, now - lastFrame)
      lastFrame = now
      if f.index == 0:
        f.moveMouse(vec2(4, 4))
        var s = f.core.settings
        s.files.prepareNext = false # c.sgy is opened here, not before (tslowdrive prepares)
        f.apply Command(kind: ckSettings, settings: s)
      case stage
      of 0: # a.sgy shown from the drive, its first tile in
        if f.shownPath == far / "a.sgy" and f.main.laidOut and f.tiles > 0 and
            not f.core.fileList.scanning:
          f.showView(f.viewOf(0, 99))
          f.next "shown"
      of 1:
        if waited > 3 and f.tiles > 0:
          fault(far / "a.sgy", fkHang, {foStat, foMapped})
          hanging = true
          tilesBefore = f.tiles
          f.showView(f.viewOf(1900, 1999)) # past what was read (0 .. 1839): the read hangs
          f.next "panned"
      of 2: # the read hangs: said in the plot once it has not answered for a while
        silentOnce(1)
        if advanced and f.wait.kind == wkReading and f.markOf("plot.wait").size.x > 0:
          said.add f.wait.words
          doAssert f.tiles >= tilesBefore, "the plot keeps its picture"
          if shots.len > 0:
            createDir(shots)
            saved = f.savePng(shots / "network-hang.png")
          f.next "read hangs"
      of 3: # Cancel: the plot stops waiting, keeps its picture, offers Retry
        if f.click("plot.wait.cancel"):
          if f.wait.kind == wkUnreadable and "Not reading a.sgy" in f.wait.words:
            said.add f.wait.words
            f.next "read cancelled"
      of 4: # the drive answers again; Retry reads
        if waited == 1: release(far / "a.sgy")
        if f.click("plot.wait.retry") and f.wait.kind == wkNone and f.main.laidOut and
            f.tiles > 0:
          f.next "read again"
      of 5: # an open that hangs: said above the plot, which stays on a.sgy
        if waited == 1:
          fault(far / "c.sgy", fkHang, {foStat})
          f.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "c.sgy")
        silentOnce(1)
        if advanced and f.wait.kind == wkOpening and f.markOf("plot.wait").size.x > 0 and
            f.shownPath == far / "a.sgy":
          said.add f.wait.words
          waited = 0
          f.next "open hangs"
      of 6: # Cancel: the open goes, the plot stays
        if f.click("plot.wait.cancel") and f.wait.kind == wkNone and
            f.shownPath == far / "a.sgy":
          release(far / "c.sgy")
          f.next "open cancelled"
      of 7: # the folder's listing hangs; another file is shown meanwhile
        if waited == 1:
          fault(far, fkHang, {foList})
          f.apply Command(kind: ckBrowse, paths: @[far])
        silentOnce(1)
        if advanced and f.core.listingWait.kind == wkListing and
            f.markOf("files.wait").size.x > 0:
          said.add f.core.listingWait.words
          f.apply Command(kind: ckShowFile, panel: MainPanel, path: near / "b.sgy")
          f.next "listing hangs"
      of 8:
        if f.shownPath == near / "b.sgy" and f.main.laidOut:
          f.next "another file meanwhile"
      of 9: # Retry the listing once the drive answers
        if waited == 1: release(far)
        if f.click("files.wait.retry") and not f.core.fileList.scanning and
            f.core.fileList.entries.len == 2 and f.core.listingWait.kind == wkNone:
          f.next "listed again"
      of 10: # the drive goes away while a.sgy is shown: the picture stays, with a message
        if waited == 1:
          f.apply Command(kind: ckShowFile, panel: MainPanel, path: far / "a.sgy")
        if waited > 2 and waited < 1000 and f.shownPath == far / "a.sgy" and f.tiles > 0:
          fault(far, fkFail)
          f.showView(f.viewOf(1900, 1999))
          waited = 1000
        if waited > 1003 and f.wait.kind == wkUnreadable and f.tiles > 0 and
            "drive is not answering" in f.wait.words:
          said.add f.wait.words
          f.next "drive gone"
      of 11: # everything hangs; the quit ends within a second and a half
        if waited == 1:
          release(far)
          fault(far, fkHang)
          fault(near, fkHang)
          f.showView(f.viewOf(600, 699))
          f.apply Command(kind: ckOpen, paths: @[far / "c.sgy"])
        if waited > 3 and hung() >= 2:
          lines = f.messages
          stoppedAt = getMonoTime()
          f.next "everything hangs"
          f.stop()
      else: discard
      if overdue(f.index, 3000, start) and stage < 12:
        lines = f.messages
        f.stop()

    let code = run(RunOptions(openPaths: @[far / "a.sgy"],
      windowSize: (1600, 1000), indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
    let quit = getMonoTime() - stoppedAt
    releaseAll() # the threads left in the drive come back and end
    doAssert code == 0, "run() exit code " & $code
    const order = ["shown", "panned", "read hangs", "read cancelled", "read again", "open hangs",
      "open cancelled", "listing hangs", "another file meanwhile", "listed again", "drive gone",
      "everything hangs"]
    for i, s in order:
      doAssert reached.len > i, "stopped before \"" & s & "\": reached " & $reached &
        "; said " & $said & "; Messages: " & $lines
    for s in said: echo "tguinetwork: said: ", s
    echo "tguinetwork: the longest time between frames while the drive hung: ",
      worstGap.inMilliseconds, " ms; the quit: ", quit.inMilliseconds, " ms"
    doAssert worstGap < initDuration(milliseconds = 500), "a frame took " & $worstGap
    doAssert quit < initDuration(milliseconds = 1500), "the quit took " & $quit
    doAssert uiCalls().len == 0, "the UI thread called the file system:\n" &
      uiCalls().join("\n")
    echo "tguinetwork: ", reached.len, " steps: ", reached.join(", ")

when isMainModule:
  main()
