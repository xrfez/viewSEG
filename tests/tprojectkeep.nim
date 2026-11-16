## The survey kept in a project: the copy of the survey files and
## `survey.bin` (docs/project.md).
##
## - An import's files, options and units are written to project.nif at once,
##   as "being copied": Close project, or a quit, while the copy runs loses
##   nothing, and the next open copies it (the survey is on the map then).
##   "Copied into the project" is said only when it is true.
##
## - A survey original is never looked at while the project opens: a job of
##   its own does it afterwards, and records the new time of a file touched.
##
## - A survey.bin that is rejected (damaged) is made again from the copies in
##   a writable project, and said.
##
## - A keep's temporary files are named for its job; two keeps never run at
##   once (the survey folder is exclusive); a cancel stops the copy.
##
## - Update from the original takes the identity after the copy (tried again
##   once when the original was written meanwhile), and is refused while the
##   survey is being copied in.
##
## - The layers of a restore a close cancelled do not land on the map.
##
## (Not seen to fail: a close's cancel already makes the inbox drop the job's
## messages, so `staleSurveyJobs` is a second guard.)
##
## - A resumed import takes only a file with the identity recorded when the
##   import began, at the path recorded; a hostile project.nif cannot make
##   the open copy another file.
##
## Seen to fail: with the temporary name of `survey.bin` made from the
## process id, "the temporary name"; with the originals looked at inside `openProjectWork`, "the
## originals were looked at before the open ended"; with `markImporting` not called, "the import is not in
## project.nif"; with the open not taking an import up, "the survey was not
## copied at the next open".
import std/[os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[identity, project, projectnif, state]
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
      doAssert st.settle(st.project.survey == srKeeping and st.said("is being copied") and
        st.project.doc.importing.allIt(it.known)),
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
      for _ in 0 ..< 50: # the quit's straggler may still hold the lock for a moment
        st.apply Command(kind: ckOpenProject, projectPath: job)
        doAssert st.settle(st.inProject)
        if not st.project.readOnly: break
        st.shutdown()
        sleep 100
        st = start(config)
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
  block originalsApart:
    # A touched original (a new time, the same bytes): the open does not wait for
    # it, it is looked at on a job of its own, and its new time is recorded.
    let job = fx.dir / "Job touch"
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    st.flushFiles()
    st.shutdown()
    let t1 = initTime(getTime().toUnix - 5000, 0)
    setLastModificationTime(survey.s, t1)
    holdStep("looking at survey.s")
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded),
      "the open waited for an original"
    doAssert again.project.originals.len == 3 and again.project.originals[0].state == osLooking,
      "the originals were looked at before the open ended: " & $again.project.originals[0].state
    releaseStep("looking at survey.s")
    doAssert again.settle(again.project.originals.allIt(it.state == osAsCopied)),
      "the originals were not looked at afterwards"
    doAssert again.project.doc.survey[0].modified == t1, "the new time was not recorded"
    again.flushFiles()
    again.shutdown()
    var third = start(config)
    third.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert third.settle(third.project.originals.len == 3 and
      third.project.originals.allIt(it.state == osAsCopied))
    doAssert not third.project.originals[0].confirmed, "read whole again at the next open"
    third.shutdown()
  block damagedStore:
    # survey.bin of the right size but damaged (its hash fails): made again
    # from the copies, and said, not "Import the survey again".
    let job = fx.dir / "Job damaged"
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    let bytes = st.project.doc.store.bytes
    st.flushFiles()
    st.shutdown()
    var bin = readFile(job / "survey" / "survey.bin")
    bin[bin.len div 2] = char(ord(bin[bin.len div 2]) xor 0x55)
    writeFile(job / "survey" / "survey.bin", bin)
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded and
      again.said("made again from the copies")), "not made again: " & $again.project.survey &
      " " & again.project.surveyNote
    doAssert again.surveyLayers == 3, "the survey is not on the map: " & $again.surveyLayers
    doAssert not again.said("Import the survey again")
    again.flushFiles()
    again.shutdown()
    doAssert getFileSize(job / "survey" / "survey.bin") == bytes
    var third = start(config)
    third.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert third.settle(third.inProject and third.project.survey == srLoaded)
    doAssert not third.said("made again from the copies"), "damaged again"
    third.shutdown()
  block ownTemporaryNames:
    # A keep's temporary files are named for its job, so that two jobs never
    # share one; a second import while the first is held begins after it, and
    # ends whole with no temporary file left.
    let job = fx.dir / "Job twice"
    holdStep("keeping survey.s")
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(inStep("keeping survey.s").len == 1)
    let id = int(inStep("keeping survey.s")[0])
    var temps: seq[string] = @[]
    for f in walkFiles(job / "survey" / "*.tmp"): temps.add f.extractFilename
    doAssert temps == @["survey.bin." & $id & ".tmp"], "the temporary name: " & $temps
    st.importSurvey(survey) # cancels the first, which waits in its step
    for _ in 0 ..< 30:
      discard st.drainInbox()
      st.persist()
      sleep 10
    doAssert inStep("keeping survey.s").len == 1, "two keeps ran at once"
    releaseStep("keeping survey.s")
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport), "the second import did not end: " & $st.project.survey
    st.flushFiles()
    st.shutdown()
    for dir in [job / "survey", job / "survey" / "files"]:
      for f in walkFiles(dir / "*.tmp"): doAssert false, "a temporary file is left: " & f
  block updateWhileWritten:
    # An original written while Update copies it: the identity recorded is
    # that of the copy (taken after, and the same as before, or tried again).
    let job = fx.dir / "Job update"
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    st.flushFiles()
    st.shutdown()
    proc grow(path: string) =
      var sf = readSps(path)
      var p = sf.points[^1]
      p.point += 1
      p.pointName = ""
      p.easting += 50
      sf.points.add p
      sf.order.setLen 0
      sleep 20 # a later modification time
      doAssert writeSps(sf, path).len == 0
    grow(survey.s)
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded and
      again.project.offer)
    holdStep("copying survey.s into the project again")
    again.apply Command(kind: ckUpdateSurvey)
    doAssert again.settle(inStep("copying survey.s into the project again").len == 1)
    again.apply Command(kind: ckUpdateSurvey) # not while it is being copied
    doAssert again.said("is being copied into the project")
    grow(survey.s) # written while it is copied
    releaseStep("copying survey.s into the project again")
    doAssert again.settle(again.project.survey == srLoaded and not again.project.offer and
      again.project.originals.allIt(it.state == osAsCopied)), "the update did not end: " &
      $again.project.survey & " " & again.project.surveyNote
    doAssert again.project.doc.survey[0].size == getFileSize(survey.s),
      "the identity recorded is not that of the copy"
    doAssert readFile(job / "survey" / "files" / "survey.s") == readFile(survey.s)
    again.shutdown()
  block staleRestore:
    # The layers of a restore that ended before a close, still in the inbox
    # when the project is closed, do not land on the map.
    let job = fx.dir / "Job stale"
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    st.flushFiles()
    st.shutdown()
    holdStep("making the survey kept in the project")
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and
      inStep("making the survey kept in the project").len == 1)
    let id = inStep("making the survey kept in the project")[0]
    releaseStep("making the survey kept in the project")
    doAssert waitUntil(cameBack(id)), "the restore did not end"
    again.apply Command(kind: ckCloseProject) # its layers are in the inbox still
    discard again.drainInbox()
    doAssert again.surveyLayers == 0, "the cancelled restore's layers landed on the map: " &
      $again.surveyLayers
    again.shutdown()
  block hostileImport:
    # A project.nif that names an import to resume copies nothing it was not
    # recorded as: no identity, or another file's, is refused with a message,
    # and the entry is cleared.
    let secret = fx.dir / "secret.txt"
    writeFile(secret, "private\n".repeat(20_000))
    var t: Time
    let real = quickIdentity(secret, t)
    for how in ["no identity", "other size", "replaced after"]:
      let job = fx.dir / ("Job hostile " & how)
      var st = start(config)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      st.flushFiles()
      st.shutdown()
      var problems: seq[string]
      var doc = readProject(readFile(job / "project.nif"), "project.nif", problems)
      var f = ImportFile(kind: jkSps, original: ProjectPath(absolute: secret))
      if how != "no identity":
        (f.known, f.size, f.modified, f.quick) = (true, real.size, t, real.quick)
      if how == "other size": f.size += 1
      doc.importing = @[f]
      writeFile(job / "project.nif", projectDocument(doc))
      if how == "replaced after": writeFile(secret, "other\n".repeat(20_000))
      var again = start(config)
      again.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert again.settle(again.inProject and again.project.survey == srFailed),
        how & ": the open did not refuse it: " & $again.project.survey
      doAssert again.said("interrupted and its files are not as they were"), how & ": not said"
      doAssert not fileExists(job / "survey" / "files" / "secret.txt"), how & ": copied"
      doAssert not again.project.doc.hasImport, how & ": the entry stays"
      again.flushFiles()
      again.shutdown()
      for f in walkFiles(job / "survey" / "files" / "*"): doAssert false, "a copy is left: " & f
      writeFile(secret, "private\n".repeat(20_000))
echo "tprojectkeep: done"
