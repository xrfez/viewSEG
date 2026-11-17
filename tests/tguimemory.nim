## Undo and redo from any window, the Edit menu, and the File memory
## window, in the running frontend (headless, SDL events), with the
## settings and what is remembered kept in a folder of the test's:
##
## - `K` kills a trace; a click in the Messages window takes the focus from
##   the plot; Ctrl+Z there undoes the kill, Ctrl+Shift+Z makes it again,
##   Ctrl+Z and Ctrl+Y the same; Edit > Undo and Edit > Redo do it with the
##   mouse;
## - the kill is written to the store a moment later; File > File memory...
##   lists it beside two entries put there before (one not opened for years,
##   one whose file is gone); "Remove those not opened for 90 days" asks
##   first, naming the entry, then removes it, and Messages says so; "Remove
##   the gone" the same; the file shown, selected and removed, is shown as
##   the file has it, and its entry goes; the store listed again while a
##   confirmation is open (an entry more, first) changes nothing of what
##   the confirmation takes away;
## - the data file is never changed.
##
## Seen to fail: with the Edit menu's shortcuts left out (Ctrl+Z only in
## the focused plot, as before), "Ctrl+Z in Messages did not happen"; with
## the removals not asking first (`ckForgetFiles` at the button), "Remove
## those not opened for 90 days did not happen" (no confirmation came);
## with the confirmation keeping row numbers (the window before), "Remove
## those not opened for 90 days: remove did not happen" (it removed the
## gone file's entry, the row that had moved under it).
##
## With `VIEWSEG_SCREENSHOTS=<dir>`, the Edit menu, the window and a
## confirmation are saved there as PNG files.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, sequtils, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =

  withFixtures fx:
    let path = fx.surveySegy()
    let before = (readFile(path), getLastModificationTime(path))
    let config = fx.dir / "config"
    let store = Store(home: config / StoreFolder)
    createDir(store.home)
    # two entries from before: one not opened for years (its file in place),
    # one whose file is gone
    let oldFile = fx.dir / "old.sgy"
    writeFile(oldFile, newString(5000))
    var old = FileRecord(identity: FileIdentity(size: 5000, quick: 1), name: "old.sgy",
      path: oldFile, opened: initTime(1_577_836_800, 0))
    old.edits.lists[teKilled] = @[1, 2]
    old.doc = docName(old.identity, 1)
    writeFile(store.docPath(old.doc), memoryDocument(old))
    var gone = FileRecord(identity: FileIdentity(size: 7000, quick: 2), name: "gone.sgy",
      path: fx.dir / "gone.sgy", opened: getTime() - initDuration(days = 2))
    gone.edits.allReversed = true
    gone.doc = docName(gone.identity, 1)
    writeFile(store.docPath(gone.doc), memoryDocument(gone))

    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    const killed = 5
    let shots = getEnv("VIEWSEG_SCREENSHOTS")

    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc click(f: FrameInfo; q: Vec2; button = 1) =
      f.pressMouse(q, true, button)
      f.pressMouse(q, false, button)

    proc chord(f: FrameInfo; key: SimKey; mods: set[SimMod] = {}) =
      const modKeys: array[SimMod, SimKey] = [skCtrl, skShift, skAlt]
      for m in mods: f.pressKey(modKeys[m], true, mods)
      f.pressKey(key, true, mods)
      f.pressKey(key, false, mods)
      for m in mods: f.pressKey(modKeys[m], false)

    proc isKilled(f: FrameInfo): bool =
      f.core.sessions.len > 0 and
        teKilled in f.core.traceEdits(f.core.sessions[0].base + killed)

    proc pointAt(f: FrameInfo; position: int): Vec2 =
      let v = f.panel.view.screenAt(f.markOf("plot.data"), DataPoint(x: float64(position),
        tMs: 702))
      vec2(round(v.x), round(v.y))

    proc clickOn(name, mark: string; done: proc (f: FrameInfo): bool) =
      ## The pointer over `mark`, then a click on it.
      step(name & ": point", proc (f: FrameInfo) = f.moveMouse(f.markOf(mark).centre),
        proc (f: FrameInfo): bool = wait > 2 and f.markOf(mark).size.x > 0)
      step(name, proc (f: FrameInfo) = f.click(f.markOf(mark).centre), done)

    proc keyed(name: string; key: SimKey; mods: set[SimMod]; want: bool) =
      step(name, proc (f: FrameInfo) = f.chord(key, mods), proc (f: FrameInfo): bool =
        f.isKilled == want)

    proc menu(name, top, item: string; done: proc (f: FrameInfo): bool) =
      clickOn(name & ": " & top, "menu." & top, proc (f: FrameInfo): bool =
        f.markOf("menu." & item).size.x > 0)
      clickOn(name, "menu." & item, done)

    # an entry the store gets while a confirmation is open (another file's
    # edits written, then the store listed again, as an agent's "list file
    # memory" does): the newest, so the rows move under the confirmation
    let newerFile = fx.dir / "newer.sgy"
    writeFile(newerFile, newString(9000))
    var newer = FileRecord(identity: FileIdentity(size: 9000, quick: 3), name: "newer.sgy",
      path: newerFile, opened: getTime() + initDuration(hours = 1))
    newer.edits.lists[teKilled] = @[4]
    newer.doc = docName(newer.identity, 1)

    proc removal(name, button: string; goes: string; relist = false) =
      ## A click in the window (it acts only once focused), the button, the
      ## confirmation naming what goes, then Remove; with `relist`, the store
      ## listed again with an entry more while the confirmation is open.
      clickOn(name & ": the window", "memory", proc (f: FrameInfo): bool = wait > 3)
      clickOn(name, button, proc (f: FrameInfo): bool =
        result = f.markOf("memory.confirm").size.x > 0 and wait > 4
        if result and shots.len > 0 and goes == old.doc:
          doAssert f.savePng(shots / "file-memory-confirm.png"))
      step(name & ": asks first", noop, proc (f: FrameInfo): bool =
        result = wait > 3
        if result:
          doAssert f.core.memoryList.records.len > 0 and
            f.core.store.docPath(goes).fileExists, "the removal did not ask first")
      if relist:
        step(name & ": listed again meanwhile", proc (f: FrameInfo) =
          writeFile(f.core.store.docPath(newer.doc), memoryDocument(newer))
          f.apply(Command(kind: ckFileMemory, origin: coAgent)), proc (f: FrameInfo): bool =
          f.core.memoryList.listed and not f.core.memoryList.listing and
            f.core.memoryList.records.anyIt(it.doc == newer.doc))
      clickOn(name & ": remove", "memory.confirm.remove", proc (f: FrameInfo): bool =
        f.markOf("memory.confirm").size.x == 0 and
          f.core.memoryList.records.allIt(it.doc != goes))
      step(name & ": removed from the store", noop, proc (f: FrameInfo): bool =
        result = not fileExists(f.core.store.docPath(goes))
        if result and relist:
          doAssert fileExists(f.core.store.docPath(gone.doc)) and
            fileExists(f.core.store.docPath(newer.doc)),
            "the confirmation removed another entry than the one it named")

    step("shown", noop, proc (f: FrameInfo): bool =
      f.panel.laidOut and f.core.sessions.len == 1 and f.core.remembering(path).known)
    var q: Vec2
    step("the plot takes the keys", proc (f: FrameInfo) =
      q = f.pointAt(killed)
      f.moveMouse(q), proc (f: FrameInfo): bool = wait > 3 and f.pick.found)
    step("a click in the plot", proc (f: FrameInfo) = f.click(q), proc (f: FrameInfo): bool =
      wait > 3)
    step("Esc", proc (f: FrameInfo) = f.chord(skEscape), proc (f: FrameInfo): bool =
      wait > 3 and f.core.selection.selected.len == 0)
    step("over the trace", proc (f: FrameInfo) = f.moveMouse(q), proc (f: FrameInfo): bool =
      wait > 3 and f.pick.found)
    keyed("K kills it", skK, {}, true)
    clickOn("a click in Messages", "messages", proc (f: FrameInfo): bool = wait > 4)
    keyed("Ctrl+Z in Messages", skZ, {smCtrl}, false)
    keyed("Ctrl+Shift+Z in Messages", skZ, {smCtrl, smShift}, true)
    keyed("Ctrl+Z again", skZ, {smCtrl}, false)
    keyed("Ctrl+Y", skY, {smCtrl}, true)
    clickOn("the Edit menu", "menu.Edit", proc (f: FrameInfo): bool =
      result = f.markOf("menu.Undo").size.x > 0 and wait > 4
      if result and shots.len > 0: doAssert f.savePng(shots / "edit-menu.png"))
    step("closed", proc (f: FrameInfo) = f.chord(skEscape), proc (f: FrameInfo): bool =
      f.markOf("menu.Undo").size.x == 0)
    menu("Edit > Undo", "Edit", "Undo", proc (f: FrameInfo): bool = not f.isKilled)
    menu("Edit > Redo", "Edit", "Redo", proc (f: FrameInfo): bool = f.isKilled)
    step("written to the store", noop, proc (f: FrameInfo): bool =
      f.core.remembering(path).doc.len > 0 and
        fileExists(f.core.store.docPath(f.core.remembering(path).doc)))
    menu("File > File memory...", "File", "File memory...", proc (f: FrameInfo): bool =
      f.markOf("memory").size.x > 0 and f.core.memoryList.listed and
        not f.core.memoryList.listing)
    step("three files listed", noop, proc (f: FrameInfo): bool =
      result = wait > 3 and f.markOf("memory.row.2").size.x > 0
      if result:
        doAssert f.core.memoryList.records.len == 3, $f.core.memoryList.records.len
        doAssert f.core.memoryList.records[0].path == path, "the newest opened is not first"
        if shots.len > 0: doAssert f.savePng(shots / "file-memory.png"))
    removal("Remove those not opened for 90 days", "memory.old", old.doc, relist = true)
    removal("Remove the gone", "memory.gone", gone.doc)
    clickOn("the newer, selected", "memory.row.0", proc (f: FrameInfo): bool = wait > 3)
    removal("Remove the newer, selected", "memory.remove", newer.doc)
    clickOn("the file shown, selected", "memory.row.0", proc (f: FrameInfo): bool = wait > 3)
    var shownDoc = ""
    step("its entry", noop, proc (f: FrameInfo): bool =
      shownDoc = f.core.remembering(path).doc
      shownDoc.len > 0)
    clickOn("Remove: the window", "memory", proc (f: FrameInfo): bool = wait > 3)
    clickOn("Remove", "memory.remove", proc (f: FrameInfo): bool =
      f.markOf("memory.confirm").size.x > 0)
    clickOn("Remove: confirmed", "memory.confirm.remove", proc (f: FrameInfo): bool =
      not f.isKilled and f.core.remembering(path).doc.len == 0)
    step("its entry removed", noop, proc (f: FrameInfo): bool =
      not fileExists(f.core.store.docPath(shownDoc)))
    step("Messages says so", noop, proc (f: FrameInfo): bool =
      var said: seq[string]
      for m in f.messages:
        if "Forgot " in m.text: said.add m.text
      doAssert said.len == 4, $said
      doAssert "old.sgy (2 killed" in said[0] and "gone.sgy (all reversed" in said[1] and
        "newer.sgy (1 killed" in said[2], $said
      true)

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
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(persist: true, configDir: some(config),
      logDir: some(fx.dir / "logs"), openPaths: @[path], windowSize: (1600, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
    echo "tguimemory: ", steps.len, " steps"

when isMainModule:
  main()
