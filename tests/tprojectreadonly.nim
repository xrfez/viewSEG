## A project opened by a second program (docs/project.md), without a window:
##
## - the second program is read-only and "Forget them" (`ckForgetFiles`)
##   removes nothing: the holder's document of a file's kills stays;
## - a lock file that cannot be opened (mode 000) is said as such, with the
##   OS error, and not as "another program has it open" (the owner's note).
##   Skipped as root, which opens any file.
##
## Seen to fail: with `forgetFiles` not checking `readOnly`, "the holder's
## document is kept" (the document was removed); with the lock's open
## failure given the owner's note, "cannot be opened" (the reason named the
## owner, "has it open").
import std/[os, strutils]
import parseSEG
import viewSEG/core/[join, project, state, survey]
import utils/[faultyfs, fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path

proc said(st: AppState; words: string): bool =
  for e in st.log:
    if words in e.text: return true

proc docs(dir: string): seq[string] =
  for k, p in walkDir(dir):
    if p.endsWith(".nif"): result.add p.extractFilename

proc main*() =

  withFixtures fx:
    installSteps()
    let field = fx.dir / "field"
    createDir(field)
    let a = field / "a.sgy"
    copyFile(fx.manyTracesSegy(200, 40), a)
    let job = fx.dir / "Job"
    let config = fx.dir / "config"
    block readOnlyForget:
      var st = start(config)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject)
      st.showFile(a)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
        edited: @[st.sessions[0].base + 5], on: true)
      doAssert st.settle(st.remembering(a).confirmed)
      st.flushFiles()
      doAssert st.settle(docs(job / "files").len == 1)
      let d = docs(job / "files")[0]
      var other = start(config)
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject)
      doAssert other.project.readOnly
      other.apply Command(kind: ckForgetFiles, forget: @[d])
      other.flushFiles()
      var said = false
      for e in other.log:
        if "open read-only" in e.text: said = true
      doAssert said, "the refusal is not said"
      discard other.settle(other.jobs.active.len == 0)
      doAssert fileExists(job / "files" / d), "a read-only program removed a document"
      other.shutdown()
      st.shutdown()
    block lockOpen:
      # a lock file nobody can open (mode 000) is said as such, not as another
      # program's; as root every file opens, so there is nothing to test
      let j2 = fx.dir / "Job2"
      var st2 = start(config)
      st2.apply Command(kind: ckNewProject, projectPath: j2)
      doAssert st2.settle(st2.inProject)
      st2.apply Command(kind: ckCloseProject)
      discard st2.settle(not st2.inProject and st2.jobs.active.len == 0)
      st2.shutdown()
      let lock = j2 / LockName
      setFilePermissions(lock, {})
      var openable = true
      try: close(open(lock, fmRead))
      except IOError: openable = false
      if openable:
        echo "tprojectreadonly: lock open case skipped (running as root)"
      else:
        var s2 = start(config)
        s2.apply Command(kind: ckOpenProject, projectPath: j2)
        doAssert s2.settle(s2.inProject)
        doAssert s2.project.readOnly and "cannot be opened" in s2.project.whyReadOnly and
          "has it open" notin s2.project.whyReadOnly, s2.project.whyReadOnly
        s2.shutdown()
      setFilePermissions(lock, {fpUserRead, fpUserWrite})
    block newSurveyNotKept:
      # a new project whose lock cannot be opened is read-only: the session's
      # survey is not copied into it (nothing under survey/ is written)
      install()
      let survey = fx.surveySps()
      let job = fx.dir / "Unkept"
      var st = start(config)
      st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps),
        JoinFile(path: survey.x, kind: jkSps)])
      doAssert st.settle(not st.importing and st.survey.layers.len > 0)
      fault(job / LockName, fkFail, {foOpen})
      st.apply Command(kind: ckNewProject, projectPath: job, useSurvey: true)
      doAssert st.settle(st.inProject and st.project.readOnly)
      doAssert st.settle(st.said("is not kept in the project")), "the refusal is not said"
      discard st.settle(st.jobs.active.len == 0)
      doAssert not fileExists(job / "survey" / "survey.bin"), "survey.bin was written"
      if dirExists(job / "survey" / "files"):
        var copies = 0
        for k, p in walkDir(job / "survey" / "files"): inc copies
        doAssert copies == 0, "a survey file was copied into a read-only project: " & $copies
      fault(job / LockName, fkNone)
      st.shutdown()
  echo "tprojectreadonly: done"

when isMainModule:
  main()
