## The geometry checks of the record shown, for the map's filters (`mfOffsetOff`,
## `mfMidpointOff`, `mfPositionOff`) and the trace table's computed columns: processSEG's
## `qc/geometry` on the trace keys (no sample is read), and the file's own header positions
## against the survey's.
##
## What each compares, and when it cannot:
## - **Offset** and **midpoint**: the header's against the positions in force. Only SEG-Y
##   headers hold an offset: a SEG-D or SEG-2 file's offsets are computed from the positions
##   when it is read, so they cannot disagree, and are not judged. After a join that replaced
##   the coordinates, or a station move, the keys' offsets are computed too: the file's own
##   headers are read again (`core/filejobs`' `ownKeysOf`) and compared with the positions in
##   force; when they cannot be read, the record is not judged.
## - **Header position** against the survey: the file's own header receiver and source
##   position against the position the survey gives the station the keys name. Every format.
##   Not judged with no survey joined, where the coordinates are angles, or where every
##   position differs (the units or the frame differ: it would flag every trace).
##
## A trace without an offset, or whose positions are unknown, cannot be compared: they are
## counted in one line (`geometryLines`), never marked. The comparison of an offset is of two
## lengths, so a record whose coordinates are angles, or whose offsets and coordinates are in
## different units, is not judged (`geometryUnits`, and offsets that are all about 3.28 or 0.3048
## times the distance).

import std/[math, strutils, tables]
import parseSEG
import processSEG/core/types
import processSEG/qc/geometry
import join, mapkinds, survey

export geometry.GeometryQc

type
  GeometryUnits* = object
    ## Whether a record's offsets and coordinates can be compared.
    judged*: bool     ## they are lengths of one unit
    angles*: bool     ## the coordinates are angles, not lengths
    unit*: SurveyUnit ## that unit, when a header names it
    why*: string      ## when not judged: the reason, in a sentence

  GeometryAsk* = object
    ## What the geometry checks of a record are given.
    units*: GeometryUnits
    replaced*: bool
      ## a join replaced the file's coordinates: the keys' offsets are computed from them
    survey*: ptr SurveyGeometry
      ## the stations the file was joined with; nil when no survey is joined
    own*: bool ## the file's own header keys are wanted (the job reads them)

  GeometrySummary* = object
    ## What the geometry checks found in the record shown.
    ready*: bool
    units*: GeometryUnits
    offsetWhy*: string                      ## why the offset is not judged; "" when it is
    midpointWhy*: string                    ## why the midpoint is not judged; "" when it is
    positionWhy*: string                    ## why the header positions are not judged; "" when they are
    offsetNone*: bool                       ## `offsetWhy` is only that no trace had both an offset and positions
    traces*: int                            ## the live seismic traces looked at
    noOffset*: int                          ## traces with no offset (or a zero one with no positions): not judged
    offsetCompared*, midpointCompared*: int ## traces whose offset, midpoint was compared
    noPositions*: int                       ## traces whose source or receiver position is unknown
    offsetOff*, midpointOff*: int
    positionsJudged*: int                   ## traces whose header position was compared with the survey's
    receiversOff*, sourcesOff*: int
    positionOff*: int                       ## traces with either position off
    positionDistance*: seq[float64]
      ## per trace of the record: its header receiver position's distance from the survey's
      ## (NaN when not compared)

const
  Geographic* = {suDegrees, suArcSeconds, suDms}
    ## coordinate units that are angles, not lengths
  Tolerance* = GeometryQc()
    ## the library's tolerances, the filters' and the columns': 1 unit or 1% of the distance
  PositionTolerance* = 1.0
    ## how far a header position may be from the survey's station's, in the survey's unit
    ## (the join calls a position the survey's when it is within a micro-unit; headers are
    ## written rounded, to the unit)
  AllDifferShare = 0.9 ## a record whose positions (or offsets) differ more than this: a unit
  AllDifferLeast = 20 ## fewest traces for that

func isFoot(u: SurveyUnit): bool {.inline.} = u in {suFeet, suUsFeet}

func geometryUnits*(coordinates, offsets: SurveyUnit): GeometryUnits =
  ## Whether offsets in unit `offsets` and coordinates in unit `coordinates` (each as the
  ## headers or the import say it, `suNotGiven` when they say nothing) are lengths of one
  ## unit. An unnamed unit is taken as the other's: it cannot be told to differ (the offsets
  ## themselves are checked against that in `checkGeometryOf`).
  result = GeometryUnits(judged: true, unit: coordinates)
  if result.unit == suNotGiven: result.unit = offsets
  if coordinates in Geographic:
    result = GeometryUnits(angles: true, unit: coordinates, why: "the coordinates are in " &
      $coordinates & ", not lengths, so they cannot be compared with the offsets")
  elif coordinates != suNotGiven and offsets != suNotGiven and coordinates != offsets and
      not (coordinates.isFoot and offsets.isFoot):
    result = GeometryUnits(unit: coordinates, why: "the offsets are in " & $offsets &
      " and the coordinates in " & $coordinates)

func unitWord*(u: SurveyUnit): string =
  ## The unit in words for a tolerance or a value: "metres"; "units" when none is named.
  if u == suNotGiven: "units" else: $u

func toleranceWords*(units: GeometryUnits): string =
  ## The tolerance, in the survey's unit: "1 metres or 1% of the distance, whichever is more".
  let q = Tolerance
  let number = if q.tolerance == q.tolerance.round: $int(q.tolerance) else: $q.tolerance
  number & " " & units.unit.unitWord & " or " & $int(q.relTolerance * 100) &
    "% of the distance, whichever is more"

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func geometryLines*(g: GeometrySummary; offset, midpoint, position: bool): seq[string] =
  ## The lines the filters list shows under the geometry findings: why a filter that is on
  ## is not judged, and the traces that give no offset or no position and so are not
  ## judged; none for nothing to say.
  if not g.ready: return
  if offset and g.offsetWhy.len > 0:
    result.add "Offset not judged: " & g.offsetWhy & "."
  if midpoint and g.midpointWhy.len > 0 and g.midpointWhy != g.offsetWhy:
    result.add "Midpoint not judged: " & g.midpointWhy & "."
  if position and g.positionWhy.len > 0:
    result.add "Header positions not judged: " & g.positionWhy & "."
  let counted = (offset and (g.offsetWhy.len == 0 or g.offsetCompared == 0 and g.offsetNone)) or
    (midpoint and g.midpointWhy.len == 0)
  if counted:
    var parts: seq[string] = @[]
    if g.noOffset > 0 and offset:
      parts.add plural(g.noOffset, "trace gives no offset", "traces give no offset")
    if g.noPositions > 0:
      let word = if g.noPositions == 1: "gives" else: "give"
      parts.add (if parts.len == 0: plural(g.noPositions, "trace", "traces") else:
        $g.noPositions) & " " & word & " no positions"
    if parts.len > 0: result.add parts.join("; ") & ": not judged."

func ratioWhy(offsets, distances: openArray[float64]): string =
  ## "the offsets look like feet and the positions like metres" (or the reverse) when nearly
  ## every offset is 3.2808 or 0.3048 times the distance between the positions; "" when not.
  var feet, metres, total = 0
  for i in 0 ..< offsets.len:
    let (o, d) = (abs(offsets[i]), distances[i])
    if o > 0 and o < Inf and d > 0 and d < Inf:
      inc total
      let r = o / d
      if abs(r / 3.28084 - 1) <= 0.01: inc feet
      elif abs(r / 0.3048 - 1) <= 0.01: inc metres
  if total >= 5:
    if feet.float64 > AllDifferShare * total.float64:
      return "the offsets look like feet and the positions like metres"
    if metres.float64 > AllDifferShare * total.float64:
      return "the offsets look like metres and the positions like feet"

func usablePosition(x, y: float64): bool {.inline.} =
  abs(x) < Inf and abs(y) < Inf and not (x == 0 and y == 0)

func live(k: TraceKeys): bool {.inline.} = k.isSeismic and k.status in {tsLive, tsUnknown}

proc checkPositions(f: SeismicFile; traces: Slice[int]; base: int; ask: GeometryAsk;
    own: openArray[TraceKeys]; ownWhy: string; hits: var array[MapFilter, FilterHits];
    s: var GeometrySummary) =
  ## The file's own header positions of `traces` against the survey's stations.
  s.positionDistance = newSeq[float64](traces.len)
  for d in s.positionDistance.mitems: d = NaN
  if ask.units.angles: s.positionWhy = ask.units.why
  elif ask.survey.isNil: s.positionWhy = "no survey is imported"
  elif own.len != traces.len:
    s.positionWhy = "the file's own header positions could not be read (" &
      (if ownWhy.len > 0: ownWhy else: "not asked") & ")"
  if s.positionWhy.len > 0: return
  var off: seq[bool] = newSeq[bool](traces.len)
  var compared = 0
  # the stations compared and those off, by role: a record has one source, whose being off
  # is one station, not every trace of the record
  var stations: array[PointRole, Table[StationKey, bool]]
  for i in 0 ..< traces.len:
    let k = f.index.keys[traces.a + i]
    if k.live:
      var either, any = false
      for (role, line, point, index, x, y) in [(prReceiver, k.rcvLine, k.rcvPoint, k.rcvIndex,
          own[i].rcvX, own[i].rcvY), (prSource, k.srcLine, k.srcPoint, k.srcIndex, own[i].srcX,
          own[i].srcY)]:
        var c: Coordinates
        let table = if role == prSource: addr ask.survey[].table.sources
                    else: addr ask.survey[].table.receivers
        if usablePosition(x, y) and table[].stationAt(line, point, index, c) and
            usablePosition(c.x, c.y):
          any = true
          let d = hypot(x - c.x, y - c.y)
          if role == prReceiver: s.positionDistance[i] = d
          let st = stationKey(line, point, max(index, 0'i16))
          stations[role][st] = stations[role].getOrDefault(st) or d > PositionTolerance
          if d > PositionTolerance:
            either = true
            if role == prReceiver: inc s.receiversOff else: inc s.sourcesOff
      if any: inc compared
      off[i] = either
      if either: inc s.positionOff
  s.positionsJudged = compared
  if compared == 0:
    s.positionWhy = "no header position could be compared (the headers hold none, or the " &
      "survey lacks their stations)"
    return
  for role in PointRole:
    var off = 0
    for _, isOff in stations[role]:
      if isOff: inc off
    let all = stations[role].len
    if all >= AllDifferLeast and off.float64 > AllDifferShare * all.float64:
      s.positionWhy = "nearly every header position differs from the survey's (" & $off &
        " of " & $all & " stations): the units or the frame differ"
      (s.positionsJudged, s.positionOff, s.receiversOff, s.sourcesOff) = (0, 0, 0, 0)
      for d in s.positionDistance.mitems: d = NaN
      return
  for i in 0 ..< traces.len:
    if off[i]: hits[mfPositionOff].traces.add base + traces.a + i

proc checkGeometryOf*(f: SeismicFile; traces: Slice[int]; base: int; ask: GeometryAsk;
    own: openArray[TraceKeys]; ownWhy: string; hits: var array[MapFilter, FilterHits]):
    GeometrySummary =
  ## Fills the geometry filters of `hits` from the keys of `traces` of `f` (its trace 0 is
  ## survey-wide `base`), and says what was found. `own` holds the keys of the file's own
  ## headers for `traces` when they were read (`ownWhy` says why not otherwise). A filter
  ## that cannot be judged is `fsNotChecked`, with the reason.
  let units = ask.units
  let n = traces.len
  result = GeometrySummary(ready: true, units: units)
  let haveOwn = own.len == n
  # what the offsets and midpoints are: the header's (SEG-Y), or computed
  var keys = newSeq[TraceKeys](n)
  for i in 0 ..< n: keys[i] = f.index.keys[traces.a + i]
  if f.kind != skSegy:
    let why = "this format gives no offset of its own: it is computed from the positions"
    result.offsetWhy = why
    result.midpointWhy = why.replace("offset", "midpoint")
  elif haveOwn:
    for i in 0 ..< n:
      (keys[i].offset, keys[i].cmpX, keys[i].cmpY) = (own[i].offset, own[i].cmpX, own[i].cmpY)
  elif ask.replaced:
    result.offsetWhy = "the offsets shown are computed from the survey" &
      (if ownWhy.len > 0: " (the file's own could not be read: " & ownWhy & ")" else: "")
    result.midpointWhy = result.offsetWhy.replace("offsets", "midpoints")
  if result.offsetWhy.len == 0 and not units.judged: result.offsetWhy = units.why
  if result.midpointWhy.len == 0 and units.angles: result.midpointWhy = units.why
  var checks = newSeq[GeometryCheck](n)
  var offsets, distances: seq[float64] = @[]
  for i in 0 ..< n:
    checks[i] = if keys[i].live: checkGeometry(keys[i], Tolerance)
                else: GeometryCheck(distance: NaN, offsetError: NaN, midpointError: NaN)
    if keys[i].live:
      inc result.traces
      offsets.add keys[i].offset
      distances.add checks[i].distance
  if result.offsetWhy.len == 0:
    result.offsetWhy = ratioWhy(offsets, distances)
  for i in 0 ..< n:
    let (flags, k) = (checks[i].flags, keys[i])
    if k.live:
      if gfNoCoordinates in flags: inc result.noPositions
      if result.offsetWhy.len == 0:
        # (a zero offset in the file's own headers is a header left empty, not a position
        # it disagrees with; in the keys parseSEG has filled it, so a zero there agrees)
        if gfNoOffset in flags or (k.offset == 0 and (gfNoCoordinates in flags or
            (haveOwn and gfZeroOffset notin flags))):
          inc result.noOffset
        elif not checks[i].offsetError.isNaN:
          inc result.offsetCompared
          if gfOffsetMismatch in flags: hits[mfOffsetOff].traces.add base + traces.a + i
      if result.midpointWhy.len == 0 and not checks[i].midpointError.isNaN:
        inc result.midpointCompared
        if gfMidpointMismatch in flags: hits[mfMidpointOff].traces.add base + traces.a + i
  if result.offsetWhy.len == 0 and result.offsetCompared == 0:
    (result.offsetWhy, result.offsetNone) = ("no trace has both an offset and its positions " &
      "to compare", true)
  if result.midpointWhy.len == 0 and result.midpointCompared == 0:
    result.midpointWhy = "no trace has both a midpoint and its positions to compare"
  result.offsetOff = hits[mfOffsetOff].traces.len
  result.midpointOff = hits[mfMidpointOff].traces.len
  let tol = units.toleranceWords
  for (m, why, what) in [(mfOffsetOff, result.offsetWhy, "traces whose offset differs from " &
      "the distance between their source and receiver by more than " & tol),
      (mfMidpointOff, result.midpointWhy, "traces whose midpoint is not halfway between " &
      "their source and receiver, by more than " & tol)]:
    if why.len > 0:
      hits[m].traces.setLen 0
      (hits[m].state, hits[m].note) = (fsNotChecked, why)
    else:
      hits[m].state = fsDone
      hits[m].count = hits[m].traces.len
      hits[m].note = what
  if result.offsetWhy.len > 0: result.offsetOff = 0
  if result.midpointWhy.len > 0: result.midpointOff = 0
  checkPositions(f, traces, base, ask, own, ownWhy, hits, result)
  if result.positionWhy.len > 0:
    (hits[mfPositionOff].state, hits[mfPositionOff].note) = (fsNotChecked, result.positionWhy)
  else:
    hits[mfPositionOff].state = fsDone
    hits[mfPositionOff].count = hits[mfPositionOff].traces.len
    hits[mfPositionOff].note = "traces whose own header position is more than " &
      $int(PositionTolerance) & " " & units.unit.unitWord & " from the survey's station (" &
      $result.receiversOff & " receivers, " & $result.sourcesOff & " sources); the station " &
      "move menu's \"Move this station to the position in this trace's headers\" follows"
