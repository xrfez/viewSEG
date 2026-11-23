## What a record's first-break picks are compared with, and when a trace is "off": pure
## numbers, no file, no job, no drawing (`core/firstbreaks` keeps the result, the view draws it).
##
## A pick is only worth comparing with the model where the data hold a break. A trace whose
## picker found noise (no break at that offset) has a pick that lies anywhere, so it is
## "no break found", never "off the model". The rule:
##
## - **Where a break is expected** (`expectedRange`): out to the offset where fewer than
##   `RangeShare` of the traces have a confident pick near the model, and never past most of the
##   picks both passes agree on. A trace beyond it is "beyond", counted apart and never judged.
## - **Comparable**: a pick of confidence from `ConfidentPick` within `GrossBandMs` of the
##   model.
## - **Off the model**: a comparable trace whose residual (pick less model) is larger than
##   the record's limit, `max(LimitFloorMs, LimitSigmas * sigma)`, `sigma` being 1.4826 times
##   the median absolute deviation (MAD) of the picks' own scatter about the record's fit.
## - **Far off the model**: a trace whose guided pick is not comparable, but whose first-pass
##   pick is confident and more than `GrossBandMs`, at most `FarOffMaxMs`, from the model,
##   and not before the model's intercept less the limit (no break comes before the first
##   possible arrival). Everything else with a model time is "no break found", never flagged.
## - **Off its neighbours**: a comparable trace whose residual, less the median residual of up
##   to `NeighbourCount` comparable neighbours on one side along its receiver line (at most
##   `NeighbourReach` places away; the left side's, the right side's or their mean, whichever is
##   nearer its own residual), is larger than
##   `max(LimitFloorMs, StationSigmas * sigma')`, `sigma'` being the same measure of the
##   differences from the mean of both sides over the record. This finds a wrong station and
##   tolerates a model that bends.
## - **A given model that does not match**: its median residual is past the limit, its
##   misfit's scatter is more than `MismatchSigmas` times the picks' own, or it finds fewer
##   than half the comparable traces the record's own fit finds.
## - **A source in the wrong place**: when the comparable traces' azimuths from the source
##   cover at least `LeanMinSpanDeg` degrees, the residuals are fitted (robustly) as `c0 +
##   a cos(az) + b sin(az)`. A constant `c0`, or a lean `sqrt(a² + b²)`, above
##   `max(StatementFloorMs, StatementSigmas * sigma)` is said in the record's words; `sigma` is
##   the scatter left after that fit, so the lean does not widen what it is measured against.
##   Nothing is said of the source when a given model does not match: the model is the
##   likelier fault.
##
## One function (`applyRule`) decides all of it, so the flags, the counts and the words cannot
## disagree.
##
## Before that, `trimmedModel` makes the model the picks are compared with: it starts from the
## closer half of the picks to a robust line, then keeps the picks within `TrimSigmas` sigmas
## (not less than `TrimFloorMs`) of the fit and refits, up to `TrimRounds` times, so a noise pick
## at a long offset does not set the model.

import std/[algorithm, math]
import breakmodel

const
  ConfidentPick* = 0.5
    ## the confidence from which a pick counts (processSEG's `ShotFitParams.minConfidence`)
  MadToSigma* = 1.4826     ## a MAD to a normal distribution's standard deviation
  TrimSigmas* = 3.0        ## picks farther than this many sigmas from the model are left out of it
  TrimFloorMs* = 12.0      ## ... but never closer than this (ms)
  TrimRounds* = 5          ## the most fit-and-drop rounds
  MinTrimmedPicks* = 10
    ## the fewest picks left that make a model to trust: fewer, and the first-pass picks stay
  StartLines* = 300        ## the pairs of picks the start's robust line is chosen from
  MinSecondPicks* = 15
    ## the fewest trimmed picks beyond the crossover that keep a second segment
  SecondGain* = 0.9
    ## the second segment must bring the robust sigma of the fit below this share of the
    ## single line's
  GuideWindowMs* = 100.0 ## the second pass's search window either side of the model (ms)
  GrossBandMs* = 100.0 ## a confident pick farther than this from the model is no break found
  LimitFloorMs* = 12.0 ## the smallest limit, on the model and on the neighbours (ms)
  LimitSigmas* = 3.0 ## the record's limit: this many sigmas of the comparable residuals
  StationSigmas* = 4.0
    ## the neighbours' limit: this many sigmas of the differences from both sides' mean
  NeighbourCount* = 3 ## comparable neighbours on each side that set a station's expectation
  NeighbourReach* = 2 * NeighbourCount
    ## the farthest (in places along the line) a neighbour is looked for on each side
  MinNeighbours* = 3 ## the fewest usable neighbours (in all) a trace needs to be judged by them
  FarOffMaxMs* = 400.0
    ## the farthest a first-pass pick may be from the model to be "far off" it; farther is noise
  RangeBins* = 20 ## the offset bins `expectedRange` cuts the record into
  RangeBinTraces* = 10 ## the fewest traces a bin holds (a sparser one is merged outward)
  RangeShare* = 0.2
    ## the share of a bin's traces with a confident pick near the model below which no break is
    ## expected there
  RangeSupportedPercentile* = 0.95
    ## the expected range is never beyond this share of the supported picks' offsets
  MinLeanEigen* = 0.15
    ## the smaller eigenvalue of the azimuths' (cos, sin) scatter matrix, per trace, below which
    ## no lean is fitted (a full ring gives 0.5; a line through the source, 0)
  MismatchSigmas* = 2.0
    ## a given model whose misfit scatter is more than this many times the pick scatter does not
    ## match the record
  StatementFloorMs* = 10.0 ## the smallest lean or constant that is said (ms)
  StatementSigmas* = 2.0 ## ... or this many sigmas
  LeanMinSpanDeg* = 180.0 ## the azimuths must cover this much of the circle
  LeanMinTraces* = 20 ## the fewest comparable traces with an azimuth that the lean is fitted to

type
  ModelFn* = proc (use: openArray[bool]): seq[float64] {.closure.}
    ## The model's time (ms) at every trace, fitted to the picks `use` marks; empty when it
    ## cannot be fitted.

  Trimmed* = object
    ## What `trimmedModel` found.
    trusted*: bool       ## at least `MinTrimmedPicks` picks were left, and a model was fitted
    model*: seq[float64] ## the last fit's times; empty unless `trusted`
    kept*: seq[bool]     ## the picks the last fit used
    used*: int           ## how many
    sigmaMs*: float64    ## the robust sigma of the kept picks' residuals; NaN for none
    rounds*: int         ## fits made

  GuideLine* = object
    ## One straight piece of a model as the picker's guide: the break at offset `x` is at
    ## `t0Ms + 1000 x / velocity` for `x` in `above < x <= upTo`.
    velocity*, t0Ms*: float64
    above*, upTo*: float64

  RuleGeometry* = object
    ## Where each trace of a record is, and what the record's own fit says, as far as the rule
    ## needs.
    eligible*: seq[bool] ## the traces the model is about (the fitted sensor's)
    lines*: seq[seq[int]] ## per receiver line, its traces in station order
    azimuth*: seq[float64] ## source to receiver, radians counter-clockwise from +x; NaN unknown
    offsetAbs*: seq[float64] ## |offset| per trace; NaN unknown (empty: every trace is in range)
    rangeMax*: float64 = NaN
      ## the largest offset at which a break is expected (`expectedRange`); beyond it a trace is
      ## never judged. NaN: no limit
    firstMs*, firstConf*: seq[float64]
      ## the first (unguided) pass's pick and confidence per trace; empty: none
    ownSigmaMs*: float64 = NaN
      ## the pick scatter about the record's OWN fit (robust sigma, ms): the limits come from it
      ## whatever model is shown, so a model that does not fit cannot widen them. NaN: the
      ## scatter about the model shown
    ownComparable*: int = -1
      ## the traces comparable with the record's OWN fit within the expected range: a given
      ## model that finds fewer than half as many does not match. -1: not known

  LeanKind* = enum
    lkNone, lkConstant, lkSide

  BreakRule* = object
    ## What the rule found; per-trace seqs are indexed as the record's traces.
    comparable*, noBreak*, beyond*, farOff*, offModel*, offNeighbours*, flagged*: seq[bool]
    nComparable*, nNoBreak*, nBeyond*, nFarOff*, nOffModel*, nOffNeighbours*, nFlagged*: int
    nInRange*: int            ## traces with a model time within the expected offsets
    limitMs*: float64         ## the record limit (ms); NaN when there is no scatter to go by
    sigmaMs*: float64         ## the pick scatter the limits come from (`ownSigmaMs`, else the
                              ## comparable residuals')
    misfitSigmaMs*: float64   ## robust sigma of the comparable residuals about the model shown
    stationLimitMs*, stationSigmaMs*: float64
    medianMs*: float64        ## median of the comparable residuals; NaN for none
    constantMs*: float64      ## c0 (NaN when not found)
    leanMs*: float64          ## fitted sqrt(a² + b²) (NaN when not fitted)
    earlyTowardDeg*: float64  ## the angle (degrees from +x towards +y) the picks are earliest at
    statement*: set[LeanKind] ## what is said of the source (nothing with `mismatch`)
    mismatch*: bool           ## a given model that does not match the record's breaks

func median*(xs: openArray[float64]): float64 =
  ## The median; NaN for none.
  if xs.len == 0: return NaN
  var s = @xs
  s.sort()
  let h = s.len div 2
  if s.len mod 2 == 1: s[h] else: (s[h - 1] + s[h]) / 2

func robustSigma*(xs: openArray[float64]): float64 =
  ## 1.4826 times the median absolute deviation about the median; NaN for none.
  if xs.len == 0: return NaN
  let m = median(xs)
  var d = newSeq[float64](xs.len)
  for i, x in xs: d[i] = abs(x - m)
  MadToSigma * median(d)

func lineFit*(x, t: openArray[float64]; use: openArray[bool]):
    tuple[interceptMs, msPerUnit: float64; ok: bool] =
  ## The straight line `t = a + s x` through the points `use` marks, by least absolute
  ## deviations (iteratively reweighted least squares, 40 rounds); `ok` is false for fewer than
  ## two points, all at one `x`, or a line that does not rise.
  result = (NaN, NaN, false)
  var xs, ts: seq[float64]
  for i in 0 ..< x.len:
    if use[i] and not x[i].isNaN and not t[i].isNaN:
      xs.add x[i]
      ts.add t[i]
  if xs.len < 2 or xs.min == xs.max: return
  var w = newSeq[float64](xs.len)
  for i in 0 ..< w.len: w[i] = 1.0
  var (a, s) = (0.0, 0.0)
  for round in 0 ..< 40:
    var (sw, sx, st, sxx, sxt) = (0.0, 0.0, 0.0, 0.0, 0.0)
    for i in 0 ..< xs.len:
      sw += w[i]
      sx += w[i] * xs[i]
      st += w[i] * ts[i]
      sxx += w[i] * xs[i] * xs[i]
      sxt += w[i] * xs[i] * ts[i]
    let den = sw * sxx - sx * sx
    if abs(den) < 1e-12 * sw * sxx: return
    s = (sw * sxt - sx * st) / den
    a = (st - s * sx) / sw
    for i in 0 ..< xs.len: w[i] = 1.0 / max(abs(ts[i] - a - s * xs[i]), 0.25)
  if s > 0: result = (a, s, true)

func medianLineStart(offs, pickMs: openArray[float64]; confident: openArray[bool]):
    seq[(float64, int)] =
  ## The confident picks with their distance from the straight line of least median of squares
  ## (the best of `StartLines` lines through pairs of picks, the pairs chosen by a fixed
  ## generator), sorted nearest first. That line is not pulled by up to half of the picks being
  ## noise, which a fit of all of them is.
  var ids: seq[int]
  for i in 0 ..< pickMs.len:
    if confident[i] and not offs[i].isNaN: ids.add i
  if ids.len < 2: return
  var state = 88172645463325252'u64
  func draw(state: var uint64; n: int): int =
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    int((state shr 33) mod uint64(n))
  var best = Inf
  var (bestA, bestS) = (0.0, 0.0)
  var dev = newSeq[float64](ids.len)
  for line in 0 ..< StartLines:
    let (i, j) = (ids[draw(state, ids.len)], ids[draw(state, ids.len)])
    if offs[i] != offs[j]:
      let s = (pickMs[j] - pickMs[i]) / (offs[j] - offs[i])
      let a = pickMs[i] - s * offs[i]
      for k, id in ids: dev[k] = abs(pickMs[id] - a - s * offs[id])
      let m = median(dev)
      if m < best: (best, bestA, bestS) = (m, a, s)
  if best == Inf: return
  for id in ids: result.add (abs(pickMs[id] - bestA - bestS * offs[id]), id)
  result.sort()

proc trimmedModel*(offsetAbs, pickMs, confidence: openArray[float64]; fit: ModelFn): Trimmed =
  ## A model that noise picks do not set. It starts from the closer half of the confident picks
  ## to a robust straight line (`medianLineStart`); then, up to `TrimRounds` times, `fit` on the
  ## picks kept, and the confident picks within `max(TrimFloorMs, TrimSigmas * sigma)` of that
  ## model kept for the next round (sigma: the robust sigma of the picks it was fitted to),
  ## until the set no longer changes. Picks dropped may come back when the model moves to them.
  ## Not `trusted` when `fit` gives nothing or fewer than `MinTrimmedPicks` picks are left.
  let n = pickMs.len
  result = Trimmed(kept: newSeq[bool](n), sigmaMs: NaN)
  var confident = newSeq[bool](n)
  var use = newSeq[bool](n)
  var count = 0
  for i in 0 ..< n:
    confident[i] = not pickMs[i].isNaN and confidence[i] >= ConfidentPick
    use[i] = confident[i]
    if use[i]: inc count
  result.kept = use
  result.used = count
  if count < MinTrimmedPicks: return
  let near = medianLineStart(offsetAbs, pickMs, confident)
  if near.len < MinTrimmedPicks: return
  let keep = max(MinTrimmedPicks, (near.len + 1) div 2)
  use = newSeq[bool](n)
  for k in 0 ..< keep: use[near[k][1]] = true
  count = keep
  var model: seq[float64]
  for round in 1 .. TrimRounds + 1:
    model = fit(use)
    inc result.rounds
    if model.len != n:
      result.used = count
      return
    var res: seq[float64]
    for i in 0 ..< n:
      if use[i] and not model[i].isNaN: res.add pickMs[i] - model[i]
    let sigma = robustSigma(res)
    let cut = max(TrimFloorMs, TrimSigmas * (if sigma.isNaN: 0.0 else: sigma))
    var next = newSeq[bool](n)
    var nextCount = 0
    for i in 0 ..< n:
      next[i] = confident[i] and not model[i].isNaN and abs(pickMs[i] - model[i]) <= cut
      if next[i]: inc nextCount
    if next == use or round > TrimRounds:
      # `use` is what `model` was fitted to
      return Trimmed(trusted: count >= MinTrimmedPicks, model: model, kept: use, used: count,
        sigmaMs: sigma, rounds: result.rounds)
    if nextCount < MinTrimmedPicks:
      result.used = nextCount
      return
    use = next
    count = nextCount
    result.kept = use
    result.used = count

func keepSecond*(beyond: int; sigmaOne, sigmaTwo: float64): bool =
  ## Whether a second segment stays: at least `MinSecondPicks` trimmed picks lie beyond the
  ## crossover and it brings the robust sigma below `SecondGain` of the single line's.
  beyond >= MinSecondPicks and not sigmaOne.isNaN and not sigmaTwo.isNaN and
    sigmaTwo < SecondGain * sigmaOne

func guideLines*(m: BreakModel): seq[GuideLine] =
  ## The picker's guide for `m` as one line per segment (its own velocity and intercept: the
  ## second segment is continuous with the first at the crossover).
  if m.v1 <= 0: return
  if m.segments == 2:
    let t2 = m.interceptMs + 1000 * m.crossover * (1 / m.v1 - 1 / m.v2)
    @[GuideLine(velocity: m.v1, t0Ms: m.interceptMs, above: -Inf, upTo: m.crossover),
      GuideLine(velocity: m.v2, t0Ms: t2, above: m.crossover, upTo: Inf)]
  else:
    @[GuideLine(velocity: m.v1, t0Ms: m.interceptMs, above: -Inf, upTo: Inf)]

func stationLines*(line, point: openArray[float64]; eligible: openArray[bool]):
    seq[seq[int]] =
  ## The eligible traces grouped by receiver line (an unknown line is one group), each in
  ## order of receiver point; a group whose points are not all known keeps the file order.
  let n = line.len
  var groups: seq[(float64, seq[int])]
  for i in 0 ..< n:
    if eligible[i]:
      let key = if line[i].isNaN: -Inf else: line[i]
      var g = -1
      for j in 0 ..< groups.len:
        if groups[j][0] == key: g = j
      if g < 0:
        groups.add (key, @[i])
      else: groups[g][1].add i
  groups.sort(proc (a, b: (float64, seq[int])): int = cmp(a[0], b[0]))
  for (_, members) in groups:
    var ids = members
    var known = true
    for i in ids: known = known and not point[i].isNaN
    if known:
      var keyed: seq[(float64, int)]
      for i in ids: keyed.add (point[i], i)
      keyed.sort()
      ids = @[]
      for (_, i) in keyed: ids.add i
    result.add ids

func expectedRange*(offsetAbs: openArray[float64]; eligible, seen, supported: openArray[bool]):
    float64 =
  ## The largest offset at which a break is expected: the eligible traces with an offset are cut
  ## into `RangeBins` bins of offset (a bin of fewer than `RangeBinTraces` traces merged with the
  ## next one out, a short last one with the one before), and walked outward from the first bin
  ## where at least `RangeShare` of the traces have a `seen` pick (a confident one near the
  ## model); the range ends at the outer edge of the last such bin before the first that falls
  ## below it, and never beyond `RangeSupportedPercentile` of the offsets of the `supported`
  ## picks (those both passes agree on: a guided pick alone may be noise its window held). NaN
  ## when no trace has a supported pick.
  var far = 0.0
  var held: seq[float64]
  for i in 0 ..< offsetAbs.len:
    if eligible[i] and not offsetAbs[i].isNaN:
      far = max(far, offsetAbs[i])
      if supported[i]: held.add offsetAbs[i]
  if held.len == 0: return NaN
  held.sort()
  let top = held[min(held.high, max(0, int(ceil(RangeSupportedPercentile * float64(
    held.len))) - 1))]
  if far <= 0: return top
  let width = far / float64(RangeBins)
  var count, inBin = newSeq[int](RangeBins)
  for i in 0 ..< offsetAbs.len:
    if eligible[i] and not offsetAbs[i].isNaN:
      let b = min(RangeBins - 1, int(offsetAbs[i] / width))
      inc count[b]
      if seen[i]: inc inBin[b]
  # the bins merged: (traces, seen, outer edge)
  var groups: seq[(int, int, float64)]
  var (c, h) = (0, 0)
  for b in 0 ..< RangeBins:
    c += count[b]
    h += inBin[b]
    if c >= RangeBinTraces:
      groups.add (c, h, width * float64(b + 1))
      (c, h) = (0, 0)
  if c > 0:
    if groups.len > 0:
      groups[^1][0] += c
      groups[^1][1] += h
      groups[^1][2] = far
    else: groups.add (c, h, far)
  var edge = NaN
  for (traces, got, outer) in groups:
    if float64(got) >= RangeShare * float64(traces): edge = outer
    elif not edge.isNaN: break
  if edge.isNaN: top else: min(edge, top)

func solve3(m: var array[3, array[4, float64]]): bool =
  ## Gauss elimination of the 3x4 system; false when singular.
  for c in 0 .. 2:
    var p = c
    for r in c + 1 .. 2:
      if abs(m[r][c]) > abs(m[p][c]): p = r
    if abs(m[p][c]) < 1e-12: return false
    swap(m[c], m[p])
    for r in 0 .. 2:
      if r != c:
        let f = m[r][c] / m[c][c]
        for k in c .. 3: m[r][k] -= f * m[c][k]
  true

func azimuthFit(res, az: openArray[float64]): tuple[c0, a, b: float64; ok: bool] =
  ## `res = c0 + a cos(az) + b sin(az)` by least absolute deviations (reweighted least
  ## squares, 40 rounds).
  result = (NaN, NaN, NaN, false)
  var w = newSeq[float64](res.len)
  for i in 0 ..< w.len: w[i] = 1.0
  var coef = [0.0, 0.0, 0.0]
  for round in 0 ..< 40:
    var m: array[3, array[4, float64]]
    for i in 0 ..< res.len:
      let row = [1.0, cos(az[i]), sin(az[i])]
      for r in 0 .. 2:
        for c in 0 .. 2: m[r][c] += w[i] * row[r] * row[c]
        m[r][3] += w[i] * row[r] * res[i]
    if not solve3(m): return
    for r in 0 .. 2: coef[r] = m[r][3] / m[r][r]
    for i in 0 ..< res.len:
      let fit = coef[0] + coef[1] * cos(az[i]) + coef[2] * sin(az[i])
      w[i] = 1.0 / max(abs(res[i] - fit), 0.25)
  result = (coef[0], coef[1], coef[2], true)

func coverageDeg(az: openArray[float64]): float64 =
  ## How much of the circle the azimuths (radians) cover: 360 less the widest gap.
  if az.len < 2: return 0
  var s = @az
  for a in s.mitems:
    a = a mod (2 * PI)
    if a < 0: a += 2 * PI
  s.sort()
  var gap = s[0] + 2 * PI - s[^1]
  for i in 1 ..< s.len: gap = max(gap, s[i] - s[i - 1])
  360.0 - gap * 180.0 / PI

func eigenMin(az: openArray[float64]): float64 =
  ## The smaller eigenvalue of the azimuths' scatter matrix [cos², cos sin; cos sin, sin²] per
  ## trace: 0.5 for a ring, 0 for traces all on one line through the source.
  var (cc, ss, cs) = (0.0, 0.0, 0.0)
  for a in az:
    cc += cos(a) * cos(a)
    ss += sin(a) * sin(a)
    cs += cos(a) * sin(a)
  let n = float64(az.len)
  (cc, ss, cs) = (cc / n, ss / n, cs / n)
  let tr = cc + ss
  let det = cc * ss - cs * cs
  (tr - sqrt(max(tr * tr - 4 * det, 0.0))) / 2

func sideMedian(ids: openArray[int]; k, dir: int; res: openArray[float64]):
    tuple[med: float64; count: int] =
  ## The median residual of up to `NeighbourCount` traces next to `ids[k]` in direction `dir`,
  ## looked for at most `NeighbourReach` places away (`ids` are the line's comparable traces).
  var near: seq[float64]
  var j = k + dir
  while j >= 0 and j < ids.len and near.len < NeighbourCount and abs(j - k) <= NeighbourReach:
    near.add res[ids[j]]
    j += dir
  (median(near), near.len)

func applyRule*(pickMs, confidence, modelMs: openArray[float64]; g: RuleGeometry;
    given = false; interceptMs = NaN): BreakRule =
  ## The rule over one record: per trace, its pick, the pick's confidence and the model's time
  ## (NaN where it has none). The traces `g.eligible` says are not part of it are not counted;
  ## those beyond `g.rangeMax` are counted apart and never judged. `given`: the model is one the
  ## user gave, which may not match the record (`mismatch`). `interceptMs`: the model's time at
  ## offset 0, before which no first-pass pick is far off it (NaN: no such bound).
  let n = pickMs.len
  result = BreakRule(comparable: newSeq[bool](n), noBreak: newSeq[bool](n),
    beyond: newSeq[bool](n), farOff: newSeq[bool](n), offModel: newSeq[bool](n),
    offNeighbours: newSeq[bool](n), flagged: newSeq[bool](n), limitMs: NaN, sigmaMs: NaN,
    misfitSigmaMs: NaN, stationLimitMs: NaN, stationSigmaMs: NaN, medianMs: NaN,
    constantMs: NaN, leanMs: NaN, earlyTowardDeg: NaN)
  var res = newSeq[float64](n)
  var all: seq[float64]
  let haveFirst = g.firstMs.len == n and g.firstConf.len == n
  for i in 0 ..< n:
    res[i] = NaN
    let live = (g.eligible.len != n or g.eligible[i]) and not modelMs[i].isNaN
    if live:
      let inRange = g.offsetAbs.len != n or g.rangeMax.isNaN or g.offsetAbs[i].isNaN or
        g.offsetAbs[i] <= g.rangeMax
      if not inRange:
        result.beyond[i] = true
        inc result.nBeyond
      else:
        inc result.nInRange
        let d = pickMs[i] - modelMs[i]
        if not d.isNaN and confidence[i] >= ConfidentPick and abs(d) <= GrossBandMs:
          res[i] = d
          result.comparable[i] = true
          all.add d
          inc result.nComparable
        else: result.noBreak[i] = true # until the far-off test below
  result.misfitSigmaMs = robustSigma(all)
  result.sigmaMs = if g.ownSigmaMs.isNaN: result.misfitSigmaMs else: g.ownSigmaMs
  if all.len > 0: result.medianMs = median(all)
  if not result.sigmaMs.isNaN:
    result.limitMs = max(LimitFloorMs, LimitSigmas * result.sigmaMs)
    for i in 0 ..< n:
      if result.comparable[i] and abs(res[i]) > result.limitMs:
        result.offModel[i] = true
  # far off: the guided window holds no break, but the first pass found a confident one
  # beyond it, near enough to be a station placed wrongly, and not before any arrival can be
  let earliest = interceptMs - (if result.limitMs.isNaN: LimitFloorMs else: result.limitMs)
  for i in 0 ..< n:
    if result.noBreak[i]:
      if haveFirst and g.firstConf[i] >= ConfidentPick and not g.firstMs[i].isNaN:
        let d = abs(g.firstMs[i] - modelMs[i])
        if d > GrossBandMs and d <= FarOffMaxMs and
            (earliest.isNaN or g.firstMs[i] >= earliest):
          (result.farOff[i], result.noBreak[i]) = (true, false)
          inc result.nFarOff
      if result.noBreak[i]: inc result.nNoBreak
  # the station rule, along each receiver line: against the median of up to NeighbourCount
  # comparable neighbours on each side (off the model or not: a stretch the model misses is
  # still the line's); a trace with fewer than MinNeighbours is not judged
  var local = newSeq[float64](n)
  for i in 0 ..< n: local[i] = NaN
  var lines = g.lines
  if lines.len == 0:
    lines = @[newSeq[int]()]
    for i in 0 ..< n: lines[0].add i
  # sigma' is that of the differences from both sides' mean (the ends' one-sided ones when no
  # trace has both): the nearer side's alone are narrower than the stations' real scatter, and
  # a limit from them flags healthy stations
  var diffs, ends: seq[float64]
  for line in lines:
    var ids: seq[int]
    for i in line:
      if i in 0 ..< n and result.comparable[i]: ids.add i
    for k in 0 ..< ids.len:
      let (ml, nl) = sideMedian(ids, k, -1, res)
      let (mr, nr) = sideMedian(ids, k, 1, res)
      if nl + nr >= MinNeighbours:
        let r = res[ids[k]]
        # with both sides: whichever of the left, the right and their mean is nearest (the mean
        # follows a steep stretch, one side a block's edge)
        var near = if nl == 0: mr
                   elif nr == 0: ml
                   elif abs(r - ml) <= abs(r - mr): ml
                   else: mr
        if nl > 0 and nr > 0 and abs(r - (ml + mr) / 2) < abs(r - near): near = (ml + mr) / 2
        local[ids[k]] = r - near
        if nl > 0 and nr > 0: diffs.add r - (ml + mr) / 2
        else: ends.add local[ids[k]]
  if diffs.len == 0: diffs = ends
  if diffs.len > 0:
    result.stationSigmaMs = robustSigma(diffs)
    result.stationLimitMs = max(LimitFloorMs, StationSigmas * result.stationSigmaMs)
    for i in 0 ..< n:
      if not local[i].isNaN and abs(local[i]) > result.stationLimitMs:
        result.offNeighbours[i] = true
  for i in 0 ..< n:
    result.flagged[i] = result.offModel[i] or result.offNeighbours[i] or result.farOff[i]
    if result.offModel[i]: inc result.nOffModel
    if result.offNeighbours[i]: inc result.nOffNeighbours
    if result.flagged[i]: inc result.nFlagged
  # a given model that does not match the record: by its median, its misfit, or because it
  # finds far fewer breaks than the record's own fit (so the record's own fit never is one)
  if given and result.nInRange > 0:
    result.mismatch = (g.ownComparable > 0 and result.nComparable * 2 < g.ownComparable) or
      (not result.limitMs.isNaN and abs(result.medianMs) > result.limitMs) or
      (not g.ownSigmaMs.isNaN and not result.misfitSigmaMs.isNaN and
        result.misfitSigmaMs > MismatchSigmas * g.ownSigmaMs)
  # the source
  if all.len == 0: return
  var rs, az: seq[float64]
  if g.azimuth.len == n:
    for i in 0 ..< n:
      if result.comparable[i] and not g.azimuth[i].isNaN:
        rs.add res[i]
        az.add g.azimuth[i]
  # the bar is the scatter left after the fit: the one-parameter fit's (the misfit's) when
  # the azimuths cannot give a lean, else the lean's; never the picks' own scatter about the
  # record's fit, which a lean widens
  var bar = max(StatementFloorMs, StatementSigmas * result.misfitSigmaMs)
  var c0 = median(all) # the one-parameter fit, when the azimuths cannot give a lean
  if rs.len >= LeanMinTraces and coverageDeg(az) >= LeanMinSpanDeg and
      eigenMin(az) >= MinLeanEigen:
    let f = azimuthFit(rs, az)
    if f.ok:
      c0 = f.c0
      result.leanMs = sqrt(f.a * f.a + f.b * f.b)
      # the picks are earliest where the lean is most negative
      result.earlyTowardDeg = arctan2(-f.b, -f.a) * 180.0 / PI
      # the scatter left after the lean and the constant, not before: the lean itself would
      # otherwise widen the sigma it is measured against
      var left = newSeq[float64](rs.len)
      for i in 0 ..< rs.len:
        left[i] = rs[i] - (f.c0 + f.a * cos(az[i]) + f.b * sin(az[i]))
      bar = max(StatementFloorMs, StatementSigmas * robustSigma(left))
      if result.leanMs > bar: result.statement.incl lkSide
  result.constantMs = c0
  if abs(c0) > bar: result.statement.incl lkConstant
  # a given model that does not match is the likelier fault: nothing is said of the source
  if result.mismatch: result.statement = {}

func earlyBearingDeg*(r: BreakRule): float64 =
  ## The direction the picks are earliest in as a compass bearing, clockwise from north, taking
  ## x as east and y as north; NaN without a lean.
  if r.earlyTowardDeg.isNaN: NaN else: (450.0 - r.earlyTowardDeg) mod 360.0

func statementWords*(r: BreakRule): string =
  ## The record's words about the source; "" when the rule finds nothing.
  func ms(x: float64): string = $int(round(x)) & " ms"
  if lkSide in r.statement:
    result = "the picks lean to one side of the source by " & ms(r.leanMs) &
      " (earliest towards bearing " & $int(round(r.earlyBearingDeg)) &
      " degrees, clockwise from north if x is east and y north): the source may be placed or " &
      "named wrongly"
  if lkConstant in r.statement:
    if result.len > 0: result.add "; "
    result.add "every pick is " & (if r.constantMs < 0: "early" else: "late") & " by " &
      ms(abs(r.constantMs))
    if lkSide notin r.statement: result.add ": the source may be placed or named wrongly"
