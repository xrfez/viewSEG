## Where each trace of a continuous recording starts, read from the trace
## headers through the vendor maps.
##
## A recorder may keep every trace's own start time in a vendor block of the
## trace header, while the general header (and so `TraceKeys.time`) holds one
## time for the whole record and the channel is the trace number. Planning a
## cut from the keys then sees one receiver per trace, all starting together,
## instead of one receiver with consecutive segments. A vendor map names the
## field `firstSampleTime`, a count of microseconds; this module reads it for
## every trace and numbers the receivers without the channel, so the segments
## of one receiver chain by their start times.
##
## The headers' bytes are read, no sample is decoded. Nothing is read when no
## vendor map is loaded.

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

type SegmentClock* = object
  ## What `segmentClock` made. `times` and `receivers` are as
  ## `initSliceStreams` takes them and are filled only when `fromHeaders`.
  times*: seq[float64] ## per trace: UTC POSIX seconds of its first sample
  receivers*: seq[int] ## per trace: the receiver, ascending by station and component
  fromHeaders*: bool ## at least one trace had the field
  fallbacks*: int ## traces without a usable field, which keep `keys.time`

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

type Place = tuple[line, point, channel: float64; index: int16; component: uint8]

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

proc receiverIds*(f: SeismicFile; withChannel: bool): seq[int] =
  ## Per trace: the receiver, numbered ascending by station and component
  ## (and by channel when `withChannel`, as `initSliceStreams` does from the
  ## keys). Needs the keys of `f`.
  var places = newSeq[Place](f.len)
  var order = newSeq[int](f.len)
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    let st = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
    places[i] = (st.line, st.point, if withChannel: k.channel else: 0.0, st.index,
      k.component)
    order[i] = i
  order.sort do (a, b: int) -> int:
    cmpPlace(places[a], places[b])
  result = newSeq[int](f.len)
  var id = 0
  for n, row in order:
    if n > 0 and cmpPlace(places[order[n - 1]], places[row]) != 0: inc id
    result[row] = id

proc segmentClock*(f: SeismicFile; reg: VendorRegistry;
    check: proc () {.gcsafe.} = nil): SegmentClock =
  ## The start time of each trace of `f` from its vendor blocks under `reg`.
  ## A trace whose `firstSampleTime` is missing, in another unit than "us GPS"
  ## (converted with the leap seconds) or "us UTC", zero or not a time keeps
  ## its `keys.time` and is counted in `fallbacks`. The receivers number the
  ## stations and components without the channel. `check`, when given, is
  ## called now and then and may raise to stop (a cancel). Needs the keys of
  ## `f` (`ensureKeys`) and its mapped memory readable.
  if reg.maps.len == 0 or f.len == 0: return
  var times = newSeq[float64](f.len)
  var fallbacks = 0
  for i in 0 ..< f.len:
    if check != nil and i mod CheckEvery == 0: check()
    let us = fieldUs(vendorTrace(f, i, reg))
    if us >= 0: times[i] = toPosixSeconds(us)
    else:
      times[i] = f.traceKeys(i).time
      inc fallbacks
  if fallbacks == f.len: return
  result = SegmentClock(times: times, fromHeaders: true, fallbacks: fallbacks,
    receivers: receiverIds(f, withChannel = false))
