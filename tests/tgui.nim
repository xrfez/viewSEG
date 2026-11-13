## Headless frame tests for the ImGui frontend: open the SDL3 / OpenGL 3 window,
## draw a few frames and read pixels back from the last one.
##
## Pass/fail rule: it needs a display. Run it under
## `xvfb-run -a -s "-screen 0 1920x1080x24" nim test` (CI does) or on a desktop.
## Without a usable video device or GL context, `run` fails and so does this
## test, loudly, with SDL's reason. There is no skip: a skipped GUI test would let
## CI go green without a frame ever being drawn.
##
## A frame really rendered when the last one shows both the theme's clear colour
## in the bottom-right corner (the dockspace's central node lets the background
## through) and something else at (120, 120), inside the plot window, which is
## placed at (40, 40) below the menu bar with size 560x380 (times the UI scale).
## Each theme is drawn once: the clear colour and the plot window's background
## must both change between them. A third run forces a 200 % display scale on
## X11 and checks that the menu bar grows.

import std/os
import viewSEG/core/geometry
import viewSEG/ui/imgui/app

const frames = 5

func near(a, b: Rgba; tol = 2): bool =
  abs(a.r.int - b.r.int) <= tol and abs(a.g.int - b.g.int) <= tol and
    abs(a.b.int - b.b.int) <= tol

type Shot = object
  size: (int, int)
  theme: ThemeMode
  scale: float32
  corner, inWindow, belowMenu: Rgba

proc render(theme: ThemeChoice): Shot =
  ## Runs the frontend for `frames` frames and samples the last one.
  var seen: seq[int]
  var shot: Shot
  proc grab(f: FrameInfo) =
    seen.add f.index
    if f.index == frames - 1:
      shot = Shot(size: (f.width, f.height), theme: f.theme, scale: f.scale,
        corner: f.readPixel(f.width - 3, f.height - 3),
        inWindow: f.readPixel(120, 120),
        belowMenu: f.readPixel(f.width - 3, 30)) # right end, under a 100 % menu bar
  let code = run(RunOptions(maxFrames: frames, onFrame: grab, theme: theme))
  if code != 0:
    echo "FAIL tgui: the window could not be opened (see the SDL error above).\n" &
      "  It needs a display: run `xvfb-run -a -s \"-screen 0 1920x1080x24\" nim test`."
  doAssert code == 0, "run() exit code " & $code
  doAssert seen.len == frames and seen[^1] == frames - 1, "frames seen: " & $seen
  doAssert shot.size[0] > 120 and shot.size[1] > 120, "framebuffer " & $shot.size
  doAssert near(shot.corner, clearColor(shot.theme)),
    "corner " & $shot.corner & ", clear colour " & $clearColor(shot.theme)
  doAssert not near(shot.inWindow, clearColor(shot.theme)),
    "nothing drawn at (120, 120): " & $shot.inWindow & " is the clear colour"
  shot

block themes:
  let dark = render(forceDark)
  let light = render(forceLight)
  doAssert dark.theme == tmDark and light.theme == tmLight
  doAssert not near(dark.corner, light.corner, 20),
    "background " & $dark.corner & " (dark) vs " & $light.corner & " (light)"
  doAssert not near(dark.inWindow, light.inWindow, 20),
    "plot window " & $dark.inWindow & " (dark) vs " & $light.inWindow & " (light)"
  doAssert dark.belowMenu == dark.corner, "a 100 % menu bar ends above y = 30"
  echo "tgui: ", frames, " frames at ", dark.size[0], "x", dark.size[1], ", scale ",
    dark.scale, "; dark: corner ", dark.corner, ", plot window ", dark.inWindow,
    "; light: corner ", light.corner, ", plot window ", light.inWindow

block doubleScale:
  # SDL's X11 driver takes its content scale from this variable. Under another
  # video driver (SDL_VIDEO_DRIVER=wayland) it does not apply: skip there.
  if getEnv("SDL_VIDEO_DRIVER") notin ["", "x11"]:
    echo "tgui: 200 % check skipped (SDL_VIDEO_DRIVER=", getEnv("SDL_VIDEO_DRIVER"), ")"
  else:
    putEnv("SDL_VIDEO_X11_SCALING_FACTOR", "2")
    let big = render(forceDark)
    delEnv("SDL_VIDEO_X11_SCALING_FACTOR")
    doAssert big.scale == 2, "scale " & $big.scale
    doAssert not near(big.belowMenu, big.corner),
      "the 200 % menu bar should reach y = 30: " & $big.belowMenu
    echo "tgui: 200 %: ", big.size[0], "x", big.size[1], ", menu bar at y = 30 ", big.belowMenu
