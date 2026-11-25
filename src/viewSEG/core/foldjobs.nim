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
## The recorded fold's cache key names the files (path, size and time), the edits, the join
## options and the station moves as well as the survey and the bin sizes. The survey that places
## the recorded traces by their stations is the one the grid is laid from (`geometryOf`).
##
## Each layer can be restricted to one offset class or one azimuth sector (`FoldSplit`, see
## `core/foldsplit`): the pre-plot count asks the library for that class's or sector's tensor,
## the recorded count takes it from each file's part (a part holds every class's or sector's
## traces, so another class drawn reads no file again), and the difference is of the same class.
## The result keeps the bins' total fold beside (`totals`, `plannedTotals`) for the hover. The
## restriction is part of the result's key and its edges or sector count of the parts' (`partsKey`).
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
## `foldCacheBytes` in all, the oldest dropped first), so a bin size chosen again
## is not counted again; a survey that changed or was cleared drops them all.
## A job that was cancelled keeps what it was given held until its work is back,
## and a new count waits for it, so changes cannot stack up counts. The jobs
## are `auto`: quiet when they go well.
##
## For the recorded fold it also keeps each file's part (`ActualPart`) by the file's id (path,
## size, time and kills), for the grid and join of the newest count, within the same bytes
## (the parts the newest count did not use go first), so a count after a file was added or
## changed, or a kill, reads only those files. The map shown stays (`updating`) until the new
## one is ready unless it cannot be right (another survey, other bins, another folder).
##
## **Threads.** The job shares no `ref` with the UI thread. The follower makes the sink, keeps
## the relations and the parts it lends, and gives the job their addresses (`FoldPins`); it
## keeps them until the job's work is back (`Jobs.workingOn`), also after a cancel, and gives
## them up to the process at the quit (`keepForStragglers`). The parts lent are never changed
## while lent (a new part replaces the `ref` in the table, never the object). The job posts
## the parts it read as plain data in the sink; the follower wraps them in `ref`s on the UI
## thread once the job is done.

import std/[algorithm, math, options, strutils, tables, times]
import parseSEG
import colourmaps, geometry
import processSEG/qc/fold
import processSEG/stack/binning
import foldactual, jobs, survey

export foldsplit

const
  NoRelations* = "The survey has no relation (X) records: the pre-plot fold counts " &
    "the source and receiver pairs they list."
  NoStations* = "The survey files give no source or receiver with coordinates."
  CachedMaps = 3   ## results kept, by survey and bin size
  MaxCells* = 4096 ## the most blocks a level has along either axis (a GPU texture's size)
  Waiting = "Waiting for the earlier count to stop."
  Cancelled* = "The count was cancelled. Turn the layer off and on, or change a bin size, " &
    "to count again."

var foldCacheBytes* = 256 shl 20
  ## The most bytes the results kept and the files' parts may hold together (the newest
  ## result is kept). Set only by tests.

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
    files*, traces*, notLive*, killed*, unplaced*, duplicates*: int
      ## actual and difference only: files read, traces in them, left out as not live and as
      ## killed, and files that gave no position
    skipped*: seq[tuple[path, why: string]] ## files that could not be read
    split*: FoldSplit
      ## the restriction the counts are of (its `pick`: -1 for every class); none: unrestricted
    noClass*: int
      ## actual and difference with a restriction: of `binned`, the traces in no class or sector
    totals*, plannedTotals*: seq[int32]
      ## with one class or sector drawn: the fold of all of them, per bin: the pre-plot's (the
      ## pre-plot layer), the recorded (actual and difference) and the planned (actual and
      ## difference)
    otherSurvey*: bool
      ## actual and difference only: the project's stored survey is another than the map's,
      ## and the map's placed the traces

  FoldSink* = ref object
    ## Filled when the job ends, except when it is cancelled. The job fills it through its
    ## address: whoever submits the work keeps it alive until the work is back.
    result*: FoldResult
    other*: FoldResult
      ## the layer made beside `result` (a count of the recorded fold also gives the
      ## difference, and the other way round); `ok` false when there is none
    fresh*: seq[ActualPart]
      ## the recorded fold and the difference: for each file, its part as the job read it (an
      ## empty part for one it was lent, `FoldInputs.known`)

  FoldStations* = object
    stations*: seq[Station]
    xs*, ys*: seq[float64]

  FoldInputs* = object
    key*: string                   ## names the survey files and the bin sizes
    relations*: ref SurveyGeometry ## kept alive by the caller while the job runs
    stations*: array[PointRole, FoldStations]
    binAlong*, binAcross*: float64 ## NaN: the library's natural bin
    kind*: FoldKind
    split*: FoldSplit
    actual*: ref ActualInputs      ## the files to count, for the recorded fold and the difference
    known*: seq[ptr ActualPart]
      ## for each file of `actual`, its part from an earlier count of the same grid and join
      ## (nil: the file is read): kept alive and unchanged by the caller until the work is back

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
    why*: string      ## then, why not (a sentence for the user)
    waiting*: bool
      ## `why` passes by itself (the folder is being listed): a map of the same scope stays
    stamp*: int       ## changes when `actual` is another build
    split*: FoldSplit ## the class or sector to draw
    scope*: string
      ## names what a recorded fold is of apart from the files' state (the folder listed): a
      ## map of another scope is never shown while a new count runs

  FoldPins = object
    ## What a job's work reads or fills in place, kept on the UI thread until the work is back
    ## (also after a cancel), then let go of there: the job is given addresses only.
    job: JobId = NoJob
    relations: ref SurveyGeometry ## the relation records it reads
    sink: FoldSink ## what it fills
    parts: seq[ref ActualPart] ## per file, the part it was lent; nil where it reads the file

  KeptPart = tuple[id: string, part: ref ActualPart, used: int]
    ## a file's part, the state of the file it is of (`ActualFile.id`), and the count that last
    ## used it

  FoldTracker* = object
    ## Starts, follows and caches the layer's job.
    status*: FoldStatus
    reason*: string
    shown*: ref FoldResult                 ## the map to draw; nil for none
    revision*: int                         ## bumped whenever `shown` changes
    job: JobId = NoJob
    pins: FoldPins                         ## the running job's
    retired: seq[FoldPins]                 ## jobs given up whose work may still run
    jobKey, jobOther: string               ## the keys of the job's two results
    jobScope: string                       ## what its results are of (`FoldWant.scope`)
    jobFiles: seq[tuple[path, id: string]] ## the files it counts
    jobJoin: string                        ## the grid and join of its parts; "" for the pre-plot
    jobCount: int
    cache: seq[tuple[key: string, res: ref FoldResult]]
    wantKey: string                        ## the key of the layer wanted now
    wantScope: string
    wantKind: FoldKind
    shownScope: string                     ## what `shown` is of
    cacheSig: string
    parts: Table[string, KeptPart]
      ## the files' parts by path, one each (of the file's newest state counted), all of the
      ## grid and join `partsFor`
    partsFor: string
    partsBytes: int
    counts: int ## counts of recorded traces started
    seen: tuple[survey: int, on: bool, along, across: float64, kind: FoldKind, stamp: int,
      split: string]
    seenSet: bool
    pending: bool
      ## a count waits: for the retired jobs' work to end, or for the running count of the same
      ## grid and join to end, whose parts it then takes

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

func splitKey(kind: FoldKind; split: FoldSplit): string =
  ## Names the restriction a result is of: the class drawn; for a recorded count also the
  ## edges when every class is drawn (the totals say how many traces are in none).
  if split.drawn or (split.active and kind.isActual): "#" & split.pickId else: ""

func foldKey(s: Survey; along, across: float64; kind = fkPreplot;
    actual: ref ActualInputs = nil; split = FoldSplit()): string =
  ## Names the survey, the bin sizes and the layer; for the recorded fold and the difference
  ## also the files counted (`ActualInputs.key`); and the restriction.
  result = s.surveySignature & "#" & binText(along) & "x" & binText(across)
  if kind != fkPreplot: result.add "#" & $kind & (if actual.isNil: "" else: "#" & actual.key)
  result.add splitKey(kind, split)

proc foldInputs*(s: Survey; along, across: float64; kind = fkPreplot;
    actual: ref ActualInputs = nil; split = FoldSplit()): FoldInputs =
  ## What the job needs from survey `s`, with bin sizes `along` and `across`
  ## the receiver lines (NaN: natural). Needs `foldReason(s) == ""`. `kind` names the
  ## layer; the recorded fold and the difference count `actual`'s files too; `split` is the
  ## restriction.
  result = FoldInputs(key: foldKey(s, along, across, kind, actual, split), binAlong: along,
    binAcross: across, kind: kind, split: split, actual: actual)
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

const
  NoData = low(int32)
    ## a bin of a difference that has neither a plan nor a trace
  ShortInk* = Rgba(r: 215, g: 25, b: 28, a: 255)
    ## short of the plan: the warning red
  MoreInk* = Rgba(r: 33, g: 102, b: 172, a: 255)
    ## more than planned: blue
  AsPlannedInk* = Rgba(r: 190, g: 190, b: 190, a: 255)
    ## as planned: a light neutral grey, seen on the white map
  LeastInk = 0.3
    ## how far the smallest difference is from the grey, towards its end

func mix(a, b: Rgba; t: float64): Rgba =
  func ch(x, y: uint8): uint8 = uint8(round(float64(x) + (float64(y) - float64(x)) * t))
  Rgba(r: ch(a.r, b.r), g: ch(a.g, b.g), b: ch(a.b, b.b), a: 255)

func diffRgba*(f: float64): Rgba =
  ## The colour of a difference that is fraction `f` (-1 to 1) of the largest: 0 is the grey
  ## of `AsPlannedInk`, positive (short of the plan) goes to red, negative (more than planned)
  ## to blue, the smallest step already `LeastInk` of the way.
  if f == 0: AsPlannedInk
  else: mix(AsPlannedInk, (if f > 0: ShortInk else: MoreInk),
    LeastInk + (1 - LeastInk) * min(1.0, abs(f)))

func diffColour*(diff, maxAbs: int32): uint32 =
  ## The packed colour of a bin whose planned fold exceeds the recorded by `diff` (negative:
  ## more was recorded than planned), `maxAbs` the largest magnitude (`diffRgba`). `NoData`
  ## is clear (alpha 0).
  if diff == NoData: return 0
  pack(diffRgba(if maxAbs > 0: float64(diff) / float64(maxAbs) else: 0.0))

func halved*(src: openArray[int32]; cols, rows: int; byMagnitude = false): seq[int32] =
  ## The highest fold of each block of 2 x 2 of the `rows x cols` values `src`; the value
  ## of largest magnitude when `byMagnitude` (`NoData` counts less than any other), the
  ## positive (short of the plan) of two of one magnitude.
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
        let (a, b) = (abs(int64(v)), abs(int64(result[at])))
        if v != NoData and (result[at] == NoData or a > b or (a == b and v > result[at])):
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
  ## keeps the value of the largest magnitude of a block and is coloured with `diffRgba`.
  let diff = r.kind == fkDifference
  let lut = lutOf(cmViridis)
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
        for k in 0 ..< src.len: l.colours[k] = diffColour(src[k], r.maxFold)
      else:
        for k in 0 ..< src.len: l.colours[k] = lut.foldColour(src[k], r.maxFold)
    result.add move l
    if cols == 1 and rows == 1: break
    peak = halved(if factor == 1: base else: peak, cols, rows, diff)
    (cols, rows, factor) = ((cols + 1) div 2, (rows + 1) div 2, factor * 2)

func bytes*(r: FoldResult): int =
  ## About how much memory the counts and levels of `r` take.
  result = (r.counts.len + r.planned.len + r.totals.len + r.plannedTotals.len) * 4
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

proc recorded(base: FoldResult; ctx: JobContext; pre, actual: FoldMap;
    totals, plannedTotals: sink seq[int32]): tuple[actual, difference: FoldResult] =
  ## The recorded fold and the difference (planned less recorded) of `actual` against `pre`,
  ## both over `base`'s grid, with their zoom levels (the totals are the caller's to add);
  ## `totals` and `plannedTotals` are the fold of all classes, when one is drawn.
  var a = base
  a.kind = fkActual
  a.counts = actual.fold.toFlatSeq
  a.planned = pre.fold.toFlatSeq
  a.totals = totals
  a.plannedTotals = plannedTotals
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

const MaxSplitCells = 1 shl 26
  ## the most cells (bins times sectors) the library may count for one sector drawn

func planOptions(split: FoldSplit): FoldOptions =
  ## What the library counts for the pre-plot of `split`: for one offset class drawn, that class
  ## alone (the same rule, one tensor); for one sector drawn, all the sectors.
  if split.drawn and split.kind == spOffset:
    FoldOptions(offsetBounds: @[split.edges[split.pick], split.edges[split.pick + 1]])
  elif split.drawn and split.kind == spAzimuth: FoldOptions(azimuthSectors: split.sectors)
  else: FoldOptions()

proc restrictPlan(m: var FoldMap; split: FoldSplit): seq[int32] =
  ## Makes `m`'s fold that of the class or sector drawn (`planOptions` counted it); returns the
  ## fold of all of them.
  var cells = m.fold # shares the map's storage
  result = cells.toFlatSeq
  var part = if split.kind == spOffset: m.offsetFold else: m.azimuthFold
  let k = if split.kind == spOffset: 0 else: split.pick
  let (src, dest) = (cast[ptr UncheckedArray[int32]](part.unsafe_raw_offset(aligned = false)),
    cast[ptr UncheckedArray[int32]](cells.unsafe_raw_offset(aligned = false)))
  copyMem(dest, addr src[k * result.len], result.len * sizeof(int32))

proc foldWork*(inp: FoldInputs; sink: FoldSink): JobWork =
  ## The work of a job that counts the fold of `inp` into `sink`
  ## (`foldSpec` is the spec to submit it with). Worker-only. The work holds `sink`, the
  ## relations and the parts of `inp.known` by their addresses: the caller keeps them until
  ## the work is back (`Jobs.workingOn`). A cancel raises `JobCancelledError` and leaves
  ## `sink` as it was. For the recorded
  ## fold and the difference the same job counts the pre-plot and the recorded
  ## traces over one grid: `sink.result` is the layer asked for, `sink.other` the
  ## other of the two.
  let rel = if inp.relations.isNil: nil else: addr inp.relations[]
  let stations = inp.stations
  let (along, across) = (inp.binAlong, inp.binAcross)
  let kind = inp.kind
  let split = inp.split
  var files = ActualInputs()
  if not inp.actual.isNil: files = inp.actual[]
  let known = inp.known
  let into = addr sink[] # the job shares no `ref`: the caller keeps the sink
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    var res = FoldResult(kind: kind, firstInline: 1, firstCrossline: 1)
    var other = FoldResult()
    var fresh: seq[ActualPart] = @[]
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
        if split.drawn and split.kind == spAzimuth and grid.len * split.sectors > MaxSplitCells:
          raise newException(ValueError, "These bins and " & $split.sectors & " sectors need " &
            "more memory than a map may take. Give larger bins or fewer sectors.")
        var m = g.preplotFold(grid, planOptions(split))
        var plannedTotals: seq[int32] = @[]
        if split.drawn: plannedTotals = m.restrictPlan(split)
        ctx.checkCancelled()
        res.describe(grid, along, across)
        res.split = split
        if kind.isActual:
          var actual = initFoldMap(grid)
          var totals: seq[int32] = @[]
          let tally = ctx.countActual(addr files, known, addr g, grid, split, actual, totals,
            fresh)
          ctx.checkCancelled()
          var made = res.recorded(ctx, m, actual, totals, plannedTotals)
          for r in [addr made.actual, addr made.difference]:
            (r.files, r.traces, r.notLive, r.killed, r.unplaced, r.skipped) =
              (tally.files, tally.traces, tally.notLive, tally.killed, tally.unplaced,
               tally.skipped)
            r.duplicates = tally.duplicates
            r.noClass = if split.shownKind == spAzimuth: tally.noSector else: tally.noClass
            (r.binned, r.outside, r.noCoordinates) = (tally.binned, tally.outside,
              tally.noCoordinates)
            r.otherSurvey = files.otherSurvey
            r.ok = true
          if tally.files == 0:
            let why = if files.files.len == 0: NoSeismicFiles
              else: "None of the " & plural(files.files.len, "file") & " could be read."
            made.actual = FoldResult(kind: fkActual, reason: why)
            made.difference = FoldResult(kind: fkDifference, reason: why)
          elif tally.unplaced == tally.files or (tally.binned == 0 and tally.outside > 0):
            let why =
              if tally.unplaced < tally.files:
                "Every trace fell outside the grid: the files' coordinates may be in another " &
                  "unit or frame than the survey."
              elif tally.noSource == tally.noCoordinates:
                "None of the " & plural(tally.files, "file") & " gives source positions (a " &
                  "recording of receivers alone, as a continuous one is), so they have no fold."
              else:
                "None of the " & plural(tally.files, "file") & " gives source or receiver " &
                  "positions, and the survey does not place them."
            made.actual = FoldResult(kind: fkActual, reason: why)
            made.difference = FoldResult(kind: fkDifference, reason: why)
          if kind == fkActual: (res, other) = (made.actual, made.difference)
          else: (res, other) = (made.difference, made.actual)
        else:
          res.counts = m.fold.toFlatSeq
          res.totals = plannedTotals
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
    into.fresh = move fresh
    into.other = move other
    into.result = move res

# ----------------------------------------------------------------- follower --

func showing*(t: FoldTracker): bool {.inline.} =
  ## Whether `shown` is drawn: it is ready, or it stays while a new count of the same scope
  ## runs (`updating`).
  not t.shown.isNil and t.status in {fmReady, fmComputing}

func updating*(t: FoldTracker): bool {.inline.} =
  ## Whether the map drawn is the last one counted while a newer count runs.
  not t.shown.isNil and t.status == fmComputing

func foldScope(s: Survey; along, across: float64; folder: string): string =
  ## What a map is of apart from the layer and the files' state: the survey, the bin sizes
  ## and the folder listed.
  s.surveySignature & "#" & binText(along) & "x" & binText(across) & "#" & folder

func bytes(p: ActualPart): int =
  (p.bins.len + p.counts.len + p.classStarts.len + p.classBins.len + p.classCounts.len) * 4 +
    p.skip.len + sizeof(ActualPart)

proc unpin(t: var FoldTracker; jobs: Jobs) =
  ## Lets go of what the job `t.pins` names was given, or keeps it until its work is back (it
  ## may still run, also when the job was listed cancelled for not stopping).
  if t.pins.job != NoJob and jobs.workingOn(t.pins.job): t.retired.add move t.pins
  t.pins = FoldPins()

proc retire(t: var FoldTracker; jobs: Jobs) =
  ## Cancels the running job. What it was given stays held until its work has ended.
  if t.job != NoJob:
    discard jobs.cancel(t.job)
    if t.pins.job != NoJob: t.retired.add move t.pins
  t.job = NoJob
  t.pins = FoldPins()

proc release(t: var FoldTracker; jobs: Jobs) =
  ## Lets go of the retired jobs whose work is back.
  var kept: seq[FoldPins] = @[]
  for p in t.retired.mitems:
    if jobs.workingOn(p.job): kept.add move p
  t.retired = move kept

proc show(t: var FoldTracker; r: ref FoldResult; scope = "") =
  t.shown = r
  t.shownScope = if r.isNil: "" else: scope
  inc t.revision

func keeps(t: FoldTracker; scope: string; kind: FoldKind): bool =
  ## Whether the map shown may stay while a count of `scope` and `kind` runs.
  not t.shown.isNil and t.shownScope == scope and t.shown.kind == kind

proc dropParts(t: var FoldTracker) =
  t.parts.clear()
  t.partsBytes = 0

func bytes(path: string; k: KeptPart): int = k.part[].bytes + path.len + k.id.len

proc keepPart(t: var FoldTracker; path, id: string; part: ref ActualPart; used: int) =
  ## Keeps `part` as file `path`'s, in its state `id`, in place of any other of the file.
  t.parts.withValue(path, was):
    t.partsBytes -= bytes(path, was[])
  t.parts[path] = (id, part, used)
  t.partsBytes += bytes(path, t.parts[path])

proc trim(t: var FoldTracker) =
  ## Keeps the maps and the parts within `foldCacheBytes`: first the parts the newest count did
  ## not use go, the oldest first, then the maps but the newest, then the newest count's parts.
  var total = t.partsBytes
  for (_, kept) in t.cache: total += kept[].bytes
  if total <= foldCacheBytes: return
  var order: seq[tuple[used: int, path: string]] = @[]
  for path, k in t.parts: order.add (k.used, path)
  order.sort()
  var k = 0
  template dropNext() =
    let path = order[k].path
    let b = bytes(path, t.parts[path])
    t.parts.del path
    t.partsBytes -= b
    total -= b
    inc k
  while total > foldCacheBytes and k < order.len and order[k].used < t.counts: dropNext()
  while t.cache.len > 1 and total > foldCacheBytes:
    total -= t.cache[0].res[].bytes
    t.cache.delete(0)
  while total > foldCacheBytes and k < order.len: dropNext()

proc remember(t: var FoldTracker; key: string; r: ref FoldResult) =
  ## Keeps `r`: of the results, at most `CachedMaps`, the oldest dropped first, and within
  ## `foldCacheBytes` with the parts (`trim`).
  t.cache.add (key, r)
  while t.cache.len > CachedMaps: t.cache.delete(0)
  t.trim()

proc dropAll(t: var FoldTracker; jobs: Jobs) =
  t.retire(jobs)
  t.cache.setLen 0
  t.cacheSig = ""
  t.dropParts()
  t.partsFor = ""
  if not t.shown.isNil:
    t.show(nil)

proc takeParts(t: var FoldTracker) =
  ## Keeps the parts of the files the job counted, those it was lent and those it read, for
  ## the next count of the same grid and join. A file it could not read is read again.
  if t.jobJoin.len == 0 or t.jobJoin != t.partsFor: return
  template sink: untyped = t.pins.sink
  for i, (path, id) in t.jobFiles:
    if i < t.pins.parts.len and not t.pins.parts[i].isNil:
      t.keepPart(path, id, t.pins.parts[i], t.jobCount)
    elif i < sink.fresh.len and sink.fresh[i].skip.len == 0:
      let p = new ActualPart
      p[] = move sink.fresh[i]
      t.keepPart(path, id, p, t.jobCount)
  sink.fresh = @[]
  t.trim()

proc take(t: var FoldTracker; key: string) =
  ## Takes the result the job left in the sink, and the one it made beside it. One wanted now
  ## is shown; one of an earlier state of the same files' scope is shown while the next count
  ## runs.
  t.takeParts()
  let r = new FoldResult
  r[] = move t.pins.sink.result
  let o = new FoldResult
  o[] = move t.pins.sink.other
  let otherKey = t.jobOther
  if o.ok and otherKey.len > 0: t.remember(otherKey, o)
  if r.ok: t.remember(key, r)
  var wanted = false
  for (k, x) in [(key, r), (otherKey, o)]:
    if k.len > 0 and k == t.wantKey:
      wanted = true
      if x.ok:
        t.status = fmReady
        t.show(x, t.jobScope)
      else:
        (t.status, t.reason) = (fmFailed, x.reason)
        if not t.shown.isNil: t.show(nil)
  if not wanted and t.jobScope == t.wantScope:
    for x in [r, o]:
      if x.ok and x.kind == t.wantKind and t.shown != x: t.show(x, t.jobScope)

proc poll(t: var FoldTracker; jobs: Jobs) =
  ## Takes the job's result once it ended.
  if t.job == NoJob: return
  let job = t.job
  let info = jobs.info(job)
  let wanted = t.jobKey == t.wantKey or t.jobOther == t.wantKey
  if info.isNone:
    # Forgotten from the history (many jobs came after it): the sink still holds
    # what it made, when it made anything; otherwise the next frame counts again.
    if jobs.workingOn(job): return
    t.job = NoJob
    template sink: untyped = t.pins.sink
    if not sink.isNil and (sink.result.ok or sink.result.reason.len > 0):
      t.take(t.jobKey)
    else:
      t.seenSet = false
    t.unpin(jobs)
  else:
    let state = info.get.state
    if state in {jsDone, jsFailed, jsCancelled}:
      t.job = NoJob
      if state == jsDone and not t.pins.sink.isNil:
        t.take(t.jobKey)
      elif state == jsFailed and wanted:
        (t.status, t.reason) = (fmFailed, "The fold could not be counted: " & info.get.error & ".")
        if not t.shown.isNil: t.show(nil)
      elif state == jsCancelled and (wanted or t.pending):
        # cancelled from the Jobs window (also a count the files changed under: the next one
        # is not started behind the user's back)
        (t.status, t.reason, t.pending) = (fmFailed, Cancelled, false)
        if not t.shown.isNil: t.show(nil)
      t.unpin(jobs)

func partsKey(s: Survey; along, across: float64; actual: ref ActualInputs;
    split: FoldSplit): string =
  ## Names what a file's part depends on besides the file: the grid (the survey and the bin
  ## sizes), the join (`ActualInputs.join`) and the classes or sectors it holds (not which one
  ## is drawn).
  s.surveySignature & "#" & binText(along) & "x" & binText(across) & "#" & actual.join & "#" &
    split.specId

proc start(t: var FoldTracker; jobs: Jobs; s: Survey; want: FoldWant; along, across: float64;
    key, otherKey, scope: string) =
  ## Submits the count of `want`. A recorded fold is lent the parts of the files kept from an
  ## earlier count of the same grid and join, by address, and pins them until its work is back.
  var inp = foldInputs(s, along, across, want.kind, want.actual, want.split)
  t.pins = FoldPins(relations: inp.relations, sink: FoldSink())
  t.jobFiles.setLen 0
  t.jobJoin = ""
  if want.kind.isActual:
    let join = partsKey(s, along, across, want.actual, want.split)
    if join != t.partsFor:
      t.dropParts()
      t.partsFor = join
    inc t.counts
    let n = want.actual.files.len
    inp.known = newSeq[ptr ActualPart](n)
    t.pins.parts = newSeq[ref ActualPart](n)
    for i in 0 ..< n:
      template f: untyped = want.actual.files[i]
      t.jobFiles.add (f.path, f.id)
      t.parts.withValue(f.path, kept):
        if kept.id == f.id:
          kept.used = t.counts
          t.pins.parts[i] = kept.part
          inp.known[i] = addr kept.part[]
    t.jobJoin = join
    t.jobCount = t.counts
  (t.jobKey, t.jobOther, t.jobScope) = (key, otherKey, scope)
  t.job = jobs.submit(foldSpec(want.kind), foldWork(inp, t.pins.sink))
  t.pins.job = t.job
  t.reason = ""

proc follow*(t: var FoldTracker; jobs: Jobs; s: Survey; want: FoldWant; along, across: float64) =
  ## Called each frame: takes a finished job's result, and starts a job when
  ## the layer was turned on or is another one, or the survey, the files counted or a
  ## bin size changed. `along` and `across` are NaN for the natural bin. Cheap while
  ## nothing changed.
  ##
  ## While a folder is being recorded its files change often. The map shown stays, marked
  ## `updating`, until the new count is ready, unless it cannot be right at all (another survey,
  ## other bin sizes, another folder). A count of the same grid and join is let run to its end
  ## when the files change under it (its result is shown meanwhile); the next one then reads
  ## only the files that are new or changed (`ActualFile.id`) and takes the others' parts.
  let on = want.on
  var changed = not t.seenSet or t.seen.survey != s.revision or t.seen.on != on or
    binText(t.seen.along) != binText(along) or binText(t.seen.across) != binText(across) or
    t.seen.kind != want.kind or t.seen.stamp != want.stamp or t.seen.split != want.split.pickId
  t.seen = (s.revision, on, along, across, want.kind, want.stamp, want.split.pickId)
  t.seenSet = true
  if t.retired.len > 0: t.release(jobs)
  if t.pending and t.retired.len == 0 and t.job == NoJob: changed = true
  if not changed:
    if t.status == fmComputing: t.poll(jobs)
  else:
    t.pending = false
    let sig = s.surveySignature
    if sig != t.cacheSig:
      t.dropAll(jobs)
      t.cacheSig = sig
    var reason = if on: s.foldReason else: ""
    var waiting = false
    if on and reason.len == 0 and want.kind.isActual and want.actual.isNil:
      reason = if want.why.len > 0: want.why else: NoSeismicFiles
      waiting = want.waiting
    let scope = foldScope(s, along, across, if want.kind.isActual: want.scope else: "")
    (t.wantScope, t.wantKind) = (scope, want.kind)
    if not on:
      t.retire(jobs)
      t.status = fmOff
      t.reason = ""
      t.wantKey = ""
      if not t.shown.isNil: t.show(nil)
    elif reason.len > 0 and waiting and t.keeps(scope, want.kind):
      # the folder is being listed again: the map stays, and so does a count running
      (t.status, t.reason) = (fmComputing, reason)
      t.wantKey = ""
    elif reason.len > 0:
      t.retire(jobs)
      (t.status, t.reason) = (fmImpossible, reason)
      t.wantKey = ""
      if not t.shown.isNil: t.show(nil)
    else:
      let key = foldKey(s, along, across, want.kind, want.actual, want.split)
      let otherKind = if want.kind == fkActual: fkDifference else: fkActual
      let otherKey = if want.kind.isActual:
          foldKey(s, along, across, otherKind, want.actual, want.split)
        else: ""
      t.wantKey = key
      var held: ref FoldResult = nil
      for (k, r) in t.cache:
        if k == key: held = r
      if not held.isNil:
        t.retire(jobs)
        t.status = fmReady
        t.reason = ""
        if t.shown != held: t.show(held, scope)
      elif t.job != NoJob and (t.jobKey == key or (otherKey.len > 0 and t.jobOther == key)):
        t.status = fmComputing
      elif t.job != NoJob and want.kind.isActual and t.jobJoin.len > 0 and
          t.jobJoin == partsKey(s, along, across, want.actual, want.split) and t.jobScope == scope:
        # the files changed under a count of the same grid and join: it runs to its end, and
        # the next count takes the parts it read
        (t.status, t.reason, t.pending) = (fmComputing, "", true)
        if not t.keeps(scope, want.kind) and not t.shown.isNil: t.show(nil)
      else:
        t.retire(jobs)
        t.release(jobs)
        if not t.keeps(scope, want.kind) and not t.shown.isNil: t.show(nil)
        t.status = fmComputing
        if t.retired.len > 0: # an earlier count still works: wait, so counts do not stack
          (t.pending, t.reason) = (true, Waiting)
        else:
          t.start(jobs, s, want, along, across, key, otherKey, scope)
  if t.status == fmComputing and t.job != NoJob: t.poll(jobs)

proc follow*(t: var FoldTracker; jobs: Jobs; s: Survey; on: bool; along, across: float64) =
  ## `follow` for the pre-plot layer alone.
  t.follow(jobs, s, FoldWant(kind: fkPreplot, on: on), along, across)

func running*(t: FoldTracker): JobId {.inline.} =
  ## The job counting now, `NoJob` for none.
  t.job

func partsKept*(t: FoldTracker): int {.inline.} =
  ## How many files' parts are kept for the next count (for tests).
  t.parts.len

proc keepForStragglers*(t: FoldTracker) =
  ## A count still working at the quit may read what it was given and write its sink: they
  ## stay, to the end of the process, instead of being released under it (as `AppState`'s own
  ## do).
  template keep(p: FoldPins) =
    if p.job != NoJob:
      if not p.relations.isNil: GC_ref(p.relations)
      if not p.sink.isNil: GC_ref(p.sink)
      for part in p.parts:
        if not part.isNil: GC_ref(part)
  keep(t.pins)
  for p in t.retired: keep(p)
