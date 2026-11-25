## The Vibrator QC window: the signature files of a folder or files the user
## picks (subfolders only when asked), a run against the project's vibrator QC
## configuration, and a CSV export. The window asks for no setting: it shows
## the configuration in force, or says that QC is not configured. The results
## table leaves room under it for the selected row.
##
## Listing and judging are background jobs. The window reads a sink only after
## that job is no longer running. The worker must not read `AppState`: the
## configuration is copied before the job starts.

import std/[os, strutils, tables]
import imguin/cimgui
import ../../core/[filesystem, jobs, state, vibfolderconf, vibfolderjobs, vibfolderqc]
import ../../view/vibfolderwords
import fittext, focus, icons, marks, overflow

type
  VibTab = enum
    vtFiles, vtResults

  VibFolderUi* = object
    listJob: JobId = NoJob
    qcJob: JobId = NoJob
    exportJob: JobId = NoJob
    sink: FolderQcSink
    listSink: FolderListSink
    choice: FolderChoice
    listed: seq[FolderListed]
    unticked: Table[string, bool] = initTable[string, bool]()
    table: FolderTable
    haveList: bool
    have: bool
    listing: bool
    running: bool
    capped: bool
    wantList: bool
    askFolder, askFiles: bool
    dropJobs: bool
    selectResults: bool
    tab: VibTab = vtFiles
    sortCol: FolderColumn = fcPath
    sortDown: bool
    progressDone: int64
    progressTotal: int64
    status: string
    filterBuf: array[128, char]
    selected: string
    focus: FocusClicks
    shownGen: int
    viewKey: string
    shotKey: string
    viewRows: seq[FolderRow]
    viewCells: seq[seq[string]]
    viewWidths: seq[float32]
    viewBuilds: int

  VibFolderOutput* = object
    commands*: seq[Command]
    exportAsked*: bool
    exportPath*: string
    askFolder*, askFiles*: bool ## a native dialog is wanted, starting at `askAt`
    askAt*: string
    closed*: bool               ## the window's close button was used: hide it as the Window menu does

proc stopJobs(ui: var VibFolderUi; st: AppState)

proc clearRun(ui: var VibFolderUi) =
  ui.listed.setLen 0
  ui.haveList = false
  ui.have = false
  ui.table = FolderTable()
  inc ui.shownGen
  ui.viewKey = ""
  ui.selected = ""
  ui.unticked = initTable[string, bool]()
  ui.selectResults = false
  ui.tab = vtFiles
  ui.capped = false
  ui.progressDone = 0
  ui.progressTotal = 0

proc choose(ui: var VibFolderUi; choice: FolderChoice) =
  ui.choice = choice
  ui.dropJobs = true
  ui.clearRun()
  ui.wantList = choice.hasChoice
  ui.status = if choice.hasChoice: Listing else: NothingChosen

proc setFolder*(ui: var VibFolderUi; folder: string) =
  ## The folder dialog's answer (or a test's): the folder to run replaces the
  ## choice, and is listed on the next draw. The tick for subfolders is kept.
  ui.choose(FolderChoice(folder: folder, subfolders: ui.choice.subfolders))

proc setFiles*(ui: var VibFolderUi; files: seq[string]) =
  ## The files dialog's answer (or a test's): these files replace the choice.
  ui.choose(FolderChoice(files: files, subfolders: ui.choice.subfolders))

proc setSubfolders*(ui: var VibFolderUi; on: bool) =
  ## Whether the chosen folder's subfolders are run too; the folder is listed again.
  if on == ui.choice.subfolders: return
  var next = ui.choice
  next.subfolders = on
  ui.choose(next)

proc writeCsv(path, text: string) =
  ## `text` written to `path`: a temporary file beside it, then a rename.
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  var f: syncio.File
  if not fs.open(f, tmp, fmWrite):
    raise newException(IOError, "cannot write " & tmp)
  try:
    if text.len > 0 and
        fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
      raise newException(IOError, "the disk did not take " & tmp)
    flushFile(f)
  finally:
    close(f)
  try:
    fs.moveFile(tmp, path)
  except OSError as e:
    discard fs.tryRemoveFile(tmp)
    raise newException(IOError, e.msg)
  except IOError:
    discard fs.tryRemoveFile(tmp)
    raise

proc exportWork(path, text: string): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    writeCsv(path, text)

proc finishList(ui: var VibFolderUi; state: JobState; error: string) =
  ui.listing = false
  if ui.listSink != nil: ui.capped = ui.listSink.capped
  if state == jsCancelled:
    ui.status = Stopped
    return
  if state == jsFailed:
    ui.status = if error.len > 0: error else: CannotList
    return
  if ui.listSink != nil: ui.listed = ui.listSink.files
  ui.haveList = true
  ui.status = Ready

proc finishQc(ui: var VibFolderUi; state: JobState; error: string) =
  ui.running = false
  if ui.sink != nil:
    ui.table = ui.sink.result
    inc ui.shownGen
    ui.viewKey = ""
    ui.shotKey = ""
    ui.have = true
    ui.selectResults = true
  if state == jsCancelled: ui.status = Stopped
  elif state == jsFailed:
    ui.status = if error.len > 0: error else: RunFailed
  else: ui.status = Ready

proc poll(ui: var VibFolderUi; st: AppState) =
  if ui.listJob != NoJob:
    let info = st.jobs.info(ui.listJob)
    if info.isNone:
      ui.listJob = NoJob
      ui.listing = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.listing = true
      let p = info.get.progress
      ui.status = if p.phase.len > 0: p.phase else: Listing
    else:
      ui.finishList(info.get.state, info.get.error)
      ui.listJob = NoJob
  if ui.qcJob != NoJob:
    let info = st.jobs.info(ui.qcJob)
    if info.isNone:
      ui.qcJob = NoJob
      ui.running = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.running = true
      let p = info.get.progress
      ui.progressDone = p.done
      ui.progressTotal = p.total
      ui.status = if p.phase.len > 0: p.phase else: Judging
    else:
      ui.finishQc(info.get.state, info.get.error)
      ui.qcJob = NoJob
  if ui.exportJob != NoJob:
    let info = st.jobs.info(ui.exportJob)
    if info.isNone: ui.exportJob = NoJob
    elif info.get.state notin {jsQueued, jsRunning}:
      if info.get.state == jsDone: ui.status = Written
      elif info.get.state == jsFailed:
        ui.status = if info.get.error.len > 0: info.get.error else: ExportFailed
      ui.exportJob = NoJob

proc submitList(ui: var VibFolderUi; st: AppState) =
  if not ui.choice.hasChoice: return
  if ui.listJob != NoJob:
    discard st.jobs.cancel(ui.listJob)
    ui.listJob = NoJob
  ui.listSink = FolderListSink()
  ui.listing = true
  ui.haveList = false
  ui.status = Listing
  ui.listJob = st.jobs.submit(folderListSpec(ui.choice),
    folderListWork(ui.choice, ui.listSink))

proc stopJobs(ui: var VibFolderUi; st: AppState) =
  if ui.listJob != NoJob:
    discard st.jobs.cancel(ui.listJob)
    ui.listJob = NoJob
    ui.listing = false
  if ui.qcJob != NoJob:
    discard st.jobs.cancel(ui.qcJob)
    ui.qcJob = NoJob
    ui.running = false

proc consider(ui: var VibFolderUi; st: AppState) =
  if ui.dropJobs:
    ui.stopJobs(st)
    ui.dropJobs = false
  ui.poll(st)
  if ui.wantList and ui.choice.hasChoice:
    ui.wantList = false
    ui.submitList(st)

proc ticked(ui: VibFolderUi): seq[FolderListed] =
  result = @[]
  for item in ui.listed:
    if item.path notin ui.unticked: result.add item

proc submitQc(ui: var VibFolderUi; st: AppState) =
  if ui.listJob != NoJob or not ui.haveList: return
  let config = vibQcConfig(st)
  if not config.configured:
    ui.status = NotConfigured
    return
  let files = ui.ticked
  if files.len == 0:
    ui.status = NoTicked
    return
  if ui.qcJob != NoJob:
    discard st.jobs.cancel(ui.qcJob)
    ui.qcJob = NoJob
  ui.sink = FolderQcSink()
  ui.running = true
  ui.have = false
  ui.progressDone = 0
  ui.progressTotal = 0
  ui.status = Judging
  ui.qcJob = st.jobs.submit(folderQcSpec(files, config.reference.path),
    folderQcWork(config.ask, config.weights, files, ui.sink,
    reference = config.reference))

proc startExport*(ui: var VibFolderUi; st: AppState; path: string) =
  ## Writes the full table, not the filtered rows. `path` gains ".csv" when
  ## it has no extension.
  if not ui.have: return
  var dest = path
  if dest.splitFile.ext.len == 0: dest.add ".csv"
  let text = resultsCsv(ui.table)
  if ui.exportJob != NoJob:
    discard st.jobs.cancel(ui.exportJob)
    ui.exportJob = NoJob
  let reads = if ui.choice.folder.len > 0: ui.choice.folder else: dest
  ui.exportJob = st.jobs.submit(JobSpec(title: "Export vibrator QC",
    lane: jlBackground, reads: @[reads]), exportWork(dest, text))

proc tip(text: string; allowDisabled = false) =
  if text.len == 0: return
  var flags = ImGui_HoveredFlags_ForTooltip.cint
  if allowDisabled: flags = flags or ImGui_HoveredFlags_AllowWhenDisabled.cint
  if igIsItemHovered(flags) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc bufText(buf: openArray[char]): string =
  result = ""
  for c in buf:
    if c == '\0': break
    result.add c

proc reversedRows(rows: seq[FolderRow]): seq[FolderRow] =
  result = newSeq[FolderRow](rows.len)
  for i, row in rows:
    result[rows.len - 1 - i] = row

proc viewOf(ui: VibFolderUi): FolderTable =
  result = sortedBy(ui.table, [ui.sortCol])
  if ui.sortDown: result.rows = reversedRows(result.rows)
  result = filtered(result, bufText(ui.filterBuf))

proc showRows*(ui: var VibFolderUi; rows: seq[FolderRow]) =
  ## Shows `rows` as the results, without a run. For tests.
  ui.table = FolderTable(rows: rows, totals: totalsOf(rows))
  ui.have = true
  ui.selectResults = true
  ui.filterBuf[0] = '\0'
  inc ui.shownGen
  ui.viewKey = ""
  ui.shotKey = ""

proc viewBuilds*(ui: VibFolderUi): int =
  ## How many times the shown rows were built. For tests.
  ui.viewBuilds

proc verdictWord(row: FolderRow): string =
  case row.outcome
  of foJudged: $row.verdict
  of foProblem: "problem"
  of foSkipped: "skipped"

const
  tableFlags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint
  tabFlags = ImGui_TabBarFlags_DrawSelectedOverline.cint

proc textCell(text, markName: string; marks: var Marks) =
  if not igTableNextColumn(): return
  let room = igGetContentRegionAvail().x
  igTextUnformatted(text.cstring, nil)
  if markName.len > 0: marks.mark(markName)
  if text.len == 0 or not igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint): return
  if textWidth(text) > room: tip(text)

proc columnWidths(rows: seq[FolderRow]; names: seq[string]): seq[float32] =
  ## Fixed column widths for the rows in sight. File fits the longest name,
  ## up to a cap; Sentence is filled in by the caller from the room left.
  let font = igGetFontSize()
  let extra = font * 1.5
  let cap = font * 28
  result = newSeq[float32](names.len)
  for i, name in names:
    result[i] = textWidth(name) + extra
  var fileW = if names.len > 0: result[0] else: cap
  let kindW = max(textWidth(DatKindLabel), textWidth(VibKindLabel)) + extra
  for row in rows:
    fileW = max(fileW, min(cap, textWidth(row.path.extractFilename) + extra))
  for i, name in names:
    if name == ColFile: result[i] = fileW
    elif name == ColKind: result[i] = max(result[i], kindW)

proc ensureView(ui: var VibFolderUi; st: AppState) =
  ## Sort, filter, cell text and column widths for the current result. Rebuilt
  ## when the result, the sort, the filter or the loaded shot logs change, not on
  ## every frame. The shot log match is made here, in memory: no file is read.
  let shots = $st.shotLogCount & "|" & $st.shotLogsRevision
  if shots != ui.shotKey:
    ui.shotKey = shots
    ui.table.rows.withShots(st)
  let key = $ui.shownGen & "|" & $ord(ui.sortCol) & "|" & $ui.sortDown & "|" &
    bufText(ui.filterBuf) & "|" & shots
  if key == ui.viewKey: return
  let shown = ui.viewOf
  ui.viewRows = shown.rows
  ui.viewCells.setLen(shown.rows.len)
  for i, row in shown.rows:
    ui.viewCells[i] = rowCells(row)
  ui.viewWidths = columnWidths(shown.rows, headers())
  ui.viewKey = key
  inc ui.viewBuilds

proc markColumn(name: string; width: float32; marks: var Marks) =
  let p = igGetCursorScreenPos()
  marks.markRect("vibfolder.col " & name, p, ImVec2_c(x: p.x + width, y: p.y + 1))

proc drawDetail(ui: VibFolderUi; rows: seq[FolderRow]; marks: var Marks) =
  var row = FolderRow()
  var found = false
  if ui.selected.len > 0:
    for r in rows:
      if r.path == ui.selected:
        row = r
        found = true
        break
  igPushTextWrapPos(0)
  if not found:
    igTextDisabled("Select a row to read its sentence.")
    marks.mark("vibfolder.detail none")
  else:
    let sentence = sentenceOf(row)
    let warnings = warningsCell(row)
    igTextUnformatted(("Sentence: " & sentence).cstring, nil)
    marks.mark("vibfolder.detail sentence " & sentence)
    igTextUnformatted(("Warnings: " & warnings).cstring, nil)
    marks.mark("vibfolder.detail warnings " & warnings)
    igTextUnformatted(("Problem: " & row.problem).cstring, nil)
    marks.mark("vibfolder.detail problem " & row.problem)
  igPopTextWrapPos()

proc drawProgress(ui: VibFolderUi; marks: var Marks) =
  let scale = int64(FolderScale)
  let known = ui.running and ui.progressTotal > 0
  let fraction = if known:
      min(1'f32, float32(ui.progressDone) / float32(ui.progressTotal))
    else: -float32(igGetTime())
  var overlay = ""
  if known:
    overlay = $(ui.progressDone div scale) & " / " & $(ui.progressTotal div scale)
  igProgressBar(fraction, ImVec2_c(x: -1, y: 0), overlay.cstring)
  marks.mark("vibfolder.progress")

proc setAll(ui: var VibFolderUi; on: bool) =
  if on: ui.unticked.clear()
  else:
    for item in ui.listed: ui.unticked[item.path] = true

proc chosenText(c: FolderChoice): string =
  ## What the user picked, in words.
  if c.folder.len > 0: ChosenFolder & c.folder
  elif c.files.len == 1: ChosenFiles & c.files[0]
  elif c.files.len > 1: ChosenFiles & $c.files.len & " files, from " &
    c.files[0].parentDir
  else: NothingChosen

proc drawChoice(ui: var VibFolderUi; marks: var Marks) =
  ## The Folder... and Files... buttons, the subfolders tick and what was picked.
  let busy = ui.running
  igBeginDisabled(busy)
  if igButton(FolderButton.cstring, ImVec2_c(x: 0, y: 0)): ui.askFolder = true
  marks.mark("vibfolder.folder")
  igSameLine(0, 8)
  if igButton(FilesButton.cstring, ImVec2_c(x: 0, y: 0)): ui.askFiles = true
  marks.mark("vibfolder.files")
  igSameLine(0, 8)
  var sub = ui.choice.subfolders
  if igCheckbox(SubfoldersLabel.cstring, addr sub): ui.setSubfolders(sub)
  marks.mark("vibfolder.subfolders " & (if ui.choice.subfolders: "on" else: "off"))
  tip(SubfoldersTip)
  igEndDisabled()
  let text = chosenText(ui.choice)
  igPushTextWrapPos(0)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()
  marks.mark("vibfolder.chosen " & text)

proc drawFiles(ui: var VibFolderUi; marks: var Marks) =
  ui.drawChoice(marks)
  var on = 0
  for item in ui.listed:
    if item.path notin ui.unticked: inc on
  if ui.listed.len > 0:
    if igButton(AllButton.cstring, ImVec2_c(x: 0, y: 0)): ui.setAll(true)
    marks.mark("vibfolder.all")
    igSameLine(0, 8)
    if igButton(NoneButton.cstring, ImVec2_c(x: 0, y: 0)): ui.setAll(false)
    marks.mark("vibfolder.none")
    igSameLine(0, 8)
    let count = tickedCount(on, ui.listed.len)
    igTextUnformatted(count.cstring, nil)
    marks.mark("vibfolder.ticked " & count)
  if igBeginChild_Str("##files", ImVec2_c(x: 0, y: 0), 0, 0):
    if ui.listed.len == 0:
      if ui.listing: igTextDisabled(Listing.cstring)
      elif ui.choice.hasChoice: igTextDisabled(NoFiles.cstring)
    else:
      for i, item in ui.listed:
        let name = item.path.extractFilename
        var on = item.path notin ui.unticked
        igPushID_Int(cint(i))
        if igCheckbox(name.cstring, addr on):
          if on: ui.unticked.del(item.path)
          else: ui.unticked[item.path] = true
        igPopID()
        marks.mark("vibfolder.file " & name)
        if on: marks.mark("vibfolder.tick " & name)
        else: marks.mark("vibfolder.untick " & name)
    igEndChild()

proc drawResults(ui: var VibFolderUi; st: AppState; marks: var Marks;
    commands: var seq[Command]) =
  igSetNextItemWidth(-1)
  discard igInputTextWithHint("##filter".cstring,
    (IconFilter & "  " & FilterHint).cstring, cast[cstring](addr ui.filterBuf[0]),
    csize_t(ui.filterBuf.len), 0, nil, nil)
  marks.mark("vibfolder.filter")
  if not ui.have:
    igTextDisabled(NoRows.cstring)
    return
  ui.ensureView(st)
  if st.shotLogCount == 0:
    igTextUnformatted(NoShotLog.cstring, nil)
    marks.mark("vibfolder.noshotlog")
  let names = headers()
  let rows = ui.viewRows
  let widths = ui.viewWidths
  var fixed = 0'f32
  var sentenceAt = -1
  for i, name in names:
    if name == ColSentence: sentenceAt = i
    else: fixed += widths[i]
  let sentenceW = max(igGetFontSize() * 24, igGetContentRegionAvail().x - fixed)
  let lineH = igGetTextLineHeightWithSpacing()
  let tableH = max(lineH * 4, igGetContentRegionAvail().y - lineH * 4)
  if not igBeginTable("##rows", names.len.cint, tableFlags, ImVec2_c(x: 0, y: tableH), 0):
    return
  for i, name in names:
    let w = if i == sentenceAt: sentenceW else: widths[i]
    igTableSetupColumn(name.cstring, ImGui_TableColumnFlags_WidthFixed.cint, w,
      ImGuiID(i + 1))
  igTableSetupScrollFreeze(1, 1)
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      if name in [ColFile, ColController, ColVibrator, ColTime, ColFfid, ColSourceLine,
          ColSourcePoint, ColKind, ColSentence]:
        markColumn(name, igGetContentRegionAvail().x, marks)
      var col = fcPath
      let sorts = sortColumn(name, col)
      let mark = name & (if sorts and col == ui.sortCol:
        (if ui.sortDown: "-" else: "") else: "")
      if igSelectable_Bool((name & "##h").cstring, false, 0, ImVec2_c(x: 0, y: 0)) and
          sorts and ui.focus.acts:
        if ui.sortCol == col: ui.sortDown = not ui.sortDown
        else:
          ui.sortCol = col
          ui.sortDown = false
      marks.mark("vibfolder.header " & name)
      if sorts and col == ui.sortCol:
        marks.mark("vibfolder.sort " & mark)
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(rows.len), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let row = rows[int(i)]
      let cells = ui.viewCells[int(i)]
      let name = if cells.len > 0: cells[0] else: row.path.extractFilename
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      discard igTableNextColumn()
      let flags = ImGui_SelectableFlags_SpanAllColumns.cint or
        ImGui_SelectableFlags_AllowDoubleClick.cint
      let on = row.path == ui.selected
      if igSelectable_Bool((name & "##row").cstring, on, flags,
          ImVec2_c(x: 0, y: 0)) and ui.focus.acts:
        ui.selected = row.path
        if igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint):
          commands.add Command(kind: ckShowFile, panel: MainPanel, path: row.path,
            listFolder: false)
      marks.mark("vibfolder.row " & name & " " & verdictWord(row))
      if name.len > 0 and igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint):
        tip(row.path)
      for c in 1 ..< cells.len:
        var cellMark = ""
        if c < names.len and names[c] == ColSentence:
          cellMark = "vibfolder.sentence " & name & " " & cells[c]
        elif c < names.len and names[c] == ColKind:
          cellMark = "vibfolder.kind " & name & " " & cells[c]
        elif c < names.len and names[c] in [ColController, ColVibrator, ColTime, ColFfid,
            ColSourceLine, ColSourcePoint]:
          cellMark = "vibfolder.cell " & names[c] & " " & name & " " & cells[c]
        textCell(cells[c], cellMark, marks)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()
  ui.drawDetail(rows, marks)

proc runWhy(ui: VibFolderUi; config: VibQcConfig; n: int): string =
  if not config.configured: NotConfigured
  elif not ui.choice.hasChoice: NothingChosen
  elif ui.listing or not ui.haveList: Listing
  elif n == 0: NoTicked
  else: ""

proc drawConfig(config: VibQcConfig; marks: var Marks) =
  ## The configuration in force, as read-only text; or the one sentence that
  ## says it is not configured, and where to configure it.
  igPushTextWrapPos(0)
  if not config.configured:
    igTextUnformatted(NotConfigured.cstring, nil)
    marks.mark("vibfolder.notconfigured")
    igTextUnformatted(WhereToConfigure.cstring, nil)
    marks.mark("vibfolder.configure where")
  else:
    let lines = configLines(config)
    for line in lines:
      igTextUnformatted(line.cstring, nil)
    marks.mark("vibfolder.profile " & lines.join(" "))
  igPopTextWrapPos()

proc drawVibFolder*(ui: var VibFolderUi; title: string; st: AppState;
    marks: var Marks): VibFolderOutput =
  ## The window titled `title`. A list asked for since the last draw starts here.
  ui.consider(st)
  var open = true
  if igBegin(title.cstring, addr open, 0):
    ui.focus.watch()
    marks.markWindow("vibfolder")
    let config = vibQcConfig(st)
    drawConfig(config, marks)
    if ui.status.len > 0 and ui.status != NothingChosen:
      igTextUnformatted(ui.status.cstring, nil)
    if ui.capped and not ui.listing:
      igTextUnformatted(CappedNote.cstring, nil)
      marks.mark("vibfolder.capped")
    if ui.haveList and not ui.listing and not ui.running:
      marks.mark("vibfolder.ready")
    let n = ui.ticked.len
    if ui.running or ui.listing: ui.drawProgress(marks)
    if ui.running:
      if igButton(CancelButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.qcJob != NoJob:
        result.commands.add Command(kind: ckCancelJob, job: ui.qcJob)
      marks.mark("vibfolder.cancel")
    else:
      let canRun = ui.haveList and not ui.listing and config.configured and n > 0
      igBeginDisabled(not canRun)
      if igButton(RunButton.cstring, ImVec2_c(x: 0, y: 0)): ui.submitQc(st)
      igEndDisabled()
      marks.mark("vibfolder.run")
      if not canRun: marks.mark("vibfolder.run.disabled")
      tip(ui.runWhy(config, n), allowDisabled = true)
      if ui.have:
        igSameLine(0, 8)
        if igButton(CopyButton.cstring, ImVec2_c(x: 0, y: 0)):
          igSetClipboardText(resultsText(ui.table).cstring)
        marks.mark("vibfolder.copy")
        igSameLine(0, 8)
        if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
          result.exportAsked = true
          let base = if ui.choice.folder.len > 0: ui.choice.folder
            elif ui.choice.files.len > 0: ui.choice.files[0].parentDir
            else: ""
          result.exportPath = if base.len > 0: base / SuggestedName else: SuggestedName
        marks.mark("vibfolder.export")
    if ui.have:
      let line = summaryLine(ui.table.totals)
      igPushTextWrapPos(0)
      igTextUnformatted(line.cstring, nil)
      igPopTextWrapPos()
      marks.mark("vibfolder.totals " & line)
      for p in ui.table.problems:
        let said = shownProblem(p)
        igTextUnformatted(said.cstring, nil)
        marks.mark("vibfolder.problem " & said)
    if igBeginTabBar("##vibfoldertabs", tabFlags):
      var filesFlags = 0.cint
      var resultsFlags = 0.cint
      if ui.selectResults:
        resultsFlags = ImGui_TabItemFlags_SetSelected.cint
        ui.selectResults = false
        ui.tab = vtResults
      let filesOn = igBeginTabItem(FilesTab.cstring, nil, filesFlags)
      marks.mark("vibfolder.tab Files")
      if filesOn:
        ui.tab = vtFiles
        ui.drawFiles(marks)
        igEndTabItem()
      let resultsOn = igBeginTabItem(ResultsTab.cstring, nil, resultsFlags)
      marks.mark("vibfolder.tab Results")
      if resultsOn:
        ui.tab = vtResults
        ui.drawResults(st, marks, result.commands)
        marks.mark("vibfolder.results")
        igEndTabItem()
      igEndTabBar()
    marks.markOverflow("vibfolder")
  ui.focus.settle()
  igEnd()
  if not open: result.closed = true
  result.askFolder = ui.askFolder
  result.askFiles = ui.askFiles
  ui.askFolder = false
  ui.askFiles = false
  result.askAt = if ui.choice.folder.len > 0: ui.choice.folder & DirSep
    elif ui.choice.files.len > 0: ui.choice.files[0].parentDir & DirSep
    else: ""
