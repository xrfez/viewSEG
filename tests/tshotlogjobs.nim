## A shot log is read and written on a background job, and held on the
## application state.
##
## The job refuses a file over 256 MiB without opening it, and a cancel
## leaves the sink empty. A failed read is one sentence. With no project a
## log is kept for the session and not stored. With a project it is copied
## under `shotlogs/`, and a close and open brings the log, its map and an
## edited cell back. The file it was imported from is not modified. A
## read-only project says so and does not write. A re-map keeps edits when
## the column count is unchanged, and says they were dropped when it changes.
## A cell edit that holds a line break is refused, said, and left unchanged.
##
## Seen to fail: with the cap refusal shortened, `over_the_cap` rejected
## "big.csv is too large."; with the read-only edit saving anyway,
## `read_only_refuses_the_save` rejected a log that did not say the refusal;
## with a newline stored anyway, `line_break_is_refused` rejected a cell
## that changed.

import std/[options, os, strutils]
import viewSEG/core/[filesystem, jobs, project, shotlog, shotlogjobs, state]
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

proc said(st: AppState; words: string): bool =
  for e in st.log:
    if words in e.text: return true

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

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
    doAssert got.sink.result.log.setCell(0, 0, "EDITED")
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

  block line_break_is_refused:
    var st = start(root / "config-break")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not kept for the session"
    let before = st.shotCell(0, 0, 0)
    let rev = st.shotRevision(0)
    let logs = st.shotLogsRevision
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "a\nb")
    doAssert st.shotCell(0, 0, 0) == before, "a line break was stored"
    doAssert st.shotRevision(0) == rev and st.shotLogsRevision == logs
    doAssert st.jobs.active.len == 0, "a refused edit started a job"
    doAssert st.said(ShotLogLineBreak), "the refusal is not said"
    doAssert not st.said("Ignored"), "the refusal is not a plain sentence"
    discard st.shutdown()

  block no_project:
    var st = start(root / "config")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not kept for the session"
    doAssert st.shotLogStored(0).len == 0
    doAssert st.said(ShotLogNotStored)
    doAssert st.shotView(0).rows.len == 200
    doAssert st.shotView(0).rows[0].shotPoint == 1000.0
    doAssert st.shotCell(0, 0, 1) == "5000"
    doAssert readFile(Sample) == original
    discard st.shutdown()

  block project_reopen:
    let job = root / "Job"
    let config = root / "config2"
    createDir(config)
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    doAssert st.shotLogStored(0) == "shotlog.csv", st.shotLogStored(0)
    let map = st.shotLogMap(0)
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "EDITED")
    doAssert st.settle(st.shotCell(0, 0, 0) == "EDITED" and st.jobs.active.len == 0),
      "the edited cell was not saved"
    st.flushFiles()
    let copy = job.partOf("shotlog.csv".shotLogCopy)
    doAssert "EDITED" in readFile(copy), "the copy does not hold the edit"
    doAssert readFile(Sample) == original, "the original file was modified"
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    doAssert st.shotLogCount == 0
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.shotLogCount == 1 and st.shotCell(0, 0, 0) ==
        "EDITED" and
      st.jobs.active.len == 0), "the log did not come back"
    doAssert st.shotLogMap(0) == map, "the map did not come back"
    doAssert st.shotView(0).rows[0].fileNumber.get == 5000
    doAssert st.shotLogsRevision > 0 and st.shotRevision(0) > 0
    discard st.shutdown()

  block remove_drops_the_copy:
    let job = root / "JobRemove"
    var st = start(root / "config3")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    let copy = job.partOf(st.shotLogStored(0).shotLogCopy)
    doAssert fileExists(copy)
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.shotLogCount == 0
    doAssert not fileExists(copy), "the copy was kept"
    doAssert readFile(Sample) == original
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.shotLogCount == 0 and st.jobs.active.len == 0),
      "a removed log came back"
    discard st.shutdown()

  block read_only_refuses_the_save:
    let job = root / "JobRo"
    let config = root / "config4"
    createDir(config)
    var holder = start(config)
    holder.apply Command(kind: ckNewProject, projectPath: job)
    doAssert holder.settle(holder.inProject and holder.jobs.active.len == 0)
    holder.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert holder.settle(holder.shotLogCount == 1 and holder.jobs.active.len == 0)
    holder.flushFiles()
    let copy = job.partOf("shotlog.csv".shotLogCopy)
    let before = readFile(copy)
    var other = start(root / "config5")
    other.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert other.settle(other.inProject and other.project.readOnly and
      other.shotLogCount == 1 and other.jobs.active.len == 0),
      "the second program did not open read-only with the log"
    other.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 1,
      logCell: "EDITED")
    doAssert other.shotCell(0, 0, 1) == "EDITED"
    doAssert other.said(ReadOnlyShotLog), "the refusal is not said"
    doAssert other.settle(other.jobs.active.len == 0)
    doAssert readFile(copy) == before, "a read-only program wrote the copy"
    let extra = root / "extra.csv"
    writeFile(extra, "a,b\n1,2\n")
    other.apply Command(kind: ckImportShotLog, logPath: extra)
    doAssert other.settle(other.shotLogCount == 2 and other.jobs.active.len == 0)
    doAssert other.shotLogStored(1).len == 0
    doAssert other.said(ReadOnlyShotLog)
    discard other.shutdown()
    discard holder.shutdown()

  block remap_keeps_edits:
    var st = start(root / "config6")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "9")
    doAssert st.settle(st.shotCell(0, 0, 0) == "9" and st.jobs.active.len == 0)
    var same = st.shotLogMap(0)
    same.roles[0] = crText
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: same)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[0] == crText),
      "the re-map did not finish"
    doAssert st.shotCell(0, 0, 0) == "9", "edits were dropped though the width was unchanged"
    discard st.shutdown()

  block remap_drops_edits:
    var st = start(root / "config6b")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "9")
    doAssert st.settle(st.shotCell(0, 0, 0) == "9" and st.jobs.active.len == 0)
    var narrow = initShotLogMap()
    narrow.delimiter = dlTab
    narrow.hasHeader = true
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: narrow)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).delimiter == dlTab),
      "the re-map did not finish"
    doAssert st.said(ShotLogEditsDropped), "the drop was not said"
    doAssert st.shotCell(0, 0, 0) != "9"
    discard st.shutdown()

  block old_project_has_no_log:
    let job = root / "JobOld"
    var st = start(root / "config7")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and fileExists(job.projectDirOf.documentOf) and
      st.jobs.active.len == 0)
    doAssert st.shotLogCount == 0
    st.flushFiles()
    doAssert "shotLogs" notin readFile(job.projectDirOf.documentOf)
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.shotLogCount == 0 and st.jobs.active.len == 0),
      "an old project loaded a shot log"
    doAssert not st.said("could not be read")
    discard st.shutdown()

  removeDir(root)
  echo "tshotlogjobs: ok"

when isMainModule: main()
