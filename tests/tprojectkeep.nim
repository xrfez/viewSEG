## The survey kept in a project: the copy of the survey files and
## `survey.bin` (docs/project.md).
##
## - An import's files, options and units are written to project.nif at once,
##   as "being copied": Close project, or a quit, while the copy runs loses
##   nothing, and the next open copies it (the survey is on the map then).
##   "Copied into the project" is said only when it is true.
##
## Seen to fail: with `markImporting` not called, "the import is not in
## project.nif"; with the open not taking an import up, "the survey was not
## copied at the next open".
import std/[os, strutils, times]
import parseSEG
import viewSEG/core/[project, state]
import utils/[fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc said(st: AppState; part: string): bool =
  for e in st.log:
    if part in e.text: return true
  false

proc surveyLayers(st: AppState): int =
  for l in st.survey.layers:
    if l.origin == loSurveyFile: inc result

proc importSurvey(st: var AppState; survey: tuple[s, r, x: string]) =
  st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
    JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
    JoinFile(path: survey.x, kind: jkSps)])

withFixtures fx:
  let field = fx.dir / "field"
  createDir(field)
  let survey = fx.surveySps()
  let config = fx.dir / "config"
  installSteps()

  for how in ["close", "quit"]:
    let job = fx.dir / ("Job " & how)
    block interrupted:
      holdStep("copying survey.r into the project")
      var st = start(config)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      st.importSurvey(survey)
      doAssert st.settle(st.project.survey == srKeeping and st.said("is being copied")),
        "the copy did not begin: " & $st.project.survey
      doAssert not st.said("is copied into"), "said copied before it was"
      if how == "close":
        st.apply Command(kind: ckCloseProject)
        doAssert st.said("still being copied")
        st.shutdown()
      else:
        st.shutdown(wait = initDuration(milliseconds = 300))
      releaseStep("copying survey.r into the project")
      let text = readFile(job / "project.nif")
      doAssert "(importing" in text and "survey.r" in text, "the import is not in project.nif"
      doAssert not fileExists(job / "survey" / "survey.bin")
    block resumed:
      var st = start(config)
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject and st.project.survey == srLoaded and
        st.project.doc.hasStore), "the survey was not copied at the next open: " &
        $st.project.survey & " " & st.project.surveyNote
      doAssert st.surveyLayers == 3, "the survey is not on the map: " & $st.surveyLayers
      for p in [survey.s, survey.r, survey.x]:
        doAssert fileExists(job / "survey" / "files" / p.extractFilename), p
      doAssert not st.project.doc.hasImport
      st.flushFiles()
      st.shutdown()
      doAssert "(importing" notin readFile(job / "project.nif")
echo "tprojectkeep: done"
