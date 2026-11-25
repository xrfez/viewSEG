## Project > Slice by shot log, headless, driven by real clicks: the menu item does
## nothing while no log is loaded and opens the dialog once one is, with no file shown too (the
## dialog asks for one and its Choose file opens it); the dialog sums up the shots, the components and the size; a
## record length that is not a whole number of samples shows the sentence of
## `checkOptions` and Cut stays dim; with a good length a run writes the file and
## the dialog offers to open it.
##
## The record length typed is kept in the settings and offered by the next open (a new
## session too). Seen to fail: with the window never storing it, "the length is remembered"
## never comes; with `open` ignoring its argument, "the remembered length was not offered".
## With the menu item still dim for a missing file, "the dialog opened with no file shown" never
## comes. With the menu item always enabled, "the dialog opened with no
## file and no log". With the summary counting the row without a time, "the
## summary names the wrong shots". With the length sentence not marked, "the cut
## did not finish: a length that is not whole samples". With Cut left enabled on
## a bad length, "Cut started a job on a bad length". With the open button not
## drawn after a cut, "the cut did not finish: Cut".
##
## A whole folder: Choose folder, the window counts the files that can be sliced and names the
## others, and Slice the folder writes a file for the one that holds the shots and nothing for
## the rest. Seen to fail with the Slice the folder button doing nothing ("the cut did not
## finish: Slice the folder").
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[cutfolderjobs, geometry, outputbinary, outputtext, references, shotlog,
  state, threads]
import viewSEG/ui/imgui/[app, cutgatherdialog, shell]
import viewSEG/view/[cutwords, outputwords]

import utils/[faultyfs, fixtures, waiting]

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  SegLen = 3000
  ItemName = "menu.Slice by shot log..."

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc hasMark(f: FrameInfo; name: string): bool =
  f.markOf(name).size.x > 0

block the_first_open_takes_the_remembered_length:
  # A new session: the settings hold the length the last session left, and the window
  # starts with it; with nothing remembered it is 10000 ms. A later open keeps what is typed.
  var ui: CutUi
  ui.open(-1, DefaultRecordMs)
  doAssert ui.recordLengthMs == 10_000.0, "the default length is not 10000"
  var again: CutUi
  again.open(-1, 4000.5)
  doAssert again.recordLengthMs == 4000.5, "the remembered length was not offered"
  again.open(-1, 2000.0)
  doAssert again.recordLengthMs == 4000.5, "a later open dropped the length"

proc makeRecording(path: string; offsetS = 0) =
  ## Two components, two source traces each of 3000 samples at 2 ms, from `offsetS` seconds
  ## after BaseUs.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 .. 1:
    for comp in 0 .. 1:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = float32(100_000 * comp + seg * SegLen + j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(comp + 11)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000 + offsetS) + float64(seg * SegLen) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, samples)
  discard w.close()

proc writeLog(path: string): ShotLogMap =
  ## Three timed shots and one row without a time.
  var text = ""
  for (file, offsetUs) in [(101, 1_000_000'i64), (102, 2_000_000), (103, 4_000_000)]:
    text.add $file & "," & $(BaseUs + offsetUs) & "\n"
  text.add "104,\n"
  writeFile(path, text)
  result = initShotLogMap()
  result.hasHeader = false
  result.roles = @[crFileNumber, crTime]
  result.dateTimePattern = EpochMicros

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    createDir(fx.dir / "in")
    createDir(fx.dir / "out")
    let rec = fx.dir / "in" / "rec.sgy"
    makeRecording(rec)
    let logPath = fx.dir / "shots.csv"
    let map = writeLog(logPath)
    let dest = fx.dir / "out" / "rec_slice.sgd"
    # a folder of recordings: one holds the shots, one is a day later, one is not a recording
    let many = fx.dir / "folder"
    createDir(many)
    makeRecording(many / "a.sgy")
    makeRecording(many / "b.sgy", 86_400)
    writeFile(many / "notes.txt", "not a recording\n")
    let before = readFile(many / "a.sgy")
    # the reference archive: a stored sweep of 16 samples at 2 ms and a pilot rule
    var sweep = newSeq[float32](16)
    for i in 0 ..< sweep.len: sweep[i] = float32(i + 1) * 0.25
    markWorkerThread() # the archive is written off the UI thread; run() marks it again
    let archive = referencesFolder(fx.dir / "config")
    let sweepId = storeSamples(archive, "test sweep", 2000.0, sweep,
      ReferenceOrigin(generated: true, dtMs: 2.0, durationMs: 32))
    let pilotId = storePilotRule(archive, PilotRule(name: "a pilot", aux: true, trace: 1,
      startMs: 0.0, spanMs: 32.0))
    install()
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkCutDest: @[fx.dir / "out"]
      elif kind == dkCutSourceFolder: @[many]
      elif kind == dkOpenFile: @[rec]
      else: @[]
    let opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      dialogs: hook)
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var clicks = 0
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc menuItem(f: FrameInfo) =
      ## The Project menu open, the item under the pointer (a click comes next).
      if not f.hasMark(ItemName): f.click(f.markOf("menu.Project").centre)
    proc summary(f: FrameInfo): string =
      let names = f.markNames("cut.summary ")
      if names.len > 0: names[0]["cut.summary ".len .. ^1] else: ""
    proc why(f: FrameInfo): string =
      let names = f.markNames("cut.why ")
      if names.len > 0: names[0]["cut.why ".len .. ^1] else: ""
    step("in the main window", proc (f: FrameInfo) = f.keepInMainWindow(),
      proc (f: FrameInfo): bool = true)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.hasMark(ItemName))
    proc noDialog(f: FrameInfo): bool =
      inc clicks
      doAssert not f.hasMark("cut"), "the dialog opened with no file and no log"
      clicks >= 5
    step("the item with no file and no log", proc (f: FrameInfo) =
      clicks = 0
      f.click(f.markOf(ItemName).centre), noDialog)
    proc logOnly(f: FrameInfo) =
      f.apply Command(kind: ckImportShotLog, logPath: logPath, logMap: map, logMapped: true)
    step("a log and no file", logOnly, proc (f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.core.jobs.active.len == 0 and
        f.core.shownFile(f.core.findPanel(MainPanel)) < 0)
    proc openItem(f: FrameInfo): bool =
      if f.hasMark(ItemName) and not f.hasMark("cut"): f.click(f.markOf(ItemName).centre)
      f.hasMark("cut")
    step("the item opens the dialog with no file shown", menuItem, openItem)
    step("the dialog says to choose a file", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool =
      doAssert f.core.cutProblem == CutNeedFile, f.core.cutProblem
      f.hasMark("cut.needSource") and f.hasMark("cut.chooseFile"))
    step("Choose file", proc (f: FrameInfo) = f.click(f.markOf("cut.chooseFile").centre),
      proc (f: FrameInfo): bool =
      f.core.shownFile(f.core.findPanel(MainPanel)) >= 0 and f.core.jobs.active.len == 0 and
        not f.hasMark("cut.needSource"))
    step("Close the dialog", proc (f: FrameInfo) = f.click(f.markOf("cut.close").centre),
      proc (f: FrameInfo): bool = not f.hasMark("cut"))
    step("the item opens the dialog", menuItem, openItem)
    proc summed(f: FrameInfo): bool =
      let s = f.summary
      if s.len == 0: return false
      doAssert f.hasMark("cut.format SEG-D Rev 3.on"), "the Format entry is not SEG-D Rev 3"
      doAssert f.hasMark("cut.order"), "the Trace order entry is not drawn"
      doAssert f.core.settings.cutGather.recordMs == 10_000.0, "the default length is not 10000"
      doAssert s.startsWith("3 shots (1 row has no time and is left out), 2 components, " &
        "about "), "the summary names the wrong shots: " & s
      true
    step("the summary", proc (f: FrameInfo) = discard, summed)
    proc clickLength(f: FrameInfo) =
      clicks = 0
      f.click(f.markOf("cut.length").centre)
    proc badLength(f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("1001")
      clicks > 8 and "whole number of samples" in f.why
    step("a length that is not whole samples", clickLength, badLength)
    step("a folder", proc (f: FrameInfo) = f.click(f.markOf("cut.changeFolder").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.folder " & (fx.dir / "out")))
    proc clickCut(f: FrameInfo) =
      clicks = 0
      f.click(f.markOf("cut.run").centre)
    proc stillDim(f: FrameInfo): bool =
      inc clicks
      doAssert not f.core.cutRunning and f.core.cutOutcome.len == 0 and not fileExists(dest),
        "Cut started a job on a bad length"
      clicks >= 6
    step("Cut on a bad length", clickCut, stillDim)
    proc goodLength(f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("1000")
      clicks > 8 and f.why.len == 0 and f.summary.len > 0
    step("a good length", clickLength, goodLength)
    proc remembered(f: FrameInfo): bool =
      f.core.settings.cutGather.recordMs == 1000.0
    step("the length is remembered", proc (f: FrameInfo) = discard, remembered)
    step("Close", proc (f: FrameInfo) = f.click(f.markOf("cut.close").centre),
      proc (f: FrameInfo): bool = not f.hasMark("cut"))
    step("the item opens the dialog again", menuItem, openItem)
    step("the dialog still has the length", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool = f.hasMark("cut.recordMs 1000.0"))
    var shot = false
    proc picture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not shot:
        createDir(dir)
        doAssert f.savePng(dir / "cut-dialog.png"), "cannot save the dialog"
      shot = true
    step("the picture", picture, proc (f: FrameInfo): bool = true)
    # The tick that correlates each record with the project's stored sweep: dim with no
    # reference chosen and with a pilot, usable with a stored sweep, remembered, and the cut
    # that follows holds the listen time (500 samples of the record less the sweep's 16).
    proc dim(f: FrameInfo): bool =
      doAssert f.hasMark("cut.correlate.disabled"), "the tick is usable with no reference"
      f.markNames("cut.correlate.why " & CorrelatedNeedRef).len == 1
    step("the tick is dim with no reference", proc (f: FrameInfo) = discard, dim)
    step("a pilot is chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: pilotId)),
      proc (f: FrameInfo): bool =
      f.hasMark("cut.correlate.disabled") and
        f.markNames("cut.correlate.why " & CorrelatedPilotWhy).len == 1)
    step("a stored sweep is chosen", proc (f: FrameInfo) =
      f.apply(Command(kind: ckSelectReference, refId: sweepId)),
      proc (f: FrameInfo): bool =
      f.hasMark("cut.correlate") and not f.hasMark("cut.correlate.disabled"))
    step("the tick is ticked", proc (f: FrameInfo) = f.click(f.markOf("cut.correlate").centre),
      proc (f: FrameInfo): bool =
      let says = f.markNames("cut.correlate.says ")
      if says.len == 0: return false
      doAssert "'test sweep'" in says[0] and "(484 samples)" in says[0], says[0]
      doAssert f.core.settings.cutGather.correlated, "the tick was not remembered"
      doAssert not f.hasMark("cut.correlate.noCarry"), "a SEG-Y recording has no headers to carry"
      f.hasMark("cut.correlate.on"))
    var corrShot = false
    proc corrPicture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not corrShot:
        createDir(dir)
        doAssert f.savePng(dir / "slicecorr.png"), "cannot save the dialog"
      corrShot = true
    step("the picture of the tick", corrPicture, proc (f: FrameInfo): bool = true)
    # The tick on and a record no longer than the sweep (10 samples of 16): the tick cannot
    # be honoured, so Slice is dim with the sentence and nothing is written; the tick can be
    # cleared, and Slice is usable again. Broken to see it fail: `problem` not set from
    # `whyNotCorrelated` (Slice then cut an uncorrelated file) and the box disabled.
    const ShortWhy = "the record must be the sweep plus the listen time"
    step("a record no longer than the sweep", clickLength, proc (f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("20")
      clicks > 8 and ShortWhy in f.why)
    var refusedShot = false
    proc refusedPicture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not refusedShot:
        createDir(dir)
        doAssert f.savePng(dir / "slicecorr-refused.png"), "cannot save the dialog"
      refusedShot = true
      clicks = 0
      f.click(f.markOf("cut.run").centre)
    step("Slice is dim with the sentence", refusedPicture, proc (f: FrameInfo): bool =
      inc clicks
      doAssert f.core.settings.cutGather.correlated and ShortWhy in f.why
      doAssert not f.core.cutRunning and not fileExists(dest), "a file was written"
      clicks >= 6)
    step("the tick is cleared", proc (f: FrameInfo) = f.click(f.markOf("cut.correlate").centre),
      proc (f: FrameInfo): bool =
      not f.core.settings.cutGather.correlated and f.why.len == 0 and f.summary.len > 0)
    step("the length restored", clickLength, proc (f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("1000")
      clicks > 8 and f.why.len == 0 and f.summary.len > 0)
    step("the tick, usable again", proc (f: FrameInfo) = f.click(f.markOf("cut.correlate").centre),
      proc (f: FrameInfo): bool =
      f.core.settings.cutGather.correlated and f.hasMark("cut.correlate.on"))
    step("Cut", proc (f: FrameInfo) = f.click(f.markOf("cut.run").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.open") and fileExists(dest))
    step("the cut file holds the listen time", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool =
      var sliced = openSeismic(dest, keys = true)
      defer: sliced.close()
      doAssert sliced.len == 6 and int(sliced.traceEntry(0).numSamples) == 484,
        $sliced.len & " traces of " & $sliced.traceEntry(0).numSamples & " samples"
      true)
    # The file now exists: the window says so and Cut stays dim (the check
    # looked at the disk again because the cut finished).
    step("the destination exists", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool = f.hasMark("cut.exists"))
    var existsShot = false
    proc existsPicture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not existsShot:
        createDir(dir)
        doAssert f.savePng(dir / "cut-dialog-exists.png"), "cannot save the dialog"
      existsShot = true
      clicks = 0
      f.click(f.markOf("cut.run").centre)
    proc stillDimOver(f: FrameInfo): bool =
      inc clicks
      doAssert not f.core.cutRunning, "Cut started over an existing file"
      clicks >= 6
    step("Cut over the existing file", existsPicture, stillDimOver)
    step("open the cut file", proc (f: FrameInfo) = f.click(f.markOf("cut.open").centre),
      proc (f: FrameInfo): bool =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      i >= 0 and f.core.sessions[i].path.endsWith("rec_slice.sgd"))
    # A destination on a drive that does not answer: the window goes on
    # drawing, Cut is dim and says it is checking, and the answer comes when the
    # drive does.
    step("a name on a drive that does not answer", proc (f: FrameInfo) =
      fault(fx.dir / "out", fkHang, {foStat})
      clicks = 0
      f.click(f.markOf("cut.name").centre),
      proc (f: FrameInfo): bool =
      inc clicks
      if clicks == 4: f.typeText("x")
      f.hasMark("cut.checking"))
    step("Cut is refused while it checks", proc (f: FrameInfo) =
      clicks = 0
      f.click(f.markOf("cut.run").centre),
      proc (f: FrameInfo): bool =
      inc clicks
      doAssert f.hasMark("cut.checking"), "the answer came from a drive that was hung"
      doAssert not f.core.cutRunning, "Cut started while the destination was unchecked"
      clicks >= 8)
    step("the drive answers", proc (f: FrameInfo) = release(fx.dir / "out"),
      proc (f: FrameInfo): bool = not f.hasMark("cut.checking") and not f.hasMark("cut.exists"))
    # The project's text header template and binary header set: offered for SEG-Y only, and
    # only when the project has chosen them.
    step("the Format entry opens", proc (f: FrameInfo) = f.click(f.markOf("cut.format").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.format SEG-Y"))
    step("SEG-Y", proc (f: FrameInfo) = f.click(f.markOf("cut.format SEG-Y").centre),
      proc (f: FrameInfo): bool = not f.hasMark("cut.format SEG-Y") and f.hasMark("cut.order"))
    # a new project has no reference: the tick still on would refuse every slice, so it is cleared
    step("the tick is cleared for the plain slices",
      proc (f: FrameInfo) = f.click(f.markOf("cut.correlate").centre),
      proc (f: FrameInfo): bool = not f.core.settings.cutGather.correlated)
    step("no project, no boxes", proc (f: FrameInfo) =
      f.apply(Command(kind: ckNewProject, projectPath: fx.dir / "job",
        dataFolders: @[fx.dir / "in"])),
      proc (f: FrameInfo): bool =
      doAssert not f.hasMark("cut.useText") or f.core.inProject, "a box with no project"
      f.core.inProject and f.core.projectOpening.len == 0 and not f.core.project.readOnly)
    step("a template and a set chosen", proc (f: FrameInfo) =
      f.apply Command(kind: ckOutputText, textAction: otaSave, textTemplate: OutputText(
        name: "Survey", encoding: teAscii, lines: @["SLICE {stem}", "RECORD {record}"]))
      f.apply Command(kind: ckOutputText, textAction: otaChoose,
        textTemplate: OutputText(name: "Survey"))
      f.apply Command(kind: ckOutputBinary, binaryAction: obaSave, binarySet: OutputBinary(
        name: "Job", entries: @[BinaryEntry(field: "jobId", value: "12")]))
      f.apply(Command(kind: ckOutputBinary, binaryAction: obaChoose,
        binarySet: OutputBinary(name: "Job"))),
      proc (f: FrameInfo): bool = f.hasMark("cut.useText") and f.hasMark("cut.useBinary"))
    var boxesShot = false
    proc boxesPicture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not boxesShot:
        createDir(dir)
        doAssert f.savePng(dir / "cut-dialog-headers.png"), "cannot save the dialog"
      boxesShot = true
    step("the picture of the boxes", boxesPicture, proc (f: FrameInfo): bool = true)
    # A whole folder: the folder is chosen, the window says how many of its files can be
    # sliced and why the others cannot, and a run writes a file for the one that holds the shots.
    # a slice is not written into the folder of an open file: the sliced file is closed
    proc closeAll(f: FrameInfo) =
      for s in f.core.sessions: f.apply Command(kind: ckClose, file: s.id)
    step("the sliced file is closed", closeAll,
      proc (f: FrameInfo): bool = f.core.sessions.len == 0)
    step("the log again (making the project closed it)", logOnly, proc (f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.core.jobs.active.len == 0)
    step("Choose folder", proc (f: FrameInfo) = f.click(f.markOf("cut.chooseFolder").centre),
      proc (f: FrameInfo): bool = f.hasMark("cut.srcFolder " & many))
    proc checked(f: FrameInfo): bool =
      let names = f.markNames("cut.folderCheck ")
      if names.len == 0: return false
      doAssert names[0].endsWith("1 recording of 3 files can be sliced (3 shots)."), names[0]
      doAssert f.hasMark("cut.folderSkip b.sgy: " & NoShotHeld), "b.sgy is not said to hold no shot"
      doAssert f.markNames("cut.folderSkip notes.txt: ").len == 1, "notes.txt is not skipped"
      true
    step("the folder is checked", proc (f: FrameInfo) = discard, checked)
    var folderShot = false
    proc folderPicture(f: FrameInfo) =
      let dir = getEnv("VIEWSEG_SCREENSHOTS")
      if dir.len > 0 and not folderShot:
        createDir(dir)
        doAssert f.savePng(dir / "slicefolder.png"), "cannot save the dialog"
      folderShot = true
    step("the picture of the folder", folderPicture, proc (f: FrameInfo): bool = true)
    step("Slice the folder", proc (f: FrameInfo) = f.click(f.markOf("cut.runFolder").centre),
      proc (f: FrameInfo): bool =
      f.markNames("cut.folderOutcome Sliced 1 file").len == 1 and
        fileExists(fx.dir / "out" / "a_slice.sgy"))
    step("nothing else was written and the source is as it was", proc (f: FrameInfo) = discard,
      proc (f: FrameInfo): bool =
      doAssert not fileExists(fx.dir / "out" / "b_slice.sgy"), "a file without a shot was sliced"
      doAssert readFile(many / "a.sgy") == before, "the source changed"
      true)
    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " (" & f.core.cutOutcome & ")"
          f.stop()
    var o = opts
    o.onFrame = onFrame
    let code = run(o)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, "the cut did not finish: " & failed
    doAssert uiCalls().len == 0, "the UI thread called the file system:\n" & uiCalls().join("\n")
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

when isMainModule:
  main()
