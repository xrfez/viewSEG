## The geometry check of the record shown, for the map's filters
## (`mfOffsetOff`, `mfMidpointOff`) and the trace table's computed columns:
## processSEG's `qc/geometry`, from the trace keys alone (no sample is read), after
## a survey join or a station move has changed them.
##
## Only two findings are failures of the data: a header offset that is not the
## distance between the source and the receiver, and a header midpoint that is
## not halfway between them. A trace without an offset, or with a zero one, or
## without coordinates, is not judged: many files carry none before a survey
## join, so those are counted in one line (`geometryWords`), never marked.
##
## **Units.** The comparison is of two lengths, so it is made only when the
## offsets and the coordinates are lengths of one unit (`geometryUnits`). A
## file whose coordinates are degrees, arc seconds or degrees, minutes and
## seconds, or whose offsets are in another unit than its coordinates, is not
## judged at all, and says why: it would otherwise mismatch on every trace.

import std/[math, strutils]
import parseSEG
import processSEG/core/[rows, types]
import processSEG/qc/geometry
import join, mapkinds

export geometry.GeometryQc

type
  GeometryUnits* = object
    ## Whether a record's offsets and coordinates can be compared.
    judged*: bool     ## they are lengths of one unit
    unit*: SurveyUnit ## that unit, when a header names it
    why*: string      ## when not judged: the reason, in a sentence

  GeometrySummary* = object
    ## What the geometry check found in the record shown.
    ready*: bool
    units*: GeometryUnits
    traces*: int      ## the live seismic traces judged
    noOffset*: int    ## traces with no offset, or a zero one that agrees with the positions
    noPositions*: int ## traces whose source or receiver position is unknown
    offsetOff*, midpointOff*: int

const
  Geographic* = {suDegrees, suArcSeconds, suDms}
    ## coordinate units that are angles, not lengths
  Tolerance* = GeometryQc()
    ## the library's tolerances, the filters' and the columns': 1 unit or 1% of the distance

func isFoot(u: SurveyUnit): bool {.inline.} = u in {suFeet, suUsFeet}

func geometryUnits*(coordinates, offsets: SurveyUnit): GeometryUnits =
  ## Whether offsets in unit `offsets` and coordinates in unit `coordinates` (each as the
  ## headers or the import say it, `suNotGiven` when they say nothing) are lengths of one
  ## unit. An unnamed unit is taken as the other's: it cannot be told to differ.
  result = GeometryUnits(judged: true, unit: coordinates)
  if result.unit == suNotGiven: result.unit = offsets
  if coordinates in Geographic:
    result = GeometryUnits(unit: coordinates, why: "the coordinates are in " & $coordinates &
      ", not lengths, so they cannot be compared with the offsets")
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

func geometryWords*(g: GeometrySummary): string =
  ## The line the filters list shows under the geometry findings: why the record is not
  ## judged, or the traces that give no offset or no position and are not judged; "" for
  ## nothing to say.
  if not g.ready: return ""
  if not g.units.judged: return "Geometry not judged: " & g.units.why & "."
  var parts: seq[string] = @[]
  if g.noOffset > 0: parts.add $g.noOffset & " traces give no offset"
  if g.noPositions > 0:
    parts.add (if parts.len == 0: $g.noPositions & " traces" else: $g.noPositions) &
      " give no positions"
  if parts.len > 0: parts.join("; ") & ": not judged."
  else: ""

proc checkGeometryOf*(f: SeismicFile; traces: Slice[int]; base: int; units: GeometryUnits;
    hits: var array[MapFilter, FilterHits]): GeometrySummary =
  ## Fills the two geometry filters of `hits` from the keys of `traces` of `f` (its trace 0
  ## is survey-wide `base`), and says what was found. Not judged (`units`): both are
  ## `fsNotChecked`, with the reason.
  result = GeometrySummary(ready: true, units: units)
  if not units.judged:
    for m in [mfOffsetOff, mfMidpointOff]:
      (hits[m].state, hits[m].note) = (fsNotChecked, units.why)
    return
  var checks = newSeq[GeometryCheck](traces.len)
  checkGeometryInto(f.rowsOf(traces), checks, Tolerance)
  for i in 0 ..< traces.len:
    let flags = checks[i].flags
    let k = f.index.keys[traces.a + i]
    if k.isSeismic and k.status != tsDead:
      inc result.traces
      if gfOffsetMismatch in flags: hits[mfOffsetOff].traces.add base + traces.a + i
      if gfMidpointMismatch in flags: hits[mfMidpointOff].traces.add base + traces.a + i
      if gfNoCoordinates in flags: inc result.noPositions
      if gfNoOffset in flags or (k.offset == 0 and gfOffsetMismatch notin flags):
        inc result.noOffset
  result.offsetOff = hits[mfOffsetOff].traces.len
  result.midpointOff = hits[mfMidpointOff].traces.len
  let tol = units.toleranceWords
  for (m, what) in [(mfOffsetOff, "traces whose offset differs from the distance between " &
      "their source and receiver by more than " & tol),
      (mfMidpointOff, "traces whose midpoint is not halfway between their source and " &
      "receiver, by more than " & tol)]:
    hits[m].state = fsDone
    hits[m].count = hits[m].traces.len
    hits[m].note = what
