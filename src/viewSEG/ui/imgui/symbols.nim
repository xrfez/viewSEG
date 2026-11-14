## Seismic symbols that no icon font has, drawn as vector shapes with the
## window's draw list, so they are crisp at any size and take any theme colour:
## the display modes (wiggle, positive fill, negative fill, greyscale density,
## wiggle over density),
## the gather domains (shot, receiver), the map markers (source, receiver)
## and the cursor's time line.
##
## Traces run downwards (time increases down the screen), as in the trace
## panel. The density symbol is drawn in neutral greys whatever the theme, like
## the density display itself.

import std/math
import imguin/cimgui
import ../../core/geometry
import ../../view/theme
import style

type
  Symbol* = enum
    syWiggle = "Wiggle"
    syWigglePositive = "Positive fill"
    syWiggleNegative = "Negative fill"
    syDensity = "Greyscale density"
    syWiggleDensity = "Wiggle over density"
    syShotGather = "Shot gather"
    syReceiverGather = "Receiver gather"
    sySource = "Source"
    syReceiver = "Receiver"
    syCursorTime = "Cursor time line"

  SymbolColours* = object
    line*: Rgba ## strokes and markers
    fill*: Rgba ## wiggle fills

const wiggleSteps = 40

func wavelet*(u: float32): float32 =
  ## The symbols' trace: two cycles under a half-sine envelope, zero at both
  ## ends (u in 0..1), starting with a positive lobe.
  sin(2 * PI * 2 * u) * sin(PI * u)

func p(x, y: float32): ImVec2_c = ImVec2_c(x: x, y: y)

proc wiggle(dl: ptr ImDrawList; x0, y0, s, cx: float32; c: SymbolColours;
    fillSign: int; thick: float32) =
  ## One trace with its baseline at `cx` (a fraction of the box `s`), filled
  ## on the side `fillSign` (+1, -1, or 0 for none).
  let amp = 0.19'f32
  var pts: array[wiggleSteps + 1, ImVec2_c]
  for i in 0 .. wiggleSteps:
    let u = i.float32 / wiggleSteps
    pts[i] = p(x0 + s * (cx + amp * wavelet(u)), y0 + s * (0.1 + 0.8 * u))
  if fillSign != 0:
    let base = x0 + s * cx
    let col = u32(c.fill)
    for i in 0 ..< wiggleSteps:
      # one trapezoid per step between the baseline and the clipped trace
      let (a, b) = (pts[i], pts[i + 1])
      let (xa, xb) = if fillSign > 0: (max(a.x, base), max(b.x, base))
                     else: (min(a.x, base), min(b.x, base))
      if xa != base or xb != base:
        var quad = [p(base, a.y), p(xa, a.y), p(xb, b.y), p(base, b.y)]
        ImDrawList_AddConvexPolyFilled(dl, addr quad[0], 4, col)
  ImDrawList_AddPolyline(dl, addr pts[0], pts.len.cint, u32(c.line), thick, 0)

proc hyperbola(dl: ptr ImDrawList; x0, y0, s, apex: float32; col: ImU32; thick: float32) =
  ## A moveout curve with its apex at height `apex` in the middle of the box.
  var pts: array[17, ImVec2_c]
  for i in 0 .. 16:
    let x = 0.1'f32 + 0.8 * i.float32 / 16
    let y = apex + 1.3 * (sqrt(0.03 + (x - 0.5) * (x - 0.5)) - sqrt(0.03'f32))
    pts[i] = p(x0 + s * x, y0 + s * y)
  ImDrawList_AddPolyline(dl, addr pts[0], pts.len.cint, col, thick, 0)

proc star(dl: ptr ImDrawList; cx, cy, r: float32; col: ImU32) =
  var pts: array[10, ImVec2_c]
  for i in 0 ..< 10:
    let a = -PI / 2 + i.float * PI / 5
    let rr = if i mod 2 == 0: r else: r * 0.45
    pts[i] = p(cx + rr * cos(a).float32, cy + rr * sin(a).float32)
  ImDrawList_AddConcavePolyFilled(dl, addr pts[0], pts.len.cint, col)

proc triangleDown(dl: ptr ImDrawList; cx, cy, r: float32; col: ImU32) =
  ImDrawList_AddTriangleFilled(dl, p(cx - r, cy - 0.6 * r), p(cx + r, cy - 0.6 * r),
    p(cx, cy + r), col)

proc drawSymbol*(dl: ptr ImDrawList; sym: Symbol; topLeft: ImVec2_c; size: float32;
    c: SymbolColours) =
  ## Draws `sym` in the square of side `size` at `topLeft` (pixels).
  let (x0, y0, s) = (topLeft.x, topLeft.y, size)
  let thick = max(1'f32, s / 14)
  let line = u32(c.line)
  case sym
  of syWiggle, syWigglePositive, syWiggleNegative:
    let sign = case sym
      of syWigglePositive: 1
      of syWiggleNegative: -1
      else: 0
    for cx in [0.3'f32, 0.7]:
      wiggle(dl, x0, y0, s, cx, c, sign, thick)
  of syDensity, syWiggleDensity:
    # a small greyscale section: the wavelet in each column, dipping to the
    # right, framed; with a wiggle over its middle
    const (cols, rows) = (5, 12)
    let (left, top, w, h) = (x0 + s * 0.1, y0 + s * 0.1, s * 0.8, s * 0.8)
    for c in 0 ..< cols:
      for r in 0 ..< rows:
        let u = clamp((r.float32 + 0.5) / rows.float32 - 0.07 * c.float32 + 0.14, 0, 1)
        let g = uint8(clamp(128 + 120 * wavelet(u), 0, 255))
        ImDrawList_AddRectFilled(dl,
          p(left + w * c.float32 / cols.float32, top + h * r.float32 / rows.float32),
          p(left + w * (c + 1).float32 / cols.float32, top + h * (r + 1).float32 / rows.float32),
          u32(Rgba(r: g, g: g, b: g, a: 255)), 0, 0)
    ImDrawList_AddRect(dl, p(left, top), p(left + w, top + h), line, 0, thick, 0)
    if sym == syWiggleDensity:
      wiggle(dl, x0, y0, s, 0.5, c, 0, thick * 1.5)
  of syShotGather, syReceiverGather:
    hyperbola(dl, x0, y0, s, 0.38, line, thick)
    hyperbola(dl, x0, y0, s, 0.62, line, thick)
    if sym == syShotGather:
      star(dl, x0 + s * 0.5, y0 + s * 0.17, s * 0.16, u32(c.fill))
    else:
      triangleDown(dl, x0 + s * 0.5, y0 + s * 0.14, s * 0.13, u32(c.fill))
  of sySource:
    star(dl, x0 + s * 0.5, y0 + s * 0.53, s * 0.42, line)
  of syReceiver:
    triangleDown(dl, x0 + s * 0.5, y0 + s * 0.45, s * 0.38, line)
  of syCursorTime:
    # a time axis at the left, its ticks, and a line from the pointer (a
    # cross at the right) across to it, in the fill colour
    let axis = x0 + s * 0.22
    ImDrawList_AddLine(dl, p(axis, y0 + s * 0.08), p(axis, y0 + s * 0.92), line, thick)
    for k in 0 .. 3:
      let y = y0 + s * (0.14 + 0.24 * k.float32)
      ImDrawList_AddLine(dl, p(axis - s * 0.12, y), p(axis, y), line, thick)
    let (cx, cy) = (x0 + s * 0.78, y0 + s * 0.5)
    ImDrawList_AddLine(dl, p(axis, cy), p(cx, cy), u32(c.fill), thick * 1.5)
    ImDrawList_AddLine(dl, p(cx, cy - s * 0.16), p(cx, cy + s * 0.16), line, thick)
    ImDrawList_AddLine(dl, p(cx - s * 0.16, cy), p(cx + s * 0.16, cy), line, thick)

func symbolColours*(t: Theme; selected = false): SymbolColours =
  ## The theme's colours for a symbol: text-coloured strokes, accent fills; a
  ## selected symbol is drawn in the accent colour.
  if selected:
    SymbolColours(line: t.roles[rlAccent], fill: t.roles[rlAccent])
  else:
    SymbolColours(line: t.roles[rlText], fill: t.roles[rlAccent])
