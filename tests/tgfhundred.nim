## Where the 100 % force came from, who it belongs to, and the word when "Set from this sweep" is
## pressed on a sweep the controller reports another force for:
##
## - `hundredSource` says "typed", "set on a.dat at target 60 %", "from the project's QC profile,
##   set on a.dat at target 60 %", each "for vibrator 12";
## - `hundredGuard`: the controller reports about 30 % and the target typed is 60 %: a line with
##   both numbers and what a 60 % sweep would read (about 120 %), also in Messages when the
##   value is set; 60 against 60, or a file with no controller record: nothing; the value is
##   set all the same;
## - the 100 % force is kept per vibrator in the project's QC profile: setting it on a sweep of
##   vibrator 12 does not give it to vibrator 13 (which then says it has none and is not judged on
##   force), an older project's one value is every vibrator's default, and a project written
##   with per-vibrator values reads back;
## - each vibrator's value keeps the unit it was given in: vibrator 11 set in counts before the
##   force scale was given and vibrator 12 in newtons after it; vibrator 11 is then converted
##   exactly with the scale, and with the scale taken away vibrator 12 is not judged on force;
##   a value kept under the older tag (one unit for all) reads with no unit, to be set again;
## - a folder run judges each file with its own vibrator's value, in its own unit;
## - without a project each vibrator's value is kept for the run alone: a window moved to another
##   vibrator's sweep has none (and says so), back on the first vibrator's it has it again.
##
## Seen to fail: with the guard's threshold removed the 60 against 60 file warned; with the
## value written to the project's one slot, vibrator 13 had vibrator 12's; with the window given
## the project's one unit, vibrator 11 opened in "" instead of counts; with the folder run given
## that one unit, vibrator 12's row was not judged on force; with the run's values not taken when
## the window moves (as before), the window moved to vibrator 12 kept vibrator 11's; with them
## not kept, vibrator 12's window did not say it had none.

import std/[math, os, strutils]
import viewSEG/core/[analysis, jobs, log, project, projectnif, settings, signatures, sigtypes,
  state, sweepinfo, threads, units, vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
import viewSEG/view/vibfolderwords
import utils/[fixtures, sigfiles, waiting]

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
    doAssert hundredSource(AnalysisParams(), 0) == ""
    doAssert hundredSource(p, 0) == "typed"
    p.forceHundredHow = hhSweep
    (p.forceHundredFile, p.forceHundredAtPct) = ("a.dat", 60.0)
    doAssert hundredSource(p, 12) == "set on a.dat at target 60 % for vibrator 12",
      hundredSource(p, 12)
    p.forceHundredFromProfile = true
    doAssert hundredSource(p, 0) ==
      "from the project's QC profile, set on a.dat at target 60 %", hundredSource(p, 0)
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

  block perVibrator:
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job", projectName: "Job")
      doAssert st.settle(st.inProject)
      let a = datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12))
      let b = datFile(fx.dir, "v13.dat", SynthDat(samples: 12000, vibrator: 13))
      let w12 = st.window(a)
      st.setFromSweep(w12, 1000, 60)
      let prof = st.project.doc.vibProfile
      doAssert prof.hundredByVibrator.len == 1 and prof.hundredByVibrator[0].vibrator == 12 and
        prof.hundredByVibrator[0].pct == 1000 and prof.hundredByVibrator[0].how == hhSweep and
        prof.hundredByVibrator[0].atPct == 60 and prof.hundredByVibrator[0].file == "v12.dat",
        $prof.hundredByVibrator
      doAssert prof.forceHundredPct.isNaN, "the project's one slot was written"
      # another vibrator has none, says so, and does not borrow
      let w13 = st.window(b)
      doAssert st.plots[w13].params.forceHundredPct.isNaN, "vibrator 13 took vibrator 12's"
      # the same vibrator again: the stored value, said to come from the profile
      let again = st.window(datFile(fx.dir, "v12b.dat",
        SynthDat(samples: 12000, vibrator: 12)))
      let q = st.plots[again].params
      doAssert q.forceHundredPct == 1000 and q.forceHundredFromProfile, $q.forceHundredPct
      doAssert hundredSource(q, 12) ==
        "from the project's QC profile, set on v12.dat at target 60 % for vibrator 12",
        hundredSource(q, 12)
      # saved and read back
      var problems: seq[string]
      let back = readProject(projectDocument(st.project.doc), "project.nif", problems)
      doAssert problems.len == 0, $problems
      doAssert back.vibProfile == prof and back.vibProfile.hundredByVibrator.len == 1
      # the folder run: vibrator 12 judged on force, 13 says it has none
      let ask = applied(prof, [])
      let jobs = initJobs()
      let sink = FolderQcSink()
      let files = @[listed(a), listed(b)]
      let id = jobs.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
      var forceJudged: array[2, bool]
      var why: array[2, string]
      for row in sink.result.rows:
        let k = if row.path == a: 0 else: 1
        why[k] = row.forceWhy
        for m in row.measures:
          if m.limit in {qlAvgForce, qlPeakForce} and m.status != qsNotJudged:
            forceJudged[k] = true
      doAssert forceJudged[0] and not forceJudged[1], $(forceJudged, why)
      doAssert "no 100 % force is set for vibrator 13" in why[1], why[1]
      st.shutdown()

  block unitPerVibrator:
    # each vibrator's 100 % force keeps the unit it was given in: vibrator 11 set in counts with
    # no force scale, then the scale given and vibrator 12 set in newtons; vibrator 11 is still in
    # counts (converted exactly with the scale), and with the scale taken away vibrator 12's
    # newtons are not read as counts (not judged on force, and said)
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
      var p = st.plots[w12].params
      (p.forceHundredPct, p.forceHundredUnit) = (417000.0, "N")
      st.change(w12, p)
      let prof = st.project.doc.vibProfile
      doAssert prof.hundredOf(11).unit == "counts" and prof.hundredOf(12).unit == "N",
        $prof.hundredByVibrator
      doAssert prof.forceHundredUnit == "", "the project's one unit was written"
      # vibrator 11 again, with the scale on: its counts, applied in newtons with the scale
      let again = st.window(datFile(fx.dir, "v11b.dat", SynthDat(samples: 12000, vibrator: 11)))
      let r11 = st.plots[again].result
      doAssert st.plots[again].params.forceHundredUnit == "counts"
      doAssert r11.hundredProblem == "" and
        abs(r11.qc.hundredPct - 750000.0 * NPerLbf / 8.0) < 1e-6, $r11.qc.hundredPct
      # saved and read back: each with its unit, never under the older tag
      var problems: seq[string]
      let text = projectDocument(st.project.doc)
      doAssert "hundredFor" notin text and "(unit \"counts\")" in text and
        "(unit \"N\")" in text, text
      let back = readProject(text, "project.nif", problems)
      doAssert problems.len == 0, $problems
      doAssert back.vibProfile == prof
      # the folder run with the scale on: both judged on force, each on its own value
      var ask = applied(prof, [])
      ask.forceScale = settings.forceScale
      let jobs = initJobs()
      var sink = FolderQcSink()
      let files = @[listed(a), listed(b)]
      var id = jobs.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
      for row in sink.result.rows:
        doAssert row.forceWhy == "", row.path & ": " & row.forceWhy
      # the scale taken away: vibrator 12's newtons are not counts
      settings.forceScale = ForceScale()
      st.apply Command(kind: ckSettings, settings: settings)
      let off = st.window(datFile(fx.dir, "v12b.dat", SynthDat(samples: 12000, vibrator: 12)))
      let r12 = st.plots[off].result
      doAssert "typed in N" in r12.hundredProblem and r12.qc.hundredPct.isNaN,
        r12.hundredProblem & " " & $r12.qc.hundredPct
      ask.forceScale = ForceScale()
      sink = FolderQcSink()
      id = jobs.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
      for row in sink.result.rows:
        if row.path == b:
          doAssert "does not apply (typed in N" in row.forceWhy, row.forceWhy
        else: doAssert row.forceWhy == "", row.forceWhy
      st.shutdown()

  block unitlessValues:
    # a value kept under the older tag, which had one unit for every vibrator, is read with no
    # unit (set it again), and stands over the same vibrator's value written before it
    let text = "(project (name \"Old\") (vibProfile (harmonics 5) (accelSet B) " &
      "(forceHundredUnit \"N\") " &
      "(vibratorHundred (vibrator 11) (pct 750000.0) (unit \"counts\") (set B)) " &
      "(vibratorHundred (vibrator 13) (pct 9.0) (unit \"kg\")) " &
      "(hundredFor (vibrator 11) (pct 417000.0)) (hundredFor (vibrator 12) (pct 5.0))))"
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    let p = back.vibProfile
    doAssert p.hundredOf(11).pct == 417000 and p.hundredOf(11).unit == "" and
      not p.hundredOf(11).setKnown, $p.hundredByVibrator
    doAssert p.hundredOf(12).unit == "" and p.hundredOf(12).pct == 5
    var unitProblems = 0
    for x in problems:
      if "(unit) needs one of counts, pound-counts and N" in x: inc unitProblems
    doAssert p.hundredOf(13).unit == "" and unitProblems == 1, $problems
    doAssert "unit not known: set it again" in profileLines(p)[0], profileLines(p)[0]

  block noProject:
    # without a project each vibrator's 100 % force is kept for the run: a window moved to
    # another vibrator's sweep has none (says so, not judged on force) and back on the first
    # vibrator's it has that one's again; nothing is saved
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let a = datFile(fx.dir, "v11.dat", SynthDat(samples: 12000, vibrator: 11))
      let b = datFile(fx.dir, "v12.dat", SynthDat(samples: 12000, vibrator: 12))
      let c = datFile(fx.dir, "v11b.dat", SynthDat(samples: 12000, vibrator: 11))
      let w = st.window(a)
      doAssert st.missingHundred(st.plots[w]) == "", "a note with no value kept"
      st.setFromSweep(w, 1000, 60)
      proc follow(st: var AppState; path: string) =
        let before = st.plots[w].result.gen
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
        doAssert st.settle(st.plots[w].file == path.extractFilename and
          st.plots[w].result.gen > before and not st.plots[w].waiting and
          st.plots[w].result.plots.len > 0), st.plots[w].file
      st.follow(b)
      doAssert st.plots[w].params.forceHundredPct.isNaN, "vibrator 12 kept vibrator 11's"
      doAssert st.missingHundred(st.plots[w]) ==
        "no 100 % force for vibrator 12 set in this run: not judged on force",
        st.missingHundred(st.plots[w])
      for q in st.plots[w].result.qc.rows:
        if q.limit in {qlAvgForce, qlPeakForce}: doAssert q.status == qsNotJudged, $q.limit
      st.follow(c)
      doAssert st.plots[w].params.forceHundredPct == 1000 and
        st.plots[w].params.forceHundredUnit == "counts" and
        st.missingHundred(st.plots[w]) == "", $st.plots[w].params.forceHundredPct
      let q = st.plots[w].params
      doAssert not q.forceHundredFromProfile and
        hundredSource(q, 11) == "set on v11.dat at target 60 % for vibrator 11",
        hundredSource(q, 11)
      # a new window still opens with none typed (a typed value is not carried into it)
      let w11 = st.window(a)
      doAssert st.plots[w11].params.forceHundredPct.isNaN
      st.shutdown()
      # a new run of the program has none: a window moved from vibrator 12 to 11 finds nothing
      var again = initAppState()
      again.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let fresh = again.window(b)
      let before = again.plots[fresh].result.gen
      again.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
      doAssert again.settle(again.plots[fresh].file == "v11.dat" and
        again.plots[fresh].result.gen > before and not again.plots[fresh].waiting)
      doAssert again.plots[fresh].params.forceHundredPct.isNaN, "the run's value was saved"
      again.shutdown()

  block olderProject:
    # a project that kept one 100 % force: it is every vibrator's default
    var d = ProjectDoc(name: "Old", hasVibProfile: true)
    d.vibProfile.forceHundredPct = 5000
    var problems: seq[string]
    let text = projectDocument(d)
    doAssert "hundredFor" notin text
    let back = readProject(text, "project.nif", problems)
    doAssert back.vibProfile.hundredOf(12).pct == 5000 and back.vibProfile.hundredOf(13).pct == 5000
    var p = back.vibProfile
    p.hundredByVibrator = @[VibHundred(vibrator: 12, pct: 7000)]
    doAssert p.hundredOf(12).pct == 7000 and p.hundredOf(13).pct == 5000

when isMainModule:
  main()
  echo "tgfhundred: ok"
