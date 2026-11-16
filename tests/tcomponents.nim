## Which components a record has, whether it is multi-component, and which
## traces a component filter keeps (`core/components`), with no window.
##
## The ocean-bottom sample's codes are sensor types 1..4 (hydrophone,
## vertical, inline, crossline). A record of one component, or of none,
## is not multi-component. The filter empty shows every trace; turning one
## off drops its traces and the last one on stays on.
##
## Seen to fail: with `multiComponent` true for a single code, a one-component
## record was multi; with `toggled` dropping the last code, the filter became
## empty and no trace remained; with `keptIndices` ignoring the filter, turning
## hydrophone off still kept every trace.
##
## The default colours are checked against white paper and every theme's plot
## background (the wiggle background when the plot follows the theme).

import std/[os, strutils]
import viewSEG/core/[components, geometry]
import viewSEG/view/theme

block names:
  doAssert kindOf(1) == ckHydrophone and kindOf(11) == ckHydrophone
  doAssert kindOf(2) == ckVertical and kindOf(12) == ckVertical and kindOf(15) == ckVertical
  doAssert kindOf(3) == ckInline and kindOf(14) == ckInline and kindOf(17) == ckInline
  doAssert kindOf(4) == ckCrossline and kindOf(13) == ckCrossline and kindOf(16) == ckCrossline
  doAssert kindOf(0) == ckOther and kindOf(6) == ckOther and kindOf(27) == ckOther
  doAssert letterOf(1) == "H" and letterOf(2) == "Z" and letterOf(3) == "X" and
    letterOf(4) == "Y"
  doAssert letterOf(9) == "9"
  doAssert nameOf(1) == "hydrophone" and nameOf(7) == "component 7"
  doAssert colourSlot(1) == 1 and colourSlot(2) == 2 and colourSlot(3) == 3 and
    colourSlot(4) == 4 and colourSlot(9) == 0
  doAssert componentMark(2) == uint8(2 shl ComponentShift)

block present:
  let obn = tally(@[1'u8, 2, 3, 4, 1, 2, 3, 4])
  doAssert obn.len == 4, $obn
  doAssert obn[0].code == 1 and obn[0].count == 2
  doAssert obn[1].code == 2 and obn[2].code == 3 and obn[3].code == 4
  # others follow the named ones, by code
  let mixed = tally(@[6'u8, 1, 9, 2, 6])
  doAssert mixed.len == 4 and mixed[0].code == 1 and mixed[1].code == 2 and
    mixed[2].code == 6 and mixed[2].count == 2 and mixed[3].code == 9, $mixed
  doAssert tally(@[0'u8, 0, 0]).len == 0
  doAssert not multiComponent(@[0'u8, 0])
  doAssert not multiComponent(@[1'u8, 1, 1, 0])
  doAssert multiComponent(@[1'u8, 2, 3, 4])
  doAssert multiComponent(@[11'u8, 12, 13, 14])
  doAssert not multiComponent(@[11'u8, 11])

block filter:
  let codes = @[1'u8, 2, 3, 4, 1, 2, 3, 4, 0]
  doAssert keptIndices(codes, {}) == @[0, 1, 2, 3, 4, 5, 6, 7, 8]
  let hydroOff = toggled(@[1'u8, 2, 3, 4], {}, 1)
  doAssert 1 notin hydroOff and 2 in hydroOff and 3 in hydroOff and 4 in hydroOff, $hydroOff
  doAssert keptIndices(codes, hydroOff) == @[1, 2, 3, 5, 6, 7, 8], $keptIndices(codes, hydroOff)
  # a quarter of the named traces gone; the unlabelled trace stays
  doAssert keptIndices(@[1'u8, 2, 3, 4, 1, 2, 3, 4], hydroOff).len == 6
  var on = hydroOff
  on = toggled(@[1'u8, 2, 3, 4], on, 2)
  on = toggled(@[1'u8, 2, 3, 4], on, 3)
  doAssert on == {4'u8}, $on
  doAssert toggled(@[1'u8, 2, 3, 4], on, 4) == on # the last one stays
  doAssert keptIndices(codes, on) == @[3, 7, 8]
  doAssert not keepsOne(@[1'u8, 2, 3, 4], {9'u8})
  doAssert keepsOne(@[1'u8, 2, 3, 4], on)
  doAssert keepsOne(@[1'u8, 2, 3, 4], {})
  # turning the last off one back on, with the others, is all on again
  doAssert toggled(@[1'u8, 2, 3, 4], {2'u8, 3, 4}, 1) == {}
  doAssert componentShown({}, 1) and not componentShown(hydroOff, 1) and
    componentShown(hydroOff, 2)
  doAssert passesComponent(0, hydroOff) and not passesComponent(1, hydroOff)

block colours_on_paper_and_themes:
  let paper = Rgba(r: 255, g: 255, b: 255, a: 255)
  let nearBlack = Rgba(r: 9, g: 9, b: 9, a: 255)
  let nearWhite = Rgba(r: 0xF5, g: 0xF5, b: 0xF5, a: 255)
  for i, c in DefaultComponentColours:
    doAssert contrast(c, paper) >= 3.0, "default " & $i & " on white: " & $contrast(c, paper)
    doAssert contrast(c, nearBlack) >= 3.0, "default " & $i & " on black: " &
      $contrast(c, nearBlack)
    doAssert contrast(c, nearWhite) >= 3.0, "default " & $i & " on near-white: " &
      $contrast(c, nearWhite)
  let root = currentSourcePath().parentDir.parentDir
  let dir = root / "assets" / "themes"
  var themes = 0
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".toml"):
      var messages: seq[string] = @[]
      let t = loadTheme(path, tmDark, messages)
      let bg = Rgba(r: t.roles[rlPlotBackground].r, g: t.roles[rlPlotBackground].g,
        b: t.roles[rlPlotBackground].b, a: 255)
      inc themes
      for i, c in DefaultComponentColours:
        let drawn = readable(c, bg, 3.0)
        doAssert contrast(drawn, bg) >= 3.0 or contrast(Black, bg) < 3.0 or
          contrast(White, bg) < 3.0,
          path.extractFilename & " " & $i & ": " & $contrast(drawn, bg)
        # the stored shade itself, where the plot is not a mid grey the hue cannot clear
        if contrast(c, bg) < 3.0 and (contrast(Black, bg) >= 3.0 and contrast(White, bg) >= 3.0):
          doAssert false, path.extractFilename & " plot needs a different shade for colour " &
            $i & " (contrast " & $contrast(c, bg) & ")"
  doAssert themes > 10, "themes loaded: " & $themes
