## Project > Cut by shot log on a file that is not a continuous recording,
## headless, driven by real clicks: a shot record (four receivers, one trace
## each) is read by a job, the dialog says why it is refused above the buttons
## and Cut stays dim, whatever is clicked.
##
## Seen to fail: with the refusal left out of the dialog's problem, "the dialog
## gave no reason"; with Cut enabled on a refusal, "Cut started on a shot record".
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

proc makeShotRecord(path: string) =
  ## Four receivers, one trace of 2000 samples at 2 ms each.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for rcv in 0 .. 3:
    var samples = newSeq[float32](2000)
    for j in 0 ..< 2000: samples[j] = float32(rcv * 2000 + j)
    var k = initTraceKeys()
    k.status = tsLive
    k.record = 1
    k.channel = float64(rcv + 1)
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = float64(BaseUs div 1_000_000)
    k.rcvLine = 1
    k.rcvPoint = float64(rcv + 1)
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
    let rec = fx.dir / "in" / "record.sgy"
    makeShotRecord(rec)
    let logPath = fx.dir / "shots.csv"
    let map = writeLog(logPath)
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
    proc why(f: FrameInfo): string =
      let names = f.markNames("cut.why ")
      if names.len > 0: names[0]["cut.why ".len .. ^1] else: ""
    step("in the main window", proc (f: FrameInfo) = f.keepInMainWindow(),
      proc (f: FrameInfo): bool = true)
    proc showBoth(f: FrameInfo) =
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: rec)
      f.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    proc bothReady(f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.core.jobs.active.len == 0 and
        f.core.shownFile(f.core.findPanel(MainPanel)) >= 0
    step("a file and a log", showBoth, bothReady)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.hasMark(ItemName))
    proc openItem(f: FrameInfo): bool =
      if f.hasMark(ItemName) and not f.hasMark("cut"): f.click(f.markOf(ItemName).centre)
      f.hasMark("cut")
    step("the item opens the dialog", proc (f: FrameInfo) = discard, openItem)
    proc refused(f: FrameInfo): bool =
      f.why.startsWith("This file is a shot record (every receiver has one trace)")
    step("the reason", proc (f: FrameInfo) = discard, refused)
    step("a folder", proc (f: FrameInfo) = f.click(f.markOf("cut.changeFolder").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.folder " & (fx.dir / "out")))
    var shot = false
    proc picture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not shot:
        createDir(dir)
        doAssert f.savePng(dir / "cut-dialog-refused.png"), "cannot save the dialog"
      shot = true
      clicks = 0
      f.click(f.markOf("cut.run").centre)
    proc stillDim(f: FrameInfo): bool =
      inc clicks
      doAssert not f.core.cutRunning and f.core.cutOutcome.len == 0,
        "Cut started on a shot record"
      doAssert f.why.len > 0, "the dialog gave no reason"
      clicks >= 6
    step("Cut on a shot record", picture, stillDim)
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
          failed = steps[at].name
          f.stop()
    var o = opts
    o.onFrame = onFrame
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, "the dialog did not get to: " & failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

when isMainModule:
  main()
