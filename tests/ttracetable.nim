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
## The table's values are the fixture's known values (a record's receiver X,
## the shot's source X, the offset between them, the channel) and the very
## values the Trace tab shows for the same trace: header fields as they are
## stored (the scaled coordinates), keys as the file's keys give them
## (inline, crossline, the values a survey join gave).
##
## Seen to fail: with the source point's column reading the receiver point (`keyValue`),
## "the joined stations of row 0"; with the rows sorted ascending whatever is asked
## (`orderOf` ignoring `descending`), "not sorted descending"; with `isAnswerOf`
## not comparing the open, "the previous open's rows would show as current";
## with a column read catching only `OSError`, an `IOError` (the `fkIo` seam
## in `faultyfs`: `mappedRead` raises it, as an unmapped read that fails)
## "the whole answer was dropped"; with the cache evicting a column this
## request needs (`if c.key notin needed` changed to `if true`), "the sort's
## column was evicted"; with `closeSession` not dropping the reader's cache,
## "a closed session's columns stayed cached".
##
## Runs alone: it bounds the time a million rows take to sort (5 s).

import std/[algorithm, math, monotimes, os, strutils, times]
import parseSEG
import viewSEG/core/state
import viewSEG/view/headerviews
import utils/[faultyfs, fixtures, waiting]

block findTakes:
  doAssert parseFind("1001") == Find(lo: 1001, hi: 1001, valid: true)
  doAssert parseFind(" 10..20 ") == Find(lo: 10, hi: 20, valid: true)
  doAssert parseFind("20..10") == Find(lo: 10, hi: 20, valid: true), "a range given high to low"
  doAssert parseFind("0 - 500") == Find(lo: 0, hi: 500, valid: true)
  doAssert parseFind("-10 - -5") == Find(lo: -10, hi: -5, valid: true)
  doAssert parseFind("-3") == Find(lo: -3, hi: -3, valid: true)
  doAssert parseFind("2.5e-3").valid and parseFind("2.5e-3").lo == 0.0025
  doAssert not parseFind("abc").valid and not parseFind("").valid and
    not parseFind("1..2..3").valid
  let f = parseFind("100..200")
  doAssert f.matches(100) and f.matches(200) and f.matches(150.5) and not f.matches(99.9)
  doAssert not f.matches(NaN)
  doAssert parseFind("0.1").matches(0.1 + 1e-12), "a scaled value's last digits"
  # The tolerance is half the least step the typed text shows, whatever the
  # size of the value: an integer matches itself only. (Seen to fail with the
  # tolerance a millionth of the larger bound: "10251135" matched 10251130 and
  # 10251145.)
  let whole = parseFind("10251135")
  doAssert whole.matches(10251135) and not whole.matches(10251130) and
    not whole.matches(10251145), "an integer matched a value next to it"
  let half = parseFind("12.5")
  doAssert half.matches(12.45) and half.matches(12.54) and not half.matches(12.56) and
    not half.matches(12.44), "a value with one decimal"
  doAssert parseFind("1.50").matches(1.504) and not parseFind("1.50").matches(1.506)
  doAssert parseFind("2.5e-3").matches(0.0025 + 4e-5) and not parseFind("2.5e-3").matches(0.0025 + 1e-4)
  doAssert parseFind("1e3").matches(1000) and not parseFind("1e3").matches(1000.5)
  doAssert parseFind("100..200.5").matches(200.5) and not parseFind("100..200.5").matches(200.6)
  # Not finite: not a Find (said as one that is not a number nor a range).
  doAssert not parseFind("nan").valid and not parseFind("inf").valid and
    not parseFind("-inf").valid and not parseFind("1e400").valid
  doAssert not parseFind("1..nan").valid and not parseFind("inf..2").valid

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
    doAssert a.values[0][1] == a.values[9][1], "the shot's source X differs between its traces"
    doAssert a.values[0][1] != 0, "no source X"
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

proc rewriteChannels(path, into: string) =
  ## The survey's keys written again with the channels reversed (the same
  ## traces, the same size), into `into`, then over `path`: a file another
  ## program rewrote in place.
  var w = openSeismicWriter(into, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: rewritten"]))
  var buf = newSeq[float32](Samples)
  for shot in 0 ..< Shots:
    for channel in 1 .. Channels:
      var k = initTraceKeys()
      k.record = float64(FirstRecord + shot)
      k.channel = float64(Channels + 1 - channel)
      k.srcPoint = FirstSrcPoint + float64(shot)
      (k.srcX, k.srcY, k.srcZ) = (srcX(shot), OriginY, Elevation)
      (k.rcvX, k.rcvY, k.rcvZ) = (rcvX(channel), OriginY, Elevation)
      k.offset = abs(rcvX(channel) - srcX(shot))
      (k.t0Ms, k.intervalUs, k.status) = (0.0, DtMs * 1000, tsLive)
      for i in 0 ..< Samples: buf[i] = surveySample(shot, channel, i)
      w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log
  copyFile(into, path)

block aRewrittenFileReopened:
  # Seen to fail with the cache keyed by the path alone: the columns sorted
  # and read before the rewrite, after a reopen, were the old file's values.
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let view = TableView(fields: @["keys.channel", "keys.srcPoint"], scope: tsFile,
      sortBy: "keys.channel", rows: 0 .. SurveyTraces - 1)
    var a = st.table(view)
    doAssert a.values[0][0] == 1 and a.values[SurveyTraces - 1][0] == Channels
    rewriteChannels(path, fx.dir / "rewritten.sgy")
    let was = st.sessions[0].id # (the file shown stays until the new one has opened)
    st.apply Command(kind: ckReopen, reopenPath: path, openChoice: OpenChoice())
    doAssert st.settle(st.sessions.len == 1 and st.sessions[0].id != was and
      st.panel(MainPanel).laidOut)
    a = st.table(view)
    let now = directKeys(path, ["keys.channel"])[0]
    doAssert a.count == SurveyTraces and a.problems.len == 0, $a.problems
    for r in 0 ..< a.rowTraces.len:
      doAssert a.values[r][0] == now[a.rowTraces[r]], "row " & $r & ": " &
        $a.values[r][0] & ", the file now says " & $now[a.rowTraces[r]]
      if r > 0: doAssert a.values[r - 1][0] <= a.values[r][0], "not sorted by the new values"
    st.shutdown()

block aColumnThatFailedIsReadAgain:
  # Seen to fail: a column whose read failed kept the failure, and every later
  # request said the same ("cannot be read now") with the drive back.
  install()
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    fault(path, fkFail, {foHeaders})
    var view = TableView(fields: @[], scope: tsFile, sortBy: "keys.rcvX", rows: 0 .. 3)
    var a = st.table(view)
    doAssert a.problems.len == 1 and "keys.rcvX" in a.problems[0], $a.problems
    release(path)
    view.rows = 0 .. 4
    a = st.table(view)
    doAssert a.problems.len == 0, "the column was not read again: " & $a.problems
    let rcvX = directKeys(path, ["keys.rcvX"])[0]
    for r in 0 ..< a.rowTraces.len:
      if r > 0: doAssert rcvX[a.rowTraces[r - 1]] <= rcvX[a.rowTraces[r]], "not sorted"
    st.shutdown()

proc sawDrop(st: var AppState): bool =
  ## The reader gave up the whole answer (a warning, no rows).
  discard st.drainInbox()
  for e in st.log:
    if "could not read what it shows" in e.text: return true
  false

block anIoErrorStaysInItsColumn:
  # An unmapped read raises IOError (`fkIo`: mappedRead raises it). That is
  # one column's problem, not a dropped answer: the record headers and the
  # other columns are still there.
  install()
  withFixtures fx:
    let path = fx.twoSetSegd()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckSelect, traces: @[st.sessions[0].base], mode: smReplace)
    fault(path, fkIo, {foHeaders})
    let view = TableView(fields: @["keys.channel"], scope: tsRecord, rows: 0 .. 3)
    st.apply Command(kind: ckInspect, inspect: {ipRecord, ipTraceHeaders, ipTable}, table: view)
    doAssert waitUntil(st.sawDrop() or (not st.inspection.waiting and
      st.inspection.answer.table.problems.len > 0)), "no answer and no warning"
    doAssert not st.sawDrop(), "the whole answer was dropped"
    doAssert st.inspection.answer.record.problem.len > 0, "the record headers went with the column"
    doAssert st.inspection.answer.table.problems.len > 0, "the column was not reported"
    doAssert st.inspection.answer.traces.len > 0 and
      st.inspection.answer.traces[0].problem.len > 0, "the Trace tab went with the column"
    releaseAll()
    st.shutdown()
  releaseAll()

block aNeededColumnIsNotEvicted:
  # The cache holds 8 columns. The sort's is the oldest. Find asks for a new
  # one. The sort's column must stay: evicting it makes the reader fail
  # (indexOf -1) instead of answering.
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let cols = ["keys.record", "keys.channel", "keys.srcLine", "keys.srcPoint",
      "keys.rcvLine", "keys.rcvPoint", "keys.offset", "keys.ensemble"]
    for name in cols:
      discard st.table(TableView(fields: @[name], scope: tsFile, sortBy: name, rows: 0 .. 2))
    let oldest = cols[0]
    let fresh = "keys.srcX" # not among the eight: a new column, and every trace has one
    let view = TableView(fields: @[oldest, fresh], scope: tsFile, sortBy: oldest,
      findField: fresh, findValue: "0..1e9", rows: 0 .. 5)
    let a = st.table(view)
    doAssert a.problems.len == 0, $a.problems
    doAssert a.count > 0, "the sort's column was evicted"
    var prev = -Inf
    for row in a.values:
      doAssert row[0] >= prev, "not sorted by the oldest column: " & $a.values
      prev = row[0]
    st.shutdown()

block aClosedSessionDropsItsColumns:
  # Seen to fail: with `closeSession` not calling `dropSession`, the reader's
  # cache still held the closed open's columns.
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let id = st.sessions[0].id
    discard st.table(TableView(fields: @["keys.channel"], scope: tsFile,
      sortBy: "keys.channel", rows: 0 .. 2))
    doAssert st.cachedTraceColumns > 0, "nothing was cached"
    st.apply Command(kind: ckClose, file: id)
    doAssert st.settle(st.sessions.len == 0 and st.cachedTraceColumns == 0),
      "a closed session's columns stayed cached"
    st.shutdown()

block anAnswerOfItsTraces:
  # Seen to fail: an answer of the record shown before still counted as
  # current after the record changed (the check did not compare the traces),
  # so the rows of that record stayed on screen.
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1)
    let view = TableView(fields: @["keys.channel"], scope: tsRecord, rows: 0 .. 3)
    let one = st.table(view)
    let s = st.sessions[0]
    doAssert one.isAnswerOf(s.path, int(s.id), s.gathers[1].traces, view)
    doAssert one.session == int(s.id), "the reader did not name the open"
    doAssert not one.isAnswerOf(s.path, int(s.id), s.gathers[2].traces, view),
      "the rows of another record would show as current"
    doAssert not one.isAnswerOf(s.path, int(s.id), s.gathers[1].traces,
      TableView(fields: @["keys.channel"], scope: tsRecord, sortBy: "keys.channel",
      rows: 0 .. 3)), "another sort is current"
    # The same file, the same traces, another open: not this answer, so the
    # table says it is reading until the new open's rows arrive.
    doAssert not one.isAnswerOf(s.path, int(s.id) + 1, s.gathers[1].traces, view),
      "the previous open's rows would show as current"
    st.shutdown()

block theTraceTabAgrees:
  # The rows of the table of one record, with the survey joined, against the
  # fixture's known values and against what the Trace tab shows for the same
  # trace.
  withFixtures fx:
    let path = fx.surveySegy()
    let sps = fx.surveySps()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    var files: seq[JoinFile]
    for p in [sps.s, sps.r, sps.x]: files.add JoinFile(path: p, kind: jkSps)
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files)
    doAssert st.settle(st.joinReport.serial > 0 and st.joinUnderWay.job == NoJob)
    doAssert st.joinReport.outcome == joJoined, $st.joinReport.words
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1)
    let base = st.sessions[0].gathers[1].traces.a
    let fields = ["keys.channel", "keys.srcX", "keys.rcvX", "keys.offset", "keys.srcLine",
      "keys.srcPoint", "keys.rcvLine", "keys.rcvPoint", "keys.record", "trace.sourceX",
      "trace.groupX", "trace.coordinateScalar"]
    let a = st.table(TableView(fields: @fields, scope: tsRecord, rows: 0 .. Channels - 1))
    doAssert a.problems.len == 0, $a.problems
    doAssert a.rowTraces.len == Channels
    for r in 0 ..< Channels: # the fixture's values: shot 1, channels 1 ..
      let channel = r + 1
      doAssert a.rowTraces[r] == base + r and a.values[r][0] == float64(channel)
      doAssert a.values[r][1] == srcX(1) and a.values[r][2] == rcvX(channel),
        "row " & $r & ": " & $a.values[r]
      doAssert abs(a.values[r][3] - abs(rcvX(channel) - srcX(1))) < 1e-6, $a.values[r][3]
      doAssert a.values[r][8] == float64(FirstRecord + 1)
      doAssert a.values[r][5] == FirstSrcPoint + 1 and a.values[r][7] == FirstRcvPoint + float64(r),
        "the joined stations of row " & $r & ": " & $a.values[r][5 .. 7]
    st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders})
    for r in [0, 5, Channels - 1]:
      st.apply Command(kind: ckSelect, traces: @[base + r], mode: smReplace)
      doAssert st.settle(not st.inspection.waiting and st.inspection.answer.traces.len == 1 and
        st.inspection.answer.traces[0].id == base + r), "no Trace tab for row " & $r
      let tab = traceTable(st.inspection.answer.traces)
      var seen = 0
      for c, name in fields:
        for row in tab.rows:
          if row.name == name and row.title.len == 0:
            inc seen
            let shown = parseFloat(row.values[0])
            let tolerance = 1e-6 * max(1.0, abs(shown))
            doAssert abs(shown - a.values[r][c]) <= tolerance, "row " & $r & " " & name &
              ": the table says " & $a.values[r][c] & ", the Trace tab " & row.values[0]
      # (inline and crossline are the file's own keys: the Trace tab shows no row for them
      # here; the joined stations and the scaled header coordinates it does)
      doAssert seen >= 7, "the Trace tab had " & $seen & " of the table's fields (row " & $r & ")"
    st.shutdown()
