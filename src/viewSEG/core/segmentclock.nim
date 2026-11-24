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
## Receivers, when the times come from the headers: a trace without a valid
## receiver line and point is never merged with a trace of another channel (its
## identity stays the keys' channel and component). At a station, one
## component, the traces are ordered by start time then file order; those that
## share a start time are different channels (the k-th of them is sub-receiver
## k) and traces with different start times chain as segments of one
## sub-receiver. A trace without the field while others have it is left out
## (its time is NaN: the planner lists it as untimed).
##
## The headers' bytes are read, no sample is decoded. Nothing is read when no
## loaded vendor map that applies to the file names the field.

import std/[parseutils, algorithm, math]
import parseSEG
import ./[shotlog, vendormaps]

const
  FirstSampleTimeField* = "firstSampleTime"
    ## The name a vendor map gives the field that holds a trace's start time.
  UnitGps* = "us GPS"                  ## microseconds since 1980-01-06 on the GPS clock
  UnitUtc* = "us UTC"                  ## microseconds since 1970 in UTC
  MaxUtcUs = 7_258_118_400_000_000'i64 ## 2200-01-01: later is not a start time
  CheckEvery = 256
  MaxChannelsPerStation* = 8
    ## more traces than this of one station and component with one start time
    ## are not channels: the file holds no start times of their own

type SegmentClock* = object
  ## What `segmentClock` made. `times` and `receivers` are as
  ## `initSliceStreams` takes them and are filled only when `fromHeaders`.
  times*: seq[float64] ## per trace: UTC POSIX seconds of its first sample
  receivers*: seq[int] ## per trace: the receiver, ascending by station and component
  fromHeaders*: bool ## at least one trace had the field
  leftOut*: int ## traces without a usable field: their time is NaN, the planner leaves them out
  unevenChannels*: int
    ## stations and components whose start times do not all have the same number of traces
  untimed*: bool
    ## more than `MaxChannelsPerStation` traces of one station and component share one
    ## start time: the file's traces have no start times of their own in these headers

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

type Place = tuple[line, point, channel: float64; index: int16; component: uint8; sub: int]

func cmpNaN(x, y: float64): int =
  if x.isNaN: (if y.isNaN: 0 else: 1)
  elif y.isNaN: -1
  else: cmp(x, y)

func cmpPlace(a, b: Place): int =
  result = cmpNaN(a.line, b.line)
  if result == 0: result = cmpNaN(a.point, b.point)
  if result == 0: result = cmp(a.index, b.index)
  if result == 0: result = cmpNaN(a.channel, b.channel)
  if result == 0: result = cmp(a.component, b.component)
  if result == 0: result = cmp(a.sub, b.sub)

func hasStation(line, point: float64): bool =
  not (line.isNaN or point.isNaN)

proc numbered(places: seq[Place]): seq[int] =
  ## The ids of `places`, ascending by place, equal places sharing one.
  var order = newSeq[int](places.len)
  for i in 0 ..< places.len: order[i] = i
  order.sort do (a, b: int) -> int:
    cmpPlace(places[a], places[b])
  result = newSeq[int](places.len)
  var id = 0
  for n, row in order:
    if n > 0 and cmpPlace(places[order[n - 1]], places[row]) != 0: inc id
    result[row] = id

proc receiverIds*(f: SeismicFile; withChannel: bool): seq[int] =
  ## Per trace: the receiver, numbered ascending by station and component
  ## (and by channel when `withChannel`, as `initSliceStreams` does from the
  ## keys). Needs the keys of `f`.
  var places = newSeq[Place](f.len)
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    let st = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
    places[i] = (st.line, st.point, if withChannel: k.channel else: 0.0, st.index,
      k.component, 0)
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
    if hasStation(k.rcvLine, k.rcvPoint):
      let st = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
      places[i] = (st.line, st.point, 0.0, st.index, k.component, -1)
      if us[i] >= 0: grouped.add i
    else:
      places[i] = (NaN, NaN, k.channel, 0'i16, k.component, 0)
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
      if e - r > MaxChannelsPerStation: result.untimed = true
      if shared >= 0 and shared != e - r: uneven = true
      shared = e - r
      r = e
    if uneven: inc result.unevenChannels
    n = m
  result.times = times
  result.fromHeaders = true
  result.receivers = numbered(places)
