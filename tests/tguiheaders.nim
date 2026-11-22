## The Headers window in the running frontend, headless, with real pointer
## and key events.
##
## A SEG-Y file shown: the Summary tab says what it is and counts the record
## shown; a click on the File headers tab shows it, and the settings
## remember it; its Text tab holds the textual header, its Binary tab the
## binary header's fields, without the Name column until the settings ask
## for it. A SEG-D record shown: its General tab lists the general headers
## (read off the UI thread), Channel sets puts the channel sets side by side
## with the fields that differ marked, and External shows the external
## header's bytes. A record of 600 channel sets shows them 64 side by side,
## a page at a time (Next, to the last page).
##
## The Trace tab (SEG-Y): empty until a trace is chosen; the trace under the
## pointer in the plot, kept when the pointer goes to the Headers window; a
## click selects a trace: its header fields in Header (the first trace's
## values in view in the default layout), its samples in Data,
## where the row at the plot's cursor time is marked and in view; Ctrl +
## click a second: two value columns, the fields that differ marked (the
## channel) and those that do not unmarked (the field record); the
## selection cleared (Esc in the plot): the trace under the pointer again;
## "Follow the pointer" off: empty, with the pointer over a trace.
##
## A SEG-D record joined with survey files: two traces selected, one whose
## receiver the survey has and one whose receiver it lacks; once joined, the
## Header table starts with the keys the join gave, the first trace's
## receiver X drawn in the accent colour (pixels of the frame), the second's
## not.
##
## A drive that stops answering, through the file-system seam
## (`tests/utils/faultyfs`): a trace header the Trace tab reads hangs; the
## window keeps drawing frames and says, above its tabs, that its reader does
## not answer; once the drive answers the trace is shown and the line goes;
## a read the drive fails says why. Nothing the UI thread calls reaches the
## file system.
##
## The Summary's line picked goes when another record is shown; the Data tab
## says when the file gives no sample interval, and when a trace has no
## samples.
##
## Seen to fail: with the tab chosen not put in the settings (no
## `ckSettings` when the tab changes), "the File headers tab was not
## remembered"; with the columns set up without `syncColumns` (every column
## shown), "stopped at binary" (the value pushed out of view by the Name and
## Offset columns); with `ckInspect` never sent, "the record's general
## headers never came". With the joined values drawn in the text colour
## (the accent's push taken out of `drawFieldTable`), "the joined receiver X
## is not in the accent colour: 0 pixels". With the line of what does not
## answer not drawn (`headersWait` not asked in `drawHeaders`), "stopped at
## \"a header read hangs\"". With the traces pointed at last not kept when
## the pointer leaves (`chosenTraces` not returning `last`), "the trace
## pointed at went"; with the trace table's marks of differing values
## cleared (`r.differs = false` after `fieldTable` in `traceTable`), "the
## channels that differ are not marked" (with `fieldTable`'s marking taken
## out for every table, the channel sets' check fails first: "the channel
## types that differ are not marked"). With the channel sets not paged
## (`pageOf` giving every set, `drawFieldTable` taking every column), Dear
## ImGui's check `columns_count < 512` stopped the program at 600 sets.
## With the old layout of the header tables (the description 18 em wide and
## the values after the bytes), "the first value is out of view" (x 1603 in a
## window ending at 1596); either change alone brings it into view. With
## the line picked kept by file only (as it was), "the line picked stayed";
## with the Data tab's two lines taken out, it stopped at "data" for each.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves headers-*.png there, and, with the
## example files present (local only), each tab of a SEG-Y and a SEG-D
## example (headers-segy3d-*.png, headers-land-*.png: the pictures
## in docs/images), the Headers window made larger by dragging its
## splitters and taken alone, the files shown from a folder of the
## fixtures (linked), so that no picture names the computer's folders;
## the land record also joined with its survey files, the headers'
## coordinates replaced (its Trace > Header and Summary then).

import std/[math, monotimes, options, os, strutils, times]
import parseSEG
import viewSEG/core/[geometry, state, vendormaps]
import viewSEG/view/theme
import viewSEG/ui/imgui/[agentshot, app, headerswindow]
import privatefiles
import utils/[faultyfs, fixtures, stations100, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

func shown(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

let shots = getEnv("VIEWSEG_SCREENSHOTS")

proc shoot(f: FrameInfo; name: string) =
  if shots.len > 0:
    doAssert f.savePng(shots / name), "cannot save " & name
    echo "tguiheaders: saved ", shots / name

type Step = proc (f: FrameInfo; wait: int): bool {.closure.}
  ## One step of a run: true once it is done; it asserts what must hold.

var began: MonoTime ## when the step under way began (its frame 0)

proc runSteps(path: string; steps: openArray[(string, Step)]; cache: string; limit = 400) =
  ## Shows `path` and takes `steps` one after another, each given up to
  ## `limit` frames and `Patience`.
  var stage = 0
  var wait = 0
  var reached: seq[string]
  let all = @steps
  began = getMonoTime()
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if stage < all.len:
      if all[stage][1](f, wait):
        reached.add all[stage][0]
        inc stage
        wait = 0
        began = getMonoTime()
      else:
        doAssert not overdue(wait, limit, began), "stopped at \"" & all[stage][0] & "\" after " &
          $reached
    else: f.stop()
  let code = run(RunOptions(openPaths: @[path], windowSize: (1600, 1000),
    indexCacheDir: some(cache), theme: forceDark, onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert stage == all.len, "stopped at stage " & $stage & " after " & $reached
  echo "tguiheaders: ", path.extractFilename, ": ", reached.join(", ")

var at: Vec2
proc clickAt(f: FrameInfo; wait: int; point: Vec2; twice = false; mods: set[SimMod] = {}) =
  ## A click at `point` over frames 1 to 5 of a step (with `twice`, another
  ## over frames 7 to 9: the first only focuses a window that had not the
  ## focus), with `mods` held.
  if wait == 1:
    at = point
    f.moveMouse(at)
  for (down, up) in [(3, 5), (7, 9)]:
    if wait == down and (down == 3 or twice):
      if smCtrl in mods: f.pressKey(skCtrl, true, {smCtrl})
      f.pressMouse(at, true)
    if wait == up and (up == 5 or twice):
      f.pressMouse(at, false)
      if smCtrl in mods: f.pressKey(skCtrl, false)

proc click(f: FrameInfo; wait: int; mark: string) =
  ## A click on `mark` over frames 1 to 5 of a step.
  if wait == 1:
    doAssert f.markOf(mark).centre.x > 0, "nothing to click: " & mark
  f.clickAt(wait, f.markOf(mark).centre)

proc pointAt(f: FrameInfo; position: int): Vec2 =
  ## The middle of the trace at `position` in the plot.
  let r = f.markOf("plot.data")
  let v = f.tracePanel.drawnView
  vec2(round(r.pos.x + float32((float64(position) - v.traces.lo) / v.traces.width) * r.size.x),
    round(r.pos.y + r.size.y / 2))

proc idAt(f: FrameInfo; position: int): int =
  ## The survey-wide id of the trace at `position` in the plot.
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  f.core.sessions[0].base + p.shown[position]

proc answered(f: FrameInfo; ids: openArray[int]): bool =
  ## Whether the inspector's newest answer is about `ids`, read.
  let a = f.core.inspection.answer
  result = a.traces.len == ids.len and not f.core.inspection.waiting
  if result:
    for k, d in a.traces:
      if d.id != ids[k]: result = false

# Screenshots of each tab on the example files (local only).
proc drag(f: FrameInfo; wait: int; start: Vec2; by: Vec2) =
  ## A drag from `start` by `by` over frames 2 to 12 of a step, as a hand
  ## would.
  if wait == 1: f.moveMouse(start)
  if wait == 2: f.pressMouse(start, true)
  if wait in 3 .. 9:
    let k = float32(wait - 2) / 7
    f.moveMouse(vec2(start.x + by.x * k, start.y + by.y * k))
  if wait == 11: f.pressMouse(vec2(start.x + by.x, start.y + by.y), false)

proc enlarge(): seq[(string, Step)] =
  ## The Headers window made taller (its splitter with the map dragged up)
  ## and wider (its column's splitter with the plot dragged left).
  result.add ("taller", Step(proc (f: FrameInfo; wait: int): bool =
    let r = f.markOf("headers")
    if wait == 1: at = vec2(round(r.pos.x + r.size.x / 2), r.pos.y - 3)
    f.drag(wait, at, vec2(0, -420))
    wait > 16))
  result.add ("wider", Step(proc (f: FrameInfo; wait: int): bool =
    let r = f.markOf("headers")
    if wait == 1: at = vec2(r.pos.x - 3, round(r.pos.y + r.size.y / 2))
    f.drag(wait, at, vec2(-420, 0))
    wait > 16))

proc shootWindow(f: FrameInfo; name: string) =
  ## The Headers window alone, saved as `name` (the rest of the frame names
  ## the computer's folders).
  if shots.len > 0:
    let r = f.markOf("headers")
    let (x0, y0) = (max(0, int(r.pos.x)), max(0, int(r.pos.y)))
    let (x1, y1) = (min(f.width, int(r.pos.x + r.size.x)), min(f.height, int(r.pos.y + r.size.y)))
    doAssert x1 > x0 and y1 > y0, "the Headers window is not on screen: " & $r
    let all = f.readFrame()
    var part = newSeq[Rgba]((x1 - x0) * (y1 - y0))
    for y in y0 ..< y1:
      for x in x0 ..< x1: part[(y - y0) * (x1 - x0) + x - x0] = all[y * f.width + x]
    let (png, why) = encodePng(part, x1 - x0, y1 - y0)
    doAssert why.len == 0, why
    writeFile(shots / name, png)
    echo "tguiheaders: saved ", shots / name

proc tabShot(name, mark, file: string): (string, Step) =
  ## A click on the tab `mark`, then a screenshot of the Headers window as
  ## `file` once `name`'s content shows.
  (name, Step(proc (f: FrameInfo; wait: int): bool =
    f.click(wait, mark)
    result = wait > 20 and not f.core.inspection.waiting
    if result: f.shootWindow(file)))

proc inked(f: FrameInfo; mark: string; ink: Rgba): int =
  ## The pixels of `mark` near `ink` (a glyph's stems, antialiased: within
  ## 48 levels; the warning and text colours are over 100 away).
  let r = f.markOf(mark)
  let pixels = f.readFrame()
  for y in max(0, int(r.pos.y)) ..< min(f.height, int(r.pos.y + r.size.y)):
    for x in max(0, int(r.pos.x)) ..< min(f.width, int(r.pos.x + r.size.x)):
      let p = pixels[y * f.width + x]
      if abs(p.r.int - ink.r.int) + abs(p.g.int - ink.g.int) + abs(p.b.int - ink.b.int) <= 48:
        inc result

proc main*() =
  if shots.len > 0: createDir(shots)

  withFixtures fx:
    runSteps(fx.surveySegy(), [
      ("summary", Step(proc (f: FrameInfo; wait: int): bool =
        result = f.laidOut and f.shown("headers.summary value Traces") and wait > 5
        if result:
          doAssert f.core.settings.headers.tab == htSummary
          doAssert f.shown("headers.summary value Sample interval")
          doAssert f.shown("headers.summary.heading")
          f.shoot("headers-summary-segy.png"))),
      ("file headers", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.tab file")
        result = wait > 8
        if result:
          doAssert f.core.settings.headers.tab == htFile,
            "the File headers tab was not remembered"
          doAssert not f.shown("headers.summary"), "the summary is still shown"
          doAssert f.shown("headers.file tab Text") and f.shown("##text")
          f.shoot("headers-text-segy.png"))),
      ("binary", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.file tab Binary")
        result = wait > 8 and f.shown("headers.binary binary.jobId 0")
        if result:
          doAssert not f.shown("headers.binary name binary.jobId"), "the Name column is shown"
          f.shoot("headers-binary-segy.png"))),
      ("name column", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1:
          var s = f.core.settings
          s.headers.columns = {hcDescription, hcName, hcBytes}
          f.apply Command(kind: ckSettings, settings: s)
        result = wait > 4
        if result:
          doAssert f.shown("headers.binary name binary.jobId"),
            "the Name column did not follow the settings"
          doAssert f.core.settings.headers.columns == {hcDescription, hcName, hcBytes},
            "the table changed the settings: " & $f.core.settings.headers.columns))],
      fx.dir / "cache")

    runSteps(fx.areasSegd(), [
      ("shown", Step(proc (f: FrameInfo; wait: int): bool = f.laidOut and wait > 3)),
      ("file headers", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.tab file")
        result = wait > 8 and f.shown("headers.general gh1.fileNumber 0")
        doAssert result or not overdue(wait, 300, began),
          "the record's general headers never came"
        if result:
          doAssert ipRecord in f.core.inspection.parts
          f.shoot("headers-general-segd.png"))),
      ("channel sets", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.file tab Channel sets")
        result = wait > 8 and f.shown("headers.sets st1cs1.channelType 0")
        if result:
          doAssert f.shown("headers.sets differs st1cs1.channelType"),
            "the channel types that differ are not marked"
          doAssert not f.shown("headers.sets differs st1cs1.scanTypeNumber")
          f.shoot("headers-sets-segd.png"))),
      ("external", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.file tab External")
        result = wait > 8 and f.shown("headers.bytes external line 0")
        if result: f.shoot("headers-external-segd.png")))],
      fx.dir / "cache")

    # A record of 600 channel sets (more than the 512 columns a table can
    # have): 64 side by side, a page at a time.
    runSteps(fx.manySetsSegd(600), [
      ("shown", Step(proc (f: FrameInfo; wait: int): bool = # (auxiliary traces only)
        f.core.panels[f.core.findPanel(MainPanel)].laidOut and wait > 3)),
      ("file headers", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.tab file")
        result = wait > 8 and f.shown("headers.general gh1.fileNumber 0")
        doAssert result or not overdue(wait, 300, began),
          "the record's general headers never came")),
      ("channel sets", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.file tab Channel sets")
        result = wait > 8 and f.shown("headers.sets st1cs1.channelType 0")
        if result:
          doAssert f.shown("headers.sets page") and f.shown("headers.sets next"),
            "no line of the pages"
          f.shoot("headers-sets-many-segd.png"))),
      ("next page", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.sets next")
        # (a row is named by its first column's set: now set 65)
        result = wait > 8 and f.shown("headers.sets st1cs65.channelType 0")
        if result: f.shoot("headers-sets-many-next-segd.png"))),
      ("last page", Step(proc (f: FrameInfo; wait: int): bool =
        for k in 0 ..< 8: f.click(wait - 10 * k, "headers.sets next")
        result = wait > 90 and f.shown("headers.sets st1cs577.channelType 0")))],
      fx.dir / "cache")

    # The Summary's picked line goes when another record is shown (its lines
    # are another record's).
    runSteps(fx.surveySegy(), [
      ("shown", Step(proc (f: FrameInfo; wait: int): bool =
        f.laidOut and f.shown("headers.summary Standard") and wait > 3)),
      ("a line picked", Step(proc (f: FrameInfo; wait: int): bool =
        # (twice: the first click only brings the window forward)
        f.clickAt(wait, f.markOf("headers.summary Standard").centre, twice = true)
        result = wait > 12 and f.headersWindow.summaryPicked >= 0)),
      ("another record", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1: f.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
        result = wait > 8 and f.laidOut and
          f.core.panels[f.core.findPanel(MainPanel)].layers[0].source.gather == 1
        if result:
          doAssert f.headersWindow.summaryPicked == -1, "the line picked stayed"))],
      fx.dir / "cache")

    # The Data tab says when the file gives no sample interval (the times
    # count samples), and when a trace has no samples.
    let noSamples = fx.dir / "no-samples.sgy"
    block:
      var bytes = readFile(fx.demoFile("survey.sgy"))
      bytes[3220] = '\0' # samples per trace, bytes 3221-3222
      bytes[3221] = '\0'
      writeFile(noSamples, bytes)
    for (path, markSrc) in [(fx.noIntervalSegy(), "headers.data no interval"),
        (noSamples, "headers.data none")]:
      # A closure cannot capture the loop variable (it is lent inside a proc).
      let mark = markSrc & ""
      runSteps(path, [
        ("shown", Step(proc (f: FrameInfo; wait: int): bool =
          result = f.core.panels[f.core.findPanel(MainPanel)].laidOut and wait > 3
          if result: f.apply Command(kind: ckSelect, traces: @[f.core.sessions[0].base + 1],
            mode: smReplace))),
        ("trace tab", Step(proc (f: FrameInfo; wait: int): bool =
          f.click(wait, "headers.tab trace")
          wait > 8 and f.shown("headers.trace tab data"))),
        ("data", Step(proc (f: FrameInfo; wait: int): bool =
          f.click(wait, "headers.trace tab data")
          result = wait > 8 and f.shown(mark)
          if result: f.shoot("headers-" & mark.replace(' ', '-') & ".png")))],
        fx.dir / "cache")

    # The Trace tab: empty until a trace is chosen; the trace under the
    # pointer, kept when the pointer leaves the plot; a click selects one, its
    # header fields and samples; Ctrl + click a second, two columns and the
    # fields that differ marked; cleared, the trace under the pointer again;
    # "Follow the pointer" off, empty.
    runSteps(fx.surveySegy(), [
      ("shown", Step(proc (f: FrameInfo; wait: int): bool =
        f.laidOut and f.core.panels[0].shown.len == Channels and wait > 3)),
      ("trace tab", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.tab trace")
        result = wait > 8
        if result:
          doAssert f.core.settings.headers.tab == htTrace
          doAssert f.shown("headers.chosen") and f.core.inspection.chosen.by == cbNone
          doAssert not f.shown("headers.trace tab header"), "a trace is shown with none chosen"
          doAssert f.core.inspection.parts == {}, "read for nothing: " &
            $f.core.inspection.parts)),
      ("the trace under the pointer", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1: f.moveMouse(f.pointAt(3))
        result = wait > 4 and f.answered([f.idAt(3)]) and f.shown("headers.trace trace.fieldRecord 0")
        if result:
          doAssert f.core.inspection.chosen.by == cbPlotPointer
          doAssert ipTraceHeaders in f.core.inspection.parts)),
      ("kept when the pointer leaves", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1: f.moveMouse(f.markOf("headers.chosen").centre)
        result = wait > 6
        if result:
          doAssert f.core.selection.hover == -1
          doAssert f.core.inspection.chosen.traces == @[f.idAt(3)], "the trace pointed at went"
          doAssert f.shown("headers.trace trace.fieldRecord 0"))),
      ("a click selects a trace", Step(proc (f: FrameInfo; wait: int): bool =
        f.clickAt(wait, f.pointAt(5), twice = true)
        result = wait > 12 and f.answered([f.idAt(5)])
        if result:
          doAssert f.core.inspection.chosen.by == cbSelection
          let d = f.core.inspection.answer.traces[0]
          for r in d.rows:
            if r.field == "traceNumberInField": doAssert r.value == "6", r.value
          doAssert f.shown("headers.trace trace.traceNumberInField 0")
          f.shoot("headers-trace-header-segy.png"))),
      ("its samples", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.trace tab data")
        result = wait > 8 and f.shown("headers.data 0 0") and
          f.core.inspection.answer.traces[0].samples.len == Samples
        if result:
          doAssert f.core.settings.headers.traceTab == ttData
          doAssert ipTraceSamples in f.core.inspection.parts
          let d = f.core.inspection.answer.traces[0]
          for i in 0 ..< Samples: doAssert d.samples[i] == surveySample(0, 6, i), $i)),
      ("the cursor's row", Step(proc (f: FrameInfo; wait: int): bool =
        if wait == 1: f.moveMouse(f.pointAt(5))
        result = wait > 6 and f.shown("headers.data cursor")
        if result:
          let r = f.markOf("headers.data cursor")
          let table = f.markOf("headers.data")
          doAssert r.pos.y >= table.pos.y and r.pos.y + r.size.y <= table.pos.y + table.size.y,
            "the cursor's row is not in view: " & $r & " in " & $table
          f.shoot("headers-trace-data-segy.png"))),
      ("Ctrl + click a second", Step(proc (f: FrameInfo; wait: int): bool =
        f.clickAt(wait, f.pointAt(9), twice = true, mods = {smCtrl}) # the plot had not the focus
        result = wait > 12 and f.answered([f.idAt(5), f.idAt(9)]) and f.shown("headers.data 0 1")
        if result:
          doAssert f.core.inspection.answer.traces[1].samples[100] == surveySample(0, 10, 100))),
      ("two columns, differences marked", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.trace tab header")
        result = wait > 8 and f.answered([f.idAt(5), f.idAt(9)]) and
          f.shown("headers.trace trace.fieldRecord 0") and
          f.core.inspection.answer.traces[1].rows.len > 0
        if result:
          doAssert f.shown("headers.trace differs trace.traceNumberInField"),
            "the channels that differ are not marked"
          doAssert not f.shown("headers.trace differs trace.fieldRecord"),
            "the same field record is marked"
          f.shoot("headers-trace-two-segy.png")
          # The first trace's values in view in the default layout (the window
          # docked at the bottom right, about 400 pixels wide), without
          # scrolling sideways.
          let w = f.markOf("headers")
          let v = f.markOf("headers.trace trace.fieldRecord 0")
          doAssert v.pos.x >= w.pos.x and v.pos.x + v.size.x <= w.pos.x + w.size.x,
            "the first value is out of view: " & $v & " in the window " & $w)),
      ("cleared: the trace under the pointer", Step(proc (f: FrameInfo; wait: int): bool =
        f.clickAt(wait, f.pointAt(11)) # a focusing click: the plot gets the keys
        if wait == 8: f.pressKey(skEscape, true)
        if wait == 9: f.pressKey(skEscape, false)
        result = wait > 12 and f.core.selection.selected.len == 0 and f.answered([f.idAt(11)])
        if result: doAssert f.core.inspection.chosen.by == cbPlotPointer)),
      ("Follow the pointer off: empty", Step(proc (f: FrameInfo; wait: int): bool =
        f.click(wait, "headers.follow")
        if wait == 10: f.moveMouse(f.pointAt(13))
        result = wait > 16
        if result:
          doAssert not f.core.settings.headers.followPointer
          doAssert f.core.selection.hover >= 0, "the pointer is not over a trace"
          doAssert f.core.inspection.chosen.by == cbNone, $f.core.inspection.chosen
          doAssert not f.shown("headers.trace tab header"), "a trace is still shown"
          doAssert f.core.inspection.answer.traces.len == 0
          f.shoot("headers-trace-none-segy.png")))],
      fx.dir / "cache")

  # A drive that stops answering: a hung read of a trace header leaves the
  # window drawing, and says so; a failing one says why.
  block aDriveThatStopsAnswering:
    install()
    withFixtures fx:
      let far = fx.dir / "far"
      createDir(far)
      copyFile(fx.surveySegy, far / "a.sgy")
      var last = MonoTime()
      var worst = initDuration()
      var advanced = false
      runSteps(far / "a.sgy", [
        ("shown", Step(proc (f: FrameInfo; wait: int): bool =
          f.laidOut and f.core.panels[0].shown.len == Channels and wait > 3)),
        ("trace tab", Step(proc (f: FrameInfo; wait: int): bool =
          f.click(wait, "headers.tab trace")
          wait > 8 and f.core.settings.headers.tab == htTrace)),
        ("a header read hangs", Step(proc (f: FrameInfo; wait: int): bool =
          if wait == 1:
            fault(far / "a.sgy", fkHang, {foHeaders})
            f.moveMouse(f.pointAt(3))
            last = getMonoTime()
          let now = getMonoTime()
          worst = max(worst, now - last)
          last = now
          if not advanced and hung() >= 1:
            advanceFsClock(StallAfter + initDuration(seconds = 1)) # as if it had not answered since
            advanced = true
          result = advanced and wait > 10 and f.shown("headers.waiting")
          if result:
            doAssert f.core.inspection.waiting and f.core.inspection.chosen.traces == @[f.idAt(3)]
            doAssert "not answering for" in f.core.headersWait.words, f.core.headersWait.words
            f.shoot("headers-not-answering.png"))),
        ("the drive answers", Step(proc (f: FrameInfo; wait: int): bool =
          if wait == 1: release(far / "a.sgy")
          result = wait > 3 and f.answered([f.idAt(3)]) and not f.shown("headers.waiting") and
            f.shown("headers.trace trace.fieldRecord 0"))),
        ("a header read fails", Step(proc (f: FrameInfo; wait: int): bool =
          if wait == 1:
            fault(far / "a.sgy", fkFail, {foHeaders})
            f.moveMouse(f.pointAt(6))
          result = wait > 3 and f.answered([f.idAt(6)]) and f.shown("headers.problem")
          if result:
            let d = f.core.inspection.answer.traces[0]
            doAssert "cannot be read now" in d.problem and d.rows.len == 0, d.problem
            release(far / "a.sgy")))],
        fx.dir / "cache")
      doAssert worst < initDuration(seconds = 5), "a frame waited " & $worst & " for the drive"
      doAssert uiCalls().len == 0, "the UI thread called the file system:\n" & uiCalls().join("\n")

  for tight in [false, true]: # the Headers window enlarged, and as it opens
    let narrow = tight
    block theSurveyLine:
      # The file's headers name the survey's stations and hold its coordinates
      # (the stations times 100, read through the shipped map): the survey
      # changes nothing, and the Trace tab's table says so in one quiet line.
      withFixtures fx:
        let path = fx.dir / "x100.sgy"
        writeFile100(path)
        var reg: VendorRegistry
        reg.addMap loadVendorMap(readFile(MapPath), MapPath)
        publishVendors(reg)
        let sps = writeSurveySps(fx.dir)
        let files = @[JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps)]
        runSteps(path, @[
          ("shown", Step(proc (f: FrameInfo; wait: int): bool =
            f.laidOut and wait > 3))] &
          (if narrow: @[] else: enlarge()) & @[
          ("trace tab", Step(proc (f: FrameInfo; wait: int): bool =
            f.click(wait, "headers.tab trace")
            wait > 8 and f.core.settings.headers.tab == htTrace)),
          ("matched", Step(proc (f: FrameInfo; wait: int): bool =
            if wait == 1:
              f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: files,
                joinUnits: JoinUnits(survey: suMetres))
            result = wait > 4 and f.core.joinReport.serial > 0 and f.core.joinUnderWay.job == NoJob
            if result:
              doAssert f.core.joinReport.outcome == joJoined, $f.core.joinReport.words
              doAssert "No trace's keys changed" in f.core.joinReport.words.join(" "),
                $f.core.joinReport.words)),
          ("a trace", Step(proc (f: FrameInfo; wait: int): bool =
            let base = f.core.sessions[0].base
            if wait == 1:
              f.apply Command(kind: ckSelect, traces: @[base + 1], mode: smReplace)
            result = wait > 6 and f.answered([base + 1]) and f.shown("headers.trace note 0")
            if result:
              doAssert f.core.inspection.answer.traces[0].joined == {}
              doAssert not f.shown("headers.trace name keys.srcLine"), "the group shows"
              let (note, window) = (f.markOf("headers.trace note 0"), f.markOf("headers"))
              doAssert note.pos.x + note.size.x <= window.pos.x + window.size.x,
                "the quiet line is cut by the window: it ends at " & $(note.pos.x + note.size.x) &
                ", the window at " & $(window.pos.x + window.size.x)
              f.shootWindow(if narrow: "surveyline-narrow.png" else: "surveyline.png")))],
          fx.dir / "cache")
        publishVendors(VendorRegistry())

  block theJoinedValues:
    withFixtures fx:
      let survey = fx.surveySps()
      var files: seq[JoinFile]
      for p in [survey.s, survey.r, survey.x]: files.add JoinFile(path: p, kind: jkSps)
      runSteps(fx.stationsSegd(), @[
        ("shown", Step(proc (f: FrameInfo; wait: int): bool = f.laidOut and wait > 3))] &
        enlarge() & @[
        ("trace tab", Step(proc (f: FrameInfo; wait: int): bool =
          f.click(wait, "headers.tab trace")
          wait > 8 and f.core.settings.headers.tab == htTrace)),
        ("two traces", Step(proc (f: FrameInfo; wait: int): bool =
          let base = f.core.sessions[0].base
          if wait == 1:
            f.apply Command(kind: ckSelect, traces: @[base + 1, base + SegdChannels + 1],
              mode: smReplace)
          wait > 4 and f.answered([base + 1, base + SegdChannels + 1]) and
            f.shown("headers.trace ext1.receiverLineNumber 1"))),
        ("joined", Step(proc (f: FrameInfo; wait: int): bool =
          if wait == 1:
            f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: files,
              joinUnits: JoinUnits(survey: suMetres))
          result = wait > 4 and f.core.joinReport.serial > 0 and not f.core.inspection.waiting and
            f.shown("headers.trace keys.rcvX 1")
          if result:
            doAssert f.core.joinReport.outcome == joJoined, $f.core.joinReport.words
            doAssert f.shown("headers.trace joined keys.rcvX 0"), "the joined receiver X is not marked"
            doAssert not f.shown("headers.trace joined keys.rcvX 1"), "the other trace's is"
            f.shoot("headers-trace-joined-segd.png")
            let accent = f.theme.roles[rlAccent]
            let lit = f.inked("headers.trace joined keys.rcvX 0", accent)
            doAssert lit > 0, "the joined receiver X is not in the accent colour: " & $lit &
              " pixels"
            doAssert f.inked("headers.trace keys.rcvX 1", accent) == 0,
              "the receiver X the survey lacks is in the accent colour"))],
        fx.dir / "cache")

  if shots.len > 0 and (privateFile("landSegd").len > 0 or privateFile("segy3d").len > 0):
    withFixtures fx:
      # Shown from a folder of the fixtures, linked under a neutral name: the
      # Summary names that folder, not the computer's, and not the private file.
      createDir(fx.dir / "examples")
      var survey: seq[JoinFile]
      for p in privateFiles("landSps", "landRps", "landXps"):
        survey.add JoinFile(path: p, kind: jkSps)
      for (key, name, segd) in [("segy3d", "segy3d", false), ("landSegd", "land", true)]:
        let src = privateFile(key)
        if src.len > 0:
          let path = fx.dir / "examples" / (name & src.splitFile.ext)
          createSymlink(src, path)
          var steps = @[("shown", Step(proc (f: FrameInfo; wait: int): bool =
            f.laidOut and wait > 10))]
          steps.add enlarge()
          steps.add tabShot("summary", "headers.tab summary", "headers-" & name & "-summary.png")
          steps.add tabShot("file headers", "headers.tab file", "headers-" & name & "-file.png")
          if segd:
            steps.add tabShot("channel sets", "headers.file tab Channel sets",
              "headers-" & name & "-sets.png")
          else:
            steps.add tabShot("binary", "headers.file tab Binary", "headers-" & name & "-binary.png")
          steps.add tabShot("trace", "headers.tab trace", "headers-" & name & "-trace-none.png")
          steps.add ("select two traces", Step(proc (f: FrameInfo; wait: int): bool =
            if wait < 20: f.clickAt(wait, f.pointAt(40), twice = true)
            else: f.clickAt(wait - 20, f.pointAt(41), mods = {smCtrl})
            wait > 40 and f.core.inspection.answer.traces.len == 2 and
              not f.core.inspection.waiting))
          steps.add tabShot("header", "headers.trace tab header",
            "headers-" & name & "-trace-header.png")
          steps.add tabShot("data", "headers.trace tab data", "headers-" & name & "-trace-data.png")
          if segd and survey.len == 3:
            # joined with its survey, the headers' coordinates replaced: the
            # values the join gave, marked
            steps.add ("join", Step(proc (f: FrameInfo; wait: int): bool =
              if wait == 1:
                f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: survey,
                  joinOptions: JoinOptions(coordinates: hcReplace),
                  joinUnits: JoinUnits(survey: suUsFeet, file: suUsFeet))
              result = f.core.joinReport.serial > 0 and f.core.joinUnderWay.job == NoJob and
                not f.core.inspection.waiting and f.core.inspection.answer.traces.len == 2 and
                f.core.inspection.answer.traces[0].joined != {}
              if result: doAssert f.core.joinReport.outcome == joJoined))
            var since = MonoTime()
            steps.add ("its notice gone", Step(proc (f: FrameInfo; wait: int): bool =
              if wait == 1: since = getMonoTime()
              getMonoTime() - since > initDuration(seconds = 6))) # (a notice stays 5 s)
            steps.add tabShot("joined", "headers.trace tab header",
              "headers-" & name & "-trace-joined.png")
            steps.add tabShot("summary joined", "headers.tab summary",
              "headers-" & name & "-summary-joined.png")
          runSteps(path, steps, fx.dir / "cache", limit = 3000)

when isMainModule:
  main()
