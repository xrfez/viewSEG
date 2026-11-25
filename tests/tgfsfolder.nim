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
##   the record, with a warning on its row; the profile's text says which is judged;
## - Swap mass and baseplate pressed on a converter's window is kept for its layout, and the
##   folder judges a file of that layout on the swapped roles with the window's numbers and its
##   word that the other order fits better;
## - a converter's weights are the project's one set: its window writes them into the profile and
##   a new one opens with them; with 100 % forces of two vibrators kept, the made signal says once
##   that the one set serves every vibrator.
##
## Seen to fail: with the converter's role swap left out of `withCodeRoles`, the made row's numbers no
## longer matched those of the true ground force (`mixedFolder`); with the profile's masses always dropped (`masses = NaN`),
## the made row was judged on the record; with the layouts' choices not applied, the swapped row's
## numbers were not the window's; with the order check left off, its row had no word of it; with
## the converter's window kept out of the profile, its weights did not reach the project; with
## the note added per row, the run said it twice; with the first profile made of the four made
## fields alone, it held the built-in phase limit, not the 3° the window showed; with each weight
## merged on its own, the profile kept a pair neither window showed.

import std/[math, os, strutils]
import viewSEG/core/[analysis, jobs, nif, project, projectnif, settings, signatures, sigtypes,
  state, sweepinfo, threads, vibanalysis, vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
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

proc sessionOf(st: AppState; path: string): int =
  result = -1
  for i, s in st.sessions:
    if s.path == path: result = i

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc window(st: var AppState; path: string): int =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessionOf(path) >= 0 and st.panel(MainPanel).laidOut)
  st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
    plotTraces: @[st.sessions[st.sessionOf(path)].base], plotParams: AnalysisParams())
  result = st.plots.high
  doAssert st.settle(st.plots[result].result.gen > 0 and not st.plots[result].waiting and
    (st.plots[result].result.plots.len > 0 or st.plots[result].result.problem.len > 0))

proc change(st: var AppState; w: int; p: AnalysisParams) =
  let before = st.plots[w].result.gen
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, origin: coWindow)
  doAssert st.settle(st.plots[w].result.gen > before and not st.plots[w].waiting)

proc profile(judge: JudgeOn; reaction = NaN; plate = NaN; weighted = NaN): VibQcProfile =
  profileOf(QcLimits(), 500.0, 5, asB, ForceScale(), 5.0e7, NaN, "", NaN, "", asB, "", judge,
    reaction, plate, weighted)

proc onLayouts(ask: VibQcAsk; layouts: seq[string]): VibQcAsk =
  result = ask
  result.layouts = layouts

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
    # the ask: the masses reach the run whatever the profile judges (a file layout may have
    # chosen to make the ground force on its own)
    let made = applied(p, [])
    doAssert made.judge == joWeighted and made.options.reactionMassKg == Wm and
      made.options.forceHundredWeighted == 1000.0
    let record = applied(profile(joRecorded, Wm, Wb, 1000.0), [])
    doAssert record.judge == joRecorded and record.options.reactionMassKg == Wm and
      record.options.forceHundredWeighted == 1000.0
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
      # (a longer record is not the converter's four-trace file: no swapped roles, no listing)
      doAssert not convertedSegy(shipped / "signature_13trace_a.sgy")
      doAssert not convertedSegy(fx.vibPlainSegy())
      doAssert not convertedSegy(datFile(fx.dir, "a.dat"))
      doAssert not convertedSegy(fx.dir / "no such file.sgy")

  block widths:
    # sample widths of the formats beyond the four-byte ones are read right (format 11 is two
    # bytes, 7 three), and a record of more than four traces is not the converter's
    withFixtures fx:
      proc file(name: string; format, samples, traces: int): string =
        var b = newSeq[byte](3600)
        (b[3220], b[3221]) = (byte(samples shr 8), byte(samples and 255))
        (b[3224], b[3225]) = (byte(format shr 8), byte(format and 255))
        let width = case format
          of 3, 11: 2
          of 7: 3
          of 8: 1
          else: 4
        for t in 0 ..< traces:
          var h = newSeq[byte](240)
          (h[28], h[29]) = (0'u8, byte([21, 19, 18, 20, 5][t mod 5]))
          b.add h
          b.add newSeq[byte](samples * width)
        result = fx.dir / name
        writeBytes(result, b)
      for (format, name) in [(1, "f1"), (3, "f3"), (5, "f5"), (7, "f7"), (8, "f8"), (11, "f11")]:
        doAssert convertedSegy(file(name & ".sgy", format, 50, 4)), name
        doAssert not convertedSegy(file(name & "x.sgy", format, 50, 5)), name & " with 5 traces"

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
      # each layout's own choice is what a file is judged on (recorded when none was made):
      # "made" chosen on a window of each file
      var st = initAppState()
      st.keepSettingsIn(fx.dir / "config", loadSettings(fx.dir / "config" / "settings.nif"))
      for f in files:
        let w = st.window(f.path)
        var p = st.plots[w].params
        let chosen = p.roles.judge == joWeighted # (a layout chosen already opens as chosen)
        p.roles.judge = joWeighted
        if f.path == files[0].path:
          (p.reactionMassKg, p.baseplateMassKg, p.forceHundredWeighted) = (Wm, Wb, 1000.0)
        if not chosen: st.change(w, p)
      let layouts = st.vibRoleChoices
      st.shutdown()
      let record = runJob(files, applied(profile(joRecorded, Wm, Wb, 1000.0), []))
      for f in files:
        let row = record.rowOf(f.path)
        doAssert row.outcome == foJudged, f.path & ": " & row.problem
        doAssert "from M and B" notin row.sentence, row.sentence
      doAssert record.rowOf(sgy).kind == sgNone and
        kindLabel(record.rowOf(sgy).kind) == SegyKindLabel
      # made: the converter's file on its weights (the reaction mass on the trace coded 19), the
      # .dat on the plain sum of its channels, both said in the sentence
      let madeAsk = applied(profile(joWeighted, Wm, Wb, 1000.0), []).onLayouts(layouts)
      let made = runJob(files, madeAsk)
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
      let wrong = runJob(@[files[0]], applied(turned, []).onLayouts(layouts))
      let right = made.rowOf(sgy)
      doAssert wrong.rowOf(sgy).sentence != right.sentence,
        "the weights made no difference: " & right.sentence
      # the made ground force with its own 100 % force not set says so on the row
      let noWeight = applied(profile(joWeighted, Wm, Wb, NaN), []).onLayouts(layouts)
      let noMade = runJob(@[files[0]], noWeight)
      doAssert "no 100 % force is set for the ground force made from mass and baseplate" in
        noMade.rowOf(sgy).forceWhy, noMade.rowOf(sgy).forceWhy
      # a profile with no weights: the converter's file stays on the record, with a warning on
      # its row; the .dat takes the file's own
      let bare = runJob(files, applied(profile(joWeighted), []).onLayouts(layouts))
      let bareRow = bare.rowOf(sgy)
      doAssert "from M and B" notin bareRow.sentence, bareRow.sentence
      var told = false
      for w in bareRow.warnings:
        if "made from M and B once both masses are typed" in w: told = true
      doAssert told, $bareRow.warnings
      doAssert "on GF from M and B" in bare.rowOf(dat).sentence

  block swappedLayout:
    # Swap mass and baseplate pressed on a converter's window is remembered for its layout: the
    # folder QC judges a file of that layout on the swapped roles, as the window does, with the
    # window's word that the other order fits better
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let c = converterOf()
      let sgy = fx.dir / "converted.sgy"
      writeVibSegy(sgy, [c.reference, c.mass, c.plate, c.record], 1.0, [21'i16, 19, 18, 20])
      let w = st.window(sgy)
      var p = st.plots[w].params
      (p.reactionMassKg, p.baseplateMassKg, p.forceHundredWeighted) = (Wm, Wb, 1000.0)
      p.roles.judge = joWeighted
      st.change(w, p)
      p = st.plots[w].params
      doAssert p.roles.mass == 1 and p.roles.baseplate == 2, $p.roles
      swap(p.roles.mass, p.roles.baseplate)
      st.change(w, p)
      let r = st.plots[w].result
      doAssert st.plots[w].params.roles.mass == 2 and r.judged == "GF (M, B)", $r.judged
      doAssert "with the two weights on the other traces" in r.judgeWarning, r.judgeWarning
      var ask = applied(profile(joWeighted, Wm, Wb, 1000.0), [])
      ask.layouts = st.vibRoleChoices
      let row = runJob(@[listed(sgy)], ask).rowOf(sgy)
      doAssert row.outcome == foJudged, row.problem
      for m in row.measures:
        let want = r.qc.rows[ord(m.limit)].measured
        doAssert abs(m.measured - want) <= 1e-9 * max(abs(want), 1.0) or
          (want.isNaN and m.measured.isNaN), $m.limit & ": " & $m.measured & " not " & $want
      var warned = false
      for x in row.warnings:
        if "with the two weights on the other traces" in x: warned = true
      doAssert warned, $row.warnings
      # with no choice kept, the codes' roles: another ground force, and no such word
      ask.layouts = @[]
      let plain = runJob(@[listed(sgy)], ask).rowOf(sgy)
      doAssert plain.sentence != row.sentence, plain.sentence
      for x in plain.warnings:
        doAssert "with the two weights on the other traces" notin x, x
      st.shutdown()

  block oneSetOfWeights:
    # the made signal's weights are one set for the project: a converter's window writes them
    # (with the switch and that signal's 100 % force) into the profile and a new one opens with
    # them; with 100 % forces kept for two vibrators the made signal says, once, that the one set
    # serves every vibrator (the window beside the boxes, the folder run above its rows)
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job", projectName: "Job")
      doAssert st.settle(st.inProject)
      let c = converterOf()
      let sgy = fx.dir / "a.sgy"
      writeVibSegy(sgy, [c.reference, c.mass, c.plate, c.record], 1.0, [21'i16, 19, 18, 20])
      let w = st.window(sgy)
      var p = st.plots[w].params
      (p.qc.avgPhaseDeg, p.harmonics) = (3.0, 7)
      st.change(w, p)
      doAssert not st.project.doc.hasVibProfile, "a limit of a converter's window made a profile"
      p = st.plots[w].params
      (p.reactionMassKg, p.baseplateMassKg, p.forceHundredWeighted) = (Wm, Wb, 1000.0)
      p.roles.judge = joWeighted
      st.change(w, p)
      doAssert st.project.doc.hasVibProfile, "the converter's weights did not reach the project"
      let kept = st.project.doc.vibProfile
      doAssert kept.madeReactionKg == Wm and kept.madeBaseplateKg == Wb and
        kept.forceHundredWeighted == 1000 and kept.judge == joWeighted, $kept
      # the first profile is the window's as it shows it: no limit nobody chose
      doAssert kept.limits.avgPhaseDeg == 3 and kept.harmonics == 7 and kept.fromFile == "a.sgy",
        $kept
      doAssert kept.forceHundredPct.isNaN and kept.targetPct.isNaN and
        kept.olderHundreds.len == 0, "a SEG-Y window's own 100 % force or drive level"
      # once there is a profile, a converter's window writes only the made signal's settings
      p = st.plots[w].params
      p.qc.avgPhaseDeg = 4.0
      st.change(w, p)
      doAssert st.project.doc.vibProfile.limits.avgPhaseDeg == 3
      # a new window of a converter's file takes the project's set, not the kind's last masses
      var settings = st.settings
      (settings.plotOptions.vibrator.reactionMassKg,
        settings.plotOptions.vibrator.forceHundredWeighted) = (5.0, 7.0)
      st.apply Command(kind: ckSettings, settings: settings)
      doAssert st.settings.plotOptions.vibrator.reactionMassKg == 5
      let b = fx.dir / "b.sgy"
      writeVibSegy(b, [c.reference, c.mass, c.plate, c.record], 1.0, [21'i16, 19, 18, 20])
      let w2 = st.window(b)
      doAssert st.plots[w2].params.reactionMassKg == Wm and
        st.plots[w2].params.forceHundredWeighted == 1000, $st.plots[w2].params.reactionMassKg
      # the weights are a pair: one window changes the reaction mass's, the other (still showing
      # the old pair) the baseplate's; the profile keeps the two changes and the window that
      # changed last shows the pair kept
      p = st.plots[w].params
      p.reactionMassKg = 3000.0
      st.change(w, p)
      doAssert st.project.doc.vibProfile.madeReactionKg == 3000
      var p2 = st.plots[w2].params
      doAssert p2.reactionMassKg == Wm
      p2.baseplateMassKg = 1500.0
      st.change(w2, p2)
      let pair = st.project.doc.vibProfile
      doAssert pair.madeReactionKg == 3000 and pair.madeBaseplateKg == 1500, $pair
      doAssert st.plots[w2].params.reactionMassKg == 3000 and
        st.plots[w2].params.baseplateMassKg == 1500, "the window does not show the pair kept"
      st.shutdown()
    # the window's line: the weights and the ground force choice are one for the project, and
    # so is the 100 % force
    doAssert "Ground force choice" in OneSetOfWeights and ".dat and .vib files included" in
      OneSetOfWeights and "used for every vibrator" in OneSetOfWeights, OneSetOfWeights

when isMainModule:
  main()
  echo "tgfsfolder: ok"
