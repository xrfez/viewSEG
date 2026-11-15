## The Seismic window in a small main window, in the running frontend,
## headless: a 1152 x 720 laptop screen at 125 % gives a window of
## 1036 x 648 pixels (the size a desktop without a window manager opens),
## where the strip wraps to six lines:
##
## - the plot keeps its room under the strip (at least five lines of text
##   high: the strip's lines scroll in a region of their own instead), and
##   is drawn;
## - agent control's `wait` settles and the plot's screenshot is a picture
##   of it (a plot with no pixels, which a window this size no longer gives,
##   has "no room to draw" and its screenshot is refused in words:
##   `tagenttools`).
##
## Seen to fail: with the strip taking every line it wraps to, "the plot has
## no room" ... "the record did not happen" (the plot 0 x 0 asks for
## nothing; `wait` busy for ever: "not drawn yet").
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[importutils, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/remote/tools
import viewSEG/ui/imgui/app {.all.}
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc complete(f: FrameInfo): bool =
  let t = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and t.len > 0 and t[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

if getEnv("SDL_VIDEO_DRIVER") notin ["", "x11"]:
  # SDL's X11 driver takes its content scale from SDL_VIDEO_X11_SCALING_FACTOR
  echo "tguismall: skipped (SDL_VIDEO_DRIVER=", getEnv("SDL_VIDEO_DRIVER"), ")"
  quit 0

privateAccess(FrameInfo)

withFixtures fx:
  let file = fx.surveySegy()
  let config = fx.dir / "config"
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard
  var frames = 0
  proc settled(n: int): proc (f: FrameInfo): bool =
    result = proc (f: FrameInfo): bool =
      inc frames
      frames >= n

  step("the record", noop, proc (f: FrameInfo): bool =
    result = f.panel.laidOut and f.complete
    if result:
      doAssert abs(f.scale - 1.25) < 0.01, "the scale is " & $f.scale
      doAssert f.height <= 650, "the window is " & $f.height & " high"
      let plot = f.markOf("plot.data")
      doAssert plot.size.y >= 5 * 13 * 1.25 and f.panel.view.rows > 0,
        "the plot has no room: " & $plot & ", " & $f.panel.view
      doAssert f.markOf("plot.strip scrolls").size.x > 0, "the strip does not scroll"
      echo "tguismall: ", f.width, " x ", f.height, ": the plot ", plot.size.x, " x ",
        plot.size.y)
  step("what agent control says", noop, proc (f: FrameInfo): bool =
    let fe = frontendOf(f.ui, false)
    let busy = busy(f.core, fe)
    result = busy.len == 0
    if result:
      let shot = fe.shoot("plot")
      doAssert shot.error.len > 0 or (shot.width > 1 and shot.height > 1),
        "a " & $shot.width & " x " & $shot.height & " picture"
      echo "tguismall: the screenshot: ", (if shot.error.len > 0: shot.error else: $shot.width &
        " x " &
        $shot.height)
    elif frames > 400:
      doAssert false, "busy: " & busy.join("; "))

  var at = 0
  var started = false
  var wait = 0
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      (started, wait, frames) = (true, 0, 0)
    else:
      inc wait
      inc frames
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif wait > 600:
        failed = steps[at].name & " did not happen"
        f.stop()
  putEnv("SDL_VIDEO_X11_SCALING_FACTOR", "1.25")
  let code = run(RunOptions(maxFrames: 4000, configDir: some(config),
    logDir: some(config / "logs"), openPaths: @[file], windowSize: (829, 518),
    theme: forceDark, userThemeDir: some(config / "no-user-themes"),
    indexCacheDir: some(config / "cache"), onFrame: onFrame))
  delEnv("SDL_VIDEO_X11_SCALING_FACTOR")
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguismall: ok"
