## The Correlate button, headless, on two synthetic vibrator files.
##
## Correlate off, then on: the record shortens to the listen time, peaks sit
## where the delays put them, the title says correlated, and the Aux window's
## reference trace, whose position is marked for correlation with a 500 ms shift, peaks at
## 500 ms. The next file in the folder follows, with no mark: its reference trace is cut raw.
## A sweep as long as the record is refused: the raw file is shown and the
## button goes off. A kill made while correlated is kept under the raw path.
## Saving a project while correlated does not write the virtual key.
## The Binary tab's hex pane shows the open raw file's bytes.
##
## Seen to fail: a stored window of the whole trace (toMs below 0) is refused
## ("the reference sweep is as long as the record"). A project saved before
## the next file clears the chosen reference, so the next file stays raw.
## A press and a release in one frame never lands. A point taken while a
## tooltip is the window under the pointer misses the button.
##
## Needs a display: run under the tester (it gives each test its own).

import std/[math, monotimes, options, os, strutils]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, filesystem, geometry, state]
import viewSEG/ui/imgui/app
import imguin/cimgui
import utils/[fixtures, waiting]

const
  DtMs = 2.0
  AuxLeadMs = 500.0 # the shift given to the marked reference trace
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  RefAux = 3
  LeadSamples = int(round(AuxLeadMs / DtMs))
  Refusal = "the reference sweep is as long as the record or longer, " &
    "so there is no listen time."
  OffTip = "plot.correlate tip No reference is chosen. Choose one in References."
  OnTip = "plot.correlate tip Correlate with the selected reference (on)"

var
  forbidden: seq[string] = @[]
  fsSeen: seq[string] = @[]
  fsHits = 0

proc note(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    inc fsHits
    if '\0' in path:
      fsSeen.add $op & " " & path.replace("\0", "\\0")
    else:
      for f in forbidden:
        if path == f: fsSeen.add $op & " " & path

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool
  Click = object
    mark, win: string
    phase: int

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc peakAt(x: openArray[float32]): int =
  var best = -1.0
  for i, v in x:
    let a = abs(float64(v))
    if a > best:
      best = a
      result = i

proc peakOf(s: Session; trace: int): int =
  let rows = s.filePtr[].readTraces(trace .. trace)
  peakAt(rowBlock(rows).row(0))

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc writeRaw(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 correlation button test"]))
  for i in 0 .. 4:
    var buf: seq[float32]
    var k = initTraceKeys()
    if i < Delays.len:
      buf = delayedSweep(sweep, Record, Delays[i])
      (k.traceCode, k.status) = (1'i16, tsLive)
    elif i == RefAux:
      buf = delayedSweep(sweep, Record, 0)
      (k.traceCode, k.status) = (5'i16, tsAuxiliary)
    else:
      buf = newSeq[float32](Record)
      for j in 0 ..< Record: buf[j] = float32(j + 1)
      (k.traceCode, k.status) = (6'i16, tsAuxiliary)
    k.record = 7.0
    k.ensemble = 10.0 + float64(i)
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the raw file did not close"

proc main*() =
  withFixtures fx:
    let folder = fx.dir / "data"
    let config = fx.dir / "config"
    let proj = fx.dir / "job"
    let shots = currentSourcePath().parentDir.parentDir / ".scratch" / "shots"
    createDir(folder)
    createDir(config)
    createDir(shots)
    let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
    let rawA = folder / "a-raw.sgy"
    let rawB = folder / "b-raw.sgy"
    writeRaw(rawA, sweep)
    writeRaw(rawB, sweep)
    forbidden = @[correlatedPath(rawA), correlatedPath(rawB)]
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var click: Click
    var shotOff, shotOn = false
    var peaked = ""

    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)

    proc noop(f: FrameInfo) = discard

    proc pointerFb(): Vec2 =
      let m = igGetMousePos()
      let s = igGetIO_Nil().DisplayFramebufferScale
      let o = igGetMainViewport().Pos
      vec2((m.x - o.x) * s.x, (m.y - o.y) * s.y)

    proc hoveredWindow(): string =
      var w: ptr ImGuiWindow = nil
      var under: ptr ImGuiWindow = nil
      igFindHoveredWindowEx(igGetMousePos(), false, addr w, addr under)
      if w.isNil: "none" else: $w.Name

    proc shown(f: FrameInfo): int =
      f.core.shownFile(f.core.findPanel(MainPanel))

    proc samplesOf(f: FrameInfo): int =
      let k = f.core.findPanel(MainPanel)
      if k >= 0: f.core.panels[k].layout.samples else: -1

    proc laid(f: FrameInfo): bool =
      let k = f.core.findPanel(MainPanel)
      k >= 0 and f.core.panels[k].laidOut

    proc entry(f: FrameInfo; name: string): ReferenceEntry =
      for e in f.core.references.entries:
        if e.name == name: return e

    proc chosenName(f: FrameInfo): string =
      let id = f.core.chosenReference
      if id.len == 0: return "none"
      for e in f.core.references.entries:
        if e.id == id: return e.name
      id

    proc correlateJob(f: FrameInfo): string =
      for j in f.core.jobs.active:
        if j.spec.title.startsWith("Correlate"):
          if result.len > 0: result.add ", "
          result.add j.spec.title
      if result.len == 0: result = "none"

    proc noDerived(f: FrameInfo): bool =
      for s in f.core.sessions:
        if s.derived: return false
      true

    proc said(f: FrameInfo): bool =
      for e in f.core.log:
        if e.source == "correlate" and Refusal in e.text: return true

    proc status(f: FrameInfo): string =
      let i = f.shown
      var who = "none"
      if i >= 0:
        who = f.core.sessions[i].name & (if f.core.sessions[i].derived: " derived" else: " raw")
      "samples=" & $f.samplesOf & " on=" & $f.core.correlateOn & " busy=" &
        $f.core.correlating & " shown=" & who & " sessions=" & $f.core.sessions.len &
        " jobs=" & f.correlateJob & " chosen=" & f.chosenName & " hover=" & hoveredWindow() &
        " mark=" & click.mark & " sized=" & $(f.markOf(click.mark).size.x > 0) &
        " onmark=" & $(f.markOf(click.mark).contains(pointerFb())) & " phase=" & $click.phase

    proc overTarget(hover, target: string): bool =
      ## A table is its own window, named `parent/child`. A tooltip is not a hit.
      target.len > 0 and "ooltip" notin hover and
        (hover == target or hover.startsWith(target & "/"))

    proc tick(c: var Click; f: FrameInfo): bool =
      ## Moves off a tooltip, aims, presses, releases. True the frame the click has been taken.
      let live = f.markOf(c.mark)
      let hover = hoveredWindow()
      let target = if c.win == "##toolbar": "##toolbar" else: f.windowName(c.win)
      case c.phase
      of 0:
        f.moveMouse(vec2(4, 4))
        if "ooltip" notin hover: c.phase = 1
      of 1:
        if "ooltip" in hover:
          f.moveMouse(vec2(4, 4))
        elif live.size.x > 0 and live.contains(pointerFb()) and overTarget(hover, target):
          f.pressMouse(live.centre, true, 1)
          c.phase = 2
        elif live.size.x > 0:
          f.moveMouse(live.centre)
      of 2:
        if igIsMouseDown_Nil(ImGui_MouseButton_Left.cint):
          let at = if live.size.x > 0: live.centre else: pointerFb()
          f.pressMouse(at, false, 1)
          c.phase = 3
      of 3:
        if not igIsMouseDown_Nil(ImGui_MouseButton_Left.cint): return true
      else: discard
      false

    proc clickStep(name, mark, win: string; extra: proc (f: FrameInfo): bool) =
      proc act(f: FrameInfo) {.closure.} =
        click = Click(mark: mark, win: win)
        f.moveMouse(vec2(4, 4))
      proc done(f: FrameInfo): bool {.closure.} =
        click.tick(f) and extra(f)
      step(name, act, done)

    proc peaksOk(f: FrameInfo; s: Session): bool =
      if peaked == s.path: return true
      let got = @[peakOf(s, 0), peakOf(s, 1), peakOf(s, 2)]
      doAssert got == @[Delays[0], Delays[1], Delays[2]], s.name & " peaks " & $got
      let aux = peakOf(s, RefAux)
      if s.diskPath == rawA:
        doAssert aux == LeadSamples, s.name & " reference peak " & $aux
      else:
        # no mark: nothing is correlated because of its trace code, so the reference trace is
        # the raw one cut to the listen time
        doAssert aux != LeadSamples, s.name & " reference trace was correlated unmarked"
      peaked = s.path
      true

    proc correlated(f: FrameInfo; name: string): bool =
      let i = f.shown
      if i < 0: return false
      let s = f.core.sessions[i]
      if s.name != name or not s.derived or not f.laid or f.samplesOf != Listen: return false
      if f.core.correlating or not f.core.correlateOn: return false
      if "correlated" notin f.windowName("plot"): return false
      f.peaksOk(s)

    proc rawShown(f: FrameInfo; name: string): bool =
      let i = f.shown
      i >= 0 and f.core.sessions[i].name == name and not f.core.sessions[i].derived and
        f.laid and f.samplesOf == Record

    proc openA(f: FrameInfo) {.closure.} =
      f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: true)
    proc openADone(f: FrameInfo): bool {.closure.} =
      let i = f.shown
      i >= 0 and f.core.sessions[i].name == "a-raw.sgy" and not f.core.sessions[i].derived and
        f.laid and f.samplesOf == Record and f.markOf("plot.data").size.x > 0 and
        f.core.referencesLoaded
    step("a-raw opens", openA, openADone)

    proc showOffTip(f: FrameInfo) {.closure.} =
      let r = f.markOf("plot.correlate")
      if r.size.x > 0: f.moveMouse(r.centre)
    proc offTipShown(f: FrameInfo): bool {.closure.} =
      let live = f.markOf("plot.correlate")
      if live.size.x == 0: return false
      if not live.contains(pointerFb()):
        f.moveMouse(live.centre)
        return false
      if f.markOf(OffTip).size.x == 0: return false
      doAssert not f.core.correlateOn
      if not shotOff:
        doAssert f.savePng(shots / "correlate-off.png"), "the off shot was not written"
        shotOff = true
      true
    step("correlate off, tip shown", showOffTip, offTipShown)

    proc storeAaa(f: FrameInfo) {.closure.} =
      let i = f.shown
      doAssert i >= 0
      # the reference trace of this file is marked for correlation, shifted by 500 ms; the
      # next file has no mark
      f.apply Command(kind: ckFileAuxMark, auxFile: rawA, auxPosition: 1, auxMarked: amMarked,
        auxShiftMs: AuxLeadMs)
      f.apply Command(kind: ckStoreReference, refStore: StoredReference(
        name: "aaa sweep", trace: f.core.sessions[i].base + RefAux, fromMs: 0, toMs: 398.0))
    proc aaaStored(f: FrameInfo): bool {.closure.} =
      let e = f.entry("aaa sweep")
      if e.name.len == 0: return false
      doAssert e.samples == SweepLen, "stored " & $e.samples & " samples, not the sweep"
      true
    step("store aaa sweep", storeAaa, aaaStored)

    proc genLong(f: FrameInfo) {.closure.} =
      f.apply Command(kind: ckGenerateReference, refGenerate: GeneratedReference(
        name: "zzz long", law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 2000,
        dtMs: DtMs, amplitude: 1))
    proc longStored(f: FrameInfo): bool {.closure.} =
      let e = f.entry("zzz long")
      if e.name.len == 0: return false
      doAssert e.samples >= Record, "the long sweep is " & $e.samples & " samples"
      true
    step("generate zzz long", genLong, longStored)

    proc archiveOpen(f: FrameInfo): bool {.closure.} =
      f.windowName("refs").len > 0 and f.markOf("references.use.0").size.x > 0
    clickStep("open the archive", "tool.Reference archive", "##toolbar", archiveOpen)

    proc aaaChosen(f: FrameInfo): bool {.closure.} =
      let e = f.entry("aaa sweep")
      e.name.len > 0 and f.core.chosenReference == e.id
    clickStep("choose aaa sweep", "references.use.0", "refs", aaaChosen)

    proc archiveClosed(f: FrameInfo): bool {.closure.} =
      ## The ImGui window object outlives `shown`; the drawn mark does not.
      f.markOf("references").size.x == 0
    clickStep("close the archive", "tool.Reference archive", "##toolbar", archiveClosed)

    proc aCorrelated(f: FrameInfo): bool {.closure.} = f.correlated("a-raw.sgy")
    clickStep("correlate a-raw", "plot.correlate", "plot", aCorrelated)

    proc fileTab(f: FrameInfo): bool {.closure.} =
      f.markOf("headers.file tab Binary").size.x > 0 and f.correlated("a-raw.sgy")
    clickStep("file headers", "headers.tab file", "headers", fileTab)

    proc binaryTab(f: FrameInfo): bool {.closure.} =
      f.markOf("headers.binary binary.sampleInterval 0").size.x > 0
    clickStep("binary header", "headers.file tab Binary", "headers", binaryTab)

    proc hexRaw(f: FrameInfo): bool {.closure.} =
      f.markOf("headers.hex raw").size.x > 0 and f.markOf("headers.hex refused").size.x == 0 and
        f.correlated("a-raw.sgy")
    clickStep("raw bytes of the field", "headers.binary binary.sampleInterval 0", "headers",
      hexRaw)

    proc openAux(f: FrameInfo) {.closure.} =
      f.apply Command(kind: ckAuxWindow, onScreen: true)
    proc auxPeaked(f: FrameInfo): bool {.closure.} =
      f.core.auxOpen and f.markOf("aux.data").size.x > 0 and f.core.correlateOn and
        f.correlated("a-raw.sgy")
    step("aux reference peak", openAux, auxPeaked)

    proc shotOnDone(f: FrameInfo): bool {.closure.} =
      if not (f.core.correlateOn and f.markOf("aux.data").size.x > 0 and
          f.markOf("plot.correlate").size.x > 0): return false
      if not shotOn:
        doAssert f.savePng(shots / "correlate-on.png"), "the on shot was not written"
        shotOn = true
      true
    step("correlated shot", noop, shotOnDone)

    proc askSpectrum(f: FrameInfo) {.closure.} =
      let i = f.shown
      doAssert i >= 0 and f.core.sessions[i].derived
      f.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
        spectrumTraces: @[f.core.sessions[i].base])
    proc spectrumAsked(f: FrameInfo): bool {.closure.} =
      let i = f.shown
      if i < 0: return false
      let asked = f.core.spectrumAsked
      asked.path == f.core.sessions[i].path and asked.session == int(f.core.sessions[i].id) and
        asked.path == correlatedPath(rawA)
    step("spectrum of the derived file", askSpectrum, spectrumAsked)

    proc killTrace(f: FrameInfo) {.closure.} =
      let i = f.shown
      doAssert i >= 0
      f.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, on: true,
        edited: @[f.core.sessions[i].base])
    proc killed(f: FrameInfo): bool {.closure.} = f.core.hasEditAt(rawA, 0, teKilled)
    step("kill trace 0", killTrace, killed)

    proc rawAgain(f: FrameInfo): bool {.closure.} =
      not f.core.correlateOn and not f.core.correlating and f.correlateJob == "none" and
        f.noDerived and f.rawShown("a-raw.sgy") and f.core.hasEditAt(rawA, 0, teKilled)
    clickStep("correlate off", "plot.correlate", "plot", rawAgain)

    proc closeFile(f: FrameInfo) {.closure.} =
      var ids: seq[SessionId] = @[]
      for s in f.core.sessions: ids.add s.id
      for id in ids: f.apply Command(kind: ckClose, file: id)
    proc closed(f: FrameInfo): bool {.closure.} = f.core.sessions.len == 0
    step("close the file", closeFile, closed)

    proc reopen(f: FrameInfo) {.closure.} =
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: rawA)
    proc reopened(f: FrameInfo): bool {.closure.} =
      f.rawShown("a-raw.sgy") and f.core.hasEditAt(rawA, 0, teKilled)
    step("reopen a-raw", reopen, reopened)

    clickStep("correlate on again", "plot.correlate", "plot", aCorrelated)

    var fileClicks = 0
    proc showNext(f: FrameInfo) {.closure.} =
      fileClicks = 0
      click = Click(mark: "files.row b-raw.sgy", win: "files")
      f.moveMouse(vec2(4, 4))
    proc nextShown(f: FrameInfo): bool {.closure.} =
      ## The first click only focuses Files; the second shows the file.
      if fileClicks < 2 and click.tick(f):
        inc fileClicks
        if fileClicks < 2: click = Click(mark: "files.row b-raw.sgy", win: "files")
      fileClicks >= 2 and f.core.correlateOn and f.correlated("b-raw.sgy")
    step("next file", showNext, nextShown)

    proc archiveAgain(f: FrameInfo): bool {.closure.} =
      f.windowName("refs").len > 0 and f.markOf("references.use.1").size.x > 0
    clickStep("open the archive again", "tool.Reference archive", "##toolbar", archiveAgain)

    proc refused(f: FrameInfo): bool {.closure.} =
      let e = f.entry("zzz long")
      if e.name.len == 0 or f.core.chosenReference != e.id: return false
      if f.core.correlateOn or f.core.correlating: return false
      f.rawShown("b-raw.sgy") and f.said and f.markOf("messages.line " & Refusal).size.x > 0
    clickStep("a sweep that cannot be used", "references.use.1", "refs", refused)

    proc aaaAgain(f: FrameInfo): bool {.closure.} =
      let e = f.entry("aaa sweep")
      e.name.len > 0 and f.core.chosenReference == e.id and not f.core.correlateOn
    clickStep("choose aaa again", "references.use.0", "refs", aaaAgain)

    clickStep("close the archive again", "tool.Reference archive", "##toolbar", archiveClosed)

    proc bCorrelated(f: FrameInfo): bool {.closure.} = f.correlated("b-raw.sgy")
    clickStep("correlate again", "plot.correlate", "plot", bCorrelated)

    proc makeProject(f: FrameInfo) {.closure.} =
      doAssert f.core.correlateOn and f.correlated("b-raw.sgy")
      f.apply Command(kind: ckNewProject, projectPath: proj, projectName: "corr",
        dataFolders: @[folder])
    proc projectOpen(f: FrameInfo): bool {.closure.} = f.core.project.dir.len > 0
    step("new project", makeProject, projectOpen)

    var flushed = false
    proc doFlush(f: FrameInfo) {.closure.} =
      f.flush()
      flushed = true
    proc filesOk(f: FrameInfo): bool {.closure.} =
      if not flushed: return false
      var hits: seq[string] = @[]
      var sawRaw = false
      for dir in [f.core.project.dir, config]:
        if dir.len == 0 or not dirExists(dir): continue
        for p in walkDirRec(dir):
          if not p.fileExists: continue
          let text = readFile(p)
          if correlatedPath(rawA) in text or correlatedPath(rawB) in text: hits.add p
          elif rawA in text or rawB in text: sawRaw = true
      doAssert hits.len == 0, "saved the virtual key: " & hits.join(", ")
      doAssert sawRaw, "no saved file names the raw path"
      true
    step("flush and search", doFlush, filesOk)

    setFsHook(note)
    proc onFrame(f: FrameInfo) =
      f.keepInMainWindow()
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        (wait, since) = (0, getMonoTime())
      else:
        inc wait
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 120, since):
          failed = steps[at].name & " did not happen: " & f.status
          for e in f.core.log:
            if e.source == "correlate" or e.severity != sevInfo: echo "  log: ", e.text
          f.stop()
    let code = run(RunOptions(persist: true, configDir: some(config),
      logDir: some(fx.dir / "logs"), indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "themes"), theme: forceDark, windowSize: (1920, 1080),
      onFrame: onFrame))
    setFsHook(nil)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    doAssert fsHits > 0, "the file-system hook saw no call"
    doAssert fsSeen.len == 0, "fs saw the virtual key: " & fsSeen.join("; ")
    doAssert fileExists(shots / "correlate-off.png") and fileExists(shots / "correlate-on.png")
    echo "tguicorrelate: ", steps.len, " steps"

when isMainModule: main()
