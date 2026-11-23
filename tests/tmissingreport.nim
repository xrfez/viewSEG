## The missing-trace report: rows, folder points, totals from `summarize`,
## duplicate counts, a stable multi-column sort, and RFC 4180 CSV.
##
## Seen to fail: with a record's missing text left empty, `ranges_text`
## rejected the blank ranges; with `never` forced false, `never_vs_in_one`
## rejected the station missing in every record; with `expected` taken from
## 0 instead of `summarize`, `totals_match_summarize` rejected the totals;
## with a duplicate count stored as 0, `duplicates_are_a_count` rejected the
## count; with equal rows reversed instead of kept, `sort_ties_and_descending`
## rejected the earlier row; with CSV fields written raw, `csv_quotes`
## rejected the path that holds a comma; with `never` left as
## `missingIn == expectedIn` and `expectedUnknown` left false when a record
## has no spread, `expected_unknown_without_spread` rejected the station.

import std/strutils
when defined(release):
  import std/[monotimes, times]
import parseSEG
import processSEG/qc/record
import viewSEG/core/missingreport

proc put(line: var string; at: int; text: string) =
  let i = at - 1
  for j, c in text:
    if i + j < line.len: line[i + j] = c

proc xRec(record, fromCh, toCh, rcvLine, fromR, toR: int): string =
  result = repeat(' ', 80)
  result[0] = 'X'
  put(result, 2, "T1")
  put(result, 8, align($record, 8))
  put(result, 16, "11")
  put(result, 18, align("1.00", 10))
  put(result, 28, align("1.00", 10))
  put(result, 38, "1")
  put(result, 39, align($fromCh, 5))
  put(result, 44, align($toCh, 5))
  put(result, 49, "1")
  put(result, 50, align($rcvLine & ".00", 10))
  put(result, 60, align($fromR & ".00", 10))
  put(result, 70, align($toR & ".00", 10))
  put(result, 80, "1")

proc surveyOf(lines: varargs[string]): SurveyGeometry =
  const H00 = "H00 SPS format version number   SPS 2.1;"
  result.addSps(parseSps(H00 & "\n" & lines.join("\n")))

proc stationsOf(g: SurveyGeometry; record: int64): seq[StationKey] =
  for run in g.relationRuns(record):
    for i in 0 ..< run.stations:
      result.add run.station(i)

proc rec(ffid: float64; xps: int64; expected, present, missing, unlisted,
    duplicates: int; missingStations: seq[StationKey] = @[];
    missingRanges: seq[StationRange] = @[]): RecordCompleteness =
  RecordCompleteness(fieldRecord: ffid, xpsRecord: xps, expected: expected,
    present: present, missing: missing, unlisted: unlisted, duplicates: duplicates,
    missingStations: missingStations, missingRanges: missingRanges)

proc pointAt(rows: openArray[PointRow]; line, point: float64): PointRow =
  for r in rows:
    if r.line == line and r.point == point: return r
  doAssert false, "no point " & $line & ":" & $point

proc main*() =
  let none = SurveyGeometry()

  block empty_input:
    let r = missingReport([], none)
    doAssert r.records.len == 0 and r.recordPoints.len == 0 and r.points.len == 0
    doAssert r.duplicates.len == 0 and r.totals.files == 0 and r.totals.records == 0
    doAssert r.totals.expected == 0 and r.totals.percentMissing == 0
    doAssert r.totals.xpsWithoutData.len == 0
    doAssert r.records.len == 0
    doAssert recordsCsv(r.records).splitLines[^1].len == 0
    doAssert recordsCsv(r.records).startsWith("file,record,expected,")

  block one_complete_record:
    let c = rec(7, -1, 4, 4, 0, 0, 0)
    let r = missingReport([FileRecords(path: "a.sgy", records: @[c])], none)
    doAssert r.records.len == 1 and r.records[0].file == "a.sgy"
    doAssert r.records[0].record == 7 and r.records[0].missing == 0
    doAssert r.records[0].missingPoints.len == 0
    doAssert r.recordPoints.len == 0 and r.points.len == 0 and r.duplicates.len == 0
    doAssert r.totals.files == 1 and r.totals.records == 1 and r.totals.present == 4

  block ranges_text:
    let ranges = @[
      StationRange(line: 100, firstPoint: 101, lastPoint: 103, count: 3),
      StationRange(line: 100, firstPoint: 110, lastPoint: 110, count: 1),
      StationRange(line: 200, firstPoint: 5, lastPoint: 6, count: 2)]
    let st = @[stationKey(100, 101, 1)]
    let c = rec(1, -1, 5, 1, 4, 0, 0, st, ranges)
    let r = missingReport([FileRecords(path: "shot.sgy", records: @[c])], none)
    doAssert r.records[0].missingPoints == "100 101-103, 110\n200 5-6",
      r.records[0].missingPoints

  block same_record_number_two_files:
    let a = rec(12, -1, 1, 0, 1, 0, 0, @[stationKey(1, 1, 1)])
    let b = rec(12, -1, 1, 1, 0, 0, 0)
    let r = missingReport([
      FileRecords(path: "east/a.sgy", records: @[a]),
      FileRecords(path: "west/b.sgy", records: @[b])], none)
    doAssert r.records.len == 2
    doAssert r.records[0].file == "east/a.sgy" and r.records[0].record == 12
    doAssert r.records[1].file == "west/b.sgy" and r.records[1].record == 12
    doAssert r.points.len == 1 and r.points[0].missingIn == 1
    doAssert r.points[0].firstFile == "east/a.sgy"

  block extras_are_a_count:
    let c = rec(3, -1, 2, 2, 0, 4, 0)
    let r = missingReport([FileRecords(path: "a.sgy", records: @[c])], none)
    doAssert r.records[0].unlisted == 4
    doAssert r.recordPoints.len == 0 and r.points.len == 0
    doAssert r.totals.extras == 4

  block duplicates_are_a_count:
    let c = rec(9, -1, 2, 2, 0, 0, 3)
    let r = missingReport([FileRecords(path: "a.sgy", records: @[c])], none)
    doAssert r.duplicates.len == 1
    doAssert r.duplicates[0].file == "a.sgy" and r.duplicates[0].record == 9
    doAssert r.duplicates[0].count == 3
    doAssert r.totals.duplicates == 3
    doAssert "count" in r.duplicatesNote and "not which stations" in r.duplicatesNote
    doAssert "not which stations" in totalsCsv(r.totals)
    let quiet = rec(1, -1, 1, 1, 0, 0, 0)
    doAssert missingReport([FileRecords(path: "a.sgy", records: @[quiet])],
      none).duplicates.len == 0

  block never_vs_in_one:
    let g = surveyOf(xRec(1, 1, 2, 100, 101, 102), xRec(2, 1, 2, 100, 101, 102),
      xRec(9, 1, 1, 100, 201, 201))
    let spread = stationsOf(g, 1)
    doAssert spread.len == 2, "the X record did not parse: " & $spread.len
    let both = rec(1, 1, 2, 0, 2, 0, 0, spread)
    let one = rec(2, 2, 2, 1, 1, 0, 0, @[spread[0]])
    let r = missingReport([
      FileRecords(path: "a.sgy", records: @[both]),
      FileRecords(path: "b.sgy", records: @[one])], g)
    let gone = pointAt(r.points, spread[0].line, spread[0].point)
    let half = pointAt(r.points, spread[1].line, spread[1].point)
    doAssert gone.expectedIn == 2 and gone.missingIn == 2 and gone.never,
      "station missing in every record that expected it"
    doAssert not gone.expectedUnknown and not half.expectedUnknown
    doAssert half.expectedIn == 2 and half.missingIn == 1 and not half.never,
      "station missing in one record"
    doAssert gone.firstFile == "a.sgy" and gone.lastFile == "b.sgy"
    doAssert gone.firstRecord == 1 and gone.lastRecord == 2
    doAssert r.points[0].never, "never sorts first"
    doAssert r.totals.never == 1
    doAssert r.recordPoints.len == 3

  block totals_match_summarize:
    let g = surveyOf(xRec(1, 1, 1, 100, 101, 101), xRec(4, 1, 1, 100, 109, 109))
    let c = rec(1, 1, 1, 0, 1, 2, 5, stationsOf(g, 1))
    let files = [
      FileRecords(path: "a.sgy", records: @[c]),
      FileRecords(path: "empty.sgy", records: @[])]
    let r = missingReport(files, g)
    var light: seq[RecordCompleteness]
    for f in files:
      for row in f.records: light.add row
    let s = summarize(g, light)
    doAssert r.totals.records == s.records and r.totals.expected == s.expected
    doAssert r.totals.present == s.present and r.totals.missing == s.missing
    doAssert r.totals.duplicates == s.duplicates and r.totals.extras == s.unlisted
    doAssert r.totals.xpsWithoutData == s.xpsWithoutData
    doAssert r.totals.xpsWithoutData == @[4'i64]
    doAssert r.totals.files == 2 and s.records == 1
    doAssert r.totals.percentMissing == 100
    doAssert r.totals.never == 1

  block sort_ties_and_descending:
    var rows = @[
      RecordRow(file: "b", record: 2, missing: 1, unlisted: 0),
      RecordRow(file: "a", record: 2, missing: 5, unlisted: 1),
      RecordRow(file: "a", record: 2, missing: 5, unlisted: 9),
      RecordRow(file: "a", record: 10, missing: 0, unlisted: 0)]
    sortRecords(rows, @[(column: rsMissing, descending: true),
      (column: rsFile, descending: false)])
    doAssert rows[0].file == "a" and rows[0].unlisted == 1, "earlier tie stays first"
    doAssert rows[1].file == "a" and rows[1].unlisted == 9
    doAssert rows[2].file == "b" and rows[2].missing == 1
    doAssert rows[3].record == 10
    sortRecords(rows, @[(column: rsRecord, descending: true),
      (column: rsFile, descending: false)])
    doAssert rows[0].record == 10
    doAssert rows[1].file == "a" and rows[1].unlisted == 1
    doAssert rows[2].file == "a" and rows[2].unlisted == 9
    doAssert rows[3].file == "b"
    var points = @[
      PointRow(line: 2, point: 1, missingIn: 1, never: true),
      PointRow(line: 1, point: 2, missingIn: 5, never: true),
      PointRow(line: 1, point: 1, missingIn: 5, never: true),
      PointRow(line: 1, point: 9, missingIn: 9, never: false)]
    sortPoints(points, DefaultPointSort)
    doAssert points[0].never and points[0].line == 1 and points[0].point == 1
    doAssert points[1].point == 2 and points[1].missingIn == 5
    doAssert points[2].line == 2 and points[2].never
    doAssert not points[3].never and points[3].missingIn == 9

  block csv_quotes:
    let path = "line 1, \"east\".sgy"
    let c = rec(1, -1, 1, 0, 1, 0, 0, @[stationKey(1, 2, 1)],
      @[StationRange(line: 1, firstPoint: 2, lastPoint: 2, count: 1)])
    let r = missingReport([FileRecords(path: path, records: @[c])], none)
    let csv = recordsCsv(r.records)
    doAssert "\"line 1, \"\"east\"\".sgy\"" in csv, csv
    doAssert csv.endsWith("\n") and '\r' notin csv
    doAssert recordPointsCsv(r.recordPoints).splitLines[1] ==
      "\"line 1, \"\"east\"\".sgy\",1,1,2,1"
    let quoted = pointsCsv(r.points)
    doAssert "\"line 1, \"\"east\"\".sgy\"" in quoted
    doAssert quoted.startsWith("line,point,index,expectedIn,missingIn,never,expectedUnknown,")

  block expected_unknown_without_spread:
    let bare = rec(1, -1, 1, 0, 1, 0, 0, @[stationKey(10, 20, 1)])
    let again = rec(2, -1, 1, 0, 1, 0, 0, @[stationKey(10, 20, 1)])
    let otherIdx = rec(2, -1, 1, 0, 1, 0, 0, @[stationKey(10, 20, 2)])
    let bareReport = missingReport([
      FileRecords(path: "a.sgy", records: @[bare]),
      FileRecords(path: "b.sgy", records: @[again, otherIdx])], none)
    doAssert bareReport.points.len == 2 and bareReport.totals.never == 0
    var seen1 = false
    var seen2 = false
    for p in bareReport.points:
      doAssert p.line == 10 and p.point == 20
      doAssert p.expectedIn == 0 and not p.never and p.expectedUnknown
      if p.index == 1:
        doAssert p.missingIn == 2
        seen1 = true
      elif p.index == 2:
        doAssert p.missingIn == 1
        seen2 = true
    doAssert seen1 and seen2
    let csv = pointsCsv(bareReport.points)
    doAssert csv.startsWith("line,point,index,expectedIn,missingIn,never,expectedUnknown,")
    doAssert "false,true" in csv
    let g = surveyOf(xRec(1, 1, 1, 100, 101, 101))
    let st = stationsOf(g, 1)[0]
    let unmatched = rec(9, 9, 1, 0, 1, 0, 0, @[st])
    let noSpread = missingReport([FileRecords(path: "a.sgy", records: @[unmatched])], g)
    let u = pointAt(noSpread.points, st.line, st.point)
    doAssert u.expectedIn == 0 and u.missingIn == 1 and not u.never and u.expectedUnknown
    doAssert noSpread.totals.never == 0
    let present = rec(1, 1, 1, 1, 0, 0, 0)
    let listed = rec(2, -1, 1, 0, 1, 0, 0, @[st])
    let mixed = missingReport([
      FileRecords(path: "shot.sgy", records: @[present]),
      FileRecords(path: "loose.sgy", records: @[listed])], g)
    let m = pointAt(mixed.points, st.line, st.point)
    doAssert m.expectedIn == 1 and m.missingIn == 1 and not m.never and m.expectedUnknown
    doAssert mixed.totals.never == 0
    let goneOnly = rec(1, 1, 1, 0, 1, 0, 0, @[st])
    let quiet = rec(2, -1, 0, 0, 0, 0, 0)
    let still = missingReport([
      FileRecords(path: "a.sgy", records: @[goneOnly]),
      FileRecords(path: "b.sgy", records: @[quiet])], g)
    let s = pointAt(still.points, st.line, st.point)
    doAssert s.expectedIn == 1 and s.missingIn == 1 and s.never and not s.expectedUnknown
    doAssert still.totals.never == 1
    let frac = stationKey(100.5, 10.25, 1)
    let fracReport = missingReport([FileRecords(path: "f.sgy", records: @[
      rec(3, -1, 1, 0, 1, 0, 0, @[frac]),
      rec(4, -1, 1, 0, 1, 0, 0, @[frac])])], none)
    doAssert fracReport.points.len == 1 and fracReport.points[0].missingIn == 2
    doAssert fracReport.points[0].line == frac.line and fracReport.points[0].point == frac.point
    doAssert fracReport.points[0].index == 1 and fracReport.points[0].expectedUnknown
    doAssert not fracReport.points[0].never
    let late = stationKey(5, 200, 1)
    let early = stationKey(5, 100, 1)
    let otherLine = stationKey(6, 100, 1)
    let ordered = missingReport([FileRecords(path: "a.sgy", records: @[
      rec(1, -1, 3, 0, 3, 0, 0, @[late, early, otherLine])])], none)
    doAssert ordered.points.len == 3
    doAssert pointAt(ordered.points, 5, 200).missingIn == 1
    doAssert pointAt(ordered.points, 5, 100).missingIn == 1
    doAssert pointAt(ordered.points, 6, 100).index == 1 and
      pointAt(ordered.points, 6, 100).expectedUnknown
    let far = stationKey(1, 200_000, 1)
    let near = stationKey(1, 1, 1)
    let wide = missingReport([FileRecords(path: "w.sgy", records: @[
      rec(1, -1, 2, 0, 2, 0, 0, @[far, near]),
      rec(2, -1, 2, 0, 2, 0, 0, @[near, far])])], none)
    doAssert wide.points.len == 2
    doAssert pointAt(wide.points, 1, 1).missingIn == 2 and
      pointAt(wide.points, 1, 200_000).missingIn == 2
    doAssert pointAt(wide.points, 1, 1).expectedUnknown

  when defined(release):
    block scale:
      const nRecords = 10_000
      const nStations = 5_000
      var missing = newSeq[StationKey](nStations)
      for i in 0 ..< nStations:
        missing[i] = stationKey(1, float64(i + 1), 1)
      let ranges = @[StationRange(line: 1, firstPoint: 1, lastPoint: float64(nStations),
        count: nStations)]
      var records = newSeq[RecordCompleteness](nRecords)
      for i in 0 ..< nRecords:
        records[i] = RecordCompleteness(fieldRecord: float64(i + 1), xpsRecord: -1,
          expected: nStations, present: 0, missing: nStations,
          missingStations: missing, missingRanges: ranges)
      let files = [FileRecords(path: "folder/line.sgy", records: records)]
      let t0 = getMonoTime()
      var report = missingReport(files, none)
      let built = (getMonoTime() - t0).inMilliseconds
      let t1 = getMonoTime()
      sortRecords(report.records, @[(column: rsMissing, descending: true),
        (column: rsRecord, descending: false)])
      sortPoints(report.points, DefaultPointSort)
      let sorted = (getMonoTime() - t1).inMilliseconds
      doAssert report.records.len == nRecords
      doAssert report.points.len == nStations
      doAssert report.recordPoints.len == nRecords * nStations
      echo "scale: build ", built, " ms, sort ", sorted, " ms, records ",
        nRecords, " stations ", nStations

when isMainModule:
  main()
