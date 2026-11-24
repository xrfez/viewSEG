## How a trace's station index matches a stored station, as the survey join
## does: the index itself, then 0 (any index of this line and point), then,
## for a trace with index 0, 1. Survey files number the first position 1 and
## never write 0, so a trace with no index matches that position.

iterator stationIndexTries*(index: int16): int16 =
  ## Those indices, in that order. A trace whose index is 0 tries 0, then 0
  ## again, then 1: the same sequence the join has always tried.
  let tries = [index, 0'i16, 1'i16]
  for i in 0 .. (if index == 0: 2 else: 1):
    yield tries[i]
