## Headless frame test for the ImGui frontend: opens the SDL3 / OpenGL 3 window,
## draws a few frames and reads pixels back from the last one.
##
## Pass/fail rule: it needs a display. Run it under
## `xvfb-run -a -s "-screen 0 1920x1080x24" nim test` (CI does) or on a desktop.
## Without a usable video device or GL context, `run` fails and so does this
## test, loudly, with SDL's reason. There is no skip: a skipped GUI test would let
## CI go green without a frame ever being drawn.
##
## A frame really rendered when the last one shows both the clear colour in the
## bottom-right corner (the dockspace's central node lets the background through)
## and something else at (120, 120), inside the plot window, which is placed at
## (40, 40) from the main viewport with size 560x380. At pixel density 1 or 2
## that point lies in the window either way.

import viewSEG/core/geometry
import viewSEG/ui/imgui/app

const frames = 5

func near(a, b: Rgba; tol = 2): bool =
  abs(a.r.int - b.r.int) <= tol and abs(a.g.int - b.g.int) <= tol and
    abs(a.b.int - b.b.int) <= tol

block renderedFrames:
  var
    seen: seq[int]
    size: (int, int)
    corner, inWindow: Rgba
  proc grab(f: FrameInfo) =
    seen.add f.index
    if f.index == frames - 1:
      size = (f.width, f.height)
      corner = f.readPixel(f.width - 3, f.height - 3)
      inWindow = f.readPixel(120, 120)
  let code = run(RunOptions(maxFrames: frames, onFrame: grab))
  if code != 0:
    echo "FAIL tgui: the window could not be opened (see the SDL error above).\n" &
      "  It needs a display: run `xvfb-run -a -s \"-screen 0 1920x1080x24\" nim test`."
  doAssert code == 0, "run() exit code " & $code
  doAssert seen.len == frames and seen[^1] == frames - 1, "frames seen: " & $seen
  doAssert size[0] > 120 and size[1] > 120, "framebuffer " & $size
  doAssert near(corner, ClearColor), "corner " & $corner & ", clear colour " & $ClearColor
  doAssert not near(inWindow, ClearColor),
    "nothing drawn at (120, 120): " & $inWindow & " is the clear colour"
  echo "tgui: ", frames, " frames at ", size[0], "x", size[1], "; corner ", corner,
    ", plot window ", inWindow
