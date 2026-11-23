## File > Output... in the running frontend, headless: the item is inactive until
## a folder is open; the window is a tab beside the Seismic window; a subfolder
## tick, None and All change the ticks; a destination inside the source is
## refused; a run writes the ticked files, the open file with a live kill
## dropped; Stop leaves the file in progress unfinished and skips the rest.
##
## Seen to fail: File column showing only the leaf, "the File column does not
## show sub/c.sgy: @[output.cell.file a.sgy, output.cell.file b.sgy,
## output.cell.file c.sgy]".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[edits, geometry, jobs, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

var holdFile2: Gate
var releaseFile2: Gate
var sawFile2: Gate

proc phaseHook(id: JobId; phase: string; back: bool) {.gcsafe, raises: [].} =
  if back: return
  if phase.len >= 6 and phase.startsWith("file 2") and holdFile2.isOpen:
    sawFile2.open()
    while holdFile2.isOpen and not releaseFile2.isOpen:
      sleep(10)

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc rowOf(f: FrameInfo; rel: string): tuple[ok: bool; outcome: string; written, dropped: int] =
  let prefix = "output.row " & rel & " "
  for name in f.markNames("output.row "):
    if not name.startsWith(prefix): continue
    let rest = name[prefix.len .. ^1].split(' ')
    if rest.len >= 3:
      return (true, rest[0], parseInt(rest[1]), parseInt(rest[2]))

proc refused(f: FrameInfo): bool =
  for name in f.markNames("output.refusal "):
    if "inside" in name: return f.markOf("output.run.disabled").size.x > 0

proc main*() =
  var wait = 0
  var since = getMonoTime()
  holdFile2.close()
  releaseFile2.close()
  sawFile2.close()
  setJobHook(phaseHook)
  try:
    withFixtures fx:
      let folder = fx.dir / "src"
      let sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shots.sgy"
      doAssert fileExists(sample), "missing " & sample
      createDir(folder / "sub")
      copyFile(sample, folder / "a.sgy")
      copyFile(sample, folder / "b.sgy")
      copyFile(sample, folder / "sub" / "c.sgy")
      let written = fx.dir / "written"
      let stopped = fx.dir / "stopped"
      let shots = currentSourcePath().parentDir.parentDir / ".scratch" / "shots"
      createDir(shots)
      createDir(fx.dir / "cache")
      createDir(fx.dir / "config")
      createDir(fx.dir / "logs")

      var answer: seq[string] = @[]
      let hook = proc (kind: DialogKind; location: string): seq[string] = answer

      var steps: seq[Step]
      proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
        steps.add Step(name: name, act: act, done: done)
      proc noop(f: FrameInfo) = discard

      step("the window is up", noop, proc (f: FrameInfo): bool =
        result = wait > 4
        if result: doAssert awOutput in f.hiddenWindows, $f.hiddenWindows)
      proc inactive(f: FrameInfo) = f.click(f.markOf("menu.File").centre)
      proc inactiveDone(f: FrameInfo): bool =
        f.markOf("menu.Output...").size.x > 0 and f.markOf("menu.Output.disabled").size.x > 0
      step("File > Output... is inactive without a folder", inactive, inactiveDone)

      proc browse(f: FrameInfo) =
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false)
        f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
      proc listed(f: FrameInfo): bool =
        not f.core.fileList.scanning and f.core.fileList.folder.len > 0
      step("the folder is listed", browse, listed)

      proc showA(f: FrameInfo) =
        f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "a.sgy")
      proc shown(f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        i >= 0 and f.core.sessions[i].path.endsWith("a.sgy")
      step("a.sgy is shown", showA, shown)

      proc kill(f: FrameInfo) =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        doAssert i >= 0
        f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
          edited: @[f.core.sessions[i].base], on: true)
      proc killed(f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        if i < 0: return false
        let path = $(f.core.sessions[i].path)
        0 in f.core.editsAt(path).shown.lists[teKilled]
      step("trace 0 of a.sgy is killed", kill, killed)

      var opened = false
      proc openOutput(f: FrameInfo) =
        if f.markOf("menu.Output...").size.x == 0: f.click(f.markOf("menu.File").centre)
      proc outputReady(f: FrameInfo): bool =
        if not opened:
          let it = f.markOf("menu.Output...")
          if it.size.x > 0 and f.markOf("menu.Output.disabled").size.x == 0:
            f.click(it.centre)
            opened = true
        result = f.markOf("output.ready").size.x > 0 and
          f.markOf("output.file a.sgy on").size.x > 0 and
          f.markOf("output.file sub/c.sgy off").size.x > 0 and
          f.markOf("output.folder sub off").size.x > 0
        if result:
          let (o, p) = (f.windowPlace("output"), f.windowPlace("plot"))
          doAssert o.inSight and o.docked and not o.apart, "not in the centre dock: " & $o
          doAssert abs(o.rect.pos.x - p.rect.pos.x) <= 2 and abs(o.rect.pos.y - p.rect.pos.y) <=
              2 and
            abs(o.rect.size.x - p.rect.size.x) <= 2 and abs(o.rect.size.y - p.rect.size.y) <= 2,
            "not a tab beside the Seismic window: " & $o.rect & " plot " & $p.rect
      step("File > Output...", openOutput, outputReady)

      proc tickSub(f: FrameInfo) = f.click(f.markOf("output.folder sub off").centre)
      proc subOn(f: FrameInfo): bool =
        f.markOf("output.folder sub on").size.x > 0 and
          f.markOf("output.file sub/c.sgy on").size.x > 0
      step("a folder tick selects its file", tickSub, subOn)

      proc none(f: FrameInfo) = f.click(f.markOf("output.none").centre)
      proc allOff(f: FrameInfo): bool =
        f.markOf("output.file a.sgy off").size.x > 0 and
          f.markOf("output.file b.sgy off").size.x > 0 and
          f.markOf("output.file sub/c.sgy off").size.x > 0
      step("None clears every file", none, allOff)

      proc all(f: FrameInfo) = f.click(f.markOf("output.all").centre)
      proc allOn(f: FrameInfo): bool =
        result = f.markOf("output.file a.sgy on").size.x > 0 and
          f.markOf("output.file b.sgy on").size.x > 0 and
          f.markOf("output.file sub/c.sgy on").size.x > 0
        if result:
          f.keepInMainWindow()
          doAssert f.savePng(shots / "output-before-run.png"), "before-run shot was not written"
      step("All ticks every file", all, allOn)

      proc badDest(f: FrameInfo) =
        answer = @[folder / "inside"]
        f.click(f.markOf("output.changeDest").centre)
      step("a destination inside the source is refused", badDest, refused)

      proc goodDest(f: FrameInfo) =
        answer = @[written]
        f.click(f.markOf("output.changeDest").centre)
      proc canRun(f: FrameInfo): bool =
        f.markOf("output.run").size.x > 0 and f.markOf("output.run.disabled").size.x == 0
      step("a destination outside the source can run", goodDest, canRun)

      proc run(f: FrameInfo) = f.click(f.markOf("output.run").centre)
      proc wrote(f: FrameInfo): bool =
        let a = rowOf(f, "a.sgy")
        let b = rowOf(f, "b.sgy")
        let c = rowOf(f, "sub/c.sgy")
        if a.ok and c.ok and f.markOf("output.cell.file sub/c.sgy").size.x == 0:
          doAssert false, "the File column does not show sub/c.sgy: " &
            $f.markNames("output.cell.file")
        result = a.ok and b.ok and c.ok and a.outcome == "written" and b.outcome == "written" and
          c.outcome == "written" and a.dropped >= 1 and
          fileExists(written / "a.sgy") and fileExists(written / "b.sgy") and
          fileExists(written / "sub" / "c.sgy") and
          f.markOf("output.cell.file sub/c.sgy").size.x > 0
        if result:
          doAssert f.savePng(shots / "output-after-run.png"), "after-run shot was not written"
      step("Run writes the three files", run, wrote)

      proc armStop(f: FrameInfo) =
        holdFile2.open()
        releaseFile2.close()
        sawFile2.close()
        answer = @[stopped]
        f.click(f.markOf("output.changeDest").centre)
      proc armed(f: FrameInfo): bool =
        f.markOf("output.destination " & stopped).size.x > 0 and
          f.markOf("output.run").size.x > 0
      step("the stop run has its own destination", armStop, armed)

      var stopping = false
      var stopFrame = -1
      proc startStop(f: FrameInfo) = f.click(f.markOf("output.run").centre)
      proc stoppedRun(f: FrameInfo): bool =
        if not stopping and sawFile2.isOpen:
          let stop = f.markOf("output.stop")
          if stop.size.x > 0:
            f.click(stop.centre)
            stopping = true
            stopFrame = f.index
        if stopping and f.index > stopFrame + 6: releaseFile2.open()
        let a = rowOf(f, "a.sgy")
        let b = rowOf(f, "b.sgy")
        let c = rowOf(f, "sub/c.sgy")
        releaseFile2.isOpen and a.ok and a.outcome == "written" and
          fileExists(stopped / "a.sgy") and b.ok and b.outcome == "skipped" and
          c.ok and c.outcome == "skipped" and not fileExists(stopped / "b.sgy") and
          not fileExists(stopped / "sub" / "c.sgy")
      step("Stop skips the files not started", startStop, stoppedRun)

      var at = 0
      var started = false
      var failed = ""
      proc onFrame(f: FrameInfo) =
        if f.index == 0: f.moveMouse(vec2(4, 4))
        if at >= steps.len or failed.len > 0:
          f.stop()
          return
        if not started:
          steps[at].act(f)
          started = true
          wait = 0
          since = getMonoTime()
        else:
          inc wait
          if wait >= 3 and steps[at].done(f):
            inc at
            started = false
          elif overdue(wait, 800, since):
            failed = steps[at].name & " did not happen"
            f.stop()
      let code = run(RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
        configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
        indexCacheDir: some(fx.dir / "cache"),
        userThemeDir: some(fx.dir / "no-user-themes"),
        assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
        dialogs: hook, onFrame: onFrame))
      doAssert code == 0, "run() exit code " & $code
      doAssert failed.len == 0, failed
      doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
      echo "tguioutput: ", steps.len, " steps"
  finally:
    releaseFile2.open()
    holdFile2.close()
    sleep(50)
    setJobHook(nil)

when isMainModule:
  main()
