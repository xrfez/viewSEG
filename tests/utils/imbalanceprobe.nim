## Built by tguiimbalance.nim: runs the frontend for three frames. With the
## argument `stray` its frame hook pops a style colour nothing pushed, a mistake
## a draw path could make; with `ok` it does nothing wrong.

import std/[options, os]
import viewSEG/ui/imgui/app # first, as in the program: see app.nim's imports
import imguin/cimgui

proc hook(f: FrameInfo) =
  if f.index == 1 and paramStr(1) == "stray":
    igPopStyleColor(1) # nothing was pushed

quit(if run(RunOptions(maxFrames: 3, windowSize: (800, 600),
  userThemeDir: some(getTempDir() / "no-user-themes"), onFrame: hook)) == 0: 0 else: 2)
