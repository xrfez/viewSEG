## The top frequency of a reference sweep, read from its own samples, with the
## reading's uncertainty: where the sweep ends, and how sure that end is.
##
## The reading is processSEG's (`readTop`, `TopReading`). `why` is the sentence
## a window shows for a `TopReason` ("" when the reading is sure enough).

from processSEG/vibroseis/sweepedge import UncertainFraction, TopReason, tpNone,
  tpNoSweep, tpTaperShort, tpNoTop, tpNotSure, TopReading, notBefore, Weighed,
  weighShapes, readTop

export UncertainFraction, TopReason, TopReading, notBefore, Weighed, weighShapes,
  readTop

func why*(r: TopReason): string =
  ## The sentence the windows show for `r`; "" for `tpNone` (the reading is sure enough).
  case r
  of tpNone: ""
  of tpNoSweep: "the reference has no sweep to read"
  of tpTaperShort: "the end taper of the sweep is too short or too noisy to be fitted"
  of tpNoTop: "the sweep's frequency law gives no top"
  of tpNotSure: "the end of the sweep is not sure enough"
