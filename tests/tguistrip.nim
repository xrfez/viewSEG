## The Seismic window's strip at the program's first window size (1280 x
## 800, the windows as at a first start), on a record with auxiliary traces
## (so the Seismic and Aux toggles are in it): it takes three lines, with
## no filter and with filters whose description is long (a band-pass, two
## notches and the DC removal), applied and shown raw. A fourth line would
## take its height from the plot, which then no longer shows a whole record
## at its first scale.
##
## The other window tests draw at 1280 x 900 or wider, measure from the
## plot's own rectangle and open records without auxiliary traces, so a
## strip grown by a line moved their plot without failing them.
##
## Seen to fail: with the filters' drop-down showing their description in
## the strip (a combo as wide as "Filters", or "Filters: 12-20-60-80 Hz,
## notch 50 Hz x3, 60 Hz, DC"), "no filter: the strip takes 4 lines".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/fixtures

const
  StripMarks = ["plot.Greyscale density", "plot.Time across", "plot.traces.Seismic",
    "plot.traces.Aux", "plot.overlap", "plot.filters", "plot.filters raw", "plot.gain",
    "plot.gain dB", "plot.trace scale", "plot.time scale", "plot.zoom out", "plot.back",
    "plot.record", "plot.next record", "plot.sort.custom", "plot.more"]
    ## the first and last control of each of the strip's groups

template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]

proc answered(f: FrameInfo): bool =
  let tiles = f.core.tiles(f.core.findPanel(MainPanel))
  f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
    f.panel.pending.gen == f.panel.requestGen

proc lines(f: FrameInfo): (int, string) =
  ## How many lines the strip's controls take, and where each is.
  var centres: seq[float32]
  var said = ""
  for name in StripMarks:
    let r = f.markOf(name)
    doAssert r.size.x > 0, name & " is not in the strip"
    centres.add r.pos.y + r.size.y / 2
    said.add name & " at " & $int(r.pos.x) & ", " & $int(r.pos.y) & "; "
  centres.sort()
  result = (1, said)
  for i in 1 ..< centres.len:
    if centres[i] - centres[i - 1] > 4: inc result[0]

withFixtures fx:
  let long = Processing(band: pbBandPass, f1: 12, f2: 20, f3: 60, f4: 80, dc: dcMean,
    notches: @[NotchFilter(hz: 50, harmonics: 3), NotchFilter(hz: 60)])
  var stage = 0
  var waited = 0
  var seen: seq[(string, int, string)]
  proc measure(f: FrameInfo; what: string) =
    let (n, said) = f.lines()
    seen.add (what, n, said)
  proc onFrame(f: FrameInfo) =
    inc waited
    case stage
    of 0:
      if f.core.panels.len > 0 and f.answered and waited > 3:
        doAssert f.panel.layout.traces == 24
        f.measure("no filter")
        f.apply Command(kind: ckProcessing, panel: MainPanel, processing: long)
        (stage, waited) = (1, 0)
    of 1:
      if f.answered and waited > 3:
        f.measure("filters: " & describe(f.panel.layers[0].processing))
        var raw = long
        raw.raw = true
        f.apply Command(kind: ckProcessing, panel: MainPanel, processing: raw)
        (stage, waited) = (2, 0)
    of 2:
      if f.answered and waited > 3:
        f.measure("filters shown raw")
        stage = 3
        f.stop()
    else: discard
    if f.index > 3000: f.stop()
  let code = run(RunOptions(maxFrames: 4000, openPaths: @[fx.twoSetSegd()],
    windowSize: (1280, 800), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 3, "stopped at stage " & $stage
  for (what, n, said) in seen:
    echo "tguistrip: ", what, ": ", n, " lines"
    doAssert n <= 3, what & ": the strip takes " & $n & " lines: " & said
