## Start-up smoke check of a built viewSEG: `nim smoke [new | <binary>]`.
##
## Takes `bin/viewSEG` (`new`: `bin/viewSEG.new`, or a path) and checks that
##
## - `--version` prints the versions of viewSEG, parseSEG and processSEG;
## - the program starts with no file, with `samples/land/shots.sgy` and with
##   `samples/land/shots.sgd`, stays up for a few seconds, and answers on its
##   agent interface: `state` names the file, and a screenshot of the window
##   (`--mcp-call screenshot`) is not blank;
## - it leaves when asked to (SIGINT, as Ctrl+C in a console) with exit code 0,
##   and neither its output nor its log folder holds an "Internal display
##   error" or a start-up failure.
##
## Nothing here reaches the real desktop or the user's own files: the checks run
## on a private X server (Xvfb, no Wayland), with a private HOME and XDG
## folders, on a copy of the binary in a private folder (so that the program's
## own folder is left alone) with its own agent socket under that folder. The
## folder is removed at the end. Needs Xvfb on the PATH and a built binary.

import std/[monotimes, os, osproc, posix, streams, strtabs, strutils, tables, times]
import stb_image/read as stb

const
  Fixtures = ["", "samples/land/shots.sgy", "samples/land/shots.sgd"]
  StartTimeout = 60 ## seconds for the agent interface to answer
  QuitTimeout = 20  ## seconds for the program to leave

var failures: seq[string]

proc fail(msg: string) =
  failures.add msg
  echo "  FAILED: ", msg

proc check(ok: bool; msg: string) =
  if not ok: fail(msg)

proc childEnv(root: string): seq[(string, string)] =
  ## The environment of every program started here: the user's own, but
  ## for the folders and the display.
  var kept: seq[(string, string)]
  for k, v in envPairs():
    if k notin ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
        "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "DISPLAY", "PARSESEG_VENDOR_PATH"]:
      kept.add (k, v)
  kept.add ("HOME", root / "home")
  kept.add ("XDG_CONFIG_HOME", root / "home" / "config")
  kept.add ("XDG_DATA_HOME", root / "home" / "data")
  kept.add ("XDG_CACHE_HOME", root / "home" / "cache")
  kept.add ("XDG_STATE_HOME", root / "home" / "state")
  kept.add ("XDG_RUNTIME_DIR", root / "run")
  result = kept

proc envTable(pairs: seq[(string, string)]; display = ""): StringTableRef =
  result = newStringTable()
  for (k, v) in pairs: result[k] = v
  if display.len > 0: result["DISPLAY"] = display

proc runIn(exe: string; args: seq[string]; env: StringTableRef; limit = 30): (string, int) =
  ## One run of the program to its end, its output and exit code.
  let p = startProcess(exe, args = args, env = env, options = {poStdErrToStdOut})
  let began = getMonoTime()
  while p.running and (getMonoTime() - began).inSeconds < limit: sleep 20
  if p.running:
    p.kill()
    result[1] = -1
  else:
    result[1] = p.peekExitCode
  result[0] = p.outputStream.readAll()
  p.close()

proc startXvfb(): (Process, string) =
  ## A private X server on a display of its own, whose number it reports.
  let p = startProcess("Xvfb", args = ["-displayfd", "1", "-screen", "0", "1920x1080x24",
    "-nolisten", "tcp"], options = {poUsePath, poStdErrToStdOut})
  var line = ""
  let ok = p.outputStream.readLine(line)
  doAssert ok and line.strip.len > 0, "Xvfb did not give a display"
  (p, ":" & line.strip)

proc notBlank(png: string): bool =
  ## Whether the picture has several colours (a window of one colour is blank).
  var (x, y, channels) = (0, 0, 0)
  let pixels = stb.load(png, x, y, channels, 3)
  var seen = initTable[int, int]()
  for i in 0 ..< x * y:
    seen[int(pixels[3 * i]) shl 16 or int(pixels[3 * i + 1]) shl 8 or int(pixels[3 * i + 2])] = 0
    if seen.len >= 8: return true

proc call(exe, socket: string; env: StringTableRef; tool: string; args = "{}";
    png = ""): (string, int) =
  var a = @["--mcp-call=" & socket, tool, args]
  if png.len > 0: a.add "--png=" & png
  runIn(exe, a, env, 60)

proc smokeRun(exe, root, name, file: string; pairs: seq[(string, string)]) =
  echo "start-up ", name
  let (xvfb, display) = startXvfb()
  defer:
    xvfb.terminate()
    discard xvfb.waitForExit(5)
    xvfb.close()
  let env = envTable(pairs, display)
  let socket = root / "run" / "agent.sock"
  let log = root / ("run-" & name & ".log")
  var args = @["--mcp=" & socket]
  if file.len > 0: args.add absolutePath(file)
  # the program's output goes to a file: it is read when the program is gone
  let p = startProcess("/bin/sh", args = @["-c", "exec \"$0\" \"$@\" > " & quoteShell(log) &
    " 2>&1", exe] & args, env = env, options = {poUsePath})
  var answered = false
  var stateText = ""
  let began = getMonoTime()
  while p.running and not answered and (getMonoTime() - began).inSeconds < StartTimeout:
    sleep 500
    let (text, code) = call(exe, socket, env, "state", """{"parts": ["files", "panels"]}""")
    if code == 0:
      answered = true
      stateText = text
  check answered, name & ": the agent interface did not answer in " & $StartTimeout & " s"
  if answered:
    sleep 3000 # up for a few seconds
    check p.running, name & ": the program left by itself"
    let (waited, wcode) = call(exe, socket, env, "wait", """{"timeout": 60}""")
    check wcode == 0, name & ": wait: " & waited
    let (state2, scode) = call(exe, socket, env, "state", """{"parts": ["files", "panels"]}""")
    check scode == 0, name & ": state: " & state2
    if file.len > 0:
      check file.extractFilename in state2, name & ": state does not name " & file.extractFilename
    let png = root / ("shot-" & name & ".png")
    let (shot, pcode) = call(exe, socket, env, "screenshot", """{"window": "window"}""", png)
    check pcode == 0 and fileExists(png), name & ": screenshot: " & shot
    if pcode == 0 and fileExists(png):
      check notBlank(png), name & ": the screenshot is blank"
  var code = -1
  if p.running:
    discard posix.kill(Pid(p.processID), SIGINT)
    let quitBegan = getMonoTime()
    while p.running and (getMonoTime() - quitBegan).inSeconds < QuitTimeout: sleep 50
    if p.running:
      fail name & ": the program did not leave in " & $QuitTimeout & " s"
      p.kill()
  code = p.waitForExit(5)
  p.close()
  check code == 0, name & ": exit code " & $code
  let output = if fileExists(log): readFile(log) else: ""
  check "Internal display error" notin output, name & ": output holds an Internal display error"
  check "startup-failure" notin output, name & ": output holds a start-up failure"
  for f in walkDirRec(root / "home" / "state"):
    if f.extractFilename == "startup-failure.log": fail name & ": " & f & " was written"
  for f in walkDirRec(root / "home" / "state"):
    if f.endsWith(".log") and "Internal display error" in readFile(f):
      fail name & ": " & f & " holds an Internal display error"

proc main() =
  let arg = if paramCount() >= 1: paramStr(1) else: ""
  let root = getCurrentDir()
  let source =
    if arg == "": root / "bin" / "viewSEG"
    elif arg == "new": root / "bin" / "viewSEG.new"
    else: absolutePath(arg)
  if not fileExists(source):
    quit "smoke: there is no " & source & " (build it first: `nim nimRelease` or `nim nimDebug`)"
  for f in Fixtures:
    if f.len > 0 and not fileExists(root / f):
      quit "smoke: there is no " & f & " (`nim samples` writes the sample set)"
  let work = getTempDir() / ("vsmoke" & $getCurrentProcessId())
  removeDir(work)
  createDir(work / "home")
  createDir(work / "run")
  setFilePermissions(work / "run", {fpUserRead, fpUserWrite, fpUserExec})
  for d in ["config", "data", "cache", "state"]: createDir(work / "home" / d)
  try:
    # a copy of the binary in a folder of its own, with the assets it looks for beside it:
    # nothing is written next to the program under test
    createDir(work / "app")
    let exe = work / "app" / "viewSEG"
    copyFile(source, exe)
    setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
    for d in ["assets", "vendormaps"]:
      if dirExists(root / d): copyDir(root / d, work / "app" / d)
    let pairs = childEnv(work)
    let env = envTable(pairs)
    echo "binary: ", source
    let (version, vcode) = runIn(exe, @["--version"], env)
    echo "  ", version.strip
    check vcode == 0, "--version: exit code " & $vcode
    check version.strip.startsWith("viewSEG ") and " (parseSEG " in version and
      ", processSEG " in version, "--version does not print the three versions: " & version
    smokeRun(exe, work, "no-file", "", pairs)
    smokeRun(exe, work, "shots-sgy", root / Fixtures[1], pairs)
    smokeRun(exe, work, "shots-sgd", root / Fixtures[2], pairs)
  finally:
    removeDir(work)
  if failures.len > 0:
    echo failures.len, " check(s) failed"
    quit QuitFailure
  echo "smoke: all checks passed"

main()
