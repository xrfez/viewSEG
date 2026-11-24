## A batch write joins the project's survey for a file it opens itself, and
## the survey is the state's: closing the project, clearing the survey or
## importing another frees the state's copy. The state keeps the survey alive
## for the batch's job until the job has ended (`holdSurvey`), so a project
## closed while the job is in the middle of opening its file does not change
## what the job writes or crash it.
##
## The job is held at the open of its source by a file system hook; the test
## then closes the project, lets the job go on and checks the written
## positions are the survey the job started with.
##
## Seen to fail: with the `holdSurvey` call left out, the project's close freed
## the survey under the job: the written receiver X was not the survey's.
##
## Synthetic files only.
import std/[atomics, os, strutils]
import parseSEG
import viewSEG/core/[filememory, filesystem, jobs, outputbatch, outputjobs, state]
import utils/[fixtures, waiting]

var gate: Gate
var reached: Atomic[bool]
var mainThread: int

proc holdOpen(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    if op in {foOpen, foMapped} and path.endsWith("held.sgd") and getThreadId() != mainThread:
      reached.store(true)
      var waited = 0
      while not gate.isOpen and waited < 60_000:
        sleep 1
        inc waited

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc main*() =
  mainThread = getThreadId()
  withFixtures fx:
    let field = fx.dir / "field"
    createDir(field)
    let record = field / "stations-only.sgd"
    moveFile(fx.stationsSegd(), record)
    let survey = fx.surveySps()
    let job = fx.dir / "Job 1"
    var st = initAppState()
    st.rememberFilesIn(fx.dir / "config")
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
      JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
      JoinFile(path: survey.x, kind: jkSps)])
    doAssert st.settle(st.joinReport.serial > before and not st.importing)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore)
    let joined = st.sessions[0].file.index.keys[5]
    doAssert joined.rcvX != 0

    let src = fx.dir / "held"
    createDir(src)
    copyFile(record, src / "held.sgd")
    let ask = BatchAsk(root: src, items: @[BatchItem(source: src / "held.sgd",
      relative: "held.sgd")], destRoot: fx.dir / "held-out", mirrorFolders: true,
      options: OutputOptions(format: ofSegy, writeSessionPositions: true),
      project: BatchProject(survey: st.projectSurvey, options: st.project.doc.options,
      moves: st.project.doc.stationMoves, tableOnly: st.projectTableOnly))
    doAssert not ask.project.survey.isNil, "the project has no survey to join from"
    gate.close()
    reached.store(false)
    setFsHook(holdOpen)
    let sink = BatchSink()
    let id = st.jobs.submit(outputBatchSpec(ask), outputBatchWork(ask, Store(), @[], sink))
    st.holdSurvey(id)
    doAssert waitUntil(reached.load), "the job did not reach its file"
    st.apply Command(kind: ckCloseProject)
    doAssert st.settle(not st.inProject and st.sessions.len == 0), "the project did not close"
    doAssert st.projectSurvey.isNil
    gate.open
    doAssert st.settle(st.jobs.info(id).get.state == jsDone), "the batch did not finish: " &
      $st.jobs.info(id).get.state & " " & sink.result.reason
    setFsHook(nil)
    doAssert sink.result.written == 1, $sink.result
    var back = openSeismic(fx.dir / "held-out" / "held.sgy", keys = true)
    doAssert back.traceKeys(5).rcvX == joined.rcvX and back.traceKeys(5).srcX == joined.srcX,
      "the written positions are not the survey's: " & $back.traceKeys(5).rcvX & " vs " &
      $joined.rcvX
    back.close()
    st.shutdown()
  echo "toutputbatchhold: done"

when isMainModule:
  main()
