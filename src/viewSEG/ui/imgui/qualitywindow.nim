## The Trace quality window: the traces of the stations measured, as a table of one
## row per station (line and point) with a count for each problem, under the figures
## that sum it up. Two tabs: File, the file shown (computed when the window is drawn), and
## Folder, the files of a folder the user chooses, computed only when Run is pressed (its
## subfolders only when the box says so). The window closes with its button.
##
## Both are background jobs (`fileScan`, `folderScan`). The window reads a sink only after
## its job is no longer running, and drops an answer that is no longer the one asked for
## (another file shown or edited, another folder or the subfolders tick changed): the job is
## cancelled and its result never read. Edits are copied on the UI thread (`editsSnapshot`)
## before a job is submitted: the worker must not read `AppState`. Nothing here is looked up
## by a record number.

import std/[algorithm, os, strutils, tables]
import imguin/cimgui
import ../../core/[edits, filesystem, jobs, qualityjobs, qualityreport, settings, state]
import ../../core/records as filerecs
import ../../view/qualitywords
import focus, icons, marks, overflow, windows

type
  ExportAsk* = object
    rows*: seq[StationRow]
    totals*: Totals
    side*: StationSide
    taken*: seq[string] ## files the CSV must not replace
    withStats*, live*: bool

  Scan = object
    ## One tab's job and what it answered.
    job: JobId = NoJob
    sink: QualitySink
    note: QualityNote
    key: string       ## what the job (or the answer) is for; "" for nothing asked
    running, have, capped: bool
    side: StationSide ## the stations this tab shows when its result holds both sides
    done, total: int64
    status: string
    result: QualityJobResult

  QualityUi* = object
    file, folder: Scan
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
    filter: array[2, array[128, char]] ## the box of each tab
    shown: array[2, seq[int]]
    shownKey: array[2, string]

  QualityOutput* = object
    commands*: seq[Command]
    exportAsked*: bool
    exportPath*: string
    askFolder*: bool ## the Folder... button was clicked
    askAt*: string

proc setFolder*(ui: var QualityUi; path: string) =
  ## The folder dialog's answer: kept in the settings on the next draw.
  ui.chosen = path

proc shownPath(st: AppState): string =
  ## The disk path of the file shown in the main panel; "" for none.
  let panel = st.findPanel(MainPanel)
  let shown = if panel >= 0: st.shownFile(panel) else: -1
  if shown >= 0: st.sessions[shown].diskPath else: ""

proc shownIsSignature(st: AppState): bool =
  ## Whether the file shown is a vibrator signature file, which this window does not measure.
  let panel = st.findPanel(MainPanel)
  let shown = if panel >= 0: st.shownFile(panel) else: -1
  shown >= 0 and st.sessions[shown].signature.kind != sgNone

proc shownRevision(st: AppState): int =
  ## The revision of the shown file's edits, so a kill or an undo measures it again.
  let panel = st.findPanel(MainPanel)
  let shown = if panel >= 0: st.shownFile(panel) else: -1
  if shown >= 0: st.editsAt(st.sessions[shown].path).revision else: -1

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

proc statsBeside(path: string): string =
  let s = path.splitFile
  let ext = if s.ext.len == 0: ".csv" else: s.ext
  s.dir / (s.name & "-statistics" & ext)

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

func columnName(c: StationSortColumn): string =
  case c
  of ssLine: ColLine
  of ssPoint: ColPoint
  of ssLacking: ColLacking
  of ssLackFiles: ColLackFiles
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
  of ssNoisyTested: ColNoisyTested
  of ssNoisy: ColNoisy
  of ssWeakTested: ColWeakTested
  of ssWeak: ColWeak

func sortText(spec: SortSpec[StationSortColumn]): string =
  var parts: seq[string] = @[]
  for s in spec:
    parts.add columnName(s.column) & (if s.descending: "-" else: "")
  parts.join(",")

func stationMark(r: StationRow): string =
  "quality.station " & r.lineText & " " & r.pointText &
    " " & $r.seen & " " & $r.killed & " " & $r.bad & " " & $r.counts[qfAllZero] & " " &
    (if r.lacking == {}: "-" else: componentList(r.lacking).replace(", ", ",")) & " " &
    $r.lackFiles

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
  ## Each column is as wide as its title and the sort number after it. A table wider than
  ## the window scrolls sideways; a title is never cut.
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

proc rightText(text: string) =
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let avail = igGetContentRegionAvail().x
  if avail > w: igSetCursorPosX(igGetCursorPosX() + avail - w)
  igTextUnformatted(text.cstring, nil)

proc numberCell(text: string) =
  if igTableNextColumn(): rightText(text)

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

proc cancel(s: var Scan; st: AppState) =
  if s.job != NoJob: discard st.jobs.cancel(s.job)
  s = Scan()

func reportOf(r: QualityJobResult; side: StationSide): QualityReport =
  if side == ssReceivers: r.receivers else: r.sources

proc finish(ui: var QualityUi; s: var Scan; state: JobState; error: string) =
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
  s.side = if s.result.receivers.totals.traces >= s.result.sources.totals.traces: ssReceivers
    else: ssSources
  ui.sortDirty = true
  ui.shownKey = ["", ""]

proc poll(ui: var QualityUi; s: var Scan; st: AppState) =
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

proc forcedKey(st: AppState; only = ""): string =
  ## The kinds of recording the user set in the Files window (those of file `only`, when
  ## given): a change of them makes an answer stale.
  var forced: seq[string] = @[]
  for path, kind in st.forcedKinds:
    if only.len == 0 or path == canonical(only): forced.add path & "=" & $kind
  forced.sort()
  forced.join(";")

proc templateKey(st: AppState): string =
  ## Which relation records the answers are read against (the loaded or made geometry, by
  ## address) and whether only the traces in the template are measured: a change drops them.
  let x = st.qcRelations(rdSource)[0]
  let o = st.qcRelations(rdReceiver)[0]
  $st.settings.noise.templateOnly & "|" & $cast[int](x) & "|" & $cast[int](o) & "|" &
    $st.settings.join.traceMatch

proc submitFile(ui: var QualityUi; st: AppState; key, path: string) =
  ui.file = Scan(key: key, running: true, status: Scanning, sink: QualitySink())
  var spec = qualitySpec(@[path])
  spec.title = "Trace quality in " & path.extractFilename
  spec.auto = true # started by the program as the file shown changes: its end is not announced
  ui.file.job = st.jobs.submit(spec,
    fileScan(path, st.indexCache, st.editsSnapshot, ui.file.sink, st.settings.noise,
      st.forcedKinds, relations = st.qcRelations(rdSource)[0],
      receivers = st.qcRelations(rdReceiver)[0], traceMatch = st.settings.join.traceMatch))

proc submitFolder(ui: var QualityUi; st: AppState; key: string) =
  let folder = st.settings.quality.folder
  let name = folder.extractFilename
  ui.folder = Scan(key: key, running: true, status: Scanning, sink: QualitySink(),
    note: QualityNote())
  var spec = qualitySpec(@[folder])
  spec.title = if name.len == 0: "Trace quality" else: "Trace quality in " & name
  ui.folder.job = st.jobs.submit(spec,
    folderScan(folder, st.settings.quality.subfolders, st.indexCache, st.editsSnapshot,
      ui.folder.sink, ui.folder.note, st.settings.noise, st.forcedKinds,
      st.settings.quality.untold, relations = st.qcRelations(rdSource)[0],
      receivers = st.qcRelations(rdReceiver)[0], traceMatch = st.settings.join.traceMatch))

proc consider(ui: var QualityUi; st: AppState) =
  ## Polls the jobs, drops an answer that is stale, and starts the File computation for
  ## the file shown. Nothing here lists or reads a folder unless Run was pressed.
  if not ui.sortsReady:
    ui.sort = DefaultStationSort
    ui.sortsReady = true
  ui.poll(ui.file, st)
  ui.poll(ui.folder, st)
  let path = st.shownPath
  let fileKey = if path.len > 0 and not st.shownIsSignature:
      path & "|" & $st.shownRevision & "|" & st.forcedKey(path) & "|" & st.templateKey
    else: ""
  if fileKey != ui.file.key:
    ui.file.cancel(st)
    ui.shownKey = ["", ""]
    if fileKey.len > 0: ui.submitFile(st, fileKey, path)
  let folder = st.settings.quality.folder
  let folderKey = if folder.len > 0:
      folder & "|" & $st.settings.quality.subfolders & "|" & $st.settings.quality.untold & "|" &
        st.forcedKey & "|" & st.templateKey
    else: ""
  if ui.folder.key.len > 0 and ui.folder.key != folderKey:
    ui.folder.cancel(st)
    ui.shownKey = ["", ""]
  if ui.runAsked:
    ui.runAsked = false
    if folderKey.len > 0:
      ui.folder.cancel(st)
      ui.submitFolder(st, folderKey)

proc startExport*(ui: var QualityUi; st: AppState; path: string) =
  ## Writes the CSV asked for when Export CSV... was clicked: the list shown then, and
  ## the statistics beside it when asked. `path` gains ".csv" when it has no extension.
  if not ui.ask.live: return
  let ask = ui.ask
  ui.ask.live = false
  var dest = path
  if dest.splitFile.ext.len == 0: dest.add ".csv"
  let beside = statsBeside(dest)
  if ui.exportJob != NoJob:
    discard st.jobs.cancel(ui.exportJob)
    ui.exportJob = NoJob
  ui.exportJob = st.jobs.submit(JobSpec(title: "Export trace quality",
    lane: jlBackground, reads: @[]), proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if normalizedPath(dest) in ask.taken or normalizedPath(beside) in ask.taken:
      raise newException(IOError, ExportIsData)
    let head = "# " & ask.side.stationNoun & " stations\n"
    writeCsv(dest, head & stationsCsv(ask.rows))
    if ask.withStats: writeCsv(beside, head & totalsCsv(ask.totals)))

proc pollExport(ui: var QualityUi; st: AppState) =
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

proc applySort(ui: var QualityUi) =
  if not ui.sortDirty: return
  ui.sortDirty = false
  for s in [addr ui.file, addr ui.folder]:
    sortStations(s.result.receivers.stations, ui.sort)
    sortStations(s.result.sources.stations, ui.sort)

proc drawRows(ui: var QualityUi; report: QualityReport; tab: int; key: string;
    marks: var Marks) =
  let text = filterText(ui.filter[tab])
  let rows = report.stations
  let next = key & "|" & text & "|" & sortText(ui.sort) & "|" & $rows.len
  if next != ui.shownKey[tab]:
    ui.shown[tab] = filterStations(rows, text)
    ui.shownKey[tab] = next
  let n = ui.shown[tab].len
  if n == 0:
    igTextDisabled(if rows.len == 0: NoStations else: NoRows)
    marks.mark("quality.norows")
    return
  var names = @[ColLine, ColPoint]
  var keys = @[ssLine, ssPoint]
  if report.totals.components > 1:
    names.add ColLacking
    keys.add ssLacking
    names.add ColLackFiles
    keys.add ssLackFiles
  for (name, column) in [(ColSeen, ssSeen), (ColKilled, ssKilled), (ColBad, ssBad),
      (ColHeaderDead, ssHeaderDead), (ColAllZero, ssAllZero), (ColConstant, ssConstant),
      (ColClipped, ssClipped), (ColSpiky, ssSpiky), (ColDcOffset, ssDcOffset),
      (ColNonFinite, ssNonFinite), (ColNoisyTested, ssNoisyTested), (ColNoisy, ssNoisy),
      (ColWeakTested, ssWeakTested), (ColWeak, ssWeak)]:
    names.add name
    keys.add column
  if not igBeginTable("##stations", names.len.cint, tableFlags, ImVec2_c(x: 0, y: 0), 0):
    return
  setupColumns(names)
  for c, name in names:
    if igTableSetColumnIndex(cint(c)):
      if headerCell(name, placeOf(ui.sort, keys[c]), marks, headerTip(name)):
        clickSort(ui.sort, keys[c], igGetIO_Nil().KeyShift)
        ui.sortDirty = true
        ui.shownKey = ["", ""]
  let clipper = ImGuiListClipper_ImGuiListClipper()
  ImGuiListClipper_Begin(clipper, cint(n), -1)
  while ImGuiListClipper_Step(clipper):
    for i in clipper.DisplayStart ..< clipper.DisplayEnd:
      let r = rows[ui.shown[tab][int(i)]]
      igTableNextRow(0, 0)
      igPushID_Int(cint(i))
      numberCell(r.lineText)
      numberCell(r.pointText)
      if report.totals.components > 1:
        if igTableNextColumn():
          igTextUnformatted(componentList(r.lacking).cstring, nil)
        numberCell($r.lackFiles)
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
      numberCell($r.noisyTested)
      tip(NoisyTestedTip)
      numberCell(noiseCell(r.noisyTested, r.noisy))
      tip(NoisyTip)
      numberCell($r.weakTested)
      tip(WeakTestedTip)
      numberCell(noiseCell(r.weakTested, r.weak))
      tip(WeakTip)
      if int(i) < 8: marks.mark(stationMark(r))
      igPopID()
  ImGuiListClipper_End(clipper)
  ImGuiListClipper_destroy(clipper)
  igEndTable()

proc drawProgress(s: Scan; commands: var seq[Command]; marks: var Marks) =
  igTextUnformatted(s.status.cstring, nil)
  let fraction = if s.total > 0: clamp(float32(s.done) / float32(s.total), 0, 1) else: 0'f32
  let overlay = scanProgressWords(s.done, s.total)
  igProgressBar(fraction, ImVec2_c(x: igGetFontSize() * 12, y: 0), overlay.cstring)
  marks.mark("quality.progress")
  if overlay.len > 0: marks.mark("quality.progress " & overlay)
  igSameLine(0, -1)
  if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and s.job != NoJob:
    commands.add Command(kind: ckCancelJob, job: s.job)
  marks.mark("quality.stop")

proc drawScan(ui: var QualityUi; st: AppState; folderTab: bool; marks: var Marks;
    out0: var QualityOutput) =
  ## What a tab shows below its own controls: a sentence for what is missing, the job in
  ## progress, or the figures and the table.
  template s: untyped = (if folderTab: ui.folder else: ui.file)
  if not folderTab and ui.file.key.len == 0:
    if st.shownIsSignature:
      igTextUnformatted(SignatureNote.cstring, nil)
      marks.mark("quality.message " & SignatureNote)
      return
    igTextUnformatted(NeedFile.cstring, nil)
    marks.mark("quality.message " & NeedFile)
    return
  if folderTab and ui.folder.key.len == 0:
    igTextUnformatted((if st.settings.quality.folder.len == 0: NeedFolder
      else: "Press Run to measure " & st.settings.quality.folder & ".").cstring, nil)
    marks.mark("quality.message folder")
    return
  if s.running:
    marks.mark("quality.scanning")
    drawProgress(s, out0.commands, marks)
    return
  if not s.have:
    igPushTextWrapPos(0)
    igTextUnformatted(s.status.cstring, nil)
    igPopTextWrapPos()
    return
  marks.mark("quality.ready")
  let r = s.result
  if s.capped: igTextUnformatted(CappedNote.cstring, nil)
  if r.mixed.len > 0:
    igPushTextWrapPos(0)
    igTextUnformatted(r.mixed.cstring, nil)
    igPopTextWrapPos()
    marks.mark("quality.message " & r.mixed)
    return
  if r.taken.len > 0:
    igPushTextWrapPos(0)
    igTextUnformatted(r.taken.cstring, nil)
    igPopTextWrapPos()
    marks.mark("quality.message " & r.taken)
  let notChecked = notCheckedNote(r.notChecked)
  if notChecked.len > 0:
    igPushTextWrapPos(0)
    igTextUnformatted(notChecked.cstring, nil)
    igPopTextWrapPos()
    marks.mark("quality.message " & notChecked)
  let scan = if folderTab: addr ui.folder else: addr ui.file
  if r.receivers.totals.traces > 0 and r.sources.totals.traces > 0:
    if igRadioButton_Bool(ReceiversOption.cstring, scan.side == ssReceivers):
      scan.side = ssReceivers
      ui.shownKey = ["", ""]
    marks.mark("quality.side receivers")
    igSameLine(0, -1)
    if igRadioButton_Bool(SourcesOption.cstring, scan.side == ssSources):
      scan.side = ssSources
      ui.shownKey = ["", ""]
    marks.mark("quality.side sources")
    marks.mark("quality.side")
  let side = scan.side
  let report = r.reportOf(side)
  marks.mark("quality.sort " & sortText(ui.sort))
  let counts = countsLine(report.totals, folderTab)
  igTextUnformatted(counts.cstring, nil)
  marks.mark("quality.counts " & counts)
  for line in statisticLines(report.totals, side, folderTab):
    igTextUnformatted(line.cstring, nil)
    marks.mark("quality.stat " & line)
    tip(FiguresTip)
  igBeginDisabled(report.totals.traces == 0)
  if igButton(ExportButton.cstring, ImVec2_c(x: 0, y: 0)):
    let text = filterText(ui.filter[int(folderTab)])
    var rows: seq[StationRow] = @[]
    for i in filterStations(report.stations, text): rows.add report.stations[i]
    var taken = r.paths
    for session in st.sessions: taken.add normalizedPath($session.diskPath)
    ui.ask = ExportAsk(rows: rows, totals: report.totals, side: side, taken: taken,
      withStats: ui.withStats, live: true)
    out0.exportAsked = true
    out0.exportPath = (if folderTab and st.settings.quality.folder.len > 0:
      st.settings.quality.folder else: st.shownPath.parentDir) / SuggestedName
  igEndDisabled()
  marks.mark("quality.export")
  igSameLine(0, -1)
  discard igCheckbox((WithStats & "##stats").cstring, addr ui.withStats)
  marks.mark("quality.statsbox")
  tip(StatsTip)
  var unreadLines: seq[string] = @[]
  for row in r.unread: unreadLines.add row.path & " — " & row.why
  igSameLine(0, -1)
  if igButton(countLabel(UnreadFiles, r.unread.len).cstring, ImVec2_c(x: 0, y: 0)):
    igOpenPopup_Str("##unread", 0)
  marks.mark("quality.unread")
  if r.unread.len > 0:
    let note = unreadNote(r.unread)
    igPushTextWrapPos(0)
    igTextUnformatted(note.cstring, nil)
    igPopTextWrapPos()
    marks.mark("quality.unreadnote " & note)
  drawPopup("##unread", NoneUnread, "quality.unreadline ", unreadLines, marks)
  if report.totals.traces > 0:
    igSetNextItemWidth(-1)
    discard igInputTextWithHint("##filterstations", (IconFilter & "  " & FilterStations).cstring,
      cast[cstring](addr ui.filter[int(folderTab)][0]), csize_t(ui.filter[0].len), 0, nil, nil)
    marks.mark("quality.filter")
    tip(FilterStationsTip)
    ui.drawRows(report, int(folderTab), (if folderTab: "folder" else: "file") & $side, marks)

proc drawFolderControls(ui: var QualityUi; st: AppState; marks: var Marks;
    out0: var QualityOutput) =
  if igButton(FolderButton.cstring, ImVec2_c(x: 0, y: 0)):
    out0.askFolder = true
    out0.askAt = st.settings.quality.folder
  marks.mark("quality.folderbutton")
  igSameLine(0, -1)
  let chosen = st.settings.quality.folder
  igTextUnformatted((if chosen.len > 0: chosen else: NoFolderChosen).cstring, nil)
  marks.mark("quality.folderpath " & chosen)
  var sub = st.settings.quality.subfolders
  if igCheckbox((SubfoldersBox & "##subfolders").cstring, addr sub) and ui.focus.acts:
    var s = st.settings
    s.quality.subfolders = sub
    out0.commands.add Command(kind: ckSettings, settings: s)
  marks.mark("quality.subfolders")
  if sub: marks.mark("quality.subfolderson")
  tip(SubfoldersTip)
  igSameLine(0, -1)
  igBeginDisabled(chosen.len == 0 or ui.folder.running)
  if igButton(RunButton.cstring, ImVec2_c(x: 0, y: 0)): ui.runAsked = true
  igEndDisabled()
  marks.mark("quality.run")
  igTextUnformatted(UntoldLabel.cstring, nil)
  for choice in UntoldKind:
    igSameLine(0, -1)
    if igRadioButton_Bool((UntoldNames[choice] & "##untold" & $ord(choice)).cstring,
        st.settings.quality.untold == choice) and ui.focus.acts:
      var s = st.settings
      s.quality.untold = choice
      out0.commands.add Command(kind: ckSettings, settings: s)
    marks.mark("quality.untold " & UntoldNames[choice])
  tip(UntoldTip)

proc drawQuality*(ui: var QualityUi; title: string; st: AppState; marks: var Marks): QualityOutput =
  ## The window titled `title`. Closing it (`stop`, called by the caller while it is
  ## hidden) cancels what runs.
  if ui.chosen.len > 0:
    var s = st.settings
    s.quality.folder = ui.chosen
    ui.chosen = ""
    result.commands.add Command(kind: ckSettings, settings: s)
  ui.consider(st)
  ui.pollExport(st)
  ui.applySort()
  if beginClosable(awQuality, title.cstring):
    ui.focus.watch()
    marks.markWindow("quality")
    if ui.status.len > 0:
      igTextUnformatted(ui.status.cstring, nil)
      marks.mark("quality.exported " & ui.status)
    if igBeginTabBar("##qualitytabs", tabFlags):
      marks.mark("quality.tab")
      let fileOn = igBeginTabItem(FileTab.cstring, nil, 0)
      marks.mark("quality.tab File")
      if fileOn:
        ui.drawScan(st, false, marks, result)
        igEndTabItem()
      let folderOn = igBeginTabItem(FolderTab.cstring, nil, 0)
      marks.mark("quality.tab Folder")
      if folderOn:
        ui.drawFolderControls(st, marks, result)
        ui.drawScan(st, true, marks, result)
        igEndTabItem()
      igEndTabBar()
    marks.markOverflow("quality")
  ui.focus.settle()
  igEnd()
