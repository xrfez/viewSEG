## The Headers window's trace table: a row per trace (of the record shown, or
## of the whole file), the header fields the user chose as columns, sorted
## by any column, the rows narrowed to those whose field holds a value, a
## field graphed along the rows. What the window asks (`TableView`), what
## the Headers reader answers (`TableAnswer`, `core/inspector`), and the
## pure parts both use: the columns the file's keys give (`KeyColumns`:
## its geometry as the plot and the map use it, layout-aware inline and
## crossline and the values a survey join gave included), what a value
## typed in Find matches (`parseFind`, `matches`), the order of the rows
## (`orderOf`) and the graph's buckets (`bucketsOf`).
##
## A column is named as parseSEG names a field (`trace.sourceX`,
## `ext1.receiverLineNumber`, a SEG-2 keyword `trace.RECEIVER_LOCATION`) or
## `keys.` and a key (`keys.rcvPoint`). Only the rows on screen are read,
## unless the rows are sorted, narrowed or graphed by a header field: that
## field is then read for every row once (on the reader's thread, in steps,
## kept until the file or its keys change).

import std/[algorithm, math, strutils]
import parseSEG
import processSEG/qc/geometry
import components

type
  TableScope* = enum
    ## Which traces the table has a row for.
    tsRecord = "record" ## the record the plot shows
    tsFile = "file"     ## every trace of the file

  TableView* = object
    ## What the trace table shows, as the window asks for it.
    fields*: seq[string] ## its columns, after the trace's number
    scope*: TableScope
    sortBy*: string      ## the column sorted by; "" for the file's order
    descending*: bool
    findField*: string   ## the column Find looks in; "" for no Find
    findValue*: string   ## what it looks for: a number, or a range "a..b"
    rows*: Slice[int] = 0 .. -1
      ## the rows wanted (positions in the order shown): those on screen
      ## and some on each side
    graph*: string ## the column graphed along the rows; "" for none

  CatalogueField* = object
    ## A field a trace of the file has, for the column chooser.
    name*: string        ## as columns name it (`trace.sourceX`)
    blockName*: string   ## its block (`trace`, `ext1`, `keys`)
    description*: string ## in plain words

  TableAnswer* = object
    ## What the Headers reader read for the trace table.
    path*: string                   ## its file; "" for none
    session*: int                   ## the open it was read for (`SessionId`); a reopen is another
    traces*: Slice[int] = 0 .. -1   ## the traces of the scope (indices in the file)
    view*: TableView                ## what it answers
    count*: int                     ## the rows: the scope's traces Find keeps
    first*: int                     ## the row of `rowTraces[0]` and `values[0]`
    rowTraces*: seq[int]            ## each row read: its trace's index in the file
    values*: seq[seq[float64]]      ## each row read: a value per field (NaN for none)
    graphMin*, graphMax*: seq[float64]
      ## the graph's buckets along the rows: each the least and the most of
      ## its rows; empty for no graph
    catalogue*: seq[CatalogueField] ## the fields of the scope's first trace
    reading*: string
      ## a column being read whole for the sort, Find or the graph: the
      ## rows' order waits for it; "" when none
    done*, total*: int ## how far that read is
    problems*: seq[string] ## per column that cannot be read, why

const
  MaxGraphBuckets* = 2048 ## the graph's points along the rows, at most
  MaxTableColumns* = 32   ## the columns a table shows, at most
  ColumnStep* = 65_536    ## traces a whole column is read by, between looks for a newer request
  KeyColumns*: array[27, tuple[name, label: string]] = [
    ("keys.record", "FFID"), ("keys.channel", "Channel"),
    ("keys.channelSet", "Channel set (SEG-D, from 1)"),
    ("keys.traceCode", "Trace ID code (SEG-Y)"),
    ("keys.srcLine", "Source line"), ("keys.srcPoint", "Source point"),
    ("keys.rcvLine", "Receiver line"), ("keys.rcvPoint", "Receiver point"),
    ("keys.component", "Component"), ("keys.offset", "Offset"), ("keys.ensemble", "CDP"),
    ("keys.inline", "Inline"), ("keys.crossline", "Crossline"),
    ("keys.srcX", "Source X"), ("keys.srcY", "Source Y"), ("keys.srcZ", "Source elevation"),
    ("keys.rcvX", "Receiver X"), ("keys.rcvY", "Receiver Y"),
    ("keys.rcvZ", "Receiver elevation"), ("keys.cmpX", "Midpoint X"),
    ("keys.cmpY", "Midpoint Y"), ("keys.status", "Status (1 live, 2 dead, 3 auxiliary)"),
    ("keys.time", "Time (UTC, POSIX seconds)"), ("keys.t0Ms", "First sample (ms)"),
    ("keys.intervalUs", "Sample interval (µs)"),
    ("keys.distance", "Distance, source to receiver"),
    ("keys.offsetError", "Offset error (offset less distance)")]
    ## the columns of the file's keys, in the column chooser's order; the last two are
    ## computed from the positions (`keyValue`)
  DefaultTableFields* = ["keys.record", "keys.channel", "keys.srcLine", "keys.srcPoint",
    "keys.rcvLine", "keys.rcvPoint", "keys.offset", "keys.ensemble"]
    ## the columns of a first table

func isKey*(name: string): bool {.inline.} = name.startsWith("keys.")

func keyLabel*(name: string): string =
  ## A key column's label ("Receiver point"); "" for another name.
  for (n, label) in KeyColumns:
    if n == name: return label

func keyValue*(k: TraceKeys; name: string; channelSet = 0; lengths = true): float64 =
  ## Key column `name` of a trace's keys and channel set number `channelSet` (0
  ## for none); NaN for a name of no key, and for a value the trace lacks. The distance
  ## and the offset error (the offset's size less the distance, in the coordinates' unit)
  ## are NaN unless `lengths`: the file's offsets and coordinates are lengths of one unit
  ## (`core/geometryqc`'s `geometryUnits`).
  case name
  of "keys.channelSet": (if channelSet <= 0: NaN else: float64(channelSet))
  of "keys.traceCode": (if k.traceCode == 0: NaN else: float64(k.traceCode))
  of "keys.record": k.record
  of "keys.channel": k.channel
  of "keys.srcLine": k.srcLine
  of "keys.srcPoint": k.srcPoint
  of "keys.rcvLine": k.rcvLine
  of "keys.rcvPoint": k.rcvPoint
  of "keys.component": float64(componentOf(k))
  of "keys.offset": k.offset
  of "keys.ensemble": k.ensemble
  of "keys.inline": k.inline
  of "keys.crossline": k.crossline
  of "keys.srcX": k.srcX
  of "keys.srcY": k.srcY
  of "keys.srcZ": k.srcZ
  of "keys.rcvX": k.rcvX
  of "keys.rcvY": k.rcvY
  of "keys.rcvZ": k.rcvZ
  of "keys.cmpX": k.cmpX
  of "keys.cmpY": k.cmpY
  of "keys.status": float64(ord(k.status))
  of "keys.time": k.time
  of "keys.t0Ms": k.t0Ms
  of "keys.intervalUs": k.intervalUs
  of "keys.distance": (if lengths: checkGeometry(k).distance else: NaN)
  of "keys.offsetError": (if lengths: checkGeometry(k).offsetError else: NaN)
  else: NaN

type
  Find* = object
    ## What Find looks for, parsed: a value, or a range from `lo` to `hi`.
    ## A value matches a bound within the bound's slack: half the least step
    ## its typed text shows (`typedSlack`), never relative to its size.
    lo*, hi*: float64
    loSlack*, hiSlack*: float64
    valid*: bool

func typedSlack(text: string): float64 =
  ## Half the least step a typed number shows: half a unit of its last
  ## decimal place ("12.5": 0.05, "2.5e-3": 0.00005); 0 for an integer
  ## ("1001", "1e3").
  let t = text.strip.toLowerAscii
  let e = t.find('e')
  let mantissa = if e >= 0: t[0 ..< e] else: t
  let dot = mantissa.find('.')
  let decimals = if dot >= 0: mantissa.len - dot - 1 else: 0
  var exponent = 0
  if e >= 0:
    var digits = t[e + 1 .. ^1]
    if digits.startsWith('+'): digits = digits[1 .. ^1]
    exponent = parseInt(digits)
  let step = exponent - decimals
  if step >= 0: 0.0 else: 0.5 * pow(10.0, float64(step))

func parseFind*(text: string): Find =
  ## `text` as Find takes it: a number ("1001"), or a range ("1001..1010",
  ## "0 - 500" too, either way round); not `valid` for anything else, nor
  ## for a number that is not finite ("nan", "inf").
  let t = text.strip
  if t.len == 0: return
  var parts: seq[string]
  if ".." in t: parts = t.split("..")
  else:
    # a dash between two numbers, not a sign
    var cut = -1
    for i in 1 ..< t.len:
      if t[i] == '-' and t[i - 1] notin {'e', 'E', '-'} and cut < 0 and
          t[0 ..< i].strip.len > 0:
        cut = i
    parts = if cut > 0: @[t[0 ..< cut], t[cut + 1 .. ^1]] else: @[t]
  try:
    if parts.len == 1:
      let x = parseFloat(parts[0].strip)
      if abs(x) < Inf: # (not NaN, nor infinite)
        let slack = typedSlack(parts[0])
        result = Find(lo: x, hi: x, loSlack: slack, hiSlack: slack, valid: true)
    elif parts.len == 2:
      let (a, b) = (parseFloat(parts[0].strip), parseFloat(parts[1].strip))
      if abs(a) < Inf and abs(b) < Inf:
        let (sa, sb) = (typedSlack(parts[0]), typedSlack(parts[1]))
        result = if a <= b: Find(lo: a, loSlack: sa, hi: b, hiSlack: sb, valid: true)
                 else: Find(lo: b, loSlack: sb, hi: a, hiSlack: sa, valid: true)
  except ValueError:
    result = Find()

func matches*(f: Find; x: float64): bool {.inline.} =
  ## Whether value `x` is what `f` looks for: within each bound's slack of
  ## it (an integer bound: equal to it).
  if not f.valid or x.isNaN: return false
  x >= f.lo - f.loSlack and x <= f.hi + f.hiSlack

func orderOf*(sortBy: openArray[float64]; keep: openArray[bool]; descending: bool):
    seq[int32] =
  ## The rows in the order shown: those of `keep` (all when it is empty),
  ## by `sortBy` (the file's order when it is empty), a value missing (NaN)
  ## last either way, ties in the file's order. Indices into the scope.
  let n = max(sortBy.len, keep.len)
  result = newSeqOfCap[int32](n)
  for i in 0 ..< n:
    if keep.len == 0 or keep[i]: result.add int32(i)
  if sortBy.len > 0:
    var keyed = newSeq[tuple[x: float64; i: int32]](result.len)
    for k, i in result: keyed[k] = (sortBy[i], i)
    keyed.sort(proc (a, b: tuple[x: float64; i: int32]): int =
      if a.x.isNaN or b.x.isNaN: result = cmp(a.x.isNaN, b.x.isNaN)
      else: result = if descending: cmp(b.x, a.x) else: cmp(a.x, b.x)
      if result == 0: result = cmp(a.i, b.i))
    for k in 0 ..< keyed.len: result[k] = keyed[k].i

proc bucketsOf*(values: openArray[float64]; order: openArray[int32]; ordered: bool;
    lo, hi: var seq[float64]) =
  ## The graph's buckets: the rows (`order` when `ordered`, else every
  ## value in turn) cut into at most `MaxGraphBuckets` runs, each given the
  ## least and the most of its values (NaN for a run of none).
  let n = if ordered: order.len else: values.len
  let buckets = min(n, MaxGraphBuckets)
  lo = newSeq[float64](buckets)
  hi = newSeq[float64](buckets)
  for b in 0 ..< buckets:
    var (a, z) = (Inf, -Inf)
    for r in b * n div buckets ..< (b + 1) * n div buckets:
      let x = if ordered: values[order[r]] else: values[r]
      if not x.isNaN:
        a = min(a, x)
        z = max(z, x)
    (lo[b], hi[b]) = if a <= z: (a, z) else: (NaN, NaN)

func isAnswerOf*(answer: TableAnswer; path: string; session: int; traces: Slice[int];
    view: TableView): bool =
  ## Whether `answer` is of the open `session` of the file `path`, the traces
  ## `traces` (the scope) and the columns, scope, sort and Find of `view`:
  ## then its rows show. Another open of the same file, with the same traces,
  ## is not this answer: the window says it is reading until that open's rows
  ## arrive. The rows on screen and the graph are not compared (they change
  ## with the scroll).
  answer.path == path and answer.session == session and answer.traces == traces and
    answer.view.fields == view.fields and
    answer.view.scope == view.scope and answer.view.sortBy == view.sortBy and
    answer.view.descending == view.descending and answer.view.findField == view.findField and
    answer.view.findValue == view.findValue

func wholeColumns*(v: TableView): seq[string] =
  ## The columns the view needs for every row of the scope: the sort's,
  ## Find's and the graph's, each once.
  for name in [v.sortBy, (if parseFind(v.findValue).valid: v.findField else: ""), v.graph]:
    if name.len > 0 and name notin result: result.add name
