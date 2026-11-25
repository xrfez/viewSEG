## Where the 100 % force came from, and the word when "Set from this sweep" is pressed on a
## sweep the controller reports another force for:
##
## - `hundredSource` says "typed", "set on a.dat at target 60 %", "from the project's QC
##   profile, set on a.dat (vibrator 12) at target 60 %": the vibrator of the sweep it was set
##   on is information only;
## - `hundredGuard`: the controller reports about 30 % and the target typed is 60 %: a line with
##   both numbers and what a 60 % sweep would read (about 120 %), also in Messages when the
##   value is set; 60 against 60, or a file with no controller record: nothing; the value is
##   set all the same;
## - the 100 % force is one for the project: set on a sweep of vibrator 11, a window on vibrator
##   12's sweep and the folder QC use it, and setting it again on 12's sweep replaces it for
##   11 too; without a project it is one value for the run; windows already open on other
##   sweeps (frozen ones too) take it at once, and so does a window that follows from a SEG-Y
##   file to a sweep;
## - the value keeps the unit it was given in: counts set before the force scale was given are
##   converted exactly with it, newtons are never read as counts;
## - a project written by a version that kept one per vibrator: one value, or values that
##   agree, are the project's; values that differ give none (said once in Messages, in the
##   window and the folder QC; not judged on force) and stay in the document until a value is
##   set from a sweep.
##
## Seen to fail: with the value written for the vibrator of the sweep alone, vibrator 12's
## window had none; with a second Set not replacing the value kept for the first vibrator,
## vibrator 11 kept its own; with the run's value kept per vibrator, a window moved to vibrator
## 12's sweep had none; with the other open windows not told of a new value, vibrator 12's
## window kept none; with a window coming from a SEG-Y file given none, it judged no force;
## with differing older values taken as the first one, the project had a
## value and no sentence; with the entries dropped on reading, they were not in the document
## until a value was set.

import std/[math, os, strutils]
import viewSEG/core/[analysis, jobs, log, project, projectnif, settings, signatures, sigtypes,
  state, sweepinfo, threads, units, vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
import viewSEG/view/vibfolderwords
import utils/[fixtures, gfsynth, sigfiles, vibsynth, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc sessionOf(st: AppState; path: string): int =
  result = -1
  for i, s in st.sessions:
    if s.path == path: result = i

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

func has(l: MessageLog; part: string): bool =
  for e in l:
    if part in e.text: return true

proc setFromSweep(st: var AppState; w: int; value, target: float64) =
  var p = st.plots[w].params
  (p.forceHundredPct, p.forceHundredUnit, p.targetPct) = (value, "counts", target)
  p.forceHundredHow = hhSweep
  st.change(w, p)

proc listed(path: string): FolderListed =
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  FolderListed(path: path, info: readSweepInfo(path, signatureKindOf(head), size))

proc main*() =
  block words:
    var p = AnalysisParams(forceHundredPct: 1000)
    doAssert hundredSource(AnalysisParams()) == ""
    doAssert hundredSource(p) == "typed"
    p.forceHundredHow = hhSweep
    (p.forceHundredFile, p.forceHundredAtPct) = ("a.dat", 60.0)
    doAssert hundredSource(p) == "set on a.dat at target 60 %", hundredSource(p)
    p.forceHundredVibrator = 12
    doAssert hundredSource(p) == "set on a.dat (vibrator 12) at target 60 %", hundredSource(p)
    p.forceHundredFromProfile = true
    doAssert hundredSource(p) ==
      "from the project's QC profile, set on a.dat (vibrator 12) at target 60 %",
      hundredSource(p)
    let g = hundredGuard(30, 60)
    doAssert "about 30 % average force" in g and "target typed is 60 %" in g and
      "read about 120 %" in g, g
    doAssert hundredGuard(60, 60).len == 0 and hundredGuard(NaN, 60).len == 0 and
      hundredGuard(65, 60).len == 0 and hundredGuard(30, NaN).len == 0

  block guard:
    withFixtures fx:
      var st = initAppState()
      let low = st.window(datFile(fx.dir, "low.dat", SynthDat(samples: 12000, forceAvg: 30)))
      doAssert abs(st.plots[low].result.controllerAvgForcePct - 30) < 1e-9
      st.setFromSweep(low, 1000, 60)
      doAssert st.plots[low].params.forceHundredPct == 1000, "the value is set all the same"
      doAssert st.plots[low].params.forceHundredFile == "low.dat" and
        st.plots[low].params.forceHundredAtPct == 60
      doAssert st.log.has("The controller reports about 30 % average force"), "no warning"
      let same = st.window(datFile(fx.dir, "same.dat", SynthDat(samples: 12000, forceAvg: 60)))
      let before = st.log.len
      st.setFromSweep(same, 1000, 60)
      doAssert st.plots[same].params.forceHundredPct == 1000
      doAssert not st.log.has("about 60 % average force"), "warned for 60 against 60"
      let bare = st.window(datFile(fx.dir, "bare.dat", SynthDat(samples: 12000, noQc: true)))
      doAssert st.plots[bare].result.controllerAvgForcePct.isNaN
      st.setFromSweep(bare, 1000, 60)
      doAssert st.plots[bare].params.forceHundredPct == 1000
      var count = 0
      for e in st.log:
        if "The controller reports" in e.text: inc count
      doAssert count == 1, "one warning only: " & $count
      discard before
      st.shutdown()

  block oneForAll:
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job", projectName: "Job")
      doAssert st.settle(st.inProject)
      let a = datFile(fx.dir, "v11.dat", SynthDat(samples: 12000, vibrator: 11))
      let b = datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12))
      let w11 = st.window(a)
      st.setFromSweep(w11, 1000, 60)
      let prof = st.project.doc.vibProfile
      doAssert prof.forceHundredPct == 1000 and prof.forceHundredUnit == "counts" and
        prof.hundredHow == hhSweep and prof.hundredAtPct == 60 and
        prof.hundredFile == "v11.dat" and prof.hundredVibrator == 11 and
        prof.olderHundreds.len == 0, $prof.hundredOf
      doAssert hundredSource(st.plots[w11].params) == "set on v11.dat (vibrator 11) at target 60 %",
        hundredSource(st.plots[w11].params)
      # a window on another vibrator's sweep uses it, and says it was set on vibrator 11's
      let w12 = st.window(b)
      let q = st.plots[w12].params
      doAssert q.forceHundredPct == 1000 and q.forceHundredFromProfile, $q.forceHundredPct
      doAssert hundredSource(q) ==
        "from the project's QC profile, set on v11.dat (vibrator 11) at target 60 %",
        hundredSource(q)
      doAssert st.hundredConflictNote(st.plots[w12]) == ""
      # the folder run judges both vibrators on it
      let jobs = initJobs()
      let files = @[listed(a), listed(b)]
      proc judged(ask: VibQcAsk): array[2, bool] =
        let sink = FolderQcSink()
        let id = jobs.submit(folderQcSpec(files),
          folderQcWork(ask, VibJobWeights(), files, sink))
        doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
        for row in sink.result.rows:
          let k = if row.path == a: 0 else: 1
          for m in row.measures:
            if m.limit in {qlAvgForce, qlPeakForce} and m.status != qsNotJudged:
              result[k] = true
      doAssert judged(applied(prof, [])) == [true, true]
      # set again on vibrator 12's sweep: it replaces the value for vibrator 11 too
      st.setFromSweep(w12, 2000, 50)
      let next = st.project.doc.vibProfile
      doAssert next.forceHundredPct == 2000 and next.hundredVibrator == 12 and
        next.hundredFile == "v12.dat" and next.hundredAtPct == 50, $next.hundredOf
      doAssert hundredSource(st.plots[w12].params) == "set on v12.dat (vibrator 12) at target 50 %"
      let again = st.window(datFile(fx.dir, "v11b.dat", SynthDat(samples: 12000, vibrator: 11)))
      doAssert st.plots[again].params.forceHundredPct == 2000
      doAssert judged(applied(next, [])) == [true, true]
      # a window moved to another sweep takes what was set since it opened
      let before = st.plots[w11].result.gen
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: b)
      doAssert st.settle(st.plots[w11].file == "v12.dat" and
        st.plots[w11].result.gen > before and not st.plots[w11].waiting)
      doAssert st.plots[w11].params.forceHundredPct == 2000
      # saved and read back, in the one-value form
      var problems: seq[string]
      let text = projectDocument(st.project.doc)
      doAssert "vibratorHundred" notin text and "(hundredVibrator 12)" in text and
        "(forceHundredPct 2000.0)" in text, text
      let back = readProject(text, "project.nif", problems)
      doAssert problems.len == 0, $problems
      doAssert back.vibProfile == next
      st.shutdown()

  block unitRule:
    # the one value keeps the unit it was given in: set in counts before the force scale was
    # given, it is converted exactly with the scale, for every vibrator; set in newtons after
    # the scale was given, it is not read as counts once the scale is taken away (not judged on
    # force, said, for every vibrator)
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job", projectName: "Job")
      doAssert st.settle(st.inProject)
      let a = datFile(fx.dir, "v11.dat", SynthDat(samples: 12000, vibrator: 11))
      let b = datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12))
      let w11 = st.window(a)
      st.setFromSweep(w11, 750000, 60)
      var settings = st.settings
      settings.forceScale = ForceScale(datCountsPerLbf: 8.0)
      st.apply Command(kind: ckSettings, settings: settings)
      let w12 = st.window(b)
      doAssert st.plots[w12].params.forceHundredUnit == "counts"
      let r12 = st.plots[w12].result
      doAssert r12.hundredProblem == "" and
        abs(r12.qc.hundredPct - 750000.0 * NPerLbf / 8.0) < 1e-6, $r12.qc.hundredPct
      var prof = st.project.doc.vibProfile
      doAssert prof.forceHundredUnit == "counts"
      var ask = applied(prof, [])
      ask.forceScale = settings.forceScale
      let jobs = initJobs()
      let files = @[listed(a), listed(b)]
      proc run(ask: VibQcAsk): FolderQcSink =
        result = FolderQcSink()
        let id = jobs.submit(folderQcSpec(files),
          folderQcWork(ask, VibJobWeights(), files, result))
        doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
      for row in run(ask).result.rows:
        doAssert row.forceWhy == "", row.path & ": " & row.forceWhy
      # typed in newtons on vibrator 12's window: the new value, in newtons, for both
      var p = st.plots[w12].params
      (p.forceHundredPct, p.forceHundredUnit) = (417000.0, "N")
      p.forceHundredHow = hhTyped
      st.change(w12, p)
      prof = st.project.doc.vibProfile
      doAssert prof.forceHundredUnit == "N" and prof.forceHundredPct == 417000, $prof.hundredOf
      settings.forceScale = ForceScale()
      st.apply Command(kind: ckSettings, settings: settings)
      let off = st.window(datFile(fx.dir, "v11b.dat", SynthDat(samples: 12000, vibrator: 11)))
      doAssert "typed in N" in st.plots[off].result.hundredProblem and
        st.plots[off].result.qc.hundredPct.isNaN, st.plots[off].result.hundredProblem
      ask = applied(prof, [])
      for row in run(ask).result.rows:
        doAssert "does not apply (typed in N" in row.forceWhy, row.forceWhy
      st.shutdown()

  block olderForms:
    # what a version that kept a 100 % force per vibrator wrote: one value, or values that all
    # agree, are the project's value; values that differ are taken as none (and said), kept as
    # read until one is set; a value kept under the older tag (one unit for all) reads with no
    # unit; a vibrator given twice keeps the last; a force out of range is said as a force
    proc read(body: string; problems: var seq[string]): VibQcProfile =
      readProject("(project (version " & $ProjectVersion &
        ") (name \"Old\") (vibProfile (harmonics 5) (accelSet B) " & body &
        "))", "project.nif", problems).vibProfile
    var problems: seq[string]
    let same = read("(vibratorHundred (vibrator 11) (pct 1000.0) (unit \"counts\") (set B) " &
      "(how sweep) (atPct 60.0) (file \"v11.dat\")) " &
      "(vibratorHundred (vibrator 12) (pct 1000.0) (unit \"counts\") (set B))", problems)
    doAssert problems.len == 0, $problems
    doAssert same.forceHundredPct == 1000 and same.forceHundredUnit == "counts" and
      same.olderHundreds.len == 0 and same.hundredConflict == "" and
      same.hundredVibrator == 11 and same.hundredFile == "v11.dat" and
      same.hundredHow == hhSweep, $same.hundredOf
    let one = read("(vibratorHundred (vibrator 12) (pct 7.0) (unit \"N\"))", problems)
    doAssert one.forceHundredPct == 7 and one.forceHundredUnit == "N" and
      one.olderHundreds.len == 0
    let single = read("(forceHundredPct 5.0) (forceHundredUnit \"N\") " &
      "(vibratorHundred (vibrator 12) (pct 5.0) (unit \"N\"))", problems)
    doAssert single.forceHundredPct == 5 and single.olderHundreds.len == 0
    let differ = read("(vibratorHundred (vibrator 11) (pct 750000.0) (unit \"counts\") (set B)) " &
      "(vibratorHundred (vibrator 12) (pct 5.0) (unit \"N\"))", problems)
    doAssert differ.forceHundredPct.isNaN and differ.olderHundreds.len == 2
    doAssert differ.hundredConflict == "This project kept different 100 % forces for " &
      "vibrators 11 and 12; it now keeps one: set it again from a sweep.", differ.hundredConflict
    let withOne = read("(forceHundredPct 9.0) (forceHundredUnit \"N\") " &
      "(vibratorHundred (vibrator 11) (pct 1.0) (unit \"N\"))", problems)
    doAssert withOne.forceHundredPct.isNaN and withOne.olderSingle.pct == 9 and
      "vibrator 11 and the others" in withOne.hundredConflict, withOne.hundredConflict
    # the entries are kept in the document, and read back the same
    var d = ProjectDoc(name: "Old", hasVibProfile: true, vibProfile: differ)
    let text = projectDocument(d)
    doAssert text.count("(vibratorHundred ") == 2 and "(forceHundredPct" notin text, text
    doAssert readProject(text, "project.nif", problems).vibProfile == differ
    d.vibProfile = withOne
    let text2 = projectDocument(d)
    doAssert "(forceHundredPct 9.0)" in text2 and text2.count("(vibratorHundred ") == 1, text2
    doAssert readProject(text2, "project.nif", problems).vibProfile == withOne
    # a folder run has no force to judge with, and says why
    let ask = applied(differ, [])
    doAssert ask.options.forceHundredPct.isNaN and ask.hundredConflict == differ.hundredConflict
    doAssert differ.hundredConflict in profileLines(differ)[0], profileLines(differ)[0]
    # (what an older reader does with the form written now: the value is in the one slot it
    # always had; the vibrator and file are tags it keeps as fields it does not know)
    var set = ProjectDoc(name: "New", hasVibProfile: true)
    set.vibProfile.setHundred(VibHundred(vibrator: 12, pct: 5.0, unit: "N", how: hhSweep,
      file: "v12.dat"))
    let newText = projectDocument(set)
    doAssert "(forceHundredPct 5.0)" in newText and "vibratorHundred" notin newText, newText
    # older tags and hostile values
    problems = @[]
    let p = read("(forceHundredUnit \"N\") " &
      "(vibratorHundred (vibrator 11) (pct 750000.0) (unit \"counts\") (set B)) " &
      "(vibratorHundred (vibrator 13) (pct 9.0) (unit \"kg\")) " &
      "(hundredFor (vibrator 11) (pct 417000.0)) (hundredFor (vibrator 12) (pct 5.0)) " &
      "(vibratorHundred (vibrator 14) (pct 1.0) (unit \"N\")) " &
      "(vibratorHundred (vibrator 14) (pct 2.0) (unit \"N\")) " &
      "(vibratorHundred (vibrator 15) (pct 20000000000.0) (unit \"N\")) " &
      "(hundredVibrator 0) (hundredFile \"x\")", problems)
    var byVibrator: seq[VibHundred] = @[]
    for e in p.olderHundreds: byVibrator.add e
    doAssert p.forceHundredPct.isNaN and byVibrator.len == 4, $byVibrator
    for e in byVibrator:
      if e.vibrator == 11: doAssert e.pct == 417000 and e.unit == "" and not e.setKnown
      if e.vibrator == 12: doAssert e.unit == "" and e.pct == 5
      if e.vibrator == 14: doAssert e.pct == 2
      if e.vibrator == 13: doAssert e.unit == ""
      doAssert e.vibrator != 15
    var unitProblems, twice, said = 0
    for x in problems:
      if "(unit) needs one of counts, pound-counts and N" in x: inc unitProblems
      if "(vibratorHundred) of vibrator 14 is given more than once: the last is kept" in x:
        inc twice
      if "(pct) needs a number above 0 and at most 1000000000 in its unit" in x and
          "kg" notin x: inc said
    doAssert unitProblems == 1 and twice == 1 and said == 1, $problems
    doAssert p.hundredConflict.len > 0

  block conflictInWindow:
    # a project whose document kept different forces for vibrators: Messages say so once, a
    # window has none and says so, the force is not judged and the entries stay in the document
    # until a value is set from a sweep, which writes the one-value form only
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      let job = fx.dir / "job"
      createDir(job)
      var d = ProjectDoc(name: "Old", hasVibProfile: true)
      d.vibProfile.olderHundreds = @[VibHundred(vibrator: 11, pct: 1000, unit: "counts"),
        VibHundred(vibrator: 12, pct: 5, unit: "N")]
      writeFile(job / ProjectFileName, projectDocument(d))
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject)
      let sentence = "This project kept different 100 % forces for vibrators 11 and 12; it " &
        "now keeps one: set it again from a sweep."
      var count = 0
      for e in st.log:
        if e.text == sentence: inc count
      doAssert count == 1, $count
      let w = st.window(datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12)))
      doAssert st.plots[w].params.forceHundredPct.isNaN
      doAssert st.hundredConflictNote(st.plots[w]) == sentence
      for q in st.plots[w].result.qc.rows:
        if q.limit in {qlAvgForce, qlPeakForce}: doAssert q.status == qsNotJudged, $q.limit
      doAssert st.project.doc.vibProfile.olderHundreds.len == 2
      # a change that is no 100 % force keeps them
      var p = st.plots[w].params
      p.qc.avgPhaseDeg = 7
      st.change(w, p)
      doAssert st.project.doc.vibProfile.olderHundreds.len == 2
      st.setFromSweep(w, 1000, 60)
      let prof = st.project.doc.vibProfile
      doAssert prof.forceHundredPct == 1000 and prof.olderHundreds.len == 0 and
        prof.hundredConflict == "" and st.hundredConflictNote(st.plots[w]) == ""
      doAssert "vibratorHundred" notin projectDocument(st.project.doc)
      st.shutdown()

  block noProject:
    # without a project the one 100 % force is kept for the run alone: set on vibrator 11's
    # sweep, a window moved to vibrator 12's sweep has it; nothing is saved
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let a = datFile(fx.dir, "v11.dat", SynthDat(samples: 12000, vibrator: 11))
      let b = datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12))
      let w = st.window(a)
      doAssert st.hundredConflictNote(st.plots[w]) == "", "a note with no value kept"
      st.setFromSweep(w, 1000, 60)
      proc follow(st: var AppState; path: string) =
        let before = st.plots[w].result.gen
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
        doAssert st.settle(st.plots[w].file == path.extractFilename and
          st.plots[w].result.gen > before and not st.plots[w].waiting and
          st.plots[w].result.plots.len > 0), st.plots[w].file
      st.follow(b)
      doAssert st.plots[w].params.forceHundredPct == 1000 and
        st.plots[w].params.forceHundredUnit == "counts", "vibrator 12 did not take the value"
      doAssert hundredSource(st.plots[w].params) ==
        "set on v11.dat (vibrator 11) at target 60 %", hundredSource(st.plots[w].params)
      # set again on vibrator 12's sweep: it is the run's one value
      st.setFromSweep(w, 2000, 50)
      st.follow(a)
      doAssert st.plots[w].params.forceHundredPct == 2000 and
        st.plots[w].params.forceHundredVibrator == 12
      # a new window still opens with none typed (a typed value is not carried into it)
      let w11 = st.window(a)
      doAssert st.plots[w11].params.forceHundredPct.isNaN
      st.shutdown()
      # a new run of the program has none
      var again = initAppState()
      again.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let fresh = again.window(b)
      let before = again.plots[fresh].result.gen
      again.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
      doAssert again.settle(again.plots[fresh].file == "v11.dat" and
        again.plots[fresh].result.gen > before and not again.plots[fresh].waiting)
      doAssert again.plots[fresh].params.forceHundredPct.isNaN, "the run's value was saved"
      again.shutdown()

  block openWindowsFollow:
    # windows already open on other sweeps take a value set in one at once, frozen ones too, and
    # say where it came from; a window that follows to another sweep of the same vibrator takes
    # the value in force; without a project the run's one value is taken the same way
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job", projectName: "Job")
      doAssert st.settle(st.inProject)
      let a = datFile(fx.dir, "v11.dat", SynthDat(samples: 12000, vibrator: 11))
      let b = datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12))
      let b2 = datFile(fx.dir, "v12b.dat", SynthDat(samples: 12000, vibrator: 12,
        fileNumber: 7002))
      proc freeze(st: var AppState; w: int; frozen = true) =
        st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: st.plots[w].params,
          plotFrozen: frozen, origin: coWindow)
        doAssert st.settle(st.plots[w].frozen == frozen and not st.plots[w].waiting)
      let w11 = st.window(a)
      st.freeze(w11) # (it stays on v11.dat when the next file is shown)
      let w12 = st.window(b)
      doAssert st.plots[w12].params.forceHundredPct.isNaN
      proc measured(st: var AppState; w: int; pct: float64): bool =
        st.settle(not st.plots[w].waiting and st.plots[w].params.forceHundredPct == pct and
          abs(st.plots[w].result.qc.hundredPct - pct) < 1e-9)
      st.setFromSweep(w11, 1000, 60)
      doAssert st.measured(w12, 1000), $st.plots[w12].result.qc.hundredPct
      doAssert hundredSource(st.plots[w12].params) ==
        "from the project's QC profile, set on v11.dat (vibrator 11) at target 60 %",
        hundredSource(st.plots[w12].params)
      # frozen: the sweep stays, the project's value is taken
      st.freeze(w12)
      st.setFromSweep(w11, 2000, 50)
      doAssert st.measured(w12, 2000), $st.plots[w12].result.qc.hundredPct
      doAssert st.plots[w12].frozen and st.plots[w12].file == "v12.dat"
      # a window on a SEG-Y file, which takes no signature file's value, follows to a sweep: it
      # takes the value in force there, as a window opened on it does
      let c = converterOf()
      let sgy = fx.dir / "converted.sgy"
      writeVibSegy(sgy, [c.reference, c.mass, c.plate, c.record], 1.0, [21'i16, 19, 18, 20])
      st.freeze(w12, false)
      let ws = st.window(sgy)
      doAssert st.plots[ws].params.forceHundredPct.isNaN
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: b2)
      doAssert st.settle(st.plots[ws].file == "v12b.dat" and st.measured(ws, 2000)),
        $st.plots[ws].params.forceHundredPct
      doAssert st.plots[w12].file == "v12b.dat" and st.measured(w12, 2000)
      st.shutdown()
      # no project: the run's one value, the same way
      var lone = initAppState()
      lone.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let x = lone.window(a)
      lone.freeze(x)
      let y = lone.window(b)
      lone.setFromSweep(x, 1500, 60)
      doAssert lone.measured(y, 1500), $lone.plots[y].result.qc.hundredPct
      doAssert hundredSource(lone.plots[y].params) == "set on v11.dat (vibrator 11) at target 60 %",
        hundredSource(lone.plots[y].params)
      lone.shutdown()

  block olderProject:
    # a project that kept one 100 % force: it is the project's, for every vibrator
    var d = ProjectDoc(name: "Old", hasVibProfile: true)
    d.vibProfile.forceHundredPct = 5000
    var problems: seq[string]
    let text = projectDocument(d)
    doAssert "hundredFor" notin text
    let back = readProject(text, "project.nif", problems)
    doAssert back.vibProfile.hundredOf.pct == 5000 and back.vibProfile.hundredConflict == ""

when isMainModule:
  main()
  echo "tgfhundred: ok"
