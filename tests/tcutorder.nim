## The order of the traces of a sliced record. The recording is built here, in SEG-D (SEG-Y
## has no slot for the receiver line): two stations, each with four coded components (11
## hydrophone, 12 vertical, 13 crossline, 14 inline) written in the order Y, H, Z, X, one
## segment of 100 samples at 2 ms whose first value names the station and the code. The
## SEG-Y slice builds its headers from keys; the SEG-D slice of it carries the source's.
##
## Seen failing with the order ignored (as the recording): "by flag: record 0 trace 0
## held ...". The channel left as the receiver's number: "channel of trace 1". The carried
## SEG-D slice reordered or given no sentence: "carried sentence". The uncoded fallback
## silent: "uncoded sentence". The as-source output changed when asked for no order: "bytes
## differ".

import std/[algorithm, assertions, options, os, sequtils, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG/continuous/slice
import viewSEG/core/[cutgather, cutgatherjobs, jobs, recordingkind, shotlog]
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  Codes = [13'i16, 11, 12, 14]       ## the order the recording writes a station's traces in
  Points = [7.0, 8.0]
  Window = 50

func firstValue(point: float64; code: int16): float32 =
  float32(1000 * int(point) + 10 * int(code))

proc makeRecording(path: string; coded: bool) =
  ## SEG-D: one segment, per station its four traces (channels 1..8). Uncoded: component 0.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 100))
  for pi, p in Points:
    for ci, code in Codes:
      var k = initTraceKeys()
      k.status = tsLive
      k.record = 1
      k.channel = float64(pi * 4 + ci + 1)
      k.component = uint8(if coded: code else: 0)
      k.intervalUs = 2000
      k.time = float64(BaseUs div 1_000_000)
      k.rcvLine = 1
      k.rcvPoint = p
      var samples = newSeq[float32](100)
      for j in 0 ..< 100: samples[j] = firstValue(p, code) + float32(j)
      w.writeTrace(k, samples)
  discard w.close()

proc logOf(two = false): ShotView =
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crTime]
  m.dateTimePattern = EpochMicros
  shots(parseShotLog("101," & $(BaseUs + 20_000) & "\n" &
    (if two: "102," & $(BaseUs + 1_500_000) & "\n" else: ""), m), m)

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; opts: CutOptions;
    two = false): tuple[ok: bool; res: CutResult] =
  let sink = CutSink()
  let sh = shotsInTime(logOf(two).rows)
  let id = jobs.submit(cutGatherSpec(source, dest),
    cutGatherWork(addr f, source, dest, sh, opts, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the slice did not finish"
  (jobs.info(id).get.state == jsDone, sink.result)

proc firstOf(f: SeismicFile; trace: int): float32 =
  f.readTraces(trace .. trace)[0, 0]

proc seen(path: string): seq[tuple[value: float32; channel: float64]] =
  var f = openSeismic(path, keys = true)
  defer: f.close()
  for t in 0 ..< f.len: result.add (firstOf(f, t), f.traceKeys(t).channel)

func want(order: seq[(float64, int16)]): seq[float32] =
  for (p, c) in order: result.add firstValue(p, c) + 10 # the window starts at sample 10

type Rcv = tuple[point: float64; code: int16; inFirst: bool]

const
  Rcvs: array[11, Rcv] = [(7.0, 13'i16, true), (7.0, 11, true), (7.0, 12, true),
    (7.0, 14, true), (8.0, 13, true), (8.0, 11, true), (8.0, 12, true), (8.0, 14, true),
    (9.0, 0, true), (9.0, 12, true), (9.0, 14, false)]
    ## station 9 has an uncoded trace, and its last receiver records only in the second record
  PerRec = 500 ## samples of a trace

func traceValue(point: float64; code: int16; g: int): float32 =
  float32(int(point) * 100000 + int(code) * 1000 + g)

proc makeTwoRecords(path: string) =
  ## SEG-D of two records a second apart: the traces' values name station, code and sample.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: PerRec))
  for rec in 1 .. 2:
    var ch = 0
    for x in Rcvs:
      if rec == 2 or x.inFirst:
        inc ch
        var k = initTraceKeys()
        k.status = tsLive
        k.record = float64(rec)
        k.channel = float64(ch)
        k.component = uint8(x.code)
        k.intervalUs = 2000
        k.time = float64(BaseUs div 1_000_000 + rec - 1)
        k.rcvLine = 1
        k.rcvPoint = x.point
        var samples = newSeq[float32](PerRec)
        for j in 0 ..< PerRec: samples[j] = traceValue(x.point, x.code, (rec - 1) * PerRec + j)
        let sensor = case x.code
          of 11: 1
          of 12: 2
          of 14: 3
          of 13: 4
          else: 0
        k.sensorType = uint8(sensor)
        w.writeTrace(k, samples)
  discard w.close()

func orderedRcvs(order: CutOrder): seq[Rcv] =
  ## The expected order of one record's traces: uncoded last in a grouped order.
  result = @Rcvs
  func rank(code: int16): int =
    case code
    of 12: 0
    of 14: 1
    of 13: 2
    of 11: 3
    else: 4
  func station(a: Rcv): float64 = a.point
  if order == coByFlag:
    result.sort(proc (a, b: Rcv): int =
      result = cmp(a.point, b.point)
      if result == 0: result = cmp(rank(a.code), rank(b.code)))
  elif order == coByComponent:
    result.sort(proc (a, b: Rcv): int =
      result = cmp(rank(a.code), rank(b.code))
      if result == 0: result = cmp(a.point, b.point))

proc main*() =
  let dir = getTempDir() / ("viewseg-cutorder-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  let jobs = initJobs()
  createDir(dir / "rec")
  let src = dir / "rec" / "coded.sgd"
  makeRecording(src, coded = true)
  var coded = openSeismic(src, keys = true)
  defer: coded.close()
  var base = initCutOptions(100.0, 0.0, standard = csSegy)
  base.treatKind = some rkReceiverContinuous # one segment per receiver, one start for all

  block as_source_is_the_default_and_unchanged:
    let a = runCut(jobs, coded, src, dir / "a.sgy", base)
    doAssert a.ok and a.res.order == coAsSource and not a.res.orderCarried and
      not a.res.orderUncoded, a.res.reason
    var o = base
    o.order = coAsSource
    let b = runCut(jobs, coded, src, dir / "b.sgy", o)
    doAssert b.ok
    doAssert readFile(dir / "a.sgy") == readFile(dir / "b.sgy"), "bytes differ"
    # the recording's order: per station the channels as written
    var expected: seq[(float64, int16)] = @[]
    for p in Points:
      for c in Codes: expected.add (p, c)
    let got = seen(dir / "a.sgy")
    doAssert got.len == 8, "traces " & $got.len & " " & $a.res.lines
    for t in 0 ..< 8:
      doAssert got[t].value == want(expected)[t], "as source: trace " & $t
      doAssert got[t].channel == float64(t + 1), "channel of trace " & $t
    doAssert not a.res.lines.anyIt("grouped" in it)

  block by_flag:
    var o = base
    o.order = coByFlag
    let r = runCut(jobs, coded, src, dir / "flag.sgy", o)
    doAssert r.ok and r.res.order == coByFlag, r.res.reason
    var expected: seq[(float64, int16)] = @[]
    for p in Points:
      for c in [12'i16, 14, 13, 11]: expected.add (p, c) # vertical, inline, crossline, hydro
    let got = seen(dir / "flag.sgy")
    for t in 0 ..< 8:
      doAssert got[t].value == want(expected)[t], "by flag: trace " & $t & " held " & $got[t].value
      doAssert got[t].channel == float64(t + 1), "channel of trace " & $t
    doAssert r.res.lines.anyIt("grouped by flag" in it), $r.res.lines

  block by_component:
    var o = base
    o.order = coByComponent
    let r = runCut(jobs, coded, src, dir / "comp.sgy", o)
    doAssert r.ok and r.res.order == coByComponent, r.res.reason
    var expected: seq[(float64, int16)] = @[]
    for c in [12'i16, 14, 13, 11]:
      for p in Points: expected.add (p, c)
    let got = seen(dir / "comp.sgy")
    for t in 0 ..< 8:
      doAssert got[t].value == want(expected)[t],
        "by component: trace " & $t & " held " & $got[t].value
      doAssert got[t].channel == float64(t + 1)
    doAssert r.res.lines.anyIt("grouped by component" in it), $r.res.lines

  block uncoded_falls_back_and_says_so:
    let plain = dir / "rec" / "plain.sgd"
    makeRecording(plain, coded = false)
    var f = openSeismic(plain, keys = true)
    defer: f.close()
    let a = runCut(jobs, f, plain, dir / "pa.sgy", base)
    var o = base
    o.order = coByFlag
    let b = runCut(jobs, f, plain, dir / "pb.sgy", o)
    doAssert a.ok and b.ok and b.res.orderUncoded and b.res.order == coAsSource
    doAssert readFile(dir / "pa.sgy") == readFile(dir / "pb.sgy"), "bytes differ"
    doAssert b.res.lines.anyIt("not coded" in it), "uncoded sentence"

  block carried_segd_keeps_the_recordings_order:
    let sgd = dir / "rec" / "rec.sgd"
    makeRecording(sgd, coded = true)
    var f = openSeismic(sgd, keys = true)
    defer: f.close()
    var plain = initCutOptions(100.0)
    plain.treatKind = some rkReceiverContinuous
    let a = runCut(jobs, f, sgd, dir / "ca.sgd", plain)
    var o = plain
    o.order = coByComponent
    let b = runCut(jobs, f, sgd, dir / "cb.sgd", o)
    doAssert a.ok and b.ok, b.res.reason
    doAssert a.res.carried, "the SEG-D source was not carried"
    doAssert b.res.orderCarried and b.res.order == coAsSource
    doAssert b.res.lines.anyIt("The traces are in the recording's order: a SEG-D slice that " &
      "keeps the recording's headers cannot reorder them." == it), "carried sentence"
    doAssert readFile(dir / "ca.sgd") == readFile(dir / "cb.sgd"), "bytes differ"

  block two_records_keep_each_traces_own_facts:
    # Two records, a receiver that records in the second only, receivers whose sensor codes
    # differ: in each grouped order every written trace holds its own samples, station, component
    # and sensor code, and both records are in the same order. Seen failing with the facts of
    # receiver i taken for the trace written i-th ("trace code of trace 0").
    let twoSrc = dir / "rec" / "two.sgd"
    makeTwoRecords(twoSrc)
    var g = openSeismic(twoSrc, keys = true)
    defer: g.close()
    for (order, name) in [(coByFlag, "flag"), (coByComponent, "comp")]:
      let expected = orderedRcvs(order)
      for standard in [csSegy, csSegdRev3]:
        var o = initCutOptions(100.0, 0.0, standard = standard)
        o.treatKind = some rkReceiverContinuous
        o.order = order
        let ext = if standard == csSegy: ".sgy" else: ".sgd"
        let dest = dir / ("two-" & name & ext)
        let r = runCut(jobs, g, twoSrc, dest, o, two = true)
        doAssert r.ok and r.res.order == order and not r.res.carried, r.res.reason
        var f = openSeismic(dest, keys = true)
        defer: f.close()
        doAssert f.len == 22, $f.len
        for rec in 0 .. 1:
          for i, x in expected:
            let t = rec * 11 + i
            let k = f.traceKeys(t)
            doAssert k.channel == float64(i + 1), "channel of trace " & $t
            let present = rec == 1 or x.inFirst
            let v = f.readTraces(t .. t)[0, 0]
            if present:
              doAssert v == traceValue(x.point, x.code, rec * PerRec + (if rec ==
                  0: 10 else: 250)),
                name & ext & ": samples of trace " & $t & ": " & $v
              if standard == csSegy:
                # (a receiver with no sensor type is no component: the plain seismic code)
                doAssert x.code == 0 or k.traceCode == x.code, "trace code of trace " & $t
              else:
                doAssert k.rcvPoint == x.point and k.component == uint8(x.code),
                  "keys of trace " & $t
            else:
              doAssert v == 0, "a receiver with no data in the record: " & $v

when isMainModule:
  main()
