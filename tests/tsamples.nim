## The committed synthetic set in samples/: counts, units, the survey join
## used by Import survey, the land SEG-Y and SEG-D samples, the ocean-bottom
## sensor order, the dead trace, and the hydrophone/vertical polarity.
##
## The files are read as they are. Nothing here regenerates them.
##
## The vibrator signature file (`vib_signature.sgd`) is checked for its trace
## order, channel types and times, the weighted-sum identity and the drop-out.
##
## The receiver-gather ocean-bottom file (`obn_receiver.sgd`) is checked for its
## trace order, the component of each trace, the orientation of each node and
## the rotated horizontals.
##
## Seen to fail: with samples/land/shots.sgy moved aside, `present` quit on
## the missing file rather than skip the check; with the reaction mass taken
## as 3000 kg in the weighted-sum check, "sweep 1 GF (M, B) differs by ..."; with node 103 written at azimuth 0,
## "azimuth 64".

import std/[math, options, os]
import parseSEG
import processSEG/core/[types, units]
import processSEG/vibroseis/vibqc
import viewSEG/core/[join, session]

const root = currentSourcePath().parentDir.parentDir

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

proc main*() =

  let samples = root / "samples"
  let land = samples / "land"
  let vib = samples / "vib"
  let obn = samples / "obn"

  block files_are_present:
    for path in [land / "land.s", land / "land.r", land / "land.x",
        land / "shots.sgy", land / "shots.sgd", vib / "vib_uncorrelated.sgd",
        vib / "vib_correlated.sgd", vib / "vib_signature.sgd", obn / "obn_receiver.sgd", obn /
        "obn.s", obn / "obn.r", obn /
        "obn.x",
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

  block vibrator_signature_order:
    ## Receiver-gather order: R sweeps 1..6, then GF, M and B. One record
    ## and one receiver per channel; each trace is a sweep, 9 s long.
    var v = openKeys(vib / "vib_signature.sgd")
    doAssert v.len == 24 and v.recordCount == 4 and v.maxSamples == 2250
    let types = [0x98'u8, 0x94, 0x99, 0x95] ## pilot, measured force, mass, baseplate
    let t0 = 1_772_367_000.0 ## 2026-03-01 12:10:00 UTC
    for i in 0 ..< 24:
      let (c, s) = (i div 6, i mod 6)
      let k = v.traceKeys(i)
      doAssert v.traceEntry(i).channelType == types[c], "trace " & $i & " type " &
        $v.traceEntry(i).channelType
      doAssert k.record == float64(c + 1) and k.rcvPoint == float64(c + 1), "trace " & $i
      doAssert k.srcPoint == float64(101 + s) and k.channel == float64(s + 1)
      doAssert k.time == t0 + 20.0 * float64(s), "trace " & $i & " time " & $k.time
      doAssert k.intervalUs == 4000 and k.status == tsAuxiliary
      doAssert v.traceEntry(i).numSamples == 2250
    doAssert v.gathers.len == 4
    for g in v.gathers: doAssert g.kind == gkReceiver, $g.kind
    v.close()

  block vibrator_signature_weighted_sum:
    ## Mr * M + Mb * B is GF, in every sweep, to float32 accuracy.
    var v = openKeys(vib / "vib_signature.sgd")
    for s in 0 ..< 6:
      let gf = rowOf(v.readTraces(6 + s .. 6 + s), 0)
      let m = rowOf(v.readTraces(12 + s .. 12 + s), 0)
      let b = rowOf(v.readTraces(18 + s .. 18 + s), 0)
      var made = newSeq[float32](gf.len)
      groundForceInto(m, b, mass(3600, muKilogram), mass(1800, muKilogram), made)
      var peak, worst = 0.0
      for j in 0 ..< gf.len:
        peak = max(peak, abs(float64(gf[j])))
        worst = max(worst, abs(float64(made[j]) - float64(gf[j])))
      doAssert peak > 50_000, "sweep " & $(s + 1) & " peak " & $peak
      doAssert worst < 1e-6 * peak, "sweep " & $(s + 1) & " GF (M, B) differs by " & $worst
    v.close()

  block vibrator_signature_sweeps:
    ## The pilot is the same 8 s sweep each time, then silence; sweep 6's
    ## force has its drop-out, mid-sweep, at 40 %.
    var v = openKeys(vib / "vib_signature.sgd")
    let pilot = rowOf(v.readTraces(0 .. 0), 0)
    for s in 1 ..< 6: doAssert rowOf(v.readTraces(s .. s), 0) == pilot, "pilot " & $s
    for j in 2001 ..< 2250: doAssert pilot[j] == 0, "listen sample " & $j
    let five = rowOf(v.readTraces(10 .. 10), 0)
    let six = rowOf(v.readTraces(11 .. 11), 0)
    var (a, b) = (0.0, 0.0)
    for j in 950 .. 1050:
      a = max(a, abs(float64(five[j])))
      b = max(b, abs(float64(six[j])))
    doAssert b < 0.5 * a, "drop-out peak " & $b & " against " & $a
    v.close()

  block obn_receiver_gathers_and_orientation:
    ## One record per node (101..104), eight shots each, four components a
    ## shot (hydrophone, vertical, inline, crossline: sensor types 1..4).
    var o = openKeys(obn / "obn_receiver.sgd")
    doAssert o.len == 128 and o.recordCount == 4 and o.maxSamples == 1000
    doAssert o.gathers.len == 4
    for g in o.gathers: doAssert g.kind == gkReceiver, $g.kind
    # roll, pitch, azimuth in degrees, per node
    let attitude = [[0.0, 0.0, 0.0], [0.0, 5.0, 30.0], [0.0, 0.0, 90.0], [3.0, 0.0, -20.0]]
    let t0 = 1_772_413_200.0 ## 2026-03-02 01:00:00 UTC
    for i in 0 ..< 128:
      let (node, shot, kind) = (i div 32, i mod 32 div 4, i mod 4)
      let k = o.traceKeys(i)
      doAssert k.record == float64(node + 1) and k.rcvPoint == float64(101 + node), "trace " & $i
      doAssert k.srcPoint == float64(101 + shot) and k.channel == float64(shot * 4 + kind + 1)
      doAssert k.sensorType == uint8(kind + 1) and k.component == uint8(kind + 1),
        "trace " & $i & " sensor " & $k.sensorType & " component " & $k.component
      doAssert k.time == t0 + 60.0 * float64(shot) and k.status == tsLive, "trace " & $i
      let att = o.traceOrientation(i)
      doAssert att.isSome, "no orientation on trace " & $i
      let a = att.get
      doAssert abs(radToDeg(float64(a.rotationX)) - attitude[node][0]) < 1e-4, "roll " & $i
      doAssert abs(radToDeg(float64(a.rotationY)) - attitude[node][1]) < 1e-4, "pitch " & $i
      doAssert abs(radToDeg(float64(a.rotationZ)) - attitude[node][2]) < 1e-4, "azimuth " & $i
      doAssert a.orientationType == 1 and a.rotationApplied == 0, "flags " & $i
    o.close()

  block obn_receiver_horizontals_are_rotated:
    ## Node 101 is not rotated: its converted wave is on the inline trace. Node
    ## 103 is turned 90 degrees: that wave is on the crossline trace (the
    ## first shot, the farthest offset).
    var o = openKeys(obn / "obn_receiver.sgd")
    proc energy(trace: int): float64 =
      ## In a window round the converted wave (1 000 m/s up from the reflector).
      let k = o.traceKeys(trace)
      let dx = k.rcvX - k.srcX
      let ps = int(round((hypot(dx, 333.0 - 6.0) / 1500.0 + hypot(dx, 333.0 - 60.0) / 1000.0) *
        1000.0 / 2.0))
      let row = rowOf(o.readTraces(trace .. trace), 0)
      for j in ps - 20 .. ps + 20: result += float64(row[j]) * float64(row[j])
    let (inline0, cross0) = (energy(2), energy(3))
    let (inline2, cross2) = (energy(64 + 2), energy(64 + 3))
    doAssert inline0 > 3 * cross0, "node 101 inline " & $inline0 & " crossline " & $cross0
    doAssert cross2 > 3 * inline2, "node 103 inline " & $inline2 & " crossline " & $cross2
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

when isMainModule:
  main()
