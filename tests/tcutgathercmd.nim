## The command that cuts the shown continuous recording at the shots of a
## loaded shot log: refused with no file or no log (and says which is
## missing), and with both it starts the cut job, writes the new file, logs the
## job's result sentences and keeps the outcome line and the file's path.
##
## Seen to fail: with the command doing nothing, "the cut wrote no file". With
## the refusal not naming what is missing, "the refusal does not say what is
## missing". With the result's sentences not logged, "the result is not in the
## log". With the outcome line not kept, "the outcome line was not kept".

import std/[os, sets, strutils]
import parseSEG
import viewSEG/core/[cutgather, jobs, recordingkind, shotlog]
import viewSEG/core/state {.all.}
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  SegLen = 3000

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
  false

proc makeRecording(path: string) =
  ## Two components, two source traces each of 3000 samples at 2 ms, the
  ## second following the first.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 .. 1:
    for comp in 0 .. 1:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = float32(100_000 * comp + seg * SegLen + j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(comp + 11)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000) + float64(seg * SegLen) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, samples)
  discard w.close()

proc makeFile(path: string; rows: openArray[tuple[rcv, first, n: int; source: float64]]) =
  ## A trace per row: its receiver, first sample, length and source point (NaN: none).
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for r in rows:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = 1
    k.channel = float64(r.rcv + 1)
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = float64(BaseUs div 1_000_000) + float64(r.first) * 0.002
    k.rcvLine = 1
    k.rcvPoint = float64(r.rcv + 1)
    k.srcPoint = r.source
    var samples = newSeq[float32](r.n)
    for j in 0 ..< r.n: samples[j] = float32(r.first + j)
    w.writeTrace(k, samples)
  discard w.close()

proc makeGather(path: string; rows: openArray[tuple[rcv, first: int]]) =
  ## SEG-D (SEG-Y has no receiver line): a trace per row of 2000 samples, one record each.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 2000))
  for i, r in rows:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = float64(i + 1)
    k.channel = 1
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = float64(BaseUs div 1_000_000) + float64(r.first) * 0.002
    k.rcvLine = 1
    k.rcvPoint = float64(r.rcv + 1)
    var samples = newSeq[float32](2000)
    for j in 0 ..< 2000: samples[j] = float32(r.first + j)
    w.writeTrace(k, samples)
  discard w.close()

proc writeLog(path: string): ShotLogMap =
  ## Three timed shots, one row without a time.
  var text = ""
  for (file, offsetUs) in [(101, 1_000_000'i64), (102, 2_000_000), (103, 4_000_000)]:
    text.add $file & "," & $(BaseUs + offsetUs) & "\n"
  text.add "104,\n"
  writeFile(path, text)
  result = initShotLogMap()
  result.hasHeader = false
  result.roles = @[crFileNumber, crUtcMicros]

proc start(dir: string): AppState =
  result = initAppState()
  var settings = result.settings
  settings.files.prepareNext = false
  result.apply Command(kind: ckSettings, settings: settings)

proc main*() =
  let dir = getTempDir() / ("viewseg-cutcmd-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)
  createDir(dir / "in")
  createDir(dir / "out")
  let rec = dir / "in" / "rec.sgy"
  makeRecording(rec)
  let logPath = dir / "shots.csv"
  let map = writeLog(logPath)
  let opts = initCutOptions(1000.0, 0.0)

  block refused_without_file_or_log:
    var st = start(dir)
    let dest = dir / "none.sgd"
    st.apply Command(kind: ckCutGather, cutLog: 0, cutOptions: opts, cutDest: dest)
    doAssert not st.cutRunning and not fileExists(dest)
    doAssert st.said(CutNeedBoth), "the refusal does not say what is missing"
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: rec)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
      "the recording was not shown"
    st.apply Command(kind: ckCutGather, cutLog: 0, cutOptions: opts, cutDest: dest)
    doAssert st.said(CutNeedLog), "the refusal does not say what is missing"
    doAssert not st.cutRunning and not fileExists(dest)
    doAssert st.cutProblem == CutNeedLog
    discard st.shutdown()

  block refused_without_file:
    var st = start(dir)
    st.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not read"
    let dest = dir / "nofile.sgd"
    st.apply Command(kind: ckCutGather, cutLog: 0, cutOptions: opts, cutDest: dest)
    doAssert st.said(CutNeedFile), "the refusal does not say what is missing"
    doAssert not st.cutRunning and not fileExists(dest)
    discard st.shutdown()

  block cut_writes_the_file:
    var st = start(dir)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: rec)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
      "the recording was not shown"
    st.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not read"
    doAssert st.cutProblem == "", st.cutProblem
    let dest = dir / "out" / "rec_cut.sgd"
    st.apply Command(kind: ckCutGather, cutLog: 0, cutOptions: opts, cutDest: dest)
    doAssert st.cutRunning, "the cut did not start"
    doAssert st.cutProblem == CutRunning
    doAssert st.settle(not st.cutRunning and st.cutOutcome.len > 0), "the cut did not finish"
    doAssert fileExists(dest), "the cut wrote no file: " & st.cutOutcome
    doAssert st.cutWritten == dest.canonical, st.cutWritten
    doAssert st.said("Cut 3 shots"), "the result is not in the log"
    doAssert "Written to rec_cut.sgd" in st.cutOutcome, "the outcome line was not kept: " &
      st.cutOutcome
    var f = openSeismic(dest, keys = true)
    doAssert f.len == 6, "records of two components for three shots: " & $f.len
    f.close()
    # A second cut to the same name is refused by the job, and said.
    st.apply Command(kind: ckCutGather, cutLog: 0, cutOptions: opts, cutDest: dest)
    doAssert st.settle(not st.cutRunning and st.cutOutcome.startsWith("The cut failed")),
      "the refusal of a name in use was not said: " & st.cutOutcome
    doAssert st.cutWritten.len == 0
    discard st.shutdown()

  block refused_when_not_continuous:
    # a shot gather (four receivers, one trace each) and a time-sliced receiver
    # gather (one receiver, a trace every 0.5 s of 4 s)
    let shotRecord = dir / "in" / "record.sgd"
    makeGather(shotRecord, [(0, 0), (1, 0), (2, 0), (3, 0)])
    let sliced = dir / "in" / "sliced.sgd"
    makeGather(sliced, [(0, 0), (0, 250), (0, 500), (0, 750)])
    for (path, words) in [(shotRecord, "This file is a shot gather"),
        (sliced, "This file is a time-sliced receiver gather, not a continuous one. Its traces")]:
      var st = start(dir)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
        "the file was not shown"
      st.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
      doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
        "the log was not read"
      # what the dialog is told: the file is read as a recording by a job
      st.watchRecording(true)
      doAssert st.settle(st.recordingFacts.ready), "the recording was not described"
      doAssert cutRefusal(st.recordingFacts).startsWith(words), cutRefusal(st.recordingFacts)
      let dest = dir / "out" / (extractFilename(path) & ".sgd")
      st.apply Command(kind: ckCutGather, cutLog: 0, cutOptions: opts, cutDest: dest)
      doAssert st.settle(not st.cutRunning and st.cutOutcome.len > 0),
        "the cut did not end"
      doAssert st.cutOutcome.startsWith("The cut failed: " & words), st.cutOutcome
      doAssert not fileExists(dest) and st.cutWritten.len == 0
      discard st.shutdown()

  block facts_of_a_continuous_recording:
    var st = start(dir)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: rec)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
      "the recording was not shown"
    doAssert not st.recordingFacts.ready
    st.watchRecording(true)
    doAssert st.settle(st.recordingFacts.ready), "the recording was not described"
    doAssert st.recordingFacts.kind == rkReceiverContinuous and st.recordingFacts.components == 2
    st.watchRecording(false)
    doAssert not st.recordingFacts.ready and not st.recordingBusy
    discard st.shutdown()

  block a_file_with_no_live_trace_is_read_once:
    # every trace is dead: the facts come back not ready, and the dialog's per-frame call
    # must not start the job again (it did, every frame, and said "being read" for ever)
    let deadFile = dir / "in" / "dead.sgy"
    var w = openSeismicWriter(deadFile, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
    for i in 0 ..< 3:
      var k = initTraceKeys()
      k.status = tsDead
      k.record = 1
      k.channel = float64(i + 1)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000)
      w.writeTrace(k, newSeq[float32](100))
    discard w.close()
    var st = start(dir)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: deadFile)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
      "the file was not shown"
    var jobsSeen = initHashSet[int]()
    var frames = 0
    doAssert st.settle((st.watchRecording(true); inc frames; st.recordingWhy.len > 0)),
      "the answer never came"
    for _ in 0 ..< 60:
      discard st.drainInbox()
      st.watchRecording(true)
      sleep(2)
    for j in st.jobs.list:
      if j.spec.title.endsWith("as a recording"): jobsSeen.incl int(j.id)
    doAssert jobsSeen.len == 1, "the job was started " & $jobsSeen.len & " times"
    doAssert not st.recordingBusy and not st.recordingFacts.ready
    doAssert st.recordingWhy == NoLiveTraceWords, st.recordingWhy
    discard st.shutdown()

when isMainModule:
  main()
