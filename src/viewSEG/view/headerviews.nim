## What the Headers window shows, as plain lines and tables: the Summary
## tab's lines (`core/properties`, exported here), the header tables
## (`fieldTable`: a row per field, a column of values per header, the values
## that differ between columns marked),
## and the lines of a block's bytes (`dumpLine`). Made from `core` (a
## session's `facts`, its records, the inspector's answers), never from the
## toolkit, so that any frontend shows the same words.

import std/[math, strutils, tables]
import parseSEG
import ../core/[properties, state]

export properties

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

const MaxSideBySide* = 64
  ## value columns a header table shows side by side, at most (Dear ImGui
  ## takes fewer than 512 columns; a SEG-D record may have 65 535 channel
  ## sets a scan type): more come a page at a time (`pageOf`)

func pageOf*(columns, page: int): Slice[int] =
  ## The value columns of `columns` that page `page` shows, `MaxSideBySide`
  ## a page (the last page for one past it).
  let last = max(0, (columns - 1) div MaxSideBySide)
  let first = clamp(page, 0, last) * MaxSideBySide
  first ..< min(columns, first + MaxSideBySide)

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
  ## on the clipboard; first a line naming the columns.
  result = "Description"
  for c, label in t.columns:
    if column < 0 or c == column: result.add '\t' & label
  result.add '\n'
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
  # eight hex digits, more past 4 GiB
  var digits = 8
  while digits < 16 and (base + a) shr (4 * digits) != 0: inc digits
  result = toHex(base + a, digits) & "  "
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
  JoinedTitle* = "From the survey"
    ## the title of the trace table's rows of values from the survey (an
    ## import): not in the trace's header, whose own fields follow
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
  ## Key `name` of `k` as text, to the thousandth (a millimetre, or a
  ## thousandth of a foot); "" when not known.
  func number(x: float64): string =
    if x.isNaN: ""
    elif x == round(x): exactText(x)
    else: formatFloat(x, ffDecimal, 3).strip(leading = false, chars = {'0'})
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

const MaxCopiedValues* = 200_000
  ## samples a copy of the Data tab's table takes at most: the text (about
  ## 3 MB) is made on the UI thread, in the frame of the click, in about
  ## 20 ms; a copy of more traces than that takes their first rows

func copiedRows*(rows, columns: int): int =
  ## The rows a copy of the Data tab's table of `rows` rows takes, with
  ## `columns` columns of samples: all of them, unless that would be more
  ## than `MaxCopiedValues` samples.
  min(rows, max(1, MaxCopiedValues div max(columns, 1)))

func dataText*(traces: openArray[TraceDetail]; column = -1): string =
  ## The Data tab's table as text, a line per sample, tab-separated: the
  ## index, the time in ms and each trace's sample (only trace `column`'s
  ## when it is not -1), as Copy puts it on the clipboard; first a line
  ## naming the columns, as the table's header row does. At most
  ## `MaxCopiedValues` samples: the first rows (`copiedRows`).
  if traces.len == 0: return
  var rows = 0
  for d in traces: rows = max(rows, d.samples.len)
  let n = copiedRows(rows, if column >= 0: 1 else: traces.len)
  let withFile = traces.manyFiles
  result = "Index\tTime (ms)"
  for c, d in traces:
    if column < 0 or c == column:
      result.add '\t' & traceLabel(d, withFile) & (if d.displayed: " as displayed" else: "")
  result.add '\n'
  let (dt, t0) = (traces[0].dtMs, traces[0].t0Ms)
  for i in 0 ..< n:
    result.add $i & '\t' & exactText(t0 + float64(i) * dt)
    for c, d in traces:
      if column < 0 or c == column:
        result.add '\t'
        if i < d.samples.len: result.add sampleText(d.samples[i])
    result.add '\n'
