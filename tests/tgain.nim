## The display gain: each gain type's reference amplitude (what is drawn
## full black), which changes read again and which only rescale, the gain
## amount in dB on top of every type, Fixed kept across gathers and files
## and taken again on request, Float following the data in view, and the samples the
## reader sends for Exponential (processSEG's exponential curve and power of
## time, held after the cutoff time) and for Normalized per trace (each
## trace's 99th percentile of |x| at 1), and a new clip percentile: the
## level taken again from the samples the reader holds (no read from the
## file), under the types that take it from the record, the view or each
## trace.
##
## Seen to fail: with the gain amount left out of `displayScale`,
## `amountRescalesWithNoRead` found the scale unchanged at +6 dB; with a
## change of the gain amount reading again (as every display change did),
## it found the scale 0 (the tiles dropped for a read); with Float's level
## kept from the first view, `floatFollowsTheView` found the same level,
## 0.98, on the quiet and the loud part of the record; with Fixed taken
## again from each new record, `fixedHoldsAcrossFiles` found the reference
## changed; with the exponential curve in dB per millisecond,
## `exponentialGain` found trace 0's sample 79 at 0.271 where 0.303 is due;
## with a new clip percentile dropping the tiles for a read (as every change
## of processing does), `clipPercentileFromTheSamples` found "none: the
## picture went while the reader worked".

import std/[algorithm, fenv, math, os, sequtils, strutils]
import parseSEG
import processSEG/gain/curves
from processSEG/core/workspace import initWorkspace
import viewSEG/core/state {.all.}
import viewSEG/core/wiggle
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
  doAssert same(d, e), "the amount, Fixed's amplitude, colours read nothing"
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
  b = a
  b.untilMs = 1500 # the cutoff, for either shape
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
  # ±300 dB, a factor of 1e15 either way. Seen to fail: with `displayScale`
  # giving 0 past what a float32 holds (as it did), "+300 dB on a
  # reference of 1e-30: scale 0.0" (more gain drew mid grey).
  doAssert MaxGainDb == 300
  doAssert DisplaySettings().withGainDb(250).gainDb == 250
  doAssert DisplaySettings().withGainDb(1000).gainDb == MaxGainDb
  doAssert DisplaySettings().withGainDb(-1000).gainDb == -MaxGainDb
  doAssert DisplaySettings().withGainDb(Inf).gainDb == MaxGainDb
  doAssert DisplaySettings().withGainDb(NaN).gainDb == 0
  # At both ends the scale is a finite float32 and every swing a finite
  # number within the overlap; where the scale passes a float32 (+300 dB on
  # a reference of 1e-30) every sample but 0 is full black or white, `a *
  # scale` overflowing to an infinity that the clip takes.
  let lut = greyLut()
  for reference in [1e-30, 1e-12, 1.0, 1e12, 1e30]:
    for db in [-MaxGainDb, MaxGainDb]:
      let scale = displayScale(reference, db)
      doAssert scale.classify in {fcNormal, fcSubnormal, fcZero}, $db & " dB on a reference of " &
        $reference & ": scale " & $scale
      for a in [-3e38'f32, -1e-30'f32, 0'f32, 1e-30'f32, 3e38'f32]:
        let d = swing(a, scale, 2)
        doAssert d.classify in {fcNormal, fcSubnormal, fcZero, fcNegZero} and abs(d) <= 2,
          $db & " dB on a reference of " & $reference & ", " & $a & ": swing " & $d
  let top = displayScale(1e-30, MaxGainDb)
  doAssert top == maximumPositiveValue(float32), "+300 dB on a reference of 1e-30: scale " & $top
  for a in [1e-30'f32, 1'f32, 3e38'f32]:
    doAssert lut.densityColour(a, top) == lut[255] and lut.densityColour(-a, top) == lut[0]
    doAssert swing(a, top, 2) == 2 and swing(-a, top, 2) == -2
  doAssert lut.densityColour(0, top) == lut[128] and swing(0, top, 2) == 0
  doAssert lut.densityColour(3e38, displayScale(1e30, -MaxGainDb)) == lut[128],
    "-300 dB on a reference of 1e30: not mid grey"

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

block exponentialCutoff:
  # The Exponential gain rises until its cutoff time and holds its value
  # after it, for dB per second and for the power of time alike: the
  # samples the reader sends are the file's times processSEG's own curve
  # (`exponentialGain`, `powerGain`) at the time, or at the cutoff past it.
  # The record runs to 998 ms; the cutoff is at 400 ms.
  #
  # Seen to fail: with no hold (the cutoff at 60 s), "dB per second: trace
  # 0 sample 351: -0.2509299, want -0.2036818..."; with the power of time's
  # knots every 20 % of time, "power of time: trace 0 sample 85:
  # 0.023919893, want 0.0240294..." (linear in dB between knots too far
  # apart).
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    for (shape, curve) in [(tgDbPerSecond, exponentialGain(6)), (tgPower, powerGain(2))]:
      var d = st.main.layers[0].display
      d.gain = dgExponential
      (d.timeGain, d.dbPerS, d.power, d.untilMs) = (shape, 6.0, 2.0, 400.0)
      st.display(d)
      doAssert st.settle(st.answered and st.main.layers[0].display.timeGain == shape)
      let t = st.shown[^1]
      doAssert t.request.decimation == 1 and t.request.stride == 1 and t.request.firstSample == 0
      var checked, held = 0
      for row in 0 ..< t.request.count:
        for i in 0 ..< t.columns:
          let raw = surveySample(0, row + 1, i)
          if abs(raw) > 0.1:
            let ms = float64(i) * DtMs
            let want = float64(raw) * curve.factorAt(min(ms, 400))
            doAssert near(float64(t.data[row * t.columns + i]), want, 1e-4),
              $shape & ": trace " & $row & " sample " & $i & ": " &
              $t.data[row * t.columns + i] & ", want " & $want
            inc checked
            if ms > 400: inc held
      doAssert checked > 100 and held > 50, $checked & " " & $held
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

block clipPercentileFromTheSamples:
  # 99 to 90: the reference falls to the 90th percentile of the samples on
  # hand, the tile comes from the reader's samples (no prefetch chunk), and
  # the picture before stays until it comes. Under Float the view's level
  # follows at once; under Normalized per trace each trace's 90th
  # percentile is brought to 1.
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
    doAssert st.settle(st.main.layout.traces > 0)
    st.look()
    var ws = initWorkspace()
    for g in [dgNone, dgFloat, dgNormalized]:
      var d = st.main.layers[0].display
      d.gain = g
      d.normScope = perTrace
      d.normStat = normPercentile
      d.clipPercentile = 99
      st.display(d)
      doAssert st.settle(st.answered and not st.main.reference.isNaN), $g & " never drawn"
      let before = st.main.reference
      let tiles = st.shown.len
      d.clipPercentile = 90
      st.display(d)
      doAssert st.shown.len == tiles, $g & ": the picture went while the reader worked"
      if g == dgFloat:
        doAssert st.main.reference < before, "Float did not follow at once"
      doAssert st.settle(st.answered), $g & ": no tile with the new percentile"
      let t = st.shown[^1]
      doAssert t.cached and t.chunks == 0, $g & ": read from the file (" & $t.chunks & " chunks)"
      if g == dgNormalized:
        doAssert st.main.reference == 1
        for row in 0 ..< t.request.count:
          let l = levelOf(t.data.toOpenArray(row * t.columns, (row + 1) * t.columns - 1), 90, ws)
          doAssert near(l.clip, 1, 0.01), "trace " & $row & ": " & $l.clip
      else:
        let want = levelOf(t.data, 90, ws).clip
        doAssert near(st.main.reference, want, (if g == dgFloat: 0.03 else: 0.01)), $g & ": " & $st.main.reference &
          " for " & $want
        doAssert st.main.reference < 0.9 * before, $g & ": " & $before & " to " &
          $st.main.reference
    st.shutdown()

block deadAndNotANumber:
  # The gain types that run on the samples (AGC, Normalized per trace,
  # Exponential) leave a trace marked dead, or one holding a NaN or an
  # infinite sample, as it is (processSEG's rule). Drawn beside gained
  # traces at its raw amplitude, such a trace would be the loudest on the
  # screen, saturated black and white. A dead trace is never drawn, under
  # any gain type, those that do nothing to the samples included: its row
  # is zero, the tile marks it dead, and the level leaves it out (its
  # zeros would lower the RMS). A sample that is not a number counts as 0,
  # so its trace is gained like its neighbours, and the log says so once.
  #
  # Seen to fail: with the samples handed to the gain as decoded (no
  # blanking), under AGC the dead trace peaked at 999.2 and the NaN and the
  # infinite sample's traces at 993.1, where their neighbours peak at 5.0;
  # with the blanking only when something runs on the samples, under None
  # "none: the dead trace peaks at ..."; with the dead rows left in the
  # level, "AGC: the level's RMS is ..."; with no word of the samples that
  # are not numbers, "no message".
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckOpen, paths: @[fx.deadAndNotANumberSegy()])
    doAssert st.settle(st.main.layout.traces == Channels)
    st.look()
    for g in [dgAgc, dgNormalized, dgExponential, dgNone, dgFixed, dgFloat, dgAuto]:
      var d = st.main.layers[0].display
      d.gain = g
      d.fixedClip = NaN
      st.display(d)
      doAssert st.settle(st.answered), $g
      let t = st.shown[^1]
      doAssert t.request.count == Channels and t.request.decimation == 1
      proc peak(row: int): float64 =
        for i in 0 ..< t.columns: result = max(result, abs(float64(t.data[row * t.columns + i])))
      let neighbours = max(peak(5), peak(7))
      doAssert peak(4) == 0, $g & ": the dead trace peaks at " & $peak(4)
      doAssert t.isDead(4) and t.isBlank(4) and not t.isDead(3), $g
      for row in [6, 10]: # the NaN and the infinite sample's traces
        doAssert peak(row) > 0 and peak(row) < 2 * neighbours,
          $g & ": trace " & $(row + 1) & " peaks at " & $peak(row) & ", its neighbours at " &
          $neighbours
      # the level is the live traces' (the dead one's zeros would lower the RMS)
      var sum = 0.0
      var n = 0
      for row in 0 ..< Channels:
        if row != 4:
          for i in 0 ..< t.columns:
            sum += float64(t.data[row * t.columns + i]) ^ 2
            inc n
      doAssert near(t.level.rms, sqrt(sum / float64(n)), 1e-4),
        $g & ": the level's RMS is " & $t.level.rms & ", the live traces' " & $sqrt(sum / float64(n))
    var said = 0
    for e in st.log:
      if "not numbers" in e.text: inc said
    doAssert said == 1, (if said == 0: "no message" else: $said & " messages")
    st.shutdown()
