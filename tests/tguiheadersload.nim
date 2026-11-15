## The Trace tab's Data of a long trace, in the running frontend, headless:
## a trace of 100 000 samples, then one of 1 000 000, is selected and its
## samples come to the Data tab (read off the UI thread); the wheel then
## scrolls the table many rows a frame, and the frames are timed: scrolling
## costs little more than an idle frame and stays under 33 ms (only the rows
## in view are made, so a million rows cost what a hundred do). The rows
## shown follow the wheel, and the samples are the trace's.
##
## Then 32 traces side by side: a frame costs what the rows in view cost,
## whatever the traces hold: 32 traces of 1 000 000 samples each cost what
## 32 of 1 000 do (nothing of the reader's answer is copied a frame).
##
## Seen to fail: with every row of the table drawn (the clipper told to
## include them all), "the Data table lags": 229 ms a frame with 100 000
## rows. With the answer's traces looped over by value (`for k, d in
## answer.traces`, a copy of every sample a frame), "the Data tab's frames
## grow with the samples held": 39.1 ms against 10.4 ms.
##
## Runs alone: it bounds the frame times while the table scrolls (under 33
## ms, and at most 15 ms over an idle frame).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func median(xs: seq[float64]): float64 =
  var s = xs
  s.sort()
  if s.len == 0: NaN else: s[s.len div 2]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc timeScrolling(path: string; samples: int; cache: string) =
  ## Shows the one trace of `path`, its Data, and times the frames while
  ## the wheel scrolls it.
  var stage = 0
  var wait = 0 # frames since the stage began, at `since`
  var since = getMonoTime()
  var last = getMonoTime()
  var idle, scrolling: seq[float64]
  var arrival = 0.0 # the frame that took the samples in
  var firstRow = -1
  proc onFrame(f: FrameInfo) =
    let now = getMonoTime()
    let ms = float64((now - last).inMicroseconds) / 1000
    last = now
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    case stage
    of 0: # the trace selected, the Trace tab's Data on screen
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      if p.laidOut and p.layout.traces == 1 and wait > 3:
        f.apply Command(kind: ckSelect, traces: @[f.core.sessions[0].base], mode: smReplace)
        var s = f.core.settings
        (s.headers.tab, s.headers.traceTab) = (htTrace, ttData)
        f.apply Command(kind: ckSettings, settings: s)
        next 1
      doAssert not overdue(wait, 2000, since), "the file was not shown"
    of 1: # the samples come
      let a = f.core.inspection.answer
      if a.traces.len == 1 and a.traces[0].samples.len == samples and
          f.markOf("headers.data 0 0").size.x > 0:
        arrival = ms
        for i in [0, samples div 2, samples - 1]:
          doAssert a.traces[0].samples[i] == longSample(i), $i
        f.moveMouse(f.markOf("headers.data").centre)
        next 2
      doAssert not overdue(wait, 600, since), "the samples never came"
    of 2: # idle frames over the table
      if wait > 5: idle.add ms
      if wait == 40: next 3
    of 3: # the wheel: 30 notches a frame, down
      if wait > 1: scrolling.add ms
      f.scrollWheel(f.markOf("headers.data").centre, -30)
      if wait == 150:
        firstRow = f.core.inspection.answer.traces.len # (kept alive below)
        next 4
    of 4:
      # The rows in view moved on: row 0 is out of view (drawn above the
      # table, where the clipper measures a row, or not at all).
      let row = f.markOf("headers.data 0 0")
      doAssert row.size.x == 0 or row.pos.y + row.size.y < f.markOf("headers.data").pos.y,
        "the table did not scroll: " & $row & " in " & $f.markOf("headers.data")
      f.stop()
    else: discard
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    indexCacheDir: some(cache), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 4, "stopped at stage " & $stage
  doAssert firstRow == 1
  let (mi, ms) = (median(idle), median(scrolling))
  echo "tguiheadersload: ", samples, " rows: the frame the samples came ",
    formatFloat(arrival, ffDecimal, 1), " ms; idle median ", formatFloat(mi, ffDecimal, 1),
    " ms; scrolling median ", formatFloat(ms, ffDecimal, 1), " ms (slowest ",
    formatFloat(scrolling.max, ffDecimal, 1), ")"
  doAssert ms < 33 and ms < mi + 15, "the Data table lags: " & $ms & " ms a frame, idle " & $mi

proc timeHeld(path: string; samples, traces: int; cache: string): float64 =
  ## Shows the Data of all `traces` traces of `path` (each of `samples`
  ## samples) and returns the median frame time while it stays on screen.
  var stage = 0
  var wait = 0 # frames since the stage began, at `since`
  var since = getMonoTime()
  var last = getMonoTime()
  var held: seq[float64]
  proc onFrame(f: FrameInfo) =
    let now = getMonoTime()
    let ms = float64((now - last).inMicroseconds) / 1000
    last = now
    inc wait
    template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
    case stage
    of 0:
      let p = f.core.panels[f.core.findPanel(MainPanel)]
      if p.laidOut and p.layout.traces == traces and wait > 3:
        var all: seq[int]
        for i in 0 ..< traces: all.add f.core.sessions[0].base + i
        f.apply Command(kind: ckSelect, traces: all, mode: smReplace)
        var s = f.core.settings
        (s.headers.tab, s.headers.traceTab) = (htTrace, ttData)
        f.apply Command(kind: ckSettings, settings: s)
        f.moveMouse(vec2(2, 2)) # off the plot: nothing hovered
        next 1
      doAssert not overdue(wait, 5000, since), "the file was not shown"
    of 1:
      let a = f.core.inspection.answer
      var full = 0
      for d in a.traces:
        if d.samples.len == samples: inc full
      if full == traces and not f.core.inspection.waiting and
          f.markOf("headers.data 0 0").size.x > 0:
        next 2
      doAssert not overdue(wait, 3000, since), "the samples never came"
    of 2:
      if wait > 10: held.add ms
      if wait == 80:
        stage = 3
        f.stop()
    else: discard
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    indexCacheDir: some(cache), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == 3, "stopped at stage " & $stage
  median(held)

withFixtures fx:
  for samples in [100_000, 1_000_000]:
    timeScrolling(fx.longTraceSegy(samples), samples, fx.dir / "cache")
  # 32 traces side by side: a frame costs what the rows in view cost, not
  # what the traces hold (nothing of the answer is copied a frame).
  let small = timeHeld(fx.longTraceSegy(1_000, 32), 1_000, 32, fx.dir / "cache")
  let large = timeHeld(fx.longTraceSegy(1_000_000, 32), 1_000_000, 32, fx.dir / "cache")
  echo "tguiheadersload: 32 traces on screen: frames of 1 000 samples each, median ",
    formatFloat(small, ffDecimal, 1), " ms; of 1 000 000 samples each, median ",
    formatFloat(large, ffDecimal, 1), " ms"
  doAssert large < max(1.5 * small, small + 5), "the Data tab's frames grow with the " &
    "samples held: " & $large & " ms against " & $small & " ms"
