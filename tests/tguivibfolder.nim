## Reports > Vibrator QC of a folder in the running frontend, headless: the item
## is always active; the window is closed at the start, then a tab beside the
## Seismic window. With no vibrator QC profile it says only that signature QC is
## not configured (and where to set it) and lists nothing, though a folder is open;
## what the user sets in a Vibrator signature window is the configuration in
## force, with no button. The Files tab picks a folder (its subfolders only when
## ticked) or files through the native dialogs; the run matches an independent
## run; the Results columns are File, Electronics number, Vibrator number, Time,
## FFID, Source line, Source point and then the verdict; a loaded shot log fills
## FFID and the source point of the sweeps it has, and the others stay empty;
## a sort, a filter, an untick and a CSV export are what the window shows. The
## window closes from the Window menu and comes back from it.
##
## Seen to fail: with the Window menu's close left out of the app (the close
## button's answer not honoured), "the close button hides the window did not
## happen". With the job weights group left out of the settings wheel, "the
## settings wheel holds the job's weights did not happen". With the mass left as
## recorded, good.dat and reversed.dat do not split into one pass and one fail.
## With the view rebuilt every frame, "the view was rebuilt: 146 from 38". With
## the File column sized to the header, `the rows match an independent run` does
## not find a File column wide enough for `reversed.dat`. With the shot match left
## out (`tvibfolderjobs` and `tvibfolderqc` break it too), "the shot log fills FFID
## and source point did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[math, monotimes, options, os, strutils]
import parseSSDAT
import viewSEG/core/[analysis, filesystem, geometry, jobs, project, settings, sigdat,
  sigjudge, sigtypes, state, vibfolderconf, vibfolderjobs, vibfolderqc, vibjudge,
  vibprofile, watchdog]
import viewSEG/ui/imgui/app
import viewSEG/view/vibfolderwords
import utils/[fixtures, sigfiles, waiting]

const Samples = 6000

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc frameTooks(text: string): seq[tuple[n, ms: int]] =
  ## Each "Frame N took M ms" in `text`. "< 1 ms" is left out.
  var i = 0
  while i < text.len:
    let at = text.find("Frame ", i)
    if at < 0: break
    var j = at + "Frame ".len
    if j >= text.len or text[j] notin {'0'..'9'}:
      i = at + "Frame ".len
      continue
    var n = 0
    while j < text.len and text[j] in {'0'..'9'}:
      n = n * 10 + (ord(text[j]) - ord('0'))
      inc j
    if not text.continuesWith(" took ", j):
      i = j
      continue
    j += " took ".len
    if j >= text.len or text[j] notin {'0'..'9'}:
      i = j
      continue
    var ms = 0
    while j < text.len and text[j] in {'0'..'9'}:
      ms = ms * 10 + (ord(text[j]) - ord('0'))
      inc j
    result.add (n, ms)
    i = j

proc syntheticRows(n: int): seq[FolderRow] =
  result = newSeq[FolderRow](n)
  let sentence = "PASS: average 12 deg, peak 20 deg, the rest judged"
  for i in 0 ..< n:
    result[i] = FolderRow(path: "row" & $i & ".dat", kind: sgDat, outcome: foJudged,
      verdict: qvPass, sentence: sentence)

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

proc signedFile(dir, name: string; massSign: int32; fileNumber = 7001'i64): string =
  ## A trigger second of its own for each file number, so a shot log can tell them apart.
  var s = SynthDat(samples: Samples, fileNumber: fileNumber)
  s.trigger.second = int(fileNumber - 7000)
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

proc listedOf(c: FolderChoice): seq[FolderListed] =
  let jobs = initJobs()
  let sink = FolderListSink()
  let id = jobs.submit(folderListSpec(c), folderListWork(c, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the independent list did not finish"
  result = sink.files

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
    let good = signedFile(folder, "good.dat", 1, 7001)
    let reversed = signedFile(folder, "reversed.dat", -1, 7002)
    let corrupt = signedFile(folder, "corrupt.dat", 1, 7003)
    let deep = signedFile(folder / "sub", "deep.dat", 1, 7004)
    let raw = readFile(corrupt)
    doAssert raw.len > 512, "the synthetic file is shorter than one block"
    writeFile(corrupt, raw[0 ..< 512])
    writeFile(folder / "notes.txt", "not a signature\n")
    let proj = fx.dir / "job"
    let outCsv = fx.dir / "out" / "vibrator-qc.csv"
    createDir(fx.dir / "out")
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let scratch = currentSourcePath().parentDir.parentDir / ".scratch"
    let notConfiguredShot = scratch / "vibfolder-not-configured.png"
    let resultsShot = scratch / "vibfolder-results.png"
    createDir(scratch)
    let limits = QcLimits(avgPhaseDeg: 40, peakPhaseDeg: 80,
      avgDistortionPct: NaN, peakDistortionPct: NaN,
      avgForcePct: NaN, peakForcePct: NaN)
    doAssert good.len > 0 and reversed.len > 0 and deep.len > 0

    var asked: seq[DialogKind]
    var answer: seq[string]
    var expectedCsv = ""
    var expectedTotals = ""
    var corruptWord = ""
    var judged = false
    var shownTable = FolderTable()
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      answer

    proc judgeOnce(f: FrameInfo) =
      if judged: return
      let files = listedOf(FolderChoice(folder: folder))
      var names: seq[string] = @[]
      for item in files: names.add item.path.extractFilename
      doAssert "notes.txt" notin names, "a text file was listed: " & $names
      doAssert "deep.dat" notin names, "a subfolder was listed: " & $names
      doAssert "good.dat" in names and "reversed.dat" in names and "corrupt.dat" in names,
        "the signature files were not all listed: " & $names
      let config = vibQcConfig(f.core)
      doAssert config.configured
      let jobs = initJobs()
      let sink = FolderQcSink()
      let id = jobs.submit(folderQcSpec(files),
        folderQcWork(config.ask, config.weights, files, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the independent run did not finish"
      let info = jobs.info(id).get
      doAssert info.state == jsDone, info.error
      let table = sink.result
      shownTable = table
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

    proc listFolder(f: FrameInfo) =
      f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
    proc folderListed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("a folder is open in the file list", listFolder, folderListed)

    proc openMenu(f: FrameInfo) = f.click(f.markOf("menu.Reports").centre)
    proc itemActive(f: FrameInfo): bool =
      f.markOf("menu.Vibrator QC of a folder").size.x > 0 and
        f.markOf("menu.Vibrator QC of a folder.disabled").size.x == 0
    step("the Reports item is active without a folder", openMenu, itemActive)

    var opened = false
    var windowMenuClicks = 0
    proc openWindow(f: FrameInfo) =
      if f.markOf("menu.Vibrator QC of a folder").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc windowOpen(f: FrameInfo): bool =
      if not opened:
        let it = f.markOf("menu.Vibrator QC of a folder")
        if it.size.x > 0:
          f.click(it.centre)
          opened = true
        return false
      if f.markOf("vibfolder.notconfigured").size.x == 0: return false
      doAssert f.markOf("vibfolder.configure where").size.x > 0, "no line says where"
      doAssert f.markNames("vibfolder.profile ").len == 0, "a configuration is shown"
      doAssert f.markNames("vibfolder.file ").len == 0,
        "the open folder was listed: " & $f.markNames("vibfolder.file ")
      doAssert f.markOf("vibfolder.run.disabled").size.x > 0, "Run is not disabled"
      doAssert f.markOf("vibfolder.folder").size.x > 0 and
        f.markOf("vibfolder.files").size.x > 0, "the choice buttons are missing"
      doAssert f.markNames("vibfolder.weight ").len == 0, "the window asks for weights"
      let (m, p) = (f.windowPlace("vibfolder"), f.windowPlace("plot"))
      if not m.inSight: return false
      doAssert m.docked and not m.apart, "not in the centre dock: " & $m
      doAssert abs(m.rect.pos.x - p.rect.pos.x) <= 2 and
        abs(m.rect.pos.y - p.rect.pos.y) <= 2,
        "not a tab beside the Seismic window: " & $m.rect & " plot " & $p.rect
      doAssert f.savePng(notConfiguredShot), "the not-configured shot was not written"
      true
    step("the window asks for no setting and lists nothing", openWindow, windowOpen)

    proc viewMenu(f: FrameInfo) =
      windowMenuClicks = 0
      f.click(f.markOf("menu.View").centre)
    proc hideFromMenu(f: FrameInfo): bool =
      if windowMenuClicks == 0:
        let it = f.markOf("menu.window.vibfolder")
        if it.size.x > 0:
          f.click(it.centre)
          inc windowMenuClicks
        return false
      awVibFolder in f.hiddenWindows
    step("the Window menu closes the window", viewMenu, hideFromMenu)

    proc viewMenuAgain(f: FrameInfo) =
      windowMenuClicks = 0
      f.click(f.markOf("menu.View").centre)
    proc showFromMenu(f: FrameInfo): bool =
      if windowMenuClicks == 0:
        let it = f.markOf("menu.window.vibfolder")
        if it.size.x > 0:
          f.click(it.centre)
          inc windowMenuClicks
        return false
      awVibFolder notin f.hiddenWindows and f.markOf("vibfolder.notconfigured").size.x > 0
    step("the Window menu brings it back", viewMenuAgain, showFromMenu)

    proc openFile(f: FrameInfo) =
      f.apply Command(kind: ckOpen, paths: @[good])
    proc fileShown(f: FrameInfo): bool =
      f.core.sessions.len > 0 and
        f.core.panels[f.core.findPanel(MainPanel)].laidOut
    step("the signature file is shown", openFile, fileShown)

    proc makeProject(f: FrameInfo) =
      f.apply Command(kind: ckNewProject, projectPath: proj, dataFolders: @[folder])
    proc projectOpen(f: FrameInfo): bool =
      f.core.inProject and not f.core.project.readOnly and
        not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("a project is open beside the data", makeProject, projectOpen)

    proc openVib(f: FrameInfo) =
      if f.core.plots.len > 0: return
      let b = f.core.sessions[0].base
      f.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[b])
    proc vibShown(f: FrameInfo): bool =
      f.core.plots.len > 0 and f.core.plots[0].result.gen > 0 and not f.core.plots[0].waiting
    step("a Vibrator window is open on the file", openVib, vibShown)

    proc plotMark(f: FrameInfo; what: string): string =
      "new plot " & $f.core.plots[0].id & "." & what
    proc openWheel(f: FrameInfo) = f.click(f.markOf(f.plotMark("wheel")).centre)
    proc weightsGroup(f: FrameInfo): bool =
      f.markOf(f.plotMark("job weight Hold-down")).size.x > 0 and
        f.markOf(f.plotMark("job weight Baseplate")).size.x > 0 and
        f.markOf(f.plotMark("job weight Reaction mass")).size.x > 0 and
        f.markOf(f.plotMark("job weight Hold-down.disabled")).size.x == 0
    step("the settings wheel holds the job's weights", openWheel, weightsGroup)

    step("the weights start unset", noop, proc (f: FrameInfo): bool =
      let w = f.core.project.doc.vibJobWeights
      doAssert w.holdDownKg.isNaN and w.baseplateMassKg.isNaN and w.reactionMassKg.isNaN,
        "a weight was set before it was typed"
      wait > 3)

    step("click the hold-down box", proc (f: FrameInfo) =
      f.click(f.markOf(f.plotMark("job weight Hold-down")).centre),
      proc (f: FrameInfo): bool = wait > 5)

    step("a typed hold-down weight is stored", proc (f: FrameInfo) =
      f.typeText("18000")
      f.pressKey(skEnter, true)
      f.pressKey(skEnter, false), proc (f: FrameInfo): bool =
      let w = f.core.project.doc.vibJobWeights
      result = w.holdDownKg == 18000.0
      if result:
        doAssert w.baseplateMassKg.isNaN and w.reactionMassKg.isNaN,
          "another weight changed: " & $w)

    step("the wheel is closed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      f.markOf(f.plotMark("job weight Hold-down")).size.x == 0)

    proc setUp(f: FrameInfo) =
      ## What the user sets in the window: the limits and the drive level (60 %).
      var p = f.core.plots[0].params
      p.qc = limits
      p.qcWindowMs = 500.0
      p.harmonics = 5
      p.targetPct = 60
      f.apply Command(kind: ckPlotDisplay, plot: f.core.plots[0].id, plotParams: p)
    proc configured(f: FrameInfo): bool =
      if not f.core.project.doc.hasVibProfile: return false
      doAssert f.core.project.doc.vibProfile.targetPct == 60,
        "the drive level was not kept: " & $f.core.project.doc.vibProfile.targetPct
      doAssert f.markNames("new plot " & $f.core.plots[0].id & ".use as profile").len == 0,
        "the Use as profile button is still drawn"
      var line = ""
      for name in f.markNames("vibfolder.profile "): line = name
      line.len > 0 and "Drive 60%" in line and "average distortion off" in line and
        f.markOf("vibfolder.notconfigured").size.x == 0
    step("the window's settings are the configuration in force", setUp, configured)

    proc closeVib(f: FrameInfo) =
      if f.core.plots.len > 0:
        f.apply Command(kind: ckClosePlot, plot: f.core.plots[0].id)
    proc vibClosed(f: FrameInfo): bool = f.core.plots.len == 0
    step("the Vibrator window is closed", closeVib, vibClosed)

    proc stillNothing(f: FrameInfo): bool =
      doAssert f.markNames("vibfolder.file ").len == 0,
        "the open folder was listed: " & $f.markNames("vibfolder.file ")
      doAssert f.markOf("vibfolder.run.disabled").size.x > 0, "Run is enabled with no choice"
      wait > 8
    step("nothing is listed until a choice is made", noop, stillNothing)

    proc chooseFolder(f: FrameInfo) =
      asked.setLen 0
      answer = @[folder]
      f.click(f.markOf("vibfolder.folder").centre)
    proc folderChosen(f: FrameInfo): bool =
      if f.markOf("vibfolder.ready").size.x == 0: return false
      if f.markOf("vibfolder.file good.dat").size.x == 0: return false
      doAssert asked == @[dkVibFolder], "asked for " & $asked
      doAssert f.markOf("vibfolder.file reversed.dat").size.x > 0
      doAssert f.markOf("vibfolder.file corrupt.dat").size.x > 0
      doAssert f.markOf("vibfolder.file notes.txt").size.x == 0, "notes.txt was listed"
      doAssert f.markOf("vibfolder.file deep.dat").size.x == 0, "a subfolder was listed"
      doAssert f.markOf("vibfolder.subfolders off").size.x > 0
      doAssert f.markNames("vibfolder.chosen Folder: ").len == 1
      doAssert f.markOf("vibfolder.tick good.dat").size.x > 0, "good.dat was not ticked"
      doAssert f.markOf("vibfolder.run.disabled").size.x == 0, "Run is disabled"
      true
    step("Folder... lists that folder only", chooseFolder, folderChosen)

    proc clickBox(f: FrameInfo; name: string) =
      ## A click on the square of a tick box.
      let box = f.markOf(name)
      f.click(vec2(round(box.pos.x + box.size.y / 2), round(box.pos.y + box.size.y / 2)))
    proc tickSubfolders(f: FrameInfo) = f.clickBox("vibfolder.subfolders off")
    proc subfoldersListed(f: FrameInfo): bool =
      f.markOf("vibfolder.subfolders on").size.x > 0 and
        f.markOf("vibfolder.file deep.dat").size.x > 0 and
        f.markOf("vibfolder.ticked 4 of 4").size.x > 0
    step("Include subfolders lists the folders under it", tickSubfolders, subfoldersListed)

    proc untickSubfolders(f: FrameInfo) = f.clickBox("vibfolder.subfolders on")
    proc subfoldersGone(f: FrameInfo): bool =
      f.markOf("vibfolder.subfolders off").size.x > 0 and
        f.markOf("vibfolder.file good.dat").size.x > 0 and
        f.markOf("vibfolder.file deep.dat").size.x == 0 and
        f.markOf("vibfolder.ticked 3 of 3").size.x > 0
    step("Include subfolders off lists the folder only", untickSubfolders, subfoldersGone)

    proc chooseFiles(f: FrameInfo) =
      asked.setLen 0
      answer = @[good, deep]
      f.click(f.markOf("vibfolder.files").centre)
    proc filesChosen(f: FrameInfo): bool =
      if f.markOf("vibfolder.ticked 2 of 2").size.x == 0: return false
      doAssert asked == @[dkVibFiles], "asked for " & $asked
      doAssert f.markOf("vibfolder.file good.dat").size.x > 0 and
        f.markOf("vibfolder.file deep.dat").size.x > 0
      doAssert f.markOf("vibfolder.file reversed.dat").size.x == 0, "a file not chosen was listed"
      true
    step("Files... lists those files", chooseFiles, filesChosen)

    step("Folder... again, for the run", chooseFolder, folderChosen)

    var clicked = false
    var picked = false
    var pickWait = 0
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
      doAssert "1 problem" in expectedTotals and "1 problems" notin expectedTotals,
        expectedTotals
      doAssert f.markOf("vibfolder.tab Results").size.x > 0, "Results tab is missing"
      doAssert f.markOf("vibfolder.col File").size.x > 90,
        "File column is " & $f.markOf("vibfolder.col File").size.x
      doAssert f.markOf("vibfolder.problem " & RecordedReference).size.x > 0,
        "reference: " & $f.markNames("vibfolder.problem ")
      doAssert f.markNames("vibfolder.problem The reference is not in the archive.").len == 0
      # the columns, in order: name, electronics, vibrator, time, then the shot log's
      var at = -1'f32
      for name in [ColFile, ColController, ColVibrator, ColTime]:
        let h = f.markOf("vibfolder.header " & name)
        doAssert h.size.x > 0, "no " & name & " column"
        doAssert h.pos.x > at, name & " is not after the column before it"
        at = h.pos.x
      let good1 = rowOf(shownTable, "good.dat")
      doAssert good1.controller == 4321 and good1.vibrator == 12
      doAssert f.markOf("vibfolder.cell " & ColController & " good.dat 4321").size.x > 0,
        "electronics: " & $f.markNames("vibfolder.cell " & ColController)
      doAssert f.markOf("vibfolder.cell " & ColVibrator & " good.dat 12").size.x > 0
      doAssert f.markNames("vibfolder.cell " & ColTime & " good.dat 2001-02-03 04:05:").len == 1,
        "time: " & $f.markNames("vibfolder.cell " & ColTime)
      doAssert f.markOf("vibfolder.noshotlog").size.x > 0, "the no-shot-log line is missing"
      doAssert f.markNames("vibfolder.cell " & ColFfid & " good.dat 7").len == 0
      if not picked:
        let row = f.markOf("vibfolder.row reversed.dat fail")
        let col = f.markOf("vibfolder.col File")
        let x = if col.size.x > 0: col.pos.x + min(24'f32, col.size.x / 2) else: row.pos.x + 24
        f.click(vec2(round(x), round(row.pos.y + row.size.y / 2)))
        picked = true
        return false
      inc pickWait
      if pickWait < 4 and f.markNames("vibfolder.detail sentence ").len == 0: return false
      let sentence = rowOf(shownTable, "reversed.dat").sentence
      var shown = false
      for name in f.markNames("vibfolder.detail sentence "):
        if sentence in name: shown = true
      doAssert shown, "detail: " & $f.markNames("vibfolder.detail ")
      true
    step("the rows match an independent run", runQc, ran)

    proc seek(f: FrameInfo; name: string): bool =
      ## True once the header `name` is drawn; else the table is scrolled one notch
      ## sideways toward it (a cell of a column off to the side is not drawn).
      if f.markOf("vibfolder.header " & name).size.x > 0: return true
      var seen = 0
      let names = headers()
      for i, h in names:
        if f.markOf("vibfolder.header " & h).size.x > 0: seen = max(seen, i)
      let target = names.find(name)
      let home = f.markOf("vibfolder.header " & ColFile).centre
      f.scrollWheel(home, 0, if target > seen: 4.0'f32 else: -4.0'f32)
      false

    proc scrollRight(f: FrameInfo) = discard
    proc verdictColumns(f: FrameInfo): bool =
      if not f.seek(ColSentence): return false
      let reason = rowOf(shownTable, "corrupt.dat").problem
      doAssert reason.len > 0, "the corrupt row has no reason"
      doAssert f.markOf("vibfolder.sentence corrupt.dat " & reason).size.x > 0,
        "sentence: " & $f.markNames("vibfolder.sentence ")
      doAssert f.markOf("vibfolder.kind good.dat " & DatKindLabel).size.x > 0,
        "kind: " & $f.markNames("vibfolder.kind ")
      let sentenceCol = f.markOf("vibfolder.col Sentence").size.x
      doAssert sentenceCol > 200, "Sentence column is " & $sentenceCol
      var at = -1'f32
      for name in [ColKind, ColVerdict, ColSentence]:
        let h = f.markOf("vibfolder.header " & name)
        doAssert h.size.x > 0, "no " & name & " column"
        doAssert h.pos.x > at, name & " is not after the column before it"
        at = h.pos.x
      true
    step("the verdict columns follow the identity columns", scrollRight, verdictColumns)

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

    proc clearFilter(f: FrameInfo) =
      f.click(f.markOf("vibfolder.filter").centre)
      f.pressKey(skEnd, true)
      f.pressKey(skEnd, false)
      for i in 1 .. 8:
        f.pressKey(skBackspace, true)
        f.pressKey(skBackspace, false)
    proc filterCleared(f: FrameInfo): bool =
      f.markOf("vibfolder.row good.dat pass").size.x > 0
    step("the filter is cleared", clearFilter, filterCleared)

    proc importLog(f: FrameInfo) =
      ## A shot log with the sweeps of good.dat (7001) and reversed.dat (7002). The cut-off
      ## file has no readable trigger time: it has no row to match, and shows none.
      let logPath = fx.dir / "shots.csv"
      let us0 = 981173106789000'i64 - 6 * 1_000_000'i64
      writeFile(logPath, "UTC microseconds,file number,source line,shot point\n" &
        $(us0 + 1_000_000) & ",7001,100.00,1010.00\n" &
        $(us0 + 2_000_000) & ",7002,100.00,1012.50\n")
      f.apply Command(kind: ckImportShotLog, logPath: logPath)
    proc logMatched(f: FrameInfo): bool =
      if f.core.shotLogCount == 0 or f.core.jobs.active.len > 0: return false
      if not f.seek(ColSourcePoint) or not f.seek(ColFfid): return false
      if f.markOf("vibfolder.cell " & ColFfid & " good.dat 7001").size.x == 0: return false
      doAssert f.markOf("vibfolder.noshotlog").size.x == 0, "the no-log line stays"
      doAssert f.markOf("vibfolder.cell " & ColSourceLine & " good.dat 100").size.x > 0
      doAssert f.markOf("vibfolder.cell " & ColSourcePoint & " good.dat 1010").size.x > 0
      doAssert f.markOf("vibfolder.cell " & ColSourcePoint & " reversed.dat 1012.5").size.x > 0,
        "the second sweep was not matched: " & $f.markNames("vibfolder.cell " & ColSourcePoint)
      doAssert f.markNames("vibfolder.cell " & ColFfid & " corrupt.dat 7").len == 0,
        "a guess for a sweep the log does not have"
      doAssert f.savePng(resultsShot), "results shot was not written"
      true
    step("the shot log fills FFID and source point", importLog, logMatched)

    var tickPhase = 0
    proc openFiles(f: FrameInfo) = tickPhase = 0
    proc ticks(f: FrameInfo): bool =
      case tickPhase
      of 0:
        f.click(f.markOf("vibfolder.tab Files").centre)
        inc tickPhase
      of 1:
        if f.markOf("vibfolder.file good.dat").size.x == 0:
          if wait mod 8 == 0: f.click(f.markOf("vibfolder.tab Files").centre)
          return false
        doAssert f.markOf("vibfolder.all").size.x > 0, "All is missing"
        doAssert f.markOf("vibfolder.none").size.x > 0, "None is missing"
        doAssert f.markOf("vibfolder.ticked 3 of 3").size.x > 0,
          "count: " & $f.markNames("vibfolder.ticked ")
        f.click(f.markOf("vibfolder.none").centre)
        inc tickPhase
      of 2:
        if f.markOf("vibfolder.ticked 0 of 3").size.x == 0: return false
        doAssert f.markOf("vibfolder.run.disabled").size.x > 0, "None left Run enabled"
        f.click(f.markOf("vibfolder.all").centre)
        inc tickPhase
      else:
        result = f.markOf("vibfolder.ticked 3 of 3").size.x > 0 and
          f.markOf("vibfolder.tick good.dat").size.x > 0 and
          f.markOf("vibfolder.run.disabled").size.x == 0
    step("All and None tick the list", openFiles, ticks)

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

    var budgetAt = -1
    var builtAt = 0
    var sinceTable = getMonoTime()
    proc showMany(f: FrameInfo) =
      f.showVibFolderTable(syntheticRows(500))
    proc manyOk(f: FrameInfo): bool =
      if f.markNames("vibfolder.row ").len == 0: return false
      if f.markNames("vibfolder.totals 500 files").len == 0: return false
      if budgetAt < 0:
        budgetAt = f.index
        builtAt = f.vibFolderViewBuilds
        sinceTable = getMonoTime()
        return false
      if getMonoTime() - sinceTable < initDuration(milliseconds = 1200): return false
      doAssert f.vibFolderViewBuilds == builtAt, "the view was rebuilt: " &
        $f.vibFolderViewBuilds & " from " & $builtAt
      let budget = int(DefaultFrameBudget.inMilliseconds)
      var worst = 0
      var bad = ""
      for m in f.messages:
        for hit in frameTooks(m.text):
          if hit.n <= budgetAt: continue
          if hit.ms > worst: worst = hit.ms
          if hit.ms > budget: bad = m.text
      echo "tguivibfolder: 500 rows, later frames worst ", worst, " ms (budget ", budget, ")"
      doAssert bad.len == 0, "over budget after the first table frame: " & bad
      true
    step("500 rows stay within the frame budget", showMany, manyOk)

    proc pressClose(f: FrameInfo) =
      ## The close button at the right end of the title row (the window's mark begins there).
      let r = f.markOf("vibfolder")
      f.click(vec2(round(r.pos.x + r.size.x - 17), round(r.pos.y + 12)))
    step("the close button hides the window", pressClose, proc (f: FrameInfo): bool =
      awVibFolder in f.hiddenWindows)

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
          failed = steps[at].name & " did not happen (marks: " &
            $f.markNames("vibfolder.") & ")"
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
