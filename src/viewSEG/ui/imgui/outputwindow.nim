## The Output window: the seismic files of one folder, including a vibrator
## signature file, ticked in a tree, written as SEG-Y or SEG-D. Wide enough,
## the source is the left pane and the write is
## the right; a narrow main window stacks them. Listing the folder and checking
## the destination run on background jobs. The write is the batch writer
## (`outputBatchWork`). A file already open is written as it stands, with its
## live edits.
##
## Ticks are not saved. All and None cover every listed file, including ones
## the name filter hides. A folder tick counts every file under it.

import std/[algorithm, options, os, strutils, tables]
from std/unicode import cmpRunesIgnoreCase
import sdl3_nim
import imguin/cimgui
import ../../core/[edits, filejobs, filekinds, filesystem, jobs, outputbatch, outputjobs,
  panels, references, state]
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
    correlate: bool
    sortOn: bool = true
    keepOwn: bool = false
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
    editing: bool
    draft: OutputPattern
    labelBuf: array[257, char]
    widthBuf: array[16, array[8, char]]
    textBuf: array[16, array[96, char]]
    focus: FocusClicks
    kindOpen: bool
    kindRow, kindTries: int
    kindAnchor: ImVec2_c
    kindWidth: float32

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

proc folderCounts(ui: OutputUi; n: Node): tuple[on, total: int] =
  ## How many files under `n` are ticked, and how many there are.
  var on, total = 0
  proc walk(node: Node) =
    if node == nil: return
    for i in node.files:
      inc total
      if ui.ticks.getOrDefault(ui.listed[i].relative, false): inc on
    for k in node.kids: walk(k)
  walk(n)
  (on, total)

proc folderState(ui: OutputUi; n: Node): int =
  ## 0 none ticked, 1 mixed, 2 every file under `n` ticked.
  let counted = ui.folderCounts(n)
  if counted.on == 0: 0 elif counted.on == counted.total: 2 else: 1

proc tickedBytes(ui: OutputUi): int64 =
  for f in ui.listed:
    if ui.ticks.getOrDefault(f.relative, false): result += f.size

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
      if not isOutputFile(kind): continue
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
      elif ui.haveResult: ui.status = ""
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
        result.add (path: item.source, file: fp, edits: copied,
          signature: st.sessions[i].signature)
        break

proc chosenPattern(st: AppState): OutputPattern =
  ## The saved pattern whose label matches the project's choice, spaces
  ## stripped and case ignored. Empty when nothing is chosen or the label
  ## names nothing: the batch then keeps today's names.
  result = OutputPattern()
  if not st.inProject: return
  let want = strip(st.project.doc.outputPattern)
  if want.len == 0: return
  for p in st.project.doc.outputPatterns:
    if cmpRunesIgnoreCase(p.name, want) == 0: return p

func chosenLabel(st: AppState): string =
  ## The chosen pattern's own label, or "" when no pattern is in use.
  let p = chosenPattern(st)
  if p.parts.len > 0: p.name else: ""

proc chosenSweep(st: AppState): tuple[name, path, why: string] =
  ## The project's chosen reference as a sweep the batch can load, or why it
  ## cannot be used. Reads no file.
  result = ("", "", CorrelatedNeedRef)
  if st.chosenReference.len == 0: return
  if not st.referencesLoaded:
    result.why = CorrelatedNeedArchive
    return
  let at = st.references.findId(st.chosenReference)
  if at < 0:
    result.why = referenceGone(st.chosenReference)
    return
  let e = st.references.entries[at]
  if e.missing or e.blocked or e.file.len == 0 or st.referencesHome.len == 0:
    result.why = referenceGone(e.name)
  elif e.isPilot:
    result.why = CorrelatedPilot
  else:
    result = (e.name, st.referencesHome / e.file, "")

proc submitRun(ui: var OutputUi; st: AppState) =
  var items: seq[BatchItem] = @[]
  for f in ui.listed:
    if ui.ticks.getOrDefault(f.relative, false):
      items.add BatchItem(source: f.source, relative: nativeRel(f.relative))
  if items.len == 0: return
  var opts = OutputOptions(format: ui.format, applyReversals: ui.reversals,
    applyShifts: ui.shifts, dropKilled: ui.dropKilled, applyOwnFilters: ui.ownFilters,
    applyProcessing: ui.processingOn, writeSessionPositions: not ui.keepOwn)
  let pk = st.findPanel(MainPanel)
  if pk >= 0 and st.panels[pk].layers.len > 0:
    if ui.processingOn: opts.processing = st.panels[pk].layers[0].processing
    if ui.sortOn: opts.sortKeys = st.panels[pk].layers[0].order
  var ask = BatchAsk(root: ui.source, items: items, destRoot: ui.dest, options: opts,
    mirrorFolders: ui.mirror, pattern: chosenPattern(st))
  let sweep = chosenSweep(st)
  if ui.correlate and sweep.why.len == 0:
    ask.correlate = BatchCorrelate(on: true, name: sweep.name, path: sweep.path)
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
  let counted = ui.folderCounts(n)
  marks.mark("output.foldercount " & n.rel & " " & $counted.on & " " & $counted.total)
  igSameLine(0, -1)
  let flags = ImGui_TreeNodeFlags_DefaultOpen.cint or ImGui_TreeNodeFlags_OpenOnArrow.cint or
    ImGui_TreeNodeFlags_SpanAvailWidth.cint
  let label = folderCount(n.name, counted.on, counted.total)
  let open = igTreeNodeEx_Str(label.cstring, flags)
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
  resultsText(lines, ui.result.written, ui.result.failed, ui.result.skipped,
    ui.result.correlatedWith)

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
  let summary = summaryLine(ui.result.written, ui.result.failed, ui.result.skipped,
    ui.result.correlatedWith)
  igTextUnformatted(summary.cstring, nil)
  if ui.result.correlatedWith.len > 0:
    marks.mark("output.correlatedWith " & ui.result.correlatedWith)
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
  let lineH = igGetTextLineHeightWithSpacing()
  var foot = lineH
  if ui.capped: foot += lineH
  let treeH = max(lineH * 3, igGetContentRegionAvail().y - foot)
  if igBeginChild_Str("##tree", ImVec2_c(x: 0, y: treeH), 0, 0):
    ui.drawTree(marks)
  igEndChild()
  if ui.capped:
    igPushTextWrapPos(0)
    igTextUnformatted(CappedNote.cstring, nil)
    igPopTextWrapPos()
  let tally = tickedLine(ui.tickedCount, sizeText(ui.tickedBytes), chosenLabel(st))
  igTextUnformatted(tally.cstring, nil)
  marks.mark("output.tally " & tally)

proc optBox(label: cstring; on: var bool; help: string) =
  discard igTableNextColumn()
  discard igCheckbox(label, addr on)
  if help.len > 0: tip(help)

proc drawOptions(ui: var OutputUi; st: AppState; marks: var Marks) =
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
  igTableNextRow(0, 0)
  optBox(KeepOwnPositions.cstring, ui.keepOwn, KeepOwnTip)
  let sweep = chosenSweep(st)
  discard igTableNextColumn()
  igBeginDisabled(sweep.why.len > 0)
  var corr = ui.correlate and sweep.why.len == 0
  if igCheckbox(OptCorrelated.cstring, addr corr): ui.correlate = corr
  igEndDisabled()
  tip(if sweep.why.len > 0: sweep.why else: CorrelatedTip)
  marks.mark(if sweep.why.len > 0: "output.correlate.disabled" else: "output.correlate")
  if corr: flagMark(marks, "output.correlate.on")
  igEndTable()

proc activityLine(ui: OutputUi; phase: string): string =
  ## The progress line: the current state, never the results summary.
  if ui.listing: return Listing
  if ui.running:
    if phase.len > 0: return "Writing " & phase
    return Writing
  if ui.stopped: return Stopped
  if ui.checking: return Checking
  if ui.listFailed.len > 0 and not ui.haveList: return ui.listFailed
  if not ui.haveResult and ui.status.len > 0 and ui.status != Ready and
      ui.status != Listing: return ui.status
  ""

proc drawRun(ui: var OutputUi; st: AppState; phase: string; marks: var Marks;
    outp: var OutputOutput) =
  let right = lineRight()
  if ui.running:
    if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.runJob != NoJob:
      outp.commands.add Command(kind: ckCancelJob, job: ui.runJob)
      marks.mark("output.cancelAsked")
    marks.mark("output.stop")
  else:
    igBeginDisabled(not ui.canRun)
    if igButton(RunButton.cstring, ImVec2_c(x: 0, y: 0)): ui.submitRun(st)
    igEndDisabled()
    if ui.canRun: marks.mark("output.run")
    else: marks.mark("output.run.disabled")
    let why = runWhy(ui.tickedCount, ui.dest)
    if why.len > 0:
      tip(why)
      marks.mark("output.run.why " & why)
    else:
      tip(RunTip)
  let line = ui.activityLine(phase)
  if line.len > 0:
    sameLineIfFits(right, textWidth(line) + 4)
    igTextUnformatted(line.cstring, nil)
    marks.mark("output.state " & line)

func takesWidth(kind: NamePartKind): bool =
  kind notin {npStem, npText, npTime, npSensorSerial}

proc bufText(buf: openArray[char]): string =
  if buf.len == 0 or buf[0] == '\0': return ""
  $cast[cstring](unsafeAddr buf[0])

proc setBuf(buf: var openArray[char]; text: string) =
  let n = min(text.len, buf.high)
  if n > 0: copyMem(addr buf[0], unsafeAddr text[0], n)
  for i in n ..< buf.len: buf[i] = '\0'

proc padOf(buf: openArray[char]): int =
  let text = bufText(buf).strip
  if text.len == 0: return 0
  try: parseInt(text)
  except ValueError: -1

proc closeKind(ui: var OutputUi)

proc loadEditor(ui: var OutputUi) =
  ui.closeKind()
  ui.draft = OutputPattern(separator: nsDot, parts: @[NamePart(kind: npStem)])
  setBuf(ui.labelBuf, "")
  for i in 0 ..< ui.widthBuf.len:
    setBuf(ui.widthBuf[i], "0")
    setBuf(ui.textBuf[i], "")

proc swapPart(ui: var OutputUi; a, b: int) =
  swap(ui.draft.parts[a], ui.draft.parts[b])
  swap(ui.widthBuf[a], ui.widthBuf[b])
  swap(ui.textBuf[a], ui.textBuf[b])
  ui.closeKind()

proc dropPart(ui: var OutputUi; i: int) =
  ui.closeKind()
  ui.draft.parts.delete(i)
  for j in i ..< ui.widthBuf.high:
    ui.widthBuf[j] = ui.widthBuf[j + 1]
    ui.textBuf[j] = ui.textBuf[j + 1]
  setBuf(ui.widthBuf[^1], "0")
  setBuf(ui.textBuf[^1], "")

func nameExt(format: OutputFormat): string =
  if format == ofSegy: ".sgy" else: ".sgd"

func previewValues(): NameValues =
  ## Placeholders that show a pattern's shape. Not read from a file.
  result[npStem] = NameValue(state: nvText, text: "file")
  result[npSrcLine] = NameValue(state: nvNumber, number: 12)
  result[npRcvLine] = NameValue(state: nvNumber, number: 12)
  result[npSigLine] = NameValue(state: nvNumber, number: 12)
  result[npSrcPoint] = NameValue(state: nvNumber, number: 1034.5)
  result[npRcvPoint] = NameValue(state: nvNumber, number: 1034.5)
  result[npSigStation] = NameValue(state: nvNumber, number: 1034.5)
  result[npRecord] = NameValue(state: nvNumber, number: 7)
  result[npFileNumber] = NameValue(state: nvInt, intValue: 7)
  result[npShotId] = NameValue(state: nvInt, intValue: 7)
  result[npSrcIndex] = NameValue(state: nvInt, intValue: 1)
  result[npRcvIndex] = NameValue(state: nvInt, intValue: 1)
  result[npSystemSerial] = NameValue(state: nvInt, intValue: 4521)
  result[npController] = NameValue(state: nvInt, intValue: 1)
  result[npVibrator] = NameValue(state: nvInt, intValue: 1)
  result[npSweepId] = NameValue(state: nvInt, intValue: 1)
  result[npSensorSerial] = NameValue(state: nvText, text: "S1042")
  result[npTime] = NameValue(state: nvTimeUs, timeUs: 1_718_454_645_000_000'i64,
    wholeSeconds: true)

proc editorWhy(ui: OutputUi; st: AppState): string =
  if not st.inProject: return NeedProjectPatterns
  if st.project.readOnly: return ReadOnlyPatterns
  patternProblem(ui.draft)

proc closeKind(ui: var OutputUi) =
  ui.kindOpen = false
  ui.kindTries = 0

proc kindBox(word: string; width: float32; open: bool): bool =
  ## A combo frame. The list itself is not opened here: a table cell would clip it.
  let style = igGetStyle()
  let pos = igGetCursorScreenPos()
  let h = igGetFrameHeight()
  result = igInvisibleButton("##kind", ImVec2_c(x: width, y: h), 0)
  let hot = open or igIsItemHovered(0)
  let frame = igGetColorU32_Col((if hot: ImGui_Col_FrameBgHovered else: ImGui_Col_FrameBg).cint, 1)
  let btn = igGetColorU32_Col((if hot: ImGui_Col_ButtonHovered else: ImGui_Col_Button).cint, 1)
  let ink = igGetColorU32_Col(ImGui_Col_Text.cint, 1)
  let dl = igGetWindowDrawList()
  let split = pos.x + max(0'f32, width - h)
  let far = ImVec2_c(x: pos.x + width, y: pos.y + h)
  ImDrawList_AddRectFilled(dl, pos, ImVec2_c(x: split, y: far.y), frame, style.FrameRounding,
    ImDrawFlags_RoundCornersLeft.cint)
  ImDrawList_AddRectFilled(dl, ImVec2_c(x: split, y: pos.y), far, btn, style.FrameRounding,
    ImDrawFlags_RoundCornersRight.cint)
  if style.FrameBorderSize > 0:
    ImDrawList_AddRect(dl, pos, far, igGetColorU32_Col(ImGui_Col_Border.cint, 1),
      style.FrameRounding, style.FrameBorderSize, 0)
  igRenderArrow(dl, ImVec2_c(x: split + style.FramePadding.y, y: pos.y + style.FramePadding.y),
    ink, ImGui_Dir_Down, 1)
  let pad = style.FramePadding
  igRenderTextClipped(ImVec2_c(x: pos.x + pad.x, y: pos.y + pad.y), ImVec2_c(x: split, y: far.y),
    word.cstring, nil, nil, ImVec2_c(x: 0, y: 0), nil)

proc placeKindList(ui: OutputUi) =
  ## Explicit size so the first frame is already hittable, on the main window.
  let vp = igGetMainViewport()
  let style = igGetStyle()
  let n = float32(ord(NamePartKind.high) + 1)
  let h = n * igGetFrameHeight() + style.WindowPadding.y * 2
  let w = max(ui.kindWidth, textWidth("Receiver index") + style.WindowPadding.x * 2)
  let x = max(vp.WorkPos.x, min(ui.kindAnchor.x, vp.WorkPos.x + vp.WorkSize.x - w))
  let y = max(vp.WorkPos.y, min(ui.kindAnchor.y, vp.WorkPos.y + vp.WorkSize.y - h))
  igSetNextWindowPos(ImVec2_c(x: x, y: y), ImGui_Cond_Always.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: w, y: h), ImGui_Cond_Always.cint)
  igSetNextWindowViewport(vp.ID)

proc drawKindList(ui: var OutputUi; marks: var Marks) =
  ## The kind list, after the parts table so a cell clip cannot hide it.
  const id = "##output.kindlist"
  if not ui.kindOpen: return
  if ui.kindRow < 0 or ui.kindRow >= ui.draft.parts.len:
    ui.closeKind()
    return
  if not igIsPopupOpen_Str(id, 0):
    if ui.kindTries <= 0:
      ui.closeKind()
      return
    igOpenPopup_Str(id, 0)
  ui.placeKindList()
  if not igBeginPopup(id, 0):
    if ui.kindTries > 0: dec ui.kindTries
    else: ui.closeKind()
    return
  ui.kindTries = 0
  let kind = ui.draft.parts[ui.kindRow].kind
  let pop = igGetCurrentWindow()
  for k in NamePartKind:
    let word = partWord(k)
    if igSelectable_Bool((word & "##k").cstring, k == kind, 0, ImVec2_c(x: 0, y: 0)):
      ui.draft.parts[ui.kindRow].kind = k
      ui.closeKind()
      igCloseCurrentPopup()
    marks.mark("output.part " & $ui.kindRow & ".item " & word)
  igEndPopup()
  # A popup that hangs out of its pane is marked hidden every other frame, so a
  # click on a visible row misses. Leave it hittable for the next frame.
  if pop != nil:
    pop.Hidden = false
    pop.HiddenFramesCanSkipItems = 0
    pop.HiddenFramesCannotSkipItems = 0
    pop.HiddenFramesForRenderOnly = 0

proc beginParts(marks: var Marks): bool =
  ## Fixed columns so every part's kind, value and buttons share a row.
  let flags = ImGui_TableFlags_SizingFixedFit.cint or ImGui_TableFlags_NoHostExtendX.cint or
    ImGui_TableFlags_PadOuterX.cint
  if not igBeginTable("##parts", 5, flags, ImVec2_c(x: 0, y: 0), 0): return false
  igTableSetupColumn("##kind", ImGui_TableColumnFlags_WidthFixed.cint, 0, ImGuiID(0))
  igTableSetupColumn(LeastDigits.cstring, ImGui_TableColumnFlags_WidthFixed.cint, 0, ImGuiID(0))
  igTableSetupColumn("##up", ImGui_TableColumnFlags_WidthFixed.cint, 0, ImGuiID(0))
  igTableSetupColumn("##down", ImGui_TableColumnFlags_WidthFixed.cint, 0, ImGuiID(0))
  igTableSetupColumn("##remove", ImGui_TableColumnFlags_WidthFixed.cint, 0, ImGuiID(0))
  igTableNextRow(ImGui_TableRowFlags_Headers.cint, 0)
  if igTableSetColumnIndex(1):
    igTableHeader(LeastDigits.cstring)
    marks.mark("output.pattern.leastdigits")
  true

proc partButton(label: cstring): bool =
  ## A small button whose top lines up with the kind box. ImGui's own small
  ## button sits on the text baseline, a few pixels below that row.
  let style = igGetStyle()
  let pad = style.FramePadding.y
  style.FramePadding.y = 0
  result = igButtonEx(label, ImVec2_c(x: 0, y: 0), 0)
  style.FramePadding.y = pad

proc drawPartRow(ui: var OutputUi; i: int; marks: var Marks): int =
  ## 1 up, 2 down, 3 remove, else 0. One table row: kind, value, buttons.
  igPushID_Int(cint(i))
  igTableNextRow(0, 0)
  discard igTableNextColumn()
  let kind = ui.draft.parts[i].kind
  let width = textWidth("Receiver index") + igGetFrameHeight()
  let open = ui.kindOpen and ui.kindRow == i
  if kindBox(partWord(kind), width, open):
    if open: ui.closeKind()
    else:
      ui.kindOpen = true
      ui.kindRow = i
      ui.kindTries = 2
  if ui.kindOpen and ui.kindRow == i:
    ui.kindAnchor = ImVec2_c(x: igGetItemRectMin().x, y: igGetItemRectMax().y)
    ui.kindWidth = width
  marks.mark("output.part " & $i & ".kind")
  discard igTableNextColumn()
  if takesWidth(kind):
    if bufText(ui.widthBuf[i]).len == 0: setBuf(ui.widthBuf[i], "0")
    igSetNextItemWidth(igGetFontSize() * 3)
    discard igInputText("##width", cast[cstring](addr ui.widthBuf[i][0]),
      csize_t(ui.widthBuf[i].len), 0, nil, nil)
    marks.mark("output.part " & $i & ".width")
    marks.mark("output.part " & $i & ".width " & bufText(ui.widthBuf[i]))
    tip(WidthTip)
    ui.draft.parts[i].pad = padOf(ui.widthBuf[i])
  elif kind == npText:
    igSetNextItemWidth(igGetFontSize() * 8)
    discard igInputText("##text", cast[cstring](addr ui.textBuf[i][0]),
      csize_t(ui.textBuf[i].len), 0, nil, nil)
    marks.mark("output.part " & $i & ".text")
    ui.draft.parts[i].text = bufText(ui.textBuf[i])
  discard igTableNextColumn()
  igBeginDisabled(i == 0)
  if partButton(UpPart.cstring): result = 1
  igEndDisabled()
  marks.mark("output.part " & $i & ".up")
  discard igTableNextColumn()
  igBeginDisabled(i == ui.draft.parts.high)
  if partButton(DownPart.cstring): result = 2
  igEndDisabled()
  marks.mark("output.part " & $i & ".down")
  discard igTableNextColumn()
  if partButton(RemovePart.cstring): result = 3
  marks.mark("output.part " & $i & ".remove")
  igPopID()

proc drawEditor(ui: var OutputUi; st: AppState; marks: var Marks; outp: var OutputOutput) =
  igSeparator()
  igTextUnformatted("File name pattern", nil)
  marks.mark("output.editor")
  let hintW = textWidth(PatternNameHint) + igGetStyle().FramePadding.x * 2 + 8
  igSetNextItemWidth(min(max(igGetFontSize() * 12, hintW), igGetContentRegionAvail().x))
  discard igInputTextWithHint("##label", PatternNameHint.cstring,
    cast[cstring](addr ui.labelBuf[0]), csize_t(ui.labelBuf.len), 0, nil, nil)
  ui.draft.name = bufText(ui.labelBuf)
  marks.mark("output.pattern.label")
  marks.mark("output.pattern.hint")
  if ui.draft.name.len > 0: marks.mark("output.pattern.label " & ui.draft.name)
  igTextUnformatted(SeparatorLabel.cstring, nil)
  marks.mark("output.pattern.separator")
  for sep in NameSeparator:
    igSameLine(0, -1)
    let choice = separatorChoice($sep)
    let on = ui.draft.separator == sep
    if igRadioButton_Bool(choice.cstring, on): ui.draft.separator = sep
    let mark = "output.pattern.sep " & $sep
    marks.mark(mark)
    if on: marks.mark(mark & ".on")
    marks.mark("output.pattern.sepchoice " & choice)
  igNewLine()
  var act = 0
  var at = 0
  if beginParts(marks):
    for i in 0 ..< ui.draft.parts.len:
      let one = ui.drawPartRow(i, marks)
      if one != 0:
        act = one
        at = i
    igEndTable()
  if act == 1 and at > 0: ui.swapPart(at, at - 1)
  elif act == 2 and at < ui.draft.parts.high: ui.swapPart(at, at + 1)
  elif act == 3: ui.dropPart(at)
  ui.drawKindList(marks)
  let shown = render(ui.draft, previewValues(), nameExt(ui.format))
  igTextUnformatted(ExampleLabel.cstring, nil)
  marks.mark("output.pattern.example")
  igSameLine(0, -1)
  if shown.problem.len > 0:
    igTextUnformatted(shown.problem.cstring, nil)
    marks.mark("output.preview.problem " & shown.problem)
  else:
    igTextUnformatted(shown.name.cstring, nil)
    marks.mark("output.pattern.preview " & shown.name)
  igBeginDisabled(ui.draft.parts.len >= MaxPatternParts)
  if igButton(AddPart.cstring, ImVec2_c(x: 0, y: 0)):
    ui.draft.parts.add NamePart(kind: npStem)
    let i = ui.draft.parts.high
    setBuf(ui.widthBuf[i], "0")
    setBuf(ui.textBuf[i], "")
  igEndDisabled()
  marks.mark("output.pattern.add")
  if igButton(SavePattern.cstring, ImVec2_c(x: 0, y: 0)):
    outp.commands.add Command(kind: ckNamePattern, patternAction: npaSave,
      namePattern: ui.draft)
  marks.mark("output.pattern.save")
  igSameLine(0, -1)
  if igButton(DeletePattern.cstring, ImVec2_c(x: 0, y: 0)):
    outp.commands.add Command(kind: ckNamePattern, patternAction: npaDelete,
      namePattern: OutputPattern(name: ui.draft.name))
  marks.mark("output.pattern.delete")
  let why = ui.editorWhy(st)
  if why.len > 0:
    igPushTextWrapPos(0)
    igTextUnformatted(why.cstring, nil)
    igPopTextWrapPos()
    marks.mark("output.pattern.problem " & why)

proc drawNames(ui: var OutputUi; st: AppState; marks: var Marks; outp: var OutputOutput) =
  igSeparator()
  igTextUnformatted(FileNamesLabel.cstring, nil)
  let chosen = if st.inProject: st.project.doc.outputPattern else: ""
  let shown = if chosen.len == 0: AsSourceFile else: chosen
  igSetNextItemWidth(-1)
  let open = igBeginCombo("##output.names", shown.cstring, 0)
  if not open:
    marks.mark("output.names")
    marks.mark("output.names " & shown)
  else:
    marks.mark("output.names.open")
    if st.inProject:
      for p in st.project.doc.outputPatterns:
        if igSelectable_Bool((p.name & "##pat").cstring, p.name == chosen, 0,
            ImVec2_c(x: 0, y: 0)):
          outp.commands.add Command(kind: ckNamePattern, patternAction: npaChoose,
            namePattern: OutputPattern(name: p.name))
        marks.mark("output.names.item " & p.name)
    if igSelectable_Bool((AsSourceFile & "##src").cstring, chosen.len == 0, 0,
        ImVec2_c(x: 0, y: 0)):
      outp.commands.add Command(kind: ckNamePattern, patternAction: npaChoose,
        namePattern: OutputPattern())
    marks.mark("output.names.item " & AsSourceFile)
    igEndCombo()
  if igButton(EditNames.cstring, ImVec2_c(x: 0, y: 0)):
    if not ui.editing: ui.loadEditor()
    ui.editing = not ui.editing
    if not ui.editing: ui.closeKind()
  marks.mark("output.names.edit")
  if ui.editing: ui.drawEditor(st, marks, outp)
  elif ui.kindOpen: ui.closeKind()

proc drawRight(ui: var OutputUi; st: AppState; phase: string; marks: var Marks;
    outp: var OutputOutput) =
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
  ui.drawNames(st, marks, outp)
  let right = lineRight()
  igTextUnformatted(FormatLabel.cstring, nil)
  sameLineIfFits(right, buttonWidth($ofSegy))
  if igRadioButton_Bool(($ofSegy).cstring, ui.format == ofSegy): ui.format = ofSegy
  marks.mark("output.format " & $ofSegy)
  if ui.format == ofSegy: marks.mark("output.format " & $ofSegy & ".on")
  sameLineIfFits(right, buttonWidth($ofSegd))
  if igRadioButton_Bool(($ofSegd).cstring, ui.format == ofSegd): ui.format = ofSegd
  marks.mark("output.format " & $ofSegd)
  if ui.format == ofSegd: marks.mark("output.format " & $ofSegd & ".on")
  ui.drawOptions(st, marks)
  discard igCheckbox(KeepFolders.cstring, addr ui.mirror)
  marks.mark("output.mirror")
  tip(MirrorTip)
  ui.drawRun(st, phase, marks, outp)
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
    var phase = ""
    if ui.running:
      let info = st.jobs.info(ui.runJob)
      if info.isSome: phase = info.get.progress.phase
      if phase.len > 0: flagMark(marks, "output.progress " & phase)
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
        ui.drawRight(st, phase, marks, result)
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
        ui.drawRight(st, phase, marks, result)
      igEndChild()
      flagMark(marks, "output.stacked")
    marks.markOverflow("output")
  ui.focus.settle()
  igEnd()
  result.askSource = ui.askSource
  result.askDest = ui.askDest
  if ui.askSource: ui.askSource = false
  if ui.askDest: ui.askDest = false
