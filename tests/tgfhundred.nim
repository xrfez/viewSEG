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
## - a folder run judges each file with its own vibrator's value.
##
## Seen to fail: with the guard's threshold removed the 60 against 60 file warned; with the
## value written to the project's one slot, vibrator 13 had vibrator 12's.

import std/[math, os, strutils]
import viewSEG/core/[analysis, jobs, log, project, projectnif, settings, signatures, sigtypes,
  state, sweepinfo, threads, vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
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
