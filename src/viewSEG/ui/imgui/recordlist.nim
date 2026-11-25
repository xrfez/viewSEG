## The "Records" window: the records (gathers) of the file the plot window
## shows (`core/records`), one row each: its place in the file, its field
## record number (FFID), its CDP, its source and receiver stations where
## they tell it apart; its seismic traces, its auxiliary traces, the traces
## the file marks dead, and the traces missing from its patch (against the
## file's own count, or the loaded relation file's X record: the cell's
## tooltip says which; empty where nothing says what was expected), drawn
## in the warning colour where traces are missing. A click on a column's
## header sorts by it (again: the other way); the file's order is "#".
##
## The record on show is marked; clicking a row shows that record (not the
## click that only brings the window forward: `focus`). While the window has
## the focus, Up / Down step to the next or previous record in the order
## shown, Page Up / Page Down by a page, Home / End to the first and last;
## Tab and Shift + Tab move between the window's controls, as in every
## window (`listkeys`). Only the rows in view are drawn (ImGui's list
## clipper), so a file of 100 000 records scrolls as lightly as one of ten;
## a new order is worked out only when the sort or the records change.

import std/algorithm
import imguin/cimgui
import ../../core/state
import ../../view/theme
import chrome, focus, listkeys, style
from windows import awRecords, beginClosable

type
  RecordSort = enum
    ## The columns the list sorts by, as `igTableSetupColumn` numbers them.
    rsPlace, rsRecord, rsEnsemble, rsSource, rsReceiver, rsSeismic, rsAux, rsDead, rsMissing

  RecordListUi* = object
    ## The window's own state between frames.
    shown: (SessionId, int)           ## the record on show last frame: a new one is scrolled into view
    follow: bool
    focus: FocusClicks                ## a click on a row acts only in a window that had the focus
    keys: ListFocus                   ## the navigation's cursor follows the record shown
    sortBy: RecordSort
    descending: bool
    sorted: (SessionId, int, string, RecordSort, bool)
      ## what `order` was made for: the file, its records, the relation file
      ## they were checked against, the sort
    counted: (SessionId, int, string) ## what `aux` and `short` were counted for
    order: seq[int] ## the records in the order shown; empty: the file's
    place: seq[int] ## each record's row in that order
    aux: bool ## some record has auxiliary traces
    short: int ## records with traces missing

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

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

func missingText(r: RecordRow; against: string): string =
  ## What a record's missing cell says when pointed at.
  case r.missingSource
  of msSurvey:
    var text = $r.plannedMissing & " of the " & $r.planned & " stations its X record in " &
      against & " plans have no trace in it."
    if r.unlisted > 0:
      text.add " " & $r.unlisted & (if r.unlisted == 1: " trace is" else: " traces are") &
        " at stations it does not plan."
    if r.duplicates > 0:
      text.add " " & $r.duplicates & (if r.duplicates == 1: " station is" else: " stations are") &
        " recorded more than once."
    text
  of msFile: $r.missing & " of the " & $r.declared & " seismic traces the file declares " &
    "for it are not in it (it holds " & $r.seismic & ")."
  of msNone: "Nothing says how many traces it should hold: load the survey's relation " &
    "file (SPS X), or import the survey (Project > Import survey), to check it against the " &
    "plan."

func key(r: RecordRow; by: RecordSort; i: int): float64 =
  ## What row `i` (`r`) sorts by; the unknown (NaN) come last.
  case by
  of rsPlace: float64(i)
  of rsRecord: r.record
  of rsEnsemble: r.ensemble
  of rsSource: (if r.srcPoint != r.srcPoint: NaN else: r.srcLine * 1e7 + r.srcPoint)
  of rsReceiver: (if r.rcvPoint != r.rcvPoint: NaN else: r.rcvLine * 1e7 + r.rcvPoint)
  of rsSeismic: float64(r.seismic)
  of rsAux: float64(r.aux)
  of rsDead: float64(r.dead)
  of rsMissing: (if r.missing < 0: NaN else: float64(r.missing))

proc resort(ui: var RecordListUi; rows: openArray[RecordRow]) =
  ## The records in the order the headers ask for; ties in the file's order.
  if ui.sortBy == rsPlace and not ui.descending:
    ui.order.setLen 0
    ui.place.setLen 0
    return
  var keys = newSeq[float64](rows.len)
  for i, r in rows: keys[i] = r.key(ui.sortBy, i)
  ui.order = newSeq[int](rows.len)
  for i in 0 ..< rows.len: ui.order[i] = i
  let down = ui.descending
  ui.order.sort(proc (a, b: int): int =
    let (x, y) = (keys[a], keys[b])
    if x != x or y != y: # NaN last, either way
      result = cmp(x != x, y != y)
    else:
      result = if down: cmp(y, x) else: cmp(x, y)
    if result == 0: result = cmp(a, b))
  ui.place = newSeq[int](rows.len)
  for k, i in ui.order: ui.place[i] = k

func rowAt(ui: RecordListUi; k: int): int {.inline.} =
  ## The record shown at row `k`.
  if ui.order.len > 0: ui.order[k] else: k

func placeOf(ui: RecordListUi; i: int): int {.inline.} =
  ## The row record `i` is shown at.
  if ui.place.len > 0: ui.place[i] else: i

proc drawRecordList*(ui: var RecordListUi; title: string; st: AppState; panel: PanelId;
    t: Theme; marks: var Marks): RecordListOutput =
  ## The window, docked or floating like any other, titled `title`, for the
  ## file `panel` shows.
  if beginClosable(awRecords, title.cstring):
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
      let records = (session.id, rows.len, session.checkedAgainst)
      if records != ui.counted: # before the columns are set up: Aux shows when some has any
        ui.counted = records
        (ui.aux, ui.short) = (false, 0)
        for r in rows:
          if r.aux > 0: ui.aux = true
          if r.missing > 0: inc ui.short
      const flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
        ImGui_TableFlags_Resizable.cint or ImGui_TableFlags_BordersInnerV.cint or
        ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_Hideable.cint or
        ImGui_TableFlags_Sortable.cint
      let footer = igGetTextLineHeightWithSpacing() + igGetStyle().ItemSpacing.y
      if rows.len > 0 and igBeginTable("##records", cint(RecordSort.high) + 1, flags,
          ImVec2_c(x: 0, y: -footer), 0):
        igTableSetupScrollFreeze(0, 1)
        # Widths for the widest values, from the first and last rows (the
        # columns would otherwise fit the rows first seen, and cut longer
        # numbers further down).
        proc width(texts: openArray[string]): float32 =
          for x in texts: result = max(result, igCalcTextSize(x.cstring, nil, false, -1).x)
          result += igGetFontSize() * 1.5 # and the sort arrow
        let (a, b) = (rows[0], rows[^1])
        # Every column is set up, so the sort's numbers hold; the columns no
        # record has a value for are not shown.
        proc column(name: string; c: RecordSort; w: float32; shown: bool; extra = 0.cint) =
          let hidden = if shown: 0.cint else: ImGui_TableColumnFlags_Disabled.cint
          igTableSetupColumn(name.cstring, ImGui_TableColumnFlags_WidthFixed.cint or hidden or
            extra, w, ImGuiID(c))
        column("#", rsPlace, width(["#", $rows.len]), true,
          ImGui_TableColumnFlags_NoHide.cint or ImGui_TableColumnFlags_DefaultSort.cint)
        column($rcRecord, rsRecord, width([$rcRecord, num(a.record), num(b.record)]),
          rcRecord in columns)
        column($rcEnsemble, rsEnsemble, width([$rcEnsemble, num(a.ensemble), num(b.ensemble)]),
          rcEnsemble in columns)
        column($rcSource, rsSource, width([$rcSource, station(a.srcLine, a.srcPoint),
          station(b.srcLine, b.srcPoint)]), rcSource in columns)
        column($rcReceiver, rsReceiver, width([$rcReceiver, station(a.rcvLine, a.rcvPoint),
          station(b.rcvLine, b.rcvPoint)]), rcReceiver in columns)
        column("Traces", rsSeismic, width(["Traces", "00000"]), true)
        column("Aux", rsAux, width(["Aux", "000"]), ui.aux)
        column("Dead", rsDead, width(["Dead", "0000"]), true)
        column("Missing", rsMissing, width(["Missing"]), true,
          ImGui_TableColumnFlags_PreferSortDescending.cint)
        # The headers, each marked "records.header <name>" (as `igTableHeadersRow`
        # draws them, which marks none)
        igPushItemFlag(ImGui_ItemFlags_NoTabStop.cint, true) # the list is one stop of Tab
        igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
        for c in RecordSort:
          if igTableSetColumnIndex(cint(c)):
            let name = igTableGetColumnName_Int(cint(c))
            igTableHeader(name)
            marks.mark("records.header " & $name)
            tip("Click to sort by " & $name)
        igPopItemFlag()
        let specs = igTableGetSortSpecs()
        if specs != nil and specs.SpecsCount > 0:
          let spec = specs.Specs[]
          ui.sortBy = RecordSort(clamp(int(spec.ColumnUserID), 0, int(RecordSort.high)))
          ui.descending = spec.SortDirection == ImGui_SortDirection_Descending
          specs.SpecsDirty = false
        let wanted = (session.id, rows.len, session.checkedAgainst, ui.sortBy, ui.descending)
        if wanted != ui.sorted or (ui.order.len > 0 and ui.order.len != rows.len):
          ui.sorted = wanted
          ui.resort(rows)
        let warning = vec4(t.roles[rlWarning])
        ui.keys.beforeRows(bridged = false) # the list is the window's only stop
        let clipper = ImGuiListClipper_ImGuiListClipper()
        ImGuiListClipper_Begin(clipper, cint(rows.len), -1)
        if ui.follow and current in 0 ..< rows.len:
          ImGuiListClipper_IncludeItemByIndex(clipper, cint(ui.placeOf(current)))
        while ImGuiListClipper_Step(clipper):
          for row in clipper.DisplayStart ..< clipper.DisplayEnd:
            let i = ui.rowAt(row)
            let r = rows[i]
            let missing = r.missing
            igTableNextRow(0, 0)
            discard igTableNextColumn()
            igPushID_Int(cint(i))
            if i == current: ui.keys.beforeShownRow()
            pushRowTabStop(i == current)
            if missing > 0: igPushStyleColor_Vec4(ImGui_Col_Text.cint, warning)
            if igSelectable_Bool(cstring($(i + 1)), i == current,
                ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0)) and
                i != current and ui.focus.acts:
              result.commands.add Command(kind: ckGather, panel: panel, gather: i)
            tip("Show this record")
            if missing > 0: igPopStyleColor(1)
            popRowTabStop()
            ui.keys.afterRow()
            if igIsItemFocused(): marks.mark("records.focused")
            igPopID()
            if i == current:
              marks.mark("records.current")
              if ui.follow:
                if not igIsItemVisible(): igSetScrollHereY(0.5)
                ui.follow = false
            if i < 3: marks.mark("records.row " & $i)
            if igTableNextColumn(): cell(num(r.record))
            if igTableNextColumn(): cell(num(r.ensemble))
            if igTableNextColumn(): cell(station(r.srcLine, r.srcPoint))
            if igTableNextColumn(): cell(station(r.rcvLine, r.rcvPoint))
            if igTableNextColumn(): cell($r.seismic)
            if igTableNextColumn(): cell(if r.aux > 0: $r.aux else: "")
            if igTableNextColumn(): cell($r.dead)
            if igTableNextColumn():
              if missing > 0: igPushStyleColor_Vec4(ImGui_Col_Text.cint, warning)
              cell(if missing >= 0: $missing else: "")
              if missing > 0: igPopStyleColor(1)
              if i < 3: marks.mark("records.missing " & $i)
              tip(if r.planned < 0 and session.checkNote.len > 0: session.checkNote
                else: missingText(r, session.checkedAgainst))
        ImGuiListClipper_End(clipper)
        ImGuiListClipper_destroy(clipper)
        igEndTable()
        marks.mark("records.table")
      igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
      var text = session.name & ": record " & $(current + 1) & " of " & $rows.len
      if ui.short > 0: text.add ", " & $ui.short & " with traces missing"
      if session.checkedAgainst.len > 0:
        text.add " (checked against " & session.checkedAgainst & ")"
      igTextUnformatted(text.cstring, nil)
      igPopStyleColor(1)
      marks.mark("records.footer")
      if rows.len > 0:
        let page = max(1, int(igGetWindowHeight() / igGetTextLineHeightWithSpacing()) - 3)
        let step = stepOf("records keys")
        ui.keys.stepped(step)
        let at = ui.placeOf(clamp(current, 0, rows.high))
        var to = case step
          of lsNone: at
          of lsNext: at + 1
          of lsPrevious: at - 1
          of lsPageDown: at + page
          of lsPageUp: at - page
          of lsFirst: 0
          of lsLast: rows.high
        to = ui.rowAt(clamp(to, 0, rows.high))
        if to != current:
          result.commands.add Command(kind: ckGather, panel: panel, gather: to)
  ui.focus.settle()
  igEnd()
