## `view/theme`: the built-in themes, the theme file format (Omarchy's
## colors.toml plus viewSEG's tables), its fallbacks, and theme discovery.

import std/[os, strutils]
import viewSEG/core/geometry
import viewSEG/view/theme

const assetThemes = currentSourcePath().parentDir.parentDir / "assets" / "themes"

func has(messages: seq[string]; part: string): bool =
  for m in messages:
    if part in m: return true
  false

block builtinsComplete:
  for t in [EverforestDark, EverforestLight]:
    for k in BaseColor:
      doAssert t.palette[k].a == 255, t.name & " " & $k
      doAssert t.palette[k] != Rgba(a: 255), t.name & " " & $k & " is black"
    for r in Role:
      doAssert t.roles[r].a == 255, t.name & " " & $r
    for i in 0 ..< 4: # components get distinct colours
      for j in 0 ..< i:
        doAssert distance(t.series[i], t.series[j]) >= 24, t.name & " series " & $i & "/" & $j
    for f in FontRole:
      doAssert t.fonts[f].endsWith(".ttf")
    doAssert contrast(t.roles[rlText], t.roles[rlWindow]) >= 4.5, t.name
    doAssert contrast(t.roles[rlText], t.roles[rlBar]) >= 4.5, t.name
    doAssert contrast(t.roles[rlTextDim], t.roles[rlWindow]) >= 2.5, t.name
  doAssert EverforestDark.mode == tmDark and EverforestLight.mode == tmLight
  doAssert luminance(EverforestDark.roles[rlWindow]) < 0.1
  doAssert luminance(EverforestLight.roles[rlWindow]) > 0.8
  # The palette recorded from the owner's Omarchy desktop.
  doAssert toHex(EverforestDark.palette[bcBackground]) == "#2d353b"
  doAssert toHex(EverforestDark.palette[bcDarkerBackground]) == "#181d20"
  doAssert toHex(EverforestDark.palette[bcOrange]) == "#e09d7f"
  doAssert toHex(EverforestLight.palette[bcBackground]) == "#fdf6e3"
  doAssert builtinTheme(tmLight) == EverforestLight

block colourHelpers:
  var c: Rgba
  doAssert parseColor("#7fbbb3", c) and c == rgb(0x7fbbb3)
  doAssert parseColor("7FBBB380", c) and c == rgb(0x7fbbb3, 0x80)
  doAssert parseColor("#fff", c) and c == rgb(0xffffff)
  doAssert not parseColor("#12345", c) and c == rgb(0xffffff)
  doAssert not parseColor("blue", c)
  doAssert toHex(rgb(0x7fbbb3, 0x80)) == "#7fbbb380"
  doAssert mix(rgb(0x000000), rgb(0xffffff), 0.5) == rgb(0x808080)
  doAssert abs(contrast(rgb(0), rgb(0xffffff)) - 21) < 0.01

block shippedFilesEqualBuiltins:
  for (file, builtin) in [("everforest-dark", EverforestDark),
      ("everforest-light", EverforestLight)]:
    var messages: seq[string]
    let t = loadTheme(assetThemes / file & ThemeExt, tmDark, messages)
    doAssert messages.len == 0, $messages
    doAssert t == builtin, file & ":\n" & toToml(t)
  doAssert DefaultThemeNames[tmDark] == "everforest-dark"

block roundTrip:
  var t = EverforestDark
  t.name = "Mine"
  t.roles[rlHighlight] = rgb(0x123456, 0x80)
  t.series[2] = rgb(0xabcdef)
  t.fonts[frMono] = "/abs/Other Mono.ttf"
  t.iconFont = "Symbols.ttf"
  t.metrics.rounding = 0
  t.metrics.fontSize = 17.5
  var messages: seq[string]
  let back = parseTheme(toToml(t), "ignored", messages)
  doAssert messages.len == 0, $messages
  doAssert back == t, toToml(back)
  for builtin in [EverforestDark, EverforestLight]:
    doAssert parseTheme(toToml(builtin), "x", messages) == builtin
  doAssert messages.len == 0

block badFileFallsBack:
  const text = """
# a hand-edited theme with mistakes
mode = "dark"
background = "#101820"
foreground = "not a colour"
accent = 12
frobnicate = "#ffffff"
red = "#ff0000" trailing
[fonts]
size = 400
ui = "Custom.ttf"
[metrics]
rounding = "round"
padding = 3
[roles]
highlight = "yellow"
glow = "#ffffff"
error = "purple-ish"
[[array]]
just text
"""
  var messages: seq[string]
  let t = parseTheme(text, "Broken", messages, "broken.toml")
  for part in ["broken.toml:4: `foreground`: `not a colour` is not a colour",
      "broken.toml:5: `accent` needs a string", "broken.toml:6: unknown key `frobnicate`",
      "broken.toml:7: `red`: unexpected text", "broken.toml:9: `fonts.size` must be 6 .. 72",
      "broken.toml:12: `metrics.rounding` needs a number",
      "broken.toml:13: unknown key `metrics.padding`", "broken.toml:16: unknown role `glow`",
      "broken.toml:17: role `error`: `purple-ish`", "broken.toml:18: bad table header",
      "broken.toml:19: expected `key = value`",
      "`foreground`, `red`, `yellow`", "built-in Everforest Dark value"]:
    doAssert messages.has(part), "missing message " & part & " in:\n" & messages.join("\n")
  # Good values are kept, bad ones fall back.
  doAssert t.name == "Broken"
  doAssert t.palette[bcBackground] == rgb(0x101820)
  doAssert t.palette[bcForeground] == EverforestDark.palette[bcForeground]
  doAssert t.palette[bcRed] == EverforestDark.palette[bcRed]
  doAssert t.palette[bcAccent] == EverforestDark.palette[bcBlue] # derived from blue
  doAssert t.roles[rlWindow] == rgb(0x101820)
  doAssert t.roles[rlHighlight] == EverforestDark.palette[bcYellow]
  doAssert t.roles[rlError] == t.palette[bcRed]
  doAssert t.fonts[frUi] == "Custom.ttf" and t.fonts[frMono] == DefaultFonts[frMono]
  doAssert t.metrics == DefaultMetrics
  # Backgrounds missing from the file are derived from its own background.
  doAssert t.palette[bcDarkBackground] != EverforestDark.palette[bcDarkBackground]
  doAssert luminance(t.palette[bcDarkerBackground]) < luminance(t.palette[bcBackground])

block emptyFileIsTheBuiltin:
  var messages: seq[string]
  let t = parseTheme("", "Empty", messages)
  doAssert t.palette == EverforestDark.palette and t.roles == EverforestDark.roles
  doAssert messages.len == 1 and messages.has("`background`, `foreground`"), $messages

block missingFile:
  var messages: seq[string]
  let t = loadTheme(getTempDir() / "no-such-theme.toml", tmLight, messages)
  doAssert t == EverforestLight
  doAssert messages.len == 1 and messages.has("cannot read the theme"), $messages

block omarchyTerminalForm:
  # The form of Omarchy's own themes (here catppuccin-latte): no `mode`, ANSI
  # colours. It must load without complaint about any key it has.
  const latte = """
accent = "#1e66f5"
cursor = "#dc8a78"
foreground = "#4c4f69"
background = "#eff1f5"
selection_foreground = "#eff1f5"
selection_background = "#dc8a78"

color0 = "#bcc0cc"
color1 = "#d20f39"
color2 = "#40a02b"
color3 = "#df8e1d"
color4 = "#1e66f5"
color5 = "#ea76cb"
color6 = "#179299"
color7 = "#5c5f77"
color8 = "#acb0be"
color9 = "#d20f39"
color10 = "#40a02b"
color11 = "#df8e1d"
color12 = "#1e66f5"
color13 = "#ea76cb"
color14 = "#179299"
color15 = "#6c6f85"
"""
  var messages: seq[string]
  let t = parseTheme(latte, "Catppuccin Latte", messages)
  doAssert t.mode == tmLight
  doAssert t.palette[bcRed] == rgb(0xd20f39) and t.palette[bcCyan] == rgb(0x179299)
  doAssert t.palette[bcMuted] == rgb(0xacb0be)
  doAssert t.palette[bcBrightBlue] == rgb(0x1e66f5)
  doAssert t.roles[rlAccent] == rgb(0x1e66f5) and t.roles[rlWindow] == rgb(0xeff1f5)
  # selection_background is a text highlight here (too strong for a background)
  doAssert t.palette[bcSelection] != rgb(0xdc8a78)
  doAssert contrast(t.roles[rlText], t.roles[rlBar]) >= 4.5
  # One line says what was derived; nothing is unknown or invalid.
  doAssert messages.len == 1 and "derived from its other colours" in messages[0],
    $messages
  doAssert "orange" in messages[0] and "dark_background" in messages[0]

block themeDiscovery:
  let root = getTempDir() / ("viewseg_ttheme_" & $getCurrentProcessId())
  let (user, shipped) = (root / "user", root / "shipped")
  createDir(user)
  createDir(shipped)
  try:
    writeFile(shipped / "everforest-dark.toml", "")
    writeFile(shipped / "b.toml", "")
    writeFile(shipped / "notes.txt", "")
    writeFile(user / "everforest-dark.toml", "")
    writeFile(user / "a-mine.toml", "")
    let found = themeFiles([user, shipped, root / "missing"])
    var names: seq[string]
    for f in found: names.add f.name
    doAssert names == @["a-mine", "everforest-dark", "b"], $names
    doAssert found[1].path == user / "everforest-dark.toml" # the user's copy wins
    doAssert themeFiles([assetThemes]).len >= 2
  finally:
    removeDir(root)
  doAssert displayName("everforest-dark") == "Everforest Dark"
  doAssert displayName("my_theme 2") == "My Theme 2"
