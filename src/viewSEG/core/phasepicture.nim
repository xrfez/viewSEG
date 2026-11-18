## How a phase spectrum is drawn: the phase unwrapped along frequency (the
## default), the absolute value, the signed value within ±180°, or that line
## with its best straight line taken off (a pure time delay).
##
## processSEG reports phase wrapped into -pi .. pi; its `unwrapPhaseInto` and
## `removeDelayInto` unwrap it along frequency and take the delay off: a jump
## of more than half a turn between one drawn bin and the next is a whole
## turn the other way. Where the amplitude is too small for the phase to mean
## anything the point is left out (a gap). The unwrap does not run across that gap: it
## starts again on the far side, from the last drawn value.

import std/[math, strutils]
import processSEG/fft/spectrum
import phaseshow

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
  PhaseMeaning*: array[PhasePicture, string] = [
    ppUnwrapped: "The phase followed along frequency without jumps: a delay is a " &
      "straight slope, a sweep a curve.",
    ppMagnitude: "The size of the phase, 0 to 180 degrees, whatever its sign.",
    ppSigned: "The phase within 180 degrees either side of its circular mean " &
      "(the shared signed rule): a reversed trace is a flat line at 180, not a jump " &
      "between -180 and 180.",
    ppDelayRemoved: "The unwrapped phase minus its best straight line, a pure time " &
      "delay: what is left is the phase's own shape."]
    ## One line per picture: what it shows, for the drop-down's list.

func phasePictureTip*(p: PhasePicture): string =
  ## The tooltip of a phase picture's drop-down: the selected picture, then
  ## how to read a sweep's phase.
  "Phase: " & $p & ". " & PhaseHelp

func unwrapPhase*(phaseDeg: openArray[float64]; shown: openArray[bool]): seq[float64] =
  ## `phaseDeg` (per bin, -180 to 180) unwrapped along the bins that are
  ## `shown` (processSEG's `unwrapPhaseInto`). A bin that is not shown, or not
  ## a number, is left out: the next drawn bin starts again from the last
  ## drawn value. NaN where nothing is drawn.
  result = newSeq[float64](phaseDeg.len)
  var on = newSeq[bool](phaseDeg.len)
  for k in 0 ..< on.len:
    on[k] = k < shown.len and shown[k]
  unwrapPhaseInto(phaseDeg, on, result)

func shownAbove*(amp: openArray[float64]; floorDb: float64;
    peakOf: openArray[float64] = []): seq[bool] =
  ## Whether each amplitude is at or above `floorDb` relative to the largest
  ## finite one (a floor of -60 leaves out what is a thousandth of the peak
  ## or quieter). None are, when every amplitude is 0. `peakOf`, when given, is the
  ## series the largest is taken from (a finer grid's floor is that of its bins).
  result = newSeq[bool](amp.len)
  var peak = 0.0
  for a in (if peakOf.len > 0: peakOf else: amp):
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
  ## 180. Signed is within 180 either side of the drawn bins' circular mean
  ## (`phaseshow`), with the gaps. Unwrapped has no
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
      result.ys[k] = result.signed[k] # centred below
    of ppUnwrapped, ppDelayRemoved:
      result.ys[k] = unwrapped[k]
  if picture == ppSigned:
    result.ys = signedAround(result.signed, centreOf(result.signed))
  if picture != ppDelayRemoved: return
  # The line is taken off the drawn bins that have a frequency.
  var on = newSeq[bool](n)
  var freq = newSeq[float64](n)
  for k in 0 ..< n:
    freq[k] = if k < hz.len: hz[k] else: NaN
    on[k] = not unwrapped[k].isNaN
  var flat = newSeq[float64](n)
  result.delayMs = removeDelayInto(unwrapped, freq, on, flat)
  if not result.delayMs.isNaN:
    result.ys = flat
