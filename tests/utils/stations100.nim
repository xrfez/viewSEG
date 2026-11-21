## A synthetic Rev 0 SEG-Y file whose headers carry the source and receiver
## line and point numbers times 100 (read through the shipped map
## `segy-x100-stations.nif`) and the survey's own coordinates and elevations,
## and the SPS survey that has its stations: for tests of what the project's
## survey does for such a file. Trace 3's source is not in the survey, trace
## 4 is an auxiliary trace.
import std/os
import parseSEG

const
  Sentence* = "C37 SOURCE AND RECEIVER LINE AND POINT NUMBERS ARE X 100 IN TRACE HEADERS"
  MapPath* = currentSourcePath().parentDir.parentDir.parentDir / "vendormaps" /
    "segy-x100-stations.nif"
  Stored* = [[10000, 31600, 51900, 13600, 1], [10000, 31700, 51900, 10050, 1],
    [10000, 31600, 77700, 100, 1], [10000, 31600, 51900, 13600, 4]]
    ## per trace: receiver line, receiver point, source line, source point (times
    ## 100) and the trace identification code (4: an auxiliary trace)

proc put(b: var seq[byte], at, bytes, v: int) =
  for k in 0 ..< bytes: b[at + k] = byte((v shr (8 * (bytes - 1 - k))) and 0xFF)

proc writeFile100*(path: string) =
  ## Big-endian Rev 0, IEEE float, one sample per trace.
  var b = newSeq[byte](3600 + Stored.len * 244)
  for i, c in Sentence: b[i] = byte(c)
  b.put(3216, 2, 2000)
  b.put(3220, 2, 1)
  b.put(3224, 2, 5)
  for t, s in Stored:
    let at = 3600 + t * 244
    b.put(at, 4, t + 1)
    b.put(at + 28, 2, s[4])
    b.put(at + 40, 4, 10)  # receiver and source elevation
    b.put(at + 44, 4, 10)
    b.put(at + 68, 2, 1)   # the scalars
    b.put(at + 70, 2, 1)
    b.put(at + 72, 4, 1000) # source X, Y
    b.put(at + 76, 4, 2000)
    b.put(at + 80, 4, 1500) # receiver X, Y
    b.put(at + 84, 4, 2500)
    b.put(at + 114, 2, 1)
    b.put(at + 116, 2, 2000)
    for k in 0 .. 3: b.put(at + 180 + 4 * k, 4, s[k])
  var text = newString(b.len)
  for i, c in b: text[i] = char(c)
  writeFile(path, text)

proc spsFiles(): tuple[s, r: SpsFile] =
  let head = SpsHeader(code: "00", description: "SPS format version num.", data: "SPS 2.1;")
  result = (SpsFile(headers: @[head]), SpsFile(headers: @[head]))
  for (line, point) in [(519.0, 136.0), (519.0, 100.5)]:
    result.s.points.add SpsPoint(kind: pkSource, line: line, point: point, index: 1, code: "G1",
      easting: 1000, northing: 2000, elevation: 10, dayOfYear: -1, hour: -1, minute: -1,
      second: -1)
  for point in [316.0, 317.0]:
    result.r.points.add SpsPoint(kind: pkReceiver, line: 100, point: point, index: 1,
      code: "G1", easting: 1500, northing: 2500, elevation: 10, dayOfYear: -1, hour: -1,
      minute: -1, second: -1)

proc surveyOf*(): SurveyGeometry =
  ## The survey: sources 519 / 136 and 519 / 100.5, receivers 100 / 316 and 317.
  result = initSurveyGeometry()
  let (s, r) = spsFiles()
  result.addSps(s)
  result.addSps(r)

proc writeSurveySps*(dir: string): tuple[s, r: string] =
  ## The survey's source and receiver files, SPS 2.1, in `dir`.
  result = (dir / "x100.s", dir / "x100.r")
  let (s, r) = spsFiles()
  for (f, path) in [(s, result.s), (r, result.r)]:
    let log = writeSps(f, path)
    doAssert log.len == 0, $log
