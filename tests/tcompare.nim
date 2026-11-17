## Two traces compared: the numbers, on synthetic samples.
##
## Seen to fail: the correlation peak taken as the first finite sample
## instead of the largest magnitude ("peak 0.000000119" on identical traces,
## not 1); a close that wiped the slots ("the slot followed the close");
## a typed +3 ms shift at 2 ms interpolating a spike of 10 into 5 and 5
## ("spike split") and the chip saying "shifted 3.0 ms" instead of the
## nearest whole sample, 4.0 ms; a reversed trace copied raw ("copied raw",
## ratio 1, and the chip not naming the reversal); the picture replaced on
## the UI thread when the options changed ("replaced on the UI thread");
## with the newer ask not cancelling the running one, "a newer picture ask
## did not cancel the older one"; a 1-sample difference filled while the
## refusal said it was not shown ("difference is not shown").

import std/[math, os, strutils]
import processSEG/core/basic
import processSEG/synth
import viewSEG/core/[compare, state]
import utils/[fixtures, waiting]

proc slot(samples: seq[float32]; dt = 2.0; t0 = 0.0; name = "synthetic.sgy";
    trace = 1): CompareSlot =
  let last = t0 + float64(max(samples.len - 1, 0)) * dt
  CompareSlot(filled: true, fileName: name, path: "/tmp/" & name, trace: trace,
    dtMs: dt, t0Ms: t0, fromMs: t0, toMs: last, samples: samples)

proc tone(n: int; dt, hz: float64): seq[float32] =
  result = newSeq[float32](n)
  for i in 0 ..< n:
    result[i] = float32(sin(2 * PI * hz * float64(i) * dt / 1000.0))

proc slopeOf(hz, phase: openArray[float64]): float64 =
  ## Least-squares slope of the finite phase samples, degrees per Hz.
  var count = 0
  var sx, sy, sxx, sxy = 0.0
  for i in 0 ..< min(hz.len, phase.len):
    if not phase[i].isNaN and not hz[i].isNaN and hz[i] > 5 and hz[i] < 80:
      inc count
      sx += hz[i]
      sy += phase[i]
      sxx += hz[i] * hz[i]
      sxy += hz[i] * phase[i]
  if count < 2: return NaN
  let den = float64(count) * sxx - sx * sx
  if abs(den) < 1e-9: return NaN
  (float64(count) * sxy - sx * sy) / den

var
  holdPicture: Gate
  pictureHeld: Gate

proc pictureHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  ## Holds the compare picture job at its phase, so a newer ask can cancel it.
  discard id
  if phase != "comparing" or back: return
  pictureHeld.open()
  var n = 0
  while not holdPicture.isOpen and n < 30000:
    sleep 1
    inc n

proc main*() =

  block identical:
    let a = tone(256, 2.0, 25.0)
    let p = pictureOf(slot(a, name = "a.sgy"), slot(a, name = "b.sgy", trace = 2),
      CompareOptions())
    doAssert p.table.available, p.table.whyNot
    doAssert abs(p.table.peak - 1.0) < 1e-3, "peak " & $p.table.peak
    doAssert abs(p.table.shiftMs) < 0.5, "shift " & $p.table.shiftMs
    doAssert p.table.polarity == "same", p.table.polarity
    doAssert p.sameGrid
    doAssert p.refusal.len == 0, p.refusal
    var drawn = 0
    for y in p.phase.ys:
      if not y.isNaN:
        inc drawn
        doAssert abs(y) < 1.0, "phase " & $y
    doAssert drawn > 4, "no phase drawn"

  block delayed:
    var a = newSeq[float32](512)
    var b = newSeq[float32](512)
    addRicker(a, 2.0, 200.0, 30.0)
    addRicker(b, 2.0, 208.0, 30.0)
    let p = pictureOf(slot(a), slot(b), CompareOptions())
    doAssert p.table.available, p.table.whyNot
    doAssert abs(p.table.shiftMs - 8.0) < 0.5, "delayed: peak at " & $p.table.shiftMs
    doAssert p.table.peak > 0.9, "delayed: peak " & $p.table.peak
    doAssert p.table.polarity == "same", p.table.polarity
    let slope = slopeOf(p.phase.xs, p.phase.ys)
    # A delay of 8 ms is -360 * f * 0.008 degrees, -2.88 degrees per Hz.
    doAssert not slope.isNaN, "delayed: slope not drawn"
    doAssert abs(slope - (-2.88)) < 0.4, "delayed: slope " & $slope

  block reversed:
    let a = tone(256, 2.0, 25.0)
    var b = a
    reversePolarity(b)
    let p = pictureOf(slot(a), slot(b), CompareOptions())
    doAssert p.table.available, p.table.whyNot
    doAssert p.table.peak < -0.9, "reversed peak " & $p.table.peak
    doAssert abs(p.table.shiftMs) < 0.5, "reversed shift " & $p.table.shiftMs
    doAssert p.table.polarity == "reversed", p.table.polarity

  block differentInterval:
    let a = tone(128, 2.0, 20.0)
    let b = tone(64, 4.0, 20.0)
    let p = pictureOf(slot(a, dt = 2.0), slot(b, dt = 4.0), CompareOptions(difference: true))
    doAssert not p.sameGrid
    doAssert p.refusal.len > 0, "no refusal"
    doAssert "resample" in p.refusal, p.refusal
    doAssert p.difference.ys.len == 0
    doAssert not p.table.available
    doAssert p.signalA.ys.len > 0 and p.signalB.ys.len > 0
    doAssert p.specA.ys.len > 0 and p.specB.ys.len > 0
    doAssert p.phase.ys.len > 0
    let ny = min(500.0 / 2.0, 500.0 / 4.0)
    for f in p.specA.xs:
      doAssert f <= ny + 1e-3, "A past the lower Nyquist: " & $f
    for f in p.specB.xs:
      doAssert f <= ny + 1e-3, "B past the lower Nyquist: " & $f

  block wholeSampleShift:
    # A spike of 10 at sample 10, dt 2 ms. Typed +3 ms is 1.5 samples:
    # interpolation splits it into 5 and 5. The nearest whole sample is 2,
    # 4.0 ms, a bulk move that keeps the 10. Typed -3 ms snaps to -4.0 ms.
    # A shift that runs off the end clips; the gap is zeros.
    var a = newSeq[float32](32)
    var b = newSeq[float32](32)
    b[10] = 10
    let pos = pictureOf(slot(a), slot(b, dt = 2.0), CompareOptions(shiftMs: 3.0))
    doAssert abs(pos.appliedShiftMs - 4.0) < 1e-9, "applied " & $pos.appliedShiftMs
    doAssert "shifted 4.0 ms" in pos.alignNote, pos.alignNote
    doAssert abs(pos.signalB.ys[8] - 10) < 1e-4, "spike split: " & $pos.signalB.ys[7] &
      " " & $pos.signalB.ys[8] & " " & $pos.signalB.ys[9]
    doAssert abs(pos.signalB.ys[7]) < 1e-4 and abs(pos.signalB.ys[9]) < 1e-4
    let neg = pictureOf(slot(a), slot(b, dt = 2.0), CompareOptions(shiftMs: -3.0))
    doAssert abs(neg.appliedShiftMs - (-4.0)) < 1e-9, "applied " & $neg.appliedShiftMs
    doAssert "shifted -4.0 ms" in neg.alignNote, neg.alignNote
    doAssert abs(neg.signalB.ys[12] - 10) < 1e-4, "negative split"
    doAssert abs(neg.signalB.ys[11]) < 1e-4 and abs(neg.signalB.ys[13]) < 1e-4
    var short = newSeq[float32](8)
    short[2] = 10
    let clip = pictureOf(slot(newSeq[float32](8)), slot(short, dt = 2.0),
      CompareOptions(shiftMs: 3.0))
    doAssert abs(clip.appliedShiftMs - 4.0) < 1e-9, "clip applied " & $clip.appliedShiftMs
    doAssert abs(clip.signalB.ys[0] - 10) < 1e-4, "clip did not move the spike"
    doAssert abs(clip.signalB.ys[6]) < 1e-4 and abs(clip.signalB.ys[7]) < 1e-4,
      "the vacated end was not zero"
    let pad = pictureOf(slot(newSeq[float32](8)), slot(short, dt = 2.0),
      CompareOptions(shiftMs: -3.0))
    doAssert abs(pad.appliedShiftMs - (-4.0)) < 1e-9, "pad applied " & $pad.appliedShiftMs
    doAssert abs(pad.signalB.ys[4] - 10) < 1e-4, "negative move lost the spike"
    doAssert abs(pad.signalB.ys[0]) < 1e-4 and abs(pad.signalB.ys[1]) < 1e-4,
      "the vacated start was not zero"
    doAssert abs(appliedShiftMs(3.0, 2.0) - 4.0) < 1e-9
    doAssert abs(appliedShiftMs(-3.0, 2.0) - (-4.0)) < 1e-9
    doAssert appliedShiftMs(NaN, 2.0).isNaN
    doAssert abs(shiftBoxMs(3.0, 4.0, 2.0) - 4.0) < 1e-9
    doAssert abs(shiftBoxMs(3.0, NaN, 2.0) - 4.0) < 1e-9
    doAssert abs(shiftBoxMs(NaN, 4.0, 2.0)) < 1e-9

  block typedShiftStored:
    # The box shows the stored shift. A typed 3 ms at 2 ms is stored as 4.0,
    # and B's chip names that, not 3.0.
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.spectrumSegy())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      st.apply Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: base)
      st.apply Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: base + 1)
      doAssert st.settle(st.compareA.filled and st.compareB.filled and not st.compareWaiting)
      doAssert abs(st.compareB.dtMs - 2.0) < 1e-6, "dt " & $st.compareB.dtMs
      st.apply Command(kind: ckCompareDisplay, compareShow: CompareOptions(shiftMs: 3.0))
      doAssert st.settle(abs(st.compareOptions.shiftMs - 4.0) < 1e-6),
        "stored " & $st.compareOptions.shiftMs
      doAssert "shifted 4.0 ms" in st.compareChip(cwB), st.compareChip(cwB)
      st.shutdown()

  block reversedAsThePlot:
    # The copy is what the plot shows: own reversal, or reverse-all, but not
    # both. Before the fix the first sample stayed raw (ratio 1) and the chip
    # did not name the reversal.
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.spectrumSegy())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      st.apply Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: base)
      doAssert st.settle(st.compareB.filled and st.compareB.samples.len > 0 and
        not st.compareWaiting)
      let raw = st.compareB.samples
      var nonzero = -1
      for i, v in raw:
        if abs(v) > 1e-4:
          nonzero = i
          break
      doAssert nonzero >= 0, "the trace is all zeros"
      proc setA() =
        st.apply Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: base)
        doAssert st.settle(st.compareA.filled and not st.compareA.waiting and
          st.compareA.samples.len == raw.len), "the copy did not arrive"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base],
        on: true)
      setA()
      let ratio = st.compareA.samples[nonzero] / raw[nonzero]
      doAssert abs(ratio + 1.0) < 1e-3, "copied raw, ratio " & $ratio
      doAssert "reversed" in st.compareChip(cwA), st.compareChip(cwA)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base],
        on: false)
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
      setA()
      let allRatio = st.compareA.samples[nonzero] / raw[nonzero]
      doAssert abs(allRatio + 1.0) < 1e-3, "reverse-all copied raw, ratio " & $allRatio
      doAssert "reversed" in st.compareChip(cwA), st.compareChip(cwA)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base],
        on: true)
      setA()
      let both = st.compareA.samples[nonzero] / raw[nonzero]
      doAssert abs(both - 1.0) < 1e-3, "both ways should stay as recorded, ratio " & $both
      doAssert "reversed" notin st.compareChip(cwA), st.compareChip(cwA)
      st.shutdown()

  block differenceAgrees:
    # Two 1-sample traces: the correlation cannot be formed. The difference
    # is a subtract and is filled. The refusal must not say it is hidden.
    var a = @[1'f32]
    var b = @[4'f32]
    let p = pictureOf(slot(a), slot(b), CompareOptions(difference: true))
    doAssert p.difference.ys.len == 1, "difference len " & $p.difference.ys.len
    doAssert abs(p.difference.ys[0] - 3.0) < 1e-6, $p.difference.ys
    doAssert "difference is not shown" notin p.refusal, p.refusal
    doAssert p.correlation.ys.len == 0
    doAssert p.table.whyNot.len > 0, "no reason for the missing correlation"

  block chip:
    let s = slot(tone(11, 2.0, 10.0), name = "shot.sgy", trace = 4)
    doAssert chipText(s, cwA) == "A: shot.sgy, trace 4, 0.000-0.020 s", chipText(s, cwA)
    var filtered = s
    filtered.filtered = true
    doAssert "own filter" in chipText(filtered, cwB, "shifted 8.0 ms"), chipText(filtered, cwB)

  block survivesCloseAndSelection:
    # A slot is a copy. Closing the file, and changing the selection, leave it.
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.spectrumSegy())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      let name = st.sessions[0].name
      st.apply Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: base)
      st.apply Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: base + 1)
      doAssert st.settle(st.compareA.filled and st.compareB.filled and not st.compareWaiting),
        "the copies did not arrive"
      doAssert st.compareOpen, "filling the second slot did not open the window"
      let kept = st.compareA.samples.len
      let chip = st.compareChip(cwA)
      doAssert name in chip, chip
      doAssert kept > 0
      st.apply Command(kind: ckSelect, traces: @[base + 3], mode: smReplace)
      doAssert st.compareA.samples.len == kept and st.compareA.fileName == name
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0)
      doAssert st.compareA.filled and st.compareA.samples.len == kept, "the slot followed the close"
      doAssert st.compareB.filled and st.compareB.trace == 2
      doAssert st.compareChip(cwA) == chip
      st.shutdown()

  block pictureOnAJob:
    # The picture is computed off the UI thread. The one on screen stays until
    # the new one arrives. A newer ask cancels the one already running.
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.spectrumSegy())
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let base = st.sessions[0].base
      st.apply Command(kind: ckSetCompare, compareSlot: cwA, compareTrace: base)
      st.apply Command(kind: ckSetCompare, compareSlot: cwB, compareTrace: base + 1)
      doAssert st.settle(st.compareA.filled and st.compareB.filled and
        st.comparePicture.signalA.ys.len > 0 and st.comparePicture.signalB.ys.len > 0)
      let firstRev = st.compareRevision
      let firstNote = st.comparePicture.alignNote
      holdPicture.close()
      pictureHeld.close()
      setJobHook(pictureHook)
      try:
        var opt = st.compareOptions
        opt.flip = true
        st.apply Command(kind: ckCompareDisplay, compareShow: opt)
        doAssert st.compareRevision == firstRev, "the picture was replaced on the UI thread"
        doAssert st.comparePicture.alignNote == firstNote
        doAssert waitUntil(pictureHeld.isOpen), "the picture was not computed on a job"
        var running = NoJob
        for j in st.jobs.active:
          if j.state == jsRunning and j.spec.title == "Compare the two traces":
            running = j.id
        doAssert running != NoJob, "no compare picture job was running"
        opt.difference = true
        st.apply Command(kind: ckCompareDisplay, compareShow: opt)
        let info = st.jobs.info(running)
        doAssert info.isSome and info.get.cancelRequested,
          "a newer picture ask did not cancel the older one"
        doAssert st.compareRevision == firstRev, "the previous picture was dropped"
        holdPicture.open()
        doAssert st.settle(st.compareRevision > firstRev and
          "polarity flipped" in st.comparePicture.alignNote), st.comparePicture.alignNote
        doAssert st.comparePicture.difference.ys.len > 0, "the newer ask was not the one drawn"
      finally:
        holdPicture.open()
        setJobHook(nil)
      st.shutdown()

  echo "tcompare: ok"

when isMainModule:
  main()
