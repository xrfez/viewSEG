## Clear shot log in `core`, without a window (`ckClearShotLog`, Project > Clear shot log...):
##
## - no log loaded: the command is ignored, and the log says so;
## - outside a project: every loaded log is gone (the count, the map's shot layers), the file it
##   was read from is the same bytes and still there, and the log said how many were cleared;
## - in a project: the document and the copy under `shotlogs/` are gone, a project saved and
##   opened again has no log, and the remembered column map is left as it was;
## - several logs are all cleared by one command;
## - a log read while the command comes: the read is cancelled and nothing of it arrives later;
## - a read-only project keeps its log and the command is ignored with the reason;
## - a project whose document names a copy that is gone: Clear shot log is allowed with no log
##   loaded, the document on disk is written before the copy's removal job ends (no flush), and
##   a reopen says nothing about an unreadable log.
##
## Seen to fail: with the project's document left as it was, "a cleared log came back" after the
## reopen; with the copies' removal left out, "the copy was kept"; with the jobs under way not
## cancelled, "a log arrived after Clear"; with the map's layers kept, "the map keeps the shot
## layer"; with `shotLogsHeld` counting only loaded logs, "an unreadable entry cannot be
## cleared"; with the document left to `SaveDelay`, "the document still names the copy".

import std/[os, options, strutils]
import viewSEG/core/[filesystem, project, shotlog, state, survey]
import utils/[steps, waiting]

const Sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shotlog.csv"

proc said(st: AppState; words: string): bool =
  for e in st.log:
    if words in e.text: return true

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc shotLayers(st: AppState): int =
  for l in st.survey.layers:
    if l.origin == loShotLog: inc result

proc main*() =
  let root = getTempDir() / ("viewseg-clearshotlog-" & $getCurrentProcessId())
  createDir(root)
  defer: removeDir(root)
  let original = readFile(Sample)
  let second = root / "second.csv"
  writeFile(second, original)

  block nothing_to_clear:
    var st = start(root / "config-none")
    doAssert st.cutMenuProblem == CutNeedLog
    st.apply Command(kind: ckClearShotLog)
    doAssert st.said("no shot log is loaded"), "nothing to clear is ignored"
    discard st.shutdown()

  block outside_a_project:
    var st = start(root / "config-out")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    st.apply Command(kind: ckImportShotLog, logPath: second)
    doAssert st.settle(st.shotLogCount == 2 and st.jobs.active.len == 0), "the logs were not read"
    doAssert st.shotLayers == 2
    st.apply Command(kind: ckClearShotLog)
    doAssert st.shotLogCount == 0, "a log was kept"
    doAssert st.shotLayers == 0, "the map keeps the shot layer"
    doAssert st.said("2 logs"), "the count is not said"
    doAssert readFile(Sample) == original and readFile(second) == original,
      "the log file changed"
    doAssert st.cutMenuProblem == CutNeedLog
    discard st.shutdown()
    doAssert readFile(Sample) == original

  block in_a_project:
    let job = root / "JobClear"
    var st = start(root / "config-in")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0), "the project did not open"
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    let copy = job.partOf(st.shotLogStored(0).shotLogCopy)
    doAssert st.settle(fileExists(copy) and st.jobs.active.len == 0), "no copy was written"
    let remembered = st.project.doc.lastShotMap.isSome
    doAssert remembered, "the import remembered no map"
    st.apply Command(kind: ckClearShotLog)
    doAssert st.shotLogCount == 0
    doAssert st.project.doc.shotLogs.len == 0, "the project keeps the log"
    doAssert st.settle(not fileExists(copy) and st.jobs.active.len == 0), "the copy was kept"
    doAssert st.project.doc.lastShotMap.isSome == remembered, "the remembered map changed"
    doAssert readFile(Sample) == original, "the log file changed"
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    doAssert st.shotLogCount == 0, "a cleared log came back"
    discard st.shutdown()

  block a_read_under_way:
    var st = start(root / "config-way")
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    st.apply Command(kind: ckClearShotLog)
    doAssert not st.said("no shot log is loaded"), "a read under way is a log to clear"
    doAssert st.settle(st.jobs.active.len == 0)
    doAssert st.shotLogCount == 0, "a log arrived after Clear"
    discard st.shutdown()

  block read_only_keeps_the_log:
    let job = root / "JobRo"
    var holder = start(root / "config-holder")
    holder.apply Command(kind: ckNewProject, projectPath: job)
    doAssert holder.settle(holder.inProject and holder.jobs.active.len == 0)
    holder.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert holder.settle(holder.shotLogCount == 1 and holder.jobs.active.len == 0)
    holder.flushFiles()
    var other = start(root / "config-other")
    other.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert other.settle(other.inProject and other.project.readOnly and
      other.shotLogCount == 1 and other.jobs.active.len == 0)
    other.apply Command(kind: ckClearShotLog)
    doAssert other.shotLogCount == 1, "a read-only project lost its log"
    doAssert other.said("read-only"), "the refusal is not said"
    discard other.shutdown()
    discard holder.shutdown()

  block an_unreadable_entry:
    let job = root / "JobGone"
    var st = start(root / "config-gone")
    st.apply Command(kind: ckNewProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    st.apply Command(kind: ckImportShotLog, logPath: Sample)
    doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
    let copy = job.partOf(st.shotLogStored(0).shotLogCopy)
    doAssert st.settle(fileExists(copy) and st.jobs.active.len == 0), "no copy was written"
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
    removeFile(copy)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject and st.jobs.active.len == 0)
    doAssert st.shotLogCount == 0 and st.project.doc.shotLogs.len == 1
    doAssert st.shotLogsHeld == 1, "the entry cannot be cleared"
    st.apply Command(kind: ckClearShotLog)
    doAssert not st.said("no shot log is loaded"), "the entry was ignored"
    doAssert st.settle(st.jobs.active.len == 0)
    doAssert st.project.doc.shotLogs.len == 0
    doAssert not readFile(documentOf(job)).contains("shotlog"),
      "the document on disk still names the copy"
    discard st.shutdown()
    var again = start(root / "config-gone-again")
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.jobs.active.len == 0)
    doAssert not again.said("could not be read"), "the reopen still reads the copy"
    doAssert again.shotLogsHeld == 0
    discard again.shutdown()
  echo "tclearshotlog: ok"

when isMainModule: main()
