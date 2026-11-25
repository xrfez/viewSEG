## The Shot log window: a table of shots, its column map, and its problems.
## Import is Project > Import shot log...; this window opens, docked as a tab,
## once a file is chosen, and View shows or hides it. One cell can be edited at a time, and
## only while Allow editing is ticked. Follow the plot, off until ticked,
## shows the row the plot is on.

import std/[algorithm, math, options, os, strutils, tables]
import imguin/cimgui
import parseSEG/survey/sps
import ../../core/[destwatch, geometry, shotlayout, shotlog, shotlogsps, shotsort, state]
import ../../view/[shotlogrows, shotlogwords, theme]
import chrome, focus, icons, marks, style
from windows import awShotLog, beginClosable

const
  ScanBatch = 1600   ## filter rows looked at in one frame
  SortBatch = 25_000 ## rows whose sort keys are read in one frame
  PatternRoom = 256
  NameRoom = 64
  SentinelRoom = 1024
  FilterRoom = 64
  SpsLineRoom = 32

type
  ListMode = enum
    lmAll, lmMatches, lmFaults, lmOnly

  ShotLogUi* = object
    ## The window's own state between frames.
    focus: FocusClicks
    haveSeen: bool                    ## a loaded log has been followed
    seenMax: int                      ## the highest id followed
    currentId: int                    ## the log on show
    columnsOpen: bool
    draft: ShotLogMap
    draftWidth: int
    draftDirty: bool                  ## the draft's boxes are read again next frame
    draftNames: seq[string]           ## the names the draft gives its columns
    draftFault: string                ## why the draft cannot be applied, or ""
    draftNameFaults: seq[tuple[col: int, why: string]]
    draftNote: string                 ## what is said about the draft's time
    # a user defined column's name, as typed
    nameBufs: seq[array[NameRoom, char]]
    skip: int32
    pattern: array[PatternRoom, char]
    sentinels: array[SentinelRoom, char]
    filter: array[FilterRoom, char]
    filterText: string
    needle: string
    scanAt: int
    matches: seq[int]
    filterDone: bool
    problemsOnly: bool
    onlySelected: bool                ## list only the selected rows
    onlyRows: seq[int]                ## the rows listed while `onlySelected`
    chosenRows: ChosenRows            ## the rows marked this frame
    scrolledFor: ScrollKey            ## what the grid last scrolled to, or would have
    allowEditing: bool                ## cell edits, undo and revert; off until ticked
    tab: int                          ## 0 grid, 1 problems
    forceGrid: bool                   ## the grid tab is selected next frame
    selected: int
    selectedCol: int                  ## a data column; -1 when the time or status column is selected
    scrollTo: int
    editing: bool
    editRow: int
    editCol: int
    editBuf: seq[char]
    editReason: string
    armEdit: bool                     ## the text box takes the keyboard when it is drawn
    pending: bool                     ## Tab committed: open the next cell next frame
    pendingRow: int
    pendingCol: int
    bound: bool
    boundId: int
    boundRev: int
    followSeen: bool                  ## an answer has been applied for the log on show
    followRev: int
    followId: int
    faultRows: seq[int]
    faultText: Table[int, string]
    spsOpen: bool                     ## the Export SPS panel is showing
    spsReady: bool                    ## the panel's options have their first values
    spsRevision: SpsRevision
    spsLine: array[SpsLineRoom, char] ## the default line, empty for none
    spsIndex: int32
    spsCode: array[4, char]
    spsTime: bool
    spsDest: string                   ## the file chosen; "" before one is
    spsTaken: DestWatch               ## whether it exists: asked when chosen, and when an export ended
    spsLogId: int                     ## the log the file was chosen for
    spsSeen: string                   ## the outcome last looked at
    spsAsk: bool                      ## the Choose file button was pressed: ask for a file
    spsAskAt: string
    spsRows: int                      ## rows with a shot point, of the log keyed below
    spsKey: tuple[id, rev: int]
    spsHaveRows: bool
    layout: ShotLayout                ## how the grid is laid out, as the user has it
    layoutId: int                     ## the log `placed` and `sortCols` are worked out for
    layoutCols: int                   ## ... and its column count
    layoutRev: int
    keys: seq[string]                 ## the log's columns' names, as a layout keeps them
    placed: seq[ColumnPlace]          ## every column but the ignored, in the order shown
    visible: seq[int]                 ## the shown columns of `placed`, as log columns, in order
    sortCols: seq[tuple[col: int, descending: bool]]
    gridGen: int                      ## the grid's table is made anew when this changes
    gridAge: int                      ## frames since
    sortBuild: SortBuild              ## the sort under way
    sortKey: string                   ## what `order` (or the build) is of
    order: seq[int]                   ## every row in the sort's order, once `haveOrder`
    rank: seq[int32]                  ## each row's place in `order`
    haveOrder: bool
    orderStamp: int
    sorted: seq[int]                  ## the listed rows in the sort's order (not for lmAll)
    sortedFrom: seq[int]              ## the rows `sorted` is of
    sortedStamp: int

func shownId*(ui: ShotLogUi): int {.inline.} =
  ## The id of the log the window shows; -1 when there is none.
  ui.currentId

proc hidden*(ui: var ShotLogUi) =
  ## The window is not drawn: it has no focus.
  ui.focus.blur()

func focused*(ui: ShotLogUi): bool {.inline.} =
  ## Whether the window had the focus at the end of the last frame.
  ui.focus.focused

func takesUndo*(ui: ShotLogUi): bool {.inline.} =
  ## Whether this window takes Ctrl+Z and Ctrl+Y: it had the focus and
  ## Allow editing is ticked.
  ui.focus.focused and ui.allowEditing

proc spsAsked*(ui: var ShotLogUi): tuple[ask: bool, at: string] =
  ## Whether the window wants a destination file chosen, and where the dialog
  ## starts. Asked once per press.
  result = (ui.spsAsk, ui.spsAskAt)
  ui.spsAsk = false

proc setSpsDest*(ui: var ShotLogUi; path: string) =
  ## The save dialog's answer; `.sps` is added when the name has no extension.
  ui.spsDest = if path.splitFile.ext.len == 0: path & ".sps" else: path
  ui.spsLogId = ui.currentId

proc setText(buf: var openArray[char]; text: string) =
  ## `text` in the box, cut at a character's end when it is too long.
  var n = min(text.len, buf.len - 1)
  while n > 0 and n < text.len and (ord(text[n]) and 0xC0) == 0x80: dec n
  for i in 0 ..< n: buf[i] = text[i]
  for i in n ..< buf.len: buf[i] = '\0'

proc bufText(buf: openArray[char]): string =
  $cast[cstring](unsafeAddr buf[0])

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 32)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc dim(text: string; t: Theme) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc wrapped(text: string; colour: Rgba) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  igPopStyleColor(1)

proc whereOf(st: AppState): string =
  if st.inProject: st.project.doc.name else: SessionOnly

proc spsOptions(ui: ShotLogUi): tuple[ok: bool, opts: ShotSpsOptions] =
  ## The panel's options; `ok` is false when the default line is not a number.
  var o = initShotSpsOptions()
  o.revision = ui.spsRevision
  o.defaultIndex = int(ui.spsIndex)
  o.pointCode = bufText(ui.spsCode)
  o.withTime = ui.spsTime
  let typed = bufText(ui.spsLine).strip
  var ok = true
  if typed.len > 0:
    try:
      o.defaultLine = parseFloat(typed)
    except ValueError:
      ok = false
  (ok, o)

proc countSpsRows(ui: var ShotLogUi; st: AppState; i, rev: int) =
  ## The rows that have a shot point, worked out again only when the log changed. A file
  ## chosen for another log is let go, and the file's existence is asked of the disk, on a
  ## job, again when an export ends.
  if ui.spsLogId != ui.currentId:
    ui.spsDest = ""
    ui.spsLogId = ui.currentId
  if st.spsOutcome != ui.spsSeen:
    ui.spsSeen = st.spsOutcome
  ui.spsTaken.follow(st.jobs, ui.spsDest,
    if ui.spsDest.len > 0: ui.spsDest & '\0' & ui.spsSeen else: "")
  let key = (ui.currentId, rev)
  if not ui.spsHaveRows or ui.spsKey != key:
    ui.spsRows = 0
    for row in st.shotView(i).rows:
      if not row.shotPoint.isNaN: inc ui.spsRows
    ui.spsKey = key
    ui.spsHaveRows = true

proc drawSps(ui: var ShotLogUi; st: AppState; i: int; t: Theme;
    marks: var Marks): seq[Command] =
  ## The Export SPS panel: the options, the file, and the button that posts the command.
  igSeparator()
  igSetNextItemWidth(igGetFontSize() * 6)
  if igBeginCombo((SpsRevisionLabel & "##sps").cstring,
      spsRevisionWords(ui.spsRevision).cstring, 0):
    for r in [sps21, sps10]:
      if igSelectable_Bool(spsRevisionWords(r).cstring, r == ui.spsRevision, 0,
          ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
        ui.spsRevision = r
      marks.mark("shotlog.sps.revision " & spsRevisionWords(r))
    igEndCombo()
  marks.mark("shotlog.sps.revision")
  igSetNextItemWidth(igGetFontSize() * 8)
  discard igInputText((SpsDefaultLine & "##sps").cstring, cast[cstring](addr ui.spsLine[0]),
    csize_t(ui.spsLine.len), 0, nil, nil)
  marks.mark("shotlog.sps.line")
  marks.mark("shotlog.sps.linetext " & bufText(ui.spsLine))
  tip(SpsDefaultLineTip)
  igSetNextItemWidth(igGetFontSize() * 8)
  var index = ui.spsIndex
  if igInputInt((SpsDefaultIndex & "##sps").cstring, addr index, 1, 1, 0):
    ui.spsIndex = clamp(index, 0, 9)
  marks.mark("shotlog.sps.index")
  marks.mark("shotlog.sps.indextext " & $ui.spsIndex)
  igSetNextItemWidth(igGetFontSize() * 4)
  discard igInputText((SpsPointCode & "##sps").cstring, cast[cstring](addr ui.spsCode[0]),
    csize_t(3), 0, nil, nil)
  marks.mark("shotlog.sps.code")
  marks.mark("shotlog.sps.codetext " & bufText(ui.spsCode))
  tip(SpsPointCodeTip)
  var time = ui.spsTime
  if igCheckbox((SpsWithTime & "##sps").cstring, addr time) and ui.focus.acts:
    ui.spsTime = time
  marks.mark("shotlog.sps.time")
  tip(SpsWithTimeTip)
  let (optsOk, opts) = ui.spsOptions()
  if not optsOk:
    wrapped(SpsBadLine, t.roles[rlWarning])
    marks.mark("shotlog.sps.why " & SpsBadLine)
  let chosen = if ui.spsDest.len > 0: ui.spsDest else: SpsNoFile
  igTextUnformatted(("File: " & chosen).cstring, nil)
  marks.mark("shotlog.sps.file " & ui.spsDest)
  igSameLine(0, -1)
  if igButton((SpsChooseFile & "##sps").cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
    ui.spsAsk = true
    ui.spsAskAt = if ui.spsDest.len > 0: ui.spsDest
      else: st.shotLogSource(i).parentDir / (st.shotLogSource(i).splitFile.name & ".sps")
  marks.mark("shotlog.sps.choose")
  let why = if st.spsRunning: SpsRunning
            elif st.shotLogBusy(i): SpsReading
            elif ui.spsDest.len == 0: SpsNeedFile
            elif ui.spsTaken.pending: SpsChecking
            elif ui.spsTaken.exists: SpsExistsTip
            elif not optsOk: SpsBadLine
            else: ""
  if why.len > 0: marks.mark("shotlog.sps.why " & why)
  igBeginDisabled(why.len > 0)
  if igButton((SpsRun & "##sps").cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
      why.len == 0:
    result.add Command(kind: ckExportShotSps, spsLog: i, spsOptions: opts,
      spsDest: ui.spsDest)
  igEndDisabled()
  marks.mark("shotlog.sps.run")
  tip(if why.len > 0: why else: SpsRunTip)
  igSameLine(0, -1)
  if igButton((SpsClose & "##sps").cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
    ui.spsOpen = false
  marks.mark("shotlog.sps.close")
  if st.spsRunning:
    dim(SpsRunningNote, t)
    marks.mark("shotlog.sps.running")
  elif st.spsOutcome.len > 0 and st.spsOutcomeLog == ui.currentId:
    wrapped(st.spsOutcome, if st.spsWritten.len > 0: t.roles[rlText] else: t.roles[rlWarning])
    marks.mark("shotlog.sps.outcome " & st.spsOutcome)
  igSeparator()

proc textWidth(label: string): float32 =
  igCalcTextSize(label.cstring, nil, false, -1).x

proc buttonWidth(label: string): float32 =
  textWidth(label) + igGetStyle().FramePadding.x * 2 + 8

proc checkWidth(label: string): float32 =
  igGetFrameHeight() + igGetStyle().ItemInnerSpacing.x + textWidth(label) + 8

proc sameLineIfFits(need: float32) =
  ## The next control goes beside the last when it fits in the window, else on a line of its
  ## own (as the Missing traces window's top line does), so that every control can be reached.
  let edge = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  if edge - igGetItemRectMax().x >= need + igGetStyle().ItemSpacing.x: igSameLine(0, -1)

proc follow(ui: var ShotLogUi; st: AppState) =
  ## The newest import, or the newest log when the one on show is gone.
  var maxId = -1
  for i in 0 ..< st.shotLogCount:
    let id = st.shotLogId(i)
    if id > maxId: maxId = id
  if maxId < 0:
    ui.currentId = -1
    return
  if not ui.haveSeen or maxId > ui.seenMax:
    ui.haveSeen = true
    ui.seenMax = maxId
    ui.currentId = maxId
  elif st.findShotLog(ui.currentId) < 0:
    ui.currentId = maxId

proc resetScan(ui: var ShotLogUi) =
  ui.scanAt = 0
  ui.matches.setLen 0
  ui.filterDone = ui.needle.len == 0

proc clearFilter(ui: var ShotLogUi) =
  setText(ui.filter, "")
  ui.filterText = ""
  ui.needle = ""
  ui.resetScan()

proc stopEdit(ui: var ShotLogUi) =
  ui.editing = false
  ui.editReason = ""
  ui.armEdit = false
  ui.pending = false

proc beginEdit(ui: var ShotLogUi; row, col: int; text: string) =
  if not ui.allowEditing: return
  ui.editing = true
  ui.editRow = row
  ui.editCol = col
  ui.selected = row
  ui.selectedCol = col
  ui.editReason = ""
  ui.armEdit = true
  ui.pending = false
  let n = max(text.len + 64, 256)
  ui.editBuf = newSeq[char](n)
  let m = min(text.len, n - 1)
  for i in 0 ..< m: ui.editBuf[i] = text[i]
  ui.editBuf[m] = '\0'

proc editText(ui: ShotLogUi): string =
  if ui.editBuf.len == 0: ""
  else: $cast[cstring](unsafeAddr ui.editBuf[0])

proc selectEditedCell(data: ptr ImGuiInputTextCallbackData): cint {.cdecl, raises: [].} =
  ## A multiline box ignores AutoSelectAll. Select the cell once, as it is focused.
  if data != nil and data.EventActivated:
    ImGuiInputTextCallbackData_SelectAll(data)
  0

proc hasBreak(s: string): bool =
  '\n' in s or '\r' in s

proc cacheFaults(ui: var ShotLogUi; st: AppState; i: int) =
  ui.faultRows.setLen 0
  ui.faultText.clear()
  if i < 0: return
  for p in st.shotView(i).problems.items:
    if p.row < 0: continue
    if ui.faultText.hasKey(p.row):
      ui.faultText[p.row].add "; "
      ui.faultText[p.row].add p.text
    else:
      ui.faultText[p.row] = p.text
      ui.faultRows.add p.row
  ui.faultRows.sort()

proc bindLog(ui: var ShotLogUi; st: AppState; i, rev: int) =
  ## Drops a draft and a filter when the log on show changes, and rebuilds
  ## the problem rows when the view does.
  if not ui.bound or ui.boundId != ui.currentId:
    ui.bound = true
    ui.boundId = ui.currentId
    ui.boundRev = rev
    ui.columnsOpen = false
    ui.layoutId = -1
    ui.sortKey = ""
    ui.haveOrder = false
    ui.sortBuild = nil
    ui.allowEditing = false
    ui.selected = -1
    ui.selectedCol = -1
    ui.scrollTo = -1
    ui.followSeen = false
    ui.stopEdit()
    ui.clearFilter()
    ui.cacheFaults(st, i)
  elif ui.boundRev != rev:
    ui.boundRev = rev
    ui.draftDirty = true
    ui.resetScan()
    ui.cacheFaults(st, i)
    ui.stopEdit()

proc sortText(ui: ShotLogUi): string =
  ## The sort as the header marks say it: the columns' names in order, a minus after a
  ## descending one.
  for k, s in ui.sortCols:
    if k > 0: result.add ", "
    result.add ui.keys[s.col]
    if s.descending: result.add " -"

proc layoutNow(ui: ShotLogUi): ShotLayout =
  layoutFrom(ui.placed, ui.keys, ui.sortCols)

proc placeVisible(ui: var ShotLogUi) =
  ui.visible.setLen 0
  for p in ui.placed:
    if not p.hidden: ui.visible.add p.col

proc eligible(ui: ShotLogUi; st: AppState; i: int): seq[bool] =
  ## Which columns the grid may show: all but those mapped to Ignore.
  let map = st.shotLogMap(i)
  result = newSeq[bool](ui.keys.len)
  for c in 0 ..< result.len:
    result[c] = c >= map.roles.len or map.roles[c] != crIgnored

proc clickSort(spec: var seq[tuple[col: int, descending: bool]]; col: int; shift: bool) =
  ## A click on a header: it becomes the one key (or turns round when it is); with Shift it
  ## is added as a further key (or turns round when it is one).
  if shift:
    var at = -1
    for i, s in spec:
      if s.col == col: at = i
    if at >= 0: spec[at].descending = not spec[at].descending
    elif spec.len < MaxLayoutSort: spec.add (col: col, descending: false)
  elif spec.len == 1 and spec[0].col == col:
    spec[0].descending = not spec[0].descending
  else:
    spec.setLen 0
    spec.add (col: col, descending: false)

proc syncLayout(ui: var ShotLogUi; st: AppState; i, width, rev: int) =
  ## Works the layout out for the log on show: when the log changes it is the one kept
  ## for it; a new revision (another map) places the same layout over its columns.
  if ui.layoutId == ui.currentId and ui.layoutRev == rev and ui.layoutCols == width: return
  if ui.layoutId != ui.currentId: ui.layout = st.shotLayout(i)
  ui.layoutId = ui.currentId
  ui.layoutRev = rev
  ui.layoutCols = width
  ui.keys = st.shotLogKeys(i)
  ui.placed = ui.layout.places(ui.keys, ui.eligible(st, i))
  ui.sortCols = ui.layout.sortColumns(ui.keys)
  ui.placeVisible()
  inc ui.gridGen

proc ensureOrder(ui: var ShotLogUi; st: AppState; i, n, rev: int) =
  ## The sort's order of the rows: read a batch of rows a frame, so a long log never holds
  ## a frame, and made once for the log, its revision and the sort, not every frame.
  if ui.sortCols.len == 0:
    ui.sortKey = ""
    ui.sortBuild = nil
    if ui.haveOrder:
      ui.haveOrder = false
      ui.order.setLen 0
      ui.rank.setLen 0
      inc ui.orderStamp
    return
  let key = $ui.currentId & "|" & $rev & "|" & ui.sortText
  if key != ui.sortKey:
    ui.sortKey = key
    let map = st.shotLogMap(i)
    var keys: seq[RowKey] = @[]
    for s in ui.sortCols:
      keys.add RowKey(col: s.col, kind: rowKindOf(map, s.col), descending: s.descending)
    ui.sortBuild = newSortBuild(n, keys, map.decimalComma)
    ui.haveOrder = false
  if ui.sortBuild != nil and st.shotSortStep(i, ui.sortBuild, SortBatch):
    let rows = ui.sortBuild.order
    ui.order = newSeq[int](rows.len)
    ui.rank = newSeq[int32](rows.len)
    for at, r in rows:
      ui.order[at] = int(r)
      ui.rank[int(r)] = int32(at)
    ui.sortBuild = nil
    ui.haveOrder = true
    inc ui.orderStamp

proc loadDraft(ui: var ShotLogUi; map: ShotLogMap; width: int) =
  ui.draft = map
  ui.draftWidth = width
  while ui.draft.roles.len < width: ui.draft.roles.add crText
  if ui.draft.roles.len > width: ui.draft.roles.setLen(width)
  ui.draft.names.setLen width
  ui.nameBufs.setLen width
  for c in 0 ..< width: setText(ui.nameBufs[c], ui.draft.names[c])
  ui.skip = int32(max(0, map.skipLines))
  setText(ui.pattern, map.dateTimePattern)
  setText(ui.sentinels, sentinelsText(map.sentinels))
  ui.draftDirty = true

proc readDraft(ui: var ShotLogUi) =
  ui.draft.skipLines = max(0, int(ui.skip))
  ui.draft.dateTimePattern = bufText(ui.pattern).strip
  for c in 0 ..< min(ui.draft.names.len, ui.nameBufs.len):
    ui.draft.names[c] = bufText(ui.nameBufs[c]).strip
  ui.draft.sentinels = splitSentinels(bufText(ui.sentinels))

proc refreshDraft(ui: var ShotLogUi; st: AppState; i: int) =
  ## Reads the boxes into the draft and works out what the dialog says about
  ## it. Done when the dialog opens, the log or its map changes, or a box or
  ## choice is edited, not every frame.
  ui.readDraft()
  ui.draftNameFaults = nameProblems(ui.draft)
  ui.draftNames = st.shotLogNames(i, ui.draft, ui.draftWidth)
  ui.draftFault = mapFault(ui.draft)
  ui.draftNote = st.shotLogTimeNote(i, ui.draft)
  ui.draftDirty = false

proc shownColumns(st: AppState; i, width: int): seq[int] =
  ## The columns the grid shows: all but those mapped to Ignore.
  let map = st.shotLogMap(i)
  for c in 0 ..< width:
    if c >= map.roles.len or map.roles[c] != crIgnored: result.add c

proc rowHits(st: AppState; i, row: int; shown: openArray[int]; needle: string): bool =
  ## Whether a shown cell of `row` holds `needle`. An ignored column is not searched.
  for c in shown:
    let cell = st.shotCell(i, row, c)
    if cell.len >= needle.len and needle in cell.toLowerAscii: return true

proc scanFilter(ui: var ShotLogUi; st: AppState; i, width, n: int) =
  if ui.needle.len == 0 or ui.filterDone or i < 0: return
  let stop = min(n, ui.scanAt + ScanBatch)
  let shown = shownColumns(st, i, width)
  for row in ui.scanAt ..< stop:
    if rowHits(st, i, row, shown, ui.needle) and
        (not ui.problemsOnly or ui.faultText.hasKey(row)):
      ui.matches.add row
  ui.scanAt = stop
  ui.filterDone = ui.scanAt >= n

proc rowFiltered(ui: ShotLogUi; st: AppState; i, row, n: int; shown: openArray[int]): bool =
  ## Whether data row `row` is left out by the filter box or Problems only.
  ## `shown` is `shownColumns`, built once for all the rows a pass asks about.
  if row < 0 or row >= n: return false
  if ui.problemsOnly and not ui.faultText.hasKey(row): return true
  if ui.needle.len > 0 and not rowHits(st, i, row, shown, ui.needle): return true
  false

proc noteFollow(ui: var ShotLogUi; st: var AppState; i, width, n: int): string =
  ## The follow line, and a scroll to the one row when the answer changed.
  ## A click's selection stays until that change. Filtering is left as it is.
  if not st.settings.shotLog.followPlot:
    ui.followSeen = false
    return ""
  let a = st.followAnswer(i)
  let changed = not ui.followSeen or ui.followId != ui.currentId or
    a.revision != ui.followRev
  ui.followSeen = true
  ui.followId = ui.currentId
  ui.followRev = a.revision
  let hidden = a.match.row >= 0 and
    ui.rowFiltered(st, i, a.match.row, n, shownColumns(st, i, width))
  if changed and a.match.row >= 0 and not hidden:
    ui.selected = a.match.row
    ui.selectedCol = -1
    ui.scrollTo = a.match.row
  followStatus(a, hidden)

proc markChosen(ui: var ShotLogUi; st: var AppState; i, width, n: int) =
  ## The rows marked and listed with Only selected, and the scroll to them. As the Headers
  ## window's Trace tab follows the pointer: the selection first; with none, and Follow the
  ## pointer on, the rows of the shot under the map's pointer; with it off the grid never
  ## scrolls by itself.
  let follow = st.settings.headers.followPointer
  let chosen = st.shotRowsChosen
  let selected = if chosen.log == ui.currentId: chosen.rows else: @[]
  var pointed: seq[int]
  # (the trace under the plot's pointer is Follow the plot's: it has its own tick)
  if follow and selected.len == 0: pointed = st.hoveredShotRows(ui.currentId)
  ui.chosenRows = chosenRows(selected, pointed, follow)
  let key = ui.chosenRows.scrollKey(if chosen.log == ui.currentId: chosen.revision else: 0)
  if ui.chosenRows.by == rbSelection and key != ui.scrolledFor and
      ui.selected != ui.chosenRows.rows[0]:
    ui.selected = ui.chosenRows.rows[0]
    ui.selectedCol = -1
  if scrollsTo(ui.scrolledFor, key, follow): ui.scrollTo = ui.chosenRows.rows[0]
  ui.scrolledFor = key
  ui.onlyRows.setLen 0
  if ui.onlySelected:
    let me = addr ui
    let state = addr st
    let shown = shownColumns(st, i, width)
    ui.onlyRows = onlySelected(selected, n,
      proc (row: int): bool = me[].rowFiltered(state[], i, row, n, shown))

proc chooseRow(ui: ShotLogUi; row: int): Command =
  ## A click on a row of the grid chooses it: the map selects its point (not its traces).
  Command(kind: ckSelectShotRows, shotLogId: ui.currentId, shotRows: @[row], shotTraces: false)

func listMode(ui: ShotLogUi): ListMode =
  if ui.onlySelected: lmOnly
  elif ui.needle.len > 0: lmMatches
  elif ui.problemsOnly: lmFaults
  else: lmAll

func inOrder(ui: ShotLogUi): bool =
  ## Whether the rows are listed in the sort's order: it is made, and a filter that is
  ## still being scanned does not list anything sorted yet.
  ui.haveOrder and not (ui.listMode == lmMatches and not ui.filterDone)

proc refreshSorted(ui: var ShotLogUi) =
  ## `sorted`: the filtered rows in the sort's order; worked out again only when the sort
  ## or the rows the filters list changed, never every frame.
  if not ui.inOrder or ui.listMode == lmAll: return
  let base = case ui.listMode
    of lmOnly: addr ui.onlyRows
    of lmMatches: addr ui.matches
    else: addr ui.faultRows
  if ui.sortedStamp == ui.orderStamp and ui.sortedFrom == base[]: return
  ui.sortedFrom = base[]
  ui.sorted = ui.sortedFrom
  let rank = addr ui.rank
  ui.sorted.sort(proc (a, b: int): int = cmp(rank[][a], rank[][b]))
  ui.sortedStamp = ui.orderStamp

proc listedCount(ui: ShotLogUi; n: int): int =
  if ui.inOrder and ui.listMode == lmAll: ui.order.len
  elif ui.inOrder: ui.sorted.len
  elif ui.onlySelected: ui.onlyRows.len
  elif ui.needle.len > 0: ui.matches.len
  elif ui.problemsOnly: ui.faultRows.len
  else: n

proc listedRow(ui: ShotLogUi; i: int): int =
  if ui.inOrder and ui.listMode == lmAll: ui.order[i]
  elif ui.inOrder: ui.sorted[i]
  elif ui.onlySelected: ui.onlyRows[i]
  elif ui.needle.len > 0: ui.matches[i]
  elif ui.problemsOnly: ui.faultRows[i]
  else: i

proc listedIndex(ui: ShotLogUi; row, n: int): int =
  ## Where data row `row` sits in the list on show, or -1.
  result = -1
  if row < 0: return
  if ui.inOrder and ui.listMode == lmAll:
    if row < ui.rank.len: result = int(ui.rank[row])
  elif ui.inOrder:
    for i, r in ui.sorted:
      if r == row: return i
  elif ui.onlySelected:
    for i, r in ui.onlyRows:
      if r == row: return i
  elif ui.needle.len > 0:
    for i, r in ui.matches:
      if r == row: return i
  elif ui.problemsOnly:
    for i, r in ui.faultRows:
      if r == row: return i
  elif row in 0 ..< n:
    result = row

proc nextListed(ui: ShotLogUi; row, col, n: int): tuple[row, col: int] =
  ## The next editable cell after (`row`, `col`) among the columns shown, in the order
  ## shown, or (-1, -1): along the row, then the first column of the next listed row.
  if ui.visible.len == 0: return (-1, -1)
  let next = nextInOrder(ui.visible, col)
  if next >= 0: return (row, next)
  let at = ui.listedIndex(row, n)
  if at < 0: return (-1, -1)
  if at + 1 >= ui.listedCount(n): return (-1, -1)
  (ui.listedRow(at + 1), ui.visible[0])

proc copyRow(st: AppState; i, row, width: int; d: Delimiter) =
  var cells = newSeq[string](width)
  for c in 0 ..< width: cells[c] = st.shotCell(i, row, c)
  igSetClipboardText(joinRow(cells, delimChar(d)).cstring)

proc roleCombo(col: int; role: var ColumnRole; marks: var Marks): bool =
  igSetNextItemWidth(-1)
  let open = igBeginCombo(("##role" & $col).cstring, label(role).cstring,
    ImGui_ComboFlags_HeightLargest.cint)
  marks.mark("shotlog.rolecombo " & $col)
  if open:
    for r in ColumnRole:
      if igSelectable_Bool(label(r).cstring, r == role, 0, ImVec2_c(x: 0, y: 0)):
        role = r
        result = true
      marks.mark("shotlog.roleitem " & $col & " " & label(r))
    igEndCombo()

proc enumCombo[T: enum](id: string; v: var T; width: float32): bool =
  igSetNextItemWidth(width)
  if igBeginCombo(id.cstring, ($v).cstring, 0):
    for x in T:
      if igSelectable_Bool(($x).cstring, x == v, 0, ImVec2_c(x: 0, y: 0)):
        v = x
        result = true
    igEndCombo()

proc drawColumns(ui: var ShotLogUi; st: AppState; i: int; t: Theme; marks: var Marks;
    busy: bool): seq[Command] =
  let width = ui.draftWidth
  if ui.draftDirty or ui.draftNames.len != width: ui.refreshDraft(st, i)
  let fault = ui.draftFault
  for r in duplicateRoles(ui.draft.roles):
    wrapped(duplicateSentence(r), t.roles[rlWarning])
    marks.mark("shotlog.duplicate " & label(r))
  igAlignTextToFramePadding()
  igTextUnformatted("Delimiter", nil)
  igSameLine(0, -1)
  if enumCombo("##delim", ui.draft.delimiter, igGetFontSize() * 8): ui.draftDirty = true
  marks.mark("shotlog.delimiter")
  igSameLine(0, -1)
  igTextUnformatted("lines to skip", nil)
  igSameLine(0, -1)
  igSetNextItemWidth(igGetFontSize() * 6)
  if igInputInt("##skip", addr ui.skip, 1, 10, 0): ui.draftDirty = true
  if ui.skip < 0: ui.skip = 0
  marks.mark("shotlog.skip")
  igSameLine(0, -1)
  var header = ui.draft.hasHeader
  if igCheckbox("header row", addr header):
    ui.draft.hasHeader = header
    ui.draftDirty = true
  marks.mark("shotlog.header")
  igAlignTextToFramePadding()
  igTextUnformatted("Clock", nil)
  igSameLine(0, -1)
  if enumCombo("##clock", ui.draft.clock, igGetFontSize() * 6): ui.draftDirty = true
  marks.mark("shotlog.clock")
  tip("The clock of a time written as a calendar date; seconds or microseconds since " &
    "1970 are always UTC")
  igAlignTextToFramePadding()
  igTextUnformatted("Time pattern", nil)
  igSameLine(0, -1)
  let current = bufText(ui.pattern).strip
  var preview = PresetsHint
  for p in TimePresets:
    if p.pattern == current: preview = p.label
  let presetWidth = igGetFontSize() * 13
  igSetNextItemWidth(-(presetWidth + igGetStyle().ItemSpacing.x))
  if igInputText("##pattern", cast[cstring](addr ui.pattern[0]),
      csize_t(ui.pattern.len), 0, nil, nil):
    ui.draftDirty = true
  marks.mark("shotlog.pattern")
  marks.mark("shotlog.patterntext " & current)
  tip(PatternTip)
  igSameLine(0, -1)
  igSetNextItemWidth(presetWidth)
  if igBeginCombo("##presets", preview.cstring, 0):
    for p in TimePresets:
      if igSelectable_Bool(p.label.cstring, p.pattern == current, 0, ImVec2_c(x: 0, y: 0)):
        setText(ui.pattern, p.pattern)
        ui.draftDirty = true
      marks.mark("shotlog.presetitem " & p.label)
    igEndCombo()
  marks.mark("shotlog.presets")
  tip(PresetsTip)
  if ui.draftNote.len > 0:
    dim(ui.draftNote, t)
    marks.mark("shotlog.timenote " & ui.draftNote)
    tip(TimeSourceTip)
  igTextUnformatted("Missing values, one per line", nil)
  if igInputTextMultiline("##sentinels", cast[cstring](addr ui.sentinels[0]),
      csize_t(ui.sentinels.len), ImVec2_c(x: -1, y: igGetTextLineHeight() * 4), 0, nil, nil):
    ui.draftDirty = true
  marks.mark("shotlog.sentinels")
  let tableH = max(igGetTextLineHeight() * 6,
    igGetContentRegionAvail().y - igGetFrameHeightWithSpacing())
  if igBeginTable("shotlog.columns", 4, ImGui_TableFlags_RowBg.cint or
      ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_ScrollY.cint or
      ImGui_TableFlags_SizingStretchProp.cint, ImVec2_c(x: 0, y: tableH), 0):
    igTableSetupColumn("Column", 0, 0, 0)
    igTableSetupColumn("First values", 0, 0, 1)
    igTableSetupColumn("Meaning", 0, 0, 2)
    igTableSetupColumn("Name", 0, 0, 3)
    igTableHeadersRow()
    for c in 0 ..< width:
      igTableNextRow(0, 0)
      igPushID_Int(cint(c))
      discard igTableNextColumn()
      let name = st.shotLogColumn(i, c)
      igTextUnformatted((if name.len > 0: name else: "Column " & $(c + 1)).cstring, nil)
      marks.mark("shotlog.role " & $c & " " & label(ui.draft.roles[c]))
      discard igTableNextColumn()
      var sample = ""
      for r in 0 ..< min(3, st.shotView(i).rows.len):
        if r > 0: sample.add " | "
        sample.add st.shotCell(i, r, c)
      igTextUnformatted(sample.cstring, nil)
      discard igTableNextColumn()
      let was = ui.draft.roles[c]
      if roleCombo(c, ui.draft.roles[c], marks):
        ui.draftDirty = true
        if ui.draft.roles[c] == crTime and was != crTime and bufText(ui.pattern).strip.len == 0:
          # a column of Unix times chosen as Time (UTC) starts with its form filled in
          ui.readDraft()
          setText(ui.pattern, st.shotLogEpochPreset(i, ui.draft, c))
      discard igTableNextColumn()
      if ui.draft.roles[c] == crText:
        igSetNextItemWidth(-1)
        if igInputTextWithHint(("##name" & $c).cstring, ui.draftNames[c].cstring,
            cast[cstring](addr ui.nameBufs[c][0]), csize_t(NameRoom), 0, nil, nil):
          ui.draftDirty = true
        marks.mark("shotlog.name " & $c)
        marks.mark("shotlog.nametext " & $c & " " & bufText(ui.nameBufs[c]))
        tip(NameTip)
        for bad in ui.draftNameFaults:
          if bad.col == c:
            wrapped(bad.why, t.roles[rlWarning])
            marks.mark("shotlog.nameproblem " & $c)
      igPopID()
    igEndTable()
  igBeginDisabled(busy or fault.len > 0)
  if igButton(ApplyButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
      not busy and fault.len == 0:
    ui.readDraft()
    result.add Command(kind: ckRemapShotLog, logIndex: i, logMap: ui.draft)
    ui.columnsOpen = false
  igEndDisabled()
  marks.mark("shotlog.apply")
  tip(if busy: "A read is under way"
      elif fault.len > 0: fault
      else: "Read the table again with this map")
  igSameLine(0, -1)
  if igButton(CancelButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
    ui.columnsOpen = false
  marks.mark("shotlog.cancel")
  tip("Leave the map as it was")
  igSameLine(0, -1)
  igBeginDisabled(busy)
  if igButton(GuessButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and not busy:
    ui.loadDraft(st.shotLogGuess(i), width)
  igEndDisabled()
  marks.mark("shotlog.guess")
  tip("Fill the map from the header names and the first rows")

proc commitEdit(ui: var ShotLogUi; i, width, n: int; st: AppState; advance: bool;
    commands: var seq[Command]) =
  let text = ui.editText
  let row = ui.editRow
  let col = ui.editCol
  if hasBreak(text):
    ui.editReason = ShotLogLineBreak
    ui.armEdit = true
    commands.add Command(kind: ckEditShotCell, logIndex: i, logRow: row, logCol: col,
      logCell: text)
    return
  commands.add Command(kind: ckEditShotCell, logIndex: i, logRow: row, logCol: col,
    logCell: text)
  if advance:
    let nxt = ui.nextListed(row, col, n)
    if nxt.row >= 0:
      ui.pending = true
      ui.pendingRow = nxt.row
      ui.pendingCol = nxt.col
      ui.scrollTo = nxt.row
  ui.editing = false
  ui.editReason = ""

proc cornerMark(t: Theme) =
  let mn = igGetItemRectMin()
  let mx = igGetItemRectMax()
  let s = igGetFontSize() * 0.4
  ImDrawList_AddTriangleFilled(igGetWindowDrawList(),
    ImVec2_c(x: mx.x, y: mn.y),
    ImVec2_c(x: mx.x - s, y: mn.y),
    ImVec2_c(x: mx.x, y: mn.y + s),
    u32(t.roles[rlHighlight]))

proc cellBox(text: string; acts: bool; copy = true): tuple[clicked, copied: bool] =
  let shown = if text.len == 0: " " else: text
  if igSelectable_Bool((shown & "##c").cstring, false, 0, ImVec2_c(x: 0, y: 0)) and acts:
    result.clicked = true
  if copy and igIsItemClicked(ImGui_MouseButton_Right.cint) and acts:
    igSetClipboardText(text.cstring)
    result.copied = true

proc drawEditor(ui: var ShotLogUi; i, width, n: int; st: AppState; t: Theme;
    marks: var Marks; commands: var seq[Command]) =
  igBeginGroup()
  if ui.armEdit:
    igSetKeyboardFocusHere(0)
    ui.armEdit = false
  igSetNextItemWidth(-1)
  let h = igGetTextLineHeight() + igGetStyle().FramePadding.y * 2
  let flags = ImGui_InputTextFlags_EnterReturnsTrue.cint or
    ImGui_InputTextFlags_CtrlEnterForNewLine.cint or
    ImGui_InputTextFlags_AutoSelectAll.cint or
    ImGui_InputTextFlags_CallbackAlways.cint
  let entered = igInputTextMultiline("##edit", cast[cstring](addr ui.editBuf[0]),
    csize_t(ui.editBuf.len), ImVec2_c(x: 0, y: h), flags, selectEditedCell, nil)
  marks.mark("shotlog.editbox")
  marks.mark("shotlog.edittext " & ui.editText)
  let escape = igIsKeyPressed_Bool(ImGui_Key_Escape, false)
  let tab = igIsKeyPressed_Bool(ImGui_Key_Tab, false) and not igGetIO_Nil().KeyShift
  if entered or tab:
    ui.commitEdit(i, width, n, st, tab, commands)
  elif escape or igIsItemDeactivated():
    ui.stopEdit()
  if ui.editReason.len > 0:
    wrapped(ui.editReason, t.roles[rlWarning])
    marks.mark("shotlog.editreason")
  igEndGroup()

proc drawGrid(ui: var ShotLogUi; st: AppState; i, width, n: int; t: Theme;
    marks: var Marks): seq[Command] =
  if not ui.allowEditing:
    if ui.editing or ui.pending: ui.stopEdit()
  elif ui.pending and not ui.editing:
    ui.beginEdit(ui.pendingRow, ui.pendingCol, st.shotCell(i, ui.pendingRow, ui.pendingCol))
    ui.scrollTo = ui.pendingRow
  ui.scanFilter(st, i, width, n)
  ui.refreshSorted()
  let listed = ui.listedCount(n)
  if ui.sortCols.len > 0 and not ui.haveOrder:
    dim(SortingNote, t)
    marks.mark("shotlog.sorting")
  marks.mark("shotlog.sort " & ui.sortText)
  marks.mark("shotlog.built " & $ui.orderStamp)
  if ui.needle.len > 0 and not ui.filterDone:
    dim("Filtering...", t)
    marks.mark("shotlog.filtering")
  elif ui.needle.len > 0:
    marks.mark("shotlog.filtered " & $listed)
  if ui.problemsOnly: marks.mark("shotlog.problemsonly")
  if ui.onlySelected:
    let line = if listed == 0: NoRowsSelected else: countText(listed, n)
    dim(line, t)
    marks.mark("shotlog.only " & line)
  marks.mark("shotlog.listed " & $listed)
  marks.mark("shotlog.marked " & $ui.chosenRows.by & " " & $ui.chosenRows.rows.len)
  let font = igGetFontSize()
  let flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint
  if not igBeginChild_Str("##grid", ImVec2_c(x: 0, y: 0), 0, 0):
    igEndChild() # always, as Dear ImGui asks (a tab that is hidden or tiny)
    return
  marks.markWindow("shotlog.grid")
  let map = st.shotLogMap(i)
  let names = st.shotLogNames(i, map, width)
  let shown = ui.visible ## the columns shown, in the order shown
  var changed = false ## the layout changed: kept
  var regen = false ## ... and the table is made anew
  if not igBeginTable(("shotlog.grid" & $ui.gridGen).cstring, cint(2 + shown.len), flags,
      ImVec2_c(x: 0, y: 0), 0):
    igEndChild()
    return
  inc ui.gridAge
  igTableSetupScrollFreeze(2, 2)
  igTableSetupColumn(TimeHeader.cstring, ImGui_TableColumnFlags_WidthFixed.cint, font * 16, 0)
  igTableSetupColumn(StatusHeader.cstring, ImGui_TableColumnFlags_WidthFixed.cint, font * 2, 1)
  var widthOf = initTable[int, float32]() ## each shown column's width, in pixels
  for c in shown:
    var w = font * DefaultColumnEm
    for p in ui.placed:
      if p.col == c:
        w = if p.width > 0: p.width * font
            else: max(w, textWidth(names[c]) + font * 2.5)
    widthOf[c] = w
    igTableSetupColumn(names[c].cstring, ImGui_TableColumnFlags_WidthFixed.cint, w,
      ImGuiID(10 + c))
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  var dragFrom = -1
  var dragTo = -1
  for k in 0 ..< 2 + shown.len:
    if not igTableSetColumnIndex(cint(k)): continue
    let col = if k < 2: -1 else: shown[k - 2]
    let name = if k == 0: TimeHeader elif k == 1: StatusHeader else: names[col]
    var label = name
    var place = 0
    for at, sc in ui.sortCols:
      if sc.col == col and col >= 0:
        place = at + 1
        label.add " " & (if sc.descending: IconArrowDown else: IconArrowUp)
        if ui.sortCols.len > 1: label.add $place
    igPushID_Int(cint(k))
    let avail = igGetContentRegionAvail().x
    let hit = igSelectable_Bool((label & "##head").cstring, false, 0,
      ImVec2_c(x: avail, y: 0)) and ui.focus.acts
    if k >= 2: marks.mark("shotlog.header " & name)
    else: marks.mark("shotlog.header " & (if k == 0: TimeHeader else: "status"))
    if place > 0:
      marks.mark("shotlog.headersort " & name & " " & $place &
        (if ui.sortCols[place - 1].descending: " down" else: " up"))
    if k == 2: tip(SortTip)
    if k >= 2:
      let io = igGetIO_Nil()
      if hit and io.MouseDragMaxDistanceSqr[0] < 25:
        clickSort(ui.sortCols, col, io.KeyShift)
        changed = true
      if igBeginDragDropSource(0):
        var from0 = int32(k - 2)
        discard igSetDragDropPayload("SHOTLOGCOL", addr from0, csize_t(sizeof(int32)), 0)
        igTextUnformatted(name.cstring, nil)
        igEndDragDropSource()
      if igBeginDragDropTarget():
        let payload = igAcceptDragDropPayload("SHOTLOGCOL", 0)
        if payload != nil:
          dragFrom = int(cast[ptr int32](payload.Data)[])
          dragTo = k - 2
        igEndDragDropTarget()
      # the width the user dragged the column to
      let now = (avail + 2 * igGetStyle().CellPadding.x) / font
      var cur = widthOf[col] / font
      if ui.gridAge > 3 and abs(now - cur) * font > 1.5 and not igIsMouseDown_Nil(0):
        for p in ui.placed.mitems:
          if p.col == col: p.width = float32(now)
        changed = true
    if igBeginPopupContextItem("##headmenu", ImGui_PopupFlags_MouseButtonRight.cint):
      if k >= 2 and igMenuItem_Bool(HideColumn.cstring, nil, false, true):
        for p in ui.placed.mitems:
          if p.col == col: p.hidden = true
        changed = true
        regen = true
      igBeginDisabled(ui.sortCols.len == 0)
      if igMenuItem_Bool(ClearSort.cstring, nil, false, true):
        ui.sortCols.setLen 0
        changed = true
      igEndDisabled()
      marks.mark("shotlog.menu.clearsort")
      if igMenuItem_Bool(ResetColumns.cstring, nil, false, true):
        ui.placed = ShotLayout().places(ui.keys, ui.eligible(st, i))
        changed = true
        regen = true
      marks.mark("shotlog.menu.reset")
      igSeparator()
      igTextDisabled(ShowColumnsHead.cstring)
      for pi, p in ui.placed.mpairs:
        var on = not p.hidden
        if igMenuItem_Bool((ui.keys[p.col] & "##show" & $pi).cstring, nil, on, true):
          p.hidden = not p.hidden
          changed = true
          regen = true
        marks.mark("shotlog.menu.col " & ui.keys[p.col] & (if on: " shown" else: " hidden"))
      igEndPopup()
    igPopID()
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(t.roles[rlTextDim]))
  for k in 0 ..< 2 + shown.len:
    if igTableSetColumnIndex(cint(k)):
      let col = if k < 2: -1 else: shown[k - 2]
      let role = if k < 2: "" elif col < map.roles.len: label(map.roles[col])
                 else: label(crText)
      let header = if col >= 0 and role != label(crText): st.shotLogColumn(i, col) else: ""
      igTextUnformatted((if header.len > 0: header else: role).cstring, nil)
      if k >= 2: marks.mark("shotlog.role " & $col & " " & role)
  igPopStyleColor(1)
  if dragFrom >= 0 and dragTo >= 0 and dragFrom != dragTo and dragFrom < shown.len:
    # the dragged column takes the place of the one it was dropped on
    let moving = shown[dragFrom]
    let target = shown[dragTo]
    var at = 0
    for q, p in ui.placed:
      if p.col == moving: at = q
    let one = ui.placed[at]
    ui.placed.delete at
    var into = 0
    for q, p in ui.placed:
      if p.col == target: into = q
    if dragTo > dragFrom: inc into
    ui.placed.insert(one, into)
    changed = true
    regen = true
  let highlight = u32(withAlpha(t.roles[rlHighlight], 70))
  let hoverMark = u32(withAlpha(t.roles[rlHighlight], 40))
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(listed), -1)
  let jump = ui.listedIndex(ui.scrollTo, n)
  if jump >= 0: ImGuiListClipper_IncludeItemByIndex(clipper, cint(jump))
  if ui.editing:
    let at = ui.listedIndex(ui.editRow, n)
    if at >= 0: ImGuiListClipper_IncludeItemByIndex(clipper, cint(at))
  var edge = -1
  let delim = st.shotLogMap(i).delimiter
  while ImGuiListClipper_Step(clipper):
    for at in clipper.DisplayStart ..< clipper.DisplayEnd:
      let row = ui.listedRow(at)
      edge = row
      igTableNextRow(0, 0)
      igPushID_Int(cint(row))
      if row == ui.selected or ui.chosenRows.isChosen(row):
        igTableSetBgColor(ImGui_TableBgTarget_RowBg1.cint,
          if ui.chosenRows.by == rbPointer: hoverMark else: highlight, -1)
      let us = st.shotView(i).rows[row].timeUtcUs
      let time = if us.isNone: "" else: utcMicrosText(us.get)
      discard igTableNextColumn()
      igPushID_Int(-1)
      let timeHit = cellBox(time, ui.focus.acts)
      igPopID()
      if timeHit.clicked:
        ui.selected = row
        ui.selectedCol = -1
        result.add ui.chooseRow(row)
      if row == 0: marks.mark("shotlog.time 0 " & time)
      marks.mark("shotlog.row " & $row)
      discard igTableNextColumn()
      let fault = if ui.faultText.hasKey(row): ui.faultText[row] else: ""
      igPushID_Int(-2)
      let statusHit = cellBox(if fault.len > 0: IconWarning else: "", ui.focus.acts)
      igPopID()
      if statusHit.clicked:
        ui.selected = row
        ui.selectedCol = -1
        result.add ui.chooseRow(row)
      if fault.len > 0: tip(fault)
      for slot, c in shown:
        if igTableSetColumnIndex(cint(2 + slot)):
          igPushID_Int(cint(c))
          let text = st.shotCell(i, row, c)
          let editing = ui.editing and row == ui.editRow and c == ui.editCol
          if editing:
            ui.drawEditor(i, width, n, st, t, marks, result)
          else:
            let differs = st.shotCellDiffers(i, row, c)
            if differs:
              igTableSetBgColor(ImGui_TableBgTarget_CellBg.cint, highlight, -1)
            let hit = cellBox(text, ui.focus.acts, not differs)
            if hit.clicked:
              ui.selected = row
              ui.selectedCol = c
              result.add ui.chooseRow(row)
            let dbl = ui.allowEditing and igIsItemHovered(0) and
              igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint) and ui.focus.acts
            if dbl: ui.beginEdit(row, c, text)
            if differs:
              if igBeginPopupContextItem(nil, ImGui_PopupFlags_MouseButtonRight.cint):
                if igMenuItem_Bool("Copy", nil, false, true):
                  igSetClipboardText(text.cstring)
                if ui.allowEditing and igMenuItem_Bool(RevertCell.cstring, nil, false, true):
                  result.add Command(kind: ckEditShotCell, logIndex: i, logRow: row,
                    logCol: c, logCell: st.shotFileCell(i, row, c))
                igEndPopup()
              cornerMark(t)
              marks.mark("shotlog.edited " & $row & " " & $c)
              tip(st.shotFileCell(i, row, c))
          igPopID()
          if row == 0: marks.mark("shotlog.cell 0 " & $c & " " & text)
      if row == ui.selected: marks.mark("shotlog.at " & $row)
      if ui.chosenRows.isChosen(row): marks.mark("shotlog.chosen " & $ui.chosenRows.by & " " & $row)
      if row == ui.scrollTo:
        if not igIsItemVisible(): igSetScrollHereY(0.5)
        ui.scrollTo = -1
      igPopID()
  if edge >= 0: marks.mark("shotlog.edge " & $edge)
  igEndTable()
  if changed:
    ui.layout = ui.layoutNow()
    if regen:
      ui.placeVisible()
      inc ui.gridGen
      ui.gridAge = 0
    result.add Command(kind: ckShotLayout, slogIndex: i, slogLayout: ui.layout)
  if ui.selected >= 0 and igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
      not igGetIO_Nil().WantTextInput and igGetIO_Nil().KeyCtrl and
      igIsKeyPressed_Bool(ImGui_Key_C, false):
    copyRow(st, i, ui.selected, width, delim)
  if ui.allowEditing and not ui.editing and ui.selected >= 0 and ui.selectedCol >= 0 and
      ui.selectedCol < width and
      igIsWindowFocused(ImGui_FocusedFlags_RootAndChildWindows.cint) and
      not igGetIO_Nil().WantTextInput and igIsKeyPressed_Bool(ImGui_Key_F2, false):
    ui.scrollTo = ui.selected
    ui.beginEdit(ui.selected, ui.selectedCol, st.shotCell(i, ui.selected, ui.selectedCol))
  igEndChild()

proc drawProblems(ui: var ShotLogUi; st: AppState; i: int; t: Theme; marks: var Marks) =
  let list = st.shotView(i).problems
  if list.items.len == 0:
    dim(EmptyProblems, t)
    marks.mark("shotlog.noproblems")
    return
  if list.count > list.items.len: dim(CappedNote, t)
  for p in list.items:
    let line = if p.row >= 0: "row " & $(p.row + 1) else: "log"
    igPushID_Int(cint(p.row))
    if igButton(line.cstring, ImVec2_c(x: 0, y: 0)) and p.row >= 0:
      ui.selected = p.row
      ui.scrollTo = p.row
      ui.tab = 0
      ui.forceGrid = true
    igPopID()
    if p.row >= 0: marks.mark("shotlog.problem " & $p.row)
    tip("Show this row in the grid")
    igSameLine(0, -1)
    igTextUnformatted(p.text.cstring, nil)

proc drawShotLog*(ui: var ShotLogUi; title: string; st: var AppState; t: Theme;
    marks: var Marks): seq[Command] =
  ## The window, titled `title`, while it is open. Edits and a re-map are commands.
  ui.follow(st)
  let i = st.findShotLog(ui.currentId)
  let rev = if i >= 0: st.shotRevision(i) else: -1
  ui.bindLog(st, i, rev)
  if beginClosable(awShotLog, title.cstring):
    ui.focus.watch()
    marks.markWindow("shotlog")
    let where = whereOf(st)
    let reading = st.shotLogReading() or (i >= 0 and st.shotLogBusy(i))
    if i < 0:
      let line = if reading: Reading & " " & where else: NoLog & " " & where
      igTextUnformatted(line.cstring, nil)
      marks.mark("shotlog.summary " & line)
      if reading: marks.mark("shotlog.reading")
    else:
      let width = st.shotLogWidth(i)
      let n = st.shotView(i).rows.len
      ui.syncLayout(st, i, width, rev)
      ui.ensureOrder(st, i, n, rev)
      let followLine = ui.noteFollow(st, i, width, n)
      ui.markChosen(st, i, width, n)
      let problems = st.shotView(i).problems.count
      let file = st.shotLogSource(i).extractFilename
      let name = if file.len > 0: file else: st.shotLogName(i)
      var line = shotLogSummary(name, n, width, problems, where)
      if st.inProject and st.project.readOnly:
        line.add " · "
        line.add ReadOnlyShotLog
      igAlignTextToFramePadding()
      if ui.allowEditing:
        igBeginDisabled(st.shotUndoCount(i) == 0)
        if igButton((IconUndo & "##undoshot").cstring, ImVec2_c(x: 0, y: 0)) and
            ui.focus.acts:
          result.add Command(kind: ckUndoShotEdit, logIndex: i)
        igEndDisabled()
        marks.mark("shotlog.undo")
        tip(UndoCellTip)
        igSameLine(0, -1)
        igBeginDisabled(st.shotRedoCount(i) == 0)
        if igButton((IconRedo & "##redoshot").cstring, ImVec2_c(x: 0, y: 0)) and
            ui.focus.acts:
          result.add Command(kind: ckRedoShotEdit, logIndex: i)
        igEndDisabled()
        marks.mark("shotlog.redo")
        tip(RedoCellTip)
        igSameLine(0, -1)
      igTextUnformatted(line.cstring, nil)
      marks.mark("shotlog.summary")
      marks.mark("shotlog.summary " & line)
      if reading:
        dim(Reading, t)
        marks.mark("shotlog.reading")
      if st.shotLogCount > 1:
        igSetNextItemWidth(igGetFontSize() * 16)
        let shown = st.shotLogName(i)
        if igBeginCombo("##logs", shown.cstring, 0):
          for k in 0 ..< st.shotLogCount:
            let id = st.shotLogId(k)
            if igSelectable_Bool(st.shotLogName(k).cstring, id == ui.currentId, 0,
                ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
              ui.currentId = id
              ui.seenMax = max(ui.seenMax, id)
            marks.mark("shotlog.log " & $id)
          igEndCombo()
        marks.mark("shotlog.logs")
      igSetNextItemWidth(igGetFontSize() * 14)
      discard igInputText("##filter", cast[cstring](addr ui.filter[0]),
        csize_t(ui.filter.len), 0, nil, nil)
      marks.mark("shotlog.filter")
      tip("Show rows whose cells hold this text")
      let typed = bufText(ui.filter).strip
      if typed != ui.filterText:
        ui.filterText = typed
        ui.needle = typed.toLowerAscii
        ui.resetScan()
      sameLineIfFits(checkWidth(ProblemsOnly))
      var only = ui.problemsOnly
      if igCheckbox(ProblemsOnly.cstring, addr only) and ui.focus.acts:
        ui.problemsOnly = only
        ui.resetScan()
      marks.mark("shotlog.problemsbox")
      sameLineIfFits(checkWidth(OnlySelected))
      var onlyChosen = ui.onlySelected
      if igCheckbox(OnlySelected.cstring, addr onlyChosen) and ui.focus.acts:
        ui.onlySelected = onlyChosen
      marks.mark("shotlog.onlybox")
      if ui.onlySelected: marks.mark("shotlog.onlyon")
      tip(OnlySelectedTip)
      sameLineIfFits(checkWidth(AllowEditing))
      var allow = ui.allowEditing
      if igCheckbox(AllowEditing.cstring, addr allow) and ui.focus.acts:
        ui.allowEditing = allow
        if not allow: ui.stopEdit()
      marks.mark("shotlog.allowbox")
      if ui.allowEditing: marks.mark("shotlog.allowon")
      tip(AllowEditingTip)
      sameLineIfFits(checkWidth(FollowPlot))
      var follow = st.settings.shotLog.followPlot
      if igCheckbox(FollowPlot.cstring, addr follow) and ui.focus.acts:
        var s = st.settings
        s.shotLog.followPlot = follow
        result.add Command(kind: ckSettings, settings: s)
      marks.mark("shotlog.followbox")
      if st.settings.shotLog.followPlot: marks.mark("shotlog.followon")
      tip(FollowPlotTip)
      sameLineIfFits(checkWidth(FollowPointer))
      var pointer = st.settings.headers.followPointer
      if igCheckbox(FollowPointer.cstring, addr pointer) and ui.focus.acts:
        var s = st.settings
        s.headers.followPointer = pointer
        result.add Command(kind: ckSettings, settings: s)
      marks.mark("shotlog.pointerbox")
      if st.settings.headers.followPointer: marks.mark("shotlog.pointeron")
      tip(FollowPointerTip)
      sameLineIfFits(buttonWidth(ColumnsButton))
      igBeginDisabled(reading)
      if igButton(ColumnsButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
          not reading:
        if not ui.columnsOpen: ui.loadDraft(st.shotLogMap(i), width)
        ui.columnsOpen = true
      igEndDisabled()
      marks.mark("shotlog.columns")
      tip("How the table was read, and what each column means")
      sameLineIfFits(buttonWidth(ExportSpsButton))
      ui.countSpsRows(st, i, rev)
      let spsWhy = if reading: SpsReading
                   elif ui.spsRows == 0: NoSpsRows
                   else: ""
      igBeginDisabled(spsWhy.len > 0)
      if igButton(ExportSpsButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
          spsWhy.len == 0:
        if not ui.spsReady:
          let o = initShotSpsOptions()
          ui.spsRevision = o.revision
          ui.spsIndex = int32(o.defaultIndex)
          ui.spsReady = true
        ui.spsOpen = not ui.spsOpen
      igEndDisabled()
      marks.mark("shotlog.exportsps")
      if spsWhy.len > 0: marks.mark("shotlog.exportsps.dim")
      tip(if spsWhy.len > 0: spsWhy else: ExportSpsTip)
      if followLine.len > 0:
        igSameLine(0, -1)
        igAlignTextToFramePadding()
        rightAlign(followLine)
        igTextUnformatted(followLine.cstring, nil)
        marks.mark("shotlog.followline " & followLine)
      if ui.spsOpen and not ui.columnsOpen: result.add ui.drawSps(st, i, t, marks)
      if ui.columnsOpen:
        result.add ui.drawColumns(st, i, t, marks, reading)
      else:
        if igBeginTabBar("shotlog.tabs", 0):
          let gridFlags = if ui.forceGrid: ImGui_TabItemFlags_SetSelected.cint else: 0
          let gridOn = igBeginTabItem(GridTab.cstring, nil, gridFlags)
          marks.mark("shotlog.tab Grid")
          if gridOn:
            ui.forceGrid = false
            ui.tab = 0
            result.add ui.drawGrid(st, i, width, n, t, marks)
            igEndTabItem()
          let problemsOn = igBeginTabItem(ProblemsTab.cstring, nil, 0)
          marks.mark("shotlog.tab Problems")
          if problemsOn:
            ui.tab = 1
            ui.drawProblems(st, i, t, marks)
            igEndTabItem()
          igEndTabBar()
    if i >= 0 and ui.allowEditing and ui.focus.focused and
        not igGetIO_Nil().WantTextInput:
      let io = igGetIO_Nil()
      if io.KeyCtrl and igIsKeyPressed_Bool(ImGui_Key_Z, false):
        if io.KeyShift:
          result.add Command(kind: ckRedoShotEdit, logIndex: i)
        else:
          result.add Command(kind: ckUndoShotEdit, logIndex: i)
      elif io.KeyCtrl and igIsKeyPressed_Bool(ImGui_Key_Y, false):
        result.add Command(kind: ckRedoShotEdit, logIndex: i)
    ui.focus.settle()
  else:
    ui.focus.blur()
  igEnd()
