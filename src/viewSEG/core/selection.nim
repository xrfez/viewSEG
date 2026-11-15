## The linked selection: the trace under the cursor, the selected traces and
## the gather on show. The trace panel, the map and the header table all read
## it and change it through `Command`s; no view talks to another.
##
## Trace ids are survey-wide (`Session.base` + the trace's index), so the
## views treat one file and a survey of many files alike.
##
## **The hover, both ways.** The trace under the plot's pointer (`hover`)
## comes with the points it was recorded at (`hoverAt`: its source and its
## receiver, in every layer), which the map lights up; the points under the
## map's pointer (`hoverPoints`) come with the traces recorded there
## (`hoverTraces`), which the plot draws in the hover colour. `AppState`
## finds both when the hover changes, so a view only draws what is here.
##
## The map can also select points (`selectPoints`: a box, a click), which may
## have no trace at all (a survey file with no seismic file open): they are
## kept beside the traces, and the map shows both. A selection of traces made
## anew (a click in the plot) replaces them.

import std/[algorithm, intsets]
import session, survey

export intsets

type
  GatherRef* = object
    ## A gather of an open file.
    file*: SessionId ## `NoSession` for none
    gather*: int = -1

  SelectMode* = enum
    smReplace = "replace" ## the traces become the selection (a click)
    smAdd = "add"         ## the traces join the selection
    smToggle = "toggle"   ## each trace is selected unless it was, then not (Ctrl + click)
    smRange = "range"
      ## the traces become the selection, and the anchor stays where it is
      ## (Shift + click: the traces from the anchor to the one clicked)
    smRemove = "remove" ## the traces leave the selection

  Selection* = object
    hover*: int = -1            ## the trace under the plot's pointer; -1 for none
    hoverAt*: seq[PointRef]
      ## where `hover` was recorded: its source and receiver points in every
      ## layer; none for none, or a trace with no position
    hoverPoints*: seq[PointRef] ## the points under the map's pointer; none for none
    hoverTraces*: IntSet
      ## the open files' traces recorded at `hoverPoints`, which the plot
      ## draws as it draws `hover`
    hoveredRevision*: int ## bumped when `hoverTraces` changes
    selected*: IntSet ## the selected traces
    anchor*: int = -1
      ## the trace clicked last (`smReplace` or `smToggle` of one trace),
      ## where a Shift + click's range starts; -1 for none
    pointAnchor*: PointRef
      ## the point clicked last on the map (`selectPoints` of one point,
      ## replaced or toggled): where a Shift + click's range along its line
      ## starts; `NoSurveyLayer` for none
    activeGather*: GatherRef
    points*: seq[PointRef] ## points selected on the map, in the order selected
    pointKeys*: IntSet ## the `key` of each of `points`
    revision*: int ## bumped on every change
    selectedRevision*: int ## bumped when `selected` or `points` changes

func targets*(s: Selection; under: int): seq[int] =
  ## What a trace operation (kill, reverse polarity) acts on with the
  ## pointer over trace `under`: every selected trace when `under` is one of
  ## them, else `under` alone, ascending; none for -1.
  if under < 0: return
  if under in s.selected:
    for t in s.selected: result.add t
    result.sort()
  else: result = @[under]

proc setHover*(s: var Selection; trace: int; at: seq[PointRef] = @[]): bool =
  ## Puts the plot's pointer on `trace` (-1: none), recorded at points `at`;
  ## false when it already was there.
  result = s.hover != trace
  if result:
    s.hover = trace
    s.hoverAt = if trace >= 0: at else: @[]
    inc s.revision

proc setHoverAt*(s: var Selection; at: seq[PointRef]) =
  ## Where the hovered trace was recorded, found again (the survey changed).
  if at != s.hoverAt:
    s.hoverAt = at
    inc s.revision

proc setHoverPoints*(s: var Selection; points: seq[PointRef]; traces: IntSet) =
  ## Puts the map's pointer on `points` (none: off every point), at which
  ## `traces` were recorded.
  if points != s.hoverPoints or traces != s.hoverTraces:
    if traces != s.hoverTraces:
      s.hoverTraces = traces
      inc s.hoveredRevision
    s.hoverPoints = points
    inc s.revision

proc select*(s: var Selection; traces: openArray[int]; mode: SelectMode) =
  ## Changes the selection by `traces`, as `mode` says. One trace replaced
  ## or toggled becomes the anchor of the next range.
  ## A new selection (`smReplace`, `smRange`) takes the map's points away.
  if mode in {smReplace, smRange}:
    s.selected.clear()
    s.points.setLen 0
    s.pointKeys.clear()
  if mode in {smReplace, smToggle} and traces.len == 1: s.anchor = traces[0]
  for t in traces:
    if mode == smRemove or (mode == smToggle and t in s.selected): s.selected.excl t
    else: s.selected.incl t
  inc s.revision
  inc s.selectedRevision

proc selectPoints*(s: var Selection; points: openArray[PointRef]; mode: SelectMode) =
  ## Changes the map's selected points by `points`, as `mode` says (a range
  ## is taken as a replace: the caller gives its points). Their traces are
  ## the caller's to select. One point replaced or toggled becomes the anchor
  ## of the next range.
  if mode in {smReplace, smRange}:
    s.points.setLen 0
    s.pointKeys.clear()
  if mode in {smReplace, smToggle} and points.len >= 1: s.pointAnchor = points[0]
  var gone: IntSet
  for p in points:
    let k = p.key
    if mode == smRemove or (mode == smToggle and k in s.pointKeys):
      if k in s.pointKeys:
        s.pointKeys.excl k
        gone.incl k
    elif k notin s.pointKeys:
      s.pointKeys.incl k
      s.points.add p
  if gone.len > 0:
    var kept: seq[PointRef]
    for p in s.points:
      if p.key notin gone: kept.add p
    s.points = move kept
  inc s.revision
  inc s.selectedRevision

proc clear*(s: var Selection) =
  ## Selects nothing: no trace, no point.
  if s.selected.len > 0 or s.points.len > 0:
    s.selected.clear()
    s.points.setLen 0
    s.pointKeys.clear()
    inc s.revision
    inc s.selectedRevision

proc forget*(s: var Selection; file: SessionId; traces: Slice[int]) =
  ## Drops every mention of a closed file: its traces, its gather.
  var changed = false
  if s.hover in traces:
    s.hover = -1
    s.hoverAt.setLen 0
    changed = true
  if s.anchor in traces: s.anchor = -1
  var gone: seq[int]
  for t in s.selected:
    if t in traces: gone.add t
  for t in gone: s.selected.excl t
  if gone.len > 0: inc s.selectedRevision
  var hovered: seq[int]
  for t in s.hoverTraces:
    if t in traces: hovered.add t
  for t in hovered: s.hoverTraces.excl t
  if hovered.len > 0:
    inc s.hoveredRevision
    changed = true
  if s.activeGather.file == file:
    s.activeGather = GatherRef()
    changed = true
  if changed or gone.len > 0:
    inc s.revision
