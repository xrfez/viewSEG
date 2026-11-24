## The first-break job as it was before it was made faster, kept for the tests that say the
## faster job gives the same answer: the record read and picked a chunk at a time on one
## thread, whole traces filtered. The trimmed model is processSEG's `qc/breakfit`, the same
## call the job makes. Not used by the program.

import std/[algorithm, math, sequtils]
import parseSEG
import processSEG/core/[rows, types, workspace]
import processSEG/filter/[design, iir]
import processSEG/qc/[firstbreak, shotfit]
import processSEG/stack/stack
import viewSEG/core/[breakmodel, breakrule, filesystem, firstbreakjobs, firstbreaks, jobs]

const
  BreakChunkReference = 512
  BendSigmaShare = 1.1

func trustNoteReference(what: string; used: int; then: string): string =
  ## Why a pass gave no model to trust, in words.
  if used < MinTrimmedPicks:
    what & " left too few confident picks that hold together (" & $used & ", at least " &
      $MinTrimmedPicks & " are needed): " & then
  else: what & " gave picks no model could be fitted to (they share one offset): " & then

func onSearchEdge(col: int; offset, t0Ms, dt: float64; n, firstSample, liveA, liveB: int;
    pr: FirstBreakParams): bool =
  ## Whether `col` is the first or last sample of the picker's guided search window, as
  ## `stretchOf` cuts it (`qc/firstbreak`). An unguided window, or none, is not an edge.
  if col < 0 or pr.guideVelocity.isNaN or offset.isNaN or not (dt > 0) or n < 2:
    return false
  var tLo = if pr.searchStartMs.isNaN: -Inf else: pr.searchStartMs
  var tHi = if pr.searchEndMs.isNaN: Inf else: pr.searchEndMs
  let tl = pr.guideT0Ms + 1000 * abs(offset) / pr.guideVelocity
  tLo = max(tLo, tl - pr.beforeMs)
  tHi = min(tHi, tl + pr.afterMs)
  let origin = t0Ms + float64(firstSample) * dt
  if origin.classify in {fcInf, fcNegInf, fcNan}: return false
  let cLo = (tLo - origin) / dt
  let cHi = (tHi - origin) / dt
  let lo = max(liveA, if cLo <= 0: 0 elif cLo >= float64(n): n else: int(ceil(cLo)))
  let hi = min(liveB + 1, if cHi < 0: 0 elif cHi >= float64(n - 1): n
    else: int(floor(cHi)) + 1)
  lo < hi and (col == lo or col == hi - 1)

proc hasNonFiniteReference(samples: Tensor[float32]; row, count: int): bool =
  ## Whether one of the first `count` samples of `row` is NaN or infinite.
  for c in 0 ..< min(count, samples.shape[1]):
    let v = samples[row, c]
    if not (v == v and abs(v) < Inf): return true

proc smoothedCopyReference(samples: Tensor[float32]; meta: ChunkMeta; plan: IirPlan[float32];
    ws: var Workspace): Tensor[float32] =
  ## A copy of the chunk `samples` with each live row of `meta` filtered by `plan` (zero phase,
  ## whole rows); `samples` is not changed. `ws` must hold `plan.workspaceSize`.
  result = samples.clone()
  plan.applyFilter(result, meta, ws)

proc breaksOfRecordReference*(file: ptr SeismicFile; path: string; traces: Slice[int];
    killed: openArray[int]; progress: BreakProgress = nil;
    off: openArray[uint8] = []; guide: BreakModel = BreakModel();
    pick: PickBasis = pbSmoothed): FirstBreaks =
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
  ## - `pick` says what the guided passes read (`pickedOn`, `highCutHz` and `pickNote` of the
  ##   result say what they did): smoothing is skipped, and said, when the interval leaves
  ##   the cut under `PickMinCutHz` or the longest trace is no longer than twice the filter's
  ##   margin. The filter runs on whole traces (each to its live length) of a copy of each chunk.
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
  # the smoothing of the guided passes: a plan, or why there is none
  var smoothing: IirPlan[float32]
  var smoothed = false
  var cutHz = 0.0
  if pick == pbSmoothed:
    let cut = pickCutHz(dt)
    if cut == 0:
      result.pickNote = "The picks are made on the samples as recorded: the sample interval (" &
        $dt & " ms) leaves less than " & $int(PickMinCutHz) & " Hz for a high cut."
    else:
      try:
        smoothing = initIirPlan(float32, butterHighCut(cut, PickHighCutSlope), dt, cols, ipZero)
        if cols > 2 * smoothing.requiredMargin:
          (smoothed, cutHz) = (true, cut)
        else:
          result.pickNote = "The picks are made on the samples as recorded: the traces (" &
            $cols & " samples) are too short for the high cut's margin (" &
            $smoothing.requiredMargin & " samples on each side)."
      except ValueError as e:
        result.pickNote = "The picks are made on the samples as recorded: " & e.msg
  let passes = if guide.given: 3 else: 2
  let total = n * passes
  type Guided = tuple[params: FirstBreakParams; rows: seq[bool]]
  proc runPass(guides: seq[Guided]; dst: var seq[FirstBreakPick]; doneBefore: int;
      smooth, dropEdges: bool) =
    ## Picks the rows each guide names with its parameters into `dst` (the others stay), the
    ## record read a chunk at a time; with `smooth`, on a zero-phase high-cut copy of the chunk.
    var plans: seq[FirstBreakPlan[float32]] = @[]
    var ws = initWorkspace()
    if smooth: ws.reserve(smoothing.workspaceSize)
    for g in guides:
      plans.add initFirstBreakPlan(float32, g.params, dt, cols)
      ws.reserve(plans[^1])
    var first = traces.a
    while first <= traces.b:
      let part = first .. min(traces.b, first + BreakChunkReference - 1)
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
      var picked = samples # what the picker reads: the chunk, or a smoothed copy of it
      if smooth:
        var skipSmooth = failed
        for r in 0 ..< part.len:
          var wanted = false
          for g in guides:
            if g.rows[part.a - traces.a + r]: wanted = true
          # a non-finite sample would turn the whole filtered trace to NaN (the filter runs
          # forward and backward): such a trace is picked as recorded
          if not wanted or samples.hasNonFiniteReference(r, counts[r]): skipSmooth.add r
        skipSmooth.sort()
        skipSmooth = deduplicate(skipSmooth, isSorted = true)
        picked = smoothedCopyReference(samples, initChunkMeta(rowsOf(chunkKeys, counts), dt, 0,
          skipSmooth), smoothing, ws)
      for gi in 0 ..< plans.len:
        var skip = failed
        for r in 0 ..< part.len:
          if not guides[gi].rows[part.a - traces.a + r]: skip.add r
        skip.sort()
        skip = deduplicate(skip, isSorted = true)
        let meta = initChunkMeta(rowsOf(chunkKeys, counts), dt, 0, skip)
        var got = newSeq[FirstBreakPick](part.len)
        plans[gi].pickInto(picked, meta, got, ws)
        let pickedRows = rowBlock(picked)
        let guided = dropEdges and not guides[gi].params.guideVelocity.isNaN
        for r in 0 ..< part.len:
          let row = part.a - traces.a + r
          if guides[gi].rows[row]:
            var pick = got[r]
            if guided and pick.col >= 0:
              let nSamp = meta.liveSamples(r, pickedRows.cols)
              if nSamp >= 2:
                let src = pickedRows.rowPtr(r)
                let live = liveSpan(src.toOpenArray(0, nSamp - 1))
                if live.len >= 2 and onSearchEdge(pick.col, chunkKeys[r].offset,
                    chunkKeys[r].t0Ms, dt, nSamp, meta.firstSample, live.a, live.b,
                    guides[gi].params):
                  pick = noPick()
            dst[row] = pick
      first = part.b + 1
      if progress != nil and not progress(doneBefore + part.b - traces.a + 1, total):
        raise newException(JobCancelledError, "cancelled")
  # The first pass: the picker's defaults over each whole trace.
  var picks = newSeq[FirstBreakPick](n)
  var everyRow = newSeq[bool](n)
  for i in 0 ..< n: everyRow[i] = true
  runPass(@[(FirstBreakParams(windowMs: FirstPassWindowMs), everyRow)], picks, 0, false,
    false)
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
          let (s1, s2) = (robustSigma(r1), robustSigma(r2))
          keep = keepSecond(beyond, s1, s2)
          if not keep and beyond >= MinSecondPicks and not (s1.isNaN or s2.isNaN):
            # the support over ALL confident picks, not only those kept: when most picks lie on
            # the second segment, the trimming starts there, and the few bent picks it lets back
            # do not move the kept set's sigma, while the confident picks the two segments hold
            # show the bend
            let (cut1, cut2) = (max(TrimFloorMs, TrimSigmas * s1), max(TrimFloorMs,
              TrimSigmas * s2))
            var sup1, sup2 = 0
            for i in 0 ..< n:
              if cf[i] >= ConfidentPick and not pm[i].isNaN and not offs[i].isNaN and
                  not fit.modelMs[i].isNaN:
                if abs(pm[i] - (one.interceptMs + one.msPerUnit * offs[i])) <= cut1: inc sup1
                if abs(pm[i] - fit.modelMs[i]) <= cut2: inc sup2
            keep = sup2 >= sup1 + MinSecondPicks and s2 <= BendSigmaShare * s1
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

  proc guidedBy(m: BreakModel; src: seq[FirstBreakPick]; doneBefore: int;
      halfMs: float64; dropEdges: bool): seq[FirstBreakPick] =
    ## `src` with each eligible trace picked again within `halfMs` of the model's time.
    ## With `dropEdges`, a pick on the first or last sample of that window is not a pick.
    var guides: seq[Guided] = @[]
    for gl in guideLines(m):
      var rows = newSeq[bool](n)
      for i in 0 ..< n:
        rows[i] = eligible[i] and offs[i] > gl.above and offs[i] <= gl.upTo
      guides.add (FirstBreakParams(guideVelocity: gl.velocity, guideT0Ms: gl.t0Ms,
        windowMs: GuidedWindowMs, beforeMs: halfMs, afterMs: halfMs), rows)
    result = src
    runPass(guides, result, doneBefore, smoothed, dropEdges)

  # The second pass: a model from the first pass's picks (without the noise ones), then every
  # trace picked again near it. The half-window follows that fit's scatter.
  let firstTrim = trimOf(picks)
  let firstW = guideWindowMs(firstTrim.tr.sigmaMs)
  var fitted = picks
  var final = firstTrim
  if firstTrim.tr.trusted:
    let again = guidedBy(firstTrim.fit.fitModel, picks, n, firstW, false)
    let secondTrim = trimOf(again)
    if secondTrim.tr.trusted:
      (fitted, final) = (again, secondTrim)
      result.twoPass = true
    else:
      result.passNote = trustNoteReference("The second, guided pass", secondTrim.tr.used,
        "the first-pass picks are shown")
  else:
    result.passNote = trustNoteReference("The first pass", firstTrim.tr.used,
      "no second pass was made: the first-pass picks are shown")
  var shown = fitted
  # a given model guides a third pass; its window is the scatter of the fit in use
  var shownW = firstW
  if guide.given:
    shownW = guideWindowMs(final.tr.sigmaMs)
    shown = guidedBy(guide, picks, 2 * n, shownW, true)
    result.twoPass = true
  if result.twoPass: # the picks shown are the guided passes'
    result.pickWindowMs = GuidedWindowMs
    if smoothed: (result.pickedOn, result.highCutHz) = (pbSmoothed, cutHz)
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
    # where a break is expected: out to where few traces have a confident pick near the model
    # (or a confident first-pass pick just outside that window: a stretch the fit misses does
    # not end the range), and not past most of the picks both passes agree on. A guided pick
    # alone may be noise the window held
    result.geometry.guideWindowMs = firstW
    let cut = max(TrimFloorMs, TrimSigmas * (if final.tr.sigmaMs.isNaN: 0.0
      else: final.tr.sigmaMs))
    let earliest = final.fit.interceptMs - LimitFloorMs
    var seenNear, supported = newSeq[bool](n)
    for i in 0 ..< n:
      let m = final.fit.modelMs[i]
      let guidedNear = fitted[i].confidence >= ConfidentPick and
        abs(fitted[i].timeMs - m) <= firstW
      let firstD = abs(picks[i].timeMs - m)
      let firstFar = picks[i].confidence >= ConfidentPick and not picks[i].timeMs.isNaN and
        firstD > firstW and firstD <= FarOffMaxMs and
        (final.fit.interceptMs.isNaN or picks[i].timeMs >= earliest)
      seenNear[i] = guidedNear or firstFar
      supported[i] = final.tr.kept[i] and picks[i].confidence >= ConfidentPick and
        abs(picks[i].timeMs - m) <= cut
    result.geometry.rangeMax = expectedRange(offs, eligible, seenNear, supported)
    result.geometry.offsetAbs = offs
    result.geometry.firstMs = newSeq[float64](n)
    result.geometry.firstConf = newSeq[float64](n)
    for i in 0 ..< n:
      result.geometry.firstMs[i] = picks[i].timeMs
      result.geometry.firstConf[i] = picks[i].confidence
    # the picks' own scatter about the record's fit, and how many it compares within the range:
    # the rule's limits, and a given model's match, are measured against these
    var fp, fc = newSeq[float64](n)
    for i in 0 ..< n: (fp[i], fc[i]) = (fitted[i].timeMs, fitted[i].confidence)
    let own = applyRule(fp, fc, final.fit.modelMs, result.geometry)
    result.geometry.ownSigmaMs = own.misfitSigmaMs
    result.geometry.ownComparable = own.nComparable
    result.geometry.guideWindowMs = shownW
    result.setRule()

