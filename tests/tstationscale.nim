## Line and point numbers a SEG-Y file stores times 100 (its textual header says
## so), read through the shipped vendor map `segy-x100-stations.nif`, on a
## synthetic Rev 0 file:
##
## - opened with the map loaded, the keys hold the numbers themselves: whole
##   numbers whole (519, not 519.0000000001), a fraction kept (100.5 stored as
##   10050), and the map's source and receiver lines and points join the
##   survey's stations by number (no trace is left to the record and channel
##   relations, which can give another shot);
## - opened with no map, the keys hold no station, as before;
## - the numbers are shown as whole numbers when whole, with decimals only when
##   the value has a fraction (the headers' trace table text);
## - `openSession` reads a file with the maps in force (`publishVendors`).
##
## Seen to fail: with the division in parseSEG's `segykeys.read` removed, "the source
## line is 100 times too large"; with `OpenOptions.vendors` not passed by `openOptions`,
## "the source line is NaN" with the map.
import std/[os, strutils]
import parseSEG
import viewSEG/core/[filejobs, headers, join, openchoice, session, survey, vendormaps]
import utils/[fixtures]

const
  Sentence = "C37 SOURCE AND RECEIVER LINE AND POINT NUMBERS ARE X 100 IN TRACE HEADERS"
  MapPath = currentSourcePath().parentDir.parentDir / "vendormaps" / "segy-x100-stations.nif"
  Stored = [[10000, 31600, 51900, 13600], [10000, 31700, 51900, 10050]]
    ## per trace: receiver line, receiver point, source line, source point, times 100

proc put(b: var seq[byte], at, bytes, v: int) =
  for k in 0 ..< bytes: b[at + k] = byte((v shr (8 * (bytes - 1 - k))) and 0xFF)

proc writeFile100(path: string) =
  ## Big-endian Rev 0, IEEE float, one sample per trace.
  var b = newSeq[byte](3600 + Stored.len * 244)
  for i, c in Sentence: b[i] = byte(c)
  b.put(3216, 2, 2000)
  b.put(3220, 2, 1)
  b.put(3224, 2, 5)
  for t, s in Stored:
    let at = 3600 + t * 244
    b.put(at, 4, t + 1)
    b.put(at + 114, 2, 1)
    b.put(at + 116, 2, 2000)
    for k in 0 .. 3: b.put(at + 180 + 4 * k, 4, s[k])
  var text = newString(b.len)
  for i, c in b: text[i] = char(c)
  writeFile(path, text)

proc surveyOf(): SurveyGeometry =
  result = initSurveyGeometry()
  var s, r = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")])
  for (line, point) in [(519.0, 136.0), (519.0, 100.5)]:
    s.points.add SpsPoint(kind: pkSource, line: line, point: point, index: 1, code: "G1",
      easting: 1000, northing: 2000, elevation: 10, dayOfYear: -1, hour: -1, minute: -1, second: -1)
  for point in [316.0, 317.0]:
    r.points.add SpsPoint(kind: pkReceiver, line: 100, point: point, index: 1, code: "G1",
      easting: 1500, northing: 2500, elevation: 10, dayOfYear: -1, hour: -1, minute: -1,
      second: -1)
  result.addSps(s)
  result.addSps(r)

proc main*() =
  withFixtures fx:
    let path = fx.dir / "x100.sgy"
    writeFile100(path)
    var reg: VendorRegistry
    reg.addMap loadVendorMap(readFile(MapPath), MapPath)

    block with_the_map:
      var f = openSeismic(path, keys = true, opts = openOptions(OpenChoice(), "", reg))
      let (a, b) = (f.index.keys[0], f.index.keys[1])
      doAssert a.srcLine == 519.0, "the source line is " & $a.srcLine
      doAssert a.srcPoint == 136.0 and a.rcvLine == 100.0 and a.rcvPoint == 316.0
      doAssert b.srcPoint == 100.5, "a fraction is kept: " & $b.srcPoint
      doAssert exactText(a.srcLine) == "519" and exactText(a.rcvPoint) == "316", "whole numbers whole"
      doAssert exactText(b.srcPoint) == "100.5"
      let plan = planJoin(addr f, surveyOf(), JoinOptions(), proc (d, n: int): bool = true)
      doAssert plan.headerStations[prSource] == 2 and plan.headerStations[prReceiver] == 2
      doAssert plan.found[prSource] == 2 and plan.found[prReceiver] == 2, $plan.found
      doAssert plan.matched == 2, $plan.matched
      f.close()

    block other_phrase_no_map:
      # "CDP COORDINATES ARE X 100": not about line and point numbers: read as without
      var raw = readFile(path)
      let at = raw.find(Sentence)
      let other = "C37 CDP COORDINATES ARE X 100 IN TRACE HEADERS"
      for i in 0 ..< Sentence.len: raw[at + i] = (if i < other.len: other[i] else: ' ')
      let p2 = fx.dir / "cdp100.sgy"
      writeFile(p2, raw)
      var f = openSeismic(p2, keys = true, opts = openOptions(OpenChoice(), "", reg))
      doAssert f.index.keys[0].srcLine.isNaN and not f.index.vendorLayout
      f.close()

    block no_map_as_before:
      var f = openSeismic(path, keys = true, opts = openOptions(OpenChoice(), "", VendorRegistry()))
      doAssert f.index.keys[0].srcLine.isNaN and f.index.keys[0].rcvPoint.isNaN
      f.close()

    block published_maps:
      publishVendors(reg)
      var s = openSession(path, cache = "", choice = OpenChoice())
      doAssert s.file.index.keys[0].srcLine == 519.0, "openSession reads the published maps"
      s.filePtr[].close()
      publishVendors(VendorRegistry())
  echo "tstationscale: ok"

when isMainModule:
  main()
