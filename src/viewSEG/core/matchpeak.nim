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
    ## an envelope peak at or above this is a clear match
  ClearPeakToSidelobe* = 4.5
    ## so is a lower one standing at least this many times above the envelope's level
    ## elsewhere (a noisy sweep: the shift is good though the coefficient is small). Measured:
    ## 4 s sweeps at -20 dB per sample stand 5.0 to 5.3 times above it, a Ricker at -20 dB
    ## 2.4; the envelope of white noise exceeds `x` times its RMS with probability e^-x², so
    ## 4.5 is a false peak in 1 of 10^8 lags
  SidelobeGapMs* = 20.0
    ## "elsewhere" is the envelope's RMS beyond this far from the peak ...
  MinSidelobeSpanMs* = 40.0
    ## ... when at least this much of the lags computed lie there; else the coefficient alone
  PreciseShiftPeakToSidelobe* = 20.0
    ## a shift is given to 0.1 ms above this ratio ...
  PreciseShiftMatch* = 0.7
    ## ... or at this match (a clean narrow-band trace has a broad envelope and a low ratio
    ## but a coefficient near 1); else to the whole millisecond, with "about"
  ReversedWithinDeg* = 30.0
    ## a rotation within this of 180 degrees is said to be reversed polarity
  NoRotationBelowDeg* = 10.0
    ## a rotation under this is not said (the traces are in phase)

type
  MatchVerdict* = enum
    mvNothing ## no value to go by
    mvNoPeak  ## the peak is at an end of the lags: the shift is past them
    mvWeak    ## the peak is under `NoClearMatch` and does not stand out either
    mvClear

  Match* = object
    verdict*: MatchVerdict
    match*: float64       ## the envelope's peak, at most 1; NaN for `mvNothing`
    shiftMs*: float64     ## the peak's place, NaN unless `mvClear`
    rotationDeg*: float64 ## -180 to 180, NaN until `rotationOf` sets it or when it cannot be read
    at*: int              ## the sample of the envelope's peak, -1 for none
    offset*: float64      ## the peak's place from it in samples, within half a sample
    sidelobe*: float64    ## the peak over the envelope's RMS elsewhere; NaN when not known
    about*: bool          ## the shift is only good to a millisecond (clear by the ratio alone, or
                          ## a ratio under `PreciseShiftPeakToSidelobe`)

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

func sidelobeRatio(envelope, lagsMs: openArray[float64]; best: int; peak: float64): float64 =
  ## `peak` over the RMS of the envelope beyond `SidelobeGapMs` of sample `best`, within the
  ## lags computed; NaN when under `MinSidelobeSpanMs` of them lie there (or the RMS is 0: Inf).
  result = NaN
  let n = min(envelope.len, lagsMs.len)
  if n < 3: return
  let step = abs(lagsMs[n - 1] - lagsMs[0]) / float64(n - 1)
  var sum = 0.0
  var count = 0
  for i in 0 ..< n:
    if not envelope[i].isNaN and abs(lagsMs[i] - lagsMs[best]) > SidelobeGapMs:
      sum += envelope[i] * envelope[i]
      inc count
  if float64(count) * step < MinSidelobeSpanMs or count == 0: return
  let rms = sqrt(sum / float64(count))
  result = if rms > 0: peak / rms else: Inf

func matchOf*(envelope, lagsMs: openArray[float64]): Match =
  ## The match and the shift from a correlation's envelope against its lags (ms,
  ## evenly spaced). NaN values are not looked at. A peak is clear at `NoClearMatch`, or
  ## at `ClearPeakToSidelobe` times the envelope elsewhere; that is checked before the
  ## peak's place, so noise peaking on the last lag is "no clear match", not "no peak".
  result = Match(verdict: mvNothing, match: NaN, shiftMs: NaN, rotationDeg: NaN, at: -1,
    sidelobe: NaN)
  var best = -1
  let n = min(envelope.len, lagsMs.len)
  for i in 0 ..< n:
    if not envelope[i].isNaN and (best < 0 or envelope[i] > envelope[best]): best = i
  if best < 0: return
  let (offset, top) = peakAt(envelope, best)
  result.match = min(top, 1.0)
  (result.at, result.offset) = (best, offset)
  result.sidelobe = sidelobeRatio(envelope, lagsMs, best, top)
  let byRatio = not result.sidelobe.isNaN and result.sidelobe >= ClearPeakToSidelobe
  if result.match < NoClearMatch and not byRatio: result.verdict = mvWeak
  elif best == 0 or best == n - 1: result.verdict = mvNoPeak
  else:
    result.verdict = mvClear
    let step = (lagsMs[best + 1] - lagsMs[best - 1]) / 2
    result.shiftMs = lagsMs[best] + offset * step
    result.about = result.match < NoClearMatch or (result.match < PreciseShiftMatch and
      (result.sidelobe.isNaN or result.sidelobe < PreciseShiftPeakToSidelobe))

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

func shownShiftMs*(m: Match): float64 =
  ## The shift as it is said: to 0.1 ms, or to the whole millisecond when `about`.
  if m.about: round(m.shiftMs) else: m.shiftMs

func shiftText*(m: Match): string =
  ## "+3.0", "-1.0", "0.0"; "about +4" (whole milliseconds) when the shift is `about`.
  if m.about:
    let w = int(round(m.shiftMs))
    "about " & (if w > 0: "+" & $w else: $w)
  else: signedMs(m.shiftMs)

func shiftSize*(m: Match): string =
  ## How far, without a sign: "3.0 ms", or "about 4 ms".
  if m.about: "about " & $abs(int(round(m.shiftMs))) & " ms"
  else: formatFloat(abs(m.shiftMs), ffDecimal, 1) & " ms"

func inStep*(m: Match): bool =
  ## Whether the shift reads zero as it is said.
  if m.about: int(round(m.shiftMs)) == 0 else: signedMs(m.shiftMs) == "0.0"

func twoDecimals*(x: float64): string = formatFloat(x, ffDecimal, 2)

func noPeakWords*(shownMs: float64): string =
  ## "no peak within ±250.0 ms: widen the time shifts".
  "no peak within ±" & formatFloat(shownMs, ffDecimal, 1) & " ms: widen the time shifts"

func weakWords*(m: Match): string =
  ## "no clear match (0.06)".
  "no clear match (" & twoDecimals(m.match) & ")"

func verdictWords*(m: Match; shownMs: float64; direction: string): string =
  ## The verdict as both windows word it: "best match 1.00 at +3.0 ms (arrives 3.0 ms
  ## after the reference; rotated 90°)", "no clear match (0.06)", "no peak within
  ## ±250.0 ms: widen the time shifts"; "" for no value. `direction` is the shift in the
  ## window's own words, said only for a clear match.
  case m.verdict
  of mvNothing: ""
  of mvNoPeak: noPeakWords(shownMs)
  of mvWeak: weakWords(m)
  of mvClear:
    let turn = rotationWords(m.rotationDeg)
    "best match " & twoDecimals(m.match) & " at " & m.shiftText & " ms (" & direction &
      (if turn.len > 0: "; " & turn else: "") & ")"
