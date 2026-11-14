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
## A command that does not fit the state (a file that is no longer open, a
## gather out of range) changes nothing and says why in the log, as a
## warning: the UI may issue a command in the same frame as the change that
## made it stale, and that must not crash anything.
##
## **No undo history.** Edits to traces (kill, reverse polarity) are kept as
## lists beside an untouched file, so each one is undone by its inverse;
## header edits are a patch, undone by removing an entry; views have "back".
## None of these needs a general history of commands.

import std/[os, sequtils]
import parseSEG
import filejobs, inbox, jobs, log, panels, selection, session, threads

export inbox, jobs, log, panels, selection, session, threads

const MainPanel* = PanelId(1)
  ## The panel `initAppState` makes; opened files appear in it.

type
  CommandKind* = enum
    ckOpen = "open"           ## open files (one interactive job each)
    ckClose = "close"         ## close an open file
    ckCancelJob = "cancel job"
    ckReorderJob = "reorder job"
    ckRemoveJob = "remove job"
    ckGather = "go to gather" ## show another gather of the file a panel shows
    ckHover = "hover"         ## the trace under the cursor
    ckSelect = "select"       ## change the selected traces
    ckClearSelection = "clear selection"

  Command* = object
    ## A user intent: the only way the UI changes the state.
    case kind*: CommandKind
    of ckOpen: paths*: seq[string]
    of ckClose: file*: SessionId
    of ckCancelJob, ckRemoveJob: job*: JobId
    of ckReorderJob:
      reordered*: JobId
      position*: int        ## 0 runs next
    of ckGather:
      panel*: PanelId
      gather*: int          ## index into the file's gathers
    of ckHover: trace*: int ## survey-wide trace id; -1 for none
    of ckSelect:
      traces*: seq[int]     ## survey-wide trace ids
      mode*: SelectMode
    of ckClearSelection: discard

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
    nextFile, nextPanel, nextBase: int
    inbox: Inbox
    jobs: Jobs
      ## Declared last: fields are destroyed last to first, so the runners
      ## stop before anything a running job uses is freed.

proc initAppState*(logCapacity: Positive = DefaultLogCapacity;
    jobHistory: Natural = DefaultJobHistory): AppState =
  ## The state of a program with no file open and one empty panel
  ## (`MainPanel`), with both job lanes running. Marks the calling thread as
  ## the UI thread.
  markUiThread()
  result = AppState(log: initMessageLog(logCapacity), inbox: initInbox(),
    jobs: initJobs(jobHistory), nextFile: 1, nextPanel: int(MainPanel) + 1)
  result.panels.add Panel(id: MainPanel)

proc shutdown*(state: var AppState) =
  ## Cancels every job and waits for the running ones to stop. Destroying the
  ## state does this too.
  assertUiThread()
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

proc report*(state: var AppState; severity: Severity; source, text: string) =
  ## Adds a message to the log: for what the frontend itself has to say (a
  ## dialog that could not be shown, a slow frame).
  state.log.add(severity, source, text)

# ---------------------------------------------------------------- helpers --

func plural(n: int; word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc ignore(state: var AppState; cmd: Command; why: string) =
  state.log.add(sevWarning, "commands", "Ignored \"" & $cmd.kind & "\": " & why & ".")

proc show(state: var AppState; panel: PanelId; file: SessionId; gather: int) =
  ## Points layer 0 of `panel` at `gather` of `file`, keeping its filter,
  ## pipeline and display; makes the layer when the panel has none.
  let k = state.findPanel(panel)
  if k < 0: return
  if state.panels[k].layers.len == 0:
    state.panels[k].layers.add recordLayer(file, gather)
  else:
    state.panels[k].layers[0].source = LayerSource(kind: lsRecord, file: file, gather: gather)
  inc state.panels[k].requestGen
  inc state.panels[k].revision
  state.selection.activeGather = GatherRef(file: file, gather: gather)
  inc state.selection.revision

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
    " in " & plural(s.gathers.len, "gather") & ".")
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
  for p in state.panels.mitems:
    let before = p.layers.len
    p.layers.keepItIf(not it.shows(s.id))
    if p.layers.len != before:
      inc p.requestGen
      inc p.revision
  let job = state.jobs.submit(JobSpec(title: "Close " & s.name, lane: jlInteractive,
    exclusive: @[s.path]), closeWork())
  state.closing.add Pending(job: job, path: s.path, session: s)

proc onFinished(state: var AppState; job: JobInfo) =
  ## Says how a job ended, and lets go of what the state kept for it.
  for i, p in state.opening:
    if p.job == job.id:
      let name = p.path.extractFilename
      case job.state
      of jsFailed: state.log.add(sevError, name, "Cannot open " & p.path & ": " & job.error)
      of jsCancelled: state.log.add(sevInfo, name, "Opening " & name & " was cancelled.")
      else: discard # done: `adopt` took the file
      state.opening.delete(i)
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
    for path in cmd.paths:
      let name = path.extractFilename
      if path.len == 0:
        state.ignore(cmd, "a file name was empty")
      elif state.sessions.anyIt(it.path == path):
        state.log.add(sevInfo, name, name & " is already open.")
      elif state.opening.anyIt(it.path == path):
        state.log.add(sevInfo, name, name & " is already being opened.")
      else:
        let job = state.jobs.submit(JobSpec(title: "Open " & name, lane: jlInteractive,
          reads: @[path]), openWork(path, state.inbox.poster))
        state.opening.add Pending(job: job, path: path)
  of ckClose:
    let i = state.findSession(cmd.file)
    if i < 0: state.ignore(cmd, $cmd.file & " is not open")
    else: state.closeSession(i)
  of ckCancelJob:
    let job = state.jobs.info(cmd.job)
    if job.isNone: state.ignore(cmd, $cmd.job & " is not listed")
    elif not state.jobs.cancel(cmd.job): state.ignore(cmd, $cmd.job & " has finished")
  of ckReorderJob:
    if not state.jobs.reorder(cmd.reordered, cmd.position):
      state.ignore(cmd, $cmd.reordered & " is not queued")
  of ckRemoveJob:
    let job = state.jobs.info(cmd.job)
    if job.isNone: state.ignore(cmd, $cmd.job & " is not listed")
    elif not state.jobs.remove(cmd.job): state.ignore(cmd, $cmd.job & " is running; cancel it first")
  of ckGather:
    state.goToGather(cmd)
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
  state.mail.setLen 0
  for job in finished:
    state.onFinished(job)
