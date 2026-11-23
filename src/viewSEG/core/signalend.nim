## A trace that cannot be matched to the whole of its reference: shorter in time than it,
## or whose signal stops before the reference does (a vibrator that stopped shaking).
## Pure functions: the analysis windows (Vibrator signature, Cross-correlation,
## Envelope) put their words in the first line of their note, in the warning colour.
##
## Where the signal ends is processSEG's (`signalEndMs`, `blockLevels`, `lastLoudMs`,
## `RippleFraction`). This module says it in words.
##
## - `shortWords`: the record ends before the reference does ("trace is 9 840 ms, the
##   reference is 12 000 ms: the last 2 160 ms of the reference have no data"); "" when
##   it does not;
## - `endWords`: the signal ends at about a time well before the reference's end. The
##   Vibrator signature takes the end from processSEG's sweep tracker (the last point
##   where the force's fundamental is measured at a worthwhile level,
##   `lastLoudMs` on `amplitude[0]`), and the reference's from the tracker's `extent`;
##   the other two have no tracker, so they look at the trace itself (`signalEndMs`).
##
## A signal that ends within `SlackMs` or 3 % of the reference's end (its taper, the
## tracker's half window) is taken to end with it. A comparison is made against where
## the reference's own signal ends, not against its length.

import std/math
from processSEG/qc/signalend import RippleFraction, blockLevels, lastLoudMs, signalEndMs

export RippleFraction, blockLevels, lastLoudMs, signalEndMs

const
  SlackMs = 150.0 ## the end of a signal may fall this much short of the reference's
  SlackFraction = 0.03

func spaced*(ms: float64): string =
  ## A time in ms for words: whole when it is (12000 is "12 000"), else with one
  ## decimal ("9 840.5"), the thousands set off by a space.
  let tenths = int64(round(ms * 10))
  let whole = tenths div 10
  let frac = tenths mod 10
  var digits = $abs(whole)
  var grouped = ""
  for i, c in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: grouped.add ' '
    grouped.add c
  result = (if tenths < 0: "-" else: "") & grouped
  if frac != 0: result.add "." & $abs(frac)

func shortWords*(who: string; traceMs, referenceMs: float64): string =
  ## "trace is 9 840 ms, the reference is 12 000 ms: the last 2 160 ms of the reference
  ## have no data"; "" when the trace is not shorter than the reference (or either is
  ## not known).
  if traceMs.isNaN or referenceMs.isNaN or not (traceMs < referenceMs): return ""
  who & " is " & spaced(traceMs) & " ms, the reference is " & spaced(referenceMs) &
    " ms: the last " & spaced(referenceMs - traceMs) & " ms of the reference have no data"

func endWords*(who: string; endMs, referenceEndMs, limitMs: float64): string =
  ## "signal ends at about 7 600 ms; the reference runs to 12 000 ms" when a signal that
  ## ended at `endMs` stops short of the reference's end by more than the slack; the
  ## trace's own end (`limitMs`: the reference's end is no sooner than it, or it is not
  ## the reference that cuts the comparison) is not a signal's early stop. "" otherwise.
  if endMs.isNaN or referenceEndMs.isNaN: return ""
  let target = if limitMs.isNaN: referenceEndMs else: min(referenceEndMs, limitMs)
  if endMs >= target - max(SlackMs, SlackFraction * target): return ""
  (if who.len > 0: who & ": " else: "") & "signal ends at about " & spaced(endMs) &
    " ms; the reference runs to " & spaced(referenceEndMs) & " ms"

func endWords*(who: string; x: openArray[float32]; dtMs, referenceEndMs: float64;
    shiftMs = 0.0): string =
  ## `endWords` for a trace `x` (no tracker): the end found in its blocks, against
  ## where the reference's own signal ends (`signalEndMs` of the reference) plus the
  ## trace's time shift against it (a trace that arrives 300 ms early ends 300 ms early).
  if x.len < 4: return ""
  endWords(who, signalEndMs(x, dtMs), referenceEndMs + shiftMs, float64(x.len) * dtMs)
