## Clear survey in `core`, without a window (`ckClearSurvey`, File > Import >
## Clear survey), on a synthetic SEG-D record and an SPS survey (S, R, X):
##
## - outside a project: after the import the trace keys hold the survey's
##   coordinates; Clear gives the file's own back (the file is read again), the
##   survey files are off the map, no file is joined, no survey is in effect,
##   and the file on disk is the same bytes; a fresh session opening the file
##   has none either; with nothing imported the command is ignored;
## - in a project: the project's document, its copies and `survey.bin` lose
##   the survey, and it does not come back when the project is closed and
##   opened again (the file opened there has its own keys); an agent's clear
##   in a project is refused (it would write into the project);
## - while an import reads its files, and while its step changes the keys: the
##   import is cancelled, nothing of it is applied afterwards (no join, no
##   layer, the keys the file's own).
##
## Seen to fail: with the clearing of the keys left out (`dropKeys`), "the
## keys are the survey's still"; with `cleared` not checked when the join's job
## ends, "the survey was applied after Clear" (a join recorded after the
## clear); with the project's document left as it was, "the project keeps
## the survey"; with the copies' removal left out, "the copies are still in
## the project".

import std/[os, sequtils, strutils]
import parseSEG
import viewSEG/core/[filesystem, state]
import utils/[fixtures, steps, waiting]

proc sps(paths: varargs[string]): seq[JoinFile] =
  for p in paths: result.add JoinFile(path: p, kind: jkSps)

proc surveyFiles(st: AppState): int =
  for l in st.survey.layers:
    if l.origin == loSurveyFile: inc result

proc keys(st: AppState; t: int): TraceKeys = st.sessions[0].file.index.keys[t]

proc opened(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.survey.findTraces(st.sessions[0].id) >= 0), "the file was not shown"

proc join(st: var AppState; files: seq[JoinFile]) =
  let before = st.joinReport.serial
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files,
    joinUnits: JoinUnits(survey: suMetres))
  doAssert st.settle(st.joinReport.serial > before and not st.importing), "the join did not end"
  doAssert st.joinReport.outcome == joJoined, st.joinReport.words.join(" ")

proc cleared(st: var AppState; path: string): bool =
  ## The survey is gone and the file is shown again, opened anew.
  st.settle(not st.surveyInEffect and st.joins.len == 0 and st.sessions.len == 1 and
    st.sessions[0].path == path and st.panel(MainPanel).laidOut and
    st.survey.findTraces(st.sessions[0].id) >= 0 and st.jobs.active.len == 0)

proc main*() =

  block outsideProject:
    withFixtures fx:
      let path = fx.stationsSegd()
      let survey = fx.surveySps()
      let bytes = readFile(path)
      var st = initAppState()
      st.opened(path)
      let own = st.keys(1)
      st.apply Command(kind: ckClearSurvey)
      doAssert st.log[st.log.len - 1].text.contains("no survey is imported"),
        "nothing to clear is ignored"
      doAssert not st.surveyInEffect
      st.join(sps(survey.s, survey.r, survey.x))
      doAssert st.surveyInEffect and st.surveyFiles == 3
      doAssert st.keys(1).rcvX != own.rcvX, "the survey's coordinates are in the keys"
      st.apply Command(kind: ckClearSurvey)
      doAssert st.cleared(path), "the survey was not cleared: " & $st.surveyFiles
      doAssert st.surveyFiles == 0, "the map keeps survey files"
      doAssert st.keys(1).rcvX == own.rcvX and st.keys(1).srcX == own.srcX,
        "the keys are the survey's still: " & $st.keys(1).rcvX
      doAssert st.survey.findTraces(st.sessions[0].id) >= 0, "the file's own positions are back"
      doAssert readFile(path) == bytes, "the seismic file changed"
      doAssert fileExists(survey.s) and fileExists(survey.r) and fileExists(survey.x)
      # Gone for good: this session's state, and a new one.
      st.apply Command(kind: ckReopen, reopenPath: path)
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1)
      doAssert not st.surveyInEffect and st.keys(1).rcvX == own.rcvX, "it came back"
      st.shutdown()
      var fresh = initAppState()
      fresh.opened(path)
      doAssert not fresh.surveyInEffect and fresh.keys(1).rcvX == own.rcvX
      fresh.shutdown()
      echo "tclearsurvey: cleared outside a project"

  block onTheMapOnly:
    withFixtures fx:
      let survey = fx.surveySps()
      var st = initAppState()
      st.apply Command(kind: ckLoadSurvey, paths: @[survey.s, survey.r])
      doAssert st.settle(st.surveyFiles == 2 and not st.importing)
      doAssert st.surveyInEffect
      st.apply Command(kind: ckClearSurvey)
      doAssert st.surveyFiles == 0 and not st.surveyInEffect, "the map keeps survey files"

  block inProject:
    withFixtures fx:
      let field = fx.dir / "field"
      createDir(field)
      let record = field / "stations-only.sgd"
      moveFile(fx.stationsSegd(), record)
      let survey = fx.surveySps()
      let job = fx.dir / "Job 7"
      let config = fx.dir / "config"
      var own: TraceKeys
      block made:
        var st = initAppState()
        st.rememberFilesIn(config)
        st.opened(record)
        own = st.keys(5)
        st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
        doAssert st.settle(st.inProject and st.projectOpening.len == 0)
        st.join(sps(survey.s, survey.r, survey.x))
        doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore),
          "the survey was not kept"
        doAssert fileExists(job / "survey" / "survey.bin")
        # an agent's clear would write into the project: refused
        st.apply Command(kind: ckClearSurvey, origin: coAgent)
        doAssert st.project.doc.hasSurvey and st.surveyInEffect, "an agent cleared the project"
        st.apply Command(kind: ckClearSurvey)
        doAssert st.cleared(record), "not cleared"
        doAssert not st.project.doc.hasSurvey and st.project.survey == srNone,
          "the project keeps the survey"
        doAssert st.surveyFiles == 0 and st.keys(5).rcvX == own.rcvX
        doAssert st.settle(not fileExists(job / "survey" / "survey.bin") and
          not dirExists(job / "survey" / "files")), "the copies are still in the project"
        st.flushFiles()
        st.shutdown()
      doAssert "survey.s" notin readFile(job / "project.nif"), "the document names the survey"
      block reopened:
        var st = initAppState()
        st.rememberFilesIn(config)
        st.apply Command(kind: ckOpenProject, projectPath: job)
        doAssert st.settle(st.inProject and st.projectOpening.len == 0)
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: record)
        doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
        for _ in 1 .. 20: discard st.drainInbox()
        doAssert not st.project.doc.hasSurvey and not st.surveyInEffect and st.surveyFiles == 0,
          "the survey came back"
        doAssert st.keys(5).rcvX == own.rcvX, "the file was matched again"
        st.shutdown()
      echo "tclearsurvey: cleared in a project"

  block whileReading:
    withFixtures fx:
      let path = fx.stationsSegd()
      var st = initAppState()
      st.opened(path)
      let own = st.keys(1)
      let big = fx.bigSps(1000, 1000)
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: sps(big))
      doAssert st.importing and st.surveyInEffect
      st.apply Command(kind: ckClearSurvey)
      doAssert st.settle(not st.importing), "the import did not end"
      doAssert st.joinReport.outcome != joJoined, "the survey was applied after Clear"
      doAssert st.settle(not st.surveyLoading(big))
      doAssert st.joins.len == 0 and st.surveyFiles == 0 and not st.surveyInEffect,
        "the survey was applied after Clear"
      doAssert st.keys(1).rcvX == own.rcvX

  block whileMatching:
    withFixtures fx:
      let path = fx.stationsSegd()
      let survey = fx.surveySps()
      var st = initAppState()
      st.opened(path)
      let own = st.keys(1)
      installSteps()
      holdStep("matching")
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id,
        joinFiles: sps(survey.s, survey.r, survey.x), joinUnits: JoinUnits(survey: suMetres))
      doAssert st.settle(inStep("matching").len == 1), "the join's step runs"
      st.apply Command(kind: ckClearSurvey)
      releaseStep("matching")
      doAssert st.settle(not st.importing), "the import did not end"
      doAssert st.cleared(path), "not cleared: " & $st.joins.len & " " & $st.surveyFiles
      doAssert st.keys(1).rcvX == own.rcvX, "the keys are the survey's still"
      doAssert st.joinReport.outcome == joCancelled, "the survey was applied after Clear"

  echo "tclearsurvey: done"

when isMainModule:
  main()
