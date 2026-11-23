## The job that finds a record's first breaks for the overlay (`core/firstbreaks`):
## it reads the record a chunk of traces at a time and picks in two passes with
## processSEG's `qc/firstbreak`, fitting the model with `qc/shotfit`'s `fitShot`.
##
## 1. **First pass**: the picker's defaults over each whole trace. A trace with no visible
##    break gets a pick on noise, anywhere in the record.
## 2. **A model without the noise picks** (`trimmedModel`, `core/breakrule`): the fit is
##    made again on the picks that stay near it (a robust start, then the picks within 3
##    sigmas, at least 12 ms, of the last fit, up to five rounds), at least 10 picks. Its
##    segments are one line unless the second has 15 picks and a clearly better fit.
## 3. **Second pass**: every trace of the fitted sensor is picked again with the picker's own
##    guide (`guideVelocity`, `guideT0Ms`; `beforeMs`, `afterMs` = 100 ms), one guide line
##    per segment of the model, so the search window is the model's time plus or minus 100
##    ms. When the user gave a model (`BreakKey.guide`) the shown picks come from a third
##    pass guided by it, and the fit (for "Use this record's fit") from the second.
## 4. The model is fitted again, trimmed the same way, to the second pass's picks; its
##    times are `ShotFit.modelMs` (or the one line's), and `FirstBreaks.setRule` decides
##    which traces are off (`core/breakrule`).
##
## When the first pass gives no model to trust, its picks stand, and `passNote` says so.
## The record is taken as one spread for the line (`fitShot`'s own `suspect` flags, which
## are meaningless for a 3D record, are not used); the stations are compared along their
## receiver lines by the rule.
##
## **Offsets.** From the keys, as the file's index holds them: the survey's
## when one is joined (the join derives each trace's `offset`), else the
## header's own, else the one parseSEG derives from the file's own coordinates
## when it reads the keys. Which of the two it was is `FirstBreaks.source`.
##
## **Killed traces** (`BreakKey.killed`) and traces that cannot be decoded are
## not live for the picker and the fit: they get no pick, and the model
## ignores them.
##
## The job is posted as `mkFirstBreaks`; the state drops an answer whose job
## it no longer waits for.

import std/[algorithm, math, sequtils]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/qc/[firstbreak, shotfit]
import breakmodel, filesystem, firstbreaks, inbox, jobs, session, threads

const BreakChunk* = 512 ## traces read and picked at a time

func trustNote(what: string; used: int; then: string): string =
  ## Why a pass gave no model to trust, in words.
  if used < MinTrimmedPicks:
    what & " left too few confident picks that hold together (" & $used & ", at least " &
      $MinTrimmedPicks & " are needed): " & then
  else: what & " gave picks no model could be fitted to (they share one offset): " & then

type BreakProgress* = proc (done, total: int): bool {.closure, gcsafe.}
  ## Called after each chunk; false asks the work to stop (`JobCancelledError`).

proc breaksOfRecord*(file: ptr SeismicFile; path: string; traces: Slice[int];
    killed: openArray[int]; progress: BreakProgress = nil;
    off: openArray[uint8] = []; guide: BreakModel = BreakModel()): FirstBreaks =
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
  let passes = if guide.given: 3 else: 2
  let total = n * passes
  type Guided = tuple[params: FirstBreakParams; rows: seq[bool]]
  proc runPass(guides: seq[Guided]; dst: var seq[FirstBreakPick]; doneBefore: int) =
    ## Picks the rows each guide names with its parameters into `dst` (the others stay), the
    ## record read a chunk at a time.
    var plans: seq[FirstBreakPlan[float32]] = @[]
    var ws = initWorkspace()
    for g in guides:
      plans.add initFirstBreakPlan(float32, g.params, dt, cols)
      ws.reserve(plans[^1])
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
      let own = f.rowsOf(part)
      var chunkKeys: seq[TraceKeys] = @[]
      var counts: seq[int] = @[]
      for r in 0 ..< part.len:
        chunkKeys.add keys[part.a - traces.a + r]
        counts.add own.numSamples(r)
      for gi in 0 ..< plans.len:
        var skip = failed
        for r in 0 ..< part.len:
          if not guides[gi].rows[part.a - traces.a + r]: skip.add r
        skip.sort()
        skip = deduplicate(skip, isSorted = true)
        let meta = initChunkMeta(rowsOf(chunkKeys, counts), dt, 0, skip)
        var got = newSeq[FirstBreakPick](part.len)
        plans[gi].pickInto(samples, meta, got, ws)
        for r in 0 ..< part.len:
          if guides[gi].rows[part.a - traces.a + r]: dst[part.a - traces.a + r] = got[r]
      first = part.b + 1
      if progress != nil and not progress(doneBefore + part.b - traces.a + 1, total):
        raise newException(JobCancelledError, "cancelled")
  # The first pass: the picker's defaults over each whole trace.
  var picks = newSeq[FirstBreakPick](n)
  var everyRow = newSeq[bool](n)
  for i in 0 ..< n: everyRow[i] = true
  runPass(@[(FirstBreakParams(), everyRow)], picks, 0)
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
  result.offsetAbs = newSeq[float64](n)
  for i in 0 ..< n:
    result.offsetAbs[i] = if keys[i].isSeismic and not keys[i].offset.isNaN: abs(keys[i].offset)
                          else: NaN
  for r in dead:
    if r in 0 ..< n: result.offsetAbs[r] = NaN # a killed trace has no bars
  result.picks = picks
  result.source = if not any: bsNone elif surveyed: bsSurvey else: bsFile
  if not any: return
  # one kind of sensor is fitted (a node record's components are not comparable);
  # the others are given the model's time
  let (mask, what) = fitMask(keys, off)
  result.fittedFrom = what
  let offs = result.offsetAbs
  var eligible = newSeq[bool](n)
  var lineKey, pointKey, azimuth = newSeq[float64](n)
  for i in 0 ..< n:
    eligible[i] = mask[i] and not offs[i].isNaN
    (lineKey[i], pointKey[i]) = (keys[i].rcvLine, keys[i].rcvPoint)
    azimuth[i] = NaN
    let (dx, dy) = (keys[i].rcvX - keys[i].srcX, keys[i].rcvY - keys[i].srcY)
    if not (dx.isNaN or dy.isNaN) and (dx != 0 or dy != 0): azimuth[i] = arctan2(dy, dx)
  result.geometry = RuleGeometry(eligible: eligible, lines: stationLines(lineKey, pointKey,
    eligible), azimuth: azimuth)
  let zeros = newSeq[int](n)
  let meta = initChunkMeta(rowsOf(keys, zeros), dt, 0, dead)

  proc trimOf(src: seq[FirstBreakPick]): tuple[tr: Trimmed; fit: ShotFit] =
    ## The model of `src`'s picks that noise picks do not set (`trimmedModel`): processSEG's
    ## fit of the picks still in, whose second segment stays only when it is supported.
    var pm, cf = newSeq[float64](n)
    for i in 0 ..< n:
      pm[i] = src[i].timeMs
      cf[i] = if mask[i]: src[i].confidence else: 0.0
    var last: ShotFit
    let fn = proc (use: openArray[bool]): seq[float64] =
      var fp = src
      for i in 0 ..< n:
        if not use[i]: fp[i].confidence = 0
      var fit: ShotFit
      try:
        fitShot(meta, fp, ShotFitParams(), fit)
      except ValueError:
        return @[]
      if fit.used < 3 or not (fit.v1 > 0 and fit.v1 < Inf): return @[]
      let one = lineFit(offs, pm, use)
      if one.ok:
        let two = fit.v2 > 0 and fit.v2 < Inf and fit.crossover > 0 and fit.crossover < Inf
        var keep = false
        if two:
          var r1, r2: seq[float64]
          var beyond = 0
          for i in 0 ..< n:
            if use[i] and not offs[i].isNaN and not fit.modelMs[i].isNaN:
              r1.add pm[i] - (one.interceptMs + one.msPerUnit * offs[i])
              r2.add pm[i] - fit.modelMs[i]
              if offs[i] > fit.crossover: inc beyond
          keep = keepSecond(beyond, robustSigma(r1), robustSigma(r2))
        if not keep:
          fit.interceptMs = one.interceptMs
          fit.v1 = 1000 / one.msPerUnit
          fit.v2 = NaN
          fit.crossover = Inf
          for i in 0 ..< n:
            if not fit.modelMs[i].isNaN:
              fit.modelMs[i] = one.interceptMs + one.msPerUnit * offs[i]
      last = fit
      fit.modelMs
    result.tr = trimmedModel(offs, pm, cf, fn)
    result.fit = last

  proc guidedBy(m: BreakModel; src: seq[FirstBreakPick]; doneBefore: int):
      seq[FirstBreakPick] =
    ## `src` with each eligible trace picked again within `GuideWindowMs` of the model's time.
    var guides: seq[Guided] = @[]
    for gl in guideLines(m):
      var rows = newSeq[bool](n)
      for i in 0 ..< n:
        rows[i] = eligible[i] and offs[i] > gl.above and offs[i] <= gl.upTo
      guides.add (FirstBreakParams(guideVelocity: gl.velocity, guideT0Ms: gl.t0Ms,
        beforeMs: GuideWindowMs, afterMs: GuideWindowMs), rows)
    result = src
    runPass(guides, result, doneBefore)

  # The second pass: a model from the first pass's picks (without the noise ones), then every
  # trace picked again near it.
  let firstTrim = trimOf(picks)
  var fitted = picks
  var final = firstTrim
  if firstTrim.tr.trusted:
    let again = guidedBy(firstTrim.fit.fitModel, picks, n)
    let secondTrim = trimOf(again)
    if secondTrim.tr.trusted:
      (fitted, final) = (again, secondTrim)
      result.twoPass = true
    else:
      result.passNote = trustNote("The second, guided pass", secondTrim.tr.used,
        "the first-pass picks are shown")
  else:
    result.passNote = trustNote("The first pass", firstTrim.tr.used,
      "no second pass was made: the first-pass picks are shown")
  var shown = fitted
  if guide.given:
    shown = guidedBy(guide, picks, 2 * n)
    result.twoPass = true
  result.picks = fitted
  result.picked = 0
  for i in 0 ..< n:
    result.pickMs[i] = shown[i].timeMs
    result.confidence[i] = shown[i].confidence
    if not shown[i].timeMs.isNaN: inc result.picked
  result.used = final.tr.used
  if final.tr.trusted:
    result.fit = final.fit
    result.hasFit = true
    for i in 0 ..< n:
      result.modelMs[i] = final.fit.modelMs[i]
      if not result.modelMs[i].isNaN: inc result.modelled
    result.setRule()

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
        proc (done, total: int): bool = ctx.progress(done, total), key.off, key.guide)
      found.key = key
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkFirstBreaks, breaks: move found)
