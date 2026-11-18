## The cross-correlation window's numbers on generated signals with known answers
## (a 30 Hz Ricker wavelet at 2 ms, 1 001 samples, its peak at 500 ms):
##
## - the match is the correlation envelope's peak and the turn of phase is said: a copy
##   rotated by 45, 90, 135 and 180 degrees reads "best match 1.00 at 0.0 ms" and
##   "rotated 45°" (and so on; 180 is "reversed polarity"); the table's rotation column says
##   the same;
## - the shift is between samples: copies delayed by +3 ms and -1 ms at 2 ms sampling read
##   +3.0 and -1.0;
## - a peak at an end of the lags is "no peak within ±6.0 ms: widen the time shifts" (and
##   "-" in the table, no phase); a trace at -20 dB signal to noise is "no clear match", with
##   no shift or direction;
## - the phase per frequency is measured after the found shift is removed: a copy delayed by
##   10 ms has a mean phase near 0, not 117°, and the note says so;
## - a transient reference gives no "signal ends early" warning for its own copies, rotated,
##   inverted, delayed or with float ripple in their tails;
## - through the program (an archive reference, the plot's band-pass 20-25-35-40 Hz): exact
##   copies of the reference match 1.00 at 0.0 dB, the table is the same as with no filter (raw
##   trace against raw reference), and the note says the plot's filters are not applied;
## - the window and the Compare window say the same of one pair, in the same words (the 90°
##   copy: "best match 1.00 at 0.0 ms ... rotated 90°" in both, not "0.874 at -8 ms" in one);
##   "Shift B by the correlation peak" moves B by that match's shift, and which way B lies is
##   said ("B lags A by 4.0 ms", "B leads A by").
##
## Seen to fail: with the match taken from the correlation at the envelope's peak (`cs[best]`),
## the 90° copy read "best match 0.00" and the 45° "0.71"; with the shift on whole samples, +3 ms
## read +2.0; with an edge peak reported as the shift, the 40 ms delay read "+6.0 ms"; with the
## weak-match test off, the -20 dB trace gave "arrives 4.0 ms after the reference"; with the
## phase taken from the unshifted traces, the 10 ms copy's mean phase was 117.0; with the
## signal end compared with the reference's length, the rotated and inverted copies warned
## "signal ends at about 700 ms"; with the plot's filters applied to the traces
## alone, the band-passed copies read match 0.75 and -14.1 dB.

import std/[math, os, strutils]
import parseSEG
import processSEG/fft/hilbert
import processSEG/core/workspace
import viewSEG/core/[analysis, compare, processing, state]
import utils/[chosenref, fixtures, waiting]

const
  DtMs = 2.0
  Samples = 1001

func ricker(delayMs = 0.0; scale = 1.0): seq[float32] =
  result = newSeq[float32](Samples)
  for i in 0 ..< Samples:
    let t = (float64(i) * DtMs - 500.0 - delayMs) / 1000
    let a = pow(PI * 30 * t, 2)
    result[i] = float32(scale * (1 - 2 * a) * exp(-a))

proc rotated(x: seq[float32]; deg: float64): seq[float32] =
  ## `x` with every phase turned by `deg`: the real part of its analytic signal times e^(i deg).
  let n = 4 * x.len
  let hp = initHilbertPlan(float32, n)
  var ws = initWorkspace()
  ws.reserve(hp.workspaceSize)
  var padded = newSeq[float32](n)
  for i in 0 ..< x.len: padded[i] = x[i]
  var env, phase, hz = newSeq[float64](n)
  hp.analyticInto(padded, DtMs, env, phase, hz, ws, -400.0)
  result = newSeq[float32](x.len)
  for i in 0 ..< x.len:
    result[i] = float32(env[i] * cos(degToRad(phase[i] + deg)))

proc noisy(x: seq[float32]; snrDb: float64): seq[float32] =
  ## `x` plus noise of the power `x`'s has, `snrDb` below it.
  var seed = 12345'u64
  var power = 0.0
  for v in x: power += float64(v) * float64(v)
  power /= float64(x.len)
  let sigma = sqrt(power * pow(10.0, -snrDb / 10))
  result = x
  for i in 0 ..< result.len:
    var sum = 0.0
    for _ in 0 ..< 12:
      seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
      sum += float64(seed shr 11) / float64(1'u64 shl 53)
    result[i] += float32(sigma * (sum - 6.0))

proc against(signals: openArray[(string, seq[float32])]; maxLagMs = 250.0;
    phaseShow = psAbsolute): AnalysisResult =
  correlationOf(signals, ricker(), "the wavelet", DtMs,
    AnalysisParams(maxLagMs: maxLagMs, phaseShow: phaseShow))

proc nanCount(ys: seq[float64]): int =
  for y in ys:
    if y.isNaN: inc result

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState; w: int): bool =
  st.plots.len > w and st.plots[w].result.gen > 0 and not st.plots[w].waiting

proc recordOf(fx: Fixtures; traces: seq[seq[float32]]): string =
  result = fx.dir / "wavelets.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test: a wavelet and copies"]))
  for c, buf in traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(c + 1), 0.0, DtMs * 1000)
    k.status = tsLive
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

template section(name: string; body: untyped) =
  ## `TIMEFIX_ONLY=<name>` runs one section (to see one fail on its own).
  if getEnv("TIMEFIX_ONLY") in ["", name]:
    block:
      body

proc main*() =
  section "rotationsAreSaid":
    for (deg, words) in [(45.0, "rotated 45°"), (90.0, "rotated 90°"), (135.0, "rotated 135°"),
        (180.0, "reversed polarity")]:
      let r = against([("t", ricker().rotated(deg))])
      doAssert r.problem == "", r.problem
      let want = "t: best match 1.00 at 0.0 ms (in step with the reference; " & words & ")"
      doAssert want in r.note, "want: " & want & "\n" & r.note
      doAssert r.table[1][5] == $int(deg), $r.table
      doAssert r.table[1][1].startsWith("1.00"), $r.table
    # a copy in phase says nothing about a rotation
    let same = against([("t", ricker(scale = 0.5))])
    doAssert "t: best match 1.00 at 0.0 ms (in step with the reference)" in same.note, same.note

  section "shiftBetweenSamples":
    let r = against([("late", ricker(delayMs = 3)), ("early", ricker(delayMs = -1))])
    doAssert "late: best match 1.00 at +3.0 ms (arrives 3.0 ms after the reference)" in r.note,
      r.note
    doAssert "early: best match 1.00 at -1.0 ms (arrives 1.0 ms before the reference)" in r.note,
      r.note
    doAssert r.table[1][2] == "+3.0" and r.table[2][2] == "-1.0", $r.table

  section "peakAtTheEdge":
    let r = against([("far", ricker(delayMs = 40))], maxLagMs = 5)
    doAssert "far: no peak within ±6.0 ms: widen the time shifts" in r.note, r.note
    doAssert "Time shifts shown: ±6.0 ms" in r.note, r.note
    doAssert "arrives" notin r.note and "best match" notin r.note, r.note
    doAssert r.table[1][1] == "-" and r.table[1][2] == "-" and r.table[1][4] == "-" and
      r.table[1][5] == "-", $r.table
    doAssert r.plots[2].curves[0].ys.nanCount == r.plots[2].curves[0].ys.len,
      "a phase was drawn for a trace with no peak"

  section "weakMatch":
    let r = against([("n", ricker().noisy(-20))])
    doAssert "n: no clear match (0." in r.note, r.note
    doAssert "arrives" notin r.note and " at " notin r.note.split("\n")[^1], r.note
    doAssert r.table[1][2] == "-" and r.table[1][5] == "-" and r.table[1][1].startsWith("0."),
      $r.table
    doAssert "phase measured unshifted" in r.note, r.note

  section "phaseAfterTheShift":
    let late = ricker(delayMs = 10)
    for show in [psAbsolute, psSigned]:
      let r = against([("late", late)], phaseShow = show)
      let mean = parseFloat(r.table[1][4])
      doAssert abs(mean) < 3.0, "mean phase of a 10 ms copy: " & r.table[1][4]
    let r = against([("late", late)])
    doAssert "phase after removing the time shift" in r.note, r.note

  section "noEarlyEndForACopyOfAWavelet":
    var ripple = ricker(delayMs = 4)
    for i in 0 ..< ripple.len: ripple[i] += float32(1e-7 * sin(float64(i)))
    let r = against([("a", ricker().rotated(90)), ("b", ricker(scale = -1)), ("c", ripple),
      ("d", ricker(delayMs = 10))])
    doAssert r.problem == "" and r.warning == "", "warning: " & r.warning
    let own = correlationOf([("self", ricker().rotated(45))], ricker(), "the wavelet", DtMs,
      AnalysisParams())
    doAssert own.warning == "", own.warning

  section "compareAgreesWithTheCorrelation":
    func slot(samples: seq[float32]; name: string): CompareSlot =
      CompareSlot(filled: true, fileName: name, trace: 1, dtMs: DtMs, t0Ms: 0,
        toMs: 2000, samples: samples)
    let a = slot(ricker(), "a.sgy")
    let turned = ricker().rotated(90)
    let p = pictureOf(a, slot(turned, "b.sgy"), CompareOptions())
    let r = against([("t", turned)])
    let words = r.note.split("\n")[^1]
    doAssert words == "t: " & p.table.matchWords.replace("B is in step with A",
      "in step with the reference"), words & " | " & p.table.matchWords
    doAssert "best match 1.00 at 0.0 ms" in p.table.matchWords and
      "rotated 90°" in p.table.matchWords, p.table.matchWords
    let late = pictureOf(a, slot(ricker(delayMs = 4), "late.sgy"), CompareOptions())
    doAssert "best match 1.00 at +4.0 ms (B lags A by 4.0 ms)" in late.table.matchWords,
      late.table.matchWords
    let early = pictureOf(a, slot(ricker(delayMs = -6), "early.sgy"), CompareOptions())
    doAssert "(B leads A by 6.0 ms)" in early.table.matchWords, early.table.matchWords
    # shifting B by the peak moves it by the match's shift, whatever the rotation
    let moved = pictureOf(a, slot(ricker(delayMs = 4).rotated(90), "both.sgy"),
      CompareOptions(shiftPeak: true))
    doAssert moved.appliedShiftMs == 4.0 and "shifted 4.0 ms (earlier)" in moved.alignNote,
      moved.alignNote

  section "rawAgainstTheReference":
    withFixtures fx:
      var traces = @[ricker()]
      for _ in 0 ..< 3: traces.add ricker()
      let path = fx.recordOf(traces)
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      discard st.chooseStored(fx.dir / "refs", base, "the wavelet")
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[base + 1, base + 2, base + 3])
      let w = st.plots.high
      doAssert st.settle(st.answered(w)), "no answer"
      let off = st.plots[w].result
      doAssert off.table[1][1] == "1.00" and off.warning == "" and
        RawAgainstReference notin off.note, off.note
      st.apply Command(kind: ckProcessing, panel: MainPanel,
        processing: Processing(band: pbBandPass, f1: 20, f2: 25, f3: 35, f4: 40))
      doAssert st.settle(st.answered(w) and "20-25" in st.plots[w].filters), "not filtered"
      let r = st.plots[w].result
      doAssert r.problem == "" and r.warning == "", r.problem & r.warning
      for row in r.table[1 .. ^1]:
        doAssert row[1] == "1.00" and row[3] == "0.0" and row[2] == "0.0", $r.table
      doAssert r.table == off.table, "the numbers changed with the filters"
      doAssert "\n" & RawAgainstReference in r.note and "through" notin r.note, r.note
      # an envelope against the reference, too
      st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[base + 1])
      let e = st.plots.high
      doAssert st.settle(st.answered(e)), "no answer"
      doAssert RawAgainstReference in st.plots[e].result.note, st.plots[e].result.note
      discard st.shutdown()

  section "vibratorRawToo":
    let sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_uncorrelated.sgd"
    doAssert fileExists(sample), sample
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: sample)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      discard st.chooseStored(fx.dir / "refs", base, "intended")
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
        plotTraces: @[base, base + 1, base + 2, base + 3],
        plotParams: AnalysisParams(reactionMassKg: 3600, baseplateMassKg: 1800))
      doAssert st.settle(st.plots.len == 1 and st.answered(0)), "no answer"
      let off = st.plots[0].result
      doAssert off.problem == "" and RawAgainstReference notin off.note, off.problem
      st.apply Command(kind: ckProcessing, panel: MainPanel,
        processing: Processing(band: pbBandPass, f1: 20, f2: 25, f3: 35, f4: 40))
      doAssert st.settle(st.answered(0) and "20-25" in st.plots[0].filters and
        st.plots[0].result.gen > off.gen), "not asked again"
      let r = st.plots[0].result
      doAssert r.problem == "" and r.table == off.table, "the table changed with the filters"
      doAssert RawAgainstReference in r.note, r.note
      discard st.shutdown()

  echo "ttimefix: ok"

when isMainModule:
  main()
