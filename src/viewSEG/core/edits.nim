## Edits to traces: the traces of a file whose polarity is reversed, the
## traces killed, the polarity of all its traces reversed, and a trace's
## own frequency filter. They are lists kept beside the file, by the
## trace's index in it, and the file itself is never changed.
##
## - **Reversed:** the trace's samples times -1, as processSEG's
##   `reversePolarity` (`polarityOp`) makes them, before any processing or
##   gain, so whatever is computed from the trace sees the reversed data.
## - **Killed:** the trace is drawn blank and left out of whatever is
##   computed over the panel (the gain's levels).
## - **All reversed:** every trace of the file reversed (`setAllReversed`),
##   as the plot's "Reverse polarity of all traces" asks; a trace reversed on
##   its own as well is reversed twice, so as recorded. Every graph uses that
##   same effective reversal (`effectivelyReversed`).
## - **Excluded:** the plot's filters (the Filters menu, the Aux traces too
##   when that is on) never touch the trace; its own filter still runs, if
##   it has one (`plotFiltersIn` says it to the readers as an own filter that
##   runs instead of the plot's).
## - **Own filter:** a trace's frequency filters (`OwnFilter`), run after
##   the plot's or instead of them. A killed trace keeps its filter; the
##   kill wins on screen (the row stays blank).
## - **Time shift:** a whole number of samples (`ShiftEntry`), given in
##   milliseconds and snapped to the sample interval. Positive is later.
##   The trace keeps its length; samples past an end are lost and that end
##   is zeros. Applied before the plot's filters and the own filter, on
##   seismic traces only (a stored shift on an auxiliary trace is not
##   applied). A killed trace keeps its shift; the kill wins on screen.
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

import std/[algorithm, math]
import processing

export OwnFilter, FilterPlace, FilterEntry, NotchFilter, filterWords, bounded, ownPerTrace

const
  MaxSteps* = 1000 ## steps kept per file for undo, the oldest dropped first
  MaxHeldTraces* = 20_000_000
    ## the traces the steps of one file's history name at most, all told
    ## (about 160 MB), the oldest steps dropped first; the newest is kept
    ## whatever its size
  MaxShiftMs* = 600_000.0
    ## Ten minutes. No record is longer, and the sample count stays far
    ## from overflow.

type
  TraceEdit* = enum
    ## What an edit does to a trace.
    teReversed = "reversed" ## polarity reversed: 180 degrees out of phase
    teKilled = "killed"     ## drawn blank, left out of the panel's levels
    teExcluded = "excluded" ## never touched by the plot's filters

  StepKind* = enum
    skNone = "none"          ## no step: nothing to undo or redo
    skChange = "change"      ## an edit given to some traces or taken away
    skClear = "clear"        ## every edit taken away
    skAllReversed = "all"    ## the polarity of every trace reversed, or put back
    skImport = "import"      ## edits taken in from a file
    skSetAside = "set aside" ## every edit taken away: the file changed on disk
    skFilter = "filter"      ## a trace's own filter set or removed
    skTimeShift = "shift"    ## a trace's time shift set or removed
    skDrop = "drop"          ## edits taken off the traces named, as one step

  ListsChange = object
    ## What a step does to the lists kept, where that is not what it does
    ## to those shown.
    added, removed: array[TraceEdit, seq[int]]
    allChanged, allBefore, allAfter: bool
    filterOn, filterOff: seq[FilterSnap]
    shiftOn, shiftOff: seq[ShiftSnap]

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
    filterOn*, filterOff*: seq[FilterSnap]
      ## skFilter, and a clear or an import that moved filters: each changed
      ## trace's filter after the step, and before it
    shiftOn*, shiftOff*: seq[ShiftSnap]
      ## skTimeShift, and a clear or an import that moved shifts: each changed
      ## trace's shift after the step, and before it
    keptOwn: bool ## what is kept changes by `keptChange`
    keptChange: ListsChange ## what it does to what is kept, with `keptOwn`

  FilterSnap* = object
    ## A trace's own filter at one side of a step.
    trace*: int
    had*: bool         ## it had a filter
    filter*: OwnFilter ## that filter, when `had`

  ShiftEntry* = object
    ## A trace's time shift: the milliseconds actually applied (a whole
    ## number of samples at the interval it was snapped to). Positive is later.
    trace*: int
    ms*: float64

  ShiftSnap* = object
    ## A trace's time shift at one side of a step.
    trace*: int
    had*: bool   ## it had a shift
    ms*: float64 ## that shift, when `had`

  EditLists* = object
    ## A file's edits: each list ascending, each trace once. `filters` and
    ## `shifts` are ascending by trace, each trace once.
    lists*: array[TraceEdit, seq[int]]
    allReversed*: bool
    filters*: seq[FilterEntry]
    shifts*: seq[ShiftEntry]

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
  not l.allReversed and l.lists[teReversed].len == 0 and l.lists[teKilled].len == 0 and
    l.lists[teExcluded].len == 0 and l.filters.len == 0 and l.shifts.len == 0

func count*(l: EditLists): int =
  ## How many edits `l` holds: traces per list, a filter as one, a shift as
  ## one, and all reversed as one.
  l.lists[teReversed].len + l.lists[teKilled].len + l.lists[teExcluded].len + l.filters.len +
    l.shifts.len + ord(l.allReversed)

func placeOf(filters: openArray[FilterEntry]; trace: int): tuple[at: int; found: bool] =
  ## Where `trace` sits in `filters` (ascending), and whether it is there.
  var lo = 0
  var hi = filters.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if filters[mid].trace < trace: lo = mid + 1
    else: hi = mid
  (lo, lo < filters.len and filters[lo].trace == trace)

func hasFilter*(l: EditLists; trace: int): bool {.inline.} =
  ## Whether trace `trace` carries a filter.
  placeOf(l.filters, trace).found

func filterOf*(l: EditLists; trace: int): OwnFilter =
  ## The filter trace `trace` carries; the default (none stored) when it has none.
  let (at, found) = placeOf(l.filters, trace)
  if found: l.filters[at].filter else: OwnFilter()

func snapOf(l: EditLists; trace: int): FilterSnap =
  ## Trace `trace`'s filter as a step would put it back.
  let (at, found) = placeOf(l.filters, trace)
  if found: FilterSnap(trace: trace, had: true, filter: l.filters[at].filter)
  else: FilterSnap(trace: trace, had: false)

func snapsAll(l: EditLists; had: bool): seq[FilterSnap] =
  ## Every filter of `l`, as snaps with `had` (false: each removed).
  result = newSeqOfCap[FilterSnap](l.filters.len)
  for e in l.filters:
    result.add FilterSnap(trace: e.trace, had: had, filter: e.filter)

proc assignFilter(l: var EditLists; trace: int; had: bool; f: OwnFilter) =
  ## Puts `f` on trace `trace` (`had`), or takes its filter away.
  let (at, found) = placeOf(l.filters, trace)
  if had:
    if found: l.filters[at].filter = f
    else: l.filters.insert(FilterEntry(trace: trace, filter: f), at)
  elif found:
    l.filters.delete(at)

proc applySnaps(l: var EditLists; snaps: openArray[FilterSnap]) =
  for s in snaps: l.assignFilter(s.trace, s.had, s.filter)

func filtersIn*(l: EditLists; traces: Slice[int]): seq[FilterEntry] =
  ## The filters of traces in `traces`, ascending.
  let (a, _) = placeOf(l.filters, traces.a)
  result = newSeqOfCap[FilterEntry](l.filters.len - a)
  for i in a ..< l.filters.len:
    if l.filters[i].trace > traces.b: break
    result.add l.filters[i]

func anyFilter*(l: EditLists; traces: Slice[int]): bool =
  ## Whether a trace in `traces` carries a filter.
  let (a, _) = placeOf(l.filters, traces.a)
  a < l.filters.len and l.filters[a].trace <= traces.b

func placeShift(shifts: openArray[ShiftEntry]; trace: int): tuple[at: int; found: bool] =
  ## Where `trace` sits in `shifts` (ascending), and whether it is there.
  var lo = 0
  var hi = shifts.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if shifts[mid].trace < trace: lo = mid + 1
    else: hi = mid
  (lo, lo < shifts.len and shifts[lo].trace == trace)

func shiftAt*(shifts: openArray[ShiftEntry]; trace: int): float64 =
  ## The stored shift of `trace`, in milliseconds; 0 when it has none.
  let (at, found) = placeShift(shifts, trace)
  if found: shifts[at].ms else: 0.0

func hasShift*(l: EditLists; trace: int): bool {.inline.} =
  ## Whether trace `trace` carries a time shift.
  placeShift(l.shifts, trace).found

func shiftOf*(l: EditLists; trace: int): float64 =
  ## The shift trace `trace` carries, in milliseconds; 0 when it has none.
  shiftAt(l.shifts, trace)

func snapShift(l: EditLists; trace: int): ShiftSnap =
  ## Trace `trace`'s shift as a step would put it back.
  let (at, found) = placeShift(l.shifts, trace)
  if found: ShiftSnap(trace: trace, had: true, ms: l.shifts[at].ms)
  else: ShiftSnap(trace: trace, had: false)

func snapsAllShifts(l: EditLists; had: bool): seq[ShiftSnap] =
  ## Every shift of `l`, as snaps with `had` (false: each removed).
  result = newSeqOfCap[ShiftSnap](l.shifts.len)
  for e in l.shifts:
    result.add ShiftSnap(trace: e.trace, had: had, ms: e.ms)

proc assignShift(l: var EditLists; trace: int; had: bool; ms: float64) =
  ## Puts a shift of `ms` on trace `trace` (`had`), or takes its shift away.
  let (at, found) = placeShift(l.shifts, trace)
  if had:
    if found: l.shifts[at].ms = ms
    else: l.shifts.insert(ShiftEntry(trace: trace, ms: ms), at)
  elif found:
    l.shifts.delete(at)

proc applyShiftSnaps(l: var EditLists; snaps: openArray[ShiftSnap]) =
  for s in snaps: l.assignShift(s.trace, s.had, s.ms)

func shiftsIn*(l: EditLists; traces: Slice[int]): seq[ShiftEntry] =
  ## The shifts of traces in `traces`, ascending. Empty, and no allocation,
  ## when none of them is shifted.
  let (a, _) = placeShift(l.shifts, traces.a)
  if a >= l.shifts.len or l.shifts[a].trace > traces.b: return
  result = newSeqOfCap[ShiftEntry](l.shifts.len - a)
  for i in a ..< l.shifts.len:
    if l.shifts[i].trace > traces.b: break
    result.add l.shifts[i]

func anyShift*(l: EditLists; traces: Slice[int]): bool =
  ## Whether a trace in `traces` carries a time shift.
  let (a, _) = placeShift(l.shifts, traces.a)
  a < l.shifts.len and l.shifts[a].trace <= traces.b

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

func effectivelyReversed*(e: FileEdits; trace: int): bool {.inline.} =
  ## Whether trace `trace` is reversed as the picture shows it, and as every
  ## graph must: reversed on its own, or every trace of the file is, but not
  ## both. Both ways is as recorded. The one answer to "is this trace
  ## effectively reversed".
  e.has(teReversed, trace) xor e.allReversed

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
  ## The edits of `a` that `b` does not have (all reversed included). A
  ## filter `b` holds with a different spec is one `b` does not have. A
  ## shift `b` holds of another size is one `b` does not have.
  for edit in TraceEdit: result.lists[edit] = difference(a.lists[edit], b.lists[edit])
  result.allReversed = a.allReversed and not b.allReversed
  for e in a.filters:
    let (at, found) = placeOf(b.filters, e.trace)
    if not found or b.filters[at].filter != e.filter: result.filters.add e
  for e in a.shifts:
    let (at, found) = placeShift(b.shifts, e.trace)
    if not found or b.shifts[at].ms != e.ms: result.shifts.add e

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
  e.shown.anyFilter(traces) or e.shown.anyShift(traces)

func anyKeptIn*(e: FileEdits; traces: Slice[int]): bool =
  ## Whether a trace in `traces` has an edit as kept.
  for edit in TraceEdit:
    if span(e.kept.lists[edit], traces).len > 0: return true
  e.kept.anyFilter(traces) or e.kept.anyShift(traces)

func hasFilter*(e: FileEdits; trace: int): bool {.inline.} =
  ## Whether trace `trace` carries a filter (as shown).
  e.shown.hasFilter(trace)

func ownOf*(e: FileEdits; trace: int): tuple[has: bool; filter: OwnFilter] =
  ## The filter trace `trace` carries (as shown), and whether it has one.
  let s = e.shown.snapOf(trace)
  (s.had, s.filter)

func keptFilter*(e: FileEdits; trace: int): tuple[has: bool; filter: OwnFilter] =
  ## The filter trace `trace` carries as kept.
  let s = e.kept.snapOf(trace)
  (s.had, s.filter)

func filtersIn*(e: FileEdits; traces: Slice[int]): seq[FilterEntry] {.inline.} =
  ## The filters of traces in `traces` (as shown), ascending.
  e.shown.filtersIn(traces)

func hasShift*(e: FileEdits; trace: int): bool {.inline.} =
  ## Whether trace `trace` carries a time shift (as shown).
  e.shown.hasShift(trace)

func shiftOf*(e: FileEdits; trace: int): float64 {.inline.} =
  ## The shift trace `trace` carries (as shown), in milliseconds; 0 for none.
  e.shown.shiftOf(trace)

func keptShift*(e: FileEdits; trace: int): float64 {.inline.} =
  ## The shift trace `trace` carries as kept, in milliseconds; 0 for none.
  e.kept.shiftOf(trace)

func shiftsIn*(e: FileEdits; traces: Slice[int]): seq[ShiftEntry] {.inline.} =
  ## The shifts of traces in `traces` (as shown), ascending.
  e.shown.shiftsIn(traces)

func plotFiltersIn*(e: FileEdits; traces: Slice[int]): seq[FilterEntry] =
  ## The own filters of traces in `traces` (as shown) as the readers of the
  ## plot's filters need them, ascending: a trace excluded from the plot's
  ## filters runs its own filter (none when it has none) instead of the
  ## plot's. The one place that decides whether the plot's filters apply to a
  ## trace, besides the auxiliary traces' own rule (`Processing.aux`).
  let own = e.shown.filtersIn(traces)
  let ex = e.listIn(teExcluded, traces)
  if ex.len == 0: return own
  result = newSeqOfCap[FilterEntry](own.len + ex.len)
  var i = 0
  var j = 0
  while i < own.len or j < ex.len:
    let t = if j >= ex.len or (i < own.len and own[i].trace <= ex[j]): own[i].trace else: ex[j]
    var entry = FilterEntry(trace: t)
    if i < own.len and own[i].trace == t:
      entry = own[i]
      inc i
    if j < ex.len and ex[j] == t:
      inc j
      entry.filter.place = fpInstead
    result.add entry

func ownNeedsWhole*(e: FileEdits; traces: Slice[int]): bool =
  ## Whether a trace in `traces` has a frequency filter of its own: the
  ## reader then keeps whole traces, as it does while the plot filters.
  for f in e.shown.filtersIn(traces):
    if f.filter.spec.hasFilters: return true
  false

func shiftMargin*(e: FileEdits; traces: Slice[int]; dtMs: float64): int =
  ## Samples a window must keep on each side so a shift of a trace in
  ## `traces` is not lost before the move: the largest whole-sample shift
  ## among them. 0 when none is shifted, or `dtMs` is not an interval.
  let shifts = e.shown.shifts
  let (a, _) = placeShift(shifts, traces.a)
  var margin = 0
  for i in a ..< shifts.len:
    if shifts[i].trace > traces.b: break
    let k = wholeShiftSamples(shifts[i].ms, dtMs)
    if k > margin: margin = k
  margin

proc turn(l: var EditLists; added, removed: array[TraceEdit, seq[int]];
    allChanged, allTo: bool) =
  ## Takes `removed` away from `l` and gives it `added`, and all reversed
  ## `allTo` when `allChanged`.
  for edit in TraceEdit:
    if removed[edit].len > 0: l.lists[edit] = difference(l.lists[edit], removed[edit])
    if added[edit].len > 0: l.lists[edit] = union(l.lists[edit], added[edit])
  if allChanged: l.allReversed = allTo

proc turnShown(l: var EditLists; s: EditStep; back: bool) =
  if back:
    l.turn(s.removed, s.added, s.allChanged, s.allBefore)
    l.applySnaps(s.filterOff)
    l.applyShiftSnaps(s.shiftOff)
  else:
    l.turn(s.added, s.removed, s.allChanged, s.allAfter)
    l.applySnaps(s.filterOn)
    l.applyShiftSnaps(s.shiftOn)

proc turnKept(l: var EditLists; s: EditStep; back: bool) =
  if not s.keptOwn: l.turnShown(s, back)
  else:
    template c: untyped = s.keptChange
    if back:
      l.turn(c.removed, c.added, c.allChanged, c.allBefore)
      l.applySnaps(c.filterOff)
      l.applyShiftSnaps(c.shiftOff)
    else:
      l.turn(c.added, c.removed, c.allChanged, c.allAfter)
      l.applySnaps(c.filterOn)
      l.applyShiftSnaps(c.shiftOn)

func size(s: EditStep): int =
  ## The traces `s` names, all told.
  result = s.traces.len + s.filterOn.len + s.filterOff.len + s.shiftOn.len + s.shiftOff.len
  for edit in TraceEdit:
    result += s.added[edit].len + s.removed[edit].len +
      s.keptChange.added[edit].len + s.keptChange.removed[edit].len
  result += s.keptChange.filterOn.len + s.keptChange.filterOff.len
  result += s.keptChange.shiftOn.len + s.keptChange.shiftOff.len

proc keptChanges(s: var EditStep; c: sink ListsChange) =
  ## `c` is what `s` does to what is kept; noted apart only where it is not
  ## what `s` does to what is shown.
  if c.added != s.added or c.removed != s.removed or c.allChanged != s.allChanged or
      (c.allChanged and (c.allBefore, c.allAfter) != (s.allBefore, s.allAfter)) or
      c.filterOn != s.filterOn or c.filterOff != s.filterOff or
      c.shiftOn != s.shiftOn or c.shiftOff != s.shiftOff:
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
    s.filterOff = e.shown.snapsAll(true)
    s.filterOn = e.shown.snapsAll(false)
    s.shiftOff = e.shown.snapsAllShifts(true)
    s.shiftOn = e.shown.snapsAllShifts(false)
    s.keptChanges(ListsChange(removed: e.kept.lists, allChanged: e.kept.allReversed,
      allBefore: true, filterOff: e.kept.snapsAll(true), filterOn: e.kept.snapsAll(false),
      shiftOff: e.kept.snapsAllShifts(true), shiftOn: e.kept.snapsAllShifts(false)))
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

proc filterDelta(before, after: EditLists): tuple[off, on: seq[FilterSnap]; n: int] =
  ## The traces whose filter differs, as snaps before (`off`) and after (`on`).
  var i, j = 0
  while i < before.filters.len or j < after.filters.len:
    let ti = if i < before.filters.len: before.filters[i].trace else: high(int)
    let tj = if j < after.filters.len: after.filters[j].trace else: high(int)
    if ti == tj:
      if before.filters[i].filter != after.filters[j].filter:
        result.off.add FilterSnap(trace: ti, had: true, filter: before.filters[i].filter)
        result.on.add FilterSnap(trace: ti, had: true, filter: after.filters[j].filter)
        inc result.n
      inc i
      inc j
    elif ti < tj:
      result.off.add FilterSnap(trace: ti, had: true, filter: before.filters[i].filter)
      result.on.add FilterSnap(trace: ti, had: false)
      inc result.n
      inc i
    else:
      result.off.add FilterSnap(trace: tj, had: false)
      result.on.add FilterSnap(trace: tj, had: true, filter: after.filters[j].filter)
      inc result.n
      inc j

proc filterAdded(have, incoming: EditLists): tuple[off, on: seq[FilterSnap]; n: int] =
  ## Filters of `incoming` that `have` does not, as snaps (an existing filter
  ## is left as it is).
  for e in incoming.filters:
    if not have.hasFilter(e.trace):
      result.off.add FilterSnap(trace: e.trace, had: false)
      result.on.add FilterSnap(trace: e.trace, had: true, filter: e.filter)
      inc result.n

proc unionFilters(l: var EditLists; extra: EditLists) =
  ## Adds the filters of `extra` that `l` does not have. One `l` already has
  ## stays: a filter set this session is not overwritten by one remembered.
  for e in extra.filters:
    if not l.hasFilter(e.trace): l.assignFilter(e.trace, true, e.filter)

proc shiftDelta(before, after: EditLists): tuple[off, on: seq[ShiftSnap]; n: int] =
  ## The traces whose shift differs, as snaps before (`off`) and after (`on`).
  var i, j = 0
  while i < before.shifts.len or j < after.shifts.len:
    let ti = if i < before.shifts.len: before.shifts[i].trace else: high(int)
    let tj = if j < after.shifts.len: after.shifts[j].trace else: high(int)
    if ti == tj:
      if before.shifts[i].ms != after.shifts[j].ms:
        result.off.add ShiftSnap(trace: ti, had: true, ms: before.shifts[i].ms)
        result.on.add ShiftSnap(trace: ti, had: true, ms: after.shifts[j].ms)
        inc result.n
      inc i
      inc j
    elif ti < tj:
      result.off.add ShiftSnap(trace: ti, had: true, ms: before.shifts[i].ms)
      result.on.add ShiftSnap(trace: ti, had: false)
      inc result.n
      inc i
    else:
      result.off.add ShiftSnap(trace: tj, had: false)
      result.on.add ShiftSnap(trace: tj, had: true, ms: after.shifts[j].ms)
      inc result.n
      inc j

proc shiftAdded(have, incoming: EditLists): tuple[off, on: seq[ShiftSnap]; n: int] =
  ## Shifts of `incoming` that `have` does not, as snaps (an existing shift
  ## is left as it is).
  for e in incoming.shifts:
    if not have.hasShift(e.trace):
      result.off.add ShiftSnap(trace: e.trace, had: false)
      result.on.add ShiftSnap(trace: e.trace, had: true, ms: e.ms)
      inc result.n

proc unionShifts(l: var EditLists; extra: EditLists) =
  ## Adds the shifts of `extra` that `l` does not have. One `l` already has
  ## stays: a shift set this session is not overwritten by one remembered.
  for e in extra.shifts:
    if not l.hasShift(e.trace): l.assignShift(e.trace, true, e.ms)

proc preferShifts(a, b: EditLists): seq[ShiftEntry] =
  ## The shifts of `a` and of `b`, ascending; where both name a trace, `a`'s.
  result = newSeqOfCap[ShiftEntry](a.shifts.len + b.shifts.len)
  var i, j = 0
  while i < a.shifts.len or j < b.shifts.len:
    let ti = if i < a.shifts.len: a.shifts[i].trace else: high(int)
    let tj = if j < b.shifts.len: b.shifts[j].trace else: high(int)
    if ti <= tj:
      result.add a.shifts[i]
      if ti == tj: inc j
      inc i
    else:
      result.add b.shifts[j]
      inc j

proc preferFilters(a, b: EditLists): seq[FilterEntry] =
  ## The filters of `a` and of `b`, ascending; where both name a trace, `a`'s.
  result = newSeqOfCap[FilterEntry](a.filters.len + b.filters.len)
  var i, j = 0
  while i < a.filters.len or j < b.filters.len:
    let ti = if i < a.filters.len: a.filters[i].trace else: high(int)
    let tj = if j < b.filters.len: b.filters[j].trace else: high(int)
    if ti <= tj:
      result.add a.filters[i]
      if ti == tj: inc j
      inc i
    else:
      result.add b.filters[j]
      inc j

proc setOwnFilters*(e: var FileEdits; traces: openArray[int]; f: OwnFilter; keep = true): int =
  ## Gives every trace of `traces` the filter `f` (already bounded), as one
  ## step (in what is kept too with `keep`). Returns how many changed; a
  ## change of none makes no step. Raises `ValueError` for a negative index.
  var shownChanged, keptChanged: seq[int]
  var off, on, kOff, kOn: seq[FilterSnap]
  for t in sortedTraces(traces):
    let want = FilterSnap(trace: t, had: true, filter: f)
    let s = e.shown.snapOf(t)
    if s != want:
      shownChanged.add t
      off.add s
      on.add want
    if keep:
      let k = e.kept.snapOf(t)
      if k != want:
        keptChanged.add t
        kOff.add k
        kOn.add want
  result = shownChanged.len
  if keep and result == 0: result = keptChanged.len
  if result > 0:
    var step = EditStep(kind: skFilter, on: true,
      traces: if shownChanged.len > 0: shownChanged else: keptChanged,
      filterOff: off, filterOn: on)
    step.keptChanges(ListsChange(filterOff: kOff, filterOn: kOn))
    e.make(step, keep)

func shiftStorable*(ms: float64): bool =
  ## Whether `ms` may be stored as a time shift: finite, and not past
  ## `MaxShiftMs` either way.
  ms == ms and ms != Inf and ms != -Inf and abs(ms) <= MaxShiftMs

proc setTimeShifts*(e: var FileEdits; traces: openArray[int]; ms, dtMs: float64;
    keep = true): int =
  ## Gives every trace of `traces` a time shift of `ms` milliseconds, snapped
  ## to a whole sample at `dtMs` (the stored value is the one applied), as
  ## one step (in what is kept too with `keep`). A snap of no sample takes
  ## the shift away. Returns how many changed; a change of none makes no
  ## step. A `dtMs` that is not a usable interval, or an `ms` that
  ## `shiftStorable` refuses, changes nothing. Raises `ValueError` for a
  ## negative index.
  if not (dtMs > 0) or not shiftStorable(ms): return 0
  let snapped = snappedShiftMs(ms, dtMs)
  let had = snapped != 0.0
  var shownChanged, keptChanged: seq[int]
  var off, on, kOff, kOn: seq[ShiftSnap]
  for t in sortedTraces(traces):
    let want = ShiftSnap(trace: t, had: had, ms: if had: snapped else: 0.0)
    let s = e.shown.snapShift(t)
    if s.had != want.had or (s.had and s.ms != want.ms):
      shownChanged.add t
      off.add s
      on.add want
    if keep:
      let k = e.kept.snapShift(t)
      if k.had != want.had or (k.had and k.ms != want.ms):
        keptChanged.add t
        kOff.add k
        kOn.add want
  result = shownChanged.len
  if keep and result == 0: result = keptChanged.len
  if result > 0:
    var step = EditStep(kind: skTimeShift, on: had,
      traces: if shownChanged.len > 0: shownChanged else: keptChanged,
      shiftOff: off, shiftOn: on)
    step.keptChanges(ListsChange(shiftOff: kOff, shiftOn: kOn))
    e.make(step, keep)

proc clearTimeShifts*(e: var FileEdits; traces: openArray[int]; keep = true): int =
  ## Takes the time shift off every trace of `traces`, as one step (in what
  ## is kept too with `keep`). Returns how many had one taken away, or caught
  ## up in what is kept. Raises `ValueError` for a negative index.
  var shownChanged, keptChanged: seq[int]
  var off, on, kOff, kOn: seq[ShiftSnap]
  for t in sortedTraces(traces):
    let s = e.shown.snapShift(t)
    if s.had:
      shownChanged.add t
      off.add s
      on.add ShiftSnap(trace: t, had: false)
    if keep:
      let k = e.kept.snapShift(t)
      if k.had:
        keptChanged.add t
        kOff.add k
        kOn.add ShiftSnap(trace: t, had: false)
  result = shownChanged.len
  if keep and result == 0: result = keptChanged.len
  if result > 0:
    var step = EditStep(kind: skTimeShift, on: false,
      traces: if shownChanged.len > 0: shownChanged else: keptChanged,
      shiftOff: off, shiftOn: on)
    step.keptChanges(ListsChange(shiftOff: kOff, shiftOn: kOn))
    e.make(step, keep)

proc dropEdits*(e: var FileEdits; traces: openArray[int]; kinds: set[TraceEdit];
    filters: bool; keep = true; shifts = false): int =
  ## Takes `kinds` and, with `filters`, the own filter, and with `shifts`
  ## the time shift, off every trace of `traces`, as one step (in what is
  ## kept too with `keep`). Returns how many traces changed; a change of
  ## none makes no step. Raises `ValueError` for a negative index.
  var shownChanged, keptChanged: seq[int]
  var removed, kRemoved: array[TraceEdit, seq[int]]
  var off, on, kOff, kOn: seq[FilterSnap]
  var sOff, sOn, ksOff, ksOn: seq[ShiftSnap]
  for t in sortedTraces(traces):
    var shown, kept = false
    for edit in kinds:
      if e.has(edit, t):
        removed[edit].add t
        shown = true
      if keep and e.keptHas(edit, t):
        kRemoved[edit].add t
        kept = true
    if filters:
      let s = e.shown.snapOf(t)
      if s.had:
        off.add s
        on.add FilterSnap(trace: t, had: false)
        shown = true
      if keep:
        let k = e.kept.snapOf(t)
        if k.had:
          kOff.add k
          kOn.add FilterSnap(trace: t, had: false)
          kept = true
    if shifts:
      let s = e.shown.snapShift(t)
      if s.had:
        sOff.add s
        sOn.add ShiftSnap(trace: t, had: false)
        shown = true
      if keep:
        let k = e.kept.snapShift(t)
        if k.had:
          ksOff.add k
          ksOn.add ShiftSnap(trace: t, had: false)
          kept = true
    if shown: shownChanged.add t
    elif kept: keptChanged.add t
  result = shownChanged.len
  if keep and result == 0: result = keptChanged.len
  if result > 0:
    var step = EditStep(kind: skDrop, on: false,
      traces: if shownChanged.len > 0: shownChanged else: keptChanged,
      removed: removed, filterOff: off, filterOn: on, shiftOff: sOff, shiftOn: sOn)
    step.keptChanges(ListsChange(removed: kRemoved, filterOff: kOff, filterOn: kOn,
      shiftOff: ksOff, shiftOn: ksOn))
    e.make(step, keep)

proc clearOwnFilters*(e: var FileEdits; traces: openArray[int]; keep = true): int =
  ## Takes the filter off every trace of `traces`, as one step (in what is
  ## kept too with `keep`). Returns how many had one taken away, or caught
  ## up in what is kept. Raises `ValueError` for a negative index.
  var shownChanged, keptChanged: seq[int]
  var off, on, kOff, kOn: seq[FilterSnap]
  for t in sortedTraces(traces):
    let s = e.shown.snapOf(t)
    if s.had:
      shownChanged.add t
      off.add s
      on.add FilterSnap(trace: t, had: false)
    if keep:
      let k = e.kept.snapOf(t)
      if k.had:
        keptChanged.add t
        kOff.add k
        kOn.add FilterSnap(trace: t, had: false)
  result = shownChanged.len
  if keep and result == 0: result = keptChanged.len
  if result > 0:
    var step = EditStep(kind: skFilter, on: false,
      traces: if shownChanged.len > 0: shownChanged else: keptChanged,
      filterOff: off, filterOn: on)
    step.keptChanges(ListsChange(filterOff: kOff, filterOn: kOn))
    e.make(step, keep)

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
  let shownF = filterDelta(e.shown, l)
  let keptF = filterDelta(e.kept, l)
  s.filterOff = shownF.off
  s.filterOn = shownF.on
  c.filterOff = keptF.off
  c.filterOn = keptF.on
  result += shownF.n
  kept += keptF.n
  let shownS = shiftDelta(e.shown, l)
  let keptS = shiftDelta(e.kept, l)
  s.shiftOff = shownS.off
  s.shiftOn = shownS.on
  c.shiftOff = keptS.off
  c.shiftOn = keptS.on
  result += shownS.n
  kept += keptS.n
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
  let shownF = filterAdded(e.shown, l)
  let keptF = filterAdded(e.kept, l)
  s.filterOff = shownF.off
  s.filterOn = shownF.on
  c.filterOff = keptF.off
  c.filterOn = keptF.on
  result += shownF.n
  kept += keptF.n
  let shownS = shiftAdded(e.shown, l)
  let keptS = shiftAdded(e.kept, l)
  s.shiftOff = shownS.off
  s.shiftOn = shownS.on
  c.shiftOff = keptS.off
  c.shiftOn = keptS.on
  result += shownS.n
  kept += keptS.n
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
  e.shown.unionFilters(l)
  e.kept.unionFilters(l)
  e.shown.unionShifts(l)
  e.kept.unionShifts(l)
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
  e.shown.filters = preferFilters(e.shown, other.shown)
  e.kept.filters = preferFilters(e.kept, other.kept)
  e.shown.shifts = preferShifts(e.shown, other.shown)
  e.kept.shifts = preferShifts(e.kept, other.kept)
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
  var i, j = 0
  while i < e.kept.filters.len or j < l.filters.len:
    let ti = if i < e.kept.filters.len: e.kept.filters[i].trace else: high(int)
    let tj = if j < l.filters.len: l.filters[j].trace else: high(int)
    let t = min(ti, tj)
    let before = if ti == t: FilterSnap(trace: t, had: true, filter: e.kept.filters[i].filter)
                 else: FilterSnap(trace: t, had: false)
    let after = if tj == t: FilterSnap(trace: t, had: true, filter: l.filters[j].filter)
                else: FilterSnap(trace: t, had: false)
    if before != after and e.shown.snapOf(t) == before:
      e.shown.assignFilter(t, after.had, after.filter)
    if ti == t: inc i
    if tj == t: inc j
  i = 0
  j = 0
  while i < e.kept.shifts.len or j < l.shifts.len:
    let ti = if i < e.kept.shifts.len: e.kept.shifts[i].trace else: high(int)
    let tj = if j < l.shifts.len: l.shifts[j].trace else: high(int)
    let t = min(ti, tj)
    let before = if ti == t: ShiftSnap(trace: t, had: true, ms: e.kept.shifts[i].ms)
                 else: ShiftSnap(trace: t, had: false)
    let after = if tj == t: ShiftSnap(trace: t, had: true, ms: l.shifts[j].ms)
                else: ShiftSnap(trace: t, had: false)
    if (before.had != after.had or (before.had and before.ms != after.ms)) and
        e.shown.snapShift(t) == before:
      e.shown.assignShift(t, after.had, after.ms)
    if ti == t: inc i
    if tj == t: inc j
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
  for snap in s.filterOn:
    if snap.trace in traces: return true
  for snap in s.filterOff:
    if snap.trace in traces: return true
  for snap in s.shiftOn:
    if snap.trace in traces: return true
  for snap in s.shiftOff:
    if snap.trace in traces: return true
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
    n += s.filterOn.len + s.shiftOn.len
    if n == 0 and s.keptOwn: # shown already (an agent's), kept by the import
      n = ord(s.keptChange.allChanged)
      for edit in TraceEdit: n += s.keptChange.added[edit].len
      n += s.keptChange.filterOn.len + s.keptChange.shiftOn.len
    $n & (if n == 1: " edit" else: " edits") & " imported from " & s.source
  of skChange:
    let what = tracesText(s.traces)
    case s.edit
    of teKilled: what & (if s.on: " killed" else: " restored")
    of teReversed: "polarity of " & what & (if s.on: " reversed" else: " put back")
    of teExcluded:
      what & (if s.on: " excluded from the plot's filters" else: " given the plot's filters again")
  of skFilter:
    let what = tracesText(s.traces)
    if s.on: what & " filtered"
    elif s.traces.len == 1: "filter of " & what & " removed"
    else: "filters of " & what & " removed"
  of skTimeShift:
    let what = tracesText(s.traces)
    if s.on: what & " shifted"
    elif s.traces.len == 1: "shift of " & what & " removed"
    else: "shifts of " & what & " removed"
  of skDrop: "edits of " & tracesText(s.traces) & " removed"

func undoText*(e: FileEdits): string =
  ## `describe` of the step `undo` takes back, without a copy of it (the
  ## Edit menu asks every frame); "" for none.
  if e.undos.len > 0: describe(e.undos[e.undos.high]) else: ""

func mergedFilters*(base, ours, theirs: EditLists): seq[FilterEntry] =
  ## The filters of a document two programs changed from `base`: a trace
  ## this program (`ours`) changed keeps `ours` (a removal included); a
  ## trace it left keeps `theirs`.
  var traces = newSeqOfCap[int](base.filters.len + ours.filters.len + theirs.filters.len)
  for e in base.filters: traces.add e.trace
  for e in ours.filters: traces.add e.trace
  for e in theirs.filters: traces.add e.trace
  traces.sort()
  var n = 0
  for t in traces:
    if n == 0 or traces[n - 1] != t:
      traces[n] = t
      inc n
  traces.setLen n
  result = newSeqOfCap[FilterEntry](n)
  for t in traces:
    let use = if base.snapOf(t) != ours.snapOf(t): ours.snapOf(t) else: theirs.snapOf(t)
    if use.had: result.add FilterEntry(trace: t, filter: use.filter)

func mergedShifts*(base, ours, theirs: EditLists): seq[ShiftEntry] =
  ## The shifts of a document two programs changed from `base`: a trace
  ## this program (`ours`) changed keeps `ours` (a removal included); a
  ## trace it left keeps `theirs`.
  var traces = newSeqOfCap[int](base.shifts.len + ours.shifts.len + theirs.shifts.len)
  for e in base.shifts: traces.add e.trace
  for e in ours.shifts: traces.add e.trace
  for e in theirs.shifts: traces.add e.trace
  traces.sort()
  var n = 0
  for t in traces:
    if n == 0 or traces[n - 1] != t:
      traces[n] = t
      inc n
  traces.setLen n
  result = newSeqOfCap[ShiftEntry](n)
  for t in traces:
    let use = if base.snapShift(t) != ours.snapShift(t): ours.snapShift(t)
              else: theirs.snapShift(t)
    if use.had: result.add ShiftEntry(trace: t, ms: use.ms)

func redoText*(e: FileEdits): string =
  ## `describe` of the step `redo` makes again, without a copy of it; ""
  ## for none.
  if e.redos.len > 0: describe(e.redos[e.redos.high]) else: ""
