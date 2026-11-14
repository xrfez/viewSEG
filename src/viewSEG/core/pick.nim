## What is under the cursor in a trace panel: the point in data
## coordinates, the trace drawn there, the nearest sample, its time and the
## value drawn for it, and the trace's keys (docs/architecture.md, rule 4).
##
## The pick reads only the panel's tiles, never the file: a trace is known
## where a tile holds it, which is everywhere on screen once the view's tile
## has come. The newest tile that holds the point wins, as it is the one
## drawn on top; zoomed out, the trace is the one drawn there (every
## `stride`-th), and the value is the one drawn for the sample's bin (the
## largest of `binned` samples). Values are as displayed: after the
## trace's edits (a killed trace reads 0) and the display's processing and
## gain.

import std/math
import parseSEG
import edits, geometry, tiles, viewport, zoom

type
  Pick* = object
    ## What lies under a point of a panel.
    inside*: bool             ## the point is over the plot
    at*: DataPoint            ## the point, in positions and ms
    sample*: int = -1         ## the nearest sample of the longest trace; -1 off the record
    found*: bool              ## a tile holds the trace: `position`, `trace` and `keys` are known
    position*: int = -1       ## the position of the trace drawn there; -1 when none
    trace*: int = -1          ## its index in its file; -1 when not known
    keys*: TraceKeys          ## its keys; every field unknown when not `found`
    amplitude*: float32 = NaN ## the value drawn at the nearest sample; NaN when not held
    binned*: int = 1          ## samples behind `amplitude`: more than 1 zoomed out
    edits*: set[TraceEdit]    ## the trace's edits, as drawn: killed, reversed

func noPick*(): Pick =
  ## A point over nothing.
  Pick(keys: initTraceKeys())

func pickAt*(tiles: openArray[Tile]; layout: PanelLayout; at: DataPoint): Pick =
  ## What lies at data point `at` of a panel with `layout` showing `tiles`
  ## (oldest first, as drawn). `inside` is left false.
  result = noPick()
  result.at = at
  if layout.dtMs > 0 and layout.samples > 0 and not at.tMs.isNaN:
    let j = round((at.tMs - layout.t0Ms) / layout.dtMs)
    if j >= 0 and j < float64(layout.samples): result.sample = int(j)
  # the newest tile holding the point, else the newest holding its trace
  var best = -1
  var full = false
  for i in countdown(tiles.high, 0):
    if tiles[i].contains(at.x, at.tMs):
      best = i
      full = true
      break
    if best < 0 and tiles[i].rowAt(at.x) >= 0: best = i
  if best < 0: return
  let t = tiles[best]
  let row = t.rowAt(at.x)
  result.found = true
  result.position = t.request.position(row)
  if row < t.traces.len: result.trace = t.traces[row]
  if row < t.keys.len: result.keys = t.keys[row]
  result.edits = t.editsAt(row)
  if full and t.columns > 0:
    let r = t.request
    let c = clamp(int(round((at.tMs - t.timeOf(0)) / (float64(r.decimation) * t.dtMs))), 0,
      t.columns - 1)
    result.amplitude = t.data[row * t.columns + c]
    result.binned = r.decimation

func pick*(tiles: openArray[Tile]; layout: PanelLayout; view: Viewport; plot: Rect;
    p: Vec2): Pick =
  ## What lies under screen point `p` of a panel drawn in `plot` showing
  ## `view`; `noPick()` when `p` is not over the plot.
  if not plot.contains(p) or plot.size.x <= 0 or plot.size.y <= 0:
    return noPick()
  result = pickAt(tiles, layout, dataAt(view, plot, p))
  result.inside = true
