## The rules of the window frames on Windows (`platform/chrome`) and of the
## Separate binary: it runs itself again and reads its own arguments.
## tray's last words (`platform/trayguard`), checked on any system:
##
## - the DWM attributes and values for each Windows version: none before
##   Windows 10 1809, the dark mode as attribute 19 from 1809 to 1909 and 20
##   from 20H1 (20, then 19, when the version is unknown), the caption, text
##   and border colours and round corners from Windows 11 on a framed window,
##   square corners and no colours on a frameless one, never Mica;
## - a theme's colours as `COLORREF`s (`0x00BBGGRR`), and which theme roles
##   the frame takes (`frames.lookOf`): the menu bar's colour for the title
##   bar, so the two read as one band;
## - the icon sizes for a window's DPI;
## - elsewhere than Windows nothing is set and the version is unknown;
## - a fatal signal runs the cleanup (which takes the tray icon away on
##   Windows) before Nim's own handler, which still writes its message and
##   ends the program: a child process raises SIGSEGV;
## - so does a Defect no thread handles, raised on a worker thread, which
##   ends the program before the main thread's cleanup could run.
##
## Seen to fail: with the dark mode attribute 20 given from build 17763,
## "1809 takes attribute 19"; with red and blue swapped in `colorRef`,
## "0x003b352d"; with the active flag ignored, "inactive title:
## 0x00aac6d3"; with the first image taken whatever its size, "24: 16";
## with `guardFatalSignals` not calling the cleanup, "the
## cleanup did not run before Nim's handler"; with the ids to remove fixed
## at 1 to 64, "13 trays: ids up to 64, the last tray's is 61"; with the
## tray's windows still searched for in the handler, "the signal handler's
## cleanup calls findWindowEx"; with
## `guardUnhandled` not
## installing its hook, "the cleanup did not run for a worker's Defect".

import std/[os, osproc, strutils]
import viewSEG/platform/[chrome, trayguard]
import viewSEG/ui/imgui/frames
import viewSEG/view/theme

proc onDeath() {.nimcall, gcsafe, raises: [].} =
  try:
    stdout.write "cleaned\n"
    stdout.flushFile
  except IOError:
    discard

proc c_raise(sig: cint): cint {.importc: "raise", header: "<signal.h>".}
var SIGSEGV {.importc, header: "<signal.h>".}: cint

proc failing() {.thread.} =
  var empty: seq[int] = @[]
  echo empty[3] # an IndexDefect no one handles, on a worker thread

func attrs(s: seq[DwmSetting]): seq[uint32] =
  for x in s: result.add x.attribute

proc main*() =

  if paramCount() == 1 and paramStr(1) == "thread":
    guardUnhandled(onDeath)
    var worker: Thread[void]
    createThread(worker, failing)
    joinThread(worker)
    echo "still alive"
    quit 0

  if paramCount() == 1 and paramStr(1) == "crash":
    guardFatalSignals(onDeath)
    discard c_raise(SIGSEGV)
    echo "still alive"
    quit 0

  let look = ChromeLook(dark: true, caption: ChromeRgb(r: 0x2d, g: 0x35, b: 0x3b),
    captionText: ChromeRgb(r: 0xd3, g: 0xc6, b: 0xaa), border: ChromeRgb(r: 0x47, g: 0x52,
    b: 0x58), inactiveText: ChromeRgb(r: 0x9d, g: 0xa9, b: 0xa0),
    inactiveBorder: ChromeRgb(r: 0x34, g: 0x3c, b: 0x42))

  block colours:
    doAssert colorRef(ChromeRgb(r: 0x2d, g: 0x35, b: 0x3b)) == 0x003b352d'u32,
      "0x" & toHex(colorRef(ChromeRgb(r: 0x2d, g: 0x35, b: 0x3b)), 8)
    doAssert colorRef(ChromeRgb(r: 255)) == 0xff
    doAssert colorRef(ChromeRgb(b: 255)) == 0xff0000

  block versions:
    let win1803 = WindowsVersion(major: 10, build: 17134)
    let win1809 = WindowsVersion(major: 10, build: 17763)
    let win1909 = WindowsVersion(major: 10, build: 18363)
    let win22h2 = WindowsVersion(major: 10, build: 19045)
    let win11 = WindowsVersion(major: 10, build: 22631)
    doAssert dwmSettings(look, fkFramed, win1803).len == 0, "no dark title bar before 1809"
    doAssert attrs(dwmSettings(look, fkFramed, win1809)) == @[19'u32], "1809 takes attribute 19"
    doAssert attrs(dwmSettings(look, fkFramed, win1909)) == @[19'u32]
    doAssert attrs(dwmSettings(look, fkFramed, win22h2)) == @[20'u32],
      "Windows 10 has no caption colours: " & $attrs(dwmSettings(look, fkFramed, win22h2))
    let framed = dwmSettings(look, fkFramed, win11)
    doAssert attrs(framed) == @[DwmwaUseImmersiveDarkMode, DwmwaCaptionColor, DwmwaTextColor,
      DwmwaBorderColor, DwmwaWindowCornerPreference], $attrs(framed)
    doAssert framed[0].value == 1 and framed[0].fallback == 0
    doAssert framed[1].value == 0x003b352d'u32 and framed[2].value == 0x00aac6d3'u32
    doAssert framed[3].value == 0x00585247'u32 and framed[4].value == DwmwcpRound
    # Inactive: the title and the border as the look says for that (Windows
    # leaves it to the program once it sets them).
    let inactive = dwmSettings(look, fkFramed, win11, active = false)
    doAssert attrs(inactive) == attrs(framed)
    doAssert inactive[2].value == 0x00a0a99d'u32, "inactive title: 0x" & toHex(inactive[2].value, 8)
    doAssert inactive[3].value == 0x00423c34'u32, "inactive border"
    doAssert inactive[1].value == framed[1].value, "the bar keeps its colour"
    let frameless = dwmSettings(look, fkFrameless, win11)
    doAssert attrs(frameless) == @[DwmwaUseImmersiveDarkMode, DwmwaWindowCornerPreference]
    doAssert frameless[1].value == DwmwcpDoNotRound
    var light = look
    light.dark = false
    doAssert dwmSettings(light, fkFramed, win11)[0].value == 0
    doAssert dwmSettings(light, fkFramed, win1809)[0].value == 0
    # Unknown: everything tried, the dark mode as 20 then 19.
    let unknown = dwmSettings(look, fkFramed, UnknownVersion)
    doAssert unknown[0] == DwmSetting(attribute: 20, value: 1, fallback: 19)
    doAssert attrs(unknown).len == 5
    for v in [win1803, win1809, win22h2, win11, UnknownVersion]:
      for k in FrameKind:
        doAssert DwmwaSystemBackdropType notin attrs(dwmSettings(look, k, v)), "no Mica"

  block settingChanges:
    # After these SDL sets the system's dark mode on each window: the look is
    # set again.
    doAssert resetsDarkMode(WmSettingChange, ImmersiveColorSet)
    doAssert resetsDarkMode(0x001A, "ImmersiveColorSet")
    doAssert not resetsDarkMode(WmSettingChange, "WindowsThemeElement")
    doAssert not resetsDarkMode(WmSettingChange, "")
    doAssert not resetsDarkMode(0x0080, ImmersiveColorSet)

  block iconSizesForDpi:
    doAssert iconSizes(96) == (32, 16)
    doAssert iconSizes(120) == (40, 20)
    doAssert iconSizes(144) == (48, 24)
    doAssert iconSizes(192) == (64, 32)
    doAssert iconSizes(0) == (32, 16)

  block trayIconImage:
    # The notification area's icon is the icon file's own image of its size
    # (16 at 100 %, 24 at 150 %), not the 32-pixel one scaled by the shell.
    let ico = readFile(currentSourcePath().parentDir.parentDir / "res" / "viewSEG.ico")
    proc width(png: string): int =
      doAssert png.len > 24 and png[1 .. 3] == "PNG", "not a PNG"
      (png[16].int shl 24) or (png[17].int shl 16) or (png[18].int shl 8) or png[19].int
    doAssert width(iconImage(ico, 16)) == 16
    doAssert width(iconImage(ico, 24)) == 24, "24: " & $width(iconImage(ico, 24))
    doAssert width(iconImage(ico, 20)) == 24, "the next larger"
    doAssert width(iconImage(ico, 32)) == 32
    doAssert width(iconImage(ico, 300)) == 256, "the largest"
    doAssert iconImage("not an icon", 16) == ""
    doAssert iconImage(ico[0 .. 40], 16) == "", "cut short"
    when not defined(windows):
      doAssert trayIconSize() == 0

  block lookOfTheme:
    let dark = lookOf(EverforestDark)
    doAssert dark.dark
    doAssert dark.caption == ChromeRgb(r: 0x21, g: 0x27, b: 0x2c), "the menu bar's colour"
    doAssert dark.captionText == ChromeRgb(r: 0xd3, g: 0xc6, b: 0xaa)
    doAssert dark.border == ChromeRgb(r: 0x47, g: 0x52, b: 0x58)
    doAssert dark.inactiveText == ChromeRgb(r: 0x9d, g: 0xa9, b: 0xa0), "text_dim"
    doAssert dark.inactiveBorder != dark.border and dark.inactiveBorder != dark.caption,
      "the inactive border is between the border and the bar: " & $dark.inactiveBorder
    let light = lookOf(EverforestLight)
    doAssert not light.dark
    doAssert light.caption == ChromeRgb(r: 0xf4, g: 0xf0, b: 0xd9)

  block trayIds:
    # SDL's ids for tray icons and menu entries share one counter: our menu
    # has 4 entries (a separator among them), so each tray takes 5 ids.
    for trays in [1, 13, 14, 100]:
      let lastTrayId = 1 + 5 * (trays - 1)
      doAssert trayIdBound(trays, 4) >= lastTrayId + 4,
        $trays & " trays: ids up to " & $trayIdBound(trays, 4) & ", the last tray's is " &
        $lastTrayId

  block notWindows:
    when not defined(windows):
      doAssert windowsVersion() == UnknownVersion
      doAssert applyChrome(cast[pointer](1), look) == 0
      doAssert not setWindowIcons(cast[pointer](1))
      doAssert removeTrayIcons() == 0
      doAssert framesNote(UnknownVersion).contains("unknown")
      doAssert framesNote(WindowsVersion(build: 22631)).contains("Windows 11")
      doAssert framesNote(WindowsVersion(build: 19045)).contains("Windows 10")

  block fatalSignalCleanup:
    when not defined(windows):
      let (output, code) = execCmdEx(quoteShell(getAppFilename()) & " crash")
      doAssert code != 0, "the program lived on: " & output
      doAssert "still alive" notin output, output
      let cleaned = output.find("cleaned")
      doAssert cleaned >= 0, "the cleanup did not run before Nim's handler:\n" & output
      let nims = output.find("SIGSEGV")
      doAssert nims > cleaned, "Nim's handler did not run after the cleanup:\n" & output

  block cleanupInAHandler:
    # What the signal handler runs on Windows makes only Shell_NotifyIconW
    # calls: windows, ids and functions are found beforehand (read from the
    # source: there is no Windows here to run it).
    let text = readFile(currentSourcePath().parentDir.parentDir / "src" / "viewSEG" /
      "platform" / "trayguard.nim")
    let start = text.find("proc removeTrayIcons*")
    doAssert start >= 0
    var body = text[start .. ^1]
    let next = body.find("\nproc ", 1)
    if next > 0: body = body[0 ..< next]
    for call in ["findWindowEx", "getWindowThreadProcessId", "getCurrentProcessId", "loadLib",
        "symAddr", ".add", " & ", "newSeq", "$"]:
      doAssert call notin body, "the signal handler's cleanup calls " & call

  block workerDefectCleanup:
    # A Defect no thread handles ends the program from the worker (Nim's
    # `threadTrouble`): the main thread's own cleanup never runs, so the hook
    # must.
    let (output, code) = execCmdEx(quoteShell(getAppFilename()) & " thread")
    doAssert code != 0, "the program lived on: " & output
    doAssert "still alive" notin output, output
    let cleaned = output.find("cleaned")
    doAssert cleaned >= 0, "the cleanup did not run for a worker's Defect:\n" & output
    let nims = output.find("IndexDefect")
    doAssert nims > cleaned, "Nim did not report the Defect after the cleanup:\n" & output

  echo "tchrome: ok"

when isMainModule:
  main()
