## Which edited trace a click in the edits row is about, and which removals
## the menu offers. The plot asks; a test checks a position without a window.
##
## A click on a letter mark is that trace. When marks are drawn as outlines
## (zoomed out), a click on the row picks the nearest edited trace within
## `MarkPickPixels`; traces whose centres share that pixel are all of them,
## one removal for the group.

import std/[algorithm, math, strutils]
import edits

export TraceEdit

const MarkPickPixels* = 4.0'f32
  ## A click on the row, when marks are outlines, picks an edited trace this
  ## close along the traces.

type
  EditMark* = object
    ## One edited trace's mark, in screen pixels. `lo`/`hi` and `cross0`/
    ## `cross1` are the drawn mark; `centre` is the trace along the row.
    trace*: int
    centre*: float32
    lo*, hi*: float32
    cross0*, cross1*: float32
    edits*: set[TraceEdit]
    hasFilter*: bool
    outline*: bool
    filterNote*: string ## the filter in words, when `hasFilter`

  MarkHit* = object
    ## The traces a position in the edits row is about. Empty: not a mark.
    traces*: seq[int] ## file indices, ascending
    shared*: bool     ## several traces share the pixel

  TraceEditView* = object
    ## One trace's edits, for the menu (the hit, and the selection).
    trace*: int
    edits*: set[TraceEdit]
    hasFilter*: bool

  MarkItem* = enum
    miRemoveKill
    miRemoveReverse
    miRemoveFilter
    miEditFilter
    miRemoveAll
    miRemoveKillSelected
    miRemoveReverseSelected
    miRemoveFilterSelected

  MarkEntry* = object
    ## One line of the menu. `traces` are file indices, ascending.
    item*: MarkItem
    traces*: seq[int]
    count*: int ## selected traces, or how many the edit-filter line names

func dedupe(traces: var seq[int]) =
  ## `traces` sorted, each value once.
  if traces.len == 0: return
  traces.sort()
  var n = 0
  for t in traces:
    if n == 0 or traces[n - 1] != t:
      traces[n] = t
      inc n
  traces.setLen n

func findView(rows: openArray[TraceEditView]; trace: int): int =
  ## The index of `trace` in `rows` (ascending), or -1.
  var lo = 0
  var hi = rows.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    if rows[mid].trace < trace: lo = mid + 1
    else: hi = mid
  if lo < rows.len and rows[lo].trace == trace: lo else: -1

func viewAt(rows: openArray[TraceEditView]; trace: int): tuple[edits: set[TraceEdit];
    hasFilter: bool] =
  let i = findView(rows, trace)
  if i >= 0: (rows[i].edits, rows[i].hasFilter) else: ({}, false)

proc marksAt*(marks: openArray[EditMark]; along, cross, band0, band1: float32): MarkHit =
  ## The edited traces a point (`along` the traces, `cross` across the row)
  ## is about, when the row occupies `band0`..`band1` across. A letter mark
  ## answers only a point on it. An outline mark answers a point on the row
  ## within `MarkPickPixels` of its centre, and every outline mark that
  ## shares that pixel.
  if cross < band0 or cross > band1: return
  var contained: seq[int]
  var containedOutline = false
  for i, m in marks:
    if along >= m.lo and along <= m.hi and cross >= m.cross0 and cross <= m.cross1:
      contained.add i
      if m.outline: containedOutline = true
  if contained.len > 0 and not containedOutline:
    for i in contained: result.traces.add marks[i].trace
    dedupe(result.traces)
    result.shared = result.traces.len > 1
    return
  var seed = -1
  if contained.len > 0: seed = contained[0]
  else:
    var bestD = MarkPickPixels + 1
    for i, m in marks:
      if m.outline:
        let d = abs(along - m.centre)
        if d <= MarkPickPixels and d < bestD:
          seed = i
          bestD = d
  if seed < 0: return
  let pixel = floor(marks[seed].centre)
  for i, m in marks:
    if (m.outline and floor(m.centre) == pixel) or i in contained:
      result.traces.add m.trace
  dedupe(result.traces)
  result.shared = result.traces.len > 1

func markTitle*(hit: MarkHit): string =
  ## The menu's first line: "N traces here" when several share the pixel,
  ## else the trace's number; "" for none.
  if hit.traces.len == 0: ""
  elif hit.shared: $hit.traces.len & " traces here"
  else: "Trace " & $(hit.traces[0] + 1)

func markTip*(hit: MarkHit; marks: openArray[EditMark]): string =
  ## The tooltip of the marks `hit` names: what they show, then
  ## "Right-click to remove". "" for none.
  if hit.traces.len == 0: return ""
  var edits: set[TraceEdit]
  var notes: seq[string]
  var filtered = false
  for t in hit.traces:
    for m in marks:
      if m.trace == t:
        edits.incl m.edits
        if m.hasFilter:
          filtered = true
          if m.filterNote.len > 0 and m.filterNote notin notes: notes.add m.filterNote
  var parts: seq[string]
  if hit.shared: parts.add $hit.traces.len & " traces here"
  if teKilled in edits: parts.add "Killed"
  if teReversed in edits: parts.add "Polarity reversed"
  if notes.len > 0: parts.add notes.join("\n")
  elif filtered: parts.add "Filtered"
  if parts.len == 0: return ""
  parts.add "Right-click to remove"
  parts.join("\n")

func kindCount(edits: set[TraceEdit]; hasFilter: bool): int =
  ord(teKilled in edits) + ord(teReversed in edits) + ord(hasFilter)

func selectedWord(n: int): string =
  if n == 1: "1 selected trace" else: $n & " selected traces"

func entryText*(e: MarkEntry; shared: bool): string =
  ## The menu line, in the words the plot shows.
  case e.item
  of miRemoveKill: "Remove kill"
  of miRemoveReverse: "Remove reversal"
  of miRemoveFilter: "Remove the trace's filter"
  of miEditFilter:
    if shared and e.count > 1: "Edit the filters of " & $e.count & " traces..."
    else: "Edit the trace's filter..."
  of miRemoveAll:
    if shared: "Remove all edits of these traces"
    else: "Remove all edits of this trace"
  of miRemoveKillSelected: "Remove kill from " & selectedWord(e.count)
  of miRemoveReverseSelected: "Remove reversal from " & selectedWord(e.count)
  of miRemoveFilterSelected: "Remove the filter from " & selectedWord(e.count)

proc withEdit(rows: openArray[TraceEditView]; traces: openArray[int];
    kind: TraceEdit): seq[int] =
  for t in traces:
    if kind in viewAt(rows, t).edits: result.add t

proc withFilter(rows: openArray[TraceEditView]; traces: openArray[int]): seq[int] =
  for t in traces:
    if viewAt(rows, t).hasFilter: result.add t

proc markEntries*(hit: MarkHit; rows: openArray[TraceEditView];
    selected: openArray[int]): seq[MarkEntry] =
  ## The menu for `hit`. `rows` names the hit and the selection (file
  ## indices); `selected` is the file's selected traces. A selection line
  ## is added when a hit trace is selected and another selected trace has
  ## the same edit.
  if hit.traces.len == 0: return
  var indexed = @rows
  indexed.sort(proc (a, b: TraceEditView): int = cmp(a.trace, b.trace))
  let sel = sortedTraces(selected)
  var unionEdits: set[TraceEdit]
  var unionFilter = false
  for t in hit.traces:
    let v = viewAt(indexed, t)
    unionEdits.incl v.edits
    if v.hasFilter: unionFilter = true
  var clickedSelected = false
  for t in hit.traces:
    if sel.binarySearch(t) >= 0: clickedSelected = true
  var entries: seq[MarkEntry]

  proc addKind(item, selectedItem: MarkItem; kind: TraceEdit) =
    if kind notin unionEdits: return
    let here = withEdit(indexed, hit.traces, kind)
    if here.len == 0: return
    entries.add MarkEntry(item: item, traces: here)
    if clickedSelected:
      let all = withEdit(indexed, sel, kind)
      var overlap = false
      if all.len >= 2:
        for t in here:
          if all.binarySearch(t) >= 0: overlap = true
      if overlap:
        entries.add MarkEntry(item: selectedItem, traces: all, count: all.len)

  proc addFilter() =
    if not unionFilter: return
    let here = withFilter(indexed, hit.traces)
    if here.len == 0: return
    entries.add MarkEntry(item: miRemoveFilter, traces: here)
    if clickedSelected:
      let all = withFilter(indexed, sel)
      var overlap = false
      if all.len >= 2:
        for t in here:
          if all.binarySearch(t) >= 0: overlap = true
      if overlap:
        entries.add MarkEntry(item: miRemoveFilterSelected, traces: all, count: all.len)
    entries.add MarkEntry(item: miEditFilter, traces: here, count: here.len)

  addKind(miRemoveKill, miRemoveKillSelected, teKilled)
  addKind(miRemoveReverse, miRemoveReverseSelected, teReversed)
  addFilter()
  if kindCount(unionEdits, unionFilter) > 1:
    entries.add MarkEntry(item: miRemoveAll, traces: hit.traces, count: hit.traces.len)
  result = entries
