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
##    station that start together) or they do not (stations differ, or no trace
##    carries a line and point or group coordinates: `rkShotGather`; a trace
##    without a line and point is placed by its coordinates). Traces of one station that
##    start together are one segment, continuous, when each component type
##    appears once; two of one component (type codes of 0 count as one) cannot
##    be told from segments without times: not continuous, `swSameStart`.
##    Otherwise it is a receiver gather. A file with exactly one live trace is a
##    receiver gather of one segment.
## 2. Only for a receiver gather: is it continuous? Yes: `rkReceiverContinuous`.
##    No: `rkReceiverSliced`, and `slicedWhy` says why.
##
## A file with stations of one segment and others of several goes through the
## second question as it stands. A receiver gather that is not continuous is told apart
## from a shot gather by the order of the file (`receiverChanges`): when the receiver changes
## between most consecutive segments of one component, the receivers repeat from record to
## record (several shots, uneven in time): a shot gather; when they stay, the segments of a
## receiver follow each other: time sliced. Consecutive traces of one receiver point that
## share one start time are one segment (its components, coded or not), and a receiver is
## named by its line and point, else by its group coordinates, else by its channel.
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
## sub-receiver is on the step, every segment covers it, and at least one
## boundary of the file is one step (k = 1): some trace follows directly on
## another. When every boundary skips (k > 1) the gaps are whole but nothing
## follows on anything, as in records sliced at shot times: not continuous
## (`swNoFollow`). One such pair anywhere in the file is enough; the other gaps
## are then a box switched off. Otherwise it is time sliced, and `slicedWhy`
## names the first trace off the rule with the numbers measured for it. A
## receiver with one segment has no step to keep.
## When every trace of the file carries one start time the reason is
## `swSameStart`.
##
## When no start difference lies from 0.9 L to L, the step is taken from the
## commonest difference divided by a whole number from 2 to 8 that lies there
## (every other trace not recorded), and only then is it L. With no trace one step after
## another such a file is not continuous; the step still measures how far apart its traces
## are.
##
## The kind is asked of any loaded file, so `describeRecording` looks only at the
## first `KindStarts` distinct start times of each sub-receiver (traces that
## share a start are the components of one segment: the step is compared with the
## next trace of a different start). The cut places every segment, so its job asks
## for `AllStarts`: a trace off the step anywhere refuses the cut with a sentence.

import std/[algorithm, math, sequtils, tables]
import parseSEG
import processSEG
import processSEG/continuous/slice
import ./[cutcarry, filesystem, jobs, segmentclock, traceorder, vendormaps]

export traceorder

const
  KindStarts* = 8
    ## how many distinct start times of a receiver the kind is decided from: cheap enough to
    ## ask of any loaded file
  AllStarts* = high(int)
    ## every start time: what the cut checks, because it places every segment
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
    swOffStep   ## the first trace off the rule: `offTrace`, `offSeconds` (how long after the
                ## one before it it starts, or, when `offLength`, how long it is) and
                ## `segmentSeconds` (the trace length of the others)
    swNoStep    ## the traces of a station start at different times but no step can be measured
    swSameStart ## every trace carries the same start time
    swNoFollow
      ## every start is a whole number of steps after the one before it, but none just one
      ## step: no trace follows directly on another (`fewestSteps`), as in records sliced at
      ## shot times

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
    stations*: int                 ## receiver points (line and point, else group coordinates)
    components*: int               ## receivers: what each cut record holds as traces
    segments*: int
    firstTime*, lastTime*: float64 ## UTC POSIX seconds; the span of every segment
    boundaries*: int               ## between consecutive segments of one receiver
    abutting*: int                 ## the next starts one step after the last
    skips*: int                    ## boundaries after whole missing segments (k > 1)
    missingSegments*: int          ## whole segments absent, summed over `skips`
    irregular*: int                ## starts that are not a whole number of steps apart
    uncovered*: int                ## receivers with a segment that does not cover the step
    offTrace*: int                 ## for `swOffStep`: the trace (from 1) that breaks the rule
    fewestSteps*: int
      ## the fewest steps from a start to the next of its receiver, over the boundaries on the
      ## step (0 for none): for `swNoFollow`
    offSeconds*: float64
      ## for `swOffStep`: how long after the segment before it that trace starts, or its
      ## length when `offLength`
    offLength*: bool ## the trace is off in its length, not in its start
    segmentSeconds*: float64 ## for `swOffStep`: the length of the other traces
    unevenChannels*: int ## from the segment clock
    kind*: RecordingKind
    slicedWhy*: SlicedWhy
      ## for `rkReceiverSliced`, and for a `rkShotGather` told by the order of the file: why
      ## the continuous test failed (`swNone` for a shot gather of one segment per receiver)
    order*: TraceOrder ## how the traces of the file are written (`traceOrder`)
    carryHeaderBytes*: int64
      ## a SEG-D file's cut record keeps its source's headers: their bytes per record
      ## (`cutcarry.carryHeaderBytes`); 0 when the cut builds its headers from keys
    forced*: bool ## `kind` was set by the user, not told from the file (`treatas.applied`)

  RecordingSink* = ref object
    ## Filled by `recordingFactsWork`; read it once the job has ended.
    facts*: RecordingFacts
    ownKeys*: bool
      ## the keys the facts were made from are the file's own headers: no survey join or
      ## station move changed them

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
    # The headers give each trace's first sample; the streams take its time zero, which is
    # that less the start of its channel set (sample 0 lies at time zero + `t0Ms`).
    result.times = result.clock.times
    for i in 0 ..< result.times.len: result.times[i] -= result.meta.t0Ms(i) / 1000
    result.receivers = result.clock.receivers
  else:
    # The keys' time is time zero, but a Rev 3 Timestamp gives the first sample: less the
    # channel set's start then, as for the headers' times above.
    result.times = newSeq[float64](file[].len)
    for i in 0 ..< file[].len:
      let k = result.meta.keys(i)
      result.times[i] = if k.timeOrigin == toFirstSample: k.time - k.t0Ms / 1000 else: k.time
    result.receivers = receiverIds(file[], result.times, dtMs / 1000)
  result.streams = initSliceStreams(result.meta, result.times, result.receivers)

proc endToEndTimes*(plan: RecordingPlan): seq[float64] =
  ## The times of the traces of `plan` if each receiver's traces followed one another end to end
  ## from the start of its first trace, in file order: what a file whose traces of a component
  ## all carry one start time is taken to be when the user says it is continuous.
  let meta = plan.meta
  let dtS = meta.dtMs / 1000
  result = plan.times
  var next = initTable[int, float64]()
  for row in 0 ..< meta.len:
    let n = meta.liveSamples(row, high(int))
    if meta.isLive(row) and n > 0:
      let r = plan.receivers[row]
      let offset = meta.sampleTimeMs(row, 0) / 1000
      let start = next.getOrDefault(r, plan.times[row] + offset)
      result[row] = start - offset
      next[r] = start + n.float64 * dtS

func firstStartMissing*(plan: RecordingPlan): bool =
  ## Whether the first live trace of a receiver of `plan` has no start time (none read, or the
  ## epoch itself): traces taken end to end from it (`endToEndTimes`) would not be placed in
  ## time.
  var seen = initTable[int, bool]()
  for row in 0 ..< plan.meta.len:
    if plan.meta.isLive(row) and plan.receivers[row] notin seen:
      seen[plan.receivers[row]] = true
      if not (plan.times[row] > 0): return true

type Seg = object
  recv: int
  start, finish: float64
  n: int ## samples
  row: int

type Place = StationPlace

func placeOf(k: TraceKeys): Place {.inline.} = stationPlace(k)

func stepOf(diffs: seq[int]; len: int): int =
  ## The commonest start difference d, in samples, with 0.9 len <= d <= len (one
  ## sample more at the top); when none lies there, the commonest d / k (k = 2 to 8,
  ## within one sample) that does, as when every other trace was not recorded; `len`
  ## when still none. A tie goes to the longer.
  result = len
  var sorted = diffs
  sorted.sort()
  func inBand(d: int): bool = 10 * d >= 9 * len and d <= len + 1
  var best, run = 0
  for x in 0 ..< sorted.len:
    run = if x > 0 and sorted[x] == sorted[x - 1]: run + 1 else: 1
    if inBand(sorted[x]) and run >= best:
      best = run
      result = sorted[x]
  if best == 0:
    var quotients: seq[int] = @[]
    for d in sorted:
      for k in 2..8:
        let q = (d + k div 2) div k
        if abs(q * k - d) <= 1 and inBand(q): quotients.add q
    quotients.sort()
    run = 0
    for x in 0 ..< quotients.len:
      run = if x > 0 and quotients[x] == quotients[x - 1]: run + 1 else: 1
      if run >= best:
        best = run
        result = quotients[x]

proc tally(segs: seq[Seg]; i, j: int; dtS: float64; starts: int; r: var RecordingFacts) =
  ## Counts the boundaries of the receiver `segs[i ..< j]` (in time order) against its step
  ## and checks the segments cover it, for its first `starts` distinct start times: traces
  ## that share a start are the components of one segment, only the first of them is used.
  ## The first trace that breaks the rule names the reason, unless one is named.
  var used: seq[Seg] = @[]
  var x = i
  while x < j and used.len < starts:
    if used.len == 0 or int(round((segs[x].start - used[^1].start) / dtS)) != 0:
      used.add segs[x]
    inc x
  let count = used.len
  if count < 2: return
  r.boundaries += count - 1
  var diffs = newSeq[int](count - 1)
  for x in 1 ..< count:
    diffs[x - 1] = int(round((used[x].start - used[x - 1].start) / dtS))
  var lens = newSeq[int](count)
  for x in 0 ..< count: lens[x] = used[x].n
  lens.sort()
  let typical = lens[count div 2]
  let step = stepOf(diffs, typical)
  var offAt = high(int) # the first used trace off the rule, by its place in the receiver
  var offGap = 0
  for x in 1 ..< count:
    let d = diffs[x - 1]
    let k = max(1, (2 * d + step) div (2 * step))
    let off = d - k * step
    if abs(off) <= 1:
      r.fewestSteps = if r.fewestSteps == 0: k else: min(r.fewestSteps, k)
      if k == 1: inc r.abutting
      else:
        inc r.skips
        r.missingSegments += k - 1
    else:
      inc r.irregular
      if x < offAt:
        offAt = x
        offGap = d
  var lengthAt = high(int)
  for x in 0 ..< count:
    let n = used[x].n
    if n + 1 < step or 10 * (n - step) > n:
      inc r.uncovered
      lengthAt = x
      break
  if r.slicedWhy == swNone and min(offAt, lengthAt) < high(int):
    r.slicedWhy = swOffStep
    r.segmentSeconds = float64(typical) * dtS
    if lengthAt < offAt:
      r.offTrace = used[lengthAt].row + 1
      r.offSeconds = float64(used[lengthAt].n) * dtS
      r.offLength = true
    else:
      r.offTrace = used[offAt].row + 1
      r.offSeconds = float64(offGap) * dtS

proc receiverChanges(meta: ChunkMeta; segs: seq[Seg]; dtS: float64): bool =
  ## Whether, between most consecutive segments of one component in file order, the receiver
  ## point changes (`placeOf`: its line and point, else its group coordinates, else its
  ## channel). Consecutive traces of one point that share one start time are one segment:
  ## they are its components, coded or not, so the channels of one station are never
  ## compared with each other. With coded components each component is followed on its own;
  ## uncoded (0), the segments are followed as one. A trace with neither a station nor group
  ## coordinates has only its channel: a single receiver whose channel number changes from
  ## trace to trace reads as one whose receiver changes.
  var order = segs
  order.sort do (a, b: Seg) -> int: cmp(a.row, b.row)
  var places = newSeq[Place](order.len)
  for x in 0 ..< order.len: places[x] = placeOf(meta.keys(order[x].row))
  var last: array[uint8, tuple[have: bool; place: Place]]
  var pairs, changed = 0
  var x = 0
  while x < order.len:
    var components: set[uint8] = {}
    var y = x
    while y < order.len and places[y] == places[x] and
        int(round((order[y].start - order[x].start) / dtS)) == 0:
      components.incl meta.keys(order[y].row).component
      inc y
    for c in components:
      if last[c].have:
        inc pairs
        if last[c].place != places[x]: inc changed
      last[c] = (true, places[x])
    x = y
  result = 2 * changed > pairs

proc describeRecording*(plan: RecordingPlan; starts = KindStarts): RecordingFacts =
  ## The facts and the verdict of `plan`, the steps checked over the first `starts` distinct
  ## start times of each receiver (`AllStarts`: every one).
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
  var inFile = newSeq[OrderTrace](segs.len) # the live traces in file order
  for x, sg in segs:
    inFile[x] = OrderTrace(component: meta.keys(sg.row).component,
      place: placeOf(meta.keys(sg.row)), start: sg.start)
  segs.sort do (a, b: Seg) -> int:
    result = cmp(a.recv, b.recv)
    if result == 0: result = cmp(a.start, b.start)
    if result == 0: result = cmp(a.row, b.row)
  result.segments = segs.len
  # per receiver with a station: how many segments it has
  var placed: seq[tuple[st: Place; segs: int]]
  var i = 0
  while i < segs.len:
    var j = i + 1
    while j < segs.len and segs[j].recv == segs[i].recv: inc j
    inc result.components
    let place = placeOf(meta.keys(segs[i].row))
    if place.how < 2: placed.add (st: place, segs: j - i)
    for x in i ..< j:
      result.firstTime = min(result.firstTime, segs[x].start)
      result.lastTime = max(result.lastTime, segs[x].finish)
    if j - i > 1: tally(segs, i, j, dtS, starts, result)
    i = j
  result.ready = true
  placed.sort do (a, b: tuple[st: Place; segs: int]) -> int:
    result = cmp(a.st.how, b.st.how)
    if result == 0: result = cmp(a.st.a, b.st.a)
    if result == 0: result = cmp(a.st.b, b.st.b)
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
      if segs.allIt(it.start == segs[0].start):
        # one segment of one station: continuous when every component appears once;
        # like components at one start cannot be told from segments without times
        var seen: seq[int] = @[]
        for sg in segs:
          let c = int(meta.keys(sg.row).component)
          if c in seen: result.slicedWhy = swSameStart
          seen.add c
        if result.slicedWhy == swNone: result.kind = rkReceiverContinuous
      else:
        # the channels of the station start at different times: measure them as one run
        var run = segs
        run.sort do (a, b: Seg) -> int:
          result = cmp(a.start, b.start)
          if result == 0: result = cmp(a.row, b.row)
        tally(run, 0, run.len, dtS, starts, result)
        if result.slicedWhy == swNone: result.slicedWhy = swNoStep
    else:
      result.kind = rkShotGather
      result.slicedWhy = swNone
  else:
    # question 2: is the receiver gather continuous? `tally` named the first trace off
    # the step; traces that all start together are named first. Every boundary a whole
    # number of steps but none of one step is not continuous: no trace follows on another
    if segs.len > 1 and segs.allIt(it.start == segs[0].start): result.slicedWhy = swSameStart
    elif result.slicedWhy == swNone and result.boundaries > 0 and result.abutting == 0:
      result.slicedWhy = swNoFollow
    result.kind = if result.slicedWhy == swNone: rkReceiverContinuous else: rkReceiverSliced
    # not continuous: the receiver changing from trace to trace, in the order of the file, is
    # a shot gather (the receivers repeat from record to record); staying put, a receiver's
    # own segments. `slicedWhy` keeps what the continuous test measured.
    if result.kind == rkReceiverSliced and receiverChanges(meta, segs, dtS):
      result.kind = rkShotGather
  result.order = traceOrder(inFile, dtS, result.kind == rkShotGather)

func isContinuousGather*(f: RecordingFacts): bool =
  ## True for a continuous receiver gather: the one kind the cut accepts.
  f.kind == rkReceiverContinuous

func keysJoined(f: SeismicFile): bool =
  ## Whether a survey join or a station move changed the keys of `f`.
  if f.index.joined: return true
  for groups in f.index.joinedTraces:
    if groups.card > 0: return true

proc recordingFactsWork*(file: ptr SeismicFile; source: string; dtMs: float64;
    reg: VendorRegistry; sink: RecordingSink): JobWork =
  ## Describes `file` on a job thread (`file` stays open until the job ends).
  ## `sink.facts` and `sink.ownKeys` are set when it finishes; a cancel leaves them unset.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      let plan = planRecording(file, source, dtMs, reg, proc () {.gcsafe.} =
        ctx.checkCancelled())
      ctx.checkCancelled()
      sink.facts = describeRecording(plan)
      sink.ownKeys = not keysJoined(file[])
      sink.facts.carryHeaderBytes = carryHeaderBytes(file[], sink.facts.components)
