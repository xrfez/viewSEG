## The "Headers" window: what the file shown is and what its headers hold,
## in three tabs (`HeadersTab`), read-only.
##
## - **Summary:** what the file is (its standard, sample format, counts,
##   timing, coordinates) and the record shown with its counts, in plain
##   words (`view/headerviews.summaryLines`).
##
## The tab shown is remembered in the settings (`Settings.headers`). A value
## is copied with Ctrl + C on its row, or from the row's right-click menu,
## which also copies the whole summary. A click that only brings the window
## forward does nothing else (`focus`); Tab moves between its controls.

import imguin/cimgui
import ../../core/state
import ../../view/[headerviews, theme]
import chrome, focus, fonts, style

type
  HeadersUi* = object
    ## The window's own state between frames.
    focus: FocusClicks
    shownTab: HeadersTab ## the tab the window last showed
    selecting: bool      ## the settings' tab is to be selected (first frame, or it changed)
    started: bool
    picked: int = -1     ## the summary row picked (Ctrl + C copies it); -1 for none
    pickedFile: string   ## the file it was picked in

  HeadersOutput* = object
    commands*: seq[Command]

proc tabItem(ui: var HeadersUi; tab: HeadersTab; wanted: HeadersTab): bool =
  ## A tab of the window's tab bar; selected once when it is the settings'.
  let flags = if ui.selecting and tab == wanted: ImGui_TabItemFlags_SetSelected.cint else: 0.cint
  result = igBeginTabItem(($tab & "##" & $ord(tab)).cstring, nil, flags)

proc copyMenu(id: string; value: string; all: proc (): string) =
  ## The right-click menu of a row: copy its value, or everything.
  if igBeginPopupContextItem(id.cstring, ImGui_PopupFlags_MouseButtonRight.cint):
    if igMenuItem_Bool("Copy", "Ctrl+C", false, true): igSetClipboardText(value.cstring)
    if igMenuItem_Bool("Copy the summary", nil, false, true): igSetClipboardText(all().cstring)
    igEndPopup()

proc drawSummary(ui: var HeadersUi; st: AppState; fonts: Fonts; t: Theme; marks: var Marks) =
  ## The Summary tab: a line per fact, headings between.
  let k = st.findPanel(MainPanel)
  let s = if k >= 0: st.shownFile(k) else: -1
  if s < 0:
    igTextDisabled("No file is shown.")
    return
  template session: untyped = st.sessions[s]
  let gather = st.panels[k].layers[0].source.gather
  let lines = summaryLines(session, gather)
  if session.path != ui.pickedFile:
    ui.picked = -1
    ui.pickedFile = session.path
  var labelWidth = 0'f32
  for l in lines:
    if not l.heading:
      labelWidth = max(labelWidth, igCalcTextSize(l.label.cstring, nil, false, -1).x)
  const flags = ImGui_TableFlags_ScrollY.cint or ImGui_TableFlags_RowBg.cint or
    ImGui_TableFlags_BordersInnerV.cint
  if igBeginTable("##summary", 2, flags, ImVec2_c(x: 0, y: 0), 0):
    igTableSetupColumn("What", ImGui_TableColumnFlags_WidthFixed.cint,
      labelWidth + igGetFontSize(), 0)
    igTableSetupColumn("Value", ImGui_TableColumnFlags_WidthStretch.cint, 0, 1)
    let all = proc (): string = summaryText(lines)
    for i, l in lines:
      igTableNextRow(0, 0)
      discard igTableNextColumn()
      igPushID_Int(cint(i))
      if l.heading:
        fonts.withFont(frHeading, 0):
          igTextUnformatted(l.label.cstring, nil)
        if i == 0: marks.mark("headers.summary.heading")
      else:
        igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
        if igSelectable_Bool(l.label.cstring, ui.picked == i,
            ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
          ui.picked = i
        igPopStyleColor(1)
        copyMenu("##copy", l.value, all)
        if igIsItemFocused() and igIsKeyPressed_Bool(ImGui_Key_C, false) and
            igGetIO_Nil().KeyCtrl:
          igSetClipboardText(l.value.cstring)
        marks.mark("headers.summary " & l.label)
        discard igTableNextColumn()
        igPushTextWrapPos(0)
        igTextUnformatted(l.value.cstring, nil)
        igPopTextWrapPos()
        marks.mark("headers.summary value " & l.label)
      igPopID()
    igEndTable()
    marks.mark("headers.summary")
  if ui.picked >= 0 and ui.picked < lines.len and igGetIO_Nil().KeyCtrl and
      igIsKeyPressed_Bool(ImGui_Key_C, false) and
      igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint):
    igSetClipboardText(lines[ui.picked].value.cstring)

proc drawHeaders*(ui: var HeadersUi; title: string; st: AppState; fonts: Fonts; t: Theme;
    marks: var Marks): HeadersOutput =
  ## The window, docked or floating like any other, titled `title` (its
  ## ImGui ID stays `###headers`), for the file the main panel shows.
  let view = st.settings.headers
  if not ui.started or view.tab != ui.shownTab:
    ui.selecting = true
    ui.started = true
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("headers")
    if igBeginTabBar("##headerstabs", 0):
      var shown = ui.shownTab
      if ui.tabItem(htSummary, view.tab):
        shown = htSummary
        marks.mark("headers.tab summary")
        ui.drawSummary(st, fonts, t, marks)
        igEndTabItem()
      else: marks.mark("headers.tab summary")
      if ui.tabItem(htFile, view.tab):
        shown = htFile
        marks.mark("headers.tab file")
        igTextDisabled("The file's header blocks.")
        igEndTabItem()
      else: marks.mark("headers.tab file")
      if ui.tabItem(htTrace, view.tab):
        shown = htTrace
        marks.mark("headers.tab trace")
        igTextDisabled("The headers and samples of the selected traces.")
        igEndTabItem()
      else: marks.mark("headers.tab trace")
      igEndTabBar()
      if ui.selecting:
        ui.selecting = false
        ui.shownTab = view.tab
      elif shown != ui.shownTab:
        ui.shownTab = shown
        var s = st.settings
        s.headers.tab = shown
        result.commands.add Command(kind: ckSettings, settings: s)
    ui.focus.settle()
  igEnd()
