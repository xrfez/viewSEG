## Seismic symbols that no icon font has, drawn as vector shapes with the
## window's draw list, so they are crisp at any size and take any theme colour:
## the display modes (wiggle, positive fill, negative fill, greyscale density,
## wiggle over density),
## the gather domains (shot, receiver), the map markers (source, receiver),
## the cursor's time line, the plot's turn (time across) and the first-break
## overlay (two bars across a trace, where the model expects the break and
## where it was picked).
##
## Traces run downwards (time increases down the screen), as in the trace
## panel; drawn `turned`, the plot's symbols turn with a plot whose time
## runs across (a quarter turn anticlockwise: time to the right, a positive
## swing up). The density symbol is drawn in neutral greys whatever the
## theme, like the density display itself.

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
    syTimeAcross = "Time across"
    syFirstBreaks = "First-break overlay"

  SymbolColours* = object
    line*: Rgba ## strokes and markers
    fill*: Rgba ## wiggle fills

const wiggleSteps = 40

func wavelet*(u: float32): float32 =
  ## The symbols' trace: two cycles under a half-sine envelope, zero at both
  ## ends (u in 0..1), starting with a positive lobe.
  sin(2 * PI * 2 * u) * sin(PI * u)

func p(x, y: float32): ImVec2_c = ImVec2_c(x: x, y: y)

type Box = object
  ## The square a symbol is drawn in, and whether it is turned.
  x0, y0, s: float32
  turned: bool

func at(b: Box; u, v: float32): ImVec2_c =
  ## The point `u` across and `v` down the box (fractions of its side),
  ## turned a quarter turn anticlockwise about its centre when the box is:
  ## down becomes right, right becomes up.
  if b.turned: p(b.x0 + b.s * v, b.y0 + b.s * (1 - u)) else: p(b.x0 + b.s * u, b.y0 + b.s * v)

proc rectFilled(dl: ptr ImDrawList; b: Box; u0, v0, u1, v1: float32; col: ImU32) =
  ## The rectangle between box fractions (`u0`, `v0`) and (`u1`, `v1`).
  let (a, c) = (b.at(u0, v0), b.at(u1, v1))
  ImDrawList_AddRectFilled(dl, p(min(a.x, c.x), min(a.y, c.y)), p(max(a.x, c.x), max(a.y, c.y)),
    col, 0, 0)

proc rect(dl: ptr ImDrawList; b: Box; u0, v0, u1, v1: float32; col: ImU32; thick: float32) =
  let (a, c) = (b.at(u0, v0), b.at(u1, v1))
  ImDrawList_AddRect(dl, p(min(a.x, c.x), min(a.y, c.y)), p(max(a.x, c.x), max(a.y, c.y)), col,
    0, thick, 0)

proc line(dl: ptr ImDrawList; b: Box; u0, v0, u1, v1: float32; col: ImU32; thick: float32) =
  ImDrawList_AddLine(dl, b.at(u0, v0), b.at(u1, v1), col, thick)

proc wiggle(dl: ptr ImDrawList; b: Box; cx: float32; c: SymbolColours; fillSign: int;
    thick: float32) =
  ## One trace with its baseline at `cx` (a fraction of the box), filled on
  ## the side `fillSign` (+1, -1, or 0 for none).
  let amp = 0.19'f32
  var uv: array[wiggleSteps + 1, (float32, float32)]
  var pts: array[wiggleSteps + 1, ImVec2_c]
  for i in 0 .. wiggleSteps:
    let u = i.float32 / wiggleSteps
    uv[i] = (cx + amp * wavelet(u), 0.1'f32 + 0.8'f32 * u)
    pts[i] = b.at(uv[i][0], uv[i][1])
  if fillSign != 0:
    let col = u32(c.fill)
    for i in 0 ..< wiggleSteps:
      # one trapezoid per step between the baseline and the clipped trace
      let ((ua, va), (ub, vb)) = (uv[i], uv[i + 1])
      let (xa, xb) = if fillSign > 0: (max(ua, cx), max(ub, cx))
                     else: (min(ua, cx), min(ub, cx))
      var quad = [b.at(cx, va), b.at(xa, va), b.at(xb, vb), b.at(cx, vb)]
      # off the baseline, in pixels
      if quad[1].x != quad[0].x or quad[1].y != quad[0].y or quad[2].x != quad[3].x or
          quad[2].y != quad[3].y:
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
    c: SymbolColours; turned = false) =
  ## Draws `sym` in the square of side `size` at `topLeft` (pixels); the
  ## plot's symbols (the display modes, the fills, the cursor's time line)
  ## `turned` with a plot whose time runs across.
  let (x0, y0, s) = (topLeft.x, topLeft.y, size)
  let b = Box(x0: x0, y0: y0, s: s, turned: turned)
  let thick = max(1'f32, s / 14)
  let line = u32(c.line)
  case sym
  of syWiggle, syWigglePositive, syWiggleNegative:
    let sign = case sym
      of syWigglePositive: 1
      of syWiggleNegative: -1
      else: 0
    for cx in [0.3'f32, 0.7]:
      wiggle(dl, b, cx, c, sign, thick)
  of syDensity, syWiggleDensity:
    # a small greyscale section: the wavelet in each column, dipping to the
    # right, framed; with a wiggle over its middle
    const (cols, rows) = (5, 12)
    for c in 0 ..< cols:
      for r in 0 ..< rows:
        let u = clamp((r.float32 + 0.5) / rows.float32 - 0.07 * c.float32 + 0.14, 0, 1)
        let g = uint8(clamp(128 + 120 * wavelet(u), 0, 255))
        rectFilled(dl, b, 0.1 + 0.8 * c.float32 / cols.float32, 0.1 + 0.8 * r.float32 /
          rows.float32, 0.1 + 0.8 * (c + 1).float32 / cols.float32, 0.1 + 0.8 * (r + 1).float32 /
          rows.float32, u32(Rgba(r: g, g: g, b: g, a: 255)))
    rect(dl, b, 0.1, 0.1, 0.9, 0.9, line, thick)
    if sym == syWiggleDensity:
      wiggle(dl, b, 0.5, c, 0, thick * 1.5)
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
    line(dl, b, 0.22, 0.08, 0.22, 0.92, line, thick)
    for k in 0 .. 3:
      let v = 0.14'f32 + 0.24'f32 * k.float32
      line(dl, b, 0.10, v, 0.22, v, line, thick)
    line(dl, b, 0.22, 0.5, 0.78, 0.5, u32(c.fill), thick * 1.5)
    line(dl, b, 0.78, 0.34, 0.78, 0.66, line, thick)
    line(dl, b, 0.62, 0.5, 0.94, 0.5, line, thick)
  of syFirstBreaks:
    # a trace running down the middle, crossed by two bars at different
    # times with a thin connector between them: the model's (the fill
    # colour) above, the pick's (the stroke colour) below
    line(dl, b, 0.5, 0.06, 0.5, 0.94, line, thick)
    line(dl, b, 0.5, 0.36, 0.5, 0.66, u32(c.fill), thick)
    line(dl, b, 0.14, 0.36, 0.86, 0.36, u32(c.fill), thick * 1.8)
    line(dl, b, 0.14, 0.66, 0.86, 0.66, line, thick * 1.8)
  of syTimeAcross:
    # a trace lying along a time axis that points to the right: the plot
    # turned, time across and a positive swing up
    let tb = Box(x0: x0, y0: y0, s: s, turned: true)
    wiggle(dl, tb, 0.58, c, 1, thick)
    line(dl, tb, 0.16, 0.06, 0.16, 0.94, line, thick)
    line(dl, tb, 0.06, 0.82, 0.16, 0.94, line, thick)
    line(dl, tb, 0.26, 0.82, 0.16, 0.94, line, thick)

func symbolColours*(t: Theme; selected = false): SymbolColours =
  ## The theme's colours for a symbol: text-coloured strokes, accent fills; a
  ## selected symbol is drawn in the accent colour.
  if selected:
    SymbolColours(line: t.roles[rlAccent], fill: t.roles[rlAccent])
  else:
    SymbolColours(line: t.roles[rlText], fill: t.roles[rlAccent])
