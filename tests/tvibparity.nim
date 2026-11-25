## The folder QC judges each file as a Vibrator window opened on that file judges it, with the
## same settings: what the user set in one window on one sweep (limits, statistics window,
## harmonics, drive level, the one 100 % force set from that sweep, the ground force's polarity
## chosen for the file layout, the options the files are opened with, the top frequency typed
## for the layout) is what every row of the run is judged with, limit by limit, and the counts
## under the table follow the rows ("not judged" is never a fail). A setting changed after a
## run is the next run's, and the run shown says the settings changed. Without a project the
## folder QC is not configured, and says where to configure it.
##
## The folder holds four sweeps of two vibrators, their ground force recorded opposite to the
## pilot (as some controllers wire it): three at the force of the sweep the 100 % force was set
## on, one at 40 % of it.
##
## Seen to fail: with the folder's roles as recorded whatever the layout's choice, every row
## failed the phase limits that the windows passed; with every file decoded with the default
## options, the rows of files opened at another sample interval were not the windows'.

import std/[math, os, strutils]
import parseSSDAT
import viewSEG/core/[analysis, jobs, openchoice, project, settings, signatures, state,
  sweepinfo, threads, vibfolderconf, vibfolderjobs, vibfolderqc, vibjudge]
import viewSEG/view/vibfolderwords
import utils/[fixtures, sigfiles, waiting]

const Samples = 6000

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc sessionOf(st: AppState; path: string): int =
  result = -1
  for i, s in st.sessions:
    if s.path == path: result = i

proc window(st: var AppState; path: string): int =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessionOf(path) >= 0 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)
  st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
    plotTraces: @[st.sessions[st.sessionOf(path)].base], plotParams: AnalysisParams())
  result = st.plots.high
  doAssert st.settle(st.plots[result].result.gen > 0 and not st.plots[result].waiting and
    (st.plots[result].result.plots.len > 0 or st.plots[result].result.problem.len > 0))

proc change(st: var AppState; w: int; p: AnalysisParams) =
  let before = st.plots[w].result.gen
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, origin: coWindow)
  doAssert st.settle(st.plots[w].result.gen > before and not st.plots[w].waiting)

proc close(st: var AppState; w: int) =
  st.apply Command(kind: ckClosePlot, plot: st.plots[w].id)

proc tone(n: int; gain: float64): seq[int32] =
  result = newSeq[int32](n)
  for i in 0 ..< n:
    let t = float64(i) / 1000.0
    result[i] = int32(gain * 6000.0 * sin(2 * PI * (8.0 * t + 12.0 * t * t)))

proc sweep(dir, name: string; vibrator, number: int; gain: float64): string =
  ## A `.dat` whose ground force (the sum of its two channels) is opposite to its pilot, at
  ## `gain` of the pilot.
  var s = SynthDat(samples: Samples, vibrator: vibrator, fileNumber: number)
  s.data[dcReference] = tone(Samples, 1)
  s.data[dcMass] = tone(Samples, -0.5 * gain)
  s.data[dcBaseplate] = tone(Samples, -0.5 * gain)
  datFile(dir, name, s)

proc listed(path: string): FolderListed =
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  FolderListed(path: path, info: readSweepInfo(path, signatureKindOf(head), size))

proc run(st: AppState; files: seq[FolderListed]): FolderTable =
  let config = vibQcConfig(st)
  doAssert config.configured and config.blocked.len == 0, config.blocked
  let jobs = initJobs()
  let sink = FolderQcSink()
  let id = jobs.submit(folderQcSpec(files, config.reference.path),
    folderQcWork(config.ask, config.weights, files, sink, reference = config.reference,
    choices = folderChoices(st, files)))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
  doAssert jobs.info(id).get.state == jsDone, jobs.info(id).get.error
  sink.result

func same(a, b: float64): bool =
  (a.isNaN and b.isNaN) or abs(a - b) <= 1e-9 * max(1.0, max(abs(a), abs(b)))

proc differences(win: AnalysisResult; row: FolderRow): seq[string] =
  ## What the row says otherwise than the window, limit by limit.
  if row.outcome != foJudged:
    return @["the row is " & $row.outcome & ": " & row.problem]
  if win.qc.verdict != row.verdict:
    result.add "verdict " & $win.qc.verdict & " / " & $row.verdict
  if win.qc.line != row.sentence:
    result.add "sentence \"" & win.qc.line & "\" / \"" & row.sentence & "\""
  for q in win.qc.rows:
    var found = false
    for m in row.measures:
      if m.limit == q.limit:
        found = true
        if m.status != q.status or not same(m.measured, q.measured) or
            not same(m.bound, q.bound):
          result.add $q.limit & ": window " & $q.status & " " & $q.measured & " (limit " &
            $q.bound & "), folder " & $m.status & " " & $m.measured & " (limit " &
            $m.bound & ")"
    if not found: result.add $q.limit & " is not in the row"

proc rowOf(t: FolderTable; path: string): FolderRow =
  for row in t.rows:
    if row.path == path: return row
  doAssert false, "no row for " & path

proc parity(st: var AppState; files: seq[FolderListed]; t: FolderTable) =
  ## Every row is what a window opened on its file now says.
  for f in files:
    let w = st.window(f.path)
    let said = differences(st.plots[w].result, rowOf(t, f.path))
    doAssert said.len == 0, f.path.extractFilename & ": " & said.join("; ")
    st.close(w)

proc main*() =
  block inProject:
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      let sweeps = fx.dir / "sweeps"
      let a11 = sweep(sweeps, "a11.dat", 11, 7001, 1.0)
      let b11 = sweep(sweeps, "b11.dat", 11, 7002, 1.0)
      let a12 = sweep(sweeps, "a12.dat", 12, 7003, 1.0)
      let low12 = sweep(sweeps, "low12.dat", 12, 7004, 0.4)
      let files = @[listed(a11), listed(b11), listed(a12), listed(low12)]
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: fx.dir / "job", projectName: "Job")
      doAssert st.settle(st.inProject)
      st.apply Command(kind: ckBrowse, paths: @[sweeps])
      doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 4)
      # everything set in one window on one sweep
      let w = st.window(a11)
      doAssert "opposite" in st.plots[w].result.polarity.line, st.plots[w].result.polarity.line
      var p = st.plots[w].params
      p.roles.groundForcePolarity = poReversed
      st.change(w, p)
      p = st.plots[w].params
      (p.qc.avgPhaseDeg, p.qc.peakPhaseDeg, p.harmonics, p.qcWindowMs) = (4.0, 8.0, 4, 400.0)
      (p.targetPct, p.tops) = (60.0, p.tops.withTop(st.vibTopKey(st.plots[w]), 90.0))
      st.change(w, p)
      p = st.plots[w].params
      p.forceHundredPct = st.plots[w].result.qc.stats.avgForce / 0.6
      (p.forceHundredUnit, p.forceHundredHow) = ("counts", hhSweep)
      st.change(w, p)
      doAssert st.plots[w].result.qc.verdict == qvPass, st.plots[w].result.qc.line
      # the files opened at another sample interval, every .dat of the listing
      st.apply Command(kind: ckReopen, reopenPath: a11, reopenAll: true,
        openChoice: OpenChoice(signature: SignatureChoice(intervalUs: 2000)))
      doAssert st.settle(st.sessionOf(a11) >= 0 and
        st.sessions[st.sessionOf(a11)].signature.choice.intervalUs == 2000 and
        st.jobs.active.len == 0)
      st.close(w)
      let t = st.run(files)
      st.parity(files, t)
      doAssert rowOf(t, a11).verdict == qvPass and rowOf(t, b11).verdict == qvPass and
        rowOf(t, a12).verdict == qvPass, rowOf(t, a11).sentence
      doAssert rowOf(t, low12).verdict == qvFail, rowOf(t, low12).sentence
      doAssert summaryLine(t.totals) ==
        "4 files, 3 passes, 1 fail, 0 not judged, 0 problems, 0 skipped.", summaryLine(t.totals)
      for row in t.rows:
        doAssert "reversed for the analysis, as you chose" in row.polarity, row.polarity
      # a setting changed after the run: the run shown says so, and the next run is judged with it
      let ran = configLines(vibQcConfig(st))
      let again = st.window(b11)
      p = st.plots[again].params
      p.qc.avgForcePct = 150
      st.change(again, p)
      doAssert configLines(vibQcConfig(st)) != ran, "the run shown does not say it is stale"
      st.close(again)
      let next = st.run(files)
      st.parity(files, next)
      doAssert next.totals.failed == 4 and next.totals.passed == 0, summaryLine(next.totals)
      st.shutdown()

  block noProject:
    # without a project the window's settings are the window's alone: the folder QC is not
    # configured and says where to configure it, rather than judging with other settings
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      let a11 = sweep(fx.dir / "sweeps", "a11.dat", 11, 7001, 1.0)
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      let w = st.window(a11)
      var p = st.plots[w].params
      p.qc.avgPhaseDeg = 4
      st.change(w, p)
      doAssert not vibQcConfig(st).configured
      st.shutdown()

when isMainModule:
  main()
  echo "tvibparity: ok"
