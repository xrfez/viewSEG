## The Output window's "Export log..." button, headless, in the running frontend.
## Before a run it is dim. After a run of three files with Processing ticked, it
## writes a text file holding the run's time, source, destination, options and
## totals, and for every file its row and all its notes, in file order. A run
## stopped after its first file exports that file written and the rest skipped.
## An export to a folder that does not exist fails as a job, which Messages
## says, and leaves no half-written file.
##
## An export that would add .txt over an existing file, or write over a file the run
## read, is refused and leaves that file as it was.
##
## Seen to fail: with the existing-file check removed, run1.txt was replaced; with the dim mark always "enabled", "Output is open, Export log dim
## did not happen". The notes and the skipped rows are seen to fail in toutputlog.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## With VIEWSEG_SCREENSHOTS set, the results with the button are saved as PNG.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, jobs, log, processing, state]
import viewSEG/view/outputwords
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo): bool
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

proc clickWhen(f: FrameInfo; name: string): bool =
  let r = f.markOf(name)
  if r.size.x <= 0: return false
  f.click(r.centre)
  true

proc reveal(f: FrameInfo; name: string): bool =
  let r = f.markOf(name)
  let pane = f.markOf("output.pane.right")
  if r.size.x > 0 and pane.size.y > 0 and r.pos.y >= pane.pos.y + 2 and
      r.pos.y + r.size.y <= pane.pos.y + pane.size.y - 2: return true
  if pane.size.y > 0: f.scrollWheel(pane.centre, if r.pos.y > pane.pos.y: -2 else: 2)
  false

proc hasPrefix(f: FrameInfo; prefix: string): bool =
  for name in f.markNames(prefix):
    if name.startsWith(prefix): return true

proc rowOf(f: FrameInfo; rel: string): tuple[ok: bool; outcome: string] =
  let prefix = "output.row " & rel & " "
  for name in f.markNames("output.row "):
    if name.startsWith(prefix):
      return (true, name[prefix.len .. ^1].split(' ')[0])

proc said(f: FrameInfo; text: string): bool =
  for e in f.core.log:
    if text in e.text: return true

proc main*() =
  var wait = 0
  var since = getMonoTime()
  holdFile2.close()
  releaseFile2.close()
  sawFile2.close()
  setJobHook(phaseHook)
  try:
    withFixtures fx:
      let field = fx.dir / "data"
      let wrote1 = fx.dir / "written"
      let wrote2 = fx.dir / "stopped"
      let log1 = fx.dir / "logs-out" / "run1.txt"
      let log2 = fx.dir / "logs-out" / "run2.txt"
      let log3 = fx.dir / "no such folder" / "run3.txt"
      for d in [field / "sub", wrote1, wrote2, fx.dir / "logs-out", fx.dir / "config",
          fx.dir / "logs", fx.dir / "cache"]:
        createDir(d)
      for rel in ["a.sgy", "b.sgy", "sub" / "c.sgy"]: copyFile(fx.surveySegy(), field / rel)
      let shotsDir = getEnv("VIEWSEG_SCREENSHOTS")
      var answer: seq[string] = @[]
      let hook = proc (kind: DialogKind; location: string): seq[string] = answer
      var steps: seq[Step]
      proc step(name: string; act: proc (f: FrameInfo): bool; done: proc (f: FrameInfo): bool) =
        steps.add Step(name: name, act: act, done: done)
      proc noop(f: FrameInfo): bool = true

      proc browse(f: FrameInfo): bool =
        f.apply Command(kind: ckBrowse, paths: @[field], showFirst: true)
        true
      proc listed(f: FrameInfo): bool =
        not f.core.fileList.scanning and f.core.fileList.folder.len > 0 and
          f.core.shownFile(f.core.findPanel(MainPanel)) >= 0
      step("the folder is listed and a file shown", browse, listed)

      proc band(f: FrameInfo): bool =
        f.apply Command(kind: ckProcessing, panel: MainPanel,
          processing: bounded(Processing(band: pbBandPass, f1: 5, f2: 10, f3: 40, f4: 60)))
        true
      proc banded(f: FrameInfo): bool =
        f.core.panels[f.core.findPanel(MainPanel)].layers[0].processing.band == pbBandPass
      step("the plot has a band-pass", band, banded)

      var opened = false
      proc openOutput(f: FrameInfo): bool =
        if opened: return true
        let it = f.markOf("menu.Output...")
        if it.size.x == 0 or f.markOf("menu.Output.disabled").size.x > 0:
          discard clickWhen(f, "menu.File")
          return false
        f.click(it.centre)
        opened = true
        true
      proc outputUp(f: FrameInfo): bool =
        if f.markOf("output.exportLog.dim").size.x == 0: return false
        doAssert f.markOf("output.exportLog").size.x == 0, "Export log is not dim before a run"
        true
      step("Output is open, Export log dim", openOutput, outputUp)

      proc tickAll(f: FrameInfo): bool = clickWhen(f, "output.all")
      proc ticked(f: FrameInfo): bool =
        f.markOf("output.file b.sgy on").size.x > 0 and
          f.markOf("output.file sub/c.sgy on").size.x > 0
      step("the files are ticked", tickAll, ticked)

      proc tickProcessing(f: FrameInfo): bool =
        if not reveal(f, "output.processing.tick"): return false
        clickWhen(f, "output.processing.tick")
      proc processingOn(f: FrameInfo): bool = f.markOf("output.processing on").size.x > 0
      step("Processing is ticked", tickProcessing, processingOn)

      proc setDest(dest: string): proc (f: FrameInfo): bool =
        result = proc (f: FrameInfo): bool =
          answer = @[dest]
          if not reveal(f, "output.changeDest"): return false
          clickWhen(f, "output.changeDest")
      proc destIs(dest: string): proc (f: FrameInfo): bool =
        result = proc (f: FrameInfo): bool =
          f.markOf("output.destination " & dest).size.x > 0 and
            f.markOf("output.run").size.x > 0
      step("the destination is set", setDest(wrote1), destIs(wrote1))

      proc run(f: FrameInfo): bool =
        if not reveal(f, "output.run"): return false
        clickWhen(f, "output.run")
      proc wrote(f: FrameInfo): bool =
        f.markOf("output.summary 3 0 0").size.x > 0 and f.markOf("output.exportLog").size.x > 0
      step("Run writes the three files", run, wrote)

      proc shot(f: FrameInfo): bool =
        if not reveal(f, "output.exportLog"): return false
        if shotsDir.len > 0:
          createDir(shotsDir)
          doAssert f.savePng(shotsDir / "output-export-log.png"), "cannot save the picture"
        true
      step("Export log is enabled after the run", noop, shot)

      proc exportTo(path: string): proc (f: FrameInfo): bool =
        result = proc (f: FrameInfo): bool =
          answer = @[path]
          if not reveal(f, "output.exportLog"): return false
          clickWhen(f, "output.exportLog")
      proc fileDone(path: string): proc (f: FrameInfo): bool =
        result = proc (f: FrameInfo): bool = fileExists(path)
      step("the log is exported", exportTo(log1), fileDone(log1))

      step("the stop run has its own destination", proc (f: FrameInfo): bool =
        holdFile2.open()
        releaseFile2.close()
        sawFile2.close()
        setDest(wrote2)(f), destIs(wrote2))

      var stopping = false
      var asked = false
      var released = false
      var writingWait = 0
      proc stoppedRun(f: FrameInfo): bool =
        if not stopping and sawFile2.isOpen and f.markOf("output.stop").size.x > 0:
          if hasPrefix(f, "output.state Writing file 2") and clickWhen(f, "output.stop"):
            stopping = true
          else:
            inc writingWait
            if writingWait > 40:
              doAssert false, "no writing line: " & $f.markNames("output.state")
        if stopping and not asked and f.markOf("output.cancelAsked").size.x > 0:
          asked = true
        elif asked and not released:
          releaseFile2.open()
          released = true
        let a = rowOf(f, "a.sgy")
        let b = rowOf(f, "b.sgy")
        released and a.ok and a.outcome == "written" and b.ok and b.outcome == "skipped" and
          f.markOf("output.state Stopped.").size.x > 0 and
          f.markOf("output.exportLog").size.x > 0
      step("Stop skips the files not started", run, stoppedRun)

      step("the stopped run's log is exported", exportTo(log2), fileDone(log2))

      proc failedExport(f: FrameInfo): bool =
        said(f, ExportFailed)
      step("an export to a missing folder fails and says so", exportTo(log3), failedExport)

      # "run1" gets ".txt" added and run1.txt is there: refused, and left as it was
      var beforeOne = ""
      let sourceFile = field / "a.sgy"
      let beforeSource = readFile(sourceFile)
      let addTxt = exportTo(fx.dir / "logs-out" / "run1")
      step("an export over an existing file with .txt added is refused",
        proc (f: FrameInfo): bool =
        if beforeOne.len == 0: beforeOne = readFile(log1)
        addTxt(f), proc (f: FrameInfo): bool = said(f, ExportExists))
      step("an export over a file the run read is refused", exportTo(sourceFile),
        proc (f: FrameInfo): bool = said(f, ExportIsData))

      var at = 0
      var started = false
      var failed = ""
      proc onFrame(f: FrameInfo) =
        if f.index == 0: f.moveMouse(vec2(4, 4))
        if at >= steps.len or failed.len > 0:
          f.stop()
          return
        if not started:
          if steps[at].act(f):
            started = true
            wait = 0
            since = getMonoTime()
          elif overdue(wait, 800, since):
            failed = steps[at].name & " did not happen"
            f.stop()
          else:
            inc wait
        else:
          inc wait
          if wait >= 3 and steps[at].done(f):
            inc at
            started = false
            wait = 0
            since = getMonoTime()
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
      let one = readFile(log1)
      for want in ["viewSEG output log\nRun: 20", "\nSource: " & field & "\n",
          "\nDestination: " & wrote1 & "\n", "\nFormat: SEG-Y\n", "\nProcessing: on (" &
          "The written traces will be filtered: band-pass 5-10-40-60 Hz.)\n",
          "\n3 written, 0 failed, 0 skipped.\n", "\n    - no saved edits were found for " &
          "this file\n", "\n    - The batch wrote the file's own positions.\n"]:
        doAssert want in one, "the log lacks " & want.escape & ":\n" & one
      doAssert one.count("    - The written traces will be filtered") == 3, one
      doAssert one.count("    - ") == 7, "a note is missing: " & one
      doAssert one.count("(185360 bytes)") == 3, one
      let places = [one.find("File: a.sgy"), one.find("File: b.sgy"),
        one.find("File: sub/c.sgy")]
      doAssert places[0] >= 0 and places[0] < places[1] and places[1] < places[2],
        "the files are not in order"
      let two = readFile(log2)
      doAssert "\n1 written, 0 failed, 2 skipped.\n" in two, two
      doAssert "\nThe run was stopped before every file was written.\n" in two, two
      doAssert two.count("  Result: skipped") == 2 and two.count("  Result: written") == 1, two
      doAssert not dirExists(fx.dir / "no such folder")
      for p in walkDirRec(fx.dir / "logs-out"): doAssert not p.endsWith(".tmp"), p
      doAssert readFile(log1) == beforeOne, "run1.txt was replaced"
      doAssert readFile(sourceFile) == beforeSource, "a source file was replaced by the log"
      echo "tguioutputlog: ", steps.len, " steps"
  finally:
    releaseFile2.open()
    holdFile2.close()
    sleep(50)
    setJobHook(nil)

when isMainModule:
  main()
