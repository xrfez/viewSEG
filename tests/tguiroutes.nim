## Every way of showing another file keeps the plot as the user left it,
## headless, in the running frontend: zoomed in (8 traces from the third, 100
## to 300 ms), wiggles over density with an overlap of 1.5, the Exponential
## gain as the power of time 1.5 until 3 000 ms at +7.5 dB with every other
## gain type's settings away from their defaults, sorted by channel
## (descending), Aux on beside Seismic, and filtered (the mean and trend
## taken off, a 3-6-50-70 Hz band-pass, a 50 Hz notch and its harmonic, the
## Aux traces too). Then, one after another: a click on a row of the Files window; Down in it; File > Open file in the same
## folder and in another; File > Open folder; File > Open recent; a file
## dropped on the window; "Follow the latest" showing a file copied into the
## folder; a click on a message naming a trace of another file; and the file
## shown written over by another program (cut short, then whole again).
## After each the plot shows the file it was sent to with the same first
## trace and time, the same scales (traces and ms per inch: the same spans on
## the same plot), the same sort, display mode, gain type with every
## parameter and gain amount, the same Seismic and Aux toggles and the same
## filters, in `core` and in what the window draws (its reader filtered
## every trace of the tile).
##
## Seen to fail: with `closeSession(keepLayers = true)` dropping the layers
## (as a close does), "changed on disk: the view is ..." (the file opened
## again was fitted, in a layer made afresh: Aux off); with `show` making a
## new layer for every file, "click in Files: Aux is off" at the first route;
## with the reader asked for no filters, "click in Files: 0 of 23 traces
## filtered".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, times]
import viewSEG/core/[geometry, log]
import viewSEG/core/state {.all.}
import viewSEG/ui/imgui/[app, shell]
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool
    patience: int ## frames, and `Patience` at least

  Kept = object
    traces, timeMs: Span
    columns, rows: int
    display: DisplaySettings
    order: seq[SortKey]
    filter: TraceFilter
    processing: Processing

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc shownPath(f: FrameInfo): string =
  let i = f.core.shownFile(f.core.findPanel(MainPanel))
  if i >= 0: f.core.sessions[i].path else: ""

proc kept(f: FrameInfo): Kept =
  let p = f.panel
  Kept(traces: p.view.traces, timeMs: p.view.timeMs, columns: p.view.columns,
    rows: p.view.rows, display: p.layers[0].display, order: p.layers[0].order,
    filter: p.layers[0].filter, processing: p.layers[0].processing)

withFixtures fx:
  let a = fx.dir / "line 7"
  let b = fx.dir / "line 8"
  createDir(a)
  createDir(b)
  copyFile(fx.threeComponentSegd(), a / "Shot1.sgd") # 1 auxiliary, 36 seismic traces
  copyFile(fx.twoSetSegd(), a / "shot2.sgd") # 2 auxiliary, 24 seismic
  copyFile(fx.threeComponentSegd(), a / "shot3.sgd")
  copyFile(fx.twoSetSegd(), b / "b1.sgd")
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0 # frames since the step began, at `since`
  var since = getMonoTime()
  var failed = ""
  var images, quiet = 0
  var want: Kept
  var pointAt: Vec2
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
      patience = 600) =
    steps.add Step(name: name, act: act, done: done, patience: patience)
  proc noop(f: FrameInfo) = discard
  proc after(n: int): proc (f: FrameInfo): bool =
    var frames = 0
    result = proc (f: FrameInfo): bool =
      inc frames
      frames >= n
  proc settled(f: FrameInfo): bool =
    let p = f.panel
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    p.laidOut and p.layout.traces > 0 and tiles.len > 0 and
      tiles[^1].request == p.pending and f.tracePanel.drawnView.sameSpans(p.view) and
      quiet >= 2

  proc shows(route, path: string): proc (f: FrameInfo): bool =
    ## Done once `path` is shown and drawn; then all is as it was.
    result = proc (f: FrameInfo): bool =
      result = f.shownPath == path and f.settled
      if result:
        let now = f.kept
        doAssert now.traces == want.traces and now.timeMs == want.timeMs,
          route & ": the view is " & $now.traces & ", " & $now.timeMs & ", not " &
          $want.traces & ", " & $want.timeMs
        doAssert now.columns == want.columns and now.rows == want.rows,
          route & ": the plot is " & $now.columns & " x " & $now.rows
        doAssert f.tracePanel.drawnView.traces == want.traces and
          f.tracePanel.drawnView.timeMs == want.timeMs, route & ": the window draws " &
          $f.tracePanel.drawnView
        doAssert now.filter == want.filter, route & ": Aux is " &
          (if now.filter.auxiliary: "on" else: "off") & ", Seismic " &
          (if now.filter.seismic: "on" else: "off")
        doAssert now.order == want.order, route & ": the sort is " & $now.order
        doAssert now.processing == want.processing, route & ": the filters are " &
          $now.processing & ", not " & $want.processing
        let t = f.core.tiles(f.core.findPanel(MainPanel))[^1]
        doAssert t.filtered == t.request.count, route & ": " & $t.filtered & " of " &
          $t.request.count & " traces filtered"
        doAssert now.display == want.display, route & ": the display is " & $now.display &
          ", not " & $want.display

  proc moveTo(mark: string) =
    step("to " & mark, proc (f: FrameInfo) =
      let r = f.markOf(mark)
      doAssert r.size.x > 0, mark & " is not shown"
      pointAt = r.centre
      f.moveMouse(pointAt), after(2))
  proc click(mark: string) =
    moveTo(mark)
    step("click " & mark, proc (f: FrameInfo) =
      f.pressMouse(pointAt, true)
      f.pressMouse(pointAt, false), after(4))

  # ------------------------------------------------------------ the plot --
  step("the first file", noop, proc (f: FrameInfo): bool =
    f.shownPath == a / "Shot1.sgd" and f.settled and not f.core.fileList.scanning)
  step("the user's display", proc (f: FrameInfo) =
    var d = f.panel.layers[0].display
    (d.mode, d.overlap, d.fills) = (dmWiggleDensity, 1.5, {wfPositive, wfNegative})
    (d.gain, d.timeGain, d.power, d.untilMs, d.dbPerS) = (dgExponential, tgPower, 1.5, 3000.0,
      9.0)
    (d.agcWindowMs, d.normScope, d.normStat, d.fixedClip, d.clipPercentile) = (300.0, perPanel,
      normRms, 0.5, 98.5)
    d = d.withGainDb(7.5)
    f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    f.apply Command(kind: ckSort, panel: MainPanel, order: @[SortKey(field: hfChannel,
      descending: true)])
    f.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing(aux: true,
      dc: dcTrend, band: pbBandPass, f1: 3, f2: 6, f3: 50, f4: 70,
      notches: @[NotchFilter(hz: 50, widthHz: 3, harmonics: 2)]))
    f.apply(Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: true,
      auxiliary: true))), after(3))
  step("zoomed in", proc (f: FrameInfo) =
    var v = f.panel.view
    (v.traces, v.timeMs) = (Span(lo: 2.5, hi: 10.5), Span(lo: 100, hi: 300))
    f.showView(v),
    proc (f: FrameInfo): bool =
      result = f.settled and f.panel.view.traces == Span(lo: 2.5, hi: 10.5)
      if result:
        want = f.kept
        doAssert want.filter.auxiliary and want.display.gainDb == 7.5 and
          want.processing.band == pbBandPass)

  # ------------------------------------------------------------ the routes --
  # a click on a row: the first may only bring the window forward
  click("files.row shot2.sgd")
  click("files.row shot2.sgd")
  step("click in Files", noop, shows("click in Files", a / "shot2.sgd"))
  step("Down in Files", proc (f: FrameInfo) =
    f.pressKey(skDown, true)
    f.pressKey(skDown, false), shows("Down in Files", a / "shot3.sgd"))
  step("File > Open file, the same folder", proc (f: FrameInfo) =
    postShellEvent(ShellEvent(kind: sePathsChosen, dialog: dkOpenFile,
      paths: @[a / "Shot1.sgd"])),
    shows("File > Open file, the same folder", a / "Shot1.sgd"))
  step("File > Open file, another folder", proc (f: FrameInfo) =
    postShellEvent(ShellEvent(kind: sePathsChosen, dialog: dkOpenFile, paths: @[b / "b1.sgd"])),
    shows("File > Open file, another folder", b / "b1.sgd"))
  step("File > Open folder", proc (f: FrameInfo) =
    postShellEvent(ShellEvent(kind: sePathsChosen, dialog: dkOpenFolder, paths: @[a])),
    shows("File > Open folder", a / "Shot1.sgd"))
  step("File > Open recent", proc (f: FrameInfo) =
    # what the menu's entry sends (`app.nim`)
    f.apply(Command(kind: ckShowFile, panel: MainPanel, path: b / "b1.sgd", listFolder: true)),
    shows("File > Open recent", b / "b1.sgd"))
  step("a file dropped", proc (f: FrameInfo) = f.dropPaths([a / "shot2.sgd"]),
    shows("a file dropped", a / "shot2.sgd"))
  step("Follow the latest", proc (f: FrameInfo) =
    var s = f.core.settings
    s.files.followLatest = true
    f.apply Command(kind: ckSettings, settings: s)
    copyFile(fx.twoSetSegd(), a / "shot4.sgd"),
    shows("Follow the latest", a / "shot4.sgd"),
    patience = 4000)
  step("Follow off", proc (f: FrameInfo) =
    var s = f.core.settings
    s.files.followLatest = false
    f.apply(Command(kind: ckSettings, settings: s)), after(2))
  step("a message naming a trace", proc (f: FrameInfo) =
    # errors alone shown, so that no other line (a slow frame's warning, in a
    # debug build under load) becomes the last
    var s = f.core.settings
    s.messages.hidden = {sevInfo, sevWarning}
    f.apply Command(kind: ckSettings, settings: s)
    f.core.mailbox.post(Msg(kind: mkLog, entry: LogEntry(time: getTime(), severity: sevError,
      source: "test", text: "An error about trace 5 of Shot1",
      loc: Location(file: a / "Shot1.sgd", trace: 5)))), after(4))
  click("messages.last")
  step("a click on a message", noop, proc (f: FrameInfo): bool =
    if f.shownPath != a / "Shot1.sgd" and f.markOf("messages.last").size.x > 0:
      # a click that only brought the Messages window forward: once more
      f.pressMouse(f.markOf("messages.last").centre, true)
      f.pressMouse(f.markOf("messages.last").centre, false)
    shows("a click on a message", a / "Shot1.sgd")(f))
  step("written over by another program", proc (f: FrameInfo) =
    copyFile(fx.twoSetSegd(), a / "Shot1.sgd"),
    proc (f: FrameInfo): bool =
      # let go of while it changes, then opened again once steady
      f.core.sessions.len > 0 and f.core.sessions[^1].size == getFileSize(a / "Shot1.sgd") and
        shows("changed on disk", a / "Shot1.sgd")(f), patience = 4000)

  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if f.tracePanel.imagesDrawn != images:
      images = f.tracePanel.imagesDrawn
      quiet = 0
    else: inc quiet
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
      elif overdue(wait, steps[at].patience, since):
        failed = steps[at].name & " did not happen (" & f.shownPath & " shown)"
        f.stop()

  let code = run(RunOptions(openPaths: @[a], windowSize: (1400, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguiroutes: ", steps.len, " steps"
