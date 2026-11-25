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
## The two survey sets (`samples/vibroseis/`, `samples/impulsive/`) are checked as
## one acquisition: the files exist and open, the three recording kinds, the shot log
## (no problems, every row a shot gather by FFID, time and source), the survey
## (every trace joined, the missing-traces count), the cut (slicing `continuous/` with
## the shot log reproduces `receiver-gathers/` sample for sample and agrees with the shot
## gathers), the deliberate defects, and for the vibrator set the reference
## (a correlation puts each arrival at its modelled sample).
##
## Seen to fail: with the vibrator signature file as it was before it became one
## record (four records of six sweeps), the order check stopped at its count
## (24 traces, 1 record); with samples/land/shots.sgy moved aside, `present` quit on
## the missing file rather than skip the check; with the reaction mass taken
## as 3000 kg in the weighted-sum check, "sweep 1 GF (M, B) differs by ..."; with node 103 written at azimuth 0,
## "azimuth 64"; with node 104's bump left out of `tools/sampledata.nim`, "roll 112"
## (trace 112 is the first one stepped).
##
## The survey sets were seen to fail with: the short shot's stations taken as channels 16
## and 22 (the channel check names 21); the cut started 2 ms after each shot (the
## reproduction check stops at the first receiver, "10_1001"); the reference shortened by
## its first two samples (the correlation and the pilot disagree); the noisy trace's noise
## at 2.0 instead of 5.0 (its rms was 3.2 times the loudest other trace, not 4).

import std/[assertions, algorithm, math, options, os, sequtils, strutils, tables]
import parseSEG
import processSEG
import processSEG/core/[types, units]
import processSEG/vibroseis/vibqc
import viewSEG/core/[cutgather, cutgatherjobs, edits, jobs, join, missingjobs, missingreport,
  qualityjobs, qualityreport, recordingkind, references, session, shotlog, vendormaps]
import utils/waiting

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


const
  SetDtMs = 2.0
  SetShots = 6
  SetReceivers = 24
  SetLines = [10.0, 20.0]
  SetDeadShot = 1    ## 0-based; line 10 station 1005
  SetNoisyShot = 4
  SetBadChannel = 5
  SetMissingShot = 3 ## its files lack two stations
  SetMissingChannels = [16, 21]

type SetSpec = object
  name: string
  vibrator: bool
  ffid0: int
  recordSamples: int
  segments: int
  startUtc: float64 ## the first continuous sample, UTC POSIX seconds
  firstShotS, stepS: float64

proc vibroseisSpec(): SetSpec =
  SetSpec(name: "vibroseis", vibrator: true, ffid0: 101, recordSamples: 3000, segments: 5,
    startUtc: 1_709_272_800.0, firstShotS: 4, stepS: 8) ## 2024-03-01 06:00:00 UTC

proc impulsiveSpec(): SetSpec =
  SetSpec(name: "impulsive", vibrator: false, ffid0: 201, recordSamples: 1000, segments: 3,
    startUtc: 1_709_283_600.0, firstShotS: 3, stepS: 4) ## 2024-03-01 09:00:00 UTC

proc receiverNames(): seq[string] =
  for line in SetLines:
    for station in 1001 .. 1012: result.add $int(line) & "_" & $station

proc kindOfFile(path: string): RecordingKind =
  var f = openKeys(path)
  defer: f.close()
  let facts = describeRecording(planRecording(addr f, path,
    f.traceKeys(0).intervalUs / 1000, VendorRegistry()))
  doAssert facts.ready, path.extractFilename
  facts.kind

proc rowsOfFile(f: SeismicFile; first, last: int): seq[seq[float32]] =
  let x = f.readTraces(first .. last)
  for r in 0 ..< x.shape[0]:
    result.add rowOf(x, r)

proc rms(x: openArray[float32]): float64 =
  for v in x: result += float64(v) * float64(v)
  sqrt(result / float64(max(x.len, 1)))

proc relationsOf(dir, name: string): ref SurveyGeometry =
  var g = initSurveyGeometry()
  for ext in [".s", ".r", ".x"]:
    present(dir / "survey" / (name & ext))
    g.addSps(dir / "survey" / (name & ext))
  result = new SurveyGeometry
  result[] = g

proc surveyFiles(dir: string; name: string): seq[string] =
  for ext in [".s", ".r", ".x"]: result.add dir / "survey" / (name & ext)

proc waitJob(jobs: Jobs; id: JobId) =
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "a job did not finish"
  let info = jobs.info(id).get
  doAssert info.state == jsDone, $info.state & ": " & info.error

proc shotLogOf(dir: string): tuple[view: ShotView; cuts: CutShots] =
  let text = readFile(dir / "shotlog.csv")
  let map = guessMap(text)
  result.view = shots(parseShotLog(text, map), map)
  result.cuts = shotsInTime(result.view.rows)

proc shotPath(dir: string; ss: SetSpec; shot: int; ext: string): string =
  dir / "shots" / ("ffid_" & $(ss.ffid0 + shot) & ext)

proc argmaxAbs(x: openArray[float32]; first, last: int): int =
  var best = -1.0
  for j in max(first, 0) .. min(last, x.high):
    if abs(float64(x[j])) > best:
      best = abs(float64(x[j]))
      result = j

proc correlated(traces: seq[seq[float32]]; reference: seq[float32]): seq[seq[float32]] =
  ## Each trace correlated with `reference` by processSEG's plan, as the program's
  ## correlation does.
  let n = traces[0].len
  let plan = initCorrelationPlan(float32, initPilot(reference, SetDtMs), SetDtMs, n)
  var raw = zeros[float32](traces.len, n)
  var keys = newSeq[TraceKeys](traces.len)
  var counts = newSeq[int](traces.len)
  let b = rowBlock(raw)
  for i, t in traces:
    for j, v in t: b.row(i)[j] = v
    keys[i] = initTraceKeys()
    keys[i].status = tsLive
    keys[i].intervalUs = 1000 * SetDtMs
    counts[i] = n
  let meta = initChunkMeta(rowsOf(keys, counts), dtMs = SetDtMs)
  var ws = initWorkspace()
  ws.reserve(plan.workspaceSize)
  var corr = zeros[float32](traces.len, plan.outSamples)
  plan.correlateInto(raw, corr, meta, ws)
  for i in 0 ..< traces.len: result.add rowOf(corr, i)

proc checkSet(ss: SetSpec; scratch: string) =
  let dir = root / "samples" / ss.name
  let names = receiverNames()
  let ffids = block:
    var r: seq[int] = @[]
    for shot in 0 ..< SetShots: r.add ss.ffid0 + shot
    r

  block files_exist:
    for ext in [".s", ".r", ".x"]: present(dir / "survey" / (ss.name & ext))
    present(dir / "shotlog.csv")
    for n in names:
      present(dir / "continuous" / (n & ".sgd"))
      present(dir / "receiver-gathers" / (n & ".sgd"))
    for shot in 0 ..< SetShots:
      present(shotPath(dir, ss, shot, ".sgd"))
      present(shotPath(dir, ss, shot, ".sgy"))
    doAssert dirExists(dir / "reference") == ss.vibrator, ss.name & " reference folder"

  block kinds_are_as_intended:
    for n in names:
      doAssert kindOfFile(dir / "continuous" / (n & ".sgd")) == rkReceiverContinuous,
        "continuous " & n
      doAssert kindOfFile(dir / "receiver-gathers" / (n & ".sgd")) == rkReceiverSliced,
        "receiver gather " & n
    for shot in 0 ..< SetShots:
      for ext in [".sgd", ".sgy"]:
        doAssert kindOfFile(shotPath(dir, ss, shot, ext)) == rkShotGather,
          "shot gather " & $shot & ext

  block shot_log_matches_the_shot_gathers:
    let (view, cuts) = shotLogOf(dir)
    doAssert view.problems.count == 0, "shot log problems " & $view.problems.count
    doAssert view.rows.len == SetShots and cuts.dropped == 0 and cuts.increasing
    for shot, row in view.rows:
      doAssert row.fileNumber == some(int64(ss.ffid0 + shot)), "FFID of row " & $shot
      doAssert row.sequence == some(int64(shot + 1)) and row.pointIndex == some(1'i64)
      doAssert row.sourceLine == 30 and row.shotPoint == float64(1001 + shot)
      let us = row.timeUtcUs.get
      doAssert us == int64(round((ss.startUtc + ss.firstShotS + float64(shot) * ss.stepS) *
        1e6)), "time of row " & $shot
      # the GPS column is the same instant: the leap seconds are those the library holds
      let line = readFile(dir / "shotlog.csv").splitLines[shot + 1].split(',')
      doAssert gpsMicrosToUtcMicros(parseBiggestInt(line[1])) == us, "GPS of row " & $shot
      for ext in [".sgd", ".sgy"]:
        var f = openKeys(shotPath(dir, ss, shot, ext))
        let (live, aux) = (f.len - 2, f.len - 2 + 1)
        for i in 0 ..< f.len:
          let k = f.traceKeys(i)
          doAssert k.record == float64(ss.ffid0 + shot), "record of " & $i
          doAssert int64(round(k.time * 1e6)) == us, "time of trace " & $i
          doAssert k.srcPoint == row.shotPoint and k.srcX == row.x and k.srcY == row.y
        doAssert f.traceKeys(live - 1).status != tsAuxiliary and
          f.traceKeys(aux - 1).status == tsAuxiliary
        f.close()

  block survey_joins_every_trace:
    let sps = surveyFiles(dir, ss.name)
    for shot in 0 ..< SetShots:
      for ext in [".sgd", ".sgy"]:
        joined(shotPath(dir, ss, shot, ext), sps)

  block shot_gathers_hold_the_spread:
    var f = openKeys(shotPath(dir, ss, 0, ".sgd"))
    doAssert f.len == SetReceivers + 2 and f.recordCount == 1 and
      f.maxSamples == ss.recordSamples
    for i in 0 ..< SetReceivers:
      let k = f.traceKeys(i)
      doAssert k.channel == float64(i + 1) and k.status != tsAuxiliary
      doAssert k.rcvLine == SetLines[i div 12] and k.rcvPoint == float64(1001 + i mod 12)
      doAssert k.rcvX == 500_000.0 + 50.0 * float64(i mod 12), "easting " & $i
      doAssert k.rcvY == 4_000_000.0 + 200.0 * float64(i div 12), "northing " & $i
      doAssert k.srcX == 500_275.0 and k.srcY == 3_999_850.0
    doAssert f.traceKeys(24).status == tsAuxiliary and f.traceKeys(25).status == tsAuxiliary
    f.close()

  block missing_stations_are_found:
    let relations = relationsOf(dir, ss.name)
    var paths: seq[string] = @[]
    for shot in 0 ..< SetShots: paths.add shotPath(dir, ss, shot, ".sgd")
    let lane = initJobs()
    let sink = MissingSink()
    lane.waitJob lane.submit(missingSpec(dir / "shots", paths),
      scanMissing(dir / "shots", paths, addr relations[], sink))
    let r = sink.result
    doAssert r.ok, r.reason
    let t = r.shot.stats
    doAssert t.files == SetShots and t.records == SetShots, $t
    doAssert t.expectedInRecords == SetShots * SetReceivers and t.missingInRecords == 2 and
      t.presentInRecords == SetShots * SetReceivers - 2, $t
    doAssert t.inTemplate == SetReceivers and t.missing == 2, $t
    doAssert r.unmatched.len == 0 and r.skipped.len == 0, $r.unmatched
    doAssert r.shot.rows.len == 2, "stations missing: " & $r.shot.rows.len
    for i, p in r.shot.rows:
      doAssert p.line == 20 and p.point == float64([1004, 1009][i]) and p.missing == 1, $p

  block missing_stations_are_the_x_records:
    for ext in [".sgd", ".sgy"]:
      var f = openKeys(shotPath(dir, ss, SetMissingShot, ext))
      doAssert f.len == SetReceivers - 2 + 2, "traces of the short shot " & $f.len
      for i in 0 ..< f.len:
        let k = f.traceKeys(i)
        doAssert k.channel notin SetMissingChannels.mapIt(float64(it)) or
          k.status == tsAuxiliary and k.channel > 24, "channel " & $k.channel
      f.close()

  block cutting_the_continuous_files_reproduces_the_receiver_gathers:
    let (_, cuts) = shotLogOf(dir)
    let opts = initCutOptions(float64(ss.recordSamples) * SetDtMs)
    let lane = initJobs()
    createDir(scratch / ss.name)
    for n in names:
      let source = dir / "continuous" / (n & ".sgd")
      let dest = scratch / ss.name / (n & ".sgd")
      var f = openKeys(source)
      let sink = CutSink()
      lane.waitJob lane.submit(cutGatherSpec(source, dest),
        cutGatherWork(addr f, source, dest, cuts, opts, sink))
      doAssert sink.result.ok and sink.result.shotsWritten == SetShots,
        sink.result.reason
      doAssert sink.result.recordsFromFileNumbers
      f.close()
      var a = openKeys(dest)
      var b = openKeys(dir / "receiver-gathers" / (n & ".sgd"))
      doAssert a.len == SetShots and b.len == SetShots, n
      for i in 0 ..< SetShots:
        let (ka, kb) = (a.traceKeys(i), b.traceKeys(i))
        doAssert ka.record == kb.record and ka.record == float64(ffids[i]), n
        doAssert ka.time == kb.time and ka.rcvPoint == kb.rcvPoint and
          ka.srcPoint == kb.srcPoint, n
        doAssert rowOf(a.readTraces(i .. i), 0) == rowOf(b.readTraces(i .. i), 0),
          n & " shot " & $i & " differs"
      a.close()
      b.close()
    removeDir(scratch / ss.name)

  block receiver_gathers_agree_with_the_shot_gathers:
    var shotFiles: seq[SeismicFile] = @[]
    for shot in 0 ..< SetShots: shotFiles.add openKeys(shotPath(dir, ss, shot, ".sgd"))
    for r, n in names:
      var g = openKeys(dir / "receiver-gathers" / (n & ".sgd"))
      for shot in 0 ..< SetShots:
        var at = -1
        for i in 0 ..< shotFiles[shot].len:
          let k = shotFiles[shot].traceKeys(i)
          if k.status != tsAuxiliary and k.channel == float64(r + 1): at = i
        if shot == SetMissingShot and (r + 1) in SetMissingChannels:
          doAssert at < 0
        else:
          doAssert at >= 0, "no channel " & $(r + 1) & " in shot " & $shot
          doAssert rowOf(shotFiles[shot].readTraces(at .. at), 0) ==
            rowOf(g.readTraces(shot .. shot), 0), n & " shot " & $shot
      g.close()
    for f in shotFiles.mitems: f.close()

  block continuous_recordings_cover_the_shot_log:
    var f = openKeys(dir / "continuous" / "10_1001.sgd")
    doAssert f.len == ss.segments and f.maxSamples == 5000
    doAssert f.traceKeys(0).time <= ss.startUtc + ss.firstShotS
    let end2 = f.traceKeys(f.len - 1).time + 5000 * SetDtMs / 1000
    doAssert end2 >= ss.startUtc + ss.firstShotS + 5 * ss.stepS + float64(ss.recordSamples) *
      SetDtMs / 1000, "the recording ends at " & $end2
    f.close()

  block the_dead_and_the_noisy_trace:
    for ext in [".sgd", ".sgy"]:
      var f = openKeys(shotPath(dir, ss, SetDeadShot, ext))
      let dead = rowOf(f.readTraces(SetBadChannel - 1 .. SetBadChannel - 1), 0)
      doAssert rms(dead) == 0, "the dead trace has samples"
      f.close()
      var g = openKeys(shotPath(dir, ss, SetNoisyShot, ext))
      var others: seq[float64] = @[]
      for i in 0 ..< SetReceivers:
        let v = rms(rowOf(g.readTraces(i .. i), 0))
        if i == SetBadChannel - 1: doAssert v > 0 else: others.add v
      let noisy = rms(rowOf(g.readTraces(SetBadChannel - 1 .. SetBadChannel - 1), 0))
      others.sort
      doAssert noisy > 4 * others[^1], "noisy rms " & $noisy & " beside " & $others[^1]
      g.close()
    for ext in [".sgd", ".sgy"]:
      var d = openKeys(shotPath(dir, ss, SetDeadShot, ext))
      doAssert d.traceKeys(SetBadChannel - 1).status == tsDead, "flag in " & ext
      doAssert d.traceKeys(SetBadChannel).status == tsLive
      d.close()
    var rg = openKeys(dir / "receiver-gathers" / "10_1005.sgd")
    doAssert rms(rowOf(rg.readTraces(SetDeadShot .. SetDeadShot), 0)) == 0
    rg.close()

  block trace_quality_finds_them:
    var paths: seq[string] = @[]
    for shot in 0 ..< SetShots: paths.add shotPath(dir, ss, shot, ".sgd")
    let lane = initJobs()
    let sink = QualitySink()
    lane.waitJob lane.submit(qualitySpec(paths),
      scanQuality(paths, initTable[string, FileEdits](), sink))
    doAssert sink.result.ok, sink.result.reason
    var found = false
    for st in sink.result.receivers.stations:
      if st.line == 10 and st.point == 1005:
        found = true
        doAssert st.counts[qfHeaderDead] == 1 and st.noisy == 1, $st
      else:
        doAssert st.bad == 0 and st.noisy == 0, $st
    doAssert found

  if ss.vibrator:
    block reference_is_the_sweep_in_the_data:
      let folder = dir / "reference"
      let index = loadIndex(folder)
      doAssert index.problems.len == 0 and not index.damaged and index.entries.len == 1,
        $index.problems
      let e = index.entries[0]
      doAssert e.name == "Linear 10-80 Hz 4 s" and e.origin.generated and not e.missing
      doAssert e.origin.law == rlLinear and e.origin.f1Hz == 10 and e.origin.f2Hz == 80
      doAssert e.origin.durationMs == 4000 and e.origin.dtMs == SetDtMs
      doAssert e.origin.taperStartMs == 200 and e.origin.taperEndMs == 200
      let (sweep, us) = readReferenceFile(segyPath(folder, e.file))
      doAssert us == 2000 and sweep.len == 2000 and e.samples == 2000
      var f = openKeys(shotPath(dir, ss, 0, ".sgd"))
      let pilot = rowOf(f.readTraces(24 .. 24), 0)
      doAssert pilot[0 ..< 2000] == sweep, "the pilot is not the reference"
      for j in 2000 ..< pilot.len: doAssert pilot[j] == 0
      f.close()

    block correlating_puts_the_arrivals_at_the_modelled_samples:
      let folder = dir / "reference"
      let e = loadIndex(folder).entries[0]
      let (sweep, _) = readReferenceFile(segyPath(folder, e.file))
      var f = openKeys(shotPath(dir, ss, 0, ".sgd"))
      let picks = [0, 5, 12, 23]
      var traces: seq[seq[float32]] = @[]
      for i in picks: traces.add rowOf(f.readTraces(i .. i), 0)
      let pilot = rowOf(f.readTraces(24 .. 24), 0)
      let viaReference = correlated(traces, sweep)
      let viaPilot = correlated(traces, pilot[0 ..< 2000])
      doAssert viaReference == viaPilot, "the reference and the pilot disagree"
      for n, i in picks:
        let k = f.traceKeys(i)
        let off = hypot(k.rcvX - k.srcX, k.rcvY - k.srcY)
        let direct = int(round(off / 2000 * 1000 / SetDtMs))
        let reflection = int(round(sqrt(800.0 ^ 2 + (off / 2400 * 1000) ^ 2) / SetDtMs))
        let a = argmaxAbs(viaReference[n], direct - 8, direct + 8)
        doAssert abs(a - direct) <= 1, "direct arrival at " & $a & ", modelled " & $direct
        doAssert viaReference[n][a] > 0.8, "weak direct peak " & $viaReference[n][a]
        let b = argmaxAbs(viaReference[n], reflection - 8, reflection + 8)
        doAssert abs(b - reflection) <= 1, "reflection at " & $b & ", modelled " & $reflection
        # zero phase: the wavelet is symmetric about its peak
        for d in 1 .. 4:
          doAssert abs(viaReference[n][a + d] - viaReference[n][a - d]) <
            0.2 * abs(viaReference[n][a]), "not zero phase at trace " & $i
      f.close()
  else:
    block no_pilot_and_the_arrivals_are_in_the_data:
      for shot in 0 ..< SetShots:
        var f = openKeys(shotPath(dir, ss, shot, ".sgd"))
        doAssert f.traceKeys(f.len - 2).status == tsAuxiliary and
          f.traceKeys(f.len - 1).status == tsAuxiliary
        f.close()
      var f = openKeys(shotPath(dir, ss, 0, ".sgd"))
      for i in [0, 5, 12, 23]:
        let k = f.traceKeys(i)
        let off = hypot(k.rcvX - k.srcX, k.rcvY - k.srcY)
        let direct = int(round(off / 2000 * 1000 / SetDtMs))
        let reflection = int(round(sqrt(800.0 ^ 2 + (off / 2400 * 1000) ^ 2) / SetDtMs))
        let row = rowOf(f.readTraces(i .. i), 0)
        doAssert abs(argmaxAbs(row, direct - 8, direct + 8) - direct) <= 1, "direct " & $i
        doAssert abs(argmaxAbs(row, reflection - 8, reflection + 8) - reflection) <= 1,
          "reflection " & $i
        doAssert row[direct] > 0.7 and row[reflection] > 0.3, "polarity " & $i
      f.close()

proc main*() =

  let samples = root / "samples"
  let land = samples / "land"
  let vib = samples / "vib"
  let obn = samples / "obn"

  block files_are_present:
    for path in [land / "land.s", land / "land.r", land / "land.x",
        land / "shots.sgy", land / "shots.sgd", land / "shotlog.csv",
        vib / "vib_uncorrelated.sgd",
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
    ## One record, one receiver: the traces run R, GF, M, B for sweep 1, then
    ## for sweep 2, up to sweep 6; each is 9 s long.
    var v = openKeys(vib / "vib_signature.sgd")
    doAssert v.len == 24 and v.recordCount == 1 and v.maxSamples == 2250
    let types = [0x98'u8, 0x94, 0x99, 0x95] ## pilot, measured force, mass, baseplate
    let t0 = 1_772_367_000.0 ## 2026-03-01 12:10:00 UTC
    for i in 0 ..< 24:
      let (s, c) = (i div 4, i mod 4)
      let k = v.traceKeys(i)
      doAssert v.traceEntry(i).channelType == types[c], "trace " & $i & " type " &
        $v.traceEntry(i).channelType
      doAssert k.record == 1 and k.rcvPoint == 1, "trace " & $i
      doAssert k.srcPoint == float64(101 + s) and k.channel == float64(i + 1)
      doAssert k.time == t0 + 20.0 * float64(s), "trace " & $i & " time " & $k.time
      doAssert k.intervalUs == 4000 and k.status == tsAuxiliary
      doAssert v.traceEntry(i).numSamples == 2250
    doAssert v.gathers.len == 1 and v.gathers[0].traces == 0 .. 23
    doAssert v.gathers[0].kind == gkReceiver, $v.gathers[0].kind
    v.close()

  block vibrator_signature_weighted_sum:
    ## Mr * M + Mb * B is GF, in every sweep, to float32 accuracy.
    var v = openKeys(vib / "vib_signature.sgd")
    for s in 0 ..< 6:
      let gf = rowOf(v.readTraces(s * 4 + 1 .. s * 4 + 1), 0)
      let m = rowOf(v.readTraces(s * 4 + 2 .. s * 4 + 2), 0)
      let b = rowOf(v.readTraces(s * 4 + 3 .. s * 4 + 3), 0)
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
    for s in 1 ..< 6: doAssert rowOf(v.readTraces(s * 4 .. s * 4), 0) == pilot, "pilot " & $s
    for j in 2001 ..< 2250: doAssert pilot[j] == 0, "listen sample " & $j
    let five = rowOf(v.readTraces(17 .. 17), 0)
    let six = rowOf(v.readTraces(21 .. 21), 0)
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
    # roll, pitch, azimuth in degrees, per node; node 104 steps by (4, 0, 15) from its
    # fifth shot (a bump)
    let attitude = [[0.0, 0.0, 0.0], [0.0, 5.0, 30.0], [0.0, 0.0, 90.0], [3.0, 0.0, -20.0]]
    let bump = [4.0, 0.0, 15.0]
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
      let step = if node == 3 and shot >= 4: bump else: [0.0, 0.0, 0.0]
      doAssert abs(radToDeg(float64(a.rotationX)) - attitude[node][0] - step[0]) < 1e-4,
        "roll " & $i
      doAssert abs(radToDeg(float64(a.rotationY)) - attitude[node][1] - step[1]) < 1e-4,
        "pitch " & $i
      doAssert abs(radToDeg(float64(a.rotationZ)) - attitude[node][2] - step[2]) < 1e-4,
        "azimuth " & $i
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

  block survey_sets:
    let scratch = getTempDir() / ("viewseg-samples-" & $getCurrentProcessId())
    checkSet(vibroseisSpec(), scratch)
    checkSet(impulsiveSpec(), scratch)
    removeDir(scratch)

when isMainModule:
  main()
