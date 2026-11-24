## The UTC instant of a record's time zero, worked out from the keys of one
## trace: the header time the library decoded and the delay recording time.
##
## SEG-Y and SEG-D give the keys' instant of sample 0 to the microsecond
## (`firstSampleUs`); the time zero is that instant less the delay. A SEG-D
## channel set the headers do not describe has no delay, so the header clock
## itself is the time zero: whole seconds for a general-header clock, and
## `time` rounded once to the microsecond for the Rev 3 time zero. A float64
## in UTC POSIX seconds resolves 2.4e-7 s at present-day values, so that one
## rounding is exact to the microsecond.

import std/[math, options]
import parseSEG

proc timeZeroOfRecord*(k: TraceKeys; kind: SeismicKind): Option[int64] =
  ## The UTC microsecond instant of time zero of the record of the trace
  ## with keys `k`, or none for a file without a time, for SEG-2 and other
  ## formats, and for SEG-Y whose delay is unknown.
  if kind notin {skSegd, skSegy}: return none(int64)
  let first = k.firstSampleUs
  if first.isSome:
    let delay = if k.t0Ms.isNaN: 0'i64 else: int64(round(k.t0Ms * 1000.0))
    return some(first.get - delay)
  if kind == skSegd and k.timeOrigin in {toHeaderSeconds, toRecordTimeZero} and
      not k.time.isNaN:
    return some(int64(round(k.time * 1e6)))
  none(int64)

proc timeZeroOfRecord*(f: SeismicFile; trace: int): Option[int64] =
  ## `timeZeroOfRecord` of trace `trace` of an open file. Raises `ValueError`
  ## for a trace out of range, and as `traceKeysInto` does for a file it cannot
  ## read.
  var ks: array[1, TraceKeys]
  f.traceKeysInto([trace], ks)
  timeZeroOfRecord(ks[0], f.kind)
