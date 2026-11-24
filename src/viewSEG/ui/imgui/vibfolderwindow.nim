## The Vibrator QC of a folder window: a list of the signature files in the
## open folder (subfolders included), a run against the project's profile, and
## a CSV export. The results table leaves room under it for the selected row.
##
## Listing and judging are background jobs. The window reads a sink only after
## that job is no longer running. The worker must not read `AppState`: the
## profile, the weights and the reference are copied before the job starts.

import std/[math, os, strutils, tables]
import imguin/cimgui
import ../../core/[filejobs, filekinds, filesystem, jobs, sigtypes, state, sweepinfo, units,
  vibfolderjobs, vibfolderqc, vibprofile]
import ../../view/vibfolderwords
import fittext, focus, icons, marks, overflow

type
  VibTab = enum
    vtFiles, vtResults

  ListNote = ref object
    files: seq[FolderListed]
    capped: bool

  VibFolderUi* = object
    listJob: JobId = NoJob
    qcJob: JobId = NoJob
    exportJob: JobId = NoJob
    sink: FolderQcSink
    note: ListNote
    folder: string
    listed: seq[FolderListed]
    unticked: Table[string, bool] = initTable[string, bool]()
    table: FolderTable
    haveList: bool
    have: bool
    listing: bool
    running: bool
    capped: bool
    wantList: bool
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

  VibFolderOutput* = object
    commands*: seq[Command]
    exportAsked*: bool
    exportPath*: string

proc requestList*(ui: var VibFolderUi) =
  ## The window was opened, or the folder changed: list on the next draw.
  ui.wantList = true

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

proc listWork(folder: string; note: ListNote): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase(Listing)
    var capped = false
    var paths: seq[string] = @[]
    try:
      paths = listedNames(@[folder], true, capped,
        proc (found: int): bool {.gcsafe, raises: [].} =
        ctx.progress(int64(found), 0))
    except OSError:
      raise newException(ValueError, CannotList)
    if note != nil: note.capped = capped
    ctx.checkCancelled()
    var files: seq[FolderListed] = @[]
    for path in paths:
      ctx.checkCancelled()
      let kind = sniff(path)
      if kind notin SignatureFileKinds: continue
      var info = SweepInfo(kind: kind.sweepKindOf)
      try:
        info = readSweepInfo(path, kind.sweepKindOf, fs.getFileSize(path))
      except OSError as e:
        info.problem = if e.msg.len > 0: e.msg else: "it cannot be read"
      files.add FolderListed(path: path, info: info)
    if note != nil: note.files = files

proc exportWork(path, text: string): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    writeCsv(path, text)

proc finishList(ui: var VibFolderUi; state: JobState; error: string) =
  ui.listing = false
  if ui.note != nil: ui.capped = ui.note.capped
  if state == jsCancelled:
    ui.status = Stopped
    return
  if state == jsFailed:
    ui.status = if error.len > 0: error else: CannotList
    return
  if ui.note != nil: ui.listed = ui.note.files
  ui.haveList = true
  ui.status = Ready

proc finishQc(ui: var VibFolderUi; state: JobState; error: string) =
  ui.running = false
  if ui.sink != nil:
    ui.table = ui.sink.result
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
  let folder = st.fileList.folder
  if folder.len == 0: return
  if ui.listJob != NoJob:
    discard st.jobs.cancel(ui.listJob)
    ui.listJob = NoJob
  ui.folder = folder
  ui.note = ListNote()
  ui.listing = true
  ui.haveList = false
  ui.status = Listing
  ui.listJob = st.jobs.submit(JobSpec(title: "List vibrator files",
    lane: jlBackground, reads: @[folder]), listWork(folder, ui.note))

proc clearRun(ui: var VibFolderUi) =
  ui.listed.setLen 0
  ui.haveList = false
  ui.have = false
  ui.table = FolderTable()
  ui.selected = ""
  ui.unticked = initTable[string, bool]()
  ui.selectResults = false
  ui.tab = vtFiles
  ui.capped = false
  ui.progressDone = 0
  ui.progressTotal = 0

proc consider(ui: var VibFolderUi; st: AppState) =
  ui.poll(st)
  let folder = st.fileList.folder
  if folder != ui.folder:
    if ui.listJob != NoJob:
      discard st.jobs.cancel(ui.listJob)
      ui.listJob = NoJob
      ui.listing = false
    if ui.qcJob != NoJob:
      discard st.jobs.cancel(ui.qcJob)
      ui.qcJob = NoJob
      ui.running = false
    ui.clearRun()
    ui.folder = folder
    ui.wantList = folder.len > 0
    ui.status = if folder.len == 0: folderWhy(false) else: Listing
  if ui.wantList and ui.listJob == NoJob and folder.len > 0:
    ui.wantList = false
    ui.submitList(st)

proc archiveIds(st: AppState): seq[string] =
  result = @[]
  if not st.referencesLoaded: return
  for e in st.references.entries:
    if e.id.len > 0: result.add e.id

proc referenceFor(st: AppState; id: string): FolderReference =
  if id.len == 0 or not st.referencesLoaded: return
  let home = st.referencesHome
  if home.len == 0: return
  for e in st.references.entries:
    if e.id != id: continue
    if e.isPilot or e.file.len == 0: return
    return FolderReference(path: home / e.file, name: e.name, startMs: e.timeStart)

proc ticked(ui: VibFolderUi): seq[FolderListed] =
  result = @[]
  for item in ui.listed:
    if item.path notin ui.unticked: result.add item

proc hasProfile(st: AppState): bool =
  st.inProject and st.project.doc.hasVibProfile

proc submitQc(ui: var VibFolderUi; st: AppState) =
  if ui.listJob != NoJob or not ui.haveList: return
  if not hasProfile(st):
    ui.status = NoProfile
    return
  let files = ui.ticked
  if files.len == 0:
    ui.status = NoTicked
    return
  if ui.qcJob != NoJob:
    discard st.jobs.cancel(ui.qcJob)
    ui.qcJob = NoJob
  let profile = st.project.doc.vibProfile
  let ask = applied(profile, archiveIds(st))
  let weights = st.project.doc.vibJobWeights
  let reference = referenceFor(st, profile.referenceId)
  ui.sink = FolderQcSink()
  ui.running = true
  ui.have = false
  ui.progressDone = 0
  ui.progressTotal = 0
  ui.status = Judging
  ui.qcJob = st.jobs.submit(folderQcSpec(files, reference.path),
    folderQcWork(ask, weights, files, ui.sink, reference = reference))

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
  let reads = if ui.folder.len > 0: ui.folder else: dest
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

type HeldWeight = object
  text: array[64, char]
  active: bool

var weightBoxes: Table[string, HeldWeight]

proc weightBox(id: string; value: float64; typed: var float64): bool =
  ## A kilograms box, empty when unset (NaN). True once the user has finished
  ## typing; nothing typed, or not a number, is none.
  if id notin weightBoxes: weightBoxes[id] = HeldWeight()
  if not weightBoxes[id].active:
    zeroMem(addr weightBoxes[id].text[0], weightBoxes[id].text.len)
    let text = if value.isNaN: "" else: sensible(value)
    for i, c in text:
      if i < weightBoxes[id].text.high: weightBoxes[id].text[i] = c
  let width = round(igCalcTextSize("00000.0", nil, false, -1).x +
    2 * igGetStyle().FramePadding.x)
  igSetNextItemWidth(width)
  discard igInputText(id.cstring, cast[cstring](addr weightBoxes[id].text[0]),
    csize_t(weightBoxes[id].text.len), ImGui_InputTextFlags_CharsScientific.cint, nil, nil)
  weightBoxes[id].active = igIsItemActive()
  let got = $cast[cstring](addr weightBoxes[id].text[0])
  typed = try: parseFloat(got.strip) except ValueError: NaN
  igIsItemDeactivatedAfterEdit()

proc changedWeight(a, b: float64): bool {.inline.} =
  a != b and not (a.isNaN and b.isNaN)

proc drawWeights(ui: var VibFolderUi; st: AppState; marks: var Marks;
    commands: var seq[Command]) =
  ## The job's three weights, above the tabs. Empty is not set. A finished edit
  ## is a `ckVibWeights` of all three. Inactive without a project.
  let can = st.inProject
  if not can: igBeginDisabled(true)
  let now = if st.inProject: st.project.doc.vibJobWeights else: VibJobWeights()
  var next = now
  var changed = false
  template one(label, id: string; current: float64; field: untyped) =
    igAlignTextToFramePadding()
    igTextUnformatted(label, nil)
    igSameLine(0, -1)
    var typed = 0.0
    if weightBox(id, current, typed) and can:
      if typed.isNaN or MassKgRange.allows(typed):
        if changedWeight(typed, current):
          field = typed
          changed = true
      else:
        ui.status = "The weight must be " & MassKgRange.words & ", not " &
          sensible(typed) & "."
    marks.mark("vibfolder.weight " & label)
    if not can: marks.mark("vibfolder.weight " & label & ".disabled")
    tip(if can: WeightsHint else: NeedProjectWeights, allowDisabled = true)
    igSameLine(0, -1)
    igTextUnformatted("kg", nil)
    igSameLine(0, 8)
  one(HoldDownLabel, "##holddown", now.holdDownKg, next.holdDownKg)
  one(BaseplateLabel, "##baseplate", now.baseplateMassKg, next.baseplateMassKg)
  one(ReactionLabel, "##reaction", now.reactionMassKg, next.reactionMassKg)
  if changed and can: commands.add Command(kind: ckVibWeights, vibWeights: next)
  if not can: igEndDisabled()
  igNewLine()

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

proc drawFiles(ui: var VibFolderUi; marks: var Marks) =
  if igBeginChild_Str("##files", ImVec2_c(x: 0, y: 0), 0, 0):
    if ui.listed.len == 0:
      igTextDisabled((if ui.listing: Listing else: NoFiles).cstring)
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

proc drawResults(ui: var VibFolderUi; marks: var Marks; commands: var seq[Command]) =
  igSetNextItemWidth(-1)
  discard igInputTextWithHint("##filter".cstring,
    (IconFilter & "  " & FilterHint).cstring, cast[cstring](addr ui.filterBuf[0]),
    csize_t(ui.filterBuf.len), 0, nil, nil)
  marks.mark("vibfolder.filter")
  if not ui.have:
    igTextDisabled(NoRows.cstring)
    return
  let names = headers()
  let shown = ui.viewOf
  let rows = shown.rows
  let widths = columnWidths(rows, names)
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
      if name in [ColFile, ColKind, ColSentence]:
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
      let cells = rowCells(row)
      let name = if cells.len > 0: cells[0] else: row.path.extractFilename
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      discard igTableNextColumn()
      let fileRoom = igGetContentRegionAvail().x
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
        if textWidth(name) > fileRoom: tip(name)
      for c in 1 ..< cells.len:
        var cellMark = ""
        if c < names.len and names[c] == ColSentence:
          cellMark = "vibfolder.sentence " & name & " " & cells[c]
        elif c < names.len and names[c] == ColKind:
          cellMark = "vibfolder.kind " & name & " " & cells[c]
        textCell(cells[c], cellMark, marks)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()
  ui.drawDetail(rows, marks)

proc runWhy(ui: VibFolderUi; st: AppState; n: int): string =
  if not hasProfile(st): NoProfile
  elif ui.listing or not ui.haveList: Listing
  elif n == 0: NoTicked
  else: ""

proc drawVibFolder*(ui: var VibFolderUi; title: string; st: AppState;
    marks: var Marks): VibFolderOutput =
  ## The window titled `title`. A list asked for since the last draw starts here.
  ui.consider(st)
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("vibfolder")
    let profiled = hasProfile(st)
    let lines = if profiled: profileLines(st.project.doc.vibProfile) else: @[NoProfile]
    igPushTextWrapPos(0)
    for line in lines:
      igTextUnformatted(line.cstring, nil)
    igPopTextWrapPos()
    marks.mark("vibfolder.profile " & lines.join(" "))
    if ui.status.len > 0:
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
      let canRun = ui.haveList and not ui.listing and profiled and n > 0
      igBeginDisabled(not canRun)
      if igButton(RunButton.cstring, ImVec2_c(x: 0, y: 0)): ui.submitQc(st)
      igEndDisabled()
      marks.mark("vibfolder.run")
      if not canRun: marks.mark("vibfolder.run.disabled")
      tip(ui.runWhy(st, n), allowDisabled = true)
      if ui.have:
        igSameLine(0, 8)
        if igButton(CopyButton.cstring, ImVec2_c(x: 0, y: 0)):
          igSetClipboardText(resultsText(ui.table).cstring)
        marks.mark("vibfolder.copy")
        igSameLine(0, 8)
        if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
          result.exportAsked = true
          let base = if ui.folder.len > 0: ui.folder else: st.fileList.folder
          result.exportPath = base / SuggestedName
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
    ui.drawWeights(st, marks, result.commands)
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
        ui.drawResults(marks, result.commands)
        marks.mark("vibfolder.results")
        igEndTabItem()
      igEndTabBar()
    marks.markOverflow("vibfolder")
  ui.focus.settle()
  igEnd()
