## The application state, and the only two ways it changes:
##
## - `apply(state, command)`: a user intent, issued by the UI;
## - `drainInbox(state)`, once per frame: what the workers posted and the
##   jobs that finished.
##
## Both run on the UI thread, which owns the state; `initAppState` marks the
## thread that calls it as the UI thread. The UI reads the state through the
## accessors below, which do not let it change anything.
##
## **Trace panels.** A panel that shows a file has a reader thread
## (`core/reader`). Showing a gather holds the file (`Jobs.hold`) and hands
## it to the reader, which posts the panel's layout; the view then fits the
## whole gather. The UI reports what its plot shows (`ckView`); when the
## request sent last does not cover that view (`covers`), a new one is made
## (`requestFor`) and the panel's `requestGen` goes up. A tile is taken in
## only when it answers the newest request: older ones are dropped. The
## newest `MaxTiles` tiles of each panel are kept, so a view keeps showing
## what it has (the previous tile, the coarser one) until the new tile comes.
##
## **Views.** The frontend moves a panel's view with the `core/zoom` forms
## and reports each new one (`ckView`); a view reported past the data is
## kept inside it (`core/zoom`'s limits). A view that starts a gesture (a
## drag, a box zoom, a burst of wheel turns, a typed scale, a fit) is sent
## with `remember`, and the one it replaces is kept for "back" (`ckBack`).
## When `core` sets a view itself (back, or the whole gather once it is laid
## out) it bumps the panel's `jumps`, and the frontend follows.
##
## A command that does not fit the state (a file that is no longer open, a
## gather out of range) changes nothing and says why in the log, as a
## warning: the UI may issue a command in the same frame as the change that
## made it stale, and that must not crash anything.
##
## **No undo history.** Edits to traces (kill, reverse polarity) are kept as
## lists beside an untouched file, so each one is undone by its inverse;
## header edits are a patch, undone by removing an entry; views have "back".
## None of these needs a general history of commands.

import std/[math, os, sequtils]
import parseSEG
import filejobs, inbox, jobs, log, panels, pick, reader, selection, session, settings,
  threads, tiles, zoom

export inbox, jobs, log, panels, pick, selection, session, settings, threads, tiles, zoom

const
  MainPanel* = PanelId(1)
    ## The panel `initAppState` makes; opened files appear in it.
  MaxTiles* = 4 ## tiles kept per panel, newest last

type
  CommandKind* = enum
    ckOpen = "open"             ## open files (one interactive job each)
    ckClose = "close"           ## close an open file
    ckCancelJob = "cancel job"
    ckReorderJob = "reorder job"
    ckRemoveJob = "remove job"
    ckGather = "go to gather"   ## show another gather of the file a panel shows
    ckView = "view"             ## what a panel's plot shows (zoom, pan, size)
    ckDisplay = "display"       ## how a panel's layer 0 is drawn
    ckHeader = "display header" ## the rows of a panel's display header
    ckBack = "back"             ## a panel's view before the last gesture
    ckSettings = "settings"     ## scale units, monitor calibrations, the readout's fields
    ckHover = "hover"           ## the trace under the cursor
    ckSelect = "select"         ## change the selected traces
    ckClearSelection = "clear selection"

  Command* = object
    ## A user intent: the only way the UI changes the state.
    case kind*: CommandKind
    of ckOpen:
      paths*: seq[string]
        ## relative or absolute: one file opens once, however it is named
    of ckClose: file*: SessionId
    of ckCancelJob, ckRemoveJob: job*: JobId
    of ckReorderJob:
      reordered*: JobId
      position*: int            ## 0 runs next
    of ckGather, ckView, ckDisplay, ckHeader, ckBack:
      panel*: PanelId
      gather*: int              ## ckGather: index into the file's gathers
      view*: Viewport           ## ckView: what the panel's plot shows now
      remember*: bool           ## ckView: a gesture starts; keep the view it replaces for back
      display*: DisplaySettings ## ckDisplay: how layer 0 is drawn
      header*: HeaderChoice     ## ckHeader: the display header's rows
    of ckHover: trace*: int     ## survey-wide trace id; -1 for none
    of ckSelect:
      traces*: seq[int]         ## survey-wide trace ids
      mode*: SelectMode
    of ckClearSelection: discard
    of ckSettings: settings*: Settings

  Pending = object
    ## An open or close job the state waits for.
    job: JobId
    path: string
    session: Session ## a closing file's session, kept until its close job ends

  AppState* = object
    ## Everything the views show. Move-only.
    log: MessageLog
    selection: Selection
    panels: seq[Panel]
    sessions: seq[Session]
    opening, closing: seq[Pending]
    mail: seq[Msg]
    indexCache: string    ## the index cache folder; "" for none
    settings: Settings
    nextFile, nextPanel, nextBase: int
    tiles: seq[seq[Tile]] ## per panel, as `panels`: the newest last
    nextTile: uint64
    inbox: Inbox
    jobs: Jobs
      ## Fields are destroyed last to first: the runners stop before
      ## anything a running job uses is freed.
    readers: seq[PanelReader]
      ## per panel, as `panels`; started when the panel first shows a file.
      ## Declared last: the readers stop (and end their holds) before the
      ## jobs and the files go.

proc initAppState*(logCapacity: Positive = DefaultLogCapacity;
    jobHistory: Natural = DefaultJobHistory; indexCache = ""): AppState =
  ## The state of a program with no file open and one empty panel
  ## (`MainPanel`), with both job lanes running. Marks the calling thread as
  ## the UI thread. `indexCache` is the folder for parseSEG's index caches
  ## (the frontend passes one under the cache directory; it is created when
  ## first needed); "" opens every file without one.
  markUiThread()
  result = AppState(log: initMessageLog(logCapacity), inbox: initInbox(),
    jobs: initJobs(jobHistory), indexCache: indexCache, nextFile: 1,
    nextPanel: int(MainPanel) + 1, nextTile: 1)
  result.panels.add Panel(id: MainPanel)
  result.tiles.add newSeq[Tile]()
  result.readers.add PanelReader()

proc shutdown*(state: var AppState) =
  ## Stops the panels' readers, cancels every job and waits for the running
  ## ones to stop. Destroying the state does this too.
  assertUiThread()
  for r in state.readers:
    r.stop()
  state.jobs.stop()

# --------------------------------------------------------------- reading --

func log*(state: AppState): lent MessageLog {.inline.} =
  ## The message log.
  state.log

func selection*(state: AppState): lent Selection {.inline.} =
  ## The trace under the cursor, the selected traces, the gather on show.
  state.selection

func panels*(state: AppState): lent seq[Panel] {.inline.} =
  ## The trace panels, `MainPanel` first.
  state.panels

func sessions*(state: AppState): lent seq[Session] {.inline.} =
  ## The open files, in the order they were opened.
  state.sessions

func jobs*(state: AppState): lent Jobs {.inline.} =
  ## The jobs, for the Jobs window and the status bar (`list`, `info`).
  state.jobs

func indexCache*(state: AppState): lent string {.inline.} =
  ## The folder of parseSEG's index caches; "" for none.
  state.indexCache

func settings*(state: AppState): lent Settings {.inline.} =
  ## The user's settings: scale units, monitor calibrations, readout fields.
  state.settings

func tiles*(state: AppState; panelIndex: int): lent seq[Tile] {.inline.} =
  ## The tiles kept for `panels[panelIndex]`, oldest first: draw them in
  ## that order. Each has its own `id`, never reused.
  state.tiles[panelIndex]

func findPanel*(state: AppState; id: PanelId): int =
  ## The index of panel `id` in `panels`; -1 when there is none.
  for i, p in state.panels:
    if p.id == id: return i
  -1

func findSession*(state: AppState; id: SessionId): int =
  ## The index of open file `id` in `sessions`; -1 when it is not open.
  for i, s in state.sessions:
    if s.id == id: return i
  -1

func findTrace*(state: AppState; trace: int): int =
  ## The index in `sessions` of the file that holds survey-wide trace id
  ## `trace`; -1 when no open file does.
  for i, s in state.sessions:
    if trace in s: return i
  -1

proc missing(what: string) {.noinline, noreturn.} =
  raise newException(KeyError, what)

func panel*(state: AppState; id: PanelId): lent Panel =
  ## Panel `id`. Raises `KeyError` when there is none.
  let i = state.findPanel(id)
  if i < 0: missing($id & " does not exist")
  state.panels[i]

func session*(state: AppState; id: SessionId): lent Session =
  ## Open file `id`. Raises `KeyError` when it is not open.
  let i = state.findSession(id)
  if i < 0: missing($id & " is not open")
  state.sessions[i]

proc mailbox(state: AppState): Poster =
  ## A handle to the inbox, as workers have (tests import this module with
  ## `{.all.}` to post as a reader would).
  state.inbox.poster

proc report*(state: var AppState; severity: Severity; source, text: string) =
  ## Adds a message to the log: for what the frontend itself has to say (a
  ## dialog that could not be shown, a slow frame).
  state.log.add(severity, source, text)

# ---------------------------------------------------------------- helpers --

func plural(n: int; word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc canonical(path: string): string =
  ## `path` made absolute and normalized ("./a.sgy", "data/../a.sgy" and the
  ## full path name one file), without touching the disk: jobs compare files
  ## by these strings. As given, normalized, when there is no current
  ## directory to resolve it against.
  try:
    absolutePath(path).normalizedPath
  except OSError, ValueError:
    path.normalizedPath

proc ignore(state: var AppState; cmd: Command; why: string) =
  state.log.add(sevWarning, "commands", "Ignored \"" & $cmd.kind & "\": " & why & ".")

proc reader(state: var AppState; k: int): lent PanelReader =
  ## The reader of `panels[k]`, started when first needed.
  if state.readers[k].isNil:
    state.readers[k] = newPanelReader(state.panels[k].id, state.inbox.poster,
      state.jobs.holdRelease)
  state.readers[k]

proc newSource(state: var AppState; k: int) =
  ## Forgets what `panels[k]` knew about its traces: its layer 0 now shows
  ## something else, or nothing. Tells its reader.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.sourceGen = p.requestGen
  p.layout = PanelLayout()
  p.known = {}
  p.kind = gkUnknown
  p.pending = ReadRequest()
  p.clip = NaN
  p.back.setLen 0
  inc p.revision
  state.tiles[k].setLen 0
  var src = ReaderSource(gen: p.sourceGen)
  var busy = false
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = state.findSession(p.layers[0].source.file)
    let g = p.layers[0].source.gather
    if i >= 0 and g in 0 ..< state.sessions[i].gathers.len:
      let s = state.sessions[i]
      p.kind = s.gathers[g].kind
      if state.jobs.hold(s.path):
        src = ReaderSource(gen: p.sourceGen, file: s.filePtr, path: s.path,
          traces: s.gathers[g].traces, filter: p.layers[0].filter)
      else:
        busy = true
        state.log.add(sevWarning, s.name, s.name & " is busy (a job needs it to itself), " &
          "so it is not shown.")
  # Nothing to read (no file, or a file with no traces): the reader posts no
  # layout, so the empty one stands, and the panel says so instead of waiting.
  p.laidOut = src.file.isNil and not busy
  if not src.file.isNil or not state.readers[k].isNil:
    state.reader(k).show(src)

proc show(state: var AppState; panel: PanelId; file: SessionId; gather: int) =
  ## Points layer 0 of `panel` at `gather` of `file`, keeping its filter,
  ## pipeline and display; makes the layer when the panel has none.
  let k = state.findPanel(panel)
  if k < 0: return
  if state.panels[k].layers.len == 0:
    state.panels[k].layers.add recordLayer(file, gather)
  else:
    state.panels[k].layers[0].source = LayerSource(kind: lsRecord, file: file, gather: gather)
  state.newSource(k)
  state.selection.activeGather = GatherRef(file: file, gather: gather)
  inc state.selection.revision

func gatherKind(state: AppState; layer: Layer): GatherKind =
  ## The kind of the gather `layer` shows; unknown for none.
  result = gkUnknown
  if layer.source.kind == lsRecord:
    let i = state.findSession(layer.source.file)
    if i >= 0 and layer.source.gather in 0 ..< state.sessions[i].gathers.len:
      result = state.sessions[i].gathers[layer.source.gather].kind

proc requestView(state: var AppState; k: int) =
  ## Asks `panels[k]`'s reader for its view, unless the request sent last
  ## already covers it.
  template p: untyped = state.panels[k]
  if p.layers.len == 0 or p.layout.traces == 0 or state.readers[k].isNil: return
  let flow = p.layers[0].displayPipeline(state.gatherKind(p.layers[0]))
  let margin = displayMargin(flow, p.layout.dtMs)
  if p.pending.gen == p.requestGen and p.pending.covers(p.layout, p.view, margin): return
  var req = requestFor(p.layout, p.view, margin)
  if req.isEmpty: return
  inc p.requestGen
  req.gen = p.requestGen
  p.pending = req
  state.readers[k].request ReaderRequest(read: req, fields: p.shownFields, flow: flow,
    clipPercentile: p.layers[0].display.clipPercentile)

proc remember(state: var AppState; k: int) =
  ## Keeps `panels[k]`'s view for back, unless it is the one kept last or
  ## the panel shows nothing yet.
  template p: untyped = state.panels[k]
  if p.laidOut and p.view.traces.width > 0 and
      (p.back.len == 0 or not p.back[^1].sameSpans(p.view)):
    p.back.add p.view
    if p.back.len > MaxBack: p.back.delete(0)

proc refetch(state: var AppState; k: int; keepTiles: bool) =
  ## Drops the request sent last and asks again for `panels[k]`'s view:
  ## what a tile holds has changed.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.pending = ReadRequest()
  if not keepTiles:
    state.tiles[k].setLen 0
    p.clip = NaN
  inc p.revision
  state.requestView(k)

proc adopt(state: var AppState; s: sink Session) =
  ## Takes in a file an open job opened, and shows its first gather.
  if s.file.kind == skUnknown:
    state.log.add(s.file.log, s.name)
    state.log.add(sevError, s.name, s.name & " is not a SEG-Y, SEG-D or SEG-2 file, " &
      "so it was not opened.")
    return # `s` is closed here, on the UI thread: nothing else has it
  let id = SessionId(state.nextFile)
  inc state.nextFile
  s.register(id, state.nextBase)
  state.nextBase += s.len
  state.log.add(s.file.log, s.name)
  state.log.add(sevInfo, "open", "Opened " & s.name & ": " & plural(s.len, "trace") &
    " in " & plural(s.gathers.len, "gather") &
    (if s.file.fromCache: " (index from the cache)." else: "."))
  let gather = if s.gathers.len > 0: 0 else: -1
  state.sessions.add s
  state.show(MainPanel, id, gather)

proc closeSession(state: var AppState; i: int) =
  ## Takes open file `i` out of every view at once, cancels the jobs that use
  ## it, and closes it once none does (after its close job, on this thread).
  var s = move state.sessions[i]
  state.sessions.delete(i)
  for job in state.jobs.list:
    if job.state in {jsQueued, jsRunning} and
        (s.path in job.spec.reads or s.path in job.spec.exclusive):
      discard state.jobs.cancel(job.id)
  state.selection.forget(s.id, s.traceIds)
  for k in 0 ..< state.panels.len:
    let before = state.panels[k].layers.len
    state.panels[k].layers.keepItIf(not it.shows(s.id))
    if state.panels[k].layers.len != before:
      state.newSource(k) # the reader lets go of the file, then the close may run
  # Not cancellable: the file must not be released while a job still reads it.
  let job = state.jobs.submit(JobSpec(title: "Close " & s.name, lane: jlInteractive,
    exclusive: @[s.path], cancellable: false), closeWork())
  state.closing.add Pending(job: job, path: s.path, session: s)

proc endOpening(state: var AppState; i: int; how: JobState; error = "") =
  ## Says how open job `opening[i]` ended, and forgets it.
  let p = state.opening[i].path
  let name = p.extractFilename
  case how
  of jsFailed: state.log.add(sevError, name, "Cannot open " & p & ": " & error)
  of jsCancelled: state.log.add(sevInfo, name, "Opening " & name & " was cancelled.")
  else: discard # done: `adopt` took the file
  state.opening.delete(i)

proc onFinished(state: var AppState; job: JobInfo) =
  ## Says how a job ended, and lets go of what the state kept for it.
  for i, p in state.opening:
    if p.job == job.id:
      state.endOpening(i, job.state, job.error)
      return
  for i, p in state.closing:
    if p.job == job.id:
      let name = p.path.extractFilename
      if job.state == jsDone: state.log.add(sevInfo, name, "Closed " & name & ".")
      state.closing.delete(i) # the file is closed here, on the UI thread
      return
  case job.state
  of jsFailed: state.log.add(sevError, "jobs", job.spec.title & " failed: " & job.error)
  of jsCancelled: state.log.add(sevInfo, "jobs", job.spec.title & " was cancelled.")
  of jsDone:
    if job.spec.lane == jlBackground:
      state.log.add(sevInfo, "jobs", job.spec.title & " is done.")
  of jsQueued, jsRunning: discard

proc goToGather(state: var AppState; cmd: Command) =
  ## Shows gather `cmd.gather` of the file in layer 0 of `cmd.panel`.
  let k = state.findPanel(cmd.panel)
  if k < 0:
    state.ignore(cmd, $cmd.panel & " does not exist")
    return
  let shown = if state.panels[k].layers.len > 0: state.panels[k].layers[0].source
              else: LayerSource(kind: lsGenerated)
  let i = if shown.kind == lsRecord: state.findSession(shown.file) else: -1
  if i < 0:
    state.ignore(cmd, $cmd.panel & " shows no file")
  elif cmd.gather notin 0 ..< state.sessions[i].gathers.len:
    let s = state.sessions[i]
    state.ignore(cmd, "there is no gather " & $cmd.gather & ": " & s.name & " has " &
      plural(s.gathers.len, "gather") & ", from 0")
  elif cmd.gather != shown.gather:
    state.show(cmd.panel, shown.file, cmd.gather)

# ---------------------------------------------------------------- changes --

proc apply*(state: var AppState; cmd: Command) =
  ## Carries out `cmd`. Anything slow it starts runs as a job; `drainInbox`
  ## takes in the result.
  assertUiThread()
  case cmd.kind
  of ckOpen:
    if cmd.paths.len == 0: state.ignore(cmd, "no file was named")
    for given in cmd.paths:
      if given.len == 0:
        state.ignore(cmd, "a file name was empty")
        continue
      let path = canonical(given)
      let name = path.extractFilename
      if state.sessions.anyIt(it.path == path):
        state.log.add(sevInfo, name, name & " is already open.")
      elif state.opening.anyIt(it.path == path):
        state.log.add(sevInfo, name, name & " is already being opened.")
      else:
        let job = state.jobs.submit(JobSpec(title: "Open " & name, lane: jlInteractive,
          reads: @[path]), openWork(path, state.inbox.poster,
          indexCacheFile(state.indexCache, path)))
        state.opening.add Pending(job: job, path: path)
  of ckClose:
    let i = state.findSession(cmd.file)
    if i < 0: state.ignore(cmd, $cmd.file & " is not open")
    else: state.closeSession(i)
  of ckCancelJob:
    let job = state.jobs.info(cmd.job)
    if job.isNone: state.ignore(cmd, $cmd.job & " is not listed")
    elif state.jobs.cancel(cmd.job): discard
    elif job.get.spec.cancellable or job.get.state notin {jsQueued, jsRunning}:
      state.ignore(cmd, $cmd.job & " has finished")
    else: state.ignore(cmd, "\"" & job.get.spec.title & "\" cannot be cancelled")
  of ckReorderJob:
    if not state.jobs.reorder(cmd.reordered, cmd.position):
      state.ignore(cmd, $cmd.reordered & " is not queued")
  of ckRemoveJob:
    let job = state.jobs.info(cmd.job)
    if job.isNone: state.ignore(cmd, $cmd.job & " is not listed")
    elif state.jobs.remove(cmd.job):
      # A queued job never runs now, so it never finishes either: an open
      # left waiting would refuse every later open of its file.
      if job.get.state == jsQueued:
        for i, p in state.opening:
          if p.job == cmd.job:
            state.endOpening(i, jsCancelled)
            break
    elif job.get.state in {jsQueued, jsRunning} and not job.get.spec.cancellable:
      state.ignore(cmd, "\"" & job.get.spec.title & "\" cannot be removed before it has run")
    else: state.ignore(cmd, $cmd.job & " is running; cancel it first")
  of ckGather:
    state.goToGather(cmd)
  of ckView:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    else:
      # Never a view past the data, whoever asks (the frontend keeps its
      # own views inside already).
      var v = cmd.view
      if state.panels[k].layout.traces > 0:
        v = kept(v, limitsOf(state.panels[k].layout))
      if v != state.panels[k].view:
        if cmd.remember: state.remember(k)
        state.panels[k].view = v
        state.requestView(k)
  of ckBack:
    # Nothing to go back to is not a mistake: the control is only disabled.
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].back.len > 0:
      template p: untyped = state.panels[k]
      var v = p.back.pop()
      v.columns = p.view.columns # the plot's size is its own
      v.rows = p.view.rows
      p.view = v
      inc p.jumps
      inc p.revision
      state.requestView(k)
  of ckSettings:
    let (s, dropped) = cleaned(cmd.settings)
    if dropped > 0:
      state.log.add(sevWarning, "settings", $dropped & " of the settings given could not " &
        "be used (a calibration that is not a positive number, or an entry given twice) " &
        "and were left out.")
    state.settings = s
  of ckDisplay:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    else:
      let was = state.panels[k].layers[0].display
      let d = cmd.display
      state.panels[k].layers[0].display = d
      inc state.panels[k].revision
      if d.gain != was.gain or d.agcWindowMs != was.agcWindowMs or
          d.clipPercentile != was.clipPercentile:
        state.refetch(k, keepTiles = false)
  of ckHeader:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif not cmd.header.auto and cmd.header.fields.len == 0:
      state.ignore(cmd, "a display header needs at least one field")
    else:
      state.panels[k].header = cmd.header
      state.refetch(k, keepTiles = true)
  of ckHover:
    if cmd.trace != -1 and state.findTrace(cmd.trace) < 0:
      state.ignore(cmd, "no open file has trace " & $cmd.trace)
    else:
      discard state.selection.setHover(cmd.trace)
  of ckSelect:
    var known: seq[int]
    for t in cmd.traces:
      if state.findTrace(t) >= 0: known.add t
    if known.len < cmd.traces.len:
      state.ignore(cmd, plural(cmd.traces.len - known.len, "trace") & " of " &
        $cmd.traces.len & " are in no open file")
    if known.len > 0 or cmd.mode == smReplace:
      state.selection.select(known, cmd.mode)
  of ckClearSelection:
    state.selection.clear()

proc drainInbox*(state: var AppState): bool =
  ## Takes in what the workers posted and how the jobs ended, in that order
  ## per job. Call it once per frame; it never waits. True when anything
  ## came in.
  assertUiThread()
  # Finished jobs first: a job posts before it finishes, so every message of
  # a job seen finishing here is in the mail drained next.
  let finished = state.jobs.takeFinished()
  state.inbox.drainInto(state.mail)
  result = finished.len > 0 or state.mail.len > 0
  for m in state.mail.mitems:
    case m.kind
    of mkOpened: state.adopt(move m.session)
    of mkLog: state.log.add(move m.entry)
    of mkLayout:
      let k = state.findPanel(m.panel)
      if k >= 0 and m.sourceGen == state.panels[k].sourceGen:
        template p: untyped = state.panels[k]
        p.layout = m.layout
        p.laidOut = true
        p.known = m.known
        p.view = fitAll(p.layout, p.view.columns, p.view.rows)
        inc p.jumps
        inc p.revision
        state.requestView(k)
    of mkTile:
      let k = state.findPanel(m.tile.panel)
      if k >= 0 and m.tile.request.gen == state.panels[k].requestGen:
        m.tile.id = state.nextTile
        inc state.nextTile
        if state.panels[k].clip.isNaN: state.panels[k].clip = m.tile.clip
        state.tiles[k].add move m.tile
        if state.tiles[k].len > MaxTiles: state.tiles[k].delete(0)
        inc state.panels[k].revision
  state.mail.setLen 0
  for job in finished:
    state.onFinished(job)
