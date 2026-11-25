## The Export SPS button of the Shot log window, in the running frontend,
## headless: the button is there and not dim for a log with shot points; it
## opens the panel; Export is refused until a file is chosen and while the chosen
## file exists (and says why); with a new name Export writes the file the core
## writes for the log, and the outcome line says how many rows were written and
## left out; a log with no shot point leaves the button dim, with its reason.
##
## Seen to fail: with the options left out of the command, "the file is not what the
## core writes for the panel's options". With a file kept when the log changes, "the first
## log's file or outcome is shown for the second".
## Seen to fail: with the button's dim state left off, "the button was not dim for
## a log with no shot point". With the name in use not refused, "Export was not
## refused for a file that exists". With the chosen name never reaching the
## command, "the SPS file was not written".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os, strutils, times]
import parseSEG
import viewSEG/core/[geometry, shotlog, shotlogsps, state]
import viewSEG/ui/imgui/app
import utils/[faultyfs, fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc boxOf(f: FrameInfo; mark: string): Vec2 =
  ## A point inside the box of a labelled input: its mark spans the label too.
  let r = f.markOf(mark)
  vec2(r.pos.x + 20, round(r.pos.y + r.size.y / 2))

proc hasMark(f: FrameInfo; prefix: string): bool =
  f.markNames(prefix).len > 0

type Step = object
  name: string
  limit: int
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let root = currentSourcePath().parentDir.parentDir
    let good = fx.dir / "good.csv"
    let blank = fx.dir / "blank.csv"
    # The third row has no easting; the fourth has no line, which the panel's
    # default line fills.
    writeFile(good, "source line,shot point,X,Y,date-time text\n" &
      "10,1000,500.5,2000.5,2024-03-01 00:00:00.000000\n" &
      "10,1001,501.5,2001.5,2024-03-01 00:00:10.000000\n" &
      "10,1002,,2002.5,2024-03-01 00:00:20.000000\n" &
      ",1003,503.5,2003.5,2024-03-01 00:00:30.000000\n")
    let second = fx.dir / "second.csv"
    writeFile(second, "source line,shot point,X,Y\n11,2000,600.5,3000.5\n")
    writeFile(blank, "shot point,X,Y\n,1,2\n,3,4\n")
    let taken = fx.dir / "taken.sps"
    writeFile(taken, "keep me\n")
    let fresh = fx.dir / "fresh.sps"
    let shot = root / ".scratch" / "shotlog-sps.png"
    createDir(shot.parentDir)

    createDir(fx.dir / "slow")
    install()
    var nextLog = good
    var nextDest = taken
    var asked: seq[DialogKind]
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      case kind
      of dkShotLog: @[nextLog]
      of dkExportShotSps: @[nextDest]
      else: @[]
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var why = ""
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
        limit = 600) =
      steps.add Step(name: name, limit: limit, act: act, done: done)
    proc importNext(f: FrameInfo) = f.click(f.markOf("menu.Import shot log...").centre)

    step("the bar", proc (f: FrameInfo) =
      f.resizeWindow(1920, 1080)
      f.keepInMainWindow()
      # the pane under the plot is too low for the panel: the window is floated here
      f.arrangeWindows(f.layoutText & "[Window][###shotlog]\nPos=20,80\nSize=1500,850\n" &
        "Collapsed=0\n\n[viewSEG][Windows]\nHidden=aux,missing,quality,vibfolder,output\n\n"),
      proc (f: FrameInfo): bool =
        f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080))
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
    step("import the log", importNext,
      proc (f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.markOf("shotlog.exportsps").size.x > 0 and
        not f.hasMark("shotlog.exportsps.dim") and not f.hasMark("shotlog.sps.run"))
    step("open the panel", proc (f: FrameInfo) = f.click(f.markOf("shotlog.exportsps").centre),
      proc (f: FrameInfo): bool =
      if not f.hasMark("shotlog.sps.run") and wait mod 8 == 0:
        f.click(f.markOf("shotlog.exportsps").centre)
      f.hasMark("shotlog.sps.run") and f.hasMark("shotlog.sps.why Choose the file"))
    step("choose a file that exists", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.sps.choose").centre),
      proc (f: FrameInfo): bool =
        why = $f.markNames("shotlog.sps.")
        asked == @[dkShotLog, dkExportShotSps] and
          f.hasMark("shotlog.sps.file " & taken) and f.hasMark("shotlog.sps.why That file exists"))
    step("Export is refused", proc (f: FrameInfo) = f.click(f.markOf("shotlog.sps.run").centre),
      proc (f: FrameInfo): bool =
      doAssert readFile(taken) == "keep me\n", "an existing file was replaced"
      doAssert not f.core.spsRunning and f.core.spsOutcome.len == 0,
        "Export was not refused for a file that exists"
      wait > 10)
    step("choose a new file", proc (f: FrameInfo) =
      nextDest = fresh
      f.click(f.markOf("shotlog.sps.choose").centre),
      proc (f: FrameInfo): bool =
        f.hasMark("shotlog.sps.file " & fresh) and not f.hasMark("shotlog.sps.why"))
    proc typeInto(name, mark, text: string; seen: string) =
      ## Clicks the box, types, and waits for the window to show `seen`.
      step(name, proc (f: FrameInfo) = f.click(boxOf(f, mark)),
        proc (f: FrameInfo): bool =
        why = $f.markNames("shotlog.sps.")
        if wait == 5: f.typeText(text)
        f.hasMark(seen) and wait >= 8)
    step("revision 1.0", proc (f: FrameInfo) = f.click(boxOf(f, "shotlog.sps.revision")),
      proc (f: FrameInfo): bool =
      let item = f.markOf("shotlog.sps.revision 1.0")
      if item.size.x > 0 and wait == 4: f.click(item.centre)
      wait >= 10 and item.size.x == 0)
    typeInto("a default line", "shotlog.sps.line", "20", "shotlog.sps.linetext 20")
    typeInto("a point index", "shotlog.sps.index", "3", "shotlog.sps.indextext 3")
    typeInto("a point code", "shotlog.sps.code", "V1", "shotlog.sps.codetext V1")
    step("Write the time", proc (f: FrameInfo) = f.click(f.markOf("shotlog.sps.time").centre),
      proc (f: FrameInfo): bool = wait >= 6)
    step("Export", proc (f: FrameInfo) = f.click(f.markOf("shotlog.sps.run").centre),
      proc (f: FrameInfo): bool =
      why = f.core.spsOutcome
      if f.hasMark("shotlog.sps.outcome Wrote 3 rows to fresh.sps"):
        doAssert fileExists(fresh), "the SPS file was not written"
        var opts = initShotSpsOptions()
        opts.revision = sps10
        opts.defaultLine = 20
        opts.defaultIndex = 3
        opts.pointCode = "V1"
        opts.withTime = true
        let want = toSps(f.core.shotView(0), opts)
        doAssert want.written == 3 and want.text.len > 0
        doAssert readFile(fresh) == want.text,
          "the file is not what the core writes for the panel's options"
        doAssert "1 row was left out: row 3 easting is missing" in f.core.spsOutcome,
          f.core.spsOutcome
        doAssert f.savePng(shot), "the screenshot was not written"
        return true
      false, 2000)
    # A file on a drive that does not answer: the window goes on drawing, Export
    # is dim and says it is checking, and the file's answer comes when the drive's does.
    step("a file on a drive that does not answer", proc (f: FrameInfo) =
      fault(fx.dir / "slow", fkHang, {foStat})
      nextDest = fx.dir / "slow" / "late.sps"
      f.click(f.markOf("shotlog.sps.choose").centre),
      proc (f: FrameInfo): bool =
        why = $f.markNames("shotlog.sps.")
        f.hasMark("shotlog.sps.file " & nextDest) and
          f.hasMark("shotlog.sps.why Checking the destination..."))
    step("Export is refused while it checks", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.sps.run").centre),
      proc (f: FrameInfo): bool =
      doAssert f.hasMark("shotlog.sps.why Checking the destination..."),
        "the answer came from a drive that was hung"
      doAssert not f.core.spsRunning, "Export started while the destination was unchecked"
      wait > 8)
    step("the drive answers", proc (f: FrameInfo) = release(fx.dir / "slow"),
      proc (f: FrameInfo): bool =
      not f.hasMark("shotlog.sps.why") and f.hasMark("shotlog.sps.file " & nextDest))
    step("another log, with a shot point", proc (f: FrameInfo) =
      nextLog = second
      f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool =
        if f.markOf("menu.Import shot log...").size.x > 0 and f.core.shotLogCount == 1:
          f.click(f.markOf("menu.Import shot log...").centre)
        if f.core.shotLogCount == 2:
          doAssert not f.hasMark("shotlog.sps.file " & fresh) and
            not f.hasMark("shotlog.sps.outcome"),
            "the first log's file or outcome is shown for the second"
          return f.hasMark("shotlog.sps.why Choose the file")
        false, 2000)
    step("another log, no shot point", proc (f: FrameInfo) =
      nextLog = blank
      f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool =
        if f.markOf("menu.Import shot log...").size.x > 0 and f.core.shotLogCount == 2:
          f.click(f.markOf("menu.Import shot log...").centre)
        f.core.shotLogCount == 3 and f.hasMark("shotlog.exportsps.dim"), 2000)

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.keepInMainWindow()
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, steps[at].limit, since):
          failed = steps[at].name & " did not happen: " & why
          f.stop()
    var opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[root / "assets"]), dialogs: hook)
    opts.onFrame = onFrame
    let code = run(opts)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguishotsps: ", steps.len, " steps"

when isMainModule:
  main()
