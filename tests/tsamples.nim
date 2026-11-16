## The committed synthetic set in samples/: counts, units, the survey join
## used by Import survey, the land SEG-Y and SEG-D samples, the ocean-bottom
## sensor order, the dead trace, and the hydrophone/vertical polarity.
##
## The files are read as they are. Nothing here regenerates them.
##
## Seen to fail: with samples/land/shots.sgy moved aside, `present` quit on
## the missing file rather than skip the check.

import std/[math, os]
import parseSEG
import viewSEG/core/[join, session]

const root = currentSourcePath().parentDir.parentDir

let samples = root / "samples"
let land = samples / "land"
let vib = samples / "vib"
let obn = samples / "obn"

proc present(path: string) =
  doAssert fileExists(path), "missing " & path.relativePath(root)

proc progress(done, total: int): bool = true

proc surveyOf(paths: openArray[string]): SurveyGeometry =
  result = initSurveyGeometry()
  for p in paths:
    present(p)
    result.addSps(p)

proc openKeys(path: string): SeismicFile =
  present(path)
  result = openSeismic(path, keys = true)

proc headersUnit(f: SeismicFile): SurveyUnit =
  ## What the file's own headers say, as the import reads them.
  let sum = f.summary
  var c = FileCrs(units: sum.coordinateUnits, format: sum.crsFormat,
    measurement: f.index.segy.binary.measurementSystem)
  if sum.crsFormat != ctNone:
    c.text = f.crsText
    c.lengthUnit = lengthUnitOf(f.crs)
  headerUnitOf(c)

proc findSeismic(f: SeismicFile; record, channel: float64): int =
  result = -1
  for i in 0 ..< f.len:
    let k = f.traceKeys(i)
    if k.status != tsAuxiliary and k.record == record and k.channel == channel:
      return i
  doAssert false, "no seismic trace record " & $record & " channel " & $channel

proc seismicOf(f: SeismicFile): seq[int] =
  for i in 0 ..< f.len:
    if f.traceKeys(i).status != tsAuxiliary: result.add i

proc joined(path: string; sps: openArray[string]) =
  var f = openKeys(path)
  var g = surveyOf(sps)
  let plan = planJoin(addr f, g, JoinOptions(), progress)
  doAssert plan.traces == f.len, path
  doAssert plan.unmatched.len == 0, path.extractFilename & " unmatched " &
    $plan.unmatched.len & " of " & $plan.seismic
  doAssert plan.matched == plan.seismic, path.extractFilename & " matched " &
    $plan.matched & " of " & $plan.seismic
  f.close()

proc pearson(a, b: openArray[float32]; lo, hi: int): float64 =
  var (s, t, st, s2, t2) = (0.0, 0.0, 0.0, 0.0, 0.0)
  let n = float64(hi - lo + 1)
  for j in lo .. hi:
    let x = float64(a[j])
    let y = float64(b[j])
    s += x
    t += y
    st += x * y
    s2 += x * x
    t2 += y * y
  let cov = st - s * t / n
  let vs = s2 - s * s / n
  let vt = t2 - t * t / n
  doAssert vs > 0 and vt > 0, "a flat window " & $lo & ".." & $hi
  cov / sqrt(vs * vt)

proc rowOf(t: Tensor[float32]; r: int): seq[float32] =
  result.setLen t.shape[1]
  for j in 0 ..< result.len: result[j] = t[r, j]

proc tonePower(x: openArray[float32]; hz, dtMs: float64): float64 =
  let w = 2 * PI * hz * dtMs / 1000
  var (re, im) = (0.0, 0.0)
  for j, v in x:
    let p = w * float64(j)
    re += float64(v) * cos(p)
    im += float64(v) * sin(p)
  re * re + im * im

block files_are_present:
  for path in [land / "land.s", land / "land.r", land / "land.x",
      land / "shots.sgy", land / "shots.sgd", vib / "vib_uncorrelated.sgd",
      vib / "vib_correlated.sgd", obn / "obn.s", obn / "obn.r", obn / "obn.x",
      obn / "obn.sgd"]:
    present(path)

block counts:
  var y = openKeys(land / "shots.sgy")
  var d = openKeys(land / "shots.sgd")
  doAssert y.len == 576 and y.maxSamples == 750, "shots.sgy " & $y.len
  doAssert d.recordCount == 6 and d.len == 588, "shots.sgd " & $d.len
  doAssert seismicOf(d).len == 576
  doAssert y.traceKeys(0).intervalUs == 2000
  var vu = openKeys(vib / "vib_uncorrelated.sgd")
  var vc = openKeys(vib / "vib_correlated.sgd")
  doAssert vu.recordCount == 1 and vu.len == 50 and vu.maxSamples == 2750
  doAssert vc.recordCount == 1 and vc.len == 49 and vc.maxSamples == 750
  doAssert seismicOf(vu).len == 48 and seismicOf(vc).len == 48
  var o = openKeys(obn / "obn.sgd")
  doAssert o.recordCount == 4 and o.len == 384 and o.maxSamples == 1000
  doAssert o.traceKeys(0).intervalUs == 2000
  y.close()
  d.close()
  vu.close()
  vc.close()
  o.close()

block units:
  let landS = headUnitOf(readFile(land / "land.s"), jkSps, whole = true)
  let landR = headUnitOf(readFile(land / "land.r"), jkSps, whole = true)
  doAssert landS.unit == suUsFeet and landS.unit.abbreviation == "ftUS", $landS
  doAssert landR.unit == suUsFeet, $landR
  doAssert landS.warning.len == 0, landS.warning
  let obnR = headUnitOf(readFile(obn / "obn.r"), jkSps, whole = true)
  let obnS = headUnitOf(readFile(obn / "obn.s"), jkSps, whole = true)
  doAssert obnR.unit == suMetres and obnR.unit.abbreviation == "m", $obnR
  doAssert obnS.unit == suMetres, $obnS
  var y = openKeys(land / "shots.sgy")
  var d = openKeys(land / "shots.sgd")
  var o = openKeys(obn / "obn.sgd")
  doAssert y.index.segy.binary.measurementSystem == 2
  let yUnit = fileUnitOf(headersUnit(y), landS.unit).unit
  let dUnit = fileUnitOf(headersUnit(d), landS.unit).unit
  doAssert yUnit == suUsFeet, "shots.sgy " & $yUnit
  doAssert dUnit == suUsFeet, "shots.sgd " & $dUnit
  doAssert headersUnit(o) == suMetres, "obn.sgd " & $headersUnit(o)
  y.close()
  d.close()
  o.close()

block import_matches_every_seismic_trace:
  let landSps = [land / "land.s", land / "land.r", land / "land.x"]
  let obnSps = [obn / "obn.s", obn / "obn.r", obn / "obn.x"]
  joined(land / "shots.sgy", landSps)
  joined(land / "shots.sgd", landSps)
  joined(obn / "obn.sgd", obnSps)

block segy_matches_segd:
  var y = openKeys(land / "shots.sgy")
  var d = openKeys(land / "shots.sgd")
  let seis = seismicOf(d)
  doAssert seis.len == y.len
  let ys = y.readTraces(0 ..< y.len)
  var worst = 0'f32
  for i, s in seis:
    let row = d.readTraces(s .. s)
    for j in 0 ..< y.maxSamples:
      worst = max(worst, abs(ys[i, j] - row[0, j]))
  doAssert worst < 1e-5, "largest sample difference " & $worst
  y.close()
  d.close()

block obn_sensors_in_order:
  var o = openKeys(obn / "obn.sgd")
  let sensors = [1'u8, 2, 3, 4]
  for i in 0 ..< o.len:
    let k = o.traceKeys(i)
    doAssert k.sensorType == sensors[i mod 4] and k.component == sensors[i mod 4],
      "trace " & $i & " sensor " & $k.sensorType & " component " & $k.component
    doAssert k.rcvPoint == 101.0 + float64(i mod 96 div 4)
  o.close()

block dead_and_hum:
  for path in [land / "shots.sgy", land / "shots.sgd"]:
    var f = openKeys(path)
    let i = findSeismic(f, 3, 12)
    let k = f.traceKeys(i)
    doAssert k.status == tsDead, path.extractFilename & " " & $k.status
    let row = f.readTraces(i .. i)
    for j in 0 ..< f.maxSamples:
      doAssert row[0, j] == 0, "dead sample " & $j
    let hum = findSeismic(f, 3, 64)
    let neighbour = findSeismic(f, 3, 63)
    let humP = tonePower(rowOf(f.readTraces(hum .. hum), 0), 60, 2)
    let nearP = tonePower(rowOf(f.readTraces(neighbour .. neighbour), 0), 60, 2)
    doAssert humP > 10 * nearP, path.extractFilename & " 60 Hz " & $humP &
      " beside " & $nearP
    f.close()

block obn_reflection_and_ghost:
  ## Record 1, the station whose keys this reads. Up-going reflection: same
  ## polarity. Receiver ghost, 80 ms later: opposite polarity.
  var o = openKeys(obn / "obn.sgd")
  var hydro, vert = -1
  for i in 0 ..< 96:
    let k = o.traceKeys(i)
    if k.rcvPoint == 112 and k.sensorType == 1: hydro = i
    if k.rcvPoint == 112 and k.sensorType == 2: vert = i
  doAssert hydro >= 0 and vert == hydro + 1, "station 112 " & $hydro & " " & $vert
  let k = o.traceKeys(hydro)
  let dx = k.rcvX - k.srcX
  let downLeg = hypot(dx, 333.0 - 6.0)
  let upLeg = hypot(dx, 333.0 - 60.0)
  let pp = int(round((downLeg + upLeg) / 1500.0 * 1000.0 / 2.0))
  let ghost = pp + 40 ## 80 ms at 2 ms
  let x = o.readTraces(hydro .. vert)
  let (h, z) = (rowOf(x, 0), rowOf(x, 1))
  let same = pearson(h, z, pp - 8, pp + 8)
  let opp = pearson(h, z, ghost - 8, ghost + 8)
  doAssert same > 0.5, "reflection correlation " & $same & " at sample " & $pp
  doAssert opp < -0.5, "ghost correlation " & $opp & " at sample " & $ghost
  o.close()
