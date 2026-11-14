## Sorting a panel's traces by keys (`Layer.order`), for its reader thread.
##
## A sort is a permutation of the rows of a `TraceRows` view: no data moves,
## and the file is never touched beyond its in-memory keys. The keys are the
## display header's fields (`HeaderField`, read from parseSEG's `TraceKeys`,
## so a SEG-Y and a SEG-D record sort alike), each ascending or descending.
## parseSEG's `sortOrder` does the sorting: stable, so traces with equal keys
## keep the order they had (the file's order, after the trace filter), with
## unknown values (NaN) after every number whichever the direction.
##
## The keys are taken one at a time, the last first, each a stable sort of
## the order the keys after it gave: memory stays at one column of the
## gather's size (8 bytes per trace) beside parseSEG's own (about 32), and
## the work can stop between keys and between runs of `StopEvery` traces
## (`stop`), so a newer request never waits for a large sort to finish.

import parseSEG
import panels

const StopEvery* = 65_536 ## traces read between two calls of `stop`

type StopProc* = proc (): bool {.gcsafe, raises: [].}
  ## True when the sort should give up (something newer is waiting).

proc stopped(stop: StopProc): bool {.inline.} = stop != nil and stop()

proc sortRowsInto*(rows: TraceRows; order: openArray[SortKey]; dst: var seq[int];
    stop: StopProc = nil): bool =
  ## `dst` becomes the rows `0 ..< rows.len` of `rows` in `order` (the first
  ## key first); no keys give the rows as they are. True when done; false
  ## when `stop` said to give up, and `dst` is then not meaningful. Raises
  ## `ValueError` for a view without keys (`rows.hasKeys`).
  if not rows.hasKeys:
    raise newException(ValueError, "the traces have no keys to sort by")
  let n = rows.len
  dst.setLen n
  for i in 0 ..< n: dst[i] = i
  result = true
  if order.len == 0 or n < 2: return
  var cols = @[newSeq[float64](n)]
  var next = newSeq[int](n)
  for j in countdown(order.high, 0):
    let key = order[j]
    var i = 0
    while i < n and result:
      let last = min(n, i + StopEvery)
      for m in i ..< last:
        let row = dst[m]
        let v = rows.keysAt(row).value(key.field, rows.traceOf(row))
        cols[0][m] = if key.descending: -v else: v # NaN stays last either way
      i = last
      if stop.stopped: result = false
    if not result: return
    let s = sortOrder(cols)
    for m in 0 ..< n: next[m] = dst[s[m]]
    swap(dst, next)
    if stop.stopped: return false
