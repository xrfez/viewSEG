## New plot windows in the running frontend, on samples/land/shots.sgy, then
## samples/vib/vib_uncorrelated.sgd in the same plot.
##
## Spectrogram, envelope and phase, then an FFT window and the Spectrum panel:
## a selection change is followed; Freeze keeps one on its traces; opening
## another file leaves the frozen one and moves the others; unfreezing
## follows; closing the file leaves a frozen window's numbers. The Headers
## window has no Freeze pin: its Trace tab follows the selection, and a new
## file.
##
## Seen to fail: with the windows locked to the traces that opened them,
## "an unfrozen window did not follow the selection". A freeze click that
## presses a point taken a few frames earlier, or while another window is
## under the pointer, leaves "fft and spectrum frozen" unmet.
##
## Break to see it fail: in `followPlots`, skip the repick. In `clickFreeze`,
## press on the first frame at that captured point, without waiting until the
## pointer is inside the live button and that window is the one under it.
##
## Needs a display: run under the tester (it gives each test its own).

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/headerviews
import imguin/cimgui
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool
  Hit = object
    mark, winId: string
    index: int
    down, up: bool
    pressAt, releaseAt: Vec2
    pressHover, releaseHover, pressWin, releaseWin: string
    pressActive, releaseActive: uint32
    pressFrame, releaseFrame: int
    buttonPress, buttonRelease: Rect

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc main*() =
  let land = root / "samples" / "land" / "shots.sgy"
  let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"
  let obn = root / "samples" / "obn" / "obn.sgd"

  doAssert fileExists(land) and fileExists(vib) and fileExists(obn)

  withFixtures fx:
    var steps: seq[Step] = @[]
    var pointAt: Vec2
    var frozenTraces: seq[int] = @[]
    var frozenFile = ""
    var hits: array[2, Hit]
    var seenApplies: array[2, int]
    var cmdFrame, cmdAgain: array[2, int]
    var watchFreeze = false
    hits[0] = Hit(mark: "spectrum.freeze", winId: "spectrum", index: 0,
      pressAt: vec2(NaN, NaN), releaseAt: vec2(NaN, NaN), pressFrame: -1, releaseFrame: -1)
    hits[1] = Hit(mark: "fft 1.freeze", winId: "fft-1", index: 1,
      pressAt: vec2(NaN, NaN), releaseAt: vec2(NaN, NaN), pressFrame: -1, releaseFrame: -1)
    cmdFrame = [-1, -1]
    cmdAgain = [-1, -1]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc after(n: int): proc (f: FrameInfo): bool =
      var frames = 0
      result = proc (f: FrameInfo): bool =
        inc frames
        frames >= n
    proc to(mark: string) =
      step("to " & mark, proc (f: FrameInfo) =
        let r = f.markOf(mark)
        doAssert r.size.x > 0, mark & " is not shown"
        pointAt = r.centre
        f.moveMouse(pointAt), after(3))
    proc click(mark: string) =
      ## Press on one frame, release on a later one: both in one frame can
      ## cancel, and the click never lands.
      to(mark)
      step("click " & mark, proc (f: FrameInfo) =
        f.pressMouse(pointAt, true, 1), proc (f: FrameInfo): bool =
        f.pressMouse(pointAt, false, 1)
        true)
    proc pointerFb(): Vec2 =
      let m = igGetMousePos()
      let s = igGetIO_Nil().DisplayFramebufferScale
      let o = igGetMainViewport().Pos
      vec2((m.x - o.x) * s.x, (m.y - o.y) * s.y)
    proc hoveredWindow(): string =
      ## ImGui's own hover query. The context field reads as garbage from this
      ## binding, so the name comes from the function ImGui uses.
      var w: ptr ImGuiWindow = nil
      var under: ptr ImGuiWindow = nil
      igFindHoveredWindowEx(igGetMousePos(), false, addr w, addr under)
      if w.isNil: "none" else: $w.Name
    func yn(b: bool): string = (if b: "yes" else: "no")
    proc px(x: float32): string =
      if x.isNaN or abs(x) > 1e6: "off" else: $int(round(x))
    proc box(r: Rect): string =
      px(r.pos.x) & "," & px(r.pos.y) & " " & px(r.size.x) & "x" & px(r.size.y)
    proc jobYes(f: FrameInfo; index: int): string =
      let waiting = f.core.spectra.len > index and f.core.spectra[index].waiting
      var titles: seq[string]
      for j in f.core.jobs.active: titles.add j.spec.title
      if not waiting and titles.len == 0: "no"
      elif titles.len == 0: "yes waiting"
      elif waiting: "yes waiting " & titles.join(", ")
      else: "yes " & titles.join(", ")
    proc noteHit(f: FrameInfo; index: int; press: bool) =
      let at = pointerFb()
      let hover = hoveredWindow()
      let active = uint32(igGetActiveID())
      let button = f.markOf(hits[index].mark)
      if press:
        hits[index].pressAt = at
        hits[index].pressHover = hover
        hits[index].pressWin = f.windowName(hits[index].winId)
        hits[index].pressActive = active
        hits[index].pressFrame = f.index
        hits[index].buttonPress = button
      else:
        hits[index].releaseAt = at
        hits[index].releaseHover = hover
        hits[index].releaseWin = f.windowName(hits[index].winId)
        hits[index].releaseActive = active
        hits[index].releaseFrame = f.index
        hits[index].buttonRelease = button
    proc inFront(f: FrameInfo; index: int): bool =
      ## The window under the pointer is this plot's, so the click cannot
      ## land on whatever is covering it.
      let name = f.windowName(hits[index].winId)
      name.len > 0 and hoveredWindow() == name
    proc noteApplies(f: FrameInfo) =
      if f.core.spectra.len < 2: return
      for i in 0..1:
        let n = f.core.spectra[i].freezeApplies
        if n == seenApplies[i]: continue
        if cmdFrame[i] < 0: cmdFrame[i] = f.index
        elif cmdAgain[i] < 0: cmdAgain[i] = f.index
        seenApplies[i] = n
    proc plotLine(f: FrameInfo; index: int): string =
      let have = f.core.spectra.len > index
      let place = f.windowPlace(hits[index].winId)
      let h = hits[index]
      let data = have and f.core.spectra[index].spectrum.raw.len > 0
      let frozen = have and f.core.spectra[index].frozen
      let applies = if have: f.core.spectra[index].freezeApplies else: -1
      var again = ""
      if cmdAgain[index] >= 0: again = " cmd2=" & $cmdAgain[index]
      h.mark & " data=" & yn(data) & " job=" & f.jobYes(index) & " frozen=" & $frozen &
        " win=" & box(place.rect) & " visible=" & yn(place.inSight) & " docked=" &
        yn(place.docked) & " apart=" & yn(place.apart) & " button=" & box(f.markOf(h.mark)) &
        " press=" & px(h.pressAt.x) & "," & px(h.pressAt.y) & " f=" & $h.pressFrame &
        " buttonAt=" & box(h.buttonPress) & " hover=" & h.pressHover & " win=" & h.pressWin &
        " active=" & $h.pressActive & " release=" & px(h.releaseAt.x) & "," & px(h.releaseAt.y) &
        " f=" & $h.releaseFrame & " buttonAt=" & box(h.buttonRelease) & " hover=" &
        h.releaseHover & " win=" & h.releaseWin & " active=" & $h.releaseActive &
        " applies=" & $applies & " cmd=" & $cmdFrame[index] & again & " now=" &
        px(pointerFb().x) & "," & px(pointerFb().y) & " hover=" & hoveredWindow() &
        " name=" & f.windowName(h.winId)
    proc freezeReport(f: FrameInfo): string =
      f.plotLine(1) & "; " & f.plotLine(0)
    proc clickFreeze(index: int) =
      ## Press once this frame's pointer is inside the live button and that
      ## window is the one under it; release once that press has been seen.
      ## A point taken a few frames ago misses once the dock has moved, and a
      ## covered button is not the one this step means to click. One press.
      let mark = hits[index].mark
      proc begin(f: FrameInfo) =
        watchFreeze = true
        hits[index].down = false
        hits[index].up = false
        hits[index].pressFrame = -1
        hits[index].releaseFrame = -1
        hits[index].pressAt = vec2(NaN, NaN)
        hits[index].releaseAt = vec2(NaN, NaN)
        let r = f.markOf(mark)
        if r.size.x > 0:
          pointAt = r.centre
          f.moveMouse(pointAt)
      proc landed(f: FrameInfo): bool =
        let live = f.markOf(mark)
        let have = f.core.spectra.len > index and f.core.spectra[index].spectrum.raw.len > 0
        if not hits[index].down:
          if live.size.x > 0:
            pointAt = live.centre
            if not live.contains(pointerFb()): f.moveMouse(pointAt)
          if have and live.size.x > 0 and live.contains(pointerFb()) and f.inFront(index):
            f.pressMouse(pointAt, true, 1)
            hits[index].down = true
        elif not hits[index].up and igIsMouseDown_Nil(ImGui_MouseButton_Left.cint):
          if live.size.x > 0: pointAt = live.centre
          f.noteHit(index, true)
          f.pressMouse(pointAt, false, 1)
          hits[index].up = true
        elif hits[index].up and not igIsMouseDown_Nil(ImGui_MouseButton_Left.cint):
          f.noteHit(index, false)
          return true
        false
      step("click " & mark, begin, landed)

    step("shots.sgy", noop, proc (f: FrameInfo): bool =
      f.answered and f.core.sessions.len == 1 and f.core.sessions[0].name == "shots.sgy")
    step("two selected", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckSelect, traces: @[b, b + 1], mode: smReplace)),
      proc (f: FrameInfo): bool = f.core.selection.selectedCount == 2)
    step("three plots", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenPlot, plotView: avSpectrogram))
      f.apply(Command(kind: ckOpenPlot, plotView: avEnvelope))
      f.apply(Command(kind: ckOpenPlot, plotView: avPhase)),
      proc (f: FrameInfo): bool =
        result = f.core.plots.len == 3 and not f.core.plots[0].waiting and
          not f.core.plots[1].waiting and not f.core.plots[2].waiting
        if result:
          let b = f.core.sessions[0].base
          doAssert f.core.plots[0].traces == @[b, b + 1]
          doAssert f.core.plots[1].traces == @[b] and f.core.plots[2].traces == @[b])
    step("selection of three", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckSelect, traces: @[b + 4, b + 5, b + 6], mode: smReplace)),
      proc (f: FrameInfo): bool =
        let b = f.core.sessions[0].base
        doAssert f.core.plots[0].traces == @[b + 4, b + 5, b + 6],
          "an unfrozen window did not follow the selection: " & $f.core.plots[0].traces
        doAssert f.core.plots[1].traces == @[b + 4] and f.core.plots[2].traces == @[b + 4]
        true)
    click("new plot 3.freeze")
    step("phase frozen", noop, proc (f: FrameInfo): bool =
      result = f.core.plots[2].frozen
      if result:
        frozenTraces = f.core.plots[2].traces
        frozenFile = f.core.plots[2].file)
    step("selection while frozen", proc (f: FrameInfo) =
      let b = f.core.sessions[0].base
      f.apply(Command(kind: ckSelect, traces: @[b + 8, b + 9], mode: smReplace)),
      proc (f: FrameInfo): bool =
        let b = f.core.sessions[0].base
        doAssert f.core.plots[2].traces == frozenTraces and f.core.plots[2].file == frozenFile,
          "a frozen window followed the selection"
        doAssert f.core.plots[0].traces == @[b + 8, b + 9],
          "an unfrozen window did not follow: " & $f.core.plots[0].traces
        true)
    step("open the vib file", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: vib)),
      proc (f: FrameInfo): bool =
        let k = f.core.findPanel(MainPanel)
        let i = f.core.shownFile(k)
        result = i >= 0 and f.core.sessions[i].path == vib and f.answered
        if result:
          doAssert f.core.plots[2].traces == frozenTraces and f.core.plots[2].file == frozenFile,
            "a frozen window followed the new file: " & f.core.plots[2].file
          doAssert "vib_uncorrelated.sgd" in f.core.plots[0].file,
            "an unfrozen window did not follow the new file: " & f.core.plots[0].file
          doAssert "vib_uncorrelated.sgd" in f.core.plots[1].file, f.core.plots[1].file)
    click("new plot 3.freeze")
    step("unfrozen, it follows", noop, proc (f: FrameInfo): bool =
      result = not f.core.plots[2].frozen and "vib_uncorrelated.sgd" in f.core.plots[2].file and
        f.core.plots[2].traces != frozenTraces)
    step("FFT of the plot", proc (f: FrameInfo) =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      let b = f.core.sessions[i].base
      f.apply(Command(kind: ckSpectrum, spectrumTraces: @[b])),
      proc (f: FrameInfo): bool =
        f.core.spectra.len == 2 and not f.core.spectra[1].waiting and
          f.markOf("fft 1.freeze").size.x > 0)
    click("menu.View")
    click("menu.window.spectrum")
    step("spectrum on screen", noop, proc (f: FrameInfo): bool =
      f.core.spectra[0].shown and f.markOf("spectrum.freeze").size.x > 0 and
        f.markOf("headers").size.x > 0 and f.markOf("headers.freeze").size.x == 0)
    step("select two on the vib file", proc (f: FrameInfo) =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      let b = f.core.sessions[i].base
      f.apply(Command(kind: ckSelect, traces: @[b + 2, b + 3], mode: smReplace)),
      proc (f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        let b = f.core.sessions[i].base
        result = not f.core.spectra[1].waiting and not f.core.spectra[0].waiting and
          not f.core.plots[0].waiting
        if result:
          doAssert f.core.spectra[1].traces == @[b + 2, b + 3],
            "the FFT window did not follow: " & $f.core.spectra[1].traces
          doAssert f.core.spectra[0].traces == @[b + 2, b + 3],
            "the Spectrum panel did not follow: " & $f.core.spectra[0].traces
          doAssert f.core.plots[0].traces == @[b + 2, b + 3]
          doAssert "vib_uncorrelated.sgd" in chosenLine(f.core, true),
            chosenLine(f.core, true))
    clickFreeze(1)
    clickFreeze(0)
    step("fft and spectrum frozen", noop, proc (f: FrameInfo): bool =
      result = f.core.spectra[1].frozen and f.core.spectra[0].frozen
      if result:
        frozenTraces = f.core.spectra[1].traces
        frozenFile = f.core.spectra[1].file)
    step("open obn", proc (f: FrameInfo) =
      f.apply(Command(kind: ckShowFile, panel: MainPanel, path: obn)),
      proc (f: FrameInfo): bool =
        let i = f.core.shownFile(f.core.findPanel(MainPanel))
        result = i >= 0 and f.core.sessions[i].path == obn and f.answered and
          not f.core.plots[0].waiting
        if result:
          doAssert f.core.spectra[1].traces == frozenTraces and f.core.spectra[1].file ==
              frozenFile,
            "a frozen FFT window followed the new file"
          doAssert f.core.spectra[0].frozen and f.core.spectra[0].file == frozenFile,
            "a frozen Spectrum panel followed the new file"
          doAssert "obn.sgd" in f.core.plots[0].file, f.core.plots[0].file
          # the selection is still the vib traces: the frozen windows keep that
          # file open, and Headers follows the selection, not the file on show
          doAssert "vib_uncorrelated.sgd" in chosenLine(f.core, true), chosenLine(f.core, true))
    clickFreeze(1)
    step("fft unfrozen follows obn", noop, proc (f: FrameInfo): bool =
      result = not f.core.spectra[1].frozen and not f.core.spectra[1].waiting and
        "obn.sgd" in f.core.spectra[1].file and f.core.spectra[1].traces != frozenTraces)
    clickFreeze(0)
    step("spectrum unfrozen follows obn", noop, proc (f: FrameInfo): bool =
      result = not f.core.spectra[0].frozen and not f.core.spectra[0].waiting and
        "obn.sgd" in f.core.spectra[0].file)
    step("select on obn, headers follow", proc (f: FrameInfo) =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      let b = f.core.sessions[i].base
      f.apply(Command(kind: ckSelect, traces: @[b], mode: smReplace)),
      proc (f: FrameInfo): bool =
        "obn.sgd" in chosenLine(f.core, true))
    clickFreeze(1)
    step("fft frozen again", noop, proc (f: FrameInfo): bool =
      result = f.core.spectra[1].frozen and f.core.spectra[1].spectrum.raw.len > 0
      if result:
        frozenTraces = f.core.spectra[1].traces
        frozenFile = f.core.spectra[1].file)
    step("close the file", proc (f: FrameInfo) =
      let i = f.core.shownFile(f.core.findPanel(MainPanel))
      f.apply(Command(kind: ckClose, file: f.core.sessions[i].id)),
      proc (f: FrameInfo): bool =
        result = f.core.shownFile(f.core.findPanel(MainPanel)) < 0
        if result:
          doAssert f.core.spectra[1].frozen and f.core.spectra[1].traces == frozenTraces and
            f.core.spectra[1].file == frozenFile and f.core.spectra[1].spectrum.raw.len > 0,
            "closing the file dropped the frozen FFT window"
          doAssert not f.core.spectra[1].waiting)

    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if watchFreeze: f.noteApplies()
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
        elif overdue(wait, 900, since):
          failed = steps[at].name & " did not happen"
          if steps[at].name == "fft and spectrum frozen" or
              steps[at].name == "click fft 1.freeze" or
              steps[at].name == "click spectrum.freeze":
            failed.add "; " & f.freezeReport()
          f.stop()
    let code = run(RunOptions(openPaths: @[land], windowSize: (1600, 1000), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

when isMainModule:
  main()
