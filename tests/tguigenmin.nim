## The Generate dialog at its smallest: settings, both plots and the buttons
## stay inside the window.
##
## Seen to fail: with the minimum height left at font×36 and the buttons
## drawn after the plots, shrinking the dialog left the spectrum mark empty
## and Generate below the window.

import std/[math, monotimes, options, os, strutils]
import imguin/cimgui
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; q: Vec2) =
  f.moveMouse(q)
  f.pressMouse(q, true, 1)
  f.pressMouse(q, false, 1)

const Dialog = "Generate a reference###generate-reference"

proc fontPx(): float32 =
  igGetFontSize() * igGetIO_Nil().DisplayFramebufferScale.x

proc inside(item, win: Rect): bool =
  item.size.x > 0 and item.size.y > 0 and
    item.pos.x >= win.pos.x - 1 and
    item.pos.y >= win.pos.y - 1 and
    item.pos.x + item.size.x <= win.pos.x + win.size.x + 1 and
    item.pos.y + item.size.y <= win.pos.y + win.size.y + 1

proc shrinkDialog() =
  let font = igGetFontSize()
  igSetWindowSize_Str(Dialog.cstring, ImVec2_c(x: font * 20, y: font * 20),
    ImGui_Cond_Always.cint)

proc main*() =
  const root = currentSourcePath().parentDir.parentDir
  withFixtures fx:
    let path = root / "samples" / "land" / "shots.sgy"
    doAssert fileExists(path), path
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

    proc previewKey(f: FrameInfo): string =
      let names = f.markNames("generate.previewkey.")
      if names.len == 0: "" else: names[^1]

    proc describe(f: FrameInfo): string =
      "window " & $f.markOf("generate") & " font " & $fontPx() &
        " ok " & $f.markOf("generate.ok") & " cancel " & $f.markOf("generate.cancel") &
        " signal " & $f.markOf("generate.preview.data") &
        " spectrum " & $f.markOf("generate.spectrum.data") &
        " param " & $f.markOf("generate.param") &
        " boost " & $f.markOf("generate.boost") & " key " & f.previewKey

    proc fits(f: FrameInfo): bool =
      let win = f.markOf("generate")
      let font = fontPx()
      let tall = font * 6
      let signal = f.markOf("generate.preview.data")
      let spec = f.markOf("generate.spectrum.data")
      win.size.y >= font * 60 - 2 and win.size.y <= font * 60 + 8 and
        inside(f.markOf("generate.ok"), win) and inside(f.markOf("generate.cancel"), win) and
        signal.size.y >= tall and spec.size.y >= tall and
        signal.size.x > font * 8 and spec.size.x > font * 8

    proc pick(f: FrameInfo; item, opener, needle: string): bool =
      let row = f.markOf(item)
      if row.size.x > 0 and wait mod 4 == 0: f.click(row.centre)
      elif row.size.x == 0 and wait mod 8 == 0: f.click(f.markOf(opener).centre)
      row.size.x == 0 and needle in f.previewKey

    step("the file opens", noop, proc (f: FrameInfo): bool =
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      p.laidOut and f.markOf("plot.data").size.x > 0 and f.core.referencesLoaded)

    step("Operations > Generate a reference...", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("menu.Operations").centre), proc (f: FrameInfo): bool =
      let it = f.markOf("menu.Generate a reference...")
      let bar = f.markOf("menu.Operations")
      if it.size.x == 0:
        if wait mod 8 == 0: f.click(bar.centre)
      elif wait mod 6 == 3: f.click(it.centre)
      f.markOf("generate").size.x > 0 and f.markOf("generate.preview.data").size.x > 0 and
        f.markOf("generate.spectrum.data").size.x > 0)

    step("the minimum window holds both plots and the buttons", proc (f: FrameInfo) =
      shrinkDialog(), proc (f: FrameInfo): bool =
      if not f.fits and wait > 20:
        failed = "default minimum: " & f.describe
        f.stop()
      f.fits)

    step("Kaiser and dB/Hz still fit at the minimum", noop, proc (f: FrameInfo): bool =
      if "tpKaiser" notin f.previewKey:
        return f.pick("generate.shape tpKaiser", "generate.shape", "tpKaiser") and false
      if "dB/Hz" notin f.previewKey:
        return f.pick("generate.law dB/Hz", "generate.law", "dB/Hz") and false
      if f.markOf("generate.param").size.x == 0 or f.markOf("generate.boost").size.x == 0:
        return false
      if not f.fits and wait > 40:
        failed = "full minimum: " & f.describe
        f.stop()
      f.fits)

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
      elif overdue(wait, 500, since):
        failed = steps[at].name & " did not happen; " & f.describe
        f.stop()

    let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000), theme: forceDark,
      persist: true, configDir: some(config), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguigenmin: ", steps.len, " steps"

when isMainModule: main()
