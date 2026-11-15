## The user's settings: everything the program remembers between runs.
## The theme, where the main window was, the recent files and folders, what
## a new plot window starts with (display, order, display header), how
## scales are stated, each monitor's calibration, the status bar's fields,
## the sort presets, the user's own sort keys, the Messages window's
## toggles, the plot's cursor time line, whether the Files window follows
## the latest file, where the map shows the point under the pointer, the
## survey import's options (File > Import > Survey), and the Headers window's
## tabs, toggles and columns.
## Every field has a default.
##
## Changed only through `Command`s (`core/state`): `ckSettings` for the
## whole object, and the plot window's own commands (display, sort, display
## header), which the new plot window defaults follow. Saved as NIF
## (`core/settingsnif`) by `AppState`, which keeps two: those in effect for
## the session, and those the user left by hand, which are saved (an
## agent's changes are for the session only; `carried` takes the user's
## change from one to the other).

import std/math
import join, log, mapkinds, panels, readout, scales

export join, mapkinds, readout, scales

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
    ## display header and the filters chosen last. Polarity is not kept:
    ## reversing it is an operation on the data, not a way of looking at it;
    ## nor is showing a plot raw (`Processing.raw`).
    display*: DisplaySettings
    order*: seq[SortKey]
    header*: HeaderChoice
    processing*: Processing

  MessagesView* = object
    ## How the Messages window shows the log.
    autoScroll*: bool = true ## follow new messages; off: stay where the user scrolled
    hidden*: set[Severity]   ## severities not shown (an error hides with sevFatal)

  FilesView* = object
    ## How the Files window follows its folder.
    followLatest*: bool
      ## show each new file in the plot once it is completely written; off:
      ## the plot stays on the file the user chose
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

  Settings* = object
    theme*: string                                ## the theme file's name; "" follows the system
    window*: WindowPlacement
    recentFiles*: seq[string]                     ## the files opened last, newest first
    recentFolders*: seq[string]                   ## their folders, newest first
    plot*: PlotDefaults
    scale*: ScaleUnits                            ## per inch or cm; time as ms per length or speed
    calibrations*: seq[Calibration]               ## one per calibrated monitor
    readout*: seq[ReadoutField] = @DefaultReadout ## the status bar's fields, in order
    sortPresets*: seq[SortPreset] = @SortPresets  ## the plot window's sort buttons
    customOrder*: seq[SortKey]                    ## the user's own keys, used last
    messages*: MessagesView                       ## the Messages window's toggles
    cursorLine*: bool                             ## the plot's cursor time line is on
    files*: FilesView                             ## the Files window's toggles
    map*: MapOptions                              ## the map's own settings
    join*: JoinOptions                            ## the geometry join's options, as set last
    headers*: HeadersView                         ## the Headers window's tabs and toggles

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

func same[T](a, b: T): bool {.inline.} =
  ## `a == b`, a value that is not a number equal to itself (as the settings
  ## file has it).
  when T is SomeFloat: a == b or (a.isNaN and b.isNaN)
  else: a == b

func carried*[T: Settings | PlotDefaults | DisplaySettings](kept, before, after: T): T =
  ## `kept` with what changed from `before` to `after`: each setting that
  ## differs, as `after` has it. A new plot's defaults and their display are
  ## taken field by field (each is a choice of its own: a new display mode
  ## leaves the gain as `kept` has it); every other setting whole (a list, a
  ## placement, a group of toggles).
  result = kept
  for name, r in fieldPairs(result):
    for key, b, a in fieldPairs(before, after):
      when key == name:
        when r is PlotDefaults or r is DisplaySettings:
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
  ## listed twice, a sort preset without a name or keys, or named twice),
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
  r.plot.processing = remembered(bounded(s.plot.processing))
  r.recentFiles = uniqueItems(s.recentFiles)
  r.recentFolders = uniqueItems(s.recentFolders)
  if not (r.window.width > 0 and r.window.height > 0):
    r.window = WindowPlacement()
  r.map.spreadTemplate = bounded(s.map.spreadTemplate)
  (r, s.calibrations.len - r.calibrations.len + s.readout.len - r.readout.len +
    s.sortPresets.len - r.sortPresets.len)
