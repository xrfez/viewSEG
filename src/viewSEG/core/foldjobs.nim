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
## so in a sentence. A cancel leaves the sink untouched.
##
## `FoldTracker` is the follower: each frame the window gives it the survey
## and the layer's settings, it starts the job when they changed and keeps
## the results by survey and bin size (a few of them), so a bin size
## chosen again is not counted again; a survey that changed or was cleared
## drops them all. The jobs are `auto`: quiet when they go well.

import std/[math, options, strutils, times]
import parseSEG
import processSEG/qc/fold
import processSEG/stack/binning
import jobs, survey

const
  NoRelations* = "The survey has no relation (X) records: the pre-plot fold counts " &
    "the source and receiver pairs they list."
  NoStations* = "The survey files give no source or receiver with coordinates."
  CachedMaps = 3 ## results kept, by survey and bin size

type
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
  ## Names the survey files as loaded (path, size, time and line naming): what
  ## a fold map depends on, apart from the bin sizes.
  for i in 0 ..< s.layers.len:
    template l: untyped = s.layers[i]
    if l.isSurveyFile:
      result.add l.path & "|" & $l.size & "|" & $l.modified.toUnix & "|" & $l.xRuns & "|" &
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
        res.binAlong = if along.isNaN: 1.0 else: along
        res.binAcross = if across.isNaN: 1.0 else: across
        var (ux, uy) = (0.0, 1.0)
        if res.crosslines > 1:
          let c1 = grid.location(1)
          res.binAlong = hypot(c1.x - c0.x, c1.y - c0.y)
          (ux, uy) = ((c1.x - c0.x) / res.binAlong, (c1.y - c0.y) / res.binAlong)
        if res.inlines > 1:
          let c1 = grid.location(res.crosslines)
          res.binAcross = hypot(c1.x - c0.x, c1.y - c0.y)
          if res.crosslines <= 1: # the inline axis is the crossline axis turned clockwise
            let (vx, vy) = ((c1.x - c0.x) / res.binAcross, (c1.y - c0.y) / res.binAcross)
            (ux, uy) = (-vy, vx)
        res.azimuthDeg = radToDeg(arctan2(ux, uy))
        res.counts = m.fold.toFlatSeq
        for v in res.counts: res.maxFold = max(res.maxFold, v)
        (res.binned, res.outside, res.noCoordinates) = (m.binned, m.outside, m.noCoordinates)
        res.ok = true
      except JobCancelledError:
        raise
      except ValueError as e:
        res = FoldResult(kind: fkPreplot, reason: sentence(e.msg))
    sink.result = move res

# ----------------------------------------------------------------- follower --

proc retire(t: var FoldTracker; jobs: Jobs) =
  ## Cancels the running job. Its relations stay held until it has ended
  ## (it may be reading them still).
  if t.job != NoJob:
    discard jobs.cancel(t.job)
    if not t.hold.isNil: t.retired.add (t.job, t.hold)
  t.job = NoJob
  t.sink = nil
  t.hold = nil

proc release(t: var FoldTracker; jobs: Jobs) =
  var kept: seq[tuple[job: JobId, hold: ref SurveyGeometry]]
  for (job, hold) in t.retired:
    let info = jobs.info(job)
    if info.isSome and info.get.state in {jsQueued, jsRunning}: kept.add (job, hold)
  t.retired = kept

proc show(t: var FoldTracker; r: ref FoldResult) =
  t.shown = r
  inc t.revision

proc remember(t: var FoldTracker; key: string; r: ref FoldResult) =
  t.cache.add (key, r)
  if t.cache.len > CachedMaps: t.cache.delete(0)

proc dropAll(t: var FoldTracker; jobs: Jobs) =
  t.retire(jobs)
  t.cache.setLen 0
  t.cacheSig = ""
  if not t.shown.isNil:
    t.show(nil)

proc poll(t: var FoldTracker; jobs: Jobs; wantKey: string) =
  ## Takes the job's result once it ended.
  if t.job == NoJob: return
  let info = jobs.info(t.job)
  if info.isNone: # forgotten: nothing to wait for
    t.job = NoJob
  else:
    let state = info.get.state
    if state in {jsDone, jsFailed, jsCancelled}:
      let key = t.jobKey
      t.job = NoJob
      t.hold = nil
      if state == jsDone and not t.sink.isNil:
        let r = new FoldResult
        r[] = move t.sink.result
        if r.ok: t.remember(key, r)
        if key == wantKey:
          if r.ok:
            t.status = fmReady
            t.show(r)
          else:
            (t.status, t.reason) = (fmFailed, r.reason)
      elif state == jsFailed and key == wantKey:
        (t.status, t.reason) = (fmFailed, "The fold could not be counted: " & info.get.error & ".")
      t.sink = nil

proc follow*(t: var FoldTracker; jobs: Jobs; s: Survey; on: bool; along, across: float64) =
  ## Called each frame: takes a finished job's result, and starts a job when
  ## the layer was turned on, or the survey or a bin size changed. `along` and
  ## `across` are NaN for the natural bin. Cheap while nothing changed.
  let now = (s.revision, on, along, across)
  let changed = not t.seenSet or t.seen.survey != now[0] or t.seen.on != on or
    binText(t.seen.along) != binText(along) or binText(t.seen.across) != binText(across)
  t.seen = (s.revision, on, along, across)
  t.seenSet = true
  if t.retired.len > 0: t.release(jobs)
  if not changed:
    if t.status == fmComputing: t.poll(jobs, t.jobKey)
  else:
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
        let inp = foldInputs(s, along, across)
        t.sink = FoldSink()
        t.hold = inp.relations
        t.jobKey = key
        t.job = jobs.submit(foldSpec(), foldWork(inp, t.sink))
        t.status = fmComputing
        t.reason = ""
        if not t.shown.isNil: t.show(nil)
  if t.status == fmComputing and t.job != NoJob: t.poll(jobs, t.jobKey)
