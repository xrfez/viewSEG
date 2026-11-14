## The keys of a list window (Files, Records): the arrow keys, Page Up and
## Page Down, Home and End step through the list, and Tab and Shift + Tab
## move between the window's controls, as in every window (the user: "tab
## should move between options in the window not files").
##
## Tab is Dear ImGui's keyboard navigation, which the window keeps (it is
## drawn without `NoNavInputs`); the stepping keys are taken from that
## navigation while the window has the focus (`stepOf` makes the window
## their owner, so the navigation does not also move its cursor or scroll
## with them). A list is one stop of Tab: its rows but the one shown are
## no tab stops (`pushRowTabStop`), and `ListFocus` takes the navigation's
## cursor along to the row shown when a key steps the list.
##
## A list that scrolls is a child window of its own, and Dear ImGui's Tab
## moves only within one window (a child "flattened" into its parent is
## the exception, but a table's child cannot be asked to be one), so
## `ListFocus` carries Tab across the list's edges: Tab on the control
## before the list (`afterLast`) or Shift + Tab on the window's first
## control (`afterFirst`) goes to the row shown; Tab or Shift + Tab on that
## row goes to the first control or the one before the list
## (`beforeFirst`, `beforeLast`, a frame later).

import imguin/cimgui

type
  ListStep* = enum
    ## What a key asks of a list.
    lsNone, lsNext, lsPrevious, lsPageDown, lsPageUp, lsFirst, lsLast

  ListFocus* = object
    ## Where Dear ImGui's navigation cursor is, as far as the list needs:
    ## on a row (a key that steps the list then takes it to the row shown
    ## next), and Tab across the list's edges.
    onRow: bool ## a row had it, this frame
    wasOnRow: bool ## a row had it, last frame
    refocus: bool ## take it to the row shown when that is drawn
    toFirst: bool ## take it to the window's first control, next frame
    toLast: bool ## take it to the control before the list, next frame

const StepKeys = [ImGui_Key_DownArrow, ImGui_Key_UpArrow, ImGui_Key_PageDown,
  ImGui_Key_PageUp, ImGui_Key_Home, ImGui_Key_End]

proc stepOf*(owner: string): ListStep =
  ## The list key pressed now (with no modifier), while the window being
  ## drawn has the focus and no text box has the keyboard: the keys are then
  ## the window's (named `owner`), not the navigation's, this frame and the
  ## next. `lsNone` otherwise; in a text box, Up, Down and the page keys
  ## stay the window's and do nothing.
  let io = igGetIO_Nil()
  if not igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint): return lsNone
  let id = igGetID_Str(owner.cstring)
  if io.WantTextInput:
    # A text box (the filter) keeps Home and End; Up, Down and the pages do
    # nothing there, rather than move the navigation out of it.
    for k in StepKeys[0 .. 3]: igSetKeyOwner(k, id, 0)
    return lsNone
  for k in StepKeys: igSetKeyOwner(k, id, 0)
  if io.KeyMods != 0: return lsNone
  let repeat = ImGui_InputFlags_Repeat.cint
  result = lsNone
  for (k, step, flags) in [(ImGui_Key_DownArrow, lsNext, repeat),
      (ImGui_Key_UpArrow, lsPrevious, repeat), (ImGui_Key_PageDown, lsPageDown, repeat),
      (ImGui_Key_PageUp, lsPageUp, repeat), (ImGui_Key_Home, lsFirst, 0.cint),
      (ImGui_Key_End, lsLast, 0.cint)]:
    if result == lsNone and igIsKeyPressed_InputFlags(k, flags, id): result = step

proc tabPressed(): (bool, bool) =
  ## Whether Tab was pressed this frame (not with Ctrl or Alt), and Shift
  ## held.
  let io = igGetIO_Nil()
  (igIsKeyPressed_InputFlags(ImGui_Key_Tab, ImGui_InputFlags_Repeat.cint, 0) and
    not io.KeyCtrl and not io.KeyAlt, io.KeyShift)

proc beforeFirst*(lf: var ListFocus) =
  ## Before the window's first control: Tab on the list's row comes here.
  if lf.toFirst:
    igSetKeyboardFocusHere(0)
    lf.toFirst = false

proc afterFirst*(lf: var ListFocus) =
  ## After the window's first control: Shift + Tab on it goes to the list.
  let (tab, shift) = tabPressed()
  if tab and shift and igIsItemFocused(): lf.refocus = true

proc beforeLast*(lf: var ListFocus) =
  ## Before the control just before the list: Shift + Tab on the list's
  ## row comes here.
  if lf.toLast:
    igSetKeyboardFocusHere(0)
    lf.toLast = false

proc afterLast*(lf: var ListFocus) =
  ## After the control just before the list: Tab on it goes to the list.
  let (tab, shift) = tabPressed()
  if tab and not shift and igIsItemFocused(): lf.refocus = true

proc pushRowTabStop*(shown: bool) =
  ## Before a row's item: only the row shown is a stop of Tab, so Tab moves
  ## past the list in one step. Pop with `popRowTabStop`.
  igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, not shown)

proc popRowTabStop*() = igPopItemFlag()

proc beforeRows*(lf: var ListFocus; bridged = true) =
  ## Before the list's rows are drawn; with `bridged`, Tab on the list's
  ## row goes to the window's other controls.
  lf.wasOnRow = lf.onRow
  lf.onRow = false
  let (tab, shift) = tabPressed()
  if bridged and tab and lf.wasOnRow:
    if shift: lf.toLast = true else: lf.toFirst = true

proc beforeShownRow*(lf: var ListFocus) =
  ## Before the item of the row shown: brings the navigation's cursor to it
  ## after a key stepped the list from a row that had it.
  if lf.refocus:
    igSetKeyboardFocusHere(0)
    lf.refocus = false

proc afterRow*(lf: var ListFocus) =
  ## After a row's item: notes whether the navigation's cursor is on it.
  if igIsItemFocused(): lf.onRow = true

proc stepped*(lf: var ListFocus; step: ListStep) =
  ## After the rows, with the key `stepOf` gave: a step taken from a row
  ## that had the navigation's cursor takes the cursor along (a click
  ## moves it itself).
  if step != lsNone and lf.onRow: lf.refocus = true
