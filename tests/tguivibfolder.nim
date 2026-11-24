## Reports > Vibrator QC of a folder in the running frontend, headless: the
## item is inactive until a folder is open; the window is closed at the start,
## then a tab beside the Seismic window; the run matches an independent run;
## a sort, a filter, an untick and a CSV export are what the window shows.
## Use as profile is inactive until a project is open, then stores the open
## Vibrator window's limits.
##
## Seen to fail: with the Reports item left enabled when no folder is open
## (no disabled mark), "Reports is inactive without a folder did not happen".
## With the mass left as recorded, good.dat and reversed.dat do not split
## into one pass and one fail. With the button left out, "Use as profile
## stores the window did not happen". With the weight boxes left out,
## "the job weights start unset did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[math, monotimes, options, os, strutils]
import parseSSDAT
import viewSEG/core/[filejobs, filekinds, filesystem, geometry, jobs, project, settings, sigdat,
  sigjudge, sigtypes, state, sweepinfo, vibfolderjobs, vibfolderqc, vibjudge, vibprofile]
import viewSEG/ui/imgui/app
import viewSEG/view/vibfolderwords
import utils/[fixtures, sigfiles, waiting]

const Samples = 6000

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc tone(n: int; sign: int32): seq[int32] =
  result = newSeq[int32](n)
  for i in 0 ..< n:
    let t = float64(i) / 1000.0
    let phase = 2 * PI * (8.0 * t + 12.0 * t * t)
    result[i] = sign * int32(6000.0 * sin(phase))

proc signedFile(dir, name: string; massSign: int32): string =
  var s = SynthDat(samples: Samples)
  let pilot = tone(Samples, 1)
  s.data[dcReference] = pilot
  var mass = newSeq[int32](Samples)
  for i, v in pilot: mass[i] = massSign * v
  s.data[dcMass] = mass
  s.data[dcBaseplate] = newSeq[int32](Samples)
  datFile(dir, name, s)

proc rowWord(row: FolderRow): string =
  case row.outcome
  of foJudged: $row.verdict
  of foProblem: "problem"
  of foSkipped: "skipped"

proc listedOf(folder: string): seq[FolderListed] =
  var capped = false
  let paths = listedNames(@[folder], true, capped)
  result = @[]
  for path in paths:
    let kind = sniff(path)
    if kind notin SignatureFileKinds: continue
    var info = SweepInfo(kind: kind.sweepKindOf)
    try:
      info = readSweepInfo(path, kind.sweepKindOf, fs.getFileSize(path))
    except OSError as e:
      info.problem = if e.msg.len > 0: e.msg else: "it cannot be read"
    result.add FolderListed(path: path, info: info)

proc rowOf(table: FolderTable; name: string): FolderRow =
  for row in table.rows:
    if row.path.extractFilename == name: return row
  doAssert false, "no row for " & name

proc main*() =
  var wait = 0
  var since = getMonoTime()

  withFixtures fx:
    let folder = fx.dir / "line"
    createDir(folder)
    let good = signedFile(folder, "good.dat", 1)
    let reversed = signedFile(folder, "reversed.dat", -1)
    let corrupt = signedFile(folder, "corrupt.dat", 1)
    let raw = readFile(corrupt)
    doAssert raw.len > 512, "the synthetic file is shorter than one block"
    writeFile(corrupt, raw[0 ..< 512])
    block shortHead:
      let headText = readFile(corrupt)
      doAssert headText.len == 512, "the short file is " & $headText.len
      var head = newSeq[byte](headText.len)
      for i, c in headText: head[i] = byte(c)
      doAssert datKind(head) == sgDat, "datKind did not see a .dat"
      doAssert fileKindOf(head, "corrupt.dat", true) == fkDat, "sniff would skip it"
    writeFile(folder / "notes.txt", "not a signature\n")
    let proj = fx.dir / "job"
    let outCsv = fx.dir / "out" / "vibrator-qc.csv"
    createDir(fx.dir / "out")
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let scratch = currentSourcePath().parentDir.parentDir / ".scratch"
    let filesShot = scratch / "vibfolder-files.png"
    let resultsShot = scratch / "vibfolder-results.png"
    createDir(scratch)
    let limits = QcLimits(avgPhaseDeg: 40, peakPhaseDeg: 80,
      avgDistortionPct: NaN, peakDistortionPct: NaN,
      avgForcePct: NaN, peakForcePct: NaN)
    let profile = profileOf(limits, 500.0, 5, asB, ForceScale(), NaN, NaN, "", NaN)
    doAssert good.len > 0 and reversed.len > 0

    var asked: seq[DialogKind]
    var answer: seq[string]
    var expectedCsv = ""
    var expectedTotals = ""
    var corruptWord = ""
    var judged = false
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      answer

    proc judgeOnce(f: FrameInfo) =
      if judged: return
      let listed = $(f.core.fileList.folder)
      let files = listedOf(listed)
      var names: seq[string] = @[]
      for item in files: names.add item.path.extractFilename
      doAssert "notes.txt" notin names, "a text file was listed: " & $names
      doAssert "good.dat" in names and "reversed.dat" in names and "corrupt.dat" in names,
        "the signature files were not all listed: " & $names
      let ask = applied(profile, [])
      let jobs = initJobs()
      let sink = FolderQcSink()
      let id = jobs.submit(folderQcSpec(files),
        folderQcWork(ask, VibJobWeights(), files, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the independent run did not finish"
      let info = jobs.info(id).get
      doAssert info.state == jsDone, info.error
      let table = sink.result
      var passes, fails = 0
      for row in table.rows:
        if row.outcome == foJudged and row.verdict == qvPass: inc passes
        elif row.outcome == foJudged and row.verdict == qvFail: inc fails
      doAssert passes == 1 and fails == 1,
        "expected one pass and one fail, got " & $passes & " / " & $fails
      doAssert rowOf(table, "good.dat").verdict == qvPass, $rowOf(table, "good.dat").verdict
      doAssert rowOf(table, "reversed.dat").verdict == qvFail,
        $rowOf(table, "reversed.dat").verdict
      corruptWord = rowWord(rowOf(table, "corrupt.dat"))
      expectedTotals = "vibfolder.totals " & summaryLine(table.totals)
      expectedCsv = resultsCsv(table)
      judged = true

    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("closed at the start", noop, proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert awVibFolder in f.hiddenWindows, $f.hiddenWindows
        doAssert not f.windowPlace("vibfolder").inSight)

    proc inactive(f: FrameInfo) = f.click(f.markOf("menu.Reports").centre)
    proc inactiveDone(f: FrameInfo): bool =
      f.markOf("menu.Vibrator QC of a folder").size.x > 0 and
        f.markOf("menu.Vibrator QC of a folder.disabled").size.x > 0
    step("Reports is inactive without a folder", inactive, inactiveDone)

    proc listFolder(f: FrameInfo) =
      f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
    proc folderListed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("the folder is listed", listFolder, folderListed)

    proc openFile(f: FrameInfo) =
      f.apply Command(kind: ckOpen, paths: @[good])
    proc fileShown(f: FrameInfo): bool =
      f.core.sessions.len > 0 and
        f.core.panels[f.core.findPanel(MainPanel)].laidOut
    step("the signature file is shown", openFile, fileShown)

    proc openVib(f: FrameInfo) =
      if f.core.plots.len > 0: return
      let b = f.core.sessions[0].base
      let p = AnalysisParams(qc: limits, qcWindowMs: 500.0, harmonics: 5, targetPct: NaN)
      f.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[b], plotParams: p)
    proc vibDisabled(f: FrameInfo): bool =
      if f.core.plots.len == 0 or f.core.inProject: return false
      let mark = "new plot " & $f.core.plots[0].id & ".use as profile"
      f.markOf(mark).size.x > 0 and f.markOf(mark & ".disabled").size.x > 0
    step("Use as profile is inactive without a project", openVib, vibDisabled)

    proc makeProject(f: FrameInfo) =
      f.apply Command(kind: ckNewProject, projectPath: proj, dataFolders: @[folder])
    proc projectOpen(f: FrameInfo): bool =
      if not (f.core.inProject and not f.core.project.readOnly and
          not f.core.fileList.scanning and f.core.fileList.folder.len > 0):
        return false
      if f.core.plots.len == 0: return false
      let mark = "new plot " & $f.core.plots[0].id & ".use as profile"
      f.markOf(mark).size.x > 0 and f.markOf(mark & ".disabled").size.x == 0
    step("a project is open beside the data", makeProject, projectOpen)

    proc useProfile(f: FrameInfo) =
      let mark = "new plot " & $f.core.plots[0].id & ".use as profile"
      f.click(f.markOf(mark).centre)
    proc profileStored(f: FrameInfo): bool =
      f.core.profileNoted and f.core.project.doc.hasVibProfile and
        f.core.project.doc.vibProfile == profile and
        f.markOf("status.profile").size.x > 0
    step("Use as profile stores the window", useProfile, profileStored)

    proc closeVib(f: FrameInfo) =
      if f.core.plots.len > 0:
        f.apply Command(kind: ckClosePlot, plot: f.core.plots[0].id)
    proc vibClosed(f: FrameInfo): bool = f.core.plots.len == 0
    step("the Vibrator window is closed", closeVib, vibClosed)

    var opened = false
    proc openReport(f: FrameInfo) =
      if f.markOf("menu.Vibrator QC of a folder").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc reportReady(f: FrameInfo): bool =
      if not opened:
        let it = f.markOf("menu.Vibrator QC of a folder")
        if it.size.x > 0 and
            f.markOf("menu.Vibrator QC of a folder.disabled").size.x == 0:
          f.click(it.centre)
          opened = true
      if f.markOf("vibfolder.ready").size.x == 0: return false
      if f.markOf("vibfolder.file good.dat").size.x == 0: return false
      if f.markOf("vibfolder.file reversed.dat").size.x == 0: return false
      if f.markOf("vibfolder.file corrupt.dat").size.x == 0: return false
      doAssert f.markOf("vibfolder.file notes.txt").size.x == 0, "notes.txt was listed"
      doAssert f.markOf("vibfolder.tick good.dat").size.x > 0, "good.dat was not ticked"
      doAssert f.markOf("vibfolder.run").size.x > 0, "Run is not drawn"
      doAssert f.markOf("vibfolder.run.disabled").size.x == 0, "Run is disabled"
      doAssert f.markOf("vibfolder.tab Files").size.x > 0, "Files tab is missing"
      var profiled = false
      for name in f.markNames("vibfolder.profile "):
        if "No profile yet" notin name: profiled = true
      doAssert profiled, "the profile line is the empty-profile sentence"
      let (m, p) = (f.windowPlace("vibfolder"), f.windowPlace("plot"))
      doAssert m.inSight and m.docked and not m.apart, "not in the centre dock: " & $m
      doAssert abs(m.rect.pos.x - p.rect.pos.x) <= 2 and
        abs(m.rect.pos.y - p.rect.pos.y) <= 2,
        "not a tab beside the Seismic window: " & $m.rect & " plot " & $p.rect
      doAssert f.savePng(filesShot), "files shot was not written"
      true
    step("Reports > Vibrator QC of a folder", openReport, reportReady)

    var clicked = false
    proc runQc(f: FrameInfo) =
      f.click(f.markOf("vibfolder.run").centre)
      clicked = true
    proc ran(f: FrameInfo): bool =
      if not clicked or f.markNames("vibfolder.row ").len == 0: return false
      judgeOnce(f)
      doAssert f.markOf("vibfolder.row good.dat pass").size.x > 0,
        "good row: " & $f.markNames("vibfolder.row ")
      doAssert f.markOf("vibfolder.row reversed.dat fail").size.x > 0,
        "reversed row: " & $f.markNames("vibfolder.row ")
      doAssert f.markOf("vibfolder.row corrupt.dat " & corruptWord).size.x > 0,
        "corrupt row (" & corruptWord & "): " & $f.markNames("vibfolder.row ")
      doAssert f.markOf(expectedTotals).size.x > 0,
        "totals: " & $f.markNames("vibfolder.totals ")
      doAssert f.markOf("vibfolder.tab Results").size.x > 0, "Results tab is missing"
      doAssert f.savePng(resultsShot), "results shot was not written"
      true
    step("the rows match an independent run", runQc, ran)

    proc sortVerdict(f: FrameInfo) = f.click(f.markOf("vibfolder.header Verdict").centre)
    proc sortedVerdict(f: FrameInfo): bool =
      f.markOf("vibfolder.sort Verdict").size.x > 0
    step("a click on Verdict sorts by Verdict", sortVerdict, sortedVerdict)

    var filterAt = vec2(0, 0)
    proc startFilter(f: FrameInfo) =
      filterAt = f.markOf("vibfolder.filter").centre
      f.moveMouse(filterAt)
    proc filtered(f: FrameInfo): bool =
      if wait == 3: f.pressMouse(filterAt, true)
      if wait == 5: f.pressMouse(filterAt, false)
      if wait == 7: f.typeText("reversed")
      if wait < 14: return false
      f.markOf("vibfolder.row reversed.dat fail").size.x > 0 and
        f.markOf("vibfolder.row good.dat pass").size.x == 0
    step("the filter shows the reversed file", startFilter, filtered)

    var exportClicked = false
    proc exportCsv(f: FrameInfo) =
      asked.setLen 0
      answer = @[outCsv]
      f.click(f.markOf("vibfolder.export").centre)
      exportClicked = true
    proc exported(f: FrameInfo): bool =
      if not exportClicked or not fileExists(outCsv): return false
      let got = readFile(outCsv)
      doAssert got == expectedCsv, "csv differs, asked " & $asked & "\n" &
        got[0 ..< min(240, got.len)]
      doAssert asked == @[dkExportVibFolder], "asked for " & $asked
      true
    step("Export CSV... writes the full table", exportCsv, exported)

    var phase = 0
    proc untick(f: FrameInfo) = phase = 0
    proc unticked(f: FrameInfo): bool =
      case phase
      of 0:
        f.click(f.markOf("vibfolder.tab Files").centre)
        inc phase
      of 1:
        if f.markOf("vibfolder.file good.dat").size.x == 0 and wait mod 8 == 0:
          f.click(f.markOf("vibfolder.tab Files").centre)
        elif f.markOf("vibfolder.file good.dat").size.x > 0:
          let box = f.markOf("vibfolder.file good.dat")
          f.click(vec2(round(box.pos.x + box.size.y / 2),
            round(box.pos.y + box.size.y / 2)))
          inc phase
      else:
        result = f.markOf("vibfolder.untick good.dat").size.x > 0 and
          f.markOf("vibfolder.run").size.x > 0 and
          f.markOf("vibfolder.run.disabled").size.x == 0
    step("unticking one file leaves Run enabled", untick, unticked)

    step("the job weights start unset", noop, proc (f: FrameInfo): bool =
      let w = f.core.project.doc.vibJobWeights
      result = f.markOf("vibfolder.weight Hold-down").size.x > 0 and
        f.markOf("vibfolder.weight Baseplate").size.x > 0 and
        f.markOf("vibfolder.weight Reaction mass").size.x > 0 and
        f.markOf("vibfolder.weight Hold-down.disabled").size.x == 0
      if result:
        doAssert w.holdDownKg.isNaN and w.baseplateMassKg.isNaN and w.reactionMassKg.isNaN,
          "a weight was set before it was typed")

    step("click the hold-down box", proc (f: FrameInfo) =
      f.click(f.markOf("vibfolder.weight Hold-down").centre), proc (f: FrameInfo): bool =
      wait > 5)

    step("a typed hold-down weight is stored", proc (f: FrameInfo) =
      f.typeText("18000")
      f.pressKey(skEnter, true)
      f.pressKey(skEnter, false), proc (f: FrameInfo): bool =
      let w = f.core.project.doc.vibJobWeights
      result = w.holdDownKg == 18000.0
      if result:
        doAssert w.baseplateMassKg.isNaN and w.reactionMassKg.isNaN,
          "another weight changed: " & $w)

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        wait = 0
        since = getMonoTime()
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      dialogs: hook, onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguivibfolder: ", steps.len, " steps"

when isMainModule:
  main()
