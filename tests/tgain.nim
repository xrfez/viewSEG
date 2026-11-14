## The display gain: each gain type's reference amplitude (what is drawn
## full black), which changes read again and which only rescale, the gain
## amount in dB on top of every type, Fixed kept across gathers and files
## and taken again on request, Float following the data in view, and the samples the
## reader sends for Exponential (processSEG's exponential curve) and for
## Normalized per trace (each trace's 99th percentile of |x| at 1).
##
## Seen to fail: with the gain amount left out of `displayScale`,
## `amountRescalesWithNoRead` found the scale unchanged at +6 dB; with a
## change of the gain amount reading again (as every display change did),
## it found the scale 0 (the tiles dropped for a read); with Float's level
## kept from the first view, `floatFollowsTheView` found the same level,
## 0.98, on the quiet and the loud part of the record; with Fixed taken
## again from each new record, `fixedHoldsAcrossFiles` found the reference
## changed; with the exponential curve in dB per millisecond,
## `exponentialGain` found trace 0's sample 79 at 0.271 where 0.303 is due.

import std/[algorithm, math, os, sequtils]
import parseSEG
import viewSEG/core/state {.all.}
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc shown(st: AppState): lent seq[Tile] = st.tiles(st.findPanel(MainPanel))

proc answered(st: AppState): bool =
  st.shown.len > 0 and st.shown[^1].request == st.main.pending and
    st.main.pending.gen == st.main.requestGen

proc display(st: var AppState; d: DisplaySettings) =
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

proc look(st: var AppState; first = -0.5; last = float64(Channels) - 0.5; t0 = 0.0;
    t1 = 998.0) =
  var v = fitAll(st.main.layout, 800, 600)
  v.traces = Span(lo: first, hi: last)
  v.timeMs = Span(lo: t0, hi: t1)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

func near(a, b: float64; eps = 1e-6): bool = abs(a - b) <= eps * max(1.0, abs(b))

block referencePerType:
  var p = Panel(layers: @[recordLayer(SessionId(1), 0)], kind: gkShot,
    level: Level(rms: 0.2, peak: 3, clip: 1.5), viewLevel: Level(rms: 0.1, peak: 1, clip: 0.4))
  template refOf(g: DisplayGain): float64 =
    p.layers[0].display.gain = g
    p.reference
  doAssert refOf(dgAuto) == 1.5 and refOf(dgAgc) == 1.5 and refOf(dgNone) == 1.5
  doAssert refOf(dgExponential) == 1.5
  doAssert refOf(dgFloat) == 0.4
  doAssert refOf(dgFixed) == 1.5 # nothing kept yet: the record's
  p.layers[0].display.fixedClip = 7
  doAssert refOf(dgFixed) == 7
  doAssert refOf(dgNormalized) == 1 # each trace brought to 1
  p.layers[0].display.normScope = perPanel
  for (stat, want) in [(normRms, 0.2), (normMax, 3.0), (normPercentile, 1.5)]:
    p.layers[0].display.normStat = stat
    doAssert refOf(dgNormalized) == want
  doAssert Panel().reference.isNaN

block whatReadsAgain:
  let d = DisplaySettings()
  template same(a, b: DisplaySettings; kind = gkShot): bool = sameProcessing(a, b, kind)
  var e = d
  e.gainDb = 12
  e.fixedClip = 3
  e.colours = pcTheme
  e.reversed = true
  doAssert same(d, e), "the amount, Fixed's amplitude, colours, polarity read nothing"
  var a, b: DisplaySettings
  for (x, y) in [(dgNone, dgFixed), (dgFixed, dgFloat), (dgNone, dgFloat)]:
    a.gain = x
    b.gain = y
    doAssert same(a, b), $x & " to " & $y & " reads again"
  # Automatic is AGC on shots and none on stacked data
  a.gain = dgAuto
  b.gain = dgAgc
  doAssert same(a, b) and not same(a, b, gkCmp)
  b.gain = dgNone
  doAssert same(a, b, gkCmp) and not same(a, b)
  b = a
  b.agcWindowMs = 250
  doAssert not same(a, b)
  # Normalized: per trace runs on the samples, per panel is a scale alone
  a = DisplaySettings(gain: dgNone)
  b = DisplaySettings(gain: dgNormalized, normScope: perPanel)
  doAssert same(a, b)
  b.normScope = perTrace
  doAssert not same(a, b)
  a = b
  a.normStat = normRms
  doAssert not same(a, b)
  # Exponential: its shape and amount
  a = DisplaySettings(gain: dgExponential)
  b = a
  b.dbPerS = 9
  doAssert not same(a, b)
  b = a
  b.power = 3 # not in use with dB per second
  doAssert same(a, b)
  b.timeGain = tgPower
  doAssert not same(a, b)
  # what each runs on the samples
  for (g, ops) in [(dgNone, 0), (dgFixed, 0), (dgFloat, 0), (dgAgc, 1), (dgExponential, 1),
      (dgNormalized, 1), (dgAuto, 1)]:
    var layer = recordLayer(SessionId(1), 0)
    layer.display.gain = g
    doAssert layer.displayPipeline(gkShot).len == ops, $g
  var layer = recordLayer(SessionId(1), 0)
  layer.display.gain = dgNormalized
  layer.display.normScope = perPanel
  doAssert layer.displayPipeline(gkShot).len == 0
  layer.display.gain = dgExponential
  layer.display.dbPerS = Inf # refused by the control; no curve here either
  doAssert layer.displayPipeline(gkShot).len == 0

block gainAmountLimits:
  doAssert DisplaySettings().withGainDb(200).gainDb == MaxGainDb
  doAssert DisplaySettings().withGainDb(-200).gainDb == -MaxGainDb
  doAssert DisplaySettings().withGainDb(NaN).gainDb == 0

block amountRescalesWithNoRead:
  # Under every gain type: +6 dB doubles the scale (20 log10 2 = 6.02),
  # and nothing is read again.
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    for g in DisplayGain:
      var d = st.main.layers[0].display
      d.gain = g
      d.gainDb = 0
      st.display(d)
      doAssert st.settle(st.answered and not st.main.reference.isNaN), $g & " never drawn"
      let gen = st.main.requestGen
      let ids = st.shown.mapIt(it.id)
      let before = displayScale(st.main.reference, st.main.layers[0].display.gainDb)
      st.display(d.withGainDb(20 * log10(2.0)))
      doAssert st.main.layers[0].display.gainDb == 20 * log10(2.0)
      let after = displayScale(st.main.reference, st.main.layers[0].display.gainDb)
      doAssert near(after, 2 * before, 1e-5), $g & ": " & $before & " became " & $after
      doAssert st.main.requestGen == gen and st.shown.mapIt(it.id) == ids,
        $g & ": the gain amount read again"
    st.shutdown()

block fixedHoldsAcrossFiles:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    var d = st.main.layers[0].display
    d.gain = dgNone
    st.display(d)
    doAssert st.settle(st.answered)
    let first = st.main.level.clip
    let gen = st.main.requestGen
    d.gain = dgFixed
    st.display(d)
    # None to Fixed reads nothing; the amplitude is the record's
    doAssert st.main.requestGen == gen
    doAssert st.main.layers[0].display.fixedClip == first and st.main.reference == first
    # another file (the survey's gathers are alike): its own level, the
    # same reference
    st.apply Command(kind: ckOpen, paths: @[fx.twoSetSegd()])
    doAssert st.settle(st.sessions.len == 2 and st.main.layout.traces > 0 and st.answered)
    doAssert st.main.level.clip != first, "the files have the same level: no test"
    doAssert st.main.reference == first, "Fixed changed with the file"
    # taken again on request, from the record shown
    d = st.main.layers[0].display
    d.fixedClip = NaN
    st.display(d)
    doAssert st.main.reference == st.main.level.clip and st.main.reference != first
    st.shutdown()

block floatFollowsTheView:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    var d = st.main.layers[0].display
    d.gain = dgFloat
    st.display(d)
    doAssert st.settle(st.answered and not st.main.reference.isNaN)
    let whole = st.main.reference
    doAssert near(whole, st.main.viewLevel.clip)
    # the flat reflector alone (half the direct wave's amplitude), then the
    # direct wave alone: each its own level, from the tile already read
    let gen = st.main.requestGen
    st.look(t0 = FlatS * 1000 - 4, t1 = FlatS * 1000 + 1000 / WaveHz + 4,
      first = float64(Channels) - 3.5)
    let flat = st.main.reference
    st.look(first = -0.5, last = 2.5, t0 = 0, t1 = 250)
    let direct = st.main.reference
    doAssert not flat.isNaN and not direct.isNaN
    doAssert flat < 0.75 * direct, "flat " & $flat & ", direct " & $direct
    doAssert st.main.requestGen == gen or st.main.pending.covers(st.main.layout,
      st.main.view, st.main.pending.margin)
    st.shutdown()

block exponentialGain:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    var d = st.main.layers[0].display
    d.gain = dgExponential
    d.dbPerS = 6
    st.display(d)
    doAssert st.settle(st.answered)
    let t = st.shown[^1]
    doAssert t.request.decimation == 1 and t.request.stride == 1
    var checked = 0
    for row in 0 ..< t.request.count:
      for i in 0 ..< t.columns:
        let raw = surveySample(0, row + 1, i)
        if abs(raw) > 0.1:
          let want = float64(raw) * pow(10.0, 6 * (float64(i) * DtMs) / 20_000)
          doAssert near(float64(t.data[row * t.columns + i]), want, 1e-4),
            "trace " & $row & " sample " & $i & ": " & $t.data[row * t.columns + i] & ", want " &
            $want
          inc checked
    doAssert checked > 100, $checked
    st.shutdown()

block normalizedPerTrace:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    var d = st.main.layers[0].display
    d.gain = dgNormalized
    st.display(d)
    doAssert st.settle(st.answered)
    let t = st.shown[^1]
    doAssert st.main.reference == 1
    for row in 0 ..< t.request.count:
      var a: seq[float64]
      for i in 0 ..< t.columns: a.add abs(float64(t.data[row * t.columns + i]))
      a.sort
      let h = float64(a.len - 1) * 0.99
      let k = int(floor(h))
      let p99 = a[k] + (h - float64(k)) * (a[min(k + 1, a.high)] - a[k])
      doAssert near(p99, 1, 1e-4), "trace " & $row & ": " & $p99
    st.shutdown()

proc deadAndNotANumberSegy(fx: Fixtures): string =
  ## The survey's first shot at 1000 times its amplitude, with channel 5
  ## marked dead (its samples as they were), one NaN sample in channel 7 and
  ## one infinite sample in channel 11.
  result = fx.dir / "dead-and-nan.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test: a dead trace, a NaN sample, an infinite sample"]))
  var buf = newSeq[float32](Samples)
  for channel in 1 .. Channels:
    var k = initTraceKeys()
    (k.record, k.channel, k.srcPoint) = (11.0, float64(channel), FirstSrcPoint)
    (k.rcvLine, k.rcvPoint) = (RcvLine, FirstRcvPoint + float64(channel - 1))
    (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, tsLive)
    for i in 0 ..< Samples: buf[i] = 1000 * surveySample(0, channel, i)
    if channel == 5: k.status = tsDead
    if channel == 7: buf[100] = NaN
    if channel == 11: buf[200] = Inf
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

block deadAndNotANumber:
  # The gain types that run on the samples (AGC, Normalized per trace,
  # Exponential) leave a trace marked dead, or one holding a NaN or an
  # infinite sample, as it is (processSEG's rule). Drawn beside gained
  # traces at its raw amplitude, such a trace would be the loudest on the
  # screen, saturated black and white. A dead trace is drawn blank instead,
  # and a sample that is not a number counts as 0, so its trace is gained
  # like its neighbours.
  #
  # Seen to fail: with the samples handed to the gain as decoded (no
  # blanking), under AGC the dead trace peaked at 999.2 and the NaN and the
  # infinite sample's traces at 993.1, where their neighbours peak at 5.0.
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.deadAndNotANumberSegy()])
    doAssert st.settle(st.main.layout.traces == Channels)
    st.look()
    for g in [dgAgc, dgNormalized, dgExponential, dgNone]: # Normalized: per trace
      var d = st.main.layers[0].display
      d.gain = g
      st.display(d)
      doAssert st.settle(st.answered), $g
      let t = st.shown[^1]
      doAssert t.request.count == Channels and t.request.decimation == 1
      proc peak(row: int): float64 =
        for i in 0 ..< t.columns: result = max(result, abs(float64(t.data[row * t.columns + i])))
      let neighbours = max(peak(5), peak(7))
      if g == dgNone:
        # nothing runs on the samples: every trace as it is in the file
        doAssert near(peak(4), peak(3), 0.2) and near(peak(6), neighbours, 0.2), $g
      else:
        doAssert peak(4) == 0, $g & ": the dead trace peaks at " & $peak(4)
        for row in [6, 10]: # the NaN and the infinite sample's traces
          doAssert peak(row) > 0 and peak(row) < 2 * neighbours,
            $g & ": trace " & $(row + 1) & " peaks at " & $peak(row) & ", its neighbours at " &
            $neighbours
    st.shutdown()
