## Trace-quality table: one row per station (line and point), a stable
## multi-column sort, a text filter, the components a station lacks, the figures in
## words, and RFC 4180 CSV. No files are read.
##
## Seen to fail: with `bad` left uncounted, `rows_counts_across_components_and_files`
## rejected a station bad count of 0. With the component left out of the station
## key's merge (a row for each component), `rows_counts_across_components_and_files`
## saw 4 rows. With the lacking set computed from the first file's notes only,
## `a_station_lacking_a_component_is_listed_and_counted` saw no lacking station.

import std/[assertions, math, strutils]
import processSEG/qc/amplitude
import viewSEG/core/missingreport except StationRow, StationSortColumn, SortSpec
import viewSEG/core/qualityreport
import viewSEG/view/qualitywords

proc add(b: var QualityBuild; file: string; line, point: float64; component: uint8;
    findings: set[Finding]; killed = false) =
  b.addTrace(TraceNote(file: file, line: line, point: point, component: component,
    killed: killed, findings: findings))

func sameNum(a, b: float64): bool =
  a == b or (a != a and b != b)

proc stationAt(rows: openArray[StationRow]; line, point: float64): StationRow =
  for r in rows:
    if sameNum(r.line, line) and sameNum(r.point, point): return r
  doAssert false, "no station " & $line & ":" & $point

proc main*() =
  block findings_drop_weak_and_noisy:
    doAssert findingsOf({afWeak, afNoisy, afDead}, false) == {qfAllZero}
    doAssert findingsOf({afClipped, afSpiky, afWeak}, false) == {qfClipped, qfSpiky}
    doAssert findingsOf({afDead, afConstant, afNonFinite}, true) == {qfHeaderDead}
    doAssert findingsOf({}, true) == {qfHeaderDead}
    doAssert findingsOf({}, false) == {}

  block rows_counts_across_components_and_files:
    var b = initQualityBuild()
    add(b, "one.sgd", 10, 1, 1, {qfAllZero})
    add(b, "one.sgd", 10, 1, 1, {qfAllZero, qfClipped})
    add(b, "one.sgd", 10, 1, 1, {qfAllZero})
    add(b, "one.sgd", 10, 1, 1, {qfClipped})
    add(b, "one.sgd", 10, 1, 1, {qfSpiky})
    add(b, "one.sgd", 10, 1, 2, {qfConstant})
    add(b, "one.sgd", 10, 2, 1, {})
    add(b, "one.sgd", 20, 1, 1, {qfAllZero}, killed = true)
    add(b, "one.sgd", 20, 1, 1, {qfHeaderDead})
    add(b, "two.sgd", 10, 1, 1, {qfDcOffset})
    let report = qualityReport(b)
    doAssert report.stations.len == 3, "a row for each component: " & $report.stations.len
    let zero = stationAt(report.stations, 10, 1)
    doAssert zero.seen == 7, $zero.seen
    doAssert zero.bad == 7, $zero.bad
    doAssert zero.killed == 0
    doAssert zero.counts[qfAllZero] == 3, $zero.counts[qfAllZero]
    doAssert zero.counts[qfClipped] == 2, $zero.counts[qfClipped]
    doAssert zero.counts[qfSpiky] == 1 and zero.counts[qfConstant] == 1
    doAssert zero.counts[qfDcOffset] == 1
    doAssert zero.counts[qfHeaderDead] == 0
    doAssert zero.components == {1'u8, 2'u8}
    let clean = stationAt(report.stations, 10, 2)
    doAssert clean.seen == 1 and clean.bad == 0
    let killed = stationAt(report.stations, 20, 1)
    doAssert killed.seen == 2 and killed.killed == 1 and killed.bad == 1, $killed
    doAssert killed.counts[qfAllZero] == 0
    doAssert killed.counts[qfHeaderDead] == 1
    let t = report.totals
    doAssert t.files == 2 and t.stations == 3 and t.badStations == 2, $t
    doAssert t.traces == 10 and t.killed == 1 and t.bad == 8, $t
    doAssert t.counts[qfAllZero] == 3 and t.counts[qfHeaderDead] == 1
    doAssert t.counts[qfClipped] == 2 and t.counts[qfConstant] == 1

  block a_station_lacking_a_component_is_listed_and_counted:
    # three components in the data; station 10:1 has all three, 10:2 has 1 and 3, 10:3 has 2
    var b = initQualityBuild()
    for c in 1'u8 .. 3'u8: add(b, "a.sgd", 10, 1, c, {})
    add(b, "a.sgd", 10, 2, 1, {})
    add(b, "a.sgd", 10, 2, 3, {})
    # a station with one component of a.sgd's three lacks the others there; the same
    # station in b.sgd and c.sgd (files of one component) lacks nothing
    add(b, "a.sgd", 10, 3, 2, {})
    add(b, "c.sgd", 10, 3, 3, {})
    let report = qualityReport(b)
    doAssert stationAt(report.stations, 10, 1).lacking == {}
    doAssert stationAt(report.stations, 10, 2).lacking == {2'u8}, $report.stations
    doAssert stationAt(report.stations, 10, 2).lackFiles == 1
    doAssert stationAt(report.stations, 10, 3).lacking == {1'u8, 3'u8}
    doAssert stationAt(report.stations, 10, 3).lackFiles == 1
    doAssert report.totals.lacking == 2 and report.totals.components == 3, $report.totals
    let lines = statisticLines(report.totals, ssReceivers, false)
    doAssert "2 receiver stations lack a component (of 3 components)" in lines, $lines
    doAssert "2 receiver stations lack a component in at least one file (of 3 components)" in
      statisticLines(report.totals, ssReceivers, true)
    doAssert stationsCsv(report.stations).splitLines[2].startsWith("10,2,2,1,2,"),
      stationsCsv(report.stations)
    doAssert filterStations(report.stations, "10 2").len == 1
    var rows = report.stations
    sortStations(rows, @[(column: ssLacking, descending: true)])
    doAssert rows[0].point == 3, $rows

  block single_component_files_among_three_component_files_flag_nobody:
    # Seen to fail: with the components taken as the union over the files, the stations of
    # b.sgd and c.sgd (one component each) were flagged as lacking two.
    var b = initQualityBuild()
    for c in 1'u8 .. 3'u8:
      add(b, "three.sgd", 10, 1, c, {})
    add(b, "one.sgd", 10, 2, 1, {})
    add(b, "other.sgd", 10, 3, 2, {})
    let report = qualityReport(b)
    doAssert report.totals.lacking == 0, $report.stations
    for r in report.stations: doAssert r.lacking == {} and r.lackFiles == 0, $r

  block a_station_lacking_in_two_of_three_files_counts_two:
    # Seen to fail: with the count left at 1 per station, this saw 1.
    var b = initQualityBuild()
    for file in ["a.sgd", "b.sgd", "c.sgd"]:
      add(b, file, 10, 1, 1, {})
      add(b, file, 10, 1, 2, {})
      add(b, file, 10, 3, 1, {})
      add(b, file, 10, 3, 2, {})
      # station 10:2 has both components in c.sgd, only component 1 in a and b
      add(b, file, 10, 2, 1, {})
      if file == "c.sgd": add(b, file, 10, 2, 2, {})
    let report = qualityReport(b)
    let two = stationAt(report.stations, 10, 2)
    doAssert two.lackFiles == 2 and two.lacking == {2'u8}, $two
    doAssert stationAt(report.stations, 10, 1).lackFiles == 0
    doAssert report.totals.lacking == 1, $report.totals

  block a_component_at_one_station_is_not_the_files:
    # Seen to fail: with every component any station has counted, the hundred stations of
    # three components were flagged as lacking the fourth.
    var b = initQualityBuild()
    for p in 1 .. 100:
      for c in 1'u8 .. 3'u8: add(b, "a.sgd", 10, float64(p), c, {})
    add(b, "a.sgd", 10, 50, 4, {}) # one hydrophone on one node
    let report = qualityReport(b)
    doAssert report.totals.lacking == 0 and report.totals.components == 3, $report.totals
    var c = initQualityBuild()
    for p in 1 .. 100:
      add(c, "a.sgd", 10, float64(p), 1, {})
      add(c, "a.sgd", 10, float64(p), 2, {})
      if p != 7: add(c, "a.sgd", 10, float64(p), 3, {})
    let flagged = qualityReport(c)
    doAssert flagged.totals.lacking == 1, $flagged.totals
    doAssert stationAt(flagged.stations, 10, 7).lacking == {3'u8}

  block memory_per_station_does_not_grow_with_the_files:
    # Seen to fail: with each station keeping its components of every file, the build at
    # 400 files held about four times what it did at 100.
    proc held(files: int): int =
      var b = initQualityBuild()
      let before = getOccupiedMem()
      for f in 0 ..< files:
        var part = initQualityBuild()
        for p in 1 .. 200:
          for c in 1'u8 .. 3'u8:
            if p != 3 or c != 2: add(part, "file" & $f & ".sgd", 10, float64(p), c, {})
        b.absorb part
      doAssert qualityReport(b).totals.lacking == 1
      result = getOccupiedMem() - before
    let small = held(100)
    let large = held(400)
    doAssert large < small * 3 div 2 + 200_000, "100 files " & $small & " bytes, 400 files " &
      $large

  block unknown_station_is_not_a_station:
    var b = initQualityBuild()
    add(b, "a.sgd", 3, NaN, 1, {qfAllZero})
    add(b, "a.sgd", NaN, 5, 1, {qfAllZero})
    add(b, "a.sgd", NaN, NaN, 1, {qfAllZero})
    add(b, "a.sgd", 10, 1, 1, {})
    let report = qualityReport(b)
    doAssert report.stations.len == 2, $report.stations
    let unknown = report.stations[1]
    doAssert unknown.isUnknown and unknown.seen == 3 and unknown.lineText == "unknown", $unknown
    doAssert report.totals.stations == 1 and report.totals.badStations == 0 and
      report.totals.traces == 4 and report.totals.bad == 3, $report.totals
    doAssert "Receiver stations with a bad trace: 0 of 1 (0%)" in
      statisticLines(report.totals, ssReceivers, false)
    doAssert stationsCsv(report.stations).splitLines[2].startsWith("unknown,,"),
      stationsCsv(report.stations)

  block one_component_has_nothing_to_lack:
    var b = initQualityBuild()
    add(b, "a.sgd", 10, 1, 1, {})
    add(b, "a.sgd", 10, 2, 1, {})
    let report = qualityReport(b)
    doAssert report.totals.lacking == 0 and report.totals.components == 1
    for line in statisticLines(report.totals, ssReceivers, false):
      doAssert "lack" notin line, line

  block unknown_station:
    var b = initQualityBuild()
    add(b, "a.sgd", NaN, NaN, 1, {qfNonFinite})
    add(b, "a.sgd", NaN, NaN, 1, {qfNonFinite})
    add(b, "a.sgd", NaN, NaN, 2, {})
    add(b, "a.sgd", 10.004, 2, 1, {})
    add(b, "a.sgd", 10, 2, 1, {})
    let report = qualityReport(b)
    let unknown = stationAt(report.stations, NaN, NaN)
    doAssert unknown.seen == 3 and unknown.bad == 2, $unknown.seen
    doAssert stationAt(report.stations, 10, 2).seen == 2
    doAssert report.stations.len == 2
    doAssert report.totals.stations == 1

  block sort_ties_and_nan:
    var b = initQualityBuild()
    add(b, "b.sgd", 2, 1, 1, {qfAllZero})
    add(b, "b.sgd", 2, 1, 1, {qfClipped})
    add(b, "a.sgd", 1, 1, 1, {qfAllZero})
    add(b, "a.sgd", NaN, 5, 1, {})
    let report = qualityReport(b)
    doAssert report.stations[0].line == 1 and report.stations[1].line == 2
    doAssert report.stations[^1].line != report.stations[^1].line
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
    add(b, "Shot,1.sgd", 10, 1.5, 3, {qfClipped})
    add(b, "other.sgd", 11, 2, 1, {})
    let report = qualityReport(b)
    doAssert filterStations(report.stations, "") == @[0, 1]
    doAssert filterStations(report.stations, "   ") == @[0, 1]
    let hit = filterStations(report.stations, "10 1.5")
    doAssert hit.len == 1 and report.stations[hit[0]].point == 1.5
    doAssert filterStations(report.stations, "1.5 11").len == 0

  block csv_quotes:
    var b = initQualityBuild()
    add(b, "Shot,1.sgd", 10, 1, 1, {qfAllZero})
    add(b, "Shot,1.sgd", 10, 1, 1, {qfAllZero})
    add(b, "two.sgd", 10, 1, 1, {qfClipped})
    let report = qualityReport(b)
    let stations = stationsCsv(report.stations)
    doAssert stations.splitLines[0].startsWith("line,point,lacking components,files lacking,seen,"), stations
    doAssert stations.splitLines[1].startsWith("10,1,,0,3,0,3,"), stations
    for line in stations.splitLines:
      doAssert "sgd" notin line, "a file name in a station row: " & line
    let totals = totalsCsv(report.totals)
    doAssert totals.startsWith("files,traces,killed,bad,stations,"), totals
    doAssert "\n2,3,0,3,1,1,0," in totals, totals

  block noisy_and_weak_counts_and_empty_cells:
    var b = initQualityBuild()
    proc noted(b: var QualityBuild; file: string; point: float64;
        noisyTested, weakTested, noisy, weak: bool; killed = false) =
      b.addTrace(TraceNote(file: file, line: 10, point: point, component: 1,
        killed: killed, findings: {}, noisyTested: noisyTested,
        weakTested: weakTested, noisy: noisy, weak: weak))
    b.noted("a.sgd", 1, true, true, true, false)
    b.noted("a.sgd", 1, true, true, false, true)
    b.noted("a.sgd", 1, true, true, false, false)
    b.noted("a.sgd", 1, true, true, true, true, killed = true) # killed: never counted
    b.noted("a.sgd", 1, false, true, false, true) # inside the area: tested for weak only
    b.noted("b.sgd", 2, false, false, false, false) # not tested: empty cells
    b.noted("d.sgd", 4, false, true, false, true) # only its noisy cell is empty
    let report = qualityReport(b)
    let a = stationAt(report.stations, 10, 1)
    doAssert a.noisyTested == 3 and a.noisy == 1 and a.weakTested == 4 and a.weak == 2 and
      a.bad == 0, $a
    let c = stationAt(report.stations, 10, 2)
    doAssert c.noisyTested == 0 and c.weakTested == 0 and c.noisy == 0 and c.weak == 0, $c
    let t = report.totals
    doAssert t.noisyTested == 3 and t.noisy == 1 and t.weakTested == 5 and t.weak == 3 and
      t.bad == 0, $t
    let lines = stationsCsv(report.stations).splitLines
    doAssert lines[0].endsWith(",tested (noisy),noisy,tested (weak),weak"), lines[0]
    doAssert lines[1].endsWith(",3,1,4,2") and lines[2].endsWith(",0,,0,") and
      lines[3].endsWith(",0,,1,1"), $lines
    doAssert totalsCsv(report.totals).splitLines[1].endsWith(",3,1,5,3,0")
    let words = statisticLines(t, ssReceivers, true)
    doAssert "Noisy: 1 of 3 tested (33.33%)" in words and "Weak: 3 of 5 tested (60%)" in words,
      $words
    var rows = report.stations
    sortStations(rows, @[(column: ssNoisy, descending: true)])
    doAssert rows[0].point == 1, "an untested station sorts before every count"
    sortStations(rows, @[(column: ssWeakTested, descending: false)])
    doAssert rows[0].point == 2 and rows[1].point == 4, $rows
    var empty = initQualityBuild()
    empty.noted("c.sgd", 3, false, false, false, false)
    doAssert totalsCsv(qualityReport(empty).totals).splitLines[1].endsWith(",0,,0,,0")
    for line in statisticLines(qualityReport(empty).totals, ssReceivers, false):
      doAssert "Noisy" notin line and "Weak" notin line, line

  block the_statistics_lines_in_words:
    var b = initQualityBuild()
    add(b, "a.sgd", 10, 1, 1, {qfAllZero, qfConstant})
    add(b, "a.sgd", 10, 1, 1, {}, killed = true)
    add(b, "a.sgd", 10, 2, 1, {})
    add(b, "b.sgd", 10, 3, 1, {qfHeaderDead})
    add(b, "b.sgd", 10, 4, 1, {})
    let t = qualityReport(b).totals
    doAssert statisticLines(t, ssReceivers, true) == @[
      "Receiver stations in the files: 4",
      "Traces: 5, 1 killed, 4 measured",
      "Bad traces: 2 (50% of the measured)",
      "Receiver stations with a bad trace: 2 of 4 (50%)",
      "Dead: 1, all zero: 1, constant: 1, clipped: 0, spiky: 0, DC offset: 0, not finite: 0"],
      $statisticLines(t, ssReceivers, true)
    doAssert statisticLines(t, ssSources, false)[0] == "Source stations in the file: 4"
    doAssert countsLine(t, true) == "2 files, 5 traces" and countsLine(t, false) == "5 traces"

  block one_word_per_quantity_in_headers_and_statistics:
    # Seen to fail: with ColSeen back at "Seen", or one header's tip left empty, this block
    # failed.
    for name in [ColSeen, ColKilled, ColBad, ColHeaderDead, ColAllZero, ColConstant,
        ColClipped, ColSpiky, ColDcOffset, ColNonFinite, ColNoisyTested, ColNoisy,
        ColWeakTested, ColWeak, ColLine, ColPoint, ColLacking]:
      doAssert headerTip(name).len > 0, name & " has no tooltip"

  block absorbing_a_part_is_adding_its_notes_one_by_one:
    proc notes(b: var QualityBuild; file: string) =
      b.add file, 10, 1, 1, {qfClipped}
      b.add file, 10, 1, 1, {}
      b.add file, 10, 2, 2, {qfAllZero, qfSpiky}
      b.add file, 10, 3, 1, {}, killed = true
    var whole = initQualityBuild()
    var joined = initQualityBuild()
    whole.notes "a.sgd"
    whole.notes "b.sgd"
    joined.notes "a.sgd"
    var part = initQualityBuild()
    part.notes "b.sgd"
    joined.absorb part
    doAssert qualityReport(joined) == qualityReport(whole), $qualityReport(joined)
    doAssert qualityReport(joined).totals.files == 2

when isMainModule:
  main()
