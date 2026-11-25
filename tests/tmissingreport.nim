## The missing-station report: a tally takes one record at a time and gives the
## stations some record lacks (line, point, in how many records) and the
## figures: stations in the template, found, missing and the percent, and the
## same counted per record. A station is one line and point whatever its
## components; a multi-record or multi-file tally adds one to Missing each
## time another record lacks the station. A stable sort and RFC 4180 CSV.
##
## Seen to fail: with a missing count that did not go up for a lost station,
## `two_records_one_station_each` rejected missing 1 for 2; with the percent
## taken of the found stations, `percent_of_the_template` rejected 100 for 50.

import std/strutils
import parseSEG
import processSEG/qc/record
import viewSEG/core/missingreport

proc st(line, point: float64): StationKey = stationKey(line, point, 1)

proc template4(): seq[StationKey] =
  for p in 1 .. 4: result.add st(10, float64(p))

proc rec(expected: seq[StationKey]; lost: openArray[int]): RecordCompleteness =
  ## A record whose template is `expected` and that lacks the points `lost`.
  result = RecordCompleteness(xpsRecord: 1, expected: expected.len)
  for s in expected:
    if int(s.point) in lost: result.missingStations.add s
  result.missing = result.missingStations.len
  result.present = result.expected - result.missing

proc rowAt(rows: openArray[StationRow]; point: float64): StationRow =
  for r in rows:
    if r.point == point: return r
  doAssert false, "no station " & $point

proc main*() =
  block empty_tally:
    let r = initTally(ssReceivers).report
    doAssert r.rows.len == 0 and r.stats.inTemplate == 0 and r.stats.records == 0
    doAssert r.stats.percentMissing == 0 and r.stats.percentMissingInRecords == 0
    doAssert stationsCsv(r.rows) == "line,point,missing\n"

  block percent_of_the_template:
    var t = initTally(ssReceivers)
    t.noteFile()
    t.addRecord(template4(), rec(template4(), [3, 4]))
    let r = t.report
    doAssert r.stats.inTemplate == 4 and r.stats.found == 2 and r.stats.missing == 2
    doAssert r.stats.percentMissing == 50.0, $r.stats.percentMissing
    doAssert r.stats.files == 1 and r.stats.records == 1
    doAssert r.rows.len == 2 and r.rows[0].point == 3 and r.rows[1].point == 4

  block two_records_one_station_each:
    ## Two records with the same four template stations: the template and the
    ## found stations are counted once, the per-record figures twice.
    var t = initTally(ssReceivers)
    t.noteFile()
    t.addRecord(template4(), rec(template4(), [4]))
    t.addRecord(template4(), rec(template4(), [1, 4]))
    let s = t.report.stats
    doAssert s.inTemplate == 4 and s.found == 3 and s.missing == 2, $s
    doAssert s.expectedInRecords == 8 and s.presentInRecords == 5 and
      s.missingInRecords == 3, $s
    doAssert s.percentMissingInRecords == 37.5, $s.percentMissingInRecords

  block missing_goes_up_with_each_record:
    var t = initTally(ssSources, derived = true)
    for lost in [@[4], @[3, 4], @[4]]:
      t.noteFile()
      t.addRecord(template4(), rec(template4(), lost))
    let r = t.report
    doAssert r.rows.rowAt(4).missing == 3 and r.rows.rowAt(3).missing == 1, $r.rows
    doAssert r.stats.files == 3 and r.stats.derived and r.stats.side == ssSources

  block a_station_counts_once_whatever_its_traces:
    ## 1C, 3C and 4C records: the library counts one station for the traces
    ## of its components, and the tally takes its figures as they are.
    for components in [1, 3, 4]:
      var keys: seq[TraceKeys] = @[]
      for p in 1 .. 3:
        for c in 1 .. components:
          var k = initTraceKeys()
          k.record = 1
          k.rcvLine = 10
          k.rcvPoint = float64(p)
          k.rcvIndex = 1
          k.component = uint8(c)
          k.status = tsLive
          keys.add k
      var g = SurveyGeometry()
      var x = initSpsRelation()
      x.recordType = 'X'
      x.fieldRecord = 1
      x.srcLine = 1
      x.srcPoint = 1
      x.srcIndex = 1
      x.fromChannel = 1
      x.toChannel = 4
      x.channelIncrement = 1
      x.rcvLine = 10
      x.fromReceiver = 1
      x.toReceiver = 4
      x.rcvIndex = 1
      g.addSps(SpsFile(relations: @[x]), rdSource)
      var stations: seq[StationKey] = @[]
      for run in g.relationRuns(1):
        for i in 0 ..< run.stations: stations.add run.station(i)
      var counts = newSeq[int](keys.len)
      let c = g.recordCompleteness(rowsOf(keys, counts), rmFieldRecord)
      doAssert c.expected == 4 and c.present == 3 and c.missing == 1,
        $components & "C: " & $c
      var t = initTally(ssReceivers)
      t.addRecord(stations, c)
      let s = t.report.stats
      doAssert s.inTemplate == 4 and s.found == 3 and s.missing == 1, $components & "C: " & $s
      doAssert s.expectedInRecords == 4 and s.presentInRecords == 3, $components & "C: " & $s

  block sort_ties_and_descending:
    var rows = @[StationRow(line: 1, point: 5, missing: 2),
      StationRow(line: 1, point: 3, missing: 2), StationRow(line: 0, point: 9, missing: 1)]
    sortStations(rows, @[(column: scMissing, descending: true)])
    doAssert rows[0].point == 5 and rows[1].point == 3 and rows[2].point == 9, $rows
    sortStations(rows, @[(column: scLine, descending: false),
      (column: scPoint, descending: true)])
    doAssert rows[0].point == 9 and rows[1].point == 5 and rows[2].point == 3, $rows

  block csv_quotes:
    let rows = @[StationRow(line: 1, point: 1.5, missing: 2)]
    doAssert stationsCsv(rows) == "line,point,missing\n1,1.5,2\n", stationsCsv(rows)
    var t = initTally(ssReceivers)
    t.addRecord(template4(), rec(template4(), [2]))
    let text = statsCsv(t.report.stats)
    doAssert text.startsWith("stations,files,records,inTemplate,found,missing,percentMissing,"),
      text
    doAssert "receivers,0,1,4,3,1,25," in text, text

  echo "tmissingreport: ok"

when isMainModule:
  main()
