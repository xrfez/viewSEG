## The filters a plot's traces are drawn through (`Layer.processing`).
##
## A layer's processing is plain data, edited in the plot window's
## processing popup and kept on the layer, so it goes with the plot to the
## next record and file; the settings keep the one a new plot starts with.
## It becomes processSEG operations (`filterPipeline`) for the file's sample
## interval when the panel's reader is asked for a view:
##
## - **DC removal**: none, the mean (`demeanOp`) or the mean and a linear
##   trend (`detrendOp`), before the filter;
## - **a pass band**: none, a low-cut (ramp `f1` to `f2`), a high-cut (`f3`
##   to `f4`) or a band-pass with all four corners (`bandPassOp`): cos²
##   ramps, zero phase, the edges handled by processSEG (`filterOp`, which
##   takes the trend out before it and puts it back scaled by the gain at
##   0 Hz);
## - **notches** (`withNotch`): each at `hz` with its `widthHz`, and its
##   harmonics (`2 hz`, `3 hz`, ...) when `harmonics` asks for them, the
##   usual 50 or 60 Hz power-line hum; in the same filter as the pass band.
##
## Corners and notches are taken within the file's Nyquist frequency
## (`limitNote` says what was cut): a ramp past it is ended at Nyquist, a
## side or a notch that cannot be is left out, so moving a slider never
## stops the processing.
##
## `raw` shows the traces without the filters (the display gain still
## applies, so the two compare); `aux` puts the auxiliary traces through
## the filters too (processSEG passes them by otherwise, as it does dead
## traces: `auxLiveRows`).
##
## The processing runs on the reader's thread, on the samples it already
## holds when only a parameter changed (`core/reader`).

import std/[math, strutils]
import parseSEG
import processSEG/pipeline
import processSEG/filter/design
import ./viewport

export design.Corners

type
  PassBand* = enum
    ## The filter's pass band.
    pbNone = "none"          ## no low-cut or high-cut
    pbLowCut = "low-cut"     ## cut below `f1 .. f2`
    pbHighCut = "high-cut"   ## cut above `f3 .. f4`
    pbBandPass = "band-pass" ## both: `f1 .. f2 .. f3 .. f4`

  DcRemoval* = enum
    ## What is taken off each trace before the filter.
    dcNone = "none"
    dcMean = "mean"            ## its mean (`demeanOp`)
    dcTrend = "mean and trend" ## its mean and linear trend (`detrendOp`)

  NotchFilter* = object
    ## A notch at `hz` Hz, `widthHz` wide (gain 1 again at `hz ± widthHz / 2`),
    ## and at its harmonics up to the `harmonics`-th (1: `hz` alone).
    on*: bool = true
    hz*: float64 = 60.0
    widthHz*: float64 = 2.0
    harmonics*: int = 1

  Processing* = object
    ## A layer's filters, and how they are shown (the module documentation).
    raw*: bool          ## the traces without the filters: as recorded, under the same gain
    aux*: bool          ## the auxiliary traces go through the filters too
    dc*: DcRemoval = dcNone
    band*: PassBand = pbNone
    f1*: float64 = 4.0  ## Hz: the low-cut ramp starts (gain 0 below)
    f2*: float64 = 8.0  ## Hz: the low-cut ramp ends (gain 1 above)
    f3*: float64 = 60.0 ## Hz: the high-cut ramp starts
    f4*: float64 = 80.0 ## Hz: the high-cut ramp ends (gain 0 above)
    notches*: seq[NotchFilter]

  FilterReach* = enum
    ## Which of the traces a plot shows its filters reach (`reach`).
    frNone = "none" ## no filter applied: none set, or shown raw
    frAll = "all"   ## every trace shown goes through them
    frSeismic = "seismic"
      ## the seismic traces; the auxiliary ones shown are passed by (`aux` off)
    frNoTrace = "no trace"
      ## none: every trace shown is auxiliary, and `aux` is off

const
  MaxFilterHz* = 10_000.0      ## a corner or notch stays within 0 and this
  MinRampHz* = 0.1             ## a ramp is at least this wide
  MinNotchHz* = 0.1            ## a notch's frequency, at least
  MinNotchWidthHz* = 0.1
  MaxNotchWidthHz* = 100.0
  MaxHarmonics* = 20           ## a notch's harmonics, at most
  MaxNotches* = 8              ## notches a layer has, at most
  NotchPresets* = [50.0, 60.0] ## the popup's quick notches: power-line hum

func hasLow*(b: PassBand): bool {.inline.} = b in {pbLowCut, pbBandPass}
func hasHigh*(b: PassBand): bool {.inline.} = b in {pbHighCut, pbBandPass}

func hasFilters*(p: Processing): bool =
  ## Whether `p` asks for anything to be done to the samples, shown raw or
  ## not.
  result = p.dc != dcNone or p.band != pbNone
  for n in p.notches:
    if n.on: result = true

func filtering*(p: Processing): bool {.inline.} =
  ## Whether the samples go through `p`'s filters now: some, and not raw.
  p.hasFilters and not p.raw

func bounded*(p: Processing): Processing =
  ## `p` with every number within what the filters take (a command from an
  ## agent can give any number): corners within `0 .. MaxFilterHz`, in order
  ## (`f1 < f2 <= f3 < f4`, each ramp at least `MinRampHz` wide), notches
  ## positive and their width and harmonics in range, at most `MaxNotches`.
  ## A value that is not a number takes its default.
  const d = Processing()
  template within(x, lo, hi, default: float64): float64 =
    if x.isNaN: default else: clamp(x, lo, hi)
  result = p
  var c = [within(p.f1, 0, MaxFilterHz, d.f1), within(p.f2, 0, MaxFilterHz, d.f2),
    within(p.f3, 0, MaxFilterHz, d.f3), within(p.f4, 0, MaxFilterHz, d.f4)]
  # In order, each ramp sloped: the corner the user moved pushes the others.
  for i in 1 .. 3:
    let gap = if i == 2: 0.0 else: MinRampHz
    if c[i] < c[i - 1] + gap: c[i] = c[i - 1] + gap
  if c[3] > MaxFilterHz:
    c[3] = MaxFilterHz
    for i in countdown(2, 0):
      let gap = if i == 1: 0.0 else: MinRampHz
      if c[i] > c[i + 1] - gap: c[i] = c[i + 1] - gap
  (result.f1, result.f2, result.f3, result.f4) = (c[0], c[1], c[2], c[3])
  result.notches.setLen 0
  for n in p.notches:
    if result.notches.len < MaxNotches:
      result.notches.add NotchFilter(on: n.on,
        hz: within(n.hz, MinNotchHz, MaxFilterHz, NotchFilter().hz),
        widthHz: within(n.widthHz, MinNotchWidthHz, MaxNotchWidthHz, NotchFilter().widthHz),
        harmonics: clamp(n.harmonics, 1, MaxHarmonics))

func reach*(p: Processing; seismic, aux: int): FilterReach =
  ## Which of a plot's traces `p` reaches, the plot showing `seismic`
  ## seismic and `aux` auxiliary ones (an auxiliary trace goes through the
  ## filters only with `aux`).
  if not p.filtering: frNone
  elif p.aux or aux == 0: frAll
  elif seismic == 0: frNoTrace
  else: frSeismic

func remembered*(p: Processing): Processing =
  ## `p` as a new plot starts with it: processed (`raw` is how one plot is
  ## shown for a while, not a choice for the next).
  result = p
  result.raw = false

type Limited = object
  ## The filter `p` gives at one sample interval, within Nyquist.
  band: PassBand
  corners: Corners
  notches: seq[Notch]
  note: string ## what was cut, in words; "" when nothing was

func number(x: float64): string =
  ## `x` Hz as the popup writes it: "60", "62.5".
  if x == round(x) and abs(x) < 1e9: $int(x) else: formatFloat(x, ffDecimal, 1)

func limited(p: Processing; dtMs: float64): Limited =
  result = Limited(band: p.band)
  if not (dtMs > 0 and dtMs < Inf): return
  let nyq = nyquistHz(dtMs)
  var cut: seq[string]
  var c = Corners(f1: p.f1, f2: p.f2, f3: p.f3, f4: p.f4)
  if result.band.hasHigh:
    if c.f3 >= nyq:
      cut.add "the high-cut (" & number(c.f3) & " Hz) is not below Nyquist"
      result.band = if result.band == pbBandPass: pbLowCut else: pbNone
    elif c.f4 > nyq:
      cut.add "the high-cut ramp ends at Nyquist, not " & number(c.f4) & " Hz"
      c.f4 = nyq
  if result.band.hasLow and c.f2 >= nyq:
    cut.add "the low-cut (" & number(c.f2) & " Hz) is not below Nyquist"
    result.band = if result.band == pbBandPass: pbHighCut else: pbNone
  if not result.band.hasLow: (c.f1, c.f2) = (0.0, 0.0)
  if not result.band.hasHigh: (c.f3, c.f4) = (Inf, Inf)
  result.corners = c
  var above = 0
  for n in p.notches:
    if n.on:
      for k in 1 .. max(1, n.harmonics):
        let hz = n.hz * float64(k)
        if hz < nyq: result.notches.add Notch(freqHz: hz, widthHz: n.widthHz)
        else: inc above
  if above > 0:
    cut.add (if above == 1: "a notch is" else: $above & " notches are") &
      " not below Nyquist and left out"
  if cut.len > 0:
    result.note = "Nyquist is " & number(nyq) & " Hz at " & number(dtMs) & " ms: "
    for i, s in cut:
      if i > 0: result.note.add "; "
      result.note.add s
    result.note.add "."

func limitNote*(p: Processing; dtMs: float64): string =
  ## What of `p` the sample interval `dtMs` cuts (a corner or notch at or
  ## past Nyquist), in a sentence; "" when nothing.
  if p.hasFilters: limited(p, dtMs).note else: ""

proc filterPipeline*(p: Processing; dtMs: float64): Pipeline =
  ## The processSEG operations `p` runs on traces `dtMs` apart: the DC
  ## removal, then the filter (`bandPassOp` for a pass band alone, else
  ## `filterOp` with the notches); none when shown raw. Within Nyquist (the
  ## module documentation); with an interval that is not known, the
  ## corners as they are (the reader says so if they do not compile).
  result = initPipeline()
  if not p.filtering: return
  case p.dc
  of dcNone: discard
  of dcMean: result.add demeanOp()
  of dcTrend: result.add detrendOp()
  let l = if dtMs > 0 and dtMs < Inf: limited(p, dtMs)
          else: Limited(band: p.band, corners: Corners(f1: p.f1, f2: p.f2, f3: p.f3, f4: p.f4))
  var c = l.corners
  if not l.band.hasLow: (c.f1, c.f2) = (0.0, 0.0)
  if not l.band.hasHigh: (c.f3, c.f4) = (Inf, Inf)
  var notches = l.notches
  if not (dtMs > 0 and dtMs < Inf):
    for n in p.notches:
      if n.on: notches.add Notch(freqHz: n.hz, widthHz: n.widthHz)
  try:
    if notches.len == 0:
      if l.band != pbNone: result.add bandPassOp(c)
    else:
      var spec = bandPass(c)
      for n in notches: spec = spec.withNotch(n.freqHz, n.widthHz)
      result.add filterOp(spec)
  except ValueError:
    discard # corners `bounded` would not give: no filter

proc filterPipeline*(p: Processing; layout: PanelLayout): Pipeline =
  ## The filters `p` runs on a panel's traces of `layout`: with no sample
  ## interval in the headers, the DC removal alone (a frequency means
  ## nothing without one: `intervalNote`).
  if not layout.noInterval: return p.filterPipeline(layout.dtMs)
  Processing(dc: p.dc, raw: p.raw).filterPipeline(layout.dtMs)

func intervalNote*(p: Processing; layout: PanelLayout): string =
  ## What the filters' drop-down says when the traces of `layout` have no
  ## sample interval and `p` sets a pass band or a notch; "" otherwise.
  var hz = p.band != pbNone
  for n in p.notches:
    if n.on: hz = true
  if layout.noInterval and hz:
    "The headers of this file give no sample interval, so the pass band and the " &
      "notches, set in Hz, are not applied to it" &
      (if p.dc != dcNone: "; the DC removal is." else: ".")
  else: ""

func filterNote*(p: Processing; layout: PanelLayout): string =
  ## What the filters' drop-down says of `p` on traces of `layout`: that
  ## they have no sample interval, or what Nyquist cuts (`limitNote`); "" when
  ## nothing.
  result = p.intervalNote(layout)
  if result.len == 0 and not layout.noInterval: result = p.limitNote(layout.dtMs)

func describe*(p: Processing): string =
  ## `p` in a few words, as the strip's button says it: "4-8-60-80 Hz,
  ## notch 60 Hz x3, DC"; "none" for no filter.
  result = ""
  case p.band
  of pbNone: discard
  of pbLowCut: result = "low-cut " & number(p.f1) & "-" & number(p.f2) & " Hz"
  of pbHighCut: result = "high-cut " & number(p.f3) & "-" & number(p.f4) & " Hz"
  of pbBandPass:
    result = number(p.f1) & "-" & number(p.f2) & "-" & number(p.f3) & "-" & number(p.f4) & " Hz"
  var on: seq[NotchFilter]
  for n in p.notches:
    if n.on: on.add n
  if on.len > 0:
    if result.len > 0: result.add ", "
    result.add "notch"
    for i, n in on:
      result.add (if i == 0: " " else: ", ") & number(n.hz) & " Hz"
      if n.harmonics > 1: result.add " x" & $n.harmonics
  if p.dc != dcNone:
    if result.len > 0: result.add ", "
    result.add (if p.dc == dcMean: "DC" else: "DC and trend")
  if result.len == 0: result = "none"

proc auxLiveRows*(rows: TraceRows; keys: var seq[TraceKeys]; samples: var seq[int]): TraceRows =
  ## A view of `rows` in which the auxiliary traces are live, so that a plan
  ## processes them as seismic traces (processSEG passes a row by unless its
  ## status is live or unknown): their keys copied into `keys`, their
  ## lengths into `samples`, which must outlive the view.
  keys.setLen rows.len
  samples.setLen rows.len
  for k in 0 ..< rows.len:
    keys[k] = rows.keysAt(k)
    if keys[k].status == tsAuxiliary: keys[k].status = tsLive
    samples[k] = rows.numSamples(k)
  rowsOf(keys, samples)

func hasAuxiliary*(rows: TraceRows): bool =
  ## Whether any of `rows` is an auxiliary trace.
  for k in 0 ..< rows.len:
    if rows.keysAt(k).status == tsAuxiliary: return true
  false
