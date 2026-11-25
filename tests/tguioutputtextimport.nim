## The text header editor's Import... button, headless, in the running frontend.
## With a project open and the editor shown, a dialog answer takes a file in:
## a plain text file with long lines and too many lines (the note says how many
## were cut and dropped; Undo import puts the lines back), a CRLF file, a
## 3200-byte ASCII header, the start of a SEG-Y file, and a file over 1 MiB
## that is refused with a sentence and changes nothing. Whatever is chosen, the
## file's bytes and modification time are the same afterwards.
##
## A pipe and a folder are refused with a sentence, not opened.
##
## An answer that arrives after the editor was closed and opened again is dropped,
## and so is a dialog's answer when the editor was closed and opened again while
## the dialog was open.
##
## Seen to fail: with the pipe check removed, the read waits for a writer and
## "a pipe is refused, not waited on" did not happen; with the over-limit check removed, "a file over 1 MiB is refused
## did not happen" (the file was taken in as text). The cut is seen to fail in
## toutputtextimport.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## With VIEWSEG_SCREENSHOTS set, the editor after an import is saved as PNG.

import std/[math, monotimes, options, os, strutils, times]
when defined(posix):
  from std/posix import mkfifo

import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/view/outputtextimport
import viewSEG/ui/imgui/[app, shell]
import utils/[faultyfs, fixtures, waiting]

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

proc main*() =
  var wait = 0
  var since = getMonoTime()
  withFixtures fx:
    let field = fx.dir / "data"
    let inbox = fx.dir / "inbox"
    let job = fx.dir / "job"
    for d in [field, inbox, fx.dir / "config", fx.dir / "logs", fx.dir / "cache"]:
      createDir(d)
    copyFile(fx.surveySegy(), field / "shots.sgy")
    let shotsDir = getEnv("VIEWSEG_SCREENSHOTS")
    var many: seq[string] = @[]
    for i in 1 .. 43: many.add(if i in {2, 5, 7}: repeat('x', 90) else: "C" & $i & " text")
    let plain = inbox / "many.txt"
    writeFile(plain, many.join("\n") & "\n")
    let crlf = inbox / "crlf.txt"
    writeFile(crlf, "C 1 first\r\nC 2 second\r\n")
    let ascii = inbox / "ascii.hdr"
    block:
      var h = initTextHeader(teAscii)
      h.text = "C 1 RAW ASCII HEADER" & repeat(' ', 60)
      var s = ""
      for b in h.data: s.add char(b)
      writeFile(ascii, s)
    let big = inbox / "big.txt"
    writeFile(big, repeat("C 1 text\n", 250_000))
    let chosen = [plain, crlf, ascii, field / "shots.sgy", big]
    var before: seq[tuple[bytes: string; mtime: Time]] = @[]
    for p in chosen: before.add (readFile(p), getLastModificationTime(p))
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
    proc outputUp(f: FrameInfo): bool = f.markOf("output.text.edit").size.x > 0
    step("Output is open", openOutput, outputUp)

    proc makeProject(f: FrameInfo): bool =
      f.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      true
    proc made(f: FrameInfo): bool =
      f.core.inProject and f.core.projectOpening.len == 0 and not f.core.project.readOnly and
        f.markNames("output.text.dim").len == 0
    step("a project is open", makeProject, made)

    proc edit(f: FrameInfo): bool = clickWhen(f, "output.text.edit")
    proc editing(f: FrameInfo): bool = f.markOf("output.text.import").size.x > 0
    step("the editor is open with Import...", edit, editing)

    proc importing(path: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        answer = @[path]
        clickWhen(f, "output.text.import")
    proc said(note, count: string): proc (f: FrameInfo): bool =
      result = proc (f: FrameInfo): bool =
        f.markNames("output.text.import.note " & note).len > 0 and
          (count.len == 0 or f.markNames("output.text.count " & count).len > 0)

    step("a long text file is cut and dropped", importing(plain),
      said("3 lines were longer than 80 characters and were cut; 5 lines after line 38 " &
        "were dropped.", "38 of 38 lines, the longest 80 of 80 characters."))
    proc many38(f: FrameInfo): bool =
      f.shot "import-cut.png"
      true
    step("the editor is shown after the import", noop, many38)

    proc undo(f: FrameInfo): bool = clickWhen(f, "output.text.import.undo")
    proc emptied(f: FrameInfo): bool =
      f.markNames("output.text.count 0 of 38 lines").len > 0 and
        f.markNames("output.text.import.undo").len == 0
    step("Undo import puts the empty text back", undo, emptied)

    step("a CRLF file is taken in", importing(crlf),
      said("2 lines were taken in.", "2 of 38 lines, the longest 10 of 80 characters."))
    step("a raw ASCII header is taken in", importing(ascii),
      said("The text header was read as ASCII", "1 of 38 lines, the longest 20 of 80"))
    step("the start of a SEG-Y file is taken in", importing(field / "shots.sgy"),
      said("The text header was read as", ""))
    step("a file over 1 MiB is refused", importing(big), said(ImportTooBig, ""))

    when defined(posix):
      let pipe = inbox / "pipe.txt"
      doAssert mkfifo(pipe.cstring, 0o600) == 0, "cannot make a pipe"
      step("a pipe is refused, not waited on", importing(pipe), said(ImportNotFile, ""))
    step("a folder is refused", importing(inbox), said(ImportNotFile, ""))

    # a slow read answers after the editor was closed and opened again: it is dropped
    let slow = inbox / "slow.txt"
    writeFile(slow, "SLOW ANSWER\n")
    install()
    fault(slow, fkDelay, {foOpen}, initDuration(milliseconds = 1500))
    proc startSlow(f: FrameInfo): bool =
      answer = @[slow]
      clickWhen(f, "output.text.import")
    step("a slow import is started", startSlow, noop)
    proc closeEditor(f: FrameInfo): bool = clickWhen(f, "output.text.edit")
    proc closed(f: FrameInfo): bool = f.markOf("output.text.import").size.x == 0
    step("the editor is closed while it reads", closeEditor, closed)
    step("the editor is opened again", edit, editing)
    var reopenedAt = getMonoTime()
    proc mark(f: FrameInfo): bool =
      reopenedAt = getMonoTime()
      true
    proc waited(f: FrameInfo): bool =
      doAssert f.markNames("output.text.import.note SLOW ANSWER").len == 0
      getMonoTime() - reopenedAt > initDuration(milliseconds = 2500)
    step("the late answer is waited for", mark, waited)
    proc untouched(f: FrameInfo): bool =
      f.markNames("output.text.count 0 of 38 lines").len > 0 and
        f.markNames("output.text.import.undo").len == 0
    step("the late answer did not replace the lines", noop, untouched)

    # the Import... dialog stays open while the editor is closed and opened again
    let lateDialog = inbox / "late-dialog.txt"
    writeFile(lateDialog, "LATE DIALOG\n")
    answer = @[]
    proc askOnly(f: FrameInfo): bool = clickWhen(f, "output.text.import")
    step("the Import... dialog is asked for and stays open", askOnly, noop)
    step("the editor is closed with the dialog open", closeEditor, closed)
    step("the editor is opened again at once", edit, editing)
    proc answerLate(f: FrameInfo): bool =
      postShellEvent ShellEvent(kind: sePathsChosen, dialog: dkOutputText, paths: @[lateDialog])
      reopenedAt = getMonoTime()
      true
    proc leftAlone(f: FrameInfo): bool =
      doAssert f.markNames("output.text.import.note LATE DIALOG").len == 0
      doAssert f.markNames("output.text.import.note 1 line was taken in.").len == 0
      getMonoTime() - reopenedAt > initDuration(milliseconds = 1500)
    step("the dialog's answer for the closed editor is dropped", answerLate, leftAlone)
    step("the lines were not replaced by the dialog's answer", noop, untouched)

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
    for i, p in chosen:
      doAssert readFile(p) == before[i].bytes, p & " changed"
      doAssert getLastModificationTime(p) == before[i].mtime, p & " was touched"
    echo "tguioutputtextimport: ", steps.len, " steps"

when isMainModule:
  main()
