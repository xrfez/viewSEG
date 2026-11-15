## The spread planned for a shot, for the map's template box: the receivers
## the relation records (SPS X) plan for a field record, or, for a receiver
## gather, the shots its O records plan for that receiver; where they are,
## and the box round them.
##
## **Where the plan comes from.** The first loaded survey file with
## relation records of the domain (`SurveyLayer.relations`: X for shots, O
## for receiver gathers). Without one, relation records made on a job
## (`spreadWork`, kept in `Spreads`): with no X records loaded at all, X
## records generated from the user's template (`TemplateSpec`: a patch of
## lines × channels, or a distance box) over the survey's R stations for
## each of its S stations, with processSEG's `generateRelations`, and O
## records made from them with parseSEG's `receiverRelations`; with X
## records but no O records, O records made from the X records, so a
## receiver gather's planned shots are known. What was made is said in
## plain words (`Spreads.words`), and a spread from records made, not read,
## says so (`PlannedSpread.generated`).
##
## **The record** (`xRecordOf`) is found as processSEG's
## `recordCompleteness` finds it: the source station's X record (the one
## numbered as the FFID when it has several), else the X record numbered as
## the FFID. A receiver gather's O record is its receiver station's. A
## source under the pointer has its station's X record (the first, when it
## was shot again).
##
## **The box** (`boxOf`) is the smallest rectangle round the planned
## stations' places with its sides along and across their lines (the
## direction of the run with most places: a receiver line for a shot, a
## source line for a receiver gather), so a patch on a survey turned off
## north is not drawn larger than it is. Stations no loaded survey file
## places are counted (`PlannedSpread.unplaced`), not drawn.

import std/[math, sets, strutils, times]
import parseSEG
import processSEG/survey/patch
import inbox, jobs, mapkinds, mapview, survey, surveyjobs, threads

export RelationDomain, StationKey

type
  SpreadNeed* = enum
    ## What relation records the map needs made.
    snGenerate = "generate"
      ## no X records loaded: X records generated from the template, O from them
    snReceivers = "receivers"
      ## X records loaded but no O records: O records made from the X records

  SpreadInputs* = object
    ## What relation records are made from.
    files*: seq[tuple[path: string; size: int64; modified: Time]]
      ## the survey files read, as they were loaded
    spec*: TemplateSpec
    needs*: set[SpreadNeed]

  Spreads* = object
    ## The relation records made for the map's planned spreads (none while
    ## the loaded survey files have what is needed).
    job*: JobId = NoJob ## the job making them; `NoJob` for none
    inputs*: SpreadInputs ## what the job, or the records held, were made from
    relations*: ref SurveyGeometry ## the records made; nil for none
    words*: seq[string] ## what was made, or why not, in plain words
    revision*: int ## bumped when `relations` or `words` change
    replaced*: seq[JobId] ## jobs cancelled for newer inputs: they end quietly

  SpreadBox* = object
    ## A rectangle on the map.
    corners*: array[4, MapPoint] ## in order round it
    shown*: bool                 ## false: no planned station has a place

  PlannedSpread* = object
    ## The spread planned for one shot (or, for a receiver gather, the shots
    ## planned for one receiver).
    domain*: RelationDomain ## rdSource: a shot's receivers; rdReceiver: a receiver's shots
    record*: int64 = -1 ## the X record (O gather); -1 when none was found
    fixed*: StationKey ## its source (receiver)
    stations*: int ## the stations planned
    places*: seq[MapPoint] ## where those a loaded survey file places are
    unplaced*: int ## planned stations no loaded survey file places
    generated*: bool ## from relation records made, not read
    source*: string ## the relation file's name; "" for records made
    box*: SpreadBox

func wholeNumber(x: float64): bool {.inline.} = abs(x) < 9e18 and x == round(x)

func hasRecord(g: SurveyGeometry; record: int64; domain: RelationDomain): bool =
  for _ in g.relationRuns(record, domain): return true
  false

func xRecordOf*(g: SurveyGeometry; ffid: float64; source: StationKey;
    hasSource: bool): int64 =
  ## The X record of a field record whose headers give FFID `ffid` (NaN: none)
  ## and, with `hasSource`, source station `source`, as processSEG's
  ## `recordCompleteness` finds it by default: the source station's X record,
  ## the one numbered as the FFID when it has several (none when no FFID
  ## chooses); else, when the station has none, the X record numbered as the
  ## FFID. -1 for none.
  result = -1
  var candidates: seq[int64]
  if hasSource:
    candidates = g.recordsAt(source)
    if candidates.len == 1: return candidates[0]
    if wholeNumber(ffid) and int64(ffid) in candidates: return int64(ffid)
  if candidates.len == 0 and wholeNumber(ffid) and g.hasRecord(int64(ffid), rdSource):
    result = int64(ffid)

proc firstRecord(g: SurveyGeometry; station: StationKey; domain: RelationDomain): int64 =
  ## The first record of `domain` at `station` (a source shot again has
  ## several); -1 for none.
  let r = g.recordsAt(station, domain)
  if r.len > 0: r[0] else: -1

func stationKeyOf*(s: Station): StationKey {.inline.} =
  ## Station `s` as parseSEG keys it.
  stationKey(s.line, s.point, s.index)

func plannedRole*(domain: RelationDomain): PointRole {.inline.} =
  ## The role of the stations a record of `domain` plans: a shot's
  ## receivers, a receiver gather's sources.
  if domain == rdSource: prReceiver else: prSource

func hasDomain(l: SurveyLayer; domain: RelationDomain): bool {.inline.} =
  l.origin == loSurveyFile and (if domain == rdSource: l.xRuns > 0
    else: l.relationRuns > l.xRuns)

func listedLayer*(s: Survey; domain: RelationDomain): int =
  ## The index of the first loaded survey file with relation records of
  ## `domain`; -1 for none.
  for i in 0 ..< s.layers.len: # by index: `for l in` copies every layer
    if s.layers[i].hasDomain(domain): return i
  -1

func placeOf(s: Survey; role: PointRole; st: StationKey): MapPoint =
  ## Where a loaded survey file places station `st` of `role`; NaN for none.
  let station = Station(line: st.line, point: st.point, index: st.index)
  for i in 0 ..< s.layers.len:
    if s.layers[i].origin == loSurveyFile:
      let p = s.layers[i].stationPoint(role, station)
      if p >= 0:
        template ix: untyped = s.layers[i].points[role].index
        return mapPoint(ix.x(p), ix.y(p))
  mapPoint(NaN, NaN)

const SamePlace* = 0.5
  ## how near (survey units) a trace's own position must be to a survey
  ## file's point to take its station, when the headers name none

func stationNear*(s: Survey; role: PointRole; x, y: float64): tuple[found: bool; st: StationKey] =
  ## The station of the loaded survey files' point of `role` at (`x`, `y`)
  ## (within `SamePlace`): a trace whose headers give coordinates but no
  ## station (a SEG-Y file without a header layout naming them) is at that
  ## station. Not found when none is there, or its station is not known.
  for i in 0 ..< s.layers.len:
    template l: untyped = s.layers[i]
    if l.origin == loSurveyFile:
      let q = l.points[role].index.nearest(x, y, SamePlace)
      if q >= 0 and l.points[role].station[q].known:
        return (true, stationKeyOf(l.points[role].station[q]))
  (false, StationKey())

func boxOf*(places: openArray[MapPoint]; along: MapPoint): SpreadBox =
  ## The smallest rectangle round `places` with its sides along direction
  ## `along` and across it (east and north when `along` is no direction).
  if places.len == 0: return
  let n = hypot(along.x, along.y)
  let u = if n > 0 and n < Inf: mapPoint(along.x / n, along.y / n) else: mapPoint(1, 0)
  let v = mapPoint(-u.y, u.x)
  let o = places[0]
  var (aLo, aHi, cLo, cHi) = (Inf, -Inf, Inf, -Inf)
  for p in places:
    let (dx, dy) = (p.x - o.x, p.y - o.y)
    let (a, c) = (dx * u.x + dy * u.y, dx * v.x + dy * v.y)
    (aLo, aHi, cLo, cHi) = (min(aLo, a), max(aHi, a), min(cLo, c), max(cHi, c))
  func at(a, c: float64): MapPoint = mapPoint(o.x + a * u.x + c * v.x, o.y + a * u.y + c * v.y)
  SpreadBox(corners: [at(aLo, cLo), at(aHi, cLo), at(aHi, cHi), at(aLo, cHi)], shown: true)

proc spreadOf*(s: Survey; g: SurveyGeometry; record: int64; domain: RelationDomain): PlannedSpread =
  ## The spread record `record` of `g` plans in `domain`: its stations,
  ## their places in the loaded survey files and the box round them.
  result = PlannedSpread(domain: domain, record: record)
  let role = plannedRole(domain)
  var seen: HashSet[StationKey]
  var best = (count: 0, first: mapPoint(NaN, NaN), last: mapPoint(NaN, NaN))
  for run in g.relationRuns(record, domain):
    result.fixed = run.fixed
    var placed = (count: 0, first: mapPoint(NaN, NaN), last: mapPoint(NaN, NaN))
    for i in 0 ..< run.stations:
      let st = run.station(i)
      if not seen.containsOrIncl(st):
        inc result.stations
        let p = s.placeOf(role, st)
        if p.x.isNaN: inc result.unplaced
        else:
          result.places.add p
          if placed.count == 0: placed.first = p
          placed.last = p
          inc placed.count
    if placed.count > best.count: best = placed
  let along = if best.count >= 2: mapPoint(best.last.x - best.first.x, best.last.y - best.first.y)
              else: mapPoint(0, 0)
  result.box = boxOf(result.places, along)

proc plannedSpread*(s: Survey; made: Spreads; domain: RelationDomain; ffid: float64;
    fixed: StationKey; hasFixed: bool): PlannedSpread =
  ## The spread planned for a field record whose headers give FFID `ffid`
  ## and (with `hasFixed`) source station `fixed` (`rdSource`), or for the
  ## receiver gather of receiver station `fixed` (`rdReceiver`; `ffid` NaN):
  ## from the first loaded survey file with relation records of `domain`,
  ## else from the records made (`made`). `record` is -1 when none plans it.
  result = PlannedSpread(domain: domain, fixed: fixed)
  let i = s.listedLayer(domain)
  if i >= 0:
    template g: untyped = s.layers[i].relations[]
    let record = if domain == rdSource: g.xRecordOf(ffid, fixed, hasFixed)
                 elif hasFixed: g.firstRecord(fixed, domain)
                 else: -1'i64
    if record >= 0:
      result = s.spreadOf(g, record, domain)
      result.source = s.layers[i].name
  elif not made.relations.isNil and hasFixed:
    let record = made.relations[].firstRecord(fixed, domain)
    if record >= 0:
      result = s.spreadOf(made.relations[], record, domain)
      result.generated = true

func describe*(t: TemplateSpec; units: string): string =
  ## "a patch of 8 lines × 120 stations", "a box of ±1500 × ±500 ft".
  func num(x: float64): string =
    if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 1)
  case t.shape
  of tsPatch: "a patch of " & $t.lines & (if t.lines == 1: " line" else: " lines") & " × " &
    $t.channels & (if t.channels == 1: " station" else: " stations")
  of tsBox: "a box of ±" & num(t.inlineHalf) & " along the receiver lines × ±" &
    num(t.crosslineHalf) & " across" & (if units.len > 0: " " & units else: "")

func patchOf(t: TemplateSpec): PatchTemplate =
  case t.shape
  of tsPatch: initPatchTemplate(t.lines, t.channels)
  of tsBox: initDistancePatch(t.inlineHalf, t.crosslineHalf)

proc spreadWork*(paths: seq[string]; spec: TemplateSpec; needs: set[SpreadNeed];
    to: Poster): JobWork =
  ## The work of a job that makes the relation records the map's planned
  ## spreads need (`needs`) from the survey files `paths` (read again,
  ## quietly): X records generated from template `spec` for every source
  ## station, and O records made from them (`snGenerate`); or O records made
  ## from the files' X records (`snReceivers`). Posts them with what was made
  ## in plain words (`mkSpreads`); a template that cannot be laid over the
  ## receivers (too few lines to measure, a template larger than any
  ## survey) posts no records and says why.
  result = proc (ctx: JobContext) {.gcsafe.} =
    var made: ref SurveyGeometry
    var words: seq[string]
    {.cast(gcsafe).}:
      var g = readGeometry(paths, ctx, to)
      ctx.checkCancelled()
      var m = new SurveyGeometry
      m[] = initSurveyGeometry()
      try:
        if snGenerate in needs:
          ctx.setPhase "generating the planned spreads"
          let shots = g.patchShots()
          if shots.len == 0:
            words.add "No spread can be generated: the survey files give no source stations."
          else:
            let xs = g.generateRelations(g.receiverLayout(), shots, patchOf(spec))
            if xs.len == 0:
              words.add "No spread was generated: the template takes no receiver for any " &
                "of the " & $shots.len & " sources (the R file's stations need coordinates)."
            else:
              m[].addSps(SpsFile(relations: xs), rdSource)
              var records = 0
              for _ in m[].records(rdSource): inc records
              words.add "Generated from the template (" & describe(spec, "") & ") for " &
                $records & " of " & $shots.len & " sources: no relation file is loaded."
              ctx.setPhase "making the receivers' planned shots"
              m[].addSps(SpsFile(relations: m[].receiverRelations()), rdReceiver)
              made = m
        elif snReceivers in needs:
          ctx.setPhase "making the receivers' planned shots"
          m[].addSps(SpsFile(relations: g.receiverRelations()), rdReceiver)
          words.add "The receivers' planned shots are made from the X records (no O " &
            "records are loaded)."
          made = m
      except ValueError as e:
        words.add "No spread can be generated from the template: " & e.msg & "."
    discard ctx.progress(1, 1)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkSpreads, spreads: move made, spreadWords: move words)
