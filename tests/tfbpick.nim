## What the first-break job's guided passes read (`core/firstbreakjobs`, `PickBasis`): a
## synthetic shot whose first break builds over some 40 ms (a 25 Hz zero-phase wavelet whose
## main lobe lies 36 ms after its onset, in noise of four levels, and on a third of the
## traces a later event three times as strong 60 ms after the first lobe) is picked on a
## zero-phase high-cut copy of each trace and on the samples as recorded; the copy gives picks
## nearer the onset and more of them confident, and no pick before the onset. The loaded
## samples are not changed; the cut follows the sample interval's Nyquist frequency and is
## left out, with a word, at an interval that leaves no room for it and on traces too short
## for the filter.
##
## Measured on the shot (pick less onset, ms; 60 traces): smoothed median 12, 54 confident,
## earliest +6; as recorded median 14, 39 confident, earliest +4.
##
## Seen to fail: with the smoothing off (the plan never used), "smoothing gave no nearer
## picks" and "smoothing gave no more confident picks"; with the copy filtered in place
## (no `clone`), "the loaded samples changed"; with the cut at the Nyquist frequency instead
## of 0.8 of it, "the 8 ms record's cut".

import std/[algorithm, math, strutils]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/filter/[design, iir]
import viewSEG/core/[breakmodel, breakrule, firstbreakjobs, firstbreaks]
import viewSEG/core/panels
import utils/[breakfiles, fbpickfiles, fixtures]

type Stats = tuple[median, earliest: float64; confident, picked: int; b: FirstBreaks]

proc pickedOn(path: string; basis: PickBasis): Stats =
  var f = openSeismic(path, keys = true)
  result.b = breaksOfRecord(addr f, path, 0 ..< f.len, [], pick = basis)
  f.close()
  var errs: seq[float64]
  for i in 0 ..< FbTraces:
    if not result.b.pickOf(i).isNaN:
      errs.add result.b.pickOf(i) - onsetMs(i)
    if result.b.confidenceOf(i) >= ConfidentPick: inc result.confident
  errs.sort()
  result.picked = errs.len
  if errs.len > 0: (result.median, result.earliest) = (errs[errs.len div 2], errs[0])

proc main*() =

  block smoothedPicksAreNearerTheOnsetAndMoreOfThemConfident:
    withFixtures fx:
      let path = fx.fbShot("slow.sgy")
      let smooth = pickedOn(path, pbSmoothed)
      let raw = pickedOn(path, pbAsRecorded)
      doAssert smooth.b.pickedOn == pbSmoothed and smooth.b.highCutHz == 60 and
        smooth.b.pickWindowMs == GuidedWindowMs and smooth.b.pickNote == "",
        $smooth.b.pickedOn & " " & $smooth.b.highCutHz
      doAssert raw.b.pickedOn == pbAsRecorded and raw.b.highCutHz == 0
      doAssert smooth.picked == FbTraces and raw.picked == FbTraces
      # measured: 12 against 14 ms, 54 against 39 confident (headroom: 1 ms, 8 traces)
      doAssert smooth.median <= raw.median - 1,
        "smoothing gave no nearer picks: " & $smooth.median & " against " & $raw.median
      doAssert smooth.confident >= raw.confident + 8,
        "smoothing gave no more confident picks: " & $smooth.confident & " against " &
        $raw.confident
      # the zero-phase copy's precursor: measured, no pick before the onset; bounded at 4 ms
      doAssert smooth.earliest >= -4, "a pick " & $(-smooth.earliest) & " ms before the onset"
      doAssert raw.earliest >= -4
      doAssert smooth.median <= 16, "the median pick is " & $smooth.median & " ms after the onset"

  block theLoadedSamplesAreNotChanged:
    withFixtures fx:
      let path = fx.fbShot("keep.sgy")
      var f = openSeismic(path, keys = true)
      var log: DiagLog
      let samples = f.readTraces(0 ..< 30, 0 ..< 1500, log)
      var before = newSeq[float32](30 * 1500)
      for r in 0 ..< 30:
        for c in 0 ..< 1500: before[r * 1500 + c] = samples[r, c]
      let plan = initIirPlan(float32, butterHighCut(60, 24), 2.0, 1500, ipZero)
      var ws = initWorkspace()
      ws.reserve(plan.workspaceSize)
      var keys: seq[TraceKeys]
      var counts: seq[int]
      for r in 0 ..< 30:
        keys.add f.index.keys[r]
        counts.add 1500
      let copy = smoothedCopy(samples, initChunkMeta(rowsOf(keys, counts), 2.0, 0, @[]), plan, ws)
      var same, copied = true
      var moved = 0.0
      for r in 0 ..< 30:
        for c in 0 ..< 1500:
          if samples[r, c] != before[r * 1500 + c]: same = false
          moved = max(moved, abs(copy[r, c] - before[r * 1500 + c]))
      doAssert same, "the loaded samples changed"
      doAssert moved > 0.01, "the copy was not filtered (" & $moved & ")"
      f.close()
      # picking the file again reads it as it was
      discard pickedOn(path, pbSmoothed)
      var g = openSeismic(path, keys = true)
      let again = g.readTraces(0 ..< 30, 0 ..< 1500, log)
      for r in 0 ..< 30:
        for c in 0 ..< 1500: doAssert again[r, c] == before[r * 1500 + c]
      g.close()

  block theCutFollowsTheNyquistFrequency:
    doAssert pickCutHz(1) == 60 and pickCutHz(2) == 60 and pickCutHz(4) == 60
    doAssert pickCutHz(8) == 50, "the 8 ms record's cut: " & $pickCutHz(8)
    doAssert pickCutHz(12) == 0 and pickCutHz(16) == 0 and pickCutHz(0).isNaN == false
    doAssert pickCutHz(NaN) == 0 and pickCutHz(-2) == 0 and pickCutHz(Inf) == 0
    withFixtures fx:
      let eight = pickedOn(fx.fbShot("dt8.sgy", dtMs = 8, samples = 375), pbSmoothed)
      doAssert eight.b.pickedOn == pbSmoothed and eight.b.highCutHz == 50 and
        eight.b.pickNote == "", $eight.b.highCutHz & " " & eight.b.pickNote
      let four = pickedOn(fx.fbShot("dt4.sgy", dtMs = 4, samples = 750), pbSmoothed)
      doAssert four.b.highCutHz == 60 and four.b.pickedOn == pbSmoothed
      let twelve = pickedOn(fx.fbShot("dt12.sgy", dtMs = 12, samples = 250), pbSmoothed)
      doAssert twelve.b.pickedOn == pbAsRecorded and twelve.b.highCutHz == 0 and
        "sample interval" in twelve.b.pickNote and "as recorded" in twelve.b.pickNote,
        twelve.b.pickNote
      doAssert twelve.picked > 0, "no pick on the unsmoothed record"
      let asked = pickedOn(fx.fbShot("dt12b.sgy", dtMs = 12, samples = 250), pbAsRecorded)
      doAssert asked.b.pickNote == "", "nothing was asked, nothing to say"

  block tracesTooShortForTheFilterAreNotSmoothed:
    withFixtures fx:
      let short = pickedOn(fx.fbShot("short.sgy", samples = 12, later = false), pbSmoothed)
      doAssert short.b.pickedOn == pbAsRecorded and "too short" in short.b.pickNote,
        short.b.pickedOn.repr & " " & short.b.pickNote

  block aTraceWithANonFiniteSampleIsPickedAsRecorded:
    # the filter runs forward and backward, so one NaN turns the whole smoothed trace to NaN:
    # such a trace is picked on its samples as recorded, and the others are not touched.
    # Seen to fail: with every trace smoothed, "trace 5 has no pick on its raw samples" (its
    # smoothed copy is NaN).
    withFixtures fx:
      let clean = pickedOn(fx.fbShot("clean.sgy"), pbSmoothed)
      let nan = pickedOn(fx.fbShot("nan.sgy", nanTrace = 5), pbSmoothed)
      let raw = pickedOn(fx.fbShot("nanraw.sgy", nanTrace = 5), pbAsRecorded)
      var moved = 0
      for i in 0 ..< FbTraces:
        if i != 5 and abs(nan.b.pickOf(i) - clean.b.pickOf(i)) > 4: inc moved
      doAssert moved <= 1, $moved & " other traces changed their pick"
      doAssert not raw.b.pickOf(5).isNaN, "the raw trace has no pick at all"
      doAssert not nan.b.pickOf(5).isNaN, "trace 5 has no pick on its raw samples"
      doAssert abs(nan.b.pickOf(5) - raw.b.pickOf(5)) <= 4, "trace 5 is not picked as recorded: " &
        $nan.b.pickOf(5) & " against " & $raw.b.pickOf(5)

  block theResultSaysWhatTheShownPicksWereMadeOn:
    # without offsets there is no model and no guided pass: the first pass's picks are shown,
    # whatever was asked; with one, the guided passes'. Seen to fail: with the fields set from
    # the choice, "the first pass's picks are said to be smoothed".
    withFixtures fx:
      let none = pickedOn(fx.shotSegy("nooffsets.sgy", gNothing), pbSmoothed)
      doAssert none.b.pickedOn == pbAsRecorded and none.b.highCutHz == 0 and
        none.b.pickWindowMs == FirstPassWindowMs and not none.b.twoPass,
        "the first pass's picks are said to be smoothed: " & $none.b.pickedOn
      let guided = pickedOn(fx.fbShot("guided.sgy"), pbSmoothed)
      doAssert guided.b.twoPass and guided.b.pickedOn == pbSmoothed and
        guided.b.pickWindowMs == GuidedWindowMs
      doAssert FirstBreaks().pickedOn == pbAsRecorded and
        FirstBreaks().pickWindowMs == FirstPassWindowMs
      doAssert DisplaySettings().breakPickOn == pbSmoothed

  echo "tfbpick: ok"

when isMainModule:
  main()
