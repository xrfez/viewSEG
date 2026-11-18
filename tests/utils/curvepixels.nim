## Whether each data curve of a curve plot is drawn, read off the frame's pixels: a curve
## counts as drawn when a few pixels of the plot area lie within a blending tolerance of its
## own colour. A curve hidden by a later one lying on it within 6 % of its range (a peak on a
## fundamental, two phases both at 2 degrees), one with no finite value, and M and B when the plot says they are "off scale"
## are not asked for. The legend is outside the area, so its swatches never count.

import std/[math, strutils]
import viewSEG/core/geometry
import viewSEG/view/[curveplot, theme]
import viewSEG/ui/imgui/app

const
  Tolerance = 30 ## colour distance that still reads as the curve (anti-aliasing, blending)
  Least = 3      ## pixels of its colour a drawn curve has at least

func covers(a, b: Curve): bool =
  ## Whether curve `a` lies on `b` closely enough to hide it (within 6 % of the data's range).
  if a.ys.len != b.ys.len or a.xs != b.xs: return false
  var lo, hi = NaN
  for y in b.ys:
    if not y.isNaN:
      lo = if lo.isNaN: y else: min(lo, y)
      hi = if hi.isNaN: y else: max(hi, y)
  let tol = 0.06 * max(hi - lo, 1e-9)
  # (nine points in ten: the ends of a taper may part them)
  var near, all = 0
  for i in 0 ..< a.ys.len:
    if not (a.ys[i].isNaN or b.ys[i].isNaN):
      inc all
      if abs(a.ys[i] - b.ys[i]) <= tol: inc near
  result = all > 0 and near * 10 >= all * 9

proc missingCurves*(f: FrameInfo; area: Rect; p: CurvePlot): seq[string] =
  ## The names of the curves of `p` with no pixel of their colour in `area`.
  var off = ""
  for c in p.curves:
    if c.name.endsWith(" off scale"): off = c.name
  var counts = newSeq[int](p.curves.len)
  var asked = newSeq[bool](p.curves.len)
  for j, c in p.curves:
    var finite = false
    for y in c.ys:
      if not y.isNaN and abs(y) != Inf: finite = true
    asked[j] = finite and not (off.len > 0 and c.name in ["M", "B"] and c.name in off)
    for k in j + 1 ..< p.curves.len:
      if p.curves[k].covers(c): asked[j] = false
  for y in int(area.pos.y) ..< int(area.pos.y + area.size.y):
    for x in int(area.pos.x) + 1 ..< int(area.pos.x + area.size.x) - 1:
      let px = f.readPixel(x, y)
      for j, c in p.curves:
        if asked[j] and distance(px, c.colour) <= Tolerance: inc counts[j]
  for j, c in p.curves:
    if asked[j] and counts[j] < Least: result.add c.name
