## The first-break overlay's model in the running frontend, headless, driven by real clicks:
## a click on the key opens where the model comes from; "Use this record's fit" keeps the
## record's fitted velocity and intercept as the given model; with a given model held for
## the record, whose source is named wrongly (offsets 100 m too long), the bars sit off the
## picks, the key is the same width and marks it "given" with the count off it (the tooltip says
## how far the record is off), and
## "Fitted to this record" gives the fit back.
##
## With `VIEWSEG_SCREENSHOTS=<dir>` the window is saved with the popover open and with the
## given model on the moved record (breakmodel-*.png); with `VIEWSEG_SHOT_FILE` too, that file
## (a shot of the land sample) is shown instead of the synthetic one.
##
## The popover also has the bars' colours and size and, behind the "Two layers" checkbox, the
## second velocity and crossover; Reset colours puts the colours back.
##
## Seen to fail: with the click on the key not opening the popover, "the key did not open
## the popover"; with "Use this record's fit" not switching to Given, "the fit was not kept as
## the given model"; with the given marker left out of the key, "the key does not say it is given"; with the
## second velocity shown always, "the second velocity shows only with Two layers".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils]
import std/math
import parseSEG
import viewSEG/core/[breakmodel, firstbreaks, geometry, join, panels, state]
import viewSEG/ui/imgui/app
import utils/[breakfiles, fbpickfiles, fixtures, waiting]

var
  waited = 0            ## frames since the step's action
  fitBefore: BreakModel ## the record's fit when "Use this record's fit" was clicked

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc ready(f: FrameInfo): bool =
  f.panel.laidOut and f.core.tiles(f.core.findPanel(MainPanel)).len > 0 and
    f.core.jobs.active.len == 0 and f.markOf("plot.data").size.x > 0

proc shown(f: FrameInfo): bool =
  let i = f.core.breaksIndex(f.core.findPanel(MainPanel))
  i >= 0 and f.core.firstBreaks[i].state == bkDone and f.markOf("plot.first break key").size.x > 0

proc moved(i: int; k: var TraceKeys): float64 =
  k.offset = offsetOf(i) + 100
  arrivalMs(offsetOf(i))

proc runSteps(name: string; opts: RunOptions; steps: seq[Step]) =
  var at = 0
  var started = false
  var wait = 0
  var since = getMonoTime()
  var failed = ""
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
      waited = wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 400, since):
        failed = name & ": " & steps[at].name & " did not happen"
        f.stop()
  var o = opts
  o.onFrame = onFrame
  let code = run(o)
  doAssert code == 0, name & ": run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, name & ": stopped at " & steps[min(at, steps.high)].name

proc main*() =
  withFixtures fx:
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    let file = if getEnv("VIEWSEG_SHOT_FILE").len > 0: getEnv("VIEWSEG_SHOT_FILE")
               else: fx.customShot("moved.sgy", Traces, moved)
    let config = fx.dir / "config-model"
    createDir(config)
    let opts = RunOptions(openPaths: @[file], windowSize: (1400, 900), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shoot(f: FrameInfo; what: string) =
      if shots.len > 0:
        createDir(shots)
        doAssert f.savePng(shots / ("breakmodel-" & what & ".png")), "cannot save " & what
    func display(f: FrameInfo): DisplaySettings = f.panel.layers[0].display
    func now(f: FrameInfo): FirstBreaks =
      f.core.shownBreaks(f.core.findPanel(MainPanel))

    proc reopen(f: FrameInfo) =
      if f.markOf("plot.first break model fitted").size.x == 0:
        f.click(f.markOf("plot.first break key settings").centre)
    step("opened", noop, proc (f: FrameInfo): bool = f.ready)
    step("the overlay on", proc (f: FrameInfo) =
      var d = f.display
      d.firstBreaks = true
      f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
      proc (f: FrameInfo): bool = f.ready and f.shown and f.markOf("plot.first break key").size.x > 0)
    step("a click on the key", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break key settings").centre), proc (f: FrameInfo): bool =
      result = f.markOf("plot.first break model use fit").size.x > 0
      doAssert waited < 200 or result, "the key did not open the popover"
      if result:
        f.shoot("popover-fitted"))
    step("move onto the button", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.first break model use fit").centre), proc (f: FrameInfo): bool =
      waited > 5)
    step("use this record's fit", proc (f: FrameInfo) =
      # (the given model then guides a new picking: the fit it copied is the one before)
      fitBefore = f.core.firstBreaks[f.core.breaksIndex(f.core.findPanel(MainPanel))].fitAsModel
      f.click(f.markOf("plot.first break model use fit").centre), proc (f: FrameInfo): bool =
      # (it is shown again once the given model's guided picking has finished)
      result = f.display.breakModel.source == bmGiven and f.shown
      doAssert waited < 200 or result, "the fit was not kept as the given model"
      if result:
        let m = f.display.breakModel
        doAssert m.v1 == fitBefore.v1 and m.interceptMs == fitBefore.interceptMs, $m
        doAssert f.now.keyParts.given, "the key does not say it is given")
    step("the popover with the given numbers", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.first break model v1").size.x > 0 and f.shown
      if result: f.shoot("popover-given"))
    # a typed velocity is applied on Enter, and Escape puts the old one back. Seen to fail: with
    # the box applying whatever was typed when it is left, "Escape applied the typed velocity"
    var v1Before = 0.0
    step("click into the velocity box", proc (f: FrameInfo) =
      v1Before = f.display.breakModel.v1
      f.click(f.markOf("plot.first break model v1").centre), proc (f: FrameInfo): bool =
      waited > 5)
    step("type and Escape", proc (f: FrameInfo) =
      f.typeText("7")
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      result = waited > 20
      doAssert f.display.breakModel.v1 == v1Before, "Escape applied the typed velocity: " &
        $f.display.breakModel.v1)
    step("the popover after Escape", reopen, proc (f: FrameInfo): bool =
      f.markOf("plot.first break model v1").size.x > 0 and waited > 5)
    step("click into the velocity box again", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break model v1").centre), proc (f: FrameInfo): bool =
      waited > 5)
    step("type and Enter", proc (f: FrameInfo) =
      f.typeText("7")
      f.pressKey(skEnter, true)
      f.pressKey(skEnter, false), proc (f: FrameInfo): bool =
      result = f.display.breakModel.v1 != v1Before
      doAssert waited < 200 or result, "Enter did not apply the typed velocity")
    var twoBefore = false
    step("Two layers is a checkbox", proc (f: FrameInfo) =
      twoBefore = f.display.breakModel.segments == 2
      doAssert f.markOf("plot.first break model two layers").size.x > 0, "no Two layers"
      doAssert (f.markOf("plot.first break model v2").size.x > 0) == twoBefore,
        "the second velocity shows only with Two layers"
      f.moveMouse(f.markOf("plot.first break model two layers").centre),
      proc (f: FrameInfo): bool = waited > 5)
    step("click Two layers", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break model two layers").centre), proc (f: FrameInfo): bool =
      result = (f.display.breakModel.segments == 2) != twoBefore
      doAssert waited < 200 or result, "Two layers did not switch")
    step("the second layer's boxes follow", noop, proc (f: FrameInfo): bool =
      result = (f.markOf("plot.first break model v2").size.x > 0) == (not twoBefore)
      doAssert waited < 200 or result, "the second velocity does not follow the checkbox"
      if result:
        doAssert f.markOf("plot.first break pick colour").size.x > 0 and
          f.markOf("plot.first break model colour").size.x > 0 and
          f.markOf("plot.first break reset colours").size.x > 0, "no colours in the popover"
        f.shoot("popover-look"))
    step("click Large", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break size large").centre), proc (f: FrameInfo): bool =
      result = f.display.breakSize == bzLarge
      doAssert waited < 200 or result, "Large did not set the size")
    step("a chosen colour", proc (f: FrameInfo) =
      var d = f.display
      d.breakPickColour = Rgba(r: 10, g: 200, b: 30, a: 255)
      f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
      proc (f: FrameInfo): bool = f.display.breakPickColour.a == 255 and waited > 5)
    step("Reset colours", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break reset colours").centre), proc (f: FrameInfo): bool =
      result = f.display.breakPickColour.a == 0
      doAssert waited < 200 or result, "Reset colours kept the colour"
      doAssert f.display.breakSize == bzLarge, "Reset colours changed the size")
    step("a model held from another record", proc (f: FrameInfo) =
      var d = f.display
      d.breakModel = BreakModel(source: bmGiven, v1: 2500, interceptMs: 20)
      f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
      proc (f: FrameInfo): bool =
      let synthetic = getEnv("VIEWSEG_SHOT_FILE").len == 0
      result = f.shown and f.now.isGiven and (f.now.medianDiffMs < -30 or not synthetic)
      if result and synthetic:
        doAssert f.now.offModel * 10 > f.now.compared * 9, $f.now.offModel
        doAssert "median" in f.now.statusWords
      if result: f.shoot("moved-source"))
    step("the popover again", reopen, proc (f: FrameInfo): bool =
      f.markOf("plot.first break model fitted").size.x > 0 and waited > 5)
    step("move onto Fitted", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.first break model fitted").centre), proc (f: FrameInfo): bool =
      waited > 5)
    step("fitted again", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break model fitted").centre), proc (f: FrameInfo): bool =
      result = f.display.breakModel.source == bmFitted and not f.now.isGiven
      doAssert waited < 200 or result, "Fitted to this record did not give the fit back")
    # the key's two parts hide and show the model bars and the pick bars; the popover's boxes
    # do the same; the wheel at the key's end opens it. Seen to fail: with the click on a part
    # still opening the popover, "a click on the model part did not hide the model"; with the
    # popover's boxes left out, "no Show picks box".
    step("close the popover", proc (f: FrameInfo) =
      (f.pressKey(skEscape, true); f.pressKey(skEscape, false)),
      proc (f: FrameInfo): bool = f.markOf("plot.first break model fitted").size.x == 0)
    step("a click on the model part", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break key model").centre), proc (f: FrameInfo): bool =
      result = not f.display.breakShowModel
      doAssert waited < 200 or result, "a click on the model part did not hide the model"
      if result:
        doAssert f.display.breakShowPicks, "the picks went with the model"
        doAssert f.now.state == bkDone and f.now.modelled > 0, "hiding changed the counts"
        f.shoot("picks-only"))
    step("a click on the pick part", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break key pick").centre), proc (f: FrameInfo): bool =
      result = not f.display.breakShowPicks
      doAssert waited < 200 or result, "a click on the pick part did not hide the picks"
      if result:
        doAssert not f.display.breakShowModel, "the model came back"
        doAssert f.markOf("plot.first break key").size.x > 0, "the key went with both"
        f.shoot("both-hidden"))
    step("the model part again", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break key model").centre), proc (f: FrameInfo): bool =
      result = f.display.breakShowModel
      doAssert waited < 200 or result, "a second click did not show the model"
      if result: f.shoot("model-only"))
    step("the wheel opens the popover", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break key settings").centre), proc (f: FrameInfo): bool =
      result = f.markOf("plot.first break show picks").size.x > 0
      doAssert waited < 200 or result, "the wheel did not open the popover"
      if result:
        doAssert f.markOf("plot.first break show model").size.x > 0, "no Show model box")
    step("move onto Show picks", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("plot.first break show picks").centre),
      proc (f: FrameInfo): bool = waited > 5)
    step("the Show picks box", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break show picks").centre), proc (f: FrameInfo): bool =
      result = f.display.breakShowPicks and f.display.breakShowModel
      doAssert waited < 200 or result, "the Show picks box did not show the picks"
      if result: f.shoot("popover-boxes"))
    # the popover's Picking choice re-picks the record once; the weak picks' box is a drawing
    # choice only. Seen to fail: with the Picking radio buttons left out, "no Picking choice";
    # with the choice not in the key, "the picks were not made again".
    step("the Picking choice is there", noop, proc (f: FrameInfo): bool =
      result = f.markOf("plot.first break pick on smoothed").size.x > 0
      doAssert waited < 200 or result, "no Picking choice in the popover"
      if result:
        doAssert f.markOf("plot.first break pick on recorded").size.x > 0 and
          f.markOf("plot.first break show weak").size.x > 0, "no As recorded or weak picks box"
        doAssert f.now.pickedOn == pbSmoothed and f.now.highCutHz == 60
        f.shoot("popover-picking"))
    step("the Show weak picks box", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break show weak").centre), proc (f: FrameInfo): bool =
      result = f.display.breakShowWeak
      doAssert waited < 200 or result, "the Show weak picks box did not set the switch")
    step("click As recorded", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break pick on recorded").centre),
      proc (f: FrameInfo): bool =
      result = f.display.breakPickOn == pbAsRecorded and f.shown and f.core.jobs.active.len == 0 and
        f.now.pickedOn == pbAsRecorded and f.now.key.pick == pbAsRecorded
      doAssert waited < 400 or result, "the picks were not made again on the samples as recorded")
    step("click Smoothed", proc (f: FrameInfo) =
      f.click(f.markOf("plot.first break pick on smoothed").centre),
      proc (f: FrameInfo): bool =
      result = f.display.breakPickOn == pbSmoothed and f.shown and f.core.jobs.active.len == 0 and
        f.now.pickedOn == pbSmoothed
      doAssert waited < 400 or result, "the picks were not made again on the smoothed copy")
    runSteps("model", opts, steps)
    if shots.len > 0:
      # pictures for a look: the overlay at normal zoom and, on records of more traces,
      # dense (bars close together) and denser (two lines); the key with a given model;
      # and the gain type none with its amount greyed
      for (label, traces) in [("overlay-normal", Traces), ("overlay-dense", 150),
          ("overlay-lines", 600)]:
        let name = label
        let big = fx.customShot(name & ".sgy", traces, moved)
        let cfg = fx.dir / ("config-" & name)
        createDir(cfg)
        var o = opts
        o.openPaths = @[big]
        o.configDir = some(cfg)
        var more: seq[Step]
        proc add(n: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
          more.add Step(name: n, act: act, done: done)
        add("opened", noop, proc (f: FrameInfo): bool = f.ready)
        add("on", proc (f: FrameInfo) =
          var d = f.display
          d.firstBreaks = true
          d.mode = dmWiggle
          d.fills = {wfPositive}
          d.gain = dgFixed
          d.breakModel = BreakModel(source: bmGiven, v1: 2500, interceptMs: 20)
          f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
          proc (f: FrameInfo): bool = f.ready and f.shown and waited > 20)
        add("shot", noop, proc (f: FrameInfo): bool =
          f.shoot(name)
          waited > 25)
        if name == "overlay-normal":
          add("gain none", proc (f: FrameInfo) =
            var d = f.display
            d.gain = dgNone
            d.gainDb = 6
            f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
            proc (f: FrameInfo): bool = waited > 20)
          add("shot none", noop, proc (f: FrameInfo): bool =
            f.shoot("gain-none")
            waited > 25)
        runSteps(name, o, more)
      # a slowly building break in noise, whose weak picks are hidden and then shown
      block weakPicks:
        let big = fx.fbShot("weak.sgy")
        let cfg = fx.dir / "config-weak"
        createDir(cfg)
        var o = opts
        o.openPaths = @[big]
        o.configDir = some(cfg)
        var more: seq[Step]
        proc add(n: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
          more.add Step(name: n, act: act, done: done)
        add("opened", noop, proc (f: FrameInfo): bool = f.ready)
        add("on", proc (f: FrameInfo) =
          var d = f.display
          d.firstBreaks = true
          d.mode = dmWiggle
          d.fills = {wfPositive}
          d.gain = dgFixed
          d.breakSize = bzLarge
          f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
          proc (f: FrameInfo): bool = f.ready and f.shown and waited > 20)
        add("hidden", noop, proc (f: FrameInfo): bool =
          f.shoot("weak-hidden")
          waited > 25)
        add("weak", proc (f: FrameInfo) =
          var d = f.display
          d.breakShowWeak = true
          f.apply(Command(kind: ckDisplay, panel: MainPanel, display: d)),
          proc (f: FrameInfo): bool = f.display.breakShowWeak and waited > 20)
        add("shown", noop, proc (f: FrameInfo): bool =
          f.shoot("weak-shown")
          waited > 25)
        runSteps("weak", o, more)
  echo "tguibreakmodel: ok"

when isMainModule:
  main()
