## The Output window's "Text header" row, headless, in the running frontend.
## With no project the row is dimmed and says a project is needed. With one,
## "Edit..." opens the template editor; a name, a line and a token inserted
## from the list give a preview filled in for the shown file; a token that
## does not exist shows the problem and Save is dim; Save keeps the template
## in the project and chooses it, and a write then holds that template as the
## first card of the file written.
##
## Seen to fail: with `headerText` left out of the run's options the written file
## kept the source's first card ("the first card is ..."). The cursor position of
## a token is tested in toutputtextedit; here the cursor is at the end.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## With VIEWSEG_SCREENSHOTS set, the row and the editor are saved as PNG files there.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, outputtext, state]
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

proc padded(line: string): string = line & repeat(' ', 80 - line.len)

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
      if f.markOf("output.text.edit").size.x == 0: return false
      doAssert f.markNames("output.text.dim Open or make a writable project").len > 0,
        "the row is not dimmed with the reason: " & $f.markNames("output.text.dim")
      true
    step("Output is open, the text row dimmed", openOutput, outputUp)

    proc makeProject(f: FrameInfo): bool =
      f.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      true
    proc made(f: FrameInfo): bool =
      if not (f.core.inProject and f.core.projectOpening.len == 0 and
          not f.core.project.readOnly): return false
      f.markNames("output.text.dim").len == 0
    step("a project is open, the row alive", makeProject, made)

    proc rowShot(f: FrameInfo): bool =
      if f.markOf("output.text From the source or library default").size.x == 0:
        return false
      f.shot "output-text-row.png"
      true
    step("the row says no template is used", noop, rowShot)

    proc edit(f: FrameInfo): bool = clickWhen(f, "output.text.edit")
    proc editing(f: FrameInfo): bool =
      f.markOf("output.text.window").size.x > 0 and
        f.markNames("output.text.save.dim An output text needs a name.").len > 0
    step("the editor is open, Save dim for want of a name", edit, editing)

    proc focusName(f: FrameInfo): bool = clickWhen(f, "output.text.name")
    proc typingNow(f: FrameInfo): bool = f.typing
    step("the name box has the keyboard", focusName, typingNow)

    proc typeName(f: FrameInfo): bool =
      f.typeText("Survey")
      true
    proc named(f: FrameInfo): bool = f.markOf("output.text.name Survey").size.x > 0
    step("the name is Survey", typeName, named)

    proc focusLines(f: FrameInfo): bool = clickWhen(f, "output.text.lines")
    step("the lines box has the keyboard", focusLines, typingNow)

    proc typeBad(f: FrameInfo): bool =
      f.typeText("C 1 FROM {nope}")
      true
    proc problem(f: FrameInfo): bool =
      if f.markNames("output.text.problem Line 1 has the token {nope}, which is not one.").len ==
          0: return false
      doAssert f.markNames("output.text.save.dim").len > 0, "Save is not dim for a problem"
      f.shot "editor-problem.png"
      true
    step("a token that is not one is a problem", typeBad, problem)

    proc retype(f: FrameInfo): bool =
      for i in 1 .. len("{nope}"):
        f.pressKey(skBackspace, true)
        f.pressKey(skBackspace, false)
      true
    proc retyped(f: FrameInfo): bool =
      f.markNames("output.text.problem").len == 0 and
        f.markNames("output.text.count 1 of 38 lines, the longest 9 of 80 characters.").len > 0
    step("the bad token is deleted", retype, retyped)

    var armTok = 0
    var coolTok = 0
    proc insertStem(f: FrameInfo): bool =
      ## The list opens on the release of the click; give it two frames.
      if f.markOf("output.text.token stem").size.x > 0:
        inc armTok
        if armTok < 2: return false
        return clickWhen(f, "output.text.token stem")
      armTok = 0
      inc coolTok
      if coolTok == 1 or coolTok mod 12 == 0:
        discard clickWhen(f, "output.text.insert")
      false
    proc inserted(f: FrameInfo): bool =
      if f.markNames("output.text.preview 0 C 1 FROM shots").len == 0: return false
      doAssert f.markNames("output.text.previewfor shots.sgy").len > 0,
        "the preview is not for the shown file: " & $f.markNames("output.text.previewfor")
      f.markNames("output.text.save.dim").len == 0
    step("the stem token is put at the cursor", insertStem, inserted)

    proc previewShot(f: FrameInfo): bool =
      f.shot "editor-preview.png"
      true
    step("the editor is shown with its preview", noop, previewShot)

    proc save(f: FrameInfo): bool = clickWhen(f, "output.text.save")
    proc saved(f: FrameInfo): bool =
      let d = f.core.project.doc
      d.outputTexts.len == 1 and d.outputTexts[0].name == "Survey" and
        d.outputTexts[0].lines == @["C 1 FROM {stem}"] and d.outputText == "Survey" and
        f.markOf("output.text.window").size.x == 0
    step("Survey is saved, chosen and the editor closed", save, saved)

    proc rowChosen(f: FrameInfo): bool = f.markOf("output.text Survey").size.x > 0
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
      f.markOf("output.format SEG-D.on").size.x > 0 and f.markOf("output.text.edit").size.x == 0
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
    let cards = back.textHeader.split('\n')
    back.close()
    doAssert cards[0] == padded("C 1 FROM shots"), "the first card is " & cards[0]
    doAssert "END TEXTUAL HEADER" in cards[39]
    echo "tguioutputtext: ", steps.len, " steps"

when isMainModule:
  main()
