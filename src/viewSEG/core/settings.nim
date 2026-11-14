## The user's settings: everything the program remembers between runs.
## The theme, where the main window was, the recent files and folders, what
## a new plot window starts with (display, order, display header), how
## scales are stated, each monitor's calibration, the status bar's fields,
## the sort presets, the user's own sort keys and the Messages window's
## toggles. Every field has a default.
##
## Changed only through `Command`s (`core/state`): `ckSettings` for the
## whole object, and the plot window's own commands (display, sort, display
## header), which the new plot window defaults follow. Saved as NIF
## (`core/settingsnif`) by `AppState`.

import std/math
import log, panels, readout, scales

export readout, scales

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
    ## What a new plot window starts with: the display, the order and the
    ## display header chosen last. Polarity is not kept: reversing it is an
    ## operation on the data, not a way of looking at it.
    display*: DisplaySettings
    order*: seq[SortKey]
    header*: HeaderChoice

  MessagesView* = object
    ## How the Messages window shows the log.
    autoScroll*: bool = true ## follow new messages; off: stay where the user scrolled
    hidden*: set[Severity]   ## severities not shown (an error hides with sevFatal)

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

proc addRecent*(list: var seq[string]; item: string; most: Positive) =
  ## Puts `item` first in `list`, once, keeping at most `most` items.
  var kept = @[item]
  for x in list:
    if x != item and kept.len < most: kept.add x
  list = kept

func uniqueKeys(order: openArray[SortKey]): seq[SortKey] =
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
  r.recentFiles = uniqueItems(s.recentFiles)
  r.recentFolders = uniqueItems(s.recentFolders)
  if not (r.window.width > 0 and r.window.height > 0):
    r.window = WindowPlacement()
  (r, s.calibrations.len - r.calibrations.len + s.readout.len - r.readout.len +
    s.sortPresets.len - r.sortPresets.len)
