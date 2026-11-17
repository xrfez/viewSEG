## The per-trace gain on a record of auxiliary traces of very different
## amplitude (`samples/vib/vib_signature.sgd`: 24 auxiliary traces, the
## ground force near 60 000, the baseplate near 12, the reference sweep near
## 1), headless, on the samples the reader sends:
##
## - Normalized per trace: every trace comes out at the level its statistic
##   names (percentile: its 99th percentile of |x| at 1; RMS: its RMS at 1;
##   peak: its largest |x| at 1), whatever its amplitude, and the quiet tail
##   after the sweep stays quiet;
## - AGC brings every trace to the same size too;
## - the panel's level (`Panel.level`) is still the record's own numbers
##   (the raw ones), which the whole-record scope and Fixed scale by.
##
## Seen to fail: with the display processing run on the seismic traces only
## (processSEG passes an auxiliary trace by), "trace 0 (percentile): its
## 99th percentile is 6e4, want 1".

import std/[algorithm, math, os]
import viewSEG/core/[geometry, state]
import utils/waiting

const
  Sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_signature.sgd"
  Dt = 4.0          # ms
  SweepEnd = 8000.0 # ms: the sweeps end, a second of quiet follows

proc main(st: AppState): lent Panel = st.panel(MainPanel)

proc shown(st: AppState): lent seq[Tile] = st.tiles(st.findPanel(MainPanel))

proc answered(st: AppState): bool =
  st.shown.len > 0 and st.shown[^1].request == st.main.pending and
    st.main.pending.gen == st.main.requestGen

proc quantile(xs: seq[float64]; q: float64): float64 =
  var s = xs
  s.sort
  s[min(s.high, int(q * float64(s.len)))]

proc rowStats(t: Tile; row: int; fromMs, toMs: float64): tuple[rms, peak, p99: float64] =
  ## RMS, largest |x| and 99th percentile of |x| of row `row` between the times.
  var mags: seq[float64]
  var sum = 0.0
  for i in 0 ..< t.columns:
    let ms = float64(i * t.request.decimation) * Dt
    if ms >= fromMs and ms < toMs:
      let v = abs(float64(t.data[row * t.columns + i]))
      mags.add v
      sum += v * v
  (sqrt(sum / float64(max(1, mags.len))), (if mags.len > 0: mags.max else: 0.0),
    (if mags.len > 0: quantile(mags, 0.99) else: 0.0))

proc read(st: var AppState; gain: DisplayGain; stat: NormStat): Tile =
  var d = st.main.layers[0].display
  d.gain = gain
  d.normScope = perTrace
  d.normStat = stat
  d.gainDb = 0
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  doAssert st.settle(st.answered), "nothing drawn"
  st.shown[^1]

proc main*() =
  doAssert fileExists(Sample), Sample
  var st = initAppState()
  st.apply Command(kind: ckOpen, paths: @[Sample])
  doAssert st.settle(st.sessions.len == 1 and st.main.laidOut), "not opened"
  var flt = st.main.layers[0].filter
  flt.auxiliary = true
  st.apply Command(kind: ckFilter, panel: MainPanel, filter: flt)
  doAssert st.settle(st.main.layout.traces > 0), "no traces: " & $st.main.layout.traces
  var v = fitAll(st.main.layout, 800, 600)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)
  doAssert st.settle(st.answered)
  doAssert st.main.layout.traces == 24

  block rawLevelIsTheRecords:
    let t = st.read(dgNone, normPercentile)
    doAssert st.main.level.peak > 5e4, "peak " & $st.main.level.peak
    var big, small = 0
    for row in 0 ..< t.request.count:
      let s = t.rowStats(row, 0, SweepEnd)
      if s.peak > 1e4: inc big
      if s.peak < 100: inc small
    doAssert big == 6 and small >= 12, "the record's traces: " & $big & " big, " & $small

  for (stat, name) in [(normPercentile, "percentile"), (normRms, "RMS"), (normMax, "peak")]:
    block perTraceNormalized:
      # (the tile holds every second sample, the larger one, so the RMS of a
      # tile's row is not the RMS of the trace: the traces are compared with
      # each other, and the exact statistics are those that decimation keeps)
      let t = st.read(dgNormalized, stat)
      doAssert t.request.count == 24, $t.request.count
      var peaks: seq[float64]
      for row in 0 ..< t.request.count:
        let s = t.rowStats(row, 0, SweepEnd)
        let tail = t.rowStats(row, SweepEnd + 100, 9000)
        peaks.add s.peak
        case stat
        of normPercentile: doAssert abs(s.p99 - 1) < 0.05, "trace " & $row & " (" & name &
          "): its 99th percentile is " & $s.p99 & ", want 1"
        of normMax: doAssert abs(s.peak - 1) < 0.05, "trace " & $row & " (" & name &
          "): its peak is " & $s.peak & ", want 1"
        of normRms: doAssert s.peak > 1.2 and s.peak < 2, "trace " & $row & " (" & name &
          "): swings to " & $s.peak & ", the sweep's crest over its RMS is 1.25 to 1.6"
        doAssert tail.peak < 0.2, "trace " & $row & " (" & name & "): its quiet tail reaches " &
          $tail.peak
      let mid = quantile(peaks, 0.5)
      for row, p in peaks:
        doAssert p > mid / 1.3 and p < mid * 1.3, "trace " & $row & " (" & name &
          "): swings to " & $p & " where the traces' middle is " & $mid

  block agcEvensTheTraces:
    let t = st.read(dgAgc, normPercentile)
    for row in 0 ..< t.request.count:
      let s = t.rowStats(row, 1000, 7000)
      doAssert s.rms > 0.1 and s.rms < 10, "AGC, trace " & $row & ": RMS " & $s.rms

  st.shutdown()
  echo "tnormaux: ok"

when isMainModule:
  main()
