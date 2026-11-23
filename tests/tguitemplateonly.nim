## The Seismic window's "Only traces in the template" button in the running frontend,
## headless, with real clicks, on `mapSps`'s S and R files and the shot of source 1003 of
## line 1 (`mapShotSegd`: a time break and 63 receivers, its X record plans 30):
##
## - the X file loaded: the button is enabled and off; the window's title says nothing;
## - a click turns it on: the plot keeps the 30 traces of the template, the title says
##   "template only: 30 of 63", and the setting is kept with the plot's choices;
## - a second click turns it off: all 63 traces, no note;
## - the X file unloaded: the button is drawn greyed, a click changes nothing, and its
##   tooltip says a relation file is needed.
##
## Seen to fail: with the button's `enabled` left out, the click on the greyed button turned
## the choice on ("the greyed button took the click").
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves template-only-*.png there.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc runMain() =
  withFixtures fx:
    let sps = fx.mapSps()
    let xps = fx.mapXps()
    let shotPath = fx.mapShotSegd(0, 2)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc click(f: FrameInfo; p: Vec2) =
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false)
    proc button(f: FrameInfo): Rect = f.markOf("plot.template only")
    proc title(f: FrameInfo): string = f.windowName("plot")
    proc filter(f: FrameInfo): TraceFilter = f.core.panels[f.core.findPanel(MainPanel)].layers[0].filter
    proc traces(f: FrameInfo): int = f.core.panels[f.core.findPanel(MainPanel)].layout.traces

    step("shown, with the relation file", noop, proc (f: FrameInfo): bool =
      result = f.core.sessions.len == 1 and f.traces == 63 and f.button.size.x > 0 and
        f.core.survey.layers.len == 4 and wait > 8 and f.core.jobs.active.len == 0 and
        f.core.templateView(f.core.findPanel(MainPanel)).available
      if result:
        doAssert not f.filter.templateOnly and "template only" notin f.title
        f.shot("template-only-off.png"))
    step("clicked", proc (f: FrameInfo) =
      f.click(f.button.centre), proc (f: FrameInfo): bool =
      result = f.filter.templateOnly and f.traces == 30 and
        "template only: 30 of 63" in f.title and wait > 8
      if result:
        doAssert f.core.settings.plot.templateOnly, "kept with the plot's choices"
        f.moveMouse(vec2(4, 4))
        f.shot("template-only-on.png"))
    step("clicked again", proc (f: FrameInfo) =
      f.click(f.button.centre), proc (f: FrameInfo): bool =
      result = not f.filter.templateOnly and f.traces == 63 and
        "template only" notin f.title and wait > 4)
    proc unloadX(f: FrameInfo) =
      f.moveMouse(vec2(4, 4))
      var id = NoSurveyLayer
      for l in f.core.survey.layers:
        if l.path == xps: id = l.id
      f.apply Command(kind: ckUnloadSurvey, layer: id)
    step("the relation file unloaded", unloadX, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len == 3 and wait > 8 and f.core.jobs.active.len == 0 and
        not f.core.templateView(f.core.findPanel(MainPanel)).available)
    step("hovering the greyed button", proc (f: FrameInfo) =
      f.moveMouse(f.button.centre), proc (f: FrameInfo): bool =
      result = wait > 40
      if result: f.shot("template-only-greyed.png"))
    step("clicked while greyed", proc (f: FrameInfo) =
      f.click(f.button.centre), proc (f: FrameInfo): bool =
      result = wait > 6
      if result:
        doAssert not f.filter.templateOnly, "the greyed button took the click"
        doAssert not f.core.settings.plot.templateOnly)

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, xps, shotPath],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =

  runMain()

when isMainModule:
  main()
