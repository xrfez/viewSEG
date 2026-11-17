## A project's survey copies named in project.nif (`core/projectnif`,
## `core/projectjobs`), without a window:
##
## - a survey `copy` that is not `survey/files/<plain name>` ("../victim.sps",
##   "survey/files/../victim.sps", "." or "") is refused by the reader, so it
##   never names a place outside `survey/files/`;
## - a project whose document names such a copy is opened, and the file it
##   names outside the project is still there afterwards;
## - keeping the survey's copies (`keepSurveyWork`) removes a copy named
##   outside `survey/files/` never, even when handed one.
##
## Seen to fail: with the reader's check left out, "a copy outside the
## project is refused" (the problem list was empty) and "a file outside the
## project was removed on open" (the file was deleted); with the parent check
## in `keepSurveyWork` left out, "a copy outside survey/files is kept".
import std/[os, strutils, times]
import parseSEG
import viewSEG/core/[inbox, jobs, join, project, projectjobs, projectnif, state, survey]
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc main*() =

  block reader:
    var problems: seq[string]
    for bad in ["../victim.sps", "a.sps", "survey/files/../victim.sps",
        "survey/files/a/b.sps", "survey/files/a\\b.sps", "survey/files/c:x.sps",
        "survey/files/.", "survey/files/..", "survey/files/", ""]:
      var d = ProjectDoc(name: "Job", created: getTime())
      d.survey = @[SurveyCopy(kind: jkSps, copy: bad, size: 1, quick: 1)]
      problems.setLen 0
      discard readProject(projectDocument(d), "project.nif", problems)
      doAssert problems.len == 1 and "copy" in problems[0], "refused: " & bad & " " & $problems
    problems.setLen 0
    var ok = ProjectDoc(name: "Job", created: getTime())
    ok.survey = @[SurveyCopy(kind: jkSps, copy: "survey/files/a.sps", size: 1, quick: 1)]
    let back = readProject(projectDocument(ok), "project.nif", problems)
    doAssert problems.len == 0 and back.survey.len == 1, $problems

  withFixtures fx:
    let sv = fx.surveySps()
    let victim = fx.dir / "victim.sps"
    copyFile(sv.s, victim)
    let job = fx.dir / "Job"
    createDir(job / "survey" / "files")
    var d = ProjectDoc(name: "Job", created: getTime())
    d.survey = @[SurveyCopy(kind: jkSps, copy: "../victim.sps",
      original: ProjectPath(absolute: "/nowhere/x.sps"), size: 1, quick: 1)]
    writeFile(job / ProjectFileName, projectDocument(d))
    var st = initAppState()
    st.rememberFilesIn(fx.dir / "config")
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    discard st.settle(st.jobs.active.len == 0)
    doAssert fileExists(victim), "a file outside the project was removed on open"
    st.shutdown()

  block keepOutside:
    withFixtures fx:
      let victim = fx.dir / "victim.sps"
      writeFile(victim, "not a copy")
      let job = fx.dir / "Job"
      createDir(job / "survey" / "files")
      let box = initInbox()
      let jobs = initJobs()
      let work = keepSurveyWork(job, @[], @[SurveyCopy(kind: jkSps, copy: "../victim.sps")],
        box.poster)
      let id = jobs.submit(JobSpec(title: "t", lane: jlBackground), work)
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
      doAssert fileExists(victim), "a copy named outside survey/files was removed"
  block oddNames:
    # survey files whose names hold characters a copy's name cannot (':' and
    # '\', legal on Linux): kept as copies with safe names, so a reopened project
    # still has all of them
    withFixtures fx:
      let survey = fx.surveySps()
      let field = fx.dir / "field"
      createDir field
      let s2 = fx.dir / "day:1.s"
      let r2 = fx.dir / "a\\b.r"
      copyFile(survey.s, s2)
      copyFile(survey.r, r2)
      let config = fx.dir / "config"
      let job = fx.dir / "Job"
      var st = initAppState()
      st.rememberFilesIn(config)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
        JoinFile(path: s2, kind: jkSps), JoinFile(path: r2, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps)])
      doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore),
        $st.project.survey & " " & st.project.surveyNote
      doAssert st.project.doc.survey.len == 3
      st.flushFiles()
      st.shutdown()
      var again = initAppState()
      again.rememberFilesIn(config)
      again.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert again.settle(again.inProject and again.project.survey in {srLoaded, srFailed})
      doAssert again.project.doc.survey.len == 3, "a survey file was dropped: " &
        $again.project.doc.survey.len
      again.flushFiles()
      again.shutdown()
  echo "tprojectpaths: done"

when isMainModule:
  main()
