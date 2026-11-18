## A trace that cannot be matched to the whole of its reference: shorter in time than it,
## or whose signal stops before the reference does (a vibrator that stopped shaking).
## Pure functions: the analysis windows (Vibrator signature, Cross-correlation,
## Envelope) put their words in the first line of their note, in the warning colour.
##
## - `shortWords`: the record ends before the reference does ("trace is 9 840 ms, the
##   reference is 12 000 ms: the last 2 160 ms of the reference have no data"); "" when
##   it does not;
## - `endWords`: the signal ends at about a time well before the reference's end. The
##   Vibrator signature takes the end from processSEG's sweep tracker (the last point
##   where the force's fundamental is measured at a worthwhile level,
##   `lastLoudMs` on `amplitude[0]`), and the reference's from the tracker's `extent`;
##   the other two have no tracker, so they look at the trace itself, in blocks
##   (`blockLevels`: the largest |sample| of each 100 ms).
##
## A signal's end is the last block whose level is at least a tenth of the 90th percentile
## of the levels (so a short burst of noise, or a long quiet tail, does not set it); a
## signal that ends within `SlackMs` or 3 % of the reference's end (its taper, the
## tracker's half window) is taken to end with it.

import std/[algorithm, math]

const
  EndFraction = 0.1 ## a level below this fraction of the typical one is silence
  SlackMs = 150.0   ## the end of a signal may fall this much short of the reference's
  SlackFraction = 0.03
  BlockMs = 100.0

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

func blockLevels*(x: openArray[float32]; dtMs: float64): (seq[float64], float64) =
  ## The largest |sample| of each block of about 100 ms, and the block's length in ms.
  let n = max(2, int(BlockMs / max(dtMs, 1e-9)))
  var levels: seq[float64] = @[]
  var i = 0
  while i < x.len:
    var top = 0.0
    for j in i ..< min(i + n, x.len):
      let v = abs(float64(x[j]))
      if not v.isNaN and v > top: top = v
    levels.add top
    i += n
  (levels, float64(n) * dtMs)

func lastLoudMs*(levels: openArray[float64]; timesMs: openArray[float64]; blockMs = 0.0):
    float64 =
  ## The time (ms) at which the signal ends: that of the last level at least a tenth of
  ## the 90th percentile of the levels, plus `blockMs` (a block's length); NaN when
  ## there is no such level (nothing but silence, or nothing measured). NaN levels are
  ## not measured.
  var sorted: seq[float64] = @[]
  for v in levels:
    if not v.isNaN: sorted.add v
  if sorted.len == 0: return NaN
  sorted.sort()
  let typical = sorted[min(sorted.high, int(float64(sorted.len) * 0.9))]
  if not (typical > 0): return NaN
  for i in countdown(min(levels.high, timesMs.high), 0):
    if not levels[i].isNaN and levels[i] >= EndFraction * typical:
      return timesMs[i] + blockMs
  NaN

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

func endWords*(who: string; x: openArray[float32]; dtMs, referenceEndMs: float64): string =
  ## `endWords` for a trace `x` (no tracker): the end found in its blocks.
  if x.len < 4: return ""
  let (levels, length) = blockLevels(x, dtMs)
  var times = newSeq[float64](levels.len)
  for i in 0 ..< levels.len: times[i] = float64(i) * length
  let ends = min(lastLoudMs(levels, times, length), float64(x.len) * dtMs)
  endWords(who, ends, referenceEndMs, float64(x.len) * dtMs)
