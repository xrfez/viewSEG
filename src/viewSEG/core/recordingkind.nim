## What kind of recording a seismic file is: the plan of its segments
## (`planRecording`, the one place their times and receivers are made) and a
## description of it (`describeRecording`) with one verdict, the `RecordingKind`.
## Nothing here knows of cutting or shot logs: the inputs are the file, the
## vendor registry and a cancel check.
##
## The kind is the answer to two yes/no questions, built on the sub-receivers
## of `segmentclock` (one station may have several channels; each is a
## sub-receiver whose segments chain by their start times):
##
## 1. Is it a shot gather? The receiver line and point change from trace to
##    trace. One segment per sub-receiver is never proof of continuity: when
##    every sub-receiver has exactly one segment and the file has more than one
##    live trace, the traces either all carry one station (the channels of one
##    station that start together: a receiver gather, not continuous,
##    `swSameStart`) or they do not (stations differ, or no trace carries a
##    line and point: `rkShotGather`). Otherwise it is a receiver gather. A
##    file with exactly one live trace is a receiver gather of one segment.
## 2. Only for a receiver gather: is it continuous? Yes: `rkReceiverContinuous`.
##    No: `rkReceiverSliced`, and `slicedWhy` says why.
##
## A file with stations of one segment and others of several goes through the
## second question as it stands.
##
## The continuous test: each trace starts a whole number of trace lengths
## after the one before it, and there is no variance. All times are compared in
## samples. Per sub-receiver, in time order, let L be its segment length (the
## middle one). The `step` is the commonest difference between consecutive
## start times that lies from 0.9 L to L (one sample more at the top); when
## none does, the step is L. A boundary is on the step when the next start
## minus the previous one is k * step, k a whole number from 1, within one
## sample; k > 1 means k - 1 segments were not recorded (the box was off and
## the system pads with zeros). The segments cover the step when each is at
## least the step long (within one sample) and repeats no more than
## `EndRepeatShare` of its length beyond the step (a little data at the ends).
## A receiver gather is continuous only when every boundary of every
## sub-receiver is on the step and every segment covers it. Otherwise it is
## time sliced, and `slicedWhy` names the first trace off the step, or says
## the traces leave dead time between them or overlap. A receiver with one
## segment has no step to keep. When every trace carries one start time the
## reason is `swSameStart`.

import std/[algorithm, math, sequtils]
import parseSEG
import processSEG
import processSEG/continuous/slice
import ./[filesystem, jobs, segmentclock, vendormaps]

const
  EndRepeatShare* = 0.1
    ## a segment may be this share of its length longer than the step between
    ## starts: it repeats a little of the data at its ends and still continues

const
  NoLiveTraceWords* = "No live trace with a start time."
    ## what a file with no live trace with a start time is told
  NoSampleIntervalWords* = "There is no seismic trace with a sample interval."
    ## what a file with no seismic trace with a sample interval is told

type
  RecordingKind* = enum
    rkShotGather         ## the receiver changes from trace to trace
    rkReceiverContinuous ## one receiver recorded continuously
    rkReceiverSliced     ## a receiver gather that is not continuous; see `SlicedWhy`

  SlicedWhy* = enum
    swNone
    swIrregular ## a trace starts off the step: `offTrace`, `offSeconds`
    swShort     ## the traces are shorter than the step: dead time between them
    swOverlap   ## traces overlap by more than a little repeated data: `overlapSeconds`
    swSameStart ## every trace carries the same start time

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
    boundaries*: int               ## between consecutive segments of one receiver
    abutting*: int                 ## the next starts one step after the last
    skips*: int                    ## boundaries after whole missing segments (k > 1)
    missingSegments*: int          ## whole segments absent, summed over `skips`
    irregular*: int                ## starts that are not a whole number of steps apart
    uncovered*: int                ## receivers with a segment that does not cover the step
    stepSeconds*, segmentSeconds*: float64
      ## for `swShort`: the traces' length and the spacing of their starts (or the step)
    offTrace*: int
      ## the trace (from 1) that starts off the step (`swIrregular`) or overlaps (`swOverlap`)
    offSeconds*: float64           ## how far off the step it starts
    overlapSeconds*: float64       ## how far it overlaps
    unevenChannels*: int           ## from the segment clock
    kind*: RecordingKind
    slicedWhy*: SlicedWhy          ## for `rkReceiverSliced`

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
  if startFieldDeclared(file[], reg):
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
  n: int ## samples
  row: int

type Station = tuple[line, point: float64; index: int16]

func stepOf(diffs: seq[int]; len: int): int =
  ## The commonest start difference d, in samples, with 0.9 len <= d <= len (one
  ## sample more at the top); `len` when none lies there. A tie goes to the longer.
  result = len
  var sorted = diffs
  sorted.sort()
  var best, run = 0
  for x in 0 ..< sorted.len:
    run = if x > 0 and sorted[x] == sorted[x - 1]: run + 1 else: 1
    if 10 * sorted[x] >= 9 * len and sorted[x] <= len + 1 and run >= best:
      best = run
      result = sorted[x]

proc tally(segs: seq[Seg]; i, j: int; dtS: float64; r: var RecordingFacts) =
  ## Counts the boundaries of the receiver `segs[i ..< j]` (two or more
  ## segments, in time order) against its step and checks the segments cover it.
  ## The first trace that breaks the rule names the reason, unless one is named.
  let count = j - i
  var diffs = newSeq[int](count - 1)
  for x in 1 ..< count:
    diffs[x - 1] = int(round((segs[i + x].start - segs[i + x - 1].start) / dtS))
  var lens = newSeq[int](count)
  for x in 0 ..< count: lens[x] = segs[i + x].n
  lens.sort()
  let step = stepOf(diffs, lens[count div 2])
  for x in 1 ..< count:
    let d = diffs[x - 1]
    let k = max(1, (2 * d + step) div (2 * step))
    let off = d - k * step
    if abs(off) <= 1:
      if k == 1: inc r.abutting
      else:
        inc r.skips
        r.missingSegments += k - 1
    else:
      inc r.irregular
      if r.slicedWhy == swNone:
        r.offTrace = segs[i + x].row + 1
        if k > 1:
          r.slicedWhy = swIrregular
          r.offSeconds = float64(abs(off)) * dtS
          r.stepSeconds = float64(step) * dtS
        elif off > 0:
          r.slicedWhy = swShort
          (r.segmentSeconds, r.stepSeconds) = (float64(lens[count div 2]) * dtS,
            float64(d) * dtS)
        else:
          r.slicedWhy = swOverlap
          r.overlapSeconds = float64(-off) * dtS
  for x in i ..< j:
    let n = segs[x].n
    if n + 1 < step or 10 * (n - step) > n:
      if r.slicedWhy == swNone:
        r.offTrace = segs[x].row + 1
        if n < step:
          r.slicedWhy = swShort
          (r.segmentSeconds, r.stepSeconds) = (float64(n) * dtS, float64(step) * dtS)
        else:
          r.slicedWhy = swOverlap
          r.overlapSeconds = float64(n - step) * dtS
      inc r.uncovered
      break

proc describeRecording*(plan: RecordingPlan): RecordingFacts =
  ## The facts and the verdict of `plan`.
  let meta = plan.meta
  let dtS = meta.dtMs / 1000
  result = RecordingFacts(dtMs: meta.dtMs, firstTime: Inf, lastTime: -Inf,
    unevenChannels: plan.clock.unevenChannels)
  var segs: seq[Seg]
  for row in 0 ..< meta.len:
    let n = meta.liveSamples(row, high(int))
    if meta.isLive(row) and n > 0:
      let start = plan.times[row] + meta.sampleTimeMs(row, 0) / 1000
      if start.classify in {fcNormal, fcZero, fcNegZero, fcSubnormal} and abs(start) <= 1e11:
        segs.add Seg(recv: plan.receivers[row], start: start, finish: start + n.float64 * dtS,
          n: n, row: row)
  if segs.len == 0: return
  segs.sort do (a, b: Seg) -> int:
    result = cmp(a.recv, b.recv)
    if result == 0: result = cmp(a.start, b.start)
    if result == 0: result = cmp(a.row, b.row)
  result.segments = segs.len
  # per receiver with a station: how many segments it has
  var placed: seq[tuple[st: Station; segs: int]]
  var i = 0
  while i < segs.len:
    var j = i + 1
    while j < segs.len and segs[j].recv == segs[i].recv: inc j
    let k = meta.keys(segs[i].row)
    inc result.components
    if not (k.rcvLine.isNaN or k.rcvPoint.isNaN):
      let st = stationKey(k.rcvLine, k.rcvPoint, k.rcvIndex)
      placed.add (st: (st.line, st.point, st.index), segs: j - i)
    for x in i ..< j:
      result.firstTime = min(result.firstTime, segs[x].start)
      result.lastTime = max(result.lastTime, segs[x].finish)
      if x > i:
        inc result.boundaries
    if j - i > 1: tally(segs, i, j, dtS, result)
    i = j
  result.ready = true
  placed.sort do (a, b: tuple[st: Station; segs: int]) -> int:
    result = cmp(a.st.line, b.st.line)
    if result == 0: result = cmp(a.st.point, b.st.point)
    if result == 0: result = cmp(a.st.index, b.st.index)
  var stations = 0
  for n in 0 ..< placed.len:
    if n == 0 or placed[n].st != placed[n - 1].st: inc stations
  result.stations = stations
  # question 1: one segment per receiver is no proof of continuity. With more than one
  # live trace, every receiver having one segment means the traces all start together
  # (several channels of one station: a receiver gather that is not continuous) or the
  # receiver changes from trace to trace (a shot gather).
  if result.segments == result.components and result.segments > 1:
    if placed.len == result.components and stations == 1:
      result.kind = rkReceiverSliced
      result.slicedWhy = swSameStart
    else:
      result.kind = rkShotGather
      result.slicedWhy = swNone
  else:
    # question 2: is the receiver gather continuous? `tally` named the first trace off
    # the step; traces that all start together are named first
    if segs.len > 1 and segs.allIt(it.start == segs[0].start): result.slicedWhy = swSameStart
    result.kind = if result.slicedWhy == swNone: rkReceiverContinuous else: rkReceiverSliced

func isContinuousGather*(f: RecordingFacts): bool =
  ## True for a continuous receiver gather: the one kind the cut accepts.
  f.kind == rkReceiverContinuous

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
