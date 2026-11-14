## Themes: the colours, fonts and metrics of the whole program, without any
## toolkit (docs/architecture.md). The frontend maps a `Theme` onto its widgets
## (`ui/imgui/style`); views and kernels read its roles (trace colours, the
## linked-selection highlight, the series palette).
##
## **A theme file is an Omarchy `colors.toml`, plus optional tables.** Any
## Omarchy theme's `colors.toml` works unchanged, in either of its two forms:
##
## - the semantic keys (`BaseColor`): `accent`, `background`, `foreground`,
##   `red` ... `brown`, `bright_*`, and `mode = "dark" | "light"`;
## - the terminal keys of Omarchy's own themes: `color0` .. `color15`,
##   `selection_background`, `cursor`, `selection_foreground`.
##
## Optional additions: `name = "..."` (the display name; default: from the file
## name), and the tables `[fonts]` (file names: `ui`, `mono`, `heading`, an
## optional `icons` font merged into `ui`; `size`, `heading_size` in pixels at
## 100 %), `[metrics]` (`Metrics`, in pixels at 100 %) and `[roles]` (any `Role`,
## as `"#rrggbb"`, `"#rrggbbaa"` or a base key such as `"yellow"`), plus
## `series = [...]` in `[roles]` for the categorical palette.
##
## The syntax is the TOML subset those need: `key = value` lines, `[table]`
## headers, `#` comments, strings in `"..."` or `'...'`, numbers, `true` /
## `false`, and one-line arrays of strings. A theme never fails to load: an
## unknown key, a bad value or a missing colour is reported as a message and the
## built-in value (Everforest of the same mode) takes its place.
##
## **Roles are derived** from the base colours by `deriveRoles`, so a palette of
## twenty colours is a whole theme. Data colours are not chrome colours: the
## greyscale density map stays neutral whatever the theme.

import std/[algorithm, math, os, parseutils, strutils]
import ../core/geometry

type
  ThemeMode* = enum
    ## Which kind of theme: light text on a dark background, or the reverse.
    tmDark = "dark", tmLight = "light"

  BaseColor* = enum
    ## The palette: the keys of an Omarchy `colors.toml`. The string is the key.
    bcAccent = "accent"                 ## focus, the active tab, links
    bcSelection = "selection"           ## selected and hovered items
    bcMuted = "muted"                   ## borders and separators
    bcBackground = "background"         ## windows and panels
    bcDarkBackground = "dark_background"     ## bars: menu, toolbar, status, tabs
    bcDarkerBackground = "darker_background" ## the backdrop between panels
    bcLighterBackground = "lighter_background" ## raised: inputs, buttons, popups
    bcForeground = "foreground"         ## text
    bcDarkForeground = "dark_foreground"     ## the faintest text: hints
    bcLightForeground = "light_foreground"   ## secondary text
    bcBrightForeground = "bright_foreground" ## emphasised text
    bcRed = "red", bcYellow = "yellow", bcOrange = "orange", bcGreen = "green",
    bcCyan = "cyan", bcBlue = "blue", bcMagenta = "magenta", bcBrown = "brown",
    bcBrightRed = "bright_red", bcBrightYellow = "bright_yellow",
    bcBrightGreen = "bright_green", bcBrightCyan = "bright_cyan",
    bcBrightBlue = "bright_blue", bcBrightMagenta = "bright_magenta"

  Palette* = array[BaseColor, Rgba]

  Role* = enum
    ## What a colour is for. `deriveRoles` documents where each comes from; a
    ## theme file may override any of them in `[roles]` under this name.
    rlBackdrop = "backdrop"           ## behind and between docked panels
    rlWindow = "window"               ## window and panel backgrounds
    rlPopup = "popup"                 ## menus, popups, tooltips
    rlBar = "bar"                     ## menu bar, toolbar, status bar, tab strips
    rlFrame = "frame"                 ## inputs, buttons, scrollbar grabs
    rlText = "text"
    rlTextDim = "text_dim"            ## secondary text, labels, units
    rlTextDisabled = "text_disabled"  ## disabled items, hints
    rlBorder = "border"
    rlSelection = "selection"         ## selected rows, items, tabs
    rlHover = "hover"                 ## anything under the mouse
    rlActive = "active"               ## pressed
    rlAccent = "accent"               ## focus, current tab, checks, sliders
    rlHighlight = "highlight"         ## linked selection: map <-> traces
    rlOk = "ok", rlWarning = "warning", rlError = "error", rlInfo = "info"
    rlPlotBackground = "plot_background"
    rlPlotGrid = "plot_grid"
    rlTrace = "trace"                 ## the default wiggle line
    rlFillPositive = "fill_positive"  ## the default positive-lobe fill
    rlFillNegative = "fill_negative"  ## the default negative-lobe fill
    rlCrosshair = "crosshair"

  FontRole* = enum
    ## The faces of the interface.
    frUi = "ui"           ## labels, menus, buttons (proportional, with icons)
    frMono = "mono"       ## tables, numbers, the status bar
    frHeading = "heading" ## headings, table headers (bold)

  Metrics* = object
    ## Sizes in pixels at 100 %; the frontend multiplies them by the UI scale.
    fontSize*: float32      ## `ui` and `mono` text
    headingSize*: float32
    rounding*: float32      ## popups, child panels
    frameRounding*: float32 ## inputs, buttons, tabs, grabs, scrollbars
    borderWidth*: float32
    windowPadding*: float32
    framePaddingX*, framePaddingY*: float32
    itemSpacingX*, itemSpacingY*: float32
    scrollbarSize*: float32

  Theme* = object
    name*: string
    mode*: ThemeMode
    palette*: Palette
    roles*: array[Role, Rgba]
    series*: array[8, Rgba] ## categorical colours: components, overlays
    fonts*: array[FontRole, string]
      ## font file names, relative to an assets `fonts/` directory, or absolute
    iconFont*: string ## a font merged into `ui` for icons; "" when `ui` has them
    metrics*: Metrics

  ThemeFile* = object
    ## A theme file found on disk.
    name*: string ## the file name without `.toml`
    path*: string

const
  ThemeExt* = ".toml"
  DefaultFonts*: array[FontRole, string] = [
    frUi: "JetBrainsMonoNerdFontPropo-Regular.ttf",
    frMono: "JetBrainsMonoNerdFontMono-Regular.ttf",
    frHeading: "JetBrainsMonoNerdFontPropo-Bold.ttf"]
  DefaultMetrics* = Metrics(fontSize: 15, headingSize: 16, rounding: 6, frameRounding: 4,
    borderWidth: 1, windowPadding: 10, framePaddingX: 8, framePaddingY: 5,
    itemSpacingX: 8, itemSpacingY: 6, scrollbarSize: 12)

# ---------------------------------------------------------------- colours --

func rgb*(hex: uint32; a = 255'u8): Rgba =
  ## `0xRRGGBB` as a colour.
  Rgba(r: uint8(hex shr 16 and 0xff), g: uint8(hex shr 8 and 0xff), b: uint8(hex and 0xff),
    a: a)

func mixChannel(x, y: uint8; t: float32): uint8 =
  uint8(clamp(round(x.float32 + (y.float32 - x.float32) * t), 0, 255))

func mix*(a, b: Rgba; t: float32): Rgba =
  ## `a` moved by the fraction `t` (0..1) towards `b`, alpha included.
  Rgba(r: mixChannel(a.r, b.r, t), g: mixChannel(a.g, b.g, t), b: mixChannel(a.b, b.b, t),
    a: mixChannel(a.a, b.a, t))

func withAlpha*(c: Rgba; a: uint8): Rgba =
  Rgba(r: c.r, g: c.g, b: c.b, a: a)

func luminance*(c: Rgba): float32 =
  ## Relative luminance (WCAG), 0 for black .. 1 for white.
  func lin(x: uint8): float32 =
    let v = x.float32 / 255
    if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)

func contrast*(a, b: Rgba): float32 =
  ## The WCAG contrast ratio of two colours, 1 .. 21.
  let (la, lb) = (luminance(a), luminance(b))
  (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

func distance*(a, b: Rgba): int =
  ## The largest difference of the red, green and blue channels.
  max(abs(a.r.int - b.r.int), max(abs(a.g.int - b.g.int), abs(a.b.int - b.b.int)))

func toHex*(c: Rgba): string =
  ## `#rrggbb`, or `#rrggbbaa` when not opaque.
  result = "#" & toHex(c.r.int, 2) & toHex(c.g.int, 2) & toHex(c.b.int, 2)
  if c.a != 255:
    result.add toHex(c.a.int, 2)
  result = result.toLowerAscii

func parseColor*(s: string; c: var Rgba): bool =
  ## Reads `#rgb`, `#rrggbb` or `#rrggbbaa` (the `#` may be left out). False,
  ## with `c` unchanged, for anything else.
  let h = if s.startsWith("#"): s[1..^1] else: s
  result = false
  if h.len in [3, 6, 8] and h.allCharsInSet(HexDigits):
    if h.len == 3:
      let v = parseHexInt(h)
      c = Rgba(r: uint8((v shr 8 and 0xf) * 17), g: uint8((v shr 4 and 0xf) * 17),
        b: uint8((v and 0xf) * 17), a: 255)
    else:
      let v = parseHexInt(h[0..5])
      c = rgb(v.uint32, if h.len == 8: uint8(parseHexInt(h[6..7])) else: 255)
    result = true

# ------------------------------------------------------------------ roles --

func deriveRoles*(p: Palette; mode: ThemeMode): array[Role, Rgba] =
  ## The roles built from the palette. Backgrounds: `backdrop` is
  ## `darker_background`, `window` is `background`, `bar` is `dark_background`,
  ## `frame` is `lighter_background`, and `popup` is `lighter_background` in a
  ## dark theme and `background` in a light one (popups stay the brightest
  ## surface). Text: `foreground`, `light_foreground` (dim) and, for disabled,
  ## halfway between `dark_foreground` and `light_foreground`. `border` is
  ## `muted`; `selection` and `hover` are `selection`, `active` is `muted`.
  ## `accent` is `accent`, `highlight` is `orange`; ok / warning / error / info
  ## are green / yellow / red / blue. Plots: `dark_background` behind, a grid
  ## 12 % of the way to `foreground`. Traces: the line and the positive fill are
  ## `foreground`, the negative fill `red`; the crosshair is `accent`.
  result[rlBackdrop] = p[bcDarkerBackground]
  result[rlWindow] = p[bcBackground]
  result[rlPopup] = if mode == tmDark: p[bcLighterBackground] else: p[bcBackground]
  result[rlBar] = p[bcDarkBackground]
  result[rlFrame] = p[bcLighterBackground]
  result[rlText] = p[bcForeground]
  result[rlTextDim] = p[bcLightForeground]
  result[rlTextDisabled] = mix(p[bcDarkForeground], p[bcLightForeground], 0.5)
  result[rlBorder] = p[bcMuted]
  result[rlSelection] = p[bcSelection]
  result[rlHover] = p[bcSelection]
  result[rlActive] = p[bcMuted]
  result[rlAccent] = p[bcAccent]
  result[rlHighlight] = p[bcOrange]
  result[rlOk] = p[bcGreen]
  result[rlWarning] = p[bcYellow]
  result[rlError] = p[bcRed]
  result[rlInfo] = p[bcBlue]
  result[rlPlotBackground] = p[bcDarkBackground]
  result[rlPlotGrid] = mix(p[bcDarkBackground], p[bcForeground], 0.12)
  result[rlTrace] = p[bcForeground]
  result[rlFillPositive] = p[bcForeground]
  result[rlFillNegative] = p[bcRed]
  result[rlCrosshair] = p[bcAccent]

func deriveSeries*(p: Palette): array[8, Rgba] =
  ## Eight distinct colours for series and components, in this order of
  ## preference: accent, orange, green, magenta, yellow, cyan, red, blue, then
  ## the bright variants, secondary text and brown, skipping near-duplicates.
  var n = 0
  for k in [bcAccent, bcOrange, bcGreen, bcMagenta, bcYellow, bcCyan, bcRed, bcBlue,
      bcBrightRed, bcBrightGreen, bcBrightYellow, bcBrightBlue, bcBrightMagenta,
      bcBrightCyan, bcLightForeground, bcBrown, bcForeground]:
    var fresh = n < result.len
    for i in 0 ..< n:
      if distance(result[i], p[k]) < 24:
        fresh = false
    if fresh:
      result[n] = p[k]
      inc n
  while n < result.len: # a palette of near-identical colours
    result[n] = p[bcForeground]
    inc n

func makeTheme*(name: string; mode: ThemeMode; p: Palette;
    fonts = DefaultFonts; metrics = DefaultMetrics): Theme =
  ## A theme whose roles and series are derived from `p`.
  Theme(name: name, mode: mode, palette: p, roles: deriveRoles(p, mode),
    series: deriveSeries(p), fonts: fonts, metrics: metrics)

const
  everforestDarkPalette: Palette = [
    # Omarchy's Everforest (the owner's desktop): upstream medium contrast,
    # except orange and the two darkest backgrounds.
    bcAccent: rgb(0x7fbbb3), bcSelection: rgb(0x3d484d), bcMuted: rgb(0x475258),
    bcBackground: rgb(0x2d353b), bcDarkBackground: rgb(0x21272c),
    bcDarkerBackground: rgb(0x181d20), bcLighterBackground: rgb(0x343f44),
    bcForeground: rgb(0xd3c6aa), bcDarkForeground: rgb(0x4f585e),
    bcLightForeground: rgb(0x9da9a0), bcBrightForeground: rgb(0xd3c6aa),
    bcRed: rgb(0xe67e80), bcYellow: rgb(0xdbbc7f), bcOrange: rgb(0xe09d7f),
    bcGreen: rgb(0xa7c080), bcCyan: rgb(0x83c092), bcBlue: rgb(0x7fbbb3),
    bcMagenta: rgb(0xd699b6), bcBrown: rgb(0x704e3f),
    bcBrightRed: rgb(0xe67e80), bcBrightYellow: rgb(0xdbbc7f),
    bcBrightGreen: rgb(0xa7c080), bcBrightCyan: rgb(0x83c092),
    bcBrightBlue: rgb(0x7fbbb3), bcBrightMagenta: rgb(0xd699b6)]
  everforestLightPalette: Palette = [
    # Upstream sainnhe/everforest, light, medium contrast, in Omarchy's keys:
    # background bg0, dark_background bg1, lighter_background bg2, selection
    # bg3, darker_background bg4, muted bg5, dark_foreground grey0,
    # light_foreground grey2. Brown has no upstream value: orange 55 % of the
    # way to bg0.
    bcAccent: rgb(0x3a94c5), bcSelection: rgb(0xe6e2cc), bcMuted: rgb(0xbdc3af),
    bcBackground: rgb(0xfdf6e3), bcDarkBackground: rgb(0xf4f0d9),
    bcDarkerBackground: rgb(0xe0dcc7), bcLighterBackground: rgb(0xefebd4),
    bcForeground: rgb(0x5c6a72), bcDarkForeground: rgb(0xa6b0a0),
    bcLightForeground: rgb(0x829181), bcBrightForeground: rgb(0x5c6a72),
    bcRed: rgb(0xf85552), bcYellow: rgb(0xdfa000), bcOrange: rgb(0xf57d26),
    bcGreen: rgb(0x8da101), bcCyan: rgb(0x35a77c), bcBlue: rgb(0x3a94c5),
    bcMagenta: rgb(0xdf69ba), bcBrown: rgb(0xf9bc89),
    bcBrightRed: rgb(0xf85552), bcBrightYellow: rgb(0xdfa000),
    bcBrightGreen: rgb(0x8da101), bcBrightCyan: rgb(0x35a77c),
    bcBrightBlue: rgb(0x3a94c5), bcBrightMagenta: rgb(0xdf69ba)]

  EverforestDark* = makeTheme("Everforest Dark", tmDark, everforestDarkPalette)
  EverforestLight* = makeTheme("Everforest Light", tmLight, everforestLightPalette)
  DefaultThemeNames*: array[ThemeMode, string] = ["everforest-dark", "everforest-light"]
    ## The shipped files that "Follow system" uses for each mode.

func builtinTheme*(mode: ThemeMode): Theme =
  ## The theme compiled in for `mode`: what any missing value falls back to.
  if mode == tmDark: EverforestDark else: EverforestLight

# ------------------------------------------------------------- the parser --

type
  ValueKind = enum vkString, vkNumber, vkBool, vkArray
  Value = object
    kind: ValueKind
    str: string
    num: float
    items: seq[string]

  Entry = object
    line: int
    key: string ## with its table, e.g. `fonts.ui`
    value: Value

func stripComment(line: string): string =
  ## `line` without a `#` comment (a `#` inside quotes is kept).
  var quote = '\0'
  result = line
  for i, ch in line:
    if quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'"', '\''}:
      quote = ch
    elif ch == '#':
      return line[0 ..< i]

func parseString(s: string; i: var int; v: var string): string =
  ## A quoted string starting at `s[i]`; returns an error or "".
  let q = s[i]
  inc i
  v = ""
  result = "unterminated string"
  while i < s.len:
    let ch = s[i]
    inc i
    if ch == q:
      return ""
    elif ch == '\\' and q == '"' and i < s.len:
      let e = s[i]
      inc i
      case e
      of 'n': v.add '\n'
      of 't': v.add '\t'
      of '"', '\\': v.add e
      else: return "unknown escape \\" & e
    else:
      v.add ch

func parseValue(text: string; v: var Value): string =
  ## The value after `=`; returns an error or "".
  let s = text.strip
  result = ""
  if s.len == 0:
    result = "no value"
  elif s[0] in {'"', '\''}:
    var i = 0
    v = Value(kind: vkString)
    result = parseString(s, i, v.str)
    if result.len == 0 and s[i..^1].strip.len > 0:
      result = "unexpected text after the string"
  elif s[0] == '[':
    v = Value(kind: vkArray)
    var i = 1
    while result.len == 0:
      while i < s.len and s[i] in {' ', '\t', ','}: inc i
      if i >= s.len:
        result = "unterminated array"
      elif s[i] == ']':
        if s[i+1..^1].strip.len > 0:
          result = "unexpected text after the array"
        break
      elif s[i] in {'"', '\''}:
        var item: string
        result = parseString(s, i, item)
        v.items.add item
      else:
        result = "arrays may hold only strings"
  elif s in ["true", "false"]:
    v = Value(kind: vkBool, num: if s == "true": 1 else: 0)
  else:
    v = Value(kind: vkNumber)
    let clean = s.replace("_", "")
    if parseFloat(clean, v.num) != clean.len or clean.len == 0:
      result = "not a value: " & s

func entries(text: string; messages: var seq[string]; where: string): seq[Entry] =
  ## Every `key = value` of `text`, keys prefixed with their table.
  var
    table = ""
    n = 0
  for raw in text.splitLines:
    inc n
    let line = stripComment(raw).strip
    let at = where & ":" & $n & ": "
    if line.len == 0:
      discard
    elif line.startsWith("["):
      if line.endsWith("]") and not line.startsWith("[["):
        table = line[1..^2].strip
      else:
        messages.add at & "bad table header `" & line & "`"
        table = "?"
    else:
      let eq = line.find('=')
      if eq <= 0:
        messages.add at & "expected `key = value`, got `" & line & "`"
      else:
        var key = line[0 ..< eq].strip.strip(chars = {'"', '\''})
        var value: Value
        let err = parseValue(line[eq+1..^1], value)
        if err.len > 0:
          messages.add at & "`" & key & "`: " & err
        else:
          if table.len > 0:
            key = table & "." & key
          result.add Entry(line: n, key: key, value: value)

func terminalAlias(k: BaseColor): string =
  ## The key of Omarchy's terminal form that stands in for `k`, if any.
  case k
  of bcRed: "color1"
  of bcGreen: "color2"
  of bcYellow: "color3"
  of bcBlue: "color4"
  of bcMagenta: "color5"
  of bcCyan: "color6"
  of bcMuted: "color8"
  of bcBrightRed: "color9"
  of bcBrightGreen: "color10"
  of bcBrightYellow: "color11"
  of bcBrightBlue: "color12"
  of bcBrightMagenta: "color13"
  of bcBrightCyan: "color14"
  else: ""

func derived(k: BaseColor; p: Palette; given: array[BaseColor, bool]; mode: ThemeMode;
    ok: var bool): Rgba =
  ## A missing base colour made from the others; `ok` is false when the colours
  ## it needs are missing too.
  let (bg, fg) = (p[bcBackground], p[bcForeground])
  let black = Rgba(a: 255)
  let dark = mode == tmDark
  ok = given[bcBackground] and given[bcForeground]
  case k
  of bcDarkBackground:
    ok = given[bcBackground]
    result = mix(bg, black, if dark: 0.25 else: 0.035)
  of bcDarkerBackground:
    ok = given[bcBackground]
    result = mix(bg, black, if dark: 0.45 else: 0.1)
  of bcLighterBackground: result = mix(bg, fg, 0.06)
  of bcSelection: result = mix(bg, fg, 0.12)
  of bcMuted: result = mix(bg, fg, 0.18)
  of bcDarkForeground: result = mix(bg, fg, 0.22)
  of bcLightForeground: result = mix(fg, bg, 0.25)
  of bcBrightForeground: result = fg
  of bcAccent:
    ok = given[bcBlue]
    result = p[bcBlue]
  of bcOrange:
    ok = given[bcRed] and given[bcYellow]
    result = mix(p[bcRed], p[bcYellow], 0.5)
  of bcBrown:
    ok = ok and given[bcRed] and given[bcYellow]
    result = mix(p[bcOrange], bg, 0.55)
  of bcBrightRed, bcBrightYellow, bcBrightGreen, bcBrightCyan, bcBrightBlue,
      bcBrightMagenta:
    let plain = BaseColor(ord(k) - ord(bcBrightRed) + ord(bcRed))
    ok = given[plain]
    result = p[plain]
  else:
    ok = false

const ignoredKeys = ["cursor", "selection_foreground", "color0", "color7", "color15"]
  ## Omarchy keys for terminals that a viewer has no use for.

func kindProblem(e: Entry; kind: ValueKind): string =
  ## "" when `e` holds a `kind`, else what is wrong.
  if e.value.kind == kind: ""
  else:
    "`" & e.key & "` needs a " &
      (case kind
       of vkString: "string"
       of vkNumber: "number"
       of vkBool: "true or false"
       of vkArray: "list of strings") & ", ignored"

proc check(e: Entry; kind: ValueKind; at: string; messages: var seq[string]): bool =
  let problem = kindProblem(e, kind)
  if problem.len > 0:
    messages.add at & problem
  problem.len == 0

proc colourOf(e: Entry; at: string; messages: var seq[string]; c: var Rgba): bool =
  result = check(e, vkString, at, messages) and parseColor(e.value.str, c)
  if not result and e.value.kind == vkString:
    messages.add at & "`" & e.key & "`: `" & e.value.str & "` is not a colour (#rrggbb)"

proc parseTheme*(text, name: string; messages: var seq[string]; where = name): Theme =
  ## The theme in `text` (the format in the module doc). Problems are appended
  ## to `messages`, prefixed with `where` and the line; the theme is always
  ## complete. `name` is used when the text sets none.
  var
    p: Palette
    given: array[BaseColor, bool]
    mode = tmDark
    modeGiven = false
    terminal: seq[(string, Rgba)]
    roleOverrides: seq[(Role, string, int)]
    seriesOverride: seq[string]
    seriesLine = 0
  result = Theme(name: name, fonts: DefaultFonts, metrics: DefaultMetrics)
  for e in entries(text, messages, where):
    let at = where & ":" & $e.line & ": "
    template expect(kind: ValueKind): bool = check(e, kind, at, messages)
    template colour(c: var Rgba): bool = colourOf(e, at, messages, c)
    var c: Rgba
    let key = e.key
    if key == "name":
      if expect(vkString): result.name = e.value.str
    elif key == "mode":
      if expect(vkString):
        case e.value.str.toLowerAscii
        of "dark": (mode, modeGiven) = (tmDark, true)
        of "light": (mode, modeGiven) = (tmLight, true)
        else: messages.add at & "`mode` is \"dark\" or \"light\", not `" & e.value.str & "`"
    elif key in ignoredKeys:
      discard
    elif key == "selection_background" or (key.startsWith("color") and
        key[5..^1].allCharsInSet(Digits) and key.len in 6..7):
      if colour(c): terminal.add (key, c)
    elif key.startsWith("fonts."):
      let sub = key[6..^1]
      case sub
      of "ui", "mono", "heading":
        if expect(vkString): result.fonts[parseEnum[FontRole](sub)] = e.value.str
      of "icons":
        if expect(vkString): result.iconFont = e.value.str
      of "size", "heading_size":
        if expect(vkNumber):
          if e.value.num < 6 or e.value.num > 72:
            messages.add at & "`" & key & "` must be 6 .. 72 pixels"
          elif sub == "size": result.metrics.fontSize = e.value.num
          else: result.metrics.headingSize = e.value.num
      else: messages.add at & "unknown key `" & key & "`, ignored"
    elif key.startsWith("metrics."):
      let sub = key[8..^1]
      let field = case sub
        of "rounding": addr result.metrics.rounding
        of "frame_rounding": addr result.metrics.frameRounding
        of "border_width": addr result.metrics.borderWidth
        of "window_padding": addr result.metrics.windowPadding
        of "frame_padding_x": addr result.metrics.framePaddingX
        of "frame_padding_y": addr result.metrics.framePaddingY
        of "item_spacing_x": addr result.metrics.itemSpacingX
        of "item_spacing_y": addr result.metrics.itemSpacingY
        of "scrollbar_size": addr result.metrics.scrollbarSize
        else: nil
      if field.isNil:
        messages.add at & "unknown key `" & key & "`, ignored"
      elif expect(vkNumber):
        if e.value.num < 0 or e.value.num > 64:
          messages.add at & "`" & key & "` must be 0 .. 64 pixels"
        else:
          field[] = e.value.num
    elif key == "roles.series":
      if expect(vkArray):
        (seriesOverride, seriesLine) = (e.value.items, e.line)
    elif key.startsWith("roles."):
      let sub = key[6..^1]
      var role = rlBackdrop
      var known = false
      for r in Role:
        if $r == sub: (role, known) = (r, true)
      if not known:
        messages.add at & "unknown role `" & sub & "`, ignored"
      elif expect(vkString):
        roleOverrides.add (role, e.value.str, e.line)
    else:
      var known = false
      for k in BaseColor:
        if $k == key:
          known = true
          if colour(c): (p[k], given[k]) = (c, true)
      if not known:
        messages.add at & "unknown key `" & key & "`, ignored"

  # The mode: stated, else from the background's brightness.
  if not modeGiven and given[bcBackground]:
    mode = if luminance(p[bcBackground]) < 0.18: tmDark else: tmLight
  result.mode = mode
  # Missing base colours: Omarchy's terminal keys, then derived, then built in.
  let builtin = builtinTheme(mode).palette
  for (key, c) in terminal:
    for k in BaseColor:
      if not given[k] and terminalAlias(k) == key:
        (p[k], given[k]) = (c, true)
  for (key, c) in terminal:
    if key == "selection_background" and not given[bcSelection] and
        given[bcBackground] and contrast(c, p[bcBackground]) < 1.6:
      (p[bcSelection], given[bcSelection]) = (c, true) # usable as a background
  var made, fallen: seq[string]
  let fromFile = given # what `derived` may build on
  for k in [bcBackground, bcForeground, bcRed, bcYellow, bcGreen, bcCyan, bcBlue,
      bcMagenta]:
    if not given[k]:
      (p[k], given[k]) = (builtin[k], true)
      fallen.add "`" & $k & "`"
  for k in BaseColor:
    if not given[k]:
      var ok: bool
      let c = derived(k, p, fromFile, mode, ok)
      if ok:
        p[k] = c
        if k notin {bcBrightForeground} + {bcBrightRed .. bcBrightMagenta}:
          made.add "`" & $k & "`" # the bright ones are optional: no message
      else:
        p[k] = builtin[k]
        fallen.add "`" & $k & "`"
  if made.len > 0:
    messages.add where & ": no " & made.join(", ") & ": derived from its other colours"
  if fallen.len > 0:
    messages.add where & ": no " & fallen.join(", ") & ": the built-in " &
      builtinTheme(mode).name & " value is used"
  result.palette = p
  result.roles = deriveRoles(p, mode)
  result.series = deriveSeries(p)
  for (role, value, line) in roleOverrides:
    var c: Rgba
    var found = false
    for k in BaseColor:
      if $k == value: (c, found) = (p[k], true)
    if found or parseColor(value, c):
      result.roles[role] = c
    else:
      messages.add where & ":" & $line & ": role `" & $role & "`: `" & value &
        "` is neither a colour nor a base colour name"
  if seriesOverride.len > 0:
    for i, value in seriesOverride:
      var c: Rgba
      if i >= result.series.len:
        messages.add where & ":" & $seriesLine & ": `series` holds at most " &
          $result.series.len & " colours; the rest are ignored"
        break
      var found = false
      for k in BaseColor:
        if $k == value: (c, found) = (p[k], true)
      if found or parseColor(value, c):
        result.series[i] = c
      else:
        messages.add where & ":" & $seriesLine & ": series colour `" & value &
          "` is not a colour"

func displayName*(fileName: string): string =
  ## `everforest-dark` -> `Everforest Dark`.
  result = ""
  for word in fileName.multiReplace(("-", " "), ("_", " ")).splitWhitespace:
    if result.len > 0: result.add ' '
    result.add word.capitalizeAscii

proc loadTheme*(path: string; mode: ThemeMode; messages: var seq[string]): Theme =
  ## The theme in file `path`. A file that cannot be read gives the built-in
  ## theme for `mode`, with a message.
  let stem = path.splitFile.name
  try:
    result = parseTheme(readFile(path), displayName(stem), messages, path)
  except IOError, OSError:
    messages.add path & ": cannot read the theme (" & getCurrentExceptionMsg() &
      "); using the built-in " & builtinTheme(mode).name
    result = builtinTheme(mode)

func toToml*(t: Theme): string =
  ## `t` as a theme file that `parseTheme` reads back equal: every base
  ## colour, the fonts and metrics, and the roles and series only where they
  ## differ from the derived ones.
  result = "name = \"" & t.name & "\"\nmode = \"" & $t.mode & "\"\n\n"
  for k in BaseColor:
    result.add $k & " = \"" & toHex(t.palette[k]) & "\"\n"
  result.add "\n[fonts]\n"
  for f in FontRole:
    result.add $f & " = \"" & t.fonts[f] & "\"\n"
  if t.iconFont.len > 0:
    result.add "icons = \"" & t.iconFont & "\"\n"
  let m = t.metrics
  result.add "size = " & $m.fontSize & "\nheading_size = " & $m.headingSize & "\n"
  result.add "\n[metrics]\n"
  for (key, v) in [("rounding", m.rounding), ("frame_rounding", m.frameRounding),
      ("border_width", m.borderWidth), ("window_padding", m.windowPadding),
      ("frame_padding_x", m.framePaddingX), ("frame_padding_y", m.framePaddingY),
      ("item_spacing_x", m.itemSpacingX), ("item_spacing_y", m.itemSpacingY),
      ("scrollbar_size", m.scrollbarSize)]:
    result.add key & " = " & $v & "\n"
  let roles = deriveRoles(t.palette, t.mode)
  var extra = ""
  for r in Role:
    if t.roles[r] != roles[r]:
      extra.add $r & " = \"" & toHex(t.roles[r]) & "\"\n"
  if t.series != deriveSeries(t.palette):
    var items: seq[string]
    for c in t.series: items.add "\"" & toHex(c) & "\""
    extra.add "series = [" & items.join(", ") & "]\n"
  if extra.len > 0:
    result.add "\n[roles]\n" & extra

proc themeFiles*(dirs: openArray[string]): seq[ThemeFile] =
  ## The `*.toml` files in `dirs`, sorted by name within each directory; a
  ## name found in an earlier directory hides the same name in later ones.
  result = @[]
  for d in dirs:
    var here: seq[ThemeFile]
    if dirExists(d):
      for kind, path in walkDir(d):
        if kind in {pcFile, pcLinkToFile} and path.endsWith(ThemeExt):
          here.add ThemeFile(name: path.splitFile.name, path: path)
    here.sort(proc (a, b: ThemeFile): int = cmp(a.name, b.name))
    for f in here:
      var seen = false
      for g in result:
        if g.name == f.name: seen = true
      if not seen:
        result.add f
