## What a cut of a SEG-D recording into SEG-D keeps of the recording's headers.
##
## The output record of a shot is made of the source's own header blocks, not
## built from keys: the writer is opened like the source (its revision and
## record headers), and each shot is a subset of the source record
## (`startSubset`) holding, for every component, the source trace (segment)
## that holds the first sample of the shot's window. Its general headers,
## extended header, channel set descriptors and every trace's header and
## vendor extension blocks are the source's; the shot says what changes: the
## file number, the record time, the trace number, the first-sample time of
## a Rev 3 trace's timestamp block, the start time of a trace's vendor block
## (when a loaded map names it) and, where the revision has a place for them,
## the source's line and point.
##
## The choice between this and the keys path lives in `openCarry`.

import std/[algorithm, math, options, tables]
import parseSEG
import parseSEG/model/traceindex
import processSEG/continuous/slice
import ./[segmentclock, vendormaps]

type
  CarryRows* = object
    ## The source trace each receiver (component) of the plan falls back on
    ## when the window of a shot has no sample of it in any segment: the
    ## first segment the plan reads of it.
    fallback*: seq[int]

  CarryShot* = object
    ## The traces of one shot's output record.
    traces*: seq[int]   ## source traces, ascending
    comps*: seq[int]    ## the component (receiver) written at each
    ordinals*: seq[int] ## its trace number in its channel set of the record, from 1

const SourceFields* = GeometryFields(sourceXy: true, receiverXy: false, elevations: true,
  midpoints: false, offsets: false, stations: true)
  ## The geometry a Rev 3 trace takes from the shot: the source's place, not the receiver's.

func hasSourcePlace*(k: TraceKeys): bool =
  ## The shot names a source line and point, a point index or coordinates.
  not (k.srcLine.isNaN or k.srcPoint.isNaN) or k.srcIndex != 0 or k.hasSourceXY

func carryRows*(plan: SlicePlan): CarryRows =
  ## The fall-back segment of every receiver; -1 for one the plan never reads.
  result.fallback = newSeq[int](plan.receiverCount)
  for r in 0 ..< result.fallback.len: result.fallback[r] = -1
  for trace in 0 ..< plan.len:
    let r = plan.receiverOf(trace)
    if result.fallback[r] < 0:
      for pc in plan.pieces(trace):
        if pc.row >= 0 and result.fallback[r] < 0: result.fallback[r] = pc.row

func firstRow(plan: SlicePlan; trace, fallback: int): int =
  ## The source trace that holds the first sample of the window of output
  ## trace `trace`: the piece that covers column 0; when that is a gap, the
  ## first segment the window does read, else `fallback`.
  result = -1
  for pc in plan.pieces(trace):
    if pc.row >= 0:
      if result < 0: result = pc.row
      if pc.dst <= 0 and pc.dst + pc.count > 0: return pc.row
  if result < 0: result = fallback

proc carryShot*(file: SeismicFile; plan: SlicePlan; rows: CarryRows; shot: int): CarryShot =
  ## The traces of shot `shot` in the order `startSubset` needs (ascending
  ## source trace), with the trace number each takes in its channel set.
  let comps = plan.receiverCount
  var pairs: seq[tuple[trace, comp: int]] = @[]
  for r in 0 ..< comps:
    pairs.add (firstRow(plan, shot * comps + r, rows.fallback[r]), r)
  pairs.sort do (a, b: tuple[trace, comp: int]) -> int: cmp(a.trace, b.trace)
  var inSet = initTable[int, int]()
  for p in pairs:
    let set = file.findTraceField(p.trace, "trace.channelSetNumber")
    let key = if set.isSome: int(set.get.toFloat) else: 0
    inSet[key] = inSet.getOrDefault(key, 0) + 1
    result.traces.add p.trace
    result.comps.add p.comp
    result.ordinals.add inSet[key]

proc openCarry*(part: string; file: SeismicFile; plan: SlicePlan; rows: CarryRows;
    reg: VendorRegistry; w: var SeismicWriter): bool =
  ## True, with `w` opened like `file`, when the cut can carry the source's
  ## headers: a SEG-D source whose slices all come from one record (a subset
  ## is made of the traces of one) that is not in Rev 3 extended recording
  ## mode and that the writer accepts as a template (it refuses multiplexed
  ## data). False leaves `w` alone and the cut builds its headers from keys.
  ## The samples are written as IEEE float32, as the keys path does, whatever
  ## the source's sample format.
  if file.kind != skSegd or plan.len == 0: return false
  for r in rows.fallback:
    if r < 0: return false
  let rec = file.traceEntry(plan.tracesNeeded[0]).record
  for t in plan.tracesNeeded:
    if file.traceEntry(t).record != rec: return false
  let head = file.index.segdRecords[int(rec)]
  if head.layout == slRev3 and head.gh3.extendedRecordingMode == 1: return false
  try:
    w = openSeismicWriter(part, like = file, segdFormat = tf8058)
    if reg.maps.len > 0: w.useVendorMaps(reg)
    result = true
  except ValueError:
    result = false

func revisionWords*(file: SeismicFile; plan: SlicePlan): string =
  ## "Rev 2.1": the revision of the record the cut copies.
  let rec = file.traceEntry(plan.tracesNeeded[0]).record
  let r = file.index.segdRecords[int(rec)].revision
  "Rev " & $r.major & "." & $r.minor

proc isRev3*(file: SeismicFile; trace: int): bool =
  file.index.segdRecords[int(file.traceEntry(trace).record)].layout == slRev3

proc startUnit(file: SeismicFile; trace: int; reg: VendorRegistry): string =
  ## The unit the vendor map gives the start-time field of `trace`, "" when
  ## the trace shows none.
  for b in vendorTrace(file, trace, reg).blocks:
    for f in b.fields:
      if f.name == FirstSampleTimeField: return f.unit

proc sourceHeaders*(file: SeismicFile; trace: int; line, point: float64;
    index: int16): seq[HeaderOverride] =
  ## A Rev 2 record's source header (General Header #3) fields for the shot:
  ## the line and point when both are known, the point index when 1 to 255.
  ## Nothing when the record has no source header.
  let rec = int(file.traceEntry(trace).record)
  if file.findRecordField(rec, "gh3.sourceLineNumber").isSome:
    if not (line.isNaN or point.isNaN):
      result.add headerOverride("gh3.sourceLineNumber", line)
      result.add headerOverride("gh3.sourcePointNumber", point)
    if index in 1'i16 .. 255'i16:
      result.add headerOverride("gh3.sourcePointIndex", int64(index))

proc traceOverrides*(file: SeismicFile; trace, ordinal: int; firstUs: int64;
    reg: VendorRegistry; startField: bool; startWritten: var bool): seq[HeaderOverride] =
  ## What a written trace changes of its source trace's headers: its number in
  ## its channel set, the instant of its first sample in a Rev 3 timestamp
  ## block, and, when `startField`, the start time of the vendor block in the
  ## unit and epoch the map gives it (`startWritten` says it was set).
  result.add headerOverride("trace.traceNumber", ordinal)
  if file.findTraceField(trace, "timestamp.timeZeroOfData").isSome:
    result.add headerOverride("timestamp.timeZeroOfData", utcUsToGpsUs(firstUs))
  if startField:
    let value = case file.startUnit(trace, reg)
      of UnitGps: utcUsToGpsUs(firstUs)
      of UnitUtc: firstUs
      else: 0'i64
    if value > 0:
      result.add headerOverride("vendor." & FirstSampleTimeField, value)
      startWritten = true
