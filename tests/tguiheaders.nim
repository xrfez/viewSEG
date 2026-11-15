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
## header's bytes.
##
## The Trace tab (SEG-Y): empty until a trace is chosen; the trace under the
## pointer in the plot, kept when the pointer goes to the Headers window; a
## click selects a trace: its header fields in Header, its samples in Data,
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
## types that differ are not marked").
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves headers-*.png there, and, with the
## example files present (local only), each tab of a SEG-Y and a SEG-D
## example (headers-inglewood-*.png, headers-morgantown-*.png), the Headers
## window made larger by dragging its splitters.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[faultyfs, fixtures]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

func shown(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

let shots = getEnv("VIEWSEG_SCREENSHOTS")
if shots.len > 0: createDir(shots)

proc shoot(f: FrameInfo; name: string) =
  if shots.len > 0:
    doAssert f.savePng(shots / name), "cannot save " & name
    echo "tguiheaders: saved ", shots / name

type Step = proc (f: FrameInfo; wait: int): bool {.closure.}
  ## One step of a run: true once it is done; it asserts what must hold.

proc runSteps(path: string; steps: openArray[(string, Step)]; cache: string) =
  ## Shows `path` and takes `steps` one after another, each given up to 400
  ## frames.
  var stage = 0
  var wait = 0
  var reached: seq[string]
  let all = @steps
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if stage < all.len:
      if all[stage][1](f, wait):
        reached.add all[stage][0]
        inc stage
        wait = 0
      else: doAssert wait < 400, "stopped at \"" & all[stage][0] & "\" after " & $reached
    else: f.stop()
  let code = run(RunOptions(maxFrames: 4000, openPaths: @[path], windowSize: (1600, 1000),
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
      if wait == 300: doAssert false, "the record's general headers never came"
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
        f.shoot("headers-trace-two-segy.png"))),
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

# Screenshots of each tab on the example files (local only).
const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

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

proc tabShot(name, mark, file: string): (string, Step) =
  ## A click on the tab `mark`, then a screenshot as `file` once `name`'s
  ## content shows.
  (name, Step(proc (f: FrameInfo; wait: int): bool =
    f.click(wait, mark)
    result = wait > 20 and not f.core.inspection.waiting
    if result: f.shoot(file)))

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

if shots.len > 0 and dirExists(examples):
  withFixtures fx:
    for (example, name, segd) in [("BO_3D-Inglewood_rev21_v7.sgy", "inglewood", false),
        ("00000151_12900_11300.sgd", "morgantown", true)]:
      let path = examples / example
      if fileExists(path):
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
        runSteps(path, steps, fx.dir / "cache")
