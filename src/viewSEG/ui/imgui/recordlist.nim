## The "Records" window: the records (gathers) of the file the plot window
## shows (`core/records`), one row each: its place in the file, its field
## record number (FFID), its CDP, its source and receiver stations where
## they tell it apart, and how many traces it holds. The record on show is
## marked; clicking a row shows that record (not the click that only brings
## the window forward: `focus`). While the window has the
## focus, Up / Down step to the next or previous record, Page Up / Page Down
## by a page, Home / End to the first and last. Only the rows in view are
## drawn (ImGui's list clipper), so a file of 100 000 records scrolls as
## lightly as one of ten.

import imguin/cimgui
import ../../core/[geometry, state]
import ../../view/theme
import chrome, focus, style

type
  RecordListUi* = object
    ## The window's own state between frames.
    shown: (SessionId, int) ## the record on show last frame: a new one is scrolled into view
    follow: bool
    focus: FocusClicks      ## a click on a row acts only in a window that had the focus

  RecordListOutput* = object
    commands*: seq[Command]

func num(x: float64): string =
  if x != x: "" # NaN: not known
  elif x == float64(int64(x)) and abs(x) < 1e15: $int64(x)
  else: $x

proc cell(text: string; right = true) =
  ## A table cell's text, right-aligned for numbers.
  if right:
    let w = igCalcTextSize(text.cstring, nil, false, -1).x
    igSetCursorPosX(igGetCursorPosX() + max(0, igGetContentRegionAvail().x - w))
  igTextUnformatted(text.cstring, nil)

proc drawRecordList*(ui: var RecordListUi; title: string; st: AppState; panel: PanelId;
    t: Theme; marks: var Marks): RecordListOutput =
  ## The window, docked or floating like any other, titled `title`, for the
  ## file `panel` shows.
  if igBegin(title.cstring, nil, ImGui_WindowFlags_NoNavInputs.cint):
    ui.focus.watch()
    marks.markWindow("records")
    let k = st.findPanel(panel)
    let s = if k >= 0: st.shownFile(k) else: -1
    if s < 0:
      igTextDisabled("No file is shown.")
    else:
      template session: untyped = st.sessions[s]
      template rows: untyped = st.sessions[s].records
      let current = st.panels[k].layers[0].source.gather
      if (session.id, current) != ui.shown:
        ui.shown = (session.id, current)
        ui.follow = true
      let columns = session.recordColumns
      var n = 2
      for c in RecordColumn:
        if c in columns: inc n
      const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
        ImGui_TableFlags_Resizable.cint or ImGui_TableFlags_BordersInnerV.cint or
        ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_Hideable.cint
      let footer = igGetTextLineHeightWithSpacing() + igGetStyle().ItemSpacing.y
      if rows.len > 0 and igBeginTable("##records", cint(n), flags,
          ImVec2_c(x: 0, y: -footer), 0):
        igTableSetupScrollFreeze(0, 1)
        # Widths for the widest values, from the first and last rows (the
        # columns would otherwise fit the rows first seen, and cut longer
        # numbers further down).
        proc width(texts: openArray[string]): float32 =
          for x in texts: result = max(result, igCalcTextSize(x.cstring, nil, false, -1).x)
          result += igGetFontSize() * 0.5
        let (a, b) = (rows[0], rows[^1])
        igTableSetupColumn("#", ImGui_TableColumnFlags_NoHide.cint or
          ImGui_TableColumnFlags_WidthFixed.cint, width(["#", $rows.len]), 0)
        for c in RecordColumn:
          if c in columns:
            let w = case c
              of rcRecord: width([$c, num(a.record), num(b.record)])
              of rcEnsemble: width([$c, num(a.ensemble), num(b.ensemble)])
              of rcSource: width([$c, station(a.srcLine, a.srcPoint),
                station(b.srcLine, b.srcPoint)])
              of rcReceiver: width([$c, station(a.rcvLine, a.rcvPoint),
                station(b.rcvLine, b.rcvPoint)])
            igTableSetupColumn(cstring($c), ImGui_TableColumnFlags_WidthFixed.cint, w, 0)
        igTableSetupColumn("Traces", ImGui_TableColumnFlags_WidthStretch.cint, 1, 0)
        igTableHeadersRow()
        let clipper = ImGuiListClipper_ImGuiListClipper()
        ImGuiListClipper_Begin(clipper, cint(rows.len), -1)
        if ui.follow and current in 0 ..< rows.len:
          ImGuiListClipper_IncludeItemByIndex(clipper, cint(current))
        while ImGuiListClipper_Step(clipper):
          for i in clipper.DisplayStart ..< clipper.DisplayEnd:
            let r = rows[i]
            igTableNextRow(0, 0)
            discard igTableNextColumn()
            igPushID_Int(cint(i))
            if igSelectable_Bool(cstring($(i + 1)), i == current,
                ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and
                i != current and ui.focus.acts:
              result.commands.add Command(kind: ckGather, panel: panel, gather: i)
            igPopID()
            if i == current:
              marks.mark("records.current")
              if ui.follow:
                if not igIsItemVisible(): igSetScrollHereY(0.5)
                ui.follow = false
            if i < 3: marks.mark("records.row " & $i)
            if rcRecord in columns:
              discard igTableNextColumn()
              cell(num(r.record))
            if rcEnsemble in columns:
              discard igTableNextColumn()
              cell(num(r.ensemble))
            if rcSource in columns:
              discard igTableNextColumn()
              cell(station(r.srcLine, r.srcPoint))
            if rcReceiver in columns:
              discard igTableNextColumn()
              cell(station(r.rcvLine, r.rcvPoint))
            discard igTableNextColumn()
            cell($r.traces & "  " & $r.kind, right = false)
        ImGuiListClipper_End(clipper)
        ImGuiListClipper_destroy(clipper)
        igEndTable()
        marks.mark("records.table")
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      let text = session.name & ": record " & $(current + 1) & " of " & $rows.len
      igTextUnformatted(text.cstring, nil)
      igPopStyleColor(1)
      marks.mark("records.footer")
      if igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
          not igGetIO_Nil().WantTextInput and rows.len > 0:
        template held(chord: cint): bool = igShortcut_Nil(chord, ImGui_InputFlags_Repeat.cint)
        let page = max(1, int(igGetWindowHeight() / igGetTextLineHeightWithSpacing()) - 3)
        var to = current
        if held(ImGui_Key_DownArrow.cint): to = current + 1
        if held(ImGui_Key_UpArrow.cint): to = current - 1
        if held(ImGui_Key_PageDown.cint): to = current + page
        if held(ImGui_Key_PageUp.cint): to = current - page
        if igShortcut_Nil(ImGui_Key_Home.cint, 0): to = 0
        if igShortcut_Nil(ImGui_Key_End.cint, 0): to = rows.high
        to = clamp(to, 0, rows.high)
        if to != current:
          result.commands.add Command(kind: ckGather, panel: panel, gather: to)
  ui.focus.settle()
  igEnd()
