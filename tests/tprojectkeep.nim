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
##
## - A resumed import takes only a file with the identity recorded when the
##   import began, at the path recorded; a hostile project.nif cannot make
##   the open copy another file.
##
## - An Update refused (an original written during both tries) or cancelled
##   leaves the copies, the document and survey.bin as they were.
##
## Seen to fail: with `commitCopies` moving one by one with no set-aside, "the first copy
## was left replaced"; with `resolveResume` taking an absolute path outside the project and its data
## folders, "is not in the project or its data folders"; with it refusing a copy that is
## inside survey/files, "the cut-short import of the existing copies was not taken up"; with
## `sweepTemporaries` removing every `*.tmp`, "the survey file day1.tmp
## was swept"; with `exclusive` taken off the keep job, "two keeps ran at
## once" (the test waits past CancelGrace and StallAfter, when the lane gives
## the next job a runner of its own); with the temporary name of `survey.bin`
## made from the process id, "the temporary name"; with the originals looked
## at inside `openProjectWork`, "the originals were looked at before the open
## ended"; with `markImporting` not called, "the import is not in
## project.nif"; with the open not taking an import up, "the survey was not
## copied at the next open".
import std/[monotimes, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[identity, jobs, project, projectnif, state]
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

proc story(st: AppState): string =
  ## What the project and its jobs did, for a failed wait: the open's
  ## outcome, the project's messages and every job's end.
  result = "read-only " & $st.project.readOnly & ", import recorded " &
    $st.project.doc.hasImport
  for e in st.log:
    if e.source == "project": result.add "\n  said: " & e.text
  for j in st.jobs.list:
    result.add "\n  job " & j.spec.title & ": " & $j.state &
      (if j.cancelRequested: ", cancel asked" else: "") & (if j.error.len > 0: " (" &
      j.error & ")" else: "")

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
  # an import cut short is taken up again by itself only for originals in the
  # project's data folders
  let inField = (s: field / survey.s.extractFilename, r: field / survey.r.extractFilename,
    x: field / survey.x.extractFilename)
  for (src, dst) in [(survey.s, inField.s), (survey.r, inField.r), (survey.x, inField.x)]:
    copyFile(src, dst)
  installSteps()

  for how in ["close", "quit"]:
    let job = fx.dir / ("Job " & how)
    block interrupted:
      holdStep("copying survey.r into the project")
      var st = start(config)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      st.importSurvey(inField)
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
        st.project.doc.hasStore), "the survey was not copied at the next open (" & how &
        "): " & $st.project.survey & " " & st.project.surveyNote & "; " & st.story
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
    # the held look at an original delays no data file's hash
    let data = field / "d.sgy"
    copyFile(fx.manyTracesSegy(200, 40), data)
    again.apply Command(kind: ckShowFile, panel: MainPanel, path: data)
    doAssert again.settle(again.sessions.len >= 1 and again.remembering(data).known and
      again.panel(MainPanel).laidOut)
    again.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[again.sessions[0].base + 3], on: true) # a record to confirm
    # (within StallAfter: past it the lane would give the hash a runner of its own)
    doAssert waitUntil((discard again.drainInbox(); again.persist();
      again.remembering(data).confirmed), initDuration(seconds = 2)) and
      inStep("looking at survey.s").len == 1, "the hash waited for the original's look"
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
    # past CancelGrace and StallAfter the lane gives the next job a runner of
    # its own: only the exclusive survey folder keeps the second keep waiting
    let until = getMonoTime() + CancelGrace + StallAfter + initDuration(seconds = 1)
    while getMonoTime() < until:
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
  block hostileImport:
    # A project.nif that names an import to resume copies nothing it was not
    # recorded as: no identity, or another file's, is refused with a message,
    # and the entry is cleared. A file outside the project folder and its data
    # folders is never copied by itself, even with the identity recorded.
    let secret = fx.dir / "secret.txt"
    let inData = field / "secret.txt"
    for (how, where) in [("no identity", "data"), ("other size", "data"),
        ("replaced after", "data"), ("right", "outside"), ("other size", "outside")]:
      let path = if where == "data": inData else: secret
      writeFile(path, "private\n".repeat(20_000))
      var t: Time
      let real = quickIdentity(path, t)
      let job = fx.dir / ("Job hostile " & how & " " & where)
      var st = start(config)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      st.flushFiles()
      st.shutdown()
      var problems: seq[string]
      var doc = readProject(readFile(job / "project.nif"), "project.nif", problems)
      var f = ImportFile(kind: jkSps, original: ProjectPath(absolute: path))
      if how != "no identity":
        (f.known, f.size, f.modified, f.quick) = (true, real.size, t, real.quick)
      if how == "other size": f.size += 1
      doc.importing = @[f]
      writeFile(job / "project.nif", projectDocument(doc))
      if how == "replaced after": writeFile(path, "other\n".repeat(20_000))
      var again = start(config)
      again.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert again.settle(again.inProject and again.project.survey == srFailed),
        how & ": the open did not refuse it: " & $again.project.survey
      if where == "data":
        doAssert again.said("interrupted and its files are not as they were"), how & ": not said"
      else:
        doAssert again.said("is not in the project or its data folders"), how & ": not said"
      doAssert not fileExists(job / "survey" / "files" / "secret.txt"), how & ": copied"
      doAssert not again.project.doc.hasImport, how & ": the entry stays"
      again.flushFiles()
      again.shutdown()
      for f in walkFiles(job / "survey" / "files" / "*"): doAssert false, "a copy is left: " & f
      removeFile(path)
  block resumedOnCopies:
    # An import cut short that named a file already inside survey/files (an
    # existing copy) is taken up again: the copy is kept as it is.
    let job = fx.dir / "Job copies"
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    st.flushFiles()
    st.shutdown()
    var problems: seq[string]
    var doc = readProject(readFile(job / "project.nif"), "project.nif", problems)
    doc.importing = @[]
    for c in doc.survey:
      doc.importing.add ImportFile(kind: c.kind, role: c.role,
        original: ProjectPath(absolute: job / "survey" / "files" / c.copy.extractFilename))
    writeFile(job / "project.nif", projectDocument(doc))
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded and
      again.project.doc.hasStore and not again.project.doc.hasImport),
      "the cut-short import of the existing copies was not taken up: " & $again.project.survey &
      " " & again.project.surveyNote
    doAssert not again.said("files are not as they were")
    again.flushFiles()
    again.shutdown()
  block updateRefused:
    # An original written during both tries is refused: the copies, the
    # document and survey.bin stay as they were, agreeing, and no temporary
    # file is left.
    let job = fx.dir / "Job refused"
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.importSurvey(survey)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    st.flushFiles()
    st.shutdown()
    let copyPath = job / "survey" / "files" / "survey.s"
    let (copyBefore, binBefore) = (readFile(copyPath), readFile(job / "survey" / "survey.bin"))
    proc grow(path: string) =
      var sf = readSps(path)
      var p = sf.points[^1]
      p.point += 1
      p.pointName = ""
      sf.points.add p
      sf.order.setLen 0
      sleep 20
      doAssert writeSps(sf, path).len == 0
    grow(survey.s)
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded and
      again.project.offer)
    let sizeBefore = again.project.doc.survey[0].size
    holdStep("copying survey.s into the project again")
    holdStep("copying survey.s into the project again (once more)")
    again.apply Command(kind: ckUpdateSurvey)
    doAssert again.settle(inStep("copying survey.s into the project again").len == 1)
    grow(survey.s)
    releaseStep("copying survey.s into the project again")
    doAssert again.settle(inStep("copying survey.s into the project again (once more)").len == 1)
    grow(survey.s)
    releaseStep("copying survey.s into the project again (once more)")
    doAssert again.settle(again.project.survey == srLoaded and
      again.said("changed while it was copied")), "the update was not refused: " &
      $again.project.survey & " " & again.project.surveyNote
    doAssert again.project.doc.survey[0].size == sizeBefore, "the document took the refused copy"
    again.flushFiles()
    again.shutdown()
    doAssert readFile(copyPath) == copyBefore, "the copy was overwritten"
    doAssert readFile(job / "survey" / "survey.bin") == binBefore, "survey.bin changed"
    for f in walkFiles(job / "survey" / "files" / "*.tmp"): doAssert false, "a temp is left: " & f
    for f in walkFiles(job / "survey" / "*.tmp"): doAssert false, "a temp is left: " & f
  block keptTmpName: # a survey file really named day1.tmp is not a job's temporary file
    let job = fx.dir / "Job tmpname"
    let (s, r, x) = fx.surveySps()
    let odd = fx.dir / "day1.tmp"
    copyFile(s, odd)
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
      JoinFile(path: odd, kind: jkSps), JoinFile(path: r, kind: jkSps),
      JoinFile(path: x, kind: jkSps)])
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport), "not imported: " & st.project.surveyNote
    let kept = job / "survey" / "files" / "day1.tmp"
    doAssert fileExists(kept), "the copy is not named day1.tmp"
    writeFile(job / "survey" / "files" / "r.7.tmp", "left by a cut-short copy")
    var sf = readSps(r)
    var p = sf.points[^1]
    p.point += 1
    p.pointName = ""
    sf.points.add p
    sf.order.setLen 0
    sleep 20
    doAssert writeSps(sf, r).len == 0
    st.flushFiles()
    st.shutdown()
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.survey == srLoaded and
      again.project.offer)
    again.apply Command(kind: ckUpdateSurvey) # sweeps the temporaries first
    doAssert again.settle(again.said("updated") or again.project.survey == srLoaded)
    again.flushFiles()
    again.shutdown()
    doAssert fileExists(kept), "the survey file day1.tmp was swept as a temporary file"
    doAssert not fileExists(job / "survey" / "files" / "r.7.tmp"), "a job's temporary file stays"
  block commitFails: # a move failing midway puts the old copies back: never a mixture
    let job = fx.dir / "Job commit"
    let (s, r, x) = fx.surveySps()
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
      JoinFile(path: s, kind: jkSps), JoinFile(path: r, kind: jkSps),
      JoinFile(path: x, kind: jkSps)])
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport)
    st.flushFiles()
    st.shutdown()
    proc grow(path: string) =
      var sf = readSps(path)
      var p = sf.points[^1]
      p.point += 1
      p.pointName = ""
      sf.points.add p
      sf.order.setLen 0
      sleep 20
      doAssert writeSps(sf, path).len == 0
    let files = job / "survey" / "files"
    let sBefore = readFile(files / s.extractFilename)
    grow(s)
    grow(r)
    # the second copy's place cannot take a file: its move fails after the first
    removeFile(files / r.extractFilename)
    createDir(files / r.extractFilename / "inside")
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and again.project.offer)
    again.apply Command(kind: ckUpdateSurvey)
    doAssert again.settle(again.said("could not be kept")), "the update did not fail"
    again.flushFiles()
    again.shutdown()
    doAssert readFile(files / s.extractFilename) == sBefore, "the first copy was left replaced"
    for f in walkFiles(files / "*"):
      doAssert f.extractFilename in [s.extractFilename, x.extractFilename],
        "a file is left: " & f
echo "tprojectkeep: done"
