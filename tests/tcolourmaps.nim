## The density colour maps (`core/colourmaps`), on the CPU: what the GPU's
## lookup texture holds and what the pixel tests compare it with.
##
## - grey is the map density always had: positive black, negative white,
##   zero mid grey;
## - the two diverging maps are white at zero (`lutIndex(0)`), their pure
##   colours at the ends (red for the most negative amplitude; blue, or
##   black, for the most positive), and run straight between;
## - viridis is matplotlib's table, entry for entry (checked at 17 of its
##   256 entries), and its lightness rises from one end to the other (no
##   band reads as another);
## - an amplitude drawn full black in grey (the reference, at the display
##   gain) is the positive end of every map, its negative the other end.
##
## Seen to fail: with viridis the polynomial fit it was before (up to 4 of
## 255 off the table), "viridis at 0: 3 off #440154"; with the zero entry at 127
## (`ZeroEntry`), `grey` found another grey there than the zero amplitude
## is drawn with.

import std/strutils
import viewSEG/core/[colourmaps, geometry, tiles]

func luma(c: Rgba): float64 = 0.2126 * float64(c.r) + 0.7152 * float64(c.g) + 0.0722 * float64(c.b)

func hex(s: string): Rgba =
  Rgba(r: uint8(parseHexInt(s[0..1])), g: uint8(parseHexInt(s[2..3])),
    b: uint8(parseHexInt(s[4..5])), a: 255)

func gap(a, b: Rgba): int =
  max([abs(int(a.r) - int(b.r)), abs(int(a.g) - int(b.g)), abs(int(a.b) - int(b.b))])

const White = Rgba(r: 255, g: 255, b: 255, a: 255)

block grey:
  let l = lutOf(cmGrey)
  doAssert l == greyLut()
  doAssert l[0] == White and l[255] == Rgba(a: 255)
  doAssert l[ZeroEntry] == Rgba(r: 127, g: 127, b: 127, a: 255)
  for i in 0 .. 255: doAssert l[i].r == uint8(255 - i) and l[i].r == l[i].g and l[i].g == l[i].b

block diverging:
  doAssert lutIndex(0) == ZeroEntry
  for (m, negative, positive) in [(cmRedWhiteBlue, Rgba(r: 255, a: 255), Rgba(b: 255, a: 255)),
      (cmRedBlack, Rgba(r: 255, a: 255), Rgba(a: 255))]:
    let l = lutOf(m)
    doAssert l[ZeroEntry] == White, $m & ": zero is not white: " & $l[ZeroEntry]
    doAssert l[0] == negative and l[255] == positive, $m & ": the ends " & $l[0] & ", " & $l[255]
    # straight lines from white: each entry the share of the way it lies
    for i in 0 .. 255:
      let (target, t) = if i >= ZeroEntry: (positive, (i - ZeroEntry) / 127)
                        else: (negative, (ZeroEntry - i) / ZeroEntry)
      let want = Rgba(r: uint8(255 - (255 - int(target.r)).float64 * t + 0.5),
        g: uint8(255 - (255 - int(target.g)).float64 * t + 0.5),
        b: uint8(255 - (255 - int(target.b)).float64 * t + 0.5), a: 255)
      doAssert gap(l[i], want) <= 1 and l[i].a == 255, $m & " at " & $i & ": " & $l[i]

block viridis:
  # matplotlib's table (`_viridis_data`, 256 entries) at every 16th entry
  # and the last, each channel times 255, rounded: the map is the table,
  # not a fit of it
  const knots = [(0, "440154"), (16, "48186A"), (32, "472D7B"), (48, "424086"),
    (64, "3B528B"), (80, "33638D"), (96, "2C728E"), (112, "26828E"), (128, "21918C"),
    (144, "1FA088"), (160, "28AE80"), (176, "3FBC73"), (192, "5EC962"), (208, "84D44B"),
    (224, "ADDC30"), (240, "D8E219"), (255, "FDE725")]
  let l = lutOf(cmViridis)
  for (i, h) in knots:
    doAssert gap(l[i], hex(h)) == 0 and l[i].a == 255,
      "viridis at " & $i & ": " & $gap(l[i], hex(h)) & " off #" & h
  for i in 1 .. 255:
    doAssert luma(l[i]) >= luma(l[i - 1]) - 0.5, "viridis darkens at " & $i

block everyMapAtTheReference:
  # the reference amplitude, at the display gain, is drawn as the map's
  # positive end; its negative as the other end; zero as the middle
  let scale = displayScale(2.5)
  for m in ColourMap:
    let l = lutOf(m)
    doAssert l.densityColour(2.5, scale) == l[255] and l.densityColour(-2.5, scale) == l[0]
    doAssert l.densityColour(9, scale) == l[255], "past the reference: clipped"
    doAssert l.densityColour(0, scale) == l[ZeroEntry]
    doAssert $m in ["grey", "red-white-blue", "viridis", "red-black"]

echo "tcolourmaps: ok"
