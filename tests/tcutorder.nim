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

import std/[assertions, options, os, sequtils, strutils]
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

proc logOf(): ShotView =
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  shots(parseShotLog("101," & $(BaseUs + 20_000) & "\n", m), m)

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; opts: CutOptions):
    tuple[ok: bool; res: CutResult] =
  let sink = CutSink()
  let sh = shotsInTime(logOf().rows)
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

when isMainModule:
  main()
