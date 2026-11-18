## The main plot's time axis always labels its last visible time, headless:
## on a 12 000-sample, 1 ms record the whole view has a label at the last
## sample ("plot.time end", at the plot's bottom edge, time running down)
## and one at the first ("plot.time start", at the top); a zoomed view
## labels its own last time, at the edge again.
##
## Seen to fail: with the end labels not set up (`SetupAxisTicks` left out)
## no text was drawn at the "plot.time end" mark ("0 pixels").
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves timeend.png there.

import std/[monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

proc main*() =

  withFixtures fx:
    let path = fx.longTraceSegy(12_000, 3)
    var stage = 0
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var shot = false
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc settled(f: FrameInfo): bool =
      let tiles = f.core.tiles(f.core.findPanel(MainPanel))
      f.panel.laidOut and tiles.len > 0 and tiles[^1].request == f.panel.pending and
        f.tracePanel.drawnView.sameSpans(f.panel.view)
    proc inked(f: FrameInfo; r: Rect): int =
      ## Pixels of `r` that are not its corner's colour: the label's glyphs.
      let bg = f.readPixel(int(r.pos.x) + 1, int(r.pos.y) + 1)
      for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
        for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
          let c = f.readPixel(x, y)
          if abs(int(c.r) - int(bg.r)) + abs(int(c.g) - int(bg.g)) + abs(int(c.b) - int(bg.b)) > 120:
            inc result
    proc check(cond: bool; what: string) =
      if not cond and failed.len == 0: failed = what
    proc onFrame(f: FrameInfo) =
      inc wait
      template next() = (stage, wait, since) = (stage + 1, 0, getMonoTime())
      let data = f.markOf("plot.data")
      let last = f.markOf("plot.time end")
      let first = f.markOf("plot.time start")
      case stage
      of 0: # the whole record
        if wait > 8 and f.settled:
          let mid = last.pos.y + last.size.y / 2
          check last.size.x > 0, "whole view: no end label"
          check f.inked(last) > 15, "whole view: no text drawn at the end label (" &
            $f.inked(last) & " pixels)"
          check abs(mid - (data.pos.y + data.size.y)) < 2,
            "whole view: the end label at " & $mid & ", the plot's bottom " &
            $(data.pos.y + data.size.y)
          check abs(first.pos.y + first.size.y / 2 - data.pos.y) < 2, "whole view: the first label"
          check f.tracePanel.drawnView.timeMs.hi == 11_999, "whole view not to the last sample"
          let dir = getEnv("VIEWSEG_SCREENSHOTS")
          if dir.len > 0 and not shot:
            createDir(dir)
            shot = f.savePng(dir / "timeend.png")
          next()
      of 1:
        if wait == 1:
          var v = f.panel.view
          v.timeMs = Span(lo: 2437, hi: 3101)
          f.showView(v)
        if wait > 8 and f.settled and f.tracePanel.drawnView.timeMs.lo == 2437:
          let at = f.panel.view.timeMs
          let want = data.pos.y + data.size.y * (3101 - at.lo) / (at.hi - at.lo)
          check abs(last.pos.y + last.size.y / 2 - want) < 2, "zoomed: the end label is at " &
            $(last.pos.y + last.size.y / 2) & ", not " & $want
          check f.inked(last) > 15, "zoomed: no text drawn at the end label"
          next()
      else: f.stop()
      if overdue(f.index, 3000, since): (failed = "timed out in stage " & $stage; f.stop())
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    echo "tguitimeend: the end labels stand at the plot's edges"

when isMainModule:
  main()
