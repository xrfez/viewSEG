## How a selected trace is drawn, in the running frontend, headless, on
## samples/vib/vib_signature.sgd (a sweep per trace: a dense band of ink) in
## wiggles: a marker stands above the selected trace (the mark "plot.selection
## markers"), its column is tinted towards the selection colour (the column's
## pixels are redder than an unselected one's), and the sweep itself keeps its
## normal ink: almost none of the pixels along the trace's centre are the
## selection colour. `HANDTEST_SHOTS=<dir>` saves handtest-select-sweep.png there.
## On a land record (wiggles, `samples/land/shots.sgy`) two traces apart make two
## markers, and handtest-select-wiggle.png.
##
## Seen to fail: with the line recoloured wherever it is drawn (`BandPx` taken
## out of the shader), "the sweep turned to the selection colour: 61 of 64 pixels";
## with the tint pass left out, "the column is not tinted".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[monotimes, options, os, sequtils, strutils]
import viewSEG/core/[geometry, panels, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_signature.sgd"

func near(a, b: Rgba; tol = 60): bool =
  abs(int(a.r) - int(b.r)) + abs(int(a.g) - int(b.g)) + abs(int(a.b) - int(b.b)) <= tol

proc scene(fx: Fixtures; path, shot: string; picks: seq[int]; sweep: bool) =
  ## Opens `path` in wiggles, selects traces `picks` (positions) and checks how they are drawn.
  block:
    doAssert fileExists(path), path
    let shots = getEnv("HANDTEST_SHOTS")
    var wait = 0
    var since = getMonoTime()
    var stage = 0
    var failed = ""
    var settle = 0
    proc column(f: FrameInfo; position: int): int =
      ## The framebuffer x of the middle of `position`'s trace.
      let data = f.markOf("plot.data")
      let v = f.core.panels[f.core.findPanel(MainPanel)].view
      int(data.pos.x + (float64(position) + 0.5 - v.traces.lo) / v.traces.width * data.size.x)
    proc region(f: FrameInfo; x: int): seq[Rgba] =
      ## The pixels of a block around column `x` of the plot, 256 rows by 21 columns.
      let data = f.markOf("plot.data")
      for k in 0 ..< 256:
        let y = int(data.pos.y + (float(k) + 0.5) / 256 * data.size.y)
        for dx in -10 .. 10: result.add f.readPixel(x + dx, y)
    var before: seq[Rgba]
    proc onFrame(f: FrameInfo) =
      inc wait
      let k = f.core.findPanel(MainPanel)
      if k >= 0 and f.core.panels[k].laidOut and f.core.panels[k].shown.len > 0:
        if stage == 0 and wait > 12:
          before = f.region(f.column(picks[0]))
          var d = f.core.panels[k].layers[0].display
          d.mode = dmWiggle
          f.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
          f.apply Command(kind: ckSelect, traces: picks.mapIt(f.core.sessions[0].base + it),
            mode: smReplace)
          stage = 1
          wait = 0
        elif stage == 1 and wait > 12:
          doAssert f.markOf("plot.selection markers").size.x > 0, "no marker over the selection"
          let sel = f.theme.roles[rlSelected]
          let x = f.column(picks[0])
          doAssert f.markOf("plot.selection marker " & $picks.len).size.x > 0,
            "fewer markers than selected traces apart"
          doAssert f.markOf("plot.selection marker " & $(picks.len + 1)).size.x == 0
          if sweep:
            var like = 0
            let data = f.markOf("plot.data")
            for j in 0 ..< 64:
              let y = int(data.pos.y + (float(j) + 0.5) / 64 * data.size.y)
              if f.readPixel(x, y).near(sel): inc like
            if like > 8:
              failed = "the sweep turned to the selection colour: " & $like & " of 64 pixels"
            # the tint: pixels of the trace's column that were paper move towards the
            # selection colour, and the ink pixels stay as they were
            let after = f.region(x)
            var tinted, spoiled = 0
            for i in 0 ..< after.len:
              let (a, b) = (after[i], before[i])
              let nearer = abs(int(a.r) - int(sel.r)) + abs(int(a.g) - int(sel.g)) +
                abs(int(a.b) - int(sel.b)) < abs(int(b.r) - int(sel.r)) + abs(int(b.g) -
                int(sel.g)) + abs(int(b.b) - int(sel.b))
              if a != b and nearer and b.near(Rgba(r: 255, g: 255, b: 255, a: 255), 30): inc tinted
              if b.near(Rgba(a: 255), 30) and a != b: inc spoiled
            if tinted < 100: failed = failed & " the column is not tinted: " & $tinted & " pixels"
            if spoiled > 3: failed = failed & " ink pixels changed: " & $spoiled
          if shots.len > 0:
            createDir(shots)
            discard f.savePng(shots / shot)
          stage = 2
          wait = 0
        elif stage == 2:
          f.stop()
      if overdue(wait, 600, since):
        failed = "no selection drawn at stage " & $stage
        f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1500, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert stage == 2, "the selection was not drawn"


proc main*() =
  withFixtures fx:
    scene(fx, sample, "handtest-select-sweep.png", @[5], true)
    scene(fx, currentSourcePath().parentDir.parentDir / "samples" / "land" / "shots.sgy",
      "handtest-select-wiggle.png", @[3, 9], false)
  echo "tguiselectlook: ok"

when isMainModule: main()
