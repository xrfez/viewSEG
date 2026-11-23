## The Missing traces window: a scan of the open folder (subfolders included)
## against the loaded relation file, two tables, and a CSV export.
##
## The scan is a background job. The window reads its sink only after the job
## is no longer running. A cancel leaves the tables already shown. Listing uses
## the same file list the folder scan uses (`listedNames`), not a second walk
## posted to the file list.

import std/[os, strutils]
import parseSEG
import imguin/cimgui
import ../../core/[filejobs, filesystem, jobs, missingjobs, missingreport, state]
import ../../core/records as filerecs
import ../../view/missingwords
import focus, icons, marks

type
  MissingTab* = enum
    mtFolder, mtRecords

  ExportAsk* = object
    tab*: MissingTab
    withPoints*, withTotals*, live*: bool

  PendingOpen = object
    path: string
    record: float64
    live: bool

  ScanNote = ref object
    capped: bool

  MissingUi* = object
    scanJob: JobId = NoJob
    exportJob: JobId = NoJob
    sink: MissingSink
    note: ScanNote
    wantScan: bool
    scanning: bool
    have: bool
    capped: bool
    exported: bool
    folder: string
    status: string
    report: MissingReport
    skipped: seq[tuple[path, why: string]]
    unmatched: seq[tuple[path: string; record: int64; why: string]]
    tab: MissingTab
    withPoints, withTotals: bool
    ask: ExportAsk
    pointSort: SortSpec[PointSortColumn]
    recordSort: SortSpec[RecordSortColumn]
    sortsReady, pointDirty, recordDirty: bool
    focus: FocusClicks
    pending: PendingOpen

  MissingOutput* = object
    commands*: seq[Command]
    exportAsked*: bool
    exportPath*: string

proc requestScan*(ui: var MissingUi) =
  ## The next draw starts a scan, cancelling one already running.
  ui.wantScan = true

proc canScan(st: AppState): bool =
  missingReady(st.fileList.folder.len > 0, st.relationLayer >= 0)

proc whyNot(st: AppState): string =
  missingWhy(st.fileList.folder.len > 0, st.relationLayer >= 0)

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

proc totalsBeside(path: string): string =
  let s = path.splitFile
  let ext = if s.ext.len == 0: ".csv" else: s.ext
  s.dir / (s.name & "-totals" & ext)

proc folderScan(folder, cache: string; relations: ref SurveyGeometry; sink: MissingSink;
    note: ScanNote): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase Listing
    var capped = false
    var paths: seq[string] = @[]
    try:
      paths = listedNames(@[folder], true, capped,
        proc (found: int): bool {.gcsafe, raises: [].} = ctx.progress(int64(found), 0))
    except OSError:
      raise newException(ValueError, CannotList)
    if note != nil: note.capped = capped
    ctx.checkCancelled()
    let scan = scanMissing(folder, paths, relations, sink, cache)
    scan(ctx)

proc exportWork(path, beside: string; points: seq[PointRow];
    records: seq[missingreport.RecordRow];
    recordPoints: seq[RecordPointRow]; totals: Totals; ask: ExportAsk): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    let main = if ask.tab == mtRecords and ask.withPoints: recordPointsCsv(recordPoints)
      elif ask.tab == mtRecords: recordsCsv(records)
      else: pointsCsv(points)
    writeCsv(path, main)
    if ask.withTotals: writeCsv(beside, totalsCsv(totals))

proc finishScan(ui: var MissingUi; state: JobState; error: string) =
  ui.scanning = false
  if ui.note != nil: ui.capped = ui.note.capped
  if state == jsCancelled:
    ui.status = Stopped
    return
  let failed = state == jsFailed or ui.sink == nil or not ui.sink.result.ok
  if failed:
    if ui.sink != nil and ui.sink.result.reason.len > 0: ui.status = ui.sink.result.reason
    elif error.len > 0: ui.status = error
    else: ui.status = ScanFailed
    return
  ui.report = ui.sink.result.report
  ui.skipped = ui.sink.result.skipped
  ui.unmatched = ui.sink.result.unmatched
  ui.have = true
  ui.pointDirty = true
  ui.recordDirty = true
  ui.status = Ready

proc poll(ui: var MissingUi; st: AppState) =
  if ui.scanJob != NoJob:
    let info = st.jobs.info(ui.scanJob)
    if info.isNone:
      ui.scanJob = NoJob
      ui.scanning = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.scanning = true
      let phase = info.get.progress.phase
      ui.status = if phase.len > 0: phase else: Scanning
    else:
      ui.finishScan(info.get.state, info.get.error)
      ui.scanJob = NoJob
  if ui.exportJob != NoJob:
    let info = st.jobs.info(ui.exportJob)
    if info.isNone: ui.exportJob = NoJob
    elif info.get.state notin {jsQueued, jsRunning}:
      if info.get.state == jsDone:
        ui.exported = true
        ui.status = Written
      elif info.get.state == jsFailed:
        ui.status = if info.get.error.len > 0: info.get.error else: ExportFailed
      ui.exportJob = NoJob

proc submit(ui: var MissingUi; st: AppState) =
  let folder = st.fileList.folder
  let layer = st.relationLayer
  if folder.len == 0 or layer < 0: return
  if ui.scanJob != NoJob:
    discard st.jobs.cancel(ui.scanJob)
    ui.scanJob = NoJob
  var relations: ref SurveyGeometry = nil
  relations = st.survey.layers[layer].relations
  let cache = st.indexCache
  ui.folder = folder
  ui.note = ScanNote()
  ui.sink = MissingSink()
  ui.capped = false
  ui.scanning = true
  ui.status = Scanning
  ui.scanJob = st.jobs.submit(missingSpec(folder, @[folder]),
    folderScan(folder, cache, relations, ui.sink, ui.note))

proc consider(ui: var MissingUi; st: AppState) =
  if not ui.sortsReady:
    ui.pointSort = DefaultPointSort
    ui.recordSort = DefaultRecordSort
    ui.sortsReady = true
  ui.poll(st)
  if ui.wantScan:
    ui.wantScan = false
    if canScan(st): ui.submit(st)
    elif not ui.have: ui.status = whyNot(st)

proc startExport*(ui: var MissingUi; st: AppState; path: string) =
  ## Writes the CSV asked for when Export CSV... was clicked, from the rows
  ## shown now. `path` gains ".csv" when it has no extension.
  if not ui.ask.live: return
  let ask = ui.ask
  ui.ask.live = false
  var dest = path
  if dest.splitFile.ext.len == 0: dest.add ".csv"
  let beside = totalsBeside(dest)
  let points = ui.report.points
  let records = ui.report.records
  let recordPoints = ui.report.recordPoints
  let totals = ui.report.totals
  if ui.exportJob != NoJob:
    discard st.jobs.cancel(ui.exportJob)
    ui.exportJob = NoJob
  ui.exportJob = st.jobs.submit(JobSpec(title: "Export missing traces",
    lane: jlBackground, reads: @[ui.folder]),
    exportWork(dest, beside, points, records, recordPoints, totals, ask))

proc takePending(ui: var MissingUi; st: AppState): seq[Command] =
  if not ui.pending.live: return
  for s in st.sessions:
    if canonical(s.path) != ui.pending.path: continue
    if s.gathers.len == 0: return
    let g = filerecs.findRecord(s.records, ui.pending.record)
    ui.pending.live = false
    if g >= 0:
      result.add Command(kind: ckGather, panel: MainPanel, gather: g)
    return

proc openRecord(ui: var MissingUi; st: AppState; file: string; record: float64): seq[Command] =
  if ui.folder.len == 0 or file.len == 0: return
  let path = canonical(ui.folder / file)
  result.add Command(kind: ckShowFile, panel: MainPanel, path: path, listFolder: false)
  let known = record == record
  var open = false
  if known:
    for s in st.sessions:
      if canonical(s.path) == path:
        open = true
        let g = filerecs.findRecord(s.records, record)
        if g >= 0:
          result.add Command(kind: ckGather, panel: MainPanel, gather: g)
        break
  if open or not known: ui.pending.live = false
  else: ui.pending = PendingOpen(path: path, record: record, live: true)

proc clickSort[C](spec: var SortSpec[C]; col: C; shift: bool) =
  if shift:
    var at = -1
    for i, s in spec:
      if s.column == col: at = i
    if at >= 0: spec[at].descending = not spec[at].descending
    else: spec.add (column: col, descending: false)
  elif spec.len == 1 and spec[0].column == col:
    spec[0].descending = not spec[0].descending
  else:
    spec.setLen 0
    spec.add (column: col, descending: false)

func placeOf[C](spec: SortSpec[C]; col: C): int =
  for i, s in spec:
    if s.column == col: return i + 1

func pointName(c: PointSortColumn): string =
  case c
  of psNever: ColNever
  of psMissingIn: ColMissingIn
  of psExpectedIn: ColExpectedIn
  of psLine: ColLine
  of psPoint: ColPoint
  of psIndex: ColIndex
  of psFirstFile: ColFirstFile
  of psFirstRecord: ColFirstRecord
  of psLastFile: ColLastFile
  of psLastRecord: ColLastRecord

func recordName(c: RecordSortColumn): string =
  case c
  of rsFile: ColFile
  of rsRecord: ColRecord
  of rsExpected: ColExpected
  of rsPresent: ColPresent
  of rsMissing: ColMissing
  of rsDuplicates: ColDuplicates
  of rsUnlisted: ColExtras

func pointSortText(spec: SortSpec[PointSortColumn]): string =
  var parts: seq[string]
  for s in spec:
    parts.add pointName(s.column) & (if s.descending: "-" else: "")
  parts.join(",")

func recordSortText(spec: SortSpec[RecordSortColumn]): string =
  var parts: seq[string]
  for s in spec:
    parts.add recordName(s.column) & (if s.descending: "-" else: "")
  parts.join(",")

func firstLine(s: string): string =
  let n = s.find('\n')
  if n < 0: s else: s[0 ..< n]

func totalsMark(t: Totals): string =
  "missing.totals " & $t.files & " " & $t.records & " " & $t.expected & " " &
    $t.present & " " & $t.missing & " " & $t.never & " " & $t.duplicates & " " &
    $t.extras & " " & $t.xpsWithoutData.len

proc tip(text: string) =
  if text.len == 0: return
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc headerCell(name: string; place: int; marks: var Marks): bool =
  let label = if place == 0: name else: name & " " & $place
  result = igSelectable_Bool((label & "##h").cstring, false, 0, ImVec2_c(x: 0, y: 0))
  marks.mark("missing.header " & name)

const
  tableFlags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint or
    ImGui_TableFlags_Hideable.cint

proc setupColumns(names: openArray[string]) =
  for i, name in names:
    igTableSetupColumn(name.cstring, ImGui_TableColumnFlags_WidthFixed.cint,
      if i == 0: 140 else: 72, ImGuiID(i + 1))
  igTableSetupScrollFreeze(0, 1)
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)

proc drawPoints(ui: var MissingUi; marks: var Marks) =
  if ui.pointDirty:
    sortPoints(ui.report.points, ui.pointSort)
    ui.pointDirty = false
  const names = [ColLine, ColPoint, ColIndex, ColExpectedIn, ColMissingIn, ColNever,
    ColUnknown, ColFirstRecord, ColLastRecord]
  const keys = [psLine, psPoint, psIndex, psExpectedIn, psMissingIn, psNever,
    psLine, psFirstRecord, psLastRecord]
  const on = [true, true, true, true, true, true, false, true, true]
  let rows = ui.report.points
  if rows.len == 0:
    igTextDisabled(NoRows)
    return
  let height = max(igGetContentRegionAvail().y, igGetTextLineHeightWithSpacing())
  if not igBeginTable("##points", names.len.cint, tableFlags, ImVec2_c(x: 0, y: height), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      let place = if on[c]: placeOf(ui.pointSort, keys[c]) else: 0
      let clicked = headerCell(name, place, marks)
      if not on[c]:
        tip(NotSortable)
      elif clicked:
        clickSort(ui.pointSort, keys[c], igGetIO_Nil().KeyShift)
        ui.pointDirty = true
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(rows.len), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let p = rows[i]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      template cell(text: string) =
        if igTableNextColumn(): igTextUnformatted(text.cstring, nil)
      cell(filerecs.stationNumber(p.line))
      cell(filerecs.stationNumber(p.point))
      cell($p.index)
      cell($p.expectedIn)
      cell($p.missingIn)
      if igTableNextColumn() and p.never: igTextUnformatted(IconCheck.cstring, nil)
      if igTableNextColumn() and p.expectedUnknown: igTextUnformatted(IconCheck.cstring, nil)
      if igTableNextColumn():
        igTextUnformatted(filerecs.stationNumber(p.firstRecord).cstring, nil)
        tip(p.firstFile)
      if igTableNextColumn():
        igTextUnformatted(filerecs.stationNumber(p.lastRecord).cstring, nil)
        tip(p.lastFile)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()

proc drawRecords(ui: var MissingUi; st: AppState; marks: var Marks; commands: var seq[Command]) =
  if ui.recordDirty:
    sortRecords(ui.report.records, ui.recordSort)
    ui.recordDirty = false
  const names = [ColFile, ColRecord, ColExpected, ColPresent, ColMissing, ColDuplicates,
    ColExtras, ColAlsoIn, ColMissingPoints]
  const keys = [rsFile, rsRecord, rsExpected, rsPresent, rsMissing, rsDuplicates, rsUnlisted,
    rsFile, rsFile]
  const on = [true, true, true, true, true, true, true, false, false]
  let rows = ui.report.records
  if rows.len == 0:
    igTextDisabled(NoRows)
    return
  let height = max(igGetContentRegionAvail().y, igGetTextLineHeightWithSpacing())
  if not igBeginTable("##records", names.len.cint, tableFlags, ImVec2_c(x: 0, y: height), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      let clicked = headerCell(name, if on[c]: placeOf(ui.recordSort, keys[c]) else: 0, marks)
      if not on[c]: tip(NotSortable)
      elif clicked:
        clickSort(ui.recordSort, keys[c], igGetIO_Nil().KeyShift)
        ui.recordDirty = true
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(rows.len), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let r = rows[i]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      discard igTableNextColumn()
      let flags = ImGui_SelectableFlags_SpanAllColumns.cint or
        ImGui_SelectableFlags_AllowDoubleClick.cint
      if igSelectable_Bool((r.file & "##row").cstring, false, flags,
          ImVec2_c(x: 0, y: 0)) and ui.focus.acts and
          igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint):
        for c in ui.openRecord(st, r.file, r.record): commands.add c
      marks.mark("missing.file " & r.file)
      if i < 8: marks.mark("missing.record " & $i)
      template cell(text: string) =
        if igTableNextColumn(): igTextUnformatted(text.cstring, nil)
      cell(filerecs.stationNumber(r.record))
      cell($r.expected)
      cell($r.present)
      cell($r.missing)
      cell($r.duplicates)
      cell($r.unlisted)
      cell($r.alsoIn)
      if igTableNextColumn():
        igTextUnformatted(firstLine(r.missingPoints).cstring, nil)
        tip(r.missingPoints)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()

proc drawPopup(id, empty, markPrefix: string; lines: openArray[string]; marks: var Marks) =
  if not igBeginPopup(id.cstring, 0): return
  if lines.len == 0: igTextUnformatted(empty.cstring, nil)
  else:
    let h = min(8.0'f32 * igGetTextLineHeightWithSpacing(),
      float32(lines.len) * igGetTextLineHeightWithSpacing())
    if igBeginChild_Str("##list", ImVec2_c(x: 420, y: h), 0, 0):
      for line in lines:
        igTextUnformatted(line.cstring, nil)
        if markPrefix.len > 0: marks.mark(markPrefix & line)
    igEndChild()
  igEndPopup()

proc drawMissing*(ui: var MissingUi; title: string; st: AppState; marks: var Marks): MissingOutput =
  ## The window titled `title`. A scan asked for since the last draw starts here.
  ui.consider(st)
  result.commands = ui.takePending(st)
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("missing")
    if ui.status.len == 0: ui.status = if canScan(st): Ready else: whyNot(st)
    igTextUnformatted(ui.status.cstring, nil)
    if ui.scanning: marks.mark("missing.scanning")
    if ui.have and not ui.scanning:
      marks.mark("missing.ready")
      let spec = if ui.tab == mtFolder: pointSortText(ui.pointSort)
        else: recordSortText(ui.recordSort)
      marks.mark("missing.sort " & spec)
      let t = ui.report.totals
      let lineH = igGetTextLineHeightWithSpacing()
      if igBeginChild_Str("##totals", ImVec2_c(x: 0, y: lineH), 0,
          ImGui_WindowFlags_HorizontalScrollbar.cint):
        igTextUnformatted(totalsLine(t.files, t.records, t.expected, t.present, t.missing,
          t.never, t.duplicates, t.extras, t.xpsWithoutData.len,
          t.percentMissing).cstring, nil)
        marks.mark(totalsMark(t))
      igEndChild()
      if ui.report.duplicatesNote.len > 0 and t.duplicates > 0:
        igTextDisabled("%s", ui.report.duplicatesNote.cstring)
    if ui.capped:
      igTextUnformatted(CappedNote.cstring, nil)
    if igButton(countLabel(SkippedFiles, ui.skipped.len).cstring, ImVec2_c(x: 0, y: 0)):
      igOpenPopup_Str("##skipped", 0)
    marks.mark("missing.skipped")
    igSameLine(0, -1)
    if igButton(countLabel(UnmatchedRecords, ui.unmatched.len).cstring,
        ImVec2_c(x: 0, y: 0)):
      igOpenPopup_Str("##unmatched", 0)
    marks.mark("missing.unmatched")
    var skippedLines: seq[string] = @[]
    for row in ui.skipped: skippedLines.add row.path & " — " & row.why
    var unmatchedLines: seq[string] = @[]
    for row in ui.unmatched:
      unmatchedLines.add row.path & " " & $row.record & ": " & row.why
    drawPopup("##skipped", NoneSkipped, "missing.skippedline ", skippedLines, marks)
    drawPopup("##unmatched", NoneUnmatched, "", unmatchedLines, marks)
    if igBeginTabBar("##missingtabs", 0):
      marks.mark("missing.tab")
      let folderOn = igBeginTabItem(FolderTab.cstring, nil, 0)
      marks.mark("missing.tab Folder")
      if folderOn:
        ui.tab = mtFolder
        igEndTabItem()
      let recordsOn = igBeginTabItem(RecordsTab.cstring, nil, 0)
      marks.mark("missing.tab Records")
      if recordsOn:
        ui.tab = mtRecords
        igEndTabItem()
      igEndTabBar()
    if igCheckbox((WithPoints & "##points").cstring, addr ui.withPoints): discard
    marks.mark("missing.points")
    tip(PointsTip)
    if igCheckbox((WithTotals & "##totals").cstring, addr ui.withTotals): discard
    marks.mark("missing.totalsbox")
    tip(TotalsTip)
    if ui.scanning:
      if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.scanJob != NoJob:
        result.commands.add Command(kind: ckCancelJob, job: ui.scanJob)
      marks.mark("missing.stop")
    else:
      igBeginDisabled(not canScan(st))
      if igButton(RescanButton.cstring, ImVec2_c(x: 0, y: 0)): ui.requestScan()
      igEndDisabled()
      marks.mark("missing.rescan")
    igSameLine(0, -1)
    igBeginDisabled(not ui.have)
    if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
      ui.ask = ExportAsk(tab: ui.tab, withPoints: ui.withPoints,
        withTotals: ui.withTotals, live: true)
      result.exportAsked = true
      let base = if ui.folder.len > 0: ui.folder else: st.fileList.folder
      result.exportPath = base / SuggestedName
    igEndDisabled()
    marks.mark("missing.export")
    if ui.have and ui.tab == mtFolder: ui.drawPoints(marks)
    elif ui.have: ui.drawRecords(st, marks, result.commands)
  ui.focus.settle()
  igEnd()
  ui.consider(st)
