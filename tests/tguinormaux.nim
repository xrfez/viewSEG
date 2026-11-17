## Normalized for each trace on a record of auxiliary traces of very
## different amplitude (`samples/vib/vib_signature.sgd`: 24 auxiliary traces,
## the ground force near 60 000, the baseplate near 12, the reference sweep
## near 1; eight seconds of sweep, a second of quiet), headless, as the plot
## draws it: wiggles with the positive fill at an overlap of 0.4, whatever
## the statistic (percentile, RMS, peak) and under AGC:
##
## - in the quiet second (not under AGC, which lifts it) after the sweep no trace puts ink beside its
##   baseline (the ground force's small noise, 60 000 times -56 dB, is
##   a swing of many trace spacings when it is not normalized);
## - in the sweep every trace swings, and none puts ink past its overlap
##   (0.4 trace spacings) into the lane between it and the next.
##
## `VIEWSEG_SCREENSHOTS=<dir>` saves normfix-*.png there, at an overlap of 2.
##
## Seen to fail: with the display gain left off the auxiliary traces
## (processSEG passes them by), "percentile: the quiet second has ink ...".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, plotref, waiting]

const
  Sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_signature.sgd"
  Overlap = 0.4

type Case = tuple[name: string, gain: DisplayGain, stat: NormStat, overlap: float64, shot: bool]

const Cases: seq[Case] = @[
  ("percentile", dgNormalized, normPercentile, Overlap, false),
  ("rms", dgNormalized, normRms, Overlap, false),
  ("peak", dgNormalized, normMax, Overlap, false),
  ("agc", dgAgc, normPercentile, Overlap, false),
  ("rms2", dgNormalized, normRms, 2.0, true),
  ("agc2", dgAgc, normPercentile, 2.0, true)]

proc inked(s: Shot; i, j: int): bool = not close(s.at(i, j), s.ink.background)

proc check(s: Shot; name: string) =
  let ppt = s.style.pixelsPerTrace
  let tail = (s.row(8300), s.row(8900))
  let sweep = (s.row(500), s.row(7500))
  var inTail, swung, past = 0
  for p in 0 .. 23:
    let c = s.column(float64(p))
    for j in tail[0] .. tail[1]:
      for i in c + int(0.08 * ppt) .. c + int(0.45 * ppt):
        if s.inked(i, j): inc inTail
    var far = 0
    for j in sweep[0] .. sweep[1]:
      for i in c + 1 .. c + int(0.5 * ppt):
        if s.inked(i, j): far = max(far, i - c)
      for i in c + int(0.46 * ppt) .. c + int(0.54 * ppt):
        if s.inked(i, j): inc past
    if far.float64 > (if name == "agc": 0.1 else: 0.25) * ppt: inc swung
  # (AGC lifts a quiet stretch to the level of the rest: its tail is not quiet)
  doAssert inTail == 0 or name == "agc", name & ": the quiet second has ink beside the baselines (" &
      $inTail &
    " pixels)"
  doAssert swung >= 22, name & ": only " & $swung & " of 24 traces swing in the sweep"
  doAssert past == 0, name & ": ink past the overlap into the lane between traces (" & $past &
    " pixels)"

proc main*() =
  doAssert fileExists(Sample), Sample
  withFixtures fx:
    var at = 0
    var wait = 0
    var since = getMonoTime()
    var stage = 0 # 0: not opened, 1: setting up the case, 2: waiting for its picture
    var images = 0
    var quiet = 0
    var failed = ""
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    if shots.len > 0: createDir(shots)
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc answered(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.panel.pending.gen == f.panel.requestGen
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if f.tracePanel.imagesDrawn != images:
        images = f.tracePanel.imagesDrawn
        quiet = 0
      else: inc quiet
      inc wait
      if at >= Cases.len or failed.len > 0:
        f.stop()
        return
      let c = Cases[at]
      case stage
      of 0:
        if f.panel.laidOut and f.panel.layers.len > 0:
          var flt = f.panel.layers[0].filter
          flt.auxiliary = true
          f.apply Command(kind: ckFilter, panel: MainPanel, filter: flt)
          stage = 1
          wait = 0
      of 1:
        if f.panel.layout.traces == 24 and wait > 4:
          var d = f.panel.layers[0].display
          d.mode = dmWiggle
          d.fills = {wfPositive}
          d.colours = pcPaper
          d.gain = c.gain
          d.normScope = perTrace
          d.normStat = c.stat
          d.gainDb = 0
          d.overlap = c.overlap
          f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
          f.showView(Viewport(traces: Span(lo: -0.5, hi: 23.5),
            timeMs: Span(lo: 0, hi: 8996), columns: f.panel.view.columns,
            rows: f.panel.view.rows))
          stage = 2
          wait = 0
      else:
        let d = f.panel.layers[0].display
        if f.answered and quiet > 8 and wait > 20 and d.gain == c.gain and
            d.overlap == c.overlap and d.normStat == c.stat and
            f.tracePanel.drawnView.sameSpans(f.panel.view):
          if shots.len > 0 and c.shot:
            discard f.savePng(shots / ("normfix-" & c.name & ".png"))
          if not c.shot:
            try: f.capture.check(c.name)
            except AssertionDefect as e: failed = e.msg
          inc at
          stage = 1
          wait = 0
      if overdue(wait, 600, since): failed = c.name & " did not happen (stage " & $stage & ")"
    let code = run(RunOptions(openPaths: @[Sample], windowSize: (1500, 800),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == Cases.len, "stopped at " & Cases[min(at, Cases.high)].name
    echo "tguinormaux: ", Cases.len, " cases"

when isMainModule:
  main()
