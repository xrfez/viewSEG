## The Missing traces window: a scan of the open folder (subfolders included)
## against the loaded relation file.
##
## The scan is a background job. The window reads its sink only after the job
## is no longer running. A cancel leaves what was already shown. Listing uses
## the same file list the folder scan uses (`listedNames`), not a second walk
## posted to the file list.

import parseSEG
import imguin/cimgui
import ../../core/[filejobs, jobs, missingjobs, state]
import ../../view/missingwords
import marks

type
  ScanNote = ref object
    capped: bool

  MissingUi* = object
    scanJob: JobId = NoJob
    sink: MissingSink
    note: ScanNote
    wantScan: bool
    scanning: bool
    have: bool
    capped: bool
    folder: string
    status: string

  MissingOutput* = object
    commands*: seq[Command]

proc requestScan*(ui: var MissingUi) =
  ## The next draw starts a scan, cancelling one already running.
  ui.wantScan = true

proc canScan(st: AppState): bool =
  missingReady(st.fileList.folder.len > 0, st.relationLayer >= 0)

proc whyNot(st: AppState): string =
  missingWhy(st.fileList.folder.len > 0, st.relationLayer >= 0)

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
  ui.have = true
  ui.status = Ready

proc poll(ui: var MissingUi; st: AppState) =
  if ui.scanJob == NoJob: return
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
  ui.poll(st)
  if ui.wantScan:
    ui.wantScan = false
    if canScan(st): ui.submit(st)
    elif not ui.have: ui.status = whyNot(st)

proc drawMissing*(ui: var MissingUi; title: string; st: AppState; marks: var Marks): MissingOutput =
  ## The window titled `title`. A scan asked for since the last draw starts here.
  ui.consider(st)
  if igBegin(title.cstring, nil, 0):
    marks.markWindow("missing")
    if ui.status.len == 0: ui.status = if canScan(st): Ready else: whyNot(st)
    igTextUnformatted(ui.status.cstring, nil)
    if ui.scanning: marks.mark("missing.scanning")
    if ui.have and not ui.scanning: marks.mark("missing.ready")
    if ui.capped: igTextUnformatted(CappedNote.cstring, nil)
    if ui.scanning:
      if igButton(StopButton.cstring, ImVec2_c(x: 0, y: 0)) and ui.scanJob != NoJob:
        result.commands.add Command(kind: ckCancelJob, job: ui.scanJob)
      marks.mark("missing.stop")
    else:
      igBeginDisabled(not canScan(st))
      if igButton(RescanButton.cstring, ImVec2_c(x: 0, y: 0)): ui.requestScan()
      igEndDisabled()
      marks.mark("missing.rescan")
  igEnd()
  ui.consider(st)
