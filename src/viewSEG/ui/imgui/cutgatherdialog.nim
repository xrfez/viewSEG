## Project > Slice by shot log: the recording the Seismic window shows, sliced at
## the times of a loaded shot log into one record per shot and written to a new
## file. A floating window. It posts the command that starts the cut; it reads
## no file, and what it sums up comes from the session and the log.
##
## The window also slices every recording of a folder in one run (`cutfolderjobs`):
## a job checks the folder when it is chosen (and again when the log, the length, the
## format or the destination change), and a second job writes. Both are the window's
## own, as the Trace quality window's scans are; the window never reads a file itself.

import std/[math, options, os, tables]
import imguin/cimgui
from parseSEG import skSegd
import processSEG/continuous/slice
import ../../core/[cutcorrelate, cutfolderjobs, cutgather, destwatch, geometry, jobs, outputbinary,
  outputtext,
  panels, recordingkind, shotlog, state, treatas]
import ../../view/[cutfolderwords, cutwords, recordingwords, theme]
import chosensweep, marks, style

const NameRoom = 256

type
  CutUi* = object
    shown*: bool
    bringUp: bool
    logId: int
    recordMs: cdouble
    align: SliceAlign
    standard: CutStandard
    correlated: bool           ## the records are correlated with the project's stored sweep
    order: CutOrder
    skipText, skipBinary: bool ## the project's text template or binary set is not used
    folder: string
    nameBuf: array[NameRoom, char]
    nameTouched: bool
    shots: CutShots
    shotsKey: tuple[id, revision: int]
    haveShots: bool
    dest: DestWatch            ## whether a file or folder of the chosen name is already there
    srcFolder: string          ## the folder whose recordings are all sliced
    check: FolderFlight        ## the check in flight
    checkKey: string           ## what the check in flight, or the last one, was made for
    checked: FolderResult      ## what the last check found
    run: FolderFlight          ## the run in flight
    ran: FolderResult          ## what the last run did
    runFolder: string          ## the folder the run in flight, or the last, was of
    known: KnownFacts          ## what the last job found out about each file of the folder
    left: seq[FolderFlight]    ## jobs given up whose work has not come back yet
    lengthActive: bool         ## the record length is being typed: no check meanwhile
    haveRan: bool

  CutDraw* = object
    commands*: seq[Command]
    askFolder*: bool       ## the Change folder button was pressed: ask for one
    askAt*: string
    askFile*: bool         ## the Choose file button was pressed: ask for the recording to slice
    askSourceFolder*: bool ## the Choose folder button was pressed: ask for the folder to slice
    askSourceAt*: string

proc open*(ui: var CutUi; logId: int; recordMs = DefaultRecordMs; correlated = false) =
  ## Shows the window. `logId` is the shot log the Shot log window shows; a
  ## later open keeps what was typed, and the log chosen. The first open takes
  ## the record length and the tick from the settings, `recordMs` and `correlated`.
  if ui.recordMs == 0:
    ui.recordMs = recordMs
    ui.correlated = correlated
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

proc setSourceFolder*(ui: var CutUi; folder: string) =
  ## The answer of the dialog that chooses the folder whose recordings are sliced.
  ui.srcFolder = folder
  ui.known = KnownFacts()
  ui.checkKey = ""
  ui.checked = FolderResult()
  ui.haveRan = false

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

proc chosenText(st: AppState): Option[OutputText] =
  ## The project's chosen text header template; none outside a project or with none chosen.
  if st.inProject: chosenText(st.project.doc.outputTexts, st.project.doc.outputText)
  else: none(OutputText)

proc chosenBinary(st: AppState): Option[OutputBinary] =
  ## The project's chosen binary header set; none outside a project or with none chosen.
  if st.inProject: chosenBinary(st.project.doc.outputBinaries, st.project.doc.outputBinary)
  else: none(OutputBinary)

proc whyNotCorrelated(ui: CutUi; st: AppState; dtMs: float64): string =
  ## Why the records cannot be correlated with the project's reference ("" when they can).
  ## `dtMs` is the shown recording's interval, NaN while it is not known: the record length
  ## and the interval are then judged by the job, each file by its own.
  let sweep = chosenSweep(st)
  if sweep.pilot.isSome: result = CorrelatedPilotWhy
  elif sweep.why.len > 0: result = sweep.why
  elif not dtMs.isNaN and usableRecordMs(ui.recordMs):
    result = correlationWhy(sweep.samples, sweep.intervalUs, ui.recordMs, dtMs)

proc options(ui: CutUi; st: AppState; groupable: bool; dtMs = NaN): CutOptions =
  result = initCutOptions(ui.recordMs, 0.0, ui.align, ui.standard) # a record begins at the shot
  if ui.correlated and ui.whyNotCorrelated(st, dtMs).len == 0:
    let sweep = chosenSweep(st)
    result.sweepPath = sweep.path
    result.sweepName = sweep.name
  if groupable: result.order = ui.order
  if ui.standard == csSegy:
    if not ui.skipText: result.headerText = chosenText(st)
    if not ui.skipBinary: result.headerBinary = chosenBinary(st)

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

proc drawOrder(ui: var CutUi; marks: var Marks; groupable, carried: bool) =
  ## The order of a record's traces. The grouped orders need a recording with two or more
  ## coded components; a SEG-D slice that keeps the recording's headers cannot take them.
  let shownOrder = if groupable: ui.order else: coAsSource
  if igBeginCombo("Trace order##cut".cstring, orderWords(shownOrder).cstring, 0):
    for o in CutOrder:
      let off = o != coAsSource and not groupable
      igBeginDisabled(off)
      if igSelectable_Bool(orderWords(o).cstring, o == shownOrder, 0, ImVec2_c(x: 0, y: 0)):
        ui.order = o
      igEndDisabled()
      marks.mark("cut.order " & orderWords(o) & (if off: ".off" else: ""))
      tip(if off: OrderOneComponent else: orderTip(o))
    igEndCombo()
  marks.mark("cut.order")
  tip(if shownOrder != coAsSource and carried: OrderKeepsHeaders else: orderTip(shownOrder))

proc drawHeaders(ui: var CutUi; st: AppState; marks: var Marks) =
  ## For a SEG-Y output, the project's text header template and binary header set, when it
  ## has chosen them: each is used unless its box is cleared.
  if ui.standard != csSegy: return
  let text = chosenText(st)
  if text.isSome:
    var use = not ui.skipText
    if igCheckbox(("Use the project's text header template '" & text.get.name &
        "'##cut.text").cstring, addr use):
      ui.skipText = not use
    marks.mark("cut.useText")
    tip(UseTextTip)
  let binary = chosenBinary(st)
  if binary.isSome:
    var use = not ui.skipBinary
    if igCheckbox(("Use the project's binary header set '" & binary.get.name &
        "'##cut.binary").cstring, addr use):
      ui.skipBinary = not use
    marks.mark("cut.useBinary")
    tip(UseBinaryTip)

proc drawCorrelated(ui: var CutUi; st: AppState; t: Theme; marks: var Marks;
    dtMs: float64; wide: float32; sourceSegd: bool): seq[Command] =
  ## The tick that correlates each record with the project's stored sweep. Dim with the
  ## reason when the reference cannot be used and the tick is off; a tick that cannot be
  ## honoured stays clearable, and the window refuses the slice meanwhile. The tick is
  ## remembered in the settings.
  let why = ui.whyNotCorrelated(st, dtMs)
  igBeginDisabled(why.len > 0 and not ui.correlated) # a tick whose cause stays can be cleared
  var on = ui.correlated
  if igCheckbox(OptCorrelated.cstring, addr on):
    ui.correlated = on
    var s = st.settings
    s.cutGather.correlated = on
    result.add Command(kind: ckSettings, settings: s)
  igEndDisabled()
  tip(if why.len > 0: why else: CorrelatedTip)
  marks.mark("cut.correlate")
  if why.len > 0 and not ui.correlated: marks.mark("cut.correlate.disabled")
  if why.len > 0: marks.mark("cut.correlate.why " & why)
  if on and why.len == 0: # no listen time is told for a record the sweep outlasts
    marks.mark("cut.correlate.on")
    let sweep = chosenSweep(st)
    if not dtMs.isNaN:
      let words = listenWords(sweep.name, sweep.samples, ui.recordMs, dtMs)
      wrapped(words, wide)
      marks.mark("cut.correlate.says " & words)
    else:
      wrapped("Each record is correlated with the sweep '" & sweep.name &
        "' and holds the listen time: the record less the sweep.", wide)
    if ui.standard == csSegdRev3 and sourceSegd:
      coloured(CorrelatedNoCarry, t.roles[rlTextDim], wide)
      marks.mark("cut.correlate.noCarry")

proc drawFormat(ui: var CutUi; marks: var Marks; sourceSegd, builtFromOptions: bool) =
  ## `sourceSegd`: the output SEG-D keeps the source's revision. `builtFromOptions`: the
  ## source is SEG-D but its headers cannot be carried (the window knows it already).
  if igBeginCombo("Format##cut".cstring, standardWords(ui.standard, sourceSegd).cstring, 0):
    for s in CutStandard:
      if igSelectable_Bool(standardWords(s, sourceSegd).cstring, s == ui.standard, 0,
          ImVec2_c(x: 0, y: 0)):
        ui.standard = s
      marks.mark("cut.format " & standardWords(s, sourceSegd))
    igEndCombo()
  marks.mark("cut.format")
  if builtFromOptions: tip(NoCarry)
  marks.mark("cut.format " & standardWords(ui.standard, sourceSegd) & ".on")

proc folderPlan(ui: CutUi; st: AppState; opts: CutOptions; write: bool): FolderPlan =
  ## What the folder jobs are given: a copy of the log's rows, the options, the open files.
  let li = st.findShotLog(ui.logId)
  result = FolderPlan(folder: ui.srcFolder, destFolder: ui.folder, rows: st.shotView(li).rows,
    opts: opts, cacheDir: st.indexCache, write: write, treats: st.forcedKinds,
    vendorGen: st.vendorGen)
  result.opts.logName = extractFilename(st.shotLogSource(li))
  if result.opts.logName.len == 0: result.opts.logName = st.shotLogName(li)
  for x in st.sessions: result.others.add x.diskPath

proc stopCheck(ui: var CutUi; st: AppState) =
  ## Gives the check in flight up; what its work reads stays until it is back.
  ui.left.retire(ui.check, st.jobs)

proc keepForStragglers*(ui: CutUi; jobs: Jobs) =
  ## At the quit: what the work of a folder job left running uses stays to the end of the
  ## process.
  keepForStragglers([ui.check, ui.run], jobs)
  keepForStragglers(ui.left, jobs)

proc endedHow(st: AppState; job: JobId; state: var JobState; error: var string) =
  ## How `job` ended; failed when it is gone.
  let info = st.jobs.info(job)
  if info.isNone:
    state = jsFailed
    error = "the job is gone"
  else:
    state = info.get.state
    error = info.get.error

proc pollFolder(ui: var CutUi; st: AppState) =
  ## Takes what the folder jobs made once they are over. A job listed as over whose work still
  ## runs (cancelled from the Jobs window, and not stopping) is given up: what it filled is
  ## not read, and what it uses stays until it is back.
  var state = jsQueued
  var error = ""
  if ui.check.job != NoJob and ui.check.ended(st.jobs):
    st.endedHow(ui.check.job, state, error)
    if ui.check.over(st.jobs):
      let (res, known) = ui.check.take()
      ui.checked = res
      if res.listed: ui.known = known
    else:
      ui.checked = FolderResult(folder: ui.srcFolder)
      ui.left.retire(ui.check, st.jobs)
    if state == jsFailed and ui.checked.reason.len == 0: ui.checked.reason = error
  if ui.run.job != NoJob and ui.run.ended(st.jobs):
    st.endedHow(ui.run.job, state, error)
    var res = FolderResult(folder: ui.runFolder)
    if ui.run.over(st.jobs):
      let (done, known) = ui.run.take()
      res = done
      if res.listed and ui.runFolder == ui.srcFolder: ui.known = known
    else: ui.left.retire(ui.run, st.jobs)
    if ui.runFolder == ui.srcFolder:
      ui.ran = res
      if state == jsFailed and ui.ran.reason.len == 0: ui.ran.reason = error
      elif state == jsCancelled: ui.ran.reason = "The run was cancelled."
      ui.haveRan = true
    ui.checkKey = "" # the folder is looked at again: its slices are there now

proc considerFolder(ui: var CutUi; st: AppState; opts: CutOptions) =
  ## Starts the check of the chosen folder when what it depends on changed. Nothing is
  ## read until a folder is chosen, and nothing is checked while a run writes.
  ui.pollFolder(st)
  if ui.run.job != NoJob or ui.lengthActive: return
  let li = st.findShotLog(ui.logId)
  var treated = ""
  for path, kind in st.forcedKinds: treated.add path & ':' & $ord(kind) & ';'
  let key = if ui.srcFolder.len > 0 and li >= 0 and ui.haveShots and usableRecordMs(ui.recordMs):
      ui.srcFolder & '\0' & $ui.shotsKey & '\0' & $ui.recordMs & '\0' & $ord(ui.standard) &
        '\0' & $ord(ui.align) & '\0' & ui.folder & '\0' & treated & '\0' & $st.vendorGen &
        '\0' & $ui.correlated & '\0' & opts.sweepPath
    else: ""
  if key == ui.checkKey: return
  ui.stopCheck(st)
  ui.checkKey = key
  ui.checked = FolderResult()
  if key.len == 0: return
  ui.check = st.jobs.startFolder(ui.folderPlan(st, opts, false), ui.known)

proc startFolder(ui: var CutUi; st: AppState; opts: CutOptions) =
  ui.stopCheck(st)
  ui.haveRan = false
  ui.runFolder = ui.srcFolder
  ui.left.retire(ui.run, st.jobs) # none while one runs: the button is off then
  ui.run = st.jobs.startFolder(ui.folderPlan(st, opts, true), ui.known)

proc drawFolder(ui: var CutUi; st: AppState; t: Theme; marks: var Marks; wide: float32;
    opts: CutOptions) =
  ## The part of the window that slices a whole folder.
  igSeparator()
  wrapped("Folder of recordings: " & (if ui.srcFolder.len > 0: ui.srcFolder else: "not chosen"),
    wide)
  marks.mark("cut.srcFolder " & ui.srcFolder)
  let li = st.findShotLog(ui.logId)
  var why = ""
  if ui.srcFolder.len == 0: why = NeedSourceFolder
  elif li < 0: why = "Load a shot log first."
  elif not usableRecordMs(ui.recordMs): why = "The record length is not usable."
  elif ui.folder.len == 0: why = NeedFolder
  elif ui.correlated and ui.whyNotCorrelated(st, NaN).len > 0:
    why = ui.whyNotCorrelated(st, NaN)
  elif ui.check.job != NoJob or ui.checkKey.len == 0 or ui.lengthActive: why = FolderBeingRead
  elif ui.checked.reason.len > 0: why = ui.checked.reason
  elif ui.checked.refused.len > 0: why = ui.checked.refused
  elif ui.checked.countSliceable == 0: why = "No recording of the folder can be sliced."
  elif st.cutRunning: why = CutRunning
  if ui.srcFolder.len > 0:
    if ui.correlated and ui.whyNotCorrelated(st, NaN).len > 0:
      coloured(why, t.roles[rlWarning], wide)
      marks.mark("cut.folderRefused")
    elif ui.check.job != NoJob:
      wrapped(FolderBeingRead, wide)
      marks.mark("cut.folderReading")
    elif ui.checked.reason.len > 0:
      coloured(ui.checked.reason, t.roles[rlWarning], wide)
    elif ui.checked.refused.len > 0:
      coloured(ui.checked.refused, t.roles[rlWarning], wide)
      marks.mark("cut.folderRefused")
    elif ui.checked.listed:
      let words = checkWords(ui.checked)
      wrapped(words, wide)
      marks.mark("cut.folderCheck " & words)
      for line in skipLines(ui.checked):
        coloured(line, t.roles[rlTextDim], wide)
        marks.mark("cut.folderSkip " & line)
      let lost = unplacedWords(ui.checked)
      if lost.len > 0:
        coloured(lost, t.roles[rlWarning], wide)
        marks.mark("cut.folderUnplaced")
  let running = ui.run.job != NoJob
  igBeginDisabled(why.len > 0 or running)
  if igButton("Slice the folder##cut".cstring, ImVec2_c(x: 0, y: 0)): ui.startFolder(st, opts)
  igEndDisabled()
  marks.mark("cut.runFolder")
  tip(if running: "The folder is being sliced; the Jobs window shows its progress"
      elif why.len > 0: why
      else: "Slice every recording of the folder and write a file for each in the folder " &
        "above; nothing is replaced")
  if running:
    wrapped("Slicing the folder: the Jobs window shows how far it has come.", wide)
    marks.mark("cut.folderRunning")
  elif ui.haveRan:
    let words = if ui.ran.reason.len > 0: ui.ran.reason else: outcomeWords(ui.ran)
    coloured(words, if ui.ran.countWritten > 0: t.roles[rlText] else: t.roles[rlWarning], wide)
    marks.mark("cut.folderOutcome " & words)
    for line in outcomeLines(ui.ran):
      wrapped(line, wide)
      marks.mark("cut.folderLine " & line)

proc drawCut*(ui: var CutUi; st: AppState; t: Theme; marks: var Marks): CutDraw =
  ## The window, while it is open. Cut posts the command when the options can
  ## be used; the outcome of the last cut is under the buttons.
  ui.left.dropOver(st.jobs) # also while the window is closed
  if not ui.shown: return
  if ui.bringUp:
    igSetWindowFocus_Str(CutWindowTitle.cstring)
    ui.bringUp = false
  let vp = igGetMainViewport()
  igSetNextWindowPos(ImVec2_c(x: vp.WorkPos.x + igGetFontSize() * 4,
    y: vp.WorkPos.y + igGetFontSize() * 2), ImGui_Cond_FirstUseEver.cint, ImVec2_c(x: 0, y: 0))
  igSetNextWindowSize(ImVec2_c(x: igGetFontSize() * 40, y: igGetFontSize() * 50),
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
    igSameLine(0, -1)
    if igButton((if shown >= 0: "Choose another file...##cut" else: "Choose file...##cut").cstring,
        ImVec2_c(x: 0, y: 0)):
      result.askFile = true
    marks.mark("cut.chooseFile")
    tip(ChooseFileTip)
    igSameLine(0, -1)
    if igButton("Choose folder...##cut".cstring, ImVec2_c(x: 0, y: 0)):
      result.askSourceFolder = true
      result.askSourceAt = ui.srcFolder
    marks.mark("cut.chooseFolder")
    tip(ChooseFolderTip)
    let why = st.cutProblem()
    if shown < 0 and st.shotLogCount > 0:
      coloured(NeedSource, t.roles[rlWarning], wide)
      marks.mark("cut.needSource")
    elif why in [CutDerived, CutSignature]:
      coloured(why, t.roles[rlWarning], wide)
      marks.mark("cut.why " & why)
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
    ui.lengthActive = igIsItemActive()
    marks.mark("cut.length")
    marks.mark("cut.recordMs " & $ui.recordMs)
    igSetNextItemWidth(igGetFontSize() * 10)
    let groupable = facts.ready and facts.componentCodes >= 2
    let dtMs = if facts.ready: facts.dtMs else: NaN
    let opts = ui.options(st, groupable, dtMs)
    let corr = opts.sweepPath.len > 0 ## the records are correlated: not the recording's own
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
    if problem.len == 0 and ui.correlated:
      problem = ui.whyNotCorrelated(st, dtMs) # never an uncorrelated file while the tick is on
    if problem.len > 0:
      coloured(problem, t.roles[rlWarning], wide)
      marks.mark("cut.why " & problem)
    if shown >= 0 and tpKind in st.treatPendingOf(st.sessions[shown].path):
      coloured(PendingWords, t.roles[rlTextDim], wide)
      marks.mark("cut.kindPending")
    ui.drawAlign(marks)
    let segd = shown >= 0 and st.sessions[shown].facts.summary.standard == skSegd
    let uncarried = segd and facts.ready and facts.carryHeaderBytes == 0
    ui.drawFormat(marks, segd and not uncarried and not corr, uncarried)
    ui.drawOrder(marks, groupable,
      segd and not uncarried and not corr and ui.standard == csSegdRev3)
    ui.drawHeaders(st, marks)
    result.commands.add ui.drawCorrelated(st, t, marks, dtMs, wide, segd)
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
      var samples = int(round(opts.recordMs / facts.dtMs))
      if corr: samples = listenSamples(chosenSweep(st).samples, opts.recordMs, facts.dtMs)
      summary = summaryWords(ui.shots, facts.components, samples, opts,
        if corr: 0'i64 else: facts.carryHeaderBytes)
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
    let canCut = why.len == 0 and problem.len == 0 and ui.folder.len > 0 and
      nameWhy.len == 0 and not ui.dest.exists and not ui.dest.pending and
      summary.len > 0 and ui.run.job == NoJob
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
    let folderOpts = ui.options(st, false, NaN) # the grouped orders need a recording's headers
    ui.considerFolder(st, folderOpts)
    ui.drawFolder(st, t, marks, wide, folderOpts)
  igEnd()
  if not open: ui.shown = false
