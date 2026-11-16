## How a phase spectrum is drawn: the phase unwrapped along frequency (the
## default), the absolute value, the signed value within ±180°, or that line
## with its best straight line taken off (a pure time delay).
##
## processSEG reports phase wrapped into -pi .. pi. Nothing there unwraps a
## spectrum along frequency, so the unwrap lives here: a jump of more than
## half a turn between one drawn bin and the next is a whole turn the other
## way. Where the amplitude is too small for the phase to mean anything the
## point is left out (a gap). The unwrap does not run across that gap: it
## starts again on the far side, from the last drawn value.

import std/[math, strutils]

type
  PhasePicture* = enum
    ## Which picture of a phase spectrum is drawn.
    ppUnwrapped = "Unwrapped" ## the default, and the drop-down's first entry
    ppMagnitude = "Magnitude 0-180"
    ppSigned = "Signed +-180"
    ppDelayRemoved = "Delay removed"

const
  PhaseFloorDb* = -60.0
    ## A spectrum window draws no phase where the amplitude is below this,
    ## relative to that spectrum's peak: there the phase is noise.
  PhaseHelp* = "A sweep's phase climbs steeply because its delay grows with " &
    "frequency (a linear sweep is a parabola); for vibrator QC, read the phase " &
    "against the pilot in the vibrator signature plot."

func unwrapPhase*(phaseDeg: openArray[float64]; shown: openArray[bool]): seq[float64] =
  ## `phaseDeg` (per bin, -180 to 180) unwrapped along the bins that are
  ## `shown`. A jump of more than half a turn from the last drawn bin is a
  ## whole turn the other way. A bin that is not shown, or not a number, is
  ## left out: the next drawn bin starts again from the last drawn value,
  ## not from whatever sat in the gap. NaN where nothing is drawn.
  result = newSeq[float64](phaseDeg.len)
  var last = NaN
  var offset = 0.0
  for k in 0 ..< phaseDeg.len:
    let draw = k < shown.len and shown[k] and not phaseDeg[k].isNaN
    if not draw:
      result[k] = NaN
    else:
      if not last.isNaN:
        var v = phaseDeg[k] + offset
        while v - last > 180:
          offset -= 360
          v -= 360
        while v - last < -180:
          offset += 360
          v += 360
      result[k] = phaseDeg[k] + offset
      last = result[k]

func shownAbove*(amp: openArray[float64]; floorDb: float64): seq[bool] =
  ## Whether each amplitude is at or above `floorDb` relative to the largest
  ## finite one (a floor of -60 leaves out what is a thousandth of the peak
  ## or quieter). None are, when every amplitude is 0.
  result = newSeq[bool](amp.len)
  var peak = 0.0
  for a in amp:
    if a > peak and a < Inf: peak = a
  if peak <= 0: return
  let floor = peak * pow(10.0, floorDb / 20.0)
  for k, a in amp:
    result[k] = a >= floor and a < Inf

func delayWords*(ms: float64): string =
  ## `ms` as the readout says a removed delay: "delay 12.3 ms"; "" when it
  ## is not a number.
  if ms.isNaN: return ""
  var t = formatFloat(ms, ffDecimal, 1)
  if t == "-0.0": t = "0.0"
  "delay " & t & " ms"

func drawnPhase*(wrapped: openArray[float64]; shown: openArray[bool];
    hz: openArray[float64]; picture: PhasePicture): tuple[ys, signed: seq[float64];
    delayMs: float64] =
  ## The phase to draw, and the signed wrapped value at each bin (NaN where
  ## `shown` is not), for `picture`. Magnitude is the absolute value, 0 to
  ## 180. Signed is today's wrapped picture, with the gaps. Unwrapped has no
  ## jumps along frequency. Delay removed is that line minus its best
  ## straight line over the drawn bins (phase = a + b·f); `delayMs` is the
  ## delay that line is, in ms (a positive delay arrives later), NaN when
  ## fewer than two bins are drawn.
  let n = wrapped.len
  result.ys = newSeq[float64](n)
  result.signed = newSeq[float64](n)
  result.delayMs = NaN
  let unwrapped = unwrapPhase(wrapped, shown)
  for k in 0 ..< n:
    let draw = k < shown.len and shown[k] and not wrapped[k].isNaN
    if draw:
      result.signed[k] = wrapped[k]
    else:
      result.signed[k] = NaN
    case picture
    of ppMagnitude:
      result.ys[k] = if draw: abs(wrapped[k]) else: NaN
    of ppSigned:
      result.ys[k] = result.signed[k]
    of ppUnwrapped, ppDelayRemoved:
      result.ys[k] = unwrapped[k]
  if picture != ppDelayRemoved: return
  var count = 0
  var sx, sy, sxx, sxy = 0.0
  for k in 0 ..< n:
    if not result.ys[k].isNaN and k < hz.len and not hz[k].isNaN:
      let (f, p) = (hz[k], result.ys[k])
      inc count
      sx += f
      sy += p
      sxx += f * f
      sxy += f * p
  if count < 2: return
  let den = float64(count) * sxx - sx * sx
  if abs(den) < 1e-12 * max(1.0, sxx): return
  let b = (float64(count) * sxy - sx * sy) / den
  let a = (sy - b * sx) / float64(count)
  for k in 0 ..< n:
    if not result.ys[k].isNaN and k < hz.len and not hz[k].isNaN:
      result.ys[k] = result.ys[k] - (a + b * hz[k])
  # phase degrees = -360 * f_Hz * delay_seconds, so b = -360 * delay_s.
  result.delayMs = -b * 1000.0 / 360.0
