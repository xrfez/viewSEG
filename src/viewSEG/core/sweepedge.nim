## The top frequency of a reference sweep, read from its own samples, with the reading's
## uncertainty: the sweep's frequency law over the stretch well above the noise, taken to
## where the sweep ends. No shape is assumed for the ramp at the end: its fall is measured
## and the point where it reaches zero is found from the part of the fall between 3 % (or
## the noise's reach) and 12 to 35 % of the sweep's amplitude, against a few shapes of it
## (powers of the time left, and the cosine squared) each of which makes a straight line;
## the data weigh them.
##
## - The envelope is the mean square of the samples over a window (the noise's mean square,
##   estimated from a quiet stretch of the record when it has one, taken off), wide enough
##   for the noise not to blur it. The plateau is taken from the reference's measured flat
##   part (`SweepExtent`) and extended while the envelope stays above half its level.
## - The law (f or ln f against time, whichever fits better) is fitted over the plateau by
##   least squares with outliers dropped.
## - The fall ends where it stops steepening (a ring-down or leakage after the ramp leaves
##   it as a gentle slope), or at the plateau's edge when there is no ramp (a step).
## - The uncertainty is twice the standard error of the end frequency: the law's standard
##   error at the end (points counted as one in five, they overlap), and the end time's from
##   the fit of the fall, the spread between the shapes that fit about as well, and a share
##   of the stretch the fall is extended over, times the sweep's rate. A reading is marked
##   uncertain when it exceeds `UncertainFraction` of the frequency.

import std/[math, algorithm, sequtils]
import processSEG/vibroseis/sweeptrack

const
  UncertainFraction* = 0.006
    ## an uncertainty (about 2 standard errors) above this fraction of the top frequency marks
    ## the reading uncertain: no synthetic sweep tried (every taper shape, noise down to 0 dB,
    ## tails) was read more than 1 % off without being marked, and 1 % is the tolerance the
    ## band check allows the top over the largest chord frequency (`vibanalysis`)
  FallHigh = 0.35 # the fall is fitted from this fraction of the plateau's amplitude ...
  FallLow = 0.03 # ... to this one at the least (-30 dB), or the noise's reach, or the knee
  SlopeKnee = 0.35 # the fall ends where its steepness (in ln A) drops under this share of
                     # the steepest so far: a tail leaves the ramp there, as a gentle slope
  Shapes = [(false, 1.0), (false, 1.25), (false, 1.5), (false, 1.75), (false, 2.0),
    (false, 2.5), (false, 3.0), (false, 4.0), (true, 1.0), (true, 2.0)]
    ## the shapes of the end the fall is tried against, each making a straight line in time:
    ## a power of the time left, A ~ x^q (false, q), or a quarter sine to the power p,
    ## A ~ sin^p(pi x / 2) (true, p: p = 2 is the cosine squared ramp, the commonest one)
  Coverage = 2.0 # the stated uncertainty is this many standard errors (about 95 %)
  ModelShare = 0.15 # of the extrapolated stretch, counted as error
  Overlap = 5.0 # track points counted as one in this many

type TopReading* = object
  ## `hz` NaN: no reading. `endMs` is where the sweep is taken to end (its top-frequency end).
  hz*: float64
  uncertaintyHz*: float64 = Inf
  uncertain*: bool
  endMs*: float64 = NaN
  rateHzS*: float64 = NaN ## the sweep's rate at its end, Hz per second
  why*: string            ## in plain words, when `uncertain`

func median(v: openArray[float64]): float64 =
  if v.len == 0: return NaN
  let s = sorted(v)
  if s.len mod 2 == 1: s[s.len div 2] else: 0.5 * (s[s.len div 2 - 1] + s[s.len div 2])

type Line = object
  a, b: float64 # y = a + b·x
  s: float64    # the residuals' standard deviation
  n: int
  xbar, sxx: float64

func fitLine(xs, ys: openArray[float64]): Line =
  ## least squares with outliers (beyond 3.5 median deviations) dropped, three rounds
  var keep = newSeq[bool](xs.len)
  for i in 0 ..< xs.len: keep[i] = true
  result = Line(a: NaN, b: NaN, s: Inf)
  for round in 0 .. 3:
    var (n, sx, sy, sxx, sxy) = (0.0, 0.0, 0.0, 0.0, 0.0)
    for i in 0 ..< xs.len:
      if keep[i]:
        n += 1
        sx += xs[i]
        sy += ys[i]
    if n < 3: return Line(a: NaN, b: NaN, s: Inf)
    let (xm, ym) = (sx / n, sy / n)
    for i in 0 ..< xs.len:
      if keep[i]:
        sxx += (xs[i] - xm) ^ 2
        sxy += (xs[i] - xm) * (ys[i] - ym)
    if sxx <= 0: return Line(a: NaN, b: NaN, s: Inf)
    let b = sxy / sxx
    let a = ym - b * xm
    var res: seq[float64] = @[]
    var ss = 0.0
    for i in 0 ..< xs.len:
      let r = ys[i] - a - b * xs[i]
      res.add abs(r)
      if keep[i]: ss += r * r
    result = Line(a: a, b: b, s: sqrt(ss / max(1.0, n - 2)), n: int(n), xbar: xm, sxx: sxx)
    let lim = 3.5 * 1.4826 * median(res)
    if round < 3:
      for i in 0 ..< xs.len: keep[i] = res[i] <= max(lim, 1e-9)

func readTop*(x: openArray[float32]; dtMs: float64; track: SweepTrack;
    extent: SweepExtent): TopReading =
  ## The reference's top frequency: the end of the sweep where its frequency is highest.
  ## `x` is the reference's samples (the first at 0 ms), `track` its frequency track and
  ## `extent` its measured sweep and flat part (where the plateau is; no shape is assumed).
  result = TopReading(hz: NaN)
  let n = x.len
  if n < 64 or not (dtMs > 0): return
  # mean squares: prefix sums
  var cum = newSeq[float64](n + 1)
  for j in 0 ..< n: cum[j + 1] = cum[j] + float64(x[j]) ^ 2
  func msq(j, k: int): float64 =
    ## the mean square of the `k` samples centred on `j` (shortened at the ends)
    let (a, b) = (max(0, j - k div 2), min(n, j + k div 2 + 1))
    (cum[b] - cum[a]) / float64(b - a)
  # the law over what the track measured, for a first top frequency (the window's size)
  var ts, fs: seq[float64] = @[]
  for m in 0 ..< track.len:
    let f = track.referenceHz[m]
    if not f.isNaN and f > 0:
      ts.add track.timeMs[m] / 1000
      fs.add f
  if ts.len < 20: return
  # a first law over every point the track measured (outliers dropped): the window's
  # size along the record, two periods at the frequency there
  var pre = fitLine(ts, fs)
  var preLn = fitLine(ts, fs.mapIt(ln(it)))
  func preAt(t: float64): float64 =
    result = if not pre.a.isNaN: pre.a + pre.b * t else: fs[0]
    if not preLn.a.isNaN and (pre.a.isNaN or preLn.s * (fs.sum / fs.len.float64) < pre.s):
      result = exp(preLn.a + preLn.b * t)
    result = clamp(result, 1.0, 500.0 / dtMs)
  let top0 = max(preAt(0.0), preAt(float64(n) * dtMs / 1000))
  # which end is the top: where the frequency is highest
  let dir = if preAt(float64(n) * dtMs / 1000) > preAt(0.0): 1 else: -1
  let (e0, e1) = (extent.flatStartMs, extent.flatEndMs)
  if e0.isNaN or e1.isNaN: return
  let jIn = clamp(int(round((if dir > 0: e0 else: e1) / dtMs)), 0, n - 1) # the far plateau edge
  let jOut = clamp(int(round((if dir > 0: e1 else: e0) / dtMs)), 0, n - 1) # the top-side edge
  if (jOut - jIn) * dir < 100: return
  # noise: the record has a quiet stretch (a quarter of a second or more of windows of 100 ms
  # within 2.5 times the quietest, which a ramp's foot is too short to give), steady (its two
  # halves alike within a factor of 3); it is that mean square over 0.75, for the minimum of
  # several windows of noise. Without such a stretch the noise is not known, and not assumed.
  let k0 = max(3, int(round(max(100.0, 4000.0 / top0) / dtMs)))
  let step = max(1, k0 div 4)
  var quiet: seq[float64] = @[]
  var jq = 0
  for j in countup(k0 div 2, n - 1 - k0 div 2, step):
    quiet.add msq(j, k0)
  var lowest0 = Inf
  for i, m in quiet:
    if m < lowest0:
      lowest0 = m
      jq = k0 div 2 + i * step
  var steady = 0
  for m in quiet:
    if m <= 2.5 * lowest0 + 1e-30: inc steady
  var noise = 0.0
  let (h1, h2) = (msq(jq - k0 div 4, k0 div 2), msq(jq + k0 div 4, k0 div 2))
  if steady >= 12 and max(h1, h2) <= 3.0 * min(h1, h2) + 1e-30: noise = lowest0 / 0.75
  # the plateau's level: the median mean square over the stretch before its top-side edge
  var lv: seq[float64] = @[]
  let kp = max(3, int(round(max(100.0, 4000.0 / top0) / dtMs)))
  let reach = min(abs(jOut - jIn), int(round(600.0 / dtMs)))
  for j in countup(0, reach - int(round(200.0 / dtMs)), max(1, kp div 4)):
    lv.add msq(jOut - dir * (j + int(round(200.0 / dtMs))), kp)
  if lv.len == 0: return
  let level = median(lv)
  if not (level > 0): return
  noise = min(noise, 0.5 * level)
  if noise < 1e-6 * level: noise = 0.0
  # the window: wide enough that the noise leaves the lowest level the fall is fitted to
  # (4 % of the plateau's power) readable
  let ratio = noise / level
  var k = max(3, int(round(6.0 / dtMs)))
  if ratio > 0:
    k = max(k, int(ceil(2.0 * (3.0 * ratio / 0.1) ^ 2)))
  k = min(k, max(3, int(round(400.0 / dtMs))))
  # the envelope: two boxes of about a period each (a triangle: the 2f ripple of one box
  # is gone), at least `k` samples wide in all
  var box = newSeq[float64](n)
  var width = newSeq[int](n)
  for j in 0 ..< n:
    width[j] = max(max(2, k div 2), int(round(1000.0 / (preAt(float64(j) * dtMs / 1000) * dtMs))))
    box[j] = msq(j, width[j])
  var cumBox = newSeq[float64](n + 1)
  for j in 0 ..< n: cumBox[j + 1] = cumBox[j] + box[j]
  var pe = newSeq[float64](n)
  for j in 0 ..< n:
    let (a, b) = (max(0, j - width[j] div 2), min(n, j + width[j] div 2 + 1))
    pe[j] = max(0.0, (cumBox[b] - cumBox[a]) / float64(b - a) - noise) / level
  # the plateau's top-side edge: from a point well inside it, to where the envelope falls
  # below half the plateau's level
  var jb = jOut - dir * int(round(200.0 / dtMs))
  while jb + dir >= 0 and jb + dir < n and pe[jb + dir] >= 0.5: jb += dir
  let (ja, jbb) = (min(jIn, jb), max(jIn, jb))
  # the law over the plateau's inner part
  ts.setLen 0
  fs.setLen 0
  let margin = (jbb - ja) div 20
  for m in 0 ..< track.len:
    let f = track.referenceHz[m]
    let j = int(round(track.timeMs[m] / dtMs))
    if not f.isNaN and f > 0 and j >= ja + margin and j <= jbb - margin:
      ts.add track.timeMs[m] / 1000
      fs.add f
  if ts.len < 20: return
  var lf: seq[float64] = @[]
  for f in fs: lf.add ln(f)
  let l1 = fitLine(ts, fs)
  let l2 = fitLine(ts, lf)
  if l1.a.isNaN and l2.a.isNaN: return
  func resid(l: Line; exponential: bool): float64 =
    var r: seq[float64] = @[]
    for i in 0 ..< ts.len:
      r.add abs((if exponential: exp(l.a + l.b * ts[i]) else: l.a + l.b * ts[i]) - fs[i])
    median(r)
  let useExp = l1.a.isNaN or (not l2.a.isNaN and resid(l2, true) < resid(l1, false))
  let law = if useExp: l2 else: l1
  func atT(t: float64): float64 = (if useExp: exp(law.a + law.b * t) else: law.a + law.b * t)
  func rateAt(t: float64): float64 =
    abs(if useExp: law.b * atT(t) else: law.b)
  let rising = dir > 0
  # the end: scan from the plateau's edge to the end of the sweep (the end in time for a
  # sweep that rises, its start for one that falls)
  let j0 = jb
  # the lowest level the fall is followed to: 3 % of the amplitude, or the noise's reach
  # (3 times the scatter of the mean square, from the noise and the window, as an amplitude)
  let lowest = max(FallLow, sqrt(3.0 * sqrt(2.0 / (1.5 * float64(k))) * ratio))
  # and the highest: a few times the lowest, so a clean fall is fitted close to its end, where
  # any shape is a power of the time left, and a noisy one over more of it
  let highest = clamp(4.0 * lowest, 0.12, FallHigh)
  var tAll, aAll: seq[float64] = @[]
  var j = j0
  var last = j0 # the last sample on the way down to the lowest level
  while j + dir >= 0 and j + dir < n:
    j += dir
    let a = sqrt(pe[j])
    if a < lowest: break
    last = j
    tAll.add float64(j) * dtMs / 1000
    aAll.add max(a, 1e-9)
  var tt, aa: seq[float64] = @[]
  for i in 0 ..< tAll.len:
    if aAll[i] <= highest:
      tt.add tAll[i]
      aa.add aAll[i]
  # a step: the envelope is down to the fit's levels within two windows of the plateau's edge,
  # so there is no ramp to fit (a tail or the noise is all that is left): the end is the edge
  let kneeSpan = max(3, width[min(n - 1, max(0, j0))])
  if tt.len > 0 and abs(tt[0] - float64(j0) * dtMs / 1000) < 2.0 * float64(kneeSpan) * dtMs / 1000:
    tt.setLen 0
    aa.setLen 0
  # the knee: a taper falls ever more steeply (in ln A) towards its end, a tail or a floor
  # leaves it as a gentle slope; the fall is kept to where its steepness (over `kneeSpan`
  # samples) stays above `SlopeKnee` of the steepest so far
  if tt.len > 2 * kneeSpan + 3:
    var steepest = 0.0
    var cut = tt.len
    for i in kneeSpan ..< tt.len - kneeSpan:
      let slope = abs(ln(aa[i - kneeSpan]) - ln(aa[i + kneeSpan])) /
        (2 * float64(kneeSpan) * dtMs / 1000)
      steepest = max(steepest, slope)
      if steepest > 0 and slope < SlopeKnee * steepest:
        cut = i
        break
    tt.setLen cut
    aa.setLen cut
  let tLast = if tt.len > 0: tt[^1] else: float64(last) * dtMs / 1000
  # the root of A^(1/q) = c (t_end - t) for each exponent q; a q is as good as the best when
  # its misfit exceeds the best's by no more than the noise's own share of it (the points'
  # amplitude scatter, from the noise level and the window, through y = A^(1/q))
  var roots, sses, allow, spans: seq[float64] = @[]
  var rootSe = newSeq[float64](Shapes.len)
  let nFit = tt.len
  var bestSse = Inf
  let kCorr = float64(max(k, 2 * kneeSpan)) # the points are one in this many independent
  if nFit >= 4:
    let kEff = float64(max(k, 3)) * 1.5
    for qi, (sine, q) in Shapes:
      var ys: seq[float64] = @[]
      var share = 0.0
      for a in aa:
        ys.add (if sine: arcsin(min(1.0, pow(a, 1.0 / q))) * 2.0 / PI else: pow(a, 1.0 / q))
        # scatter of the mean square (relative to the plateau's) and of the amplitude
        let sig = sqrt(2.0 / kEff * (ratio * ratio + 2.0 * ratio * a * a)) + 0.01 * a * a
        let da = sig / (2.0 * a)
        let slope = pow(a, 1.0 / q - 1.0) / q
        share += (da * (if sine: 2.0 / PI * slope / sqrt(max(1e-9, 1.0 - pow(a, 2.0 / q)))
          else: slope)) ^ 2
      let l = fitLine(tt, ys)
      if l.a.isNaN or l.b * float64(dir) > 0:
        roots.add NaN
        sses.add Inf
        spans.add 1.0
        allow.add 0.0
      else:
        let root = -l.a / l.b
        roots.add root
        sses.add l.s * l.s * float64(l.n)
        spans.add max(1e-9, abs(ys[0] - ys[^1]))
        allow.add share / float64(tt.len)
        bestSse = min(bestSse, sses[^1])
        # the root's standard error: the line's at y = 0 over the slope
        # (the scatter is the larger of the fit's own, which a handful of points understates,
        # and the noise's expected share; the points are one in `kCorr` independent)
        let neff = max(2.0, float64(l.n) / kCorr)
        let sy = max(l.s, sqrt(share / float64(tt.len)))
        rootSe[qi] = sy / abs(l.b) * sqrt(1.0 / neff + (root - l.xbar) ^ 2 * kCorr / l.sxx)
  var tEnd = NaN
  var sigT = Inf
  var why = ""
  let tEdge = float64(j0) * dtMs / 1000
  if nFit >= 4 and bestSse < Inf:
    # the exponents weighted by how well each fits (a Gaussian likelihood: the misfit above
    # the best one's over twice the noise's share of it; the points overlap, so only one in
    # `k` of them counts): the root is their mean, and their spread is part of its error
    var sw, sr, sr2, se2 = 0.0
    for qi in 0 ..< roots.len:
      if not roots[qi].isNaN:
        let w = exp(-(sses[qi] - bestSse) / (2.0 * max(allow[qi], 1e-12) * kCorr))
        sw += w
        sr += w * roots[qi]
        sr2 += w * roots[qi] * roots[qi]
        se2 += w * rootSe[qi] ^ 2
    tEnd = sr / sw
    let spread = sqrt(max(0.0, sr2 / sw - tEnd * tEnd))
    let se = sqrt(se2 / sw)
    # never short of the last point seen
    tEnd = if rising: max(tEnd, tLast) else: min(tEnd, tLast)
    # the power law is a model of the fall below the 20 % it was not fitted to: a share of the
    # stretch it is extended over is counted as its error
    # (a fit that is close to exact, a few thousandths of its span, is a model that holds)
    var bestAt = 0
    for qi in 0 ..< sses.len:
      if sses[qi] < sses[bestAt]: bestAt = qi
    let misfit = sqrt(bestSse / float64(nFit)) / spans[bestAt]
    let share = ModelShare * clamp(misfit / 0.02, 0.1, 1.0)
    sigT = sqrt(se ^ 2 + spread ^ 2 + (share * abs(tEnd - tLast)) ^ 2)
  else:
    # the fall is too short to measure (an abrupt end, or one lost in noise): the end is
    # where the envelope crosses half its plateau, give or take half the window
    tEnd = tEdge
    sigT = 0.5 * float64(k) * dtMs / 1000
    why = "the end of the sweep is too short or too noisy for its taper to be measured"
  let est = atT(tEnd)
  if not (est > 0 and est < Inf): return
  # the law's own error at the end
  let neff = max(3.0, float64(law.n) / Overlap)
  let sx = law.sxx / Overlap
  let seLaw = law.s * sqrt(1.0 / neff + (tEnd - law.xbar) ^ 2 / max(1e-12, sx))
  let seLawHz = if useExp: seLaw * est else: seLaw
  let u = Coverage * sqrt(seLawHz ^ 2 + (rateAt(tEnd) * sigT) ^ 2)
  result = TopReading(hz: est, uncertaintyHz: u, endMs: tEnd * 1000, rateHzS: rateAt(tEnd))
  if u > UncertainFraction * est:
    result.uncertain = true
    if why.len == 0:
      why = "the taper at its end is partly below the noise"
    result.why = why
