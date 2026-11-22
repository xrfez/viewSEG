## The Reference archive window as a selectable list, headless, on samples/ only: a click on
## a row selects that one row, the buttons above the table act on it and do nothing with no
## row selected, a double click views, the mark in the first column is the reference in use,
## the arrow keys move the selection, and the table takes the height the window is given,
## with a project's Main archive hanging under it. Screenshots go under .scratch.
##
## Seen to fail: with the rows' selectable drawn without the selection, "a click did not
## select the second row"; with the table's height fixed (as it was), "the table did not grow
## with the window".

import std/[algorithm, math, monotimes, options, os, strutils]
import imguin/cimgui
import viewSEG/core/[geometry, references, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir
const shots = root / ".scratch"

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; q: Vec2; button = 1) =
  f.moveMouse(q)
  f.pressMouse(q, true, button)
  f.pressMouse(q, false, button)

proc main*() =
  withFixtures fx:
    let path = root / "samples" / "land" / "shots.sgy"
    doAssert fileExists(path), path
    let config = fx.dir / "config"
    createDir(config)
    createDir(shots)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var before: Rect ## a table's rectangle before the window was given more height
    var windowBefore: Rect
    var inUse = ""

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc clickMark(f: FrameInfo; mark: string): bool =
      let r = f.markOf(mark)
      if r.size.x > 0 and wait mod 6 == 3:
        f.click(r.centre)
        true
      else: false

    proc tap(f: FrameInfo; mark: string) =
      ## One click on `mark`, once per step, as a person's: the pointer arrives first.
      let q = f.markOf(mark).centre
      case wait
      of 2: f.moveMouse(q)
      of 4: f.pressMouse(q, true)
      of 5: f.pressMouse(q, false)
      else: discard

    proc byName(f: FrameInfo; n: int): ReferenceEntry =
      ## The nth entry in the table's order (by name).
      var es = f.core.references.entries
      es.sort(proc (a, b: ReferenceEntry): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))
      es[n]

    proc selectedAt(f: FrameInfo; row: int): bool =
      let names = f.markNames("references.selected")
      names.len == 1 and abs(f.markOf("references.selected").pos.y -
        f.markOf("references.row." & $row).pos.y) < 1

    proc openArchive(f: FrameInfo) =
      f.click(f.markOf("menu.Operations").centre)

    step("the file opens", noop, proc (f: FrameInfo): bool =
      f.core.referencesLoaded and f.markOf("plot.data").size.x > 0)

    step("five references are stored", proc (f: FrameInfo) =
      for (n, f1, f2) in [("Chirp B", 8.0, 40.0), ("Chirp A", 10.0, 80.0), ("Chirp D", 6.0, 60.0),
          ("Chirp C", 12.0, 90.0)]:
        f.apply(Command(kind: ckGenerateReference, refGenerate: GeneratedReference(name: n,
          law: rlLinear, f1Hz: f1, f2Hz: f2, durationMs: 200, dtMs: 2, amplitude: 1)))
      f.apply(Command(kind: ckPilotReference, refPilot: PilotRule(name: "Chirp E pilot",
        aux: false, trace: 1, startMs: 0, spanMs: 200))), proc (f: FrameInfo): bool =
      f.core.references.entries.len == 5)

    step("Operations > Reference archive...", openArchive, proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Reference archive...")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(f.markOf("menu.Operations").centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.markOf("references.row.4").size.x > 0 and wait > 6)

    step("no row is selected, and the buttons do nothing", noop, proc (f: FrameInfo): bool =
      doAssert f.markNames("references.selected").len == 0, "a row was selected at the start"
      for a in ["use", "view", "rename", "delete", "compareA", "compareB", "copy"]:
        doAssert f.markOf("references.act." & a).size.x > 0, "no button " & a
      if wait == 3:
        for a in ["use", "view", "delete", "rename"]:
          f.click(f.markOf("references.act." & a).centre)
      if wait > 14:
        doAssert f.markOf("references.confirm").size.x == 0, "Delete asked with no row selected"
        doAssert f.markOf("references.rename").size.x == 0, "Rename started with no row selected"
        doAssert f.core.chosenReference.len == 0 and f.core.refViews.len == 0,
          "a button acted with no row selected"
        result = true)

    step("a click selects that row, and one row at a time", noop, proc (f: FrameInfo): bool =
      # one click only: two within a double-click time would view the row
      f.tap("references.row.1")
      f.selectedAt(1) and wait > 8)

    step("another row's click moves the selection", noop, proc (f: FrameInfo): bool =
      f.tap("references.row.2")
      result = f.selectedAt(2) and wait > 8
      if result: doAssert f.core.refViews.len == 0, "a single click viewed a row")

    step("Use puts the selected row in use", noop, proc (f: FrameInfo): bool =
      if f.core.chosenReference.len == 0: discard f.clickMark("references.act.use")
      doAssert f.core.chosenReference.len == 0 or f.core.chosenReference == f.byName(2).id,
        "Use chose another row than the selected one"
      f.core.chosenReference.len > 0)

    step("the mark of another row chooses it, None chooses none", noop,
        proc (f: FrameInfo): bool =
      if f.core.chosenReference == f.byName(2).id: discard f.clickMark("references.use.0")
      result = f.core.chosenReference == f.byName(0).id
      if result: doAssert f.selectedAt(2), "the mark moved the selection"
      )

    step("None", noop, proc (f: FrameInfo): bool =
      if f.core.chosenReference.len > 0: discard f.clickMark("references.none")
      f.core.chosenReference.len == 0)

    step("the Down key moves the selection", proc (f: FrameInfo) =
      f.pressKey(skDown, true), proc (f: FrameInfo): bool =
      if wait == 2: f.pressKey(skDown, false)
      result = wait > 4 and f.selectedAt(3))

    step("a double click views the row", noop, proc (f: FrameInfo): bool =
      if f.core.refViews.len == 0:
        let q = f.markOf("references.row.0").centre
        case wait mod 12
        of 2: f.moveMouse(q)
        of 4: f.pressMouse(q, true)
        of 5: f.pressMouse(q, false)
        of 6: f.pressMouse(q, true)
        of 7: f.pressMouse(q, false)
        else: discard
      else:
        result = f.core.refViews[0].name == f.byName(0).name
        if result: f.apply Command(kind: ckCloseRefView, refWindow: f.core.refViews[0].id))

    step("Rename edits the name in the row", noop, proc (f: FrameInfo): bool =
      if f.markOf("references.rename").size.x == 0: discard f.clickMark("references.act.rename")
      f.markOf("references.rename").size.x > 0)

    step("Escape leaves the name as it was", proc (f: FrameInfo) =
      f.pressKey(skEscape, true), proc (f: FrameInfo): bool =
      if wait == 2: f.pressKey(skEscape, false)
      result = wait > 4 and f.markOf("references.rename").size.x == 0)

    step("the selection is shown, and the use mark of the chosen row", noop,
        proc (f: FrameInfo): bool =
      f.apply Command(kind: ckSelectReference, refId: f.byName(4).id)
      result = wait > 4
      if result:
        discard f.savePng(shots / "reference-archive-list.png"))

    step("the window grows, and the table with it", proc (f: FrameInfo) =
      before = f.markOf("references.table")
      windowBefore = f.markOf("references")
      igSetWindowSize_Str(f.windowName("refs").cstring, ImVec2_c(x: windowBefore.size.x,
        y: windowBefore.size.y + 120), ImGui_Cond_Always.cint), proc (f: FrameInfo): bool =
      result = wait > 6 and f.markOf("references").size.y > windowBefore.size.y + 100
      if result:
        let grown = f.markOf("references.table").size.y - before.size.y
        doAssert abs(grown - 120) <= 2, "the table did not grow with the window: " & $grown)

    step("a project: its table and the Main archive header under it", proc (f: FrameInfo) =
      f.apply(Command(kind: ckNewProject, projectPath: fx.dir / "job", dataFolders: @[])),
        proc (f: FrameInfo): bool =
      if f.core.inProject and f.core.referencesLoaded and f.core.mainReferences.entries.len == 5:
        if f.core.references.entries.len == 0 and wait mod 20 == 0:
          for i in 0 .. 2:
            f.apply(Command(kind: ckCopyReference, refId: f.core.mainReferences.entries[i].id))
        result = f.core.references.entries.len == 3 and
          f.markOf("references.main.header").size.x > 0 and wait > 10
      if result:
        # the header is the window's last thing; the table has the height that is left
        let win = f.markOf("references")
        let head = f.markOf("references.main.header")
        doAssert win.pos.y + win.size.y - (head.pos.y + head.size.y) < 30,
          "the Main archive header is not at the window's bottom")

    step("the project's table grows with the window", proc (f: FrameInfo) =
      before = f.markOf("references.table")
      windowBefore = f.markOf("references")
      igSetWindowSize_Str(f.windowName("refs").cstring, ImVec2_c(x: windowBefore.size.x,
        y: windowBefore.size.y + 80), ImGui_Cond_Always.cint), proc (f: FrameInfo): bool =
      result = wait > 6 and f.markOf("references").size.y > windowBefore.size.y + 60
      if result:
        let grown = f.markOf("references.table").size.y - before.size.y
        doAssert abs(grown - 80) <= 2, "the project's table did not grow: " & $grown)

    step("the Main archive opens, and both tables show", noop, proc (f: FrameInfo): bool =
      if f.markOf("references.main.table").size.x == 0:
        discard f.clickMark("references.main.header")
      result = f.markOf("references.main.table").size.y > 40 and wait > 8
      if result:
        doAssert f.markOf("references.table").size.y > 40, "the project's table is gone"
        let win = f.markOf("references")
        let main = f.markOf("references.main.table")
        doAssert main.pos.y + main.size.y <= win.pos.y + win.size.y + 1,
          "the Main archive's table runs out of the window"
        discard f.savePng(shots / "reference-archive-project.png"))

    step("a main archive row: Use does nothing, Copy to project copies it", proc (f: FrameInfo) =
      inUse = f.core.chosenReference, proc (f: FrameInfo): bool =
      let row = f.markOf("references.main.row.2")
      if f.markOf("references.selected").pos.y != row.pos.y:
        discard f.clickMark("references.main.row.2")
      elif wait mod 12 == 3: f.click(f.markOf("references.act.use").centre)
      elif wait mod 12 == 9: f.click(f.markOf("references.act.copy").centre)
      doAssert f.core.chosenReference == inUse, "Use took a main archive row"
      f.core.references.entries.len == 4)

    proc onFrame(f: FrameInfo) =
      inc wait
      if at >= steps.len: f.stop()
      elif not started:
        steps[at].act(f)
        started = true
        since = getMonoTime()
      elif steps[at].done(f):
        inc at
        started = false
        wait = 0
      elif overdue(wait, 400, since):
        failed = steps[at].name & " did not happen"
        for e in f.core.log: echo "  log: ", e.text
        discard f.savePng(shots / "archive-failed.png")
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiarchive: ", steps.len, " steps"

when isMainModule:
  main()
