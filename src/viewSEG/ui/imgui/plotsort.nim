## The plot window's trace order: one drop-down in its strip. Its label is
## "Sort: " and what is in use (a preset's name, "file order", or "custom").
## The list is the file's order, each preset of the settings
## (`Settings.sortPresets`, by default `SortPresets`: Line/Station, By Flag,
## By Component), and **Custom...**, which opens the popover of the user's
## own keys, starting from the keys used last (`Settings.customOrder`).
##
## A preset the traces have none of the keys of is greyed, unless it is the
## order in use. Picking the preset already in use does nothing; the file's
## order is the "File order" row. A change is a `ckSort`: the panel's reader
## sorts, off the UI thread, and the plot keeps drawing the old order until
## the new one comes.

import std/[math, options, strutils]
import imguin/cimgui
import ../../core/[state, vendorfieldlist]
import ../../view/[strip, theme, vendorfieldmenu]
import chrome, icons, style

const
  sortKeysId* = "##sortkeys" ## the popover of the user's own keys
  MaxSortKeys = 24           ## keys the popover holds

type SortKeysUi* = object
  ## The keys being put together in the popover, until "Sort" sends them.
  draft*: seq[SortKey]

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc send(p: Panel; order: seq[SortKey]; cmds: var seq[Command]) =
  cmds.add Command(kind: ckSort, panel: p.id, order: order)

proc toggle*(label: string; selected: bool; t: Theme): bool =
  ## A text button drawn on the selection colour, its text in the accent
  ## colour, when `selected` (as the display mode buttons are).
  if selected:
    igPushStyleColor_Vec4(ImGui_Col_Button.cint, vec4(t.roles[rlSelection]))
    igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlAccent]))
  result = igButton(label.cstring, ImVec2_c(x: 0, y: 0))
  if selected: igPopStyleColor(2)

proc drawSortCombo*(p: Panel; s: Settings; marks: var Marks; cmds: var seq[Command]): bool =
  ## The strip's sort drop-down. True when Custom... was clicked: the caller
  ## opens the popover (`openSortKeys`), in the window's ID scope.
  let presets = s.sortPresets
  let order = p.layers[0].order
  let label = sortLabel(order, presets)
  let style = igGetStyle()
  igSetNextItemWidth(round(igCalcTextSize(label.cstring, nil, false, -1).x +
    igGetFrameHeight() + 3 * style.FramePadding.x))
  if igBeginCombo("##sort", label.cstring, 0):
    for row in sortRows(order, presets, p.known):
      case row.kind
      of srSeparator:
        igSeparator()
      of srFileOrder, srPreset, srCustom:
        let id = row.label & "##sortrow"
        if row.greyed: igBeginDisabled(true)
        let clicked = igSelectable_Bool(id.cstring, row.inUse, 0, ImVec2_c(x: 0, y: 0))
        if row.greyed: igEndDisabled()
        if row.kind == srPreset: marks.mark("plot.sort." & row.label)
        elif row.kind == srCustom: marks.mark("plot.sort.custom")
        else: marks.mark("plot.sort.file order")
        if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
            ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
          igTextUnformatted(row.tip.cstring, nil)
          igEndTooltip()
        if clicked:
          let pick = sortPick(row, presets)
          if pick.acts: p.send(pick.order, cmds)
          if pick.opensCustom: result = true
    igEndCombo()
  marks.mark("plot.sort")
  tip(sortTip(order))

proc openSortKeys*(ks: var SortKeysUi; p: Panel; s: Settings) =
  ## Opens the popover at the mouse with the order in use when it is the
  ## user's own, else the keys the user sorted by last, else the order in
  ## use, else Line/Station's keys.
  let order = p.layers[0].order
  let own = order.len > 0 and presetOf(order, s.sortPresets) < 0
  ks.draft = if own: order
             elif s.customOrder.len > 0: s.customOrder
             elif order.len > 0: order
             else: SortPresets[0].keys
  igOpenPopup_Str(sortKeysId, 0)

proc fieldName(f: HeaderField; known: set[HeaderField]): string =
  $f & (if f in known: "" else: "  (not in this file)")

var vendorFilter: array[64, char] # the filter box of the vendor fields submenu

proc vendorList(st: AppState; p: Panel): Option[VendorFieldList] =
  ## The shown file's vendor fields (none while they are being listed).
  let at = st.findPanel(p.id)
  let file = if at >= 0: st.shownFile(at) else: -1
  if file < 0: some(VendorFieldList()) else: st.vendorFields(st.sessions[file].id)

func keyLabel(k: SortKey; known: set[HeaderField]; list: Option[VendorFieldList]): string =
  ## The key's field as its drop-down shows it; a vendor field the file lacks says so
  ## (while the file's list is being made, it says nothing).
  if k.field != hfVendor: return fieldName(k.field, known)
  result = k.name
  if list.isSome:
    var has = false
    for e in list.get.entries:
      if e.name == k.name: has = true
    if not has: result.add "  (not in this file)"

proc pickVendor(st: AppState; p: Panel; keys: openArray[SortKey]; marks: var Marks;
    prefix: string; inCombo = false): string =
  ## The "Vendor fields" submenu: the shown file's numeric vendor fields, the keys' own ticked;
  ## the name of the one clicked ("" for none).
  let list = vendorList(st, p)
  var lines: seq[HeaderRef] = @[]
  for k in keys:
    if k.field == hfVendor: lines.add vendorRef(k.name)
  let open = igBeginMenu("Vendor fields", true)
  marks.mark(prefix & "vendor")
  tip("Fields of the vendor header maps that the shown file has: the traces can be sorted " &
    "by a number one; traces without a value come last")
  if open:
    # a click would close the popover with the menu (a menu window has its own item flags)
    igPushItemFlag(ImGui_ItemFlags_AutoClosePopups.cint, inCombo)
    let first = vendorFieldMenu(list, lines, "")
    if first.filtered:
      igSetNextItemWidth(igGetFontSize() * 16)
      discard igInputTextWithHint("##sortvendorfilter", "Filter fields", cast[cstring](
          addr vendorFilter[0]),
        csize_t(vendorFilter.len), 0, nil, nil)
      marks.mark(prefix & "vendor filter")
    let menu = vendorFieldMenu(list, lines,
      if first.filtered: ($cast[cstring](addr vendorFilter[0])).strip else: "")
    case menu.kind
    of vmReading, vmNone, vmNoMatch:
      let words = case menu.kind
        of vmReading: ReadingWords
        of vmNone: NoFieldsWords
        else: NoMatchWords
      igBeginDisabled(true)
      discard igMenuItem_Bool(words.cstring, nil, false, false)
      igEndDisabled()
    of vmItems:
      for item in menu.items:
        igBeginDisabled(not item.enabled)
        let clicked = igMenuItem_Bool(item.label.cstring, nil, item.ticked, item.enabled)
        igEndDisabled()
        marks.mark(prefix & "vendor " & item.name)
        if clicked and not item.ticked: result = item.name
    igPopItemFlag()
    igEndMenu()

proc drawSortKeys*(ks: var SortKeysUi; p: Panel; st: AppState; marks: var Marks; cmds: var seq[Command]) =
  ## The popover of the user's own keys, if it is open: each key a header
  ## field, ascending or descending, the first first; "Sort" sends them.
  if not igBeginPopup(sortKeysId, 0): return
  marks.markWindow("plot.sort keys")
  igSeparatorText("Sort the traces by")
  let style = igGetStyle()
  let width = igCalcTextSize("source point  (not in this file)", nil, false, -1).x +
    igGetFrameHeight() + 2 * style.FramePadding.x
  let list = vendorList(st, p)
  var removed = -1
  var moved = (-1, -1)
  for i in 0 ..< ks.draft.len:
    igPushID_Int(cint(i))
    let key = ks.draft[i]
    igSetNextItemWidth(width)
    if igBeginCombo("##field", keyLabel(key, p.known, list).cstring, 0):
      for f in HeaderField:
        if f == hfVendor: continue # the vendor fields are the submenu below
        if igSelectable_Bool(fieldName(f, p.known).cstring, f == key.field, 0,
            ImVec2_c(x: 0, y: 0)):
          ks.draft[i].field = f
          ks.draft[i].name = ""
      let picked = pickVendor(st, p, ks.draft, marks, "plot.sort keys.field " & $i & ".",
        inCombo = true)
      if picked.len > 0:
        ks.draft[i].field = hfVendor
        ks.draft[i].name = picked
      igEndCombo()
    marks.mark("plot.sort keys.field " & $i)
    igSameLine(0, -1)
    let dirText = (if key.descending: "Descending" else: "Ascending") & "##dir"
    if igButton(dirText.cstring, ImVec2_c(x: 0, y: 0)):
      ks.draft[i].descending = not key.descending
    marks.mark("plot.sort keys.direction " & $i)
    tip("Smallest first, or largest first; unknown values come last either way")
    igSameLine(0, -1)
    igBeginDisabled(i == 0)
    if igArrowButton("##up", ImGui_Dir_Up): moved = (i, i - 1)
    igEndDisabled()
    igSameLine(0, 2)
    igBeginDisabled(i == ks.draft.high)
    if igArrowButton("##down", ImGui_Dir_Down): moved = (i, i + 1)
    igEndDisabled()
    igSameLine(0, 2)
    if igSmallButton((IconRemove & "##remove").cstring): removed = i
    tip("Remove this key")
    igPopID()
  if moved[0] >= 0: swap(ks.draft[moved[0]], ks.draft[moved[1]])
  if removed >= 0: ks.draft.delete(removed)
  if ks.draft.len == 0:
    igTextUnformatted("No keys: the file's order.", nil)
  if igBeginMenu("Add a key", ks.draft.len < MaxSortKeys):
    # a click would close the popover with the menu: the keys put together would be lost
    igPushItemFlag(ImGui_ItemFlags_AutoClosePopups.cint, false)
    for f in HeaderField:
      if f == hfVendor: continue
      var used = false
      for k in ks.draft:
        if k.field == f: used = true
      if not used and igMenuItem_Bool(fieldName(f, p.known).cstring, nil, false, true):
        ks.draft.add SortKey(field: f)
    let picked = pickVendor(st, p, ks.draft, marks, "plot.sort keys.add.")
    if picked.len > 0: ks.draft.add vendorKey(picked)
    igPopItemFlag()
    igEndMenu()
  marks.mark("plot.sort keys.add")
  igSeparator()
  if igButton("Sort", ImVec2_c(x: 0, y: 0)):
    p.send(ks.draft, cmds)
    igCloseCurrentPopup()
  marks.mark("plot.sort keys.sort")
  tip("Sort the traces by these keys, the first first; traces equal in every key keep " &
    "the file's order")
  igSameLine(0, -1)
  if igButton("File order", ImVec2_c(x: 0, y: 0)):
    p.send(@[], cmds)
    igCloseCurrentPopup()
  tip("The traces as they are in the file")
  igSameLine(0, -1)
  if igButton("Cancel", ImVec2_c(x: 0, y: 0)):
    igCloseCurrentPopup()
  igEndPopup()
