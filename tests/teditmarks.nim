## Which trace a position in the edits row is about, and which menu lines
## that trace gets (`core/editmarks`), plus a removal of every kind as one
## undo step (`dropEdits`).
##
## Seen to fail: with `marksAt` returning no trace, "a letter mark names its
## trace"; with the selection line left out, "the selection line"; with
## `dropEdits` making one step per kind, "one undo brings every edit back".

import std/strutils
import viewSEG/core/[editmarks, edits, processing]

func letter(trace: int; centre, w: float32; edits: set[TraceEdit];
    hasFilter = false): EditMark =
  EditMark(trace: trace, centre: centre, lo: centre - w / 2, hi: centre + w / 2,
    cross0: 10, cross1: 22, edits: edits, hasFilter: hasFilter, outline: false,
    filterNote: if hasFilter: "Band-pass 10-60 Hz, after the plot's filters" else: "")

func bar(trace: int; centre: float32; edits: set[TraceEdit]; hasFilter = false): EditMark =
  EditMark(trace: trace, centre: centre, lo: centre - 0.4, hi: centre + 0.4,
    cross0: 0, cross1: 16, edits: edits, hasFilter: hasFilter, outline: true,
    filterNote: if hasFilter: "Band-pass 10-60 Hz, after the plot's filters" else: "")

func texts(hit: MarkHit; rows: openArray[TraceEditView]; selected: openArray[int]): seq[string] =
  for e in markEntries(hit, rows, selected): result.add entryText(e, hit.shared)

proc main*() =

  block letter_mark:
    let marks = [letter(4, 100, 8, {teKilled}), letter(9, 140, 8, {teReversed})]
    let hit = marksAt(marks, 101, 16, 0, 18)
    doAssert hit.traces == @[4] and not hit.shared, "a letter mark names its trace"
    doAssert markTitle(hit) == "Trace 5"
    doAssert marksAt(marks, 112, 16, 0, 18).traces.len == 0, "between letters is not a mark"
    doAssert marksAt(marks, 101, 30, 0, 18).traces.len == 0, "outside the row is not a mark"

  block outline_nearest:
    let marks = [bar(2, 40, {teKilled}), bar(8, 80, {teReversed})]
    let near = marksAt(marks, 40 + MarkPickPixels, 8, 0, 16)
    doAssert near.traces == @[2], "within a few pixels of an outline"
    doAssert marksAt(marks, 40 + MarkPickPixels + 1, 8, 0, 16).traces.len == 0,
      "past a few pixels is not a mark"

  block shared_pixel:
    # Centres 10.1, 10.4 and 10.8 share pixel 10; 11.6 is the next pixel.
    let marks = [bar(1, 10.1, {teKilled}), bar(2, 10.4, {teKilled}),
      bar(3, 10.8, {teReversed}), bar(4, 11.6, {teKilled})]
    let hit = marksAt(marks, 10.3, 4, 0, 16)
    doAssert hit.shared and hit.traces == @[1, 2, 3], "traces that share the pixel: " & $hit.traces
    doAssert markTitle(hit) == "3 traces here"
    let rows = [
      TraceEditView(trace: 1, edits: {teKilled}),
      TraceEditView(trace: 2, edits: {teKilled}),
      TraceEditView(trace: 3, edits: {teReversed})]
    let lines = texts(hit, rows, [])
    doAssert lines == @["Remove kill", "Remove reversal", "Remove all edits of these traces"],
      "the group lines: " & $lines
    let kill = markEntries(hit, rows, [])[0]
    doAssert kill.traces == @[1, 2], "kill is taken off the traces that have it"

  block one_trace_lines:
    let hit = MarkHit(traces: @[7])
    let rows = [TraceEditView(trace: 7, edits: {teKilled, teReversed}, hasFilter: true)]
    let lines = texts(hit, rows, [])
    doAssert lines == @["Remove kill", "Remove reversal", "Remove the trace's filter",
      "Edit the trace's filter...", "Remove all edits of this trace"], "one trace: " & $lines
    doAssert markTip(MarkHit(traces: @[4]), [letter(4, 0, 8, {teKilled})]).endsWith(
      "Right-click to remove")

  block selection_lines:
    let hit = MarkHit(traces: @[4])
    let rows = [
      TraceEditView(trace: 4, edits: {teKilled}),
      TraceEditView(trace: 5, edits: {teKilled}),
      TraceEditView(trace: 9, edits: {teKilled, teReversed})]
    let lines = texts(hit, rows, [4, 5, 9])
    doAssert "Remove kill from 3 selected traces" in lines, "the selection line: " & $lines
    doAssert "Remove reversal from" notin lines.join("\n"), "reversal is not on the clicked trace"
    let alone = texts(hit, rows, [])
    doAssert alone == @["Remove kill"], "not selected: " & $alone
    let kill = markEntries(hit, rows, [4, 5, 9])[1]
    doAssert kill.item == miRemoveKillSelected and kill.traces == @[4, 5, 9]

  block shift_lines:
    let hit = MarkHit(traces: @[7])
    let rows = [TraceEditView(trace: 7, hasShift: true)]
    let lines = texts(hit, rows, [])
    doAssert lines == @["Remove the time shift", "Edit the time shift..."], "a shift: " & $lines
    let shared = MarkHit(traces: @[7, 8], shared: true)
    let many = [
      TraceEditView(trace: 7, hasShift: true),
      TraceEditView(trace: 8, hasShift: true)]
    let group = texts(shared, many, [7, 8])
    doAssert "Edit the time shifts of 2 traces..." in group, "shared shifts: " & $group
    doAssert "Remove the time shift from 2 selected traces" in group, "the selection: " & $group
    doAssert shiftNote(11, [8.0]) == "Trace 12: shifted +8 ms"
    doAssert shiftNote(0, [8.0, 0.0]) == "1 trace is shifted"
    doAssert shiftNote(0, [8.0, -4.0]) == "2 traces are shifted"
    doAssert shiftNote(0, [0.0, 0.0]) == ""
    doAssert shiftApplies(7.0, 2.0) == "applies +8 ms: 4 samples", shiftApplies(7.0, 2.0)
    doAssert shiftApplies(2.0, 2.0) == "applies +2 ms: 1 sample", shiftApplies(2.0, 2.0)
    doAssert shiftApplies(0.0, 2.0) == "applies 0 ms: 0 samples"
    doAssert shiftApplies(1e30, 2.0) == ""
    doAssert "not kept" in shiftRefusal(1e30)

  block drop_is_one_step:
    var e = FileEdits()
    let f = bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: 8, f2: 10, f3: 60, f4: 70)))
    discard e.change(teKilled, [3, 4], true)
    discard e.change(teReversed, [3], true)
    discard e.setOwnFilters([3], f, true)
    doAssert e.dropEdits([3, 4], {teKilled, teReversed}, true) == 2
    doAssert e.editsOf(3) == {} and e.editsOf(4) == {} and not e.hasFilter(3)
    let undone = e.undo()
    doAssert undone.kind == skDrop, "one undo brings every edit back"
    doAssert e.editsOf(3) == {teKilled, teReversed} and e.hasFilter(3) and e.editsOf(4) == {teKilled}
    doAssert e.redo().kind == skDrop and e.editsOf(3) == {}
    doAssert e.dropEdits([3], {teKilled}, false) == 0, "nothing left is not a step"

  echo "teditmarks: ok"

when isMainModule:
  main()
