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
## - fewer than four traces, nothing (said);
## - a direct-current offset does not change the image (the mean is removed);
## - a trace that ends before the box still keeps its slot;
## - whole offsets of a fractional spacing (33.528 m stored as 33 and 34 m
##   steps) are regular at 33.53, a missing trace is not. Seen to fail: with
##   the step's 1 % test on each step, "spacing nan, want 33.53".
##
## Seen to fail: with the wavenumber not turned (the transform's own
## sign), "peak at -14.58333333333333 cycles/km, want 15.0"; with the
## columns not centred on k = 0, "peak at -35.416666666666664 cycles/km,
## want 15.0"; with the box's mean left in, "a direct-current offset
## changed the f-k: peak at -7.105427357601002e-15 cycles/km, 0.0 Hz";
## with a trace that ends before the box left out, "the window has 47
## live rows, the plan was built for 48"; with the stop check not passed
## to the library, "uncancelled polls 0".

import std/[math, monotimes, strutils, times]
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

proc main*() =

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

  block fractionalSpacingWholeOffsets:
    # a group interval of 33.528 m stored as whole metres (steps of 33 and 34):
    # regular at 33.53, as the header's whole unit allows; a trace missing is not
    var pos: seq[float64] = @[]
    for i in 0 ..< 48: pos.add float64(round(float64(i) * 33.528))
    let sp = regularSpacing(pos)
    doAssert abs(sp - 33.53) <= 0.01, "spacing " & $sp & ", want 33.53"
    pos.delete(20)
    doAssert regularSpacing(pos).isNaN, "a missing trace read as regular"

  block directCurrent:
    # the mean of the box is removed: a constant added to every sample is not
    # an event. Seen to fail with that removal left out.
    let plain = fkOf(planeWave(1), Dx, "offsets", suMetres, Dt, 0, AnalysisParams())
    var shifted = planeWave(1)
    for r in shifted.mitems:
      for i in 0 ..< r.len: r[i] += 1000
    let withDc = fkOf(shifted, Dx, "offsets", suMetres, Dt, 0, AnalysisParams())
    doAssert withDc.problem == "", withDc.problem
    let (k, f, _, _) = withDc.image.peakOf
    doAssert abs(f - F) <= withDc.image.dy and abs(k - 1000 * F / V) <= withDc.image.dx,
      "a direct-current offset changed the f-k: peak at " & $k & " cycles/km, " & $f & " Hz"
    doAssert plain.problem == ""

  block shortTraceKeepsItsSlot:
    # a trace that ends before the box still counts, so the wavenumber axis
    # is the gather's. Seen to fail with that trace left out.
    var rows = planeWave(1)
    rows[5].setLen(4)
    var p = AnalysisParams()
    p.fkFromMs = 400
    p.fkToMs = 800
    let r = fkOf(rows, Dx, "offsets", suMetres, Dt, 0, p)
    doAssert r.problem == "", r.problem
    doAssert "48 traces" in r.note, r.note
    let all = fkOf(planeWave(1), Dx, "offsets", suMetres, Dt, 0, p)
    doAssert r.image.cols == all.image.cols and r.image.rows == all.image.rows

  block tooFew:
    let r = fkOf(planeWave(1)[0 .. 2], Dx, "offsets", suMetres, Dt, 0, AnalysisParams())
    doAssert "4 traces at least" in r.problem, r.problem

  block cancelling:
    # a long f-k (96 traces of 8 s at 1 ms) given up from outside: stops between
    # steps, each short, and says so (no numbers). The stop is the Nth poll,
    # about a third of an uncancelled run's polls: a clock threshold can pass
    # before it fires. Seen to fail: with that check not passed to the
    # library, "uncancelled polls 0".
    var big: seq[seq[float32]] = @[]
    for i in 0 ..< 96:
      var r = newSeq[float32](8192)
      for j in 0 ..< r.len: r[j] = float32(sin(float64(j + i) / 9))
      big.add r
    var counted = 0
    let countStop = proc (): bool =
      inc counted
      false
    let full = fkOf(big, 10, "offsets", suMetres, 1.0, 0, AnalysisParams(), countStop)
    doAssert not full.cancelled and full.problem == "", full.problem
    doAssert counted > 30, "uncancelled polls " & $counted
    let stopOn = counted div 3
    var polls = 0
    var last = getMonoTime()
    var worst = 0.0
    let begun = getMonoTime()
    var askedAt = begun
    var asked = false
    let stop = proc (): bool =
      let now = getMonoTime()
      worst = max(worst, float64((now - last).inNanoseconds) / 1e6)
      last = now
      inc polls
      if polls >= stopOn:
        if not asked:
          askedAt = now
          asked = true
        return true
      false
    let r = fkOf(big, 10, "offsets", suMetres, 1.0, 0, AnalysisParams(), stop)
    let after = float64((getMonoTime() - askedAt).inNanoseconds) / 1e6
    doAssert r.cancelled and r.image.isEmpty, "not given up"
    doAssert polls > 10 and worst < 250, $polls & " polls, the longest step " & $worst & " ms"
    doAssert asked and after < 250, "stopped " & $after & " ms after it was asked"
    # never asked to stop: it finishes
    doAssert not fkOf(big[0 .. 7], 10, "offsets", suMetres, 1.0, 0, AnalysisParams()).cancelled
    # asked to stop at once, the spectrogram and the correlation do
    doAssert spectrogramOf(big[0 .. 3], 1.0, 0, AnalysisParams(windowMs: 128, overlap: 75),
      proc (): bool = true).cancelled
    doAssert correlationOf([("a", big[0])], big[1], "b", 1.0, AnalysisParams(maxLagMs: 100),
      proc (): bool = true).cancelled

  echo "tfk: ok"

when isMainModule:
  main()
