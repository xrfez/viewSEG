## Start-up failures are shown and logged, never silent: each step of opening
## the main window (SDL video, the window, the OpenGL 3.3 context, the OpenGL
## functions, Dear ImGui's SDL3 and OpenGL 3 backends) is made to fail in turn.
## Each must return exit code 1, call the failure hook once (it stands in for
## the message box, which would wait for a click), name the step, and write the
## message to the log folder. A normal start follows, which shows that every
## failed start cleaned up after itself, and then a real failure (an unknown
## SDL video driver).
##
## Seen to fail: with the result of `ImGui_ImplSDL3_InitForOpenGL` discarded
## again, as it was, the `ssImguiSdl` case ran to the end and returned 0; with
## `fail` writing to stderr directly again, `noStderr` got "errno: 9 `Bad file
## descriptor`" from the write and the hook (the message box) was never called.
##
## Needs a display for the steps after SDL video: run under
## `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[options, os, strutils]
when defined(posix):
  import std/posix
import viewSEG/ui/imgui/app {.all.}

let tmp = getTempDir() / ("viewseg_tstartup_" & $getCurrentProcessId())
let logs = tmp / "logs"

proc start(simulate: set[StartupStep]; failures: var seq[StartupFailure]): int =
  ## Runs the frontend for two frames with `simulate` failing.
  var got: seq[StartupFailure]
  result = run(RunOptions(maxFrames: 2, logDir: some(logs),
    userThemeDir: some(tmp / "no-user-themes"),
    onFailure: proc (f: StartupFailure) = got.add f).simulating(simulate))
  failures = got

try:
  block eachStepFails:
    for step in StartupStep:
      removeDir(logs)
      var failures: seq[StartupFailure]
      let code = start({step}, failures)
      doAssert code == 1, $step & ": exit code " & $code
      doAssert failures.len == 1, $step & ": hook called " & $failures.len & " times"
      let f = failures[0]
      doAssert f.step == step, $f.step
      doAssert ("could not " & $step & ".") in f.text, f.text
      doAssert f.logFile == logs / failureLogName, f.logFile
      doAssert f.logFile in f.text, "the message names the log file: " & f.text
      let logged = readFile(f.logFile)
      doAssert f.text in logged, logged
      echo "tstartup: ", step, ": reported and logged"

  block messageWording:
    let t = failureText(ssGlContext, "GLX: no matching config", "/x/startup-failure.log")
    doAssert t.startsWith("viewSEG cannot start: it could not create an OpenGL 3.3 core context.")
    doAssert "GLX: no matching config" in t and "update it" in t
    doAssert t.endsWith("This message is saved in /x/startup-failure.log")
    doAssert "saved in" notin failureText(ssVideo, "", "") # no log file: not mentioned

  block unwritableLogFolder:
    # A log folder that cannot be made still reports the failure, without a file.
    writeFile(tmp / "a-file", "")
    var got: seq[StartupFailure]
    let code = run(RunOptions(logDir: some(tmp / "a-file" / "logs"),
      onFailure: proc (f: StartupFailure) = got.add f).simulating({ssWindow}))
    doAssert code == 1 and got.len == 1
    doAssert got[0].logFile == "" and "saved in" notin got[0].text, got[0].text

  block noStderr:
    # A program started from the desktop (on Windows, say) may have no usable
    # stderr, and Nim raises when a write fails: the failure must still reach
    # the message box (the hook here). Closing descriptor 2 makes writes fail
    # that way. SDL video is not started (simulated), so nothing else takes
    # descriptor 2 meanwhile.
    when defined(posix):
      let saved = dup(2)
      discard posix.close(2)
      var failures: seq[StartupFailure]
      var code = -1
      var raised = ""
      try:
        code = start({ssVideo}, failures)
      except IOError as e:
        raised = e.msg
      discard dup2(saved, 2)
      discard posix.close(saved)
      doAssert raised.len == 0, "a failed write to stderr stopped the report: " & raised
      doAssert code == 1 and failures.len == 1, $code & ", " & $failures.len

  block startsAfterwards:
    var failures: seq[StartupFailure]
    let code = start({}, failures)
    if code != 0:
      echo "FAIL tstartup: the window could not be opened: ", failures
    doAssert code == 0 and failures.len == 0

  block realFailure:
    # Last: SDL keeps its own copy of the environment once it has read it.
    putEnv("SDL_VIDEO_DRIVER", "no-such-driver")
    var failures: seq[StartupFailure]
    let code = start({}, failures)
    doAssert code == 1 and failures.len == 1, $code
    doAssert failures[0].step == ssVideo
    doAssert failures[0].reason.len > 0, "SDL gave a reason"
    echo "tstartup: unknown video driver: ", failures[0].reason
finally:
  removeDir(tmp)
