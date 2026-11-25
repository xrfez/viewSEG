## A receiver station that clearly moved, headless, driven by real clicks: the Seismic window's
## right-click menu offers "Move this station to the position in this trace's headers" with
## its distance from the survey's position (the file's own header position, read from disk
## after a survey join replaced the keys); the click keeps the move, the Project window lists
## it, and its Remove button takes it away, the keys going back to the survey's position.
## `VIEWSEG_SCREENSHOTS=<dir>` saves stamove-menu.png and stamove-project.png there.
##
## Seen to fail: with the Project window's Remove button sending nothing, "Remove took the
## move away" did not happen.
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state, stationmoves]
import viewSEG/ui/imgui/app
import utils/[farsurvey, fixtures, waiting]

const SurveyWords = "50.0 m from the survey's position"

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2; button = 1) =
  f.moveMouse(at)
  f.pressMouse(at, true, button)
  f.pressMouse(at, false, button)

func near(a, b: float64): bool =
  abs(a - b) <= 0.01

proc hasMark(f: FrameInfo; name: string): bool =
  f.markOf(name).size.x > 0

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let survey = fx.surveyFarther()
    let record = fx.surveySegy()
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    let opts = RunOptions(openPaths: @[record], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var hovered = -1 # the survey-wide trace the menu was opened on
    var header: tuple[x, y: float64] # its own header position
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    template keysAt(f: FrameInfo; t: int): untyped = f.core.sessions[0].file.index.keys[t]
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        doAssert f.savePng(shots / name), name & " was not written"

    step("the file is shown", proc (f: FrameInfo) = f.keepInMainWindow(),
      proc (f: FrameInfo): bool =
      f.core.panels[f.core.findPanel(MainPanel)].laidOut and f.hasMark("plot.data"))
    var serial = 0
    proc importSurvey(f: FrameInfo) =
      serial = f.core.joinReport.serial
      f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps)], joinOptions: JoinOptions(coordinates: hcReplace),
        joinUnits: JoinUnits(survey: suMetres))
    step("the survey replaces the header positions", importSurvey, proc (f: FrameInfo): bool =
      f.core.joinReport.serial > serial and f.core.joinUnderWay.job == NoJob)
    step("the menu offered the header position", noop, proc (f: FrameInfo): bool =
      for n in f.markNames("plot.menu.stamove.header.item "):
        if SurveyWords in n:
          hovered = f.core.selection.hover
          return true
      if not f.hasMark("plot.menu.target") and wait mod 12 == 2:
        f.click(f.markOf("plot.data").centre, 3)
      false)
    step("the menu's picture", noop, proc (f: FrameInfo): bool =
      if wait < 6: return false
      f.shot "stamove-menu.png"
      doAssert f.hasMark("plot.menu.stamove.dialog") and f.hasMark("plot.menu.stamove.remove")
      let own = f.core.ownPositionOf(hovered)
      doAssert own.isSome, "the header position was not read"
      header = (own.get.x, own.get.y)
      let local = hovered - f.core.sessions[0].base
      doAssert near(f.keysAt(local).rcvX, header.x + 50.0),
        "the survey's position is not 50 m east of the header's"
      true)
    step("a click keeps the move", noop, proc (f: FrameInfo): bool =
      if f.core.project.doc.stationMoves.len == 1: return true
      let item = f.markNames("plot.menu.stamove.header.item ")
      if item.len > 0 and wait mod 6 == 3: f.click(f.markOf("plot.menu.stamove.header").centre)
      false)
    step("the keys follow the move", noop, proc (f: FrameInfo): bool =
      let m = f.core.project.doc.stationMoves[0]
      near(m.x, header.x) and near(m.y, header.y) and
        near(f.keysAt(hovered - f.core.sessions[0].base).rcvX, header.x))
    step("Project > Project...", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Project").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Project...")
      if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
      f.projectWindows.shown and f.hasMark("project.move.0"))
    step("the Project window lists the move", noop, proc (f: FrameInfo): bool =
      if wait < 6: return false
      f.shot "stamove-project.png"
      f.hasMark("project.moves") and f.hasMark("project.move.remove.0"))
    step("Remove took the move away", noop, proc (f: FrameInfo): bool =
      if f.core.project.doc.stationMoves.len == 0 and not f.hasMark("project.move.0"):
        return near(f.keysAt(hovered - f.core.sessions[0].base).rcvX, header.x + 50.0)
      if wait mod 6 == 3: f.click(f.markOf("project.move.remove.0").centre)
      false)

    var at = 0
    var started = false
    var failed = ""
    var o = opts
    o.onFrame = proc (f: FrameInfo) =
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
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          for e in f.core.log: echo "  log: ", e.text
          discard f.savePng(getTempDir() / "tguistationmove-failed.png")
          f.stop()
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

when isMainModule:
  main()
