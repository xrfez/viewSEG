## The runner's platform switches (`tests/utils/displaytests`): which test
## files need a display (`--no-display`) and which a run leaves out (`leftOut`:
## `--no-timing`, and `## Not on Windows:` on Windows).
##
## - the import scan: lists, brackets, multi-line imports and comments;
## - a file needs a display when it is named `tgui*`, imports the toolkit,
##   `viewSEG/ui/...`, `viewSEG/gpu/...` or the main module `viewSEG`, or
##   imports a helper in `tests/utils` that does (and only then);
## - the real suite: the window tests are told apart, and the files the Windows
##   job runs (the ones that need none) are many and include the archive's;
## - what a run leaves out for each switch and for the header lines.
##
## Seen to fail: with the main module `viewSEG` not counted, `tcommandline`
## (it imports `viewSEG`, and so the window code) was left in the Windows run
## and did not build there ("windres"); with the helpers not followed,
## a file importing `utils/assertprobe` was left in.

import std/[os, strutils]
import utils/displaytests

proc main*() =
  let tests = currentSourcePath().parentDir

  block the_import_scan:
    let text = "import std/[os, strutils], parseSEG # a comment: import viewSEG/ui/x\n" &
      "from viewSEG/core/state import nil\n" &
      "import\n  utils/fixtures,\n  viewSEG/ui/imgui/[icons, menus]\n" &
      "import viewSEG/[core/state,\n  gpu/textures]\n" &
      "let notAnImport = \"import imguin\"\n"
    let found = importsOf(text)
    for want in ["std/", "os", "parseSEG", "viewSEG/core/state", "utils/fixtures",
        "viewSEG/ui/imgui/", "icons", "gpu/textures"]:
      doAssert want in found, want & " not in " & $found
    doAssert "viewSEG/ui/x" notin found and "imguin" notin found, $found

  let dir = getTempDir() / "viewSEG-tdisplaytests-" & $getCurrentProcessId()
  createDir(dir / "utils")
  defer: removeDir(dir)
  proc put(name, text: string): string =
    result = dir / name
    writeFile(result, text)

  block what_needs_a_display:
    doAssert needsDisplay(put("tguithing.nim", "import std/os\n")), "named tgui"
    doAssert needsDisplay(put("t1.nim", "import imguin/cimgui\n"))
    doAssert needsDisplay(put("t2.nim", "import viewSEG/ui/imgui/app\n"))
    doAssert needsDisplay(put("t3.nim", "import viewSEG/[core/state, ui/imgui/shell]\n"))
    doAssert needsDisplay(put("t4.nim", "import viewSEG/gpu/textures\n"))
    doAssert needsDisplay(put("t5.nim", "import std/strutils\nimport viewSEG\n")),
      "the main module"
    doAssert needsDisplay(put("t6.nim", "import sdl3_nim\n"))
    doAssert not needsDisplay(put("t7.nim", "import std/os\nimport viewSEG/core/state\n" &
      "import viewSEG/platform/paths, viewSEG/view/theme\n"))
    doAssert not needsDisplay(put("t8.nim", "import viewSEG/remote/schema\n"))

  block helpers_are_followed:
    discard put("utils/windowy.nim", "import viewSEG/ui/imgui/app\n")
    discard put("utils/plain.nim", "import std/os\nimport viewSEG/core/state\n")
    discard put("utils/loopy.nim", "import loopy2\n")
    discard put("utils/loopy2.nim", "import loopy\n")
    doAssert needsDisplay(put("t9.nim", "import utils/windowy\n"))
    doAssert needsDisplay(put("t10.nim", "import utils/[plain, windowy]\n"))
    doAssert not needsDisplay(put("t11.nim", "import utils/plain\n"))
    doAssert not needsDisplay(put("t12.nim", "import utils/loopy\n")), "an import cycle ends"

  block the_real_suite:
    var withDisplay, without: seq[string]
    for f in walkFiles(tests / "t*.nim"):
      let name = f.extractFilename
      if name == "tester.nim":
        continue
      if needsDisplay(f): withDisplay.add name else: without.add name
    for name in ["tgui.nim", "tstartup.nim", "tcommandline.nim", "tchrome.nim", "tshell.nim"]:
      doAssert name in withDisplay, name & " needs a display"
    for name in ["treferences.nim", "tpaths.nim", "tfilememory.nim", "tdiskio.nim",
        "tdisplaytests.nim", "tpathcase.nim", "tlayers.nim"]:
      doAssert name in without, name & " needs none"
    doAssert withDisplay.len > 100 and without.len > 100, $(withDisplay.len, without.len)

  block what_a_run_leaves_out:
    let plain = put("p1.nim", "import std/os\n")
    let window = put("tguip.nim", "import std/os\n")
    let timing = @["## Runs alone: it times things."]
    let sockets = @["## Not on Windows: a Unix socket."]
    doAssert leftOut(plain, @[], true, true, true) == ""
    doAssert leftOut(window, @[], false, false, false) == "", "no switch: everything runs"
    doAssert leftOut(window, @[], true, false, false) == "needs a display"
    doAssert leftOut(plain, timing, false, true, false) == "measures times"
    doAssert leftOut(plain, timing, true, false, false) == "", "timing files stay without the switch"
    doAssert leftOut(plain, sockets, true, true, true) == "not on Windows"
    doAssert leftOut(plain, sockets, true, true, false) == "", "the mark is for Windows only"

when isMainModule:
  main()
