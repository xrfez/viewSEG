## How a phase, or a phase difference, is drawn so that it never alternates
## between -180 and 180: one rule for every plot of one (the envelope's phase
## against the reference, the correlation's phase difference, the vibrator
## signature's phase, the spectrum windows' signed picture).
##
## A phase is only known modulo a turn, so a difference that sits at 180°
## (a reversed trace) reads as +180 at one sample and -180 at the next. Two
## ways to show it:
## - **Absolute**: the size of the phase, 0 to 180. The sign is the readout's
##   bracketed value. The default: how far out of phase, whichever way.
## - **Signed**: each value within ±180° of the curve's circular mean
##   (processSEG's `circularMeanDeg`), so a reversed trace is a flat line at
##   180 and the axis reads plain numbers around that centre.
##
## The readouts under a plot say which is shown: absolute, the mean of the sizes
## (`meanText`); signed, the circular mean.

import std/[math, strutils]
import processSEG/fft/spectrum

type
  PhaseShow* = enum
    ## Which way a phase is shown.
    psAbsolute = "Absolute"
    psSigned = "Signed"

const
  PhaseShowTip* = "Absolute: how far out of phase, 0 to 180 degrees, whichever way. " &
    "Signed: the phase around its own mean, so a reversed trace is a flat line at 180 " &
    "and not a jump between -180 and 180."
  PhaseShowWords*: array[PhaseShow, string] = [
    psAbsolute: "absolute (0 to 180 degrees; the bracketed value is the signed one)",
    psSigned: "signed, within 180 degrees either side of its circular mean"]

func wrapTurn*(deg: float64): float64 =
  ## `deg` wrapped to (-180, 180]; NaN stays NaN.
  if deg.isNaN: return deg
  let r = floorMod(deg, 360.0)
  if r > 180: r - 360 else: r

func centreOf*(deg: openArray[float64]): float64 =
  ## The circular mean of the finite values, degrees; 0 when there is none
  ## (or when they cancel).
  let m = circularMeanDeg(deg).meanDeg
  if m.isNaN: 0.0 else: m

func signedAround*(deg: openArray[float64]; centre: float64): seq[float64] =
  ## Each value within ±180 of `centre` (the same angle, a turn or two off).
  result = newSeq[float64](deg.len)
  for k, v in deg:
    result[k] = if v.isNaN: v else: centre + wrapTurn(v - centre)

func shownPhase*(deg: openArray[float64]; mode: PhaseShow):
    tuple[ys, signed: seq[float64]; centre: float64] =
  ## `deg` as `mode` draws it: `ys`, and the signed value within ±180 of 0 at
  ## each point (`signed`, for the readout's brackets); `centre` is what Signed
  ## is around (0 for Absolute).
  result.signed = newSeq[float64](deg.len)
  for k, v in deg: result.signed[k] = wrapTurn(v)
  case mode
  of psAbsolute:
    result.ys = newSeq[float64](deg.len)
    for k, v in result.signed: result.ys[k] = abs(v)
  of psSigned:
    result.centre = centreOf(deg)
    result.ys = signedAround(deg, result.centre)

func meanOfPhase*(deg: openArray[float64]; mode: PhaseShow): float64 =
  ## The mean the readouts say: absolute, of the sizes; signed, the circular
  ## mean. NaN when there is no number.
  case mode
  of psSigned:
    result = circularMeanDeg(deg).meanDeg
  of psAbsolute:
    var sum = 0.0
    var n = 0
    for v in deg:
      if not v.isNaN and v.classify != fcInf and v.classify != fcNegInf:
        sum += abs(wrapTurn(v))
        inc n
    result = if n == 0: NaN else: sum / float64(n)

func meanText*(deg: openArray[float64]; mode: PhaseShow): string =
  ## "mean 12.3°", "mean |phase| 12.3°"; "" when there is none.
  let m = meanOfPhase(deg, mode)
  if m.isNaN: return ""
  (if mode == psAbsolute: "mean |phase| " else: "mean ") & formatFloat(m, ffDecimal, 1) & "°"
