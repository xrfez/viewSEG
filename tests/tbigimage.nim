## An image view of a long f-k or spectrogram is drawn cut down to the plot's
## pixels, not cell by cell:
##
## - `reduceImage` of a 512 x 15001 image (an f-k of 256 traces over 60 s)
##   gives at most `MaxDrawnCells` cells, and no more than the plot's pixels
##   along each axis; each is the largest value of the cells it stands for (a
##   single bright cell is never lost), the bounds stay those of the image
##   and the rows run from the highest y down;
## - zoomed in to a few cells, every cell is drawn;
## - the work is a pass over the cells in view, in time that does not grow
##   per frame (the UI keeps the result while the view is the same);
## - in the running frontend (headless), an f-k of 64 traces of 16000
##   samples draws no more than `MaxDrawnCells` cells and its frames stay
##   short, and its cursor still reads a cell of the whole image.
##
## Seen to fail: with the reduction's bins fixed at one cell (`fx`, `fy` always
## 1, no cap), "512 x 15001" for the cells of a 512 x 15001 image.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, monotimes, options, os, times]
import viewSEG/core/[analysis, state]
import viewSEG/ui/imgui/app
import viewSEG/ui/imgui/plotwindows
import viewSEG/view/analysisview
import utils/fixtures

const
  Cols = 512
  Rows = 15001

proc main*() =

  block reduction:
    var img = AnalysisImage(cols: Cols, rows: Rows, x0: -256, dx: 1, y0: 0, dy: 0.0333,
      lo: -60, hi: 0, xUnit: "/km", yUnit: "Hz")
    img.values = newSeq[float32](Cols * Rows)
    for i in 0 ..< img.values.len: img.values[i] = -60
    # one bright cell, alone
    img.values[300 * Rows + 12345] = 0
    let t0 = getMonoTime()
    let r = img.reduceImage(img.x0 - 0.5, img.xOf(Cols - 1) + 0.5, -0.02, img.yOf(Rows - 1) + 0.02,
      1000, 600)
    let ms = float64((getMonoTime() - t0).inNanoseconds) / 1e6
    doAssert r.cols * r.rows <= MaxDrawnCells, $(r.cols * r.rows) & " cells for a " & $Cols &
      " x " & $Rows & " image"
    doAssert r.cols <= 1000 and r.rows <= 600 and r.cols >= 500 and r.rows >= 300,
      $r.cols & " x " & $r.rows
    doAssert r.values.len == r.cols * r.rows
    var peak = -1000'f32
    var at = 0
    for i, v in r.values:
      if v > peak: (peak, at) = (v, i)
    doAssert peak == 0, "the bright cell was lost: " & $peak
    # where it is: row 12345 is at y = 411.5 Hz; the top row is the highest y
    let (row, col) = (at div r.cols, at mod r.cols)
    let y = r.yMax - (float64(row) + 0.5) * (r.yMax - r.yMin) / float64(r.rows)
    let x = r.xMin + (float64(col) + 0.5) * (r.xMax - r.xMin) / float64(r.cols)
    doAssert abs(y - img.yOf(12345)) <= float64(r.binRows) * img.dy, $y & " Hz, want " &
      $img.yOf(12345)
    doAssert abs(x - img.xOf(300)) <= float64(r.binCols) * img.dx, $x
    doAssert r.xMin <= img.x0 and r.yMin <= img.y0 and r.xMax >= img.xOf(Cols - 1) and
      r.yMax >= img.yOf(Rows - 1), "the bounds do not cover the image"
    # zoomed in to 20 x 40 cells: all of them
    let z = img.reduceImage(img.xOf(100), img.xOf(119), img.yOf(5000), img.yOf(5039), 1000, 600)
    doAssert z.binCols == 1 and z.binRows == 1 and z.cols * z.rows <= 22 * 42 and
      z.cols * z.rows >= 20 * 40, $z.cols & " x " & $z.rows
    doAssert ms < 2000, "one pass over " & $(Cols * Rows) & " cells took " & $ms & " ms"

  withFixtures fx:
    var frames: seq[float64] = @[]
    var last = getMonoTime()
    var drawn = 0
    var phase = 0
    var waited = 0
    var failed = ""
    proc onFrame(f: FrameInfo) =
      let now = getMonoTime()
      let ms = float64((now - last).inNanoseconds) / 1e6
      last = now
      case phase
      of 0:
        if f.core.panels.len > 0 and f.core.sessions.len > 0 and
            f.core.panel(MainPanel).laidOut:
          var all: seq[int] = @[]
          for i in 0 ..< 64: all.add f.core.sessions[0].base + i
          f.apply(Command(kind: ckOpenPlot, plotView: avFk, plotTraces: all))
          phase = 1
      of 1:
        if f.core.plots.len == 1 and not f.core.plots[0].waiting and
            f.markOf("new plot 1.image").size.x > 0:
          if f.core.plots[0].result.problem.len > 0: failed = f.core.plots[0].result.problem
          phase = 2
        else:
          inc waited
          if waited > 3000: failed = "no f-k"
      of 2:
        # the first frames draw it; then a run of steady ones
        frames.add ms
        inc waited
        drawn = f.plotWindows.cellsDrawn(1)
        if frames.len >= 40: phase = 3
      else: discard
      if phase == 3 or failed.len > 0: f.stop()
    let code = run(RunOptions(openPaths: @[fx.longTraceSegy(16000, 64)],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0 and failed.len == 0, failed
    doAssert drawn in 1 .. MaxDrawnCells, $drawn & " cells drawn"
    frames.sort()
    doAssert frames[frames.len div 2] < 300, "median frame " & $frames[frames.len div 2] & " ms"
    doAssert frames[^2] < 1500, "a frame of " & $frames[^2] & " ms"
  echo "tbigimage: ok"

when isMainModule:
  main()
