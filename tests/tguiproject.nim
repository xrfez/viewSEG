## Projects in the running frontend, headless, driven by real clicks on the
## menus and the project's windows, the system's folder dialogs answered by
## the test (`RunOptions.dialogs`), with the settings in a folder of the
## test's own:
##
## - File > New project...: its window, the place chosen with Choose...,
##   the data folder the file list lists given, Make the project: the
##   project is made and open, the title names it;
## - the survey imported (as the Import survey window does) is kept in it;
## - File > Close project, then File > Recent projects: it opens again, its
##   survey on the map without the import;
## - a survey original that changed: File > Open project... opens it, the
##   Project window comes forward with Update from the original, and its
##   click copies the original in again;
## - the program started again opens the project that was open at the quit.
##
## Seen to fail: with the Project window not brought forward when the
## project offers an update, "the Project window offers the update" did not
## happen; with `lastProject` not read at start, "the project open at the
## quit is opened again" did not happen.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[app, projectwindow]
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc surveyLayers(st: AppState): int =
  for l in st.survey.layers:
    if l.origin == loSurveyFile: inc result

var wait = 0
var since = getMonoTime()

proc runSteps(steps: seq[Step]; opts: RunOptions) =
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
        echo "  project: ", f.core.project.dir, " making ", f.projectWindows.making,
          " title ", f.windowTitle, " place ", f.projectWindows.place, " data ",
          f.projectWindows.data, " make ", f.markOf("newproject.make")
        discard f.savePng(getTempDir() / "tguiproject-failed.png")
        f.stop()
  let code = run(o)
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

withFixtures fx:
  let field = fx.dir / "field"
  createDir(field)
  let record = field / "stations-only.sgd"
  moveFile(fx.stationsSegd(), record)
  let survey = fx.surveySps()
  let config = fx.dir / "config"
  let places = fx.dir / "projects"
  createDir(config)
  var asked: seq[DialogKind]
  var answer: seq[string]
  let hook = proc (kind: DialogKind; location: string): seq[string] =
    asked.add kind
    answer
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  proc menu(sub, item: string; chosen: seq[string]; then: proc (f: FrameInfo): bool) =
    step("File > " & (if sub.len > 0: sub & " > " else: "") & item, proc (f: FrameInfo) =
      asked.setLen 0
      answer = chosen
      f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu." & item)
      if it.size.x > 0 and wait mod 5 == 0: f.click(it.centre)
      elif sub.len > 0 and f.markOf("menu." & sub).size.x > 0 and wait mod 10 == 0:
        f.click(f.markOf("menu." & sub).centre)
      then(f))
  proc press(mark: string; chosen: seq[string]; then: proc (f: FrameInfo): bool) =
    step("click " & mark, proc (f: FrameInfo) =
      answer = chosen, proc (f: FrameInfo): bool =
      let r = f.markOf(mark)
      if r.size.x > 0 and wait mod 6 == 3: f.click(r.centre)
      then(f))
  let dir = places / "field"
  let opts = RunOptions(openPaths: @[record], windowSize: (1400, 900), theme: forceDark,
    persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]), dialogs: hook)

  step("the file is shown", noop, proc (f: FrameInfo): bool =
    f.core.panels[f.core.findPanel(MainPanel)].laidOut and f.core.fileList.folder == field)
  menu("", "New project...", @[], proc (f: FrameInfo): bool = f.projectWindows.making)
  press("newproject.place", @[places], proc (f: FrameInfo): bool =
    f.projectWindows.place == places)
  step("its data folder is the folder listed", noop, proc (f: FrameInfo): bool =
    f.projectWindows.data == @[field])
  press("newproject.make", @[], proc (f: FrameInfo): bool =
    f.core.inProject and f.core.project.dir == dir and f.windowTitle == "viewSEG - field")
  proc importSurvey(f: FrameInfo) =
    f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: @[
      JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
      JoinFile(path: survey.x, kind: jkSps)])
  step("the survey imported is kept in the project", importSurvey, proc (f: FrameInfo): bool =
    f.core.project.survey == srLoaded and f.core.project.doc.hasStore)
  menu("", "Close project", @[], proc (f: FrameInfo): bool =
    not f.core.inProject and f.windowTitle == "viewSEG")
  menu("Recent projects", "project.0", @[], proc (f: FrameInfo): bool =
    f.core.inProject and f.core.project.survey == srLoaded and f.core.surveyLayers == 3)
  proc grow() =
    ## an original grows meanwhile: one more source
    var sf = readSps(survey.s)
    var p = sf.points[^1]
    p.point += 1
    p.pointName = ""
    p.easting += 50
    sf.points.add p
    sf.order.setLen 0
    sleep 20
    doAssert writeSps(sf, survey.s).len == 0
  proc closedAndGrown(f: FrameInfo): bool =
    result = not f.core.inProject
    if result: grow()
  menu("", "Close project", @[], closedAndGrown)
  menu("", "Open project...", @[dir], proc (f: FrameInfo): bool =
    f.core.inProject and f.core.project.offer)
  step("the Project window offers the update", noop, proc (f: FrameInfo): bool =
    f.projectWindows.shown and f.markOf("project.update").size.x > 0)
  press("project.update", @[], proc (f: FrameInfo): bool =
    f.core.project.survey == srLoaded and f.core.project.originals.len == 3 and
      f.core.project.originals[0].state == osAsCopied and f.core.project.doc.store.sources ==
      Shots + 1)
  runSteps(steps, opts)
  doAssert asked == @[dkOpenProject], $asked

  # Started again: the project open at the quit is opened again.
  var again: seq[Step]
  again.add Step(name: "the project open at the quit is opened again", act: noop,
    done: proc (f: FrameInfo): bool =
    f.core.inProject and f.core.project.dir == dir and f.core.project.survey == srLoaded and
      f.core.surveyLayers == 3)
  var o2 = opts
  o2.openPaths = @[]
  runSteps(again, o2)
echo "tguiproject: done"
