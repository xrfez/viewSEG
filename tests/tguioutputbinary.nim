## The Output window's "Binary header" row, headless, in the running frontend.
## With no project the row is dimmed and says a project is needed. With one,
## "Edit..." opens the set editor with a table of every field that can be set;
## a name, a valid value (Job ID) and a value out of range (Ensemble fold) show
## the field's note and the problem and Save is dim; the value is corrected,
## the shown file's own values are in their column, Save keeps the set in the
## project and chooses it, and a write then holds the two values in the binary
## header of the file written. The row is gone for SEG-D.
##
## Seen to fail: with `headerBinary` left out of the run's options the written
## file kept the source's Job ID ("the job id is ..."); with Save left enabled
## for a problem, "Save is not dim for a problem".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## With VIEWSEG_SCREENSHOTS set, the row and the editor are saved as PNG files there.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, outputbinary, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo): bool
    done: proc (f: FrameInfo): bool

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
  let r = f.markOf(name)
  if r.size.x <= 0 or f.inRightPane(r): return r.size.x > 0
  let pane = f.markOf("output.pane.right")
  f.scrollWheel(pane.centre, if r.pos.y > pane.pos.y: -2 else: 2)
  false

proc main*() =
  var wait = 0
  var since = getMonoTime()
  withFixtures fx:
    let field = fx.dir / "data"
    let dest = fx.dir / "written"
    let job = fx.dir / "job"
    createDir(field)
    createDir(dest)
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    createDir(fx.dir / "cache")
    let sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shots.sgy"
    doAssert fileExists(sample), "missing " & sample
    copyFile(sample, field / "shots.sgy")
    let shotsDir = getEnv("VIEWSEG_SCREENSHOTS")
    var answer: seq[string] = @[]
    let hook = proc (kind: DialogKind; location: string): seq[string] = answer
    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo): bool; done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo): bool = true
    proc shot(f: FrameInfo; name: string) =
      if shotsDir.len > 0:
        createDir(shotsDir)
        doAssert f.savePng(shotsDir / name), "cannot save " & name

    proc browse(f: FrameInfo): bool =
      f.apply Command(kind: ckBrowse, paths: @[field], showFirst: true)
      true
    proc listed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0 and
        f.core.shownFile(f.core.findPanel(MainPanel)) >= 0
    step("the folder is listed and a file shown", browse, listed)

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
      if f.markOf("output.binary.edit").size.x == 0: return false
      doAssert f.markNames("output.binary.dim Open or make a writable project").len > 0,
        "the row is not dimmed with the reason: " & $f.markNames("output.binary.dim")
      true
    step("Output is open, the binary row dimmed", openOutput, outputUp)

    proc makeProject(f: FrameInfo): bool =
      f.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      true
    proc made(f: FrameInfo): bool =
      if not (f.core.inProject and f.core.projectOpening.len == 0 and
          not f.core.project.readOnly): return false
      f.markNames("output.binary.dim").len == 0
    step("a project is open, the row alive", makeProject, made)

    proc rowShot(f: FrameInfo): bool =
      if f.markOf("output.binary From the source or library default").size.x == 0:
        return false
      f.shot "output-binary-row.png"
      true
    step("the row says no set is used", noop, rowShot)

    proc edit(f: FrameInfo): bool = clickWhen(f, "output.binary.edit")
    proc editing(f: FrameInfo): bool =
      f.markOf("output.binary.window").size.x > 0 and
        f.markNames("output.binary.save.dim A binary header set needs a name.").len > 0
    step("the editor is open, Save dim for want of a name", edit, editing)

    proc focusName(f: FrameInfo): bool = clickWhen(f, "output.binary.name")
    proc typingNow(f: FrameInfo): bool = f.typing
    step("the name box has the keyboard", focusName, typingNow)

    proc typeName(f: FrameInfo): bool =
      f.typeText("Survey")
      true
    proc named(f: FrameInfo): bool = f.markOf("output.binary.name Survey").size.x > 0
    step("the name is Survey", typeName, named)

    proc focusJob(f: FrameInfo): bool = clickWhen(f, "output.binary.value jobId")
    step("the Job ID box has the keyboard", focusJob, typingNow)
    proc typeJob(f: FrameInfo): bool =
      f.typeText("7")
      true
    proc jobSet(f: FrameInfo): bool =
      f.markNames("output.binary.count 1 field set").len > 0 and
        f.markNames("output.binary.save.dim").len == 0
    step("Job ID is 7: one field set, Save alive", typeJob, jobSet)

    proc focusFold(f: FrameInfo): bool = clickWhen(f, "output.binary.value ensembleFold")
    step("the Ensemble fold box has the keyboard", focusFold, typingNow)
    proc typeBad(f: FrameInfo): bool =
      f.typeText("40000")
      true
    proc problem(f: FrameInfo): bool =
      if f.markNames("output.binary.problem Ensemble fold: 40000 is not from -32768 to " &
          "32767.").len == 0: return false
      doAssert f.markNames("output.binary.note ensembleFold 40000 is not from -32768 to " &
        "32767.").len > 0, "the field's own note is missing"
      doAssert f.markNames("output.binary.save.dim").len > 0, "Save is not dim for a problem"
      f.shot "editor-problem.png"
      true
    step("a value out of range is a problem", typeBad, problem)

    proc retype(f: FrameInfo): bool =
      for i in 1 .. len("40000"):
        f.pressKey(skBackspace, true)
        f.pressKey(skBackspace, false)
      f.typeText("4")
      true
    proc retyped(f: FrameInfo): bool =
      f.markNames("output.binary.problem").len == 0 and
        f.markNames("output.binary.count 2 fields set").len > 0 and
        f.markNames("output.binary.save.dim").len == 0
    step("the value is corrected", retype, retyped)

    proc shownIn(f: FrameInfo): bool =
      if f.markNames("output.binary.shown jobId").len == 0: return false
      doAssert f.markNames("output.binary.shownfor In the shown file: shots.sgy").len > 0,
        "the column is not for the shown file: " & $f.markNames("output.binary.shownfor")
      f.shot "editor-values.png"
      true
    step("the shown file's own values are in their column", noop, shownIn)

    proc filterFold(f: FrameInfo): bool = clickWhen(f, "output.binary.filter")
    step("the filter box has the keyboard", filterFold, typingNow)
    proc typeFilter(f: FrameInfo): bool =
      f.typeText("fold")
      true
    proc filtered(f: FrameInfo): bool =
      f.markOf("output.binary.field ensembleFold").size.x > 0 and
        f.markOf("output.binary.field jobId").size.x == 0
    step("the filter leaves the fold fields", typeFilter, filtered)

    proc clearFilter(f: FrameInfo): bool =
      for i in 1 .. len("fold"):
        f.pressKey(skBackspace, true)
        f.pressKey(skBackspace, false)
      true
    proc unfiltered(f: FrameInfo): bool = f.markOf("output.binary.field jobId").size.x > 0
    step("the filter is cleared", clearFilter, unfiltered)

    proc save(f: FrameInfo): bool = clickWhen(f, "output.binary.save")
    proc saved(f: FrameInfo): bool =
      let d = f.core.project.doc
      d.outputBinaries.len == 1 and d.outputBinaries[0].name == "Survey" and
        d.outputBinaries[0].entries == @[BinaryEntry(field: "jobId", value: "7"),
          BinaryEntry(field: "ensembleFold", value: "4")] and d.outputBinary == "Survey" and
        f.markOf("output.binary.window").size.x == 0
    step("Survey is saved, chosen and the editor closed", save, saved)

    proc rowChosen(f: FrameInfo): bool =
      if f.markOf("output.binary Survey").size.x == 0: return false
      f.shot "output-binary-row-chosen.png"
      true
    step("the row names Survey", noop, rowChosen)

    proc tickAll(f: FrameInfo): bool =
      if f.markOf("output.file shots.sgy on").size.x > 0: return true
      clickWhen(f, "output.all")
    proc ticked(f: FrameInfo): bool = f.markOf("output.file shots.sgy on").size.x > 0
    step("shots.sgy is ticked", tickAll, ticked)

    proc setDest(f: FrameInfo): bool =
      answer = @[dest]
      if not reveal(f, "output.changeDest"): return false
      clickWhen(f, "output.changeDest")
    proc destReady(f: FrameInfo): bool =
      f.markOf("output.destination " & dest).size.x > 0 and f.markOf("output.run").size.x > 0
    step("the destination is set", setDest, destReady)

    proc run(f: FrameInfo): bool =
      if not reveal(f, "output.run"): return false
      clickWhen(f, "output.run")
    proc wrote(f: FrameInfo): bool =
      if f.markOf("output.summary 0 1 0").size.x > 0:
        doAssert false, "the write failed: " & $f.markNames("output.row")
      fileExists(dest / "shots.sgy") and f.markOf("output.summary 1 0 0").size.x > 0
    step("Run writes the file", run, wrote)

    proc segd(f: FrameInfo): bool =
      if not reveal(f, "output.format SEG-D"): return false
      clickWhen(f, "output.format SEG-D")
    proc segdNoRow(f: FrameInfo): bool =
      f.markOf("output.format SEG-D.on").size.x > 0 and f.markOf("output.binary.edit").size.x == 0
    step("the row is gone for SEG-D", segd, segdNoRow)

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
    var back = openSeismic(dest / "shots.sgy", keys = false)
    let jobId = back.fileField("binary.jobId").toFloat
    let fold = back.fileField("binary.ensembleFold").toFloat
    back.close()
    doAssert jobId == 7, "the job id is " & $jobId
    doAssert fold == 4, "the ensemble fold is " & $fold
    echo "tguioutputbinary: ", steps.len, " steps"

when isMainModule:
  main()
