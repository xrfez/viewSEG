## Edits to traces: the traces of a file whose polarity is reversed, and
## the traces killed. They are lists kept beside the file, by the trace's
## index in it, and the file itself is never changed.
##
## - **Reversed:** the trace's samples times -1, as processSEG's
##   `reversePolarity` (`polarityOp`) makes them, before any processing or
##   gain, so whatever is computed from the trace sees the reversed data.
## - **Killed:** the trace is drawn blank and left out of whatever is
##   computed over the panel (the gain's levels).
##
## **Undo** needs no history: each change is its own inverse (kill and
## restore, reverse and reverse again), so a file keeps only its last
## change (`LastEdit`), the traces it changed and how; `undo` turns them
## back and forgets it. `clearAll` empties both lists, and is undone the
## same way.
##
## The lists are plain data, changed only by `AppState` when it applies a
## `Command`; the reader of a panel gets a copy of those of its gather with
## each request.

import std/[algorithm, intsets]

export intsets

type
  TraceEdit* = enum
    ## What an edit does to a trace.
    teReversed = "reversed" ## polarity reversed: 180 degrees out of phase
    teKilled = "killed"     ## drawn blank, left out of the panel's levels

  LastEditKind* = enum
    lkNone = "none"     ## nothing to undo
    lkChange = "change" ## an edit turned on or off on some traces
    lkClear = "clear"   ## every edit cleared

  LastEdit* = object
    ## The change a file's undo reverts.
    kind*: LastEditKind
    edit*: TraceEdit                    ## lkChange: which edit
    on*: bool                           ## lkChange: turned on (true) or off
    traces*: seq[int]                   ## lkChange: the traces it changed, ascending
    before*: array[TraceEdit, seq[int]] ## lkClear: each list before, ascending

  FileEdits* = object
    ## The edits of one file's traces, by their index in the file.
    lists: array[TraceEdit, IntSet]
    last: LastEdit
    revision: int ## bumped on every change

func sorted(s: IntSet): seq[int] =
  for t in s: result.add t
  result.sort()

func has*(e: FileEdits; edit: TraceEdit; trace: int): bool {.inline.} =
  ## Whether trace `trace` has edit `edit`.
  trace in e.lists[edit]

func editsOf*(e: FileEdits; trace: int): set[TraceEdit] =
  ## The edits trace `trace` has.
  for edit in TraceEdit:
    if trace in e.lists[edit]: result.incl edit

func len*(e: FileEdits; edit: TraceEdit): int {.inline.} =
  ## How many traces have edit `edit`.
  e.lists[edit].len

func isEmpty*(e: FileEdits): bool =
  ## Whether no trace has an edit.
  for edit in TraceEdit:
    if e.lists[edit].len > 0: return false
  true

func revision*(e: FileEdits): int {.inline.} = e.revision
  ## Bumped on every change.

func last*(e: FileEdits): lent LastEdit {.inline.} = e.last
  ## The change `undo` reverts; `lkNone` for none.

func canUndo*(e: FileEdits): bool {.inline.} = e.last.kind != lkNone
  ## Whether there is a change to undo.

func listIn*(e: FileEdits; edit: TraceEdit; traces: Slice[int]): seq[int] =
  ## The traces in `traces` with edit `edit`, ascending.
  for t in e.lists[edit]:
    if t in traces: result.add t
  result.sort()

func anyIn*(e: FileEdits; traces: Slice[int]): bool =
  ## Whether a trace in `traces` has an edit.
  for edit in TraceEdit:
    for t in e.lists[edit]:
      if t in traces: return true
  false

func put(e: var FileEdits; edit: TraceEdit; trace: int; on: bool) {.inline.} =
  if on: e.lists[edit].incl trace else: e.lists[edit].excl trace

proc change*(e: var FileEdits; edit: TraceEdit; traces: openArray[int]; on: bool): int =
  ## Gives every trace of `traces` edit `edit` (`on`) or takes it away, and
  ## keeps the traces that changed for `undo`. Returns how many changed; a
  ## change of none leaves the last change to undo as it was. Raises
  ## `ValueError` for a negative trace index.
  var changed: seq[int]
  for t in traces:
    if t < 0: raise newException(ValueError, "a trace index must not be negative, got " & $t)
    if (t in e.lists[edit]) != on: # a trace given twice changes once
      e.put(edit, t, on)
      changed.add t
  if changed.len > 0:
    changed.sort()
    e.last = LastEdit(kind: lkChange, edit: edit, on: on, traces: changed)
    inc e.revision
  changed.len

proc undo*(e: var FileEdits): LastEdit =
  ## Reverts the last change and forgets it (there is no deeper history);
  ## returns what was reverted, `lkNone` when there was nothing.
  result = move e.last
  e.last = LastEdit()
  case result.kind
  of lkNone: discard
  of lkChange:
    for t in result.traces: e.put(result.edit, t, not result.on)
    inc e.revision
  of lkClear:
    for edit in TraceEdit:
      for t in result.before[edit]: e.lists[edit].incl t
    inc e.revision

proc clearAll*(e: var FileEdits): bool =
  ## Takes every edit away, the file then shown as it is on disk; `undo`
  ## brings them back. False when there were none.
  result = not e.isEmpty
  if result:
    var last = LastEdit(kind: lkClear)
    for edit in TraceEdit:
      last.before[edit] = sorted(e.lists[edit])
      e.lists[edit].clear()
    e.last = last
    inc e.revision

func touches*(l: LastEdit; edit: TraceEdit): bool =
  ## Whether change `l` changed edit `edit` of some trace.
  case l.kind
  of lkNone: false
  of lkChange: l.edit == edit
  of lkClear: l.before[edit].len > 0

func changedIn*(l: LastEdit; traces: Slice[int]): bool =
  ## Whether change `l` changed a trace in `traces`.
  case l.kind
  of lkNone: false
  of lkChange:
    for t in l.traces:
      if t in traces: return true
    false
  of lkClear:
    for edit in TraceEdit:
      for t in l.before[edit]:
        if t in traces: return true
    false

func tracesText(traces: openArray[int]): string =
  if traces.len == 1: "trace " & $(traces[0] + 1) else: $traces.len & " traces"

func describe*(l: LastEdit): string =
  ## Change `l` in words, as the undo item names it: "trace 21 killed",
  ## "polarity of 3 traces reversed", "all edits cleared"; "" for none.
  case l.kind
  of lkNone: ""
  of lkClear: "all edits cleared"
  of lkChange:
    let what = tracesText(l.traces)
    case l.edit
    of teKilled: what & (if l.on: " killed" else: " restored")
    of teReversed: "polarity of " & what & (if l.on: " reversed" else: " put back")
