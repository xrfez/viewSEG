## The Headers window's trace table in `core`: what Find takes (a value, a
## range either way round, not text), the rows' order (by a column, missing
## values last, ties in the file's order, narrowed by Find), the graph's
## buckets, and the keys as columns; then the table read by the Headers
## reader (`core/inspector`) for a file shown: the record's rows with the
## columns asked (keys and header fields), only the rows asked for, sorted
## by a header field read whole, narrowed by Find, the whole file's rows, a
## graphed column, the fields the traces have for the column chooser, and a
## field the file has not said as a problem. A million values sort in a few
## seconds at most (about 2 s in a debug build).
##
## Seen to fail: with the rows sorted ascending whatever is asked
## (`orderOf` ignoring `descending`), "not sorted descending".
##
## Runs alone: it bounds the time a million rows take to sort (5 s).

import std/[algorithm, math, monotimes, os, strutils, times]
import parseSEG
import viewSEG/core/state
import utils/[fixtures, waiting]

block findTakes:
  doAssert parseFind("1001") == Find(lo: 1001, hi: 1001, valid: true)
  doAssert parseFind(" 10..20 ") == Find(lo: 10, hi: 20, valid: true)
  doAssert parseFind("20..10") == Find(lo: 10, hi: 20, valid: true), "a range given high to low"
  doAssert parseFind("0 - 500") == Find(lo: 0, hi: 500, valid: true)
  doAssert parseFind("-10 - -5") == Find(lo: -10, hi: -5, valid: true)
  doAssert parseFind("-3") == Find(lo: -3, hi: -3, valid: true)
  doAssert parseFind("2.5e-3") == Find(lo: 0.0025, hi: 0.0025, valid: true)
  doAssert not parseFind("abc").valid and not parseFind("").valid and
    not parseFind("1..2..3").valid
  let f = parseFind("100..200")
  doAssert f.matches(100) and f.matches(200) and f.matches(150.5) and not f.matches(99.9)
  doAssert not f.matches(NaN)
  doAssert parseFind("0.1").matches(0.1 + 1e-12), "a scaled value's last digits"

block rowsInOrder:
  let values = [3.0, NaN, 1.0, 3.0, 2.0]
  doAssert orderOf(values, [], false) == @[2'i32, 4, 0, 3, 1], "missing last, ties in order"
  doAssert orderOf(values, [], true) == @[0'i32, 3, 4, 2, 1], "not sorted descending"
  doAssert orderOf([], [true, false, true, false, true], false) == @[0'i32, 2, 4]
  doAssert orderOf(values, [true, true, false, true, true], false) == @[4'i32, 0, 3, 1]
  var lo, hi: seq[float64]
  bucketsOf(values, [], false, lo, hi)
  doAssert lo.len == 5 and lo[1].isNaN and hi[0] == 3
  bucketsOf(values, @[2'i32, 4, 0], true, lo, hi)
  doAssert lo == @[1.0, 2.0, 3.0]
  var many = newSeq[float64](3 * MaxGraphBuckets)
  for i, x in many.mpairs: x = float64(i)
  bucketsOf(many, [], false, lo, hi)
  doAssert lo.len == MaxGraphBuckets and lo[0] == 0 and hi[0] == 2 and hi[^1] == float64(many.high)

block aMillionRows:
  var values = newSeq[float64](1_000_000)
  for i, x in values.mpairs: x = float64((i * 7919) mod 1_000_003)
  let start = getMonoTime()
  let order = orderOf(values, [], true)
  let ms = (getMonoTime() - start).inMilliseconds
  doAssert order.len == values.len and values[order[0]] >= values[order[^1]]
  echo "ttracetable: a million rows sorted in ", ms, " ms"
  doAssert ms < 5000, $ms & " ms"

block keysAsColumns:
  var k = initTraceKeys()
  (k.record, k.channel, k.rcvPoint, k.inline, k.status) = (12.0, 3.0, 105.0, 1001.0, tsAuxiliary)
  doAssert k.keyValue("keys.record") == 12 and k.keyValue("keys.channel") == 3
  doAssert k.keyValue("keys.inline") == 1001 and k.keyValue("keys.status") == 3
  doAssert k.keyValue("keys.nope").isNaN and k.keyValue("trace.sourceX").isNaN
  doAssert keyLabel("keys.rcvPoint") == "Receiver point" and keyLabel("trace.x") == ""
  for f in DefaultTableFields: doAssert keyLabel(f).len > 0, f

proc table(st: var AppState; view: TableView): TableAnswer =
  ## The table `view` asks for, once the reader has answered it.
  st.apply Command(kind: ckInspect, inspect: {ipTable}, table: view)
  doAssert st.settle(not st.inspection.waiting and st.inspection.answer.table.view == view),
    "no answer for " & $view
  st.inspection.answer.table

block readByTheReader:
  withFixtures fx:
    let path = fx.surveySegy()
    let before = (readFile(path), getLastModificationTime(path))
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1)
    let base = st.sessions[0].gathers[1].traces.a
    var view = TableView(fields: @["keys.channel", "trace.sourceX", "keys.offset"],
      scope: tsRecord, rows: 0 .. 9)
    var a = st.table(view)
    doAssert a.problems.len == 0, $a.problems
    doAssert a.count == Channels and a.traces == base ..< base + Channels
    doAssert a.first == 0 and a.rowTraces.len == 10, "not only the rows asked: " &
      $a.rowTraces.len
    doAssert a.rowTraces[0] == base and a.values[0][0] == 1 and a.values[9][0] == 10
    doAssert a.values[0][1] > 0, "no source X"
    var names: seq[string]
    for c in a.catalogue: names.add c.name
    doAssert "keys.rcvPoint" in names and "trace.sourceX" in names, $names
    # Sorted by a header field, the largest first.
    view.sortBy = "keys.offset"
    view.descending = true
    a = st.table(view)
    for r in 1 ..< a.values.len:
      doAssert a.values[r - 1][2] >= a.values[r][2], "not sorted descending"
    # Find: channels 3 to 5, the range given high to low.
    view.findField = "keys.channel"
    view.findValue = "5..3"
    a = st.table(view)
    doAssert a.count == 3 and a.rowTraces.len == 3, $a.count
    for row in a.values: doAssert row[0] in [3.0, 4.0, 5.0]
    # The whole file, graphed by its channel.
    view = TableView(fields: @["keys.record", "keys.channel"], scope: tsFile, rows: 60 .. 100,
      graph: "keys.channel")
    a = st.table(view)
    doAssert a.count == SurveyTraces and a.first == 60 and a.rowTraces.len == SurveyTraces - 60
    doAssert a.values[0][0] == float64(FirstRecord + 2), $a.values[0]
    doAssert a.graphMin.len == SurveyTraces and a.graphMax[0] == 1 and
      a.graphMax[Channels - 1] == Channels
    # A field the traces do not have.
    view = TableView(fields: @["trace.noSuchField"], rows: 0 .. 3)
    a = st.table(view)
    doAssert a.problems.len == 1 and "trace.noSuchField" in a.problems[0], $a.problems
    doAssert a.values.len == 4 and a.values[0][0].isNaN
    st.shutdown()
    doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"

proc directKeys(path: string; names: openArray[string]): seq[seq[float64]] =
  ## Each column `names` of every trace of `path`, read from the file itself.
  var f = openSeismic(path, keys = true)
  result = newSeq[seq[float64]](names.len)
  for t in 0 ..< f.len:
    let k = f.traceKeys(t)
    for c, name in names: result[c].add keyValue(k, name)
  f.close()

block columnsOfTheSameRequest:
  # Seen to fail with the cache full (eight columns) and a sort by one new
  # column with Find on another: the index of the sort's column was taken
  # before the Find's read evicted the oldest column, so the sort and the row
  # values came from the column after it.
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let filled = ["keys.record", "keys.channel", "keys.srcPoint", "keys.srcX", "keys.srcY",
      "keys.offset", "keys.ensemble", "keys.rcvLine"]
    for name in filled:
      discard st.table(TableView(fields: @["keys.channel"], scope: tsFile, sortBy: name,
        rows: 0 .. 0))
    let fields = ["keys.channel", "keys.rcvX", "keys.cmpX"]
    let expect = directKeys(path, fields)
    var sorted = expect[2]
    sorted.sort
    let (lo, hi) = (int(sorted[3].floor), int(sorted[10].ceil))
    var kept: seq[int]
    for t in 0 ..< SurveyTraces:
      if expect[2][t] >= float64(lo) and expect[2][t] <= float64(hi): kept.add t
    let view = TableView(fields: @fields, scope: tsFile, sortBy: "keys.rcvX",
      findField: "keys.cmpX", findValue: $lo & ".." & $hi, rows: 0 .. SurveyTraces - 1)
    let a = st.table(view)
    doAssert a.problems.len == 0, $a.problems
    doAssert a.count == kept.len and a.rowTraces.len == kept.len,
      "rows kept: " & $a.count & ", " & $kept.len
    for r, t in a.rowTraces:
      doAssert t in kept, "row " & $r & " is trace " & $t & ", not kept by Find"
      for c, name in fields:
        doAssert a.values[r][c] == expect[c][t], "row " & $r & " " & name & ": " &
          $a.values[r][c] & ", the file says " & $expect[c][t]
      if r > 0:
        doAssert expect[1][a.rowTraces[r - 1]] <= expect[1][t], "not sorted by keys.rcvX"
    st.shutdown()
