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

import std/[algorithm, math, options, strutils, tables]
import parseSEG
import parseSEG/model/traceindex
import processSEG/continuous/slice
import ./[segmentclock, vendormaps]

const TriggerTimeField* = "triggerTime"
  ## The vendor map field, beside `FirstSampleTimeField`, that says when a trace's data
  ## begin. Both state it, so a trace carried with either unchanged would contradict the
  ## sliced data: the start time is the instant of the slice's first sample, and the
  ## trigger time, the instant the recorder was triggered for the data the trace holds, is
  ## that same instant for a slice, whose data begin at its first sample. A trigger that
  ## lay before or after the first sample in the recording does not keep that offset: it
  ## becomes the first sample's instant too. A trigger field in "us GPS" or "us UTC" is
  ## written in its own unit; one with no unit takes the start time's new value when, in
  ## the segment carried, it held the same value as the start time in the same encoding;
  ## else it stays as carried, and is counted. Only these two are rewritten; any other time
  ## field of a vendor block stays as carried.

type
  CarryRows* = object
    ## The source trace each receiver (component) of the plan falls back on
    ## when the window of a shot has no sample of it in any segment: the
    ## first segment the plan reads of it.
    fallback*: seq[int]
    rank*: seq[int]
      ## each receiver's place among the receivers by first appearance in the source:
      ## the order its trace number keeps in every record

  StartCount* = object
    ## Traces whose vendor start-time field was rewritten, and those with none to rewrite.
    rewritten*, missing*: int
    trigger*, triggerLeft*: int ## the trigger time field: rewritten, and left as carried

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
  var order = newSeq[int](result.fallback.len)
  for r in 0 ..< order.len: order[r] = r
  let first = result.fallback
  order.sort do (a, b: int) -> int: cmp(first[a], first[b])
  result.rank = newSeq[int](order.len)
  for n, r in order: result.rank[r] = n

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
  ## source trace; a fixed order of the components is not possible, as each
  ## takes the segment that holds its own first sample). Each component keeps
  ## one trace number in every record instead: its place among the components
  ## of its channel set, in the order they first appear in the source.
  let comps = plan.receiverCount
  var pairs: seq[tuple[trace, comp: int]] = @[]
  for r in 0 ..< comps:
    pairs.add (firstRow(plan, shot * comps + r, rows.fallback[r]), r)
  pairs.sort do (a, b: tuple[trace, comp: int]) -> int: cmp(a.trace, b.trace)
  var sets: seq[int] = @[]
  for p in pairs:
    let set = file.findTraceField(p.trace, "trace.channelSetNumber")
    sets.add(if set.isSome: int(set.get.toFloat) else: 0)
  for i, p in pairs:
    var ordinal = 1
    for j, q in pairs:
      if sets[j] == sets[i] and rows.rank[q.comp] < rows.rank[p.comp]: inc ordinal
    result.traces.add p.trace
    result.comps.add p.comp
    result.ordinals.add ordinal

proc carryRefusal*(file: SeismicFile; plan: SlicePlan; rows: CarryRows): string =
  ## "" when the cut can carry the source's headers: a SEG-D source whose
  ## slices all come from one record (a subset is made of the traces of one)
  ## that is not in Rev 3 extended recording mode, and every receiver has a
  ## segment to take its headers from. Else the reason, as a clause.
  if file.kind != skSegd: return "the recording is not SEG-D"
  if plan.len == 0: return "no trace is read"
  for r in rows.fallback:
    if r < 0: return "a component has no trace that any shot reads"
  let rec = file.traceEntry(plan.tracesNeeded[0]).record
  for t in plan.tracesNeeded:
    if file.traceEntry(t).record != rec:
      return "the traces the shots read lie in more than one record of the recording"
  let head = file.index.segdRecords[int(rec)]
  if head.layout == slRev3 and head.gh3.extendedRecordingMode == 1:
    return "the record is in Rev 3 extended recording mode"

proc openCarry*(part: string; file: SeismicFile; plan: SlicePlan; rows: CarryRows;
    reg: VendorRegistry; w: var SeismicWriter): string =
  ## "", with `w` opened like `file`, when the cut has no `carryRefusal` and the
  ## writer accepts the source as a template (it refuses multiplexed data);
  ## else the reason, and `w` is left alone: the cut builds its headers from
  ## keys. The samples are written as IEEE float32, as the keys path does,
  ## whatever the source's sample format.
  result = carryRefusal(file, plan, rows)
  if result.len == 0:
    try:
      w = openSeismicWriter(part, like = file, segdFormat = tf8058)
      if reg.maps.len > 0: w.useVendorMaps(reg)
    except ValueError as e:
      result = e.msg.replace(file.path, "the recording")

proc carryBytes*(file: SeismicFile; plan: SlicePlan; rows: CarryRows; shots: int): int64 =
  ## The size of the carried output: per record the source record's header
  ## blocks, per trace its header and extension bytes and its samples as float32.
  let rec = int(file.traceEntry(plan.tracesNeeded[0]).record)
  var perRecord = file.index.segdRecords[rec].headerBytes
  for r in 0 ..< plan.receiverCount:
    perRecord += int64(file.traceEntry(rows.fallback[r]).headerBytes) +
      int64(plan.samples) * 4
  result = int64(shots) * perRecord

func sourceFormat*(file: SeismicFile; plan: SlicePlan): int =
  ## The sample format code of the source record when it is not IEEE float32
  ## (8058), else 0.
  let rec = file.traceEntry(plan.tracesNeeded[0]).record
  let code = file.index.segdRecords[int(rec)].gh1.formatCode
  if code == 8058: 0 else: code

proc carryHeaderBytes*(file: SeismicFile; components: int): int64 =
  ## What one carried record of `components` traces holds besides its samples, worked out
  ## from the whole file before any shot is planned (the summary's size): the first record's
  ## header blocks and, per component, the header bytes of the first trace. 0 when the file
  ## would not be carried (not SEG-D, several records, Rev 3 extended recording mode).
  if file.kind != skSegd or file.len == 0: return 0
  let rec = file.traceEntry(0).record
  if file.traceEntry(file.len - 1).record != rec: return 0
  let head = file.index.segdRecords[int(rec)]
  if head.layout == slRev3 and head.gh3.extendedRecordingMode == 1: return 0
  head.headerBytes + int64(components) * int64(file.traceEntry(0).headerBytes)

func revisionWords*(file: SeismicFile; plan: SlicePlan): string =
  ## "Rev 2.1": the revision of the record the cut copies.
  let rec = file.traceEntry(plan.tracesNeeded[0]).record
  let r = file.index.segdRecords[int(rec)].revision
  "Rev " & $r.major & "." & $r.minor

proc isRev3*(file: SeismicFile; trace: int): bool =
  file.index.segdRecords[int(file.traceEntry(trace).record)].layout == slRev3

type FoundField = tuple[map, target: string; field: VendorFieldFact]

func findField(shown: VendorShown; name: string): Option[FoundField] =
  ## The first decoded field called `name`, with the map and target that decoded it (the
  ## writer's vendor override also takes the first block that has the field).
  for b in shown.blocks:
    for f in b.fields:
      if f.name == name: return some((b.map, b.name, f))

func fieldPlan(reg: VendorRegistry; found: FoundField): Option[VendorFieldPlan] =
  ## How the map that decoded `found` lays the field out.
  for m in reg.maps:
    if m.name == found.map:
      for t in m.targets:
        if t.name == found.target:
          for p in t.fields:
            if p.name == found.field.name: return some(p)

func sameEncoding(reg: VendorRegistry; a, b: FoundField): bool =
  ## Whether two decoded fields store a value in the same bytes: the same encoding, width,
  ## byte order and scale, so equal shown values are equal raw values, and one value
  ## written to both gives both the same bytes.
  let (x, y) = (fieldPlan(reg, a), fieldPlan(reg, b))
  if x.isSome and y.isSome:
    let (p, q) = (x.get, y.get)
    result = p.enc == q.enc and p.len == q.len and p.nibbles == q.nibbles and
      p.lowNibble == q.lowNibble and p.order == q.order and p.scaled == q.scaled and
      p.scale == q.scale and p.offset == q.offset

func declares*(reg: VendorRegistry; name: string): bool =
  ## Whether a map of `reg` has a field called `name`.
  for m in reg.maps:
    for t in m.targets:
      for fld in t.fields:
        if fld.name == name: return true
      for r in t.repeats:
        for fld in r.fields:
          if fld.name == name: return true

proc instantIn(unit: string; firstUs: int64): int64 =
  ## `firstUs` (UTC microseconds) in the unit and epoch of a time field; 0 for a unit the
  ## viewer does not convert.
  case unit
  of UnitGps: utcUsToGpsUs(firstUs)
  of UnitUtc: firstUs
  else: 0'i64

const
  TimestampBlock = 0x42'u8 ## a Rev 3 trace's Timestamp block: the instant of its first sample
  SourceDescriptionBlocks = {0x15'u8 .. 0x19'u8, 0x1F'u8}
    ## the Rev 3 Source Description blocks: vibrator, explosive, airgun, water gun,
    ## electromagnetic and other sources

proc extensionTypes(file: SeismicFile; trace: int): set[uint8] =
  ## The block types (byte 32) of a Rev 3 trace's header blocks after Trace Header
  ## Extension #1, as the writer finds the blocks it patches; empty for Rev 2, whose
  ## blocks have no type.
  if isRev3(file, trace):
    let e = file.traceEntry(trace)
    let extra = int(e.headerBytes) - SegdTraceHeaderSize - SegdBlockSize
    if extra >= SegdBlockSize:
      let bytes = file.copyBytes(e.offset + SegdTraceHeaderSize + SegdBlockSize, extra)
      for (_, kind) in blocks(bytes): result.incl kind

proc hasSourceHeader*(file: SeismicFile; trace: int): bool =
  ## A Rev 2 record's source header (General Header #3).
  file.findRecordField(int(file.traceEntry(trace).record), "gh3.sourceLineNumber").isSome

proc ownSource*(file: SeismicFile; trace: int): bool =
  ## The record's own source header names a line or a point other than 0.
  let rec = int(file.traceEntry(trace).record)
  for name in ["gh3.sourceLineNumber", "gh3.sourcePointNumber"]:
    let v = file.findRecordField(rec, name)
    if v.isSome and v.get.toFloat != 0: return true

proc sourceBlocks*(file: SeismicFile; trace: int): tuple[description, position: bool] =
  ## Whether a Rev 3 trace has a Source Description block and a Position block, the
  ## places the shot's source line, point and coordinates are written to.
  let kinds = extensionTypes(file, trace)
  (kinds * SourceDescriptionBlocks != {}, BlockTypePosition1 in kinds)

proc sessionPositions*(file: SeismicFile): bool =
  ## The session's keys hold receiver positions that did not come from the file's own
  ## headers (a survey join or a move).
  if not file.hasKeys: return false
  for groups in file.index.joinedTraces:
    if groups.card > 0: return true
  file.index.joined

proc sourceHeaders*(file: SeismicFile; trace: int; line, point: float64;
    index: int16): seq[HeaderOverride] =
  ## A Rev 2 record's source header (General Header #3) fields for the shot:
  ## the line and point when both are known, the point index when 1 to 255.
  ## Nothing when the record has no source header.
  if hasSourceHeader(file, trace):
    if not (line.isNaN or point.isNaN):
      result.add headerOverride("gh3.sourceLineNumber", line)
      result.add headerOverride("gh3.sourcePointNumber", point)
    if index in 1'i16 .. 255'i16:
      result.add headerOverride("gh3.sourcePointIndex", int64(index))

proc traceOverrides*(file: SeismicFile; trace, ordinal: int; firstUs: int64;
    reg: VendorRegistry; startField, dead: bool; counts: var StartCount): seq[HeaderOverride] =
  ## What a written trace changes of its source trace's headers: its number in
  ## its channel set, the instant of its first sample in a Rev 3 timestamp
  ## block (`firstUs`, UTC microseconds), and, when `startField`, the start time of
  ## the vendor block in the unit and epoch the map gives it (`counts` says how many
  ## were set and how many traces had none), the trigger time of the vendor block as
  ## `TriggerTimeField` says; `dead` marks the trace dead.
  result.add headerOverride("trace.traceNumber", ordinal)
  # A trace no segment reaches is zeros: the trace edit code 1 is how the keys path marks
  # a dead trace (`tsDead`). A trace partly covered stays as the source has it.
  if dead: result.add headerOverride("trace.traceEdit", 1)
  if TimestampBlock in extensionTypes(file, trace):
    result.add headerOverride("timestamp.timeZeroOfData", utcUsToGpsUs(firstUs))
  if startField or reg.declares(TriggerTimeField):
    let shown = vendorTrace(file, trace, reg)
    let start = shown.findField(FirstSampleTimeField)
    var startValue = 0'i64
    if startField:
      if start.isSome: startValue = instantIn(start.get.field.unit, firstUs)
      if startValue > 0:
        result.add headerOverride("vendor." & FirstSampleTimeField, startValue)
        inc counts.rewritten
      else: inc counts.missing
    # only a trace whose own blocks have the trigger field counts it
    let trigger = shown.findField(TriggerTimeField)
    if trigger.isSome:
      var value = instantIn(trigger.get.field.unit, firstUs)
      if value <= 0 and trigger.get.field.unit.len == 0 and startValue > 0 and
          trigger.get.field.value == start.get.field.value and
          reg.sameEncoding(start.get, trigger.get):
        value = startValue
      if value > 0:
        result.add headerOverride("vendor." & TriggerTimeField, value)
        inc counts.trigger
      else: inc counts.triggerLeft
