## The frame Windows draws around a window: the title bar's colours, its dark
## or light mode, the corners and the border, set through DWM window
## attributes on a native window handle (`HWND`); and the window's own icons
## at the size its screen wants. The frontend gives the handle and the
## colours (docs/architecture.md, "Windows: what makes the window look
## native"); this module knows no toolkit and no theme.
##
## What is set, by Windows version (`dwmSettings`):
##
## | Attribute | Id | Windows | Value |
## |---|---|---|---|
## | `DWMWA_USE_IMMERSIVE_DARK_MODE` | 20 | 10 20H1 (build 18985) and later | the theme is dark |
## | the same, before 20H1 | 19 | 10 1809 to 1909 (17763 .. 18984) | the theme is dark |
## | `DWMWA_CAPTION_COLOR` | 35 | 11 (22000) | the title bar |
## | `DWMWA_TEXT_COLOR` | 36 | 11 | the title |
## | `DWMWA_BORDER_COLOR` | 34 | 11 | the border, framed windows only |
## | `DWMWA_WINDOW_CORNER_PREFERENCE` | 33 | 11 | round when framed, square when not |
##
## When the version is unknown (`RtlGetVersion` failed) every attribute is
## tried, the dark mode as 20 and then 19, and an attribute Windows does not
## know is refused (`E_INVALIDARG`) with no harm: nothing here can fail on
## Windows 10. `DWMWA_SYSTEMBACKDROP_TYPE` (Mica, 38) is not set: the
## frontend paints the whole client area opaque, so Mica could show only in
## the title bar, which the caption colour paints over.
##
## SDL sets the system's dark mode on every window again after each
## `WM_SETTINGCHANGE` "ImmersiveColorSet", which Windows sends for accent and
## other personalisation changes too, without telling the program; each
## window given a look is therefore subclassed (`SetWindowSubclass`, Common
## Controls 6) and set again right after SDL has handled that message.
##
## Frameless windows (the frontend's own windows dragged out of the main
## one, its menus and tooltips outside it) draw their own title and border:
## they get the dark mode and square corners only, so Windows 11 neither
## clips their drawn corners nor adds a second border.
##
## Every Win32 function is looked up at run time (`std/dynlib`), so a
## missing one is skipped, never a failure to start. On other systems the
## procs do nothing; the pure functions work everywhere and are tested there.

type
  ChromeRgb* = object
    ## An opaque colour, 0 .. 255 a channel.
    r*, g*, b*: uint8

  ChromeLook* = object
    ## What a window's frame looks like.
    dark*: bool             ## dark title bar (Windows 10's only colour choice)
    caption*: ChromeRgb     ## the title bar (Windows 11)
    captionText*: ChromeRgb ## the title on it
    border*: ChromeRgb      ## the one-pixel border of a framed window

  FrameKind* = enum
    ## Whether Windows draws the window's title bar.
    fkFramed    ## a title bar and borders: the main window
    fkFrameless ## none: the frontend draws its own

  WindowsVersion* = object
    ## `RtlGetVersion`'s answer; `build` 0 when it is not known.
    major*, minor*, build*: int

  DwmSetting* = object
    ## One `DwmSetWindowAttribute` call: a DWORD `value` for `attribute`,
    ## then `fallback` (when not 0) with the same value if it is refused.
    attribute*, value*, fallback*: uint32

const
  DwmwaUseImmersiveDarkModeBefore20H1* = 19'u32
  DwmwaUseImmersiveDarkMode* = 20'u32
  DwmwaWindowCornerPreference* = 33'u32
  DwmwaBorderColor* = 34'u32
  DwmwaCaptionColor* = 35'u32
  DwmwaTextColor* = 36'u32
  DwmwaSystemBackdropType* = 38'u32
  DwmwcpDoNotRound* = 1'u32 ## `DWMWCP_DONOTROUND`
  DwmwcpRound* = 2'u32      ## `DWMWCP_ROUND`
  DarkModeBuild* = 17763    ## Windows 10 1809: the first dark title bar (attribute 19)
  DarkMode20Build* = 18985  ## the build that renumbered it 20 (released in 20H1)
  Windows11Build* = 22000   ## caption, text and border colours, corners
  UnknownVersion* = WindowsVersion()

func colorRef*(c: ChromeRgb): uint32 =
  ## `c` as a Win32 `COLORREF`: `0x00BBGGRR`.
  c.r.uint32 or (c.g.uint32 shl 8) or (c.b.uint32 shl 16)

func known(v: WindowsVersion): bool = v.build > 0

func darkModeSetting*(v: WindowsVersion; dark: bool): seq[DwmSetting] =
  ## The dark mode attribute for `v`: 20 from build 18985, 19 from 17763,
  ## none before (Windows 10 1803 and older have no dark title bar); 20 then
  ## 19 when the version is not known.
  let value = if dark: 1'u32 else: 0'u32
  if not v.known:
    @[DwmSetting(attribute: DwmwaUseImmersiveDarkMode, value: value,
      fallback: DwmwaUseImmersiveDarkModeBefore20H1)]
  elif v.build >= DarkMode20Build:
    @[DwmSetting(attribute: DwmwaUseImmersiveDarkMode, value: value)]
  elif v.build >= DarkModeBuild:
    @[DwmSetting(attribute: DwmwaUseImmersiveDarkModeBefore20H1, value: value)]
  else:
    @[]

func dwmSettings*(look: ChromeLook; kind: FrameKind; v: WindowsVersion): seq[DwmSetting] =
  ## Every attribute to set on a window of `kind` for `look` on Windows `v`,
  ## in order (the table in the module doc).
  result = darkModeSetting(v, look.dark)
  if not v.known or v.build >= Windows11Build:
    case kind
    of fkFramed:
      result.add DwmSetting(attribute: DwmwaCaptionColor, value: colorRef(look.caption))
      result.add DwmSetting(attribute: DwmwaTextColor, value: colorRef(look.captionText))
      result.add DwmSetting(attribute: DwmwaBorderColor, value: colorRef(look.border))
      result.add DwmSetting(attribute: DwmwaWindowCornerPreference, value: DwmwcpRound)
    of fkFrameless:
      result.add DwmSetting(attribute: DwmwaWindowCornerPreference, value: DwmwcpDoNotRound)

func iconSizes*(dpi: int): tuple[big, small: int] =
  ## The sizes of a window's big (Alt+Tab, taskbar) and small (title bar)
  ## icons at `dpi` (96 = 100 %), as `GetSystemMetricsForDpi` gives them:
  ## 32 and 16 pixels at 100 %, scaled and rounded down.
  let d = if dpi <= 0: 96 else: dpi
  (32 * d div 96, 16 * d div 96)

const
  WmSettingChange* = 0x001A'u32
  ImmersiveColorSet* = "ImmersiveColorSet"

func resetsDarkMode*(msg: uint32; setting: string): bool =
  ## Whether window message `msg` with the setting name `setting` (its
  ## `lParam`) is one after which SDL sets the system's dark mode on the window
  ## again: `WM_SETTINGCHANGE` "ImmersiveColorSet", which Windows sends for a
  ## light/dark switch and for accent and other personalisation changes too.
  msg == WmSettingChange and setting == ImmersiveColorSet

when defined(windows):
  import std/dynlib

  type
    Hwnd = pointer
    OsVersionInfoW {.bycopy.} = object
      ## `RTL_OSVERSIONINFOW`
      size, major, minor, build, platformId: uint32
      csdVersion: array[128, uint16]

    DwmSetWindowAttributeFn = proc (hwnd: Hwnd; attribute: uint32; value: pointer;
      size: uint32): int32 {.stdcall, gcsafe, raises: [].}
    RtlGetVersionFn = proc (info: ptr OsVersionInfoW): int32 {.stdcall, gcsafe, raises: [].}
    SetWindowPosFn = proc (hwnd, after: Hwnd; x, y, cx, cy: int32;
      flags: uint32): int32 {.stdcall, gcsafe, raises: [].}
    GetDpiForWindowFn = proc (hwnd: Hwnd): uint32 {.stdcall, gcsafe, raises: [].}
    GetModuleHandleWFn = proc (name: pointer): pointer {.stdcall, gcsafe, raises: [].}
    LoadImageWFn = proc (instance: pointer; name: pointer; kind: uint32; cx, cy: int32;
      load: uint32): pointer {.stdcall, gcsafe, raises: [].}
    SendMessageWFn = proc (hwnd: Hwnd; msg: uint32; wParam: uint; lParam: int): int {.
      stdcall, gcsafe, raises: [].}
    SubclassProc = proc (hwnd: Hwnd; msg: uint32; wParam: uint; lParam: int; id: uint;
      refData: uint): int {.stdcall, gcsafe, raises: [].}
    SetWindowSubclassFn = proc (hwnd: Hwnd; subclass: SubclassProc; id: uint;
      refData: uint): int32 {.stdcall, gcsafe, raises: [].}
    RemoveWindowSubclassFn = proc (hwnd: Hwnd; subclass: SubclassProc; id: uint): int32 {.
      stdcall, gcsafe, raises: [].}
    DefSubclassProcFn = proc (hwnd: Hwnd; msg: uint32; wParam: uint; lParam: int): int {.
      stdcall, gcsafe, raises: [].}

  static: doAssert sizeof(OsVersionInfoW) == 276

  const
    SwpNoSize = 0x0001'u32
    SwpNoMove = 0x0002'u32
    SwpNoZOrder = 0x0004'u32
    SwpNoActivate = 0x0010'u32
    SwpFrameChanged = 0x0020'u32
    SwpNoOwnerZOrder = 0x0200'u32
    ImageIcon = 1'u32
    WmSetIcon = 0x0080'u32
    WmNcDestroy = 0x0082'u32
    SubclassId = 0x56534547'u # "VSEG"
    IconSmall = 0'u
    IconBig = 1'u

  var
    looked = false
    dwmSet: DwmSetWindowAttributeFn
    rtlGetVersion: RtlGetVersionFn
    setWindowPos: SetWindowPosFn
    getDpiForWindow: GetDpiForWindowFn
    getModuleHandle: GetModuleHandleWFn
    loadImage: LoadImageWFn
    sendMessage: SendMessageWFn
    icons: seq[(int, pointer)] ## loaded icons by size, kept for the program's life
    setWindowSubclass: SetWindowSubclassFn
    removeWindowSubclass: RemoveWindowSubclassFn
    defSubclassProc: DefSubclassProcFn
    keptLook: ChromeLook       ## the look the windows keep (`applyChrome`'s last)
    keptVersion: WindowsVersion

  proc lookUp() =
    ## Finds the functions once (main thread).
    if looked: return
    looked = true
    proc find(lib: LibHandle; name: string): pointer =
      if lib.isNil: nil else: lib.symAddr(name)
    let dwm = loadLib("dwmapi.dll")
    let ntdll = loadLib("ntdll.dll")
    let user32 = loadLib("user32.dll")
    let kernel32 = loadLib("kernel32.dll")
    dwmSet = cast[DwmSetWindowAttributeFn](find(dwm, "DwmSetWindowAttribute"))
    rtlGetVersion = cast[RtlGetVersionFn](find(ntdll, "RtlGetVersion"))
    setWindowPos = cast[SetWindowPosFn](find(user32, "SetWindowPos"))
    getDpiForWindow = cast[GetDpiForWindowFn](find(user32, "GetDpiForWindow")) # 10 1607+
    loadImage = cast[LoadImageWFn](find(user32, "LoadImageW"))
    sendMessage = cast[SendMessageWFn](find(user32, "SendMessageW"))
    getModuleHandle = cast[GetModuleHandleWFn](find(kernel32, "GetModuleHandleW"))
    let comctl32 = loadLib("comctl32.dll") # version 6, as the manifest asks
    setWindowSubclass = cast[SetWindowSubclassFn](find(comctl32, "SetWindowSubclass"))
    removeWindowSubclass = cast[RemoveWindowSubclassFn](find(comctl32, "RemoveWindowSubclass"))
    defSubclassProc = cast[DefSubclassProcFn](find(comctl32, "DefSubclassProc"))

proc windowsVersion*(): WindowsVersion =
  ## The running Windows' version from `RtlGetVersion` (which, unlike
  ## `GetVersionEx`, is not shimmed); `UnknownVersion` when it cannot say,
  ## and elsewhere than Windows.
  result = UnknownVersion
  when defined(windows):
    lookUp()
    if rtlGetVersion != nil:
      var info = OsVersionInfoW(size: uint32(sizeof(OsVersionInfoW)))
      if rtlGetVersion(addr info) == 0:
        result = WindowsVersion(major: info.major.int, minor: info.minor.int,
          build: info.build.int)

when defined(windows):
  proc setAttributes(hwnd: pointer; look: ChromeLook; kind: FrameKind; version: WindowsVersion;
      redraw: bool): int {.gcsafe, raises: [].} =
    result = 0
    {.cast(gcsafe).}:
      for s in dwmSettings(look, kind, version):
        var value = s.value
        if dwmSet(hwnd, s.attribute, addr value, 4) >= 0:
          inc result
        elif s.fallback != 0 and dwmSet(hwnd, s.fallback, addr value, 4) >= 0:
          inc result
      if redraw and setWindowPos != nil:
        discard setWindowPos(hwnd, nil, 0, 0, 0, 0, SwpNoSize or SwpNoMove or SwpNoZOrder or
          SwpNoActivate or SwpNoOwnerZOrder or SwpFrameChanged)

  proc keepLook(hwnd: Hwnd; msg: uint32; wParam: uint; lParam: int; id: uint;
      refData: uint): int {.stdcall, gcsafe, raises: [].} =
    ## The windows' subclass: SDL's window procedure first, then, after a
    ## settings change SDL answers by setting the system's dark mode
    ## (`resetsDarkMode`), the kept look again.
    {.cast(gcsafe).}:
      result = defSubclassProc(hwnd, msg, wParam, lParam)
      if msg == WmSettingChange and lParam != 0:
        var setting = ""
        let wide = cast[ptr UncheckedArray[uint16]](lParam)
        var i = 0
        while i < 64 and wide[i] != 0:
          setting.add char(wide[i] and 0x7f)
          inc i
        if resetsDarkMode(msg, setting):
          discard setAttributes(hwnd, keptLook, FrameKind(refData), keptVersion, redraw = true)
      elif msg == WmNcDestroy:
        discard removeWindowSubclass(hwnd, keepLook, SubclassId)

proc applyChrome*(hwnd: pointer; look: ChromeLook; kind = fkFramed;
    version = windowsVersion(); redraw = false): int =
  ## Sets `look` on window `hwnd` (`dwmSettings`); with `redraw`, has
  ## Windows draw the frame again at once (for a window already shown: Windows
  ## 10 repaints a changed title bar only then). The window keeps the look:
  ## after each `WM_SETTINGCHANGE` "ImmersiveColorSet" (a light/dark or accent
  ## change), on which SDL sets the system's dark mode on it, it is set again
  ## (a window subclass, `SetWindowSubclass`). Returns how many attributes
  ## Windows took; 0 elsewhere than Windows, for a nil handle, and without
  ## DWM.
  result = 0
  when defined(windows):
    lookUp()
    if hwnd != nil and dwmSet != nil:
      (keptLook, keptVersion) = (look, version)
      if setWindowSubclass != nil and defSubclassProc != nil and removeWindowSubclass != nil:
        discard setWindowSubclass(hwnd, keepLook, SubclassId, uint(ord(kind)))
      result = setAttributes(hwnd, look, kind, version, redraw)

proc setWindowIcons*(hwnd: pointer; resourceId = 1): bool =
  ## Gives window `hwnd` the executable's icon `resourceId` (`platform/winres`)
  ## at exactly the sizes its screen's DPI wants (`iconSizes`), taken from the
  ## icon file's own images: Windows' default is one size scaled for both.
  ## Call again when the window's DPI changes. False when nothing was set,
  ## and elsewhere than Windows.
  result = false
  when defined(windows):
    lookUp()
    if hwnd != nil and loadImage != nil and sendMessage != nil and getModuleHandle != nil:
      let dpi = if getDpiForWindow != nil: getDpiForWindow(hwnd).int else: 96
      let (big, small) = iconSizes(dpi)
      proc icon(size: int): pointer =
        for (s, h) in icons:
          if s == size: return h
        result = loadImage(getModuleHandle(nil), cast[pointer](uint(resourceId)), ImageIcon,
          int32(size), int32(size), 0)
        if result != nil: icons.add (size, result)
      let (b, s) = (icon(big), icon(small))
      if b != nil: discard sendMessage(hwnd, WmSetIcon, IconBig, cast[int](b))
      if s != nil: discard sendMessage(hwnd, WmSetIcon, IconSmall, cast[int](s))
      result = b != nil or s != nil
