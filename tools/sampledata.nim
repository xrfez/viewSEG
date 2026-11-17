## Synthetic sample set for screenshots, docs and demos.
##
##   nim samples
##
## Writes samples/ once. Float samples are not regenerated in tests: the
## committed files are what a viewer opens. One noise seed, the library
## default. Wavelets, the sweep, the noise, the SPS files and the SEG files
## come from parseSEG and processSEG.
##
## Land coordinates are US survey feet on a State Plane-sized origin.
## Ocean-bottom coordinates are metres. The vibroseis record is one land
## source point and one receiver line, an 8-80 Hz sweep with 3 s of listen.

import std/[math, options, os, strutils, times]
import parseSEG, processSEG

const
  DtLand = 2.0
  LandSamples = 750                  ## 1.5 s at 2 ms
  LandUs = 2000.0
  QcRecord = 3
  DeadChannel = 12                   ## line 1001, station 112
  ReversedChannel = 28               ## line 1001, station 128
  HumChannel = 64                    ## line 1002, station 116
  HumHz = 60.0
  HumAmp = 1.5
  NoiseSigma = 0.02
  RcvLines = [1001.0, 1002.0]
  RcvFirst = 101
  RcvCount = 48
  RcvSpacing = 110.0
  LineGap = 440.0
  SrcLine = 2001.0
  SrcFirst = 101
  ShotCount = 6
  ShotStep = 220.0
  OriginE = 2_000_000.0
  OriginN = 500_000.0
  SrcE = OriginE + 23.5 * RcvSpacing ## between stations 124 and 125
  SrcN0 = OriginN - LineGap
  VibDt = 4.0
  SweepMs = 8000.0
  ListenMs = 3000.0
  VibTaperMs = 300.0
  SweepF1 = 8.0
  SweepF2 = 80.0
  PhaseLag = 6.0
  SigSweeps = 6
  SigSensorLine = 9001.0             ## the unit's one receiver, point 1
  SigSpacing = 20.0                  ## s between sweeps
  SigRecordMs = 9000.0               ## the 8 s sweep and 1 s of listen
  SigGroundForce = 60_000.0          ## ground force amplitude, N
  SigBaseplate = 12.0                ## baseplate acceleration amplitude, m/s2
  SigReactionKg = 3600.0
  SigBaseplateKg = 1800.0
  SigGfNoise = 100.0                 ## seeded noise on the ground force, N
  SigBpNoise = 0.05                  ## and on the baseplate, m/s2
  RgNodes = 4                        ## receiver-gather file: nodes 101..104
  RgShots = 8                        ## and eight shots, 100 m apart, 275 m west to 425 m east
  ObnDt = 2.0
  ObnSamples = 1000                  ## 2 s at 2 ms
  ObnUs = 2000.0
  Water = 1500.0
  NodeDepth = 60.0
  GunDepth = 6.0
  Reflector = 333.0                  ## m below the surface; zero-offset PP is 400 ms
  Shear = 1000.0
  GhostDelay = 80.0                  ## two-way water time at the node, ms
  NodeLine = 3001.0
  NodeFirst = 101
  NodeCount = 24
  NodeSpacing = 50.0
  GunLine = 4001.0
  GunFirst = 101
  GunCount = 4
  GunSpacing = 100.0
  ObnE = 500_000.0
  ObnN = 5_800_000.0
  ObnScale = 10_000.0                ## 8036 counts per unit amplitude
  MaxBytes = 7 * 1000 * 1000

type Station = object
  line, point, easting, northing, elevation: float64

proc fail(log: DiagLog; what: string) =
  if log.isFatal or log.count(sevError) > 0:
    echo what
    for d in log: echo d
    quit what & " failed"

proc unixUtc(year: int; month: Month; day, hour: int): float64 =
  float64(initDateTime(day, month, year, hour, 0, 0, utc()).toTime.toUnix)

proc signedOffset(src, rcv: Station): float64 =
  let dx = rcv.easting - src.easting
  let dy = rcv.northing - src.northing
  let d = hypot(dx, dy)
  if d == 0: 0.0
  elif dx != 0: (if dx > 0: d else: -d)
  else: (if dy > 0: d else: -d)

proc landElev(easting, northing: float64): float64 =
  ## Tenths of a foot: 0.4 ft per station east, 1 ft per line north.
  820.0 + 0.4 * (easting - OriginE) / RcvSpacing + (northing - OriginN) / LineGap

proc header(code, description, data: string): SpsHeader =
  SpsHeader(code: code, description: description, data: data)

proc surveyHeaders(unitName, factor, projection, zone, datum: string): seq[SpsHeader] =
  @[header("00", "SPS format version num.", "SPS 2.1;"),
    header("12", "Geodetic datum spheroid", datum & ";"),
    header("18", "Projection type", projection & ";"),
    header("19", "Zone", zone & ";"),
    header("20", "Description of grid units", unitName & ";"),
    header("201", "Factor to meters", factor & ";")]

proc saveSps(f: SpsFile; path: string) =
  fail(writeSps(f, path), path)

proc spsPoint(kind: SpsPointKind; st: Station; code: string; depth, water,
    uphole: float64): SpsPoint =
  result = initSpsPoint(kind)
  result.line = st.line
  result.point = st.point
  result.index = 1
  result.code = code
  result.easting = st.easting
  result.northing = st.northing
  result.elevation = st.elevation
  if not depth.isNaN: result.pointDepth = depth
  if not water.isNaN: result.waterDepth = water
  if not uphole.isNaN: result.upholeTime = uphole

proc spsRelation(record: int; src: Station; fromCh, toCh, inc: int;
    rcvLine, fromRcv, toRcv: float64): SpsRelation =
  result = initSpsRelation()
  result.fieldRecord = record
  result.recordIncrement = 1
  result.instrumentCode = '1'
  result.srcLine = src.line
  result.srcPoint = src.point
  result.srcIndex = 1
  result.fromChannel = fromCh
  result.toChannel = toCh
  result.channelIncrement = inc
  result.rcvLine = rcvLine
  result.fromReceiver = fromRcv
  result.toReceiver = toRcv
  result.rcvIndex = 1

proc landReceiver(line: float64; station: int): Station =
  let e = OriginE + float64(station - RcvFirst) * RcvSpacing
  let n = OriginN + (line - RcvLines[0]) / (RcvLines[1] - RcvLines[0]) * LineGap
  Station(line: line, point: float64(station), easting: e, northing: n,
    elevation: landElev(e, n))

proc landSource(shot: int): Station =
  let n = SrcN0 + float64(shot) * ShotStep
  Station(line: SrcLine, point: float64(SrcFirst + shot), easting: SrcE,
    northing: n, elevation: landElev(SrcE, n))

proc landSpread(): seq[Station] =
  ## Channels 1..48 line 1001, 49..96 line 1002, stations 101..148.
  for line in RcvLines:
    for s in RcvFirst ..< RcvFirst + RcvCount:
      result.add landReceiver(line, s)

proc writeLandSps(dir: string) =
  let headers = surveyHeaders("US survey feet", "0.3048006096",
    "State Plane Coordinate System", "Texas South Central", "NAD83")
  var s, r, x = SpsFile(headers: headers)
  for shot in 0 ..< ShotCount:
    let src = landSource(shot)
    s.points.add spsPoint(pkSource, src, "E1", 30, NaN, 12)
    x.relations.add spsRelation(shot + 1, src, 1, RcvCount, 1, RcvLines[0],
      float64(RcvFirst), float64(RcvFirst + RcvCount - 1))
    x.relations.add spsRelation(shot + 1, src, RcvCount + 1, 2 * RcvCount, 1,
      RcvLines[1], float64(RcvFirst), float64(RcvFirst + RcvCount - 1))
  for st in landSpread():
    r.points.add spsPoint(pkReceiver, st, "G1", NaN, NaN, NaN)
  saveSps(s, dir / "land.s")
  saveSps(r, dir / "land.r")
  saveSps(x, dir / "land.x")

proc crsFeet(): string =
  "((OGP:P1/11 CRS))\n" &
    "HC,1,4,0,CRS,1,0,1,projected,NAD83 / Texas South Central\n" &
    "HC,1,5,0,Map Projection,1,0,Texas South Central\n" &
    "HC,1,5,1,Projection Method,1,9802,Lambert Conic Conformal (2SP)\n" &
    "HC,1,5,2,False easting,1,8806,2000000,1,US survey foot\n" &
    "HC,1,5,2,False northing,1,8807,500000,1,US survey foot\n" &
    "HC,1,6,1,US survey foot\n"

proc crsMetres(): string =
  "((OGP:P1/11 CRS))\n" &
    "HC,1,4,0,CRS,1,0,1,projected,WGS 84 / UTM zone 15N\n" &
    "HC,1,5,0,Map Projection,1,0,UTM zone 15N\n" &
    "HC,1,5,2,False easting,1,8806,500000,1,metre\n" &
    "HC,1,5,2,False northing,1,8807,0,1,metre\n" &
    "HC,1,6,1,metre\n"

proc segdOpts(interval: float64; n: int; feet: bool; time: float64;
    format = sd8058): SegdOutputOptions =
  SegdOutputOptions(sampleIntervalUs: interval, numSamples: n, format: format,
    units: (if feet: cuFeet else: cuMeters),
    crsText: (if feet: crsFeet() else: crsMetres()), time: time)

proc traceKey(record, channel: int; src, rcv: Station; haveRcv: bool;
    time, interval: float64; status: TraceStatus; sensor: uint8): TraceKeys =
  result = initTraceKeys()
  result.record = float64(record)
  result.channel = float64(channel)
  result.srcLine = src.line
  result.srcPoint = src.point
  result.srcIndex = 1
  result.srcX = src.easting
  result.srcY = src.northing
  result.srcZ = src.elevation
  if haveRcv:
    result.rcvLine = rcv.line
    result.rcvPoint = rcv.point
    result.rcvIndex = 1
    result.rcvX = rcv.easting
    result.rcvY = rcv.northing
    result.rcvZ = rcv.elevation
    result.cmpX = (src.easting + rcv.easting) / 2
    result.cmpY = (src.northing + rcv.northing) / 2
    result.offset = signedOffset(src, rcv)
  result.t0Ms = 0
  result.intervalUs = interval
  result.time = time
  result.status = status
  result.sensorType = sensor
  result.component = sensor
  if status == tsDead: result.traceCode = 2
  elif status == tsLive: result.traceCode = 1

proc fillLand(shot: var Tensor[float32]; offsets: openArray[float64];
    seed: int64; qc: bool) =
  shot.addLinear(offsets, DtLand, t0Ms = 8, velocity = 2500, freqHz = 40)
  shot.addLinear(offsets, DtLand, t0Ms = 60, velocity = 7000, freqHz = 25,
    amp = 0.65)
  shot.addHyperbola(offsets, DtLand, t0Ms = 220, velocity = 6500, freqHz = 30,
    amp = 0.8)
  shot.addHyperbola(offsets, DtLand, t0Ms = 520, velocity = 9500, freqHz = 22,
    amp = 0.5)
  shot.addLinear(offsets, DtLand, t0Ms = 0, velocity = 850, freqHz = 10, amp = 1.5)
  shot.addLinear(offsets, DtLand, t0Ms = 0, velocity = 850, freqHz = 14, amp = 1.0)
  let b = rowBlock(shot)
  for r in 0 ..< b.len:
    let arrive = linearMs(0, 850, offsets[r])
    for k in 1 .. 5:
      let centre = arrive + float64(k) * 100.0
      if centre < 1400:
        addRicker(b.row(r), DtLand, centre, 10, amp = 1.2 * exp(-0.4 * float64(k)))
  shot.addNoise(NoiseSigma, seed)
  if qc:
    for j in 0 ..< b.cols: b.row(DeadChannel - 1)[j] = 0
    for j in 0 ..< b.cols:
      b.row(ReversedChannel - 1)[j] = -b.row(ReversedChannel - 1)[j]
    addSinusoid(b.row(HumChannel - 1), DtLand, HumHz, amp = HumAmp)

proc auxTrace(n: int; centre, freq, amp: float64): seq[float32] =
  result = newSeq[float32](n)
  addRicker(result, DtLand, centre, freq, amp = amp)

proc writeLand(dir, scratch: string; t0: float64): seq[float64] =
  ## Seismic traces of shots.sgd and a seismic-only copy converted to
  ## shots.sgy (the copy is deleted). Returns each SEG-Y trace's offset.
  let spread = landSpread()
  var offsets = newSeq[float64](spread.len)
  let opts = segdOpts(LandUs, LandSamples, true, t0)
  let temp = scratch / "land-seismic.sgd"
  var full = openSeismicWriter(dir / "shots.sgd", opts)
  var seis = openSeismicWriter(temp, opts)
  for shot in 0 ..< ShotCount:
    let src = landSource(shot)
    for i, rcv in spread:
      offsets[i] = signedOffset(src, rcv)
    var data = zeros[float32](spread.len, LandSamples)
    let seed = DefaultNoiseSeed + int64(shot) * 1000
    fillLand(data, offsets, seed, qc = shot + 1 == QcRecord)
    let b = rowBlock(data)
    let time = t0 + 30.0 * float64(shot)
    for i, rcv in spread:
      let dead = shot + 1 == QcRecord and i + 1 == DeadChannel
      let status = if dead: tsDead else: tsLive
      let at = if i == 0: time else: NaN
      let k = traceKey(shot + 1, i + 1, src, rcv, true, at, LandUs, status, 2)
      full.writeTrace(k, b.row(i))
      seis.writeTrace(k, b.row(i))
      result.add offsets[i]
    var tb = auxTrace(LandSamples, 0, 80, 1.0)
    var uh = auxTrace(LandSamples, 12, 60, 0.8)
    let none = Station()
    let ktb = traceKey(shot + 1, 97, src, none, false, NaN, LandUs,
      tsAuxiliary, 0)
    let kuh = traceKey(shot + 1, 98, src, none, false, NaN, LandUs,
      tsAuxiliary, 0)
    full.writeTrace(ktb, tb, channelType = sctTimeBreak)
    full.writeTrace(kuh, uh, channelType = sctUpHole)
  fail(full.close(), "shots.sgd")
  fail(seis.close(), "seismic copy")
  var g = initSurveyGeometry()
  for name in ["land.s", "land.r", "land.x"]: g.addSps(dir / name)
  let conv = convertWithGeometry(temp, dir / "shots.sgy", g,
    ConvertOptions(format: st5))
  fail(conv, "shots.sgy")
  removeFile(temp)

proc fixSegy(path, journal: string; offsets: openArray[float64]) =
  var ed = openEditor(path, journal)
  var bad = false
  try:
    let deadAt = (QcRecord - 1) * RcvCount * 2 + (DeadChannel - 1)
    if not ed.setTraceField(deadAt, "trace.traceIdCode", 2):
      echo ed.log
      bad = true
    var i = 0
    while i < offsets.len and not bad:
      let stored = int32(round(offsets[i]))
      if not ed.setTraceField(i, "trace.offset", stored):
        echo "offset ", i, " refused"
        echo ed.log
        bad = true
      inc i
  finally:
    ed.close()
  if fileExists(journal): removeFile(journal)
  if bad: quit "could not finish " & path

proc addSpike(row: var openArray[float32]; sweep: openArray[float32];
    delay: int; amp: float32) =
  var j = 0
  var k = delay
  if k < 0:
    j = -k
    k = 0
  while j < sweep.len and k < row.len:
    row[k] += amp * sweep[j]
    inc j
    inc k

proc place(row: var openArray[float32]; sweep: openArray[float32]; timeMs,
    amp: float64) =
  addSpike(row, sweep, int(round(timeMs / VibDt)), float32(amp))

proc fillVib(row: var openArray[float32]; sweep: openArray[float32];
    offset: float64) =
  place(row, sweep, linearMs(8, 2500, offset), 1.0)
  place(row, sweep, linearMs(60, 7000, offset), 0.65)
  place(row, sweep, hyperbolicMs(220, 6500, offset), 0.8)
  place(row, sweep, hyperbolicMs(520, 9500, offset), 0.5)
  let arrive = linearMs(0, 850, offset)
  place(row, sweep, arrive, 1.5)
  for k in 1 .. 5:
    place(row, sweep, arrive + float64(k) * 100.0, 1.2 * exp(-0.4 * float64(k)))

proc writeVib(dir: string; t0: float64) =
  let spec = linearSweep(SweepF1, SweepF2, SweepMs, VibDt,
    initSweepTaper(VibTaperMs, VibTaperMs))
  let pilot = generatePilot(spec, float32)
  let nRec = spec.sweepLen + int(ListenMs / VibDt) - 1
  let nOut = nRec - pilot.len + 1
  doAssert nOut == int(ListenMs / VibDt), "listen length " & $nOut
  var force = spec
  force.amplitude = 2.0
  let gf = force.sweepHarmonics(float32, [
    SweepHarmonic(phaseDeg: PhaseLag),
    SweepHarmonic(order: 2, amp: 0.08),
    SweepHarmonic(order: 3, amp: 0.04)], samples = nRec)
  let src = landSource(QcRecord - 1)
  var spread: seq[Station] = @[]
  for s in RcvFirst ..< RcvFirst + RcvCount:
    spread.add landReceiver(RcvLines[0], s)
  var raw = zeros[float32](spread.len + 1, nRec)
  let b = rowBlock(raw)
  for i, rcv in spread:
    fillVib(b.row(i), pilot.samples, signedOffset(src, rcv))
    addNoise(b.row(i), NoiseSigma, DefaultNoiseSeed + 10_000 + int64(i))
  for j in 0 ..< pilot.len: b.row(spread.len)[j] = pilot.samples[j]
  var keys = newSeq[TraceKeys](raw.shape[0])
  var counts = newSeq[int](raw.shape[0])
  for i in 0 ..< keys.len:
    keys[i] = initTraceKeys()
    keys[i].status = if i < spread.len: tsLive else: tsAuxiliary
    keys[i].t0Ms = 0
    keys[i].intervalUs = VibDt * 1000
    counts[i] = nRec
  let meta = initChunkMeta(rowsOf(keys, counts), dtMs = VibDt)
  let plan = initCorrelationPlan(float32, pilot, VibDt, nRec)
  doAssert plan.outSamples == nOut
  var ws = initWorkspace()
  ws.reserve(plan.workspaceSize)
  var corr = zeros[float32](raw.shape[0], plan.outSamples)
  plan.correlateInto(raw, corr, meta, ws)
  let opts = segdOpts(VibDt * 1000, nRec, true, t0)
  var w = openSeismicWriter(dir / "vib_uncorrelated.sgd", opts)
  let cb = rowBlock(corr)
  for i, rcv in spread:
    let at = if i == 0: t0 else: NaN
    let k = traceKey(1, i + 1, src, rcv, true, at, VibDt * 1000, tsLive, 2)
    w.writeTrace(k, b.row(i))
  let none = Station()
  var kp = traceKey(1, spread.len + 1, src, none, false, NaN, VibDt * 1000,
    tsAuxiliary, 0)
  var kg = kp
  kg.channel = float64(spread.len + 2)
  w.writeTrace(kp, b.row(spread.len), channelType = sctSourceRefPilot)
  w.writeTrace(kg, gf, channelType = sctSourceSigMeasured)
  fail(w.close(), "vib_uncorrelated.sgd")
  let copts = segdOpts(VibDt * 1000, nOut, true, t0)
  var c = openSeismicWriter(dir / "vib_correlated.sgd", copts)
  for i, rcv in spread:
    let at = if i == 0: t0 else: NaN
    let k = traceKey(1, i + 1, src, rcv, true, at, VibDt * 1000, tsLive, 2)
    c.writeTrace(k, cb.row(i))
  var ka = traceKey(1, spread.len + 1, src, none, false, NaN, VibDt * 1000,
    tsAuxiliary, 0)
  c.writeTrace(ka, cb.row(spread.len), channelType = sctTrueRefSweep)
  fail(c.close(), "vib_correlated.sgd")

type SigSweep = object
  ## One sweep of the vibrator signature file.
  phaseDeg: float64      ## the ground force's phase to the pilot
  second, third: float64 ## its 2nd and 3rd harmonics, fraction of the fundamental
  dropout: bool          ## the force falls to 40 % for 0.5 s mid-sweep

const SigTable = [
  SigSweep(phaseDeg: 2.0, second: 0.02, third: 0.0),
  SigSweep(phaseDeg: 4.0, second: 0.05, third: 0.01),
  SigSweep(phaseDeg: 6.5, second: 0.09, third: 0.02),
  SigSweep(phaseDeg: 9.0, second: 0.15, third: 0.04),
  SigSweep(phaseDeg: 12.0, second: 0.24, third: 0.07),
  SigSweep(phaseDeg: 6.0, second: 0.06, third: 0.02, dropout: true)]

proc sigRecord(spec: SweepSpec; n: int; amp: float64; h: openArray[SweepHarmonic]):
    seq[float32] =
  var s = spec
  s.amplitude = amp
  s.sweepHarmonics(float32, h, samples = n)

proc writeVibSignature(dir: string; t0: float64) =
  ## Six sweeps of four signals (R, GF, M, B) in ONE record, a receiver gather
  ## (one receiver, the sweep is the source): the traces run R, GF, M, B for
  ## sweep 1, then for sweep 2, and so on, 9 s each. M is made from GF and B so
  ## that Mr*M + Mb*B is GF to float32 accuracy.
  let spec = linearSweep(SweepF1, SweepF2, SweepMs, VibDt,
    initSweepTaper(VibTaperMs, VibTaperMs))
  let pilot = generatePilot(spec, float32)
  let n = int(SigRecordMs / VibDt)
  var pil = newSeq[float32](n)
  for j in 0 ..< pilot.len: pil[j] = pilot.samples[j]
  var gf, mass, base: array[SigSweeps, seq[float32]]
  for s in 0 ..< SigSweeps:
    let row = SigTable[s]
    gf[s] = sigRecord(spec, n, SigGroundForce, [
      SweepHarmonic(phaseDeg: row.phaseDeg),
      SweepHarmonic(order: 2, amp: row.second),
      SweepHarmonic(order: 3, amp: row.third)])
    if row.dropout:
      let a = int(3750.0 / VibDt)
      let b = int(4250.0 / VibDt)
      for j in a - 6 .. b + 6:
        let edge = min(min(j - (a - 6), (b + 6) - j), 6)
        gf[s][j] *= float32(1.0 - 0.6 * float64(edge) / 6.0)
    addNoise(gf[s], SigGfNoise, DefaultNoiseSeed + 30_000 + int64(s))
    base[s] = sigRecord(spec, n, SigBaseplate, [
      SweepHarmonic(phaseDeg: 10.0 + 0.5 * float64(s)),
      SweepHarmonic(order: 2, amp: 0.04 + 0.01 * float64(s)),
      SweepHarmonic(order: 3, amp: 0.02)])
    addNoise(base[s], SigBpNoise, DefaultNoiseSeed + 31_000 + int64(s))
    mass[s] = newSeq[float32](n)
    for j in 0 ..< n:
      mass[s][j] = float32((float64(gf[s][j]) - SigBaseplateKg * float64(base[s][j])) /
        SigReactionKg)
  let opts = segdOpts(VibDt * 1000, n, true, t0)
  var o = opts
  o.receiverGather = true
  var w = openSeismicWriter(dir / "vib_signature.sgd", o)
  let types = [sctSourceRefPilot, sctSourceSigMeasured, sctSourceMass, sctSourceBasePlate]
  for s in 0 ..< SigSweeps:
    for c in 0 ..< 4:
      let src = landSource(s)
      let time = t0 + SigSpacing * float64(s)
      var sensor = landSource(0)
      sensor.line = SigSensorLine
      sensor.point = 1
      var k = traceKey(1, s * 4 + c + 1, src, sensor, true, time, VibDt * 1000,
        tsAuxiliary, 0)
      k.offset = 0
      let data = case c
        of 0: pil
        of 1: gf[s]
        of 2: mass[s]
        else: base[s]
      w.writeTrace(k, data, channelType = types[c])
  fail(w.close(), "vib_signature.sgd")

proc obnNode(station: int): Station =
  let e = ObnE + float64(station - NodeFirst) * NodeSpacing
  Station(line: NodeLine, point: float64(station), easting: e, northing: ObnN,
    elevation: -NodeDepth)

proc obnGun(shot: int): Station =
  let centre = ObnE + float64(NodeCount - 1) * NodeSpacing / 2
  let e = centre - GunSpacing * 1.5 + float64(shot) * GunSpacing
  Station(line: GunLine, point: float64(GunFirst + shot), easting: e,
    northing: ObnN, elevation: -GunDepth)

proc writeObnSps(dir: string) =
  let headers = surveyHeaders("Metres", "1.0", "Universal Transverse Mercator",
    "15N", "WGS 84")
  var s, r, x = SpsFile(headers: headers)
  for shot in 0 ..< GunCount:
    let src = obnGun(shot)
    s.points.add spsPoint(pkSource, src, "A1", GunDepth, GunDepth, NaN)
    # Channel increment 4: four components at each of the 24 stations.
    # toChannel is the first channel of the last station (93), so the run
    # is a whole number of stations.
    x.relations.add spsRelation(shot + 1, src, 1, 1 + (NodeCount - 1) * 4, 4,
      NodeLine, float64(NodeFirst), float64(NodeFirst + NodeCount - 1))
  for st in NodeFirst ..< NodeFirst + NodeCount:
    r.points.add spsPoint(pkReceiver, obnNode(st), "N1", NaN, NodeDepth, NaN)
  saveSps(s, dir / "obn.s")
  saveSps(r, dir / "obn.r")
  saveSps(x, dir / "obn.x")

proc slant(dx, dz: float64): float64 = hypot(dx, dz)

proc fillObn(row: var openArray[float32]; kind: int; dx: float64; seed: int64) =
  ## kind 0 hydrophone, 1 vertical, 2 inline, 3 crossline.
  let down = slant(dx, NodeDepth - GunDepth)
  let directMs = down / Water * 1000
  let downLeg = slant(dx, Reflector - GunDepth)
  let upLeg = slant(dx, Reflector - NodeDepth)
  let ppMs = (downLeg + upLeg) / Water * 1000
  let psMs = downLeg / Water * 1000 + upLeg / Shear * 1000
  let horiz = dx / max(downLeg, 1.0)
  if kind <= 1:
    addRicker(row, ObnDt, directMs, 80, amp = 0.9 * (if kind == 1: -0.8 else: 1.0))
    addRicker(row, ObnDt, ppMs, 80, amp = 0.8)
    addRicker(row, ObnDt, ppMs + GhostDelay, 80,
      amp = 0.45 * (if kind == 1: -1.0 else: 1.0))
  if kind == 2:
    addRicker(row, ObnDt, ppMs, 80, amp = 0.35 * horiz)
    addRicker(row, ObnDt, psMs, 25, amp = 0.7 * horiz)
  elif kind == 3:
    addRicker(row, ObnDt, psMs, 25, amp = 0.1 * horiz)
  addNoise(row, NoiseSigma, seed)

proc toCounts(row: var openArray[float32]) =
  ## 24-bit integer counts. A unit amplitude is `ObnScale` counts.
  for j in 0 ..< row.len:
    row[j] = float32(round(float64(row[j]) * ObnScale))

proc writeObn(dir: string; t0: float64) =
  let opts = segdOpts(ObnUs, ObnSamples, false, t0, sd8036)
  var w = openSeismicWriter(dir / "obn.sgd", opts)
  let sensors = [1'u8, 2, 3, 4]
  for shot in 0 ..< GunCount:
    let src = obnGun(shot)
    let time = t0 + 60.0 * float64(shot)
    var ch = 1
    for st in NodeFirst ..< NodeFirst + NodeCount:
      let rcv = obnNode(st)
      let dx = rcv.easting - src.easting
      for kind, sensor in sensors:
        var row = newSeq[float32](ObnSamples)
        let seed = DefaultNoiseSeed + 20_000 + int64(shot) * 1000 + int64(ch)
        fillObn(row, kind, dx, seed)
        toCounts(row)
        let at = if ch == 1: time else: NaN
        let k = traceKey(shot + 1, ch, src, rcv, true, at, ObnUs, tsLive, sensor)
        w.writeTrace(k, row)
        inc ch
  fail(w.close(), "obn.sgd")

type Attitude = object
  ## A node's sensor orientation, degrees: roll about X (inline), pitch about
  ## Y (crossline), azimuth about Z (down, so clockwise seen from above).
  roll, pitch, azimuth: float64

const RgAttitudes = [
  Attitude(),
  Attitude(pitch: 5, azimuth: 30),
  Attitude(azimuth: 90),
  Attitude(roll: 3, azimuth: -20)]

const
  BumpNode = 3 ## the node (0-based) that is bumped part-way through its gather: 104
  BumpShot = 4 ## from this shot (0-based; the fifth) on it lies turned by `Bump`
  Bump = Attitude(roll: 4, azimuth: 15)

func attitudeOf(node, shot: int): Attitude =
  ## The orientation of node `node` (0-based) while it records shot `shot`:
  ## fixed, but for node 104, which steps by `Bump` from the fifth shot.
  result = RgAttitudes[node]
  if node == BumpNode and shot >= BumpShot:
    result.roll += Bump.roll
    result.pitch += Bump.pitch
    result.azimuth += Bump.azimuth

type Mat3 = array[3, array[3, float64]]

proc attitudeMatrix(a: Attitude): Mat3 =
  ## R = Rz(azimuth) Ry(pitch) Rx(roll): the sensor axes in the survey frame.
  let (cx, sx) = (cos(degToRad(a.roll)), sin(degToRad(a.roll)))
  let (cy, sy) = (cos(degToRad(a.pitch)), sin(degToRad(a.pitch)))
  let (cz, sz) = (cos(degToRad(a.azimuth)), sin(degToRad(a.azimuth)))
  [[cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx],
   [sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx],
   [-sy, cy * sx, cy * cx]]

proc obnShot(shot: int): Station =
  ## Gun points 101..108 on line 4001, centred on the four nodes.
  let centre = ObnE + float64(RgNodes - 1) * NodeSpacing / 2
  Station(line: GunLine, point: float64(GunFirst + shot),
    easting: centre - GunSpacing * float64(RgShots - 1) / 2 + float64(shot) * GunSpacing,
    northing: ObnN, elevation: -GunDepth)

proc writeObnReceivers(dir: string; t0: float64) =
  ## `obn_receiver.sgd`: a receiver gather per node (one record each), whose
  ## traces are the shots of that node, each with its four components
  ## (hydrophone, vertical, inline, crossline). The horizontal and vertical
  ## traces are recorded in the node's own rotated frame, which the file
  ## states in each trace's orientation header; nothing is rotated back. Node
  ## 104 is bumped before its fifth shot: its orientation steps there.
  var o = segdOpts(ObnUs, ObnSamples, false, t0, sd8036)
  o.receiverGather = true
  var w = openSeismicWriter(dir / "obn_receiver.sgd", o)
  let sensors = [1'u8, 2, 3, 4]
  for node in 0 ..< RgNodes:
    let rcv = obnNode(NodeFirst + node)
    for shot in 0 ..< RgShots:
      let a = attitudeOf(node, shot)
      let m = attitudeMatrix(a)
      let att = initTraceOrientation(float32(degToRad(a.roll)), float32(degToRad(a.pitch)),
        float32(degToRad(a.azimuth)), orientationType = 1)
      let src = obnShot(shot)
      let dx = rcv.easting - src.easting
      var rows: array[4, seq[float32]]
      for kind in 0 ..< 4:
        rows[kind] = newSeq[float32](ObnSamples)
        let seed = DefaultNoiseSeed + 40_000 + int64(node) * 1000 + int64(shot) * 10 + kind
        fillObn(rows[kind], kind, dx, seed)
      # The survey-frame vector is (inline, crossline, down) = rows 2, 3, 1; the
      # sensors read R^T v. The vertical's sign in `fillObn` is kept as it is.
      for j in 0 ..< ObnSamples:
        let v = [float64(rows[2][j]), float64(rows[3][j]), float64(rows[1][j])]
        var r: array[3, float64]
        for i in 0 ..< 3: r[i] = m[0][i] * v[0] + m[1][i] * v[1] + m[2][i] * v[2]
        rows[2][j] = float32(r[0])
        rows[3][j] = float32(r[1])
        rows[1][j] = float32(r[2])
      for kind in 0 ..< 4:
        toCounts(rows[kind])
        let k = traceKey(node + 1, shot * 4 + kind + 1, src, rcv, true,
          t0 + 60.0 * float64(shot), ObnUs, tsLive, sensors[kind])
        w.writeTrace(k, rows[kind], orientation = some(att))
  fail(w.close(), "obn_receiver.sgd")

proc near(a, b: float64; tol: float64): bool =
  abs(a - b) <= tol

proc checkLand(dir: string) =
  var y = openSeismic(dir / "shots.sgy", keys = true)
  var d = openSeismic(dir / "shots.sgd", keys = true)
  doAssert y.len == ShotCount * RcvCount * 2, "SEG-Y traces " & $y.len
  doAssert d.recordCount == ShotCount
  doAssert y.summary.formatCode == 5
  doAssert y.index.segy.binary.measurementSystem == 2, "measurement system"
  var seismic: seq[int] = @[]
  var dead = 0
  for i in 0 ..< d.len:
    let k = d.traceKeys(i)
    if k.status != tsAuxiliary: seismic.add i
    if k.status == tsDead: inc dead
  doAssert seismic.len == y.len, "seismic traces " & $seismic.len
  doAssert dead == 1, "SEG-D dead traces " & $dead
  let ys = y.readTraces(0 ..< y.len)
  var worst = 0'f32
  for i, s in seismic:
    let row = d.readTraces(s .. s)
    for j in 0 ..< LandSamples:
      worst = max(worst, abs(ys[i, j] - row[0, j]))
  doAssert worst == 0, "SEG-Y and SEG-D differ by " & $worst
  let deadAt = (QcRecord - 1) * RcvCount * 2 + (DeadChannel - 1)
  let kd = y.traceKeys(deadAt)
  doAssert kd.status == tsDead, "dead reads as " & $kd.status
  doAssert kd.record == float64(QcRecord) and kd.channel == float64(DeadChannel)
  doAssert kd.rcvLine == RcvLines[0] and kd.rcvPoint == float64(RcvFirst + DeadChannel - 1),
    "dead station " & $kd.rcvLine & " " & $kd.rcvPoint
  doAssert near(kd.srcX, SrcE, 0.05) and near(kd.rcvZ, landElev(kd.rcvX, kd.rcvY), 0.05),
    "coordinates " & $kd.srcX & " " & $kd.rcvZ
  doAssert abs(kd.offset) > 1, "offset " & $kd.offset
  let rev = y.traceKeys(deadAt + (ReversedChannel - DeadChannel))
  doAssert rev.channel == float64(ReversedChannel) and rev.status == tsLive
  y.close()
  d.close()
  let sps = parseSps(readFile(dir / "land.s"))
  doAssert sps.gridUnit.name == "US survey feet"
  doAssert abs(sps.gridUnit.metres - 1200.0 / 3937.0) < 1e-9

proc checkObn(dir: string) =
  var f = openSeismic(dir / "obn.sgd", keys = true)
  doAssert f.recordCount == GunCount and f.len == GunCount * NodeCount * 4
  doAssert f.summary.coordinateUnits == cuMeters, $f.summary.coordinateUnits
  let sensors = [1'u8, 2, 3, 4]
  for i in 0 ..< NodeCount * 4:
    let k = f.traceKeys(i)
    doAssert k.sensorType == sensors[i mod 4] and k.component == sensors[i mod 4],
      "sensor " & $i & " is " & $k.sensorType
    doAssert k.rcvPoint == float64(NodeFirst + i div 4)
  f.close()
  let sps = parseSps(readFile(dir / "obn.r"))
  doAssert sps.gridUnit.name == "Metres" and abs(sps.gridUnit.metres - 1) < 1e-9

proc report(root: string) =
  var total = 0'i64
  for kind, path in walkDir(root / "samples"):
    if kind == pcDir:
      for k, f in walkDir(path):
        if k == pcFile:
          let n = getFileSize(f)
          total += n
          echo f.extractFilename, " ", n, " bytes"
  echo "samples/ ", total, " bytes"
  if total > MaxBytes:
    quit "samples/ is " & $total & " bytes, over " & $MaxBytes

proc main() =
  let root = currentSourcePath().parentDir.parentDir
  let scratch = root / ".scratch"
  createDir(scratch)
  createDir(root / "samples" / "land")
  createDir(root / "samples" / "vib")
  createDir(root / "samples" / "obn")
  let landT = unixUtc(2026, mMar, 1, 0)
  let vibT = unixUtc(2026, mMar, 1, 12)
  let obnT = unixUtc(2026, mMar, 2, 0)
  let land = root / "samples" / "land"
  writeLandSps(land)
  let offsets = writeLand(land, scratch, landT)
  fixSegy(land / "shots.sgy", scratch / "shots.journal", offsets)
  checkLand(land)
  writeVib(root / "samples" / "vib", vibT)
  writeVibSignature(root / "samples" / "vib", vibT + 600.0)
  writeObnSps(root / "samples" / "obn")
  writeObn(root / "samples" / "obn", obnT)
  writeObnReceivers(root / "samples" / "obn", obnT + 3600.0)
  checkObn(root / "samples" / "obn")
  report(root)
  echo "wrote samples/"

main()
