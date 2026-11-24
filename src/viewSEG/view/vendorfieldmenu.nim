## What the display-line menu's "Vendor fields" submenu lists: the numeric vendor
## fields of the shown file, each ticked when it is a line of the display header,
## the fields a line cannot show, disabled with the reason, and the vendor lines
## chosen that the file does not have, kept so that they can be unticked.
##
## `vendorFieldMenu` makes the list from the state's answer (`core/vendorfieldlist`)
## and the header's lines; the toolkit only draws it. `withVendorLine` is the
## header a tick makes, to be sent as the display-header command.

import std/[options, strutils]
from ../core/panels import HeaderRef, MaxHeaderLines, hfVendor, vendorRef
import ../core/vendorfieldlist
from parseSEG import VendorLevel, vlRecord, vlTrace

const
  FilterAbove* = 25 ## more fields than this get a filter box
  ReadingWords* = "Reading…"
  ReadingTip* = "The vendor fields this file has are being listed."
  NoFieldsWords* = "No vendor fields: load a vendor header map (Tools > Reload vendor maps)."
  NoFieldsTip* = "No vendor header map loaded applies to this file, so it has no vendor " &
    "field. Maps are loaded from the project's, your own and the program's vendormaps " &
    "folders; Tools > Reload vendor maps reads them again."
  NoMatchWords* = "No vendor field matches the filter."
  TextTip* = "Text field: a display line shows numbers."
  RepeatTip* = "A field of a repeat: a display line shows one element of it, chosen " &
    "by name as name[i] with the command 'display header'."
  CapTip* = "A display header has at most " & $MaxHeaderLines &
    " lines: untick one to add this."
  MissingTip* = "Not in this file (a vendor map that defined it is not loaded or does " &
    "not apply): untick to remove the line."

type
  VendorMenuKind* = enum
    vmReading ## the fields are being listed: one disabled item
    vmNone    ## the file has no vendor field and no vendor line is chosen
    vmItems   ## `items`, which the filter may have left empty (`vmNoMatch`)
    vmNoMatch ## fields exist, none matches the filter

  VendorFieldItem* = object
    name*: string  ## what a tick chooses (`vendorRef`)
    label*: string ## the item's words
    tip*: string
    ticked*: bool
    enabled*: bool

  VendorFieldMenu* = object
    kind*: VendorMenuKind
    items*: seq[VendorFieldItem]
    filtered*: bool ## the filter box is wanted (more than `FilterAbove` fields)

func chosenNames(lines: openArray[HeaderRef]): seq[string] =
  for l in lines:
    if l.field == hfVendor: result.add l.name

func matches(name, filter: string): bool =
  filter.len == 0 or filter.toLowerAscii in name.toLowerAscii

func vendorFieldMenu*(list: Option[VendorFieldList]; lines: openArray[HeaderRef];
    filter: string): VendorFieldMenu =
  ## The submenu for the file whose fields are `list` (none while being read) and the
  ## display header's `lines`; only the names that hold `filter` (any case) are listed.
  ## Numeric fields come first, in the maps' order, then the fields a line cannot
  ## show, then the lines chosen that the file lacks.
  if list.isNone: return VendorFieldMenu(kind: vmReading)
  let chosen = lines.chosenNames
  let atCap = lines.len >= MaxHeaderLines
  let fields = list.get.entries
  var disabled: seq[VendorFieldItem] = @[]
  var seen: seq[string] = @[]
  result = VendorFieldMenu(kind: vmItems, filtered: fields.len > FilterAbove)
  for e in fields:
    seen.add e.name
    if e.name.matches(filter):
      let ticked = e.name in chosen
      let place = case e.level
        of vlRecord: " (record)"
        of vlTrace: ""
      if e.isNumeric:
        let tip = "Show the vendor field " & e.name & " as a display line" & place &
          (if e.level == vlRecord: ": one value per record, shown on each of its traces" else: "")
        result.items.add VendorFieldItem(name: e.name, label: e.name, ticked: ticked,
          enabled: ticked or not atCap, tip: if ticked or not atCap: tip else: CapTip)
      else:
        disabled.add VendorFieldItem(name: e.name, label: e.name, ticked: ticked,
          enabled: ticked, tip: (if e.repeated: RepeatTip else: TextTip) & place)
  result.items.add disabled
  for name in chosen:
    if name notin seen and name.matches(filter):
      result.items.add VendorFieldItem(name: name, label: name & "  (not in this file)",
        tip: MissingTip, ticked: true, enabled: true)
  if result.items.len == 0:
    result.kind = if filter.len > 0 or fields.len > 0: vmNoMatch else: vmNone

func withVendorLine*(lines: openArray[HeaderRef]; name: string; on: bool): seq[HeaderRef] =
  ## `lines` with the vendor line `name` added at the end (`on`), or left out.
  for l in lines:
    if not (l.field == hfVendor and l.name == name): result.add l
  if on: result.add vendorRef(name)
