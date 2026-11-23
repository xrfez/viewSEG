## The Missing traces window: a scan of the open folder (subfolders included)
## against the loaded relation file, two tables, and a CSV export. Totals wrap.
## The table fills the rest of the window; a box above it narrows the rows.
##
## The scan is a background job. The window reads its sink only after the job
## is no longer running. A cancel leaves the tables already shown. Listing uses
## the same file list the folder scan uses (`listedNames`), not a second walk
## posted to the file list.

import std/[os, strutils]
import parseSEG
import imguin/cimgui
import ../../core/[filejobs, filelist, filesystem, jobs, missingjobs, missingreport, state]
import ../../core/records as filerecs
import ../../view/missingwords
import focus, icons, marks, overflow

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
    folderFilter, recordFilter: array[128, char]
    folderShown, recordShown: seq[int]
    folderKey, recordKey: string

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
  ui.folderKey = ""
  ui.recordKey = ""
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
    igPushTextWrapPos(igGetFontSize() * 30)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc headerCell(name: string; place: int; marks: var Marks; sentence = ""): bool =
  result = igSelectable_Bool((name & "##h").cstring, false, 0, ImVec2_c(x: 0, y: 0))
  marks.mark("missing.header " & name)
  if sentence.len > 0: tip(sentence)
  if place > 0:
    igSameLine(0, igGetStyle().ItemInnerSpacing.x)
    igPushFont(igGetFont(), igGetStyle().FontSizeBase * 0.72)
    igTextDisabled("%d", cint(place))
    igPopFont()

const
  tableFlags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_ScrollY.cint or
    ImGui_TableFlags_ScrollX.cint or ImGui_TableFlags_Resizable.cint or
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingStretchProp.cint

proc setupColumns(names: openArray[string]) =
  for i, name in names:
    igTableSetupColumn(name.cstring, ImGui_TableColumnFlags_WidthStretch.cint,
      if i == 0: 3 else: 1, ImGuiID(i + 1))
  igTableSetupScrollFreeze(1, 1)
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)

func filterText(buf: openArray[char]): string =
  result = ""
  for c in buf:
    if c == '\0': break
    result.add c

func hasWord(text, word: string): bool =
  if word.len == 0: return true
  if text.len < word.len: return false
  for i in 0 .. text.len - word.len:
    var j = 0
    while j < word.len and text[i + j].toLowerAscii == word[j]: inc j
    if j == word.len: return true

func matchesWords(text: string; words: openArray[string]): bool =
  for w in words:
    if not hasWord(text, w): return false
  true

proc refreshFolder(ui: var MissingUi; words: seq[string]) =
  if words.len == 0:
    ui.folderKey = ""
    return
  let next = filterText(ui.folderFilter) & "|" & pointSortText(ui.pointSort) & "|" &
    $ui.report.points.len
  if next == ui.folderKey: return
  ui.folderShown.setLen 0
  for i, p in ui.report.points:
    let text = filerecs.stationNumber(p.line) & " " & filerecs.stationNumber(p.point)
    if matchesWords(text, words): ui.folderShown.add i
  ui.folderKey = next

proc refreshRecords(ui: var MissingUi; words: seq[string]) =
  if words.len == 0:
    ui.recordKey = ""
    return
  let next = filterText(ui.recordFilter) & "|" & recordSortText(ui.recordSort) & "|" &
    $ui.report.records.len
  if next == ui.recordKey: return
  ui.recordShown.setLen 0
  for i, r in ui.report.records:
    if matchesWords(r.file, words): ui.recordShown.add i
  ui.recordKey = next

proc rightText(text: string) =
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let avail = igGetContentRegionAvail().x
  if avail > w: igSetCursorPosX(igGetCursorPosX() + avail - w)
  igTextUnformatted(text.cstring, nil)

proc numberCell(text: string) =
  if igTableNextColumn(): rightText(text)

proc flagCell(on: bool; sentence: string) =
  if not igTableNextColumn(): return
  if on: igTextUnformatted(IconCheck.cstring, nil)
  else: igDummy(ImVec2_c(x: igGetFontSize(), y: igGetTextLineHeight()))
  tip(sentence)

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

proc pushRight(width: float32): bool =
  let spacing = igGetStyle().ItemSpacing.x
  let edge = igGetCursorScreenPos().x + igGetContentRegionAvail().x
  if edge - igGetItemRectMax().x >= width + spacing:
    igSameLine(0, 0)
    igSetCursorScreenPos(ImVec2_c(x: edge - width, y: igGetItemRectMin().y))
    return true
  if igGetContentRegionAvail().x >= width:
    igSetCursorPosX(igGetCursorPosX() + igGetContentRegionAvail().x - width)
    return true
  false

proc figureWidth(label, value: string; cap: float32): float32 =
  igPushFont(igGetFont(), igGetStyle().FontSizeBase * 0.72)
  let labelW = igCalcTextSize(label.cstring, nil, false, cap).x
  igPopFont()
  min(cap, max(labelW, igCalcTextSize(value.cstring, nil, false, -1).x) + 1)

proc drawFigure(label, value, mark, tipText: string; width: float32; marks: var Marks) =
  igBeginGroup()
  igPushFont(igGetFont(), igGetStyle().FontSizeBase * 0.72)
  igPushTextWrapPos(igGetCursorPos().x + width)
  igTextDisabled("%s", label.cstring)
  igPopTextWrapPos()
  igPopFont()
  igTextUnformatted(value.cstring, nil)
  igEndGroup()
  marks.mark("missing.figure " & mark)
  if tipText.len > 0: tip(tipText)

proc drawFigures(figs: openArray[tuple[label, value, mark, tip: string]]; marks: var Marks) =
  let spacing = igGetStyle().ItemSpacing.x
  let avail = max(igGetFontSize() * 6, igGetContentRegionAvail().x)
  for i, fig in figs:
    let cap = min(avail, igGetFontSize() * 14)
    let w = figureWidth(fig.label, fig.value, cap)
    if i > 0 and fitsBeside(w): igSameLine(0, spacing)
    drawFigure(fig.label, fig.value, fig.mark, fig.tip, min(w, cap), marks)

proc drawPoints(ui: var MissingUi; marks: var Marks) =
  if ui.pointDirty:
    sortPoints(ui.report.points, ui.pointSort)
    ui.pointDirty = false
    ui.folderKey = ""
  const names = [ColLine, ColPoint, ColIndex, ColExpectedIn, ColMissingIn, ColNever,
    ColUnknown, ColFirstRecord, ColLastRecord]
  const keys = [psLine, psPoint, psIndex, psExpectedIn, psMissingIn, psNever,
    psLine, psFirstRecord, psLastRecord]
  const on = [true, true, true, true, true, true, false, true, true]
  let words = filterWords(filterText(ui.folderFilter))
  ui.refreshFolder(words)
  let rows = ui.report.points
  let n = if words.len == 0: rows.len else: ui.folderShown.len
  if n == 0:
    igTextDisabled(NoRows)
    return
  if not igBeginTable("##points", names.len.cint, tableFlags, ImVec2_c(x: 0, y: 0), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      let place = if on[c]: placeOf(ui.pointSort, keys[c]) else: 0
      let sentence = if name == ColNever: NeverTip
        elif name == ColUnknown: UnknownTip
        elif not on[c]: NotSortable
        else: ""
      let clicked = headerCell(name, place, marks, sentence)
      if on[c] and clicked:
        clickSort(ui.pointSort, keys[c], igGetIO_Nil().KeyShift)
        ui.pointDirty = true
        ui.folderKey = ""
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let at = if words.len == 0: int(i) else: ui.folderShown[int(i)]
      let p = rows[at]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      numberCell(filerecs.stationNumber(p.line))
      numberCell(filerecs.stationNumber(p.point))
      numberCell($p.index)
      numberCell($p.expectedIn)
      numberCell($p.missingIn)
      flagCell(p.never, NeverTip)
      flagCell(p.expectedUnknown, UnknownTip)
      if igTableNextColumn():
        rightText(filerecs.stationNumber(p.firstRecord))
        tip(p.firstFile)
      if igTableNextColumn():
        rightText(filerecs.stationNumber(p.lastRecord))
        tip(p.lastFile)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()

proc drawRecords(ui: var MissingUi; st: AppState; marks: var Marks; commands: var seq[Command]) =
  if ui.recordDirty:
    sortRecords(ui.report.records, ui.recordSort)
    ui.recordDirty = false
    ui.recordKey = ""
  const names = [ColFile, ColRecord, ColExpected, ColPresent, ColMissing, ColDuplicates,
    ColExtras, ColAlsoIn, ColMissingPoints]
  const keys = [rsFile, rsRecord, rsExpected, rsPresent, rsMissing, rsDuplicates, rsUnlisted,
    rsFile, rsFile]
  const on = [true, true, true, true, true, true, true, false, false]
  let words = filterWords(filterText(ui.recordFilter))
  ui.refreshRecords(words)
  let rows = ui.report.records
  let n = if words.len == 0: rows.len else: ui.recordShown.len
  if n == 0:
    igTextDisabled(NoRows)
    return
  if not igBeginTable("##records", names.len.cint, tableFlags, ImVec2_c(x: 0, y: 0), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      let place = if on[c]: placeOf(ui.recordSort, keys[c]) else: 0
      let clicked = headerCell(name, place, marks, if on[c]: "" else: NotSortable)
      if on[c] and clicked:
        clickSort(ui.recordSort, keys[c], igGetIO_Nil().KeyShift)
        ui.recordDirty = true
        ui.recordKey = ""
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let at = if words.len == 0: int(i) else: ui.recordShown[int(i)]
      let r = rows[at]
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
      if int(i) < 8: marks.mark("missing.record " & $int(i))
      numberCell(filerecs.stationNumber(r.record))
      numberCell($r.expected)
      numberCell($r.present)
      numberCell($r.missing)
      numberCell($r.duplicates)
      numberCell($r.unlisted)
      numberCell($r.alsoIn)
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
    var status = ui.status
    if ui.capped:
      if status.len > 0: status.add " "
      status.add CappedNote
    igPushTextWrapPos(0)
    igTextUnformatted(status.cstring, nil)
    igPopTextWrapPos()
    if ui.scanning: marks.mark("missing.scanning")
    if ui.have and not ui.scanning:
      marks.mark("missing.ready")
      let spec = if ui.tab == mtFolder: pointSortText(ui.pointSort)
        else: recordSortText(ui.recordSort)
      marks.mark("missing.sort " & spec)
      let t = ui.report.totals
      let dupTip = if t.duplicates > 0: ui.report.duplicatesNote else: ""
      let missingValue = $t.missing & " (" & percentText(t.percentMissing) & "%)"
      igBeginGroup()
      drawFigures([
        (FigFiles, $t.files, "files", ""),
        (FigRecords, $t.records, "records", ""),
        (FigExpected, $t.expected, "expected", ""),
        (FigPresent, $t.present, "present", ""),
        (FigMissing, missingValue, "missing", ""),
        (FigNever, $t.never, "never", ""),
        (FigDuplicates, $t.duplicates, "duplicates", dupTip),
        (FigExtras, $t.extras, "extras", ""),
        (FigNoData, $t.xpsWithoutData.len, "nodata", "")], marks)
      igEndGroup()
      marks.mark(totalsMark(t))
      let here = igGetCursorScreenPos()
      marks.markRect("missing.totals.scroll", here, ImVec2_c(x: here.x, y: here.y + 1))
    template pointsBox() =
      discard igCheckbox((WithPoints & "##points").cstring, addr ui.withPoints)
      marks.mark("missing.points")
      tip(PointsTip)
    template totalsBox() =
      discard igCheckbox((WithTotals & "##totals").cstring, addr ui.withTotals)
      marks.mark("missing.totalsbox")
      tip(TotalsTip)
    template exportBox() =
      igBeginDisabled(not ui.have)
      if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
        ui.ask = ExportAsk(tab: ui.tab, withPoints: ui.withPoints,
          withTotals: ui.withTotals, live: true)
        result.exportAsked = true
        let base = if ui.folder.len > 0: ui.folder else: st.fileList.folder
        result.exportPath = base / SuggestedName
      igEndDisabled()
      marks.mark("missing.export")
    let skippedLabel = countLabel(SkippedFiles, ui.skipped.len)
    let unmatchedLabel = countLabel(UnmatchedRecords, ui.unmatched.len)
    if ui.scanning:
      if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.scanJob != NoJob:
        result.commands.add Command(kind: ckCancelJob, job: ui.scanJob)
      marks.mark("missing.stop")
    else:
      igBeginDisabled(not canScan(st))
      if igButton(RescanButton.cstring, ImVec2_c(x: 0, y: 0)): ui.requestScan()
      igEndDisabled()
      marks.mark("missing.rescan")
    sameLineIfFits(buttonWidth(skippedLabel))
    if igButton(skippedLabel.cstring, ImVec2_c(x: 0, y: 0)):
      igOpenPopup_Str("##skipped", 0)
    marks.mark("missing.skipped")
    sameLineIfFits(buttonWidth(unmatchedLabel))
    if igButton(unmatchedLabel.cstring, ImVec2_c(x: 0, y: 0)):
      igOpenPopup_Str("##unmatched", 0)
    marks.mark("missing.unmatched")
    var rightW = checkWidth(WithTotals) + igGetStyle().ItemSpacing.x + buttonWidth(ExportButton)
    if ui.tab == mtRecords:
      rightW += checkWidth(WithPoints) + igGetStyle().ItemSpacing.x
    if pushRight(rightW):
      if ui.tab == mtRecords:
        pointsBox()
        igSameLine(0, -1)
      totalsBox()
      igSameLine(0, -1)
      exportBox()
    else:
      if ui.tab == mtRecords:
        sameLineIfFits(checkWidth(WithPoints))
        pointsBox()
      sameLineIfFits(checkWidth(WithTotals))
      totalsBox()
      sameLineIfFits(buttonWidth(ExportButton))
      exportBox()
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
    if ui.have:
      let recordsTab = ui.tab == mtRecords
      let hint = IconFilter & "  " & (if recordsTab: FilterRecords else: FilterFolder)
      let id = if recordsTab: "##filterrecords" else: "##filterfolder"
      let buf = if recordsTab: addr ui.recordFilter[0] else: addr ui.folderFilter[0]
      igSetNextItemWidth(-1)
      discard igInputTextWithHint(id.cstring, hint.cstring, cast[cstring](buf),
        csize_t(ui.folderFilter.len), 0, nil, nil)
      marks.mark("missing.filter")
      tip(if recordsTab: FilterRecordsTip else: FilterFolderTip)
      if ui.tab == mtFolder: ui.drawPoints(marks)
      else: ui.drawRecords(st, marks, result.commands)
    marks.markOverflow("missing")
  ui.focus.settle()
  igEnd()
  ui.consider(st)
