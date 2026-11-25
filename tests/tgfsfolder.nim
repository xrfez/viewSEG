## The ground force switch in the project's vibrator QC profile and the folder QC: the choice
## (with the masses and the 100 % force it needs) is kept in the profile and the project file,
## written only when it is "made from mass and baseplate" (an older file reads as before), and a
## folder run judges each file with it. The external converter's SEG-Y files are listed and
## judged with the signature files:
##
## - a SEG-Y whose first four traces are coded 21, 19, 18, 20 is a converter's file
##   (`convertedSegy`), another SEG-Y or a `.dat` is not; the shipped 4-trace samples are;
## - "In the record" (the default) judges as before: no masses, the recorded ground force;
## - "Made from mass and baseplate" judges a converter's file on the ground force made with
##   the profile's weights (the reaction mass on the trace coded 19, the channel it is), a `.dat`
##   on the plain sum of its two channels; a profile with no weights leaves the file judged on
##   the record, with a warning on its row; the profile's text says which is judged.
##
## Seen to fail: with the converter's role swap left out of `withCodeRoles`, the made row's numbers no
## longer matched those of the true ground force (`mixedFolder`); with the profile's masses always dropped (`masses = NaN`),
## the made row was judged on the record.

import std/[math, os, strutils]
import viewSEG/core/[analysis, jobs, nif, project, projectnif, settings, signatures, sigtypes, sweepinfo,
  threads, vibanalysis, vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
import viewSEG/view/vibfolderwords
import utils/[fixtures, gfsynth, sigfiles, vibfiles, vibsynth, waiting]

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc runJob(files: seq[FolderListed]; ask: VibQcAsk): FolderTable =
  let jobs = initJobs()
  let sink = FolderQcSink()
  let id = jobs.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the job did not finish"
  doAssert jobs.state(id) == jsDone, jobs.info(id).get.error
  sink.result

proc rowOf(table: FolderTable; path: string): FolderRow =
  for row in table.rows:
    if row.path == path: return row
  doAssert false, "no row for " & path

proc listed(path: string): FolderListed =
  if convertedSegy(path): return FolderListed(path: path, converted: true)
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  FolderListed(path: path, info: readSweepInfo(path, signatureKindOf(head), size))

proc profile(judge: JudgeOn; reaction = NaN; plate = NaN; weighted = NaN): VibQcProfile =
  profileOf(QcLimits(), 500.0, 5, asB, ForceScale(), 5.0e7, NaN, "", NaN, "", asB, "", judge,
    reaction, plate, weighted)

proc main*() =
  block profileKeepsTheSwitch:
    let p = profile(joWeighted, Wm, Wb, 1000.0)
    var d = ProjectDoc(name: "Land", hasVibProfile: true, vibProfile: p)
    let text = projectDocument(d)
    doAssert "(judge made)" in text and "(madeReactionKg 3600.0)" in text and
      "(forceHundredWeighted 1000.0)" in text, text
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.vibProfile == p and back.vibProfile.judge == joWeighted
    # in the record: nothing written, an older file reads as before
    d.vibProfile = profile(joRecorded)
    let plain = projectDocument(d)
    doAssert "judge" notin plain and "madeReactionKg" notin plain, plain
    doAssert readProject(plain, "project.nif", problems).vibProfile.judge == joRecorded
    doAssert p != profile(joRecorded, Wm, Wb, 1000.0)
    # the ask: the masses reach the run only when the ground force is made
    let made = applied(p, [])
    doAssert made.judge == joWeighted and made.options.reactionMassKg == Wm and
      made.options.forceHundredWeighted == 1000.0
    let record = applied(profile(joRecorded, Wm, Wb, 1000.0), [])
    doAssert record.judge == joRecorded and record.options.reactionMassKg.isNaN and
      record.options.forceHundredWeighted.isNaN
    # a window that changes only the switch writes only it into the stored profile
    let stored = profile(joRecorded, NaN, NaN, NaN)
    var flipped = stored
    flipped.judge = joWeighted
    let kept = merged(profile(joRecorded, Wm, Wb, 1000.0), stored, flipped)
    doAssert kept.judge == joWeighted and kept.madeReactionKg == Wm and
      kept.forceHundredWeighted == 1000.0, $kept
    doAssert "ground force made from mass and baseplate" in changeWords(stored, flipped)
    # the profile's text says which ground force is judged
    doAssert "Ground force in the record." in profileLines(profile(joRecorded))[0]
    doAssert "Ground force made from mass and baseplate (3600 kg, 1400 kg)." in
      profileLines(p)[0], profileLines(p)[0]

  block listing:
    withFixtures fx:
      let shipped = currentSourcePath.parentDir.parentDir / "samples" / "vib" / "field"
      doAssert convertedSegy(shipped / "signature_4trace_a.sgy")
      doAssert convertedSegy(shipped / "signature_13trace_a.sgy")
      doAssert not convertedSegy(fx.vibPlainSegy())
      doAssert not convertedSegy(datFile(fx.dir, "a.dat"))
      doAssert not convertedSegy(fx.dir / "no such file.sgy")

  block mixedFolder:
    withFixtures fx:
      let c = converterOf()
      let sgy = fx.dir / "converted.sgy"
      writeVibSegy(sgy, [c.reference, c.mass, c.plate, c.record], 1.0, [21'i16, 19, 18, 20])
      let dat = datFile(fx.dir, "a.dat")
      let sample = currentSourcePath.parentDir.parentDir / "samples" / "vib" / "field" /
        "signature_4trace_a.sgy"
      let files = @[listed(sgy), listed(dat), listed(sample)]
      doAssert files[0].converted and not files[1].converted and files[2].converted
      let record = runJob(files, applied(profile(joRecorded, Wm, Wb, 1000.0), []))
      for f in files:
        let row = record.rowOf(f.path)
        doAssert row.outcome == foJudged, f.path & ": " & row.problem
        doAssert "from M and B" notin row.sentence, row.sentence
      doAssert record.rowOf(sgy).kind == sgNone and
        kindLabel(record.rowOf(sgy).kind) == SegyKindLabel
      # made: the converter's file on its weights (the reaction mass on the trace coded 19), the
      # .dat on the plain sum of its channels, both said in the sentence
      let made = runJob(files, applied(profile(joWeighted, Wm, Wb, 1000.0), []))
      for f in files:
        let row = made.rowOf(f.path)
        doAssert row.outcome == foJudged, f.path & ": " & row.problem
        doAssert "on GF from M and B" in row.sentence, row.sentence
      # ... and it is the true ground force: the numbers of a window that holds the true one
      let truth = vibratorOf(@[c.reference, c.truth], @["Ref", "GF"],
        [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1], 1.0,
        AnalysisParams(forceHundredPct: 1000.0), -1, NaN)
      doAssert truth.problem == "", truth.problem
      for l in [qlAvgPhase, qlAvgDistortion, qlAvgForce, qlPeakForce]:
        var got = NaN
        for m in made.rowOf(sgy).measures:
          if m.limit == l: got = m.measured
        let want = truth.qc.rows[ord(l)].measured
        doAssert abs(got - want) <= 0.01 * max(abs(want), 1.0), $l & ": " & $got & " not " & $want
      # the weights the wrong way round make another ground force: the converter swap is real
      var turned = profile(joWeighted, Wb, Wm, 1000.0)
      let wrong = runJob(@[files[0]], applied(turned, []))
      let right = made.rowOf(sgy)
      doAssert wrong.rowOf(sgy).sentence != right.sentence,
        "the weights made no difference: " & right.sentence
      # a profile with no weights: the converter's file stays on the record, with a warning on
      # its row; the .dat takes the file's own
      let bare = runJob(files, applied(profile(joWeighted), []))
      let bareRow = bare.rowOf(sgy)
      doAssert "from M and B" notin bareRow.sentence, bareRow.sentence
      var told = false
      for w in bareRow.warnings:
        if "made from M and B once both masses are typed" in w: told = true
      doAssert told, $bareRow.warnings
      doAssert "on GF from M and B" in bare.rowOf(dat).sentence

when isMainModule:
  main()
  echo "tgfsfolder: ok"
