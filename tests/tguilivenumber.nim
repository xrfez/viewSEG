## A number typed into a box takes effect as it is typed, headless, one key at a time, with
## the box kept (Dear ImGui 1.92.9 writes a typed number back only when the box is left, unless
## `ImGuiItemFlags_LiveEditOnInputScalar` is set, which the frame loop does for every box):
##
## - the Generate dialog's Length box: the preview's key follows "4000" typed as 4, 40, 400,
##   4000, the box still has the keyboard;
## - the Store dialog's From box: the line under the boxes says what "2500" takes;
## - the compare window's From box: the window's option follows "150".
##
## Seen to fail: with the frame loop not setting the flag, the key kept the old length, the
## line the old window and the option NaN until the box was left.
##
## The windows are kept inside the main one (`keepInMainWindow`: a tooltip that becomes a window
## of its own takes a click on a loaded machine; see `tguienvelope`).
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[compare, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

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
    let path = fx.longTraceSegy(12_000, 2)
    let config = fx.dir / "config"
    createDir(config)
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc has(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

    proc nameWith(f: FrameInfo; prefix: string): string =
      for n in f.markNames(prefix): return n

    proc digit(box, typed: string; follows: proc (f: FrameInfo; typed: string): bool) =
      ## (a proc of its own: closures made in a loop body share one environment)
      step("type " & typed & " in " & box, proc (f: FrameInfo) = f.typeText($typed[^1]),
        proc (f: FrameInfo): bool =
        result = wait > 2 and follows(f, typed)
        if result: doAssert f.typing, box & " lost the keyboard after " & typed)

    proc keys(box, digits: string; follows: proc (f: FrameInfo; typed: string): bool) =
      ## Clicks `box`, types `digits` one key at a time and, after each, waits for `follows`
      ## (what the digits so far must have done) with the box still having the keyboard.
      step("click " & box, noop, proc (f: FrameInfo): bool =
        if not f.typing and wait mod 8 == 3: f.click(f.markOf(box).centre)
        f.typing and wait > 3)
      for n in 1 .. digits.len: digit(box, digits[0 ..< n], follows)

    step("the file opens", proc (f: FrameInfo) = f.keepInMainWindow,
      proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.has("plot.data") and f.core.referencesLoaded)

    # the Generate dialog
    step("Operations > Generate a reference...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("menu.Operations").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Generate a reference...")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(f.markOf("menu.Operations").centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.has("generate") and f.has("generate.length") and
        f.nameWith("generate.previewkey.").len > 0)
    keys("generate.length", "4000", proc (f: FrameInfo; typed: string): bool =
      # (a length shorter than the taper is refused in words, the box keeps what is typed)
      (" " & typed & ".0 ") in f.nameWith("generate.previewkey.") or
        (typed.len < 3 and f.has("generate.message")))
    step("the Generate dialog closes", noop, proc (f: FrameInfo): bool =
      if f.has("generate.cancel") and wait mod 6 == 3: f.click(f.markOf("generate.cancel").centre)
      not f.has("generate"))

    # the compare window
    proc setCompare(f: FrameInfo) =
      let base = f.core.sessions[0].base
      f.apply Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: base)
      f.apply Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: base + 1)

    step("A and B are set, the window opens", setCompare, proc (f: FrameInfo): bool =
      f.has("compare.from") and f.core.compareOpen and wait > 10)
    keys("compare.from", "150", proc (f: FrameInfo; typed: string): bool =
      f.core.compareOptions.fromMs == parseFloat(typed))
    proc closeCompare(f: FrameInfo) =
      f.apply Command(kind: ckCompareWindow, compareOpen: false)

    step("the compare window closes", closeCompare, proc (f: FrameInfo): bool =
      not f.has("compare.from"))

    # the Store dialog
    proc toPlot(f: FrameInfo) =
      f.moveMouse(f.markOf("plot.data").centre)

    step("the plot's menu, then Store", toPlot, proc (f: FrameInfo): bool =
      if f.has("store"): return true
      if f.has("plot.menu.store"):
        if wait mod 6 == 3: f.click(f.markOf("plot.menu.store").centre)
      elif wait mod 10 == 2: f.click(f.markOf("plot.data").centre, 3)
      false)
    keys("store.from", "2500", proc (f: FrameInfo; typed: string): bool =
      let n = parseInt(typed)
      let words = f.nameWith("store.taken:")
      # "Takes 2 500 to 11 999 ms: ..." (the digits grouped by thousands)
      let grouped = if n >= 1000: $(n div 1000) & " " & align($(n mod 1000), 3, '0') else: $n
      (grouped & " to 11 999 ms") in words)

    proc onFrame(f: FrameInfo) =
      inc wait
      if failed.len > 0: return
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
        failed = steps[at].name & " did not happen; key " & f.nameWith("generate.previewkey.") &
          " taken " & f.nameWith("store.taken:")
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguilivenumber: ", steps.len, " steps"

when isMainModule: main()
