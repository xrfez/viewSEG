## The fold of the imported survey's pre-plot (its X records), counted over
## the bins of a grid laid on its midpoints (processSEG's `surveyGrid` and
## `preplotFold`), on a background job; the map's "Pre-plot fold" layer
## draws it.
##
## `foldInputs` takes what the job needs from the survey on the UI thread:
## every survey file's stations with coordinates (a copy of two arrays a
## role, a few milliseconds for a million points), and the first survey
## file's relation records (`SurveyLayer.relations`, read where they are:
## the caller keeps the `ref` alive until the job ends, as `checkWork` is
## kept). All the survey files' stations are used together, so the S, R
## and X files of one survey may be three files; with several files that
## hold X records the first one's records are counted. The job copies the
## relations, adds the stations, and makes the grid and the fold. It never
## looks at app state.
##
## The same job counts two more layers over the same grid (`foldactual`): the fold of the traces
## recorded in the seismic files the Files window lists (`fkActual`), and the difference, pre-plot
## less recorded (`fkDifference`). One count gives both: `FoldSink.result` is the layer asked for
## and `other` the second, and both are kept, so switching from one to the other starts no job.
## The recorded fold's cache key names the files (path, size and time), the edits, the station
## moves and the project's survey as well as the bin sizes.
##
## The result (`FoldResult`) is plain data: the grid's origin (the first
## bin's centre), its azimuth and bin sizes, the counts `[inlines x
## crosslines]` row-major as processSEG lays them out, and how many pairs
## were binned, fell outside the grid or had no coordinates. `kind` names
## what the counts are, so a map of recorded fold or a difference map can
## be another layer of the same shape. A bin size that asks for more bins
## than the library allows is not a crash: `ok` is false and `reason` says
## so in a sentence. A cancel leaves the sink untouched. The job also makes
## the coarser levels a zoomed-out map draws (`levels`, see `core/foldgrid`),
## so the UI thread only uploads them.
##
## `FoldTracker` is the follower: each frame the window gives it the survey
## and the layer's settings, it starts the job when they changed and keeps
## the results by survey and bin size (at most `CachedMaps` of them and
## `CachedBytes` in all, the oldest dropped first), so a bin size chosen again
## is not counted again; a survey that changed or was cleared drops them all.
## A job that was cancelled keeps its relations held until its work is back,
## and a new count waits for it, so changes cannot stack up counts. The jobs
## are `auto`: quiet when they go well.

import std/[math, options, strutils, times]
import parseSEG
import colourmaps, geometry
import processSEG/qc/fold
import processSEG/stack/binning
import foldactual, jobs, survey

const
  NoRelations* = "The survey has no relation (X) records: the pre-plot fold counts " &
    "the source and receiver pairs they list."
  NoStations* = "The survey files give no source or receiver with coordinates."
  CachedMaps = 3           ## results kept, by survey and bin size
  CachedBytes = 256 shl 20 ## and the most bytes they may hold together (the newest is kept)
  MaxCells* = 4096         ## the most blocks a level has along either axis (a GPU texture's size)
  Waiting = "Waiting for the earlier count to stop."
  Cancelled* = "The count was cancelled. Turn the layer off and on, or change a bin size, " &
    "to count again."

type
  FoldLevel* = object
    ## Blocks of `factor x factor` bins, row-major, `rows x cols` blocks.
    factor*, cols*, rows*: int
    colours*: seq[uint32]
      ## per block, packed as bytes r, g, b, a (little-endian); alpha 0 for no fold

  FoldKind* = enum
    fkPreplot = "pre-plot"      ## pairs the X records plan
    fkActual = "actual"         ## traces recorded in the files the Files window lists
    fkDifference = "difference" ## pre-plot less actual, per bin (positive: short of the plan)

  FoldResult* = object
    ## A fold map as the map window draws it.
    ok*: bool
    reason*: string                         ## when not `ok`: a sentence for the user
    kind*: FoldKind
    x0*, y0*: float64                       ## the centre of the first bin (inline 0, crossline 0)
    azimuthDeg*: float64                    ## degrees clockwise from north: the crossline axis
    binAlong*, binAcross*: float64
      ## bin sizes along the azimuth (between crosslines) and across it (between inlines)
    firstInline*, firstCrossline*: float64
    inlines*, crosslines*: int
    counts*: seq[int32]                     ## `inlines * crosslines`, bin = inline * crosslines + crossline
    levels*: seq[FoldLevel]
      ## index `log2(factor)`: blocks of the highest fold of `factor x factor` bins, up to one
      ## block; a level wider than `MaxCells` blocks is left out (`factor` 0)
    maxFold*: int32
      ## the highest count; for a difference, the largest magnitude (the scale's end)
    binned*, outside*, noCoordinates*: int
      ## pairs (pre-plot), or traces counted, outside the grid and without coordinates
    planned*: seq[int32]
      ## actual and difference only: the pre-plot count of each bin, `counts` is then the
      ## recorded count or planned less recorded
    files*, traces*, notLive*, killed*, unplaced*: int
      ## actual and difference only: files read, traces in them, left out as not live and as
      ## killed, and files that gave no position
    skipped*: seq[tuple[path, why: string]] ## files that could not be read

  FoldSink* = ref object
    ## Filled when the job ends, except when it is cancelled.
    result*: FoldResult
    other*: FoldResult
      ## the layer made beside `result` (a count of the recorded fold also gives the
      ## difference, and the other way round); `ok` false when there is none

  FoldStations* = object
    stations*: seq[Station]
    xs*, ys*: seq[float64]

  FoldInputs* = object
    key*: string                   ## names the survey files and the bin sizes
    relations*: ref SurveyGeometry ## kept alive by the caller while the job runs
    stations*: array[PointRole, FoldStations]
    binAlong*, binAcross*: float64 ## NaN: the library's natural bin
    kind*: FoldKind
    actual*: ref ActualInputs      ## the files to count, for the recorded fold and the difference

  FoldStatus* = enum
    fmOff        ## the layer is off
    fmImpossible ## the survey cannot give one: `reason` says why
    fmComputing
    fmReady
    fmFailed     ## the job ended without a map: `reason` says why

  FoldWant* = object
    ## The layer the map wants this frame, for `follow`.
    kind*: FoldKind
    on*: bool
    actual*: ref ActualInputs
      ## recorded fold and difference: the files to count; nil when they cannot be counted
    why*: string ## then, why not (a sentence for the user)
    stamp*: int  ## changes when `actual` is another build

  FoldTracker* = object
    ## Starts, follows and caches the layer's job.
    status*: FoldStatus
    reason*: string
    shown*: ref FoldResult   ## the map to draw; nil for none
    revision*: int           ## bumped whenever `shown` changes
    job: JobId
    sink: FoldSink
    hold: ref SurveyGeometry ## the relations the job reads
    retired: seq[tuple[job: JobId, hold: ref SurveyGeometry]]
      ## cancelled jobs that may still read theirs
    jobKey, jobOther: string ## the keys of the job's two results
    cache: seq[tuple[key: string, res: ref FoldResult]]
    wantKey: string          ## the key of the layer wanted now
    cacheSig: string
    seen: tuple[survey: int, on: bool, along, across: float64, kind: FoldKind, stamp: int]
    seenSet: bool
    pending: bool            ## a count waits for the retired jobs' work to end

func isSurveyFile(l: SurveyLayer): bool {.inline.} = l.origin == loSurveyFile

func foldReason*(s: Survey): string =
  ## Why the survey cannot give a pre-plot fold; "" when it can.
  var (x, sources, receivers) = (false, false, false)
  for i in 0 ..< s.layers.len:
    template l: untyped = s.layers[i]
    if l.isSurveyFile:
      x = x or l.xRuns > 0
      sources = sources or l.points[prSource].len > 0
      receivers = receivers or l.points[prReceiver].len > 0
  if not x: NoRelations
  elif not (sources and receivers): NoStations
  else: ""

func surveySignature*(s: Survey): string =
  ## Names the survey files as loaded (the layer's id, which a load makes anew,
  ## its path, size and time, and how many stations and X records it read):
  ## what a fold map depends on, apart from the bin sizes. A file read again
  ## is another survey, whatever its names.
  for i in 0 ..< s.layers.len:
    template l: untyped = s.layers[i]
    if l.isSurveyFile:
      result.add $int(l.id) & "|" & l.path & "|" & $l.size & "|" & $l.modified.toUnix & "|" &
          $l.xRuns & "|" &
        $l.points[prSource].len & "|" & $l.points[prReceiver].len & ";"

func binText(v: float64): string = (if v.isNaN: "natural" else: $v)

func isActual(kind: FoldKind): bool {.inline.} = kind in {fkActual, fkDifference}

func foldKey(s: Survey; along, across: float64; kind = fkPreplot;
    actual: ref ActualInputs = nil): string =
  ## Names the survey, the bin sizes and the layer; for the recorded fold and the difference
  ## also the files counted (`ActualInputs.key`).
  result = s.surveySignature & "#" & binText(along) & "x" & binText(across)
  if kind != fkPreplot: result.add "#" & $kind & (if actual.isNil: "" else: "#" & actual.key)

proc foldInputs*(s: Survey; along, across: float64; kind = fkPreplot;
    actual: ref ActualInputs = nil): FoldInputs =
  ## What the job needs from survey `s`, with bin sizes `along` and `across`
  ## the receiver lines (NaN: natural). Needs `foldReason(s) == ""`. `kind` names the
  ## layer; the recorded fold and the difference count `actual`'s files too.
  result = FoldInputs(key: foldKey(s, along, across, kind, actual), binAlong: along,
    binAcross: across, kind: kind, actual: actual)
  for i in 0 ..< s.layers.len:
    template l: untyped = s.layers[i]
    if l.isSurveyFile:
      if result.relations.isNil and l.xRuns > 0: result.relations = l.relations
      for r in PointRole:
        template p: untyped = l.points[r]
        for k in 0 ..< p.len:
          if p.station[k].known:
            result.stations[r].stations.add p.station[k]
            result.stations[r].xs.add p.index.x(k)
            result.stations[r].ys.add p.index.y(k)

func foldSpec*(kind = fkPreplot): JobSpec =
  ## The job that counts the fold: background, started by the program.
  JobSpec(title: if kind.isActual: "Count the recorded fold for the map"
    else: "Count the pre-plot fold for the map", lane: jlBackground, auto: true)

func sentence(msg: string): string =
  ## A library message as a sentence for the user.
  var m = msg
  if m.startsWith("surveyGrid: "): m = m["surveyGrid: ".len .. ^1]
  if "maxBins" in m:
    let cut = m.find(", more than maxBins")
    let detail = if cut >= 0: m[0 ..< cut] else: m
    "These bin sizes make too many bins for a map (the limit is " &
      $(1 shl 26) & "): " & detail & ". Give larger bins."
  else:
    m.strip(chars = {' ', '.'}) & "."

func pack(c: Rgba): uint32 {.inline.} =
  uint32(c.r) or (uint32(c.g) shl 8) or (uint32(c.b) shl 16) or (uint32(c.a) shl 24)

func foldColour*(lut: Lut; fold, maxFold: int32): uint32 =
  ## The packed colour of a bin with `fold` pairs; 0 (clear) for none. Any
  ## other fold is its fraction of `maxFold` in the colour map `lut`.
  if fold <= 0 or maxFold <= 0: return 0
  let t = min(1.0, float64(fold) / float64(maxFold))
  var c = lut[int(round(t * 255))]
  c.a = 255
  pack(c)

const NoData = low(int32) ## a bin of a difference that has neither a plan nor a trace

func diffColour*(lut: Lut; diff, maxAbs: int32): uint32 =
  ## The packed colour of a bin whose planned fold exceeds the recorded by `diff` (negative:
  ## more was recorded than planned), on a diverging colour map `lut` centred on 0: 0 is the
  ## map's neutral entry, `maxAbs` its end on either side. `NoData` is clear (alpha 0).
  if diff == NoData: return 0
  let t = if maxAbs > 0: min(1.0, abs(float64(diff)) / float64(maxAbs)) else: 0.0
  let at = if diff >= 0: ZeroEntry + int(round(t * float64(255 - ZeroEntry)))
           else: ZeroEntry - int(round(t * float64(ZeroEntry)))
  var c = lut[at]
  c.a = 255
  pack(c)

func halved(src: openArray[int32]; cols, rows: int; byMagnitude = false): seq[int32] =
  ## The highest fold of each block of 2 x 2 of the `rows x cols` values `src`; the value
  ## of largest magnitude when `byMagnitude` (`NoData` counts less than any other).
  let (c2, r2) = ((cols + 1) div 2, (rows + 1) div 2)
  result = newSeq[int32](c2 * r2)
  if byMagnitude:
    for v in result.mitems: v = NoData
  for i in 0 ..< rows:
    let row = (i div 2) * c2
    for j in 0 ..< cols:
      let at = row + j div 2
      let v = src[i * cols + j]
      if byMagnitude:
        if v != NoData and (result[at] == NoData or abs(int64(v)) > abs(int64(result[at]))):
          result[at] = v
      else:
        result[at] = max(result[at], v)

func levelOne(r: FoldResult): seq[int32] =
  ## The values the first level is coloured from: the counts, or for a difference the
  ## difference of the bins that have a plan or a trace and `NoData` for the rest.
  if r.kind != fkDifference: return r.counts
  result = newSeq[int32](r.counts.len)
  for k in 0 ..< r.counts.len:
    result[k] = if r.counts[k] == 0 and r.planned[k] == 0: NoData else: r.counts[k]

proc makeLevels(r: FoldResult; ctx: JobContext): seq[FoldLevel] =
  ## The levels of `r` (see `FoldResult.levels`): each is the highest fold of
  ## the blocks of the one before, so the cost is a little over the count's. A difference
  ## keeps the value of the largest magnitude of a block and is coloured with a diverging map.
  let diff = r.kind == fkDifference
  let lut = lutOf(if diff: cmRedWhiteBlue else: cmViridis)
  var (cols, rows, factor) = (r.crosslines, r.inlines, 1)
  var peak: seq[int32] = @[]
  let base = r.levelOne
  while true:
    ctx.checkCancelled()
    var l = FoldLevel()
    if cols <= MaxCells and rows <= MaxCells:
      l = FoldLevel(factor: factor, cols: cols, rows: rows, colours: newSeq[uint32](cols * rows))
      let src = if factor == 1: base else: peak
      if diff:
        for k in 0 ..< src.len: l.colours[k] = lut.diffColour(src[k], r.maxFold)
      else:
        for k in 0 ..< src.len: l.colours[k] = lut.foldColour(src[k], r.maxFold)
    result.add move l
    if cols == 1 and rows == 1: break
    peak = halved(if factor == 1: base else: peak, cols, rows, diff)
    (cols, rows, factor) = ((cols + 1) div 2, (rows + 1) div 2, factor * 2)

func bytes*(r: FoldResult): int =
  ## About how much memory the counts and levels of `r` take.
  result = (r.counts.len + r.planned.len) * 4
  for l in r.levels: result += l.colours.len * 4

func geometryOf(rel: ptr SurveyGeometry; stations: array[PointRole, FoldStations]):
    SurveyGeometry =
  ## The relations and the stations as one geometry.
  result = rel[]
  for r in PointRole:
    for k, st in stations[r].stations:
      if r == prSource:
        result.addSource(st.line, st.point, st.index, stations[r].xs[k], stations[r].ys[k])
      else:
        result.addReceiver(st.line, st.point, st.index, stations[r].xs[k], stations[r].ys[k])

proc describe(res: var FoldResult; grid: Binning; along, across: float64) =
  ## Fills the grid's origin, azimuth and bin sizes and its counts' shape in `res`.
  res.inlines = grid.inlines
  res.crosslines = grid.crosslines
  let c0 = grid.location(0)
  (res.x0, res.y0) = (c0.x, c0.y)
  # The sizes asked for, as typed; the natural ones are measured between bin
  # centres, and an axis of one bin has none to measure (the other axis's size
  # stands in, or 1).
  var (ux, uy) = (0.0, 1.0)
  var (sizeAlong, sizeAcross) = (along, across)
  if res.crosslines > 1:
    let c1 = grid.location(1)
    let d = hypot(c1.x - c0.x, c1.y - c0.y)
    if sizeAlong.isNaN: sizeAlong = d
    (ux, uy) = ((c1.x - c0.x) / d, (c1.y - c0.y) / d)
  if res.inlines > 1:
    let c1 = grid.location(res.crosslines)
    let d = hypot(c1.x - c0.x, c1.y - c0.y)
    if sizeAcross.isNaN: sizeAcross = d
    if res.crosslines <= 1: # the inline axis is the crossline axis turned clockwise
      let (vx, vy) = ((c1.x - c0.x) / d, (c1.y - c0.y) / d)
      (ux, uy) = (-vy, vx)
  if sizeAlong.isNaN: sizeAlong = if sizeAcross.isNaN: 1.0 else: sizeAcross
  if sizeAcross.isNaN: sizeAcross = sizeAlong
  (res.binAlong, res.binAcross) = (sizeAlong, sizeAcross)
  res.azimuthDeg = radToDeg(arctan2(ux, uy))

func plural(n: int; word: string): string = $n & " " & word & (if n == 1: "" else: "s")

proc recorded(base: FoldResult; ctx: JobContext; pre, actual: FoldMap):
    tuple[actual, difference: FoldResult] =
  ## The recorded fold and the difference (planned less recorded) of `actual` against `pre`,
  ## both over `base`'s grid, with their zoom levels (the totals are the caller's to add).
  var a = base
  a.kind = fkActual
  a.counts = actual.fold.toFlatSeq
  a.planned = pre.fold.toFlatSeq
  for v in a.counts: a.maxFold = max(a.maxFold, v)
  var d = a
  d.kind = fkDifference
  d.counts = foldDifference(pre, actual).toFlatSeq
  d.maxFold = 0
  for v in d.counts: d.maxFold = max(d.maxFold, abs(v))
  ctx.setPhase "preparing the zoom levels"
  a.levels = makeLevels(a, ctx)
  d.levels = makeLevels(d, ctx)
  (result.actual, result.difference) = (a, d)

proc foldWork*(inp: FoldInputs; sink: FoldSink): JobWork =
  ## The work of a job that counts the fold of `inp` into `sink`
  ## (`foldSpec` is the spec to submit it with). Worker-only. A cancel
  ## raises `JobCancelledError` and leaves `sink` as it was. For the recorded
  ## fold and the difference the same job counts the pre-plot and the recorded
  ## traces over one grid: `sink.result` is the layer asked for, `sink.other` the
  ## other of the two.
  let rel = if inp.relations.isNil: nil else: addr inp.relations[]
  let stations = inp.stations
  let (along, across) = (inp.binAlong, inp.binAcross)
  let kind = inp.kind
  var files = ActualInputs()
  if not inp.actual.isNil: files = inp.actual[]
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var res = FoldResult(kind: kind, firstInline: 1, firstCrossline: 1)
    var other = FoldResult()
    {.cast(gcsafe).}:
      try:
        if rel == nil:
          raise newException(ValueError, NoRelations)
        ctx.setPhase "gathering the stations"
        let g = geometryOf(rel, stations)
        ctx.checkCancelled()
        ctx.setPhase "laying out the bins"
        let grid = surveyGrid(g, binInline = along, binCrossline = across)
        ctx.checkCancelled()
        ctx.setPhase "counting the pairs"
        var m = g.preplotFold(grid)
        ctx.checkCancelled()
        res.describe(grid, along, across)
        if kind.isActual:
          var actual = initFoldMap(grid)
          let tally = ctx.countActual(addr files, grid, actual)
          ctx.checkCancelled()
          var made = res.recorded(ctx, m, actual)
          for r in [addr made.actual, addr made.difference]:
            (r.files, r.traces, r.notLive, r.killed, r.unplaced, r.skipped) =
              (tally.files, tally.traces, tally.notLive, tally.killed, tally.unplaced,
               tally.skipped)
            (r.binned, r.outside, r.noCoordinates) = (tally.binned, tally.outside,
              tally.noCoordinates)
            r.ok = true
          if tally.files == 0:
            let why = if files.files.len == 0: NoSeismicFiles
              else: "None of the " & plural(files.files.len, "file") & " could be read."
            made.actual = FoldResult(kind: fkActual, reason: why)
            made.difference = FoldResult(kind: fkDifference, reason: why)
          elif tally.unplaced == tally.files:
            let why = "None of the " & plural(tally.files, "file") & " gives source or " &
              "receiver positions, and the survey does not place them."
            made.actual = FoldResult(kind: fkActual, reason: why)
            made.difference = FoldResult(kind: fkDifference, reason: why)
          if kind == fkActual: (res, other) = (made.actual, made.difference)
          else: (res, other) = (made.difference, made.actual)
        else:
          res.counts = m.fold.toFlatSeq
          for v in res.counts: res.maxFold = max(res.maxFold, v)
          ctx.setPhase "preparing the zoom levels"
          res.levels = makeLevels(res, ctx)
          (res.binned, res.outside, res.noCoordinates) = (m.binned, m.outside, m.noCoordinates)
          res.ok = true
      except JobCancelledError:
        raise
      except ValueError as e:
        res = FoldResult(kind: kind, reason: sentence(e.msg))
        other = if kind.isActual: FoldResult(kind: if kind == fkActual: fkDifference else: fkActual,
          reason: res.reason) else: FoldResult()
    sink.other = move other
    sink.result = move res

# ----------------------------------------------------------------- follower --

proc keepHeld(t: var FoldTracker; jobs: Jobs; job: JobId) =
  ## Keeps the relations `t.hold` until the work of `job` is back (it may be
  ## reading them still, also when the job was listed cancelled for not stopping).
  if job != NoJob and not t.hold.isNil and jobs.workingOn(job): t.retired.add (job, t.hold)
  t.hold = nil

proc retire(t: var FoldTracker; jobs: Jobs) =
  ## Cancels the running job. Its relations stay held until its work has ended.
  if t.job != NoJob:
    discard jobs.cancel(t.job)
    if not t.hold.isNil: t.retired.add (t.job, t.hold)
  t.job = NoJob
  t.sink = nil
  t.hold = nil

proc release(t: var FoldTracker; jobs: Jobs) =
  var kept: seq[tuple[job: JobId, hold: ref SurveyGeometry]]
  for (job, hold) in t.retired:
    if jobs.workingOn(job): kept.add (job, hold)
  t.retired = kept

proc show(t: var FoldTracker; r: ref FoldResult) =
  t.shown = r
  inc t.revision

proc remember(t: var FoldTracker; key: string; r: ref FoldResult) =
  ## Keeps `r`: of the results, at most `CachedMaps` and `CachedBytes`, the oldest dropped first.
  t.cache.add (key, r)
  var total = 0
  for (_, kept) in t.cache: total += kept[].bytes
  while t.cache.len > 1 and (t.cache.len > CachedMaps or total > CachedBytes):
    total -= t.cache[0].res[].bytes
    t.cache.delete(0)

proc dropAll(t: var FoldTracker; jobs: Jobs) =
  t.retire(jobs)
  t.cache.setLen 0
  t.cacheSig = ""
  if not t.shown.isNil:
    t.show(nil)

proc take(t: var FoldTracker; key, wantKey: string) =
  ## Takes the result the job left in the sink (`wantKey` is what is wanted now), and the
  ## one it made beside it.
  let r = new FoldResult
  r[] = move t.sink.result
  let o = new FoldResult
  o[] = move t.sink.other
  let otherKey = t.jobOther
  if o.ok and otherKey.len > 0: t.remember(otherKey, o)
  if r.ok: t.remember(key, r)
  for (k, x) in [(key, r), (otherKey, o)]:
    if k.len > 0 and k == wantKey:
      if x.ok:
        t.status = fmReady
        t.show(x)
      else:
        (t.status, t.reason) = (fmFailed, x.reason)

proc poll(t: var FoldTracker; jobs: Jobs; wantKey: string) =
  ## Takes the job's result once it ended.
  if t.job == NoJob: return
  let job = t.job
  let info = jobs.info(job)
  if info.isNone:
    # Forgotten from the history (many jobs came after it): the sink still holds
    # what it made, when it made anything; otherwise the next frame counts again.
    if jobs.workingOn(job): return
    let key = t.jobKey
    t.job = NoJob
    t.keepHeld(jobs, job)
    if not t.sink.isNil and (t.sink.result.ok or t.sink.result.reason.len > 0):
      t.take(key, wantKey)
    else:
      t.seenSet = false
    t.sink = nil
  else:
    let state = info.get.state
    if state in {jsDone, jsFailed, jsCancelled}:
      let key = t.jobKey
      t.job = NoJob
      t.keepHeld(jobs, job)
      if state == jsDone and not t.sink.isNil:
        t.take(key, wantKey)
      elif state == jsFailed and (key == wantKey or t.jobOther == wantKey):
        (t.status, t.reason) = (fmFailed, "The fold could not be counted: " & info.get.error & ".")
      elif state == jsCancelled and (key == wantKey or t.jobOther == wantKey):
        # cancelled from the Jobs window
        (t.status, t.reason) = (fmFailed, Cancelled)
      t.sink = nil

proc follow*(t: var FoldTracker; jobs: Jobs; s: Survey; want: FoldWant; along, across: float64) =
  ## Called each frame: takes a finished job's result, and starts a job when
  ## the layer was turned on or is another one, or the survey, the files counted or a
  ## bin size changed. `along` and `across` are NaN for the natural bin. Cheap while
  ## nothing changed.
  let on = want.on
  var changed = not t.seenSet or t.seen.survey != s.revision or t.seen.on != on or
    binText(t.seen.along) != binText(along) or binText(t.seen.across) != binText(across) or
    t.seen.kind != want.kind or t.seen.stamp != want.stamp
  t.seen = (s.revision, on, along, across, want.kind, want.stamp)
  t.seenSet = true
  if t.retired.len > 0: t.release(jobs)
  if t.pending and t.retired.len == 0: changed = true
  if not changed:
    if t.status == fmComputing: t.poll(jobs, t.wantKey)
  else:
    t.pending = false
    let sig = s.surveySignature
    if sig != t.cacheSig:
      t.dropAll(jobs)
      t.cacheSig = sig
    var reason = if on: s.foldReason else: ""
    if on and reason.len == 0 and want.kind.isActual and want.actual.isNil:
      reason = if want.why.len > 0: want.why else: NoSeismicFiles
    if not on:
      t.retire(jobs)
      t.status = fmOff
      t.reason = ""
      if not t.shown.isNil: t.show(nil)
    elif reason.len > 0:
      (t.status, t.reason) = (fmImpossible, reason)
      if not t.shown.isNil: t.show(nil)
    else:
      let key = foldKey(s, along, across, want.kind, want.actual)
      let otherKind = if want.kind == fkActual: fkDifference else: fkActual
      let otherKey = if want.kind.isActual: foldKey(s, along, across, otherKind, want.actual)
        else: ""
      t.wantKey = key
      var held: ref FoldResult = nil
      for (k, r) in t.cache:
        if k == key: held = r
      if not held.isNil:
        t.retire(jobs)
        t.status = fmReady
        t.reason = ""
        if t.shown != held: t.show(held)
      elif t.job != NoJob and (t.jobKey == key or (otherKey.len > 0 and t.jobOther == key)):
        t.status = fmComputing
      else:
        t.retire(jobs)
        t.release(jobs)
        if not t.shown.isNil: t.show(nil)
        t.status = fmComputing
        if t.retired.len > 0: # an earlier count still works: wait, so counts do not stack
          (t.pending, t.reason) = (true, Waiting)
        else:
          let inp = foldInputs(s, along, across, want.kind, want.actual)
          t.sink = FoldSink()
          t.hold = inp.relations
          t.jobKey = key
          t.jobOther = otherKey
          t.job = jobs.submit(foldSpec(want.kind), foldWork(inp, t.sink))
          t.reason = ""
  if t.status == fmComputing and t.job != NoJob: t.poll(jobs, t.wantKey)

proc follow*(t: var FoldTracker; jobs: Jobs; s: Survey; on: bool; along, across: float64) =
  ## `follow` for the pre-plot layer alone.
  t.follow(jobs, s, FoldWant(kind: fkPreplot, on: on), along, across)

func running*(t: FoldTracker): JobId {.inline.} =
  ## The job counting now, `NoJob` for none: the window holds what it reads (the project's
  ## survey) until that job ends.
  t.job

proc keepForStragglers*(t: FoldTracker) =
  ## A count still working at the quit may read the relations it was given and
  ## write its sink: they stay, to the end of the process, instead of being
  ## released under it (as `AppState`'s own do).
  if not t.hold.isNil: GC_ref(t.hold)
  if not t.sink.isNil: GC_ref(t.sink)
  for (_, hold) in t.retired:
    if not hold.isNil: GC_ref(hold)
