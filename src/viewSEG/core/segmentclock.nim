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
## A receiver is a station and a component (`stationPlace`: the receiver line and point,
## else the group coordinates, else the channel alone). From the keys (`receiverIds`), the
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

func stationPlace*(k: TraceKeys): StationPlace =
  ## Where the trace `k` was recorded: its receiver line and point (`how` 0), else its group
  ## coordinates when they are not both zero (1), else its channel alone (2; -1 when it has
  ## none).
  if not (k.rcvLine.isNaN or k.rcvPoint.isNaN):
    let s = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
    (0'i8, s.line, s.point, s.index)
  elif not (k.rcvX.isNaN or k.rcvY.isNaN) and (k.rcvX != 0 or k.rcvY != 0):
    (1'i8, k.rcvX, k.rcvY, 0'i16)
  else:
    (2'i8, (if k.channel.isNaN: -1.0 else: k.channel), 0.0, 0'i16)

func placeOf(k: TraceKeys; channel: float64; sub: int): Place =
  let st = stationPlace(k)
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

proc numbered(places: seq[Place]): seq[int] =
  ## The ids of `places`, equal places sharing one, in the order the file shows
  ## them: stations by their first trace, within a station the components by
  ## theirs, then by sub-receiver and first trace. Nothing is sorted by station
  ## number or component code. A place named by its channel alone is a station of its own.
  var order = newSeq[int](places.len)
  for i in 0 ..< places.len: order[i] = i
  order.sort do (a, b: int) -> int:
    result = cmpPlace(places[a], places[b])
    if result == 0: result = cmp(a, b)
  type Group = tuple[first, run, stationFirst, compFirst, sub: int]
  var groups: seq[Group] = @[]
  var groupOf = newSeq[int](places.len)
  var runs = 0 # the stations met: a run of places of one station
  for n, row in order:
    let pl = places[row]
    if n == 0 or cmpPlace(places[order[n - 1]], pl) != 0:
      if n == 0 or not sameStation(places[order[n - 1]], pl): inc runs
      groups.add (row, runs - 1, row, row, pl.sub)
    groupOf[row] = groups.len - 1
  var stationFirst = newSeq[int](runs)
  for r in 0 ..< runs: stationFirst[r] = high(int)
  var compFirst = initTable[tuple[run: int; comp: uint8], int]()
  for g in groups:
    stationFirst[g.run] = min(stationFirst[g.run], g.first)
    let key = (g.run, places[g.first].component)
    compFirst[key] = min(compFirst.getOrDefault(key, high(int)), g.first)
  for g in groups.mitems:
    g.stationFirst = stationFirst[g.run]
    g.compFirst = compFirst[(g.run, places[g.first].component)]
  var ranked = newSeq[int](groups.len)
  for i in 0 ..< groups.len: ranked[i] = i
  ranked.sort do (a, b: int) -> int:
    result = cmp(groups[a].stationFirst, groups[b].stationFirst)
    if result == 0: result = cmp(groups[a].compFirst, groups[b].compFirst)
    if result == 0: result = cmp(groups[a].sub, groups[b].sub)
    if result == 0: result = cmp(groups[a].first, groups[b].first)
  var idOfGroup = newSeq[int](groups.len)
  for id, g in ranked: idOfGroup[g] = id
  result = newSeq[int](places.len)
  for row in 0 ..< places.len: result[row] = idOfGroup[groupOf[row]]

proc receiverIds*(f: SeismicFile; times: seq[float64]; dtS: float64): seq[int] =
  ## Per trace: the receiver, numbered in the order the file shows them (stations by their
  ## first trace, components of a station by theirs). A receiver is a station
  ## (`stationPlace`) and a component; its channel number tells its traces apart only when
  ## two live traces of that station and component share a start time (`times`, per trace,
  ## within half a sample of `dtS` seconds): the uncoded components of one station, as
  ## `initSliceStreams` tells them from the keys. Otherwise the channel is left out, so a
  ## receiver whose channel number changes from record to record, or rises from trace to
  ## trace, stays one receiver. Needs the keys of `f`.
  var places = newSeq[Place](f.len)
  for i in 0 ..< f.len: places[i] = placeOf(f.traceKeys(i), 0.0, 0)
  var timed: seq[int] = @[] # the live traces with a start time
  for i in 0 ..< f.len:
    if f.traceKeys(i).status in {tsLive, tsUnknown} and times[i].classify in
        {fcNormal, fcZero, fcNegZero, fcSubnormal}:
      timed.add i
  timed.sort do (a, b: int) -> int:
    result = cmpPlace(places[a], places[b])
    if result == 0: result = cmp(times[a], times[b])
    if result == 0: result = cmp(a, b)
  func together(x, y: float64): bool =
    if dtS > 0: abs(y - x) < dtS / 2 else: x == y
  var told: seq[Place] = @[] # the stations and components whose channels tell traces apart
  var n = 0
  while n < timed.len:
    var m = n + 1
    var shared = false
    while m < timed.len and cmpPlace(places[timed[n]], places[timed[m]]) == 0:
      if together(times[timed[m - 1]], times[timed[m]]): shared = true
      inc m
    if shared: told.add places[timed[n]]
    n = m
  if told.len > 0: # (in order: `timed` is sorted by place)
    for i in 0 ..< f.len:
      if told.binarySearch(places[i], cmpPlace) >= 0:
        places[i].channel = f.traceKeys(i).channel
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
  var grouped: seq[int] = @[] # the traces with a station and a start time
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    if us[i] >= 0: times[i] = toPosixSeconds(us[i])
    else:
      times[i] = NaN
      inc result.leftOut
    places[i] = placeOf(k, 0.0, -1)
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
