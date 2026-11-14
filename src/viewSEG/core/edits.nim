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
## **Cost.** The lists are kept ascending, so what the screen asks for
## every frame or every new view (whether a gather has an edit, its edited
## traces, a trace's edits) is a binary search, however many traces a file
## has edited elsewhere; only a change walks a list.
##
## The lists are plain data, changed only by `AppState` when it applies a
## `Command`; the reader of a panel gets a copy of those of its gather with
## each request.

import std/algorithm

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
    lists: array[TraceEdit, seq[int]] ## each ascending, each trace once
    last: LastEdit
    revision: int                     ## bumped on every change

func union(a, b: openArray[int]): seq[int] =
  ## The values of `a` and of `b` (both ascending), ascending, each once.
  result = newSeqOfCap[int](a.len + b.len)
  var i, j = 0
  while i < a.len or j < b.len:
    let x = if j >= b.len or (i < a.len and a[i] <= b[j]): a[i] else: b[j]
    if result.len == 0 or result[^1] != x: result.add x
    if i < a.len and a[i] == x: inc i
    if j < b.len and b[j] == x: inc j

func difference(a, b: openArray[int]): seq[int] =
  ## The values of `a` that are not in `b` (both ascending), ascending.
  result = newSeqOfCap[int](a.len)
  var j = 0
  for x in a:
    while j < b.len and b[j] < x: inc j
    if j >= b.len or b[j] != x: result.add x

func span(list: openArray[int]; traces: Slice[int]): Slice[int] =
  ## The indices in `list` (ascending) of its values in `traces`.
  list.lowerBound(traces.a) ..< list.upperBound(traces.b)

func has*(e: FileEdits; edit: TraceEdit; trace: int): bool {.inline.} =
  ## Whether trace `trace` has edit `edit`.
  e.lists[edit].binarySearch(trace) >= 0

func editsOf*(e: FileEdits; trace: int): set[TraceEdit] =
  ## The edits trace `trace` has.
  for edit in TraceEdit:
    if e.has(edit, trace): result.incl edit

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
  let s = span(e.lists[edit], traces)
  if s.len > 0: e.lists[edit][s] else: @[]

func anyIn*(e: FileEdits; traces: Slice[int]): bool =
  ## Whether a trace in `traces` has an edit.
  for edit in TraceEdit:
    if span(e.lists[edit], traces).len > 0: return true
  false

proc put(e: var FileEdits; edit: TraceEdit; traces: openArray[int]; on: bool) =
  ## Gives the traces `traces` (ascending) edit `edit`, or takes it away.
  e.lists[edit] = if on: union(e.lists[edit], traces) else: difference(e.lists[edit], traces)

proc change*(e: var FileEdits; edit: TraceEdit; traces: openArray[int]; on: bool): int =
  ## Gives every trace of `traces` edit `edit` (`on`) or takes it away, and
  ## keeps the traces that changed for `undo`. Returns how many changed; a
  ## change of none leaves the last change to undo as it was. Raises
  ## `ValueError` for a negative trace index.
  var wanted = newSeqOfCap[int](traces.len)
  for t in traces:
    if t < 0: raise newException(ValueError, "a trace index must not be negative, got " & $t)
    wanted.add t
  wanted.sort()
  var changed: seq[int]
  for t in wanted: # a trace given twice changes once
    if e.has(edit, t) != on and (changed.len == 0 or changed[^1] != t): changed.add t
  if changed.len > 0:
    e.put(edit, changed, on)
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
    e.put(result.edit, result.traces, not result.on)
    inc e.revision
  of lkClear:
    for edit in TraceEdit: e.put(edit, result.before[edit], true)
    inc e.revision

proc clearAll*(e: var FileEdits): bool =
  ## Takes every edit away, the file then shown as it is on disk; `undo`
  ## brings them back. False when there were none.
  result = not e.isEmpty
  if result:
    var last = LastEdit(kind: lkClear)
    for edit in TraceEdit: last.before[edit] = move e.lists[edit]
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
  of lkChange: span(l.traces, traces).len > 0
  of lkClear:
    for edit in TraceEdit:
      if span(l.before[edit], traces).len > 0: return true
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
