## What the Messages window asks of `core`: a message that names a trace
## shows that trace's gather in the plot, the trace selected, whether its
## file is open or must be opened again first (and the open does not lose
## the request); a trace the file does not have is a warning; Export writes
## every message, one line each, off the UI thread (a full log holds no
## frame); the Messages window's toggles are settings and survive a restart.
##
## Seen to fail: with `adopt` not taking up the pending jump, `closedFile`
## found the first gather shown and nothing selected; with `gatherOf` off
## by one at a gather's last trace, `openFile` showed gather 0 for trace 47;
## with the export writing only the newest entry, `exported` found one line;
## with the lines made on the UI thread (`fileLine` in `apply`),
## `exportHoldsNoFrame` found the export holding the frame 88 ms.
##
## Runs alone: it bounds the time the export holds the frame (30 ms).

import std/[monotimes, os, strutils, times]
import viewSEG/core/[persist, state]
import utils/[fixtures, owntime, waiting]

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc shownGather(st: AppState): (string, int) =
  let k = st.findPanel(MainPanel)
  let i = st.shownFile(k)
  if i < 0: ("", -1) else: (st.sessions[i].path, st.panels[k].layers[0].source.gather)

proc selected(st: AppState): seq[int] =
  for t in st.selection.selected: result.add t

block openFile:
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.shownGather == (path, 0))
    # Trace 47 is the last of the second shot (24 a shot).
    st.apply Command(kind: ckShowTrace, panel: MainPanel, path: path,
      traceIndex: 2 * Channels - 1)
    doAssert st.shownGather == (path, 1), $st.shownGather
    doAssert st.selected == @[st.sessions[0].base + 2 * Channels - 1], $st.selected
    st.apply Command(kind: ckShowTrace, panel: MainPanel, path: path, traceIndex: Channels)
    doAssert st.shownGather == (path, 1) and st.selected == @[st.sessions[0].base + Channels]
    st.apply Command(kind: ckShowTrace, panel: MainPanel, path: path, traceIndex: 0)
    doAssert st.shownGather == (path, 0)
    st.apply Command(kind: ckShowTrace, panel: MainPanel, path: path,
      traceIndex: SurveyTraces + 5)
    doAssert st.log.has("has no trace " & $(SurveyTraces + 5), sevWarning)
    st.apply Command(kind: ckShowTrace, panel: MainPanel, path: "", traceIndex: 3)
    doAssert st.log.has("no trace was named", sevWarning)
    st.shutdown()

block closedFile:
  # The file a message names was stepped away from: it opens again, then
  # the trace is shown.
  withFixtures fx:
    let survey = fx.surveySegy()
    let other = fx.twoSetSegd()
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: survey)
    doAssert st.settle(st.shownGather[0] == survey)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.shownGather[0] == other and st.sessions.len == 1)
    st.apply Command(kind: ckShowTrace, panel: MainPanel, path: survey, traceIndex: 60)
    doAssert st.settle(st.shownGather == (survey, 2)), $st.shownGather
    let i = st.shownFile(st.findPanel(MainPanel))
    doAssert st.selected == @[st.sessions[i].base + 60], $st.selected
    # A request left pending is forgotten when the user chooses another file.
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.shownGather == (other, 0))
    st.shutdown()

block exported:
  withFixtures fx:
    var st = initAppState()
    for i in 1 .. 5: st.report(sevWarning, "test", "warning number " & $i)
    let path = fx.dir / "messages.log"
    st.apply Command(kind: ckExportLog, docPath: path)
    st.flushFiles()
    doAssert st.settle(st.log.has("Messages exported to " & path))
    let text = readFile(path)
    var lines = 0
    for l in text.splitLines:
      if "warning number" in l: inc lines
    doAssert lines == 5, text
    st.apply Command(kind: ckExportLog, docPath: "")
    doAssert st.log.has("no file was named", sevWarning)
    st.shutdown()

block exportHoldsNoFrame:
  # A full log (10 000 messages) is exported without holding the frame: the
  # disk thread makes the lines, a few microseconds each for the local time.
  withFixtures fx:
    var st = initAppState()
    for i in 1 .. DefaultLogCapacity: st.report(sevWarning, "test", "warning number " & $i)
    let path = fx.dir / "full.log"
    let t0 = ownTime()
    st.apply Command(kind: ckExportLog, docPath: path)
    let took = ownTime() - t0
    doAssert took < initDuration(milliseconds = 30), "the export held the frame " &
      $took.inMilliseconds & " ms"
    st.flushFiles()
    doAssert st.settle(st.log.has("Messages exported to " & path))
    doAssert readFile(path).countLines >= DefaultLogCapacity
    st.shutdown()

block togglesAreSettings:
  withFixtures fx:
    let dir = fx.dir / "config"
    createDir(dir)
    block first:
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
      var s = st.settings
      doAssert s.messages.autoScroll and s.messages.hidden == {}
      s.messages = MessagesView(autoScroll: false, hidden: {sevInfo})
      st.apply Command(kind: ckSettings, settings: s)
      st.shutdown()
    var st = initAppState()
    st.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
    doAssert not st.settings.messages.autoScroll and st.settings.messages.hidden == {sevInfo}
    st.shutdown()
