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
## amplitude to the most positive, entry for entry matplotlib's table.

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
  Viridis: array[256, uint32] = [
    0x440154, 0x440256, 0x450457, 0x450559, 0x46075A, 0x46085C, 0x460A5D, 0x460B5E,
    0x470D60, 0x470E61, 0x471063, 0x471164, 0x471365, 0x481467, 0x481668, 0x481769,
    0x48186A, 0x481A6C, 0x481B6D, 0x481C6E, 0x481D6F, 0x481F70, 0x482071, 0x482173,
    0x482374, 0x482475, 0x482576, 0x482677, 0x482878, 0x482979, 0x472A7A, 0x472C7A,
    0x472D7B, 0x472E7C, 0x472F7D, 0x46307E, 0x46327E, 0x46337F, 0x463480, 0x453581,
    0x453781, 0x453882, 0x443983, 0x443A83, 0x443B84, 0x433D84, 0x433E85, 0x423F85,
    0x424086, 0x424186, 0x414287, 0x414487, 0x404588, 0x404688, 0x3F4788, 0x3F4889,
    0x3E4989, 0x3E4A89, 0x3E4C8A, 0x3D4D8A, 0x3D4E8A, 0x3C4F8A, 0x3C508B, 0x3B518B,
    0x3B528B, 0x3A538B, 0x3A548C, 0x39558C, 0x39568C, 0x38588C, 0x38598C, 0x375A8C,
    0x375B8D, 0x365C8D, 0x365D8D, 0x355E8D, 0x355F8D, 0x34608D, 0x34618D, 0x33628D,
    0x33638D, 0x32648E, 0x32658E, 0x31668E, 0x31678E, 0x31688E, 0x30698E, 0x306A8E,
    0x2F6B8E, 0x2F6C8E, 0x2E6D8E, 0x2E6E8E, 0x2E6F8E, 0x2D708E, 0x2D718E, 0x2C718E,
    0x2C728E, 0x2C738E, 0x2B748E, 0x2B758E, 0x2A768E, 0x2A778E, 0x2A788E, 0x29798E,
    0x297A8E, 0x297B8E, 0x287C8E, 0x287D8E, 0x277E8E, 0x277F8E, 0x27808E, 0x26818E,
    0x26828E, 0x26828E, 0x25838E, 0x25848E, 0x25858E, 0x24868E, 0x24878E, 0x23888E,
    0x23898E, 0x238A8D, 0x228B8D, 0x228C8D, 0x228D8D, 0x218E8D, 0x218F8D, 0x21908D,
    0x21918C, 0x20928C, 0x20928C, 0x20938C, 0x1F948C, 0x1F958B, 0x1F968B, 0x1F978B,
    0x1F988B, 0x1F998A, 0x1F9A8A, 0x1E9B8A, 0x1E9C89, 0x1E9D89, 0x1F9E89, 0x1F9F88,
    0x1FA088, 0x1FA188, 0x1FA187, 0x1FA287, 0x20A386, 0x20A486, 0x21A585, 0x21A685,
    0x22A785, 0x22A884, 0x23A983, 0x24AA83, 0x25AB82, 0x25AC82, 0x26AD81, 0x27AD81,
    0x28AE80, 0x29AF7F, 0x2AB07F, 0x2CB17E, 0x2DB27D, 0x2EB37C, 0x2FB47C, 0x31B57B,
    0x32B67A, 0x34B679, 0x35B779, 0x37B878, 0x38B977, 0x3ABA76, 0x3BBB75, 0x3DBC74,
    0x3FBC73, 0x40BD72, 0x42BE71, 0x44BF70, 0x46C06F, 0x48C16E, 0x4AC16D, 0x4CC26C,
    0x4EC36B, 0x50C46A, 0x52C569, 0x54C568, 0x56C667, 0x58C765, 0x5AC864, 0x5CC863,
    0x5EC962, 0x60CA60, 0x63CB5F, 0x65CB5E, 0x67CC5C, 0x69CD5B, 0x6CCD5A, 0x6ECE58,
    0x70CF57, 0x73D056, 0x75D054, 0x77D153, 0x7AD151, 0x7CD250, 0x7FD34E, 0x81D34D,
    0x84D44B, 0x86D549, 0x89D548, 0x8BD646, 0x8ED645, 0x90D743, 0x93D741, 0x95D840,
    0x98D83E, 0x9BD93C, 0x9DD93B, 0xA0DA39, 0xA2DA37, 0xA5DB36, 0xA8DB34, 0xAADC32,
    0xADDC30, 0xB0DD2F, 0xB2DD2D, 0xB5DE2B, 0xB8DE29, 0xBADE28, 0xBDDF26, 0xC0DF25,
    0xC2DF23, 0xC5E021, 0xC8E020, 0xCAE11F, 0xCDE11D, 0xD0E11C, 0xD2E21B, 0xD5E21A,
    0xD8E219, 0xDAE319, 0xDDE318, 0xDFE318, 0xE2E418, 0xE5E419, 0xE7E419, 0xEAE51A,
    0xECE51B, 0xEFE51C, 0xF1E51D, 0xF4E61E, 0xF6E620, 0xF8E621, 0xFBE723, 0xFDE725]
    ## matplotlib's viridis (`_viridis_data`, by Stéfan van der Walt and
    ## Nathaniel Smith, CC0), each channel times 255, rounded: 0xRRGGBB, the
    ## most negative amplitude first

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

func makeLut(m: ColourMap): Lut =
  case m
  of cmGrey:
    for i in 0 .. 255:
      let g = uint8(255 - i)
      result[i] = Rgba(r: g, g: g, b: g, a: 255)
  of cmRedWhiteBlue: result = diverging(Red, White, Blue)
  of cmViridis:
    for i, c in Viridis:
      result[i] = Rgba(r: uint8(c shr 16), g: uint8((c shr 8) and 0xFF), b: uint8(c and 0xFF),
        a: 255)
  of cmRedBlack: result = diverging(Red, White, Black)

const Luts = block:
  var all: array[ColourMap, Lut]
  for m in ColourMap: all[m] = makeLut(m)
  all

func lutOf*(m: ColourMap): Lut {.inline.} = Luts[m]
  ## The 256 colours of map `m`.
