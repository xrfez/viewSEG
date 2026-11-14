## Headless frame tests for the ImGui frontend: open the SDL3 / OpenGL 3 window,
## draw a few frames and read the last one back.
##
## Pass/fail rule: it needs a display. Run it under
## `xvfb-run -a -s "-screen 0 1920x1080x24" nim test` (CI does) or on a desktop.
## Without a usable video device or GL context, `run` fails and so does this
## test, loudly, with SDL's reason. There is no skip: a skipped GUI test would let
## CI go green without a frame ever being drawn.
##
## What is checked, in each theme: the panels are the theme's window colour,
## the bars its bar colour and the gaps its backdrop; an icon glyph (Open file)
## and a custom symbol (Wiggle, selected, so in the accent colour) leave pixels
## where the frontend says it drew them; no pixel is Dear ImGui's stock blue.
## Then: missing and unreadable fonts fall back and say so; a theme file that is
## not Everforest changes the background and the accent; 200 % grows the bars.
##
## `VIEWSEG_SCREENSHOTS=<dir>` also saves shell-dark.png, shell-light.png and
## shell-dark-200.png there (docs/screenshots/ holds the committed ones).

import std/[options, os, strutils]
import viewSEG/core/geometry
import viewSEG/view/theme
import viewSEG/ui/imgui/[app, shell]

const
  frames = 5
  repoAssets = currentSourcePath().parentDir.parentDir / "assets"
  markNames = ["toolbar", "statusbar", "plot", "table", "tool.Open file", "tool.Wiggle",
    "tool.Greyscale density"]
  stockBlue = Rgba(r: 66, g: 150, b: 250, a: 255) # Dear ImGui's accent

type Shot = object
  width, height: int
  theme: Theme
  scale: float32
  pixels: seq[Rgba]
  marks: seq[(string, Rect)]
  messages: seq[Message]

proc render(opts: RunOptions; save = ""): Shot =
  ## Runs the frontend for `frames` frames and keeps the last one.
  var opts = opts
  var shot: Shot
  var seen = 0
  opts.maxFrames = frames
  opts.onFrame = proc (f: FrameInfo) =
    inc seen
    if f.index == frames - 1:
      shot = Shot(width: f.width, height: f.height, theme: f.theme, scale: f.scale,
        pixels: f.readFrame(), messages: f.messages.items)
      for n in markNames:
        shot.marks.add (n, f.markOf(n))
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if save.len > 0 and dir.len > 0:
        createDir(dir)
        doAssert f.savePng(dir / save), "cannot save " & dir / save
        echo "tgui: saved ", dir / save
  let code = run(opts)
  if code != 0:
    echo "FAIL tgui: the window could not be opened (see the SDL error above).\n" &
      "  It needs a display: run `xvfb-run -a -s \"-screen 0 1920x1080x24\" nim test`."
  doAssert code == 0, "run() exit code " & $code
  doAssert seen == frames, "frames seen: " & $seen
  doAssert shot.width > 400 and shot.height > 300, $shot.width & "x" & $shot.height
  shot

func at(s: Shot; x, y: int): Rgba = s.pixels[y * s.width + x]

func mark(s: Shot; name: string): Rect =
  for (n, r) in s.marks:
    if n == name: return r
  raise newException(KeyError, "no mark " & name)

func count(s: Shot; r: Rect; pred: proc (c: Rgba): bool {.noSideEffect.}): int =
  ## Pixels inside `r` for which `pred` holds.
  result = 0
  for y in max(0, r.pos.y.int) ..< min(s.height, int(r.pos.y + r.size.y)):
    for x in max(0, r.pos.x.int) ..< min(s.width, int(r.pos.x + r.size.x)):
      if pred(s.at(x, y)): inc result

func warnings(s: Shot): seq[string] =
  for m in s.messages:
    if m.level != mlInfo: result.add m.text

func has(s: Shot; part: string): bool =
  for m in s.messages:
    if part in m.text: return true
  false

proc checkLook(s: Shot; t: Theme) =
  ## The frame is drawn in theme `t`.
  let r = t.roles
  let table = s.mark("table")
  doAssert table.size.x > 50 and table.size.y > 50, $table
  let inPanel = s.at(int(table.pos.x + table.size.x) - 6, int(table.pos.y + table.size.y) - 6)
  doAssert distance(inPanel, r[rlWindow]) <= 1,
    t.name & ": panel " & toHex(inPanel) & ", window colour " & toHex(r[rlWindow])
  let inBar = s.at(s.width - 3, s.height - 3)
  doAssert distance(inBar, r[rlBar]) <= 1, t.name & ": status bar " & toHex(inBar)
  let toolbar = s.mark("toolbar")
  let gap = s.at(1, int(toolbar.pos.y + toolbar.size.y) + 60)
  doAssert distance(gap, r[rlBackdrop]) <= 1, t.name & ": gap " & toHex(gap)
  let bar = r[rlBar]
  let accent = r[rlAccent]
  let glyph = s.count(s.mark("tool.Open file"), proc (c: Rgba): bool = distance(c, bar) > 60)
  doAssert glyph >= 10, t.name & ": the Open file icon left " & $glyph & " pixels"
  let symbol = s.count(s.mark("tool.Wiggle"), proc (c: Rgba): bool = distance(c, accent) <= 24)
  doAssert symbol >= 10, t.name & ": the Wiggle symbol left " & $symbol & " accent pixels"
  let blue = s.count(Rect(size: vec2(s.width.float32, s.height.float32)),
    proc (c: Rgba): bool = distance(c, stockBlue) <= 30)
  doAssert blue == 0, t.name & ": " & $blue & " pixels of Dear ImGui's blue"

let themeDir = repoAssets / "themes"
let tmp = getTempDir() / ("viewseg_tgui_" & $getCurrentProcessId())
let noUserThemes = some(tmp / "no-user-themes")
createDir(tmp)
var toolbar100 = 0'f32
try:
  block themes:
    for (choice, builtin, file) in [(forceDark, EverforestDark, "shell-dark.png"),
        (forceLight, EverforestLight, "shell-light.png")]:
      let s = render(RunOptions(theme: choice, userThemeDir: noUserThemes), file)
      doAssert s.theme == builtin, s.theme.name # the shipped file, loaded unchanged
      doAssert s.warnings.len == 0, $s.warnings
      s.checkLook(builtin)
      if choice == forceDark:
        toolbar100 = s.mark("toolbar").size.y
      echo "tgui: ", s.theme.name, " ", s.width, "x", s.height, " scale ", s.scale,
        ": checks pass"

  block liveThemeChanges:
    # The system switches to light, then the user picks a theme in the menu,
    # then goes back to following the system: each restyles the next frame.
    var seen: seq[string]
    let code = run(RunOptions(maxFrames: 7, userThemeDir: noUserThemes,
      onFrame: proc (f: FrameInfo) =
        seen.add f.theme.name
        case f.index
        of 1: postShellEvent(ShellEvent(kind: seThemeChanged, theme: stDark))
        of 3: postShellEvent(ShellEvent(kind: seThemeChanged, theme: stLight))
        of 4: f.chooseTheme("everforest-dark")
        of 5: f.chooseTheme("")
        else: discard))
    doAssert code == 0
    doAssert seen[2 .. 6] == @["Everforest Dark", "Everforest Dark", "Everforest Light",
      "Everforest Dark", "Everforest Light"], $seen
    echo "tgui: live theme changes: ", seen[2 .. 6]

  block missingFonts:
    # Assets without fonts/: the built-in font, a warning, and a full frame.
    let assets = tmp / "assets-nofonts"
    createDir(assets / "themes")
    copyFile(themeDir / "everforest-dark.toml", assets / "themes" / "everforest-dark.toml")
    let s = render(RunOptions(theme: forceDark, assetDirs: some(@[assets]),
      userThemeDir: noUserThemes))
    doAssert s.has("Fonts: `JetBrainsMonoNerdFontPropo-Regular.ttf` not found") and
      s.has("Using the built-in font"), $s.messages
    doAssert s.theme == EverforestDark
    let r = s.mark("table")
    doAssert distance(s.at(int(r.pos.x + r.size.x) - 6, int(r.pos.y + r.size.y) - 6),
      EverforestDark.roles[rlWindow]) <= 1
    echo "tgui: missing fonts: ", s.warnings[0]

  block unreadableFontsAndNoAssets:
    let assets = tmp / "assets-badfonts"
    createDir(assets / "fonts")
    let real = readFile(repoAssets / "fonts" / DefaultFonts[frMono])
    writeFile(assets / "fonts" / DefaultFonts[frUi], "this is not a font")
    writeFile(assets / "fonts" / DefaultFonts[frMono], real[0 ..< 4096]) # truncated
    writeFile(assets / "fonts" / DefaultFonts[frHeading], "")
    let s = render(RunOptions(theme: forceLight, assetDirs: some(@[assets]),
      userThemeDir: noUserThemes))
    doAssert s.has(DefaultFonts[frUi] & " is not a TrueType or OpenType font"), $s.messages
    doAssert s.has(DefaultFonts[frMono] & " is not a TrueType or OpenType font")
    doAssert s.has(DefaultFonts[frHeading] & " is not a TrueType or OpenType font") # empty
    doAssert s.theme == EverforestLight # no theme file there: the built-in one
    let none = render(RunOptions(theme: forceDark, assetDirs: some(newSeq[string]()),
      userThemeDir: noUserThemes))
    doAssert none.has("No assets folder found") and none.has("Using the built-in font")
    doAssert none.theme == EverforestDark
    echo "tgui: unreadable fonts and no assets: fall back, logged"

  block anotherPalette:
    # A theme that is not Everforest, in the same format, chosen by name from
    # the user's theme folder (as VIEWSEG_THEME=slate would).
    let user = tmp / "user-themes"
    createDir(user)
    writeFile(user / "slate.toml", """
# a blue-grey test palette with an amber accent
name = "Slate"
mode = "dark"
accent = "#e3a33b"
selection = "#3e4c59"
muted = "#52606d"
background = "#1f2933"
dark_background = "#18212a"
darker_background = "#11181f"
lighter_background = "#27333f"
foreground = "#e4e7eb"
dark_foreground = "#616e7c"
light_foreground = "#9aa5b1"
bright_foreground = "#f5f7fa"
red = "#ef4e4e"
yellow = "#f7c948"
orange = "#f0b429"
green = "#57ae5b"
cyan = "#38bec9"
blue = "#47a3f3"
magenta = "#da4a91"
brown = "#8d6e63"
""")
    putEnv("VIEWSEG_THEME", "slate")
    let s = render(RunOptions(userThemeDir: some(user)))
    delEnv("VIEWSEG_THEME")
    doAssert s.theme.name == "Slate", s.theme.name
    doAssert s.warnings.len == 0, $s.warnings
    doAssert s.theme.roles[rlWindow] == rgb(0x1f2933)
    doAssert s.theme.roles[rlAccent] == rgb(0xe3a33b)
    s.checkLook(s.theme) # background, bars, gaps and the accent all changed
    echo "tgui: a non-Everforest theme file restyles background and accent"

  block doubleScale:
    # SDL's X11 driver takes its content scale from this variable. Under another
    # video driver (SDL_VIDEO_DRIVER=wayland) it does not apply: skip there.
    if getEnv("SDL_VIDEO_DRIVER") notin ["", "x11"]:
      echo "tgui: 200 % check skipped (SDL_VIDEO_DRIVER=", getEnv("SDL_VIDEO_DRIVER"), ")"
    else:
      putEnv("SDL_VIDEO_X11_SCALING_FACTOR", "2")
      let big = render(RunOptions(theme: forceDark, userThemeDir: noUserThemes),
        "shell-dark-200.png")
      delEnv("SDL_VIDEO_X11_SCALING_FACTOR")
      doAssert big.scale == 2, "scale " & $big.scale
      let h = big.mark("toolbar").size.y
      doAssert h >= 1.8 * toolbar100, "toolbar " & $h & " px at 200 %, " & $toolbar100 &
        " at 100 %"
      big.checkLook(EverforestDark)
      echo "tgui: 200 %: ", big.width, "x", big.height, ", toolbar ", h, " px"
finally:
  removeDir(tmp)
