## Density colour maps: the colours a density plot draws its amplitudes in.
##
## A map is a `Lut` of 256 colours, from the most negative amplitude (entry
## 0) through zero (entry 128, `lutIndex` of 0) to the most positive (entry
## 255). The GPU takes it as a 1-D lookup texture (`gpu/plotimage`), and
## `core/tiles`' `densityColour` looks it up the same way on the CPU, which
## is what the pixel tests compare the GPU with.
##
## | Map | Negative | Zero | Positive |
## |---|---|---|---|
## | Grey (the default) | white | mid grey | black |
## | Red-white-blue | red | white | blue |
## | Viridis | dark purple | teal | yellow |
## | Red-black | red | white | black |
##
## The two diverging maps run in a straight line in RGB from white at zero
## to their colour at each end, so a zero sample is white and the strongest
## amplitudes (those the gain draws full black in the grey map) are the
## pure colours. Viridis (matplotlib's, perceptually uniform, readable in
## grey and by most colour-blind viewers) runs from the most negative
## amplitude to the most positive; it is the polynomial fit of the map
## commonly used in shaders, within 4 of 255 of matplotlib's table.

import std/math
import geometry

type
  ColourMap* = enum
    ## A density plot's colour map.
    cmGrey = "grey"                   ## positive black, negative white, zero mid grey
    cmRedWhiteBlue = "red-white-blue" ## negative red, zero white, positive blue
    cmViridis = "viridis"             ## dark purple (negative) to yellow (positive)
    cmRedBlack = "red-black"          ## negative red, zero white, positive black

  Lut* = array[256, Rgba]
    ## A colour map: index 0 for the most negative amplitude, 255 for the
    ## most positive.

const
  ZeroEntry* = 128 ## the entry a zero amplitude is drawn with (`lutIndex(0)`)
  White = Rgba(r: 255, g: 255, b: 255, a: 255)
  Red = Rgba(r: 255, g: 0, b: 0, a: 255)
  Blue = Rgba(r: 0, g: 0, b: 255, a: 255)
  Black = Rgba(r: 0, g: 0, b: 0, a: 255)
  Viridis = [
    [0.2777273272234177, 0.005407344544966578, 0.3340998053353061],
    [0.1050930431085774, 1.404613529898575, 1.384590162594685],
    [-0.3308618287255563, 0.214847559468213, 0.09509516302823659],
    [-4.634230498983486, -5.799100973351585, -19.33244095627987],
    [6.228269936347081, 14.17993336680509, 56.69055260068105],
    [4.776384997670288, -13.74514537774601, -65.35303263337234],
    [-5.435455855934631, 4.645852612178535, 26.3124352495832]]
    ## the polynomial in t (0 to 1) of each channel, lowest power first

func channel(x: float64): uint8 {.inline.} = uint8(round(clamp(x, 0.0, 1.0) * 255))

func mix(a, b: Rgba; t: float64): Rgba =
  ## `a` moved `t` (0 to 1) of the way to `b`, in RGB.
  func ch(x, y: uint8): uint8 = uint8(round(float64(x) + (float64(y) - float64(x)) * t))
  Rgba(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b), a: 255)

func diverging(negative, zero, positive: Rgba): Lut =
  ## `zero` at `ZeroEntry`, `negative` at entry 0 and `positive` at 255,
  ## straight lines between.
  for i in 0 .. 255:
    result[i] = if i >= ZeroEntry: mix(zero, positive, float64(i - ZeroEntry) / 127)
                else: mix(zero, negative, float64(ZeroEntry - i) / ZeroEntry)

func viridisAt*(t: float64): Rgba =
  ## Viridis at `t`, 0 (dark purple) to 1 (yellow).
  var c: array[3, float64]
  for ch in 0 .. 2:
    for k in countdown(Viridis.high, 0): c[ch] = c[ch] * t + Viridis[k][ch]
  Rgba(r: channel(c[0]), g: channel(c[1]), b: channel(c[2]), a: 255)

func makeLut(m: ColourMap): Lut =
  case m
  of cmGrey:
    for i in 0 .. 255:
      let g = uint8(255 - i)
      result[i] = Rgba(r: g, g: g, b: g, a: 255)
  of cmRedWhiteBlue: result = diverging(Red, White, Blue)
  of cmViridis:
    for i in 0 .. 255: result[i] = viridisAt(float64(i) / 255)
  of cmRedBlack: result = diverging(Red, White, Black)

const Luts = block:
  var all: array[ColourMap, Lut]
  for m in ColourMap: all[m] = makeLut(m)
  all

func lutOf*(m: ColourMap): Lut {.inline.} = Luts[m]
  ## The 256 colours of map `m`.
