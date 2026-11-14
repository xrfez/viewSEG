## Trace panels and their layers.
##
## A panel shows one or more layers on the same axes; a layer is a source, a
## trace filter, a processing pipeline and display settings. One layer is the
## usual case; more are overlays (a recorded pilot over a generated one). The
## auxiliary viewer is another panel on the same record whose filter keeps the
## auxiliary traces, with its own pipeline.
##
## A panel also holds what its reader thread said about its traces (the
## layout, the header fields they have values for), the view the UI
## reported, the views before it (for "back") and the request sent for it
## (`core/viewport`). The tiles that answer the requests are kept by
## `AppState` beside the panel.
##
## Panels and layers are plain data, read by the views and changed only by
## `AppState` when it applies a `Command` or takes in what a reader posted.
##
## **Display gain.** A layer is drawn after its pipeline, then its gain
## type's processing on the CPU (`displayPipeline`: AGC, per-trace
## normalization, an exponential gain; none for the other types), then a
## scale on the GPU: a *reference* amplitude is drawn full black (or white),
## raised or lowered by the gain amount in dB (`DisplaySettings.gainDb`),
## which every type has. The amount changes only the scale, so it never
## reads or processes anything again. The reference (`reference`) is:
##
## - None, AGC, Exponential, Automatic: the clip percentile of |x| of the
##   gather's first tile after a change of gather or processing, so the
##   brightness holds while panning;
## - Fixed: one amplitude kept with the display settings (`fixedClip`), so
##   it is the same for every gather and file until changed; taken from the
##   data shown when Fixed is chosen;
## - Normalized: each trace (`perTrace`, on the CPU) or the whole gather
##   (`perPanel`, by the scale alone) brought to the same level, its RMS,
##   peak or clip percentile, which is drawn full black;
## - Float: the clip percentile of the data in view, recomputed whenever the
##   view changes (`viewLevel`).
##
## **Trace order.** A layer shows its traces in the file's order, or sorted
## by keys (`Layer.order`: header fields, each ascending or descending, the
## first key first); `SortPresets` are the orders the plot window has
## buttons for. The panel's reader sorts (`core/sorting`), so each panel
## has its own order; the order is a list of trace numbers, and nothing in
## the file moves.

import std/math
import parseSEG
import processSEG/pipeline
import processSEG/gain/[curves, gain]
import processSEG/vibroseis/sweep
import session, viewport

export pipeline.Pipeline, pipeline.len, sweep.SweepSpec, viewport, GatherKind, NormScope,
  NormStat

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
    ## The gain type a layer is shown with, after its pipeline (the module
    ## documentation says what each does).
    dgAuto = "automatic" ## AGC for a pre-stack gather, none for stacked data
    dgNone = "none" ## the samples as they are, one scale per gather
    dgFixed = "fixed" ## one scale for every gather and file, until changed
    dgNormalized = "normalized" ## each trace, or the gather, brought to the same level
    dgExponential = "exponential" ## a gain rising with time
    dgFloat = "float" ## the scale follows the data in view
    dgAgc = "AGC" ## automatic gain control over `agcWindowMs`

  TimeGain* = enum
    ## The shape of the exponential gain.
    tgDbPerSecond = "dB per second" ## `dbPerS` dB per second of time
    tgPower = "power of time"       ## `(t / 1 s)^power`, as spherical divergence

  Level* = object
    ## Amplitude statistics of the live traces of some data (processSEG's
    ## `panelStats`): RMS, largest |x|, and the clip percentile of |x|. NaN
    ## when unknown.
    rms*: float64 = NaN
    peak*: float64 = NaN
    clip*: float64 = NaN

  DisplaySettings* = object
    ## How a layer is drawn.
    visible*: bool = true
    mode*: DisplayMode = dmDensity
    colours*: PlotColours = pcPaper
    gain*: DisplayGain = dgAuto
    gainDb*: float64                     ## the gain amount on top of any type: + brighter
    agcWindowMs*: float64 = 500.0        ## the AGC window
    fixedClip*: float64 = NaN            ## Fixed: |x| drawn full black at 0 dB; NaN: none yet
    normScope*: NormScope = perTrace     ## Normalized: each trace, or the whole gather
    normStat*: NormStat = normPercentile ## Normalized: the level brought to full black
    timeGain*: TimeGain = tgDbPerSecond  ## Exponential: its shape
    dbPerS*: float64 = 6.0               ## Exponential: dB per second
    power*: float64 = 2.0                ## Exponential: the power of time
    clipPercentile*: float64 = 99.0      ## amplitudes above this percentile are clipped
    overlap*: float64 = 1.0              ## a wiggle's largest swing, in trace spacings
    reversed*: bool                      ## polarity reversed for display

  Layer* = object
    source*: LayerSource
    filter*: TraceFilter
    order*: seq[SortKey] ## the traces' order, the first key first; empty: the file's order
    pipeline*: Pipeline  ## processSEG operations; empty shows the raw samples
    display*: DisplaySettings

  HeaderField* = enum
    ## A value the display header can show above each trace, and a key the
    ## traces can be sorted by.
    hfRcvLine = "line" ## receiver line
    hfRcvPoint = "point" ## receiver point (the station)
    hfComponent = "component" ## of a multi-component station (parseSEG's `TraceKeys.component`)
    hfChannel = "channel"
    hfRecord = "FFID" ## field record
    hfSrcLine = "source line"
    hfSrcPoint = "source point"
    hfOffset = "offset"
    hfEnsemble = "CDP"
    hfInline = "inline"
    hfCrossline = "crossline"
    hfTrace = "trace" ## the trace's number in the file, from 1

  HeaderChoice* = object
    ## The rows of a panel's display header.
    auto*: bool = true        ## from what the file has (`defaultFields`)
    fields*: seq[HeaderField] ## the user's choice, top row first, when not `auto`

  SortKey* = object
    ## One key of a trace order: a header field, smallest first unless
    ## `descending`.
    field*: HeaderField
    descending*: bool

  SortPreset* = object
    ## A named trace order, as the plot window's sort buttons offer it.
    name*: string
    keys*: seq[SortKey] ## the first key first

  Panel* = object
    id*: PanelId
    layers*: seq[Layer]      ## drawn in order; layer 0 is the one gather navigation moves
    header*: HeaderChoice
    requestGen*: uint64      ## bumped whenever the panel needs new data; tiles carry it
    sourceGen*: uint64       ## `requestGen` when layer 0's source last changed; layouts carry it
    layout*: PanelLayout     ## layer 0's traces, from the reader; `traces` 0 until it says
    laidOut*: bool           ## `layout` is known: the reader said, or there is nothing to read
    known*: set[HeaderField] ## the header fields layer 0's traces have values for
    kind*: GatherKind        ## the kind of gather layer 0 shows
    view*: Viewport          ## what the plot shows
    back*: seq[Viewport]     ## earlier views, newest last, for "back"; at most `MaxBack`
    pending*: ReadRequest    ## the request sent last; empty for none
    level*: Level            ## the first tile's since the source or the processing changed
    viewLevel*: Level        ## Float: the data in view, since the view last changed
    orderGen*: uint64
      ## `requestGen` when layer 0's order last changed: tiles from before
      ## it are kept until the first tile in the new order comes
    jumps*: int
      ## bumped when `core` sets the view itself (the whole gather when it
      ## is first laid out, back): the UI follows
    revision*: int ## bumped on every change

const
  NoPanel* = PanelId(0)
  MaxBack* = 50     ## earlier views a panel remembers
  GainStepDb* = 3.0 ## the gain amount's - and + buttons and keys
  MaxGainDb* = 60.0 ## the gain amount stays within ± this
  SortPresets* = [
    SortPreset(name: "Line/Station",
      keys: @[SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint)]),
    SortPreset(name: "By Flag",
      keys: @[SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint), SortKey(field: hfComponent)]),
    SortPreset(name: "By Component",
      keys: @[SortKey(field: hfComponent), SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint)])]
    ## The plot window's sort buttons, in order. Line/Station: receiver line,
    ## then point, a station's traces in the file's order; By Flag: the same,
    ## then component, so a station's components lie side by side in order;
    ## By Component: the traces grouped by component, each group by line,
    ## then point.

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
  of hfComponent: (if k.component == 0: NaN else: float64(k.component))
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

func presetOf*(order: openArray[SortKey]): int =
  ## The index in `SortPresets` of the preset whose keys are `order`; -1 for
  ## none (the file's order, or keys of the user's own).
  for i, s in SortPresets:
    if s.keys == @order: return i
  -1

func describe*(order: openArray[SortKey]): string =
  ## `order` in words: "line, then point (descending)"; "the file's order"
  ## for none.
  if order.len == 0: return "the file's order"
  for i, k in order:
    if i > 0: result.add ", then "
    result.add $k.field
    if k.descending: result.add " (descending)"

func effectiveGain*(d: DisplaySettings; kind: GatherKind): DisplayGain =
  ## The gain `d` shows a gather of `kind` with: `dgAuto` is AGC for a
  ## pre-stack gather (shot, receiver, offset, other) and none for stacked
  ## or unknown data.
  if d.gain != dgAuto: d.gain
  elif kind in {gkShot, gkReceiver, gkOffset, gkOther}: dgAgc
  else: dgNone

func cpuGain(d: DisplaySettings; kind: GatherKind): DisplayGain =
  ## The part of the gain that runs on the CPU, in the reader: `dgNone`
  ## for the types that are a scale alone.
  case d.effectiveGain(kind)
  of dgAgc: dgAgc
  of dgExponential: dgExponential
  of dgNormalized: (if d.normScope == perTrace: dgNormalized else: dgNone)
  of dgAuto, dgNone, dgFixed, dgFloat: dgNone

func displayPipeline*(layer: Layer; kind: GatherKind): Pipeline =
  ## What the reader runs on layer `layer`'s samples: its pipeline, then
  ## the CPU part of its display gain.
  result = layer.pipeline
  let d = layer.display
  case d.cpuGain(kind)
  of dgAgc: result.add agcOp(windowMs = d.agcWindowMs)
  of dgNormalized: result.add normalizeOp(d.normStat, perTrace, percentile = d.clipPercentile)
  of dgExponential:
    try:
      result.add gainCurveOp(if d.timeGain == tgDbPerSecond: exponentialGain(d.dbPerS)
                             else: powerGain(d.power))
    except ValueError:
      discard # a value that is not finite: no curve (the control refuses one)
  else: discard

func sameProcessing*(a, b: DisplaySettings; kind: GatherKind): bool =
  ## Whether `a` and `b` give a gather of `kind` the same samples: then a
  ## change from one to the other reads nothing again (the gain amount, a
  ## Fixed amplitude, the colours and the type among those that are a scale
  ## alone change only how they are drawn).
  let g = a.cpuGain(kind)
  result = g == b.cpuGain(kind) and a.clipPercentile == b.clipPercentile
  if result:
    case g
    of dgAgc: result = a.agcWindowMs == b.agcWindowMs
    of dgNormalized: result = a.normStat == b.normStat
    of dgExponential:
      result = a.timeGain == b.timeGain and (if a.timeGain == tgDbPerSecond:
        a.dbPerS == b.dbPerS else: a.power == b.power)
    else: discard

func usable(x: float64): bool {.inline.} = x > 0 and x < Inf

func reference*(p: Panel): float64 =
  ## The amplitude `p`'s layer 0 draws full black at a gain amount of 0 dB
  ## (the module documentation): NaN when it is not known yet.
  result = NaN
  if p.layers.len > 0:
    let d = p.layers[0].display
    case d.effectiveGain(p.kind)
    of dgFixed: result = if usable(d.fixedClip): d.fixedClip else: p.level.clip
    of dgFloat: result = p.viewLevel.clip
    of dgNormalized:
      if d.normScope == perTrace: result = 1 # each trace brought to 1
      else:
        result = case d.normStat
          of normRms: p.level.rms
          of normMax: p.level.peak
          of normPercentile: p.level.clip
    else: result = p.level.clip

func withGainDb*(d: DisplaySettings; db: float64): DisplaySettings =
  ## `d` with the gain amount `db`, within ± `MaxGainDb` (0 for a value that
  ## is not a number).
  result = d
  result.gainDb = if db.isNaN: 0.0 else: clamp(db, -MaxGainDb, MaxGainDb)

func displayMargin*(flow: Pipeline; dtMs: float64): int =
  ## The samples `flow` needs beyond a window on each side; 0 when it
  ## cannot say (an invalid op: the reader reports it).
  if not (dtMs > 0 and dtMs < Inf): return 0
  try:
    flow.requiredMargin(dtMs)
  except ValueError:
    0
