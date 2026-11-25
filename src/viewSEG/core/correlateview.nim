## The prepared correlation of one raw file.
##
## `initCorrelateView` fills one. A session holds it as a `ref` so reader
## threads share the plan. The fields are that state: a caller does not build
## a view by setting them.

import std/[sets, tables]
import processSEG

type
  CorrelateView* = object
    ## What correlating any trace of one raw file needs. The plan is a `ref`
    ## only so threads can share it; everything else is a value. Built by
    ## `initCorrelateView`; do not use one whose build was refused.
    plan*: ref CorrelationPlan[float32]
    pilot*: seq[float32]
    path*: string ## the raw file's path, copied once so a later read does not allocate
    refs*: HashSet[int] ## the marked auxiliary traces, correlated
    odd*: HashSet[int]
    recordSamples*: int
    listenSamples*: int ## samples of listen time: the record minus the sweep
    dtMs*: float64
    t0Ms*: float64 ## time of listen sample 0: the first seismic trace's finite t0, else 0
    lags*: Table[int, int]
      ## the marked traces that are shifted before they are correlated, by `lagOf`
      ## (negative moves later)
