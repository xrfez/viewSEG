## The Output window: the seismic files of one folder, ticked in a tree, written
## as SEG-Y or SEG-D. Wide enough, the source is the left pane and the write is
## the right; a narrow main window stacks them. Listing the folder and checking
## the destination run on background jobs. The write is the batch writer
## (`outputBatchWork`). A file already open is written as it stands, with its
## live edits.
##
## Ticks are not saved. All and None cover every listed file, including ones
## the name filter hides. A folder tick counts every file under it.

import std/[algorithm, options, os, strutils, tables]
import sdl3_nim
import imguin/cimgui
import ../../core/[edits, filejobs, filekinds, filesystem, jobs, outputbatch, outputjobs,
  panels, state]
import ../../view/[filetable, outputwords]
import fittext, focus, icons, marks, overflow

type
  ListedFile = object
    source: string
    relative: string
    size: int64

  ListNote = ref object
    files: seq[ListedFile]
    capped: bool
    gen: int

  RefuseNote = ref object
    sentence: string
    gen: int

  Node = ref object
    name: string
    rel: string
    files: seq[int]
    kids: seq[Node]

  OutputUi* = object
    source, dest: string
    format: OutputFormat = ofSegy
    reversals: bool = true
    dropKilled: bool = true
    ownFilters: bool = true
    processingOn: bool = true
    shifts: bool = true
    sortOn: bool = true
    mirror: bool = true
    filterBuf: array[128, char]
    ticks: Table[string, bool]
    listed: seq[ListedFile]
    tree: Node
    listGen, seenList: int
    listJob: JobId = NoJob
    listNote: ListNote
    listing: bool
    haveList: bool
    listFailed: string
    capped: bool
    refuseJob: JobId = NoJob
    refuseNote: RefuseNote
    refuseGen, seenRefuse: int
    refusal: string
    checking: bool
    runJob: JobId = NoJob
    sink: BatchSink
    running: bool
    haveResult: bool
    stopped: bool
    result: BatchResult
    status: string
    wantList, wantRefuse: bool
    askSource, askDest: bool
    focus: FocusClicks

  OutputOutput* = object
    commands*: seq[Command]
    askSource*, askDest*: bool
    askAt*: string

proc open*(ui: var OutputUi; folder: string) =
  ## File > Output...: the source becomes `folder` and the list starts again.
  ui.source = folder
  ui.wantList = true
  ui.wantRefuse = true

proc setSource*(ui: var OutputUi; folder: string) =
  ## The source dialog's answer.
  ui.source = folder
  ui.wantList = true
  ui.refusal = ""
  ui.wantRefuse = true

proc setDest*(ui: var OutputUi; folder: string) =
  ## The destination dialog's answer.
  ui.dest = folder
  ui.refusal = ""
  ui.wantRefuse = true

func slash(path: string): string =
  result = newStringOfCap(path.len)
  for c in path:
    if c == '\\' or c == '/': result.add '/'
    else: result.add c

func nativeRel(rel: string): string =
  if DirSep == '/': rel else: rel.replace('/', DirSep)

func leaf(rel: string): string =
  var cut = -1
  for i, c in rel:
    if c == '/' or c == '\\': cut = i
  if cut < 0: rel else: rel.substr(cut + 1)

func sameString(a, b: string): bool =
  when defined(windows): cmpIgnoreCase(a, b) == 0
  else: a == b

func underRoot(path, root: string): string =
  ## The path of `path` below `root`, with `/`, or "" when it is not under it.
  ## Strings only.
  if root.len == 0: return
  let norm = path.normalizedPath
  let base = root.normalizedPath
  let prefix = if base.endsWith(DirSep): base else: base & DirSep
  if sameString(norm, base): return
  when defined(windows):
    if not norm.toLowerAscii.startsWith(prefix.toLowerAscii): return
  else:
    if not norm.startsWith(prefix): return
  slash(norm.substr(prefix.len))

proc buildTree(files: seq[ListedFile]): Node =
  result = Node()
  for i, f in files:
    var node = result
    let parts = f.relative.split({'/', '\\'})
    var rel = ""
    for p, part in parts:
      if part.len == 0: continue
      if p == parts.high:
        node.files.add i
      else:
        if rel.len > 0: rel.add '/'
        rel.add part
        var found: Node = nil
        for k in node.kids:
          if k.name == part: found = k
        if found == nil:
          found = Node(name: part, rel: rel)
          node.kids.add found
        node = found

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: result = $(st.sessions[i].path)

proc retickShown(ui: var OutputUi; st: AppState) =
  ui.ticks = initTable[string, bool]()
  let shown = shownPath(st)
  if shown.len == 0: return
  let want = shown.normalizedPath
  for f in ui.listed:
    if sameString(f.source.normalizedPath, want):
      ui.ticks[f.relative] = true

proc tickedCount(ui: OutputUi): int =
  for f in ui.listed:
    if ui.ticks.getOrDefault(f.relative, false): inc result

proc setAll(ui: var OutputUi; on: bool) =
  for f in ui.listed:
    ui.ticks[f.relative] = on

proc setUnder(ui: var OutputUi; n: Node; on: bool) =
  if n == nil: return
  for i in n.files:
    ui.ticks[ui.listed[i].relative] = on
  for k in n.kids: ui.setUnder(k, on)

proc folderState(ui: OutputUi; n: Node): int =
  ## 0 none ticked, 1 mixed, 2 every file under `n` ticked.
  var on, off = 0
  proc walk(node: Node) =
    if node == nil: return
    for i in node.files:
      if ui.ticks.getOrDefault(ui.listed[i].relative, false): inc on
      else: inc off
    for k in node.kids: walk(k)
  walk(n)
  if on == 0: 0 elif off == 0: 2 else: 1

func filterOf(ui: OutputUi): string =
  $cast[cstring](unsafeAddr ui.filterBuf[0])

func nameMatches(rel, filt: string): bool =
  filt.len == 0 or leaf(rel).toLowerAscii.contains(filt.toLowerAscii)

proc visible(ui: OutputUi; n: Node; filt: string): bool =
  if n == nil: return false
  if filt.len == 0: return true
  for i in n.files:
    if nameMatches(ui.listed[i].relative, filt): return true
  for k in n.kids:
    if ui.visible(k, filt): return true

proc listWork(folder: string; note: ListNote; gen: int): JobWork =
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
    var files: seq[ListedFile] = @[]
    for path in paths:
      ctx.checkCancelled()
      var opened = false
      let kind = sniff(path, opened)
      if not isSeismic(kind): continue
      var size: int64 = 0
      try: size = fs.getFileSize(path)
      except OSError: size = 0
      let rel = underRoot(path, folder)
      if rel.len == 0: continue
      files.add ListedFile(source: path.normalizedPath, relative: rel, size: size)
    files.sort(proc (a, b: ListedFile): int = cmp(a.relative, b.relative))
    note.files = files
    note.capped = capped
    note.gen = gen

proc refuseWork(source, dest: string; note: RefuseNote; gen: int): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase Checking
    note.sentence = refuseOutputRoot(source, dest)
    note.gen = gen

proc cancelJob(st: AppState; id: var JobId) =
  if id != NoJob:
    discard st.jobs.cancel(id)
    id = NoJob

proc startList(ui: var OutputUi; st: AppState) =
  cancelJob(st, ui.listJob)
  ui.haveList = false
  ui.listing = false
  ui.listFailed = ""
  ui.capped = false
  ui.listed.setLen 0
  ui.tree = nil
  ui.ticks = initTable[string, bool]()
  if ui.source.len == 0: return
  inc ui.listGen
  ui.listNote = ListNote(gen: -1)
  ui.listing = true
  ui.status = Listing
  let folder = ui.source
  let note = ui.listNote
  let gen = ui.listGen
  ui.listJob = st.jobs.submit(JobSpec(title: ListTitle, lane: jlBackground, reads: @[folder]),
    listWork(folder, note, gen))

proc startRefuse(ui: var OutputUi; st: AppState) =
  cancelJob(st, ui.refuseJob)
  ui.checking = false
  if ui.dest.len == 0 or ui.source.len == 0:
    ui.refusal = ""
    return
  inc ui.refuseGen
  ui.refuseNote = RefuseNote(gen: -1)
  ui.checking = true
  let source = ui.source
  let dest = ui.dest
  let note = ui.refuseNote
  let gen = ui.refuseGen
  ui.refuseJob = st.jobs.submit(JobSpec(title: CheckTitle, lane: jlBackground),
    refuseWork(source, dest, note, gen))

proc applyList(ui: var OutputUi; st: AppState) =
  ui.listed = ui.listNote.files
  ui.capped = ui.listNote.capped
  ui.tree = buildTree(ui.listed)
  ui.haveList = true
  ui.listFailed = ""
  ui.retickShown(st)
  ui.status = if ui.listed.len == 0: NoSeismic else: Ready

proc poll(ui: var OutputUi; st: AppState) =
  if ui.listJob != NoJob:
    let info = st.jobs.info(ui.listJob)
    if info.isNone:
      ui.listJob = NoJob
      ui.listing = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.listing = true
      let phase = info.get.progress.phase
      ui.status = if phase.len > 0: phase else: Listing
    else:
      if info.get.state == jsDone and ui.listNote != nil and ui.listNote.gen == ui.listGen:
        ui.applyList(st)
      elif info.get.state == jsFailed:
        ui.listFailed = if info.get.error.len > 0: info.get.error else: CannotList
        ui.status = ui.listFailed
        ui.haveList = false
      elif info.get.state == jsCancelled:
        ui.status = Stopped
      ui.listJob = NoJob
      ui.listing = false
  if ui.refuseJob != NoJob:
    let info = st.jobs.info(ui.refuseJob)
    if info.isNone:
      ui.refuseJob = NoJob
      ui.checking = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.checking = true
    else:
      if info.get.state == jsDone and ui.refuseNote != nil and
          ui.refuseNote.gen == ui.refuseGen:
        ui.refusal = ui.refuseNote.sentence
      ui.refuseJob = NoJob
      ui.checking = false
  if ui.runJob != NoJob:
    let info = st.jobs.info(ui.runJob)
    if info.isNone:
      ui.runJob = NoJob
      ui.running = false
    elif info.get.state in {jsQueued, jsRunning}:
      ui.running = true
      let phase = info.get.progress.phase
      ui.status = if phase.len > 0: phase else: Writing
    else:
      ui.running = false
      ui.stopped = info.get.state == jsCancelled
      if ui.sink != nil and (info.get.state in {jsDone, jsCancelled, jsFailed}):
        ui.result = ui.sink.result
        ui.haveResult = true
      if info.get.state == jsFailed and not ui.haveResult:
        ui.status = if info.get.error.len > 0: info.get.error else: WriteFailed
      elif ui.stopped: ui.status = Stopped
      elif ui.haveResult: ui.status = summaryLine(ui.result.written, ui.result.failed,
        ui.result.skipped)
      ui.runJob = NoJob

proc consider(ui: var OutputUi; st: AppState) =
  ui.poll(st)
  if ui.source.len == 0 and st.fileList.folder.len > 0:
    ui.source = $(st.fileList.folder)
    ui.wantList = true
  if ui.wantList:
    ui.wantList = false
    ui.startList(st)
  if ui.wantRefuse:
    ui.wantRefuse = false
    ui.startRefuse(st)

proc canRun(ui: OutputUi): bool =
  ui.source.len > 0 and ui.dest.len > 0 and ui.refusal.len == 0 and not ui.checking and
    not ui.listing and ui.haveList and ui.tickedCount > 0 and not ui.running

proc sortWords(keys: seq[SortKey]): string =
  var parts: seq[string] = @[]
  for k in keys:
    var one = $k.field
    if k.descending: one.add " descending"
    parts.add one
  parts.join(", ")

proc liveFiles(st: AppState; items: seq[BatchItem]): seq[OpenFile] =
  for i in 0 ..< st.sessions.len:
    let fp = st.sessions[i].filePtr
    if fp == nil: continue
    let sessionPath = $(st.sessions[i].path)
    let want = sessionPath.normalizedPath
    for item in items:
      if sameString(item.source.normalizedPath, want):
        var copied: FileEdits = st.editsAt(sessionPath)
        result.add (path: item.source, file: fp, edits: copied)
        break

proc submitRun(ui: var OutputUi; st: AppState) =
  var items: seq[BatchItem] = @[]
  for f in ui.listed:
    if ui.ticks.getOrDefault(f.relative, false):
      items.add BatchItem(source: f.source, relative: nativeRel(f.relative))
  if items.len == 0: return
  var opts = OutputOptions(format: ui.format, applyReversals: ui.reversals,
    applyShifts: ui.shifts, dropKilled: ui.dropKilled, applyOwnFilters: ui.ownFilters,
    applyProcessing: ui.processingOn)
  let pk = st.findPanel(MainPanel)
  if pk >= 0 and st.panels[pk].layers.len > 0:
    if ui.processingOn: opts.processing = st.panels[pk].layers[0].processing
    if ui.sortOn: opts.sortKeys = st.panels[pk].layers[0].order
  let ask = BatchAsk(root: ui.source, items: items, destRoot: ui.dest, options: opts,
    mirrorFolders: ui.mirror)
  ui.sink = BatchSink()
  ui.haveResult = false
  ui.stopped = false
  ui.running = true
  ui.status = Writing
  let opened = liveFiles(st, items)
  ui.runJob = st.jobs.submit(outputBatchSpec(ask),
    outputBatchWork(ask, st.store, opened, ui.sink))

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc triCheck(label: string; state: int): bool =
  ## True when the box was clicked. `state` is 0, 1 (mixed) or 2.
  let mixed = state == 1
  if mixed: igPushItemFlag(ImGui_ItemFlags_MixedValue.cint, true)
  var on = state == 2
  result = igCheckbox(label.cstring, addr on)
  if mixed: igPopItemFlag()

proc fileUrl(path: string): string =
  result = "file://"
  let body = if path.startsWith("/"): path else: "/" & path
  for c in body:
    if c.isAlphaNumeric or c in {'/', '-', '_', '.', '~'}: result.add c
    else:
      result.add '%'
      result.add toHex(ord(c), 2)

proc drawFile(ui: var OutputUi; i: int; marks: var Marks) =
  let f = ui.listed[i]
  let rel = f.relative
  igPushID_Str(rel.cstring)
  var on = ui.ticks.getOrDefault(rel, false)
  if igCheckbox("##tick".cstring, addr on): ui.ticks[rel] = on
  marks.mark("output.file " & rel & " " & (if ui.ticks.getOrDefault(rel, false): "on" else: "off"))
  igSameLine(0, -1)
  igTextUnformatted((leaf(rel) & "  " & sizeText(f.size)).cstring, nil)
  igPopID()

proc drawNode(ui: var OutputUi; n: Node; filt: string; marks: var Marks) =
  if n == nil or not ui.visible(n, filt): return
  let state = ui.folderState(n)
  let word = if state == 0: "off" elif state == 1: "mixed" else: "on"
  igPushID_Str(n.rel.cstring)
  if triCheck("##tick", state):
    ui.setUnder(n, state != 2)
  marks.mark("output.folder " & n.rel & " " & word)
  igSameLine(0, -1)
  let flags = ImGui_TreeNodeFlags_DefaultOpen.cint or ImGui_TreeNodeFlags_OpenOnArrow.cint or
    ImGui_TreeNodeFlags_SpanAvailWidth.cint
  let open = igTreeNodeEx_Str(n.name.cstring, flags)
  igPopID()
  if open:
    for k in n.kids: ui.drawNode(k, filt, marks)
    for i in n.files:
      if nameMatches(ui.listed[i].relative, filt): ui.drawFile(i, marks)
    igTreePop()

proc drawTree(ui: var OutputUi; marks: var Marks) =
  let filt = ui.filterOf
  if ui.tree == nil: return
  for k in ui.tree.kids: ui.drawNode(k, filt, marks)
  for i in ui.tree.files:
    if nameMatches(ui.listed[i].relative, filt): ui.drawFile(i, marks)

func outcomeText(r: BatchItemResult): string =
  result = $r.outcome
  if r.outcome == boFailed and r.why.len > 0:
    result.add ": "
    result.add r.why

func joinedNotes(lines: openArray[string]): string =
  if lines.len == 0: return
  result = lines[0]
  for i in 1 ..< lines.len:
    result.add "; "
    result.add lines[i]

proc copyText(ui: OutputUi): string =
  var lines: seq[string] = @[]
  for r in ui.result.items:
    lines.add slash(r.relative) & "\t" & outcomeText(r) & "\t" & $r.writtenTraces & "\t" &
      $r.droppedTraces & "\t" & joinedNotes(r.lines)
  resultsText(lines, ui.result.written, ui.result.failed, ui.result.skipped)

proc rightText(text: string) =
  let w = igCalcTextSize(text.cstring, nil, false, -1).x
  let avail = igGetContentRegionAvail().x
  if avail > w: igSetCursorPosX(igGetCursorPosX() + avail - w)
  igTextUnformatted(text.cstring, nil)

proc hoverFull(text: string) =
  if text.len == 0: return
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint) and igBeginItemTooltip():
    igPushTextWrapPos(igGetFontSize() * 36)
    igTextUnformatted(text.cstring, nil)
    igPopTextWrapPos()
    igEndTooltip()

proc drawFileCell(rel: string; marks: var Marks) =
  let shown = shortenPath(rel, max(0'f32, igGetContentRegionAvail().x))
  igTextUnformatted(shown.cstring, nil)
  if shown != rel: hoverFull(rel)
  marks.mark("output.cell.file " & shown)

proc drawResults(ui: OutputUi; marks: var Marks) =
  if not ui.haveResult: return
  let summary = summaryLine(ui.result.written, ui.result.failed, ui.result.skipped)
  igTextUnformatted(summary.cstring, nil)
  marks.mark("output.summary " & $ui.result.written & " " & $ui.result.failed & " " &
    $ui.result.skipped)
  if ui.result.reason.len > 0:
    igPushTextWrapPos(0)
    igTextUnformatted(ui.result.reason.cstring, nil)
    igPopTextWrapPos()
  if ui.result.items.len > 0:
    let flags = ImGui_TableFlags_RowBg.cint or ImGui_TableFlags_Borders.cint or
      ImGui_TableFlags_Resizable.cint or ImGui_TableFlags_SizingStretchProp.cint or
      ImGui_TableFlags_ScrollY.cint
    let footer = igGetFrameHeightWithSpacing()
    let room = igGetContentRegionAvail().y
    let minH = igGetTextLineHeightWithSpacing() * 5
    let tableH = if room > footer + minH: room - footer else: minH
    if igBeginTable("##results", 5, flags, ImVec2_c(x: 0, y: tableH), 0):
      let pad = igGetStyle().CellPadding.x * 2 + 16
      let numW = max(textWidth(ColWritten), textWidth(ColDropped)) + pad
      igTableSetupColumn(ColFile.cstring, ImGui_TableColumnFlags_WidthStretch.cint, 3,
        ImGuiID(0))
      igTableSetupColumn(ColOutcome.cstring, ImGui_TableColumnFlags_WidthStretch.cint,
        1.6, ImGuiID(1))
      igTableSetupColumn(ColWritten.cstring, ImGui_TableColumnFlags_WidthFixed.cint,
        numW, ImGuiID(2))
      igTableSetupColumn(ColDropped.cstring, ImGui_TableColumnFlags_WidthFixed.cint,
        numW, ImGuiID(3))
      igTableSetupColumn(ColNotes.cstring, ImGui_TableColumnFlags_WidthStretch.cint, 2,
        ImGuiID(4))
      igTableSetupScrollFreeze(0, 1)
      igTableHeadersRow()
      for r in ui.result.items:
        let rel = slash(r.relative)
        igTableNextRow(0, 0)
        discard igTableNextColumn()
        drawFileCell(rel, marks)
        marks.mark("output.row " & rel & " " & $r.outcome & " " & $r.writtenTraces & " " &
          $r.droppedTraces)
        discard igTableNextColumn()
        let outcome = outcomeText(r)
        let outcomeShown = shortenEnd(outcome, max(0'f32, igGetContentRegionAvail().x))
        igTextUnformatted(outcomeShown.cstring, nil)
        if outcomeShown != outcome or r.why.len > 0: hoverFull(outcome)
        discard igTableNextColumn()
        rightText($r.writtenTraces)
        discard igTableNextColumn()
        rightText($r.droppedTraces)
        discard igTableNextColumn()
        let notes = joinedNotes(r.lines)
        let notesShown = shortenEnd(notes, max(0'f32, igGetContentRegionAvail().x))
        igTextUnformatted(notesShown.cstring, nil)
        hoverFull(notes)
      igEndTable()
  if igButton(CopyButton.cstring, ImVec2_c(x: 0, y: 0)):
    igSetClipboardText(ui.copyText.cstring)
  marks.mark("output.copy")
  tip(CopyTip)
  igSameLine(0, -1)
  igBeginDisabled(ui.dest.len == 0)
  if igButton(OpenButton.cstring, ImVec2_c(x: 0, y: 0)):
    discard SDL_OpenURL(fileUrl(ui.dest).cstring)
  igEndDisabled()
  marks.mark("output.open")
  tip(OpenTip)

proc buttonWidth(label: string): float32 =
  textWidth(label) + igGetStyle().FramePadding.x * 2 + 8

proc sameLineIfFits(right, need: float32) =
  if igGetItemRectMax().x + igGetStyle().ItemSpacing.x + need <= right + 1:
    igSameLine(0, -1)

proc lineRight(): float32 =
  igGetCursorScreenPos().x + igGetContentRegionAvail().x

proc flagMark(marks: var Marks; name: string) =
  let p = igGetCursorScreenPos()
  marks.markRect(name, p, ImVec2_c(x: p.x + 1, y: p.y + 1))

proc pathLine(label, path, button, textMark, extra, buttonMark: string;
    marks: var Marks): bool =
  ## "Label: path" with `button` at the row's end. The path keeps its last
  ## name and is cut from the left when the row is short.
  let gap = igGetStyle().ItemSpacing.x
  let btn = buttonWidth(button)
  let prefix = label & ": "
  let room = igGetContentRegionAvail().x
  let beside = room >= textWidth(prefix) + igGetFontSize() * 4 + gap + btn
  let textRoom = if beside: room - gap - btn - textWidth(prefix)
                 else: room - textWidth(prefix)
  let body = if path.len == 0: "—" else: shortenPath(path, max(0'f32, textRoom))
  igTextUnformatted((prefix & body).cstring, nil)
  if path.len > 0: tip(path)
  marks.mark(textMark)
  if extra.len > 0: marks.mark(extra)
  if beside: igSameLine(0, -1)
  result = igButton(button.cstring, ImVec2_c(x: 0, y: 0))
  marks.mark(buttonMark)

proc drawLeft(ui: var OutputUi; st: AppState; marks: var Marks; outp: var OutputOutput) =
  if pathLine(SourceLabel, ui.source, ChangeSource, "output.source", "",
      "output.changeSource", marks):
    ui.askSource = true
    outp.askAt = ui.source
  let right = lineRight()
  if igButton(AllButton.cstring, ImVec2_c(x: 0, y: 0)): ui.setAll(true)
  marks.mark("output.all")
  sameLineIfFits(right, buttonWidth(NoneButton))
  if igButton(NoneButton.cstring, ImVec2_c(x: 0, y: 0)): ui.setAll(false)
  marks.mark("output.none")
  sameLineIfFits(right, buttonWidth(ShownButton))
  if igButton(ShownButton.cstring, ImVec2_c(x: 0, y: 0)): ui.retickShown(st)
  marks.mark("output.shown")
  tip(ShownTip)
  igSetNextItemWidth(-1)
  discard igInputTextWithHint("##filter", (IconFilter & "  " & FilterHint).cstring,
    cast[cstring](addr ui.filterBuf[0]), csize_t(ui.filterBuf.len), 0, nil, nil)
  marks.mark("output.filter")
  tip(FilterTip)
  let treeH = max(igGetTextLineHeightWithSpacing() * 3, igGetContentRegionAvail().y)
  if igBeginChild_Str("##tree", ImVec2_c(x: 0, y: treeH), 0, 0):
    ui.drawTree(marks)
  igEndChild()

proc optBox(label: cstring; on: var bool; help: string) =
  discard igTableNextColumn()
  discard igCheckbox(label, addr on)
  if help.len > 0: tip(help)

proc drawOptions(ui: var OutputUi; st: AppState) =
  var keys = ""
  let pk = st.findPanel(MainPanel)
  if pk >= 0 and st.panels[pk].layers.len > 0:
    keys = sortWords(st.panels[pk].layers[0].order)
  let flags = ImGui_TableFlags_SizingStretchSame.cint
  if not igBeginTable("##apply", 2, flags, ImVec2_c(x: 0, y: 0), 0): return
  igTableSetupColumn("##l", ImGui_TableColumnFlags_WidthStretch.cint, 1, ImGuiID(0))
  igTableSetupColumn("##r", ImGui_TableColumnFlags_WidthStretch.cint, 1, ImGuiID(1))
  igTableNextRow(0, 0)
  optBox(OptReversals.cstring, ui.reversals, "")
  optBox(OptKilled.cstring, ui.dropKilled, "")
  igTableNextRow(0, 0)
  optBox(OptFilters.cstring, ui.ownFilters, "")
  optBox(OptProcessing.cstring, ui.processingOn, ProcessingTip)
  igTableNextRow(0, 0)
  optBox(OptShifts.cstring, ui.shifts, "")
  optBox(OptSort.cstring, ui.sortOn, sortTip(keys))
  igEndTable()

proc drawRun(ui: var OutputUi; st: AppState; marks: var Marks; outp: var OutputOutput) =
  if ui.running:
    if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.runJob != NoJob:
      outp.commands.add Command(kind: ckCancelJob, job: ui.runJob)
    marks.mark("output.stop")
  else:
    igBeginDisabled(not ui.canRun)
    if igButton(RunButton.cstring, ImVec2_c(x: 0, y: 0)): ui.submitRun(st)
    igEndDisabled()
    if ui.canRun: marks.mark("output.run")
    else: marks.mark("output.run.disabled")
    tip(RunTip)

proc drawRight(ui: var OutputUi; st: AppState; marks: var Marks; outp: var OutputOutput) =
  let extra = if ui.dest.len > 0: "output.destination " & ui.dest else: ""
  if pathLine(DestLabel, ui.dest, ChangeDest, "output.dest", extra, "output.changeDest",
      marks):
    ui.askDest = true
    outp.askAt = if ui.dest.len > 0: ui.dest else: ui.source
  if ui.refusal.len > 0:
    igPushTextWrapPos(0)
    igTextUnformatted(ui.refusal.cstring, nil)
    igPopTextWrapPos()
    marks.mark("output.refusal " & ui.refusal)
  let right = lineRight()
  igTextUnformatted(FormatLabel.cstring, nil)
  sameLineIfFits(right, buttonWidth($ofSegy))
  if igRadioButton_Bool(($ofSegy).cstring, ui.format == ofSegy): ui.format = ofSegy
  sameLineIfFits(right, buttonWidth($ofSegd))
  if igRadioButton_Bool(($ofSegd).cstring, ui.format == ofSegd): ui.format = ofSegd
  ui.drawOptions(st)
  discard igCheckbox(KeepFolders.cstring, addr ui.mirror)
  marks.mark("output.mirror")
  tip(MirrorTip)
  ui.drawRun(st, marks, outp)
  ui.drawResults(marks)

proc drawOutput*(ui: var OutputUi; title: string; st: AppState; marks: var Marks): OutputOutput =
  ## The window titled `title`. A list or a destination check asked for since
  ## the last draw starts here. Wide: two panes sharing the height, a
  ## draggable split. Narrow: the source above the write.
  ui.consider(st)
  if igBegin(title.cstring, nil, 0):
    ui.focus.watch()
    marks.markWindow("output")
    if ui.listing: flagMark(marks, "output.listing")
    if ui.haveList and not ui.listing: flagMark(marks, "output.ready")
    if ui.running:
      let info = st.jobs.info(ui.runJob)
      if info.isSome and info.get.progress.phase.len > 0:
        flagMark(marks, "output.progress " & info.get.progress.phase)
    var status = ui.status
    if status.len == 0:
      status = if ui.source.len == 0: NeedFolder elif ui.haveList: Ready else: Listing
    if ui.capped:
      if status.len > 0: status.add " "
      status.add CappedNote
    igPushTextWrapPos(0)
    igTextUnformatted(status.cstring, nil)
    igPopTextWrapPos()
    let wide = igGetMainViewport().Size.x >= 900
    let avail = igGetContentRegionAvail()
    if wide:
      let leftW = max(igGetFontSize() * 14, avail.x * 0.45)
      let split = ImGui_ChildFlags_Borders.cint or ImGui_ChildFlags_ResizeX.cint
      if igBeginChild_Str("##out.left", ImVec2_c(x: leftW, y: 0), split, 0):
        marks.markWindow("output.pane.left")
        ui.drawLeft(st, marks, result)
      igEndChild()
      igSameLine(0, -1)
      if igBeginChild_Str("##out.right", ImVec2_c(x: 0, y: 0),
          ImGui_ChildFlags_Borders.cint, 0):
        marks.markWindow("output.pane.right")
        ui.drawRight(st, marks, result)
      igEndChild()
      flagMark(marks, "output.beside")
    else:
      let leftH = max(igGetFontSize() * 10, avail.y * 0.45)
      let split = ImGui_ChildFlags_Borders.cint or ImGui_ChildFlags_ResizeY.cint
      if igBeginChild_Str("##out.left.stack", ImVec2_c(x: 0, y: leftH), split, 0):
        marks.markWindow("output.pane.left")
        ui.drawLeft(st, marks, result)
      igEndChild()
      if igBeginChild_Str("##out.right.stack", ImVec2_c(x: 0, y: 0),
          ImGui_ChildFlags_Borders.cint, 0):
        marks.markWindow("output.pane.right")
        ui.drawRight(st, marks, result)
      igEndChild()
      flagMark(marks, "output.stacked")
    marks.markOverflow("output")
  ui.focus.settle()
  igEnd()
  result.askSource = ui.askSource
  result.askDest = ui.askDest
  if ui.askSource: ui.askSource = false
  if ui.askDest: ui.askDest = false
