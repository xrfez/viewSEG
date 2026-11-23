## The user's settings: everything the program remembers between runs.
## The theme, where the main window was, the recent files, folders and
## projects (and the project open at the quit, opened again at start), what
## a new plot window starts with (display, order, display header, which traces), how
## scales are stated, each monitor's calibration, the status bar's fields,
## the sort presets, the user's own sort keys, the Messages window's
## toggles, the plot's cursor time line, whether the Files window follows
## the latest file, where the map shows the point under the pointer, the
## survey import's options (Project > Import survey), the Headers window's
## tabs, toggles and columns, whether killed traces are hidden, how the
## spectrum windows show their spectra, the named display presets, the
## colours of a multi-component record, and whether a plot shows a physical
## value in metric or imperial units.
## Every field has a default.
##
## Changed only through `Command`s (`core/state`): `ckSettings` for the
## whole object, and the plot window's own commands (display, sort, display
## header, trace filter), which the new plot window defaults follow. Saved as NIF
## (`core/settingsnif`) by `AppState`, which keeps two: those in effect for
## the session, and those the user left by hand, which are saved (an
## agent's changes are for the session only; `carried` takes the user's
## change from one to the other).

import std/math
import components, displaypresets, geometry, join, log, mapkinds, noisearea, panels, plotoptions,
  readout, scales, spectra, tracetable, units

export displaypresets, join, mapkinds, noisearea, plotoptions, readout, scales, spectra, units

type
  Calibration* = object
    ## A monitor's measured pixel size.
    monitor*: string ## the monitor, as the frontend names it (its name and size in pixels)
    ppi*: float64    ## framebuffer pixels per inch

  WindowPlacement* = object
    ## Where the main window was, in the desktop's coordinates: its place
    ## and size when not maximized. A `width` of 0: never saved, so the
    ## window opens at its default size where the desktop puts it.
    x*, y*: int
    width*, height*: int
    maximized*: bool

  PlotDefaults* = object
    ## What a new plot window starts with: the display, the order, the
    ## display header, the filters and which traces (seismic, auxiliary)
    ## chosen last. Polarity is not kept: reversing it is an operation on
    ## the data, not a way of looking at it; nor is showing a plot raw
    ## (`Processing.raw`). Which components are off is not kept: that choice
    ## holds for one file and starts all on for the next.
    display*: DisplaySettings
    order*: seq[SortKey]
    header*: HeaderChoice
    processing*: Processing
    seismic*: bool = true ## seismic traces
    auxiliary*: bool ## auxiliary traces
    templateOnly*: bool ## only the traces the record's template lists (`TraceFilter.templateOnly`)

  AuxDefaults* = object
    ## What the Aux window starts with and keeps: its display (wiggles; the gain types
    ## it offers, Normalized at first; a trace spacing of swing; a red wiggle line and
    ## positive fill, black negative fill) and its display header. Not the main plot's:
    ## its gain, fills and look are its own.
    display*: DisplaySettings = DisplaySettings(gain: dgNormalized, overlap: 1.0,
      colours: pcRedPaper)
    header*: HeaderChoice

  MessagesView* = object
    ## How the Messages window shows the log.
    autoScroll*: bool = true ## follow new messages; off: stay where the user scrolled
    hidden*: set[Severity]   ## severities not shown (an error hides with sevFatal)

  TrayOptions* = object
    ## The program's icon in the system tray (the notification area).
    icon*: bool = true
      ## the icon is there, with a menu: Show viewSEG, Open file..., Quit
    minimize*: bool
      ## minimizing the main window hides it in the tray instead of the
      ## taskbar (with the icon on)

  FilesView* = object
    ## How the Files window follows its folder.
    followLatest*: bool
      ## show each new file in the plot once it is completely written; off:
      ## the plot stays on the file the user chose
    subfolders*: bool
      ## list the files of the folder's subfolders too ("Include subfolders"), when no
      ## project is open (a project keeps its own)
    listSignatureFiles*: bool = true
      ## list a vibrator controller's `.dat` and `.vib` signature files in the Files window,
      ## step through them and follow them like seismic files ("Signature files"); off: they
      ## stay in the scan, counted, and are left out of the table, the steps and Follow
    prepareNext*: bool = true
      ## open the next file of the list in the background while one is
      ## shown (its index, its first view's samples), so that stepping
      ## through a folder on a slow drive does not wait at every file

  MapInfo* = enum
    ## Where the map shows the information of the point under the pointer.
    miPopup = "popup" ## in a popup beside the pointer
    miStrip = "strip" ## in a strip along the map's bottom edge

  MapLengths* = enum
    ## The unit the map's scale bar and ruler state lengths in.
    dlSurvey = "the survey's unit" ## as the survey's coordinates are
    dlMetres = "metres"
    dlFeet = "feet"                ## international feet: 0.3048 m
    dlUsFeet = "US survey feet"    ## 1200/3937 m

  MapOptions* = object
    ## How the map shows what it shows.
    info*: MapInfo ## where the point under the pointer is described
    lengths*: MapLengths
      ## the unit of the scale bar's and the ruler's lengths, converted from
      ## the survey's when another is chosen
    hiddenGroups*: set[MapGroup]
      ## the groups of layers hidden as a whole (the Preplot, the Recorded)
    templateBox*: bool
      ## the box round the spread planned for the record shown and for the
      ## shot under the pointer is drawn (off by default)
    spreadTemplate*: TemplateSpec
      ## what planned spreads are generated from when no relation file is loaded
    folderShots*: bool = true
      ## the survey's sources whose record is in a file of the folder listed are marked
    filters*: set[MapFilter]
      ## the filters the map marks (none by default)

  HeadersTab* = enum
    ## The Headers window's tabs.
    htSummary = "Summary"
    htFile = "File headers"
    htTrace = "Trace"
    htTable = "Trace table"

  TraceTab* = enum
    ## The Trace tab's own tabs.
    ttHeader = "Header" ## every header field of the traces
    ttData = "Data"     ## their samples

  HeaderColumn* = enum
    ## The columns of the header tables that can be shown or hidden.
    hcDescription = "Description" ## the field in plain words
    hcName = "Name"               ## its name as parseSEG and the patches give it (block.field)
    hcBytes = "Bytes"             ## the bytes it takes in its block, from 1
    hcOffset = "Offset"           ## the file offset of its first byte

  HeadersView* = object
    ## How the Headers window shows what it shows.
    tab*: HeadersTab                                       ## the tab shown
    traceTab*: TraceTab                                    ## the Trace tab's own tab shown
    followPointer*: bool = true
      ## with no trace selected, the Trace tab shows the trace under the
      ## pointer (in the plot, or a receiver's on the map)
    asDisplayed*: bool
      ## the Data tab's samples after the edits, the polarity and the
      ## display gain's processing; off: as recorded
    columns*: set[HeaderColumn] = {hcDescription, hcBytes} ## the columns shown
    tableFields*: seq[string] = @DefaultTableFields
      ## the trace table's columns, after the trace's number (`core/tracetable`)
    tableScope*: TableScope ## the trace table's rows: the record shown, or the file

  SpectrumOptions* = object
    ## How the spectrum windows show their spectra: each new FFT window as
    ## the last one changed, the live panel as it was left.
    window*: SpectrumDisplay ## a new FFT window's (the whole trace by default)
    live*: SpectrumDisplay = SpectrumDisplay(time: stVisible)
      ## the live panel's (the visible time by default: it follows the view)

  ForceScale* = object
    ## The user's force scale for a vibrator signature file: display and the verdict only,
    ## the samples stay raw counts. Never shipped: a local setting.
    datCountsPerLbf*: float64 = NaN ## a `.dat`: counts per pound-force; NaN: counts
    vibAccMvPerCount*: float64 = NaN
      ## a `.vib`: the accelerometer constant (the header's sensitivity turns it into a
      ## force factor, `scaleOf`); NaN: pound-counts

  Settings* = object
    theme*: string                                ## the theme file's name; "" follows the system
    units*: UnitSystem
      ## how a plot shows a physical value (a mass, a force, a velocity);
      ## Metric, the default. An older file that does not say loads as Metric.
    noise*: NoiseSettings
      ## how the noisy-trace test sets its exclusion area: automatic, or a fixed time, a
      ## radius or a number of stations
    window*: WindowPlacement
    recentFiles*: seq[string] ## the files opened last, newest first
    recentFolders*: seq[string] ## their folders, newest first
    recentProjects*: seq[string] ## the project folders opened last, newest first
    lastProject*: string ## the project open at the quit; "" for none
    reopenProject*: bool = true ## start with the project open at the quit
    referenceId*: string
      ## the reference the plots use when no project is open; "" is the file's own pilot
    forceScale*: ForceScale ## a signature file's force scale (Vibrator window)
    vibRoles*: seq[string]
      ## the vibrator signature's roles chosen by hand, per file layout, when no project is
      ## open (`choiceText`)
    plot*: PlotDefaults
    aux*: AuxDefaults ## the Aux window's display and header
    scale*: ScaleUnits ## per inch or cm; time as ms per length or speed
    calibrations*: seq[Calibration] ## one per calibrated monitor
    readout*: seq[ReadoutField] = @DefaultReadout ## the status bar's fields, in order
    sortPresets*: seq[SortPreset] = @SortPresets ## the plot window's sort buttons
    customOrder*: seq[SortKey] ## the user's own keys, used last
    messages*: MessagesView ## the Messages window's toggles
    cursorLine*: bool ## the plot's cursor time line is on
    files*: FilesView ## the Files window's toggles
    map*: MapOptions ## the map's own settings
    join*: JoinOptions ## the geometry join's options, as set last
    headers*: HeadersView ## the Headers window's tabs and toggles
    hideKilled*: bool
      ## killed traces are left out of the plot (the traces beside them close
      ## up); off: drawn blank
    spectrum*: SpectrumOptions ## the spectrum windows' display
    plotOptions*: PlotOptions
      ## the New plot windows' options, per kind: a new window opens with them
    displayPresets*: seq[DisplayPreset] ## named displays, in the order made
    tray*: TrayOptions ## the tray icon and minimizing to it
    componentColours*: array[4, Rgba] = DefaultComponentColours
      ## hydrophone, vertical, inline, crossline: the Seismic window's
      ## component buttons and, on a multi-component record, its traces

func calibration*(s: Settings; monitor: string): float64 =
  ## The calibrated pixels per inch of `monitor`; NaN when it is not
  ## calibrated.
  for c in s.calibrations:
    if c.monitor == monitor: return c.ppi
  NaN

func ppiFor*(s: Settings; monitor: string; displayScale: float64): float64 =
  ## The pixels per inch of `monitor`: its calibration, else
  ## `defaultPpi(displayScale)`.
  let c = s.calibration(monitor)
  if c.isNaN: defaultPpi(displayScale) else: c

proc calibrate*(s: var Settings; monitor: string; ppi: float64) =
  ## Sets `monitor`'s pixels per inch; NaN removes its calibration. Raises
  ## `ValueError` for a value that is neither NaN nor positive and finite.
  if not ppi.isNaN and not (ppi > 0 and ppi < Inf):
    raise newException(ValueError, "pixels per inch must be positive, got " & $ppi)
  var kept: seq[Calibration]
  for c in s.calibrations:
    if c.monitor != monitor: kept.add c
  if not ppi.isNaN: kept.add Calibration(monitor: monitor, ppi: ppi)
  s.calibrations = kept

func remembered*(d: DisplaySettings): DisplaySettings =
  ## `d` as new plot windows keep it: shown. (The polarity is not a display
  ## setting: `Layer.reversed`.)
  result = d
  result.visible = true

func sameScale*(a, b: ForceScale): bool =
  ## Whether two force scales are the same (an empty one, NaN, equal to another).
  func eq(x, y: float64): bool = x == y or (x.isNaN and y.isNaN)
  eq(a.datCountsPerLbf, b.datCountsPerLbf) and eq(a.vibAccMvPerCount, b.vibAccMvPerCount)

func `==`*(a, b: ForceScale): bool =
  ## An empty scale (NaN) equals another empty one.
  sameScale(a, b)

func same[T](a, b: T): bool =
  ## `a == b`, a value that is not a number equal to itself (as the settings
  ## file has it), also inside a list of objects (the display presets).
  when T is SomeFloat: a == b or (a.isNaN and b.isNaN)
  elif T is seq[DisplayPreset]: samePresets(a, b)
  elif T is ForceScale: sameScale(a, b)
  else: a == b

func carried*[T: Settings | PlotDefaults | AuxDefaults | DisplaySettings](kept, before, after: T): T =
  ## `kept` with what changed from `before` to `after`: each setting that
  ## differs, as `after` has it. A new plot's defaults and their display are
  ## taken field by field (each is a choice of its own: a new display mode
  ## leaves the gain as `kept` has it); every other setting whole (a list, a
  ## placement, a group of toggles).
  result = kept
  for name, r in fieldPairs(result):
    for key, b, a in fieldPairs(before, after):
      when key == name:
        when r is PlotDefaults or r is AuxDefaults or r is DisplaySettings:
          r = carried(r, b, a)
        else:
          if not same(b, a): r = a

proc addRecent*(list: var seq[string]; item: string; most: Positive) =
  ## Puts `item` first in `list`, once, keeping at most `most` items.
  var kept = @[item]
  for x in list:
    if x != item and kept.len < most: kept.add x
  list = kept

func uniqueKeys*(order: openArray[SortKey]): seq[SortKey] =
  ## `order` with each field once, at its first place.
  for k in order:
    var seen = false
    for g in result:
      if g.field == k.field: seen = true
    if not seen: result.add k

func uniqueItems(list: openArray[string]): seq[string] =
  ## `list` without empty items, each once, at its first place.
  for x in list:
    if x.len > 0 and x notin result: result.add x

func cleaned*(s: Settings): (Settings, int) =
  ## `s` without what cannot be used (a calibration that is not positive
  ## and finite, a monitor calibrated twice: the last one counts, a field
  ## listed twice, a sort preset without a name or keys, or named twice, a
## display preset that cannot be named so, or named twice),
  ## and how many entries were dropped. A recent file listed twice, or a
  ## sort key given twice in one order, is kept once without counting.
  var r = s
  r.calibrations.setLen 0
  for i in countdown(s.calibrations.high, 0):
    let c = s.calibrations[i]
    var seen = false
    for d in r.calibrations:
      if d.monitor == c.monitor: seen = true
    if c.ppi > 0 and c.ppi < Inf and not seen: r.calibrations.insert(c, 0)
  r.readout = cleaned(s.readout)
  r.sortPresets.setLen 0
  for p in s.sortPresets:
    var named = p.name.len == 0
    for q in r.sortPresets:
      if q.name == p.name: named = true
    if not named and p.keys.len > 0:
      r.sortPresets.add SortPreset(name: p.name, keys: uniqueKeys(p.keys))
  r.customOrder = uniqueKeys(s.customOrder)
  r.plot.order = uniqueKeys(s.plot.order)
  r.plot.display = remembered(s.plot.display)
  r.aux.display = forAux(remembered(s.aux.display))
  r.plot.processing = remembered(bounded(s.plot.processing))
  r.recentFiles = uniqueItems(s.recentFiles)
  r.recentFolders = uniqueItems(s.recentFolders)
  r.recentProjects = uniqueItems(s.recentProjects)
  if not (r.window.width > 0 and r.window.height > 0):
    r.window = WindowPlacement()
  r.map.spreadTemplate = bounded(s.map.spreadTemplate)
  r.noise = bounded(s.noise)
  r.displayPresets = cleaned(s.displayPresets)
  (r, s.calibrations.len - r.calibrations.len + s.readout.len - r.readout.len +
    s.sortPresets.len - r.sortPresets.len + s.displayPresets.len - r.displayPresets.len)
