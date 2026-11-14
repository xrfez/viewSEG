## The linked selection: the trace under the cursor, the selected traces and
## the gather on show. The trace panel, the map and the header table all read
## it and change it through `Command`s; no view talks to another.
##
## Trace ids are survey-wide (`Session.base` + the trace's index), so the
## views treat one file and a survey of many files alike.

import std/intsets
import session

export intsets

type
  GatherRef* = object
    ## A gather of an open file.
    file*: SessionId ## `NoSession` for none
    gather*: int = -1

  SelectMode* = enum
    smReplace = "replace" ## the traces become the selection
    smAdd = "add"         ## the traces join the selection
    smToggle = "toggle"   ## each trace is selected unless it was, then not (Shift + click)

  Selection* = object
    hover*: int = -1       ## the trace under the cursor; -1 for none
    selected*: IntSet      ## the selected traces
    activeGather*: GatherRef
    revision*: int         ## bumped on every change
    selectedRevision*: int ## bumped when `selected` changes

proc setHover*(s: var Selection; trace: int): bool =
  ## Puts the cursor on `trace` (-1: none); false when it already was.
  result = s.hover != trace
  if result:
    s.hover = trace
    inc s.revision

proc select*(s: var Selection; traces: openArray[int]; mode: SelectMode) =
  ## Changes the selection by `traces`, as `mode` says.
  if mode == smReplace: s.selected.clear()
  for t in traces:
    if mode == smToggle and t in s.selected: s.selected.excl t
    else: s.selected.incl t
  inc s.revision
  inc s.selectedRevision

proc clear*(s: var Selection) =
  ## Selects nothing.
  if s.selected.len > 0:
    s.selected.clear()
    inc s.revision
    inc s.selectedRevision

proc forget*(s: var Selection; file: SessionId; traces: Slice[int]) =
  ## Drops every mention of a closed file: its traces, its gather.
  var changed = false
  if s.hover in traces:
    s.hover = -1
    changed = true
  var gone: seq[int]
  for t in s.selected:
    if t in traces: gone.add t
  for t in gone: s.selected.excl t
  if gone.len > 0: inc s.selectedRevision
  if s.activeGather.file == file:
    s.activeGather = GatherRef()
    changed = true
  if changed or gone.len > 0:
    inc s.revision
