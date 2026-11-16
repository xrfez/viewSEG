## The f-k view's numbers (`core/fkanalysis`), on plane waves made here:
##
## - a 30 Hz plane wave dipping at 2000 m/s across 48 traces 10 m apart
##   peaks at 30 Hz and +15 cycles/km (k = f/v), within a bin, and the
##   apparent velocity read there is 2000 m/s within the bins' spacing; the
##   same wave dipping the other way peaks at -15;
## - with no regular spacing the wavenumber is per trace (0.15: f·Δx/v) and
##   the axis says so;
## - a box (from, to) is of those times only: a wave outside it is not seen;
## - the spacing: regular offsets give it, a split spread's signed offsets
##   too, irregular ones none, then receivers' coordinates along the line;
## - fewer than four traces, nothing (said).
##
## Seen to fail: with the wavenumber not turned (the transform's own
## sign), "peak at -14.58333333333333 cycles/km, want 15.0"; with the
## columns not centred on k = 0, "peak at -35.416666666666664 cycles/km,
## want 15.0".

import std/[math, strutils]
import viewSEG/core/[analysis, fkanalysis, join]
import viewSEG/view/analysisview

const
  Dt = 2.0  # ms
  N = 500   # samples: 1 s
  Traces = 48
  Dx = 10.0 # m
  V = 2000.0
  F = 30.0

proc planeWave(dip: float64; startMs = 0.0; endMs = 1000.0; dx = Dx; v = V): seq[seq[float32]] =
  ## A cosine of F Hz, trace i delayed i·Dx/V·dip seconds, between two times.
  for i in 0 ..< Traces:
    var r = newSeq[float32](N)
    for j in 0 ..< N:
      let t = float64(j) * Dt
      if t >= startMs and t < endMs:
        r[j] = float32(cos(2 * PI * F * (t / 1000 - dip * float64(i) * dx / v)))
    result.add r

proc peakOf(img: AnalysisImage): (float64, float64, int, int) =
  ## The wavenumber and frequency of the largest value, and its cell.
  var (bc, br) = (0, 0)
  for c in 0 ..< img.cols:
    for r in 0 ..< img.rows:
      if img.valueAt(c, r) > img.valueAt(bc, br): (bc, br) = (c, r)
  (img.xOf(bc), img.yOf(br), bc, br)

block dippingPlaneWave:
  let r = fkOf(planeWave(1), Dx, "offsets", suMetres, Dt, 0, AnalysisParams())
  doAssert r.problem == "", r.problem
  let img = r.image
  doAssert img.xLabel == "Wavenumber (cycles/km)" and img.yLabel == "Frequency (Hz)"
  let (k, f, c, row) = img.peakOf
  doAssert abs(k - 1000 * F / V) <= img.dx, "peak at " & $k & " cycles/km, want " &
    $(1000 * F / V)
  doAssert abs(f - F) <= img.dy, "peak at " & $f & " Hz, want " & $F
  # the apparent velocity read there: f / k, within the cell's spacing
  let text = img.readingText(PlotCursor(held: true, x: c, y: row))
  let v = parseFloat(text.split(" · ")[^1].split(' ')[0])
  doAssert abs(v - V) < V * (img.dx / k + img.dy / f), text
  doAssert text.endsWith(" m/s"), text
  doAssert img.hi == 0 and img.valueAt(c, row) == 0
  # the other way: a negative wavenumber
  let back = fkOf(planeWave(-1), Dx, "offsets", suMetres, Dt, 0, AnalysisParams()).image
  let (kb, _, _, _) = back.peakOf
  doAssert abs(kb + 1000 * F / V) <= back.dx, "peak at " & $kb & ", want " & $(-1000 * F / V)

block feetAndMetres:
  # one wave, 3000 m/s at 30 Hz, traces 110 ft (33.528 m) apart. Its true
  # wavenumber is 10 cycles/km = 3.048 cycles/kft, and its velocity 3000 m/s
  # = 9842.5 ft/s, whichever unit the file is in
  const Ft = 0.3048
  let rows = planeWave(1, dx = 110 * Ft, v = 3000)
  let ft = fkOf(rows, 110, "offsets", suFeet, Dt, 0, AnalysisParams())
  doAssert ft.problem == "" and ft.image.xLabel == "Wavenumber (cycles/kft)", ft.image.xLabel
  doAssert ft.image.xUnit == "/kft" and ft.image.velocityUnit == "ft/s"
  let (kf, _, cf, rf) = ft.image.peakOf
  doAssert abs(kf - 3.048) <= ft.image.dx, "peak at " & $kf & " cycles/kft, want 3.048"
  let tf = ft.image.readingText(PlotCursor(held: true, x: cf, y: rf))
  let vf = parseFloat(tf.split(" · ")[^1].split(' ')[0])
  doAssert abs(vf - 9842.5) < 9842.5 * (ft.image.dx / kf + ft.image.dy / 30), tf
  doAssert tf.endsWith(" ft/s") and "feet" in ft.note, ft.note
  let us = fkOf(rows, 110, "offsets", suUsFeet, Dt, 0, AnalysisParams())
  doAssert us.image.xLabel == "Wavenumber (cycles/kft)" and "US survey feet" in us.note, us.note
  # the same wave in metres: 10 cycles/km, 3000 m/s
  let m = fkOf(rows, 110 * Ft, "offsets", suMetres, Dt, 0, AnalysisParams())
  let (km, _, cm, rm) = m.image.peakOf
  doAssert abs(km - 10) <= m.image.dx, "peak at " & $km & " cycles/km, want 10"
  let tm = m.image.readingText(PlotCursor(held: true, x: cm, y: rm))
  let vm = parseFloat(tm.split(" · ")[^1].split(' ')[0])
  doAssert abs(vm - 3000) < 3000 * (m.image.dx / km + m.image.dy / 30), tm
  doAssert tm.endsWith(" m/s")
  # an angular unit, or none given, is no length: per trace, said why
  for u in [suDegrees, suArcSeconds, suDms, suNotGiven]:
    let a = fkOf(rows, 110, "offsets", u, Dt, 0, AnalysisParams())
    doAssert a.image.xLabel == "Wavenumber (cycles per trace)" and
      a.image.velocityUnit == "traces/s" and "not a length" in a.note, $u & ": " & a.note

block perTrace:
  let r = fkOf(planeWave(1), NaN, "", suMetres, Dt, 0, AnalysisParams())
  let img = r.image
  doAssert img.xLabel == "Wavenumber (cycles per trace)", img.xLabel
  let (k, _, _, _) = img.peakOf
  doAssert abs(k - F * Dx / V) <= img.dx, "peak at " & $k & " cycles per trace"
  doAssert "not regular" in r.note, r.note

block aBox:
  # the wave only after 600 ms; a box of 0 to 500 ms sees nothing of it
  var p = AnalysisParams(fkFromMs: 0, fkToMs: 500)
  let early = fkOf(planeWave(1, startMs = 600), Dx, "offsets", suMetres, Dt, 0, p)
  doAssert early.problem == ""
  var loud = 0
  for v in early.image.values:
    if v > -40: inc loud
  doAssert loud == 0, $loud & " cells above -40 dB where the box has no wave"
  p.fkFromMs = 600
  p.fkToMs = 998
  let late = fkOf(planeWave(1, startMs = 600), Dx, "offsets", suMetres, Dt, 0, p)
  let (k, _, _, _) = late.image.peakOf
  doAssert abs(k - 1000 * F / V) <= late.image.dx

block spacing:
  doAssert regularSpacing([100.0, 125, 150, 175]) == 25
  doAssert regularSpacing([-50.0, -25, 0, 25, 50]) == 25 # a split spread, signed
  doAssert regularSpacing([100.0, 125, 160, 175]).isNaN
  doAssert regularSpacing([100.0, 100, 100]).isNaN
  let nan = [NaN, NaN, NaN, NaN]
  let s = spacingOf(nan, [0.0, 30, 60, 90], [0.0, 40, 80, 120])
  doAssert s.spacing == 50 and s.source == "receiver coordinates", $s
  doAssert spacingOf(nan, nan, nan).spacing.isNaN

block tooFew:
  let r = fkOf(planeWave(1)[0 .. 2], Dx, "offsets", suMetres, Dt, 0, AnalysisParams())
  doAssert "4 traces at least" in r.problem, r.problem

echo "tfk: ok"
