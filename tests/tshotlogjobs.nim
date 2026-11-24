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
## Undo and redo put a cell's text back through the same save path, a new
## edit clears redo, the history holds 1000 steps, a re-map clears it, and
## undo with nothing changes nothing.
## The project remembers the last column map. An import with no map given uses
## it when the file has the same columns and, with a header, the same names;
## a guess is used otherwise, and the completion sentence is only said when
## the remembered map was used. A header name longer than a shot log's name,
## after trimming, is not remembered and does not match. Removing a log does
## not clear it. A read-only
## project uses it and does not write it. No project remembers nothing.
##
## Seen to fail: with the cap refusal shortened, `over_the_cap` rejected
## "big.csv is too large."; with the read-only edit saving anyway,
## `read_only_refuses_the_save` rejected a log that did not say the refusal;
## with a newline stored anyway, `line_break_is_refused` rejected a cell
## that changed; with the copy written onto its own source,
## `import_does_not_write_onto_its_source` stored `shotlog.csv`; with the
## pre-edit text carried forward, `second_remap_keeps_edits` lost the cell;
## with the revision bumped in the edit command, `edit_waits_to_bump_revision`
## saw it move before the save assigned the view; with the copy set aside,
## `save_does_not_set_the_copy_aside` saw a `.old` file, and with no sweep,
## `reopen_sweeps_shot_log_temps` kept `shotlog.csv.7.tmp`; with the copy
## removed on the UI thread, `remove_does_not_touch_the_copy_on_the_ui_thread`
## and `finished_save_removes_off_the_ui_thread` saw that write; with the
## re-map parsing a passed string, `remap_reads_the_log_not_a_stale_copy`
## lost the edit; with the remembered map not applied, `remembered_map_on_the_job`
## rejected `usedLast`; with a read-only project remembering a new map anyway,
## `read_only_uses_the_map` kept the guess; with `decimalComma` left out of the
## map writer, `decimal_comma_survives_reopen` read `1,5` as not a number; with
## header names cut to 120 characters, `long_header_does_not_match` used the
## remembered map for a longer name, and `long_header_is_not_remembered` kept
## the re-mapped roles.

import std/[options, os, strutils]
import viewSEG/core/[filesystem, jobs, project, shotlog, shotlogjobs, state]
import utils/[faultyfs, steps, waiting]

const Sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shotlog.csv"

proc stateOf(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc ended(jobs: Jobs; id: JobId): bool =
  let info = jobs.info(id)
  info.isSome and info.get.state in {jsDone, jsFailed, jsCancelled}

proc runImport(path: string; map = ShotLogMap(); given = false;
    remembered = ShotLogMap(); remember = false; headers: seq[string] = @[]):
    tuple[st: JobState; sink: ShotLogSink; error: string] =
  let jobs = initJobs()
  result.sink = ShotLogSink()
  let id = jobs.submit(importSpec(path), importShotLog(path, map, given, result.sink,
    remembered, remember, headers))
  doAssert waitUntil(jobs.ended(id)), "the import did not finish: " & $jobs.stateOf(id)
  let info = jobs.info(id).get
  (info.state, result.sink, info.error)

proc said(st: AppState; words: string): bool =
  for e in st.log:
    if words in e.text: return true

proc timesSaid(st: AppState; words: string): int =
  for e in st.log:
    if words in e.text: inc result

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
var asideWrites: seq[string]

proc noteWrite(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if op == foWrite:
    {.cast(gcsafe).}: asideWrites.add path

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

  block save_does_not_set_the_copy_aside:
    let dir = root / "atomic"
    createDir(dir)
    let got = runImport(Sample)
    doAssert got.st == jsDone, got.error
    let dest = dir.partOf("shotlog.csv".shotLogCopy)
    createDir(dest.parentDir)
    writeFile(dest, "previous")
    asideWrites.setLen 0
    setFsHook(noteWrite)
    defer: setFsHook(nil)
    let jobs = initJobs()
    let sink = ShotLogSink()
    let id = jobs.submit(saveSpec(dest),
      saveShotLog(dir, "shotlog.csv", got.sink.result.log, got.sink.result.map, sink))
    doAssert waitUntil(jobs.ended(id)), "the save did not finish"
    doAssert jobs.stateOf(id) == jsDone, jobs.info(id).get.error
    for path in asideWrites:
      doAssert ".old" notin path, "the copy was set aside: " & path
    doAssert not fileExists(dest & ".old")
    for kind, path in walkDir(dest.parentDir):
      doAssert not path.endsWith(".old"), path
    doAssert readFile(dest) == got.sink.result.log.toText()

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

  block edit_waits_to_bump_revision:
    let job = root / "JobRev"
    var st = start(root / "config-rev")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    let rev = st.shotRevision(0)
    let logs = st.shotLogsRevision
    installSteps()
    holdStep("writing")
    defer:
      releaseStep("writing")
      setJobHook(nil)
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "HELD")
    doAssert waitUntil(inStep("writing").len > 0), "the save did not reach writing"
    doAssert st.shotCell(0, 0, 0) == "HELD"
    doAssert st.shotRevision(0) == rev, "the revision bumped before the view was assigned"
    doAssert st.shotLogsRevision == logs
    releaseStep("writing")
    doAssert st.settle(st.jobs.active.len == 0 and st.shotCell(0, 0, 0) == "HELD"),
      "the save did not finish"
    doAssert st.shotRevision(0) == rev + 1, "the revision did not bump when the view was assigned"
    doAssert st.shotLogsRevision == logs + 1
    discard st.shutdown()

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

  block import_does_not_write_onto_its_source:
    let job = root / "JobOwn"
    var st = start(root / "config-own")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    let parked = job.partOf("shotlog.csv".shotLogCopy)
    createDir(parked.parentDir)
    writeFile(parked, original)
    st.apply Command(kind: ckImportShotLog, logPath: parked)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    doAssert st.shotLogStored(0) != "shotlog.csv",
      "the copy was written onto its own source (" & st.shotLogStored(0) & ")"
    doAssert readFile(parked) == original, "the file already at the copy path was changed"
    let copy = job.partOf(st.shotLogStored(0).shotLogCopy)
    doAssert fileExists(copy) and copy != parked
    doAssert readFile(Sample) == original
    discard st.shutdown()

  block remove_does_not_touch_the_copy_on_the_ui_thread:
    let job = root / "JobUiRemove"
    var st = start(root / "config-uiremove")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    let copy = job.partOf(st.shotLogStored(0).shotLogCopy)
    doAssert fileExists(copy)
    install()
    defer:
      releaseAll()
      setFsHook(nil)
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.shotLogCount == 0
    doAssert st.settle(not fileExists(copy) and st.jobs.active.len == 0), "the copy was kept"
    for call in uiCalls():
      doAssert copy notin call, "the copy was touched on the UI thread: " & call
    doAssert calls(foWrite, copy) > 0, "the copy was not removed"
    discard st.shutdown()

  block finished_save_removes_off_the_ui_thread:
    let job = root / "JobSaveRemove"
    var st = start(root / "config-saveremove")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    let copy = job.partOf(st.shotLogStored(0).shotLogCopy)
    install()
    defer:
      releaseAll()
      setFsHook(nil)
    var earlier: seq[JobId]
    for info in st.jobs.list: earlier.add info.id
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "LATER")
    proc saveDone(st: AppState): bool =
      for info in st.jobs.list:
        if info.id notin earlier and info.spec.title.startsWith("Save ") and
            info.state == jsDone: return true
    doAssert waitUntil(st.saveDone()), "the save did not finish"
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.shotLogCount == 0
    doAssert st.settle(not fileExists(copy) and st.jobs.active.len == 0), "the copy was kept"
    for call in uiCalls():
      doAssert copy notin call, "the copy was touched on the UI thread: " & call
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
    doAssert st.settle(not fileExists(copy) and st.jobs.active.len == 0), "the copy was kept"
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

  block remap_reads_the_log_not_a_stale_copy:
    let got = runImport(Sample)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.log.setCell(0, 0, "9")
    let jobs = initJobs()
    let sink = ShotLogSink()
    let id = jobs.submit(remapSpec(Sample),
      remapShotLog(got.sink.result.log, got.sink.result.map, sink))
    doAssert waitUntil(jobs.ended(id)), "the re-map did not finish"
    doAssert jobs.stateOf(id) == jsDone, jobs.info(id).get.error
    doAssert sink.result.ok
    doAssert sink.result.log.cell(0, 0) == "9", "the re-map parsed a stale copy of the text"

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

  block second_remap_keeps_edits:
    let job = root / "JobRemap2"
    var st = start(root / "config-remap2")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "9")
    doAssert st.settle(st.shotCell(0, 0, 0) == "9" and st.jobs.active.len == 0),
      "the edited cell was not saved"
    var same = st.shotLogMap(0)
    same.roles[0] = crText
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: same)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotCell(0, 0, 0) == "9"),
      "the first re-map dropped the edit"
    var again = st.shotLogMap(0)
    again.roles[1] = crText
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: again)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crText),
      "the second re-map did not finish"
    doAssert st.shotCell(0, 0, 0) == "9", "a second re-map dropped the edit"
    st.flushFiles()
    doAssert "9" in readFile(job.partOf(st.shotLogStored(0).shotLogCopy)),
      "the saved copy lost the edit"
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

  block reopen_sweeps_shot_log_temps:
    let job = root / "JobSweep"
    var st = start(root / "config-sweep")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    let named = root / "notes.3.tmp"
    writeFile(named, "n,v\n1,2\n")
    st.apply Command(kind: ckImportShotLog, logPath: named)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    doAssert st.shotLogStored(0) == "notes.3.tmp", st.shotLogStored(0)
    st.flushFiles()
    let folder = job.partOf("shotlogs")
    let recorded = readFile(folder / "notes.3.tmp")
    writeFile(folder / "shotlog.csv.7.tmp", "temp")
    writeFile(folder / "day1.tmp", "keep")
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the project did not reopen"
    doAssert not fileExists(folder / "shotlog.csv.7.tmp"), "a leftover temporary was kept"
    doAssert readFile(folder / "day1.tmp") == "keep", "a copy named day1.tmp was removed"
    doAssert readFile(folder / "notes.3.tmp") == recorded, "a recorded copy was removed"
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

  block undo_and_redo:
    var st = start(root / "config-undo")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    let before = st.shotCell(0, 0, 0)
    doAssert st.shotUndoCount(0) == 0 and st.shotRedoCount(0) == 0
    st.apply Command(kind: ckUndoShotEdit, logIndex: 0)
    st.apply Command(kind: ckRedoShotEdit, logIndex: 0)
    doAssert st.shotCell(0, 0, 0) == before
    doAssert st.jobs.active.len == 0, "undo with nothing started a job"
    doAssert not st.said("Ignored"), "undo with nothing was ignored"
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "11")
    doAssert st.settle(st.shotCell(0, 0, 0) == "11" and st.jobs.active.len == 0)
    let rev = st.shotRevision(0)
    doAssert st.shotUndoCount(0) == 1 and st.shotRedoCount(0) == 0
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 1, logCell: "22")
    doAssert st.settle(st.shotCell(0, 0, 1) == "22" and st.jobs.active.len == 0)
    doAssert st.shotUndoCount(0) == 2
    st.apply Command(kind: ckUndoShotEdit, logIndex: 0)
    doAssert st.settle(st.shotCell(0, 0, 1) == "5000" and st.shotRevision(0) == rev + 2 and
      st.jobs.active.len == 0), "undo did not go through the save path"
    doAssert st.shotUndoCount(0) == 1 and st.shotRedoCount(0) == 1
    doAssert st.shotCell(0, 0, 0) == "11"
    st.apply Command(kind: ckRedoShotEdit, logIndex: 0)
    doAssert st.settle(st.shotCell(0, 0, 1) == "22" and st.jobs.active.len == 0)
    doAssert st.shotUndoCount(0) == 2 and st.shotRedoCount(0) == 0
    st.apply Command(kind: ckUndoShotEdit, logIndex: 0)
    doAssert st.settle(st.jobs.active.len == 0)
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "33")
    doAssert st.settle(st.shotCell(0, 0, 0) == "33" and st.jobs.active.len == 0)
    doAssert st.shotRedoCount(0) == 0, "a new edit left the redo list"
    doAssert st.shotUndoCount(0) == 2, "undo pushed a history step"
    discard st.shutdown()

  block undo_cap:
    var st = start(root / "config-cap")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    for n in 1 .. 1001:
      st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0,
        logCell: $n)
      doAssert st.settle(st.shotCell(0, 0, 0) == $n and st.jobs.active.len == 0),
        "edit " & $n & " did not finish"
    doAssert st.shotUndoCount(0) == 1000, "the history was not capped"
    st.apply Command(kind: ckUndoShotEdit, logIndex: 0)
    doAssert st.settle(st.shotCell(0, 0, 0) == "1000" and st.jobs.active.len == 0),
      "the oldest step was not dropped"
    discard st.shutdown()

  block remap_clears_history:
    var st = start(root / "config-hist")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: 0, logCell: "9")
    doAssert st.settle(st.shotCell(0, 0, 0) == "9" and st.jobs.active.len == 0)
    doAssert st.shotUndoCount(0) == 1
    var same = st.shotLogMap(0)
    same.roles[0] = crText
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: same)
    doAssert st.shotUndoCount(0) == 0 and st.shotRedoCount(0) == 0,
      "a re-map left the history"
    doAssert st.settle(st.jobs.active.len == 0)
    doAssert st.shotUndoCount(0) == 0
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.shotLogCount == 0
    discard st.shutdown()

  const
    Table = "# day\nfile;shot;note\n3;12;c\n"
    TableCase = "# day\n FILE ;Shot; note \n4;13;d\n"
    TableWide = "# day\nfile;shot;note;extra\n5;14;e;x\n"
    TableRenamed = "# day\nreel;shot;note\n5;14;e\n"

  block remembered_map_on_the_job:
    let path = root / "job-remember.csv"
    writeFile(path, Table)
    var remembered = initShotLogMap()
    remembered.delimiter = dlSemicolon
    remembered.skipLines = 1
    remembered.hasHeader = true
    remembered.roles = @[crText, crSequence, crText]
    let headers = @["file", "shot", "note"]
    let got = runImport(path, remember = true, remembered = remembered, headers = headers)
    doAssert got.st == jsDone, got.error
    doAssert got.sink.result.usedLast, "the remembered map was not used"
    doAssert got.sink.result.map.roles == remembered.roles
    doAssert got.sink.result.map.delimiter == dlSemicolon
    doAssert got.sink.result.map.skipLines == 1
    let cased = root / "job-case.csv"
    writeFile(cased, TableCase)
    let gotCase = runImport(cased, remember = true, remembered = remembered, headers = headers)
    doAssert gotCase.st == jsDone, gotCase.error
    doAssert gotCase.sink.result.usedLast, "capitals and end spaces did not fit"
    doAssert gotCase.sink.result.map.roles[1] == crSequence
    let wide = root / "job-wide.csv"
    writeFile(wide, TableWide)
    let gotWide = runImport(wide, remember = true, remembered = remembered, headers = headers)
    doAssert gotWide.st == jsDone, gotWide.error
    doAssert not gotWide.sink.result.usedLast, "an extra column used the remembered map"
    doAssert gotWide.sink.result.map.roles[1] == crShotPoint
    let renamed = root / "job-renamed.csv"
    writeFile(renamed, TableRenamed)
    let gotRenamed = runImport(renamed, remember = true, remembered = remembered,
      headers = headers)
    doAssert gotRenamed.st == jsDone, gotRenamed.error
    doAssert not gotRenamed.sink.result.usedLast, "a renamed header used the remembered map"
    doAssert gotRenamed.sink.result.map.roles[1] == crShotPoint
    var given = remembered
    given.roles = @[crText, crText, crText]
    let gotGiven = runImport(path, given, given = true, remembered = remembered,
      remember = true, headers = headers)
    doAssert gotGiven.st == jsDone, gotGiven.error
    doAssert not gotGiven.sink.result.usedLast, "a given map was treated as remembered"
    doAssert gotGiven.sink.result.map.roles == @[crText, crText, crText]

  block long_header_does_not_match:
    # A header longer than a shot log's name, after trimming, does not match a
    # remembered map either way: a longer file against the shared prefix, and
    # a prefix file against a longer remembered name. Cutting both to 120 would
    # make them the same.
    let prefix = "h".repeat(MaxShotLogName)
    let longer = root / "job-long-header.csv"
    let exact = root / "job-exact-header.csv"
    let padded = root / "job-padded-header.csv"
    writeFile(longer, prefix & "X;shot\n3;4\n")
    writeFile(exact, prefix & ";shot\n1;2\n")
    writeFile(padded, " " & prefix & " ;shot\n9;10\n")
    var remembered = initShotLogMap()
    remembered.delimiter = dlSemicolon
    remembered.hasHeader = true
    remembered.roles = @[crText, crSequence]
    let gotLong = runImport(longer, remember = true, remembered = remembered,
      headers = @[prefix, "shot"])
    doAssert gotLong.st == jsDone, gotLong.error
    doAssert not gotLong.sink.result.usedLast, "a long header used the remembered map"
    doAssert gotLong.sink.result.map.roles[1] == crShotPoint
    let gotCut = runImport(exact, remember = true, remembered = remembered,
      headers = @[prefix & "X", "shot"])
    doAssert gotCut.st == jsDone, gotCut.error
    doAssert not gotCut.sink.result.usedLast, "a cut remembered header matched"
    doAssert gotCut.sink.result.map.roles[1] == crShotPoint
    let gotSame = runImport(longer, remember = true, remembered = remembered,
      headers = @[prefix & "X", "shot"])
    doAssert gotSame.st == jsDone, gotSame.error
    doAssert not gotSame.sink.result.usedLast, "an equal long header used the remembered map"
    let gotExact = runImport(exact, remember = true, remembered = remembered,
      headers = @[prefix, "shot"])
    doAssert gotExact.st == jsDone, gotExact.error
    doAssert gotExact.sink.result.usedLast, "a header of 120 did not fit"
    let gotPad = runImport(padded, remember = true, remembered = remembered,
      headers = @[prefix, "shot"])
    doAssert gotPad.st == jsDone, gotPad.error
    doAssert gotPad.sink.result.usedLast, "a trimmed header of 120 did not fit"

  block remembered_map_survives_remove:
    let job = root / "JobRemember"
    let table = root / "remember.csv"
    let cased = root / "remember-case.csv"
    writeFile(table, Table)
    writeFile(cased, TableCase)
    var st = start(root / "config-remember")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    doAssert st.shotLogMap(0).roles[0] == crFileNumber and
      st.shotLogMap(0).roles[1] == crShotPoint, "the first import did not guess"
    doAssert not st.said(ColumnsAsLast), "a guess said the remembered sentence"
    var changed = st.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence),
      "the re-map did not finish"
    doAssert st.project.doc.lastShotMap.isSome, "the re-map was not remembered"
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.settle(st.shotLogCount == 0 and st.jobs.active.len == 0), "the log was kept"
    doAssert st.project.doc.lastShotMap.isSome, "removing the log cleared the map"
    st.flushFiles()
    let doc = readFile(job.projectDirOf.documentOf)
    doAssert "(lastShotMap" in doc, "the remembered map was not written"
    doAssert "(headerName \"file\")" in doc, "the header names were not written"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the second import did not finish"
    doAssert st.shotLogMap(0).roles == @[crText, crSequence, crText],
      "the remembered roles were not used"
    doAssert st.said(ColumnsAsLast), "the completion sentence was not said"
    let saidOnce = st.timesSaid(ColumnsAsLast)
    st.apply Command(kind: ckImportShotLog, logPath: cased)
    doAssert st.settle(st.shotLogCount == 2 and st.jobs.active.len == 0),
      "the cased import did not finish"
    doAssert st.shotLogMap(1).roles[1] == crSequence, "capitals and end spaces did not fit"
    doAssert st.timesSaid(ColumnsAsLast) == saidOnce + 1, "the cased import said nothing"
    discard st.shutdown()

  block decimal_comma_survives_reopen:
    # Import a semicolon log whose numbers use a comma, write the project
    # document and read it back, then import the same text with no map: the
    # remembered map is used and the depths are numbers.
    const Table = "shot;depth\n1;1,5\n2;2,25\n"
    let job = root / "JobDecimal"
    let table = root / "decimal.csv"
    writeFile(table, Table)
    var st = start(root / "config-decimal")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    doAssert st.shotLogMap(0).decimalComma, "the first import did not see a decimal comma"
    doAssert st.shotView(0).rows[0].sourceDepth == 1.5 and
      st.shotView(0).rows[1].sourceDepth == 2.25
    doAssert st.shotView(0).problems.count == 0
    st.flushFiles()
    let doc = readFile(job.projectDirOf.documentOf)
    doAssert "(decimalComma true)" in doc, "decimalComma was not written"
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the project did not reopen"
    doAssert st.project.doc.lastShotMap.isSome and
      st.project.doc.lastShotMap.get.map.decimalComma, "decimalComma did not come back"
    doAssert st.project.doc.shotLogs[0].map.decimalComma, "a stored log lost decimalComma"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 2 and st.jobs.active.len == 0),
      "the second import did not finish"
    doAssert st.said(ColumnsAsLast), "the remembered map was not used"
    doAssert st.shotLogMap(1).decimalComma, "the remembered map lost decimalComma"
    doAssert st.shotView(1).rows[0].sourceDepth == 1.5, "depth 1,5 was not 1.5"
    doAssert st.shotView(1).rows[1].sourceDepth == 2.25, "depth 2,25 was not 2.25"
    doAssert st.shotView(1).problems.count == 0, "the remembered map reported problems"
    discard st.shutdown()

  block remembered_map_survives_reopen:
    let job = root / "JobReopenMap"
    let table = root / "reopen.csv"
    writeFile(table, Table)
    var st = start(root / "config-reopen-map")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not stored"
    var changed = st.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence),
      "the re-map did not finish"
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.settle(st.shotLogCount == 0 and st.jobs.active.len == 0)
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.shotLogCount == 0 and st.jobs.active.len == 0),
      "the project did not reopen"
    doAssert st.project.doc.lastShotMap.isSome, "the remembered map did not come back"
    doAssert st.project.doc.lastShotMap.get.map.roles[1] == crSequence
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the import after reopen did not finish"
    doAssert st.shotLogMap(0).roles == @[crText, crSequence, crText],
      "the map was not remembered after reopen"
    doAssert st.said(ColumnsAsLast)
    discard st.shutdown()

  block long_header_is_not_remembered:
    let prefix = "h".repeat(MaxShotLogName)
    let job = root / "JobLongHeader"
    let exact = root / "state-exact-header.csv"
    let longer = root / "state-long-header.csv"
    let other = root / "state-other-header.csv"
    writeFile(exact, prefix & ";shot\n1;2\n")
    writeFile(longer, prefix & "X;shot\n3;4\n")
    writeFile(other, prefix & "Y;shot\n5;6\n")
    var st = start(root / "config-long-header")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: exact)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    var changed = st.shotLogMap(0)
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence)
    doAssert st.project.doc.lastShotMap.isSome and
      st.project.doc.lastShotMap.get.headers[0] == prefix
    let said = st.timesSaid(ColumnsAsLast)
    st.apply Command(kind: ckImportShotLog, logPath: longer)
    doAssert st.settle(st.shotLogCount == 2 and st.jobs.active.len == 0),
      "the long import did not finish"
    doAssert st.shotLogMap(1).roles[1] == crShotPoint, "a long header used the remembered map"
    doAssert st.timesSaid(ColumnsAsLast) == said, "a long header said the remembered sentence"
    var longMap = st.shotLogMap(1)
    longMap.roles[1] = crFileNumber
    st.apply Command(kind: ckRemapShotLog, logIndex: 1, logMap: longMap)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(1).roles[1] == crFileNumber)
    doAssert st.project.doc.lastShotMap.get.headers[0] == prefix, "a long header was remembered"
    doAssert st.project.doc.lastShotMap.get.map.roles[1] == crSequence,
      "re-mapping a long header was remembered"
    st.apply Command(kind: ckImportShotLog, logPath: other)
    doAssert st.settle(st.shotLogCount == 3 and st.jobs.active.len == 0)
    doAssert st.shotLogMap(2).roles[1] == crShotPoint,
      "another long header used the remembered map"
    doAssert st.timesSaid(ColumnsAsLast) == said
    discard st.shutdown()

  block extra_column_is_guessed:
    let job = root / "JobWide"
    let table = root / "wide-base.csv"
    let wide = root / "wide.csv"
    writeFile(table, Table)
    writeFile(wide, TableWide)
    var st = start(root / "config-wide")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    var changed = st.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence)
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.settle(st.shotLogCount == 0 and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: wide)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the wide import did not finish"
    doAssert st.shotLogWidth(0) == 4, "the extra column was not read"
    doAssert st.shotLogMap(0).roles[1] == crShotPoint, "an extra column used the remembered map"
    doAssert not st.said(ColumnsAsLast), "a guess said the remembered sentence"
    discard st.shutdown()

  block renamed_header_is_guessed:
    let job = root / "JobRenamed"
    let table = root / "renamed-base.csv"
    let renamed = root / "renamed.csv"
    writeFile(table, Table)
    writeFile(renamed, TableRenamed)
    var st = start(root / "config-renamed")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    var changed = st.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence)
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.settle(st.shotLogCount == 0 and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: renamed)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the renamed import did not finish"
    doAssert st.shotLogMap(0).roles[1] == crShotPoint,
      "a renamed header used the remembered map"
    doAssert not st.said(ColumnsAsLast), "a guess said the remembered sentence"
    discard st.shutdown()

  block given_map_wins:
    let job = root / "JobGiven"
    let table = root / "given.csv"
    writeFile(table, Table)
    var st = start(root / "config-given")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    var changed = st.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence)
    var given = changed
    given.roles = @[crText, crText, crText]
    st.apply Command(kind: ckImportShotLog, logPath: table, logMap: given, logMapped: true)
    doAssert st.settle(st.shotLogCount == 2 and st.jobs.active.len == 0),
      "the given import did not finish"
    doAssert st.shotLogMap(1).roles == @[crText, crText, crText], "the given map was not used"
    doAssert not st.said(ColumnsAsLast), "a given map said the remembered sentence"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 3 and st.jobs.active.len == 0),
      "the import after a given map did not finish"
    doAssert st.shotLogMap(2).roles == @[crText, crText, crText],
      "the given map was not remembered"
    doAssert st.said(ColumnsAsLast)
    discard st.shutdown()

  block old_project_has_no_last_map:
    let job = root / "JobOldMap"
    let table = root / "old-map.csv"
    writeFile(table, Table)
    var st = start(root / "config-old-map")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and fileExists(job.projectDirOf.documentOf) and
      st.jobs.active.len == 0)
    st.flushFiles()
    doAssert "lastShotMap" notin readFile(job.projectDirOf.documentOf)
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "an old project did not open"
    doAssert st.project.doc.lastShotMap.isNone
    doAssert not st.said("left out") and not st.said("could not be read")
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    doAssert st.shotLogMap(0).roles[1] == crShotPoint, "an old project used a remembered map"
    doAssert not st.said(ColumnsAsLast)
    discard st.shutdown()

  block hostile_last_map_is_ignored:
    let job = root / "JobHostile"
    let table = root / "hostile.csv"
    writeFile(table, Table)
    var st = start(root / "config-hostile")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    let path = job.projectDirOf.documentOf
    let fresh = readFile(path)
    writeFile(path, fresh.replace("(version 1)",
      "(version 1) (lastShotMap (map (role \"not a role\")))"))
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "a hostile map stopped the open"
    doAssert st.project.doc.lastShotMap.isNone, "a hostile map was stored"
    doAssert st.project.doc.name.len > 0
    doAssert st.said("not a column role"), "the bad role was not said"
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    doAssert st.shotLogMap(0).roles[1] == crShotPoint, "a hostile map was used"
    doAssert not st.said(ColumnsAsLast)
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    var roles = ""
    for i in 1 .. 300: roles.add " (role \"text\")"
    writeFile(path, fresh.replace("(version 1)",
      "(version 1) (lastShotMap (map" & roles & "))"))
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0),
      "too many columns stopped the open"
    doAssert st.project.doc.lastShotMap.isNone, "an oversized map was stored"
    doAssert st.said("left out"), "too many columns were not said"
    discard st.shutdown()

  block read_only_uses_the_map:
    let job = root / "JobRoMap"
    let table = root / "ro-map.csv"
    writeFile(table, Table)
    var holder = start(root / "config-ro-map")
    holder.apply Command(kind: ckNewProject, projectPath: job)
    doAssert holder.settle(holder.inProject and holder.jobs.active.len == 0)
    holder.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert holder.settle(holder.shotLogCount == 1 and holder.jobs.active.len == 0)
    var changed = holder.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    holder.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert holder.settle(holder.jobs.active.len == 0 and
      holder.shotLogMap(0).roles[1] == crSequence)
    holder.flushFiles()
    let doc = job.projectDirOf.documentOf
    doAssert "(lastShotMap" in readFile(doc)
    var other = start(root / "config-ro-map-2")
    other.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert other.settle(other.inProject and other.project.readOnly and
      other.jobs.active.len == 0), "the second program did not open read-only"
    let before = readFile(doc)
    other.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert other.settle(other.shotLogCount == 2 and other.jobs.active.len == 0),
      "the read-only import did not finish"
    doAssert other.shotLogMap(1).roles == @[crText, crSequence, crText],
      "a read-only project did not use the remembered map"
    doAssert other.said(ColumnsAsLast)
    doAssert other.shotLogStored(1).len == 0
    doAssert readFile(doc) == before, "a read-only project wrote project.nif"
    doAssert other.project.doc.lastShotMap.get.map.roles[1] == crSequence
    let wide = root / "ro-wide.csv"
    writeFile(wide, TableWide)
    other.apply Command(kind: ckImportShotLog, logPath: wide)
    doAssert other.settle(other.shotLogCount == 3 and other.jobs.active.len == 0),
      "the wide read-only import did not finish"
    doAssert other.shotLogMap(2).roles[1] == crShotPoint, "an extra column was not guessed"
    doAssert other.project.doc.lastShotMap.get.map.roles[1] == crSequence,
      "a read-only project remembered a new map"
    doAssert readFile(doc) == before, "a read-only project wrote project.nif"
    discard other.shutdown()
    discard holder.shutdown()

  block no_project_does_not_remember:
    let table = root / "session.csv"
    writeFile(table, Table)
    var st = start(root / "config-session")
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0),
      "the log was not kept for the session"
    var changed = st.shotLogMap(0)
    changed.roles[0] = crText
    changed.roles[1] = crSequence
    st.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: changed)
    doAssert st.settle(st.jobs.active.len == 0 and st.shotLogMap(0).roles[1] == crSequence)
    st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
    doAssert st.shotLogCount == 0
    st.apply Command(kind: ckImportShotLog, logPath: table)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    doAssert st.shotLogMap(0).roles[1] == crShotPoint, "a session remembered a map"
    doAssert not st.said(ColumnsAsLast)
    doAssert st.said(ShotLogNotStored)
    discard st.shutdown()

  removeDir(root)
  echo "tshotlogjobs: ok"

when isMainModule: main()
