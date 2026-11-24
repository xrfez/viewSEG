## Where each trace of a continuous recording starts, read from the trace
## headers through the vendor maps.
##
## A recorder may keep every trace's own start time in a vendor block of the
## trace header, while the general header (and so `TraceKeys.time`) holds one
## time for the whole record and the channel is the trace number. Planning a
## cut from the keys then sees one receiver per trace, all starting together,
## instead of one receiver with consecutive segments. A vendor map names the
## field `firstSampleTime`, a count of microseconds; this module reads it for
## every trace and numbers the receivers so the segments of one receiver chain
## by their start times.
##
## A receiver is a station and a component (`stationPlaces`: the receiver line and point,
## else the group coordinates, those within `SameSpot` of each other one point, else the
## channel alone). From the keys (`receiverIds`), the
## channel number also tells apart the traces of one station and component that share a
## start time, and only those. When the times come from the headers, a trace without a
## station or group coordinates is never merged with a trace of another channel (its
## identity stays the keys' channel and component). At a station, one component, the traces
## are ordered by start time then file order; those that share a start time are different
## channels (the k-th of them is sub-receiver k: the channel number of such a recorder is the
## trace number) and traces with different start times chain as segments of one
## sub-receiver. A trace without the field while others have it is left out (its time is
## NaN: the planner lists it as untimed).
##
## The headers' bytes are read, no sample is decoded. Nothing is read when no
## loaded vendor map that applies to the file names the field.

import std/[parseutils, algorithm, math, tables]
import parseSEG
import ./[shotlog, traceorder, vendormaps]

const
  FirstSampleTimeField* = "firstSampleTime"
    ## The name a vendor map gives the field that holds a trace's start time.
  UnitGps* = "us GPS"                  ## microseconds since 1980-01-06 on the GPS clock
  UnitUtc* = "us UTC"                  ## microseconds since 1970 in UTC
  MaxUtcUs = 7_258_118_400_000_000'i64 ## 2200-01-01: later is not a start time
  CheckEvery = 256

type SegmentClock* = object
  ## What `segmentClock` made. `times` and `receivers` are as
  ## `initSliceStreams` takes them and are filled only when `fromHeaders`.
  times*: seq[float64] ## per trace: UTC POSIX seconds of its first sample
  receivers*: seq[int] ## per trace: the receiver, numbered in the order the file shows them
  fromHeaders*: bool ## at least one trace had the field
  leftOut*: int ## traces without a usable field: their time is NaN, the planner leaves them out
  unevenChannels*: int
    ## stations and components whose start times do not all have the same number of traces

proc startUs(unit: string; value: int64): int64 =
  ## UTC microseconds of a start time in `unit`; -1 when the unit is another
  ## or the value is zero, negative or not a time of 1970..2200.
  result = -1
  if value > 0:
    case unit
    of UnitUtc: result = value
    of UnitGps: result = gpsMicrosToUtcMicros(value)
    else: discard
    if result <= 0 or result >= MaxUtcUs: result = -1

proc fieldUs(shown: VendorShown): int64 =
  ## The usable start of a trace's decoded blocks, or -1.
  result = -1
  for b in shown.blocks:
    for f in b.fields:
      if f.name == FirstSampleTimeField and result < 0:
        var v = 0'i64
        let used = parseBiggestInt(f.value, v)
        if used > 0 and used == f.value.len: result = startUs(f.unit, v)

type Place = tuple[how: int8; a, b: float64; index: int16; channel: float64; component: uint8;
    sub: int]
  ## a station (`StationPlace`), then what tells its receivers apart

const
  SameSpot* = 5.0
    ## group coordinates (survey units) this near each other are one receiver point: a node
    ## whose position is written a little differently from record to record stays one
  FarCoordinate = 1e15 ## beyond this a group coordinate is no position

func isCoordinate(v: float64): bool =
  v.classify in {fcNormal, fcZero, fcNegZero, fcSubnormal} and abs(v) < FarCoordinate

func stationPlace*(k: TraceKeys): StationPlace =
  ## Where the trace `k` was recorded: its receiver line and point (`how` 0), else its group
  ## coordinates when they are not both zero (1), else its channel alone (2; -1 when it has
  ## none). The coordinates are as written: `stationPlaces` takes near ones as one point.
  if not (k.rcvLine.isNaN or k.rcvPoint.isNaN):
    let s = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
    (0'i8, s.line, s.point, s.index)
  elif k.rcvX.isCoordinate and k.rcvY.isCoordinate and (k.rcvX != 0 or k.rcvY != 0):
    (1'i8, k.rcvX, k.rcvY, 0'i16)
  else:
    (2'i8, (if k.channel.isNaN: -1.0 else: k.channel), 0.0, 0'i16)

proc stationPlaces*(f: SeismicFile): seq[StationPlace] =
  ## Per trace of `f`: its `stationPlace`, group coordinates within `SameSpot` of a point met
  ## earlier in the file named as that point. The one place both the kind and the segment
  ## clock take a receiver point from. Needs the keys of `f`.
  result = newSeq[StationPlace](f.len)
  func cell(v: float64): int64 = int64(floor(v / SameSpot))
  var points: seq[tuple[x, y: float64]] = @[]
  # coordinates as written: their point
  var exact = initTable[tuple[x, y: float64], int]()
  var byCell = initTable[(int64, int64), seq[int]]()
  for i in 0 ..< f.len:
    result[i] = stationPlace(f.traceKeys(i))
    if result[i].how == 1:
      let p = (x: result[i].a, y: result[i].b)
      var near = exact.getOrDefault(p, -1)
      if near < 0:
        let (cx, cy) = (cell(p.x), cell(p.y))
        near = high(int)
        for dx in -1'i64 .. 1'i64:
          for dy in -1'i64 .. 1'i64:
            for q in byCell.getOrDefault((cx + dx, cy + dy)):
              if q < near and hypot(points[q].x - p.x, points[q].y - p.y) <= SameSpot: near = q
        if near == high(int):
          near = points.len
          points.add p
          byCell.mgetOrPut((cx, cy), @[]).add near
        exact[p] = near
      result[i].a = points[near].x
      result[i].b = points[near].y

func placeOf(st: StationPlace; k: TraceKeys; channel: float64; sub: int): Place =
  (st.how, st.a, st.b, st.index, channel, k.component, sub)

func cmpNaN(x, y: float64): int =
  if x.isNaN: (if y.isNaN: 0 else: 1)
  elif y.isNaN: -1
  else: cmp(x, y)

func sameStation(x, y: Place): bool =
  ## Whether `x` and `y` are one station: never so for a place named by its channel alone.
  x.how < 2 and x.how == y.how and x.a == y.a and x.b == y.b and x.index == y.index

func cmpPlace(x, y: Place): int =
  result = cmp(x.how, y.how)
  if result == 0: result = cmpNaN(x.a, y.a)
  if result == 0: result = cmpNaN(x.b, y.b)
  if result == 0: result = cmp(x.index, y.index)
  if result == 0: result = cmpNaN(x.channel, y.channel)
  if result == 0: result = cmp(x.component, y.component)
  if result == 0: result = cmp(x.sub, y.sub)

proc ranked(places: seq[Place]; groupOf: seq[int]; count: int): seq[int] =
  ## The ids of `places` whose equal places are numbered `groupOf` (0 ..< `count`, each new
  ## one in file order), in the order the file shows them: stations by their first trace,
  ## within a station the components by theirs, then by sub-receiver and first trace.
  ## Nothing is sorted by station number or component code. A place named by its channel
  ## alone is a station of its own. No place may hold a NaN (they are hashed).
  var keys = newSeq[tuple[key: tuple[stationFirst, compFirst, sub, first: int]; g: int]](count)
  var stationFirst = initTable[StationPlace, int]()
  var compFirst = initTable[(StationPlace, uint8), int]()
  var seen = 0
  for row, pl in places:
    let g = groupOf[row]
    if g == seen:
      inc seen
      let st: StationPlace = (pl.how, pl.a, pl.b, pl.index)
      keys[g] =
        if pl.how < 2: ((stationFirst.mgetOrPut(st, row),
          compFirst.mgetOrPut((st, pl.component), row), pl.sub, row), g)
        else: ((row, row, pl.sub, row), g)
  keys.sort()
  var idOf = newSeq[int](count)
  for id, k in keys: idOf[k.g] = id
  result = newSeq[int](places.len)
  for row in 0 ..< places.len: result[row] = idOf[groupOf[row]]

proc numbered(places: seq[Place]): seq[int] =
  ## `ranked`, equal places sharing one id.
  var groupOf = newSeq[int](places.len)
  var groups = initTable[Place, int]()
  for row, pl in places: groupOf[row] = groups.mgetOrPut(pl, groups.len)
  ranked(places, groupOf, groups.len)

proc receiverIds*(f: SeismicFile; stations: seq[StationPlace]; times: seq[float64];
    dtS: float64): seq[int] =
  ## Per trace: the receiver, numbered in the order the file shows them (stations by their
  ## first trace, components of a station by theirs). A receiver is a station (`stations`,
  ## per trace, from `stationPlaces`) and a component; its channel number tells its traces
  ## apart only when two live traces of that station and component share a start time
  ## (`times`, per trace, within half a sample of `dtS` seconds): the uncoded components of
  ## one station, as `initSliceStreams` tells them from the keys. Otherwise the channel is
  ## left out, so a receiver whose channel number changes from record to record, or rises
  ## from trace to trace, stays one receiver. Needs the keys of `f`.
  var places = newSeq[Place](f.len)
  var channels = newSeq[float64](f.len)
  var groupOf = newSeq[int](f.len) # per trace: its station and component, numbered
  var groups = initTable[Place, int]()
  var timed: seq[int] = @[] # the live traces with a start time
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    places[i] = placeOf(stations[i], k, 0.0, 0)
    channels[i] = if k.channel.isNaN: NegInf else: k.channel
    groupOf[i] = groups.mgetOrPut(places[i], groups.len)
    if k.status in {tsLive, tsUnknown} and times[i].classify in
        {fcNormal, fcZero, fcNegZero, fcSubnormal}:
      timed.add i
  # the start times of each station and component, together (a counting sort), each run
  # sorted: two within half a sample are traces the channel must tell apart
  var bounds = newSeq[int](groups.len + 1)
  for i in timed: inc bounds[groupOf[i] + 1]
  for g in 1 .. groups.len: bounds[g] += bounds[g - 1]
  var fill = bounds
  var starts = newSeq[float64](timed.len)
  for i in timed:
    starts[fill[groupOf[i]]] = times[i]
    inc fill[groupOf[i]]
  var told = newSeq[bool](groups.len)
  for g in 0 ..< groups.len:
    if bounds[g + 1] - bounds[g] > 1:
      sort(starts.toOpenArray(bounds[g], bounds[g + 1] - 1))
      for x in bounds[g] + 1 ..< bounds[g + 1]:
        let d = starts[x] - starts[x - 1]
        if (if dtS > 0: d < dtS / 2 else: d == 0): told[g] = true
  if true notin told: result = ranked(places, groupOf, groups.len)
  else:
    for i in 0 ..< f.len:
      if told[groupOf[i]]: places[i].channel = channels[i]
    result = numbered(places)

func declaresStart(m: VendorMap): bool =
  for t in m.targets:
    for fld in t.fields:
      if fld.name == FirstSampleTimeField: return true
    for r in t.repeats:
      for fld in r.fields:
        if fld.name == FirstSampleTimeField: return true

proc startFieldDeclared*(f: SeismicFile; reg: VendorRegistry): bool =
  ## True when a map of `reg` that applies to `f` declares the start time
  ## field: false means no trace header needs reading. Reads the index only.
  var declaring: seq[int] = @[]
  for n, m in reg.maps:
    if m.declaresStart: declaring.add n
  if declaring.len == 0: return false
  case f.kind
  of skSegy:
    let ctx = vendorContext(f.index.segy)
    for n in declaring:
      if reg.maps[n].applies(ctx): return true
  of skSegd:
    let blocks = reg.usesRecordBlocks
    for rec in f.index.segdRecords:
      let ctx = vendorContext(rec, blocks)
      for n in declaring:
        if reg.maps[n].applies(ctx): return true
  else: discard

proc segmentClock*(f: SeismicFile; reg: VendorRegistry;
    check: proc () {.gcsafe.} = nil): SegmentClock =
  ## The start time of each trace of `f` from its vendor blocks under `reg`.
  ## A trace whose `firstSampleTime` is missing, in another unit than "us GPS"
  ## (converted with the leap seconds) or "us UTC", zero or not a time gets
  ## NaN as its time (the planner leaves it out) and is counted in `leftOut`.
  ## The receivers are as the module description says. Nothing is returned
  ## (`fromHeaders` false) when no map applies or no trace has the field.
  ## `check`, when given, is called now and then and may raise to stop (a
  ## cancel). Needs the keys of `f` (`ensureKeys`) and its mapped memory
  ## readable.
  if reg.maps.len == 0 or f.len == 0 or not startFieldDeclared(f, reg): return
  var us = newSeq[int64](f.len)
  var found = 0
  for i in 0 ..< f.len:
    if check != nil and i mod CheckEvery == 0: check()
    us[i] = fieldUs(vendorTrace(f, i, reg))
    if us[i] >= 0: inc found
  if found == 0: return
  var times = newSeq[float64](f.len)
  var places = newSeq[Place](f.len)
  let stations = stationPlaces(f)
  var grouped: seq[int] = @[] # the traces with a station and a start time
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    if us[i] >= 0: times[i] = toPosixSeconds(us[i])
    else:
      times[i] = NaN
      inc result.leftOut
    places[i] = placeOf(stations[i], k, 0.0, -1)
    if places[i].how < 2:
      if us[i] >= 0: grouped.add i
    else: places[i].sub = 0
  # within a station and component: by start time, then file order; the k-th
  # trace of those sharing a start time is sub-receiver k
  grouped.sort do (a, b: int) -> int:
    result = cmpPlace(places[a], places[b])
    if result == 0: result = cmp(us[a], us[b])
    if result == 0: result = cmp(a, b)
  var n = 0
  while n < grouped.len:
    var m = n
    while m < grouped.len and cmpPlace(places[grouped[n]], places[grouped[m]]) == 0: inc m
    var shared = -1 # the traces per start time of this station and component
    var uneven = false
    var r = n
    while r < m:
      var e = r
      while e < m and us[grouped[e]] == us[grouped[r]]: inc e
      for k in r ..< e: places[grouped[k]].sub = k - r
      if shared >= 0 and shared != e - r: uneven = true
      shared = e - r
      r = e
    if uneven: inc result.unevenChannels
    n = m
  result.times = times
  result.fromHeaders = true
  result.receivers = numbered(places)
