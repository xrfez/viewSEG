## What the Headers window shows, as plain lines and tables: the Summary
## tab's lines (what the file is and the counts of the record shown, in
## plain words), the header tables (`fieldTable`: a row per field, a column
## of values per header, the values that differ between columns marked),
## and the lines of a block's bytes (`dumpLine`). Made from `core` (a
## session's `facts`, its records, the inspector's answers), never from the
## toolkit, so that any frontend shows the same words.

import std/[math, os, strutils, tables, times]
import parseSEG
import ../core/state

type
  SummaryLine* = object
    ## One line of the Summary tab: a value and what it is, or a heading.
    label*: string
    value*: string ## "" for a heading
    heading*: bool

func grouped*(n: int64): string =
  ## `n` with its thousands apart: "1 234 567".
  let digits = $abs(n)
  for i, c in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: result.add ' '
    result.add c
  if n < 0: result = "-" & result

func bytesText*(n: int64): string =
  ## A size in bytes, and in KiB, MiB or GiB past a thousand.
  const units = ["KiB", "MiB", "GiB", "TiB"]
  result = grouped(n) & (if n == 1: " byte" else: " bytes")
  var x = float64(n)
  var u = -1
  while x >= 1024 and u < units.high:
    x /= 1024
    inc u
  if u >= 0: result.add " (" & formatFloat(x, ffDecimal, 1) & " " & units[u] & ")"

func msText*(ms: float64): string =
  ## A time in ms in its shortest form; "" when not known.
  if ms.isNaN: "" else: exactText(ms) & " ms"

func gatherWord(k: GatherKind): string =
  case k
  of gkShot: "shot record"
  of gkReceiver: "receiver gather"
  of gkCmp: "CMP gather"
  of gkOffset: "common-offset gather"
  of gkUnknown, gkOther: "record"

func standardText(s: FileSummary): string =
  result = case s.standard
    of skSegy: "SEG-Y"
    of skSegd: "SEG-D"
    of skSeg2: "SEG-2"
    of skUnknown: "not recognised"
  if s.standard in {skSegy, skSegd}: result.add " revision " & $s.revision
  elif s.standard == skSeg2: result.add " revision " & $s.revision.major
  if s.mixedRevisions: result.add " (its records are of several revisions)"

proc add(lines: var seq[SummaryLine]; label, value: string) =
  if value.len > 0: lines.add SummaryLine(label: label, value: value)

proc heading(lines: var seq[SummaryLine]; label: string) =
  lines.add SummaryLine(label: label, heading: true)

func firstLine(text: string): string =
  let i = text.find('\n')
  result = (if i >= 0: text[0 ..< i] else: text).strip
  if result.len > 100: result = result[0 ..< 100] & "..."

func unitWords*(c: CoordinateUnits): string =
  ## The unit a file's headers give its coordinates in, in the words of the
  ## join window (File > Join geometry).
  result = $unitOf(c)
  if c == cuLength: result.add " (the headers say a length, not whether metres or feet)"

proc summaryLines*(s: Session; gather: int; joins: openArray[Joined] = []): seq[SummaryLine] =
  ## The Summary tab of file `s` with its gather `gather` shown (-1 for
  ## none): the file, its format, its traces and timing, its coordinates
  ## (as the join window gives them: the units its headers say, or those
  ## confirmed for its join, and its CRS text), the join it was given (of
  ## `joins`), and the record shown with its counts (the Records window's),
  ## and for SEG-D that record's channel sets.
  template facts: untyped = s.facts
  let sm = facts.summary
  result.heading "File"
  result.add "Name", s.name
  result.add "Folder", s.path.parentDir
  if s.size >= 0: result.add "Size", bytesText(s.size)
  if s.modified != Time(): result.add "Modified", s.modified.local.format("yyyy-MM-dd HH:mm:ss")
  result.heading "Format"
  result.add "Standard", standardText(sm)
  if sm.standard in {skSegy, skSeg2}:
    result.add "Byte order", (if sm.byteOrder == boBig: "big-endian" else: "little-endian")
  if facts.textEncoding.len > 0: result.add "Textual header", facts.textEncoding
  if facts.extendedText.len > 0:
    result.add "Extended textual headers", $facts.extendedText.len
  if sm.formatCode >= 0:
    let name = formatName(sm.standard, sm.formatCode)
    result.add "Sample format", $sm.formatCode & (if name.len > 0: ": " & name else: "")
  elif sm.standard == skSegd:
    result.add "Sample format", "differs between records"
  result.add "Samples decodable", (if sm.decodable: "yes"
    else: "no: some traces are in a sample format that cannot be decoded")
  result.heading "Traces"
  result.add "Traces", grouped(sm.traceCount)
  result.add "Records", grouped(s.gathers.len) &
    (if sm.standard == skSegd: " (" & grouped(sm.recordCount) & " SEG-D records)" else: "")
  if sm.firstFieldRecord >= 0:
    let what = if sm.standard == skSegd: "File numbers" else: "Field records (FFID)"
    result.add what, (if sm.lastFieldRecord == sm.firstFieldRecord: $sm.firstFieldRecord
      else: $sm.firstFieldRecord & " to " & $sm.lastFieldRecord)
  result.add "Samples per trace", (if sm.samplesPerTrace >= 0: grouped(sm.samplesPerTrace)
    else: "differ between traces")
  result.add "Sample interval", (if sm.sampleIntervalUs.isNaN: "differs between " &
    (if sm.standard == skSegd: "channel sets" else: "traces")
    else: exactText(sm.sampleIntervalUs / 1000) & " ms")
  result.add "Record length", msText(sm.recordLengthMs)
  var joined = -1
  for j, x in joins:
    if x.session == s.id: joined = j
  result.heading "Coordinates"
  let said = unitWords(s.crs.units)
  if joined >= 0:
    let confirmed = $joins[joined].units.file
    result.add "Units", confirmed & " (confirmed for the geometry join" &
      (if confirmed != $unitOf(s.crs.units): "; the headers say " & said else: "") & ")"
  else:
    result.add "Units", said
  result.add "Coordinate reference", (if s.crs.format == ctNone or s.crs.text.len == 0:
    "none in the file" else: $s.crs.format & ": " & firstLine(latin1(s.crs.text)))
  if joined >= 0:
    let j = joins[joined]
    result.heading "Geometry join"
    var names: seq[string]
    for f in j.files: names.add f.path.extractFilename
    result.add "Survey files", names.join(", ")
    result.add "Their units", $j.units.survey
    result.add "Matched", $j.plan.matched & " of " & $j.plan.seismic & " seismic traces"
    result.add "Keys changed", $j.plan.changes & (if j.plan.changes == 1: " trace" else: " traces")
    for k, w in j.words:
      result.add (if k == 0: "What it did" else: ""), w
  if gather in 0 ..< s.records.len:
    let r = s.records[gather]
    result.heading "The record shown: " & $(gather + 1) & " of " & $s.records.len
    result.add "Kind", gatherWord(r.kind)
    if not r.record.isNaN: result.add "FFID", exactText(r.record)
    result.add "Source", station(r.srcLine, r.srcPoint)
    result.add "Receiver", station(r.rcvLine, r.rcvPoint)
    if not r.ensemble.isNaN: result.add "CDP", exactText(r.ensemble)
    result.add "Traces", $r.traces & " (from trace " & $(r.first + 1) & ")"
    result.add "Seismic", $r.seismic
    result.add "Auxiliary", $r.aux
    result.add "Dead", $r.dead
    result.add "Missing", (case r.missingSource
      of msSurvey: $r.plannedMissing & " of the " & $r.planned & " stations its X record in " &
        s.checkedAgainst & " plans"
      of msFile: $r.missing & " of the " & $r.declared & " seismic traces the file declares"
      of msNone: "not known (the file declares no count; load the relation file to check)")
    let rec = s.file.segdRecordOf(r.first)
    if rec >= 0:
      var sets = 0
      for c in facts.channelSets:
        if c.record == rec: inc sets
      if sets > 0:
        result.heading "Channel sets of the record shown (SEG-D record " & $(rec + 1) & ")"
        let rev3 = sm.revision.major >= 3
        for c in facts.channelSets:
          if c.record == rec:
            result.add "Set " & $c.number & (if c.scanType > 0: " (scan type " &
              $(c.scanType + 1) & ")" else: ""),
              channelTypeName(rev3, c.channelType) & ", " & $c.traceCount &
              (if c.traceCount == 1: " trace, " else: " traces, ") & $c.samplesPerTrace &
              " samples at " & msText(c.sampleIntervalUs / 1000) & ", " &
              exactText(c.startTimeMs) & " to " & msText(c.endTimeMs)
  for p in facts.problems:
    result.add "Not read", p

type
  TableRow* = object
    ## One row of a header table: a field, with a value per column; or a
    ## block's title.
    title*: string ## a block's title: the row says only that; "" for a field
    description*: string ## the field in plain words
    name*: string ## its name as parseSEG gives it: block.field
    bytes*: string ## the bytes it takes in its block, from 1: "1-4"
    offset*: string ## the file offset of its first byte (the first column's)
    values*: seq[string] ## per column; "" where a column has no such field
    differs*: bool ## the columns do not all hold the same value
    joined*: seq[bool]
      ## per column, a value a geometry join gave (not the header's); empty
      ## for a header's field

  FieldTable* = object
    ## A header table: fields as rows, a column of values per header shown
    ## (a trace, a channel set; one for a file's or a record's blocks).
    columns*: seq[string] ## each value column's label
    rows*: seq[TableRow]

func bytesOf(r: FieldRow): string =
  if r.last <= r.first: $r.first else: $r.first & "-" & $r.last

func fieldTable*(columns: openArray[seq[FieldRow]]; labels: openArray[string];
    standard: SeismicKind; byBlock = true): FieldTable =
  ## The rows of `columns` (each a header listing, in its order) side by
  ## side: a row per field (per block and field with `byBlock`, else per
  ## field whatever its block, as for channel sets), in the order the
  ## fields first come, with a title row where the block changes (with
  ## `byBlock`); `differs` where the columns' values are not all the same.
  result = FieldTable(columns: @labels)
  var place: Table[string, int]
  var lastBlock = ""
  for c, rows in columns:
    for r in rows:
      let key = (if byBlock: r.blockName else: "") & "." & r.field
      var k = place.getOrDefault(key, -1)
      if k < 0:
        if byBlock and r.blockName != lastBlock:
          result.rows.add TableRow(title: blockTitle(r.blockName, standard) & " (" &
            r.blockName & ", " & $r.blockSize & " bytes at " & $r.blockOffset & ")")
          lastBlock = r.blockName
        k = result.rows.len
        place[key] = k
        result.rows.add TableRow(description: r.description,
          name: (if r.field.len > 0: r.blockName & "." & r.field else: r.blockName),
          bytes: bytesOf(r), offset: $r.offset, values: newSeq[string](columns.len))
      result.rows[k].values[c] = r.value
  if columns.len > 1:
    for row in result.rows.mitems:
      if row.title.len == 0:
        for v in row.values:
          if v != row.values[0]: row.differs = true

func tableText*(t: FieldTable; column = -1): string =
  ## The table as text, a line per row, tab-separated: the description and
  ## the values (only those of `column` when it is not -1), as Copy puts it
  ## on the clipboard.
  for row in t.rows:
    if row.title.len > 0: result.add row.title & '\n'
    else:
      result.add row.description
      for c, v in row.values:
        if column < 0 or c == column: result.add '\t' & v
      result.add '\n'

func dumpLines*(bytes: openArray[byte]): int =
  ## The lines of a block's bytes, 16 a line.
  (bytes.len + 15) div 16

func dumpLine*(bytes: openArray[byte]; base: int64; line: int): string =
  ## Line `line` of `bytes` (a block that starts at file offset `base`): its
  ## offset in hexadecimal, its 16 bytes in hexadecimal and as text, a dot
  ## for what is not printable ASCII.
  let a = line * 16
  result = toHex(base + a, 8) & "  "
  var text = ""
  for i in a ..< a + 16:
    if i < bytes.len:
      result.add toHex(bytes[i]) & ' '
      text.add (if bytes[i] in 0x20'u8 .. 0x7E'u8: char(bytes[i]) else: '.')
    else: result.add "   "
    if i == a + 7: result.add ' '
  result.add ' ' & text

func traceLabel*(d: TraceDetail; withFile: bool): string =
  ## A trace's column: "Trace 13" (its place in its file, from 1), its
  ## channel when its headers give one, and its file's name with
  ## `withFile` (columns of several files).
  result = (if withFile: d.file & " " else: "") & "Trace " & $(d.trace + 1)
  if not d.keys.channel.isNaN and d.keys.channel > 0:
    result.add " (ch " & exactText(d.keys.channel) & ")"

func manyFiles*(traces: openArray[TraceDetail]): bool =
  ## Whether `traces` are of more than one file.
  for d in traces:
    if d.file != traces[0].file: return true
  false

const
  JoinedTitle* = "Joined from the survey files"
    ## the title of the trace table's rows of joined values: not in the
    ## trace's header, whose own fields follow
  JoinedKeys = [(jgSourceStation, "srcLine", "Source line"),
    (jgSourceStation, "srcPoint", "Source point"),
    (jgSourceStation, "srcIndex", "Source point index"),
    (jgReceiverStation, "rcvLine", "Receiver line"),
    (jgReceiverStation, "rcvPoint", "Receiver point"),
    (jgReceiverStation, "rcvIndex", "Receiver point index"),
    (jgSourceXy, "srcX", "Source X"), (jgSourceXy, "srcY", "Source Y"),
    (jgSourceZ, "srcZ", "Source elevation"),
    (jgReceiverXy, "rcvX", "Receiver X"), (jgReceiverXy, "rcvY", "Receiver Y"),
    (jgReceiverZ, "rcvZ", "Receiver elevation"),
    (jgDerived, "offset", "Offset, source to receiver"),
    (jgDerived, "cmpX", "Midpoint X"), (jgDerived, "cmpY", "Midpoint Y"),
    (jgComponent, "component", "Component")]
    ## the keys a join may give, by the group parseSEG marks them in

func keyText(k: TraceKeys; name: string): string =
  ## Key `name` of `k` as text; "" when not known.
  func number(x: float64): string = (if x.isNaN: "" else: exactText(x))
  case name
  of "srcLine": number(k.srcLine)
  of "srcPoint": number(k.srcPoint)
  of "srcIndex": $k.srcIndex
  of "rcvLine": number(k.rcvLine)
  of "rcvPoint": number(k.rcvPoint)
  of "rcvIndex": $k.rcvIndex
  of "srcX": number(k.srcX)
  of "srcY": number(k.srcY)
  of "srcZ": number(k.srcZ)
  of "rcvX": number(k.rcvX)
  of "rcvY": number(k.rcvY)
  of "rcvZ": number(k.rcvZ)
  of "offset": number(k.offset)
  of "cmpX": number(k.cmpX)
  of "cmpY": number(k.cmpY)
  of "component": $k.component
  else: ""

func traceStandard(traces: openArray[TraceDetail]): SeismicKind =
  ## The standard of the traces' header blocks (the first listed).
  result = skSegy
  for d in traces:
    if d.rows.len > 0:
      case d.rows[0].kind
      of hbSegdTrace, hbSegdExt1, hbSegdExt1Rev3: return skSegd
      of hbSeg2Trace: return skSeg2
      else: return skSegy

func traceTable*(traces: openArray[TraceDetail]): FieldTable =
  ## The Trace tab's Header table: a value column per trace whose header
  ## fields were read, the fields that differ between them marked; first,
  ## when a geometry join gave some of their keys, a row per key it gave
  ## (in the groups it gave to any of them, `JoinedKeys`), each value from
  ## the keys, marked `joined` where the join gave it to that trace.
  let withFile = traces.manyFiles
  var columns: seq[seq[FieldRow]]
  var labels: seq[string]
  var shown: seq[int] # the traces with columns
  for k, d in traces:
    if d.rows.len > 0:
      columns.add d.rows
      labels.add traceLabel(d, withFile)
      shown.add k
  result = fieldTable(columns, labels, traceStandard(traces))
  var groups: set[JoinGroup]
  for k in shown: groups.incl traces[k].joined
  if groups == {}: return
  var rows = @[TableRow(title: JoinedTitle)]
  for (group, name, words) in JoinedKeys:
    if group in groups:
      var row = TableRow(description: words, name: "keys." & name,
        values: newSeq[string](shown.len), joined: newSeq[bool](shown.len))
      for c, k in shown:
        row.values[c] = keyText(traces[k].keys, name)
        row.joined[c] = group in traces[k].joined
      for v in row.values:
        if v != row.values[0]: row.differs = true
      rows.add row
  rows.add result.rows
  result.rows = move rows

func listed(numbers: openArray[int]): string =
  ## "13", "13 and 14", "13, 14 and 20".
  for k, n in numbers:
    if k > 0: result.add(if k == numbers.high: " and " else: ", ")
    result.add $n

proc chosenLine*(st: AppState; followPointer: bool): string =
  ## The line at the top of the Trace tab: which traces it shows and what
  ## chose them, or how to choose one.
  let c = st.inspection.chosen
  var files: seq[string]
  var numbers: seq[int]
  for t in c.traces:
    let i = st.findTrace(t)
    if i >= 0:
      if st.sessions[i].name notin files: files.add st.sessions[i].name
      numbers.add t - st.sessions[i].base + 1
  let ofFile = if files.len == 1: " of " & files[0] else: ""
  let traces = if numbers.len == 1: "Trace " & $numbers[0] & ofFile
               elif numbers.len <= 8: "Traces " & listed(numbers) & ofFile
               else: $numbers.len & " traces" & ofFile & " (" & $numbers[0] & " to " &
                 $numbers[^1] & ")"
  result = case c.by
    of cbNone:
      if followPointer: "No trace is selected or under the pointer: point at a trace in the " &
        "plot or a receiver on the map, or click one to keep it here."
      else: "No trace is selected: click a trace in the plot, or a receiver on the map, to " &
        "see it here (Follow the pointer is off)."
    of cbSelection: traces & ", selected."
    of cbPlotPointer: traces & ", pointed at in the plot."
    of cbMapPointer: traces & ", recorded at the receiver pointed at on the map."
  if c.total > c.traces.len:
    result.add " The first " & $c.traces.len & " of the " & $c.total & " are shown: at most " &
      $MaxInspected & " side by side."

func sampleText*(x: float32): string =
  ## A sample in its shortest form.
  $x

func dataText*(traces: openArray[TraceDetail]; column = -1): string =
  ## The Data tab's table as text, a line per sample, tab-separated: the
  ## index, the time in ms and each trace's sample (only trace `column`'s
  ## when it is not -1), as Copy puts it on the clipboard.
  var n = 0
  for d in traces: n = max(n, d.samples.len)
  if traces.len == 0: return
  let (dt, t0) = (traces[0].dtMs, traces[0].t0Ms)
  for i in 0 ..< n:
    result.add $i & '\t' & exactText(t0 + float64(i) * dt)
    for c, d in traces:
      if column < 0 or c == column:
        result.add '\t'
        if i < d.samples.len: result.add sampleText(d.samples[i])
    result.add '\n'

func summaryText*(lines: openArray[SummaryLine]): string =
  ## The lines as text, as Copy puts them on the clipboard: a heading on a
  ## line of its own, a value after its label and a tab.
  for l in lines:
    if l.heading:
      if result.len > 0: result.add '\n'
      result.add l.label & '\n'
    else: result.add l.label & '\t' & l.value & '\n'
