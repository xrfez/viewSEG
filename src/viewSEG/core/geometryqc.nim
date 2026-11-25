## The geometry check of the record shown, for the map's filter "header position disagrees
## with the survey" (`mfPositionOff`): the file's own header receiver and source positions
## (read from the file on disk, not the keys in memory, which a join or a station move may have
## replaced) against the positions in force: the survey's station the keys name, or the station
## move that applies to that receiver. Every format. And whether a file's offsets and coordinates
## are lengths of one unit, for the trace table's computed columns (`geometryUnits`).
##
## What it compares, and when it cannot:
## - Not judged with no survey joined (or the project's), or where the coordinates are angles,
##   or when the file's own headers could not be read.
## - A record whose header positions are the survey's times 3.2808 or 0.3048 (feet against
##   metres) is not judged, with that said: most of its stations so, or every one of a record
##   too small for a share to mean anything (`PatternLeast`).
## - A record whose stations mostly sit one distance and bearing from the survey's is judged,
##   and the common shift said, with the stations further off than that shift counted apart.
## - A receiver farther than the tolerance (`GeometryAsk.tolerance`) marks its traces; a source
##   marks its station, never the receivers' traces.

import std/[algorithm, math, options, strutils, tables]
import parseSEG
import join, mapkinds, stationmoves, survey

type
  GeometryUnits* = object
    ## Whether a record's offsets and coordinates can be compared.
    judged*: bool     ## they are lengths of one unit
    angles*: bool     ## the coordinates are angles, not lengths
    unit*: SurveyUnit ## that unit, when a header names it
    why*: string      ## when not judged: the reason, in a sentence

  GeometryAsk* = object
    ## What the geometry check of a record is given.
    units*: GeometryUnits
    survey*: ptr SurveyGeometry
      ## the stations the file was joined with; nil when no survey is joined
    projectSurvey*: bool
      ## `survey` is the project's, and this file is not joined to it
    own*: bool
      ## the file's own header positions are wanted (the job reads them)
    unit*: SurveyUnit ## the survey's unit: the header positions' and the tolerance's
    tolerance*: float64
      ## how far a header position may be from its position in force, in `unit`
      ## (`positionTolerance`)
    moves*: StationMoves
      ## the project's station moves: a receiver's position in force where one applies

  OwnHeader* = object
    ## A trace's positions as the file on disk gives them (not the keys in memory, which a join
    ## or a station move may have replaced): what the geometry check compares.
    rcvX*, rcvY*, srcX*, srcY*: float64

  OwnHeaders* = object
    ## What a record's own headers give, read once while the file is open
    ## (`core/filejobs`' `ownRowsOf`), a row per trace of the record.
    rows*: seq[OwnHeader]
      ## the file's own positions; empty: not read (`why` says why)
    why*: string
      ## why `rows` could not be read; "" when read or not asked
    vendors*: int ## the vendor maps' load (`AppState.vendorGen`) `rows` were read with

  GeometrySummary* = object
    ## What the geometry check found in the record shown.
    ready*: bool
    positionWhy*: string
      ## why the header positions are not judged; "" when they are
    traces*: int                    ## the live seismic traces looked at
    span*: Slice[int] = 0 .. -1     ## the record's traces (indices in the file)
    positionUnit*: SurveyUnit       ## the survey's unit, the header positions'
    tolerance*: float64             ## the position tolerance used, in `positionUnit`
    positionsJudged*: int           ## traces whose header position was compared
    notInSurvey*: int
      ## traces whose header gives a position but whose station the survey does not have
    receiversOff*, sourcesOff*: int ## the distinct stations off
    positionOff*: int               ## traces marked: their receiver is off
    movedAgree*: int
      ## stations a station move brought to their header position (the survey's is off)
    projectSurvey*: bool            ## compared with the project's survey, not joined
    shift*: tuple[stations: int; dx, dy: float64]
      ## the shift most stations share, when it is more than the tolerance (0 stations: none)
    furtherOff*: int
      ## with a shift: the stations off by more than it (beyond the tolerance of it), marked
      ## with the rest
    furtherTraces*: seq[int]
      ## the survey-wide ids of the traces of those receivers (a part of the filter's traces)
    sourceWords*: seq[string] ## the sources off, in words
    positionDistance*: seq[float64]
      ## per trace of the record: its header receiver position's distance from the position
      ## in force (NaN when not compared)

const
  Geographic* = {suDegrees, suArcSeconds, suDms}
    ## coordinate units that are angles, not lengths
  DefaultMetres* = 5.0
    ## the position tolerance unless set, in metres (and any unit not feet)
  DefaultFeet* = 16.0
    ## the same, in feet
  PatternShare = 0.8
    ## stations in a record that share one scale (a unit) or one shift: more than this share
  PatternLeast* = 5
    ## fewest stations for a share; a smaller record is taken for a unit only when every one of
    ## its stations is scaled
  FeetPerMetre = 3.28084
  MaxSourcesSaid = 3 ## sources off said by name; the rest counted
  NoSurveyWhy* = "no survey is imported" ## why the header positions are not judged, without one

func isFoot(u: SurveyUnit): bool {.inline.} = u in {suFeet, suUsFeet}

func positionTolerance*(setting: float64; unit: SurveyUnit): float64 =
  ## The position tolerance in force: `setting` (the map's, in the survey's unit), or with 0
  ## the default: 16 when `unit` is feet, else 5.
  if setting > 0: setting
  elif unit.isFoot: DefaultFeet
  else: DefaultMetres

func geometryUnits*(coordinates, offsets: SurveyUnit): GeometryUnits =
  ## Whether offsets in unit `offsets` and coordinates in unit `coordinates` (each as the
  ## headers or the import say it, `suNotGiven` when they say nothing) are lengths of one
  ## unit. An unnamed unit is taken as the other's: it cannot be told to differ.
  result = GeometryUnits(judged: true, unit: coordinates)
  if result.unit == suNotGiven: result.unit = offsets
  if coordinates in Geographic:
    result = GeometryUnits(angles: true, unit: coordinates, why: "the coordinates are in " &
      $coordinates & ", not lengths, so they cannot be compared with the offsets")
  elif coordinates != suNotGiven and offsets != suNotGiven and coordinates != offsets and
      not (coordinates.isFoot and offsets.isFoot):
    result = GeometryUnits(unit: coordinates, why: "the offsets are in " & $offsets &
      " and the coordinates in " & $coordinates)

func numberWords(x: float64): string =
  ## `x` as the lines write a length: whole from 10 on, else to one decimal, without ".0".
  if abs(x) >= 10 or x == round(x): $int64(round(x))
  else: formatFloat(x, ffDecimal, 1)

func lengthWords*(x: float64; u: SurveyUnit): string =
  ## A length in the survey's unit, in words: "5 m", "16 ft"; "1 unit", "5 units" when no
  ## unit is named.
  let unit = if u == suNotGiven: (if x == 1: "unit" else: "units") else: u.abbreviation
  numberWords(x) & " " & unit

func bearingWords*(dx, dy: float64): string =
  ## The direction of a shift east `dx` and north `dy` in words: "north", "south-east".
  const words = ["north", "north-east", "east", "south-east", "south", "south-west", "west",
    "north-west"]
  let degrees = arctan2(dx, dy).radToDeg # (clockwise from north)
  words[int(floorMod(round(degrees / 45), 8.0))]

func stationWords(line, point: float64): string =
  ## A station as the lines name it: "1/1001".
  numberWords(line) & "/" & numberWords(point)

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func geometryLines*(g: GeometrySummary): seq[string] =
  ## The lines the filters list shows under the position filter: why it is not judged, what
  ## the header positions share, the sources off, the stations moved and those the survey
  ## lacks; none for nothing to say.
  if not g.ready: return
  if g.positionWhy.len > 0:
    result.add "Header positions not judged: " & g.positionWhy & "."
  else:
    if g.shift.stations > 0:
      var line = plural(g.shift.stations, "station sits", "stations sit") & " about " &
        lengthWords(hypot(g.shift.dx, g.shift.dy), g.positionUnit) & " " &
        bearingWords(g.shift.dx, g.shift.dy) & " of the survey (the same shift for all of " &
        "them: check the survey file or the coordinate frame)"
      if g.furtherOff > 0: line.add "; " & $g.furtherOff & " more " &
        (if g.furtherOff == 1: "is" else: "are") & " further off"
      result.add line & "."
    for words in g.sourceWords: result.add words
    if g.movedAgree > 0:
      result.add plural(g.movedAgree, "station", "stations") & " moved to agree with " &
        "the headers."
    if g.notInSurvey > 0:
      result.add plural(g.notInSurvey, "trace's station is", "traces' stations are") &
        " not in the survey: not judged."
  if g.projectSurvey and g.positionWhy != NoSurveyWhy:
    result.add "Compared with the project's survey: this file is not joined to it."

func usablePosition(x, y: float64): bool {.inline.} =
  abs(x) < Inf and abs(y) < Inf and not (x == 0 and y == 0)

func live(k: TraceKeys): bool {.inline.} = k.isSeismic and k.status in {tsLive, tsUnknown}

type StationFact = object
  ## One station of the record, as its traces' own headers place it.
  role: PointRole
  line, point: float64
  index: int16
  hx, hy: float64    ## its first trace's header position
  fx, fy: float64    ## its position in force
  far: float64       ## the farthest of its traces' header positions from `fx`, `fy`
  surveyFar: float64 ## the same, from the survey's position
  moved: bool        ## a station move gives the position in force

func median(xs: var seq[float64]): float64 =
  xs.sort()
  let n = xs.len
  if n mod 2 == 1: xs[n div 2] else: (xs[n div 2 - 1] + xs[n div 2]) / 2

func unitWhy(facts: openArray[StationFact]): string =
  ## "the header positions look like feet and the survey's like metres" (or the reverse) when
  ## most stations' header positions are the position in force times 3.2808 (0.3048) about
  ## the origin, to 1 %: more than `PatternShare` of them, or, in a record of fewer than
  ## `PatternLeast` stations, every one; "" when not.
  if facts.len == 0: return
  for (factor, words) in [(FeetPerMetre, "feet and the survey's like metres"),
      (0.3048, "metres and the survey's like feet")]:
    var alike = 0
    for f in facts:
      let (sx, sy) = (factor * f.fx, factor * f.fy)
      if hypot(f.hx - sx, f.hy - sy) <= 0.01 * hypot(sx, sy): inc alike
    let scaled = if facts.len >= PatternLeast: alike.float64 > PatternShare * facts.len.float64
                 else: alike == facts.len
    if scaled:
      return "the header positions look like " & words & " (" & $alike & " of " &
        $facts.len & (if facts.len == 1: " station)" else: " stations)")

func commonShift(facts: openArray[StationFact]; tolerance: float64):
    tuple[stations: int; dx, dy: float64] =
  ## The shift most stations' header positions share from their positions in force (each
  ## within `tolerance` of the median shift), when it is more than `tolerance`; 0 stations
  ## when none.
  if facts.len < PatternLeast: return
  var xs, ys = newSeq[float64](facts.len)
  for i, f in facts: (xs[i], ys[i]) = (f.hx - f.fx, f.hy - f.fy)
  let (mx, my) = (median(xs), median(ys))
  if hypot(mx, my) > tolerance:
    var alike = 0
    for f in facts:
      if hypot(f.hx - f.fx - mx, f.hy - f.fy - my) <= tolerance: inc alike
    if alike.float64 > PatternShare * facts.len.float64: result = (alike, mx, my)

proc checkPositions(f: SeismicFile; traces: Slice[int]; base: int; ask: GeometryAsk;
    own: OwnHeaders; hits: var array[MapFilter, FilterHits]; s: var GeometrySummary) =
  ## The file's own header positions of `traces` against their positions in force.
  s.positionDistance = newSeq[float64](traces.len)
  for d in s.positionDistance.mitems: d = NaN
  (s.tolerance, s.positionUnit) = (ask.tolerance, ask.unit)
  s.projectSurvey = ask.projectSurvey
  if ask.units.angles: s.positionWhy = ask.units.why
  elif ask.survey.isNil: s.positionWhy = NoSurveyWhy
  elif own.rows.len != traces.len:
    s.positionWhy = "the file's own headers could not be read (" &
      (if own.why.len > 0: own.why else: "not asked") & ")"
  if s.positionWhy.len > 0: return
  let tol = ask.tolerance
  var facts: seq[StationFact] = @[]
  var at: array[PointRole, Table[StationKey, int]] # a station's index in `facts`
  var receiverOf = newSeq[int](traces.len) # each trace's receiver in `facts`; -1 none
  var compared = 0
  for i in 0 ..< traces.len:
    receiverOf[i] = -1
    let k = f.index.keys[traces.a + i]
    if k.live:
      inc s.traces
      var any, missing = false
      for (role, line, point, index, x, y) in [(prReceiver, k.rcvLine, k.rcvPoint, k.rcvIndex,
          own.rows[i].rcvX, own.rows[i].rcvY), (prSource, k.srcLine, k.srcPoint, k.srcIndex,
          own.rows[i].srcX, own.rows[i].srcY)]:
        var c: Coordinates
        let table = if role == prSource: addr ask.survey[].table.sources
                    else: addr ask.survey[].table.receivers
        if usablePosition(x, y):
          if table[].stationAt(line, point, index, c) and usablePosition(c.x, c.y):
            any = true
            var (fx, fy, moved) = (c.x, c.y, false)
            if role == prReceiver:
              let m = ask.moves.movedPosition(StationKey(line: line, point: point,
                index: index), k.time)
              if m.isSome: (fx, fy, moved) = (m.get.x, m.get.y, true)
            let d = hypot(x - fx, y - fy)
            let st = stationKey(line, point, max(index, 0'i16))
            var j = at[role].getOrDefault(st, -1)
            if j < 0:
              j = facts.len
              at[role][st] = j
              facts.add StationFact(role: role, line: line, point: point, index: index,
                hx: x, hy: y, fx: fx, fy: fy, moved: moved)
            facts[j].far = max(facts[j].far, d)
            facts[j].surveyFar = max(facts[j].surveyFar, hypot(x - c.x, y - c.y))
            if role == prReceiver:
              s.positionDistance[i] = d
              receiverOf[i] = j
          else: missing = true
      if any: inc compared
      if missing: inc s.notInSurvey
  s.positionsJudged = compared
  if compared == 0:
    s.positionWhy = "no header position could be compared (the headers hold none, or the " &
      "survey lacks their stations)"
    return
  let units = unitWhy(facts)
  if units.len > 0:
    s.positionWhy = units
    s.positionsJudged = 0
    for d in s.positionDistance.mitems: d = NaN
    return
  s.shift = commonShift(facts, tol)
  # with a shift: the stations off the position in force by more than it, beyond the tolerance
  var further = newSeq[bool](facts.len)
  if s.shift.stations > 0:
    let size = hypot(s.shift.dx, s.shift.dy)
    for j, fact in facts:
      if hypot(fact.hx - fact.fx - s.shift.dx, fact.hy - fact.fy - s.shift.dy) > tol and
          fact.far > size + tol:
        further[j] = true
        inc s.furtherOff
  for fact in facts:
    if fact.far > tol:
      if fact.role == prReceiver: inc s.receiversOff
      else:
        inc s.sourcesOff
        hits[mfPositionOff].sources.add stationKey(fact.line, fact.point, fact.index)
        if s.sourcesOff <= MaxSourcesSaid:
          s.sourceWords.add "The source " & stationWords(fact.line, fact.point) & " is " &
            lengthWords(fact.far, ask.unit) & " from the survey."
    elif fact.moved and fact.surveyFar > tol: inc s.movedAgree
  if s.sourcesOff > MaxSourcesSaid:
    s.sourceWords.add "And " & plural(s.sourcesOff - MaxSourcesSaid, "more source",
      "more sources") & "."
  for i in 0 ..< traces.len:
    if receiverOf[i] >= 0 and s.positionDistance[i] > tol:
      hits[mfPositionOff].traces.add base + traces.a + i
      if further[receiverOf[i]]: s.furtherTraces.add base + traces.a + i
  s.positionOff = hits[mfPositionOff].traces.len

proc checkGeometryOf*(f: SeismicFile; traces: Slice[int]; base: int; ask: GeometryAsk;
    own: OwnHeaders; hits: var array[MapFilter, FilterHits]): GeometrySummary =
  ## Fills the position filter of `hits` from the keys of `traces` of `f` (its trace 0 is
  ## survey-wide `base`) and `own`, what the file's own headers give the traces as far as they
  ## were read, and says what was found. A filter that cannot be judged is `fsNotChecked`,
  ## with the reason.
  result = GeometrySummary(ready: true, span: traces)
  checkPositions(f, traces, base, ask, own, hits, result)
  if result.positionWhy.len > 0:
    (hits[mfPositionOff].state, hits[mfPositionOff].note) = (fsNotChecked, result.positionWhy)
    hits[mfPositionOff].traces.setLen 0
    hits[mfPositionOff].sources.setLen 0
    result.furtherTraces.setLen 0
  else:
    hits[mfPositionOff].state = fsDone
    hits[mfPositionOff].count = hits[mfPositionOff].traces.len
    hits[mfPositionOff].note = "traces whose own header receiver position is more than " &
      lengthWords(ask.tolerance, ask.unit) & " from its position in force (the " &
      (if ask.projectSurvey: "project's survey" else: "survey") & "'s station, or its " &
      "station move): " & plural(result.receiversOff, "receiver", "receivers") & " off; " &
      plural(result.sourcesOff, "source", "sources") & " off (" &
      "marked at the source, not on the traces); the station move menu's \"Move this " &
      "station to the position in this trace's headers\" follows"
