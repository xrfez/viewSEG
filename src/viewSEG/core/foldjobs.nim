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
import jobs, survey

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
    fkPreplot = "pre-plot" ## pairs the X records plan

  FoldResult* = object
    ## A fold map as the map window draws it.
    ok*: bool
    reason*: string                        ## when not `ok`: a sentence for the user
    kind*: FoldKind
    x0*, y0*: float64                      ## the centre of the first bin (inline 0, crossline 0)
    azimuthDeg*: float64                   ## degrees clockwise from north: the crossline axis
    binAlong*, binAcross*: float64
      ## bin sizes along the azimuth (between crosslines) and across it (between inlines)
    firstInline*, firstCrossline*: float64
    inlines*, crosslines*: int
    counts*: seq[int32]                    ## `inlines * crosslines`, bin = inline * crosslines + crossline
    levels*: seq[FoldLevel]
      ## index `log2(factor)`: blocks of the highest fold of `factor x factor` bins, up to one
      ## block; a level wider than `MaxCells` blocks is left out (`factor` 0)
    maxFold*: int32
    binned*, outside*, noCoordinates*: int ## pairs

  FoldSink* = ref object
    ## Filled when the job ends, except when it is cancelled.
    result*: FoldResult

  FoldStations* = object
    stations*: seq[Station]
    xs*, ys*: seq[float64]

  FoldInputs* = object
    key*: string                   ## names the survey files and the bin sizes
    relations*: ref SurveyGeometry ## kept alive by the caller while the job runs
    stations*: array[PointRole, FoldStations]
    binAlong*, binAcross*: float64 ## NaN: the library's natural bin

  FoldStatus* = enum
    fmOff        ## the layer is off
    fmImpossible ## the survey cannot give one: `reason` says why
    fmComputing
    fmReady
    fmFailed     ## the job ended without a map: `reason` says why

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
    jobKey: string
    cache: seq[tuple[key: string, res: ref FoldResult]]
    cacheSig: string
    seen: tuple[survey: int, on: bool, along, across: float64]
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

func foldKey(s: Survey; along, across: float64): string =
  s.surveySignature & "#" & binText(along) & "x" & binText(across)

proc foldInputs*(s: Survey; along, across: float64): FoldInputs =
  ## What the job needs from survey `s`, with bin sizes `along` and `across`
  ## the receiver lines (NaN: natural). Needs `foldReason(s) == ""`.
  result = FoldInputs(key: foldKey(s, along, across), binAlong: along, binAcross: across)
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

func foldSpec*(): JobSpec =
  ## The job that counts the fold: background, started by the program.
  JobSpec(title: "Count the pre-plot fold for the map", lane: jlBackground, auto: true)

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

func halved(src: openArray[int32]; cols, rows: int): seq[int32] =
  ## The highest fold of each block of 2 x 2 of the `rows x cols` values `src`.
  let (c2, r2) = ((cols + 1) div 2, (rows + 1) div 2)
  result = newSeq[int32](c2 * r2)
  for i in 0 ..< rows:
    let row = (i div 2) * c2
    for j in 0 ..< cols:
      let at = row + j div 2
      result[at] = max(result[at], src[i * cols + j])

proc makeLevels(r: FoldResult; ctx: JobContext): seq[FoldLevel] =
  ## The levels of `r` (see `FoldResult.levels`): each is the highest fold of
  ## the blocks of the one before, so the cost is a little over the count's.
  let lut = lutOf(cmViridis)
  var (cols, rows, factor) = (r.crosslines, r.inlines, 1)
  var peak: seq[int32] = @[]
  while true:
    ctx.checkCancelled()
    var l = FoldLevel()
    if cols <= MaxCells and rows <= MaxCells:
      l = FoldLevel(factor: factor, cols: cols, rows: rows, colours: newSeq[uint32](cols * rows))
      if factor == 1:
        for k in 0 ..< r.counts.len: l.colours[k] = lut.foldColour(r.counts[k], r.maxFold)
      else:
        for k in 0 ..< peak.len: l.colours[k] = lut.foldColour(peak[k], r.maxFold)
    result.add move l
    if cols == 1 and rows == 1: break
    peak = if factor == 1: halved(r.counts, cols, rows) else: halved(peak, cols, rows)
    (cols, rows, factor) = ((cols + 1) div 2, (rows + 1) div 2, factor * 2)

func bytes*(r: FoldResult): int =
  ## About how much memory the counts and levels of `r` take.
  result = r.counts.len * 4
  for l in r.levels: result += l.colours.len * 4

proc foldWork*(inp: FoldInputs; sink: FoldSink): JobWork =
  ## The work of a job that counts the fold of `inp` into `sink`
  ## (`foldSpec` is the spec to submit it with). Worker-only. A cancel
  ## raises `JobCancelledError` and leaves `sink` as it was.
  let rel = if inp.relations.isNil: nil else: addr inp.relations[]
  let stations = inp.stations
  let (along, across) = (inp.binAlong, inp.binAcross)
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var res = FoldResult(kind: fkPreplot, firstInline: 1, firstCrossline: 1)
    {.cast(gcsafe).}:
      try:
        if rel == nil:
          raise newException(ValueError, NoRelations)
        ctx.setPhase "gathering the stations"
        var g = rel[]
        for r in PointRole:
          for k, st in stations[r].stations:
            if r == prSource:
              g.addSource(st.line, st.point, st.index, stations[r].xs[k], stations[r].ys[k])
            else:
              g.addReceiver(st.line, st.point, st.index, stations[r].xs[k], stations[r].ys[k])
        ctx.checkCancelled()
        ctx.setPhase "laying out the bins"
        let grid = surveyGrid(g, binInline = along, binCrossline = across)
        ctx.checkCancelled()
        ctx.setPhase "counting the pairs"
        var m = g.preplotFold(grid)
        ctx.checkCancelled()
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
        res.counts = m.fold.toFlatSeq
        for v in res.counts: res.maxFold = max(res.maxFold, v)
        ctx.setPhase "preparing the zoom levels"
        res.levels = makeLevels(res, ctx)
        (res.binned, res.outside, res.noCoordinates) = (m.binned, m.outside, m.noCoordinates)
        res.ok = true
      except JobCancelledError:
        raise
      except ValueError as e:
        res = FoldResult(kind: fkPreplot, reason: sentence(e.msg))
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
  ## Takes the result the job left in the sink (`wantKey` is what is wanted now).
  let r = new FoldResult
  r[] = move t.sink.result
  if r.ok: t.remember(key, r)
  if key == wantKey:
    if r.ok:
      t.status = fmReady
      t.show(r)
    else:
      (t.status, t.reason) = (fmFailed, r.reason)

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
      elif state == jsFailed and key == wantKey:
        (t.status, t.reason) = (fmFailed, "The fold could not be counted: " & info.get.error & ".")
      elif state == jsCancelled and key == wantKey: # cancelled from the Jobs window
        (t.status, t.reason) = (fmFailed, Cancelled)
      t.sink = nil

proc follow*(t: var FoldTracker; jobs: Jobs; s: Survey; on: bool; along, across: float64) =
  ## Called each frame: takes a finished job's result, and starts a job when
  ## the layer was turned on, or the survey or a bin size changed. `along` and
  ## `across` are NaN for the natural bin. Cheap while nothing changed.
  let now = (s.revision, on, along, across)
  var changed = not t.seenSet or t.seen.survey != now[0] or t.seen.on != on or
    binText(t.seen.along) != binText(along) or binText(t.seen.across) != binText(across)
  t.seen = (s.revision, on, along, across)
  t.seenSet = true
  if t.retired.len > 0: t.release(jobs)
  if t.pending and t.retired.len == 0: changed = true
  if not changed:
    if t.status == fmComputing: t.poll(jobs, t.jobKey)
  else:
    t.pending = false
    let sig = s.surveySignature
    if sig != t.cacheSig:
      t.dropAll(jobs)
      t.cacheSig = sig
    let reason = if on: s.foldReason else: ""
    if not on:
      t.retire(jobs)
      t.status = fmOff
      t.reason = ""
      if not t.shown.isNil: t.show(nil)
    elif reason.len > 0:
      (t.status, t.reason) = (fmImpossible, reason)
      if not t.shown.isNil: t.show(nil)
    else:
      let key = foldKey(s, along, across)
      var held: ref FoldResult = nil
      for (k, r) in t.cache:
        if k == key: held = r
      if not held.isNil:
        t.retire(jobs)
        t.status = fmReady
        t.reason = ""
        if t.shown != held: t.show(held)
      elif t.job != NoJob and t.jobKey == key:
        t.status = fmComputing
      else:
        t.retire(jobs)
        t.release(jobs)
        if not t.shown.isNil: t.show(nil)
        t.status = fmComputing
        if t.retired.len > 0: # an earlier count still works: wait, so counts do not stack
          (t.pending, t.reason) = (true, Waiting)
        else:
          let inp = foldInputs(s, along, across)
          t.sink = FoldSink()
          t.hold = inp.relations
          t.jobKey = key
          t.job = jobs.submit(foldSpec(), foldWork(inp, t.sink))
          t.reason = ""
  if t.status == fmComputing and t.job != NoJob: t.poll(jobs, t.jobKey)

proc keepForStragglers*(t: FoldTracker) =
  ## A count still working at the quit may read the relations it was given and
  ## write its sink: they stay, to the end of the process, instead of being
  ## released under it (as `AppState`'s own do).
  if not t.hold.isNil: GC_ref(t.hold)
  if not t.sink.isNil: GC_ref(t.sink)
  for (_, hold) in t.retired:
    if not hold.isNil: GC_ref(hold)
