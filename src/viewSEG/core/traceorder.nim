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
## A shot gather is usually sorted by station only inside each record: the station restarts
## at every record, so only the time holds for the whole file. When the station does not hold
## for the file, the shot gather is judged record by record (by the record number the file
## gives each trace; a file without one, or with one record, is not judged so): every component's stations non-decreasing inside every
## record, rising in at least one, and the components laid out alike in each record.

import std/[math, sets]

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
    sortInRecords*: bool
      ## a shot gather whose stations are in order only inside each record (the station
      ## restarts at every record): the sub-sort holds per record
    groupInRecords*: bool
      ## the same for the grouping: the components lie so inside each record

  StationPlace* = tuple[how: int8; a, b: float64; index: int16]
    ## a receiver point as the file names it: by its station (`how` 0: `a` the line, `b` the
    ## point), else by its group coordinates (1: x and y), else by its channel (2: `a`)

  OrderTrace* = object
    ## One live trace, in file order.
    component*: uint8
    place*: StationPlace
    start*: float64 ## UTC POSIX seconds of its first sample
    record*: int64  ## the file's own record (field record, SEG-D file number); `NoRecord`
                    ## when the headers do not say

const NoRecord* = -1'i64 ## `OrderTrace.record` of a trace whose record is not told

func isKnown*(o: TraceOrder): bool =
  ## Whether the order of the traces could be told.
  o.subSort != tsNotKnown

func placeCmp(a, b: StationPlace): int =
  result = cmp(a.how, b.how)
  if result == 0: result = cmp(a.a, b.a)
  if result == 0: result = cmp(a.b, b.b)
  if result == 0: result = cmp(a.index, b.index)

func keyState(traces: openArray[OrderTrace]; dtS: float64; byTime: bool): int =
  ## -1 when a component's traces fall in the key (station, or time in samples) or it cannot
  ## be told, 1 when every component is non-decreasing and the key rises somewhere, else 0. A time is compared with the latest of its component,
  ## not with the trace before it, so small steps back cannot add up unseen. A trace placed by
  ## its channel alone has no station: the station order is then not told.
  var top: array[uint8, int] # per component: 1 + the index of its latest trace, 0 for none
  var rose = false
  for i in 0 ..< traces.len:
    let c = traces[i].component
    if not byTime and traces[i].place.how == 2: return -1
    if top[c] > 0:
      let p = traces[top[c] - 1]
      let d =
        if byTime:
          if dtS > 0: cmp(int(round((traces[i].start - p.start) / dtS)), 0)
          else: cmp(traces[i].start, p.start)
        else: placeCmp(traces[i].place, p.place)
      if d < 0: return -1
      if d > 0: rose = true
      if (byTime and traces[i].start > p.start) or (not byTime and d > 0): top[c] = i + 1
    else: top[c] = i + 1
  result = int(rose)

func holds(traces: openArray[OrderTrace]; dtS: float64; byTime: bool): bool =
  ## Whether the key is non-decreasing for every component and rises somewhere.
  keyState(traces, dtS, byTime) > 0

func contiguousComponents(traces: openArray[OrderTrace]): bool =
  ## Whether each component is one run of traces.
  var done: set[uint8] = {}
  for i in 1 ..< traces.len:
    if traces[i].component != traces[i - 1].component:
      done.incl traces[i - 1].component
      if traces[i].component in done: return false
  result = true

func cycles(traces: openArray[OrderTrace]; count: int): bool =
  ## Whether the traces are consecutive sets of `count` traces, each of `count` different
  ## components and of one station (never one placed by its channel alone: its components
  ## cannot be told to be together).
  if traces.len mod count != 0 or traces[0].place.how == 2: return false
  var i = 0
  while i < traces.len:
    var seen: set[uint8] = {}
    for j in i ..< i + count:
      if traces[j].component in seen: return false
      if traces[j].place != traces[i].place: return false
      seen.incl traces[j].component
    i += count
  result = true

func uncodedGroups(traces: openArray[OrderTrace]; dtS: float64): bool =
  ## Whether the traces are all of component 0 (not coded) and some two in a row share their
  ## station and start: the components of one station, which cannot be told apart.
  for t in traces:
    if t.component != 0: return false
  for i in 1 ..< traces.len:
    if traces[i].place == traces[i - 1].place:
      let d = traces[i].start - traces[i - 1].start
      if (if dtS > 0: int(round(d / dtS)) == 0 else: d == 0): return true

func recordEnd(traces: openArray[OrderTrace]; a: int): int =
  ## The index after the record that starts at `a`: the run of traces of one record number.
  result = a + 1
  while result < traces.len and traces[result].record == traces[a].record: inc result

func stationInRecords(traces: openArray[OrderTrace]; dtS: float64; count: int;
    grouping: var TraceGrouping): bool =
  ## Whether inside every record each component's stations are non-decreasing (the station
  ## restarts at each record) and rise in at least one record. `grouping` is then how the
  ## components lie in the records: one component, each a run, or each station's together;
  ## `tgNotKnown` when the records differ or lie in neither way.
  var rose = false
  var allBlocks, allFlags = true
  var seen = initHashSet[int64]()
  var a = 0
  for t in traces:
    if t.record == NoRecord: return false
  while a < traces.len:
    let b = recordEnd(traces, a)
    if traces[a].record in seen: return false # a record in two separate runs
    seen.incl traces[a].record
    case keyState(traces.toOpenArray(a, b - 1), dtS, false)
    of -1: return false
    of 1: rose = true
    else: discard
    if count > 1:
      allBlocks = allBlocks and contiguousComponents(traces.toOpenArray(a, b - 1))
      allFlags = allFlags and cycles(traces.toOpenArray(a, b - 1), count)
    a = b
  grouping =
    if count == 1: tgNone
    elif allBlocks: tgByComponent
    elif allFlags: tgByFlag
    else: tgNotKnown
  result = rose and seen.len > 1

func traceOrder*(traces: openArray[OrderTrace]; dtS: float64; shot: bool): TraceOrder =
  ## The order of `traces` (live traces, in file order), times compared in samples of `dtS`
  ## seconds. `shot`: the file is a shot gather, which prefers the station when both
  ## sub-sorts hold; a receiver gather prefers the time.
  ## Traces that are all of component 0 with two in a row at one station and start are several
  ## uncoded components: the grouping is not known (`tgNotKnown`) whatever the layout, though
  ## the sub-sort is still said when it holds. Uncoded data laid out by component, whose
  ## station repeats from one component to the next, is told only when its time rises.
  result = TraceOrder(grouping: tgNotKnown, subSort: tsNotKnown)
  if traces.len < 2: return
  var comps: set[uint8] = {}
  for t in traces: comps.incl t.component
  let count = comps.card
  let blocks = count > 1 and contiguousComponents(traces)
  let uncoded = uncodedGroups(traces, dtS)
  let keys = if shot: [tsByStation, tsByTime] else: [tsByTime, tsByStation]
  for key in keys:
    let byTime = key == tsByTime
    if holds(traces, dtS, byTime):
      let g =
        if uncoded: tgNotKnown
        elif count == 1: tgNone
        elif blocks: tgByComponent
        elif cycles(traces, count): tgByFlag
        else: tgNotKnown
      if g != tgNotKnown or uncoded: return TraceOrder(grouping: g, subSort: key)
    if shot and not byTime:
      var g = tgNotKnown
      if stationInRecords(traces, dtS, count, g):
        if uncoded: g = tgNotKnown
        if g != tgNotKnown or uncoded:
          return TraceOrder(grouping: g, subSort: key, sortInRecords: true,
            groupInRecords: true)
