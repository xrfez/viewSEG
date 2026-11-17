## Edits to traces: killing and reversing the polarity of single traces,
## their undo and their clearing, in `core` (`core/edits`, and `ckEdit`,
## `ckUndoEdit`, `ckClearEdits` on a panel whose reader runs):
##
## - the lists: a change gives or takes an edit from traces and keeps what
##   it changed for the undo, a trace given twice changes once, a change of
##   nothing makes no step, undo goes back step by step and redo forward
##   again, a new change drops what was undone, clearing and reversing all
##   are steps too, each in words; what is kept (the user's) and what is
##   shown (an agent's too) part and meet as the steps say;
## - a killed trace's row of the tile is zero and the tile says so; the
##   panel's level is taken again without it (the spike planted in it no
##   longer sets the peak), and so are the Float gain's level of the data
##   in view and the Normalized gain's reference for the whole gather; the
##   readout says "killed";
## - a reversed trace's row is what processSEG's `polarityOp` makes of the
##   file's own samples of that trace (read with parseSEG), the other rows
##   as the file has them; the readout says "polarity reversed" and reads
##   the negated amplitude;
## - an edit on the view on screen reads nothing from the file (the tile is
##   made from the samples the reader holds); the tiles from before stay
##   drawn until the new one comes, then go;
## - undo, the selection, clear all and its undo;
## - the edits hold through another record, a sort, a gain change and a
##   step to another file and back (the file opened again, under a new id);
## - commands that do not fit are ignored with a warning;
## - what the screen asks of the lists every frame or view does not grow
##   with the traces edited elsewhere in the file;
## - a trace marked dead in the file is blank under every gain, reversed or
##   not, and the status bar says "dead";
## - the user's own change of traces an agent changed says what is kept of
##   each; the history holds at most `MaxHeldTraces` traces; the Edit menu's
##   words and a step to another record copy no step and no history;
## - the file is never changed.
##
## Seen to fail: with the reader not blanking killed rows (`prepare`
## without its zeroing), "trace 15's row is not blank: 100.0"; with the
## killed rows not left out of the tile's level, "the level's RMS is
## 0.2076..., the other traces' 0.2121..."; with `relevel` not looked at in
## `drainInbox`, "the panel's level peak is 100.0 after the kill"; with
## `valuesInView` counting killed rows, "the Float level's RMS 0.2076...";
## with `make` leaving the steps undone (`redos`), "a new change drops what
## was undone"; with `undo` making its step on what is kept whatever
## `keep` says, "an agent's undo reached what is kept";
## with the reversal left out of `prepare`, "trace 8 sample 66: 0.117537394
## in the tile, polarityOp gives -0.117537394"; with the samples held never
## used, "the tile after the kill was read from the file"; with the lists kept as `IntSet`s (every query walking
## them), "a frame's questions to the lists take 4987.1 µs with 200 000
## traces edited elsewhere"; with the dead trace drawn as recorded under
## None (the blanking only when something runs on the samples), "under
## None the dead-marked trace is drawn"; with a step's change of what is
## kept taken as its change of what is shown (`keptChanges` not called),
## "the user's kill of the selection is kept without the agent's trace:
## @[3, 4, 6, 7]", and in `clearAll`, "the user's clear left what is kept";
## with the history bounded by its steps alone, "24000000 traces held in 12
## steps"; with the Edit menu's words made from a copy of the step (`^1`, as
## `nextUndo` does), "the Edit menu's words take 4904.85 µs a frame"; with
## `show` asking the file's edits through `getOrDefault` (a copy of the
## lists and the history), "a step to another record allocates 4158 times
## more with a history of a thousand steps (24 with none)".
##
## Runs alone: it bounds the time a frame's questions to the lists take (50 µs).

import std/[algorithm, math, monotimes, os, sequtils, strutils, times]
import parseSEG
import processSEG/[adapters, pipeline]
import processSEG/core/workspace
import viewSEG/core/state
import utils/[fixtures, waiting]

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and p.pending.gen == p.requestGen and st.tiles(0).len > 0 and
    st.tiles(0)[^1].request == p.pending

proc edit(st: var AppState; edit: TraceEdit; traces: seq[int]; on = true) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: edit, edited: traces, on: on)

proc rowOf(t: Tile; trace: int): seq[float32] =
  ## The tile's values of the trace with index `trace` in its file.
  let r = t.traces.find(trace)
  doAssert r >= 0, "trace " & $(trace + 1) & " is not in the tile"
  t.data[r * t.columns ..< (r + 1) * t.columns]

func blank(v: openArray[float32]): bool =
  for x in v:
    if x != 0: return false
  true

proc warnings(st: AppState): int =
  for e in st.log:
    if e.severity == sevWarning: inc result

proc last(st: AppState): string =
  for e in st.log: result = e.text

proc display(st: var AppState; d: DisplaySettings) =
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

proc deadMarkedSegy(dir: string): string =
  ## The survey's first shot with channel 5 marked dead in the file, its
  ## samples as they were.
  result = dir / "dead-marked.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    text: @["C01 viewSEG test: a trace marked dead that holds samples"]))
  var buf = newSeq[float32](Samples)
  for channel in 1 .. Channels:
    var k = initTraceKeys()
    (k.record, k.channel, k.srcPoint) = (11.0, float64(channel), FirstSrcPoint)
    (k.rcvLine, k.rcvPoint) = (RcvLine, FirstRcvPoint + float64(channel - 1))
    (k.t0Ms, k.intervalUs) = (0.0, DtMs * 1000)
    k.status = if channel == 5: tsDead else: tsLive
    for i in 0 ..< Samples: buf[i] = surveySample(0, channel, i)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0

proc main*() =

  block lists:
    var e: FileEdits
    doAssert e.isEmpty and not e.canUndo and not e.canRedo and e.nextUndo.kind == skNone
    doAssert e.change(teKilled, [3, 5, 3], true) == 2
    doAssert e.has(teKilled, 3) and e.has(teKilled, 5) and e.len(teKilled) == 2
    doAssert e.nextUndo.kind == skChange and e.nextUndo.traces == @[3, 5] and e.nextUndo.on
    doAssert describe(e.nextUndo) == "2 traces killed"
    doAssert e.change(teKilled, [5, 7], true) == 1 # 5 was killed already
    doAssert e.nextUndo.traces == @[7] and describe(e.nextUndo) == "trace 8 killed"
    doAssert e.change(teKilled, [5], true) == 0
    doAssert e.nextUndo.traces == @[7] and e.steps.undos == 2, "a change of nothing made a step"
    let r = e.revision
    let undone = e.undo()
    doAssert undone.kind == skChange and undone.traces == @[7] and not e.has(teKilled, 7)
    doAssert e.revision > r and e.canUndo and e.canRedo
    doAssert describe(e.nextRedo) == "trace 8 killed" and describe(e.nextUndo) == "2 traces killed"
    doAssert e.redo().traces == @[7] and e.has(teKilled, 7) and not e.canRedo
    discard e.undo()
    discard e.undo()
    doAssert e.isEmpty and not e.canUndo and e.steps.redos == 2
    doAssert e.undo().kind == skNone and e.isEmpty, "an undo of nothing changed the edits"
    discard e.redo()
    doAssert e.len(teKilled) == 2 and e.steps == (1, 1)
    doAssert e.change(teReversed, [4], true) == 1
    doAssert not e.canRedo, "a new change drops what was undone"
    doAssert describe(e.nextUndo) == "polarity of trace 5 reversed"
    doAssert e.change(teReversed, [3], true) == 1
    doAssert e.editsOf(3) == {teKilled, teReversed} and e.editsOf(4) == {teReversed}
    doAssert e.editsOf(6) == {}
    doAssert e.change(teReversed, [4], false) == 1
    doAssert describe(e.nextUndo) == "polarity of trace 5 put back"
    doAssert e.change(teKilled, [5], false) == 1 and describe(e.nextUndo) == "trace 6 restored"
    doAssert e.listIn(teKilled, 0 .. 10) == @[3] and e.listIn(teReversed, 4 .. 10) == @[]
    doAssert e.anyIn(3 .. 3) and not e.anyIn(4 .. 10)
    doAssert e.nextUndo.changedIn(5 .. 5) and not e.nextUndo.changedIn(0 .. 4)
    doAssert e.nextUndo.touches(teKilled) and not e.nextUndo.touches(teReversed)
    block all:
      doAssert e.setAllReversed(true) and e.allReversed and not e.setAllReversed(true)
      doAssert describe(e.nextUndo) == "polarity of all traces reversed"
      doAssert e.nextUndo.changedIn(100 .. 100) and not e.nextUndo.touches(teKilled)
      discard e.undo()
      doAssert not e.allReversed
      discard e.redo()
      doAssert e.allReversed and e.kept.allReversed
    doAssert e.clearAll() and e.isEmpty and not e.allReversed
    doAssert describe(e.nextUndo) == "all edits cleared"
    doAssert e.nextUndo.touches(teKilled) and e.nextUndo.touches(teReversed) and
      e.nextUndo.changedIn(3 .. 3)
    doAssert not e.clearAll(), "a clear of nothing"
    discard e.undo()
    doAssert e.editsOf(3) == {teKilled, teReversed} and e.len(teKilled) == 1 and e.allReversed
    doAssertRaises ValueError: discard e.change(teKilled, [-1], true)

  block history:
    # at most MaxSteps steps, the oldest dropped
    var e: FileEdits
    for t in 0 .. MaxSteps + 9: discard e.change(teKilled, [t], true)
    doAssert e.steps.undos == MaxSteps
    var n = 0
    while e.canUndo:
      discard e.undo()
      inc n
    doAssert n == MaxSteps and e.len(teKilled) == 10, $e.len(teKilled)

  block keptAndShown:
    # A change an agent makes (`keep = false`) is shown, not kept; the user's
    # is both. An agent's undo of the user's step is shown only; the user's
    # undo or redo of an agent's step reaches what is kept as shown.
    var e: FileEdits
    doAssert e.change(teKilled, [1, 2], true) == 2 # the user
    doAssert e.kept.lists[teKilled] == @[1, 2] and e.keptRevision == 1
    doAssert e.change(teKilled, [8], true, keep = false) == 1 # an agent
    doAssert e.has(teKilled, 8) and e.kept.lists[teKilled] == @[1, 2] and e.keptRevision == 1
    doAssert e.setAllReversed(true, keep = false) and not e.kept.allReversed
    discard e.undo(keep = false) # the agent takes back its own two
    discard e.undo(keep = false)
    discard e.undo(keep = false) # and the user's kill, for the session only
    doAssert e.isEmpty and e.kept.lists[teKilled] == @[1, 2], "an agent's undo reached what is kept"
    discard e.redo() # the user makes the kill of 1 and 2 again: as it was
    discard e.redo() # and the agent's kill of 8, now the user's own action
    doAssert e.kept.lists[teKilled] == @[1, 2, 8] and not e.kept.allReversed
    doAssert e.clearAll(keep = false) and e.kept.lists[teKilled] == @[1, 2, 8]
    discard e.undo(keep = false)
    doAssert e.clearAll() and e.kept.isEmpty
    discard e.undo()
    doAssert e.kept.lists[teKilled] == @[1, 2, 8]

  block userOverAgent:
    # Where an agent's change made what is shown and what is kept differ, the
    # user's own change says what is kept, for every trace it names.
    block selection: # the user kills a selection that holds a trace an agent killed
      var e: FileEdits
      discard e.change(teKilled, [5], true, keep = false)
      doAssert e.change(teKilled, [3, 4, 5, 6, 7], true) == 4
      doAssert e.kept.lists[teKilled] == @[3, 4, 5, 6, 7],
        "the user's kill of the selection is kept without the agent's trace: " &
        $e.kept.lists[teKilled]
      discard e.undo()
      doAssert e.kept.isEmpty and e.shown.lists[teKilled] == @[5], "the undo is not as before"
      discard e.redo()
      doAssert e.kept.lists[teKilled] == @[3, 4, 5, 6, 7]
    block onlyKept: # the user kills the one trace an agent killed: no change shown
      var e: FileEdits
      discard e.change(teKilled, [5], true, keep = false)
      doAssert e.change(teKilled, [5], true) == 1 and e.kept.lists[teKilled] == @[5]
    block clear: # the user clears all after an agent's undo hid the user's kill
      var e: FileEdits
      discard e.change(teKilled, [5], true)
      discard e.setAllReversed(true)
      discard e.undo(keep = false)
      discard e.undo(keep = false)
      doAssert e.isEmpty and e.kept.lists[teKilled] == @[5] and e.kept.allReversed
      doAssert e.clearAll(), "nothing to clear for the user"
      doAssert e.kept.isEmpty, "the user's clear left what is kept: " & $e.kept
      discard e.undo()
      doAssert e.kept.lists[teKilled] == @[5] and e.kept.allReversed and e.isEmpty
    block allReversed: # the user reverses all after an agent put it back
      var e: FileEdits
      discard e.setAllReversed(true, keep = false)
      discard e.setAllReversed(false) # the user puts it back: nothing kept
      doAssert not e.kept.allReversed
      discard e.setAllReversed(true) # the user's own
      doAssert e.kept.allReversed and e.allReversed
    block imported: # the user imports a list with a trace an agent killed
      var e: FileEdits
      discard e.change(teKilled, [5], true, keep = false)
      var l: EditLists
      l.lists[teKilled] = @[5, 6]
      doAssert e.takeIn(l, "list.csv") == 1
      doAssert e.kept.lists[teKilled] == @[5, 6], "the import is kept without the agent's trace"
      var f: FileEdits
      discard f.change(teKilled, [5], true, keep = false)
      l.lists[teKilled] = @[5]
      doAssert f.takeIn(l, "list.csv") == 1 and f.kept.lists[teKilled] == @[5]
      doAssert describe(f.nextUndo) == "1 edit imported from list.csv", describe(f.nextUndo)

  block heldBound:
    # The history holds at most `MaxHeldTraces` traces all told: a selection
    # of a million traces killed and restored again and again drops the
    # oldest steps, never the newest.
    var e: FileEdits
    var all = newSeq[int](1_000_000)
    for i, t in all.mpairs: t = i
    for k in 0 ..< 12: doAssert e.change(teKilled, all, k mod 2 == 0) == all.len
    doAssert e.held <= MaxHeldTraces and e.steps.undos in 2 ..< 12,
      $e.held & " traces held in " & $e.steps.undos & " steps"
    doAssert e.len(teKilled) == 0
    discard e.undo()
    doAssert e.len(teKilled) == all.len
    doAssert e.change(teKilled, [1], false) == 1 # drops the step undone
    var held = 0
    while e.canUndo:
      discard e.undo()
      inc held
    doAssert held == e.steps.redos and e.held <= MaxHeldTraces

  block menuWords:
    # What the Edit menu asks every frame (the newest step in words) does not
    # copy the step: a change of a million traces.
    var e: FileEdits
    var all = newSeq[int](1_000_000)
    for i, t in all.mpairs: t = i
    discard e.change(teKilled, all, true)
    discard e.change(teReversed, all, true)
    discard e.undo()
    const calls = 50
    let start = getMonoTime()
    var n = 0
    for i in 0 ..< calls: n += e.undoText.len + e.redoText.len
    let us = float64((getMonoTime() - start).inNanoseconds) / 1000 / calls
    doAssert n == calls * ("1000000 traces killed".len + "polarity of 1000000 traces reversed".len)
    doAssert us < 50, "the Edit menu's words take " & $us & " µs a frame"

  block takeInAndRemembered:
    var e: FileEdits
    discard e.change(teKilled, [4], true)
    var l: EditLists
    l.lists[teKilled] = @[4, 6]
    l.lists[teReversed] = @[1]
    l.allReversed = true
    doAssert e.takeIn(l, "list.csv") == 3 # 4 was killed already
    doAssert describe(e.nextUndo) == "3 edits imported from list.csv"
    doAssert e.listIn(teKilled, 0 .. 9) == @[4, 6] and e.allReversed and e.kept.allReversed
    discard e.undo()
    doAssert e.listIn(teKilled, 0 .. 9) == @[4] and not e.allReversed and e.len(teReversed) == 0
    var f: FileEdits
    discard f.change(teKilled, [9], true)
    f.remembered(l)
    doAssert f.listIn(teKilled, 0 .. 9) == @[4, 6, 9] and f.kept.lists[teKilled] == @[4, 6, 9]
    doAssert f.steps.undos == 1, "what is remembered is no step"
    f.forget()
    doAssert f.isEmpty and f.kept.isEmpty and not f.canUndo

  block merged:
    # one file's edits made under two paths: each list the union, the
    # history of both (each step undone as before)
    var a, b: FileEdits
    discard a.change(teKilled, [3, 5], on = true)
    discard b.change(teKilled, [5, 9], on = true)
    discard b.change(teReversed, [2], on = true, keep = false)
    a.merge(b)
    doAssert a.shown.lists[teKilled] == @[3, 5, 9] and a.kept.lists[teKilled] == @[3, 5, 9]
    doAssert a.shown.lists[teReversed] == @[2] and a.kept.lists[teReversed].len == 0
    doAssert a.steps.undos == 3
    discard a.undo() # the reversal (shown only)
    discard a.undo() # 5 and 9 killed
    doAssert a.shown.lists[teKilled] == @[3], $a.shown.lists[teKilled]

  block cost:
    # What the screen asks of a file's lists every frame (whether the gather
    # shown has an edit: `gatherEdited`) and with every new view (the
    # gather's edited traces, sent with the request: `requestView`) does not
    # grow with the traces edited elsewhere in the file: a large selection
    # killed in another record.
    var e: FileEdits
    var far = newSeq[int](200_000)
    for i, t in far.mpairs: t = 1_000_000 + i
    doAssert e.change(teKilled, far, true) == far.len
    doAssert e.change(teReversed, [5, 7, 1_000_003], true) == 3
    doAssert e.listIn(teKilled, 1_000_000 .. 1_000_004) == @[1_000_000, 1_000_001, 1_000_002,
      1_000_003, 1_000_004]
    doAssert e.listIn(teReversed, 0 .. high(int)) == @[5, 7, 1_000_003]
    doAssert e.anyIn(1_199_999 .. 1_300_000) and not e.anyIn(1_200_000 .. 1_300_000)
    doAssert e.editsOf(1_000_003) == {teKilled, teReversed}
    const calls = 200
    var found = 0
    let start = getMonoTime()
    for i in 0 ..< calls:
      if e.anyIn(0 .. 99) and not e.anyIn(100 .. 999): inc found
      found += e.listIn(teKilled, 0 .. 99).len + e.listIn(teReversed, 0 .. 99).len
    let us = float64((getMonoTime() - start).inNanoseconds) / 1000 / calls
    doAssert found == 3 * calls, $found
    doAssert us < 50, "a frame's questions to the lists take " & $us &
      " µs with 200 000 traces edited elsewhere"
    # a change, its undo and a clearing keep the lists ascending, each trace once
    doAssert e.change(teKilled, [999_999, 1_000_001, 999_999], true) == 1
    doAssert e.listIn(teKilled, 999_998 .. 1_000_001) == @[999_999, 1_000_000, 1_000_001]
    doAssert e.change(teKilled, [1_000_000, 1_000_002, 5], false) == 2
    doAssert e.listIn(teKilled, 999_998 .. 1_000_003) == @[999_999, 1_000_001, 1_000_003]
    discard e.undo()
    doAssert e.listIn(teKilled, 999_998 .. 1_000_003) == @[999_999, 1_000_000, 1_000_001,
      1_000_002, 1_000_003]
    doAssert e.clearAll() and e.len(teKilled) == 0 and not e.anyIn(0 .. high(int))
    discard e.undo()
    doAssert e.len(teKilled) == far.len + 1 and e.len(teReversed) == 3

  withFixtures fx:
    let path = fx.surveySegy(pdSpike) # shot 0, channel 15 (trace index 14): a sample of 100
    let other = fx.surveySegy()
    let before = (readFile(path), getLastModificationTime(path))
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    var d = st.panel(MainPanel).layers[0].display
    d.gain = dgNone # nothing else on the samples: the tile holds them as decoded
    st.display(d)
    let lay = st.panel(MainPanel).layout
    # one tile row per trace, one column per sample: nothing decimated
    let whole = fitAll(lay, 640, 2 * lay.samples)
    st.apply Command(kind: ckView, panel: MainPanel, view: whole)
    doAssert st.settle(st.answered)
    let recorded = st.tiles(0)[^1]
    doAssert recorded.request.stride == 1 and recorded.request.decimation == 1 and
      recorded.request.count == Channels, $recorded.request
    doAssert recorded.edits.len == 0 and recorded.level.peak == 100, $recorded.level
    var base = st.sessions[0].base
    const spiked = 14
    const flipped = 7

    block kill:
      let gen = st.panel(MainPanel).requestGen
      st.edit(teKilled, @[base + spiked])
      doAssert st.panel(MainPanel).requestGen > gen, "nothing asked for"
      doAssert st.tiles(0).len > 0, "the tiles from before are drawn until the new one comes"
      doAssert st.traceEdits(base + spiked) == {teKilled} and st.gatherEdited(0)
      doAssert st.settle(st.answered)
      doAssert st.tiles(0).len == 1, $st.tiles(0).len & " tiles after the kill"
      let t = st.tiles(0)[^1]
      doAssert t.cached, "the tile after the kill was read from the file"
      doAssert t.rowOf(spiked).blank, "trace 15's row is not blank: " & $max(t.rowOf(spiked))
      doAssert t.editsAt(t.traces.find(spiked)) == {teKilled} and t.isKilled(spiked)
      for k in 0 ..< Channels:
        if k != spiked: doAssert t.rowOf(k) == recorded.rowOf(k), "trace " & $(k + 1) & " changed"
      doAssert t.level.peak < 2, "the level's peak is " & $t.level.peak &
        " with the spike's trace killed"
      # the RMS over the other traces: the killed one is not counted as zeros
      var sum = 0.0
      var n = 0
      for k in 0 ..< Channels:
        if k != spiked:
          for v in recorded.rowOf(k):
            sum += float64(v) * float64(v)
            inc n
      let rms = sqrt(sum / float64(n))
      doAssert abs(t.level.rms - rms) <= 1e-6 * rms, "the level's RMS is " & $t.level.rms &
        ", the other traces' " & $rms
      doAssert st.panel(MainPanel).level.peak < 2, "the panel's level peak is " &
        $st.panel(MainPanel).level.peak & " after the kill"
      # the readout over the killed trace
      var p = pickAt(st.tiles(0), lay, DataPoint(x: float64(spiked), tMs: 600))
      p.inside = true
      doAssert p.found and p.edits == {teKilled} and p.editNote == "killed" and p.amplitude == 0
      p = pickAt(st.tiles(0), lay, DataPoint(x: float64(spiked + 1), tMs: 600))
      p.inside = true
      doAssert p.editNote == "", p.editNote
      # Float: the level of the data in view leaves it out too
      var f = d
      f.gain = dgFloat
      st.display(f)
      let vl = st.panel(MainPanel).viewLevel
      doAssert vl.peak < 2 and abs(vl.rms - rms) <= 1e-6 * rms, "the Float level's RMS " &
        $vl.rms & ", the other traces' " & $rms
      # Normalized, the whole gather, its peak: the reference leaves it out
      f.gain = dgNormalized
      (f.normScope, f.normStat) = (perPanel, normMax)
      st.display(f)
      doAssert st.panel(MainPanel).reference < 2, "Normalized's reference " &
        $st.panel(MainPanel).reference
      st.display(d)
      doAssert st.settle(st.answered)

    block reverse:
      st.edit(teReversed, @[base + flipped])
      doAssert st.settle(st.answered)
      let t = st.tiles(0)[^1]
      doAssert t.cached, "the tile after the reversal was read from the file"
      doAssert t.editsAt(t.traces.find(flipped)) == {teReversed}
      # processSEG's polarityOp on the file's own samples of that trace
      var f = openSeismic(path, keys = true)
      var log: DiagLog
      let one = @[flipped]
      var x = f.readTraces(one, log)
      doAssert log.len == 0
      let plan = initPipeline([polarityOp()]).compile(float32, lay.dtMs, x.shape[1])
      var ws = initWorkspace()
      ws.reserve(plan)
      plan.apply(x, f.chunkMeta(one, dtMs = lay.dtMs), ws)
      let got = t.rowOf(flipped)
      for j in 0 ..< t.columns:
        let want = x[0, t.request.firstSample + j]
        doAssert got[j] == want, "trace 8 sample " & $(t.request.firstSample + j) & ": " &
          $got[j] & " in the tile, polarityOp gives " & $want
      doAssert got != recorded.rowOf(flipped), "the reversed row is as recorded"
      f.close()
      doAssert t.rowOf(spiked).blank, "the kill went"
      # the readout: the negated amplitude, and says so
      var at = DataPoint(x: float64(flipped), tMs: 0)
      while abs(pickAt([recorded], lay, at).amplitude) < 0.05 and at.tMs < 990: at.tMs += 2
      var p = pickAt(st.tiles(0), lay, at)
      p.inside = true
      doAssert p.amplitude == -pickAt([recorded], lay, at).amplitude and p.amplitude != 0
      doAssert p.editNote == "polarity reversed", p.editNote
      # both
      st.edit(teKilled, @[base + flipped])
      doAssert st.settle(st.answered)
      p = pickAt(st.tiles(0), lay, at)
      p.inside = true
      doAssert p.editNote == "killed, polarity reversed", p.editNote

    block undo:
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert "Undone: trace 8 killed." in st.last, st.last
      doAssert st.settle(st.answered)
      doAssert not st.tiles(0)[^1].rowOf(flipped).blank and st.traceEdits(base + flipped) ==
        {teReversed}
      doAssert st.editsOf(0).canUndo and st.editsOf(0).canRedo, "the steps before are kept"
      st.apply Command(kind: ckRedoEdit, panel: MainPanel)
      doAssert "Redone: trace 8 killed." in st.last, st.last
      doAssert st.settle(st.answered)
      doAssert st.tiles(0)[^1].rowOf(flipped).blank, "the redo did not kill it again"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.answered)
      let gen = st.panel(MainPanel).requestGen
      st.edit(teKilled, @[base + flipped], on = false) # no change: no step, the redo stays
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      st.apply Command(kind: ckRedoEdit, panel: MainPanel)
      doAssert st.settle(st.answered)
      st.edit(teKilled, @[base + 20]) # a new step drops what was undone
      doAssert st.settle(st.answered)
      st.apply Command(kind: ckRedoEdit, panel: MainPanel)
      doAssert st.last == "Nothing to redo." and not st.editsOf(0).canRedo, st.last
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.answered) and st.panel(MainPanel).requestGen > gen
      # undo of a reversal
      st.edit(teReversed, @[base + flipped], on = false)
      doAssert st.settle(st.answered)
      doAssert st.tiles(0)[^1].rowOf(flipped) == recorded.rowOf(flipped), "not put back"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.answered)
      doAssert st.tiles(0)[^1].rowOf(flipped) != recorded.rowOf(flipped), "the undo did not reverse"

    block selection:
      st.apply Command(kind: ckSelect, traces: @[base + 2, base + 3, base + 4], mode: smReplace)
      let targets = st.selection.targets(base + 3)
      doAssert targets == @[base + 2, base + 3, base + 4], $targets
      doAssert st.selection.targets(base + 9) == @[base + 9] and st.selection.targets(-1).len == 0
      st.edit(teKilled, targets)
      doAssert "3 traces killed." in st.last, st.last
      doAssert st.settle(st.answered)
      for k in 2 .. 4: doAssert st.tiles(0)[^1].rowOf(k).blank
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.answered)
      for k in 2 .. 4: doAssert st.tiles(0)[^1].rowOf(k) == recorded.rowOf(k)

    block clearAll:
      doAssert not st.editsOf(0).isEmpty
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      doAssert st.editsOf(0).isEmpty and not st.gatherEdited(0)
      doAssert st.settle(st.answered)
      let t = st.tiles(0)[^1]
      doAssert t.edits.len == 0 and t.data == recorded.data, "not as the file has them"
      doAssert st.panel(MainPanel).level.peak == 100, "the level did not take the spike back"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.answered)
      doAssert st.traceEdits(base + spiked) == {teKilled} and
        st.traceEdits(base + flipped) == {teReversed}
      doAssert st.tiles(0)[^1].rowOf(spiked).blank

    proc checkEdits(st: var AppState; what: string) =
      ## The view's tile has trace 15 killed and trace 8 reversed.
      doAssert st.settle(st.panel(MainPanel).laidOut and st.answered), what
      let t = st.tiles(0)[^1]
      doAssert t.rowOf(spiked).blank, what & ": trace 15 is not blank"
      doAssert t.rowOf(flipped) != recorded.rowOf(flipped), what & ": trace 8 is not reversed"
      doAssert t.editsAt(t.traces.find(flipped)) == {teReversed}, what

    block holds:
      # another record, and back
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.panel(MainPanel).laidOut and st.answered)
      doAssert st.tiles(0)[^1].edits.len == 0 and not st.gatherEdited(0)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      st.apply Command(kind: ckView, panel: MainPanel, view: whole)
      st.checkEdits("back to the record")
      # a sort: the channels backwards, so a position is another trace
      st.apply Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfChannel, descending: true)])
      st.checkEdits("sorted")
      doAssert st.tiles(0)[^1].traces[0] == Channels - 1, "not sorted"
      doAssert not st.tiles(0)[^1].cached, "other traces in the view, and none read"
      doAssert st.tiles(0)[^1].isKilled(Channels - 1 - spiked)
      st.apply Command(kind: ckSort, panel: MainPanel, order: @[])
      st.checkEdits("the file's order")
      # a gain change, on the same view: made from the samples at hand
      var agc = d
      agc.gain = dgAgc
      st.display(agc)
      st.checkEdits("AGC")
      doAssert st.tiles(0)[^1].cached, "a gain change on the same view read the file"
      st.display(d)
      st.checkEdits("no gain")
      # another file, and back: opened again, a new id and base
      let id = st.sessions[0].id
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path != path and
        st.panel(MainPanel).laidOut and st.answered)
      doAssert st.tiles(0)[^1].edits.len == 0, "the other file has edits"
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == path and
        st.panel(MainPanel).laidOut)
      doAssert not (st.sessions[0].id == id)
      base = st.sessions[0].base
      st.apply Command(kind: ckView, panel: MainPanel, view: whole)
      st.checkEdits("the file again")
      doAssert st.traceEdits(base + spiked) == {teKilled}

    block ignored:
      let w = st.warnings
      st.edit(teKilled, @[base + 10_000])
      doAssert st.warnings == w + 1 and "not in" in st.last, st.last
      st.edit(teKilled, @[])
      doAssert st.warnings == w + 2 and "no trace" in st.last, st.last
      st.apply Command(kind: ckUndoEdit, panel: PanelId(99))
      doAssert st.warnings == w + 3
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0)
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      doAssert st.warnings == w + 4 and "shows no file" in st.last, st.last
    st.shutdown()
    doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"

  block deadMarked:
    # A trace marked dead in the file is never drawn, under any gain, and
    # reversing it changes nothing on screen: its row stays blank, its edits
    # say it is reversed (the display header and the status bar say so), and
    # the status bar says it is dead.
    withFixtures fx:
      let path = deadMarkedSegy(fx.dir)
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      var d = st.panel(MainPanel).layers[0].display
      d.gain = dgNone
      st.display(d)
      let lay = st.panel(MainPanel).layout
      st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
      doAssert st.settle(st.answered)
      const dead = 4
      doAssert st.tiles(0)[^1].rowOf(dead).blank, "under None the dead-marked trace is drawn"
      st.edit(teReversed, @[st.sessions[0].base + dead])
      doAssert st.settle(st.answered)
      let t = st.tiles(0)[^1]
      let row = t.traces.find(dead)
      doAssert t.editsAt(row) == {teReversed} and t.isDead(row) and t.rowOf(dead).blank
      var p = pickAt(st.tiles(0), lay, DataPoint(x: float64(dead), tMs: 100))
      p.inside = true
      doAssert editNote(p) == "dead, polarity reversed", editNote(p)
      d.gain = dgAgc
      st.display(d)
      doAssert st.settle(st.answered)
      doAssert st.tiles(0)[^1].rowOf(dead).blank, "under AGC the dead-marked trace is drawn"
      st.shutdown()

  block historyNotCopied:
    # Stepping to another record of a file with a long history does not copy
    # its edits and their history (a thousand steps): it allocates as many
    # times as with none.
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      doAssert st.sessions[0].gathers.len >= 2
      proc allocs(): int = cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs
      proc stepAllocs(st: var AppState): int =
        ## The allocations of two steps to another record and back, the least of three.
        result = high(int)
        for k in 0 ..< 3:
          let a0 = allocs()
          st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
          st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
          result = min(result, allocs() - a0)
          doAssert st.settle(st.panel(MainPanel).laidOut)
      let none = st.stepAllocs()
      let base = st.sessions[0].base
      for k in 0 ..< MaxSteps: st.edit(teKilled, @[base + 3], on = k mod 2 == 0)
      doAssert st.editsOf(0).steps.undos == MaxSteps
      let many = st.stepAllocs()
      doAssert many - none < 500, "a step to another record allocates " & $(many - none) &
        " times more with a history of a thousand steps (" & $none & " with none)"
      st.shutdown()
    echo "tedits: ok"

when isMainModule:
  main()
