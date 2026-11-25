## A folder QC job judges each signature file as one Vibrator window would,
## reports polarity without changing samples, and does not stop when one
## file cannot be read. A cancel after the first file lists the rest as
## skipped. Job weights do not change the verdict.
##
## Seen to fail: with ground-force polarity set to reversed,
## `rolesStayRecorded` names it. With the ground-force samples negated
## before the verdict, `sameAsAlone` names it (fail / pass). With a missing
## reference still judged against the recorded pilot, `missingReference`
## names a judged row. With `applyFileScale` not called, `holdDownWhenScaled`
## finds no hold-down words. With the unit guessed as newtons, `emptyUnitRefused`
## names "N". With `controllerNote` left out, `setBWarning` finds no
## "follows set A (probable)". With the archive citation left out,
## `archiveCited` finds no "Measured against the project reference". With the
## list ignoring `subfolders`, `choiceListed` finds `deep.dat` without the tick. With
## the profile stored only by a button (the `showPlot` store left out),
## `settingsReachQc` finds "the window's settings were not kept". With the profile's
## reference used instead of the chosen one, `chosenReferenceWins` names the stored id.
## With the stored force scale used, `scaleInForce` finds NaN. With `withShots` left out,
## `shotLogMatch` finds no FFID.

import std/[math, options, os, strutils]
import parseSEG
import parseSEG/common/diagnostics
import parseSSDAT
import viewSEG/core/[analysis, jobs, persist, project, references, session, settings,
  signatures, sigjudge, sigtypes, state, sweepinfo, threads, units, vibanalysis, vibfolderconf,
  vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
import utils/[chosenref, fixtures, sigfiles, waiting]

const Samples = 6000

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc timesOf(words: seq[string]; word: string): int =
  for w in words:
    if w == word: inc result

proc bytesOf(path: string): string = readFile(path)

proc listed(path: string): FolderListed =
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  let kind = if size >= 0: signatureKindOf(head) else: sgNone
  FolderListed(path: path, info: readSweepInfo(path, kind, size))

proc askOf(force = NaN): VibQcAsk =
  var profile = profileOf(QcLimits(), 500.0, 5, asB, ForceScale(), force, NaN, "", NaN)
  applied(profile, [])

proc tone(n: int; sign: int32): seq[int32] =
  result = newSeq[int32](n)
  for i in 0 ..< n:
    let t = float64(i) / 1000.0
    let phase = 2 * PI * (8.0 * t + 12.0 * t * t)
    result[i] = sign * int32(6000.0 * sin(phase))

proc reversedFile(dir, name: string): string =
  var s = SynthDat(samples: Samples)
  let pilot = tone(Samples, 1)
  s.data[dcReference] = pilot
  var mass = newSeq[int32](Samples)
  for i, v in pilot: mass[i] = -v
  s.data[dcMass] = mass
  s.data[dcBaseplate] = newSeq[int32](Samples)
  datFile(dir, name, s)

proc runJob(files: seq[FolderListed]; ask: VibQcAsk; weights = VibJobWeights();
    reference = FolderReference()):
    tuple[st: JobState; table: FolderTable; error: string] =
  let jobs = initJobs()
  let sink = FolderQcSink()
  let id = jobs.submit(folderQcSpec(files, reference.path),
    folderQcWork(ask, weights, files, sink, reference = reference))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the folder job did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc rowOf(table: FolderTable; path: string): FolderRow =
  for row in table.rows:
    if row.path == path: return row
  doAssert false, "no row for " & path

proc alone(path: string; ask: VibQcAsk): AnalysisResult =
  ## The same file, judged here, not by the job. Calls `applyFileScale` and
  ## `vibratorOf`, the core procs the Vibrator window calls. It cannot call
  ## `analysisreader.vibratorOf`: that name is not a proc (`vibratorOf` lives
  ## in `vibanalysis`, which the reader thread calls), and `serve` needs an
  ## `AppState` and that thread. `signatureAsk` is private and needs
  ## `AppState` too, so the scale is applied here.
  markWorkerThread()
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  doAssert size > 0
  var raw = newSeq[byte](bytesOf(path).len)
  for i, c in bytesOf(path): raw[i] = byte(c)
  var log: DiagLog
  var s = decodeToSession(raw, path, getLastModificationTime(path), SignatureChoice(), log)
  defer:
    s = nil
    clearCycleRoots()
  var rows: seq[seq[float32]] = @[]
  var names: seq[string] = @[]
  var codes: seq[int16] = @[]
  for t in 0 ..< s.len:
    let samples = s.filePtr[].readTraces(t .. t)
    var one = newSeq[float32](samples.shape[1])
    for j in 0 ..< one.len: one[j] = samples[0, j]
    rows.add one
    codes.add s.filePtr[].traceKeys(t).traceCode
    if t < s.signature.traces.len: names.add s.signature.traces[t].name
    else: names.add "trace " & $(t + 1)
  let dtMs = s.filePtr[].traceKeys(0).intervalUs / 1000.0
  let facts = s.signature
  var roles = VibRoles().withCodeRoles(codes, "")
  roles.groundForcePolarity = poAsRecorded
  roles.massPolarity = poAsRecorded
  roles.judge = joRecorded
  let setA = facts.kind == sgVib and ask.accelSet == asA
  let params = AnalysisParams(roles: roles, harmonics: ask.options.harmonics,
    accelSet: ask.accelSet, qcWindowMs: ask.options.qcWindowMs, qc: ask.options.qc,
    forceHundredPct: ask.options.forceHundredPct,
    forceHundredUnit: ask.forceHundredUnit, forceHundredSet: ask.forceHundredSet,
    forceHundredSetKnown: ask.forceHundredSetKnown, targetPct: ask.options.targetPct,
    reactionMassKg: NaN, baseplateMassKg: NaN, projectReference: false)
  var sig = SignatureAsk(given: true, isDat: facts.kind == sgDat, setA: setA)
  sig.applyFileScale(facts.kind, ask.forceScale.datCountsPerLbf,
    ask.forceScale.vibAccMvPerCount, facts.info.weights, setA, facts.qc.valid,
    facts.qc.targetForceLbf, ask.options.targetPct)
  case facts.kind
  of sgDat:
    if facts.qc.valid:
      sig.ctlFrom = "this file"
      sig.ctl = facts.qc.brief
      sig.ctl.valid = true
      sig.correlationStored = facts.qc.correlationStored
      sig.correlationLagZero = facts.qc.correlationLagZero
  of sgVib:
    if facts.pair.len > 0 and facts.pairQc.valid:
      sig.ctlFrom = "the .dat of this sweep"
      sig.ctl = facts.pairQc
  of sgNone: discard
  var at: array[VibRole, int]
  at[vsReference] = roles.reference
  at[vsGroundForce] = roles.groundForce
  at[vsMass] = roles.mass
  at[vsBaseplate] = roles.baseplate
  vibratorOf(rows, names, at, dtMs, params, forceNote = signatureForceNote(facts), sig = sig)

proc phaseOf(row: FolderRow): float64 =
  result = NaN
  for m in row.measures:
    if m.limit == qlAvgPhase: return m.measured

var lane: Jobs

proc stopAtSecond(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("file 2 of"): return
  discard lane.cancel(id)

proc main*() =
  let dir = getTempDir() / ("viewseg-vqc-" & $getCurrentProcessId())
  createDir(dir)
  let plain = datFile(dir, "plain.dat", SynthDat(samples: Samples))
  let other = datFile(dir, "other.dat", SynthDat(samples: Samples, fileNumber: 7002,
    vibrator: 13))
  let bad = dir / "bad.dat"
  writeFile(bad, "not a signature")
  let rev = reversedFile(dir, "reversed.dat")
  let before = bytesOf(rev)
  let ask = askOf()

  block rolesStayRecorded:
    let roles = folderRoles(@[21'i16, 20, 18, 19], sgDat, asB)
    doAssert roles.groundForcePolarity == poAsRecorded
    doAssert roles.massPolarity == poAsRecorded
    let params = folderParams(ask, roles, sgDat)
    doAssert params.reactionMassKg.isNaN and params.baseplateMassKg.isNaN
    doAssert params.forceHundredPct.isNaN
    doAssert params.roles.groundForcePolarity == poAsRecorded

  block sameAsAlone:
    let got = runJob(@[listed(plain)], ask, VibJobWeights(holdDownKg: 10000,
      baseplateMassKg: 2000, reactionMassKg: 1500))
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, plain)
    doAssert row.outcome == foJudged, row.problem
    let one = alone(plain, ask)
    doAssert one.problem.len == 0, one.problem
    doAssert row.verdict == one.qc.verdict, $row.verdict & " / " & $one.qc.verdict
    doAssert row.sentence == one.qc.line, row.sentence & " / " & one.qc.line
    doAssert ForceNotJudged in got.table.problems
    var forceJudged = false
    for m in row.measures:
      if m.limit in {qlAvgForce, qlPeakForce} and m.status != qsNotJudged:
        forceJudged = true
    doAssert not forceJudged, "a profile with no 100 % force judged a force limit"
    doAssert timesOf(got.table.problems, ForceNotJudged) == 1

  block reversed:
    let got = runJob(@[listed(rev)], ask)
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, rev)
    doAssert row.outcome == foJudged, row.problem
    doAssert "opposite" in row.polarity, row.polarity
    doAssert "reversed for the analysis" notin row.polarity, row.polarity
    doAssert phaseOf(row) > 90, $phaseOf(row)
    doAssert bytesOf(rev) == before, "the job wrote the signature file"

  block missingReference:
    ## A reference that cannot be read is a problem on every row, not a banner
    ## the files then ignore. Seen to fail when the load's words were added once
    ## and each file was judged against its own pilot.
    let sentence = "the reference \"pilot\" is no longer in the archive " &
      "(the reference file is missing)"
    let gone = FolderReference(path: dir / "missing-ref.sgy", name: "pilot")
    let got = runJob(@[listed(plain), listed(other)], ask, reference = gone)
    doAssert got.st == jsDone, got.error
    doAssert got.table.rows.len == 2, $got.table.rows.len
    for row in got.table.rows:
      doAssert row.outcome == foProblem, $row.outcome & " " & row.problem
      doAssert row.problem == sentence, row.problem
      doAssert row.sentence.len == 0 and row.verdict == qvNotJudged
      doAssert row.measures.len == 0
    doAssert sentence notin got.table.problems
    let junk = dir / "junk-ref.sgy"
    writeFile(junk, "not a reference")
    let unread = runJob(@[listed(plain)], ask,
      reference = FolderReference(path: junk, name: "kept"))
    doAssert unread.st == jsDone, unread.error
    let unreadRow = rowOf(unread.table, plain)
    doAssert unreadRow.outcome == foProblem
    markWorkerThread()
    var loader = ""
    try:
      discard readReferenceFile(junk)
    except CatchableError as e:
      loader = e.msg
    doAssert loader.len > 0 and loader != "the reference file is missing", loader
    doAssert unreadRow.problem == "the reference \"kept\" is no longer in the archive (" &
      loader & ")", unreadRow.problem
    let emptyPath = dir / "empty-ref.sgy"
    var one = newSeq[float32](1)
    one[0] = 1
    writeReferenceFile(emptyPath, "bare", 1000.0, one, ReferenceOrigin())
    var raw = readFile(emptyPath)
    # a trace of no samples: the writer refuses to author one, so the sample
    # count in the binary header and the trace header is set to 0 and the
    # sample is dropped
    doAssert raw.len > 3200 + 400 + 240
    raw[3220] = '\0'
    raw[3221] = '\0'
    let traceAt = 3200 + 400
    raw[traceAt + 114] = '\0'
    raw[traceAt + 115] = '\0'
    raw.setLen(traceAt + 240)
    writeFile(emptyPath, raw)
    let empty = runJob(@[listed(plain)], ask,
      reference = FolderReference(path: emptyPath, name: "bare"))
    doAssert empty.st == jsDone, empty.error
    let emptyRow = rowOf(empty.table, plain)
    doAssert emptyRow.outcome == foProblem, $emptyRow.outcome & " " & emptyRow.problem
    var emptyWhy = ""
    try:
      discard readReferenceFile(emptyPath)
    except CatchableError as e:
      emptyWhy = e.msg
    doAssert emptyWhy.len > 0, "the empty reference was readable"
    doAssert emptyRow.problem == "the reference \"bare\" is no longer in the archive (" &
      emptyWhy & ")", emptyRow.problem
    doAssert emptyRow.measures.len == 0

  block corruptDoesNotStop:
    let got = runJob(@[listed(bad), listed(other)], ask)
    doAssert got.st == jsDone, got.error
    let failed = rowOf(got.table, bad)
    doAssert failed.outcome == foProblem, $failed.outcome
    doAssert failed.problem.len > 0
    let rest = rowOf(got.table, other)
    doAssert rest.outcome == foJudged, rest.problem

  block holdDownWhenScaled:
    ## A `.vib` with a force scale and no typed 100 % force takes the file's
    ## hold-down, so a force that cannot pass is a failure. Seen to fail when
    ## `hundredN` stayed unset and the force limit was not judged.
    var facts = SignatureFacts(kind: sgVib)
    facts.info.weights = VibWeights(holdDownLb: 40000, sensitivity1: 20,
      sensitivity2: 20)
    let sig = folderSignature(facts, ForceScale(vibAccMvPerCount: 10.0), asB)
    doAssert "hold-down" in sig.hundredWords, sig.hundredWords
    doAssert sig.hundredN == 40000.0 * NPerLbf, $sig.hundredN
    doAssert folderSignature(facts, ForceScale(), asB).hundredN.isNaN
    let vib = vibFile(dir, "scaled.vib")
    var limits = QcLimits(avgForcePct: 1e6)
    let scaled = applied(profileOf(limits, 500.0, 5, asB,
      ForceScale(vibAccMvPerCount: 10.0), NaN, NaN, "", NaN), [])
    let got = runJob(@[listed(vib)], scaled)
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, vib)
    doAssert row.outcome == foJudged, row.problem
    var force = qsNotJudged
    for m in row.measures:
      if m.limit == qlAvgForce: force = m.status
    doAssert force == qsFail, $force
    doAssert row.verdict == qvFail, $row.verdict

  block emptyUnitRefused:
    ## A typed 100 % force keeps the unit the profile stored. An empty unit
    ## with a scale set is refused, not taken as newtons. Seen to fail when
    ## the job guessed "N" whenever a scale was set.
    let roles = folderRoles(@[21'i16, 20, 18, 19], sgDat, asB)
    let guessed = applied(profileOf(QcLimits(), 500.0, 5, asB,
      ForceScale(datCountsPerLbf: 8.0), 1000.0, NaN, "", NaN), [])
    doAssert folderParams(guessed, roles, sgDat).forceHundredUnit == "",
      folderParams(guessed, roles, sgDat).forceHundredUnit
    let got = runJob(@[listed(plain)], guessed)
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, plain)
    doAssert row.outcome == foJudged, row.problem
    var said = false
    for w in row.warnings:
      if w == "typed with no unit; the axis is now in newtons: type it again": said = true
    doAssert said, $row.warnings
    for m in row.measures:
      if m.limit in {qlAvgForce, qlPeakForce}:
        doAssert m.status == qsNotJudged, $m.status
    let counted = applied(profileOf(QcLimits(), 500.0, 5, asB,
      ForceScale(datCountsPerLbf: 8.0), 1000.0, NaN, "", NaN, "counts"), [])
    doAssert folderParams(counted, roles, sgDat).forceHundredUnit == "counts"

  block weights:
    let vib = vibFile(dir, "one.vib")
    let got = runJob(@[listed(vib)], ask, VibJobWeights(holdDownKg: 10000))
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, vib)
    doAssert row.outcome == foJudged, row.problem
    var said = false
    for w in row.weightWords:
      if "differ" in w: said = true
    doAssert said, $row.weightWords
    let bare = runJob(@[listed(vib)], ask)
    doAssert rowOf(bare.table, vib).verdict == row.verdict

  block setBWarning:
    ## A `.vib` judged on set B keeps the window's note that the controller's
    ## QC report follows set A. Seen to fail when `controllerNote` was dropped.
    let pairDir = dir / "setb"
    discard datFile(pairDir, "4321_0.dat", SynthDat(samples: 12000))
    let vib = vibFile(pairDir, "0007.VIB")
    let got = runJob(@[listed(pairDir / "4321_0.dat"), listed(vib)], ask)
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, vib)
    var said = false
    for w in row.warnings:
      if "follows set A (probable)" in w: said = true
    doAssert said, $row.outcome & " " & $row.warnings

  block archiveCited:
    ## A held archive reference is named on the row. Seen to fail when the
    ## row was judged and never said which reference it used.
    markWorkerThread()
    let refPath = dir / "pilot.sgy"
    var samples = newSeq[float32](2000)
    for i in 0 ..< samples.len:
      let t = float64(i) / 1000.0
      samples[i] = float32(sin(2 * PI * (8.0 * t + 12.0 * t * t)))
    writeReferenceFile(refPath, "sweep-a", 1000.0, samples, ReferenceOrigin())
    let got = runJob(@[listed(plain)], ask,
      reference = FolderReference(path: refPath, name: "sweep-a"))
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, plain)
    doAssert row.outcome == foJudged, $row.outcome & " " & row.problem
    var said = false
    for w in row.warnings:
      if w == "Measured against the project reference sweep-a": said = true
    doAssert said, $row.warnings

  block poundCountsSet:
    ## Pound-counts belong to the set they were typed on. Seen to fail when the
    ## job assumed the set now judged and failed the file against it.
    let vib = vibFile(dir, "setforce.vib")
    var limits = QcLimits(peakForcePct: 0.01)
    let mismatched = applied(profileOf(limits, 500.0, 5, asB, ForceScale(), 1000.0,
      NaN, "", NaN, "pound-counts", asA), [])
    let roles = folderRoles(@[21'i16, 1, 11, 2], sgVib, asB)
    let params = folderParams(mismatched, roles, sgVib)
    doAssert params.forceHundredSet == asA, $params.forceHundredSet
    doAssert params.accelSet == asB
    let sentence = "typed in pound-counts of accelerometer set A; the window now " &
      "judges set B (another sensitivity): type it again"
    let got = runJob(@[listed(vib)], mismatched)
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, vib)
    doAssert row.outcome == foJudged, $row.outcome & " " & row.problem
    var said = false
    for w in row.warnings:
      if w == sentence: said = true
    doAssert said, $row.warnings
    for m in row.measures:
      if m.limit in {qlAvgForce, qlPeakForce}:
        doAssert m.status == qsNotJudged, $m.status
    var old = profileOf(limits, 500.0, 5, asB, ForceScale(), 1000.0, NaN, "", NaN,
      "pound-counts", asB)
    old.forceHundredSetKnown = false
    let unknown = applied(old, [])
    doAssert not unknown.forceHundredSetKnown
    let unread = runJob(@[listed(vib)], unknown)
    doAssert unread.st == jsDone, unread.error
    let oldRow = rowOf(unread.table, vib)
    doAssert oldRow.outcome == foJudged, $oldRow.outcome & " " & oldRow.problem
    let unknownSentence = "typed in pound-counts of an accelerometer set this " &
      "project does not record; the window now judges set B (another sensitivity): " &
      "type it again"
    var unknownSaid = false
    for w in oldRow.warnings:
      if w == unknownSentence: unknownSaid = true
    doAssert unknownSaid, $oldRow.warnings
    for m in oldRow.measures:
      if m.limit in {qlAvgForce, qlPeakForce}:
        doAssert m.status == qsNotJudged, $m.status & " " & $oldRow.warnings

  block pairedVibKeepsFail:
    ## A paired `.vib` that fails peak force keeps that verdict and is counted.
    ## Seen to fail when pairing wiped it and the totals said 0 failed.
    let pairDir = dir / "pairfail"
    let dat = datFile(pairDir, "4321_0.dat", SynthDat(samples: 12000))
    let vib = vibFile(pairDir, "0007.VIB")
    var limits = QcLimits(peakForcePct: 0.01)
    let tight = applied(profileOf(limits, 500.0, 5, asB, ForceScale(), 1000.0, NaN,
      "", NaN, "pound-counts"), [])
    let got = runJob(@[listed(dat), listed(vib)], tight)
    doAssert got.st == jsDone, got.error
    let vibRow = rowOf(got.table, vib)
    doAssert vibRow.outcome == foJudged, $vibRow.outcome & " " & vibRow.problem
    doAssert vibRow.verdict == qvFail, $vibRow.verdict & " " & vibRow.sentence
    doAssert vibRow.sentence.len > 0
    doAssert vibRow.measures.len > 0
    let datRow = rowOf(got.table, dat)
    doAssert datRow.outcome == foJudged, $datRow.outcome & " " & datRow.problem
    var vibNamed = false
    var datNamed = false
    for w in vibRow.warnings:
      if w == "Paired with 4321_0.dat": vibNamed = true
    for w in datRow.warnings:
      if w == "Paired with 0007.VIB": datNamed = true
    doAssert vibNamed, $vibRow.warnings
    doAssert datNamed, $datRow.warnings
    doAssert got.table.totals.failed >= 1, $got.table.totals

  block recordedReference:
    ## With no archive reference the row names the recorded pilot, as the
    ## window does. Seen to fail when that sentence was set only for an
    ## archive reference.
    let got = runJob(@[listed(plain)], ask)
    doAssert got.st == jsDone, got.error
    let row = rowOf(got.table, plain)
    doAssert row.outcome == foJudged, row.problem
    let sentence = "Measured against the recorded reference, reference " &
      "(no project reference is chosen)"
    var said = false
    for w in row.warnings:
      if w == sentence: said = true
    doAssert said, $row.warnings

  block cancel:
    lane = initJobs()
    setJobHook(stopAtSecond)
    let sink = FolderQcSink()
    let files = @[listed(plain), listed(other), listed(rev)]
    let id = lane.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
    doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the cancelled job did not finish"
    setJobHook(nil)
    doAssert lane.state(id) == jsCancelled, $lane.state(id)
    doAssert sink.result.cancelled
    doAssert sink.result.rows.len == 3, $sink.result.rows.len
    doAssert sink.result.rows[0].outcome == foJudged, sink.result.rows[0].problem
    doAssert sink.result.rows[1].outcome == foSkipped, $sink.result.rows[1].outcome
    doAssert sink.result.rows[2].outcome == foSkipped
    doAssert sink.result.totals.skipped == 2

  block choiceListed:
    ## What is listed is what was chosen, and nothing else: a folder (its subfolders only
    ## when asked), single files, or both. No choice lists nothing.
    let tree = dir / "tree"
    discard datFile(tree, "top.dat", SynthDat(samples: Samples, fileNumber: 7101))
    discard datFile(tree / "sub", "deep.dat", SynthDat(samples: Samples, fileNumber: 7102))
    writeFile(tree / "notes.txt", "not a signature\n")
    proc names(c: FolderChoice): seq[string] =
      let jobs = initJobs()
      let sink = FolderListSink()
      let id = jobs.submit(folderListSpec(c), folderListWork(c, sink))
      doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
        "the list job did not finish"
      doAssert jobs.state(id) == jsDone, jobs.info(id).get.error
      result = @[]
      for f in sink.files: result.add f.path.extractFilename
    doAssert not FolderChoice().hasChoice
    doAssert names(FolderChoice()).len == 0, "nothing chosen listed something"
    doAssert names(FolderChoice(folder: tree)) == @["top.dat"], $names(FolderChoice(folder: tree))
    let deep = names(FolderChoice(folder: tree, subfolders: true))
    doAssert deep == @["deep.dat", "top.dat"], $deep
    let one = names(FolderChoice(files: @[tree / "sub" / "deep.dat"]))
    doAssert one == @["deep.dat"], $one
    let both = names(FolderChoice(folder: tree, files: @[tree / "sub" / "deep.dat"]))
    doAssert both == @["deep.dat", "top.dat"], $both
    doAssert names(FolderChoice(files: @[tree / "notes.txt"])).len == 0,
      "a text file was listed"
    let sink = FolderListSink()
    let jobs = initJobs()
    let gone = FolderChoice(folder: tree / "missing")
    let id = jobs.submit(folderListSpec(gone), folderListWork(gone, sink))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled})
    doAssert jobs.state(id) == jsDone and sink.files.len == 0, "a missing folder listed files"

  block rowIdentity:
    ## Each row names the electronics number, the vibrator and the trigger time of its
    ## sweep, and what a shot log is asked.
    let files = @[listed(plain), listed(other)]
    let got = runJob(files, ask)
    let first = rowOf(got.table, plain)
    doAssert first.controller == 4321 and first.vibrator == 12, $(first.controller, first.vibrator)
    doAssert first.triggerNs == files[0].info.triggerNs and first.triggerNs != 0
    doAssert rowOf(got.table, other).vibrator == 13
    doAssert first.query.fileNumber == some(7001'i64)
    let corrupt = runJob(@[listed(bad)], ask)
    doAssert corrupt.table.rows[0].outcome == foProblem

  withFixtures fx:
    let sigs = fx.dir / "sigs"
    let good = datFile(sigs, "good.dat", SynthDat(samples: Samples, fileNumber: 7001))
    let lone = datFile(sigs, "lone.dat", SynthDat(samples: Samples, fileNumber: 7050,
      line: 300, station: 4000, trigger: DatTime(year: 2001, month: 2, day: 3, hour: 5,
      minute: 30, second: 1, nanosecond: 250_000_000)))
    let configDir = fx.dir / "config"
    createDir(configDir)
    proc started(): AppState =
      result = initAppState()
      result.keepSettingsIn(configDir, loadSettings(configDir / "settings.nif"))
    proc openWindow(st: var AppState; path: string): int =
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      var at = -1
      doAssert st.settle((at = -1; (for i, s in st.sessions: (if s.path == path: at = i));
        at >= 0) and st.panel(MainPanel).laidOut and
        st.shownFile(st.findPanel(MainPanel)) == at), path
      var base = 0
      for s in st.sessions:
        if s.path == path: base = s.base
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
      result = st.plots.high
      doAssert st.settle(st.plots[result].result.gen > 0 and not st.plots[result].waiting)
    proc change(st: var AppState; w: int; p: AnalysisParams; origin = coWindow) =
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p,
        origin: origin)
      doAssert st.settle(not st.plots[w].waiting)

    block notConfigured:
      var st = started()
      doAssert not vibQcConfig(st).configured, "configured without a project"
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job-a", projectName: "Job")
      doAssert st.settle(st.inProject)
      doAssert not vibQcConfig(st).configured, "configured without a profile"
      let w = st.openWindow(good)
      doAssert not vibQcConfig(st).configured, "opening a window stored a profile"
      discard w

    block settingsReachQc:
      ## What the user sets in the Vibrator signature window is the configuration the QC
      ## reads: no other button.
      var st = started()
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job-b", projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.openWindow(good)
      var p = st.plots[w].params
      p.targetPct = 60
      p.qc.avgPhaseDeg = 33
      st.change(w, p)
      let cfg = vibQcConfig(st)
      doAssert cfg.configured, "the window's settings were not kept"
      doAssert cfg.ask.options.targetPct == 60, $cfg.ask.options.targetPct
      doAssert cfg.ask.options.qc.avgPhaseDeg == 33
      doAssert cfg.profile.fromFile == "good.dat", cfg.profile.fromFile
      doAssert ForceNotJudged notin cfg.ask.problems, $cfg.ask.problems
      p.targetPct = 70
      st.change(w, p, coAgent)
      doAssert vibQcConfig(st).ask.options.targetPct == 60, "an agent's change was stored"
      # a change that is no setting of the profile (the unfolded roles) stores nothing
      var q = st.plots[w].params
      q.details = not q.details
      st.change(w, q)
      doAssert vibQcConfig(st).ask.options.targetPct == 60
      var weights = st.project.doc.vibJobWeights
      weights.holdDownKg = 1200
      st.apply Command(kind: ckVibWeights, vibWeights: weights)
      doAssert vibQcConfig(st).weights.holdDownKg == 1200

    block scaleInForce:
      ## The force scale is the one set now, not the one in the stored profile.
      var st = started()
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job-c", projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.openWindow(good)
      var p = st.plots[w].params
      p.targetPct = 60
      st.change(w, p)
      var s = st.settings
      s.forceScale = ForceScale(datCountsPerLbf: 12.5)
      st.apply Command(kind: ckSettings, settings: s)
      doAssert vibQcConfig(st).ask.forceScale.datCountsPerLbf == 12.5,
        $vibQcConfig(st).ask.forceScale

    block chosenReferenceWins:
      ## The project's chosen reference is the one measured against; the profile's own is
      ## the fallback when none is chosen.
      var st = started()
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job-d", projectName: "Job")
      doAssert st.settle(st.inProject)
      let w = st.openWindow(good)
      let base = st.sessions[0].base
      let first = st.chooseStored(fx.dir / "refs", base, "first")
      var p = st.plots[w].params
      p.targetPct = 60
      st.change(w, p)
      doAssert vibQcConfig(st).profile.referenceId == first, "the window's reference was lost"
      let second = st.chooseStored(fx.dir / "refs", base, "second")
      doAssert second != first
      var cfg = vibQcConfig(st)
      doAssert cfg.profile.referenceId == second, "the stored reference was used: " &
        cfg.profile.referenceId
      doAssert cfg.ask.referenceId == second and cfg.referenceName == "second"
      st.apply Command(kind: ckSelectReference, refId: "")
      cfg = vibQcConfig(st)
      doAssert cfg.profile.referenceId == first, "no fallback to the stored reference"

    block shotLogMatch:
      ## The sweep's row in a loaded shot log: its FFID and source line and point. With no
      ## log, or no row for the sweep, nothing: never a guess.
      var st = started()
      let files = @[listed(good), listed(lone)]
      var table = runJob(files, ask).table
      table.rows.withShots(st)
      for row in table.rows:
        doAssert not row.shot.found and row.shot.ffid.len == 0, "a match with no shot log"
      let us = files[0].info.triggerNs div 1000
      let logPath = fx.dir / "shots.csv"
      writeFile(logPath, "UTC microseconds,file number,source line,shot point\n" &
        $us & ",7001,100.00,1010.00\n" & $(us + 1_000_000_000) & ",7099,100.00,1011.00\n")
      st.apply Command(kind: ckImportShotLog, logPath: logPath)
      doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0), "the log did not load"
      table.rows.withShots(st)
      let hit = rowOf(table, good)
      doAssert hit.shot.found and hit.shot.ffid == "7001", $hit.shot
      doAssert hit.shot.line == "100" and hit.shot.point == "1010", $hit.shot
      let miss = rowOf(table, lone)
      doAssert not miss.shot.found and miss.shot.ffid.len == 0 and miss.shot.point.len == 0,
        "a guess for a sweep the log does not have: " & $miss.shot

  echo "tvibfolderjobs: ok"

when isMainModule:
  main()
