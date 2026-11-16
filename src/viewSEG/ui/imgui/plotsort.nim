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

import std/math
import imguin/cimgui
import ../../core/state
import ../../view/[strip, theme]
import chrome, icons, style

const sortKeysId* = "##sortkeys" ## the popover of the user's own keys

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

proc drawSortKeys*(ks: var SortKeysUi; p: Panel; marks: var Marks; cmds: var seq[Command]) =
  ## The popover of the user's own keys, if it is open: each key a header
  ## field, ascending or descending, the first first; "Sort" sends them.
  if not igBeginPopup(sortKeysId, 0): return
  marks.markWindow("plot.sort keys")
  igSeparatorText("Sort the traces by")
  let style = igGetStyle()
  let width = igCalcTextSize("source point  (not in this file)", nil, false, -1).x +
    igGetFrameHeight() + 2 * style.FramePadding.x
  var removed = -1
  var moved = (-1, -1)
  for i in 0 ..< ks.draft.len:
    igPushID_Int(cint(i))
    let key = ks.draft[i]
    igSetNextItemWidth(width)
    if igBeginCombo("##field", fieldName(key.field, p.known).cstring, 0):
      for f in HeaderField:
        if igSelectable_Bool(fieldName(f, p.known).cstring, f == key.field, 0,
            ImVec2_c(x: 0, y: 0)):
          ks.draft[i].field = f
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
  if igBeginMenu("Add a key", ks.draft.len < HeaderField.high.ord + 1):
    for f in HeaderField:
      var used = false
      for k in ks.draft:
        if k.field == f: used = true
      if not used and igMenuItem_Bool(fieldName(f, p.known).cstring, nil, false, true):
        ks.draft.add SortKey(field: f)
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
