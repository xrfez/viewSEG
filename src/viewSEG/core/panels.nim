## Trace panels and their layers.
##
## A panel shows one or more layers on the same axes; a layer is a source, a
## trace filter, a processing pipeline and display settings. One layer is the
## usual case; more are overlays (a recorded pilot over a generated one). The
## auxiliary viewer is another panel on the same record whose filter keeps the
## auxiliary traces, with its own pipeline.
##
## Panels and layers are plain data, read by the views and changed only by
## `AppState` when it applies a `Command`.

import processSEG/pipeline
import processSEG/vibroseis/sweep
import session

export pipeline.Pipeline, pipeline.len, sweep.SweepSpec

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
    ## Which of the source's traces a layer shows.
    seismic*: bool = true                  ## seismic traces
    auxiliary*: bool                       ## auxiliary traces (pilots, time breaks, uphole)
    channelSets*: seq[int]                 ## SEG-D channel sets to show; empty shows all
    channels*: Slice[int] = 0 .. high(int) ## channel numbers to show
    components*: set[uint8]                ## components to show; empty shows all

  DisplayMode* = enum
    dmDensity = "density" ## greyscale or colour density
    dmWiggle = "wiggle"   ## lines only
    dmWigglePositive = "wiggle, positive fill"
    dmWiggleNegative = "wiggle, negative fill"

  PlotColours* = enum
    pcPaper = "paper" ## white background, black traces, whatever the theme
    pcTheme = "follow theme"
    pcCustom = "custom"

  DisplaySettings* = object
    ## How a layer is drawn.
    visible*: bool = true
    mode*: DisplayMode = dmDensity
    colours*: PlotColours = pcPaper
    clipPercentile*: float64 = 99.0 ## amplitudes above this percentile are clipped
    overlap*: float64 = 1.0         ## how far a wiggle may swing over its neighbours, in trace spacings
    reversed*: bool                 ## polarity reversed for display

  Layer* = object
    source*: LayerSource
    filter*: TraceFilter
    pipeline*: Pipeline ## processSEG operations; empty shows the raw samples
    display*: DisplaySettings

  Panel* = object
    id*: PanelId
    layers*: seq[Layer] ## drawn in order; layer 0 is the one gather navigation moves
    requestGen*: uint64 ## bumped whenever the panel needs new data; tiles carry it
    revision*: int      ## bumped on every change

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
