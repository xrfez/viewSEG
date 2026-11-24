## Project > Slice by shot log: the recording the Seismic window shows, sliced at
## the times of a loaded shot log into one record per shot and written to a new
## file. A floating window. It posts the command that starts the cut; it reads
## no file, and what it sums up comes from the session and the log.

import std/[math, os]
import imguin/cimgui
import processSEG/continuous/slice
import ../../core/[cutgather, destwatch, geometry, panels, recordingkind, shotlog, state]
import ../../view/[cutwords, theme]
import marks, style

const NameRoom = 256

type
  CutUi* = object
    shown*: bool
    bringUp: bool
    logId: int
    recordMs: cdouble
    startMs: cdouble
    align: SliceAlign
    standard: CutStandard
    folder: string
    nameBuf: array[NameRoom, char]
    nameTouched: bool
    shots: CutShots
    shotsKey: tuple[id, revision: int]
    haveShots: bool
    dest: DestWatch ## whether a file or folder of the chosen name is already there

  CutDraw* = object
    commands*: seq[Command]
    askFolder*: bool ## the Change folder button was pressed: ask for one
    askAt*: string

proc open*(ui: var CutUi; logId: int; recordMs = DefaultRecordMs) =
  ## Shows the window. `logId` is the shot log the Shot log window shows; a
  ## later open keeps what was typed, and the log chosen. The first open takes
  ## the record length from the settings, `recordMs`.
  if ui.recordMs == 0:
    ui.recordMs = recordMs
    ui.align = saNearest
    ui.standard = csSegdRev3
    ui.logId = -1
  if ui.logId < 0 or not ui.shown: ui.logId = logId
  ui.shown = true
  ui.bringUp = true

func recordLengthMs*(ui: CutUi): float64 {.inline.} =
  ## The record length the window shows, in ms; 0 before the first open.
  float64(ui.recordMs)

proc setFolder*(ui: var CutUi; folder: string) =
  ## The folder dialog's answer.
  ui.folder = folder

proc nameText(ui: CutUi): string =
  $cast[cstring](unsafeAddr ui.nameBuf[0])

proc setName(ui: var CutUi; name: string) =
  let n = min(name.len, NameRoom - 1)
  for i in 0 ..< n: ui.nameBuf[i] = name[i]
  ui.nameBuf[n] = '\0'

proc tip(text: string) =
  if igIsItemHovered(ImGui_HoveredFlags_ForTooltip.cint or
      ImGui_HoveredFlags_AllowWhenDisabled.cint) and igBeginItemTooltip():
    igTextUnformatted(text.cstring, nil)
    igEndTooltip()

proc wrapped(text: string; width: float32) =
  igPushTextWrapPos(igGetCursorPos().x + width)
  igTextUnformatted(text.cstring, nil)
  igPopTextWrapPos()

proc coloured(text: string; colour: Rgba; width: float32) =
  igPushStyleColor_Vec4(ImGui_Col_Text.cint, vec4(colour))
  wrapped(text, width)
  igPopStyleColor(1)

proc options(ui: CutUi): CutOptions =
  initCutOptions(ui.recordMs, ui.startMs, ui.align, ui.standard)

proc sources(ui: var CutUi; st: AppState) =
  ## The shots of the chosen log, worked out again only when it changed.
  if st.findShotLog(ui.logId) < 0 and st.shotLogCount > 0:
    ui.logId = st.shotLogId(st.shotLogCount - 1) # the newest, when the window shows none
  let li = st.findShotLog(ui.logId)
  if li >= 0:
    let key = (ui.logId, st.shotRevision(li))
    if not ui.haveShots or ui.shotsKey != key:
      ui.shots = shotsInTime(st.shotView(li).rows)
      ui.shotsKey = key
      ui.haveShots = true
  else:
    ui.haveShots = false

proc nameProblem(name: string): string =
  if name.len == 0: NeedName
  elif DirSep in name or '/' in name: NameHasFolder
  else: ""

proc checkExists(ui: var CutUi; st: AppState; nameWhy: string) =
  ## Asks the disk, on a job, only when the destination or the state of the
  ## cut changed, never on every frame.
  let dest = if ui.folder.len > 0 and nameWhy.len == 0: ui.folder / ui.nameText else: ""
  let key = if dest.len > 0:
      dest & '\0' & st.cutOutcome & (if st.cutRunning: "1" else: "0")
    else: ""
  ui.dest.follow(st.jobs, dest, key)

proc drawLog(ui: var CutUi; st: AppState; marks: var Marks) =
  let li = st.findShotLog(ui.logId)
  let label = if li >= 0: st.shotLogName(li) else: "No shot log"
  if igBeginCombo("Shot log##cut".cstring, label.cstring, 0):
    for i in 0 ..< st.shotLogCount:
      igPushID_Int(cint(i))
      if igSelectable_Bool(st.shotLogName(i).cstring, st.shotLogId(i) == ui.logId, 0,
          ImVec2_c(x: 0, y: 0)):
        ui.logId = st.shotLogId(i)
      marks.mark("cut.log " & st.shotLogName(i))
      igPopID()
    igEndCombo()
  marks.mark("cut.log")

proc drawAlign(ui: var CutUi; marks: var Marks) =
  if igBeginCombo("Alignment##cut".cstring, alignWords(ui.align).cstring, 0):
    for a in SliceAlign:
      if igSelectable_Bool(alignWords(a).cstring, a == ui.align, 0, ImVec2_c(x: 0, y: 0)):
        ui.align = a
      marks.mark("cut.align " & alignWords(a))
      tip(alignTip(a))
    igEndCombo()
  marks.mark("cut.align")
  tip(alignTip(ui.align))

proc drawFormat(ui: var CutUi; marks: var Marks) =
  if igBeginCombo("Format##cut".cstring, standardWords(ui.standard).cstring, 0):
    for s in CutStandard:
      if igSelectable_Bool(standardWords(s).cstring, s == ui.standard, 0,
          ImVec2_c(x: 0, y: 0)):
        ui.standard = s
      marks.mark("cut.format " & standardWords(s))
    igEndCombo()
  marks.mark("cut.format")
  marks.mark("cut.format " & standardWords(ui.standard) & ".on")

proc drawCut*(ui: var CutUi; st: AppState; t: Theme; marks: var Marks): CutDraw =
  ## The window, while it is open. Cut posts the command when the options can
  ## be used; the outcome of the last cut is under the buttons.
  if not ui.shown: return
  if ui.bringUp:
    igSetWindowFocus_Str(CutWindowTitle.cstring)
    ui.bringUp = false
  let vp = igGetMainViewport()
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + igGetFontSize() * 4,
    y: vp.WorkPos.y + igGetFontSize() * 2), ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 40, y: igGetFontSize() * 38),
    ImGui_Cond_FirstUseEver.cint)
  let wide = igGetFontSize() * 34
  var open = true
  if igBegin(CutWindowTitle.cstring, addr open, ImGui_WindowFlags_NoDocking.cint):
    marks.markWindow("cut")
    wrapped(Intro, wide)
    igSpacing()
    let shown = st.shownFile(st.findPanel(MainPanel))
    let sourceName = if shown >= 0: st.sessions[shown].name else: ""
    igTextUnformatted(("Source: " & (if sourceName.len >
        0: sourceName else: "no file shown")).cstring,
      nil)
    marks.mark("cut.source")
    ui.sources(st)
    let facts = st.recordingFacts
    ui.drawLog(st, marks)
    igSetNextItemWidth(igGetFontSize() * 10)
    if igInputDouble("Record length (ms)##cut".cstring, addr ui.recordMs, 0, 0,
        "%.3f".cstring, 0) and usableRecordMs(ui.recordMs) and
        ui.recordMs != st.settings.cutGather.recordMs:
      var s = st.settings
      s.cutGather.recordMs = ui.recordMs
      result.commands.add Command(kind: ckSettings, settings: s)
    marks.mark("cut.length")
    marks.mark("cut.recordMs " & $ui.recordMs)
    igSetNextItemWidth(igGetFontSize() * 10)
    discard igInputDouble("Start (ms)##cut".cstring, addr ui.startMs, 0, 0, "%.3f".cstring, 0)
    marks.mark("cut.start")
    let opts = ui.options()
    var problem = ""
    if shown >= 0 and facts.ready:
      problem = checkOptions(opts, facts.dtMs)
    elif shown >= 0 and st.recordingBusy:
      problem = RecordingBeingRead
    elif shown >= 0:
      problem = if st.recordingWhy.len > 0: st.recordingWhy else: HeadersNotRead
    let refusal = if shown >= 0: cutRefusal(facts) else: ""
    if problem.len == 0 and refusal.len > 0: problem = refusal
    if problem.len == 0 and ui.haveShots and ui.shots.shots.len == 0:
      problem = "The shot log has no shot with a time."
    if problem.len > 0:
      coloured(problem, t.roles[rlWarning], wide)
      marks.mark("cut.why " & problem)
    ui.drawAlign(marks)
    ui.drawFormat(marks)
    igSeparator()
    wrapped("Folder: " & (if ui.folder.len > 0: ui.folder else: "not chosen"), wide)
    marks.mark("cut.folder " & ui.folder)
    if igButton("Change folder...##cut".cstring, ImVec2_c(x: 0, y: 0)):
      result.askFolder = true
      result.askAt = ui.folder
    marks.mark("cut.changeFolder")
    if not ui.nameTouched: ui.setName(defaultName(sourceName, ui.standard))
    igSetNextItemWidth(igGetFontSize() * 24)
    if igInputText("File name##cut".cstring, cast[cstring](addr ui.nameBuf[0]),
        csize_t(NameRoom), 0, nil, nil):
      ui.nameTouched = true
    marks.mark("cut.name")
    let nameWhy = nameProblem(ui.nameText)
    if nameWhy.len > 0 and ui.nameTouched: coloured(nameWhy, t.roles[rlWarning], wide)
    ui.checkExists(st, nameWhy)
    if ui.dest.exists:
      coloured(DestExists, t.roles[rlWarning], wide)
      marks.mark("cut.exists")
    igSeparator()
    var summary = ""
    if shown >= 0 and ui.haveShots and facts.ready and problem.len == 0:
      let samples = int(round(opts.recordMs / facts.dtMs))
      summary = summaryWords(ui.shots, facts.components, samples, opts)
    if summary.len > 0:
      wrapped(summary, wide)
      marks.mark("cut.summary " & summary)
      if facts.skips > 0:
        let skipped = skipWords(facts.skips, facts.missingSegments)
        wrapped(skipped, wide)
        marks.mark("cut.skips " & skipped)
      let numbering = numberingWords(ui.shots)
      if numbering.len > 0:
        wrapped(numbering, wide)
        marks.mark("cut.numbering")
    let why = st.cutProblem()
    let canCut = why.len == 0 and problem.len == 0 and ui.folder.len > 0 and
      nameWhy.len == 0 and not ui.dest.exists and not ui.dest.pending and
      summary.len > 0
    igBeginDisabled(not canCut)
    if igButton("Slice##cut".cstring, ImVec2_c(x: 0, y: 0)):
      result.commands.add Command(kind: ckCutGather, cutLog: st.findShotLog(ui.logId),
        cutOptions: opts, cutDest: ui.folder / ui.nameText)
    igEndDisabled()
    marks.mark("cut.run")
    if ui.dest.pending: marks.mark("cut.checking")
    tip(if why.len > 0: why
        elif ui.folder.len == 0: NeedFolder
        elif nameWhy.len > 0: nameWhy
        elif ui.dest.pending: DestChecking
        elif ui.dest.exists: DestExists
        elif problem.len > 0: problem
        else: "Slice the recording and write the file; the Jobs window shows its progress")
    igSameLine(0, -1)
    if igButton("Close##cut".cstring, ImVec2_c(x: 0, y: 0)): ui.shown = false
    marks.mark("cut.close")
    if st.cutRunning:
      wrapped("Slicing: the Jobs window shows how far it has come.", wide)
      marks.mark("cut.running")
    elif st.cutOutcome.len > 0:
      coloured(st.cutOutcome,
        if st.cutWritten.len > 0: t.roles[rlText] else: t.roles[rlWarning], wide)
      marks.mark("cut.outcome " & st.cutOutcome)
      if st.cutWritten.len > 0:
        if igButton((OpenCut & "##cut").cstring, ImVec2_c(x: 0, y: 0)):
          result.commands.add Command(kind: ckShowFile, panel: MainPanel,
            path: st.cutWritten, listFolder: true)
        marks.mark("cut.open")
  igEnd()
  if not open: ui.shown = false
