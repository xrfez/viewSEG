## The plot's right-click menu marks an auxiliary trace for correlation, headless, on a
## synthetic record of three auxiliary traces and no seismic one.
##
## The Correlate button's refusal says what to do. Right-clicking the middle trace opens
## "Correlate auxiliary trace 2" with the line "Not marked: ..."; "In this file" marks the
## position (it is then in the file's edits) and the record is correlated; Shift... takes
## 500 through its popover (a value past the limit is refused in the core's words). With a
## project open, "In the project (every file)" marks the position there too; "In this file"
## unticked then writes an explicit "no" for the file. Undo takes the marks back one by one.
## `VIEWSEG_SCREENSHOTS=<dir>` saves auxmenu-open.png and auxmenu-correlated.png there.
##
## Seen to fail: with the group drawn for seismic traces only, "no group on the auxiliary
## trace"; with "In this file" sending "forget" in place of "no" over a project mark, the
## file entry was missing; with the shift popover sending the project command for a file
## mark, the file kept 0.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import processSEG
import viewSEG/core/[edits, geometry, state]
import viewSEG/ui/imgui/[app, auxmarkmenu]
import utils/[fixtures, waiting]

const
  DtMs = 2.0
  Record = 600
  SweepLen = 100
  Unmarked = "Not marked: this trace is cut to the listen time, not correlated"
  Hint = "Right-click an auxiliary trace and mark it for correlation."

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc writeAux(path: string; sweep: openArray[float32]) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
    measurementSystem: 1, text: @["C01 auxiliary menu test"]))
  for i in 0 .. 2:
    var buf = newSeq[float32](Record)
    for j in 0 ..< sweep.len: buf[j + 10 * i] = sweep[j]
    var k = initTraceKeys()
    k.traceCode = if i == 0: 5'i16 else: 6'i16
    k.status = tsAuxiliary
    k.record = 7.0
    k.ensemble = 10.0 + float64(i)
    k.channel = float64(i + 1)
    k.intervalUs = DtMs * 1000.0
    k.t0Ms = 0.0
    k.time = 1_700_000_000.0
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the file did not close"

proc main*() =
  withFixtures fx:
    let folder = fx.dir / "data"
    let config = fx.dir / "config"
    createDir(folder)
    createDir(config)
    let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
    let path = folder / "aux-only.sgy"
    writeAux(path, sweep)
    var stage = 0
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var pos = 0 # the auxiliary position the menu showed
    var shotOpen, shotDone = false
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    template mainPanel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc click(f: FrameInfo; q: Vec2; button = 1) =
      f.moveMouse(q)
      f.pressMouse(q, true, button)
      f.pressMouse(q, false, button)
    proc entry(f: FrameInfo): tuple[has: bool; entry: AuxMarkEntry] =
      for e in f.core.editsAt(path).auxMarks:
        if e.position == pos: return (true, e)
      (false, AuxMarkEntry(position: pos))
    proc has(f: FrameInfo; prefix: string): bool =
      f.markNames(prefix).len > 0
    proc said(f: FrameInfo; part: string): bool =
      for e in f.core.log:
        if part in e.text: return true
    proc seen(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0
    proc onFrame(f: FrameInfo) =
      inc wait
      template next() = (stage, wait, since) = (stage + 1, 0, getMonoTime())
      template menuClick(mark: string) =
        # the menu closes after a click on an item; a click every few frames until it has
        if wait mod 6 == 3: f.click(f.markOf(mark).centre)
      let plot = f.markOf("plot.data")
      case stage
      of 0: # open, store a sweep, choose it, ask to correlate
        if wait == 1 and shots.len > 0: f.keepInMainWindow
        if wait > 10 and f.mainPanel.laidOut and plot.size.x > 0 and f.core.referencesLoaded:
          f.apply Command(kind: ckStoreReference, refStore: StoredReference(
            name: "sweep", trace: f.core.sessions[0].base, fromMs: 0,
            toMs: float64(SweepLen - 1) * DtMs))
          next()
      of 1:
        if f.core.references.entries.len == 1:
          f.apply Command(kind: ckSelectReference, refId: f.core.references.entries[0].id)
          f.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
          next()
      of 2: # refused, with what to do
        if f.said("no auxiliary trace is marked for correlation"): next()
        elif wait > 300: failed = "no refusal said"
      of 3: # right-click the middle trace
        if f.has("plot.menu.aux "): next()
        elif wait mod 10 == 2: f.click(plot.centre, 3)
        if f.has("plot.menu.aux "):
          pos = parseInt(f.markNames("plot.menu.aux ")[0].split(' ')[^1])
          let hover = f.core.selection.hover
          let local = hover - f.core.sessions[0].base
          if hover < 0 or pos != local + 1:
            failed = "the menu says trace " & $pos & " over trace " & $(local + 1)
      of 4: # open the group
        if f.seen("plot.menu.aux.file"):
          if not f.has("plot.menu.aux.state " & Unmarked):
            failed = "the line says " & $f.markNames("plot.menu.aux.state")
          if shots.len > 0 and not shotOpen and wait > 8:
            createDir(shots)
            discard f.savePng(shots / "auxmenu-open.png")
            shotOpen = true
          if shots.len == 0 or shotOpen: next()
        elif wait mod 6 == 3: f.click(f.markOf("plot.menu.aux").centre)
      of 5: # mark it in this file
        if f.entry.has: next()
        else: menuClick("plot.menu.aux.file")
      of 6:
        if not (f.entry.entry.marked and f.entry.entry.ms == 0.0):
          failed = "the file's mark is " & $f.entry
        elif wait == 2 and not f.core.correlateOn:
          # the refusal turned the button off: press it again, as a user would
          f.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
        elif f.mainPanel.laidOut and f.core.sessions.len > 1 and f.core.correlateOn:
          # correlated: the derived view is shown
          var derived = false
          for s in f.core.sessions:
            if s.derived: derived = true
          if derived and not f.core.correlating: next()
        elif wait > 600: failed = "the marked file was not correlated"
      of 7: # the shift: open the popover, refuse a huge value, take 500
        if f.seen("plot.auxshift field"): next()
        elif f.seen("plot.menu.aux.shift"): menuClick("plot.menu.aux.shift")
        elif f.has("plot.menu.aux "):
          if wait mod 6 == 3: f.click(f.markOf("plot.menu.aux").centre)
        elif wait mod 10 == 2: f.click(plot.centre, 3)
      of 8:
        let box = f.markOf("plot.auxshift field")
        if not f.typing:
          if wait mod 8 == 3: f.click(box.centre)
        elif f.has("plot.auxshift typed 700000"):
          if not f.has("plot.auxshift refused a shift of 700000"):
            failed = "a shift of 700000 ms was not refused: " & $f.markNames("plot.auxshift")
          else:
            f.pressKey(skEnter, true) # Enter on a refused value sends nothing
            f.pressKey(skEnter, false)
            next()
        elif wait mod 8 == 5: f.typeText("700000")
        if wait > 300: failed = "the popover did not take the keyboard"
      of 9: # click the field again (it selects its text), then type 500 over it
        if f.entry.entry.ms != 0.0: failed = "a refused shift was kept: " & $f.entry
        elif f.has("plot.auxshift typed 500"): next()
        elif not f.typing:
          if wait mod 8 == 3: f.click(f.markOf("plot.auxshift field").centre)
        elif f.has("plot.auxshift typed 700000") and wait mod 6 == 1: f.typeText("500")
      of 10:
        if wait mod 6 == 1:
          f.pressKey(skEnter, true)
          f.pressKey(skEnter, false)
        if f.entry.has and f.entry.entry.ms == 500.0:
          if shots.len > 0 and not shotDone:
            if wait mod 20 == 0: # the corrected view needs a moment
              createDir(shots)
              discard f.savePng(shots / "auxmenu-correlated.png")
              shotDone = true
          else: next()
        elif wait > 300: failed = "the shift is " & $f.entry
      of 11: # the project: ticks the position there with the shift in force
        if wait == 1:
          f.apply Command(kind: ckNewProject, projectPath: fx.dir / "job",
            dataFolders: @[folder])
        if f.core.inProject and not f.core.project.readOnly: next()
        elif wait > 600: failed = "the project did not open"
      of 12:
        if f.has("plot.menu.aux "):
          if f.seen("plot.menu.aux.project"): next()
          elif f.seen("plot.menu.aux.file"): discard
          elif wait mod 6 == 3: f.click(f.markOf("plot.menu.aux").centre)
        elif wait mod 10 == 2: f.click(plot.centre, 3)
      of 13:
        var inProject = false
        for e in f.core.projectAuxMarks:
          if e.position == pos and e.marked and e.ms == 500.0: inProject = true
        if inProject: next()
        else: menuClick("plot.menu.aux.project")
      of 14: # untick in the file: the project marks it, so the file writes "no"
        if f.has("plot.menu.aux "):
          if f.seen("plot.menu.aux.file"):
            let e = f.entry
            if e.has and not e.entry.marked: next()
            else: menuClick("plot.menu.aux.file")
          elif wait mod 6 == 3: f.click(f.markOf("plot.menu.aux").centre)
        elif wait mod 10 == 2: f.click(plot.centre, 3)
      of 15: # Undo takes the "no" back, then the shift, then the first mark
        f.apply Command(kind: ckUndoEdit, panel: MainPanel)
        next()
      of 16:
        if not (f.entry.has and f.entry.entry.marked and f.entry.entry.ms == 500.0):
          failed = "undo of the no left " & $f.entry
        else:
          f.apply Command(kind: ckUndoEdit, panel: MainPanel)
          f.apply Command(kind: ckUndoEdit, panel: MainPanel)
          next()
      of 17:
        if f.entry.has: failed = "undo did not take the first mark back: " & $f.entry
        else: next()
      else:
        f.stop()
      if failed.len > 0 or overdue(f.index, 6000, since):
        if failed.len == 0: failed = "timed out in stage " & $stage
        f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
      theme: forceDark, persist: true, configDir: some(config),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert withAuxHint("the file has no seismic traces and no auxiliary trace is marked " &
      "for correlation.").endsWith(Hint), "the status line gives no hint"
    doAssert withAuxHint("another note") == "another note"
    echo "tguiauxmenu: ok"

when isMainModule:
  main()
