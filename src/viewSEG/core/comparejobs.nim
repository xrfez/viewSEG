## The jobs that copy a trace into a compare slot, and the job that works
## out the picture. Each runs off the UI thread: a seismic file is read,
## and a reference is a file. A copy is posted as `mkCompare`. The picture
## is posted as `mkComparePicture`; a newer ask cancels the older job, and
## the window keeps the picture it has until the new one arrives. A trace
## is copied as the plot shows it: polarity reversed when it is effectively
## reversed, then its time shift, then its own filter. A reference stays as
## stored, with none of them.

import std/[math, strutils]
import parseSEG
import processSEG/core/[basic, rows, types, workspace]
import processSEG/pipeline
import compare, filesystem, inbox, jobs, processing, references, threads
from editmarks import shiftWords

proc post(to: Poster; job: JobId; news: CompareNews) =
  clearCycleRoots()
  to.post Msg(job: job, kind: mkCompare, compareNews: news)

proc postPicture(to: Poster; job: JobId; pic: ComparePicture; gen: uint64) =
  clearCycleRoots()
  to.post Msg(job: job, kind: mkComparePicture, comparePicture: pic, comparePicGen: gen)

proc numText(x: float64): string =
  if x.isNaN or abs(x) >= 1e15: ""
  elif abs(x - round(x)) < 1e-3: $int64(round(x))
  else: formatFloat(x, ffDecimal, 2)

proc channelWords(k: TraceKeys): string =
  let n = numText(k.channel)
  if n.len == 0: "" else: "channel " & n

proc stationWords(k: TraceKeys): string =
  let line = numText(k.rcvLine)
  let point = numText(k.rcvPoint)
  if line.len > 0 or point.len > 0:
    var s = ""
    if line.len > 0: s.add "line " & line
    if point.len > 0:
      if s.len > 0: s.add " "
      s.add "point " & point
    return s
  let srcLine = numText(k.srcLine)
  let srcPoint = numText(k.srcPoint)
  if srcLine.len == 0 and srcPoint.len == 0: return ""
  var s = "source"
  if srcLine.len > 0: s.add " line " & srcLine
  if srcPoint.len > 0: s.add " point " & srcPoint
  s

proc applyOwn(samples: var seq[float32]; dtMs: float64; f: OwnFilter) =
  ## The trace's own frequency filter, in place. Nothing when it asks for
  ## none. Raises `ValueError` when the filter will not compile.
  if samples.len == 0 or not f.spec.hasFilters or not (dtMs > 0): return
  let pipe = f.ownPipeline(dtMs)
  if pipe.len == 0: return
  var keys = @[initTraceKeys()]
  let counts = @[samples.len]
  let rows = rowsOf(keys, counts)
  let meta = initChunkMeta(rows, dtMs)
  let plan = pipe.compile(float32, dtMs, samples.len, recordSamples = samples.len)
  var ws = initWorkspace()
  ws.reserve(plan)
  var view = rowBlock(samples, 1, samples.len)
  plan.apply(view, meta, ws)

proc compareTraceWork*(file: ptr SeismicFile; path: string; size: int64; trace: int;
    own: OwnFilter; reversed: bool; shiftMs: float64; gen: uint64; to: Poster): JobWork =
  ## Reads trace `trace` of the open file. When `reversed` (the trace is
  ## effectively reversed: own reversal or reverse-all, not both), flips
  ## polarity, then applies `shiftMs` (positive later; 0 for none) on a
  ## seismic trace, then its own filter, and posts the copy. The file is not
  ## changed.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the trace"
    var news = CompareNews(gen: gen)
    try:
      var samples: seq[float32] = @[]
      var keys = initTraceKeys()
      var us = 0.0
      {.cast(gcsafe).}:
        samples = readRawTrace(file, path, trace)
        keys = file[].traceKeys(trace)
        us = if keys.intervalUs > 0 and keys.intervalUs < Inf: keys.intervalUs
             else: file[].sampleIntervalUs(trace)
      if samples.len == 0:
        raise newException(IOError, "the trace could not be read")
      if not (us > 0 and us < Inf):
        raise newException(ValueError, "the trace has no sample interval")
      let dt = us / 1000.0
      if reversed:
        reversePolarity(samples)
        news.reversed = true
      if shiftMs != 0.0 and keys.isSeismic:
        applyStoredShift(samples, shiftMs, dt)
        news.shiftWords = shiftWords(shiftMs)
      if own.spec.hasFilters:
        applyOwn(samples, dt, own)
        news.filtered = true
        news.filterWords = ownBrief(own)
      let t0 = if keys.t0Ms.classify in {fcNan, fcInf, fcNegInf}: 0.0 else: keys.t0Ms
      news.samples = samples
      news.dtMs = dt
      news.t0Ms = t0
      news.fromMs = t0
      news.toMs = t0 + float64(samples.len - 1) * dt
      news.channelText = channelWords(keys)
      news.stationText = stationWords(keys)
      post(to, ctx.id, news)
    except CatchableError as e:
      news.failure = e.msg
      post(to, ctx.id, news)

proc comparePictureWork*(a, b: CompareSlot; opt: CompareOptions; gen: uint64;
    to: Poster): JobWork =
  ## Works out the picture of slots `a` and `b` under `opt` and posts it.
  ## A cancel asked for before it posts (a newer ask) drops the result.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "comparing"
    ctx.checkCancelled()
    var pic: ComparePicture
    {.cast(gcsafe).}:
      pic = pictureOf(a, b, opt)
    if ctx.cancelled: return
    postPicture(to, ctx.id, pic, gen)

proc compareRefWork*(path: string; gen: uint64; t0Ms: float64; to: Poster): JobWork =
  ## Reads a reference's SEG-Y and posts its samples. `t0Ms` is the first
  ## sample's time, as the archive records it.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the reference"
    var news = CompareNews(gen: gen)
    try:
      let (samples, us) = readReferenceFile(path)
      if samples.len == 0:
        raise newException(ValueError, "the reference file has no sample")
      if not (us > 0 and us < Inf):
        raise newException(ValueError, "the reference has no sample interval")
      let dt = us / 1000.0
      let t0 = if t0Ms.isNaN: 0.0 else: t0Ms
      news.samples = samples
      news.dtMs = dt
      news.t0Ms = t0
      news.fromMs = t0
      news.toMs = t0 + float64(samples.len - 1) * dt
      post(to, ctx.id, news)
    except CatchableError as e:
      news.failure = e.msg
      post(to, ctx.id, news)
