## How well two traces match, read off their cross-correlation, the same way for the
## Cross-correlation window and the Compare window (one pair gives one set of words).
##
## The match, the time shift and the rotation are processSEG's (`matchOf`, `peakAt`,
## `rotationOf`). This module says them in words.
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
from processSEG/vibroseis/matchpeak import ClearPeakToSidelobe, Match, MatchVerdict,
  MinSidelobeSpanMs, NoClearMatch, PreciseShiftMatch, PreciseShiftPeakToSidelobe,
  SidelobeGapMs, matchOf, mvClear, mvNoPeak, mvNothing, mvWeak, peakAt, rotationOf

export ClearPeakToSidelobe, Match, MatchVerdict, MinSidelobeSpanMs, NoClearMatch,
  PreciseShiftMatch, PreciseShiftPeakToSidelobe, SidelobeGapMs, matchOf, peakAt, rotationOf

const
  ReversedWithinDeg* = 30.0
    ## a rotation within this of 180 degrees is said to be reversed polarity
  NoRotationBelowDeg* = 10.0
    ## a rotation under this is not said (the traces are in phase)

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
