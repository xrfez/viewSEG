## Edits to traces: the traces of a file whose polarity is reversed, the
## traces killed, and the polarity of all its traces reversed. They are
## lists kept beside the file, by the trace's index in it, and the file
## itself is never changed.
##
## - **Reversed:** the trace's samples times -1, as processSEG's
##   `reversePolarity` (`polarityOp`) makes them, before any processing or
##   gain, so whatever is computed from the trace sees the reversed data.
## - **Killed:** the trace is drawn blank and left out of whatever is
##   computed over the panel (the gain's levels).
## - **All reversed:** every trace of the file reversed (`setAllReversed`),
##   as the plot's "Reverse polarity of all traces" asks; a trace reversed on
##   its own as well is reversed twice, so as recorded.
##
## **History.** Every change is a step (`EditStep`): what it gave and what it
## took away, per list. `undo` takes the newest step back and keeps it for
## `redo`, which makes it again; a new change drops the steps undone. The
## history is for the session: what is remembered with the file is the lists
## (`core/filememory`), not how they came to be. At most `MaxSteps` steps are
## kept, the oldest dropped first.
##
## **Shown and kept.** The lists come twice: those shown (what the plot
## draws) and those kept, what the user made by hand and the file's memory
## holds. Each change says whether it is kept (`keep`: a change an agent
## makes is shown for the session only); a step given or taken back by a
## kept command reaches both, by the same additions and removals, so an
## agent's change undone or made again by the user is then kept as shown.
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

const MaxSteps* = 1000 ## steps kept per file for undo, the oldest dropped first

type
  TraceEdit* = enum
    ## What an edit does to a trace.
    teReversed = "reversed" ## polarity reversed: 180 degrees out of phase
    teKilled = "killed"     ## drawn blank, left out of the panel's levels

  StepKind* = enum
    skNone = "none"           ## no step: nothing to undo or redo
    skChange = "change"       ## an edit given to some traces or taken away
    skClear = "clear"         ## every edit taken away
    skAllReversed = "all"     ## the polarity of every trace reversed, or put back
    skImport = "import"       ## edits taken in from a file
    skSetAside = "set aside"  ## every edit taken away: the file changed on disk

  EditStep* = object
    ## One change of a file's edits: what it gave and took away.
    kind*: StepKind
    edit*: TraceEdit                     ## skChange: which edit
    on*: bool                            ## skChange: given (true); skAllReversed: reversed after
    traces*: seq[int]                    ## skChange: the traces it changed, ascending
    added*, removed*: array[TraceEdit, seq[int]]
      ## the traces each list gained and lost, ascending
    source*: string                      ## skImport: the file's name
    allChanged*: bool                    ## the polarity of all traces changed with it
    allBefore*, allAfter*: bool          ## all reversed before and after it

  EditLists* = object
    ## A file's edits: each list ascending, each trace once.
    lists*: array[TraceEdit, seq[int]]
    allReversed*: bool

  FileEdits* = object
    ## The edits of one file's traces, by their index in the file: those
    ## shown and those kept, with the history of the session.
    shown: EditLists
    kept: EditLists
    undos, redos: seq[EditStep] ## the newest last
    revision: int               ## bumped on every change of what is shown
    keptRevision: int           ## bumped on every change of what is kept

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

func isEmpty*(l: EditLists): bool =
  ## Whether `l` holds no edit.
  not l.allReversed and l.lists[teReversed].len == 0 and l.lists[teKilled].len == 0

func count*(l: EditLists): int =
  ## How many edits `l` holds: traces per list, and all reversed as one.
  l.lists[teReversed].len + l.lists[teKilled].len + ord(l.allReversed)

func sortedTraces*(traces: openArray[int]): seq[int] =
  ## `traces` ascending, each once. Raises `ValueError` for a negative one.
  result = newSeqOfCap[int](traces.len)
  for t in traces:
    if t < 0: raise newException(ValueError, "a trace index must not be negative, got " & $t)
    result.add t
  result.sort()
  var n = 0
  for i in 0 ..< result.len:
    if n == 0 or result[n - 1] != result[i]:
      result[n] = result[i]
      inc n
  result.setLen n

func has*(e: FileEdits; edit: TraceEdit; trace: int): bool {.inline.} =
  ## Whether trace `trace` has edit `edit` (as shown).
  e.shown.lists[edit].binarySearch(trace) >= 0

func editsOf*(e: FileEdits; trace: int): set[TraceEdit] =
  ## The edits trace `trace` has (as shown).
  for edit in TraceEdit:
    if e.has(edit, trace): result.incl edit

func len*(e: FileEdits; edit: TraceEdit): int {.inline.} =
  ## How many traces have edit `edit` (as shown).
  e.shown.lists[edit].len

func allReversed*(e: FileEdits): bool {.inline.} = e.shown.allReversed
  ## Whether the polarity of every trace is reversed (as shown).

func isEmpty*(e: FileEdits): bool {.inline.} = e.shown.isEmpty
  ## Whether no trace has an edit (as shown).

func shown*(e: FileEdits): lent EditLists {.inline.} = e.shown
  ## The edits as shown.

func kept*(e: FileEdits): lent EditLists {.inline.} = e.kept
  ## The edits as the user made them: what the file's memory holds.

func revision*(e: FileEdits): int {.inline.} = e.revision
  ## Bumped on every change of what is shown.

func keptRevision*(e: FileEdits): int {.inline.} = e.keptRevision
  ## Bumped on every change of what is kept.

func canUndo*(e: FileEdits): bool {.inline.} = e.undos.len > 0
  ## Whether there is a step to undo.

func canRedo*(e: FileEdits): bool {.inline.} = e.redos.len > 0
  ## Whether there is a step undone to make again.

func nextUndo*(e: FileEdits): EditStep =
  ## The step `undo` takes back; `skNone` for none.
  if e.undos.len > 0: e.undos[^1] else: EditStep()

func nextRedo*(e: FileEdits): EditStep =
  ## The step `redo` makes again; `skNone` for none.
  if e.redos.len > 0: e.redos[^1] else: EditStep()

func steps*(e: FileEdits): tuple[undos, redos: int] {.inline.} = (e.undos.len, e.redos.len)
  ## How many steps can be undone, and redone.

func listIn*(e: FileEdits; edit: TraceEdit; traces: Slice[int]): seq[int] =
  ## The traces in `traces` with edit `edit` (as shown), ascending.
  let s = span(e.shown.lists[edit], traces)
  if s.len > 0: e.shown.lists[edit][s] else: @[]

func anyIn*(e: FileEdits; traces: Slice[int]): bool =
  ## Whether a trace in `traces` has an edit (as shown).
  for edit in TraceEdit:
    if span(e.shown.lists[edit], traces).len > 0: return true
  false

proc forward(l: var EditLists; s: EditStep) =
  for edit in TraceEdit:
    if s.removed[edit].len > 0: l.lists[edit] = difference(l.lists[edit], s.removed[edit])
    if s.added[edit].len > 0: l.lists[edit] = union(l.lists[edit], s.added[edit])
  if s.allChanged: l.allReversed = s.allAfter

proc backward(l: var EditLists; s: EditStep) =
  for edit in TraceEdit:
    if s.added[edit].len > 0: l.lists[edit] = difference(l.lists[edit], s.added[edit])
    if s.removed[edit].len > 0: l.lists[edit] = union(l.lists[edit], s.removed[edit])
  if s.allChanged: l.allReversed = s.allBefore

proc make(e: var FileEdits; s: sink EditStep; keep: bool) =
  ## Makes the new step `s`, on what is kept too with `keep`, and drops the
  ## steps undone.
  e.shown.forward(s)
  inc e.revision
  if keep:
    let was = e.kept
    e.kept.forward(s)
    if e.kept != was: inc e.keptRevision
  e.redos.setLen 0
  e.undos.add s
  if e.undos.len > MaxSteps: e.undos.delete(0)

proc change*(e: var FileEdits; edit: TraceEdit; traces: openArray[int]; on: bool;
    keep = true): int =
  ## Gives every trace of `traces` edit `edit` (`on`) or takes it away, as a
  ## step of the history (kept with `keep`). Returns how many changed; a
  ## change of none makes no step. Raises `ValueError` for a negative trace
  ## index.
  var changed: seq[int]
  for t in sortedTraces(traces):
    if e.has(edit, t) != on: changed.add t
  result = changed.len
  if result > 0:
    var s = EditStep(kind: skChange, edit: edit, on: on, traces: changed)
    if on: s.added[edit] = move changed
    else: s.removed[edit] = move changed
    e.make(s, keep)

proc clearAll*(e: var FileEdits; keep = true; kind = skClear): bool =
  ## Takes every edit away (as a step: `undo` brings them back), the file
  ## then shown as it is on disk. False when there were none. `kind` is
  ## `skSetAside` when the file changed on disk.
  result = not e.shown.isEmpty
  if result:
    var s = EditStep(kind: kind, allChanged: e.shown.allReversed, allBefore: true)
    s.removed = e.shown.lists
    e.make(s, keep)

proc setAllReversed*(e: var FileEdits; on: bool; keep = true): bool =
  ## Reverses the polarity of every trace (`on`) or puts it back, as a step.
  ## False when it was so already.
  result = e.shown.allReversed != on
  if result:
    e.make(EditStep(kind: skAllReversed, on: on, allChanged: true, allBefore: not on,
      allAfter: on), keep)

proc takeIn*(e: var FileEdits; l: EditLists; source: string; keep = true): int =
  ## Adds the edits of `l` (a file's list imported: `source` names it) as
  ## one step; returns how many were not there yet.
  var s = EditStep(kind: skImport, source: source)
  for edit in TraceEdit:
    s.added[edit] = difference(sortedTraces(l.lists[edit]), e.shown.lists[edit])
    result += s.added[edit].len
  if l.allReversed and not e.shown.allReversed:
    (s.allChanged, s.allAfter) = (true, true)
    inc result
  if result > 0: e.make(s, keep)

proc remembered*(e: var FileEdits; l: EditLists) =
  ## Adds what the file's memory holds (`l`) to what is shown and kept, as
  ## no step: the file is shown as it was left. Edits made before it came
  ## (the file's identity known late) are kept beside them.
  let was = e.shown
  for edit in TraceEdit:
    e.shown.lists[edit] = union(e.shown.lists[edit], l.lists[edit])
    e.kept.lists[edit] = union(e.kept.lists[edit], l.lists[edit])
  e.shown.allReversed = e.shown.allReversed or l.allReversed
  e.kept.allReversed = e.kept.allReversed or l.allReversed
  if e.shown != was: inc e.revision

proc forget*(e: var FileEdits) =
  ## Takes away what is kept and what is shown, and the history: the file
  ## is shown as it is on disk, and nothing is remembered.
  if not e.shown.isEmpty: inc e.revision
  if not e.kept.isEmpty: inc e.keptRevision
  e.shown = EditLists()
  e.kept = EditLists()
  e.undos.setLen 0
  e.redos.setLen 0

proc turn(l: var EditLists; s: EditStep; back: bool) {.inline.} =
  if back: l.backward(s) else: l.forward(s)

proc undo*(e: var FileEdits; keep = true): EditStep =
  ## Takes the newest step back (on what is kept too with `keep`) and keeps
  ## it for `redo`; returns it, `skNone` when there was none.
  if e.undos.len == 0: return EditStep()
  result = e.undos.pop()
  e.shown.turn(result, back = true)
  inc e.revision
  if keep:
    let was = e.kept
    e.kept.turn(result, back = true)
    if e.kept != was: inc e.keptRevision
  e.redos.add result

proc redo*(e: var FileEdits; keep = true): EditStep =
  ## Makes the step undone last again (on what is kept too with `keep`);
  ## returns it, `skNone` when there was none.
  if e.redos.len == 0: return EditStep()
  result = e.redos.pop()
  e.shown.turn(result, back = false)
  inc e.revision
  if keep:
    let was = e.kept
    e.kept.turn(result, back = false)
    if e.kept != was: inc e.keptRevision
  e.undos.add result

func touches*(s: EditStep; edit: TraceEdit): bool =
  ## Whether step `s` changed edit `edit` of some trace.
  s.added[edit].len > 0 or s.removed[edit].len > 0

func changedIn*(s: EditStep; traces: Slice[int]): bool =
  ## Whether step `s` changed a trace in `traces` (reversing all changes
  ## every trace).
  if s.allChanged: return true
  for edit in TraceEdit:
    if span(s.added[edit], traces).len > 0 or span(s.removed[edit], traces).len > 0:
      return true
  false

func tracesText(traces: openArray[int]): string =
  if traces.len == 1: "trace " & $(traces[0] + 1) else: $traces.len & " traces"

func describe*(s: EditStep): string =
  ## Step `s` in words, as the undo and redo items name it: "trace 21
  ## killed", "polarity of 3 traces reversed", "all edits cleared"; "" for
  ## none.
  case s.kind
  of skNone: ""
  of skClear: "all edits cleared"
  of skSetAside: "edits set aside (the file changed on disk)"
  of skAllReversed:
    "polarity of all traces " & (if s.on: "reversed" else: "put back")
  of skImport:
    var n = ord(s.allChanged)
    for edit in TraceEdit: n += s.added[edit].len
    $n & (if n == 1: " edit" else: " edits") & " imported from " & s.source
  of skChange:
    let what = tracesText(s.traces)
    case s.edit
    of teKilled: what & (if s.on: " killed" else: " restored")
    of teReversed: "polarity of " & what & (if s.on: " reversed" else: " put back")
