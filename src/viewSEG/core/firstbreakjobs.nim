## The job that finds a record's first breaks for the overlay (`core/firstbreaks`):
## it reads the record a chunk of traces at a time, picks each trace's first
## break with processSEG's `qc/firstbreak` (its defaults), and fits one
## refraction model to the confident picks against the traces' offsets with
## `qc/shotfit`'s `fitShot`; the model's time at each trace is `ShotFit.modelMs`.
## Nothing is computed here that those two do not give: the picks are the
## picker's, the model's times the fit's, the offsets the trace keys'.
##
## **Offsets.** From the keys, as the file's index holds them: the survey's
## when one is joined (the join derives each trace's `offset`), else the
## header's own, else the one parseSEG derives from the file's own coordinates
## when it reads the keys. Which of the two it was is `FirstBreaks.source`.
##
## **Killed traces** (`BreakKey.killed`) and traces that cannot be decoded are
## not live for the picker and the fit: they get no pick, and the model
## ignores them. The record is taken as one spread, all its seismic traces.
##
## The job is posted as `mkFirstBreaks`; the state drops an answer whose job
## it no longer waits for.

import std/[algorithm, math, sequtils]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/qc/[firstbreak, shotfit]
import filesystem, firstbreaks, inbox, jobs, session, threads

const BreakChunk* = 512 ## traces read and picked at a time

type BreakProgress* = proc (done, total: int): bool {.closure, gcsafe.}
  ## Called after each chunk; false asks the work to stop (`JobCancelledError`).

proc breaksOfRecord*(file: ptr SeismicFile; path: string; traces: Slice[int];
    killed: openArray[int]; progress: BreakProgress = nil;
    off: openArray[uint8] = []): FirstBreaks =
  ## The first breaks of the record `traces` of `file` (at `path`), the
  ## traces in `killed` (file trace numbers, ascending) left out. Reads
  ## the record in place; raises `JobCancelledError` when `progress` says stop.
  ##
  ## - The sample interval is the first seismic trace's that has one, as
  ##   the plot's reader takes it; a trace with another interval is not live.
  ##   Without one the result is `bkFailed`.
  ## - A trace's times are on its own axis (`t0Ms`; one without a `t0Ms` is
  ##   taken to start where the plot's axis does); `shiftMs` moves them to the plot's.
  ## - The model is fitted from the traces `fitMask` says (all, unless the
  ##   record has several components; `off` are those the panel switches off);
  ##   every live trace gets its time from it. A header offset of 0 is unset.
  template f: untyped = file[]
  let n = traces.len
  result = FirstBreaks(state: bkDone, first: traces.a, pickMs: newSeq[float64](n),
    modelMs: newSeq[float64](n), confidence: newSeq[float64](n), shiftMs: newSeq[float64](n),
    flagged: newSeq[bool](n), dtMs: NaN, thresholdMs: NaN)
  for i in 0 ..< n:
    result.pickMs[i] = NaN
    result.modelMs[i] = NaN
  if n == 0: return
  var keys = newSeq[TraceKeys](n)
  var dt = NaN
  var layoutT0 = 0.0
  var firstUs = NaN
  for i in 0 ..< n:
    keys[i] = f.index.keys[traces.a + i]
    let k = keys[i]
    if dt.isNaN and k.isSeismic and k.intervalUs > 0 and k.intervalUs < Inf:
      (dt, firstUs) = (k.intervalUs / 1000, k.intervalUs)
      if k.t0Ms.classify notin {fcNan, fcInf, fcNegInf}: layoutT0 = k.t0Ms
  if dt.isNaN:
    result.state = bkFailed
    result.why = "the sample interval is not known"
    return
  result.dtMs = dt
  var dead: seq[int] # rows of the record that are not live: killed, other interval, undecodable
  for t in killed:
    if t in traces: dead.add t - traces.a
  var fixT0 = false
  for i in 0 ..< n:
    let k = keys[i]
    if k.isSeismic and k.intervalUs > 0 and k.intervalUs < Inf and
        abs(k.intervalUs - firstUs) > 1e-9 * firstUs:
      dead.add i
    if keys[i].t0Ms.classify in {fcNan, fcInf, fcNegInf}:
      keys[i].t0Ms = layoutT0
      fixT0 = true
    result.shiftMs[i] = layoutT0 - keys[i].t0Ms
  let cols = max(1, f.maxSamples(traces))
  let plan = initFirstBreakPlan(float32, FirstBreakParams(), dt, cols)
  var ws = initWorkspace()
  ws.reserve(plan.workspaceSize)
  var picks = newSeq[FirstBreakPick](n)
  var first = traces.a
  while first <= traces.b:
    let part = first .. min(traces.b, first + BreakChunk - 1)
    fs.mappedRead(path)
    var log: DiagLog
    let samples = f.readTraces(part, 0 ..< cols, log)
    var failed: seq[int] # rows of this chunk (0-based in it): undecodable, then the others
    for d in log:
      if d.loc.trace in part:
        failed.add d.loc.trace - part.a
        dead.add d.loc.trace - traces.a
    for r in dead:
      if r + traces.a in part: failed.add r + traces.a - part.a
    failed.sort()
    failed = deduplicate(failed, isSorted = true)
    let own = f.rowsOf(part)
    var chunkKeys: seq[TraceKeys] = @[]
    var counts: seq[int] = @[]
    if fixT0:
      for r in 0 ..< part.len:
        chunkKeys.add keys[part.a - traces.a + r]
        counts.add own.numSamples(r)
    let meta = initChunkMeta(if fixT0: rowsOf(chunkKeys, counts) else: own, dt, 0, failed)
    plan.pickInto(samples, meta, picks.toOpenArray(part.a - traces.a, part.b - traces.a), ws)
    first = part.b + 1
    if progress != nil and not progress(part.b - traces.a + 1, n):
      raise newException(JobCancelledError, "cancelled")
  dead.sort()
  dead = deduplicate(dead, isSorted = true)
  for i in 0 ..< n:
    result.pickMs[i] = picks[i].timeMs
    result.confidence[i] = picks[i].confidence
    if not picks[i].timeMs.isNaN: inc result.picked
  # The offsets: the keys' (a join's, the headers', or derived from the file's
  # coordinates); a header offset of exactly 0 is one left unset.
  var any = false
  var surveyed = false
  for i in 0 ..< n:
    let x = keys[i].offset
    if x == 0: keys[i].offset = NaN
    elif keys[i].isSeismic and not x.isNaN:
      any = true
      if jgDerived in f.index.joinedGroups(traces.a + i): surveyed = true
  result.picks = picks
  result.source = if not any: bsNone elif surveyed: bsSurvey else: bsFile
  if not any: return
  # one kind of sensor is fitted (a node record's components are not comparable);
  # the others are given the model's time
  let (mask, what) = fitMask(keys, off)
  result.fittedFrom = what
  var fitPicks = picks
  for i in 0 ..< n:
    if not mask[i]: fitPicks[i].confidence = 0
  let zeros = newSeq[int](n)
  let meta = initChunkMeta(rowsOf(keys, zeros), dt, 0, dead)
  var fit: ShotFit
  try:
    fitShot(meta, fitPicks, ShotFitParams(), fit)
  except ValueError:
    return # no model: the picks stand alone
  result.fit = fit
  result.hasFit = true
  result.used = fit.used
  result.thresholdMs = fit.threshold
  for i in 0 ..< n:
    result.modelMs[i] = fit.modelMs[i]
    result.flagged[i] = fit.suspect[i]
    if not fit.modelMs[i].isNaN: inc result.modelled

proc firstBreaksWork*(file: ptr SeismicFile; path: string; key: BreakKey;
    traces: Slice[int]; to: Poster): JobWork =
  ## The work of a job that finds the first breaks of record `key.gather`
  ## (`traces`) of open file `key.file` (`file`, at `path`) and posts them
  ## (`mkFirstBreaks`). Submitted with the file in `reads`.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var found: FirstBreaks
    {.cast(gcsafe).}:
      ctx.setPhase "picking and fitting the first breaks"
      found = breaksOfRecord(file, path, traces, key.killed,
        proc (done, total: int): bool = ctx.progress(done, total), key.off)
      found.key = key
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkFirstBreaks, breaks: move found)
