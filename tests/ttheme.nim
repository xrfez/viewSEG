## `view/theme`: the built-in themes, the theme file format (Omarchy's
## colors.toml plus viewSEG's tables), its fallbacks, and theme discovery.
##
## Hostile theme files (`hostileFiles`): one over `MaxThemeBytes` (a real
## one is about 2 KB) is not read, with one message; one full of mistakes
## says at most `MaxThemeMessages` of them and how many more; a FIFO named
## `*.toml` is not opened (it would wait for a writer for ever); and
## `themeFiles` keeps each file's messages for when it is chosen. Seen to
## fail: with the size not checked, the 70 KiB file was parsed ("t ==
## EverforestDark" failed); with the messages not capped, "302 messages";
## with the FIFO opened, the test hung until killed. A user's theme named as
## a shipped one is listed under a title of its own (seen to fail with the
## titles left the themes' names: "Everforest Dark" twice).

import std/[os, strutils, times]
import viewSEG/core/geometry
import viewSEG/view/theme
when defined(posix):
  import std/posix

const assetThemes = currentSourcePath().parentDir.parentDir / "assets" / "themes"

func has(messages: seq[string]; part: string): bool =
  for m in messages:
    if part in m: return true
  false

proc main*() =

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

  block framesShow:
    # an unticked checkbox or radio button, an empty box, is its frame alone:
    # in every theme the program ships it stands out from windows and popups
    # (seen to fail with the frame `lighter_background` as it was: Everforest
    # Dark's is its popup's colour, distance 0)
    var shipped = @[EverforestDark, EverforestLight]
    for f in walkFiles(assetThemes / "*.toml"):
      var messages: seq[string]
      let mode = if "light" in f.extractFilename: tmLight else: tmDark
      shipped.add loadTheme(f, mode, messages)
      doAssert messages.len == 0, f & ": " & $messages
    for t in shipped:
      doAssert distance(t.roles[rlFrame], t.roles[rlPopup]) >= MinFrameStep and
        distance(t.roles[rlFrame], t.roles[rlWindow]) >= MinFrameStep,
        t.name & ": frame " & toHex(t.roles[rlFrame]) & ", popup " & toHex(t.roles[rlPopup]) &
        ", window " & toHex(t.roles[rlWindow])

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

  block notANumberIsOutOfRange:
    # `nan` parses as a number but fails every comparison: it must not slip
    # through the range checks into the metrics.
    var messages: seq[string]
    let t = parseTheme("[fonts]\nsize = nan\nheading_size = -NaN\n[metrics]\nrounding = nan\n",
      "NaN", messages, "nan.toml")
    doAssert t.metrics == DefaultMetrics, $t.metrics
    for part in ["nan.toml:2: `fonts.size` must be 6 .. 72",
        "nan.toml:3: `fonts.heading_size` must be 6 .. 72",
        "nan.toml:5: `metrics.rounding` must be 0 .. 64"]:
      doAssert messages.has(part), "missing message " & part & " in:\n" & messages.join("\n")

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

  block hostileFiles:
    let dir = getTempDir() / ("viewseg_hostile_" & $getCurrentProcessId())
    createDir(dir)
    try:
      var big = ""
      while big.len <= MaxThemeBytes: big.add "x = 1\n"
      writeFile(dir / "big.toml", big)
      var messages: seq[string]
      let started = epochTime()
      let t = loadTheme(dir / "big.toml", tmDark, messages)
      doAssert t == EverforestDark
      doAssert messages.len == 1 and messages.has("too large"), $messages.len & " messages"
      doAssert epochTime() - started < 1
      var bad = ""
      for i in 0 ..< 300: bad.add "key" & $i & " = 1\n"
      writeFile(dir / "bad.toml", bad)
      messages.setLen 0
      discard loadTheme(dir / "bad.toml", tmDark, messages)
      doAssert messages.len == MaxThemeMessages + 1, $messages.len & " messages"
      doAssert messages[^1].contains("more"), messages[^1]
      when defined(posix):
        doAssert mkfifo(cstring(dir / "fifo.toml"), 0o600) == 0
        messages.setLen 0
        discard loadTheme(dir / "fifo.toml", tmDark, messages)
        doAssert messages.len == 1 and messages.has("not a file"), $messages
      let found = themeFiles([dir])
      for f in found:
        if f.name == "bad": doAssert f.problems.len == MaxThemeMessages + 1
        if f.name == "big": doAssert f.problems.len == 1 and f.theme.name == "Big", f.theme.name
    finally:
      removeDir(dir)

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
    # A user's theme named as a shipped one is listed under a name of its own.
    createDir(user)
    try:
      writeFile(user / "my-forest.toml", "name = \"Everforest Dark\"\nbackground = \"#203020\"\n")
      var titles: seq[string]
      for f in themeFiles([user, assetThemes]):
        if f.name in ["my-forest", "everforest-dark"]: titles.add f.title
      doAssert titles.len == 2 and titles[0] != titles[1], $titles
      doAssert "Everforest Dark (everforest-dark)" in titles or
        "Everforest Dark (my-forest)" in titles, $titles
    finally:
      removeDir(root)
    doAssert displayName("everforest-dark") == "Everforest Dark"
    doAssert displayName("my_theme 2") == "My Theme 2"

  block parsingLeavesNothingBehind:
    # Parsing a theme file frees all it allocates. Seen to fail: with
    # `stripComment` setting `result` to the line and then returning the line
    # cut at its `#` (Nim 2.4.2 then never frees the first value), 900 parses
    # of a file of commented lines left 9 000 strings allocated.
    proc live(): int =
      let s = cast[tuple[allocs, deallocs: int]](getAllocStats())
      s.allocs - s.deallocs
    var text = ""
    for i in 0 ..< 10:
      text.add "accent = \"#7fbbb3\" # a comment on line " & $i & ", long enough for the heap\n"
    var messages: seq[string]
    discard parseTheme(text, "commented", messages) # whatever is made once and kept
    let before = live()
    for i in 0 ..< 900:
      messages.setLen 0
      discard parseTheme(text, "commented", messages)
    doAssert live() - before < 100, $(live() - before) & " allocations left"

when isMainModule:
  main()
