## Project > Cut by shot log, headless, driven by real clicks: the menu item does
## nothing while no file is shown and no log is loaded and opens the dialog once
## both are there; the dialog sums up the shots, the components and the size; a
## record length that is not a whole number of samples shows the sentence of
## `checkOptions` and Cut stays dim; with a good length a run writes the file and
## the dialog offers to open it.
##
## Seen to fail: with the menu item always enabled, "the dialog opened with no
## file and no log". With the summary counting the row without a time, "the
## summary names the wrong shots". With the length sentence not marked, "the cut
## did not finish: a length that is not whole samples". With Cut left enabled on
## a bad length, "Cut started a job on a bad length". With the open button not
## drawn after a cut, "the cut did not finish: Cut".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, shotlog, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  SegLen = 3000
  ItemName = "menu.Cut by shot log..."

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc hasMark(f: FrameInfo; name: string): bool =
  f.markOf(name).size.x > 0

proc makeRecording(path: string) =
  ## Two components, two source traces each of 3000 samples at 2 ms.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 .. 1:
    for comp in 0 .. 1:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = float32(100_000 * comp + seg * SegLen + j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(comp + 11)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000) + float64(seg * SegLen) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, samples)
  discard w.close()

proc writeLog(path: string): ShotLogMap =
  ## Three timed shots and one row without a time.
  var text = ""
  for (file, offsetUs) in [(101, 1_000_000'i64), (102, 2_000_000), (103, 4_000_000)]:
    text.add $file & "," & $(BaseUs + offsetUs) & "\n"
  text.add "104,\n"
  writeFile(path, text)
  result = initShotLogMap()
  result.hasHeader = false
  result.roles = @[crFileNumber, crUtcMicros]

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    createDir(fx.dir / "in")
    createDir(fx.dir / "out")
    let rec = fx.dir / "in" / "rec.sgy"
    makeRecording(rec)
    let logPath = fx.dir / "shots.csv"
    let map = writeLog(logPath)
    let dest = fx.dir / "out" / "rec_cut.sgd"
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkCutDest: @[fx.dir / "out"] else: @[]
    let opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      dialogs: hook)
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var clicks = 0
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc menuItem(f: FrameInfo) =
      ## The Project menu open, the item under the pointer (a click comes next).
      if not f.hasMark(ItemName): f.click(f.markOf("menu.Project").centre)
    proc summary(f: FrameInfo): string =
      let names = f.markNames("cut.summary ")
      if names.len > 0: names[0]["cut.summary ".len .. ^1] else: ""
    proc why(f: FrameInfo): string =
      let names = f.markNames("cut.why ")
      if names.len > 0: names[0]["cut.why ".len .. ^1] else: ""
    step("in the main window", proc (f: FrameInfo) = f.keepInMainWindow(),
      proc (f: FrameInfo): bool = true)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.hasMark(ItemName))
    proc noDialog(f: FrameInfo): bool =
      inc clicks
      doAssert not f.hasMark("cut"), "the dialog opened with no file and no log"
      clicks >= 5
    step("the item with no file and no log", proc (f: FrameInfo) =
      clicks = 0
      f.click(f.markOf(ItemName).centre), noDialog)
    proc showBoth(f: FrameInfo) =
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: rec)
      f.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    proc bothReady(f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.core.jobs.active.len == 0 and
        f.core.shownFile(f.core.findPanel(MainPanel)) >= 0
    step("a file and a log", showBoth, bothReady)
    proc openItem(f: FrameInfo): bool =
      if f.hasMark(ItemName) and not f.hasMark("cut"): f.click(f.markOf(ItemName).centre)
      f.hasMark("cut")
    step("the item opens the dialog", menuItem, openItem)
    proc summed(f: FrameInfo): bool =
      let s = f.summary
      if s.len == 0: return false
      doAssert f.hasMark("cut.format SEG-D Rev 3.on"), "the Format entry is not SEG-D Rev 3"
      doAssert s.startsWith("3 shots (1 row has no time and is left out), 2 components, " &
        "about "), "the summary names the wrong shots: " & s
      true
    step("the summary", proc (f: FrameInfo) = discard, summed)
    proc clickLength(f: FrameInfo) =
      clicks = 0
      f.click(f.markOf("cut.length").centre)
    proc badLength(f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("1001")
      clicks > 8 and "whole number of samples" in f.why
    step("a length that is not whole samples", clickLength, badLength)
    step("a folder", proc (f: FrameInfo) = f.click(f.markOf("cut.changeFolder").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.folder " & (fx.dir / "out")))
    proc clickCut(f: FrameInfo) =
      clicks = 0
      f.click(f.markOf("cut.run").centre)
    proc stillDim(f: FrameInfo): bool =
      inc clicks
      doAssert not f.core.cutRunning and f.core.cutOutcome.len == 0 and not fileExists(dest),
        "Cut started a job on a bad length"
      clicks >= 6
    step("Cut on a bad length", clickCut, stillDim)
    proc goodLength(f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("1000")
      clicks > 8 and f.why.len == 0 and f.summary.len > 0
    step("a good length", clickLength, goodLength)
    var shot = false
    proc picture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not shot:
        createDir(dir)
        doAssert f.savePng(dir / "cut-dialog.png"), "cannot save the dialog"
      shot = true
    step("the picture", picture, proc (f: FrameInfo): bool = true)
    step("Cut", proc (f: FrameInfo) = f.click(f.markOf("cut.run").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.open") and fileExists(dest))
    step("open the cut file", proc (f: FrameInfo) = f.click(f.markOf("cut.open").centre),
      proc (f: FrameInfo): bool =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      i >= 0 and f.core.sessions[i].path.endsWith("rec_cut.sgd"))
    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
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
        elif overdue(wait, 400, since):
          failed = steps[at].name & " (" & f.core.cutOutcome & ")"
          f.stop()
    var o = opts
    o.onFrame = onFrame
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, "the cut did not finish: " & failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

when isMainModule:
  main()
