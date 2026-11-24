## The order the traces of a file are written in, told from their headers alone.
##
## Two levels. The grouping matters only when a station has more than one component: by flag
## (all components of a station together, the station or the time outer, the component inner)
## or by component (all of one component, then all of the next). Inside it the traces are
## sorted by station or by time. A file of one component has only the sub-sort.
##
## Nothing is guessed. An order holds only when every consecutive pair of traces of one
## component agrees (non-decreasing; a tie never breaks it) and the key rises at least once
## (a constant key tells nothing). Components are never compared with each other: a
## hydrophone's position or time is not set against a geophone's. When no order holds, or the
## file has fewer than two traces, the answer is `tgNotKnown` and `tsNotKnown`.
## When both sub-sorts hold (station and time rise together), a shot gather says its stations
## (`byStation`) and a receiver gather its times (`byTime`).

import std/math

type
  TraceGrouping* = enum
    tgNotKnown    ## the traces are in no order, or it cannot be told
    tgNone        ## one component: no grouping
    tgByFlag      ## the components of a station (or of a time) are together
    tgByComponent ## all the traces of one component, then of the next

  TraceSubSort* = enum
    tsNotKnown ## the traces are in no order, or it cannot be told
    tsByStation
    tsByTime

  TraceOrder* = object
    grouping*: TraceGrouping
    subSort*: TraceSubSort

  StationPlace* = tuple[how: int8; a, b: float64; index: int16]
    ## a receiver point as the file names it: by its station (`how` 0: `a` the line, `b` the
    ## point), else by its group coordinates (1: x and y), else by its channel (2: `a`)

  OrderTrace* = object
    ## One live trace, in file order.
    component*: uint8
    place*: StationPlace
    start*: float64 ## UTC POSIX seconds of its first sample

func isKnown*(o: TraceOrder): bool =
  ## Whether the order of the traces could be told.
  o.subSort != tsNotKnown

func placeCmp(a, b: StationPlace): int =
  result = cmp(a.how, b.how)
  if result == 0: result = cmp(a.a, b.a)
  if result == 0: result = cmp(a.b, b.b)
  if result == 0: result = cmp(a.index, b.index)

func holds(traces: openArray[OrderTrace]; dtS: float64; byTime: bool): bool =
  ## Whether the traces of every component are non-decreasing in the key (station, or time in
  ## samples) and the key rises somewhere.
  var last: array[uint8, int] # per component: 1 + the index of its last trace, 0 for none
  var rose = false
  result = true
  for i in 0 ..< traces.len:
    let c = traces[i].component
    if last[c] > 0:
      let p = traces[last[c] - 1]
      let d =
        if byTime:
          if dtS > 0: cmp(int(round((traces[i].start - p.start) / dtS)), 0)
          else: cmp(traces[i].start, p.start)
        else: placeCmp(traces[i].place, p.place)
      if d < 0: return false
      if d > 0: rose = true
    last[c] = i + 1
  result = rose

func contiguousComponents(traces: openArray[OrderTrace]): bool =
  ## Whether each component is one run of traces.
  var done: set[uint8] = {}
  for i in 1 ..< traces.len:
    if traces[i].component != traces[i - 1].component:
      done.incl traces[i - 1].component
      if traces[i].component in done: return false
  result = true

func cycles(traces: openArray[OrderTrace]; count: int; samePlace: bool): bool =
  ## Whether the traces are consecutive sets of `count` traces, each of `count` different
  ## components (and, with `samePlace`, of one station).
  if traces.len mod count != 0: return false
  var i = 0
  while i < traces.len:
    var seen: set[uint8] = {}
    for j in i ..< i + count:
      if traces[j].component in seen: return false
      if samePlace and traces[j].place != traces[i].place: return false
      seen.incl traces[j].component
    i += count
  result = true

func traceOrder*(traces: openArray[OrderTrace]; dtS: float64; shot: bool): TraceOrder =
  ## The order of `traces` (live traces, in file order), times compared in samples of `dtS`
  ## seconds. `shot`: the file is a shot gather, which prefers the station when both
  ## sub-sorts hold; a receiver gather prefers the time.
  result = TraceOrder(grouping: tgNotKnown, subSort: tsNotKnown)
  if traces.len < 2: return
  var comps: set[uint8] = {}
  for t in traces: comps.incl t.component
  let count = comps.card
  let blocks = count > 1 and contiguousComponents(traces)
  let keys = if shot: [tsByStation, tsByTime] else: [tsByTime, tsByStation]
  for key in keys:
    let byTime = key == tsByTime
    if holds(traces, dtS, byTime):
      let g =
        if count == 1: tgNone
        elif blocks: tgByComponent
        elif cycles(traces, count, not byTime): tgByFlag
        else: tgNotKnown
      if g != tgNotKnown: return TraceOrder(grouping: g, subSort: key)
