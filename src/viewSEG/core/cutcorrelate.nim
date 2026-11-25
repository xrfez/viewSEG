## What a slice that correlates each shot's record with a stored sweep asks of the recording
## and the sweep: the checks and the sentences, with no file read. The window runs them on
## the facts the reference archive keeps of the sweep (its length and interval); the job
## runs them again on the sweep it read.

import std/math
import processSEG/core/types
import correlatejobs

func recordSamplesOf(ms, dtMs: float64): int =
  int(round(ms / dtMs))

func sweepWords*(sweepSamples: int; sweepIntervalUs: float64): string =
  ## "8000 ms" style length of a sweep.
  msText(float64(sweepSamples) * sweepIntervalUs / 1000.0) & " ms"

const CorrelatedStartWhy* = "A correlated slice must begin at the shot: the window start " &
  "must be zero, or time zero would not be the shot."

func correlationWhy*(sweepSamples: int; sweepIntervalUs, recordMs, dtMs: float64): string =
  ## "" when records of `recordMs` of a recording sampled every `dtMs` ms can be correlated
  ## with a sweep of `sweepSamples` samples at `sweepIntervalUs`, else the sentence saying
  ## what is wrong: the sweep's sample interval is not the recording's, or the record is not
  ## longer than the sweep (it must be the sweep plus the listen time).
  let sweepDt = sweepIntervalUs / 1000.0
  if sweepSamples < 2:
    result = "The reference sweep has fewer than two samples."
  elif sweepDt.isNaN or sweepDt <= 0 or sweepDt == Inf:
    result = "The reference sweep has no sample interval."
  elif not sameInterval(sweepDt, dtMs):
    result = "The reference sweep is sampled every " & msText(sweepDt) &
      " ms and the recording every " & msText(dtMs) & " ms."
  elif recordSamplesOf(recordMs, dtMs) <= sweepSamples:
    result = "The record is " & msText(recordMs) & " ms long and the sweep " &
      sweepWords(sweepSamples, sweepIntervalUs) & ": the record must be the sweep plus " &
      "the listen time."

func listenSamples*(sweepSamples: int; recordMs, dtMs: float64): int =
  ## The samples a correlated record holds: the record less the sweep.
  recordSamplesOf(recordMs, dtMs) - sweepSamples

func listenWords*(sweepName: string; sweepSamples: int; recordMs, dtMs: float64): string =
  ## What a ticked window says: the listen time that will be written and the sweep.
  "Each record is correlated with the sweep '" & sweepName & "' and holds the listen time, " &
    msText(float64(listenSamples(sweepSamples, recordMs, dtMs)) * dtMs) & " ms (" &
    $listenSamples(sweepSamples, recordMs, dtMs) & " samples): the record less the sweep's " &
    msText(float64(sweepSamples) * dtMs) & " ms."
