## The click that brings a window forward does only that, in the running
## frontend, headless, with real clicks: in the Seismic window it selects
## no trace, in the Records window it shows no other record, in the Files
## window it shows no other file, in the Messages window a line naming a
## trace of another file shows no other file; the next click in the same
## window does.
##
## Seen to fail: with the plot's click selecting whatever the focus (as it
## did), "a focusing click selected {5}"; with the Records rows acting on any
## click, "a focusing click showed record 2"; with the Files rows acting on
## any click, "a focusing click showed long-spread.sgy"; with the Messages
## lines acting on any click (as they did), "a focusing click in Messages
## showed survey-clean.sgy".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, options, os, strutils, times]
import viewSEG/core/[geometry, log]
import viewSEG/core/state {.all.}
import viewSEG/ui/imgui/app
import utils/fixtures

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

withFixtures fx:
  let path = fx.surveySegy()
  discard fx.longSpreadSegy() # a second file in the folder
  var steps: seq[Step]
  var at = 0
  var started = false
  var wait = 0
  var failed = ""
  var trace: Vec2
  template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc click(f: FrameInfo; at: Vec2) =
    f.pressMouse(at, true)
    f.pressMouse(at, false)
  proc clickSteps(name, mark: string; done: proc (f: FrameInfo): bool) =
    ## Move to `mark`, then click it.
    step("to " & name, proc (f: FrameInfo) = f.moveMouse(f.markOf(mark).centre),
      proc (f: FrameInfo): bool = wait > 3)
    step(name, proc (f: FrameInfo) = f.click(f.markOf(mark).centre), done)
  proc shownFile(f: FrameInfo): string =
    let s = f.core.findSession(f.panel.layers[0].source.file)
    if s >= 0: f.core.sessions[s].path.extractFilename else: ""

  step("the file is shown", proc (f: FrameInfo) = f.moveMouse(vec2(4, 4)),
    proc (f: FrameInfo): bool =
    result = f.panel.laidOut and f.markOf("files.row long-spread.sgy").size.x > 0 and
      f.markOf("records.row 1").size.x > 0 and wait > 10
    if result:
      let r = f.markOf("plot.data")
      trace = vec2(round(r.pos.x + r.size.x * 5.5 / 25), round(r.pos.y + r.size.y / 2)))
  # the Files window has the focus: the plot does not
  clickSteps("the Files window's foot", "files.footer", proc (f: FrameInfo): bool = wait > 3)
  step("to a trace", proc (f: FrameInfo) = f.moveMouse(trace),
    proc (f: FrameInfo): bool = wait > 3)
  step("a focusing click in the plot", proc (f: FrameInfo) = f.click(trace),
    proc (f: FrameInfo): bool =
    result = wait > 6
    if result:
      doAssert f.core.selection.selected.len == 0, "a focusing click selected " &
        $f.core.selection.selected)
  step("the next click selects", proc (f: FrameInfo) = f.click(trace),
    proc (f: FrameInfo): bool = f.core.selection.selected.len == 1)
  # the plot has the focus: the Records window does not
  clickSteps("a focusing click in Records", "records.row 1", proc (f: FrameInfo): bool =
    result = wait > 6
    if result:
      doAssert f.panel.layers[0].source.gather == 0, "a focusing click showed record " &
        $(f.panel.layers[0].source.gather + 1))
  step("the next click shows record 2", proc (f: FrameInfo) =
    f.click(f.markOf("records.row 1").centre), proc (f: FrameInfo): bool =
      f.panel.layers[0].source.gather == 1)
  # the Records window has the focus: the Files window does not
  clickSteps("a focusing click in Files", "files.row long-spread.sgy",
    proc (f: FrameInfo): bool =
    result = wait > 6
    if result:
      doAssert f.shownFile == "survey-clean.sgy" or f.shownFile.startsWith("survey"),
        "a focusing click showed " & f.shownFile)
  step("the next click shows it", proc (f: FrameInfo) =
    f.click(f.markOf("files.row long-spread.sgy").centre), proc (f: FrameInfo): bool =
      f.shownFile == "long-spread.sgy")
  # the Files window has the focus: the Messages window does not
  step("a message naming a trace", proc (f: FrameInfo) =
    f.core.mailbox.post(Msg(kind: mkLog, entry: LogEntry(time: getTime(),
      severity: sevWarning, source: "test", text: "A warning about trace 7",
      loc: Location(file: path, trace: 7)))), proc (f: FrameInfo): bool =
      f.markOf("messages.last").size.x > 0 and wait > 3)
  clickSteps("a focusing click in Messages", "messages.last", proc (f: FrameInfo): bool =
    result = wait > 6
    if result:
      doAssert f.shownFile == "long-spread.sgy", "a focusing click in Messages showed " &
        f.shownFile)
  step("the next click shows its trace", proc (f: FrameInfo) =
    f.click(f.markOf("messages.last").centre), proc (f: FrameInfo): bool =
      f.shownFile == path.extractFilename and f.core.selection.selected.len == 1)

  proc onFrame(f: FrameInfo) =
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      started = true
      wait = 0
    else:
      inc wait
      if wait >= 2 and steps[at].done(f):
        inc at
        started = false
      elif wait > 400:
        failed = steps[at].name & " did not happen"
        f.stop()

  let code = run(RunOptions(maxFrames: 4000, openPaths: @[path], windowSize: (1280, 900),
    theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
  echo "tguifocus: ", steps.len, " steps"
