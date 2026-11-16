## Every theme viewSEG ships (`assets/themes/`): Omarchy's, but Retro 82 and
## Ristretto (their licences do not allow a public release), each with
## its proper name and mode, loading without a message, and each readable and
## usable by the limits below, checked on the colours as drawn:
##
## - text on windows, popups, bars, frames and a selected or hovered item:
##   4.5 (WCAG's AA ratio for text);
## - secondary text, and text in the accent and the status colours (ok,
##   warning, error, info), on the same surfaces: 3; secondary text dimmer
##   than text; disabled items 2 on windows and popups;
## - a selected or hovered item against the window, popup or frame under it:
##   1.08;
## - the plot, on paper and in the theme's colours: the traces, both fills, a
##   hovered and a selected trace 3 against the background (WCAG's ratio for
##   graphics); the hovered and the selected trace 25 (CIE76 deltaE) from
##   the traces, and 30 from each other;
## - the map, on both backgrounds: sources, receivers, the record's receivers,
##   the hovered and the selected points 3 against the background; sources
##   40 from receivers; both 20 from the hovered and the selected points,
##   those 20 from each other; the record's receivers 12 from the others;
##   the marks of the map's filters (a colour for failed traces, amplitude
##   flags, edits and the spread) 3 against the background, 20 from all of
##   those and from each other;
## - every two of those marks told apart without their colours (by their
##   shapes, or else 10 apart as a protanope, deuteranope or tritanope sees
##   them), in the built-in themes too;
## - each file names, in its comment, the roles viewSEG moved to meet them;
## - text 4.5 on a pressed item (`active`) and on selected text in an input
##   (`text_selection`, itself 1.08 off the frame); secondary and status text
##   3 on a selected or hovered item; a checkbox's tick 3 on its checked box;
##   disabled items 2 on every surface;
## - the status colours (ok, warning, error, info) 20 (deltaE) from each
##   other and 15 from the text, where colour alone tells them apart;
## - a frame (an unticked checkbox) 12 (largest channel difference) from the
##   window and the popup;
## - the same of themes a user may drop in: all one colour (grey, black,
##   white; dark and light), and a light theme with a dark bar.
##
## The limits are written here, not taken from `view/theme`, so that lowering
## one there fails here. Seen to fail: with `legible` not called in
## `deriveRoles`, 159 problems ("Catppuccin Latte: ok on window 2.96 < 3.0",
## "Everforest Light: warning on window 2.12 < 3.0" ...); with the map's
## record receivers always moved toward the outline, "Lumon, follow theme:
## the record's receivers from the receivers 1.90 < 12.0"; with `text` added
## by hand to white.toml's list, "white.toml says it moves text, text_dim,
## ..., viewSEG moves ..."; with the user themes as `legible` took them
## before, 49 problems ("one grey dark: frame from window 0.00 < 12.0",
## selection 1.00 against window ...); with bars of the other kind left as
## they are, "light, dark bar: text on bar 1.29 < 4.5"; with the status
## colours as the palettes give them, 28 problems ("Lumon: error from ok
## 3.47 < 20.0", "Solitude: warning from text 5.41 < 15.0" ...); with
## pressed items, rows, ticks and text selections as they were, 105
## ("Last Horizon: warning on selection 1.49 < 3.0", "Everforest Dark: text
## on text_selection 4.17 < 4.5" ...).

import std/[math, os, sequtils, strformat, strutils]
import viewSEG/core/[geometry, mapkinds, panels, survey]
import viewSEG/view/[maplayers, plotink, theme]

const
  assetThemes = currentSourcePath().parentDir.parentDir / "assets" / "themes"
  Shipped = [("catppuccin", "Catppuccin", tmDark),
    ("catppuccin-latte", "Catppuccin Latte", tmLight), ("ethereal", "Ethereal", tmDark),
    ("everforest-dark", "Everforest Dark", tmDark),
    ("everforest-light", "Everforest Light", tmLight),
    ("flexoki-light", "Flexoki Light", tmLight), ("gruvbox", "Gruvbox", tmDark),
    ("hackerman", "Hackerman", tmDark), ("jade-horse", "Jade Horse", tmDark),
    ("kanagawa", "Kanagawa", tmDark), ("last-horizon", "Last Horizon", tmDark),
    ("lumon", "Lumon", tmDark), ("lupine", "Lupine", tmLight),
    ("matte-black", "Matte Black", tmDark), ("miasma", "Miasma", tmDark),
    ("nord", "Nord", tmDark), ("osaka-jade", "Osaka Jade", tmDark),
    ("rose-pine", "Rosé Pine", tmLight), ("solitude", "Solitude", tmDark),
    ("starship", "Starship", tmDark), ("tokyo-night", "Tokyo Night", tmDark),
    ("vantablack", "Vantablack", tmDark), ("white", "White", tmLight)]
  Marker = "# Roles viewSEG moves in this theme"

var problems: seq[string]

proc atLeast(what: string; value, limit: float64) =
  if not (value >= limit):
    problems.add &"{what} {value:.2f} < {limit}"

proc load(file: string): Theme =
  var messages: seq[string]
  result = loadTheme(assetThemes / file & ThemeExt, tmDark, messages)
  doAssert messages.len == 0, file & ": " & $messages

block allShipped:
  # the Omarchy themes that may ship, and Everforest Light, under its own
  # name and mode; those that may not are not there
  var found: seq[string]
  for f in themeFiles([assetThemes]): found.add f.name
  doAssert found == Shipped.mapIt(it[0]), $found
  for gone in ["retro-82", "ristretto"]:
    doAssert gone notin found, gone & " is shipped"
    doAssert gone in readFile(assetThemes / "README.md"), gone & ": the README says nothing"
  for (file, name, mode) in Shipped:
    let t = load(file)
    doAssert t.name == name, file & " is called " & t.name
    doAssert t.mode == mode, file & " is " & $t.mode
    let text = readFile(assetThemes / file & ThemeExt)
    doAssert "mode = \"" & $mode & "\"" in text, file & " does not say its mode"
    doAssert text.startsWith("# viewSEG theme: " & name), file & "'s first line"
    if file notin ["everforest-dark", "everforest-light"]:
      doAssert "Omarchy's " & file & " theme" in text, file & " does not say where it is from"
  doAssert load("everforest-dark") == EverforestDark
  doAssert load("everforest-light") == EverforestLight

proc checkUi(t: Theme) =
  let r = t.roles
  let surfaces = [("window", r[rlWindow]), ("popup", r[rlPopup]), ("bar", r[rlBar]),
    ("frame", r[rlFrame])]
  for (where, bg) in @surfaces & @[("selection", r[rlSelection]), ("hover", r[rlHover])]:
    atLeast(t.name & ": text on " & where, contrast(r[rlText], bg), 4.5)
  for role in [rlTextDim, rlAccent, rlOk, rlWarning, rlError, rlInfo]:
    for (where, bg) in surfaces:
      atLeast(t.name & ": " & $role & " on " & where, contrast(r[role], bg), 3.0)
  atLeast(t.name & ": text over secondary text, on window",
    contrast(r[rlText], r[rlWindow]) - contrast(r[rlTextDim], r[rlWindow]), 0.01)
  for where in [rlWindow, rlPopup, rlBar, rlFrame, rlSelection, rlHover]:
    atLeast(t.name & ": text_disabled on " & $where, contrast(r[rlTextDisabled], r[where]), 2.0)
  # what else is drawn on what: text on a pressed button, secondary and
  # status text on a selected or hovered row, a checkbox's tick on its
  # checked box (the frame a fifth of the way to the accent, as the style
  # draws it), text on its selection in an input
  atLeast(t.name & ": text on active", contrast(r[rlText], r[rlActive]), 4.5)
  for role in [rlTextDim, rlAccent, rlOk, rlWarning, rlError, rlInfo]:
    for where in [rlSelection, rlHover]:
      atLeast(t.name & ": " & $role & " on " & $where, contrast(r[role], r[where]), 3.0)
  atLeast(t.name & ": the tick on a checked box",
    contrast(r[rlAccent], mix(r[rlFrame], r[rlAccent], 0.2)), 3.0)
  atLeast(t.name & ": text on text_selection", contrast(r[rlText], r[rlTextSelection]), 4.5)
  atLeast(t.name & ": text_selection against frame",
    contrast(r[rlTextSelection], r[rlFrame]), 1.08)
  for role in [rlSelection, rlHover]:
    for where in [rlWindow, rlPopup, rlFrame]:
      atLeast(t.name & ": " & $role & " against " & $where, contrast(r[role], r[where]), 1.08)
  let status = [rlOk, rlWarning, rlError, rlInfo]
  for i in 0 ..< status.len: # where colour alone says it: a warning is not an error
    atLeast(t.name & ": " & $status[i] & " from text", deltaE(r[status[i]], r[rlText]), 15)
    for j in 0 ..< i:
      atLeast(t.name & ": " & $status[i] & " from " & $status[j],
        deltaE(r[status[i]], r[status[j]]), 20)
  for where in [rlWindow, rlPopup]: # an unticked checkbox is its frame alone
    atLeast(t.name & ": frame from " & $where, float64(distance(r[rlFrame], r[where])), 12)

proc checkPlot(t: Theme) =
  for colours in [pcPaper, pcTheme]:
    let ink = plotInk(t, DisplaySettings(colours: colours))
    let (w, bg) = (ink.wiggle, ink.background)
    let at = t.name & ", " & $colours & ": "
    for (what, c) in [("traces", w.line), ("positive fill", w.positive),
        ("negative fill", w.negative), ("hovered trace", w.hover),
        ("selected trace", w.selected)]:
      atLeast(at & what & " on the plot", contrast(c, bg), 3.0)
    atLeast(at & "hovered trace from the traces", deltaE(w.hover, w.line), 25)
    atLeast(at & "selected trace from the traces", deltaE(w.selected, w.line), 25)
    atLeast(at & "hovered from selected traces", deltaE(w.hover, w.selected), 30)

proc checkMap(t: Theme) =
  for colours in [pcPaper, pcTheme]:
    let ink = mapInk(t, colours)
    let at = t.name & ", " & $colours & ": "
    let points = [("sources", ink.roles[prSource]), ("receivers", ink.roles[prReceiver]),
      ("hovered points", ink.hover), ("selected points", ink.selected)]
    for (what, c) in @points & @[("the record's receivers", ink.active)]:
      atLeast(at & what & " on the map", contrast(c, ink.background), 3.0)
    for i in 0 ..< points.len:
      for j in 0 ..< i:
        atLeast(at & points[i][0] & " from " & points[j][0], deltaE(points[i][1], points[j][1]),
          if i == 1 and j == 0: 40 else: 20)
    atLeast(at & "the record's receivers from the receivers",
      deltaE(ink.active, ink.roles[prReceiver]), 12)
    # the marks of the map's filters, a colour for each kind of finding (a
    # failed trace, an amplitude flag, an edit, the spread): each 3 against
    # the background, 20 from the points and from each other
    let flags = [("failed traces' marks", filterInk(t, mfDead, ink.background)),
      ("amplitude flags' marks", filterInk(t, mfNoisy, ink.background)),
      ("edits' marks", filterInk(t, mfKilled, ink.background)),
      ("the spread's marks", filterInk(t, mfMissing, ink.background))]
    for i, (what, c) in flags:
      atLeast(at & what & " on the map", contrast(c, ink.background), 3.0)
      for (other, o) in @points & @[("the record's receivers", ink.active)]:
        atLeast(at & what & " from " & other, deltaE(c, o), 20)
      for j in 0 ..< i:
        atLeast(at & what & " from " & flags[j][0], deltaE(c, flags[j][1]), 20)

block readable:
  for (file, _, _) in Shipped:
    let t = load(file)
    checkUi(t)
    checkPlot(t)
    checkMap(t)
  doAssert problems.len == 0, $problems.len & " problems:\n" & problems.join("\n")

# Colour blindness: Machado, Oliveira and Fernandes (2009), severity 1, on
# linear RGB.
type Vision = enum protanopia, deuteranopia, tritanopia
const Machado: array[Vision, array[3, array[3, float64]]] = [
  [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998]],
  [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881]],
  [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602],
    [0.004733, 0.691367, 0.303900]]]

func seen(c: Rgba; v: Vision): Rgba =
  ## `c` as a viewer with vision `v` sees it.
  func linear(u: uint8): float64 =
    let x = float64(u) / 255
    if x <= 0.04045: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)
  func encoded(x: float64): uint8 =
    let y = clamp(x, 0, 1)
    uint8(round(255 * (if y <= 0.0031308: 12.92 * y else: 1.055 * pow(y, 1 / 2.4) - 0.055)))
  let l = [linear(c.r), linear(c.g), linear(c.b)]
  var o: array[3, float64]
  for i in 0 .. 2:
    for j in 0 .. 2: o[i] += Machado[v][i][j] * l[j]
  Rgba(r: encoded(o[0]), g: encoded(o[1]), b: encoded(o[2]), a: c.a)

block marksWithoutColour:
  # Every two filters' marks are told apart by a viewer who cannot tell
  # some colours apart (protanopia, deuteranopia, tritanopia), in every
  # shipped theme and both built-in ones, on both backgrounds: by their
  # shape (the kind's outline and the symbol inside; the kinds' sizes,
  # 4 pixels apart, are not counted), or else by their colours as that
  # viewer sees them, 10 apart (deltaE). The marks' shapes alone tell every
  # two apart. Seen to fail with each filter's shape as it was (a shape a
  # filter, shared across the kinds: dead and clipped both squares): 70
  # problems ("Miasma, paper, protanopia: noisy from spread not the template
  # 1.6 < 10", "Flexoki Light, paper, deuteranopia: all zero from reversed
  # 1.8 < 10" ...).
  const Marked = {MapFilter.low .. MapFilter.high} - {mfAuxiliary, mfNoPosition}
  var shapes: seq[(FlagShape, FlagSymbol)]
  for f in Marked:
    let g = (f.shapeOf, FilterMarks[f].symbol)
    doAssert g notin shapes, $f & " is marked as another filter is: " & $g
    shapes.add g
  var themes = @[builtinTheme(tmDark), builtinTheme(tmLight)]
  for (file, _, _) in Shipped: themes.add load(file)
  var problems: seq[string]
  for t in themes:
    for colours in [pcPaper, pcTheme]:
      let ink = mapInk(t, colours)
      for v in Vision:
        for f in Marked:
          for g in Marked:
            if g > f and (f.shapeOf, FilterMarks[f].symbol) ==
                (g.shapeOf, FilterMarks[g].symbol):
              let d = deltaE(seen(filterInk(t, f, ink.background), v),
                seen(filterInk(t, g, ink.background), v))
              if d < 10:
                problems.add &"{t.name}, {colours}, {v}: {f} from {g} {d:.1f} < 10"
  doAssert problems.len == 0, $problems.len & " problems:\n" & problems.join("\n")

block adjustmentsNoted:
  # each file says which roles viewSEG moves for it, and only those
  for (file, _, _) in Shipped:
    let t = load(file)
    let lines = readFile(assetThemes / file & ThemeExt).splitLines
    var said = "(nothing)"
    for i, line in lines:
      if line.startsWith(Marker) and i + 2 < lines.len:
        said = lines[i + 2].strip(chars = {'#', ' '})
    let moved = adjustedRoles(t.palette, t.mode).mapIt($it)
    doAssert said == (if moved.len == 0: "none" else: moved.join(", ")),
      file & ".toml says it moves " & said & ", viewSEG moves " & $moved

block repairs:
  # A palette that fails is repaired: a light theme's yellow warnings are
  # darkened; a grey palette's marks come from the built-in theme.
  var p = EverforestLight.palette
  p[bcYellow] = rgb(0xffd700)
  let t = makeTheme("yellow", tmLight, p)
  doAssert contrast(t.roles[rlWarning], t.roles[rlWindow]) >= 3.0
  doAssert rlWarning in adjustedRoles(p, tmLight)
  var grey: Palette
  for k in BaseColor: grey[k] = rgb(0x808080)
  (grey[bcBackground], grey[bcForeground]) = (rgb(0x101010), rgb(0xe0e0e0))
  let g = makeTheme("grey", tmDark, grey)
  problems.setLen 0
  checkPlot(g)
  checkMap(g)
  doAssert problems.len == 0, problems.join("\n")
  doAssert g.roles[rlHighlight] != rgb(0x808080)

block userThemes:
  # Themes a user may drop in, which the derivation must still make usable:
  # every colour the same (grey, black, white), and a light theme with a
  # dark bar (the menu bar's text drawn in the one text colour).
  problems.setLen 0
  for (name, c) in [("one grey", 0x808080), ("all black", 0x000000), ("all white", 0xffffff)]:
    var p: Palette
    for k in BaseColor: p[k] = rgb(c.uint32)
    for mode in ThemeMode:
      let t = makeTheme(name & " " & $mode, mode, p)
      checkUi(t)
      checkPlot(t)
      checkMap(t)
  var p = EverforestLight.palette
  p[bcDarkBackground] = rgb(0x202020)
  let bar = makeTheme("light, dark bar", tmLight, p)
  checkUi(bar)
  doAssert problems.len == 0, $problems.len & " problems:\n" & problems.join("\n")
