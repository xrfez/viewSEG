## The compare window does not throw samples away before the plot, and the
## draw keeps the peak in each bin of the range on screen.
##
## Seen to fail: 120000 samples with spikes at index 1 and 15 drawn as
## 4000 zeros (stepped down once, before the plot, so a zoom could not
## reach those samples); with the on-screen bins taking the first sample
## instead of the peak, "the spike was stepped over".

import std/[math, os, strutils]
import viewSEG/core/compare
import viewSEG/view/[compareview, curveplot, theme]

proc main*() =

  block noUpFrontCut:
    const n = 120_000
    var ys = newSeq[float64](n)
    ys[1] = 10
    ys[15] = 7
    var xs = newSeq[float64](n)
    for i in 0 ..< n: xs[i] = float64(i) * 0.5
    var pic = ComparePicture()
    pic.signalA = CompareSeries(xs: xs, ys: ys)
    let plot = signalPlot(pic, EverforestDark)
    doAssert plot.curves.len == 1
    doAssert plot.curves[0].ys.len == n, "cut to " & $plot.curves[0].ys.len
    doAssert abs(plot.curves[0].ys[1] - 10) < 1e-9, "spike at 1 dropped"
    doAssert abs(plot.curves[0].ys[15] - 7) < 1e-9, "spike at 15 dropped"
    # Stepping to 4000 drops both spikes. Peak-keeping the pixels on screen
    # keeps the larger one; a zoom to those samples draws both.
    let drawn = plot.forScreen(xs[0], xs[^1], 4_000)
    doAssert drawn[0].ys.len <= 4_002, "drew " & $drawn[0].ys.len
    doAssert drawn[0].ys.len > 100
    var kept = false
    for y in drawn[0].ys:
      if abs(y - 10) < 1e-6: kept = true
    doAssert kept, "the spike was stepped over"
    let zoomed = plot.forScreen(0.0, 10.0, 100)
    var z10, z7 = false
    for y in zoomed[0].ys:
      if abs(y - 10) < 1e-6: z10 = true
      if abs(y - 7) < 1e-6: z7 = true
    doAssert z10 and z7, "zoom did not reach both spikes"
    doAssert zoomed[0].ys.len <= 25, "zoomed still decimated: " & $zoomed[0].ys.len

  block gapStaysAGap:
    # A bin with no finite sample stays a gap, not a zero (a phase break).
    var p = CurvePlot()
    p.curves.add Curve(name: "g", xs: @[0.0, 1, 2, 3, 4, 5, 6, 7],
      ys: @[NaN, NaN, NaN, NaN, 9.0, NaN, NaN, NaN])
    let d = p.forScreen(0, 7, 4) # two bins of four, two points each
    var sawNan, saw9, saw0 = false
    for y in d[0].ys:
      if y.isNaN: sawNan = true
      elif abs(y - 9) < 1e-9: saw9 = true
      elif abs(y) < 1e-9: saw0 = true
    doAssert sawNan and saw9 and not saw0, "a gap was drawn as zero"

  block drawerRedoesForTheView:
    let text = readFile(currentSourcePath().parentDir.parentDir / "src" / "viewSEG" /
      "ui" / "imgui" / "curveplot.nim")
    doAssert "forScreen" in text, "the plot does not decimate for the range on screen"

  echo "tcomparedraw: ok"

when isMainModule:
  main()
