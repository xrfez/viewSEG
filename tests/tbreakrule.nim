## The first-break overlay's rule for which traces are "off" (`core/breakrule`), and the
## two-pass picking that feeds it (`core/firstbreakjobs`), on synthetic records:
##
## - a healthy record with 10 ms of scatter flags almost nothing (a fixed 12 ms limit would flag
##   about a quarter of it);
## - one displaced station is off its neighbours, also against a model that bends (the record
##   limit flags the bend, the station rule only the station); a block of 5 is flagged;
## - a source placed 200 ft sideways gives the record's words about the lean and the sign (the
##   side the picks are earliest at); a constant offset gives "every pick is late"; azimuths
##   covering less than a half circle give nothing;
## - far traces whose picks are not breaks are "no break found", never flagged, and do not move
##   the fitted model (a fit to every confident pick is far off);
## - a second segment stays only with enough trimmed picks beyond the crossover and a better fit;
##   fewer picks than the minimum give no trusted model;
## - through the real job on a record with a refracted arrival and far traces whose events
##   are not on the model: the fit is within a few percent of the truth, the picks are the
##   guided pass's, few traces are flagged, and the key's count, the flags and the drawn links
##   are the same number (the key once said 358 of 490 while 3769 traces were drawn flagged).
##
## Seen to fail: with the second pass left out, "b.twoPass" (no second pass); with the trimming
## left out (the closer half and the sigma limit both removed), "kept 300" of 200 and the fit
## following the noise picks; with the lean's sigma taken before the fit, no statement for a 200 ft
## shift; with a fixed 12 ms limit the healthy record's premise ("flags 69") is a sixth of the
## record, against 0 to 4 with the rule; and the 400 m source of `tbreakmodel` shows every trace
## as no break found instead of off.

import std/[math, strutils]
import parseSEG
import viewSEG/core/[breakmodel, breakrule, firstbreakjobs, firstbreaks, geometry, join,
  orientation,
  viewport]
import viewSEG/view/breakbars
import utils/[breakfiles, fixtures]

type Lcg = object
  state: uint64

proc next(r: var Lcg): float64 =
  ## Uniform in [0, 1).
  r.state = r.state * 6364136223846793005'u64 + 1442695040888963407'u64
  float64(r.state shr 11) / 9007199254740992.0

proc normal(r: var Lcg; sigma: float64): float64 =
  ## About normal: the sum of twelve uniforms.
  var s = -6.0
  for i in 0 ..< 12: s += r.next
  s * sigma

proc line(n: int; sigma: float64; seed: uint64): tuple[pick, conf, model, offs: seq[float64]] =
  ## A line of `n` stations: model 20 ms + 0.4 ms a metre, picks with `sigma` of scatter.
  var r = Lcg(state: seed)
  for i in 0 ..< n:
    let x = 100.0 + 10.0 * float64(i)
    result.offs.add x
    result.model.add 20 + 0.4 * x
    result.pick.add result.model[i] + r.normal(sigma)
    result.conf.add 1.0

proc oneLine(n: int): RuleGeometry =
  var ids = newSeq[int](n)
  for i in 0 ..< n: ids[i] = i
  RuleGeometry(eligible: newSeq[bool](0), lines: @[ids], azimuth: newSeq[float64](0))

proc flagCount(r: BreakRule; model, neighbours: bool): int =
  for i in 0 ..< r.flagged.len:
    if (model and r.offModel[i]) or (neighbours and r.offNeighbours[i]): inc result

proc ring(shiftX, constant: float64; spanDeg: float64): tuple[pick, conf, model: seq[float64];
    g: RuleGeometry] =
  ## Receivers round a source recorded at the origin, 8000 ft/s, the real source `shiftX` feet
  ## to +x; each pick `constant` ms late. The azimuths cover `spanDeg`.
  var r = Lcg(state: 7)
  const n = 360
  result.g = RuleGeometry(eligible: @[], lines: @[], azimuth: newSeq[float64](n))
  for i in 0 ..< n:
    let az = (float64(i) / n) * spanDeg * PI / 180
    let radius = 1000.0 + 5.0 * float64(i)
    let (rx, ry) = (radius * cos(az), radius * sin(az))
    let truth = 20 + sqrt((rx - shiftX) ^ 2 + ry ^ 2) / 8000 * 1000
    result.model.add 20 + radius / 8000 * 1000
    result.pick.add truth + constant + r.normal(2)
    result.conf.add 1.0
    result.g.azimuth[i] = az

proc main*() =

  block aHealthyRecordFlagsAlmostNothing:
    let d = line(400, 10, 1)
    let r = applyRule(d.pick, d.conf, d.model, oneLine(400))
    doAssert r.nComparable == 400 and r.nNoBreak == 0
    doAssert abs(r.sigmaMs - 10) < 2, "sigma " & $r.sigmaMs
    doAssert r.limitMs > 26 and r.limitMs < 35, "limit " & $r.limitMs
    var fixed = 0
    for i in 0 ..< 400:
      if abs(d.pick[i] - d.model[i]) > 12: inc fixed
    doAssert fixed > 400 div 10, "the premise: a fixed 12 ms flags " & $fixed
    doAssert r.nFlagged <= 8, "healthy record: " & $r.nFlagged & " flagged"
    doAssert r.statement == {} and statementWords(r) == ""
    doAssert r.nFlagged == r.flagCount(true, true), "the count is the flags"

  block aDisplacedStationIsOffItsNeighboursEvenOnABentModel:
    var d = line(300, 6, 2)
    for i in 0 ..< 300: d.pick[i] += 40 * sin(float64(i) / 40) # the model does not follow
    d.pick[150] += 60
    let r = applyRule(d.pick, d.conf, d.model, oneLine(300))
    doAssert r.offNeighbours[150], "the displaced station"
    doAssert r.flagCount(false, true) <= 2, "off their neighbours: " & $r.flagCount(false, true)
    doAssert abs(d.pick[60] - d.model[60]) > 30, "the premise: the bend is past 12 ms"
    for i in [148, 149, 151, 152]: doAssert not r.offNeighbours[i], "neighbour " & $i

  block aBlockOfSwappedStationsIsFlaggedAndNothingBesideIt:
    var d = line(300, 3, 3)
    for i in 100 ..< 105: d.pick[i] += (if i mod 2 == 0: 60 else: 80)
    let r = applyRule(d.pick, d.conf, d.model, oneLine(300))
    var got: seq[int]
    for i in 0 ..< 300:
      if r.flagged[i]: got.add i
    doAssert got == @[100, 101, 102, 103, 104], "flagged " & $got

  block oneBadStationIsTheOnlyOneFlagged:
    var d = line(300, 3, 8)
    d.pick[150] += 60
    let r = applyRule(d.pick, d.conf, d.model, oneLine(300))
    var got: seq[int]
    for i in 0 ..< 300:
      if r.flagged[i]: got.add i
    doAssert got == @[150], "flagged " & $got

  block aLineOfThreeStationsIsNotJudgedByItsNeighbours:
    var d = line(3, 3, 9)
    d.pick[2] += 50
    let r = applyRule(d.pick, d.conf, d.model, oneLine(3))
    doAssert r.nOffNeighbours == 0, "three stations have too few neighbours"
    doAssert not r.flagged[0] and not r.flagged[1], $r.flagged

  block aSourceShiftedSidewaysGivesTheLeanAndItsSign:
    let east = ring(200, 0, 360)
    let r = applyRule(east.pick, east.conf, east.model, east.g)
    doAssert lkSide in r.statement and lkConstant notin r.statement, $r.statement
    doAssert abs(r.leanMs - 25) < 6, "lean " & $r.leanMs
    # the real source is at +x: the picks are earliest where the receivers are
    doAssert abs(r.earlyTowardDeg) < 15, "earliest towards " & $r.earlyTowardDeg
    # x east, y north: the picks are earliest towards the east, a compass bearing of 90
    doAssert abs(r.earlyBearingDeg - 90) < 15, "bearing " & $r.earlyBearingDeg
    doAssert "towards bearing 9" in statementWords(r) or "towards bearing 8" in statementWords(r),
      statementWords(r)
    doAssert "lean to one side of the source by" in statementWords(r) and
      "may be placed or named wrongly" in statementWords(r), statementWords(r)
    let west = ring(-200, 0, 360)
    let w = applyRule(west.pick, west.conf, west.model, west.g)
    doAssert abs(abs(w.earlyTowardDeg) - 180) < 15, "earliest towards " & $w.earlyTowardDeg
    let late = ring(0, 30, 360)
    let l = applyRule(late.pick, late.conf, late.model, late.g)
    doAssert lkConstant in l.statement and lkSide notin l.statement, $l.statement
    doAssert "every pick is late by 30 ms" in statementWords(l), statementWords(l)
    let early = ring(0, -30, 360)
    doAssert "every pick is early by 30 ms" in statementWords(applyRule(early.pick, early.conf,
      early.model, early.g))
    let healthy = ring(0, 0, 360)
    doAssert applyRule(healthy.pick, healthy.conf, healthy.model, healthy.g).statement == {}
    let part = ring(200, 0, 120)
    doAssert applyRule(part.pick, part.conf, part.model, part.g).statement == {},
      "azimuths over 120 degrees say nothing"

  block farTracesWithoutABreakAreNotFlaggedAndDoNotMoveTheFit:
    var d = line(300, 4, 4)
    for i in 200 ..< 300: d.pick[i] += 300 + float64((i * 97) mod 600) # noise picks, confident
    let fitOn = proc (use: openArray[bool]): seq[float64] =
      let f = lineFit(d.offs, d.pick, use)
      if not f.ok: return @[]
      for x in d.offs: result.add f.interceptMs + f.msPerUnit * x
    var all = newSeq[bool](300)
    for i in 0 ..< 300: all[i] = true
    let raw = fitOn(all)
    doAssert abs(raw[250] - d.model[250]) > 40, "the premise: the fit follows the noise"
    let t = trimmedModel(d.offs, d.pick, d.conf, fitOn)
    doAssert t.trusted and t.used >= 190 and t.used <= 200, "kept " & $t.used
    for i in 0 ..< 300:
      doAssert abs(t.model[i] - d.model[i]) < 3, "the fit follows the noise picks at " & $i
    for i in 200 ..< 300: doAssert not t.kept[i]
    let r = applyRule(d.pick, d.conf, t.model, oneLine(300))
    doAssert r.nNoBreak == 100 and r.nComparable == 200, $r.nNoBreak & " no break found"
    for i in 200 ..< 300: doAssert r.noBreak[i] and not r.flagged[i]
    doAssert r.nFlagged <= 3, "flagged " & $r.nFlagged
    # a trace with no confident pick is no break found too, and never flagged
    d.conf[10] = 0.1
    let q = applyRule(d.pick, d.conf, t.model, oneLine(300))
    doAssert q.noBreak[10] and not q.flagged[10]

  block aSecondSegmentStaysOnlyWhenSupported:
    doAssert not keepSecond(10, 5, 3), "too few beyond the crossover"
    doAssert not keepSecond(40, 5, 4.8), "no better a fit"
    doAssert keepSecond(40, 5, 3)
    doAssert not keepSecond(40, NaN, 3)

  block tooFewPicksGiveNoTrustedModel:
    let d = line(40, 3, 5)
    var conf = d.conf
    for i in 8 ..< 40: conf[i] = 0.2 # 8 confident picks
    let fitOn = proc (use: openArray[bool]): seq[float64] = d.model
    let t = trimmedModel(d.offs, d.pick, conf, fitOn)
    doAssert not t.trusted and t.model.len == 0 and t.used == 8, $t.used
    doAssert trimmedModel(d.offs, d.pick, d.conf, fitOn).trusted
    doAssert not trimmedModel(d.offs, d.pick, d.conf, proc (use: openArray[bool]): seq[float64] =
      @[]).trusted

  block stationsAreTakenAlongTheirLine:
    # points out of file order, two lines, one point unknown
    let lines = [2.0, 1, 2, 1, 2, 1]
    let points = [30.0, 20, 10, 10, 20, 30]
    let eligible = [true, true, true, true, true, false]
    let g = stationLines(lines, points, eligible)
    doAssert g == @[@[3, 1], @[2, 4, 0]], $g
    let unknown = stationLines([NaN, NaN, NaN], [NaN, 3, 1], [true, true, true])
    doAssert unknown == @[@[0, 1, 2]], "an unknown point keeps the file order: " & $unknown

  block theGuideIsContinuousAtTheCrossover:
    let m = BreakModel(source: bmGiven, v1: 2000, interceptMs: 10, v2: 4000, crossover: 1000)
    let gl = guideLines(m)
    doAssert gl.len == 2
    let t1 = gl[0].t0Ms + 1000 * 1000 / gl[0].velocity
    let t2 = gl[1].t0Ms + 1000 * 1000 / gl[1].velocity
    doAssert abs(t1 - t2) < 1e-9 and abs(t1 - m.modelMs(1000)) < 1e-9
    doAssert guideLines(BreakModel(source: bmGiven, v1: 2000)).len == 1
    doAssert guideLines(BreakModel()).len == 0

  block throughTheJobFarNoiseDoesNotSetTheModel:
    # a refracted arrival (2500 m/s, 20 ms) to 2300 m, then 180 traces whose strongest event
    # is 150 to 500 ms off the model (before or after it)
    const n = 400
    withFixtures fx:
      let path = fx.customShot("far.sgy", n, proc (i: int; k: var TraceKeys): float64 =
        k.offset = 100.0 + 10.0 * float64(i)
        let model = 20 + 0.4 * k.offset
        let away = 150.0 + float64((i * 173) mod 350) # an event, but not on the model
        if i < 220: model elif i mod 2 == 0: model + away else: model - away)
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.state == bkDone and b.hasModel and b.twoPass, b.passNote
      doAssert abs(b.fit.v1 - 2500) < 125, "the fit is off: " & $b.fit.v1
      doAssert abs(b.fit.interceptMs - 20) < 15, "the intercept is off: " & $b.fit.interceptMs
      doAssert b.segments == 1 or b.fit.crossover > 1500, "a segment follows the noise"
      let m = b.fitAsModel
      doAssert abs(m.v1 - 2500) < 125 and m.segments == 1, $m
      doAssert b.rule.nBeyond >= 150, "beyond the offsets of the breaks: " & $b.rule.nBeyond
      doAssert b.rule.nFarOff == 0, "far traces beyond the range are no finding"
      doAssert b.rule.nComparable >= 200, "compared: " & $b.rule.nComparable
      doAssert b.rule.nFlagged <= 12, "flagged " & $b.rule.nFlagged
      var shownFlags = 0
      for i in 0 ..< n:
        if b.mismatched(i): inc shownFlags
        if b.rule.noBreak[i] or b.rule.beyond[i]:
          doAssert (not b.mismatched(i)) and (b.faintOf(i) or b.confidenceOf(i) >= ConfidentPick)
      doAssert shownFlags == b.offModel and b.offModel == b.rule.nFlagged
      # drawn: one link a flagged trace, as many as the count
      var shown = newSeq[int](n)
      for i in 0 ..< n: shown[i] = i
      let layout = PanelLayout(traces: n, samples: 1000, dtMs: 2, t0Ms: 0)
      let view = Viewport(traces: Span(lo: -0.5, hi: n.float64 - 0.5),
        timeMs: Span(lo: 0, hi: 2000), columns: 1600, rows: 400)
      let g = breakGeometry(b, shown, layout, view, TimeDown, Rect(pos: vec2(0, 0),
        size: vec2(1600, 400)))
      var links = 0
      for mk in g.marks:
        if mk.kind == bmLink: inc links
      doAssert not g.lines and links == b.offModel, "flagged drawn " & $links & ", counted " &
        $b.offModel
      doAssert "no break found" in b.modelWords(suMetres) and
        "off their neighbours" in b.modelWords(suMetres), b.modelWords(suMetres)

  block aGivenModelsMisfitDoesNotWidenItsLimits:
    # the picks are a healthy 5 ms scatter about the truth; the given model is 10 % slow
    # (the break arrives 0.04 ms a metre earlier than it says). With the limits taken from the
    # scatter about the model shown, the misfit itself sets them and little is flagged.
    var d = line(300, 4, 11)
    var slow: seq[float64]
    for x in d.offs: slow.add 20 + 0.44 * x
    var g = oneLine(300)
    g.ownSigmaMs = 4.0
    let right = applyRule(d.pick, d.conf, slow, g, given = true)
    doAssert right.limitMs == 12 and right.nFlagged > 150 and right.mismatch,
      $right.limitMs & ", flagged " & $right.nFlagged
    g.ownSigmaMs = NaN # the old rule: the scatter about the model shown
    let old = applyRule(d.pick, d.conf, slow, g, given = true)
    doAssert old.nFlagged < right.nFlagged div 2, "the premise: " & $old.nFlagged
    var fast: seq[float64]
    for x in d.offs: fast.add 20 + 0.36 * x
    g.ownSigmaMs = 4.0
    let quick = applyRule(d.pick, d.conf, fast, g, given = true)
    doAssert quick.mismatch and quick.nFlagged > 150, "flagged " & $quick.nFlagged
    let exact = applyRule(d.pick, d.conf, d.model, g, given = true)
    doAssert not exact.mismatch and exact.nFlagged <= 3, "flagged " & $exact.nFlagged

  block throughTheJobAGivenModelThatDoesNotMatchSaysSo:
    const n = 300
    withFixtures fx:
      let path = fx.customShot("given.sgy", n, proc (i: int; k: var TraceKeys): float64 =
        k.offset = 100.0 + 10.0 * float64(i)
        20 + 0.4 * k.offset)
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.hasModel and b.rule.nFlagged <= 3
      for v in [2000.0, 2750.0]:
        let g = b.withModel(BreakModel(source: bmGiven, v1: v, interceptMs: 20))
        doAssert g.rule.mismatch and g.rule.nFlagged > n div 2,
          $v & ": flagged " & $g.rule.nFlagged
        let w = g.modelWords(suMetres)
        doAssert "does not match this record's breaks" in w and "own fit is 25" in w, w
      let ok = b.withModel(BreakModel(source: bmGiven, v1: 2500, interceptMs: 20))
      doAssert not ok.rule.mismatch and "does not match" notin ok.modelWords(suMetres)

  block mostTracesBeyondTheVisibleRangeSayNothingAlarming:
    # 400 traces, 40 within 500 m where the break is seen, 360 beyond it with a confident
    # pick anywhere: the given model is the right one
    var d = line(400, 4, 12)
    for i in 40 ..< 400: d.pick[i] += 150 + float64((i * 61) mod 500)
    var g = oneLine(400)
    g.offsetAbs = d.offs
    g.rangeMax = d.offs[39]
    g.firstMs = d.pick
    g.firstConf = d.conf
    g.ownSigmaMs = 4.0
    let r = applyRule(d.pick, d.conf, d.model, g, given = true)
    doAssert r.nBeyond == 360 and r.nComparable == 40 and r.nFarOff == 0 and r.nNoBreak == 0,
      $r.nBeyond & " beyond, " & $r.nComparable & " compared"
    doAssert not r.mismatch and r.nFlagged <= 1, "flagged " & $r.nFlagged
    g.rangeMax = NaN # the old test: nothing is beyond, so most traces have no break found
    let old = applyRule(d.pick, d.conf, d.model, g, given = true)
    doAssert old.mismatch, "the premise: without a range the model seems not to fit"

  block aCrookedTwoDimensionalLineHasNoLean:
    for wiggle in [0.5, 2.0, 5.0]:
      for seed in [1'u64, 2, 3]:
        var rng = Lcg(state: seed * 7919)
        var p, c, m: seq[float64]
        var g = RuleGeometry()
        for i in 0 ..< 400:
          let x = -4000.0 + 20.0 * float64(i)
          let y = wiggle / 180 * PI * abs(x) * (if (i div 37) mod 2 == 0: 1.0 else: -1.0)
          m.add 20 + hypot(x, y) / 10
          p.add m[^1] + rng.normal(5)
          c.add 1
          g.azimuth.add arctan2(y, x)
        let r = applyRule(p, c, m, g)
        doAssert lkSide notin r.statement, "wiggle " & $wiggle & " seed " & $seed & ": lean " &
          $r.leanMs

  block aFarOffBreakInsideTheRangeIsFlaggedAndOneBeyondIsNot:
    var d = line(300, 4, 13)
    var g = oneLine(300)
    g.offsetAbs = d.offs
    g.rangeMax = d.offs[249]
    g.firstMs = d.pick
    g.firstConf = d.conf
    var conf = d.conf
    for i in 100 ..< 105:
      g.firstMs[i] = d.model[i] + 250 # the first pass found a break far from the model
      conf[i] = 0.1 # the guided window holds none
    for i in 280 ..< 300:
      g.firstMs[i] = d.model[i] + 250
      conf[i] = 0.1
    let r = applyRule(d.pick, conf, d.model, g)
    for i in 100 ..< 105: doAssert r.farOff[i] and r.flagged[i]
    for i in 280 ..< 300: doAssert r.beyond[i] and not r.flagged[i] and not r.farOff[i]
    doAssert r.nFarOff == 5 and r.nFlagged <= 7, $r.nFarOff & ", flagged " & $r.nFlagged

  block throughTheJobFarOffBlocksInsideTheRangeAreFlagged:
    # breaks 95 and 250 ms late on two blocks of five traces inside the range, noise-like
    # events beyond it
    const n = 400
    withFixtures fx:
      let path = fx.customShot("blocks.sgy", n, proc (i: int; k: var TraceKeys): float64 =
        k.offset = 100.0 + 10.0 * float64(i)
        let model = 20 + 0.4 * k.offset
        let away = 150.0 + float64((i * 173) mod 350)
        if i in 100 ..< 105: model + 250
        elif i in 110 ..< 115: model + 95
        elif i < 220: model
        elif i mod 2 == 0: model + away
        else: model - away)
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      for i in 100 ..< 105: doAssert b.mismatched(i), "250 ms late: trace " & $i
      for i in 110 ..< 115: doAssert b.mismatched(i), "95 ms late: trace " & $i
      var far = 0
      for i in 230 ..< n:
        if b.mismatched(i): inc far
      doAssert far == 0, "beyond the range: " & $far & " flagged"
      doAssert b.rule.nFarOff >= 5, "far off the model: " & $b.rule.nFarOff
      doAssert abs(b.differenceMs(102) - 250) < 40, "the link spans the break: " & $b.differenceMs(102)
      doAssert "far off the model" in b.modelWords(suMetres)

  block aBendAtTheCrossoverIsNotACluster:
    # velocity 1 to velocity 2 (continuous) at 1000 m, over 300 traces to 3090 m. A gentle
    # bend (2500 to 3333 m/s) must not leave a cluster flagged at the crossover; the numbers
    # of a strong one (2000 to 4000 m/s) are printed (the fit is then one line, see report)
    const n = 300
    for (s1, s2, strong) in [(0.4, 0.3, false), (0.5, 0.25, true)]:
      let (slope1, slope2) = (s1, s2)
      withFixtures fx:
        let path = fx.customShot("bend.sgy", n, proc (i: int; k: var TraceKeys): float64 =
          k.offset = 100.0 + 10.0 * float64(i)
          if k.offset <= 1000: 20 + slope1 * k.offset
          else: 20 + slope1 * 1000 + slope2 * (k.offset - 1000))
        var f = openSeismic(path, keys = true)
        let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
        f.close()
        var near = 0
        for i in 80 .. 100:
          if b.mismatched(i): inc near
        echo "tbreakrule: bend ", slope1, " to ", slope2, ": segments ", b.segments, ", flagged ",
          b.rule.nFlagged, " of ", b.rule.nComparable, ", ", near, " at the crossover"
        if not strong: doAssert near <= 2, "a cluster of " & $near & " flagged at the crossover"

  echo "tbreakrule: ok"

when isMainModule: main()
