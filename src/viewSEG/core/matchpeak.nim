## How well two traces match, read off their cross-correlation, the same way for the
## Cross-correlation window and the Compare window (one pair gives one set of words).
##
## - the **match** is the correlation envelope's peak: the shape's match whatever the
##   constant phase turn of one trace (a trace that is the other's Hilbert transform
##   matches 1.00), found between samples by a parabola through the peak and its two
##   neighbours;
## - the **time shift** is that peak's place (a trace that is the other delayed by τ
##   peaks at +τ);
## - the **rotation** is the argument of the correlation's analytic signal at the peak,
##   in degrees (90 for a quarter turn, 180 for a mirror image), taken from the
##   correlation over every lag so that the lags shown do not change it;
## - a peak under `NoClearMatch` is no clear match: no shift, no direction, no
##   rotation is said; a peak at an end of the lags is no peak: the shift is past them.
##
## Said in words: a rotation within `NoRotationBelowDeg` of 0 is not mentioned, one
## within `ReversedWithinDeg` of 180 is "reversed polarity", any other is "rotated 90°".

import std/[math, strutils]
import processSEG/fft/hilbert
import processSEG/core/workspace
import processSEG/vibroseis/sweeptrack

const
  NoClearMatch* = 0.3
    ## an envelope peak below this is no clear match: no shift, no direction is said
  ReversedWithinDeg* = 30.0
    ## a rotation within this of 180 degrees is said to be reversed polarity
  NoRotationBelowDeg* = 10.0
    ## a rotation under this is not said (the traces are in phase)

type
  MatchVerdict* = enum
    mvNothing ## no value to go by
    mvNoPeak  ## the peak is at an end of the lags: the shift is past them
    mvWeak    ## the peak is under `NoClearMatch`
    mvClear

  Match* = object
    verdict*: MatchVerdict
    match*: float64       ## the envelope's peak, at most 1; NaN for `mvNothing`
    shiftMs*: float64     ## the peak's place, NaN unless `mvClear`
    rotationDeg*: float64 ## -180 to 180, NaN until `withRotation` or when it cannot be read

func peakAt*(y: openArray[float64]; i: int): tuple[offset, value: float64] =
  ## The vertex of the parabola through `y[i-1]`, `y[i]`, `y[i+1]` (`i` a maximum
  ## inside the array): its place in samples from `i` (within half a sample) and its
  ## height. A flat or noisy top (no downward curve) is the sample itself.
  result = (0.0, y[i])
  if i < 1 or i + 1 >= y.len: return
  let den = y[i - 1] - 2 * y[i] + y[i + 1]
  if not (den < 0): return
  let d = clamp(0.5 * (y[i - 1] - y[i + 1]) / den, -0.5, 0.5)
  result = (d, y[i] - 0.25 * (y[i - 1] - y[i + 1]) * d)

func matchOf*(envelope, lagsMs: openArray[float64]): Match =
  ## The match and the shift from a correlation's envelope against its lags (ms,
  ## evenly spaced). NaN values are not looked at.
  result = Match(verdict: mvNothing, match: NaN, shiftMs: NaN, rotationDeg: NaN)
  var best = -1
  for i in 0 ..< min(envelope.len, lagsMs.len):
    if not envelope[i].isNaN and (best < 0 or envelope[i] > envelope[best]): best = i
  if best < 0: return
  let (offset, top) = peakAt(envelope, best)
  result.match = min(top, 1.0)
  if best == 0 or best == min(envelope.len, lagsMs.len) - 1: result.verdict = mvNoPeak
  elif result.match < NoClearMatch: result.verdict = mvWeak
  else:
    result.verdict = mvClear
    let step = (lagsMs[best + 1] - lagsMs[best - 1]) / 2
    result.shiftMs = lagsMs[best] + offset * step

proc rotationOf*(c: openArray[float32]; dtMs: float64; at: int; offset: float64): float64 =
  ## The phase turn (degrees) of the correlation `c` (over every lag, lag 0 in the
  ## middle) at its peak: the argument of its analytic signal at sample `at`, taken
  ## `offset` (within half a sample) towards the next one by its phase's step. NaN
  ## when it cannot be read.
  result = NaN
  if c.len < 2 or at notin 0 ..< c.len: return
  let near = if offset < 0: at - 1 elif offset > 0: at + 1 else: at
  if near notin 0 ..< c.len: return
  try:
    let hp = initHilbertPlan(float32, c.len)
    var ws = initWorkspace()
    ws.reserve(hp.workspaceSize)
    var env, phase, hz = newSeq[float64](c.len)
    hp.analyticInto(c, dtMs, env, phase, hz, ws, -120.0)
    if phase[at].isNaN or phase[near].isNaN: return
    result = wrapDeg(phase[at] + abs(offset) * wrapDeg(phase[near] - phase[at]))
  except ValueError:
    discard

func rotationWords*(rot: float64): string =
  ## "" for a rotation in phase (within `NoRotationBelowDeg`) or unknown,
  ## "reversed polarity" within `ReversedWithinDeg` of a half turn, else "rotated 90°".
  if rot.isNaN or abs(rot) < NoRotationBelowDeg: ""
  elif abs(rot) > 180 - ReversedWithinDeg: "reversed polarity"
  else: "rotated " & $int(round(rot)) & "°"

func rotationCell*(rot: float64): string =
  ## A rotation as a table cell: whole degrees, 180 (never -180); "-" for none.
  if rot.isNaN: return "-"
  let d = int(round(rot))
  if d == -180: "180" elif d == 0: "0" else: $d

func signedMs*(x: float64): string =
  ## "+2.0", "-2.0", "0.0": milliseconds with their sign.
  let t = formatFloat(x, ffDecimal, 1)
  if t == "0.0" or t == "-0.0": "0.0"
  elif x > 0: "+" & t
  else: t

func twoDecimals*(x: float64): string = formatFloat(x, ffDecimal, 2)

func noPeakWords*(shownMs: float64): string =
  ## "no peak within ±250.0 ms: widen the time shifts".
  "no peak within ±" & formatFloat(shownMs, ffDecimal, 1) & " ms: widen the time shifts"

func weakWords*(m: Match): string =
  ## "no clear match (0.06)".
  "no clear match (" & twoDecimals(m.match) & ")"
