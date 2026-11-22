## The vibrator signature window on samples/vib/vib_signature.sgd, with the
## sample's first trace stored as the reference and chosen, in the running
## frontend, read from the window's own picture:
##
## - each of the five plots draws its curves (pixels in the plot's area in the
##   curves' colours) and its y axis's tick labels (text pixels left of the
##   area), also after the masses are typed one digit at a time, the unit is
##   switched and the window scrolled;
## - the masses row reads `reaction [..] baseplate [..] [kg|lb]` in that order,
##   the active unit drawn selected (its button's colour differs from the other's and
##   follows a click), no stray unit word after the first box;
## - the note under the row is wrapped inside the window, the Ref role offers the
##   project reference first.
##
## `VIBFIX_SHOT=<file.png>` saves the frame once the plots are drawn.
##
## Seen to fail: with the plots' y limits set to the first point's value only (a
## test of the pixel check), "... 0 curve pixels"; with the unit switch drawn as before,
## after the baseplate box, "the unit switch is not after the baseplate".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[analysis, geometry, state, references, units]
import viewSEG/view/[analysisview, curveplot, theme]
import viewSEG/ui/imgui/app
import utils/[curvepixels, fixtures, waiting]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
  "vib_signature.sgd"

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =
  withFixtures fx:
    doAssert fileExists(sample), "no sample " & sample
    var steps: seq[Step] = @[]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    var refId = ""
    var frames = 0
    var drawn: set[0 .. 4] = {}
    proc after(n: int): proc (f: FrameInfo): bool =
      var seen = 0
      result = proc (f: FrameInfo): bool =
        inc seen
        seen >= n
    proc checkPlots(f: FrameInfo) =
      ## The plots whole in view: curve pixels and y tick labels in the picture.
      let plots = f.core.plots[0].result.curvePlots(f.theme, f.core.settings.units)
      doAssert plots.len == 5, $plots.len
      let win = f.markOf("new plot 1")
      let top = f.markOf("new plot 1.summary")
      for i, p in plots:
        let r = f.markOf("new plot 1.plot " & $i & ".data")
        if r.size.x == 0: continue
        let child = f.markOf("new plot 1.plots scroll") # the plots' own region, when they scroll
        if r.pos.y < top.pos.y + top.size.y or r.pos.y + r.size.y > win.pos.y + win.size.y - 30 or
            (child.size.y > 0 and r.pos.y + r.size.y > child.pos.y + child.size.y):
          continue # partly scrolled out of view
        let what = p.yLabel & " (plot " & $(i + 1) & ")"
        var ink = 0
        let missing = f.missingCurves(r, p)
        for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
          for x in max(0, int(r.pos.x) - 70) ..< int(r.pos.x) - 1:
            if distance(f.readPixel(x, y), f.theme.roles[rlText]) <= 90: inc ink
        # (the legend is outside the area: its swatches no longer count as curve pixels)
        doAssert missing.len == 0, what & ": curves not drawn: " & $missing
        doAssert ink > 12, what & ": " & $ink & " pixels of y tick labels"
        drawn.incl i
    proc scrollTo(notches: float32) =
      for k in 0 ..< 4:
        step("scroll " & $notches, proc (f: FrameInfo) =
          let c = f.markOf("new plot 1.plot 2.data").centre
          f.moveMouse(c)
          f.scrollWheel(c, notches), after(4))
    step("the file shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len > 0 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
    step("a reference stored", proc (f: FrameInfo) =
      f.apply(Command(kind: ckStoreReference, refStore: StoredReference(name: "pilot",
        trace: f.core.sessions[0].base, fromMs: 0, toMs: -1))),
      proc (f: FrameInfo): bool =
        for e in f.core.references.entries:
          if e.name == "pilot": refId = e.id
        refId.len > 0)
    step("chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: refId)),
      proc (f: FrameInfo): bool = f.core.chosenReference == refId)
    step("a vibrator signature", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[b, b + 1, b + 2, b + 3], plotParams: AnalysisParams(harmonics: 5,
            details: true))),
      proc (f: FrameInfo): bool =
        f.core.plots.len == 1 and not f.core.plots[0].waiting and
          f.core.plots[0].result.problem.len == 0 and f.core.plots[0].result.plots.len == 4 and
          f.markOf("new plot 1.plot 2.data").size.x > 0)
    # the masses typed a digit at a time, results arriving behind the keystrokes
    var digits = 0
    step("the masses typed", noop, proc (f: FrameInfo): bool =
      const rs = [3.0, 36, 360, 3600, 3600, 3600, 3600, 3600]
      const bs = [NaN, NaN, NaN, NaN, 1, 18, 180, 1800]
      if digits < rs.len:
        var params = f.core.plots[0].params
        params.reactionMassKg = rs[digits]
        params.baseplateMassKg = bs[digits]
        f.apply(Command(kind: ckPlotDisplay, plot: 1, plotParams: params))
        inc digits
        return false
      f.core.plots[0].params.baseplateMassKg == 1800 and not f.core.plots[0].waiting and
        f.core.plots[0].result.plots.len == 5 and
        f.markOf("new plot 1.plot 2.data").size.x > 0)
    step("settle", noop, after(20))
    step("the top plots drawn", noop, proc (f: FrameInfo): bool =
      checkPlots(f)
      true)
    scrollTo(-3)
    step("the bottom plots drawn", noop, proc (f: FrameInfo): bool =
      checkPlots(f)
      let dir = getEnv("VIBFIX_SHOT")
      if dir.len > 0: discard f.savePng(dir)
      true)
    step("all five seen", noop, proc (f: FrameInfo): bool =
      doAssert drawn == {0 .. 4}, "plots checked: " & $drawn
      true)
    scrollTo(3)
    # the roles' table is a popover until the Roles button is clicked
    step("the roles opened", proc (f: FrameInfo) =
      let c = f.markOf("new plot 1.roles").centre
      f.moveMouse(c)
      f.pressMouse(c, true)
      f.pressMouse(c, false),
      proc (f: FrameInfo): bool = f.markOf("new plot 1.role Ref").size.x > 0)
    step("the Ref role offers the project reference", noop, proc (f: FrameInfo): bool =
      doAssert f.markOf("new plot 1.role Ref").size.x > f.markOf("new plot 1.role GF").size.x,
        "the Ref role is not wide enough for the project reference's name"
      true)
    step("the roles closed", proc (f: FrameInfo) =
      let c = f.markOf("new plot 1.verdict").centre
      f.moveMouse(c)
      f.pressMouse(c, true)
      f.pressMouse(c, false),
      proc (f: FrameInfo): bool = f.markOf("new plot 1.role Ref").size.x == 0)
    # the masses are in the settings wheel
    step("the wheel opened", proc (f: FrameInfo) =
      let c = f.markOf("new plot 1.wheel").centre
      f.moveMouse(c)
      f.pressMouse(c, true)
      f.pressMouse(c, false),
      proc (f: FrameInfo): bool = f.markOf("new plot 1.reaction mass").size.x > 0)
    # the masses row, its order, its switch
    step("the masses row", noop, proc (f: FrameInfo): bool =
      let (a, b) = (f.markOf("new plot 1.reaction mass"), f.markOf("new plot 1.baseplate mass"))
      let (kg, lb) = (f.markOf("new plot 1.unit kg"), f.markOf("new plot 1.unit lb"))
      doAssert a.size.x > 0 and b.size.x > 0 and kg.size.x > 0 and lb.size.x > 0
      doAssert a.pos.x < b.pos.x and b.pos.x + b.size.x <= kg.pos.x + 1 and
        kg.pos.x < lb.pos.x, "the unit switch is not after the baseplate: " & $[a, b, kg, lb]
      doAssert abs(a.pos.y - lb.pos.y) < 8 and abs(a.pos.y - b.pos.y) < 8,
        "the row is not one line: " & $[a, b, kg, lb]
      # the active unit (metric) is the selected one: its button's colour is not lb's
      let on = f.readPixel(int(kg.pos.x) + 4, int(kg.centre.y))
      let off = f.readPixel(int(lb.pos.x) + 4, int(lb.centre.y))
      doAssert distance(on, off) > 20, "kg is not drawn selected: " & $on & " " & $off
      # the note is wrapped inside the window
      let win = f.markOf("new plot 1")
      let note = f.markOf("new plot 1.summary")
      doAssert note.pos.x + note.size.x <= win.pos.x + win.size.x + 1,
        "the note runs past the window: " & $note & " in " & $win
      true)
    step("lb clicked", proc (f: FrameInfo) =
      let c = f.markOf("new plot 1.unit lb").centre
      f.moveMouse(c)
      f.pressMouse(c, true)
      f.pressMouse(c, false),
      proc (f: FrameInfo): bool = f.core.settings.units == usImperial)
    step("lb is selected, nothing stored", proc (f: FrameInfo) =
      f.moveMouse(vec2(f.markOf("new plot 1").pos.x + 300, f.markOf("new plot 1").pos.y + 20)),
      proc (f: FrameInfo): bool =
      let kg = f.markOf("new plot 1.unit kg")
      let lb = f.markOf("new plot 1.unit lb")
      doAssert f.core.plots[0].params.reactionMassKg == 3600 and
        f.core.plots[0].params.baseplateMassKg == 1800, "the switch changed the masses"
      f.index > 0 and distance(f.readPixel(int(lb.pos.x) + 4, int(lb.centre.y)),
        f.readPixel(int(kg.pos.x) + 4, int(kg.centre.y))) > 20)
    step("the wheel closed", proc (f: FrameInfo) =
      let c = f.markOf("new plot 1.verdict").centre
      f.moveMouse(c)
      f.pressMouse(c, true)
      f.pressMouse(c, false),
      proc (f: FrameInfo): bool = f.markOf("new plot 1.reaction mass").size.x == 0)
    step("settle in lb", noop, after(20))
    step("the plots in lb", noop, proc (f: FrameInfo): bool =
      drawn = {}
      checkPlots(f)
      doAssert drawn.card >= 2, "plots checked in lb: " & $drawn
      true)
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
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[sample], windowSize: (1600, 1050),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguivibplots: ok"

when isMainModule:
  main()
