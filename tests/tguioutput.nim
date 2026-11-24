## File > Output... in the running frontend, headless: the item is inactive until
## a folder is open; the window is a tab beside the Seismic window; a subfolder
## tick, None and All change the ticks; a destination inside the source is
## refused; a run writes the ticked files, the open file with a live kill
## dropped; Stop leaves the file in progress unfinished and skips the rest.
##
## Seen to fail: File column showing only the leaf, "the File column does not
## show sub/c.sgy: @[output.cell.file a.sgy, output.cell.file b.sgy,
## output.cell.file c.sgy]". Panes forced to stack: "panes are not side by
## side: @[] @[output.stacked]". Panes forced to stay beside: "panes did not
## stack in a narrow window". State line missing while writing: "no writing
## line: @[]". Folder count missing: "no folder count: @[]". Tally missing:
## "no tally: @[]". Run with no sentence: "Run says nothing: @[]".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
##
## A second run builds a three-part file-name pattern in the editor, saves it,
## chooses it from the drop-down, writes one sample file under that name, then
## with "As the source file" writes the source's name, and deletes the pattern.
## Seen to fail: with the source line placeholder 11, "the preview is not
## 00012.1034p5.file.sgd". With the chosen pattern left off the batch, the
## write step said the file was still vib_uncorrelated.sgd, not
## 02001.103.vib_uncorrelated.sgd. With the tally suffix removed, "the tally
## does not name the pattern".

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[edits, geometry, jobs, outputnamevalues, sigtypes, state]
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

proc inRightPane(f: FrameInfo; r: Rect): bool =
  let pane = f.markOf("output.pane.right")
  r.size.x > 0 and pane.size.y > 0 and r.pos.y >= pane.pos.y + 2 and
    r.pos.y + r.size.y <= pane.pos.y + pane.size.y - 2

proc reveal(f: FrameInfo; name: string): bool =
  ## Scrolls the write pane until `name` is inside it. True once it is.
  let r = f.markOf(name)
  if r.size.x <= 0 or f.inRightPane(r): return r.size.x > 0
  let pane = f.markOf("output.pane.right")
  f.scrollWheel(pane.centre, if r.pos.y > pane.pos.y: -2 else: 2)
  false

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

proc beside(f: FrameInfo): bool =
  let l = f.markOf("output.pane.left")
  let r = f.markOf("output.pane.right")
  f.markOf("output.beside").size.x > 0 and l.size.x > 0 and r.size.x > 0 and
    abs(l.pos.y - r.pos.y) <= 4 and abs(l.size.y - r.size.y) <= 4 and
    l.pos.x + l.size.x <= r.pos.x + 8

proc hasPrefix(f: FrameInfo; prefix: string): bool =
  for name in f.markNames(prefix):
    if name.startsWith(prefix): return true

proc tallyHas(f: FrameInfo; text: string): bool =
  for name in f.markNames("output.tally "):
    if text in name: return true

proc renderedName(path: string): string =
  ## The leaf the editor's three-part pattern writes for `path` as SEG-D.
  var seismic = openSeismic(path, keys = true)
  let values = nameValuesOf(seismic, path, SignatureFacts(), FileEdits(), true, nil)
  seismic.close()
  let pattern = OutputPattern(name: "Line", separator: nsDot, parts: @[
    NamePart(kind: npSrcLine, pad: 5),
    NamePart(kind: npSrcPoint),
    NamePart(kind: npStem)])
  let named = render(pattern, values, ".sgd")
  doAssert named.problem.len == 0, named.problem
  doAssert named.name != "vib_uncorrelated.sgd", named.name
  named.name

proc stacked(f: FrameInfo): bool =
  let l = f.markOf("output.pane.left")
  let r = f.markOf("output.pane.right")
  f.markOf("output.stacked").size.x > 0 and l.size.y > 0 and r.size.y > 0 and
    l.pos.y + l.size.y <= r.pos.y + 8 and abs(l.pos.x - r.pos.x) <= 4

proc namePatterns()

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
      proc step(name: string; act: proc (f: FrameInfo): bool; done: proc (f: FrameInfo): bool) =
        steps.add Step(name: name, act: act, done: done)
      proc noop(f: FrameInfo): bool = true

      step("the window is up", noop, proc (f: FrameInfo): bool =
        result = wait > 4
        if result: doAssert awOutput in f.hiddenWindows, $f.hiddenWindows)
      proc inactive(f: FrameInfo): bool = clickWhen(f, "menu.File")
      proc inactiveDone(f: FrameInfo): bool =
        f.markOf("menu.Output...").size.x > 0 and f.markOf("menu.Output.disabled").size.x > 0
      step("File > Output... is inactive without a folder", inactive, inactiveDone)

      proc browse(f: FrameInfo): bool =
        f.pressKey(skEscape, true)
        f.pressKey(skEscape, false)
        f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
        true
      proc listed(f: FrameInfo): bool =
        not f.core.fileList.scanning and f.core.fileList.folder.len > 0
      step("the folder is listed", browse, listed)

      proc showA(f: FrameInfo): bool =
        f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "a.sgy")
        true
      proc shown(f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        i >= 0 and f.core.sessions[i].path.endsWith("a.sgy")
      step("a.sgy is shown", showA, shown)

      proc kill(f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        if i < 0: return false
        f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
          edited: @[f.core.sessions[i].base], on: true)
        true
      proc killed(f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        if i < 0: return false
        let path = $(f.core.sessions[i].path)
        0 in f.core.editsAt(path).shown.lists[teKilled]
      step("trace 0 of a.sgy is killed", kill, killed)

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
      proc outputReady(f: FrameInfo): bool =
        if f.markOf("output.ready").size.x > 0 and
            f.markOf("output.file a.sgy on").size.x > 0 and not beside(f):
          doAssert false, "panes are not side by side: " & $f.markNames("output.beside") &
            " " & $f.markNames("output.stacked")
        if f.markOf("output.folder sub off").size.x > 0 and
            f.markOf("output.foldercount sub 0 1").size.x == 0:
          doAssert false, "no folder count: " & $f.markNames("output.foldercount")
        if f.markOf("output.file a.sgy on").size.x > 0 and not hasPrefix(f, "output.tally "):
          doAssert false, "no tally: " & $f.markNames("output.tally")
        if f.markOf("output.file a.sgy on").size.x > 0 and
            f.markOf("output.run.disabled").size.x > 0 and
            not hasPrefix(f, "output.run.why "):
          doAssert false, "Run says nothing: " & $f.markNames("output.run.why")
        result = f.markOf("output.ready").size.x > 0 and
          f.markOf("output.file a.sgy on").size.x > 0 and
          f.markOf("output.file sub/c.sgy off").size.x > 0 and
          f.markOf("output.folder sub off").size.x > 0 and beside(f) and
          f.markOf("output.foldercount sub 0 1").size.x > 0 and
          hasPrefix(f, "output.tally 1 file ticked, ") and
          f.markOf("output.run.why Choose a destination folder.").size.x > 0
        if result:
          let (o, p) = (f.windowPlace("output"), f.windowPlace("plot"))
          doAssert o.inSight and o.docked and not o.apart, "not in the centre dock: " & $o
          doAssert abs(o.rect.pos.x - p.rect.pos.x) <= 2 and abs(o.rect.pos.y - p.rect.pos.y) <=
              2 and
            abs(o.rect.size.x - p.rect.size.x) <= 2 and abs(o.rect.size.y - p.rect.size.y) <= 2,
            "not a tab beside the Seismic window: " & $o.rect & " plot " & $p.rect
      step("File > Output...", openOutput, outputReady)

      proc tickSub(f: FrameInfo): bool = clickWhen(f, "output.folder sub off")
      proc subOn(f: FrameInfo): bool =
        f.markOf("output.folder sub on").size.x > 0 and
          f.markOf("output.file sub/c.sgy on").size.x > 0 and
          f.markOf("output.foldercount sub 1 1").size.x > 0
      step("a folder tick selects its file", tickSub, subOn)

      proc none(f: FrameInfo): bool = clickWhen(f, "output.none")
      proc allOff(f: FrameInfo): bool =
        f.markOf("output.file a.sgy off").size.x > 0 and
          f.markOf("output.file b.sgy off").size.x > 0 and
          f.markOf("output.file sub/c.sgy off").size.x > 0 and
          hasPrefix(f, "output.tally 0 files ticked, ") and
          f.markOf("output.run.why Tick at least one file. Choose a destination folder.").size.x > 0
      step("None clears every file", none, allOff)

      proc all(f: FrameInfo): bool = clickWhen(f, "output.all")
      proc allOn(f: FrameInfo): bool =
        result = f.markOf("output.file a.sgy on").size.x > 0 and
          f.markOf("output.file b.sgy on").size.x > 0 and
          f.markOf("output.file sub/c.sgy on").size.x > 0 and
          f.markOf("output.foldercount sub 1 1").size.x > 0 and
          hasPrefix(f, "output.tally 3 files ticked, ")
        if result:
          f.keepInMainWindow()
          doAssert f.savePng(shots / "output-before-run.png"), "before-run shot was not written"
      step("All ticks every file", all, allOn)

      proc badDest(f: FrameInfo): bool =
        answer = @[folder / "inside"]
        clickWhen(f, "output.changeDest")
      step("a destination inside the source is refused", badDest, refused)

      proc goodDest(f: FrameInfo): bool =
        answer = @[written]
        clickWhen(f, "output.changeDest")
      proc canRun(f: FrameInfo): bool =
        f.markOf("output.run").size.x > 0 and f.markOf("output.run.disabled").size.x == 0 and
          f.markOf("output.run.why Choose a destination folder.").size.x == 0
      step("a destination outside the source can run", goodDest, canRun)

      proc run(f: FrameInfo): bool = clickWhen(f, "output.run")
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
          f.markOf("output.cell.file sub/c.sgy").size.x > 0 and
          f.markOf("output.summary 3 0 0").size.x > 0 and
          not hasPrefix(f, "output.state ")
        if result:
          doAssert f.savePng(shots / "output-after-run.png"), "after-run shot was not written"
      step("Run writes the three files", run, wrote)

      proc narrow(f: FrameInfo): bool =
        f.resizeWindow(800, 1080)
        true
      proc stackedDone(f: FrameInfo): bool =
        if f.mainWindowRect().size.x < 900 and f.markOf("output.beside").size.x > 0:
          doAssert false, "panes did not stack in a narrow window"
        stacked(f)
      step("a narrow window stacks the panes", narrow, stackedDone)

      proc wide(f: FrameInfo): bool =
        f.resizeWindow(1920, 1080)
        true
      step("a wide window puts the panes side by side", wide, beside)

      proc armStop(f: FrameInfo): bool =
        holdFile2.open()
        releaseFile2.close()
        sawFile2.close()
        answer = @[stopped]
        clickWhen(f, "output.changeDest")
      proc armed(f: FrameInfo): bool =
        f.markOf("output.destination " & stopped).size.x > 0 and
          f.markOf("output.run").size.x > 0
      step("the stop run has its own destination", armStop, armed)

      var stopping = false
      var asked = false
      var released = false
      var writingWait = 0
      proc startStop(f: FrameInfo): bool = clickWhen(f, "output.run")
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
        let c = rowOf(f, "sub/c.sgy")
        released and a.ok and a.outcome == "written" and
          fileExists(stopped / "a.sgy") and b.ok and b.outcome == "skipped" and
          c.ok and c.outcome == "skipped" and not fileExists(stopped / "b.sgy") and
          not fileExists(stopped / "sub" / "c.sgy") and
          f.markOf("output.state Stopped.").size.x > 0
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
      echo "tguioutput: ", steps.len, " steps"
  finally:
    releaseFile2.open()
    holdFile2.close()
    sleep(50)
    setJobHook(nil)
  namePatterns()

proc namePatterns() =
  ## The editor, on its own project: three parts, a padded preview, save,
  ## choose, then a batch that writes the rendered name and, with "As the
  ## source file", the source name. Then the pattern is deleted.
  setJobHook(nil)
  withFixtures fx:
    let field = fx.dir / "data"
    let job = fx.dir / "job"
    let sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
      "vib_uncorrelated.sgd"
    doAssert fileExists(sample), "missing " & sample
    createDir(field)
    copyFile(sample, field / "vib_uncorrelated.sgd")
    writeFile(field / "note.txt", "x")
    let wantName = renderedName(field / "vib_uncorrelated.sgd")
    let namedDest = fx.dir / "named"
    let plainDest = fx.dir / "plain"
    createDir(namedDest)
    createDir(plainDest)
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    createDir(fx.dir / "cache")
    let shot = currentSourcePath().parentDir.parentDir / ".scratch" / "output-names.png"
    createDir(shot.parentDir)
    var answer: seq[string] = @[]
    let hook = proc (kind: DialogKind; location: string): seq[string] = answer
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    proc step(name: string; act: proc (f: FrameInfo): bool; done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo): bool = true

    proc browse(f: FrameInfo): bool =
      f.apply Command(kind: ckBrowse, paths: @[field], showFirst: false)
      true
    proc listed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("the folder is listed", browse, listed)

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
      f.markOf("output.names.edit").size.x > 0
    step("Output is open", openOutput, outputUp)

    proc makeProject(f: FrameInfo): bool =
      f.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      true
    proc made(f: FrameInfo): bool =
      f.core.inProject and f.core.projectOpening.len == 0 and not f.core.project.readOnly
    step("a project is open", makeProject, made)

    proc edit(f: FrameInfo): bool = clickWhen(f, "output.names.edit")
    proc editing(f: FrameInfo): bool = f.markOf("output.editor").size.x > 0
    step("the editor is open", edit, editing)

    proc focusLabel(f: FrameInfo): bool = clickWhen(f, "output.pattern.label")
    proc labelReady(f: FrameInfo): bool = f.typing
    step("the label box has the keyboard", focusLabel, labelReady)

    proc typeLabel(f: FrameInfo): bool =
      doAssert f.typing, "the label box does not take the keys"
      f.pressKey(skCtrl, true, {smCtrl})
      f.typeText("a")
      f.pressKey(skCtrl, false)
      f.typeText("Line")
      f.pressKey(skEnter, true)
      f.pressKey(skEnter, false)
      true
    proc labeled(f: FrameInfo): bool =
      f.markOf("output.pattern.label Line").size.x > 0
    step("the label is Line", typeLabel, labeled)

    proc openKind(f: FrameInfo): bool =
      if f.markOf("output.part 0.item Source line").size.x > 0: return true
      discard clickWhen(f, "output.part 0.kind")
      false
    proc kindOpen(f: FrameInfo): bool =
      f.markOf("output.part 0.item Source line").size.x > 0
    step("the first part's kinds are open", openKind, kindOpen)

    proc pickLine(f: FrameInfo): bool = clickWhen(f, "output.part 0.item Source line")
    proc linePicked(f: FrameInfo): bool =
      f.markOf("output.part 0.width").size.x > 0
    step("the first part is a source line", pickLine, linePicked)

    proc focusWidth(f: FrameInfo): bool = clickWhen(f, "output.part 0.width")
    proc widthReady(f: FrameInfo): bool = f.typing
    step("the width box has the keyboard", focusWidth, widthReady)

    proc typeWidth(f: FrameInfo): bool =
      doAssert f.typing, "the width box does not take the keys"
      f.pressKey(skCtrl, true, {smCtrl})
      f.typeText("a")
      f.pressKey(skCtrl, false)
      f.typeText("5")
      f.pressKey(skEnter, true)
      f.pressKey(skEnter, false)
      true
    step("the width is 5", typeWidth, noop)

    proc addSecond(f: FrameInfo): bool =
      if f.markOf("output.part 1.kind").size.x > 0: return true
      discard clickWhen(f, "output.pattern.add")
      false
    proc secondAdded(f: FrameInfo): bool = f.markOf("output.part 1.kind").size.x > 0
    step("a second part is added", addSecond, secondAdded)

    proc openPoint(f: FrameInfo): bool =
      if f.markOf("output.part 1.item Source point").size.x > 0: return true
      discard clickWhen(f, "output.part 1.kind")
      false
    proc pointOpen(f: FrameInfo): bool =
      f.markOf("output.part 1.item Source point").size.x > 0
    step("the second part's kinds are open", openPoint, pointOpen)

    proc pickPoint(f: FrameInfo): bool = clickWhen(f, "output.part 1.item Source point")
    proc pointPicked(f: FrameInfo): bool =
      f.markOf("output.part 1.item Source point").size.x == 0 and
        f.markOf("output.part 1.kind").size.x > 0
    step("the second part is a source point", pickPoint, pointPicked)

    proc addThird(f: FrameInfo): bool =
      if f.markOf("output.part 2.kind").size.x > 0: return true
      discard clickWhen(f, "output.pattern.add")
      false
    proc thirdAdded(f: FrameInfo): bool = f.markOf("output.part 2.kind").size.x > 0
    step("a third part is added", addThird, thirdAdded)

    proc segd(f: FrameInfo): bool =
      if not reveal(f, "output.format SEG-D"): return false
      clickWhen(f, "output.format SEG-D")
    proc segdOn(f: FrameInfo): bool = f.markOf("output.format SEG-D.on").size.x > 0
    step("SEG-D is selected", segd, segdOn)

    proc shotPreview(f: FrameInfo): bool =
      let want = "output.pattern.preview 00012.1034p5.file.sgd"
      if f.markOf(want).size.x == 0:
        doAssert false, "the preview is not 00012.1034p5.file.sgd: " &
          $f.markNames("output.pattern.preview") & " " & $f.markNames("output.preview.problem")
      if not reveal(f, want): return false
      doAssert f.savePng(shot), "the name-pattern shot was not written"
      true
    step("the preview is the three-part name", noop, shotPreview)

    proc save(f: FrameInfo): bool =
      if not reveal(f, "output.pattern.save"): return false
      clickWhen(f, "output.pattern.save")
    proc saved(f: FrameInfo): bool =
      for p in f.core.project.doc.outputPatterns:
        if p.name == "Line" and p.parts.len == 3 and p.parts[0].kind == npSrcLine and
            p.parts[0].pad == 5 and p.parts[1].kind == npSrcPoint and
            p.parts[2].kind == npStem:
          return true
    step("Line is saved", save, saved)

    var arm = 0
    var cool = 0
    proc choose(f: FrameInfo): bool =
      ## The drop-down opens on the click's release. Give the list a frame to
      ## take its place, then click the row.
      if f.markOf("output.names.item Line").size.x > 0:
        inc arm
        if arm < 2: return false
        return clickWhen(f, "output.names.item Line")
      arm = 0
      if f.markOf("output.names.open").size.x > 0: return false
      if not reveal(f, "output.names"): return false
      inc cool
      if cool == 1 or cool mod 12 == 0:
        discard clickWhen(f, "output.names")
      false
    proc chosen(f: FrameInfo): bool =
      f.markOf("output.names Line").size.x > 0 and f.core.project.doc.outputPattern == "Line"
    step("Line is chosen", choose, chosen)

    proc tickAll(f: FrameInfo): bool =
      if f.markOf("output.file vib_uncorrelated.sgd on").size.x > 0: return true
      clickWhen(f, "output.all")
    proc namedTally(f: FrameInfo): bool =
      if f.markOf("output.ready").size.x > 0 and
          f.markOf("output.file vib_uncorrelated.sgd off").size.x == 0 and
          f.markOf("output.file vib_uncorrelated.sgd on").size.x == 0:
        doAssert false, "the sample file is not listed: " & $f.markNames("output.file")
      let on = f.markOf("output.file vib_uncorrelated.sgd on").size.x > 0
      if on and not tallyHas(f, "named by Line"):
        doAssert false, "the tally does not name the pattern: " &
          $f.markNames("output.tally")
      on
    step("the tally names the pattern", tickAll, namedTally)

    proc setNamed(f: FrameInfo): bool =
      answer = @[namedDest]
      if not reveal(f, "output.changeDest"): return false
      clickWhen(f, "output.changeDest")
    proc namedReady(f: FrameInfo): bool =
      f.markOf("output.destination " & namedDest).size.x > 0 and
        f.markOf("output.run").size.x > 0
    step("the patterned run has a destination", setNamed, namedReady)

    proc runNamed(f: FrameInfo): bool =
      if not reveal(f, "output.run"): return false
      clickWhen(f, "output.run")
    proc wroteNamed(f: FrameInfo): bool =
      ## The results table sits below the editor, so a clipped row is not the
      ## check. The written leaf is.
      if f.markOf("output.summary 0 1 0").size.x > 0:
        doAssert false, "the patterned write failed: " & $f.markNames("output.row") &
          " " & $f.markNames("output.summary")
      if not fileExists(namedDest / wantName):
        if f.markOf("output.summary 1 0 0").size.x == 0: return false
        var names: seq[string] = @[]
        for kind, path in walkDir(namedDest):
          names.add path.extractFilename
        doAssert false, "wrote " & $names & " not " & wantName
      not fileExists(namedDest / "vib_uncorrelated.sgd")
    step("Run writes the rendered name", runNamed, wroteNamed)

    var armSrc = 0
    var coolSrc = 0
    proc chooseSource(f: FrameInfo): bool =
      if f.markOf("output.names.item As the source file").size.x > 0:
        inc armSrc
        if armSrc < 2: return false
        return clickWhen(f, "output.names.item As the source file")
      armSrc = 0
      if f.markOf("output.names.open").size.x > 0: return false
      if not reveal(f, "output.names"): return false
      inc coolSrc
      if coolSrc == 1 or coolSrc mod 12 == 0:
        discard clickWhen(f, "output.names")
      false
    proc sourceShown(f: FrameInfo): bool =
      f.markOf("output.names As the source file").size.x > 0 and
        f.core.project.doc.outputPattern.len == 0 and not tallyHas(f, "named by")
    step("As the source file is chosen", chooseSource, sourceShown)

    proc setPlain(f: FrameInfo): bool =
      answer = @[plainDest]
      if not reveal(f, "output.changeDest"): return false
      clickWhen(f, "output.changeDest")
    proc plainReady(f: FrameInfo): bool =
      f.markOf("output.destination " & plainDest).size.x > 0 and
        f.markOf("output.run").size.x > 0
    step("the source-name run has a destination", setPlain, plainReady)

    proc runPlain(f: FrameInfo): bool =
      if not reveal(f, "output.run"): return false
      clickWhen(f, "output.run")
    proc wrotePlain(f: FrameInfo): bool =
      if f.markOf("output.summary 0 1 0").size.x > 0:
        doAssert false, "the source-name write failed: " & $f.markNames("output.summary")
      if not fileExists(plainDest / "vib_uncorrelated.sgd"): return false
      not fileExists(plainDest / wantName)
    step("As the source file writes the source name", runPlain, wrotePlain)

    proc remove(f: FrameInfo): bool =
      if not reveal(f, "output.pattern.delete"): return false
      clickWhen(f, "output.pattern.delete")
    proc gone(f: FrameInfo): bool =
      var has = false
      for p in f.core.project.doc.outputPatterns:
        if p.name == "Line": has = true
      not has and f.markOf("output.names As the source file").size.x > 0
    step("Line is deleted", remove, gone)

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0:
        f.keepInMainWindow()
        f.moveMouse(vec2(4, 4))
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
    doAssert fileExists(shot), "no name-pattern shot"
    echo "tguioutput names: ", steps.len, " steps"

when isMainModule:
  main()
