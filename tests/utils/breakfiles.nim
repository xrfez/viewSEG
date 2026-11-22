## A synthetic shot over a half space for the first-break overlay's tests: 48
## traces of 2000 ms at 2 ms, the offsets 100 m to 2450 m, a first break at
## 20 ms plus 0.4 ms a metre (2500 m/s) as a Ricker wavelet in a little noise,
## and one trace (`PlantedTrace`) whose data arrive `PlantedMs` late: its
## header is wrong. The offsets are in the headers, or derived from the
## coordinates, or not given (`Geometry`).

import std/os
import parseSEG
import processSEG/synth
import fixtures

const
  Traces* = 48
  Samples* = 1000
  Dt* = 2.0
  PlantedTrace* = 20 ## its data arrive late by `PlantedMs`: its header is wrong
  PlantedMs* = 80.0

type Geometry* = enum
  gHeaderOffset, gCoordinates, gNothing

func offsetOf*(i: int): float64 = 100.0 + 50.0 * float64(i)

func arrivalMs*(x: float64): float64 =
  ## The true first break: 20 ms plus 0.4 ms a metre (2500 m/s).
  20.0 + 0.4 * x

proc shotSegy*(fx: Fixtures; name: string; geometry: Geometry): string =
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break overlay test: a shot over a 2500 m/s half space"]))
  var buf = newSeq[float32](Samples)
  for i in 0 ..< Traces:
    for j in 0 ..< Samples: buf[j] = 0
    let late = if i == PlantedTrace: PlantedMs else: 0.0
    buf.addRicker(Dt, arrivalMs(offsetOf(i)) + late + 15, 30, 1.0)
    buf.addNoise(0.03, int64(i + 1))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      Dt * 1000, tsLive)
    case geometry
    of gHeaderOffset: k.offset = offsetOf(i)
    of gCoordinates:
      # (a source at (0, 0) counts as a header left empty)
      (k.srcX, k.srcY, k.rcvX, k.rcvY) = (1000.0, 500.0, 1000.0 + offsetOf(i), 500.0)
    of gNothing: discard
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log

type Tweak* = proc (i: int; k: var TraceKeys): float64
  ## Sets the keys of trace `i` of `customShot` (they start as `shotSegy`'s: record 1, channel
  ## `i + 1`, the interval `Dt`, the offset `offsetOf(i)`) and returns its first break in ms.

proc customShot*(fx: Fixtures; name: string; traces: int; tweak: Tweak): string =
  ## A shot of `traces` traces whose keys and first breaks `tweak` chooses; each trace's data
  ## start at its own `t0Ms`, and carry its wavelet where `tweak` says, in a little noise.
  result = fx.dir / name
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break overlay test: " & name]))
  var buf = newSeq[float32](Samples)
  for i in 0 ..< traces:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      Dt * 1000, tsLive)
    k.offset = offsetOf(i mod Traces)
    let at = tweak(i, k)
    for j in 0 ..< Samples: buf[j] = 0
    buf.addRicker(Dt, at + 15, 30, 1.0, t0Ms = k.t0Ms)
    buf.addNoise(0.03, int64(i + 1))
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log
