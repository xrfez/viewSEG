## Trace-quality tables: rows, compact ranges, a stable multi-column sort,
## a text filter, and RFC 4180 CSV. No files are read.
##
## Seen to fail: with `bad` left uncounted, `rows_counts_and_ranges` rejected
## a station bad count of 0.

import std/[assertions, math, strutils]
import processSEG/qc/amplitude
import viewSEG/core/qualityreport

proc add(b: var QualityBuild; file: string; record, line, point: float64;
    component: uint8; findings: set[Finding]; killed = false; index: int16 = 1) =
  b.addTrace(TraceNote(file: file, record: record, line: line, point: point,
    index: index, component: component, killed: killed, findings: findings))

func sameNum(a, b: float64): bool =
  a == b or (a != a and b != b)

proc stationAt(rows: openArray[StationRow]; line, point: float64; component: uint8;
    index: int16 = 1): StationRow =
  for r in rows:
    if sameNum(r.line, line) and sameNum(r.point, point) and r.component == component and
        r.index == index:
      return r
  doAssert false, "no station " & $line & ":" & $point & " c" & $component

proc recordAt(rows: openArray[RecordRow]; file: string; record: float64): RecordRow =
  for r in rows:
    if r.file == file and sameNum(r.record, record): return r
  doAssert false, "no record " & file & " " & $record

proc main*() =
  block findings_drop_weak_and_noisy:
    doAssert findingsOf({afWeak, afNoisy, afDead}, false) == {qfAllZero}
    doAssert findingsOf({afClipped, afSpiky, afWeak}, false) == {qfClipped, qfSpiky}
    doAssert findingsOf({afDead, afConstant, afNonFinite}, true) == {qfHeaderDead}
    doAssert findingsOf({}, true) == {qfHeaderDead}
    doAssert findingsOf({}, false) == {}

  block rows_counts_and_ranges:
    var b = initQualityBuild()
    add(b, "one.sgd", 1, 10, 1, 1, {qfAllZero})
    add(b, "one.sgd", 2, 10, 1, 1, {qfAllZero, qfClipped})
    add(b, "one.sgd", 3, 10, 1, 1, {qfAllZero})
    add(b, "one.sgd", 5, 10, 1, 1, {qfClipped})
    add(b, "one.sgd", 2.5, 10, 1, 1, {qfSpiky})
    add(b, "two.sgd", 7, 10, 1, 1, {qfDcOffset})
    add(b, "one.sgd", 1, 10, 1, 2, {qfConstant})
    add(b, "one.sgd", 4, 10, 2, 1, {})
    add(b, "one.sgd", 8, 20, 1, 1, {qfAllZero}, killed = true)
    add(b, "one.sgd", 9, 20, 1, 1, {qfHeaderDead})
    let report = qualityReport(b)
    let zero = stationAt(report.stations, 10, 1, 1)
    doAssert zero.seen == 6, $zero.seen
    doAssert zero.bad == 6, $zero.bad
    doAssert zero.killed == 0
    doAssert zero.counts[qfAllZero] == 3, $zero.counts[qfAllZero]
    doAssert zero.counts[qfClipped] == 2, $zero.counts[qfClipped]
    doAssert zero.counts[qfSpiky] == 1
    doAssert zero.counts[qfDcOffset] == 1
    doAssert zero.counts[qfHeaderDead] == 0
    doAssert zero.badRecords == "one.sgd 1-3, 5, 2.5\ntwo.sgd 7", zero.badRecords
    let other = stationAt(report.stations, 10, 1, 2)
    doAssert other.seen == 1 and other.counts[qfConstant] == 1 and other.bad == 1
    doAssert other.counts[qfAllZero] == 0
    let clean = stationAt(report.stations, 10, 2, 1)
    doAssert clean.seen == 1 and clean.bad == 0 and clean.badRecords.len == 0
    let killed = stationAt(report.stations, 20, 1, 1)
    doAssert killed.seen == 2 and killed.killed == 1 and killed.bad == 1, $killed
    doAssert killed.counts[qfAllZero] == 0
    doAssert killed.counts[qfHeaderDead] == 1
    let rec = recordAt(report.records, "one.sgd", 2)
    doAssert rec.seen == 1 and rec.bad == 1 and rec.counts[qfAllZero] == 1 and
      rec.counts[qfClipped] == 1
    let t = report.totals
    doAssert t.files == 2 and t.stations == 4 and t.records == 9, $t
    doAssert t.traces == 10 and t.killed == 1 and t.bad == 8, $t
    doAssert t.counts[qfAllZero] == 3 and t.counts[qfHeaderDead] == 1
    doAssert t.counts[qfClipped] == 2 and t.counts[qfConstant] == 1

  block components_are_not_merged:
    var b = initQualityBuild()
    add(b, "a.sgd", 1, 3, 4, 1, {qfAllZero})
    add(b, "a.sgd", 1, 3, 4, 2, {qfAllZero})
    add(b, "a.sgd", 1, 9, 4, 1, {qfAllZero})
    let report = qualityReport(b)
    doAssert report.stations.len == 3
    doAssert stationAt(report.stations, 3, 4, 1).seen == 1
    doAssert stationAt(report.stations, 3, 4, 2).seen == 1
    doAssert report.records.len == 1
    doAssert report.records[0].seen == 3 and report.records[0].counts[qfAllZero] == 3

  block unknown_station_and_record:
    var b = initQualityBuild()
    add(b, "a.sgd", NaN, NaN, NaN, 1, {qfNonFinite})
    add(b, "a.sgd", NaN, NaN, NaN, 1, {qfNonFinite}, index = 1)
    add(b, "a.sgd", NaN, NaN, NaN, 2, {})
    add(b, "a.sgd", 1, 10.004, 2, 1, {})
    add(b, "a.sgd", 1, 10, 2, 1, {})
    let report = qualityReport(b)
    let unknown = stationAt(report.stations, NaN, NaN, 1)
    doAssert unknown.seen == 2 and unknown.bad == 2, $unknown.seen
    doAssert stationAt(report.stations, NaN, NaN, 2).seen == 1
    doAssert stationAt(report.stations, 10, 2, 1).seen == 2
    doAssert report.records.len == 2
    let nanRec = recordAt(report.records, "a.sgd", NaN)
    doAssert nanRec.seen == 3 and nanRec.counts[qfNonFinite] == 2

  block sort_ties_and_nan:
    var b = initQualityBuild()
    add(b, "b.sgd", 2, 2, 1, 1, {qfAllZero})
    add(b, "b.sgd", 3, 2, 1, 1, {qfClipped})
    add(b, "a.sgd", NaN, 1, 1, 1, {qfAllZero})
    add(b, "a.sgd", 1, NaN, 5, 1, {})
    let report = qualityReport(b)
    doAssert report.stations[0].line == 1 and report.stations[1].line == 2
    doAssert report.stations[^1].line != report.stations[^1].line
    doAssert report.records[0].file == "a.sgd" and report.records[0].record == 1
    doAssert report.records[1].record != report.records[1].record
    var rows = report.stations
    sortStations(rows, @[(column: ssBad, descending: true)])
    doAssert rows[0].line == 2 and rows[0].bad == 2
    doAssert rows[1].bad == 1 and rows[2].bad == 0
    sortStations(rows, @[(column: ssBad, descending: false)])
    doAssert rows[0].bad == 0 and rows[1].bad == 1 and rows[2].bad == 2
    var tied = report.stations
    sortStations(tied, @[(column: ssKilled, descending: false)])
    doAssert tied[0].line == 1 and tied[1].line == 2
    doAssert tied[2].line != tied[2].line

  block filter_words:
    var b = initQualityBuild()
    add(b, "Shot,1.sgd", 4, 10, 1.5, 3, {qfClipped}, index = 2)
    add(b, "other.sgd", 9, 11, 2, 1, {})
    let report = qualityReport(b)
    doAssert filterStations(report.stations, "") == @[0, 1]
    doAssert filterStations(report.stations, "   ") == @[0, 1]
    let hit = filterStations(report.stations, "10 1.5")
    doAssert hit.len == 1 and report.stations[hit[0]].component == 3
    doAssert filterStations(report.stations, "SHOT").len == 1
    doAssert filterStations(report.stations, "1.5 9").len == 0
    doAssert filterRecords(report.records, "shot 4").len == 1
    doAssert filterRecords(report.records, "missing").len == 0
    doAssert filterRecords(report.records, "").len == 2

  block csv_quotes:
    var b = initQualityBuild()
    add(b, "Shot,1.sgd", 1, 10, 1, 1, {qfAllZero})
    add(b, "Shot,1.sgd", 2, 10, 1, 1, {qfAllZero})
    add(b, "two.sgd", 3, 10, 1, 1, {qfClipped})
    let report = qualityReport(b)
    let stations = stationsCsv(report.stations)
    doAssert "\"Shot,1.sgd 1-2\\ntwo.sgd 3\"" in stations or
      "\"Shot,1.sgd 1-2\ntwo.sgd 3\"" in stations, stations
    let records = recordsCsv(report.records)
    doAssert "\"Shot,1.sgd\"" in records, records
    let totals = totalsCsv(report.totals)
    doAssert totals.startsWith("files,records,traces,killed,bad,stations,")
    doAssert "\n2,3,3,0,3,1," in totals, totals

  block noisy_and_weak_counts_and_empty_cells:
    var b = initQualityBuild()
    proc noted(b: var QualityBuild; file: string; record: float64; tested, noisy, weak: bool;
        killed = false) =
      b.addTrace(TraceNote(file: file, record: record, line: 10, point: record, index: 1,
        component: 1, killed: killed, findings: {}, tested: tested, noisy: noisy, weak: weak))
    b.noted("a.sgd", 1, true, true, false)
    b.noted("a.sgd", 1, true, false, true)
    b.noted("a.sgd", 1, true, false, false)
    b.noted("a.sgd", 1, true, true, true, killed = true) # killed: never counted
    b.noted("b.sgd", 2, false, false, false) # not tested: empty cells
    let report = qualityReport(b)
    let a = recordAt(report.records, "a.sgd", 1)
    doAssert a.tested == 3 and a.noisy == 1 and a.weak == 1 and a.bad == 0, $a
    let c = recordAt(report.records, "b.sgd", 2)
    doAssert c.tested == 0 and c.noisy == 0 and c.weak == 0, $c
    let t = report.totals
    doAssert t.tested == 3 and t.noisy == 1 and t.weak == 1 and t.bad == 0, $t
    let lines = recordsCsv(report.records).splitLines
    doAssert lines[0].endsWith(",noisy,weak"), lines[0]
    doAssert lines[1].endsWith(",1,1") and lines[2].endsWith(",,"), $lines
    doAssert totalsCsv(report.totals).splitLines[1].endsWith(",1,1")
    doAssert stationsCsv(report.stations).splitLines[0].endsWith(",noisy,weak,badRecords")
    var rows = report.records
    sortRecords(rows, @[(column: rsNoisy, descending: true)])
    doAssert rows[0].file == "a.sgd", "an untested record sorts before every count"
    var empty = initQualityBuild()
    empty.noted("c.sgd", 3, false, false, false)
    doAssert totalsCsv(qualityReport(empty).totals).splitLines[1].endsWith(",,")

when isMainModule:
  main()
