## The first-break overlay's rule for which traces are "off" (`core/breakrule`), and the
## two-pass picking that feeds it (`core/firstbreakjobs`), on synthetic records:
##
## - a healthy record with 10 ms of scatter flags almost nothing (a fixed 12 ms limit would flag
##   about a quarter of it), over many seeds too;
## - one displaced station is off its neighbours, also against a model that bends (the record
##   limit flags the bend, the station rule only the station), and one trace 15 ms off flat
##   neighbours is still flagged; inside a stretch the model misses
##   and at a bend it misses; a block of 5 is flagged and nothing beside it; far-off traces are
##   no neighbours (two noise picks next to a record's end do not flag the end trace; a good
##   trace among far-off noise with too few comparable neighbours is not judged), but the
##   shoulder of a far-off drift that departs the same way is not off its neighbours (15 ms the
##   other way is; one far-off trace is no drift);
## - a source placed 200 ft sideways gives the record's words about the lean and the sign (the
##   side the picks are earliest at), also against the scatter about the record's own fit; a
##   constant offset gives "every pick is late"; azimuths covering less than a half circle give
##   nothing; a given model that does not match says nothing of the source;
## - far traces whose picks are not breaks are "no break found" or beyond the range, never
##   flagged, and do not move the fitted model (a fit to every confident pick is far off); the
##   range ends at the farthest offsets where enough comparable breaks are seen, across a
##   stretch of noise or dead traces with breaks beyond it (whose traces are judged, never
##   beyond), and never past most picks both passes agree on, so noise the guided window held,
##   or a far half of noise alone, does not widen it; a comparable pick is strictly inside the
##   band, and a guided pick on its search's first sample (the record-fit pass searching round a
##   model a few ms off the one it is judged against, at 1, 2 and 4 ms) is no break: the first
##   pass decides (a confident first-pass pick inside the band is compared, so a block 18 ms
##   early is off the model; one not confident is no pick); "far off" is a first-pass pick
##   outside the guided window (100 ms when it is not set) and at most 400 ms from the model,
##   never one before the first possible arrival; the guided window is four sigmas of the fit's
##   scatter, at least 20 ms and at most 100 ms (100 ms when the scatter is not known): a burst
##   60 ms before a tight record's break is outside it, a wide scatter keeps 100 ms, and a 60 ms
##   first-pass miss under a 20 ms window is far off, not no break;
## - the record's own fit as a given model matches even where few breaks are seen;
## - a second segment stays only with enough trimmed picks beyond the crossover and a better fit,
##   or when it holds clearly more of all the confident picks: a bend whose second segment holds
##   most picks is two segments, a straight line one; fewer picks than the minimum give no
##   trusted model;
## - through the real job on a record with a refracted arrival and far traces whose events
##   are not on the model: the fit is within a few percent of the truth, the picks are the
##   guided pass's, few traces are flagged, and the key's count, the flags and the drawn links
##   are the same number (the key once said 358 of 490 while 3769 traces were drawn flagged).
##
## Seen to fail: with the second pass left out, "b.twoPass" (no second pass); with the trimming
## left out (the closer half and the sigma limit both removed), "kept 300" of 200 and the fit
## following the noise picks; with the lean's sigma taken before the fit, no statement for a 200 ft
## shift; with a fixed 12 ms limit the healthy record's premise ("flags 69") is a sixth of the
## record, against 0 to 4 with the rule; the 400 m source of `tbreakmodel` shows every trace
## as no break found instead of off; with the range the 98th percentile of the kept picks'
## offsets, "the range ends at 3750"; with far off unbounded, "trace 200 is noise, not far off",
## and without the intercept's bound "trace 10 is noise"; with the mismatch test "fewer than half
## of the traces in range compared", "the record's own fit does not match"; with the source's bar
## from the picks' own scatter, "200 ft: lean 25, nothing said"; with the source sentence kept
## under a mismatch, "the picks lean to one side ... every pick is early by 59 ms"; with the
## neighbour rule leaving off-model traces out (and the nearer side alone), "healthy record: 5
## flagged" (and `tfirstbreaks`' 80 ms drift off its neighbours); without the support test for a
## second segment, "bend 0.4 to 0.3: one segment"; with the guided window left at 100 ms, "the
## burst 60 ms before the break was picked" and "60 ms off is no break, not far off"; with the
## edge pick kept on the record-fit pass, "1 ms: trace 20 compared at -14.0 ms" (-14.1 at 2 ms,
## -16.0 at 4 ms); with far off taken only beyond the band, "a first-pass pick on the edge is no
## break"; with far-off traces' first-pass picks among the neighbours, "end trace 0 off its
## neighbours" (and 11); without the shoulder's excuse, "the shoulder is off its neighbours";
## with the range ending at the first bin where few breaks are seen, "the range ends at 1102.5"
## for the dead stretch (and 613.5 for the unit case); without the cap of the agreed picks,
## "the range ends at 1715.0" for the far half of noise and "2450.0" for the trailing noise;
## without the first pass's pick when the guided one is rejected, "trace 8 is not compared on its
## first-pass pick" and "1 ms: trace 20 not compared on its first-pass pick"; with that pick's
## confidence not asked, "trace 30 is compared".

import std/[math, os, strutils]
import parseSEG
import processSEG/synth
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

func scatterShift(i: int; jitter: float64): float64 =
  ## Alternating `jitter`, and half as much again on every tenth trace.
  let sign = if i mod 2 == 0: 1.0 else: -1.0
  let extra = if i mod 10 == 0: 0.5 * jitter elif i mod 10 == 1: -0.5 * jitter else: 0.0
  sign * jitter + extra

func scatterArrival(i: int; jitter: float64): float64 =
  ## The break of `scatterShot` trace `i`: `180 + 0.4 x` plus `scatterShift`.
  180.0 + 0.4 * (200.0 + 25.0 * float64(i)) + scatterShift(i, jitter)

proc scatterShot(fx: Fixtures; name: string; traces: int; jitter: float64; burst: bool): string =
  ## Offsets `200 + 25 i` m, the break at `scatterArrival`. When `burst`, every eighth trace
  ## also has a wavelet four times as strong 60 ms before the break.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break rule test: " & name]))
  var buf = newSeq[float32](breakfiles.Samples)
  for i in 0 ..< traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      Dt * 1000, tsLive)
    k.offset = 200.0 + 25.0 * float64(i)
    let at = scatterArrival(i, jitter)
    for j in 0 ..< buf.len: buf[j] = 0
    buf.addRicker(Dt, at + 15, 30, 1.0)
    if burst and i mod 8 == 0: buf.addRicker(Dt, at - 60 + 15, 30, 4.0)
    buf.addNoise(0.03, int64(i + 1))
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log

proc tightBurstStaysOut(b: FirstBreaks; n: int; what: string) =
  ## The guided pass never takes the burst 60 ms before the break (`pickMs`, not `pickOf`: a
  ## far-off trace shows the first pass, which did take the burst). Its energy fills the
  ## picker's lead-in, so the guided pick of a burst trace is the window's last sample at no
  ## confidence (dropped: the window clamping) or, when confident, the break.
  doAssert b.twoPass and b.hasModel, what & b.passNote
  doAssert b.geometry.guideWindowMs == GuideMinMs, what & "window " & $b.geometry.guideWindowMs
  doAssert "20 to 400" in b.modelWords(suMetres), b.modelWords(suMetres)
  for i in countup(0, n - 1, 8):
    let at = scatterArrival(i, 2.0)
    let pick = b.pickMs[i]
    doAssert pick.isNaN or abs(pick - (at - 60)) > 25,
      what & "the burst 60 ms before the break was picked"
    doAssert pick.isNaN or b.confidence[i] < ConfidentPick or abs(pick - at) < 30,
      what & "trace " & $i & " pick " & $pick & " not the break at " & $at
    doAssert not b.rule.comparable[i] or abs(pick - at) < 30, what & "trace " & $i

proc twoEventShot(fx: Fixtures; name: string; traces: int;
    events: proc (i: int): (float64, float64); second = 1.0): string =
  ## A shot of `traces` traces at `100 + 10 i` m, each with two wavelets at the times `events`
  ## gives (NaN for none), the second `second` as strong as the first, in a little noise.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break rule test: " & name]))
  var buf = newSeq[float32](breakfiles.Samples)
  for i in 0 ..< traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      Dt * 1000, tsLive)
    k.offset = 100.0 + 10.0 * float64(i)
    for j in 0 ..< buf.len: buf[j] = 0
    let (a, b) = events(i)
    if not a.isNaN: buf.addRicker(Dt, a + 15, 30, 1.0)
    if not b.isNaN: buf.addRicker(Dt, b + 15, 30, second)
    buf.addNoise(0.03, int64(i + 1))
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log

proc main*() =

  block guideWindowMsFollowsTheScatter:
    doAssert guideWindowMs(NaN) == GuideMaxMs
    doAssert guideWindowMs(0) == GuideMaxMs
    doAssert guideWindowMs(-4) == GuideMaxMs
    doAssert guideWindowMs(-Inf) == GuideMaxMs
    doAssert guideWindowMs(Inf) == GuideMaxMs
    doAssert guideWindowMs(3) == GuideMinMs
    doAssert guideWindowMs(GuideMinMs / GuideSigmas) == GuideMinMs
    doAssert guideWindowMs(12.5) == 50
    doAssert guideWindowMs(GuideMaxMs / GuideSigmas) == GuideMaxMs
    doAssert guideWindowMs(40) == GuideMaxMs

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
    doAssert r.nFlagged <= 4, "healthy record: " & $r.nFlagged & " flagged"
    # and over many records: the neighbour rule adds next to nothing to the model's 3 sigmas
    var worst, neighbours = 0
    for seed in 1'u64 .. 60:
      let h = line(400, 10, seed * 7919)
      var g = oneLine(400)
      g.ownSigmaMs = 10
      let q = applyRule(h.pick, h.conf, h.model, g)
      worst = max(worst, q.nFlagged)
      neighbours += q.nOffNeighbours
    doAssert worst <= 4 and neighbours <= 6, "healthy records: worst " & $worst & " flagged, " &
      $neighbours & " off their neighbours in 60"
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

  block aTrace15MsOffFlatNeighboursIsFlagged:
    # the station rule's own case: one trace 15 ms off a flat line is still flagged
    var d = line(40, 0, 1)
    d.pick[20] += 15
    let r = applyRule(d.pick, d.conf, d.model, oneLine(40))
    doAssert r.offNeighbours[20], "15 ms off flat neighbours was not flagged"
    doAssert r.nOffNeighbours == 1, $r.nOffNeighbours

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
      doAssert b.geometry.rangeMax < 2500, "the range ends at " & $b.geometry.rangeMax
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

  block throughTheJobNoiseInTheGuidedWindowDoesNotWidenTheRange:
    # breaks to 2290 m (2500 m/s, 20 ms); beyond, each trace has an event 200 to 400 ms before
    # the model (which the first pass picks) and one within 90 ms of it (which the guided pass
    # picks, and the trim keeps on some traces): only picks both passes agree on make the range
    const n = 400
    withFixtures fx:
      let path = fx.twoEventShot("window.sgy", n, proc (i: int): (float64, float64) =
        let model = 20 + 0.4 * (100.0 + 10.0 * float64(i))
        if i < 220: (model, NaN)
        else: (model - 200 - float64((i * 37) mod 200), model - 90 + float64((i * 53) mod 180)),
        second = 0.4)
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.hasModel and abs(b.fit.v1 - 2500) < 125, $b.fit.v1
      doAssert b.geometry.rangeMax < 2500, "the range ends at " & $b.geometry.rangeMax
      var far = 0
      for i in 230 ..< n:
        if b.mismatched(i): inc far
      doAssert far == 0, $far & " noise traces beyond the breaks flagged"
      doAssert b.rule.nFlagged <= 6, "flagged " & $b.rule.nFlagged

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
    g.rangeMax = NaN # without a range, the confident noise picks near the model are judged
    let old = applyRule(d.pick, d.conf, d.model, g, given = true)
    doAssert old.nFarOff > 100, "the premise: without a range noise is far off: " & $old.nFarOff

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

  block theRangeEndsWhereTheTwoPassesStopAgreeing:
    # 400 traces to 4090 m: breaks both passes agree on for half the traces out to 2000 m, and
    # beyond it a guided pick near the model on 1 trace in 4 (noise the window held, which the
    # first pass did not see there): more than a fifth, so only the agreed picks end the range.
    # The old rule, the 98th percentile of the kept picks' offsets, ran to the far end. (Here
    # the picks seen near the model are those kept.)
    var offs: seq[float64]
    var eligible, kept, agreed: seq[bool]
    for i in 0 ..< 400:
      offs.add 100.0 + 10.0 * float64(i)
      eligible.add true
      let near = offs[i] <= 2000
      kept.add (if near: i mod 2 == 0 else: i mod 4 == 0)
      agreed.add near and i mod 2 == 0
    let r = expectedRange(offs, eligible, kept, agreed)
    doAssert r >= 1900 and r <= 2100, "the range ends at " & $r
    var held: seq[float64]
    for i in 0 ..< 400:
      if kept[i]: held.add offs[i]
    doAssert held[int(0.98 * float64(held.len)) - 1] > 3500, "the premise"
    doAssert expectedRange(offs, eligible, kept, kept) > 3500, "guided picks alone: the far end"
    # a range with no supported pick has no end; neither a stretch where few breaks are seen
    # (noise, dead traces) nor one the passes do not agree on (breaks the model misses) ends it
    # while supported picks go on beyond it
    doAssert expectedRange(offs, eligible, kept, newSeq[bool](400)).isNaN
    var gap = kept
    for i in 50 ..< 100: gap[i] = false
    doAssert expectedRange(offs, eligible, gap, agreed) >= 1900,
      "a stretch where few breaks are seen, with agreed picks beyond it, ends the range at " &
      $expectedRange(offs, eligible, gap, agreed)
    var missed = agreed
    for i in 50 ..< 100: missed[i] = false
    doAssert expectedRange(offs, eligible, kept, missed) >= 1900

  block aComparablePickIsStrictlyInsideTheBand:
    # on the band's edge is outside it, for the guided pick and the first pass's alike. Seen to
    # fail with far off taken only beyond the band: "a first-pass pick on the edge is no break"
    doAssert isComparable(219.99, 1, 200, 20) and not isComparable(220, 1, 200, 20)
    doAssert isComparable(180.01, 1, 200, 20) and not isComparable(180, 1, 200, 20)
    doAssert not isComparable(205, ConfidentPick - 0.01, 200, 20)
    doAssert not isComparable(NaN, 1, 200, 20) and not isComparable(205, 1, NaN, 20)
    var d = line(40, 0, 1)
    var g = oneLine(40)
    g.guideWindowMs = 20
    g.firstMs = d.pick
    g.firstConf = d.conf
    var p = d.pick
    p[8] = d.model[8] + 20
    g.firstMs[8] = p[8]
    let r = applyRule(p, d.conf, d.model, g)
    doAssert not r.comparable[8] and r.farOff[8], "a first-pass pick on the edge is no break"

  block twoFarOffNoisePicksAtARecordEndDoNotFlagTheEndTrace:
    # 12 flat traces, window 20 ms: two traces next to an end have no guided break and a
    # confident first-pass pick 300 ms late (noise). The end trace is judged against its
    # comparable neighbours only. Seen to fail with far-off traces' first-pass picks among the
    # neighbours: "end trace 0 off its neighbours" (and 11, at the other end).
    for (last, noise) in [(0, [1, 2]), (11, [9, 10])]:
      var d = line(12, 0, 1)
      var g = oneLine(12)
      g.guideWindowMs = 20
      g.firstMs = d.pick
      g.firstConf = d.conf
      var conf = d.conf
      for i in noise:
        conf[i] = 0.1
        g.firstMs[i] = d.model[i] + 300
      let r = applyRule(d.pick, conf, d.model, g)
      for i in noise: doAssert r.farOff[i], "trace " & $i & " not far off"
      doAssert not r.offNeighbours[last] and not r.flagged[last],
        "end trace " & $last & " off its neighbours"
    # a good trace beside far-off noise with too few comparable neighbours is not judged
    var d = line(6, 0, 1)
    var g = oneLine(6)
    g.guideWindowMs = 20
    g.firstMs = d.pick
    g.firstConf = d.conf
    var conf = d.conf
    for i in 1 .. 4:
      conf[i] = 0.1
      g.firstMs[i] = d.model[i] + 300
    let r = applyRule(d.pick, conf, d.model, g)
    doAssert r.nFarOff == 4 and r.nOffNeighbours == 0 and r.nFlagged == 4,
      $r.nOffNeighbours & " off their neighbours, " & $r.nFlagged & " flagged"

  block theShoulderOfADriftIsNotOffItsNeighbours:
    # 40 flat traces, window 20 ms; 21 to 27 have no guided break and a first-pass break 30 to
    # 60 ms late (a drift wider than the window); trace 20, 15 ms late, is its shoulder. Seen
    # to fail without the shoulder's excuse: "the shoulder is off its neighbours".
    var d = line(40, 0, 1)
    var g = oneLine(40)
    g.guideWindowMs = 20
    g.firstMs = d.pick
    g.firstConf = d.conf
    var conf = d.conf
    for i in 21 .. 27:
      conf[i] = 0.1
      g.firstMs[i] = d.model[i] + 30 + 5 * float64(i - 21)
    var p = d.pick
    p[20] += 15
    let r = applyRule(p, conf, d.model, g)
    doAssert r.comparable[20] and r.nFarOff == 7
    doAssert not r.offNeighbours[20], "the shoulder is off its neighbours"
    # 15 ms early beside a drift that is late is a wrong station
    p[20] = d.pick[20] - 15
    doAssert applyRule(p, conf, d.model, g).offNeighbours[20], "15 ms early beside a late drift"
    # one far-off trace is no drift
    p[20] = d.pick[20] + 15
    for i in 22 .. 27: conf[i] = 1.0
    let one = applyRule(p, conf, d.model, g)
    doAssert one.nFarOff == 1 and one.offNeighbours[20], "beside one far-off trace"

  block aRejectedGuidedPickFallsBackToTheFirstPass:
    # trace 8: no guided pick (dropped), the first pass's break 18 ms early: compared on it, off
    # the model. Trace 30: the guided pick outside the band, the first pass's inside it but not
    # confident (noise): no pick. Seen to fail without the first pass's pick, "trace 8 is not
    # compared on its first-pass pick"; with its confidence not asked, "trace 30 is compared".
    var d = line(40, 0, 1)
    var g = oneLine(40)
    g.guideWindowMs = 20
    g.firstMs = d.pick
    g.firstConf = d.conf
    var p = d.pick
    var conf = d.conf
    (p[8], conf[8]) = (NaN, 0.0)
    g.firstMs[8] = d.model[8] - 18
    p[30] = d.model[30] + 25
    (g.firstMs[30], g.firstConf[30]) = (d.model[30] + 5, 0.3)
    let r = applyRule(p, conf, d.model, g)
    doAssert r.comparable[8] and r.firstPick[8], "trace 8 is not compared on its first-pass pick"
    doAssert r.offModel[8] and r.offNeighbours[8], "trace 8 is not off the model"
    doAssert not r.comparable[30] and r.noBreak[30] and not r.flagged[30], "trace 30 is compared"
    doAssert r.nFirstPick == 1, $r.nFirstPick & " compared on the first pass's pick"

  block farOffIsANearMissNotNoise:
    # the first pass's pick is far off the model only 100 to 400 ms from it, and never before
    # the model's intercept less the limit: farther, or before any arrival, it is noise
    var d = line(300, 4, 14)
    var g = oneLine(300)
    g.offsetAbs = d.offs
    g.rangeMax = 4000
    g.firstMs = d.pick
    g.firstConf = d.conf
    var conf = d.conf
    for i in [100, 101, 102, 103, 104, 200, 201, 202, 10, 11, 12]: conf[i] = 0.1
    for i in 100 .. 104: g.firstMs[i] = d.model[i] + 250 # a station a few hundred metres off
    for i in 200 .. 202: g.firstMs[i] = d.model[i] + 900 # noise late in the trace
    for i in 10 .. 12: g.firstMs[i] = d.model[i] - 150 # before the first possible arrival
    let r = applyRule(d.pick, conf, d.model, g, interceptMs = 20)
    for i in 100 .. 104: doAssert r.farOff[i] and r.flagged[i], "trace " & $i
    for i in [200, 201, 202, 10, 11, 12]:
      doAssert r.noBreak[i] and not r.flagged[i], "trace " & $i & " is noise, not far off"
    doAssert r.nFarOff == 5, $r.nFarOff
    # a confident pick 150 ms early at a long offset is a near miss (it is after the intercept)
    g.firstMs[250] = d.model[250] - 150
    conf[250] = 0.1
    doAssert applyRule(d.pick, conf, d.model, g, interceptMs = 20).farOff[250]

  block aSixtyMsMissIsFarOffInsideANarrowWindow:
    # Seen to fail: with the band left at 100 ms, "60 ms off is no break, not far off".
    var d = line(40, 2, 21)
    var g = oneLine(40)
    g.guideWindowMs = GuideMinMs
    g.firstMs = d.pick
    g.firstConf = d.conf
    var conf = d.conf
    conf[8] = 0.1
    g.firstMs[8] = d.model[8] + 60
    let r = applyRule(d.pick, conf, d.model, g, interceptMs = 20)
    doAssert r.farOff[8] and not r.noBreak[8], "60 ms off is no break, not far off"
    doAssert r.guideWindowMs == GuideMinMs
    g.guideWindowMs = GuideMaxMs
    let wide = applyRule(d.pick, conf, d.model, g, interceptMs = 20)
    # inside the wide window the first pass's pick is compared, the guided one being none
    doAssert not wide.farOff[8] and wide.comparable[8] and wide.firstPick[8],
      "60 ms is inside the wide window"

  block theRecordsOwnFitNeverMismatchesWhereFewBreaksAreSeen:
    # within the range only a third of the traces have a confident pick (a healthy long record):
    # the given model that is the record's own fit matches; one 20 % slow does not
    var d = line(300, 4, 15)
    var conf = d.conf
    for i in 0 ..< 300:
      if i mod 3 != 0: conf[i] = 0.1
    var g = oneLine(300)
    g.ownSigmaMs = 4
    g.ownComparable = 100
    let own = applyRule(d.pick, conf, d.model, g, given = true)
    doAssert own.nComparable == 100 and own.nNoBreak == 200
    doAssert not own.mismatch, "the record's own fit does not match"
    var slow: seq[float64]
    for x in d.offs: slow.add 20 + 0.5 * x
    doAssert applyRule(d.pick, conf, slow, g, given = true).mismatch

  block aMovedSourceIsSaidAgainstTheScatterLeftAfterTheLean:
    # the job's limits come from the picks' scatter about the record's own fit, which holds the
    # lean; the source's bar must be the scatter left after the lean, or a moved source is
    # never said
    for shift in [200.0, 400.0]:
      let east = ring(shift, 0, 360)
      var res: seq[float64]
      for i in 0 ..< east.pick.len: res.add east.pick[i] - east.model[i]
      var g = east.g
      g.ownSigmaMs = robustSigma(res)
      doAssert g.ownSigmaMs > 0.8 * shift / 8, "the premise: the lean is in the scatter"
      let r = applyRule(east.pick, east.conf, east.model, g)
      doAssert lkSide in r.statement, $shift & " ft: lean " & $r.leanMs & ", nothing said"

  block aGivenModelThatDoesNotMatchSaysNothingOfTheSource:
    # receivers farther out towards +y: a slow model's misfit grows with offset, so it leans
    # with azimuth; the model is the fault, not the source
    let ring0 = ring(0, 0, 360)
    var slow: seq[float64]
    for i in 0 ..< ring0.model.len:
      let radius = 1000.0 + 5.0 * float64(i)
      slow.add 20 + radius / 6400 * 1000
    var g = ring0.g
    g.ownSigmaMs = 2
    let r = applyRule(ring0.pick, ring0.conf, slow, g, given = true)
    doAssert r.mismatch and r.leanMs > StatementFloorMs, "the premise: " & $r.leanMs
    doAssert r.statement == {} and statementWords(r) == "", statementWords(r)

  block theNeighboursFollowAStretchTheModelMisses:
    # a 60 ms ramp the model misses over 90 stations: off the model, but none off its neighbours;
    # a wrong station inside it, and one at a bend the model misses (a V), are found
    var d = line(300, 3, 16)
    for i in 0 ..< 90: d.pick[i] += 60.0 * float64(90 - i) / 90
    var g = oneLine(300)
    g.ownSigmaMs = 3
    let r = applyRule(d.pick, d.conf, d.model, g)
    doAssert r.nOffModel > 30 and r.nOffNeighbours == 0, "ramp: " & $r.nOffNeighbours &
      " off their neighbours"
    d.pick[40] += 40
    let s = applyRule(d.pick, d.conf, d.model, g)
    doAssert s.offNeighbours[40] and s.nOffNeighbours == 1, $s.nOffNeighbours
    var v = line(300, 3, 17)
    for i in 0 ..< 300: v.pick[i] += 0.6 * abs(float64(i - 150)) - 40
    v.pick[150] += 30
    let b = applyRule(v.pick, v.conf, v.model, g)
    doAssert b.offNeighbours[150] and b.nOffNeighbours <= 2, "the station at the bend: " &
      $b.nOffNeighbours & " off their neighbours, limit " & $b.stationLimitMs

  block aBendAtTheCrossoverIsNotACluster:
    # velocity 1 to velocity 2 (continuous) at 1000 m, over 300 traces to 3090 m: most picks are
    # on the second segment, so the trimming starts there and the kept set's sigma alone does
    # not keep the bend. Both a gentle (2500 to 3333 m/s) and a strong (2000 to 4000 m/s) bend
    # are two segments with the right velocities, and few traces of all are flagged; a straight
    # line stays one
    const n = 300
    # Seen to fail: with the trim not started again from the picks it dropped, "one segment" for
    # the 2000 to 4000 m/s and 3:1 bends on the smoothed picks (a single line of 4000 m/s, 86
    # near picks dropped); with the second segment kept for any gain, "a straight line has 2
    # segments".
    for (s1, s2) in [(0.4, 0.3), (0.5, 0.25), (0.6, 0.2), (0.4, 0.4)]:
      for basis in [pbSmoothed, pbAsRecorded]:
        let (slope1, slope2) = (s1, s2)
        withFixtures fx:
          let path = fx.customShot("bend.sgy", n, proc (i: int; k: var TraceKeys): float64 =
            k.offset = 100.0 + 10.0 * float64(i)
            if k.offset <= 1000: 20 + slope1 * k.offset
            else: 20 + slope1 * 1000 + slope2 * (k.offset - 1000))
          var f = openSeismic(path, keys = true)
          let b = breaksOfRecord(addr f, path, 0 ..< f.len, [], pick = basis)
          f.close()
          let what = $basis & " bend " & $slope1 & " to " & $slope2 & ": "
          if slope1 == slope2:
            doAssert b.segments == 1,
              what & "a straight line has " & $b.segments & " segments"
          else:
            doAssert b.segments == 2, what & "one segment"
            doAssert abs(b.fit.v1 - 1 / slope1 * 1000) < 0.05 * 1000 / slope1 and
              abs(b.fit.v2 - 1000 / slope2) < 0.05 * 1000 / slope2, what & $b.fit.v1 & ", " &
              $b.fit.v2
            doAssert abs(b.fit.crossover - 1000) < 100, what & "crossover " & $b.fit.crossover
          if slope1 != slope2:
            doAssert b.used == n, what & "only " & $b.used & " picks used"
            doAssert b.rule.nFlagged == 0, what & $b.rule.nFlagged & " flagged"
          doAssert b.rule.nFlagged <= 6, what & $b.rule.nFlagged & " of " & $b.rule.nComparable &
            " flagged"

  block aTightScatterExcludesABurstTheWideWindowWouldPick:
    # sigma about 3 ms, so the guided window is 20 ms: a burst 60 ms before the break is
    # outside it. Seen to fail with the window left at 100 ms: "the burst 60 ms before the
    # break was picked".
    const n = 80
    withFixtures fx:
      let path = fx.scatterShot("tight.sgy", n, 2.0, burst = true)
      var f = openSeismic(path, keys = true)
      tightBurstStaysOut(breaksOfRecord(addr f, path, 0 ..< f.len, []), n, "")
      let given = BreakModel(source: bmGiven, v1: 2500, interceptMs: 180)
      tightBurstStaysOut(breaksOfRecord(addr f, path, 0 ..< f.len, [], guide = given), n,
        "given model: ")
      f.close()

  block aWideScatterKeepsTheFullGuidedWindow:
    const n = 80
    withFixtures fx:
      let path = fx.scatterShot("wide.sgy", n, 35.0, burst = false)
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.twoPass and b.hasModel, b.passNote
      doAssert b.geometry.guideWindowMs == GuideMaxMs, "window " & $b.geometry.guideWindowMs
      doAssert "100 to 400" in b.modelWords(suMetres), b.modelWords(suMetres)

  block aRecordFitSearchEdgeIsNotABreak:
    # Four traces 18 ms early on a tight record (window 20 ms), at 1, 2 and 4 ms. The second
    # pass searches around the first-trim model, a few ms later than the model fitted again to
    # the guided picks: the break is outside the search and the picker returns its first sample,
    # which is inside the refit model's band. That is the window clamping, not a break: the
    # trace is judged by its first-pass pick, which is inside the band, so it is compared on
    # that pick and off the model (the first pass picks the samples as recorded a few ms late:
    # -13 to -16 ms, not -18). Seen to fail with the edge kept on the record-fit pass: "1 ms:
    # trace 20 compared at -14.0 ms"; without the first pass's pick when the guided one is
    # rejected, "1 ms: trace 20 not compared on its first-pass pick" (no break found, silent).
    for dt in [1.0, 2.0, 4.0]:
      withFixtures fx:
        let path = fx.customShot("early.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
          arrivalMs(k.offset) + (if i in 20 .. 23: -18.0 else: 0.0), dtMs = dt)
        var f = openSeismic(path, keys = true)
        let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
        f.close()
        let what = $int(dt) & " ms: "
        doAssert b.twoPass and b.geometry.guideWindowMs == GuideMinMs,
          what & "window " & $b.geometry.guideWindowMs
        doAssert b.rule.nComparable >= Traces - 4 - 3, what & $b.rule.nComparable & " compared"
        for t in 20 .. 23:
          doAssert not isComparable(b.pickMs[t], b.confidence[t], b.modelMs[t], GuideMinMs),
            what & "trace " & $t & " compared at " &
            formatFloat(b.pickMs[t] - b.modelMs[t], ffDecimal, 1) & " ms"
          doAssert b.rule.comparable[t] and b.rule.firstPick[t],
            what & "trace " & $t & " not compared on its first-pass pick"
          let d = b.differenceMs(t)
          doAssert b.rule.offModel[t] and b.mismatched(t) and d < -12 and d > -20,
            what & "trace " & $t & " not off the model: " & $d & " ms"
          doAssert "the first pass's pick" in b.readoutText(t), b.readoutText(t)

  block throughTheJobTheRangeSpansADeadStretch:
    # Traces 18 to 33 hold noise alone, real breaks lie beyond them: the range reaches the far
    # breaks, and the dead traces are no break found (judged one by one), never beyond. Seen to
    # fail with the range ending at the first bin where few breaks are seen: "the range ends at
    # 1102.5".
    withFixtures fx:
      let path = fx.customShot("dead.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        if i in 18 .. 33: NaN else: arrivalMs(k.offset))
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.twoPass and b.hasModel, b.passNote
      doAssert b.geometry.rangeMax >= offsetOf(44), "the range ends at " & $b.geometry.rangeMax
      for t in 18 .. 33:
        doAssert not b.rule.beyond[t] and not b.rule.comparable[t] and not b.rule.flagged[t],
          "dead trace " & $t
      for t in 34 .. 44: doAssert b.rule.comparable[t], "trace " & $t & " beyond the dead stretch"
      doAssert b.rule.nFlagged == 0, $b.rule.nFlagged & " flagged"

  block throughTheJobANoiseFarHalfIsBeyond:
    # Traces 24 to 47 hold noise alone: the range ends with the breaks, nothing far is judged.
    # Seen to fail with the range not capped by the picks both passes agree on: "the range ends
    # at 1715.0".
    withFixtures fx:
      let path = fx.customShot("half.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        if i >= 24: NaN else: arrivalMs(k.offset))
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.twoPass and b.hasModel, b.passNote
      doAssert b.geometry.rangeMax == 1200, "the range ends at " & $b.geometry.rangeMax
      for t in 24 ..< Traces: doAssert b.rule.beyond[t], "trace " & $t & " is judged"
      doAssert b.rule.nFlagged == 0, $b.rule.nFlagged & " flagged"

  block throughTheJobTrailingNoiseStaysBeyond:
    # Traces 36 to 47 hold an event 150 to 400 ms off the model, not a break: the range ends at
    # the breaks (1800 m), whatever the first pass picked there. Seen to fail with the range not
    # capped by the picks both passes agree on: "the range ends at 2450.0".
    withFixtures fx:
      let path = fx.customShot("tail.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        let away = 150.0 + float64((i * 173) mod 250)
        if i < 36: arrivalMs(k.offset)
        elif i mod 2 == 0: arrivalMs(k.offset) + away
        else: arrivalMs(k.offset) - away)
      var f = openSeismic(path, keys = true)
      let b = breaksOfRecord(addr f, path, 0 ..< f.len, [])
      f.close()
      doAssert b.twoPass and b.hasModel, b.passNote
      doAssert b.geometry.rangeMax == 1800, "the range ends at " & $b.geometry.rangeMax
      for t in 36 ..< Traces: doAssert b.rule.beyond[t], "trace " & $t & " is judged"
      doAssert b.rule.nFlagged == 0, $b.rule.nFlagged & " flagged"

  echo "tbreakrule: ok"

when isMainModule: main()
