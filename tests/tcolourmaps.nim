## The density colour maps (`core/colourmaps`), on the CPU: what the GPU's
## lookup texture holds and what the pixel tests compare it with.
##
## - grey is the map density always had: positive black, negative white,
##   zero mid grey;
## - the two diverging maps are white at zero (`lutIndex(0)`), their pure
##   colours at the ends (red for the most negative amplitude; blue, or
##   black, for the most positive), and run straight between;
## - viridis is within 4 of 255 of matplotlib's map at nine points, and its
##   lightness rises from one end to the other (no band reads as another);
## - an amplitude drawn full black in grey (the reference, at the display
##   gain) is the positive end of every map, its negative the other end.
##
## Seen to fail: with viridis's map made from 1 down to 0, `l[0] ==
## viridisAt(0)`; with the zero entry at 127 (`ZeroEntry`), `grey` found
## another grey there than the zero amplitude is drawn with.

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
  # R's viridis(9), matplotlib's map at 0, 1/8, ..., 1
  const knots = ["440154", "472D7B", "3B528B", "2C728E", "21908C", "27AD81", "5DC863", "AADC32",
    "FDE725"]
  let l = lutOf(cmViridis)
  for k, h in knots:
    let at = viridisAt(k / 8)
    doAssert gap(at, hex(h)) <= 4, "viridis at " & $k & "/8: " & $gap(at, hex(h)) & " off #" & h
  doAssert l[0] == viridisAt(0) and l[255] == viridisAt(1)
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
