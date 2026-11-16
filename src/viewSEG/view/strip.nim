## What the Seismic window's control strip shows, apart from drawing it:
## which groups a record and a display mode put in the strip, the sort
## drop-down's label and which of its rows are greyed, and the words the
## gain box shows.

import std/[math, strutils]
import ../core/panels

type
  StripGroup* = enum
    ## The strip's groups, left to right. The gear is not one of them: it
    ## stays at the right end of the first row. `sgComponents` is reserved
    ## for one toggle per component, drawn after the trace toggles; nothing
    ## adds it to the strip yet.
    sgRecord, sgZoom, sgDisplay, sgGain, sgFilters, sgSort, sgTraces, sgComponents

  SortRowKind* = enum
    srFileOrder, srPreset, srSeparator, srCustom

  SortRow* = object
    kind*: SortRowKind
    label*: string
    preset*: int = -1 ## index in the presets, for a preset row
    greyed*: bool
    inUse*: bool
    tip*: string

  SortPick* = object
    ## What a click on a sort row does. `acts` sends `order` (empty: the
    ## file's order). `opensCustom` opens the popover of the user's own
    ## keys. A row already in use, a greyed preset and the separator do
    ## neither.
    acts*: bool
    order*: seq[SortKey]
    opensCustom*: bool

func showTraceToggles*(hasAuxiliary, seismicOn, auxOn: bool): bool =
  ## The Seismic / Aux toggles are drawn when the record has auxiliary
  ## traces, or seismic is off, or aux is on.
  hasAuxiliary or not seismicOn or auxOn

func showFills*(mode: DisplayMode): bool =
  ## The fill toggles are drawn in the two wiggle modes, not in density.
  mode != dmDensity

func stripGroups*(showTraces: bool): seq[StripGroup] =
  ## The groups drawn, in order. `sgComponents` follows `sgTraces` when a
  ## later change draws it: the groups before it stay as they are.
  result = @[sgRecord, sgZoom, sgDisplay, sgGain, sgFilters, sgSort]
  if showTraces: result.add sgTraces

func sortInUse*(order: openArray[SortKey]; presets: openArray[SortPreset]): string =
  ## What the sort drop-down names: a preset's name, "file order", or "custom".
  if order.len == 0: return "file order"
  let i = presetOf(order, presets)
  if i >= 0: presets[i].name else: "custom"

func sortLabel*(order: openArray[SortKey]; presets: openArray[SortPreset]): string =
  ## The drop-down's label.
  "Sort: " & sortInUse(order, presets)

func sortTip*(order: openArray[SortKey]): string =
  ## The drop-down's tooltip: the keys in use.
  "Now: " & describe(order) & "."

func presetUsable*(keys: openArray[SortKey]; known: set[HeaderField]; inUse: bool): bool =
  ## A preset the traces have none of the keys of does nothing, unless it
  ## is the order in use (it stays selectable, so the order can be seen).
  if inUse: return true
  for k in keys:
    if k.field in known: return true
  false

func presetTip*(keys: openArray[SortKey]; usable: bool): string =
  ## The sentence the preset's button had, without the click that put the
  ## file's order back (that row is "File order" now).
  "Sort the traces by " & describe(keys) &
    (if usable: "." else: " (these traces have none of them).")

func sortRows*(order: openArray[SortKey]; presets: openArray[SortPreset];
    known: set[HeaderField]): seq[SortRow] =
  ## The drop-down's rows: the file's order, each preset, a separator, then
  ## Custom... A preset is greyed when the file has none of its keys, unless
  ## it is the order in use.
  let current = presetOf(order, presets)
  result.add SortRow(kind: srFileOrder, label: "File order", inUse: order.len == 0,
    tip: "The traces as they are in the file.")
  for i, s in presets:
    let inUse = i == current
    let usable = presetUsable(s.keys, known, inUse)
    result.add SortRow(kind: srPreset, label: s.name, preset: i, greyed: not usable,
      inUse: inUse, tip: presetTip(s.keys, usable))
  result.add SortRow(kind: srSeparator)
  let own = order.len > 0 and current < 0
  result.add SortRow(kind: srCustom, label: "Custom...", inUse: own,
    tip: "Sort the traces by keys of your own: header fields, the first first, each " &
      "ascending or descending." & (if own: "\nNow: " & describe(order) &
      ".\nFile order, in the list it opens, gives the file's order back." else: ""))

func sortPick*(row: SortRow; presets: openArray[SortPreset]): SortPick =
  ## What a click on `row` does. The preset already in use does nothing;
  ## so does a greyed one, and the separator.
  case row.kind
  of srSeparator: discard
  of srFileOrder:
    if not row.inUse: result = SortPick(acts: true)
  of srPreset:
    if not row.inUse and not row.greyed and row.preset >= 0 and row.preset <= presets.high:
      result = SortPick(acts: true, order: presets[row.preset].keys)
  of srCustom:
    result = SortPick(opensCustom: true)

func gainDbText*(db: float64): string =
  ## The gain box's text, the unit in the box: "+0.0 dB".
  let n = formatFloat(abs(db), ffDecimal, 1)
  (if db < 0: "-" else: "+") & n & " dB"

func parseGainDb*(text: string): float64 =
  ## A gain amount typed into the box: a bare number, or one followed by
  ## "dB". NaN when it is not a number.
  var s = text.strip
  if s.toLowerAscii.endsWith("db"):
    s = s[0 ..< s.len - 2].strip
  if s.len == 0: return NaN
  try:
    parseFloat(s)
  except ValueError:
    NaN
