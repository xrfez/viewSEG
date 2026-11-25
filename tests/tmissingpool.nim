## The Missing traces scan on the item pool: the report is the same, field for field and in
## the CSV, whether the files are read on one thread or on several, for folders of shot
## gathers (a shot with no X record, several X records at one source, a file that is not
## seismic, a path given twice), of receiver gathers (derived O records and loaded ones, a
## receiver in several files, one with no source or no station), files whose kind cannot be
## told (the folder's unanimous rule and its choices) and a mix of the two sides. A cancel
## leaves the sink empty, a file the drive fails on is that file's skipped entry, and the
## item types hold plain data.
##
## Seen to fail: with the item for file `i` reading file `i xor 1`, `scenariosSayWhatTheyShould`
## finds the skipped files named wrongly (the threads agree with each other, so the figures are
## pinned); with the reason a file could not be read not kept, `oneFileFails` finds the victim
## missing from the skipped list; with the mix not announced to the items, `mixedFolderStopsReading`
## finds 8 files read on one thread, not 2.

import std/[atomics, os, strutils, tables, times]
import parseSEG
import viewSEG/core/[jobs, missingjobs, missingreport, recordingkind, reportside, settings]
import utils/[faultyfs, waiting]

proc put(line: var string; at: int; text: string) =
  let i = at - 1
  for j, c in text:
    if i + j < line.len: line[i + j] = c

proc xRec(record: int; srcLine, srcPoint: string; fromCh, toCh, rcvLine, fromR,
    toR: int; rcvIndex = 1; chInc = 1): string =
  result = repeat(' ', 80)
  result[0] = 'X'
  put(result, 2, "T1")
  put(result, 8, align($record, 8))
  put(result, 16, "11")
  put(result, 18, align(srcLine, 10))
  put(result, 28, align(srcPoint, 10))
  put(result, 38, "1")
  put(result, 39, align($fromCh, 5))
  put(result, 44, align($toCh, 5))
  put(result, 49, $chInc)
  put(result, 50, align($rcvLine & ".00", 10))
  put(result, 60, align($fromR & ".00", 10))
  put(result, 70, align($toR & ".00", 10))
  put(result, 80, $rcvIndex)

proc oRec(record: int; rcvLine, rcvPoint, srcLine: string; fromS, toS: int): string =
  ## An O record: the receiver is in the source columns, the sources in the receiver columns.
  result = xRec(record, rcvLine, rcvPoint, 1, toS - fromS + 1, parseInt(srcLine), fromS, toS)
  result[0] = 'O'

proc surveyOf(lines: seq[string]): ref SurveyGeometry =
  const H00 = "H00 SPS format version number   SPS 2.1;"
  var g = SurveyGeometry()
  g.addSps(parseSps(H00 & "\n" & lines.join("\n")))
  result = new SurveyGeometry
  result[] = g

proc shotFile(path: string; shots: openArray[tuple[record: int; src: float64;
    receivers: Slice[int]]]) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  for shot in shots:
    var ch = 1
    for point in shot.receivers:
      var k = initTraceKeys()
      k.record = float64(shot.record)
      k.channel = float64(ch)
      k.srcLine = 1
      k.srcPoint = shot.src
      k.srcIndex = 1
      k.rcvLine = 10
      k.rcvPoint = float64(point)
      k.rcvIndex = 1
      k.intervalUs = 2000
      k.status = tsLive
      w.writeTrace(k, @[0'f32])
      inc ch
  doAssert w.close().len == 0, "shot file was not written: " & path

proc slicedFile(path: string; stations: openArray[tuple[receiver: float64;
    sources: seq[float64]]]) =
  ## Receiver gathers cut in slices: a record and a trace for each shot of a receiver.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 10, time: 1_700_000_000.0, receiverGather: true))
  let samples = newSeq[float32](10)
  var ch = 0
  var rec = 0
  for st in stations:
    for slice, src in st.sources:
      inc ch
      inc rec
      var k = initTraceKeys()
      k.record = float64(100 + rec)
      k.channel = float64(ch)
      k.srcLine = 1
      k.srcPoint = src
      k.srcIndex = 1
      k.rcvLine = 10
      k.rcvPoint = st.receiver
      k.rcvIndex = 1
      k.intervalUs = 2000
      k.time = 1_700_000_000.0 + 60.0 * float64(slice)
      k.status = tsLive
      w.writeTrace(k, samples)
  doAssert w.close().len == 0, "sliced file was not written: " & path

proc receiverFile(path: string; record: int; receiver: float64; sources: openArray[float64]) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0, receiverGather: true))
  for i, src in sources:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(i + 1)
    k.srcLine = 1
    k.srcPoint = src
    k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = receiver
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, @[0'f32])
  doAssert w.close().len == 0, "receiver file was not written: " & path

proc plainFile(path: string; record: int; receivers: Slice[int]; stationless = false;
    sourceless = false) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  var ch = 0
  for point in receivers:
    inc ch
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    if not sourceless:
      k.srcLine = 1
      k.srcPoint = 1
      k.srcIndex = 1
    if not stationless:
      k.rcvLine = 10
      k.rcvPoint = float64(point)
      k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, @[0'f32])
  doAssert w.close().len == 0, "file was not written: " & path

type
  Scenario* = object
    ## A folder to scan and how.
    name*, folder*: string
    paths*: seq[string]
    survey*: ref SurveyGeometry
    forced*: Table[string, RecordingKind]
    untold*: UntoldKind
    folderRun*: bool

proc forcing(paths: openArray[string]; kind: RecordingKind): Table[string, RecordingKind] =
  for p in paths: result[p.normalizedPath] = kind

proc sliceOf(base: openArray[float64]; n: int): seq[float64] =
  for i in 0 ..< n: result.add base[i mod base.len]

proc shotFolder(root: string): Scenario =
  ## Shots 1..13 recorded by receivers 1..8, each short of some receivers; the first six
  ## files hold a second shot with no X record; source 14 has two X records.
  var xs: seq[string] = @[]
  for s in 1 .. 13: xs.add xRec(s, "1.00", $s & ".00", 1, 8, 10, 1, 8)
  xs.add xRec(14, "1.00", "14.00", 1, 4, 10, 1, 4)
  xs.add xRec(15, "1.00", "14.00", 1, 4, 10, 5, 8)
  result = Scenario(name: "shots", folder: root / "shots", survey: surveyOf(xs))
  createDir(result.folder)
  for f in 1 .. 13:
    let path = result.folder / ("s" & align($f, 2, '0') & ".sgd")
    var shots = @[(record: f, src: float64(f), receivers: 1 .. 3 + f mod 6)]
    if f <= 6: shots.add (record: 40 + f, src: float64(90 + f), receivers: 1 .. 4)
    shotFile(path, shots)
    result.paths.add path
  let fits = result.folder / "s14-fits.sgd"
  shotFile(fits, [(record: 14, src: 14.0, receivers: 1 .. 4)])
  let tie = result.folder / "s14-tie.sgd"
  shotFile(tie, [(record: 14, src: 14.0, receivers: 3 .. 6)])
  let notes = result.folder / "notes.txt"
  writeFile(notes, "not seismic\n")
  result.paths.add [fits, tie, notes, result.folder / "gone.sgd", result.paths[0]]

proc receiverFolder(root, name: string; loaded: bool): Scenario =
  ## Receivers 1..12 recorded in 16 files, receiver 1 in three of them, receiver 13 with no
  ## O record, a receiver with no source station, a file with no receiver station.
  var xs: seq[string] = @[]
  for s in 1 .. 6: xs.add xRec(s, "1.00", $s & ".00", 1, 12, 10, 1, 12)
  if loaded:
    for r in 1 .. 12: xs.add oRec(100 + r, "10.00", $r & ".00", "1", 1, 6)
  result = Scenario(name: name, folder: root / name, survey: surveyOf(xs))
  createDir(result.folder)
  let all = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
  for r in 1 .. 12:
    let path = result.folder / ("r" & align($r, 2, '0') & ".sgd")
    slicedFile(path, [(receiver: float64(r), sources: all.sliceOf(2 + r mod 5))])
    result.paths.add path
  let two = result.folder / "pair.sgd"
  slicedFile(two, [(receiver: 1.0, sources: @[5.0, 6.0]), (receiver: 13.0, sources: @[1.0])])
  let again = result.folder / "again.sgd"
  slicedFile(again, [(receiver: 1.0, sources: @[6.0]), (receiver: 2.0, sources: @[6.0])])
  let blind = result.folder / "blind.sgd"
  plainFile(blind, 1, 14 .. 14, sourceless = true)
  let nameless = result.folder / "nameless.sgd"
  plainFile(nameless, 1, 7 .. 9, stationless = true)
  result.paths.add [two, again, blind, nameless]
  result.forced = result.paths.forcing(rkReceiverSliced)

proc untoldFolder(root, name: string; sides: string; untold = ukNotChecked;
    folderRun = true): Scenario =
  ## Files of one receiver and one source, which cannot be told, with `sides`: "shot",
  ## "receiver", "both" or "none" files that can.
  var xs: seq[string] = @[]
  for s in 1 .. 6: xs.add xRec(s, "1.00", $s & ".00", 1, 20, 10, 1, 20)
  result = Scenario(name: name, folder: root / name, survey: surveyOf(xs), untold: untold,
    folderRun: folderRun)
  createDir(result.folder)
  for f in 1 .. 4:
    if sides in ["shot", "both"]:
      let path = result.folder / ("s" & $f & ".sgd")
      shotFile(path, [(record: f, src: float64(f), receivers: 1 .. 12 + f)])
      result.paths.add path
    if sides in ["receiver", "both"]:
      let path = result.folder / ("r" & $f & ".sgd")
      receiverFile(path, 100 + f, float64(f), [1.0, 2.0, 3.0 + float64(f mod 3)])
      result.paths.add path
    let u = result.folder / ("u" & $f & ".sgd")
    receiverFile(u, 200 + f, 7.0 + float64(f), [float64(f)])
    result.paths.add u
  let late = result.folder / "u9.sgd"
  receiverFile(late, 209, 17.0, [2.0])
  result.paths.add late

proc scenarios*(root: string): seq[Scenario] =
  ## Every folder the report is compared on.
  result = @[shotFolder(root), receiverFolder(root, "recv-derived", false),
    receiverFolder(root, "recv-loaded", true),
    untoldFolder(root, "untold-shot", "shot"),
    untoldFolder(root, "untold-receiver", "receiver"),
    untoldFolder(root, "untold-none", "none"),
    untoldFolder(root, "untold-mixed", "both"),
    untoldFolder(root, "untold-as-shot", "shot", ukShot, false),
    untoldFolder(root, "untold-as-receiver", "receiver", ukReceiver, false),
    untoldFolder(root, "untold-file-tab", "shot", ukNotChecked, false)]
  # a mix: shot gathers and receiver gathers in one folder, the files after the mix too
  var mixed = untoldFolder(root, "mixed", "both", ukNotChecked, false)
  mixed.paths.add mixed.folder / "s1.sgd"
  result.add mixed

proc fingerprint*(r: MissingJobResult): string =
  ## Every field of the result and the CSVs the window exports.
  result = $r & "\n" & stationsCsv(r.shot.rows, ssReceivers) & statsCsv(r.shot.stats) &
    stationsCsv(r.receiver.rows, ssSources) & statsCsv(r.receiver.stats)

proc runOn(sc: Scenario; threads: int): tuple[st: JobState; result: MissingJobResult;
    error: string] =
  let jobs = initJobs()
  jobs.setItemThreads(threads)
  let sink = MissingSink()
  let id = jobs.submit(missingSpec(sc.folder, sc.paths),
    scanMissing(sc.folder, sc.paths, addr sc.survey[], sink, "", sc.forced, nil, false, sc.untold,
    sc.folderRun))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the scan of " & sc.name & " did not finish"
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

var lane: Jobs
var reads: int

var phases: seq[string]

proc notePhase(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back: return
  {.cast(gcsafe).}:
    phases.add phase

proc stopOnScanning(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase.startsWith("scanning"): discard lane.cancel(id)

proc stopOnThird(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("reading"): return
  inc reads
  if reads >= 3: discard lane.cancel(id)

proc main*() =
  let root = getTempDir() / ("viewseg-misspool-" & $getCurrentProcessId())
  createDir(root)
  let all = scenarios(root)

  block plain:
    static:
      doAssert plainData(MissingJobResult)

  block sameOnAnyThreads:
    for sc in all:
      let serial = sc.runOn(1)
      doAssert serial.st == jsDone, sc.name & ": " & serial.error
      doAssert serial.result.ok, sc.name
      for threads in [2, 4, 8]:
        let got = sc.runOn(threads)
        doAssert got.st == jsDone, sc.name & ": " & got.error
        doAssert fingerprint(got.result) == fingerprint(serial.result),
          sc.name & " differs on " & $threads & " threads:\n" & fingerprint(got.result) &
          "\n" & fingerprint(serial.result)

  block scenariosSayWhatTheyShould:
    ## the folders exercise what they are for, so the equality above means something
    var by: Table[string, MissingJobResult]
    for sc in all: by[sc.name] = sc.runOn(1).result
    let shots = by["shots"]
    # (the figures the serial scan gave before the pool: shot files/records/missing/in template)
    let t = shots.shot.stats
    doAssert (t.files, t.records, t.missing, t.inTemplate) == (14, 14, 5, 8), $t
    doAssert shots.skipped[0].path == "notes.txt" and shots.skipped[1].path == "gone.sgd",
      $shots.skipped
    let r = by["recv-derived"].receiver.stats
    doAssert (r.files, r.records, r.missing, r.inTemplate) == (14, 12, 4, 6), $r
    let u = by["untold-shot"].shot.stats
    doAssert (u.files, u.records, u.missing, u.inTemplate) == (9, 9, 20, 20), $u
    doAssert shots.shot.stats.files > 10 and shots.shot.rows.len > 0
    doAssert shots.unmatched.len >= 7, $shots.unmatched
    doAssert shots.skipped.len == 2, $shots.skipped
    let derived = by["recv-derived"]
    doAssert derived.receiver.stats.records >= 12 and derived.receiver.stats.derived
    doAssert derived.unmatched.len >= 3, $derived.unmatched
    doAssert not by["recv-loaded"].receiver.stats.derived
    doAssert by["untold-shot"].sides.shots == 9 and by["untold-shot"].taken.len > 0
    doAssert by["untold-receiver"].sides.receivers == 9 and by["untold-receiver"].taken.len > 0
    doAssert by["untold-none"].sides.untold == 5 and by["untold-none"].notChecked.len == 5
    doAssert by["untold-mixed"].mixed.len > 0
    doAssert by["untold-as-shot"].sides.shots == 9 and
      by["untold-as-receiver"].sides.receivers == 9
    doAssert by["untold-file-tab"].notChecked.len == 5
    doAssert by["mixed"].mixed.len > 0

  block mixedFolderStopsReading:
    ## once the files taken are of both sides the gathers of the rest are not read: on one
    ## thread exactly the files up to the one that made the mix, on more no more than the
    ## files in hand then
    var mixed: Scenario
    for sc in all:
      if sc.name == "mixed": mixed = sc
    let serial = mixed.runOn(1)
    for threads in [1, 4]:
      gatherFiles.store(0)
      let got = mixed.runOn(threads)
      let read = gatherFiles.load()
      doAssert fingerprint(got.result) == fingerprint(serial.result)
      doAssert got.result.mixed.len > 0
      if threads == 1: doAssert read == 2, $read
      else: doAssert read <= 2 + 2 * threads and read < 13, $read

  block secondBatchSaysNoFileRead:
    ## the files whose kind cannot be told are read in a second batch, which names no file
    ## as being read: the last "reading" phase comes before the second "scanning" one
    var sc: Scenario
    for one in all:
      if one.name == "untold-shot": sc = one
    phases = @[]
    setJobHook(notePhase)
    let got = sc.runOn(1)
    setJobHook(nil)
    doAssert got.st == jsDone and got.result.taken.len > 0
    var scanning: seq[int] = @[]
    var lastReading = -1
    for i, p in phases:
      if p.startsWith("scanning"): scanning.add i
      elif p.startsWith("reading"): lastReading = i
    doAssert scanning.len == 2 and lastReading < scanning[1], $phases

  block budgetInForce:
    ## a budget no file fits: one file at a time, the same report
    let saved = missingBudget
    missingBudget = 1
    for sc in all:
      let one = sc.runOn(1)
      let got = sc.runOn(4)
      doAssert fingerprint(got.result) == fingerprint(one.result), sc.name
    missingBudget = saved

  block cancelStops:
    lane = initJobs()
    lane.setItemThreads(4)
    setJobHook(stopOnThird)
    reads = 0
    let sc = all[0]
    let sink = MissingSink()
    let id = lane.submit(missingSpec(sc.folder, sc.paths),
      scanMissing(sc.folder, sc.paths, addr sc.survey[], sink))
    doAssert waitUntil(lane.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
      "the cancelled scan did not finish"
    setJobHook(nil)
    doAssert lane.info(id).get.state == jsCancelled
    doAssert not sink.result.ok and sink.result.shot.stats.records == 0

  block cancelBeforeTheFirstFile:
    ## a cancel as the batch starts: no file is taken, and the job is still cancelled
    lane = initJobs()
    lane.setItemThreads(4)
    setJobHook(stopOnScanning)
    let sc = all[0]
    let sink = MissingSink()
    let id = lane.submit(missingSpec(sc.folder, sc.paths),
      scanMissing(sc.folder, sc.paths, addr sc.survey[], sink))
    doAssert waitUntil(lane.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
      "the cancelled scan did not finish"
    setJobHook(nil)
    doAssert lane.info(id).get.state == jsCancelled
    doAssert not sink.result.ok

  block cancelWhileRunning:
    install()
    fault(root, fkDelay, {foMapped, foHeaders}, initDuration(milliseconds = 40))
    let jobs = initJobs()
    jobs.setItemThreads(4)
    let sc = all[0]
    let sink = MissingSink()
    let id = jobs.submit(missingSpec(sc.folder, sc.paths),
      scanMissing(sc.folder, sc.paths, addr sc.survey[], sink))
    sleep 100
    discard jobs.cancel(id)
    doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
      "the cancelled scan did not finish"
    fault(root, fkNone)
    setFsHook(nil)
    doAssert jobs.info(id).get.state == jsCancelled
    doAssert not sink.result.ok

  block oneFileFails:
    install()
    let sc = all[0]
    let victim = sc.paths[4]
    fault(victim, fkFail)
    let serial = sc.runOn(1)
    let pooled = sc.runOn(4)
    fault(victim, fkNone)
    setFsHook(nil)
    for got in [serial, pooled]:
      doAssert got.st == jsDone, got.error
      var named = false
      for s in got.result.skipped:
        if s.path == victim.extractFilename: named = true
      doAssert named, "the failed file is not listed as skipped: " & $got.result.skipped
      doAssert got.result.shot.stats.files > 10
    doAssert fingerprint(pooled.result) == fingerprint(serial.result)

  removeDir(root)
  echo "tmissingpool: ok"

when isMainModule:
  main()
