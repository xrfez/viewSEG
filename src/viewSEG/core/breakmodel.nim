## The velocity model the first-break overlay can be given (`BreakModel`): instead of one
## fitted to each record's own picks (which follows the record, and so hides a source at
## the wrong place), a model held fixed across records, whose expected break at every
## trace shows a source named wrongly or a station assigned wrongly.
##
## The model is processSEG's two-segment shape (`qc/shotfit`): `t = a + x / v1` up to
## the crossover `xc`, then `a + xc / v1 + (x - xc) / v2`, continuous at `xc`, in ms for
## an offset `x` in the offsets' unit and velocities in that unit per second. Nothing
## here knows a file, a unit's name or a window.

import std/math

const
  MaxBreakVelocity* = 1.0e6     ## the largest velocity a model takes (offset units per second)
  MaxBreakIntercept* = 10_000.0 ## the largest intercept (ms), either way
  MaxBreakCrossover* = 1.0e7    ## the largest crossover offset

type
  BreakModelSource* = enum
    bmFitted = "Fitted to this record"
    bmGiven = "Given"

  PickBasis* = enum
    ## What the guided passes of first-break picking read: a zero-phase high-cut copy of
    ## each trace (the loaded samples are never changed), or the samples as loaded.
    pbSmoothed = "smoothed"
    pbAsRecorded = "as recorded"

  BreakModel* = object
    ## Where the overlay's model comes from, and the given one's numbers.
    source*: BreakModelSource
    v1*: float64          ## velocity (offset units per second); 0 or less: none given yet
    interceptMs*: float64 ## the delay at zero offset
    v2*: float64          ## a second velocity beyond `crossover`; 0 or less: one segment
    crossover*: float64   ## the offset where the second line starts

func finite(x: float64): bool {.inline.} = x - x == 0

func bounded*(m: BreakModel): BreakModel =
  ## `m` with each number within range: not-a-number and out-of-range values set to 0,
  ## a second velocity kept only with a crossover.
  result = m
  func within(x, lo, hi: float64): float64 = (if finite(x): clamp(x, lo, hi) else: 0.0)
  result.v1 = within(m.v1, 0, MaxBreakVelocity)
  result.interceptMs = within(m.interceptMs, -MaxBreakIntercept, MaxBreakIntercept)
  result.v2 = within(m.v2, 0, MaxBreakVelocity)
  result.crossover = within(m.crossover, 0, MaxBreakCrossover)
  if result.v2 <= 0 or result.crossover <= 0: (result.v2, result.crossover) = (0.0, 0.0)

func given*(m: BreakModel): bool =
  ## Whether the overlay uses `m`: it is the given one, and it has a velocity.
  m.source == bmGiven and m.v1 > 0

func segments*(m: BreakModel): int =
  ## The straight segments of a given model: 0 without a velocity, 1 or 2.
  if m.v1 <= 0: 0 elif m.v2 > 0 and m.crossover > 0: 2 else: 1

func modelMs*(m: BreakModel; offset: float64): float64 =
  ## The expected first break (ms) at `offset` (either side of the source: its size is
  ## used); NaN without a velocity or an offset.
  if not finite(offset) or m.v1 <= 0: return NaN
  let x = abs(offset)
  if m.segments == 2 and x > m.crossover:
    m.interceptMs + 1000 * (m.crossover / m.v1 + (x - m.crossover) / m.v2)
  else:
    m.interceptMs + 1000 * x / m.v1
