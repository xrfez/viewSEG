## Record navigation in the running frontend, headless, with real pointer
## and key events: the Records window lists the file's records and marks the
## one shown; a click on a row shows that record; with the window focused,
## Tab steps no record and puts the keyboard's focus on the record shown,
## Up, Home and End step through them, the focus going along; in the plot
## window, Page Up / Page
## Down, Home and End do, and so do the strip's arrows; Ctrl + G opens "Go
## to record", where a place or an FFID typed and Enter shows that record.
## A file of 100 000 records: End shows the last record and scrolls the list
## to it, and turning the wheel over the list costs a frame no more than a
## short list does (only the rows in view are drawn).
##
## Seen to fail: with the keyboard's focus left on the row it was on
## (`ListFocus.stepped` not called), "the focus stayed on the record
## before"; with the record list's rows all drawn (no clipper), every
## frame with 100 000 records took about 184 ms (5 ms with it), "the list
## lags"; with Page Down not handled in the plot, "stopped before page
## down"; with the "Go to record" popup reading the FFID box as a place,
## "stopped before goto ffid".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves records-*.png there.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/fixtures

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc gatherShown(f: FrameInfo): int =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  if p.layers.len > 0: p.layers[0].source.gather else: -1

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

let shots = getEnv("VIEWSEG_SCREENSHOTS")
if shots.len > 0: createDir(shots)

withFixtures fx:
  var
    stage = 0
    wait = 0
    at: Vec2
    reached: seq[string]
  proc key(f: FrameInfo; k: SimKey; mods: set[SimMod] = {}) =
    case wait
    of 1:
      if smCtrl in mods: f.pressKey(skCtrl, true, {smCtrl})
    of 2: f.pressKey(k, true, mods)
    of 3: f.pressKey(k, false, mods)
    of 4:
      if smCtrl in mods: f.pressKey(skCtrl, false)
    else: discard
  proc click(f: FrameInfo; mark: string; focusing = false) =
    ## A click on `mark`; with `focusing`, two: the first only brings an
    ## unfocused window forward.
    if wait == 1:
      at = f.markOf(mark).centre
      f.moveMouse(at)
    if wait == 3: f.pressMouse(at, true)
    if wait == 5: f.pressMouse(at, false)
    if focusing and wait == 8: f.pressMouse(at, true)
    if focusing and wait == 10: f.pressMouse(at, false)
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    proc next(name: string) =
      reached.add name
      inc stage
      wait = 0
    template reach(name: string; gather: int) =
      if wait > 6 and f.gatherShown == gather and f.laidOut: next name
    case stage
    of 0:
      if f.laidOut and f.markOf("records.row 2").size.x > 0 and
          f.markOf("records.current").size.x > 0:
        next "listed"
    of 1:
      f.click("records.row 2", focusing = true)
      if wait == 7: doAssert f.gatherShown != 2, "a focusing click showed record 3"
      reach("click", 2)
    of 2: # Tab steps no record (the list is the window's one stop of Tab); Up
      # does, and the keyboard's focus goes along to the record shown
      if wait == 2: f.pressKey(skTab, true)
      if wait == 3: f.pressKey(skTab, false)
      if wait == 9:
        doAssert f.gatherShown == 2, "Tab showed record " & $(f.gatherShown + 1)
        doAssert f.markOf("records.focused") == f.markOf("records.current"),
          "Tab did not put the focus on the record shown: " & $f.markOf("records.focused")
      if wait == 10: f.pressKey(skUp, true)
      if wait == 11: f.pressKey(skUp, false)
      if wait > 18 and f.gatherShown == 1 and f.laidOut:
        doAssert f.markOf("records.focused") == f.markOf("records.current"),
          "the focus stayed on the record before: " & $f.markOf("records.focused")
        next "up"
    of 3:
      f.key(skHome)
      reach("home", 0)
    of 4:
      f.key(skEnd)
      reach("end", 2)
    of 5: # into the plot
      f.click("plot.data")
      if wait > 6: next "plot"
    of 6:
      f.key(skPageUp)
      reach("page up", 1)
    of 7:
      f.key(skPageDown)
      reach("page down", 2)
    of 8:
      f.key(skHome)
      reach("plot home", 0)
    of 9:
      f.key(skEnd)
      reach("plot end", 2)
    of 10:
      f.click("plot.previous record")
      reach("previous", 1)
    of 11:
      f.click("plot.next record")
      reach("next", 2)
    of 12:
      f.click("plot.data")
      if wait == 8: f.pressKey(skCtrl, true, {smCtrl})
      if wait == 9: f.pressKey(skG, true, {smCtrl})
      if wait == 10: f.pressKey(skG, false, {smCtrl})
      if wait == 11: f.pressKey(skCtrl, false)
      if wait > 14 and f.markOf("goto").size.x > 0: next "goto open"
    of 13:
      if wait == 2: f.typeText("1") # the place is selected: typing replaces it
      if wait == 4: f.pressKey(skEnter, true)
      if wait == 5: f.pressKey(skEnter, false)
      reach("goto place", 0)
    of 14:
      if wait <= 6: f.click("plot.record") # the record's number opens the popup too
      if wait == 10:
        at = f.markOf("goto.ffid").centre
        f.moveMouse(at)
      if wait == 12: f.pressMouse(at, true)
      if wait == 14: f.pressMouse(at, false)
      if wait == 16: f.typeText($(FirstRecord + 1))
      if wait == 18: f.pressKey(skEnter, true)
      if wait == 19: f.pressKey(skEnter, false)
      if wait > 20 and f.gatherShown == 1 and f.laidOut:
        if shots.len > 0: discard f.savePng(shots / "records-survey.png")
        next "goto ffid"
    else: f.stop()
    if f.index > 3000: f.stop()

  let code = run(RunOptions(maxFrames: 3500, openPaths: @[fx.surveySegy()],
    windowSize: (1600, 1000), indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  const order = ["listed", "click", "up", "home", "end", "plot", "page up", "page down",
    "plot home", "plot end", "previous", "next", "goto open", "goto place", "goto ffid"]
  for i, s in order:
    doAssert reached.len > i, "stopped before " & s & ": reached " & $reached

  # 100 000 records: End, then the wheel over the list.
  let many = fx.manyRecordsSegy()
  stage = 0
  wait = 0
  var
    idle, scrolling: seq[float64] # frame times, ms
    last = getMonoTime()
    lastShown = false
  proc onMany(f: FrameInfo) =
    inc wait
    let now = getMonoTime()
    let ms = (now - last).inMicroseconds.float64 / 1000
    last = now
    if f.index == 0: f.moveMouse(vec2(4, 4))
    case stage
    of 0:
      if f.laidOut and f.markOf("records.row 2").size.x > 0:
        stage = 1
        wait = 0
    of 1:
      f.click("records.row 2", focusing = true)
      if wait > 12 and f.gatherShown == 2:
        stage = 2
        wait = 0
    of 2:
      f.key(skEnd)
      if wait > 10 and f.gatherShown == ManyRecords - 1 and f.laidOut:
        lastShown = f.markOf("records.current").size.x > 0
        at = f.markOf("records.table").centre
        f.moveMouse(at)
        stage = 3
        wait = 0
    of 3: # idle frames, then the wheel, a notch a frame
      if wait in 5 .. 64: idle.add ms
      if wait >= 66 and wait < 126:
        if wait > 66: scrolling.add ms
        f.scrollWheel(at, (if wait < 96: 3 else: -3))
      if wait == 126:
        if shots.len > 0: discard f.savePng(shots / "records-many.png")
        f.stop()
    else: f.stop()
    if f.index > 3000: f.stop()
  let code2 = run(RunOptions(maxFrames: 3500, openPaths: @[many], windowSize: (1600, 1000),
    indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onMany))
  doAssert code2 == 0
  doAssert lastShown, "End did not scroll the list to the last record"
  doAssert scrolling.len >= 50 and idle.len >= 50, $scrolling.len & " " & $idle.len
  let medIdle = idle.sorted[idle.len div 2]
  let medScroll = scrolling.sorted[scrolling.len div 2]
  let worst = scrolling.max
  echo "tguirecords: ", reached.len, " steps; 100000 records: frames idle ",
    formatFloat(medIdle, ffDecimal, 1), " ms, scrolling median ",
    formatFloat(medScroll, ffDecimal, 1), " ms, slowest ", formatFloat(worst, ffDecimal, 1),
    " ms"
  doAssert medScroll < 50 and medScroll < medIdle * 3 + 10,
    "the list lags: median " & $medScroll & " ms a frame while scrolling, " & $medIdle & " idle"
