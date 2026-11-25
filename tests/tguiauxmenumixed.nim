## The auxiliary group of the plot's menu appears on auxiliary traces only, headless, on a
## record of two seismic traces followed by two auxiliary ones, shown together. A right-click
## on each of the four traces: the seismic ones have no "Correlate auxiliary trace" item; the
## auxiliary ones have it, numbered by their place among the auxiliary traces (1 and 2).
##
## Seen to fail: with the group drawn on every trace, "the seismic trace 1 has the group";
## with the position counted among all the traces, "the menu says 3 over auxiliary trace 1".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =
  withFixtures fx:
    let folder = fx.dir / "data"
    createDir(folder)
    let path = folder / "mixed.sgy"
    block:
      var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1,
        measurementSystem: 1, text: @["C01 auxiliary menu test"]))
      for i in 0 .. 3:
        var buf = newSeq[float32](200)
        for j in 0 ..< 200: buf[j] = float32(sin(float64(j + i) / 5))
        var k = initTraceKeys()
        if i >= 2:
          k.traceCode = 6'i16
          k.status = tsAuxiliary
        else:
          k.status = tsLive
        k.record = 7.0
        k.channel = float64(i + 1)
        k.intervalUs = 2000.0
        k.time = 1_700_000_000.0
        w.writeTrace(k, buf)
      doAssert w.close().len == 0
    var stage = 0
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var seen: seq[string] = @[] # "trace:position", position 0 for no group
    const Fractions = [0.12, 0.38, 0.62, 0.88]
    var at = 0
    template mainPanel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc onFrame(f: FrameInfo) =
      inc wait
      template next() = (stage, wait, since) = (stage + 1, 0, getMonoTime())
      let plot = f.markOf("plot.data")
      case stage
      of 0:
        if wait > 10 and f.mainPanel.laidOut and plot.size.x > 0:
          var flt = f.mainPanel.layers[0].filter
          flt.auxiliary = true
          f.apply Command(kind: ckFilter, panel: MainPanel, filter: flt)
          next()
      of 1: # the four traces are shown: right-click at a fraction of the width
        if wait > 20 and f.markOf("plot.traces.Aux").size.x > 0:
          if f.markOf("plot.menu.target").size.x > 0:
            let hover = f.core.selection.hover
            let local = hover - f.core.sessions[0].base
            let names = f.markNames("plot.menu.aux ")
            let position = if names.len > 0: parseInt(names[0].split(' ')[^1]) else: 0
            if hover < 0: failed = "no trace under the pointer"
            seen.add $(local + 1) & ":" & $position
            if local >= 2 and position != local - 1:
              failed = "the menu says " & $position & " over auxiliary trace " & $(local - 1)
            if local < 2 and position != 0:
              failed = "the seismic trace " & $(local + 1) & " has the group"
            next()
          elif wait mod 10 == 2:
            let q = vec2(plot.pos.x + plot.size.x * Fractions[at], plot.pos.y + plot.size.y / 2)
            f.moveMouse(q)
            f.pressMouse(q, true, 3)
            f.pressMouse(q, false, 3)
      of 2: # a click on the status bar closes the menu, then the next trace
        if f.markOf("plot.menu.target").size.x > 0:
          if wait mod 6 == 1:
            let q = vec2(700, 887)
            f.moveMouse(q)
            f.pressMouse(q, true, 1)
            f.pressMouse(q, false, 1)
        else:
          inc at
          if at == Fractions.len: next()
          else:
            stage = 1
            wait = 0
      else:
        f.stop()
      if failed.len > 0 or overdue(f.index, 6000, since):
        if failed.len == 0: failed = "timed out in stage " & $stage & " at " & $at
        f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert seen == @["1:0", "2:0", "3:1", "4:2"], "the menus were " & $seen
    echo "tguiauxmenumixed: ok"

when isMainModule:
  main()
