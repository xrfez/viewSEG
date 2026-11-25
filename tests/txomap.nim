## Relation records are found by station, never by record number, on the
## map: X records (a source's receivers) serve a shot, O records (a
## receiver's shots) a receiver gather, both loaded at once.
##
## - a listed shot whose FFID is another source's X record number but whose
##   source station is its own is placed at its station; with no station and
##   no place in its headers it is placed nowhere (its FFID names no X record);
## - a receiver gather's points on the map come from the O records of its
##   receiver station while the X records are loaded too;
## - a station with two X records plans the union of their receivers;
## - a station with two O records likewise.
##
## Seen to fail (with the old code): the FFID placed the shot "with no
## station" at source 1/3, and the station-named shot with FFID of source 0/0
## was placed at both; the receiver gather's points were the receivers and
## source of the X record numbered by its trace record (the shot's, not its
## sources); the station's spread had the lowest record's receivers only.

import std/[math, os, sets, tables]
import parseSEG
import viewSEG/core/[state, shots, spread]
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

proc loaded(st: var AppState; paths: varargs[string]): bool =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)
  st.settle(st.jobs.active.len == 0 and st.survey.layers.len >= paths.len)

proc show(st: var AppState; path: string): bool =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  st.settle(st.sessions.len > 0 and st.sessions[^1].path == path.expandFilename and
    st.survey.findTraces(st.sessions[^1].id) >= 0 and st.jobs.active.len == 0)

proc sourceAt(st: AppState; line, k: int): PointRef =
  for i in 0 ..< st.survey.layers.len:
    template l: untyped = st.survey.layers[i]
    if l.origin == loSurveyFile:
      let p = l.stationPoint(prSource, Station(line: MapSrcLines[line],
        point: 1001 + float64(k), index: 1))
      if p >= 0: return PointRef(layer: l.id, role: prSource, point: p)
  doAssert false, "no source " & $line & "/" & $k

proc main*() =

  block shotByStation:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      doAssert st.loaded(sps.s, sps.r, fx.mapXps, fx.mapOps)
      let a = st.sourceAt(0, 0)
      let b = st.sourceAt(1, 3)
      var x: ShotIndex
      for f in ["a.sgy", "b.sgy"]: x.files[f] = FileShots(path: f)
      # FFID = the X record number of source 0/0, station = source 1/3.
      x.matchOne(st.survey, "a.sgy", ShotOf(gather: 0, record: float64(mapRecord(0, 0)),
        source: StationKey(line: MapSrcLines[1], point: 1004, index: 1), hasStation: true,
        x: NaN, y: NaN))
      doAssert x.shotsAt(b).len == 1, "placed at its station"
      doAssert x.shotsAt(a).len == 0, "not at the source whose X record has its number"
      # No station and no place: the FFID finds no X record.
      x.matchOne(st.survey, "b.sgy", ShotOf(gather: 0, record: float64(mapRecord(1, 3)),
        hasStation: false, x: NaN, y: NaN))
      doAssert x.pointRefs.len == 1 and x.shotsAt(b).len == 1,
        "the FFID placed a shot: " & $x.shotsAt(b).len

  block receiverGatherFromO:
    withFixtures fx:
      let sps = fx.mapSps()
      var st = initAppState()
      doAssert st.loaded(sps.s, sps.r, fx.mapXps, fx.mapOps)
      doAssert st.show(fx.mapReceiverSegy(1, 4))
      doAssert st.shownDomain == rdReceiver
      let pts = st.activePoints
      var g = initSurveyGeometry()
      g.addSps(fx.mapOps)
      let rcv = stationKey(MapRcvLines[1], 105, 1)
      var want: HashSet[StationKey]
      for r in g.recordsAt(rcv, rdReceiver):
        for run in g.relationRuns(r, rdReceiver):
          for i in 0 ..< run.stations: want.incl run.station(i)
      doAssert want.len > 0
      var got: HashSet[StationKey]
      for p in pts[prSource]:
        let i = st.survey.find(p.layer)
        if st.survey.layers[i].origin == loSurveyFile:
          got.incl stationKeyOf(st.survey.layers[i].points[prSource].station[p.point])
      doAssert got == want, "sources of the O records: " & $got.len & " of " & $want.len

  block unionOfRecords:
    withFixtures fx:
      let sps = fx.mapSps()
      # Two X records at source 1/1 (a reshoot): receivers 101 .. 105 and
      # 111 .. 115 of line 100; the X file's record numbers 7 and 9.
      var xf = SpsFile(headers: @[SpsHeader(code: "00",
        description: "SPS format version num.", data: "SPS 2.1;")])
      for (rec, first) in [(7'i64, 101.0), (9'i64, 111.0)]:
        xf.relations.add SpsRelation(fieldRecord: rec, recordIncrement: 1,
          instrumentCode: '1', srcLine: MapSrcLines[0], srcPoint: 1001, srcIndex: 1,
          fromChannel: 1, toChannel: 5, channelIncrement: 1, rcvLine: MapRcvLines[0],
          fromReceiver: first, toReceiver: first + 4, rcvIndex: 1)
      let path = fx.dir / "two.x"
      doAssert writeSps(xf, path).len == 0
      var st = initAppState()
      doAssert st.loaded(sps.s, sps.r, path)
      let s = st.survey.plannedSpread(st.spreads, rdSource,
        stationKey(MapSrcLines[0], 1001, 1))
      doAssert s.stations == 10 and s.places.len == 10, "the union: " & $s.stations
      doAssert s.record == 7

  echo "txomap: ok"

when isMainModule:
  main()
