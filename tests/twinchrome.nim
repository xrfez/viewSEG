## The Windows-only code of the window frames and the tray's last words
## (`platform/chrome`, `platform/trayguard`) and the resources
## (`platform/winres`) compile, link and land in a Windows executable: a
## small program using them is cross-compiled with zig for
## x86_64-windows-gnu (as `nim winRelease` builds the program, without
## SDL), then its PE file is read:
##
## - the subsystem is GUI (2), so no console window opens; with
##   `-d:console` it is a console program (3);
## - the manifest is in it, with per-monitor DPI v2;
## - the Win32 functions it looks up at run time are named in it.
##
## `twinbuild` checks that the whole program translates to C for Windows;
## this one goes on to the C compile and the link for the Windows parts.
## Skipped without zig (CI's test job; its release job builds the program
## with zig). Nothing here runs the program: there is no Windows here.
##
## Seen to fail: with the windows not subclassed to keep their look after
## a settings change, "SetWindowSubclass is not looked up"; with `winres`
## linking `-mwindows` only (zig ignores it),
## "subsystem 3, not GUI (2)"; with `RtlGetVersion`'s struct declared one
## field short, the `static` size check stops the compile.

import std/[os, osproc, strutils]

proc u16(s: string; at: int): int = s[at].int or (s[at + 1].int shl 8)
proc u32(s: string; at: int): int = u16(s, at) or (u16(s, at + 2) shl 16)

proc subsystem(exe: string): int =
  ## The PE optional header's Subsystem field.
  doAssert exe.len > 0x40 and exe[0 .. 1] == "MZ", "not an executable"
  let pe = u32(exe, 0x3c)
  doAssert exe[pe ..< pe + 4] == "PE\0\0", "no PE header"
  let optional = pe + 24
  doAssert u16(exe, optional) == 0x20b, "not PE32+ (64-bit)"
  u16(exe, optional + 68)

const probe = """
import viewSEG/platform/[chrome, trayguard, winres]

proc onDeath() {.nimcall, gcsafe, raises: [].} = discard removeTrayIcons()

let v = windowsVersion()
prepareTrayRemoval("SDL_TRAY")
guardFatalSignals(onDeath)
echo v.build, " ", applyChrome(nil, ChromeLook(dark: true)), " ", setWindowIcons(nil)
"""

let zig = findExe("zig")
if zig.len == 0:
  echo "twinchrome: skipped (no zig)"
else:
  let
    root = currentSourcePath().parentDir.parentDir
    work = getTempDir() / "viewSEG-twinchrome-" & $getCurrentProcessId()
  createDir(work)
  try:
    writeFile(work / "probe.nim", probe)
    proc build(name: string; extra: openArray[string]): string =
      ## Builds the probe into `work/name`; returns the executable's bytes.
      let exe = work / name
      var args = @[getCurrentCompilerExe(), "c", "--hints:off", "--warnings:off",
        "--skipParentCfg", "--skipUserCfg", "--skipProjCfg", "--path:" & root / "src",
        "--os:windows", "--cpu:amd64", "-d:zigcc", "-d:release", "--cc:clang",
        "--clang.exe:" & root / "tools" / "zigcc", "--clang.linkerexe:" & root / "tools" / "zigcc",
        "--passC:-target x86_64-windows-gnu", "--passL:-target x86_64-windows-gnu",
        "--nimcache:" & work / ("cache-" & name), "-o:" & exe]
      args.add extra
      args.add work / "probe.nim"
      let (output, code) = execCmdEx(quoteShellCommand(args), workingDir = work)
      doAssert code == 0, "the Windows probe does not build:\n" & output.strip
      readFile(exe)
    let gui = build("probe.exe", [])
    doAssert subsystem(gui) == 2, "subsystem " & $subsystem(gui) & ", not GUI (2)"
    doAssert "PerMonitorV2" in gui, "no manifest with per-monitor DPI v2"
    for name in ["DwmSetWindowAttribute", "RtlGetVersion", "GetDpiForWindow", "LoadImageW",
        "Shell_NotifyIconW", "FindWindowExW", "SetWindowSubclass", "DefSubclassProc",
        "RemoveWindowSubclass"]:
      doAssert name in gui, name & " is not looked up"
    let console = build("probe-console.exe", ["-d:console"])
    doAssert subsystem(console) == 3, "-d:console: subsystem " & $subsystem(console)
  finally:
    removeDir(work)
  echo "twinchrome: ok"
