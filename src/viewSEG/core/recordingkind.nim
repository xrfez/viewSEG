## What kind of recording a seismic file is: the plan of its segments
## (`planRecording`, the one place their times and receivers are made) and a
## description of it (`describeRecording`) with one verdict, the `RecordingKind`.
## Nothing here knows of cutting or shot logs: the inputs are the file, the
## vendor registry and a cancel check.
##
## - `rkShotRecord`: no receiver has more than one segment, and the longest
##   trace is no longer than `LongTraceSeconds`. The file holds one record,
##   one trace per receiver.
## - `rkSlicedGather`: the file was cut by shots already. Any of three
##   signs is enough, checked in this order. The segments of one receiver carry more than one
##   source identity (the source line, point, index and X/Y of their keys,
##   those that are present; the record and file numbers are not read, since
##   a continuous recording may store each segment as its own record), or
##   more than `HeavyOverlapShare` of the boundaries between one receiver's
##   segments start before the middle of the segment before (traces that
##   cover each other, as dense shooting gives, when the keys do not name
##   the shot), or
##   the receivers have several segments and fewer than `ContinuousShare` of
##   their boundaries abut (the next start within one sample of this end) or
##   overlap.
## - `rkContinuous`: anything else, with isolated gaps allowed.
##
## A file of one trace per receiver is continuous when that trace is longer
## than `LongTraceSeconds`: it is one long recording.

import std/[algorithm, math]
import parseSEG
import processSEG
import processSEG/continuous/slice
import ./[filesystem, jobs, segmentclock, vendormaps]

const
  ContinuousShare* = 0.5
    ## the share of a file's segment boundaries that must abut or overlap for
    ## it to count as one recording rather than records cut apart
  HeavyOverlapShare* = 0.5
    ## more than this share of the boundaries starting inside the first half of
    ## the segment before mean the traces cover each other, as
    ## records cut by shot do
  LongTraceSeconds* = 60.0
    ## one trace per receiver is a continuous recording only when it is
    ## longer than this

type
  RecordingKind* = enum
    rkContinuous
    rkShotRecord
    rkSlicedGather

  SlicedBy* = enum
    sbNone
    sbSources ## the segments of a receiver carry different sources
    sbOverlap ## the segments mostly cover the same time as their neighbours
    sbGaps    ## most boundaries between segments are gaps

  RecordingPlan* = object
    ## The segments of a file as the cut plans them.
    meta*: ChunkMeta
    times*: seq[float64] ## per trace: UTC POSIX seconds of its time zero
    receivers*: seq[int] ## per trace: its receiver
    clock*: SegmentClock
    streams*: SliceStreams

  RecordingFacts* = object
    ready*: bool                   ## the file has a live trace and a sample interval
    dtMs*: float64
    stations*: int                 ## receiver points
    components*: int               ## receivers: what each cut record holds as traces
    segments*: int
    firstTime*, lastTime*: float64 ## UTC POSIX seconds; the span of every segment
    longest*: float64              ## the longest trace, seconds
    boundaries*: int               ## between consecutive segments of one receiver
    abutting*, overlapping*, gapped*: int
    heavy*: int                    ## boundaries where the next segment starts before the middle of the last
    sourcePoints*: int             ## most distinct sources among one receiver's segments
    kind*: RecordingKind
    slicedBy*: SlicedBy

  RecordingSink* = ref object
    ## Filled by `recordingFactsWork`; read it once the job has ended.
    facts*: RecordingFacts

proc planRecording*(file: ptr SeismicFile; source: string; dtMs: float64;
    reg: VendorRegistry; check: proc () {.gcsafe.} = nil): RecordingPlan =
  ## The plan of `file` (open, read from `source`): its keys are read when missing and the start
  ## times come from the trace headers when a map of `reg` names them.
  ## `check` may raise to stop. Runs on a job's thread.
  if not file[].hasKeys:
    if not file[].inMemory: fs.mappedRead(source, headers = true)
    file[].ensureKeys()
  result.meta = chunkMeta(file[], 0 ..< file[].len, dtMs = dtMs)
  if reg.maps.len > 0:
    if not file[].inMemory: fs.mappedRead(source, headers = true)
    result.clock = segmentClock(file[], reg, check)
  if result.clock.fromHeaders:
    result.times = result.clock.times
    result.receivers = result.clock.receivers
  else:
    result.times = newSeq[float64](file[].len)
    for i in 0 ..< file[].len: result.times[i] = result.meta.keys(i).time
    result.receivers = receiverIds(file[], withChannel = true)
  result.streams = initSliceStreams(result.meta, result.times, result.receivers)

type Seg = object
  recv: int
  start, finish: float64
  row: int

type Source = tuple[line, point, x, y: float64; index: int16; present: set[0 .. 4]]

func sourceOf(k: TraceKeys): Source =
  func orZero(x: float64): float64 = (if x.isNaN: 0.0 else: x)
  result = (orZero(k.srcLine), orZero(k.srcPoint), orZero(k.srcX), orZero(k.srcY),
    k.srcIndex, {})
  if not k.srcLine.isNaN: result.present.incl 0
  if not k.srcPoint.isNaN: result.present.incl 1
  if not k.srcX.isNaN: result.present.incl 2
  if not k.srcY.isNaN: result.present.incl 3
  if k.srcIndex != 0: result.present.incl 4

func cmpSource(a, b: Source): int =
  result = cmp(a.line, b.line)
  if result == 0: result = cmp(a.point, b.point)
  if result == 0: result = cmp(a.x, b.x)
  if result == 0: result = cmp(a.y, b.y)
  if result == 0: result = cmp(a.index, b.index)
  if result == 0: result = cmp(a.present.card, b.present.card)

proc describeRecording*(plan: RecordingPlan): RecordingFacts =
  ## The facts and the verdict of `plan`.
  let meta = plan.meta
  let dtS = meta.dtMs / 1000
  result = RecordingFacts(dtMs: meta.dtMs, firstTime: Inf, lastTime: -Inf)
  var segs: seq[Seg]
  for row in 0 ..< meta.len:
    let n = meta.liveSamples(row, high(int))
    if meta.isLive(row) and n > 0:
      let start = plan.times[row] + meta.sampleTimeMs(row, 0) / 1000
      if start.classify in {fcNormal, fcZero, fcNegZero, fcSubnormal} and abs(start) <= 1e11:
        segs.add Seg(recv: plan.receivers[row], start: start, finish: start + n.float64 * dtS,
          row: row)
  if segs.len == 0: return
  segs.sort do (a, b: Seg) -> int:
    result = cmp(a.recv, b.recv)
    if result == 0: result = cmp(a.start, b.start)
    if result == 0: result = cmp(a.row, b.row)
  result.segments = segs.len
  var stations = newSeq[tuple[line, point: float64; index: int16]]()
  var multi = false
  var i = 0
  while i < segs.len:
    var j = i + 1
    while j < segs.len and segs[j].recv == segs[i].recv: inc j
    let k = meta.keys(segs[i].row)
    let st = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
    stations.add (st.line, st.point, st.index)
    inc result.components
    var reach = segs[i].finish
    var sources: seq[Source]
    for x in i ..< j:
      result.firstTime = min(result.firstTime, segs[x].start)
      result.lastTime = max(result.lastTime, segs[x].finish)
      result.longest = max(result.longest, segs[x].finish - segs[x].start)
      let src = sourceOf(meta.keys(segs[x].row))
      if src.present != {}: sources.add src
      if x > i:
        multi = true
        inc result.boundaries
        let delta = segs[x].start - reach
        if abs(delta) <= dtS: inc result.abutting
        elif delta < 0:
          inc result.overlapping
          if segs[x].start < segs[x - 1].start + (segs[x - 1].finish - segs[x - 1].start) / 2:
            inc result.heavy
        else: inc result.gapped
        reach = max(reach, segs[x].finish)
    sources.sort(cmpSource)
    var different = 0
    for s in 0 ..< sources.len:
      if s == 0 or cmpSource(sources[s - 1], sources[s]) != 0: inc different
    result.sourcePoints = max(result.sourcePoints, different)
    i = j
  stations.sort do (a, b: tuple[line, point: float64; index: int16]) -> int:
    result = cmp(a.line, b.line)
    if result == 0: result = cmp(a.point, b.point)
    if result == 0: result = cmp(a.index, b.index)
  for s in 0 ..< stations.len:
    if s == 0 or stations[s - 1] != stations[s]: inc result.stations
  result.ready = true
  if not multi and result.longest <= LongTraceSeconds:
    result.kind = rkShotRecord
  elif result.sourcePoints > 1:
    result.kind = rkSlicedGather
    result.slicedBy = sbSources
  elif float64(result.heavy) > HeavyOverlapShare * float64(result.boundaries):
    result.kind = rkSlicedGather
    result.slicedBy = sbOverlap
  elif result.boundaries > 0 and
      float64(result.abutting + result.overlapping) < ContinuousShare * float64(result.boundaries):
    result.kind = rkSlicedGather
    result.slicedBy = sbGaps

proc recordingFactsWork*(file: ptr SeismicFile; source: string; dtMs: float64;
    reg: VendorRegistry; sink: RecordingSink): JobWork =
  ## Describes `file` on a job thread (`file` stays open until the job ends).
  ## `sink.facts` is set when it finishes; a cancel leaves it unset.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      let plan = planRecording(file, source, dtMs, reg, proc () {.gcsafe.} =
        ctx.checkCancelled())
      ctx.checkCancelled()
      sink.facts = describeRecording(plan)
