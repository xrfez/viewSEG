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
## kept command reaches both, so an agent's change undone or made again by
## the user is then kept as shown. Where an agent's change has made the two
## differ, a step says what it does to each (a user's kill of a selection
## that holds a trace an agent killed kills it in what is kept too; the
## user's "clear all" clears what is kept, also what an agent's undo hid).
## At most `MaxSteps` steps are kept, and at most `MaxHeldTraces` traces
## over all of them (a few changes of a million traces each), the oldest
## dropped first.
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

const
  MaxSteps* = 1000 ## steps kept per file for undo, the oldest dropped first
  MaxHeldTraces* = 20_000_000
    ## the traces the steps of one file's history name at most, all told
    ## (about 160 MB), the oldest steps dropped first; the newest is kept
    ## whatever its size

type
  TraceEdit* = enum
    ## What an edit does to a trace.
    teReversed = "reversed" ## polarity reversed: 180 degrees out of phase
    teKilled = "killed"     ## drawn blank, left out of the panel's levels

  StepKind* = enum
    skNone = "none"          ## no step: nothing to undo or redo
    skChange = "change"      ## an edit given to some traces or taken away
    skClear = "clear"        ## every edit taken away
    skAllReversed = "all"    ## the polarity of every trace reversed, or put back
    skImport = "import"      ## edits taken in from a file
    skSetAside = "set aside" ## every edit taken away: the file changed on disk

  ListsChange = object
    ## What a step does to the lists kept, where that is not what it does
    ## to those shown.
    added, removed: array[TraceEdit, seq[int]]
    allChanged, allBefore, allAfter: bool

  EditStep* = object
    ## One change of a file's edits: what it gave and took away.
    kind*: StepKind
    edit*: TraceEdit            ## skChange: which edit
    on*: bool                   ## skChange: given (true); skAllReversed: reversed after
    traces*: seq[int]           ## skChange: the traces it changed, ascending
    added*, removed*: array[TraceEdit, seq[int]]
      ## the traces each list gained and lost, ascending (as shown)
    source*: string             ## skImport: the file's name
    allChanged*: bool           ## the polarity of all traces changed with it
    allBefore*, allAfter*: bool ## all reversed before and after it
    keptOwn: bool               ## what is kept changes by `keptChange`
    keptChange: ListsChange     ## what it does to what is kept, with `keptOwn`

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
    held: int ## the traces the steps name, all told (`MaxHeldTraces`)
    revision: int ## bumped on every change of what is shown
    keptRevision: int ## bumped on every change of what is kept

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
  var ascending = traces.len == 0 or traces[0] >= 0
  for i in 1 ..< traces.len:
    if traces[i] <= traces[i - 1]:
      ascending = false
      break
  if ascending: return @traces # the lists read and kept are so already
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

func keptOf*(e: FileEdits; trace: int): set[TraceEdit] =
  ## The edits trace `trace` has as kept (what the file's memory holds):
  ## those of `editsOf` that are not are shown for the session only (an
  ## agent's), and those that are not in `editsOf` are kept but hidden for
  ## the session (an agent's undo of the user's).
  for edit in TraceEdit:
    if e.kept.lists[edit].binarySearch(trace) >= 0: result.incl edit

func minus*(a, b: EditLists): EditLists =
  ## The edits of `a` that `b` does not have (all reversed included).
  for edit in TraceEdit: result.lists[edit] = difference(a.lists[edit], b.lists[edit])
  result.allReversed = a.allReversed and not b.allReversed

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

func anyKeptIn*(e: FileEdits; traces: Slice[int]): bool =
  ## Whether a trace in `traces` has an edit as kept.
  for edit in TraceEdit:
    if span(e.kept.lists[edit], traces).len > 0: return true
  false

proc turn(l: var EditLists; added, removed: array[TraceEdit, seq[int]];
    allChanged, allTo: bool) =
  ## Takes `removed` away from `l` and gives it `added`, and all reversed
  ## `allTo` when `allChanged`.
  for edit in TraceEdit:
    if removed[edit].len > 0: l.lists[edit] = difference(l.lists[edit], removed[edit])
    if added[edit].len > 0: l.lists[edit] = union(l.lists[edit], added[edit])
  if allChanged: l.allReversed = allTo

proc turnShown(l: var EditLists; s: EditStep; back: bool) =
  if back: l.turn(s.removed, s.added, s.allChanged, s.allBefore)
  else: l.turn(s.added, s.removed, s.allChanged, s.allAfter)

proc turnKept(l: var EditLists; s: EditStep; back: bool) =
  if not s.keptOwn: l.turnShown(s, back)
  else:
    template c: untyped = s.keptChange
    if back: l.turn(c.removed, c.added, c.allChanged, c.allBefore)
    else: l.turn(c.added, c.removed, c.allChanged, c.allAfter)

func size(s: EditStep): int =
  ## The traces `s` names, all told.
  result = s.traces.len
  for edit in TraceEdit:
    result += s.added[edit].len + s.removed[edit].len +
      s.keptChange.added[edit].len + s.keptChange.removed[edit].len

proc keptChanges(s: var EditStep; c: sink ListsChange) =
  ## `c` is what `s` does to what is kept; noted apart only where it is not
  ## what `s` does to what is shown.
  if c.added != s.added or c.removed != s.removed or c.allChanged != s.allChanged or
      (c.allChanged and (c.allBefore, c.allAfter) != (s.allBefore, s.allAfter)):
    s.keptOwn = true
    s.keptChange = c

proc make(e: var FileEdits; s: sink EditStep; keep: bool) =
  ## Makes the new step `s`, on what is kept too with `keep`, and drops the
  ## steps undone, and the oldest beyond `MaxSteps` or `MaxHeldTraces`.
  e.shown.turnShown(s, back = false)
  inc e.revision
  if keep:
    let was = e.kept
    e.kept.turnKept(s, back = false)
    if e.kept != was: inc e.keptRevision
  for r in e.redos: e.held -= r.size
  e.redos.setLen 0
  e.held += s.size
  e.undos.add s
  var drop = 0
  while e.undos.len - drop > 1 and (e.undos.len - drop > MaxSteps or e.held > MaxHeldTraces):
    e.held -= e.undos[drop].size
    inc drop
  if drop > 0: e.undos = e.undos[drop .. ^1]

func keptHas(e: FileEdits; edit: TraceEdit; trace: int): bool {.inline.} =
  e.kept.lists[edit].binarySearch(trace) >= 0

proc change*(e: var FileEdits; edit: TraceEdit; traces: openArray[int]; on: bool;
    keep = true): int =
  ## Gives every trace of `traces` edit `edit` (`on`) or takes it away, as a
  ## step of the history (kept with `keep`: then every trace of `traces` is
  ## so in what is kept, also one an agent's change made so as shown
  ## already). Returns how many changed; a change of none makes no step.
  ## Raises `ValueError` for a negative trace index.
  var changed, keptChanged: seq[int]
  for t in sortedTraces(traces):
    if e.has(edit, t) != on: changed.add t
    if e.keptHas(edit, t) != on: keptChanged.add t
  result = changed.len
  if keep and result == 0: result = keptChanged.len
  if result > 0:
    var s = EditStep(kind: skChange, edit: edit, on: on,
      traces: if changed.len > 0: changed else: keptChanged)
    var c = ListsChange()
    if on: (s.added[edit], c.added[edit]) = (move changed, move keptChanged)
    else: (s.removed[edit], c.removed[edit]) = (move changed, move keptChanged)
    s.keptChanges(c)
    e.make(s, keep)

proc clearAll*(e: var FileEdits; keep = true; kind = skClear): bool =
  ## Takes every edit away (as a step: `undo` brings them back), the file
  ## then shown as it is on disk, and with `keep` nothing kept either. False
  ## when there were none. `kind` is `skSetAside` when the file changed on
  ## disk.
  result = not e.shown.isEmpty or (keep and not e.kept.isEmpty)
  if result:
    var s = EditStep(kind: kind, allChanged: e.shown.allReversed, allBefore: true)
    s.removed = e.shown.lists
    s.keptChanges(ListsChange(removed: e.kept.lists, allChanged: e.kept.allReversed,
      allBefore: true))
    e.make(s, keep)

proc setAllReversed*(e: var FileEdits; on: bool; keep = true): bool =
  ## Reverses the polarity of every trace (`on`) or puts it back, as a step
  ## (in what is kept too with `keep`). False when it was so already.
  let shownToo = e.shown.allReversed != on
  let keptToo = e.kept.allReversed != on
  result = shownToo or (keep and keptToo)
  if result:
    var s = EditStep(kind: skAllReversed, on: on, allChanged: shownToo, allBefore: not on,
      allAfter: on)
    s.keptChanges(ListsChange(allChanged: keptToo, allBefore: not on, allAfter: on))
    e.make(s, keep)

proc setTo*(e: var FileEdits; l: EditLists; source: string; keep = true): int =
  ## Makes the edits those of `l` (a record's state: what it has that the
  ## file does not is given, what the file has that it does not is taken
  ## away) as one step, in what is kept too with `keep`; returns how many
  ## traces changed.
  var s = EditStep(kind: skImport, source: source)
  var c = ListsChange()
  var kept = 0
  for edit in TraceEdit:
    let list = sortedTraces(l.lists[edit])
    s.added[edit] = difference(list, e.shown.lists[edit])
    s.removed[edit] = difference(e.shown.lists[edit], list)
    c.added[edit] = difference(list, e.kept.lists[edit])
    c.removed[edit] = difference(e.kept.lists[edit], list)
    result += s.added[edit].len + s.removed[edit].len
    kept += c.added[edit].len + c.removed[edit].len
  if l.allReversed != e.shown.allReversed:
    (s.allChanged, s.allBefore, s.allAfter) = (true, e.shown.allReversed, l.allReversed)
    inc result
  if l.allReversed != e.kept.allReversed:
    (c.allChanged, c.allBefore, c.allAfter) = (true, e.kept.allReversed, l.allReversed)
    inc kept
  if keep and result == 0: result = kept
  if result > 0:
    s.keptChanges(c)
    e.make(s, keep)

proc takeIn*(e: var FileEdits; l: EditLists; source: string; keep = true): int =
  ## Adds the edits of `l` (a file's list imported: `source` names it) as
  ## one step (in what is kept too with `keep`); returns how many were not
  ## there yet.
  var s = EditStep(kind: skImport, source: source)
  var c = ListsChange()
  var kept = 0
  for edit in TraceEdit:
    let list = sortedTraces(l.lists[edit])
    s.added[edit] = difference(list, e.shown.lists[edit])
    c.added[edit] = difference(list, e.kept.lists[edit])
    result += s.added[edit].len
    kept += c.added[edit].len
  if l.allReversed and not e.shown.allReversed:
    (s.allChanged, s.allAfter) = (true, true)
    inc result
  if l.allReversed and not e.kept.allReversed:
    (c.allChanged, c.allAfter) = (true, true)
    inc kept
  if keep and result == 0: result = kept
  if result > 0:
    s.keptChanges(c)
    e.make(s, keep)

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

proc merge*(e: var FileEdits; other: sink FileEdits) =
  ## Takes the edits of `other` in beside those of `e`, one file's edits
  ## made under two paths (a copy, a link): shown and kept, each the union
  ## of both, so neither loses an edit; the history of both, `e`'s steps
  ## first (the steps undone are dropped), within `MaxSteps` and
  ## `MaxHeldTraces`.
  let (wasShown, wasKept) = (e.shown, e.kept)
  for edit in TraceEdit:
    e.shown.lists[edit] = union(e.shown.lists[edit], other.shown.lists[edit])
    e.kept.lists[edit] = union(e.kept.lists[edit], other.kept.lists[edit])
  e.shown.allReversed = e.shown.allReversed or other.shown.allReversed
  e.kept.allReversed = e.kept.allReversed or other.kept.allReversed
  if e.shown != wasShown: inc e.revision
  if e.kept != wasKept: inc e.keptRevision
  for r in e.redos: e.held -= r.size
  e.redos.setLen 0
  for s in other.undos:
    e.held += s.size
    e.undos.add s
  var drop = 0
  while e.undos.len - drop > 1 and (e.undos.len - drop > MaxSteps or e.held > MaxHeldTraces):
    e.held -= e.undos[drop].size
    inc drop
  if drop > 0: e.undos = e.undos[drop .. ^1]

proc adopt*(e: var FileEdits; l: EditLists) =
  ## What is kept becomes `l` (the file's memory as another program changed
  ## it, merged with this one's), as no step: what it gained and lost is
  ## shown so too.
  let was = e.shown
  for edit in TraceEdit:
    let gained = difference(l.lists[edit], e.kept.lists[edit])
    let lost = difference(e.kept.lists[edit], l.lists[edit])
    e.shown.lists[edit] = union(difference(e.shown.lists[edit], lost), gained)
  if l.allReversed != e.kept.allReversed: e.shown.allReversed = l.allReversed
  if l != e.kept:
    e.kept = l
    inc e.keptRevision
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
  e.held = 0

proc undo*(e: var FileEdits; keep = true): EditStep =
  ## Takes the newest step back (on what is kept too with `keep`) and keeps
  ## it for `redo`; returns it, `skNone` when there was none.
  if e.undos.len == 0: return EditStep()
  result = e.undos.pop()
  e.shown.turnShown(result, back = true)
  inc e.revision
  if keep:
    let was = e.kept
    e.kept.turnKept(result, back = true)
    if e.kept != was: inc e.keptRevision
  e.redos.add result

proc redo*(e: var FileEdits; keep = true): EditStep =
  ## Makes the step undone last again (on what is kept too with `keep`);
  ## returns it, `skNone` when there was none.
  if e.redos.len == 0: return EditStep()
  result = e.redos.pop()
  e.shown.turnShown(result, back = false)
  inc e.revision
  if keep:
    let was = e.kept
    e.kept.turnKept(result, back = false)
    if e.kept != was: inc e.keptRevision
  e.undos.add result

func held*(e: FileEdits): int {.inline.} = e.held
  ## The traces the steps of the history name, all told (`MaxHeldTraces`).

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
    if n == 0 and s.keptOwn: # shown already (an agent's), kept by the import
      n = ord(s.keptChange.allChanged)
      for edit in TraceEdit: n += s.keptChange.added[edit].len
    $n & (if n == 1: " edit" else: " edits") & " imported from " & s.source
  of skChange:
    let what = tracesText(s.traces)
    case s.edit
    of teKilled: what & (if s.on: " killed" else: " restored")
    of teReversed: "polarity of " & what & (if s.on: " reversed" else: " put back")

func undoText*(e: FileEdits): string =
  ## `describe` of the step `undo` takes back, without a copy of it (the
  ## Edit menu asks every frame); "" for none.
  if e.undos.len > 0: describe(e.undos[e.undos.high]) else: ""

func redoText*(e: FileEdits): string =
  ## `describe` of the step `redo` makes again, without a copy of it; ""
  ## for none.
  if e.redos.len > 0: describe(e.redos[e.redos.high]) else: ""
