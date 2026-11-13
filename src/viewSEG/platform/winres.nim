## Windows resources compiled into the executable: the application manifest,
## the icon and the version information. Import it from the main module only.
##
## These must be linked into the .exe at build time; no windowing library (SDL,
## GLFW) can supply them at run time. The manifest (`res/viewSEG.exe.manifest`)
## turns on visual styles, per-monitor DPI v2, UTF-8 and Windows 10/11
## behaviour; the icon (`res/viewSEG.ico`, resource id 1) is what Explorer, the
## taskbar and Alt-Tab show. With SDL3, set the hint
## `SDL_HINT_WINDOWS_INTRESOURCE_ICON` (and `..._ICON_SMALL`) to "1" so its windows
## use it too.
##
## At compile time this module writes a .rc file into the nimcache (the version
## comes from viewSEG.nimble, so there is one source for it), compiles it, and
## links the result:
## - MinGW gcc: `windres` (or `x86_64-w64-mingw32-windres`), producing a COFF object;
## - MSVC (`--cc:vcc`): `rc.exe`, producing a .res the MSVC linker accepts;
## - zig cc (`-d:zigcc`): `zig rc`, producing a .res that `zig cc` links (zig cc
##   compiling the .rc itself rejects absolute paths in it: `FileSystemFailure`).
## Override the tool with `-d:windresExe=...`. Elsewhere this module is empty.

{.used.} # imported for its side effects (linking) only

when defined(windows):
  import std/[compilesettings, os, strutils] # os: quoteShell only

  const
    windresExe {.strdefine.} = ""
    outDir = querySetting(SingleValueSetting.nimcacheDir)

  func up(path: string, levels: int): string =
    ## `path` without its last `levels` components, whatever the separator.
    result = path
    for _ in 1 .. levels:
      result = result[0 ..< max(result.rfind('/'), result.rfind('\\'))]

  func `/+`(a, b: string): string = a & "/" & b

  const
    rootDir = currentSourcePath().up(4) # src/viewSEG/platform/winres.nim
    resDir = rootDir /+ "res"
    # The build host (not the target): only a Windows host has drive letters.
    windowsHost = rootDir.len > 1 and rootDir[1] == ':'

  proc nimbleVersion(): string {.compileTime.} =
    for line in staticRead(rootDir /+ "viewSEG.nimble").splitLines:
      if line.startsWith("version"):
        return line.split('=', 1)[1].strip.strip(chars = {'"'})
    "0.0.0"

  func slash(s: string): string = s.replace('\\', '/')

  proc rcText(): string {.compileTime.} =
    ## The resource script. Numeric ids and constants only, so no Windows
    ## headers are needed: 24 = RT_MANIFEST, id 1 = the process manifest.
    let v = nimbleVersion()
    var parts = v.split('.')
    while parts.len < 4: parts.add "0"
    let commas = parts[0 .. 3].join(",")
    result = "1 24 \"" & slash(resDir /+ "viewSEG.exe.manifest") & "\"\n" &
      "1 ICON \"" & slash(resDir /+ "viewSEG.ico") & "\"\n" &
      "1 VERSIONINFO\nFILEVERSION " & commas & "\nPRODUCTVERSION " & commas &
      "\nFILEOS 0x40004\nFILETYPE 0x1\nBEGIN\n" &
      "  BLOCK \"StringFileInfo\"\n  BEGIN\n    BLOCK \"040904B0\"\n    BEGIN\n" &
      "      VALUE \"CompanyName\", \"xrfez\"\n" &
      "      VALUE \"FileDescription\", \"viewSEG seismic viewer\"\n" &
      "      VALUE \"FileVersion\", \"" & v & "\"\n" &
      "      VALUE \"InternalName\", \"viewSEG\"\n" &
      "      VALUE \"OriginalFilename\", \"viewSEG.exe\"\n" &
      "      VALUE \"ProductName\", \"viewSEG\"\n" &
      "      VALUE \"ProductVersion\", \"" & v & "\"\n" &
      "    END\n  END\n  BLOCK \"VarFileInfo\"\n  BEGIN\n" &
      "    VALUE \"Translation\", 0x0409, 1200\n  END\nEND\n"

  proc run(cmd: string) {.compileTime.} =
    let (output, code) = gorgeEx(cmd)
    if code != 0:
      raiseAssert "winres: `" & cmd & "` failed:\n" & output

  proc resourceObject(): string {.compileTime.} =
    ## Writes the .rc file, compiles it, and returns the file to link.
    # The nimcache may not exist yet this early in the compile.
    when windowsHost:
      run "cmd /c if not exist " & quoteShell(outDir) & " mkdir " & quoteShell(outDir)
    else:
      run "mkdir -p " & quoteShell(outDir)
    let rc = outDir /+ "viewSEG_res.rc"
    writeFile(rc, rcText())
    when defined(zigcc):
      result = outDir /+ "viewSEG_res.res"
      run (if windresExe.len > 0: windresExe else: "zig rc") & " /fo " &
        quoteShell(result) & " " & quoteShell(rc)
    elif defined(vcc):
      result = outDir /+ "viewSEG_res.res"
      run (if windresExe.len > 0: windresExe else: "rc") & " /nologo /fo " &
        quoteShell(result) & " " & quoteShell(rc)
    else:
      result = outDir /+ "viewSEG_res.o"
      let tool =
        if windresExe.len > 0: windresExe
        elif windowsHost: "windres"        # MSYS2 / MinGW
        else: "x86_64-w64-mingw32-windres" # cross-compiling from Linux
      run tool & " -O coff -i " & quoteShell(rc) & " -o " & quoteShell(result)

  const resObject = resourceObject()
  {.link: resObject.}

  when not defined(console):
    when defined(vcc):
      {.passL: "/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup".}
    elif defined(zigcc): # zig cc ignores -mwindows
      {.passL: "-Wl,--subsystem,windows".}
    else:
      {.passL: "-mwindows".}
