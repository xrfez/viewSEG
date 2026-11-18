## Where a stored reference lies against the unit's recorded reference trace, found by
## cross-correlation: the vibrator signature measures the unit's force against the
## stored reference, and a sweep that began a lead-in after the record's first sample
## (or before it) is misread by the whole lead-in unless the two are put in step.
##
## - `alignStored` correlates the recorded reference with the stored one and takes the
##   envelope's peak (`matchOf`, the way the Cross-correlation window reads it) as the
##   shift: positive when the recorded trace comes after the stored one starts. A peak
##   that is not clear, or that lies at an end of the lags, gives no shift (the two are
##   taken to start together).
## - `placed` puts the stored samples where the shift says: zeros before them for a
##   positive one, the samples before the record's first dropped for a negative one.
## - Without a recorded reference there is nothing to align to: `startedAt` places the
##   stored window at its own `timeStart`, which the archive keeps.
##
## Pure; never raises.

import std/math
import processSEG/vibroseis/crosscorrelate
import processSEG/core/workspace
import matchpeak

const
  MaxAlignShiftMs* = 2000.0 ## the largest lead-in or lag looked for, either way

type
  Alignment* = object
    found*: bool      ## a clear peak: `shiftMs` is the shift
    shiftMs*: float64 ## the recorded reference's lead over the stored one's start; NaN: none
    match*: float64   ## the envelope's peak, 1 for identical shapes; NaN: none
    words*: string    ## "stored reference aligned to the recorded reference: +115 ms"

func shiftWords*(shiftMs: float64): string =
  ## "+115 ms", "-17 ms", "0 ms": the shift to a whole millisecond (the signs shown).
  let w = int64(round(shiftMs))
  if w > 0: "+" & $w & " ms" elif w < 0: $w & " ms" else: "0 ms"

proc alignStored*(recorded, stored: openArray[float32];
    dtMs: float64): Alignment =
  ## The shift of `stored` (a reference as the archive holds it) against `recorded` (the
  ## unit's own reference trace), both at `dtMs`. Not found for traces too short to
  ## correlate, or with no clear peak.
  result = Alignment(found: false, shiftMs: NaN, match: NaN,
    words: "the stored reference and the recorded reference could not be aligned (no " &
    "clear correlation peak): the two are taken to start together")
  let n = max(recorded.len, stored.len)
  if recorded.len < 8 or stored.len < 8 or not (dtMs > 0 and dtMs < Inf):
    return
  try:
    let lag = clamp(MaxAlignShiftMs, dtMs, float64(n - 1) * dtMs)
    let cp = initCrossCorrelationPlan(float32, lag, dtMs, n)
    var ws = initWorkspace()
    ws.reserve(cp.workspaceSize)
    var c, e = newSeq[float32](cp.lags)
    cp.crossCorrelateInto(recorded, stored, c, e, ws)
    var envelope, lagsMs = newSeq[float64](cp.lags)
    for i in 0 ..< cp.lags:
      envelope[i] = float64(e[i])
      lagsMs[i] = cp.lagMs(i)
    let m = matchOf(envelope, lagsMs)
    result.match = m.match
    if m.verdict == mvClear:
      result.found = true
      result.shiftMs = m.shiftMs
      result.words = "stored reference aligned to the recorded reference: " &
        shiftWords(m.shiftMs)
  except ValueError, AssertionDefect:
    discard

func placed*(stored: openArray[float32]; wholeSamples: int): seq[float32] =
  ## `stored` starting `wholeSamples` after the record's first sample (zeros before it);
  ## a negative number drops that many of its first samples.
  if wholeSamples >= 0:
    result = newSeq[float32](wholeSamples + stored.len)
    for i, v in stored: result[wholeSamples + i] = v
  else:
    let drop = min(-wholeSamples, stored.len)
    result = newSeq[float32](stored.len - drop)
    for i in 0 ..< result.len: result[i] = stored[drop + i]

func startedAt*(stored: openArray[float32]; startMs, dtMs: float64): seq[float32] =
  ## `stored` placed at its own start time (an archive window's From), no alignment.
  if startMs.isNaN or not (dtMs > 0): return @stored
  placed(stored, int(round(startMs / dtMs)))

func startsTogether*(startMs: float64): string =
  ## What the note says when there is no recorded reference to align to.
  if startMs.isNaN or abs(startMs) < 1e-9:
    "no recorded reference to align the stored one to: the stored reference and the " &
      "traces are taken to start together"
  else:
    "no recorded reference to align the stored one to: the stored reference starts at " &
      "its own stored time, " & shiftWords(startMs) &
          ", and the traces and it are " &
      "taken to share the record's first sample"
