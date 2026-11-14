## The plot's left edge stays put, headless: on a six-second record, the view
## shown over 0 to 900 ms (time labels of three digits), 1000 to 1900 ms
## (four), 5000 to 5900 ms and the whole record, through the same view
## command a pan or a zoom sends, puts the plot's data area at the same
## place and size every time, because every time label is padded to the
## longest the record can have. And Ctrl + click on a trace selects nothing
## (docs/plot-window.md: it belongs to the mute editor), where a plain click
## on it selects it.
##
## Seen to fail: with the labels not padded (no `ImPlot_SetupAxisFormat`),
## the data area started at x = 359 over 0 to 900 ms and at x = 366 over
## 1000 to 1900 ms; with Ctrl not looked at in a click, "Ctrl + click
## selected 1 traces".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/fixtures

withFixtures fx:
  let path = fx.longRecordSegy()
  const spans = [(0.0, 900.0), (1000.0, 1900.0), (5000.0, 5900.0), (0.0, 5998.0),
    (40.0, 120.0)]
  var rects: seq[Rect]
  var stage = 0
  var wait = 0
  var q: Vec2
  var ctrlClicked, clicked = -1
  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
  proc answered(f: FrameInfo): bool =
    let p = f.panel
    let tiles = f.core.tiles(f.core.findPanel(MainPanel))
    p.laidOut and tiles.len > 0 and tiles[^1].request == p.pending and
      f.tracePanel.drawnView.sameSpans(p.view)
  proc onFrame(f: FrameInfo) =
    inc wait
    if stage < spans.len: # each view, then the data area's place
      if wait == 1 and f.panel.laidOut:
        var v = f.panel.view
        v.timeMs = Span(lo: spans[stage][0], hi: spans[stage][1])
        f.showView(v)
      if wait > 6 and f.answered and f.tracePanel.drawnView.timeMs.lo == spans[stage][0]:
        rects.add f.markOf("plot.data")
        inc stage
        wait = 0
      elif not f.panel.laidOut: wait = 0
    else:
      let k = stage - spans.len
      case k
      of 0: # the pointer over trace 10
        let p = f.markOf("plot.data")
        let v = f.panel.view.screenAt(p, DataPoint(x: 10, tMs: 80))
        q = vec2(round(v.x), round(v.y))
        f.moveMouse(q)
        (stage, wait) = (stage + 1, 0)
      of 1: # Ctrl + click, Ctrl held from the frame before
        if wait == 3: f.pressKey(skCtrl, true, {smCtrl})
        if wait == 5:
          f.pressMouse(q, true)
          f.pressMouse(q, false)
        if wait == 8: f.pressKey(skCtrl, false)
        if wait == 14:
          ctrlClicked = f.core.selection.selected.len
          (stage, wait) = (stage + 1, 0)
      of 2: # a plain click
        if wait == 3:
          f.pressMouse(q, true)
          f.pressMouse(q, false)
        if wait == 9:
          clicked = f.core.selection.selected.len
          f.stop()
      else: discard
    if f.index > 3000: f.stop()
  let code = run(RunOptions(maxFrames: 3500, openPaths: @[path], windowSize: (1400, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert rects.len == spans.len, "only " & $rects.len & " views shown"
  for i in 1 ..< rects.len:
    doAssert rects[i] == rects[0], "over " & $spans[i] & " ms the plot is at " & $rects[i] &
      ", over " & $spans[0] & " ms at " & $rects[0]
  doAssert ctrlClicked == 0, "Ctrl + click selected " & $ctrlClicked & " traces"
  doAssert clicked == 1, "a click selected " & $clicked & " traces"
  echo "tguiedge: the plot at ", rects[0], " over ", spans.len, " views"
