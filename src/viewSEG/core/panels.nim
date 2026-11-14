## Trace panels and their layers.
##
## A panel shows one or more layers on the same axes; a layer is a source, a
## trace filter, a processing pipeline and display settings. One layer is the
## usual case; more are overlays (a recorded pilot over a generated one). The
## auxiliary viewer is another panel on the same record whose filter keeps the
## auxiliary traces, with its own pipeline.
##
## A panel also holds what its reader thread said about its traces (the
## layout, the header fields they have values for), the view the UI last
## reported and the request sent for it (`core/viewport`). The tiles that
## answer the requests are kept by `AppState` beside the panel.
##
## Panels and layers are plain data, read by the views and changed only by
## `AppState` when it applies a `Command` or takes in what a reader posted.

import std/math
import parseSEG
import processSEG/pipeline
import processSEG/gain/gain
import processSEG/vibroseis/sweep
import session, viewport

export pipeline.Pipeline, pipeline.len, sweep.SweepSpec, viewport, GatherKind

type
  PanelId* = distinct int
    ## Names a panel; never reused. `NoPanel` (0) names none.

  LayerSourceKind* = enum
    lsRecord = "record"             ## a gather of an open file
    lsGenerated = "generated trace" ## a trace made by the viewer, such as a pilot sweep

  LayerSource* = object
    ## What a layer draws.
    case kind*: LayerSourceKind
    of lsRecord:
      file*: SessionId ## `NoSession` until a file is shown
      gather*: int     ## index into the file's gathers
    of lsGenerated:
      sweep*: SweepSpec

  TraceFilter* = object
    ## Which of the source's traces a layer shows. The reader applies the
    ## seismic and auxiliary switches; the other fields are not applied yet.
    seismic*: bool = true ## seismic traces
    auxiliary*: bool ## auxiliary traces (pilots, time breaks, uphole)
    channelSets*: seq[int] ## SEG-D channel sets to show; empty shows all
    channels*: Slice[int] = 0 .. high(int) ## channel numbers to show
    components*: set[uint8] ## components to show; empty shows all

  DisplayMode* = enum
    dmDensity = "density" ## greyscale or colour density
    dmWiggle = "wiggle"   ## lines only
    dmWigglePositive = "wiggle, positive fill"
    dmWiggleNegative = "wiggle, negative fill"

  PlotColours* = enum
    pcPaper = "paper" ## white background, black traces, whatever the theme
    pcTheme = "follow theme"
    pcCustom = "custom"

  DisplayGain* = enum
    ## The gain a layer is shown with, after its pipeline.
    dgAuto = "automatic"             ## AGC for a pre-stack gather, none for stacked data
    dgNone = "none"                  ## the samples as they are, clipped
    dgTraceBalance = "trace balance" ## every trace brought to the same RMS
    dgAgc = "AGC"                    ## automatic gain control over `agcWindowMs`

  DisplaySettings* = object
    ## How a layer is drawn.
    visible*: bool = true
    mode*: DisplayMode = dmDensity
    colours*: PlotColours = pcPaper
    gain*: DisplayGain = dgAuto
    agcWindowMs*: float64 = 500.0   ## the AGC window
    clipPercentile*: float64 = 99.0 ## amplitudes above this percentile are clipped
    overlap*: float64 = 1.0         ## how far a wiggle may swing over its neighbours, in trace spacings
    reversed*: bool                 ## polarity reversed for display

  Layer* = object
    source*: LayerSource
    filter*: TraceFilter
    pipeline*: Pipeline ## processSEG operations; empty shows the raw samples
    display*: DisplaySettings

  HeaderField* = enum
    ## A value the display header can show above each trace.
    hfRcvLine = "line"   ## receiver line
    hfRcvPoint = "point" ## receiver point
    hfChannel = "channel"
    hfRecord = "FFID"    ## field record
    hfSrcLine = "source line"
    hfSrcPoint = "source point"
    hfOffset = "offset"
    hfEnsemble = "CDP"
    hfInline = "inline"
    hfCrossline = "crossline"
    hfTrace = "trace"    ## the trace's number in the file, from 1

  HeaderChoice* = object
    ## The rows of a panel's display header.
    auto*: bool = true        ## from what the file has (`defaultFields`)
    fields*: seq[HeaderField] ## the user's choice, top row first, when not `auto`

  Panel* = object
    id*: PanelId
    layers*: seq[Layer]      ## drawn in order; layer 0 is the one gather navigation moves
    header*: HeaderChoice
    requestGen*: uint64      ## bumped whenever the panel needs new data; tiles carry it
    sourceGen*: uint64       ## `requestGen` when layer 0's source last changed; layouts carry it
    layout*: PanelLayout     ## layer 0's traces, from the reader; `traces` 0 until it says
    laidOut*: bool           ## whether the reader has said (`layout` may be empty: no traces)
    known*: set[HeaderField] ## the header fields layer 0's traces have values for
    kind*: GatherKind        ## the kind of gather layer 0 shows
    view*: Viewport          ## what the UI last showed
    pending*: ReadRequest    ## the request sent last; empty for none
    clip*: float64 = NaN     ## the display clip: the first tile's since the source or gain changed
    fits*: int               ## bumped when the view is reset to show everything; the UI follows
    revision*: int           ## bumped on every change

const NoPanel* = PanelId(0)

func `==`*(a, b: PanelId): bool {.borrow.}
func `$`*(id: PanelId): string = "panel " & $int(id)

func recordLayer*(file: SessionId; gather: int): Layer =
  ## A layer showing gather `gather` of `file`, with the default filter,
  ## no processing and the default display.
  Layer(source: LayerSource(kind: lsRecord, file: file, gather: gather))

func shows*(layer: Layer; file: SessionId): bool =
  ## Whether `layer` draws traces of `file`.
  layer.source.kind == lsRecord and layer.source.file == file

func value*(k: TraceKeys; field: HeaderField; trace: int): float64 =
  ## `field` of the trace with keys `k` and index `trace`; NaN when unknown.
  case field
  of hfRcvLine: k.rcvLine
  of hfRcvPoint: k.rcvPoint
  of hfChannel: k.channel
  of hfRecord: k.record
  of hfSrcLine: k.srcLine
  of hfSrcPoint: k.srcPoint
  of hfOffset: k.offset
  of hfEnsemble: k.ensemble
  of hfInline: k.inline
  of hfCrossline: k.crossline
  of hfTrace: float64(trace + 1)

func defaultFields*(known: set[HeaderField]; kind = gkUnknown): seq[HeaderField] =
  ## The display header of a gather of `kind` whose traces have values for
  ## `known`, the first group that has any: for a shot gather receiver line
  ## and point, else field record and channel; for a receiver gather source
  ## line and point, else field record; for stacked or unknown data inline
  ## and crossline, else the CDP, else receiver line and point. The trace
  ## number when nothing else is known.
  let groups =
    case kind
    of gkReceiver: @[@[hfSrcLine, hfSrcPoint], @[hfRecord], @[hfRcvLine, hfRcvPoint]]
    of gkShot, gkOffset, gkOther:
      @[@[hfRcvLine, hfRcvPoint], @[hfRecord, hfChannel], @[hfEnsemble]]
    of gkCmp, gkUnknown:
      @[@[hfInline, hfCrossline], @[hfEnsemble], @[hfRcvLine, hfRcvPoint],
        @[hfRecord, hfChannel]]
  for group in groups:
    for f in group:
      if f in known: result.add f
    if result.len > 0: return
  @[hfTrace]

func shownFields*(p: Panel): seq[HeaderField] =
  ## The rows of `p`'s display header, top first.
  if p.header.auto: defaultFields(p.known, p.kind) else: p.header.fields

func effectiveGain*(d: DisplaySettings; kind: GatherKind): DisplayGain =
  ## The gain `d` shows a gather of `kind` with: `dgAuto` is AGC for a
  ## pre-stack gather (shot, receiver, offset, other) and none for stacked
  ## or unknown data.
  if d.gain != dgAuto: d.gain
  elif kind in {gkShot, gkReceiver, gkOffset, gkOther}: dgAgc
  else: dgNone

func displayPipeline*(layer: Layer; kind: GatherKind): Pipeline =
  ## What the reader runs on layer `layer`'s samples: its pipeline, then
  ## its display gain.
  result = layer.pipeline
  case layer.display.effectiveGain(kind)
  of dgAgc: result.add agcOp(windowMs = layer.display.agcWindowMs)
  of dgTraceBalance: result.add normalizeOp(normRms, perTrace)
  of dgNone, dgAuto: discard

func displayMargin*(flow: Pipeline; dtMs: float64): int =
  ## The samples `flow` needs beyond a window on each side; 0 when it
  ## cannot say (an invalid op: the reader reports it).
  if not (dtMs > 0 and dtMs < Inf): return 0
  try:
    flow.requiredMargin(dtMs)
  except ValueError:
    0
