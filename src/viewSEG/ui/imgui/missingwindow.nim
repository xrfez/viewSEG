## The Missing traces window: the stations the survey's relation records call
## for that a file does not hold, as a table of line, point and how many
## records lack it, under the figures that sum it up. Two tabs: File, the
## file shown (computed when the window is drawn), and Folder, the files of a
## folder the user chooses, computed only when Run is pressed (its subfolders
## only when the box says so). The window closes with its button.
##
## Both are background jobs (`scanMissing`). The window reads a sink only
## after its job is no longer running, and drops an answer that is no longer
## the one asked for (another file shown, another folder or the subfolders tick
## changed, another survey): the job is cancelled and its result never read.

import std/[os, strutils]
import parseSEG
import imguin/cimgui
import ../../core/[edits, filejobs, filelist, filesystem, jobs, missingjobs, missingreport, state]
import ../../core/records as filerecs
import ../../view/missingwords
import focus, icons, marks, overflow

type
  MissingTab* = enum
    mtFile, mtFolder

  ExportAsk* = object
    rows*: seq[StationRow]
    stats*: MissingStats
    withStats*, live*: bool

  Scan = object
    ## One tab's job and what it answered.
    job: JobId = NoJob
    sink: MissingSink
    note: ScanNote
    key: string ## what the job (or the answer) is for; "" for nothing asked
    running, have, capped: bool
    done, total: int64
    status: string
    result: MissingJobResult

  MissingUi* = object
    file, folder: Scan
    tab: MissingTab
    side: StationSide
    runAsked: bool
    chosen: string
    exportJob: JobId = NoJob
    exported: bool
    status: string
    withStats: bool
    ask: ExportAsk
    sort: SortSpec[StationSortColumn]
    sortsReady, sortDirty: bool
    focus: FocusClicks
    filter: array[128, char]
    shown: seq[int]
    shownKey: string

  MissingOutput* = object
    commands*: seq[Command]
    exportAsked*: bool
    exportPath*: string
    askFolder*: bool ## the Folder... button was clicked
    askAt*: string
    close*: bool     ## the window's close button was clicked

proc setFolder*(ui: var MissingUi; path: string) =
  ## The folder dialog's answer: kept in the settings on the next draw.
  ui.chosen = path

proc surveyKey(st: AppState): string =
  ## Which survey the answers are for: the layer holding the relation records and
  ## its relations (a reloaded file is another).
  let layer = st.relationLayer
  if layer < 0: ""
  else: $layer & "@" & $cast[int](st.survey.layers[layer].relations)

proc shownPath(st: AppState): string =
  ## The disk path of the file shown in the main panel; "" for none.
  let panel = st.findPanel(MainPanel)
  let shown = if panel >= 0: st.shownFile(panel) else: -1
  if shown >= 0: st.sessions[shown].diskPath else: ""

proc shownHasKilled(st: AppState): bool =
  ## Whether the file shown in the main panel has killed traces.
  let panel = st.findPanel(MainPanel)
  let shown = if panel >= 0: st.shownFile(panel) else: -1
  shown >= 0 and st.editsAt(st.sessions[shown].path).anyKilled

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
    ImGui_TableFlags_BordersInnerV.cint or ImGui_TableFlags_SizingFixedFit.cint
  tabFlags = ImGui_TabBarFlags_DrawSelectedOverline.cint

proc setupColumns(names: openArray[string]; wide: openArray[float32]) =
  ## Each column is as wide as its title and the sort number after it, or `wide[i]` font
  ## sizes when that is more (file names, point lists). A table wider than the window scrolls
  ## sideways; a title is never cut.
  let extra = igGetFontSize() * 1.5
  for i, name in names:
    let w = max(igCalcTextSize(name.cstring, nil, false, -1).x + extra,
      wide[i] * igGetFontSize())
    igTableSetupColumn(name.cstring, ImGui_TableColumnFlags_WidthFixed.cint, w,
      ImGuiID(i + 1))
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

func statsBeside(path: string): string =
  let s = path.splitFile
  let ext = if s.ext.len == 0: ".csv" else: s.ext
  s.dir / (s.name & "-statistics" & ext)

func sortText(spec: SortSpec[StationSortColumn]): string =
  var parts: seq[string] = @[]
  for s in spec:
    let name = case s.column
      of scLine: ColLine
      of scPoint: ColPoint
      of scMissing: ColMissing
    parts.add name & (if s.descending: "-" else: "")
  parts.join(",")

proc cancel(s: var Scan; st: AppState) =
  if s.job != NoJob: discard st.jobs.cancel(s.job)
  s = Scan()

proc finish(ui: var MissingUi; s: var Scan; state: JobState; error: string) =
  s.running = false
  if s.note != nil: s.capped = s.note.capped
  if state == jsCancelled:
    s.status = Stopped
    return
  let failed = state == jsFailed or s.sink == nil or not s.sink.result.ok
  if failed:
    s.status =
      if s.sink != nil and s.sink.result.reason.len > 0: s.sink.result.reason
      elif error.len > 0: error
      else: ScanFailed
    return
  s.result = s.sink.result
  s.have = true
  s.status = Ready
  ui.sortDirty = true
  ui.shownKey = ""
  if ui.side == ssReceivers and s.result.shot.stats.records == 0 and
      s.result.receiver.stats.records > 0:
    ui.side = ssSources
  elif ui.side == ssSources and s.result.receiver.stats.records == 0 and
      s.result.shot.stats.records > 0:
    ui.side = ssReceivers

proc poll(ui: var MissingUi; s: var Scan; st: AppState) =
  if s.job == NoJob: return
  let info = st.jobs.info(s.job)
  if info.isNone:
    s.job = NoJob
    s.running = false
  elif info.get.state in {jsQueued, jsRunning}:
    s.running = true
    s.done = info.get.progress.done
    s.total = info.get.progress.total
    let phase = info.get.progress.phase
    s.status = if phase.len > 0: phase else: Scanning
  else:
    ui.finish(s, info.get.state, info.get.error)
    s.job = NoJob

proc submitFile(ui: var MissingUi; st: AppState; key, path: string) =
  let layer = st.relationLayer
  let folder = path.parentDir
  ui.file = Scan(key: key, running: true, status: Scanning, sink: MissingSink())
  var spec = missingSpec(folder, @[path])
  spec.title = "Missing traces in " & path.extractFilename
  ui.file.job = st.jobs.submit(spec,
    scanMissing(folder, @[path], st.survey.layers[layer].relations, ui.file.sink,
      st.indexCache))

proc submitFolder(ui: var MissingUi; st: AppState; key: string) =
  let layer = st.relationLayer
  let folder = st.settings.missing.folder
  ui.folder = Scan(key: key, running: true, status: Scanning, sink: MissingSink(),
    note: ScanNote())
  ui.folder.job = st.jobs.submit(missingSpec(folder, @[folder]),
    folderScan(folder, st.settings.missing.subfolders, st.indexCache,
      st.survey.layers[layer].relations, ui.folder.sink, ui.folder.note))

proc consider(ui: var MissingUi; st: AppState) =
  ## Polls the jobs, drops an answer that is stale, and starts the File
  ## computation for the file shown. Nothing here lists or reads a folder
  ## unless Run was pressed.
  if not ui.sortsReady:
    ui.sort = DefaultStationSort
    ui.sortsReady = true
  ui.poll(ui.file, st)
  ui.poll(ui.folder, st)
  let survey = st.surveyKey
  let path = st.shownPath
  let fileKey = if survey.len > 0 and path.len > 0: path & "|" & survey else: ""
  if fileKey != ui.file.key:
    ui.file.cancel(st)
    ui.shownKey = ""
    if fileKey.len > 0: ui.submitFile(st, fileKey, path)
  let folder = st.settings.missing.folder
  let folderKey = if survey.len > 0 and folder.len > 0:
    folder & "|" & $st.settings.missing.subfolders & "|" & survey else: ""
  if ui.folder.key.len > 0 and ui.folder.key != folderKey:
    ui.folder.cancel(st)
    ui.shownKey = ""
  if ui.runAsked:
    ui.runAsked = false
    if folderKey.len > 0:
      ui.folder.cancel(st)
      ui.submitFolder(st, folderKey)

proc startExport*(ui: var MissingUi; st: AppState; path: string) =
  ## Writes the CSV asked for when Export CSV... was clicked: the list shown
  ## then, and the statistics beside it when asked. `path` gains ".csv" when
  ## it has no extension.
  if not ui.ask.live: return
  let ask = ui.ask
  ui.ask.live = false
  var dest = path
  if dest.splitFile.ext.len == 0: dest.add ".csv"
  let beside = statsBeside(dest)
  if ui.exportJob != NoJob:
    discard st.jobs.cancel(ui.exportJob)
    ui.exportJob = NoJob
  ui.exportJob = st.jobs.submit(JobSpec(title: "Export missing traces",
    lane: jlBackground, reads: @[]), proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    writeCsv(dest, stationsCsv(ask.rows))
    if ask.withStats: writeCsv(beside, statsCsv(ask.stats)))

proc pollExport(ui: var MissingUi; st: AppState) =
  if ui.exportJob == NoJob: return
  let info = st.jobs.info(ui.exportJob)
  if info.isNone: ui.exportJob = NoJob
  elif info.get.state notin {jsQueued, jsRunning}:
    if info.get.state == jsDone:
      ui.exported = true
      ui.status = Written
    elif info.get.state == jsFailed:
      ui.status = if info.get.error.len > 0: info.get.error else: ExportFailed
    ui.exportJob = NoJob

proc applySort(ui: var MissingUi) =
  if not ui.sortDirty: return
  ui.sortDirty = false
  for s in [addr ui.file, addr ui.folder]:
    sortStations(s.result.shot.rows, ui.sort)
    sortStations(s.result.receiver.rows, ui.sort)

proc drawRows(ui: var MissingUi; rows: seq[StationRow]; key: string; marks: var Marks) =
  let words = filterWords(filterText(ui.filter))
  let next = key & "|" & filterText(ui.filter) & "|" & sortText(ui.sort) & "|" & $rows.len
  if words.len > 0 and next != ui.shownKey:
    ui.shown.setLen 0
    for i, r in rows:
      if matchesWords(filerecs.stationNumber(r.line) & " " & filerecs.stationNumber(r.point),
          words): ui.shown.add i
    ui.shownKey = next
  let n = if words.len == 0: rows.len else: ui.shown.len
  if n == 0:
    igTextDisabled(if rows.len == 0: NothingMissing else: NoRows)
    marks.mark("missing.norows")
    return
  const names = [ColLine, ColPoint, ColMissing]
  const keys = [scLine, scPoint, scMissing]
  if not igBeginTable("##stations", names.len.cint, tableFlags, ImVec2_c(x: 0, y: 0), 0):
    return
  setupColumns(names, [0'f32, 0, 0])
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      let clicked = headerCell(name, placeOf(ui.sort, keys[c]), marks,
        if keys[c] == scMissing: MissingTip else: "")
      if clicked:
        clickSort(ui.sort, keys[c], igGetIO_Nil().KeyShift)
        ui.sortDirty = true
        ui.shownKey = ""
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let at = if words.len == 0: int(i) else: ui.shown[int(i)]
      let r = rows[at]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      numberCell(filerecs.stationNumber(r.line))
      numberCell(filerecs.stationNumber(r.point))
      numberCell($r.missing)
      if int(i) < 8:
        marks.mark("missing.row " & filerecs.stationNumber(r.line) & " " &
          filerecs.stationNumber(r.point) & " " & $r.missing)
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()

proc drawScan(ui: var MissingUi; st: AppState; folderTab: bool; marks: var Marks;
    out0: var MissingOutput) =
  ## What a tab shows below its own controls: a sentence for what is missing, the
  ## job in progress, or the figures and the table.
  template s: untyped = (if folderTab: ui.folder else: ui.file)
  if st.relationLayer < 0:
    igPushTextWrapPos(0)
    igTextUnformatted(NoTemplate.cstring, nil)
    igPopTextWrapPos()
    marks.mark("missing.message " & NoTemplate)
    return
  if not folderTab and ui.file.key.len == 0:
    igTextUnformatted(NeedFile.cstring, nil)
    marks.mark("missing.message " & NeedFile)
    return
  if folderTab and ui.folder.key.len == 0:
    igTextUnformatted((if st.settings.missing.folder.len == 0: NeedFolder
      else: "Press Run to check " & st.settings.missing.folder & ".").cstring, nil)
    marks.mark("missing.message folder")
    return
  if s.running:
    marks.mark("missing.scanning")
    igTextUnformatted(s.status.cstring, nil)
    let fraction = if s.total > 0: clamp(float32(s.done) / float32(s.total), 0, 1) else: 0'f32
    igProgressBar(fraction, ImVec2_c(x: igGetFontSize() * 12, y: 0), "")
    marks.mark("missing.progress")
    igSameLine(0, -1)
    if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and s.job != NoJob:
      out0.commands.add Command(kind: ckCancelJob, job: s.job)
    marks.mark("missing.stop")
    return
  if not s.have:
    igPushTextWrapPos(0)
    igTextUnformatted(s.status.cstring, nil)
    igPopTextWrapPos()
    return
  marks.mark("missing.ready")
  let r = s.result
  var status = ""
  if s.capped: status = CappedNote
  if status.len > 0: igTextUnformatted(status.cstring, nil)
  if r.notChecked.len > 0 and not folderTab:
    igTextUnformatted(Continuous.cstring, nil)
    marks.mark("missing.message " & Continuous)
  if r.shot.stats.records == 0 and r.receiver.stats.records == 0:
    if not (r.notChecked.len > 0 and not folderTab):
      igPushTextWrapPos(0)
      igTextUnformatted(NoTemplateRecord.cstring, nil)
      igPopTextWrapPos()
      marks.mark("missing.message " & NoTemplateRecord)
  else:
    if r.shot.stats.records > 0 and r.receiver.stats.records > 0:
      var sources = ui.side == ssSources
      if igRadioButton_Bool(ReceiversOption.cstring, not sources): ui.side = ssReceivers
      igSameLine(0, -1)
      if igRadioButton_Bool(SourcesOption.cstring, sources): ui.side = ssSources
      marks.mark("missing.side")
    let side = if ui.side == ssReceivers: r.shot else: r.receiver
    marks.mark("missing.sort " & sortText(ui.sort))
    let counts = countsLine(side.stats, folderTab)
    igTextUnformatted(counts.cstring, nil)
    marks.mark("missing.counts " & counts)
    for line in statisticLines(side.stats, folderTab):
      igTextUnformatted(line.cstring, nil)
      marks.mark("missing.stat " & line)
    if not folderTab and st.shownHasKilled:
      igTextUnformatted(KilledNote.cstring, nil)
      marks.mark("missing.message " & KilledNote)
    if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
      ui.ask = ExportAsk(rows: side.rows, stats: side.stats, withStats: ui.withStats,
        live: true)
      out0.exportAsked = true
      out0.exportPath = (if folderTab and st.settings.missing.folder.len > 0:
        st.settings.missing.folder else: st.shownPath.parentDir) / SuggestedName
    marks.mark("missing.export")
    igSameLine(0, -1)
    discard igCheckbox((WithStats & "##stats").cstring, addr ui.withStats)
    marks.mark("missing.statsbox")
    tip(StatsTip)
  var skippedLines: seq[string] = @[]
  for row in r.skipped: skippedLines.add row.path & " — " & row.why
  var unmatchedLines: seq[string] = @[]
  for row in r.unmatched: unmatchedLines.add row.path & " " & $row.record & ": " & row.why
  var notCheckedLines: seq[string] = @[]
  for row in r.notChecked: notCheckedLines.add row.path & " — " & row.why
  template popupButton(label, id, markName: string) =
    if igButton(label.cstring, ImVec2_c(x: 0, y: 0)): igOpenPopup_Str(id.cstring, 0)
    marks.mark(markName)
    igSameLine(0, -1)
  popupButton(countLabel(SkippedFiles, r.skipped.len), "##skipped", "missing.skipped")
  popupButton(countLabel(UnmatchedRecords, r.unmatched.len), "##unmatched",
    "missing.unmatched")
  if folderTab:
    popupButton(countLabel(NotChecked, r.notChecked.len), "##notchecked",
      "missing.notchecked")
  igNewLine()
  drawPopup("##skipped", NoneSkipped, "missing.skippedline ", skippedLines, marks)
  drawPopup("##unmatched", NoneUnmatched, "", unmatchedLines, marks)
  drawPopup("##notchecked", NoneNotChecked, "missing.notcheckedline ", notCheckedLines, marks)
  if r.shot.stats.records > 0 or r.receiver.stats.records > 0:
    let side = if ui.side == ssReceivers: r.shot else: r.receiver
    igSetNextItemWidth(-1)
    discard igInputTextWithHint("##filterstations", (IconFilter & "  " & FilterStations).cstring,
      cast[cstring](addr ui.filter[0]), csize_t(ui.filter.len), 0, nil, nil)
    marks.mark("missing.filter")
    tip(FilterStationsTip)
    ui.drawRows(side.rows, (if folderTab: "folder" else: "file") & $ui.side, marks)

proc drawFolderControls(ui: var MissingUi; st: AppState; marks: var Marks;
    out0: var MissingOutput) =
  if igButton(FolderButton.cstring, ImVec2_c(x: 0, y: 0)):
    out0.askFolder = true
    out0.askAt = st.settings.missing.folder
  marks.mark("missing.folderbutton")
  igSameLine(0, -1)
  let chosen = st.settings.missing.folder
  igTextUnformatted((if chosen.len > 0: chosen else: NoFolderChosen).cstring, nil)
  marks.mark("missing.folderpath " & chosen)
  var sub = st.settings.missing.subfolders
  if igCheckbox((SubfoldersBox & "##subfolders").cstring, addr sub) and ui.focus.acts:
    var s = st.settings
    s.missing.subfolders = sub
    out0.commands.add Command(kind: ckSettings, settings: s)
  marks.mark("missing.subfolders")
  if sub: marks.mark("missing.subfolderson")
  tip(SubfoldersTip)
  igSameLine(0, -1)
  igBeginDisabled(chosen.len == 0 or st.relationLayer < 0 or ui.folder.running)
  if igButton(RunButton.cstring, ImVec2_c(x: 0, y: 0)): ui.runAsked = true
  igEndDisabled()
  marks.mark("missing.run")

proc drawMissing*(ui: var MissingUi; title: string; st: AppState; marks: var Marks): MissingOutput =
  ## The window titled `title`. Closing it cancels what runs.
  if ui.chosen.len > 0:
    var s = st.settings
    s.missing.folder = ui.chosen
    ui.chosen = ""
    result.commands.add Command(kind: ckSettings, settings: s)
  ui.consider(st)
  ui.pollExport(st)
  ui.applySort()
  var open = true
  if igBegin(title.cstring, addr open, 0):
    ui.focus.watch()
    marks.markWindow("missing")
    if ui.status.len > 0:
      igTextUnformatted(ui.status.cstring, nil)
      marks.mark("missing.exported")
    if igBeginTabBar("##missingtabs", tabFlags):
      marks.mark("missing.tab")
      let fileOn = igBeginTabItem(FileTab.cstring, nil, 0)
      marks.mark("missing.tab File")
      if fileOn:
        ui.tab = mtFile
        ui.drawScan(st, false, marks, result)
        igEndTabItem()
      let folderOn = igBeginTabItem(FolderTab.cstring, nil, 0)
      marks.mark("missing.tab Folder")
      if folderOn:
        ui.tab = mtFolder
        ui.drawFolderControls(st, marks, result)
        ui.drawScan(st, true, marks, result)
        igEndTabItem()
      igEndTabBar()
    marks.markOverflow("missing")
  ui.focus.settle()
  igEnd()
  if not open:
    result.close = true
    ui.file.cancel(st)
    ui.folder.cancel(st)
