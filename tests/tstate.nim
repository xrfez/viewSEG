## The application state, changed only through `apply` and `drainInbox`,
## on fixture files: open shows the first gather; close takes a file out of
## every view at once and closes it on a job; go to a gather, hover and
## select; commands that do not fit the state warn and change nothing; a
## failed, refused or cancelled open is reported and nothing raises; a slow
## background job does not delay an open; a close waits for the jobs that
## read the file and cannot be cancelled or removed; a removed open does not
## block the file; one file named in several ways opens once; the log keeps
## its bound; and the files are never changed.
##
## Seen to fail: with `adopt` no longer pointing the main panel at the new
## file, `openShowsTheFirstGather` found no layer; with `closeSession` not
## calling `forget`, `closeTakesTheFileAway` still had the closed file's
## trace under the cursor; with the close job cancellable, as it was,
## `closeWaitsForItsReaders` found it cancelled while a reader ran (under
## `nim asan`, a reader holding `filePtr` then read the freed session:
## heap-use-after-free); with `ckRemoveJob` not forgetting the open it
## removed, `removedOpenCanBeOpenedAgain` was told the file "is already being
## opened"; with paths compared as given, `oneFileManySpellings` made 3 opens.
## With `select` not counting a trace a toggle takes out, `selectionCounts`
## found the count one too high at its first toggle. With an agent's
## refused `theme` echoed whole, `themeRefusalsAreShort` found 100 077
## characters in the log line.

import std/[algorithm, monotimes, os, random, strutils, times]
import viewSEG/core/state
import utils/[fixtures, waiting]

var gates: array[4, Gate]

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc lastText(log: MessageLog): string = log[log.len - 1].text

proc openCmd(paths: varargs[string]): Command = Command(kind: ckOpen, paths: @paths)

proc gated(gate: int): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} = gates[gate].waitAt(ctx)

proc jobTitled(st: AppState; title: string): JobInfo =
  for j in st.jobs.list:
    if j.spec.title == title: return j
  raise newException(KeyError, "no job " & title)

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

block selectionCounts:
  # The selection's size is kept as it changes (the plot's menu says it
  # every frame it is open, however many are selected): it is what the
  # set holds after every kind of change.
  var sel = Selection()
  var r = initRand(20261115)
  for round in 0 ..< 2000:
    var traces: seq[int]
    for _ in 0 .. r.rand(5): traces.add r.rand(40)
    case r.rand(9)
    of 0: sel.clear()
    of 1: sel.forget(SessionId(1), r.rand(20) .. r.rand(20) + r.rand(10))
    else: sel.select(traces, SelectMode(r.rand(ord(SelectMode.high))))
    doAssert sel.selectedCount == sel.selected.len, "round " & $round & ": " &
      $sel.selectedCount & " counted, " & $sel.selected.len & " selected"
    doAssert sel.anySelected == (sel.selected.len > 0)

block openShowsTheFirstGather:
  withFixtures fx:
    let path = fx.surveySegy()
    let name = path.extractFilename
    let before = snapshot(path)
    var st = initAppState()
    doAssert st.panels.len == 1 and st.panel(MainPanel).layers.len == 0
    st.apply openCmd(path)
    let job = st.jobTitled("Open " & name)
    doAssert job.spec.lane == jlInteractive and job.spec.reads == @[path]
    doAssert st.settle(st.sessions.len == 1)
    let s = st.sessions[0]
    doAssert s.id == SessionId(1) and s.base == 0
    doAssert s.len == SurveyTraces and s.gathers.len == Shots
    let p = st.panel(MainPanel)
    doAssert p.layers.len == 1
    doAssert p.layers[0].source.kind == lsRecord
    doAssert p.layers[0].source.file == s.id and p.layers[0].source.gather == 0
    doAssert p.layers[0].display.mode == dmWiggle and p.layers[0].display.fills == {wfPositive} and
      p.layers[0].display.colours == pcPaper
    doAssert p.layers[0].filter.seismic and not p.layers[0].filter.auxiliary
    doAssert p.layers[0].pipeline.len == 0
    doAssert p.requestGen > 0
    doAssert st.selection.activeGather == GatherRef(file: s.id, gather: 0)
    doAssert st.log.has("Opened " & name & ": 72 traces in 3 gathers."), st.log.lastText
    doAssert st.log.count(sevWarning) == 0 and st.log.count(sevError) == 0
    # The same file again: nothing new is opened.
    st.apply openCmd(path)
    doAssert st.log.has(name & " is already open.")
    var opens = 0 # (the other job reads its positions for the survey)
    for j in st.jobs.list:
      if j.spec.title.startsWith("Open "): inc opens
    doAssert opens == 1
    st.shutdown()
    doAssert snapshot(path) == before, "opening changed the file"

block gatherHoverSelect:
  withFixtures fx:
    var st = initAppState()
    st.apply openCmd(fx.surveySegy())
    doAssert st.settle(st.sessions.len == 1)
    let file = st.sessions[0].id
    let gen = st.panel(MainPanel).requestGen
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 2)
    doAssert st.panel(MainPanel).layers[0].source.gather == 2
    doAssert st.panel(MainPanel).requestGen > gen
    doAssert st.selection.activeGather == GatherRef(file: file, gather: 2)
    let warnings = st.log.count(sevWarning)
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 3)
    doAssert st.log.lastText.contains("there is no gather 3"), st.log.lastText
    st.apply Command(kind: ckGather, panel: PanelId(9), gather: 0)
    doAssert st.log.lastText.contains("panel 9 does not exist"), st.log.lastText
    doAssert st.log.count(sevWarning) == warnings + 2
    doAssert st.panel(MainPanel).layers[0].source.gather == 2

    let rev = st.selection.revision
    st.apply Command(kind: ckHover, trace: 5)
    doAssert st.selection.hover == 5 and st.selection.revision == rev + 1
    st.apply Command(kind: ckHover, trace: 5)
    doAssert st.selection.revision == rev + 1, "hovering the same trace changed nothing"
    let entries = st.log.len
    st.apply Command(kind: ckHover, trace: 10_000) # of no open file: no hover, and no warning
    doAssert st.selection.hover == -1 and st.log.len == entries, st.log.lastText
    st.apply Command(kind: ckHover, trace: 5)
    st.apply Command(kind: ckHover, trace: -1)
    doAssert st.selection.hover == -1

    template selected(): seq[int] =
      var ids: seq[int]
      for t in st.selection.selected: ids.add t
      ids.sorted
    st.apply Command(kind: ckSelect, traces: @[1, 2, 3], mode: smReplace)
    doAssert selected() == @[1, 2, 3]
    st.apply Command(kind: ckSelect, traces: @[4], mode: smAdd)
    doAssert selected() == @[1, 2, 3, 4]
    st.apply Command(kind: ckSelect, traces: @[2, 5], mode: smToggle)
    doAssert selected() == @[1, 3, 4, 5]
    st.apply Command(kind: ckSelect, traces: @[7, 99_999], mode: smAdd)
    doAssert selected() == @[1, 3, 4, 5, 7]
    doAssert st.log.lastText.contains("1 trace of 2 are in no open file"), st.log.lastText
    st.apply Command(kind: ckClearSelection)
    doAssert st.selection.selected.len == 0

block closeTakesTheFileAway:
  withFixtures fx:
    let survey = fx.surveySegy()
    let segd = fx.twoSetSegd()
    let before = (snapshot(survey), snapshot(segd))
    var st = initAppState()
    st.apply openCmd(survey, segd)
    doAssert st.settle(st.sessions.len == 2)
    let first = st.sessions[st.findSession(SessionId(1))]
    let second = st.sessions[st.findSession(SessionId(2))]
    doAssert second.base == first.len, "trace ids are survey-wide"
    let shown = st.panel(MainPanel).layers[0].source.file
    let other = if shown == first.id: second else: first
    # Select traces of both files, hover one of the file that is not shown.
    st.apply Command(kind: ckSelect, traces: @[first.base, first.base + 1, second.base],
      mode: smReplace)
    st.apply Command(kind: ckHover, trace: other.base)
    st.apply Command(kind: ckClose, file: other.id)
    doAssert st.sessions.len == 1 and st.findSession(other.id) < 0, "close is immediate"
    doAssert st.selection.hover == -1
    for t in st.selection.selected:
      doAssert t notin other.traceIds, "a closed file's trace is still selected"
    doAssert st.selection.selected.len > 0
    doAssert st.panel(MainPanel).layers.len == 1, "the shown file stays"
    # Closing the file on show empties the panel.
    st.apply Command(kind: ckClose, file: shown)
    doAssert st.sessions.len == 0
    doAssert st.panel(MainPanel).layers.len == 0
    doAssert st.selection.activeGather.file == NoSession
    doAssert st.selection.selected.len == 0
    doAssert st.settle(st.log.has("Closed " & survey.extractFilename & ".") and
      st.log.has("Closed " & segd.extractFilename & "."))
    st.apply Command(kind: ckClose, file: shown)
    doAssert st.log.lastText.contains("is not open"), st.log.lastText
    st.shutdown()
    doAssert (snapshot(survey), snapshot(segd)) == before, "closing changed a file"

block failedOpensAreReported:
  withFixtures fx:
    var st = initAppState()
    let missing = fx.dir / "no-such-file.sgy"
    st.apply openCmd(missing)
    doAssert st.settle(st.log.has("Cannot open " & missing, sevError))
    let text = fx.dir / "notes.sgy"
    writeFile(text, "These are not seismic data.\n".repeat(200))
    st.apply openCmd(text)
    doAssert st.settle(st.log.has("is not a SEG-Y, SEG-D or SEG-2 file", sevError))
    doAssert st.sessions.len == 0
    doAssert st.panel(MainPanel).layers.len == 0
    st.apply openCmd()
    doAssert st.log.lastText.contains("no file was named")
    doAssert st.jobTitled("Open no-such-file.sgy").state == jsFailed

block cancelReorderRemoveThroughCommands:
  withFixtures fx:
    let path = fx.surveySegy()
    let name = path.extractFilename
    var st = initAppState()
    # A job that holds the file to itself keeps the open queued behind it.
    let holder = st.jobs.submit(JobSpec(title: "Hold the file", lane: jlInteractive,
      exclusive: @[path]), gated(0))
    doAssert waitUntil(st.jobs.info(holder).get.state == jsRunning)
    st.apply openCmd(path)
    let opening = st.jobTitled("Open " & name).id
    doAssert st.jobs.info(opening).get.state == jsQueued
    st.apply openCmd(path)
    doAssert st.log.has(name & " is already being opened.")
    st.apply Command(kind: ckReorderJob, reordered: opening, position: 0)
    doAssert st.log.count(sevWarning) == 0
    st.apply Command(kind: ckRemoveJob, job: holder)
    doAssert st.log.lastText.contains("is running; cancel it first"), st.log.lastText
    st.apply Command(kind: ckCancelJob, job: opening)
    doAssert st.settle(st.log.has("Opening " & name & " was cancelled."))
    st.apply Command(kind: ckCancelJob, job: opening)
    doAssert st.log.lastText.contains("has finished"), st.log.lastText
    st.apply Command(kind: ckReorderJob, reordered: opening, position: 0)
    doAssert st.log.lastText.contains("is not queued"), st.log.lastText
    st.apply Command(kind: ckCancelJob, job: holder)
    doAssert st.settle(st.log.has("Hold the file was cancelled."))
    st.apply Command(kind: ckRemoveJob, job: opening)
    doAssert st.jobs.info(opening).isNone
    st.apply Command(kind: ckRemoveJob, job: opening)
    doAssert st.log.lastText.contains("is not listed"), st.log.lastText
    doAssert st.sessions.len == 0

block backgroundDoesNotDelayOpen:
  withFixtures fx:
    let path = fx.surveySegy()
    var st = initAppState()
    let scan = st.jobs.submit(JobSpec(title: "Scan the folder", lane: jlBackground,
      reads: @[path]), gated(1))
    doAssert waitUntil(st.jobs.info(scan).get.state == jsRunning)
    st.apply openCmd(path) # reads the same file: reading is shared
    doAssert st.settle(st.sessions.len == 1)
    doAssert st.jobs.info(scan).get.state == jsRunning
    gates[1].open()
    doAssert st.settle(st.log.has("Scan the folder is done."))

proc stubborn(gate: int): JobWork =
  ## A reader in the middle of a chunk: it stops only when its gate opens,
  ## whatever cancel was asked for meanwhile.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let deadline = getMonoTime() + Patience * 2
    while not gates[gate].isOpen and getMonoTime() < deadline: sleep 1

block closeWaitsForItsReaders:
  # The file is released only once no job reads it, so the close job cannot
  # be cancelled or removed: a reader still running would read freed memory.
  withFixtures fx:
    let path = fx.surveySegy()
    let name = path.extractFilename
    var st = initAppState()
    st.apply openCmd(path)
    doAssert st.settle(st.sessions.len == 1)
    let reader = st.jobs.submit(JobSpec(title: "QC pass", lane: jlBackground,
      reads: @[path]), stubborn(2))
    doAssert waitUntil(st.jobs.info(reader).get.state == jsRunning)
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.jobs.info(reader).get.cancelRequested, "the close did not stop the reader"
    let close = st.jobTitled("Close " & name)
    doAssert close.state == jsQueued
    st.apply Command(kind: ckCancelJob, job: close.id)
    doAssert st.log.lastText.contains("cannot be cancelled"), st.log.lastText
    st.apply Command(kind: ckRemoveJob, job: close.id)
    doAssert st.log.lastText.contains("cannot be removed"), st.log.lastText
    discard st.drainInbox()
    doAssert st.jobs.info(close.id).get.state == jsQueued
    doAssert not st.log.has("Closed " & name & "."), "closed while a job read the file"
    gates[2].open()
    doAssert st.settle(st.log.has("Closed " & name & "."))

block removedOpenCanBeOpenedAgain:
  withFixtures fx:
    let path = fx.surveySegy()
    let name = path.extractFilename
    var st = initAppState()
    let holder = st.jobs.submit(JobSpec(title: "Hold the file", lane: jlInteractive,
      exclusive: @[path]), gated(3))
    doAssert waitUntil(st.jobs.info(holder).get.state == jsRunning)
    st.apply openCmd(path)
    st.apply Command(kind: ckRemoveJob, job: st.jobTitled("Open " & name).id)
    doAssert st.log.has("Opening " & name & " was cancelled.")
    st.apply openCmd(path)
    doAssert not st.log.lastText.contains("already being opened"), st.log.lastText
    gates[3].open()
    doAssert st.settle(st.sessions.len == 1)

block oneFileManySpellings:
  withFixtures fx:
    let path = fx.surveySegy()
    let name = path.extractFilename
    var st = initAppState()
    st.apply openCmd(path, fx.dir & "/./" & name, relativePath(path, getCurrentDir()))
    doAssert st.jobs.list.len == 1, $st.jobs.list.len & " opens of one file"
    doAssert st.settle(st.sessions.len == 1)
    st.apply openCmd(fx.dir & "/sub/../" & name)
    doAssert st.log.lastText == name & " is already open.", st.log.lastText
    doAssert st.sessions[0].path == path

block logKeepsItsBound:
  var st = initAppState(logCapacity = 3)
  for i in 1 .. 5:
    st.apply Command(kind: ckClose, file: SessionId(i))
  doAssert st.log.len == 3 and st.log.dropped == 2
  doAssert st.log.lastText.contains("file 5 is not open")

block shutdownCancelsEverything:
  withFixtures fx:
    let path = fx.surveySegy()
    gates[0].close()
    var st = initAppState()
    let holder = st.jobs.submit(JobSpec(title: "Hold the file", lane: jlInteractive,
      exclusive: @[path]), gated(0))
    doAssert waitUntil(st.jobs.info(holder).get.state == jsRunning)
    st.apply openCmd(path)
    st.shutdown()
    doAssert st.jobs.info(holder).get.state == jsCancelled
    doAssert st.jobTitled("Open " & path.extractFilename).state == jsCancelled
    discard st.drainInbox()
    doAssert st.log.has("Opening " & path.extractFilename & " was cancelled.")
    doAssert st.sessions.len == 0

block themeRefusalsAreShort:
  # An agent's `theme` that is refused is named in the log in short: not
  # 100 000 characters of it.
  var st = initAppState()
  let warnings = st.log.count(sevWarning)
  st.apply Command(origin: coAgent, kind: ckTheme, theme: repeat("../x", 25_000))
  doAssert st.log.count(sevWarning) == warnings + 1
  doAssert st.log.lastText.len < 200, $st.log.lastText.len & " characters"
  doAssert st.settings.theme == ""
  st.offerThemes(@["nord"])
  st.apply Command(origin: coAgent, kind: ckTheme, theme: "nope")
  doAssert st.log.lastText.contains("nord") and st.log.lastText.len < 200, st.log.lastText
  st.apply Command(origin: coAgent, kind: ckTheme, theme: "nord")
  doAssert st.settings.theme == "nord"
  st.shutdown()
