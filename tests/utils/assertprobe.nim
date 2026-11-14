## Built by tasserts.nim in a release build: runs the frontend and makes two of
## Dear ImGui's checks fail, one plain `IM_ASSERT` and one recoverable user
## error. Exits 0 when the program carried on and both reached the Messages
## window, 2 when they did not; a release build that still aborts on them
## dies with SIGABRT instead.

import std/[options, os, strutils]
import viewSEG/ui/imgui/app # first, as in the program: see app.nim's imports
import imguin/cimgui

var logged: seq[string]

proc probe(f: FrameInfo) =
  if f.index == 1:
    discard igGetStyleColorName(-1) # an unknown colour: IM_ASSERT(0)
    igPopStyleColor(1) # nothing pushed: IM_ASSERT_USER_ERROR
  if f.index == 3:
    for m in f.messages.items:
      if "Dear ImGui's check" in m.text: logged.add m.text

let code = run(RunOptions(maxFrames: 4, userThemeDir: some(getTempDir() / "no-user-themes"),
  onFrame: probe))
echo "assertprobe: ", logged.len, " checks logged"
for text in logged: echo text # the program echoes its log only to a terminal
quit(if code == 0 and logged.len == 2 and "PopStyleColor" in logged.join: 0 else: 2)
