## A shot log is read and written on a background job.
##
## The job refuses a file over 256 MiB without opening it, and a cancel
## leaves the sink empty. A failed read is one sentence. The file it was
## imported from is not modified.
##
## Seen to fail: with the cap refusal shortened, `over_the_cap` rejected
## "big.csv is too large."

import std/[options, os, strutils]
import viewSEG/core/[filesystem, jobs, project, shotlog, shotlogjobs]
import utils/[faultyfs, waiting]

const Sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shotlog.csv"

proc stateOf(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc ended(jobs: Jobs; id: JobId): bool =
  let info = jobs.info(id)
  info.isSome and info.get.state in {jsDone, jsFailed, jsCancelled}

proc runImport(path: string; map = ShotLogMap(); given = false):
    tuple[st: JobState; sink: ShotLogSink; error: string] =
  let jobs = initJobs()
  result.sink = ShotLogSink()
  let id = jobs.submit(importSpec(path), importShotLog(path, map, given, result.sink))
  doAssert waitUntil(jobs.ended(id)), "the import did not finish: " & $jobs.stateOf(id)
  let info = jobs.info(id).get
  (info.state, result.sink, info.error)

proc sparse(path: string; bytes: int64) =
  var f: File
  doAssert open(f, path, fmWrite), "cannot create " & path
  f.setFilePos(bytes - 1)
  f.write("x")
  f.close()

var lane: Jobs
var opened: int

proc stopReading(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase == "reading": discard lane.cancel(id)

proc countOpen(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if op == foOpen or op == foRead:
    {.cast(gcsafe).}: inc opened

proc main*() =
  let root = getTempDir() / ("viewseg-shotlog-" & $getCurrentProcessId())
  createDir(root)
  let original = readFile(Sample)

  block spec_names_the_file:
    doAssert importSpec(Sample).title == "Import shotlog.csv"
    doAssert importSpec(Sample).lane == jlBackground
    doAssert importSpec("").title == "Import shot log"
    doAssert loadSpec(root / "shotlogs" / "a.csv").title == "Load a.csv"
    doAssert saveSpec(root / "shotlogs" / "a.csv").title == "Save a.csv"
    doAssert remapSpec("").title == "Re-map shot log"

  block import_sample:
    let got = runImport(Sample)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.ok
    doAssert got.sink.result.log.len == 200 and got.sink.result.log.width == 22
    doAssert got.sink.result.view.rows.len == 200
    doAssert got.sink.result.view.rows[0].shotPoint == 1000.0
    doAssert got.sink.result.view.rows[0].fileNumber.get == 5000
    doAssert got.sink.result.map.delimiter == dlComma and got.sink.result.map.hasHeader
    doAssert got.sink.result.map.roles[0] == crSequence
    doAssert got.sink.result.map.roles[1] == crFileNumber
    doAssert readFile(Sample) == original

  block given_map:
    var m = initShotLogMap()
    m.delimiter = dlComma
    m.hasHeader = true
    m.roles = @[crText, crFileNumber]
    let got = runImport(Sample, m, given = true)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.map.roles[0] == crText
    doAssert got.sink.result.map.roles[1] == crFileNumber
    doAssert got.sink.result.view.rows[0].fileNumber.get == 5000
    doAssert got.sink.result.view.rows[0].sequence.isNone

  block save_and_load:
    let dir = root / "copy"
    createDir(dir)
    let got = runImport(Sample)
    doAssert got.st == jsDone, got.error
    got.sink.result.log.setCell(0, 0, "EDITED")
    let jobs = initJobs()
    let sink = ShotLogSink()
    let dest = dir.partOf("shotlog.csv".shotLogCopy)
    let id = jobs.submit(saveSpec(dest),
      saveShotLog(dir, "shotlog.csv", got.sink.result.log, got.sink.result.map, sink))
    doAssert waitUntil(jobs.ended(id)), "the save did not finish"
    doAssert jobs.stateOf(id) == jsDone, jobs.info(id).get.error
    doAssert sink.result.ok
    doAssert "EDITED" in readFile(dest)
    doAssert readFile(Sample) == original
    let loaded = ShotLogSink()
    let lid = jobs.submit(loadSpec(dest), loadShotLog(dest, got.sink.result.map, loaded))
    doAssert waitUntil(jobs.ended(lid)), "the load did not finish"
    doAssert jobs.stateOf(lid) == jsDone, jobs.info(lid).get.error
    doAssert loaded.result.ok and loaded.result.log.cell(0, 0) == "EDITED"
    doAssert loaded.result.view.rows.len == 200

  block over_the_cap:
    let big = root / "big.csv"
    sparse(big, ShotLogCap + 1)
    opened = 0
    setFsHook(countOpen)
    defer: setFsHook(nil)
    let got = runImport(big)
    doAssert got.st == jsFailed, $got.st & " " & got.error
    doAssert got.error == "big.csv is larger than 256 MiB and was not read.", got.error
    doAssert got.sink.result.reason == got.error
    doAssert not got.sink.result.ok and got.sink.result.log == nil
    doAssert opened == 0, "a file over the cap was opened (" & $opened & ")"
    doAssert '\n' notin got.error

  block cancel_leaves_the_sink:
    lane = initJobs()
    let sink = ShotLogSink()
    setJobHook(stopReading)
    defer: setJobHook(nil)
    let id = lane.submit(importSpec(Sample), importShotLog(Sample, ShotLogMap(), false, sink))
    doAssert waitUntil(lane.ended(id)), "the import did not finish: " & $lane.stateOf(id)
    doAssert lane.stateOf(id) == jsCancelled, $lane.stateOf(id) & " " & lane.info(id).get.error
    doAssert not sink.result.ok
    doAssert sink.result.reason.len == 0
    doAssert sink.result.log == nil
    doAssert sink.result.text.len == 0

  block failed_read_is_one_sentence:
    let bad = root / "bad.csv"
    writeFile(bad, "a,b\n1,2\n")
    install()
    fault(bad, fkFail, {foRead})
    defer:
      releaseAll()
      setFsHook(nil)
    let got = runImport(bad)
    doAssert got.st == jsFailed, $got.st & " " & got.error
    doAssert got.error == "bad.csv could not be read.", got.error
    doAssert got.sink.result.reason == got.error
    doAssert '\n' notin got.error and "stack" notin got.error.toLowerAscii

  removeDir(root)
  echo "tshotlogjobs: ok"

when isMainModule: main()
