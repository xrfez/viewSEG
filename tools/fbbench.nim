## Times the first-break job on a synthetic record: `nim c -d:release tools/fbbench.nim`, then
## `fbbench make <file> <traces> [dtMs]` writes a record of that many traces of 4001 samples
## (a refracted arrival, far traces of noise only), and `fbbench run <file> [runs] [workers]`
## picks it `runs` times and prints the median time and a fingerprint of the result.

import std/[algorithm, math, monotimes, os, strutils, tables, times]
import parseSEG
import processSEG/synth
import viewSEG/core/firstbreakjobs
import ../tests/utils/fbprint

const Samples = 4001

proc make(path: string; traces: int; dtMs: float64) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    text: @["C01 first-break benchmark record"]))
  var buf = newSeq[float32](Samples)
  for i in 0 ..< traces:
    let x = 50.0 + 6000.0 * float64(i) / float64(traces) # offset in m
    let t = if x < 1200: 0.33 * x else: 400 + 0.2 * (x - 1200) # ms: direct, then refracted
    for j in 0 ..< Samples: buf[j] = 0
    if i mod 13 != 5 or x < 4500: buf.addRicker(dtMs, t + 25, 30, 1.0)
    buf.addNoise(0.05, int64(i + 1))
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(i + 1), 0.0,
      dtMs * 1000, tsLive)
    k.offset = x
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

proc run(path: string; runs, workers: int) =
  var times: seq[float64]
  var print = 0'u64
  for r in 0 ..< runs:
    var f = openSeismic(path, keys = true)
    let t0 = getMonoTime()
    let b = breaksOfRecord(addr f, path, 0 ..< f.len, [], workers = workers)
    times.add float64((getMonoTime() - t0).inNanoseconds) / 1e6
    print = fingerprint(b)
    f.close()
  times.sort()
  echo "median ", times[times.len div 2].formatFloat(ffDecimal, 1), " ms, min ",
    times[0].formatFloat(ffDecimal, 1), " fingerprint ", print.toHex

when isMainModule:
  let a = commandLineParams()
  if a[0] == "make": make(a[1], parseInt(a[2]), if a.len > 3: parseFloat(a[3]) else: 1.0)
  else: run(a[1], if a.len > 2: parseInt(a[2]) else: 5, if a.len > 3: parseInt(a[3]) else: 0)
