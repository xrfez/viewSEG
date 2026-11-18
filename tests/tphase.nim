## Phase pictures (`core/phasepicture`, and the phase spectrum that draws
## them): the unwrapped line by default, the absolute value, the signed
## value, and that line with its delay taken off.
##
## - known phases: a straight line, a parabola, and a line with a gap, each
##   unwrapped back to what it was; the unwrap starts again after the gap
##   from the last drawn value, and does not follow a jump that sits in the
##   gap;
## - magnitude stays in 0 to 180; signed is the wrapped value, with the
##   gaps; the default picture is unwrapped (the spectrum's, and the analysis's);
## - an impulse's delay-removed phase is flat, and the delay it reports is
##   the impulse's time;
## - the sample pilot (`samples/vib/vib_uncorrelated.sgd`, the source
##   reference) has an unwrapped phase that falls smoothly inside 8 to 80 Hz
##   and is absent outside that band.
##
## Seen to fail: with `unwrapPhase` adjusting a bin but not keeping the
## offset for the next, "parabola at 15: 180.0"; with the disabled spectrum
## boxes still given the stored flag, the GUI test's "processed drawn
## ticked while no filter is on".

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[analysis, phasepicture, spectra]

func near(a, b, tol: float64): bool = abs(a - b) <= tol

func wrap(p: float64): float64 =
  result = p
  while result > 180: result -= 360
  while result <= -180: result += 360

proc main*() =

  block unwrapKnown:
    # A line that crosses 180 once, and a parabola that crosses it many times.
    var line, shown = newSeq[float64](8)
    var on = newSeq[bool](8)
    for k in 0 ..< 8:
      line[k] = wrap(20.0 * float64(k))
      on[k] = true
    let got = unwrapPhase(line, on)
    for k in 0 ..< 8:
      doAssert near(got[k], 20.0 * float64(k), 1e-9), "unwrapped " & $got[k] &
        ", want " & $(20.0 * float64(k))
    var quad = newSeq[float64](30)
    var qOn = newSeq[bool](30)
    for k in 0 ..< 30:
      quad[k] = wrap(-0.8 * float64(k * k))
      qOn[k] = true
    let q = unwrapPhase(quad, qOn)
    for k in 0 ..< 30:
      doAssert near(q[k], -0.8 * float64(k * k), 1e-6), "parabola at " & $k & ": " & $q[k]

  block unwrapGap:
    # 0, a hidden 179, then -179. Continuing from 0, -179 stays -179. Drawing
    # the hidden bin carries the offset on, and -179 becomes 181.
    let wrapped = [0.0, 179.0, -179.0]
    let got = unwrapPhase(wrapped, [true, false, true])
    doAssert got[1].isNaN, "the gap was drawn"
    doAssert near(got[0], 0, 1e-9)
    doAssert near(got[2], -179, 1e-6), "after the gap: " & $got[2] & ", want -179.0"
    let through = unwrapPhase(wrapped, [true, true, true])
    doAssert near(through[1], 179, 1e-6) and near(through[2], 181, 1e-6), $through

  block pictures:
    let wrapped = [10.0, 170.0, -170.0, -20.0, 5.0]
    let shown = [true, true, false, true, true]
    let hz = [0.0, 1.0, 2.0, 3.0, 4.0]
    let mag = drawnPhase(wrapped, shown, hz, ppMagnitude)
    for y in mag.ys:
      doAssert y.isNaN or (y >= -1e-6 and y <= 180 + 1e-4), "magnitude " & $y &
        " is outside 0..180"
    doAssert mag.ys[2].isNaN and near(mag.ys[1], 170, 1e-9) and near(mag.ys[3], 20, 1e-9)
    let signed = drawnPhase(wrapped, shown, hz, ppSigned)
    doAssert near(signed.ys[1], 170, 1e-9) and signed.ys[2].isNaN and
      near(signed.ys[3], -20, 1e-9)
    let unwrapped = drawnPhase(wrapped, shown, hz, ppUnwrapped)
    doAssert unwrapped.ys[2].isNaN
    doAssert near(unwrapped.ys[3], -20, 1e-6) or near(unwrapped.ys[3], 340, 1e-6)
    doAssert PhasePicture(0) == ppUnwrapped, "the default is not unwrapped"
    doAssert SpectrumDisplay().phasePicture == ppUnwrapped,
      "the spectrum display does not default to unwrapped"
    doAssert AnalysisParams().phasePicture == ppUnwrapped,
      "the analysis does not default to unwrapped"

  block delayOfAnImpulse:
    let n = 512
    let m = 40
    var x = newSeq[float32](n)
    x[m] = 1
    let r = phaseOf(x, "impulse", 2.0, AnalysisParams(phaseWithinDb: 40,
      phasePicture: ppDelayRemoved))
    doAssert r.problem == "", r.problem
    let ph = r.plots[1].curves[0].ys
    var nDrawn = 0
    let hz = r.plots[1].xs
    for k, y in ph:
      if not y.isNaN:
        inc nDrawn
        # (removing the mean adds a sinc, 1/(π·f·T) radians of the impulse's flat amplitude)
        let slack = 1.0 + 2 * 360 / (PI * PI * hz[k] * 1.024)
        doAssert abs(y) < slack, "residual " & $y & " after the delay was taken off"
    doAssert nDrawn > 10
    doAssert r.note.find("delay 80.0 ms") >= 0, r.note
    let mag = phaseOf(x, "impulse", 2.0, AnalysisParams(phasePicture: ppMagnitude))
    doAssert mag.plots[1].yLo == 0 and mag.plots[1].yHi == 180, "the default axis is not 0..180"
    for y in mag.plots[1].curves[0].ys:
      doAssert y.isNaN or (y >= -1e-6 and y <= 180 + 1e-4), $y
    doAssert mag.note.find("0 to 180") >= 0, mag.note

  block pilotOfTheSample:
    let path = currentSourcePath().parentDir.parentDir / "samples" / "vib" /
      "vib_uncorrelated.sgd"
    var f = openSeismic(path, keys = true)
    var pilot = -1
    for i in 0 ..< f.len:
      if not f.traceKeys(i).isSeismic and f.traceEntry(i).channelSetIndex == 1:
        pilot = i
    doAssert pilot >= 0, "no pilot trace"
    let dtMs = f.traceKeys(pilot).intervalUs / 1000
    let samples = f.readTraces(pilot .. pilot)
    var x = newSeq[float32](samples.shape[1])
    for i in 0 ..< x.len: x[i] = samples[0, i]
    f.close()
    # Wide enough that the sweep's band is drawn, tight enough that the noise
    # outside it is not: the same -60 dB floor a spectrum window uses.
    let r = phaseOf(x, "pilot", dtMs, AnalysisParams(phaseWithinDb: -PhaseFloorDb,
      phasePicture: ppUnwrapped))
    doAssert r.problem == "", r.problem
    let hz = r.plots[1].xs
    let ph = r.plots[1].curves[0].ys
    var last = Inf
    var lastHz = 0.0
    var inside = 0
    for k in 0 ..< hz.len:
      let inBand = hz[k] >= 8.0 and hz[k] <= 80.0
      if inBand:
        doAssert not ph[k].isNaN, "no phase at " & $hz[k] & " Hz"
        if last < Inf:
          doAssert ph[k] < last, "the phase rises from " & $last & " at " & $lastHz &
            " to " & $ph[k] & " at " & $hz[k]
          let slope = (last - ph[k]) / (hz[k] - lastHz)
          doAssert slope < 8000, "a jump of " & $slope & " deg/Hz at " & $hz[k]
        (last, lastHz) = (ph[k], hz[k])
        inc inside
      elif hz[k] > 100.0:
        doAssert ph[k].isNaN, "a phase at " & $hz[k] & " Hz, outside the sweep"
    doAssert inside > 50, "only " & $inside & " bins inside 8-80 Hz"
    let mag = phaseOf(x, "pilot", dtMs, AnalysisParams(phaseWithinDb: -PhaseFloorDb,
      phasePicture: ppMagnitude))
    for y in mag.plots[1].curves[0].ys:
      doAssert y.isNaN or (y >= -1e-6 and y <= 180 + 1e-4), $y

  echo "tphase: ok"

when isMainModule:
  main()
