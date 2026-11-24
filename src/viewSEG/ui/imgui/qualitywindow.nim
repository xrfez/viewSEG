## The Trace quality window: a scan of the open folder (subfolders included),
## two tables, and a CSV export. The totals wrap. A line under them names files
## or traces that could not be read, when any could not. The table fills the
## rest of the window; a box above it narrows the rows.
##
## The scan is a background job. The window reads its sink only after the job
## is no longer running. A cancel leaves the tables already shown. Listing uses
## the same file list the folder scan uses (`listedNames`), not a second walk
## posted to the file list. Edits are copied on the UI thread (`editsSnapshot`)
## before the job is submitted: the worker must not read `AppState`.

import std/[os, strutils, tables]
import imguin/cimgui
import ../../core/[edits, filejobs, filesystem, jobs, qualityjobs, qualityreport, session, state]
import ../../core/records as filerecs
import ../../view/qualitywords
import focus, icons, marks, overflow

type
  QualityTab* = enum
    qtStations, qtRecords

  ExportAsk* = object
    tab*: QualityTab
    withTotals*, live*: bool

  PendingOpen = object
    path: string
    record: float64
    live: bool

  ScanNote = ref object
    capped: bool

  QualityUi* = object
    scanJob: JobId = NoJob
    exportJob: JobId = NoJob
    sink: QualitySink
    note: ScanNote
    wantScan: bool
    scanning: bool
    have: bool
    capped: bool
    exported: bool
    folder: string
    status: string
    progressDone, progressTotal: int64
    report: QualityReport
    unread: seq[tuple[path, why: string]]
    tab: QualityTab
    withTotals: bool
    ask: ExportAsk
    stationSort: SortSpec[StationSortColumn]
    recordSort: SortSpec[RecordSortColumn]
    sortsReady, stationDirty, recordDirty: bool
    focus: FocusClicks
    pending: PendingOpen
    stationFilter, recordFilter: array[128, char]
    stationShown, recordShown: seq[int]
    stationKey, recordKey: string

  QualityOutput* = object
    commands*: seq[Command]
    exportAsked*: bool
    exportPath*: string

proc requestScan*(ui: var QualityUi) =
  ## The next draw starts a scan, cancelling one already running.
  ui.wantScan = true

proc canScan(st: AppState): bool =
  qualityReady(st.fileList.folder.len > 0)

proc whyNot(st: AppState): string =
  qualityWhy(st.fileList.folder.len > 0)

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

proc editsFor(paths: openArray[string]; snap: EditsSnapshot): Table[string, FileEdits] =
  ## `snap` keyed by each listed path, so a killed trace is found under the
  ## path the scan names. A path with no edits is left out.
  for path in paths:
    var key = ""
    let disk = diskOf(path)
    if disk in snap.alias: key = snap.alias[disk]
    elif path in snap.alias: key = snap.alias[path]
    elif disk in snap.byKey: key = disk
    elif path in snap.byKey: key = path
    else:
      let canon = canonical(path)
      if canon in snap.alias: key = snap.alias[canon]
      elif canon in snap.byKey: key = canon
    if key.len > 0 and key in snap.byKey:
      result[path] = snap.byKey[key]

proc folderScan(folder, cache: string; snap: EditsSnapshot; sink: QualitySink;
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
    let scan = scanQuality(paths, editsFor(paths, snap), sink, cache)
    scan(ctx)

proc exportWork(path, beside: string; stations: seq[StationRow];
    records: seq[qualityreport.RecordRow];
    totals: Totals; ask: ExportAsk): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    let main = if ask.tab == qtRecords: recordsCsv(records) else: stationsCsv(stations)
    writeCsv(path, main)
    if ask.withTotals: writeCsv(beside, totalsCsv(totals))

proc finishScan(ui: var QualityUi; state: JobState; error: string) =
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
  ui.unread = ui.sink.result.unread
  ui.have = true
  ui.stationDirty = true
  ui.recordDirty = true
  ui.stationKey = ""
  ui.recordKey = ""
  ui.status = Ready

proc poll(ui: var QualityUi; st: AppState) =
  if ui.scanJob != NoJob:
    let info = st.jobs.info(ui.scanJob)
    if info.isNone:
      ui.scanJob = NoJob
      ui.scanning = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.scanning = true
      let p = info.get.progress
      ui.progressDone = p.done
      ui.progressTotal = p.total
      ui.status = if p.phase.len > 0: p.phase else: Scanning
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

proc submit(ui: var QualityUi; st: AppState) =
  let folder = st.fileList.folder
  if folder.len == 0: return
  if ui.scanJob != NoJob:
    discard st.jobs.cancel(ui.scanJob)
    ui.scanJob = NoJob
  let snap = st.editsSnapshot
  let cache = st.indexCache
  ui.folder = folder
  ui.note = ScanNote()
  ui.sink = QualitySink()
  ui.capped = false
  ui.scanning = true
  ui.progressDone = 0
  ui.progressTotal = 0
  ui.status = Scanning
  ui.scanJob = st.jobs.submit(qualitySpec(@[folder]),
    folderScan(folder, cache, snap, ui.sink, ui.note))

proc consider(ui: var QualityUi; st: AppState) =
  if not ui.sortsReady:
    ui.stationSort = DefaultStationSort
    ui.recordSort = DefaultRecordSort
    ui.sortsReady = true
  ui.poll(st)
  if ui.wantScan:
    ui.wantScan = false
    if canScan(st): ui.submit(st)
    elif not ui.have: ui.status = whyNot(st)

proc startExport*(ui: var QualityUi; st: AppState; path: string) =
  ## Writes the CSV asked for when Export CSV... was clicked, from the rows
  ## shown now. `path` gains ".csv" when it has no extension.
  if not ui.ask.live: return
  let ask = ui.ask
  ui.ask.live = false
  var dest = path
  if dest.splitFile.ext.len == 0: dest.add ".csv"
  let beside = totalsBeside(dest)
  let stations = ui.report.stations
  let records = ui.report.records
  let totals = ui.report.totals
  if ui.exportJob != NoJob:
    discard st.jobs.cancel(ui.exportJob)
    ui.exportJob = NoJob
  ui.exportJob = st.jobs.submit(JobSpec(title: "Export trace quality",
    lane: jlBackground, reads: @[ui.folder]),
    exportWork(dest, beside, stations, records, totals, ask))

proc takePending(ui: var QualityUi; st: AppState): seq[Command] =
  if not ui.pending.live: return
  for s in st.sessions:
    if canonical(s.path) != ui.pending.path: continue
    if s.gathers.len == 0: return
    let g = filerecs.findRecord(s.records, ui.pending.record)
    ui.pending.live = false
    if g >= 0:
      result.add Command(kind: ckGather, panel: MainPanel, gather: g)
    return

proc openRecord(ui: var QualityUi; st: AppState; file: string; record: float64): seq[Command] =
  if file.len == 0: return
  let path = canonical(file)
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

func stationName(c: StationSortColumn): string =
  case c
  of ssLine: ColLine
  of ssPoint: ColPoint
  of ssIndex: ColIndex
  of ssComponent: ColComponent
  of ssSeen: ColSeen
  of ssKilled: ColKilled
  of ssBad: ColBad
  of ssHeaderDead: ColHeaderDead
  of ssAllZero: ColAllZero
  of ssConstant: ColConstant
  of ssClipped: ColClipped
  of ssSpiky: ColSpiky
  of ssDcOffset: ColDcOffset
  of ssNonFinite: ColNonFinite
  of ssBadRecords: ColBadRecords

func recordName(c: RecordSortColumn): string =
  case c
  of rsFile: ColFile
  of rsRecord: ColRecord
  of rsSeen: ColSeen
  of rsKilled: ColKilled
  of rsBad: ColBad
  of rsHeaderDead: ColHeaderDead
  of rsAllZero: ColAllZero
  of rsConstant: ColConstant
  of rsClipped: ColClipped
  of rsSpiky: ColSpiky
  of rsDcOffset: ColDcOffset
  of rsNonFinite: ColNonFinite

func stationSortText(spec: SortSpec[StationSortColumn]): string =
  var parts: seq[string] = @[]
  for s in spec:
    parts.add stationName(s.column) & (if s.descending: "-" else: "")
  parts.join(",")

func recordSortText(spec: SortSpec[RecordSortColumn]): string =
  var parts: seq[string] = @[]
  for s in spec:
    parts.add recordName(s.column) & (if s.descending: "-" else: "")
  parts.join(",")

func firstLine(s: string): string =
  let n = s.find('\n')
  if n < 0: s else: s[0 ..< n]

func totalsMark(t: Totals): string =
  "quality.totals " & $t.files & " " & $t.records & " " & $t.traces & " " &
    $t.killed & " " & $t.bad & " " & $t.stations & " " & $t.counts[qfAllZero]

func stationMark(r: StationRow): string =
  "quality.station " & filerecs.stationNumber(r.line) & " " & filerecs.stationNumber(r.point) &
    " " & $r.index & " " & $r.component & " " & $r.seen & " " & $r.killed & " " &
    $r.bad & " " & $r.counts[qfAllZero]

proc tip(text: string) =
  if text.len == 0: return
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc headerCell(name: string; place: int; marks: var Marks; sentence = ""): bool =
  result = igSelectable_Bool((name & "##h").cstring, false, 0, ImVec2_c(x: 0, y: 0))
  marks.mark("quality.header " & name)
  if sentence.len > 0: tip(sentence)
  if place > 0:
    igSameLine(0, igGetStyle().ItemInnerSpacing.x)
    igPushFont(igGetFont(), igGetStyle().FontSizeBase * 0.72)
    igTextDisabled("%d", cint(place))
    igPopFont()

const
  tableFlags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint
  tabFlags = ImGui_TabBarFlags_DrawSelectedOverline.cint

proc setupColumns(names: openArray[string]) =
  let extra = igGetFontSize() * 1.5
  for i, name in names:
    let w = igCalcTextSize(name.cstring, nil, false, -1).x + extra
    igTableSetupColumn(name.cstring, ImGui_TableColumnFlags_WidthFixed.cint, w,
      ImGuiID(i + 1))
  igTableSetupScrollFreeze(1, 1)
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)

func filterText(buf: openArray[char]): string =
  result = ""
  for c in buf:
    if c == '\0': break
    result.add c

proc refreshStations(ui: var QualityUi) =
  let text = filterText(ui.stationFilter)
  let next = text & "|" & stationSortText(ui.stationSort) & "|" & $ui.report.stations.len
  if next == ui.stationKey: return
  ui.stationShown = filterStations(ui.report.stations, text)
  ui.stationKey = next

proc refreshRecords(ui: var QualityUi) =
  let text = filterText(ui.recordFilter)
  let next = text & "|" & recordSortText(ui.recordSort) & "|" & $ui.report.records.len
  if next == ui.recordKey: return
  ui.recordShown = filterRecords(ui.report.records, text)
  ui.recordKey = next

proc rightText(text: string) =
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let avail = igGetContentRegionAvail().x
  if avail > w: igSetCursorPosX(igGetCursorPosX() + avail - w)
  igTextUnformatted(text.cstring, nil)

proc numberCell(text: string) =
  if igTableNextColumn(): rightText(text)

proc textWidth(label: string): float32 =
  igCalcTextSize(label.cstring, nil, false, -1).x

proc buttonWidth(label: string): float32 =
  textWidth(label) + igGetStyle().FramePadding.x * 2 + 8

proc checkWidth(label: string): float32 =
  igGetFrameHeight() + igGetStyle().ItemInnerSpacing.x + textWidth(label) + 8

proc fitsBeside(need: float32): bool =
  let edge = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  edge - igGetItemRectMax().x >= need + igGetStyle().ItemSpacing.x

proc sameLineIfFits(need: float32) =
  if fitsBeside(need): igSameLine(0, -1)

proc drawStations(ui: var QualityUi; marks: var Marks) =
  if ui.stationDirty:
    sortStations(ui.report.stations, ui.stationSort)
    ui.stationDirty = false
    ui.stationKey = ""
  const names = [ColLine, ColPoint, ColIndex, ColComponent, ColSeen, ColKilled, ColBad,
    ColHeaderDead, ColAllZero, ColConstant, ColClipped, ColSpiky, ColDcOffset,
    ColNonFinite, ColBadRecords]
  const keys = [ssLine, ssPoint, ssIndex, ssComponent, ssSeen, ssKilled, ssBad,
    ssHeaderDead, ssAllZero, ssConstant, ssClipped, ssSpiky, ssDcOffset, ssNonFinite,
    ssBadRecords]
  ui.refreshStations()
  let rows = ui.report.stations
  let n = ui.stationShown.len
  if n == 0:
    igTextDisabled(NoRows)
    return
  if not igBeginTable("##stations", names.len.cint, tableFlags, ImVec2_c(x: 0, y: 0), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      if headerCell(name, placeOf(ui.stationSort, keys[c]), marks, headerTip(name)):
        clickSort(ui.stationSort, keys[c], igGetIO_Nil().KeyShift)
        ui.stationDirty = true
        ui.stationKey = ""
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let r = rows[ui.stationShown[int(i)]]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      discard igTableNextColumn()
      discard igSelectable_Bool((filerecs.stationNumber(r.line) & "##row").cstring, false,
        ImGui_SelectableFlags_SpanAllColumns.cint, ImVec2_c(x: 0, y: 0))
      marks.mark(stationMark(r))
      numberCell(filerecs.stationNumber(r.point))
      numberCell($r.index)
      numberCell($r.component)
      numberCell($r.seen)
      numberCell($r.killed)
      tip(KilledTip)
      numberCell($r.bad)
      tip(BadTip)
      numberCell($r.counts[qfHeaderDead])
      numberCell($r.counts[qfAllZero])
      numberCell($r.counts[qfConstant])
      numberCell($r.counts[qfClipped])
      numberCell($r.counts[qfSpiky])
      numberCell($r.counts[qfDcOffset])
      numberCell($r.counts[qfNonFinite])
      if igTableNextColumn():
        igTextUnformatted(firstLine(r.badRecords).cstring, nil)
        tip(r.badRecords)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()

proc drawRecords(ui: var QualityUi; st: AppState; marks: var Marks; commands: var seq[Command]) =
  if ui.recordDirty:
    sortRecords(ui.report.records, ui.recordSort)
    ui.recordDirty = false
    ui.recordKey = ""
  const names = [ColFile, ColRecord, ColSeen, ColKilled, ColBad, ColHeaderDead, ColAllZero,
    ColConstant, ColClipped, ColSpiky, ColDcOffset, ColNonFinite]
  const keys = [rsFile, rsRecord, rsSeen, rsKilled, rsBad, rsHeaderDead, rsAllZero,
    rsConstant, rsClipped, rsSpiky, rsDcOffset, rsNonFinite]
  ui.refreshRecords()
  let rows = ui.report.records
  let n = ui.recordShown.len
  if n == 0:
    igTextDisabled(NoRows)
    return
  if not igBeginTable("##records", names.len.cint, tableFlags, ImVec2_c(x: 0, y: 0), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      if headerCell(name, placeOf(ui.recordSort, keys[c]), marks, headerTip(name)):
        clickSort(ui.recordSort, keys[c], igGetIO_Nil().KeyShift)
        ui.recordDirty = true
        ui.recordKey = ""
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let r = rows[ui.recordShown[int(i)]]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      discard igTableNextColumn()
      let flags = ImGui_SelectableFlags_SpanAllColumns.cint or
        ImGui_SelectableFlags_AllowDoubleClick.cint
      let shown = r.file.extractFilename
      if igSelectable_Bool((shown & "##row").cstring, false, flags, ImVec2_c(x: 0, y: 0)) and
          ui.focus.acts and igIsMouseDoubleClicked_Nil(ImGui_MouseButton_Left.cint):
        for c in ui.openRecord(st, r.file, r.record): commands.add c
      marks.mark("quality.file " & shown)
      tip(r.file)
      if int(i) < 8: marks.mark("quality.record " & $int(i))
      numberCell(filerecs.stationNumber(r.record))
      numberCell($r.seen)
      numberCell($r.killed)
      tip(KilledTip)
      numberCell($r.bad)
      tip(BadTip)
      numberCell($r.counts[qfHeaderDead])
      numberCell($r.counts[qfAllZero])
      numberCell($r.counts[qfConstant])
      numberCell($r.counts[qfClipped])
      numberCell($r.counts[qfSpiky])
      numberCell($r.counts[qfDcOffset])
      numberCell($r.counts[qfNonFinite])
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

proc drawProgress(ui: QualityUi; commands: var seq[Command]; marks: var Marks) =
  let cancelW = buttonWidth(CancelButton)
  let width = max(igGetFontSize() * 6, igGetContentRegionAvail().x - cancelW -
    igGetStyle().ItemSpacing.x)
  let fraction = if ui.progressTotal > 0:
      min(1'f32, float32(ui.progressDone) / float32(ui.progressTotal))
    else: -float32(igGetTime())
  let overlay = if ui.progressTotal > 0: $ui.progressDone & " / " & $ui.progressTotal else: ""
  igProgressBar(fraction, ImVec2_c(x: width, y: 0), overlay.cstring)
  marks.mark("quality.progress")
  igSameLine(0, -1)
  if igButton(CancelButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.scanJob != NoJob:
    commands.add Command(kind: ckCancelJob, job: ui.scanJob)
  marks.mark("quality.cancel")

proc drawFiltered(ui: var QualityUi; st: AppState; marks: var Marks;
    commands: var seq[Command]) =
  if not ui.have: return
  let recordsTab = ui.tab == qtRecords
  let hint = IconFilter & "  " & (if recordsTab: FilterRecords else: FilterStations)
  let id = if recordsTab: "##filterrecords" else: "##filterstations"
  let buf = if recordsTab: addr ui.recordFilter[0] else: addr ui.stationFilter[0]
  igSetNextItemWidth(-1)
  discard igInputTextWithHint(id.cstring, hint.cstring, cast[cstring](buf),
    csize_t(ui.stationFilter.len), 0, nil, nil)
  marks.mark("quality.filter")
  tip(if recordsTab: FilterRecordsTip else: FilterStationsTip)
  if ui.tab == qtStations: ui.drawStations(marks)
  else: ui.drawRecords(st, marks, commands)

proc drawQuality*(ui: var QualityUi; title: string; st: AppState; marks: var Marks): QualityOutput =
  ## The window titled `title`. A scan asked for since the last draw starts here.
  ui.consider(st)
  result.commands = ui.takePending(st)
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("quality")
    if ui.status.len == 0: ui.status = if canScan(st): Ready else: whyNot(st)
    var status = ui.status
    if ui.capped and not ui.scanning:
      if status.len > 0: status.add " "
      status.add CappedNote
    igPushTextWrapPos(0)
    igTextUnformatted(status.cstring, nil)
    igPopTextWrapPos()
    if ui.scanning: marks.mark("quality.scanning")
    if ui.capped: marks.mark("quality.capped")
    if ui.have and not ui.scanning:
      marks.mark("quality.ready")
      let spec = if ui.tab == qtStations: stationSortText(ui.stationSort)
        else: recordSortText(ui.recordSort)
      marks.mark("quality.sort " & spec)
      igPushTextWrapPos(0)
      igTextUnformatted(totalsLine(ui.report.totals).cstring, nil)
      igPopTextWrapPos()
      marks.mark(totalsMark(ui.report.totals))
      marks.mark("quality.totalsline " & totalsLine(ui.report.totals))
      if ui.unread.len > 0:
        let note = unreadNote(ui.unread)
        igPushTextWrapPos(0)
        igTextUnformatted(note.cstring, nil)
        igPopTextWrapPos()
        marks.mark("quality.unreadnote " & note)
    let unreadLabel = countLabel(UnreadFiles, ui.unread.len)
    if ui.scanning: drawProgress(ui, result.commands, marks)
    else:
      igBeginDisabled(not canScan(st))
      if igButton(RescanButton.cstring, ImVec2_c(x: 0, y: 0)): ui.requestScan()
      igEndDisabled()
      marks.mark("quality.rescan")
    sameLineIfFits(buttonWidth(unreadLabel))
    if igButton(unreadLabel.cstring, ImVec2_c(x: 0, y: 0)):
      igOpenPopup_Str("##unread", 0)
    marks.mark("quality.unread")
    sameLineIfFits(checkWidth(WithTotals))
    discard igCheckbox((WithTotals & "##totals").cstring, addr ui.withTotals)
    marks.mark("quality.totalsbox")
    tip(TotalsTip)
    sameLineIfFits(buttonWidth(ExportButton))
    igBeginDisabled(not ui.have)
    if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
      ui.ask = ExportAsk(tab: ui.tab, withTotals: ui.withTotals, live: true)
      result.exportAsked = true
      let base = if ui.folder.len > 0: ui.folder else: st.fileList.folder
      result.exportPath = base / SuggestedName
    igEndDisabled()
    marks.mark("quality.export")
    var unreadLines: seq[string] = @[]
    for row in ui.unread: unreadLines.add row.path & " — " & row.why
    drawPopup("##unread", NoneUnread, "quality.unreadline ", unreadLines, marks)
    if igBeginTabBar("##qualitytabs", tabFlags):
      marks.mark("quality.tab")
      let stationsOn = igBeginTabItem(StationsTab.cstring, nil, 0)
      marks.mark("quality.tab Stations")
      if stationsOn:
        ui.tab = qtStations
        ui.drawFiltered(st, marks, result.commands)
        igEndTabItem()
      let recordsOn = igBeginTabItem(RecordsTab.cstring, nil, 0)
      marks.mark("quality.tab Records")
      if recordsOn:
        ui.tab = qtRecords
        ui.drawFiltered(st, marks, result.commands)
        igEndTabItem()
      igEndTabBar()
    marks.markOverflow("quality")
  ui.focus.settle()
  igEnd()
