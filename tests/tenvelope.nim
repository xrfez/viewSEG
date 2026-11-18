## The envelope window's phase against the reference (`envelopeOf`), on
## samples/vib/vib_uncorrelated.sgd (an 8 s sweep, 8 to 80 Hz, a pilot and a
## ground force 6 degrees ahead of it) and on short signals:
##
## - a trace against itself is 0 degrees everywhere it is drawn, titled "Phase
##   against the reference", on a fixed axis of -180 to 180;
## - the sample's ground force against its pilot reads about +6 degrees on
##   the mean inside the sweep, in the plot's words under it;
## - without a reference, or asked "Of the trace itself", the phase is the
##   trace's own, as it was drawn, retitled, with the help line; the
##   frequency plot gets the reference's dim curve only against a reference;
## - a reference of another length is zero-padded to the longer, the phase
##   drawn only where both are above the floor; a reference given and not
##   used says why in the note.
##
## Seen to fail: with the difference taken as reference minus trace, the
## ground force read -6 degrees; with the floor not applied to the reference,
## the quiet part after the sweep was drawn as scatter ("drawn after the
## sweep"); with `phaseAgainst` ignored, "of the trace itself" drew the
## difference.

import std/[math, os, strutils]
import parseSEG
import processSEG/fft/spectrum
import viewSEG/core/analysis

const root = currentSourcePath().parentDir.parentDir

proc trace(f: var SeismicFile; i: int): seq[float32] =
  let x = f.readTraces(i .. i)
  result = newSeq[float32](x.shape[1])
  for j in 0 ..< result.len: result[j] = x[0, j]

func finite(ys: seq[float64]): seq[int] =
  for i, y in ys:
    if not y.isNaN: result.add i

proc main*() =
  let path = root / "samples" / "vib" / "vib_uncorrelated.sgd"
  doAssert fileExists(path), path
  var f = openSeismic(path, keys = true)
  let pilot = f.trace(48)
  let force = f.trace(49)
  let dtMs = f.traceKeys(48).intervalUs / 1000
  f.close()

  block itself:
    let r = envelopeOf(pilot, "pilot", dtMs, 0.0, AnalysisParams(), pilot, "the pilot")
    doAssert r.problem == "", r.problem
    doAssert r.plots.len == 3 and r.plots[1].title == "Phase against the reference"
    doAssert r.plots[1].yLo == 0 and r.plots[1].yHi == 10, "a flat 0 fits 0 to 10° (sizes: never below 0)"
    let ys = r.plots[1].curves[0].ys
    let drawn = ys.finite
    doAssert drawn.len > 1000, $drawn.len & " samples drawn"
    for i in drawn: doAssert ys[i] == 0.0, "sample " & $i & " is " & $ys[i]
    doAssert "mean |phase| 0.0" in r.plots[1].aside and "largest 0.0" in r.plots[1].aside,
      r.plots[1].aside
    doAssert r.plots[2].curves.len == 2 and r.plots[2].curves[1].style == csReference

  block frequencyPastAQuarterOfTheRate:
    # processSEG's instantaneous frequency is right above a quarter of the sampling rate
    # (62.5 Hz at 4 ms): the pilot's frequency follows the sweep's line, 8 to 80 Hz over 8 s,
    # up to its end.
    # Seen to fail: with processSEG 0.7.0, a fold below the line past 62.5 Hz.
    let r = envelopeOf(pilot, "pilot", dtMs, 0.0, AnalysisParams())
    doAssert r.problem == "", r.problem
    let hz = r.plots[2].curves[0].ys
    let xs = r.plots[2].xs
    var n = 0
    for i, y in hz:
      if xs[i] in 6500.0 .. 7500.0 and not y.isNaN:
        inc n
        let want = 8.0 + 72.0 * xs[i] / 8000.0
        doAssert abs(y - want) < 2.0, "at " & $xs[i] & " ms: " & $y & " Hz, the sweep is " & $want
    doAssert n > 100, "frequencies drawn past 62.5 Hz: " & $n

  block groundForce:
    let r = envelopeOf(force, "GF", dtMs, 0.0, AnalysisParams(), pilot, "the pilot")
    doAssert r.problem == "", r.problem
    let ys = r.plots[1].curves[0].ys
    var sum = 0.0
    var n = 0
    let xs = r.plots[1].xs
    for i, y in ys:
      if not y.isNaN and xs[i] in 1000.0 .. 7000.0: # well inside the 8 s sweep
        sum += y
        inc n
    doAssert n > 1000, "drawn inside the sweep: " & $n
    let mean = sum / float64(n)
    doAssert abs(mean - 6.0) < 1.0, "the ground force reads " & $mean & " degrees"
    doAssert "mean |phase| 6" in r.plots[1].aside or "mean |phase| 5" in r.plots[1].aside or
      "mean |phase| 7" in r.plots[1].aside, r.plots[1].aside
    # not drawn where the reference is gone: the listen time after the sweep
    doAssert r.plots[1].yLo >= 0 and r.plots[1].yHi > 6 and
      r.plots[1].yHi <= 185, "the axis holds the drawn values: " & $(r.plots[1].yLo,
      r.plots[1].yHi)
    for i, y in ys:
      if xs[i] > 8600.0: doAssert y.isNaN, "drawn after the sweep at " & $xs[i] & " ms"

  block circularMean:
    doAssert abs(circularMeanDeg([179.0, -179.0]).meanDeg.abs - 180.0) < 1e-9, "a plain mean says 0"
    doAssert abs(circularMeanDeg([10.0, 20.0, NaN]).meanDeg - 15.0) < 1e-9
    doAssert circularMeanDeg([NaN]).meanDeg.isNaN
    # a reversed trace reads 180, not a plain mean's 2.5
    var sweep = newSeq[float32](2000)
    for i in 0 ..< sweep.len:
      let t = float64(i) * 0.002
      sweep[i] = float32(sin(2 * PI * (8 * t + 12 * t * t)))
    var rev = newSeq[float32](sweep.len)
    for i in 0 ..< sweep.len: rev[i] = -sweep[i] + float32(0.001 * sin(float64(i)))
    let r = envelopeOf(rev, "rev", 2.0, 0.0, AnalysisParams(phaseShow: psSigned), sweep,
      "ref")
    doAssert "mean 180.0" in r.plots[1].aside or "mean -180.0" in r.plots[1].aside,
      r.plots[1].aside
    let a = envelopeOf(rev, "rev", 2.0, 0.0, AnalysisParams(), sweep, "ref")
    doAssert "mean |phase| 180.0" in a.plots[1].aside, a.plots[1].aside

  block paddingIsNotDrawn:
    var sweep = newSeq[float32](2000)
    for i in 0 ..< sweep.len:
      let t = float64(i) * 0.002
      sweep[i] = float32(sin(2 * PI * (8 * t + 12 * t * t)))
    let r = envelopeOf(sweep[0 ..< 1500], "short", 2.0, 0.0, AnalysisParams(), sweep, "ref")
    doAssert r.plots[1].xs.len == 1500 and r.plots[0].curves[0].ys.len == 1500 and
      r.plots[2].curves[1].ys.len == 1500, "the plots end with the trace"
    doAssert r.plots[1].curves[0].ys.finite.len > 500

  block ownPhase:
    let own = envelopeOf(force, "GF", dtMs, 0.0)
    doAssert own.plots[1].title == "Instantaneous phase of the trace"
    doAssert "turns once per cycle" in own.note and "choose a reference to compare" in own.note
    doAssert own.plots[2].curves.len == 1
    let asked = envelopeOf(force, "GF", dtMs, 0.0, AnalysisParams(phaseAgainst: paSelf),
      pilot, "the pilot")
    doAssert asked.plots[1].title == own.plots[1].title
    doAssert asked.plots[1].curves[0].ys.len == own.plots[1].curves[0].ys.len
    for i, y in own.plots[1].curves[0].ys:
      let z = asked.plots[1].curves[0].ys[i]
      doAssert (y.isNaN and z.isNaN) or y == z, "the trace's own phase changed at " & $i
    doAssert asked.plots[2].curves.len == 1, "a reference curve against nothing"
    doAssert "Against the reference" in asked.note, asked.note
    let said = envelopeOf(force, "GF", dtMs, 0.0, AnalysisParams(phaseAgainst: paSelf),
      notUsed = "gone", haveReference = true)
    doAssert "was not used" notin said.note and "choose a reference to compare" notin said.note,
      said.note

  block mismatch:
    let short = pilot[0 ..< 1000]
    let r = envelopeOf(force, "GF", dtMs, 0.0, AnalysisParams(), short, "a short one")
    doAssert r.problem == ""
    doAssert r.plots[1].xs.len == force.len, "the longer sets the length"
    var late = 0
    for i in 1500 ..< force.len: # the transform's ringing ends within a few hundred samples
      if not r.plots[1].curves[0].ys[i].isNaN: inc late
    doAssert late == 0, "the phase is drawn where the reference is zero padding: " & $late
    doAssert r.plots[1].curves[0].ys.finite.len in 100 .. 1500, "drawn over the reference's part"
    let said = envelopeOf(force, "GF", dtMs, 0.0, AnalysisParams(), notUsed = "the reference is" &
      " 2 ms, this file is 4 ms")
    doAssert said.note.startsWith("The reference was not used: the reference is 2 ms"), said.note
    doAssert said.plots[1].title == "Instantaneous phase of the trace"

when isMainModule: main()
