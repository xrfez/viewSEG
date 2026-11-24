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
## normalization, an exponential gain held after its cutoff time; none for
## the other types), then a scale on the GPU: a *reference* amplitude is
## drawn full black (or white), raised or lowered by the gain amount in dB
## (`DisplaySettings.gainDb`), which every type has. The amount changes only
## the scale, so it never reads or processes anything again. The reference
## (`reference`) is:
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
##
## **Polarity.** Reversing the polarity of every trace of a layer
## (`Layer.reversed`) is an operation on its data, not a way of drawing it:
## processSEG's `polarityOp` runs first in the display pipeline, so the
## tiles, the readout's amplitude, the gain's statistics and anything
## computed from the layer later hold the reversed samples. Single traces
## are reversed, or killed, by the file's edits (`core/edits`), which the
## reader applies before the pipeline.
##
## **Names.** A panel's window is named for what it shows (`windowTitle`):
## "Seismic" for seismic traces, "Aux" for auxiliary ones, "FFT" for
## spectra, "F-K" for an f-k plot; a second window of a kind is numbered
## ("Seismic 2"). The name follows the panel's trace filter and kind, so
## the same window names itself again when it is reused.

import std/[math, options, sequtils, sets, strutils]
import parseSEG
import processSEG/pipeline
import processSEG/gain/[curves, gain]
import processSEG/vibroseis/sweep
import breakmodel, colourmaps, components, geometry, orientation, processing, session, viewport, zoom

export breakmodel, pipeline.Pipeline, pipeline.len, sweep.SweepSpec, viewport, orientation,
    processing,
  GatherKind, NormScope, NormStat, ColourMap

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
    ## seismic and auxiliary switches and the components. Channel sets and
    ## channel numbers are not applied.
    seismic*: bool = true ## seismic traces
    auxiliary*: bool ## auxiliary traces (pilots, time breaks, uphole)
    channelSets*: seq[int] ## SEG-D channel sets to show; empty shows all
    channels*: Slice[int] = 0 .. high(int) ## channel numbers to show
    templateOnly*: bool
      ## leave out the seismic traces the record's template does not list (the traces of
      ## the map's "not in the template" filter); a record with no template shows all
    components*: set[uint8]
      ## components switched off (`TraceKeys.component`); empty shows all,
      ## so a component first seen on a later record is shown. A trace with
      ## no component stays. The choice holds across records of one file
      ## and is cleared when another file is shown. A record left with no
      ## trace because every component present is off is shown whole again.

  DisplayMode* = enum
    ## How a layer's traces are drawn: density is drawn only in the modes
    ## that name it (`drawsWiggles`, `drawsDensity`). In the wiggle modes a
    ## view is never zoomed out past one pixel a trace (`viewLimits`), so
    ## every trace in view is drawn as a wiggle.
    dmDensity = "density" ## density, in its colour map (grey by default)
    dmWiggle = "wiggle" ## wiggles, with the fills chosen
    dmWiggleDensity = "wiggle over density" ## wiggles over density

  WiggleFill* = enum
    ## The lobes of a wiggle that are filled.
    wfPositive = "positive fill" ## right of the baseline (above it when time is across)
    wfNegative = "negative fill" ## left of it (below it)

  PlotColours* = enum
    pcPaper = "paper" ## white background, black traces, whatever the theme
    pcTheme = "follow theme"
    pcCustom = "custom"
    pcRedPaper = "red on paper"
      ## white paper, the theme's negative-fill red for the wiggle line and the
      ## positive fill, black negative fill (the Aux window's start)

  CustomColours* = object
    ## The plot's colours when the user picks them (`pcCustom`).
    background*, line*, positive*, negative*: Rgba
    hover*, selected*: Rgba ## a hovered or selected trace: line and fills

  BreakSize* = enum
    ## How large the first-break overlay's bars are drawn (`view/breakbars`).
    bzSmall = "small"
    bzMedium = "medium"
    bzLarge = "large"

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
    ## `panelStats`): RMS, largest |x|, and the clip percentile of |x|, of the
    ## samples as read (before the display gain; the auxiliary traces when
    ## there is no seismic one). The types that scale by the record or the
    ## view use them; Normalized for each trace does not (`reference` is 1).
    ## NaN when unknown.
    rms*: float64 = NaN
    peak*: float64 = NaN
    clip*: float64 = NaN

  DisplaySettings* = object
    ## How a layer is drawn.
    visible*: bool = true
    mode*: DisplayMode = dmWiggle
    fills*: set[WiggleFill] = {wfPositive} ## the wiggles' fills: either, both or none
    colours*: PlotColours = pcPaper
    custom*: CustomColours                 ## the colours under `pcCustom`
    colourMap*: ColourMap = cmGrey         ## density's colours (`core/colourmaps`)
    gain*: DisplayGain = dgAuto
    gainDb*: float64                       ## the gain amount on top of any type: + brighter
    agcWindowMs*: float64 = 500.0          ## the AGC window
    fixedClip*: float64 = NaN              ## Fixed: |x| drawn full black at 0 dB; NaN: none yet
    normScope*: NormScope = perTrace       ## Normalized: each trace, or the whole gather
    normStat*: NormStat = normPercentile   ## Normalized: the level brought to full black
    timeGain*: TimeGain = tgDbPerSecond    ## Exponential: its shape
    dbPerS*: float64 = 6.0                 ## Exponential: dB per second
    power*: float64 = 2.0                  ## Exponential: the power of time
    untilMs*: float64 = 2000.0             ## Exponential: rises until this time, then holds
    clipPercentile*: float64 = 99.0        ## amplitudes above this percentile are clipped
    overlap*: float64 = 1.0
      ## a wiggle's largest swing, in trace spacings (1 reaches the next
      ## trace's baseline): the reference amplitude swings this far, and
      ## nothing further
    orientation*: Orientation = orTimeDown
      ## which way the plot is turned (`core/orientation`): the panel's
      ## layer 0 decides for the whole plot
    firstBreaks*: bool
      ## the first-break overlay (`core/firstbreaks`) is drawn: a bar at the
      ## time the model expects each trace's first break and another at the
      ## pick. Off by default; like the orientation, not part of a preset
    breakModel*: BreakModel
      ## where the overlay's model comes from: fitted to the record, or the velocity
      ## model the user gives (`core/breakmodel`); not part of a preset either
    breakPickColour*, breakModelColour*: Rgba
      ## the overlay's pick and model bars in the colours the user chose; alpha 0 (the
      ## default) leaves the theme's; not part of a preset either
    breakSize*: BreakSize = bzMedium ## the overlay's bars' size; not part of a preset either
    breakShowPicks*, breakShowModel*: bool = true
      ## whether the overlay draws the pick bars and the model bars; each can be hidden to
      ## see the other alone; not part of a preset either
    breakShowWeak*: bool
      ## whether the overlay draws the picks not compared with the model (unconfident, or no
      ## break found) faint; off by default; not part of a preset either
    breakPickOn*: PickBasis = pbSmoothed
      ## what the overlay's guided picking reads (`core/firstbreakjobs`): a smoothed copy or
      ## the samples as recorded; not part of a preset either

  Layer* = object
    source*: LayerSource
    filter*: TraceFilter
    order*: seq[SortKey] ## the traces' order, the first key first; empty: the file's order
    pipeline*: Pipeline  ## processSEG operations; empty shows the raw samples
    reversed*: bool
      ## every trace's polarity reversed: processSEG's `polarityOp` runs on the
      ## samples before anything else (`displayPipeline`), so the gain, the
      ## readout and whatever is computed from the layer see reversed data
    display*: DisplaySettings
    processing*: Processing
      ## the filters its traces go through (`core/processing`), before the
      ## polarity and the gain; kept with the layer, so they go with the
      ## plot to the next record and file

  HeaderField* = enum
    ## A value the display header can show above each trace, and a key the
    ## traces can be sorted by.
    hfRcvLine = "line" ## receiver line
    hfRcvPoint = "point" ## receiver point (the station)
    hfComponent = "component" ## of a multi-component station (parseSEG's `TraceKeys.component`)
    hfChannel = "channel"
    hfChannelSet = "channel set"
      ## SEG-D: the trace's channel set (counted from 1) and, in the header, its
      ## type; unknown for SEG-Y
    hfTraceId = "trace ID code"
      ## SEG-Y trace identification code (the header shows its name); unknown
      ## when 0 and for SEG-D
    hfRecord = "FFID" ## field record
    hfSrcLine = "source line"
    hfSrcPoint = "source point"
    hfOffset = "offset"
    hfEnsemble = "CDP"
    hfInline = "inline"
    hfCrossline = "crossline"
    hfTrace = "trace" ## the trace's number in the file, from 1
    hfStartTime = "Start time"
      ## when the trace's first sample was recorded, in UTC microseconds since 1970
      ## (the keys' first-sample instant, else their `time`); the sort by it reads a
      ## recorder's own per-trace start time from the headers when a vendor map has it
    hfVendor = "vendor field"
      ## a trace field a vendor map defines, chosen by name (`HeaderRef.name`); only
      ## a display line shows it (`value` has none: the reader's column cache does)

  HeaderRef* = object
    ## A header chosen for a display line: a built-in `field`, or, for `hfVendor`, the
    ## vendor field called `name` (the bare field name when it is unique among the
    ## file's vendor fields, else `block.name`). `name` is read only for `hfVendor`.
    field*: HeaderField
    name*: string

  HeaderChoice* = object
    ## The rows of a panel's display header.
    auto*: bool = true      ## from what the file has (`defaultFields`)
    fields*: seq[HeaderRef] ## the user's choice, top row first, when not `auto`

  SortKey* = object
    ## One key of a trace order: a header field, smallest first unless
    ## `descending`. For `hfVendor` the key is the vendor field called `name`
    ## (read only then); a name the file has no field of sorts as all absent.
    field*: HeaderField
    descending*: bool
    name*: string

  SortPreset* = object
    ## A named trace order, as the plot window's sort buttons offer it.
    name*: string
    keys*: seq[SortKey] ## the first key first

  PanelShows* = enum
    ## What a panel draws, which names its window (`windowTitle`).
    psTraces = "traces"     ## traces over time, as filtered: Seismic or Aux
    psSpectrum = "spectrum" ## amplitude spectra
    psFk = "f-k"            ## an f-k plot

  PanelRole* = enum
    ## What a trace panel is for. The Seismic window (`prSeismic`) is the whole plot; the
    ## Aux window (`prAux`) is a restricted second plot of the same record, with the
    ## controls `capsOf` leaves it.
    prSeismic = "seismic"
    prAux = "aux"

  SettingsTab* = enum
    ## The tabs of a panel's gear popover.
    stLook = "Look", stTraces = "Traces", stScales = "Scales"

  PanelCaps* = object
    ## What a panel of a role has: the controls its window draws, the choices its commands
    ## may carry, and the groups of its right-click menu. Decided here, so that the window
    ## only draws what it is given and the state refuses the rest.
    stepsRecords*: bool ## a record stepper, Go to, Page Up / Page Down; else it follows
    modes*: set[DisplayMode] ## the display modes it can be in
    gains*: set[DisplayGain] ## the gain types it offers (`dgAuto` is the choice to let go)
    chooseGain*: bool ## "Let viewSEG choose": the automatic gain
    breaks*: bool ## the first-break overlay
    templateButton*: bool ## the "only traces in the template" button
    filters*: bool ## the frequency filters, Raw, and a trace's own filter
    sort*: bool ## the sort drop-down
    traceChoice*: bool ## the Seismic / Aux toggles and the component toggles
    settingsTabs*: set[SettingsTab] ## the gear's tabs
    displayPresets*, densityMap*, componentColours*: bool
      ## the gear's Look tab's sections of that name
    menuMap*: bool ## the right-click menu's Map group
    menuWholeRecord*: bool ## its Whole record group
    menuFilters*: bool ## its Exclude and Filter entries

  Panel* = object
    id*: PanelId
    role*: PanelRole = prSeismic
      ## what it is for: the Seismic window, or the Aux window (`capsOf`)
    shows*: PanelShows        ## what it draws
    layers*: seq[Layer]       ## drawn in order; layer 0 is the one gather navigation moves
    header*: HeaderChoice
    requestGen*: uint64       ## bumped whenever the panel needs new data; tiles carry it
    sourceGen*: uint64        ## `requestGen` when layer 0's source last changed; layouts carry it
    layout*: PanelLayout      ## layer 0's traces, from the reader; `traces` 0 until it says
    laidOut*: bool            ## `layout` is known: the reader said, or there is nothing to read
    known*: set[HeaderField]  ## the header fields layer 0's traces have values for
    widest*: array[HeaderField, int]
      ## per field, its longest value over layer 0's traces as the header
      ## shows it (`numberText`), in characters: its column's width when
      ## time is across, the same wherever the view goes in the gather
    kind*: GatherKind ## the kind of gather layer 0 shows
    view*: Viewport ## what the plot shows
    back*: seq[Viewport] ## earlier views, newest last, for "back"; at most `MaxBack`
    pending*: ReadRequest ## the request sent last; empty for none
    level*: Level
      ## the record's (`relevel`, `basis`): a tile's of `basis`, or the one
      ## its reader works out for it; another tile's stands in only while
      ## there is none
    viewLevel*: Level ## Float: the data in view, since the view last changed
    orderGen*: uint64
      ## `requestGen` when layer 0's order last changed: tiles from before
      ## it are kept until the first tile in the new order comes
    samplesGen*: uint64
      ## `requestGen` when what layer 0's samples hold last changed (the
      ## polarity, an edit of its traces): tiles from before it are drawn
      ## until the first tile after it comes, then dropped
    filterRun*: uint64
      ## `requestGen` of the first request of the filter changes made one
      ## after another, with nothing else between (a filter changed again and again): a tile
      ## asked for since then is drawn even when a newer change waits, so
      ## the plot follows the slider; 0 for none
    filterGen*: uint64 ## `requestGen` after the newest filter change
    relevel*: bool
      ## `level` is to be taken again (a new record, a kill or a restore, the
      ## filters, a clip percentile, a gain that runs on the samples), over
      ## `basis` whatever is in view: from a tile of it, or from the reader's
      ## work out of it (`askLevel`)
    levelSince*: uint64 ## `requestGen` when `relevel` was last set
    levelAsked*: bool ## the reader was asked for the record's level since
    basis*: ReadRequest
      ## what the record's level is taken over: the record's first request
      ## (as it was first shown, with its read-ahead: all of it at the fit in
      ## density), whatever the view later; empty until it is made
    jumps*: int
      ## bumped when `core` sets the view itself (the whole gather when it
      ## is first laid out, back): the UI follows
    carry*: Viewport
      ## the view of the gather shown before, until the next one is laid out
      ## and shown at the same scales; no width for none (it fits instead)
    carryLayout*: PanelLayout ## that gather's layout
    shown*: seq[int]
      ## per position, the index in its file of the trace shown there (the
      ## gather after the trace filter, in the order shown), from the
      ## reader; empty until it says
    componentCodes*: seq[uint8]
      ## distinct components of the gather before the component filter, in
      ## button order; empty until the reader says, and when the gather has none
    componentCounts*: seq[int]
      ## how many traces of each `componentCodes` entry, before the filter
    componentSensors*: seq[uint8]
      ## sensor type of each, when its traces agree; 0 otherwise. The
      ## button's letter and colour come from this, not from the code.
    hidden*: seq[int]
      ## the traces of the gather its reader leaves out of the positions,
      ## ascending: the killed ones, when killed traces are hidden (a setting)
    templateWait*: bool
      ## the record is not read yet: "Only traces in the template" is on and the check that
      ## says which traces the template lists has not ended, so it is read once, without them
    revision*: int ## bumped on every change

const
  NoPanel* = PanelId(0)
  MinOverlap* = 0.1       ## the trace overlap's range, in trace spacings
  MaxOverlap* = 10.0
  MaxBack* = 50           ## earlier views a panel remembers
  GainStepDb* = 3.0       ## the gain amount's - and + buttons and keys
  GainShiftStepDb* = 12.0 ## the same with Shift held
  MaxGainDb* = 300.0      ## the gain amount stays within ± this (a factor of 1e15)
  SortPresets* = [
    SortPreset(name: "Line/Station",
      keys: @[SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint)]),
    SortPreset(name: "Time", keys: @[SortKey(field: hfStartTime)]),
    SortPreset(name: "By Flag, Line/Station",
      keys: @[SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint), SortKey(field: hfComponent)]),
    SortPreset(name: "By Flag, Time",
      keys: @[SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint), SortKey(field: hfStartTime),
        SortKey(field: hfComponent)]),
    SortPreset(name: "By Component, Line/Station",
      keys: @[SortKey(field: hfComponent), SortKey(field: hfRcvLine), SortKey(field: hfRcvPoint)]),
    SortPreset(name: "By Component, Time",
      keys: @[SortKey(field: hfComponent), SortKey(field: hfStartTime)])]
    ## The plot window's sort drop-down, in order: a grouping and, inside it, a
    ## sub-sort. Line/Station: receiver line, then point, a station's traces in
    ## the file's order; Time: by start time. By Flag: a station's components
    ## together, the stations by line, then point (then, for By Flag, Time, a
    ## station's segments in time, each segment's components together). By
    ## Component: the traces grouped by component (vertical, inline, crossline,
    ## hydrophone), each group by line, then point, or by time.

const
  MinUntilMs* = 10.0
    ## the Exponential gain's cutoff time (`DisplaySettings.untilMs`) stays
    ## within this and `MaxUntilMs`
  MaxUntilMs* = 60_000.0
  MinAgcWindowMs* = 10.0 ## the AGC window's range, as the gain's controls take it
  MaxAgcWindowMs* = 20_000.0
  MaxDbPerS* = 60.0 ## the Exponential gain's dB per second stays within ± this
  MaxPower* = 5.0 ## the power of time stays within ± this
  MinClipPercentile* = 50.0 ## the percentile amplitudes are clipped at, from this to 100
  MinFixedClip* = 1e-30 ## a Fixed gain's amplitude, from this to `MaxFixedClip`
  MaxFixedClip* = 1e30

func `==`*(a, b: PanelId): bool {.borrow.}
func `$`*(id: PanelId): string = "panel " & $int(id)

func recordLayer*(file: SessionId; gather: int): Layer =
  ## A layer showing gather `gather` of `file`, with the default filter,
  ## no processing and the default display.
  Layer(source: LayerSource(kind: lsRecord, file: file, gather: gather))

func shows*(layer: Layer; file: SessionId): bool =
  ## Whether `layer` draws traces of `file`.
  layer.source.kind == lsRecord and layer.source.file == file

converter headerRef*(f: HeaderField): HeaderRef =
  ## A built-in header as a `HeaderRef`, so every plain `HeaderField` keeps working.
  HeaderRef(field: f)

converter headerRefs*(fs: seq[HeaderField]): seq[HeaderRef] =
  ## Built-in headers as `HeaderRef`s.
  for f in fs: result.add HeaderRef(field: f)

func vendorRef*(name: string): HeaderRef =
  ## The display line of the vendor field `name`.
  HeaderRef(field: hfVendor, name: name)

const MaxHeaderLines* = 32 ## display lines a header may have

func usableLineName*(name: string): bool =
  ## Whether `name` can name a vendor line: 1 to 200 characters, no control character
  ## (what the settings file keeps, so an agent cannot choose one that would be lost).
  name.len in 1 .. 200 and not name.anyIt(it < ' ' or it == '\127')

func builtInLineNames*(): seq[string] =
  ## The names of the built-in header lines, in the enum's order.
  for f in HeaderField:
    if f != hfVendor: result.add $f

func headerRefOf*(name: string): HeaderRef =
  ## The line called `name`: the built-in field of that name (any case; a
  ## built-in field wins a clash), else the vendor field of that name.
  for f in HeaderField:
    if f != hfVendor and cmpIgnoreCase($f, name) == 0: return HeaderRef(field: f)
  HeaderRef(field: hfVendor, name: name)

const MaxSortKeys* = 24 ## keys a trace order may have

func vendorKey*(name: string; descending = false): SortKey =
  ## The sort key of the vendor field `name`.
  SortKey(field: hfVendor, name: name, descending: descending)

func sameField*(a, b: SortKey): bool =
  ## Whether `a` and `b` sort by the same field (the direction aside).
  a.field == b.field and (a.field != hfVendor or a.name == b.name)

func keyName*(k: SortKey): string =
  ## The key's field in words: the built-in field's name, or the vendor field's own.
  if k.field == hfVendor: k.name else: $k.field

func `==`*(a, b: HeaderRef): bool =
  a.field == b.field and (a.field != hfVendor or a.name == b.name)

func uniqueLines*(fields: openArray[HeaderRef]): seq[HeaderRef] =
  ## `fields` with each line once, in order (in a time linear in their number).
  var seen = initHashSet[string]()
  for f in fields:
    if seen.containsOrIncl($ord(f.field) & (if f.field == hfVendor: f.name else: "")): continue
    result.add f

func `$`*(h: HeaderRef): string =
  ## The line's name: the built-in field's, or the vendor field's own name.
  if h.field == hfVendor: h.name else: $h.field

func value*(k: TraceKeys; field: HeaderField; trace: int; channelSet = 0): float64 =
  ## `field` of the trace with keys `k`, index `trace` and channel set number
  ## `channelSet` (`core/channelsets`; 0 for none); NaN when unknown.
  case field
  of hfRcvLine: k.rcvLine
  of hfRcvPoint: k.rcvPoint
  of hfComponent: (if componentOf(k) == 0: NaN else: float64(componentOf(k)))
  of hfChannel: k.channel
  of hfChannelSet: (if channelSet <= 0: NaN else: float64(channelSet))
  of hfTraceId: (if k.traceCode == 0: NaN else: float64(k.traceCode))
  of hfRecord: k.record
  of hfSrcLine: k.srcLine
  of hfSrcPoint: k.srcPoint
  of hfOffset: k.offset
  of hfEnsemble: k.ensemble
  of hfInline: k.inline
  of hfCrossline: k.crossline
  of hfTrace: float64(trace + 1)
  of hfStartTime:
    let us = k.firstSampleUs
    if us.isSome: float64(us.get)
    elif k.time.isNaN: NaN
    else: k.time * 1e6
  of hfVendor: NaN # a vendor field's values are a column of the file, not the keys

func value*(k: TraceKeys; field: HeaderRef; trace: int; channelSet = 0): float64 =
  ## `value` of a display line's built-in field; NaN for a vendor line.
  value(k, field.field, trace, channelSet)

func joinGroupsOf*(field: HeaderField): set[JoinGroup] =
  ## The groups of a trace's keys `field` shows: what a geometry join may
  ## have given it (parseSEG's `joinedGroups`).
  case field
  of hfRcvLine, hfRcvPoint: {jgReceiverStation}
  of hfSrcLine, hfSrcPoint: {jgSourceStation}
  of hfComponent: {jgComponent}
  of hfOffset: {jgDerived}
  else: {}

func defaultFields*(known: set[HeaderField]; kind = gkUnknown): seq[HeaderRef] =
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
      if f in known: result.add headerRef(f)
    if result.len > 0: return
  @[headerRef(hfTrace)]

func shownFields*(p: Panel): seq[HeaderRef] =
  ## The rows of `p`'s display header, top first.
  if p.header.auto: defaultFields(p.known, p.kind) else: p.header.fields

const
  AuxGains* = {dgNone, dgFixed, dgNormalized}
    ## the gain types the Aux window offers: the others are for seismic data

func capsOf*(role: PanelRole): PanelCaps =
  ## The controls and choices of a panel of `role`.
  case role
  of prSeismic:
    PanelCaps(stepsRecords: true, modes: {DisplayMode.low .. DisplayMode.high},
      gains: {DisplayGain.low .. DisplayGain.high}, chooseGain: true, breaks: true,
      templateButton: true, filters: true, sort: true, traceChoice: true,
      settingsTabs: {stLook, stTraces, stScales}, displayPresets: true, densityMap: true,
      componentColours: true, menuMap: true, menuWholeRecord: true, menuFilters: true)
  of prAux:
    PanelCaps(modes: {dmWiggle}, gains: AuxGains, settingsTabs: {stLook, stTraces})

func caps*(p: Panel): PanelCaps {.inline.} = capsOf(p.role)

func forAux*(d: DisplaySettings): DisplaySettings =
  ## `d` as the Aux window can show it: wiggles only, a gain type it offers (Normalized
  ## in place of the others), no first-break overlay.
  result = d
  result.mode = dmWiggle
  if result.gain notin AuxGains: result.gain = dgNormalized
  result.firstBreaks = false

func auxFilter*(): TraceFilter =
  ## The Aux window's trace filter: the auxiliary traces, no seismic one.
  TraceFilter(seismic: false, auxiliary: true)

func contentName*(p: Panel): string =
  ## What `p` shows, as its window is named: "Seismic" (seismic traces),
  ## "Aux" (auxiliary traces), "Seismic + Aux" (both), "FFT" (spectra),
  ## "F-K". A panel with no layer yet is named for the filter a new layer
  ## gets.
  case p.shows
  of psSpectrum: "FFT"
  of psFk: "F-K"
  of psTraces:
    if p.role == prAux: return "Aux"
    let f = if p.layers.len > 0: p.layers[0].filter else: TraceFilter()
    if f.seismic and f.auxiliary: "Seismic + Aux"
    elif f.auxiliary: "Aux"
    elif f.seismic: "Seismic"
    else: "Traces"

func windowTitle*(panels: openArray[Panel]; k: int): string =
  ## The title of `panels[k]`'s window: what it shows (`contentName`),
  ## numbered from the second window of that name on, in the order of
  ## `panels` ("Seismic", "Seismic 2").
  result = contentName(panels[k])
  var n = 1
  for i in 0 ..< k:
    if contentName(panels[i]) == result: inc n
  if n > 1: result.add " " & $n

func presetOf*(order: openArray[SortKey]; presets: openArray[SortPreset] = SortPresets): int =
  ## The index in `presets` of the preset whose keys are `order`; -1 for
  ## none (the file's order, or keys of the user's own).
  for i, s in presets:
    if s.keys == @order: return i
  -1

func describe*(order: openArray[SortKey]): string =
  ## `order` in words: "line, then point (descending)"; "the file's order"
  ## for none.
  if order.len == 0: return "the file's order"
  for i, k in order:
    if i > 0: result.add ", then "
    result.add k.keyName
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

proc timeGainCurve*(d: DisplaySettings): GainCurve =
  ## The Exponential gain of `d` as processSEG's gain curve: `dbPerS` dB per
  ## second (`exponentialGain`) or the power of time (`powerGain`), rising
  ## until `untilMs` and held at its value there after it (processSEG's
  ## `heldGain`, a knot curve flat past its last knot). Raises `ValueError`
  ## for a setting that is not finite.
  let until = if d.untilMs.isNaN: 2000.0 else: clamp(d.untilMs, MinUntilMs, MaxUntilMs)
  case d.timeGain
  of tgDbPerSecond: heldGain(exponentialGain(d.dbPerS), until)
  of tgPower: heldGain(powerGain(d.power), until)

func normalizesWhole*(layer: Layer; kind: GatherKind): bool =
  ## Whether the display gain sets each trace's level from the whole trace (Normalized,
  ## for each trace): the reader then decodes whole traces, as it does for the filters,
  ## so that the level does not change with the part in view.
  layer.display.cpuGain(kind) == dgNormalized

func displayPipeline*(layer: Layer; kind: GatherKind): Pipeline =
  ## What the reader runs on layer `layer`'s samples: the polarity reversal
  ## when every trace is reversed (`polarityOp`), its pipeline, then the CPU
  ## part of its display gain.
  result = initPipeline()
  if layer.reversed: result.add polarityOp()
  for op in layer.pipeline: result.add op
  let d = layer.display
  case d.cpuGain(kind)
  of dgAgc: result.add agcOp(windowMs = d.agcWindowMs)
  of dgNormalized: result.add normalizeOp(d.normStat, perTrace, percentile = d.clipPercentile)
  of dgExponential:
    try:
      result.add gainCurveOp(timeGainCurve(d))
    except ValueError:
      discard # a value that is not finite: no curve (the control refuses one)
  else: discard

func flowReachesAux*(layer: Layer; kind: GatherKind): bool =
  ## Whether the display gain's CPU part runs on the auxiliary traces too:
  ## the types that set each trace's own size (Normalized for each trace, AGC)
  ## do, so a trace of 60 000 and one of 1 come out alike; the others are a
  ## scale of the record or a curve in time, and leave an auxiliary trace as
  ## it is.
  layer.display.cpuGain(kind) in {dgNormalized, dgAgc}

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
      result = a.timeGain == b.timeGain and a.untilMs == b.untilMs and
        (if a.timeGain == tgDbPerSecond: a.dbPerS == b.dbPerS else: a.power == b.power)
    else: discard

func onlyClipDiffers*(a, b: DisplaySettings; kind: GatherKind): bool =
  ## Whether the clip percentile is all that gives a gather of `kind`
  ## other samples or another level under `a` than under `b`: then the
  ## reader makes the new tiles from the samples it holds, and the plot
  ## keeps the old ones until they come.
  var c = a
  c.clipPercentile = b.clipPercentile
  a.clipPercentile != b.clipPercentile and sameProcessing(c, b, kind)

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

func appliedGainDb*(d: DisplaySettings; kind: GatherKind): float64 =
  ## The gain amount `d` draws a gather of `kind` with: 0 under the type none (the samples
  ## as stored; the amount is kept for the other types), else `gainDb`.
  if d.effectiveGain(kind) == dgNone: 0.0 else: d.gainDb

func withGainDb*(d: DisplaySettings; db: float64): DisplaySettings =
  ## `d` with the gain amount `db`, within ± `MaxGainDb` (0 for a value that
  ## is not a number).
  result = d
  result.gainDb = if db.isNaN: 0.0 else: clamp(db, -MaxGainDb, MaxGainDb)

func opaqueOrNone(c: Rgba): Rgba =
  ## A colour a user chose, opaque; alpha 0 (none chosen) stays that.
  if c.a == 0: Rgba() else: Rgba(r: c.r, g: c.g, b: c.b, a: 255)

func bounded*(d: DisplaySettings): DisplaySettings =
  ## `d` with each number within the range the gain's controls and the
  ## settings file take (a command from elsewhere, an agent's, can give any
  ## number): clamped, and one that is not a number set to its default.
  ## A Fixed gain's amplitude that is not positive and finite is none yet
  ## (NaN), as the "From this record" button gives.
  template within(x: float64; lo, hi, default: float64): float64 =
    if x.isNaN: default else: clamp(x, lo, hi)
  const defaults = DisplaySettings()
  result = d.withGainDb(d.gainDb)
  result.overlap = within(d.overlap, MinOverlap, MaxOverlap, defaults.overlap)
  result.agcWindowMs = within(d.agcWindowMs, MinAgcWindowMs, MaxAgcWindowMs,
    defaults.agcWindowMs)
  result.fixedClip = if d.fixedClip > 0 and d.fixedClip < Inf:
                       clamp(d.fixedClip, MinFixedClip, MaxFixedClip)
                     else: NaN
  result.dbPerS = within(d.dbPerS, -MaxDbPerS, MaxDbPerS, defaults.dbPerS)
  result.power = within(d.power, -MaxPower, MaxPower, defaults.power)
  result.untilMs = within(d.untilMs, MinUntilMs, MaxUntilMs, defaults.untilMs)
  result.clipPercentile = within(d.clipPercentile, MinClipPercentile, 100.0,
    defaults.clipPercentile)
  result.breakModel = d.breakModel.bounded
  result.breakPickColour = d.breakPickColour.opaqueOrNone
  result.breakModelColour = d.breakModelColour.opaqueOrNone

func drawsWiggles*(d: DisplaySettings): bool {.inline.} =
  ## Whether a layer drawn with `d` shows wiggles: in the wiggle modes, at
  ## every zoom.
  d.mode != dmDensity

func drawsDensity*(d: DisplaySettings): bool {.inline.} =
  ## Whether a layer drawn with `d` shows density: only in the modes the
  ## user chose it with (density, and wiggles over density).
  d.mode != dmWiggle

func effectiveOverlap*(d: DisplaySettings): float64 =
  ## The trace overlap `d` draws with: within `MinOverlap .. MaxOverlap`, 1
  ## for one that is not a number (`clamp` would keep it, and nothing would
  ## be drawn).
  if d.overlap.isNaN: 1.0 else: clamp(d.overlap, MinOverlap, MaxOverlap)

func turn*(d: DisplaySettings): Turn {.inline.} =
  ## The mapping between data and screen of a plot drawn with `d`.
  turnOf(d.orientation)

func traceMargin*(d: DisplaySettings): float64 =
  ## How far a view of a layer drawn with `d` reaches past the first and
  ## last trace's cells, in trace spacings: in the wiggle modes, the swing
  ## the trace overlap allows beyond them (`overlap - 0.5`), so those
  ## traces' outer lobes are shown whole; none in the density mode, or for
  ## an overlap that keeps every lobe within its trace's cell.
  if d.drawsWiggles: max(0.0, d.effectiveOverlap - 0.5) else: 0.0

func viewLimits*(layout: PanelLayout; d: DisplaySettings; columns: int): ViewLimits =
  ## The limits (`core/zoom`) of a view of a layer of `layout` drawn with
  ## `d` on a plot `columns` pixels long along the positions
  ## (`Viewport.columns`, whichever way it is turned): the data's, reaching
  ## `traceMargin` past the first and last trace, and in the wiggle modes
  ## no more traces than `columns / MinTracePixels`, so every trace in view
  ## is drawn. A plot whose size is not known yet (0) has no such limit.
  let widest = if d.drawsWiggles and columns > 0: float64(columns) / MinTracePixels else: Inf
  limitsOf(layout, widest, d.traceMargin)

func viewLimits*(p: Panel; layout: PanelLayout; columns: int): ViewLimits =
  ## The limits of a view of `layout` (`p.layout`, or the gather it showed
  ## before) on a plot `columns` pixels along the positions, as `p`'s layer
  ## 0 is drawn; a
  ## panel with no layer draws nothing, and only the data limits it.
  if p.layers.len == 0: limitsOf(layout)
  else: viewLimits(layout, p.layers[0].display, columns)

func viewLimits*(p: Panel; columns: int): ViewLimits {.inline.} =
  ## The limits of `p`'s view on a plot `columns` pixels along the
  ## positions.
  p.viewLimits(p.layout, columns)

func allShown*(p: Panel; base: int): seq[int] =
  ## Every trace `p` shows, in the order shown, as survey-wide ids (its file's trace 0 is
  ## `base`): after the Seismic / Aux choice and the killed traces it hides. What Select
  ## all selects. Empty until the reader has said what is shown.
  for k in p.shown: result.add base + k

func rangeOf*(p: Panel; base, anchor, to: int): seq[int] =
  ## The traces `p` shows from survey-wide trace `anchor` to `to`, both
  ## included, in the order shown, as survey-wide ids (its file's trace 0 is
  ## `base`): what a Shift + click selects. `@[to]` alone when `anchor` is
  ## not shown (none, another file, another gather) or the order is not
  ## known yet.
  let a = p.shown.find(anchor - base)
  let b = p.shown.find(to - base)
  if anchor < 0 or a < 0 or b < 0: return @[to]
  for k in min(a, b) .. max(a, b): result.add base + p.shown[k]

func sameReach*(a, b: ReadRequest): bool =
  ## Whether `a` and `b` read the same traces and samples, at the same
  ## resolution (whatever their `gen`, margin or extremes).
  a.first == b.first and a.count == b.count and a.stride == b.stride and
    a.firstSample == b.firstSample and a.samples == b.samples and a.decimation == b.decimation

const MaxBasisTraces* = 256
  ## traces the record's level is taken over, at most, when the record's
  ## first view is not all of it (`recordRequest`): a few reads

func wholeRecord*(r: ReadRequest; layout: PanelLayout): bool =
  ## Whether `r` reads all of the record `layout` lays out: from its first
  ## position to its last (every `stride`-th) and every sample.
  not r.isEmpty and r.first == 0 and r.last + r.stride >= layout.traces and
    r.firstSample == 0 and r.samples >= layout.samples

func recordRequest*(p: Panel; margin: int): ReadRequest =
  ## What the record's level is taken over when the record's first view is
  ## not all of it (zoomed, the scales carried from the record before; a
  ## wiggle mode's first screen): every trace, or every `stride`-th so that
  ## at most `MaxBasisTraces` are read, and every sample at the plot's
  ## resolution in time. Empty while the plot's size is not known.
  result = ReadRequest(stride: 1, decimation: 1)
  if p.layers.len > 0 and p.layout.traces > 0 and p.view.columns > 0 and p.view.rows > 0:
    var d = p.layers[0].display
    d.mode = dmDensity # all of it: no wiggle mode's limit
    let columns = min(p.view.columns, MaxBasisTraces)
    result = requestFor(p.layout, fitted(viewLimits(p.layout, d, columns), columns,
      p.view.rows), margin, readAhead = 0)

func levelSampling*(p: Panel): string =
  ## Over which traces `p`'s record's level is taken, when not over every
  ## one: "every 4th trace" (a trace louder than its neighbours between
  ## them is missed, which a peak or a clip of 100 would show); "" for every
  ## trace, or while it is not known.
  let n = p.basis.stride
  if p.basis.isEmpty or n <= 1: return ""
  let suffix = if n mod 100 in 11 .. 13: "th"
               else:
                 case n mod 10
                 of 1: "st"
                 of 2: "nd"
                 of 3: "rd"
                 else: "th"
  "every " & $n & suffix & " trace"

func displayMargin*(flow: Pipeline; dtMs: float64): int =
  ## The samples `flow` needs beyond a window on each side; 0 when it
  ## cannot say (an invalid op: the reader reports it).
  if not (dtMs > 0 and dtMs < Inf): return 0
  try:
    flow.requiredMargin(dtMs)
  except ValueError:
    0
