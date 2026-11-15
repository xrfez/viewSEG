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
## **Order.** `ckSort` gives layer 0 an order (keys, or the file's order):
## the panel's reader sorts, off this thread, and the view stays where it
## is. The plot goes on drawing the tiles in the old order until the first
## tile in the new one comes (`sorting` says so meanwhile), then drops them.
##
## A command that does not fit the state (a file that is no longer open, a
## gather out of range) changes nothing and says why in the log, as a
## warning: the UI may issue a command in the same frame as the change that
## made it stale, and that must not crash anything. A hover is the
## exception: it comes with every move of the mouse, so a hover on a trace
## no open file has clears the hover and says nothing.
##
## **Highlighting, linked.** The trace under the plot's pointer (`ckHover`)
## and the selected traces (`ckSelect`, `ckClearSelection`) are survey-wide
## trace ids in the `Selection`, so the plot and the map show the same
## ones. A hovered trace comes with the points it was recorded at
## (`hoverAt`: from its keys as a tile carries them, so that a loaded
## relation file fills the stations its headers lack), which the map lights
## up; the points under the map's pointer (`ckHoverPoints`) come with the
## traces recorded there (`hoverTraces`), which the plot draws as it draws
## its own hover. `ckShowPoints` shows the record of a source's traces;
## `ckSelectPoints` selects points and their traces, or the stations along
## a line from the point clicked last (a range). When the hover lights
## nothing up in the other view, `hoverNote` says why. None of it reads a
## trace or makes a layer again: both are found again only when the survey
## changes (`relink`).
##
## **Settings.** The settings (`core/settings`) change only through
## commands: `ckSettings`, and the plot's display, order and display header,
## which a new plot window then starts with; opening a file adds it to the
## recent files. Given a folder (`keepSettingsIn`), they are saved there by
## the disk thread a moment after they last changed (`SaveDelay`, `persist`)
## and at `shutdown`; `ckExportSettings` and `ckImportSettings` write and
## read a file of the user's, and `ckResetSettings` goes back to the
## defaults, keeping a copy.
##
## **Edits to traces.** Killing a trace and reversing its polarity
## (`ckEdit`) change lists kept per file (`core/edits`), by the trace's
## index in the file, never the file: they hold for the session, through
## another record, a sort, a gain change, and a step to another file and
## back (the file is opened again under a new id, the lists are its path's).
## Each change has the panels that show the file make their view's tiles
## again (the reader does it from the samples it holds when it can); the
## tiles from before are drawn until then. A kill, or a restore, also has
## the next tile set the panel's level again, as the level leaves killed
## traces out.
##
## **The survey** (`core/survey`): where sources and receivers are, for the
## map. Each open file's positions are read from its keys by a job once it
## is open (`surveyjobs.positionsWork`), and leave with the file. Survey
## files (SPS, SEG P1) are loaded on their own (`ckLoadSurvey`): a file
## named to File > Open, dropped, given on the command line or clicked in
## the file list that is a survey file goes there instead of the plot (the
## open job tells by its first bytes, `surveyjobs.openFileWork`).
##
## **No undo history.** Each change to the edits is its own inverse, so
## `ckUndoEdit` reverts a file's last one and `ckClearEdits` takes every
## edit away (and is undone the same way); header edits are a patch, undone
## by removing an entry; views have "back". None of these needs a general
## history of commands.

import std/[algorithm, math, monotimes, os, sequtils, sets, strutils, tables, times]
import parseSEG
from processSEG/core/workspace import Workspace, initWorkspace
import diskio, edits, filejobs, filelist, inbox, jobs, layouts, log, mapstate, panels, persist,
  pick, reader, selection, session, settings, survey, surveyjobs, threads, tiles, watch, zoom

export edits, filelist, inbox, jobs, layouts, log, mapstate, panels, persist, pick, selection,
  session, settings, survey, threads, tiles, zoom
export WatchInterval

const
  MainPanel* = PanelId(1)
    ## The panel `initAppState` makes; opened files appear in it.
  MaxTiles* = 4         ## tiles kept per panel, newest last
  FloatValues* = 32_768 ## values in view the Float gain takes its level from, at most
  MaxNotices* = 20      ## notices kept
  MaxPanelValues* = 48 * 1024 * 1024
    ## the values (192 MiB, and as much on the GPU) a panel's tiles hold at
    ## most: the oldest are dropped first, the newest is always kept

type
  CommandKind* = enum
    ckOpen = "open"                      ## open files (one interactive job each) and keep them open
    ckBrowse = "browse"                  ## list files and folders in the file list
    ckShowFile = "show file"             ## show a file in a panel, in place of the one it shows
    ckShowTrace = "show trace"           ## show a trace of a file (a message names it), selected
    ckClose = "close"                    ## close an open file
    ckCancelJob = "cancel job"
    ckReorderJob = "reorder job"
    ckRemoveJob = "remove job"
    ckGather = "go to gather"            ## show another gather of the file a panel shows
    ckView = "view"                      ## what a panel's plot shows (zoom, pan, size)
    ckDisplay = "display"                ## how a panel's layer 0 is drawn
    ckHeader = "display header"          ## the rows of a panel's display header
    ckSort = "sort"                      ## the order of a panel's traces
    ckFilter = "trace filter"            ## which of the record's traces a panel shows
    ckReverseAll = "reverse all"         ## reverse the polarity of every trace of a panel, or not
    ckBack = "back"                      ## a panel's view before the last gesture
    ckSettings = "settings"              ## replace the settings
    ckExportSettings = "export settings" ## write the settings to a file of the user's
    ckImportSettings = "import settings" ## take settings in from such a file
    ckResetSettings = "reset settings"   ## back to the defaults
    ckLayout = "window layout"           ## how the windows are arranged now
    ckSaveLayout = "save layout"         ## keep the arrangement under a name
    ckLoadLayout = "load layout"         ## arrange the windows as a layout file says
    ckExportLayout = "export layout"     ## write the arrangement to a file of the user's
    ckImportLayout = "import layout"     ## load such a file and keep it among the layouts
    ckExportLog = "export messages"      ## write the messages to a file of the user's
    ckEdit = "edit traces"               ## kill or restore traces, reverse their polarity or not
    ckUndoEdit = "undo edit"             ## revert the last change to the edits of a panel's file
    ckClearEdits = "clear edits"         ## take every edit of a panel's file away
    ckHover = "hover"                    ## the trace under the cursor
    ckSelect = "select"                  ## change the selected traces
    ckClearSelection = "clear selection"
    ckLoadSurvey = "load survey"         ## read SPS or P1 files into the survey
    ckUnloadSurvey = "unload survey"     ## take a survey file's layer out of the survey
    ckMapView = "map view"               ## what the map shows (zoom, pan, size)
    ckMapBack = "map back"               ## the map's view before the last gesture
    ckMapLayer = "map layer"             ## show or hide a layer of the map
    ckSelectPoints = "select points"     ## change the points selected on the map, and their traces
    ckHoverPoints = "hover points"       ## the points under the map's pointer, and their traces
    ckShowPoints = "show points' record" ## show the record of the traces recorded at map points

  Command* = object
    ## A user intent: the only way the UI changes the state.
    case kind*: CommandKind
    of ckOpen, ckBrowse, ckLoadSurvey:
      paths*: seq[string]
        ## relative or absolute: one file opens once, however it is named
      showFirst*: bool                ## ckBrowse: show the first file found in the main panel
    of ckClose: file*: SessionId
    of ckCancelJob, ckRemoveJob: job*: JobId
    of ckReorderJob:
      reordered*: JobId
      position*: int                  ## 0 runs next
    of ckGather, ckView, ckDisplay, ckHeader, ckSort, ckReverseAll, ckBack, ckShowFile,
        ckShowTrace, ckEdit, ckUndoEdit, ckClearEdits, ckFilter:
      panel*: PanelId
      gather*: int                    ## ckGather: index into the file's gathers
      path*: string                   ## ckShowFile, ckShowTrace: the file to show
      traceIndex*: int                ## ckShowTrace: the trace's index (in its record)
      recordIndex*: int               ## ckShowTrace: the SEG-D record it counts in; -1: the file
      listFolder*: bool               ## ckShowFile: the file list lists its folder too
      view*: Viewport                 ## ckView: what the panel's plot shows now
      remember*: bool                 ## ckView: a gesture starts; keep the view it replaces for back
      display*: DisplaySettings       ## ckDisplay: how layer 0 is drawn
      header*: HeaderChoice           ## ckHeader: the display header's rows
      order*: seq[SortKey]            ## ckSort: layer 0's keys, the first first; empty: the file's order
      reverse*: bool                  ## ckReverseAll: every trace of layer 0 reversed, or none
      edit*: TraceEdit                ## ckEdit: killed, or reversed
      edited*: seq[int]               ## ckEdit: survey-wide ids of traces of the panel's file
      on*: bool                       ## ckEdit: the edit given (true) or taken away
      filter*: TraceFilter            ## ckFilter: layer 0's traces (seismic, auxiliary)
    of ckHover: trace*: int           ## survey-wide trace id; -1 for none
    of ckSelect:
      traces*: seq[int]               ## survey-wide trace ids
      mode*: SelectMode
    of ckClearSelection, ckResetSettings: discard
    of ckSettings: settings*: Settings
    of ckExportSettings, ckImportSettings, ckLoadLayout, ckExportLayout, ckImportLayout,
        ckExportLog:
      docPath*: string                ## the file written or read
    of ckLayout: arrangement*: string ## the toolkit's layout text
    of ckSaveLayout: layoutName*: string
    of ckUnloadSurvey: layer*: SurveyLayerId
    of ckMapView:
      mapView*: MapView               ## what the map shows now
      mapRemember*: bool              ## a gesture starts: keep the view it replaces for back
    of ckMapBack: discard
    of ckMapLayer:
      mapLayer*: MapLayerKey
      shown*: bool                    ## drawn, or hidden
    of ckSelectPoints, ckHoverPoints, ckShowPoints:
      points*: seq[PointRef]
        ## ckSelectPoints: the points; ckHoverPoints: those under the
        ## pointer (none: off every point); ckShowPoints: those on the spot
        ## clicked, whose traces' record the main panel shows
      pointMode*: SelectMode
        ## ckSelectPoints: replace, add, toggle or remove, their traces
        ## likewise; or a range, from the point clicked last along its line
        ## to the first of `points`

  Notice* = object
    ## A brief notice: a background job ended (the frontend shows it for a
    ## moment; the log keeps it).
    severity*: Severity
    text*: string
    serial*: int ## counts up from 0, never reused

  Pending = object
    ## An open or close job the state waits for.
    job: JobId
    path: string
    session: Session ## a closing file's session, kept until its close job ends
    panel: PanelId   ## an open: the panel it is shown in (`ckShowFile`); NoPanel: the main one
    gather: int      ## an open: the gather shown first (a file opened again: the one it showed)
    unwanted: bool   ## an open no longer wanted (another file was chosen): dropped when it comes
    follow: bool     ## an open "Follow the latest" made: shown only when the file is whole
    quiet: bool      ## a close of a file the plot stepped away from: not logged

  Reopen = object
    ## A panel that showed a file another program changed: it shows the
    ## file again once the file stops changing.
    path: string
    panel: PanelId
    gather: int

  Loading = object
    ## A survey file being loaded, or an open file's positions being read.
    job: JobId
    path: string
    session: SessionId ## positions: the open file; `NoSession` for a survey file

  Linked = tuple[survey, selection, loading: int; active: GatherRef]
    ## what the hover's links and note were found from

  AppState* = object
    ## Everything the views show. Move-only.
    log: MessageLog
    selection: Selection
    hoverNote: string     ## why the hover lights nothing up; "" when it does
    linked: Linked
    survey: Survey        ## the survey files loaded and the open files' positions
    map: MapState         ## the map's view and hidden layers
    loading: seq[Loading] ## the jobs that fill the survey
    checking: seq[tuple[job: JobId; relations: ref SurveyGeometry]]
      ## the relations each record check reads in place, kept alive until it
      ## ends (destroyed after `jobs`, whose runners stop first)
    loadNamed: seq[string]
      ## the files the listing was asked for: loaded when it finds them survey files
    saidPositions: HashSet[string]
      ## files whose positions' problems were said; folders said to hold no coordinates
    panels: seq[Panel]
    sessions: seq[Session]
    opening, closing: seq[Pending]
    files: FileList ## the file list
    edits: Table[string, FileEdits]
      ## per file (its canonical path): the traces killed and reversed
    noEdits: FileEdits ## always empty: `editsOf` for a file with none
    showFound: PanelId ## show the first file the listing finds here; NoPanel for none
    jump: tuple[path: string; trace, record: int]
      ## a trace to show once its file is open (`ckShowTrace`); "" for none
    oldScans: seq[JobId] ## scans replaced by a newer listing: they end quietly
    watch: FolderWatch
      ## looks at the listed folder and the open files; none until needed
    watchEvery: Duration ## the pause between its looks
    reopens: seq[Reopen] ## panels waiting for a changed file to stop changing
    followed: HashSet[string]
      ## files "Follow the latest" opened (each is shown once)
    followedUpTo: Time
      ## the modification time of the file "Follow the latest" showed last:
      ## an older one is never followed after it (it would step back in time)
    onDiskSaid: Table[string, string]
      ## per open file: what was said last of its changes
    editStamps: Table[string, tuple[size: int64; modified: Time]]
      ## per file with edits: its size and time when they were made
    notices: seq[Notice] ## the newest `MaxNotices`
    nextNotice: int
    mail: seq[Msg]
    indexCache: string ## the index cache folder; "" for none
    settings: Settings
    nextFile, nextPanel, nextBase: int
    tiles: seq[seq[Tile]] ## per panel, as `panels`: the newest last
    nextTile: uint64
    scratch: Workspace ## for the Float gain's level, on this thread
    inbox: Inbox
    disk: DiskIo ## writes the session log and the settings; none until needed
    logFile: string ## the session log; "" for none
    logged: int ## the log's serial the session log has reached
    configDir: string ## where the settings and layouts are saved; "" for nowhere
    keepsSettings: bool ## the settings are saved there; false: their file is left alone
    backups: seq[string] ## backups of the settings asked for this run: no name twice
    defaults: Settings ## what a reset goes back to
    settingsRev: int ## bumped on every change of `settings`
    savedRev: int ## the revision saved last
    changedAt: MonoTime ## when `settings` last changed
    arrangement: string ## how the windows are arranged now (the toolkit's text)
    layoutRev, layoutSaved: int
    layoutAt: MonoTime ## when the arrangement last changed
    layoutList: seq[SavedLayout]
    loaded: Layout ## the layout loaded last, for the frontend to show
    loads: int ## bumped each time a layout is loaded
    jobs: Jobs
      ## Fields are destroyed last to first: the runners stop before
      ## anything a running job uses is freed.
    readers: seq[PanelReader]
      ## per panel, as `panels`; started when the panel first shows a file.
      ## Declared last: the readers stop (and end their holds) before the
      ## jobs and the files go.

proc initAppState*(logCapacity: Positive = DefaultLogCapacity;
    jobHistory: Natural = DefaultJobHistory; indexCache = "";
    watchEvery = WatchInterval): AppState =
  ## The state of a program with no file open and one empty panel
  ## (`MainPanel`), with both job lanes running. Marks the calling thread as
  ## the UI thread. `indexCache` is the folder for parseSEG's index caches
  ## (the frontend passes one under the cache directory; it is created when
  ## first needed); "" opens every file without one. The folder listed and
  ## the open files are looked at every `watchEvery` (`core/watch`).
  markUiThread()
  result = AppState(log: initMessageLog(logCapacity), inbox: initInbox(),
    jobs: initJobs(jobHistory), indexCache: indexCache, nextFile: 1,
    nextPanel: int(MainPanel) + 1, nextTile: 1, scratch: initWorkspace(),
    files: FileList(job: NoJob), watchEvery: watchEvery)
  result.panels.add Panel(id: MainPanel)
  result.tiles.add newSeq[Tile]()
  result.readers.add PanelReader()

const SaveDelay* = initDuration(seconds = 1)
  ## settings are saved this long after their last change (and at shutdown)

proc diskIo(state: var AppState): lent DiskIo =
  ## The disk thread, started when first needed.
  if state.disk.isNil: state.disk = newDiskIo(state.inbox.poster)
  state.disk

proc folderWatch(state: var AppState): lent FolderWatch =
  ## The folder's watch, started when first needed.
  if state.watch.isNil: state.watch = newFolderWatch(state.inbox.poster, state.watchEvery)
  state.watch

proc logTo*(state: var AppState; dir: string) =
  ## From now on, writes the log to a new file in `dir`, this run's session
  ## log (`sessionLogPath`), off this thread, entries logged so far first;
  ## removes the oldest session logs there, keeping `KeptSessionLogs`.
  assertUiThread()
  discard state.diskIo
  state.logFile = sessionLogPath(dir)
  state.logged = state.log.nextSerial - state.log.len
  state.disk.prune(dir, SessionLogPrefix, SessionLogSuffix, KeptSessionLogs - 1,
    spare = state.logFile)

func logFile*(state: AppState): lent string {.inline.} =
  ## This run's session log; "" when the log is not written to a file.
  state.logFile

proc writeLog(state: var AppState) =
  ## Hands what was logged since the last call to the disk thread, which
  ## makes the lines: a line takes a few microseconds (the local time), a
  ## copy of the entry a fraction of that.
  if state.logFile.len == 0 or state.logged == state.log.nextSerial: return
  var text = ""
  let first = state.log.nextSerial - state.log.len
  if state.logged < first:
    text.add "(" & $(first - state.logged) & " messages were dropped before they " &
      "could be written)\n"
  var entries = newSeqOfCap[LogEntry](state.log.nextSerial - max(state.logged, first))
  for e in state.log.since(state.logged):
    entries.add e
  state.logged = state.log.nextSerial
  state.disk.append(state.logFile, text, "the session log", entries)

proc settingsFile*(state: AppState): string =
  ## Where the settings are saved; "" when they are not.
  if state.configDir.len == 0 or not state.keepsSettings: ""
  else: state.configDir / SettingsFileName

proc keepSettingsIn*(state: var AppState; dir: string; loaded: LoadedSettings) =
  ## Takes the settings `loadSettings` read from `dir` and logs what it
  ## said; from now on, saves them in `dir`'s `SettingsFileName`, off this
  ## thread, `SaveDelay` after they last changed and at `shutdown` (unless
  ## `loaded` says they must not be: the file is left as it is).
  assertUiThread()
  for (severity, text) in loaded.notes:
    state.log.add(severity, "settings", text)
  state.settings = cleaned(loaded.settings)[0]
  state.defaults = cleaned(loaded.defaults)[0]
  state.configDir = dir
  state.keepsSettings = loaded.saveable
  inc state.settingsRev
  state.savedRev = if loaded.rewrite: state.settingsRev - 1 else: state.settingsRev
  state.changedAt = getMonoTime()
  discard state.diskIo

proc saveNamed(state: var AppState; name, imgui: string) =
  ## Keeps `imgui` as the user's layout `name`, replacing one of that name.
  let path = layoutPath(state.configDir, name)
  state.diskIo.replace(path, layoutDocument(Layout(name: name, imgui: imgui)),
    "the layout \"" & name & "\"", done = "Layout \"" & name & "\" saved in " & path & ".")
  state.layoutList = state.layoutList.added(SavedLayout(name: name, path: path))

proc keepLayoutsIn*(state: var AppState; dir: string; presetDirs: openArray[string]) =
  ## From now on, saves the arrangement in `dir`'s `LayoutFileName` (a
  ## moment after it changes, and at `shutdown`) and named layouts in its
  ## `layouts/`; lists those and the presets in `presetDirs`' `layouts/`.
  assertUiThread()
  if state.configDir.len == 0: state.configDir = dir
  state.layoutList = listLayouts(dir, presetDirs)
  discard state.diskIo

func layouts*(state: AppState): lent seq[SavedLayout] {.inline.} =
  ## The layouts that can be loaded: the user's, then the presets.
  state.layoutList

func loadedLayout*(state: AppState): lent Layout {.inline.} =
  ## The layout loaded last (`ckLoadLayout`, `ckImportLayout`): the
  ## frontend arranges its windows so when `layoutLoads` goes up.
  state.loaded

func layoutLoads*(state: AppState): int {.inline.} =
  ## Bumped each time a layout is loaded.
  state.loads

func arrangement*(state: AppState): lent string {.inline.} =
  ## How the windows are arranged, as the frontend last said (`ckLayout`).
  state.arrangement

func settingsRevision*(state: AppState): int {.inline.} =
  ## Bumped on every change of the settings.
  state.settingsRev

proc saveSettings(state: var AppState) =
  let file = state.settingsFile
  if file.len > 0:
    state.disk.replace(file, settingsDocument(state.settings), "the settings")
  state.savedRev = state.settingsRev

proc saveArrangement(state: var AppState) =
  if state.configDir.len > 0 and state.arrangement.len > 0:
    state.disk.replace(state.configDir / LayoutFileName,
      layoutDocument(Layout(imgui: state.arrangement)), "the window layout")
  state.layoutSaved = state.layoutRev

proc persist*(state: var AppState; now = getMonoTime()) =
  ## Hands what is due to the disk thread: what was logged since the last
  ## call, and the settings and the arrangement once `SaveDelay` has passed
  ## since they last changed. Call it once per frame, after the frame's
  ## commands; it never waits.
  assertUiThread()
  state.writeLog()
  if state.savedRev != state.settingsRev and now - state.changedAt >= SaveDelay:
    state.saveSettings()
  if state.layoutSaved != state.layoutRev and now - state.layoutAt >= SaveDelay:
    state.saveArrangement()

proc flushFiles*(state: var AppState) =
  ## Saves what is due now, without waiting for `SaveDelay`, and waits
  ## until the disk thread has written everything handed to it (tests).
  assertUiThread()
  state.writeLog()
  if state.savedRev != state.settingsRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.disk.flush()

proc shutdown*(state: var AppState) =
  ## Stops the panels' readers, cancels every job and waits for the running
  ## ones to stop, then writes what is left to the session log. Destroying
  ## the state does this too.
  assertUiThread()
  for r in state.readers:
    r.stop()
  state.watch.stop()
  state.jobs.stop()
  if state.savedRev != state.settingsRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.writeLog()
  state.disk.stop()

# --------------------------------------------------------------- reading --

func log*(state: AppState): lent MessageLog {.inline.} =
  ## The message log.
  state.log

func selection*(state: AppState): lent Selection {.inline.} =
  ## The trace under the cursor, the selected traces, the gather on show.
  state.selection

func hoverNote*(state: AppState): lent string {.inline.} =
  ## Why the hover lights nothing up in the other view, in plain words, for
  ## the status bar: a trace with no place on the map, a point no trace of
  ## the open files was recorded at, a point whose traces are in other
  ## records. "" when the hover lights up what it should, or there is none.
  state.hoverNote

func tilesTaken*(state: AppState): int {.inline.} =
  ## How many tiles the panels have taken in since the start: each is a read
  ## (for tests: a hover reads nothing).
  int(state.nextTile) - 1

func panels*(state: AppState): lent seq[Panel] {.inline.} =
  ## The trace panels, `MainPanel` first.
  state.panels

func sessions*(state: AppState): lent seq[Session] {.inline.} =
  ## The open files, in the order they were opened.
  state.sessions

func jobs*(state: AppState): lent Jobs {.inline.} =
  ## The jobs, for the Jobs window and the status bar (`list`, `info`).
  state.jobs

func fileList*(state: AppState): lent FileList {.inline.} =
  ## The file list: the files of the folder (or the files) listed last, and
  ## the one the main panel shows.
  state.files

func survey*(state: AppState): lent Survey {.inline.} =
  ## The survey: the survey files loaded and the open files' positions.
  state.survey

func map*(state: AppState): lent MapState {.inline.} =
  ## The map's view, the views before it and its hidden layers.
  state.map

func surveyLoading*(state: AppState; path: string): bool =
  ## Whether survey file `path` (canonical) is being loaded, or opened by a
  ## job that may find it one.
  state.loading.anyIt(it.session == NoSession and it.path == path) or
    state.opening.anyIt(it.path == path and not it.unwanted)

func shownFile*(state: AppState; panelIndex: int): int =
  ## The index in `sessions` of the file `panels[panelIndex]` shows; -1 for
  ## none.
  template p: untyped = state.panels[panelIndex]
  result = -1
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    for i, s in state.sessions:
      if s.id == p.layers[0].source.file: return i

func notices*(state: AppState): lent seq[Notice] {.inline.} =
  ## The newest notices, oldest first: what background jobs had to say
  ## when they ended. Each has its own `serial`.
  state.notices

func indexCache*(state: AppState): lent string {.inline.} =
  ## The folder of parseSEG's index caches; "" for none.
  state.indexCache

func settings*(state: AppState): lent Settings {.inline.} =
  ## The user's settings (`core/settings`).
  state.settings

func defaultSettings*(state: AppState): lent Settings {.inline.} =
  ## What a reset of the settings goes back to.
  state.defaults

func tiles*(state: AppState; panelIndex: int): lent seq[Tile] {.inline.} =
  ## The tiles kept for `panels[panelIndex]`, oldest first: draw them in
  ## that order. Each has its own `id`, never reused.
  state.tiles[panelIndex]

func sorting*(state: AppState; panelIndex: int): bool =
  ## Whether `panels[panelIndex]`'s traces were given a new order since it
  ## was shown and no tile in that order has come yet: the plot still shows
  ## the old order.
  template p: untyped = state.panels[panelIndex]
  template t: untyped = state.tiles[panelIndex]
  p.orderGen > p.sourceGen and (t.len == 0 or t[^1].request.gen < p.orderGen)

func findPanel*(state: AppState; id: PanelId): int =
  ## The index of panel `id` in `panels`; -1 when there is none.
  for i, p in state.panels:
    if p.id == id: return i
  -1

func windowTitle*(state: AppState; id: PanelId): string =
  ## The title of panel `id`'s window: what it shows, numbered from the
  ## second of a kind on ("Seismic", "Seismic 2", "Aux"; `panels`).
  let k = state.findPanel(id)
  if k < 0: "Seismic" else: windowTitle(state.panels, k)

proc watchLook*(state: AppState): Duration =
  ## How long the folder's watch took for its last look (it runs on its own
  ## thread); zero before the first.
  state.watch.lookTime

func reopening*(state: AppState; panel: PanelId): tuple[path: string; waiting: bool] =
  ## The file `panel` lets go of because another program changed it, and
  ## shows again: `waiting` until the file stops changing, then while it
  ## opens. ("", false) for none.
  for r in state.reopens:
    if r.panel == panel: return (r.path, true)
  let k = state.findPanel(panel)
  if k >= 0 and state.shownFile(k) < 0 and state.panels[k].layers.len > 0 and
      state.panels[k].layers[0].source.kind == lsRecord:
    for o in state.opening:
      if o.panel == panel and not o.unwanted: return (o.path, false)
  ("", false)

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

func traceEdits*(state: AppState; trace: int): set[TraceEdit] =
  ## The edits of survey-wide trace `trace` now; none for a trace no open
  ## file has.
  let i = state.findTrace(trace)
  if i >= 0 and state.sessions[i].path in state.edits:
    result = state.edits[state.sessions[i].path].editsOf(trace - state.sessions[i].base)

func editsOf*(state: AppState; panelIndex: int): lent FileEdits =
  ## The edits of the file `panels[panelIndex]` shows; none when it shows
  ## none or the file has none. Not a copy: the screen asks every frame, so
  ## pass it on rather than keep it in a `let`, which copies.
  # Not an `if` expression: Nim 2.4.2 copies its branch into a temporary
  # and returns a view of that, freed on return.
  let i = state.shownFile(panelIndex)
  if i >= 0 and state.sessions[i].path in state.edits:
    return state.edits[state.sessions[i].path]
  state.noEdits

func shownTraces(state: AppState; panelIndex: int): (int, Slice[int]) =
  ## The index in `sessions` of the file `panels[panelIndex]` shows, and the
  ## traces of the gather it shows; -1 for none.
  result = (-1, 0 .. -1)
  let i = state.shownFile(panelIndex)
  if i >= 0:
    let g = state.panels[panelIndex].layers[0].source.gather
    if g in 0 ..< state.sessions[i].gathers.len:
      result = (i, state.sessions[i].gathers[g].traces)

func gatherEdited*(state: AppState; panelIndex: int): bool =
  ## Whether a trace of the gather `panels[panelIndex]` shows has an edit:
  ## then the display header has a row for them.
  let (i, traces) = state.shownTraces(panelIndex)
  i >= 0 and state.sessions[i].path in state.edits and
    state.edits[state.sessions[i].path].anyIn(traces)

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

proc logProblems(state: var AppState; source: string; problems: openArray[string]) =
  ## Logs `problems` as warnings, the first `MaxProblemLines` one by one and
  ## a count of the rest (`addProblems`).
  var notes: seq[Note]
  notes.addProblems(problems)
  for (severity, text) in notes: state.log.add(severity, source, text)

proc seismicAt(state: AppState; path: string): bool =
  ## Whether `path` names a seismic file the program has open, is opening or
  ## closing, or lists: what it writes of its own never goes over one
  ## (Working rules: a loaded file is never changed).
  let p = canonical(path)
  state.sessions.anyIt(it.path == p) or state.opening.anyIt(it.path == p) or
    state.closing.anyIt(it.path == p) or state.files.find(p) >= 0 or
    state.survey.findFile(p) >= 0

proc refusedExport(state: var AppState; cmd: Command): bool =
  ## Says why `cmd` (an export) writes nothing, when it may not: no file
  ## named, or a seismic file named.
  result = true
  if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
  elif state.seismicAt(cmd.docPath):
    state.ignore(cmd, cmd.docPath & " is a seismic file viewSEG has open or lists, and " &
      "viewSEG never writes over one; choose another name")
  else: result = false

proc change(state: var AppState; s: sink Settings) =
  ## Makes `s` the settings, noting a change when it is one (as saved:
  ## a value that is not a number equals itself).
  if settingsDocument(s) != settingsDocument(state.settings):
    state.settings = s
    inc state.settingsRev
    state.changedAt = getMonoTime()

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
  # The next gather or file is shown at the same scales (`carried`); a panel
  # that showed nothing yet, or shows nothing now, fits the new one.
  if p.layers.len == 0:
    p.carry = Viewport()
  elif p.laidOut and p.layout.traces > 0 and p.view.traces.width > 0:
    p.carry = p.view
    p.carryLayout = p.layout
  inc p.requestGen
  p.sourceGen = p.requestGen
  p.layout = PanelLayout()
  p.shown.setLen 0
  p.known = {}
  p.kind = gkUnknown
  p.pending = ReadRequest()
  p.level = Level()
  p.viewLevel = Level()
  p.relevel = false
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
        src = ReaderSource(gen: p.sourceGen, file: s.filePtr, path: s.path, size: s.size,
          traces: s.gathers[g].traces, filter: p.layers[0].filter, order: p.layers[0].order)
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
  if state.panels[k].layers.len == 0: # a new plot: as the user last had one
    var layer = recordLayer(file, gather)
    layer.display = state.settings.plot.display
    layer.order = state.settings.plot.order
    state.panels[k].layers.add layer
    state.panels[k].header = state.settings.plot.header
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
  let wiggles = p.layers[0].display.drawsWiggles
  if p.pending.gen == p.requestGen:
    # Enough on hand on every side: nothing to ask. The view itself on hand,
    # or on its way: the read-ahead is filled again once the request sent is
    # answered, so a key held down does not start a read every few frames
    # and finish none.
    if p.pending.covers(p.layout, p.view, margin, wiggles, keep = KeepAhead): return
    if p.pending.covers(p.layout, p.view, margin, wiggles) and
        not state.tiles[k].anyIt(it.request.gen == p.pending.gen):
      return
  var req = requestFor(p.layout, p.view, margin, wiggles = wiggles)
  if req.isEmpty: return
  inc p.requestGen
  req.gen = p.requestGen
  p.pending = req
  var reversed, killed: seq[int]
  let (i, traces) = state.shownTraces(k)
  if i >= 0 and state.sessions[i].path in state.edits:
    template e: untyped = state.edits[state.sessions[i].path]
    reversed = e.listIn(teReversed, traces)
    killed = e.listIn(teKilled, traces)
  state.readers[k].request ReaderRequest(read: req, fields: p.shownFields, flow: flow,
    clipPercentile: p.layers[0].display.clipPercentile, reversed: reversed, killed: killed,
    raw: rfRawAmplitude in state.settings.readout)

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
    p.level = Level()
    p.viewLevel = Level()
  inc p.revision
  state.requestView(k)

proc resample(state: var AppState; k: int; relevel = false) =
  ## Asks again for `panels[k]`'s view: what its samples hold has changed
  ## (the polarity, an edit). The tiles from before are drawn until the
  ## first one after the change comes (`drainInbox`), so the plot never goes
  ## blank; with `relevel`, that tile sets the panel's level again.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.samplesGen = p.requestGen
  if relevel: p.relevel = true
  p.pending = ReadRequest()
  inc p.revision
  state.requestView(k)

proc reorder(state: var AppState; k: int) =
  ## Tells `panels[k]`'s reader its layer 0's new order and asks again for
  ## the view, which stays as it is. The tiles in the old order are drawn
  ## until the first one in the new order comes (`drainInbox`), so the plot
  ## never goes blank; each tile names its own traces, so what the pick and
  ## the display header say always matches what is drawn.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.orderGen = p.requestGen
  p.shown.setLen 0
  p.pending = ReadRequest()
  inc p.revision
  if not state.readers[k].isNil:
    state.readers[k].sortBy(p.orderGen, p.layers[0].order)
  state.requestView(k)

func usable(x: float64): bool {.inline.} = x > 0 and x < Inf

proc settleGain(state: var AppState; k: int) =
  ## After a change of display, view or tiles of `panels[k]`: Fixed takes
  ## its amplitude from the data shown when it has none yet (and the
  ## settings keep it, for new plots and the next run), and Float
  ## takes its level from the data now in view (keeping the one before
  ## when no tile holds any of it yet).
  template p: untyped = state.panels[k]
  if p.layers.len == 0: return
  template d: untyped = state.panels[k].layers[0].display
  case d.effectiveGain(p.kind)
  of dgFixed:
    if not usable(d.fixedClip) and usable(p.level.clip):
      d.fixedClip = p.level.clip
      inc p.revision
      # kept for the next run too, as a typed amplitude is
      var s = state.settings
      s.plot.display = remembered(d)
      state.change s
  of dgFloat:
    var values: seq[float32]
    for i in countdown(state.tiles[k].high, 0): # the newest tile that meets the view
      if values.len == 0:
        state.tiles[k][i].valuesInView(p.view, FloatValues, values)
    if values.len > 0:
      let level = levelOf(values, d.clipPercentile, state.scratch)
      if usable(level.clip):
        p.viewLevel = level
        inc p.revision
  else: discard

proc choose(state: var AppState; path: string) =
  ## Marks `path` as the file the main panel shows (or is opening).
  if state.files.chosen != path:
    state.files.chosen = path
    inc state.files.revision

proc chooseShown(state: var AppState) =
  ## Marks the file the main panel shows as chosen again (an open for it
  ## failed or was cancelled).
  let i = state.shownFile(state.findPanel(MainPanel))
  state.choose(if i >= 0: state.sessions[i].path else: "")

proc watchOpen(state: var AppState) =
  ## Tells the folder's watch which files are open now, or are to be shown
  ## again once they stop changing.
  var paths: seq[string]
  for s in state.sessions: paths.add s.path
  for r in state.reopens:
    if r.path notin paths: paths.add r.path
  if paths.len > 0 or not state.watch.isNil: state.folderWatch.watchOpen(paths)

proc closeSession(state: var AppState; i: int; quiet = false; keepLayers = false) =
  ## Takes open file `i` out of every view at once, cancels the jobs that use
  ## it, and closes it once none does (after its close job, on this thread);
  ## `quiet` logs nothing when it is closed. With `keepLayers`, the panels
  ## that showed it keep their layers (display, order, view) for the file
  ## to be shown again, opened anew; they show nothing meanwhile.
  var s = move state.sessions[i]
  state.sessions.delete(i)
  for job in state.jobs.list:
    if job.state in {jsQueued, jsRunning} and
        (s.path in job.spec.reads or s.path in job.spec.exclusive):
      discard state.jobs.cancel(job.id)
  state.selection.forget(s.id, s.traceIds)
  let positions = state.survey.findTraces(s.id)
  if positions >= 0: discard state.survey.remove(state.survey.layers[positions].id)
  for k in 0 ..< state.panels.len:
    if keepLayers:
      if state.panels[k].layers.anyIt(it.shows(s.id)): state.newSource(k)
    else:
      let before = state.panels[k].layers.len
      state.panels[k].layers.keepItIf(not it.shows(s.id))
      if state.panels[k].layers.len != before:
        state.newSource(k) # the reader lets go of the file, then the close may run
  # Not cancellable: the file must not be released while a job still reads it.
  let job = state.jobs.submit(JobSpec(title: "Close " & s.name, lane: jlInteractive,
    exclusive: @[s.path], cancellable: false), closeWork())
  if not keepLayers and state.files.chosen == s.path and
      state.shownFile(state.findPanel(MainPanel)) < 0:
    state.choose("")
  state.closing.add Pending(job: job, path: s.path, session: s, quiet: quiet)
  state.watchOpen()

proc failed(state: var AppState; path: string) =
  ## Notes that `path` of the file list could not be shown.
  if path notin state.files.failed:
    state.files.failed.add path
    inc state.files.revision

proc showReplacing(state: var AppState; k: int; file: SessionId; gather: int) =
  ## Shows `gather` of `file` in `panels[k]`, in place of what it showed,
  ## and closes the file it showed when no other panel shows it: stepping
  ## through a folder keeps one file open, not every file seen.
  let shown = state.shownFile(k)
  let old = if shown >= 0: state.sessions[shown].id else: NoSession
  state.show(state.panels[k].id, file, gather)
  if old != NoSession and not (old == file) and
      not state.panels.anyIt(it.layers.anyIt(it.shows(old))):
    state.closeSession(state.findSession(old), quiet = true)

func gatherOf*(s: Session; trace: int): int =
  ## The index of the gather of `s` that holds trace `trace`; -1 for none.
  var (lo, hi) = (0, s.gathers.high)
  while lo <= hi:
    let mid = (lo + hi) div 2
    let g = s.gathers[mid].traces
    if trace < g.a: hi = mid - 1
    elif trace > g.b: lo = mid + 1
    else: return mid
  -1

func fileTrace(s: Session; record, trace: int): int =
  ## The index in the file of trace `trace` of SEG-D record `record` (as
  ## parseSEG's diagnostics count them); `trace` itself for a record below
  ## 1 (SEG-Y, the first record) and when the record is not found.
  result = trace
  if record > 0:
    template e: untyped = s.file.index.entries
    var (lo, hi) = (0, e.len) # the first entry of the record: records are in file order
    while lo < hi:
      let mid = (lo + hi) div 2
      if int(e[mid].record) < record: lo = mid + 1 else: hi = mid
    if lo < e.len and int(e[lo].record) == record: result = lo + trace

proc showTrace(state: var AppState; k: int; i: int; trace: int; record = -1) =
  ## Shows the gather of open file `sessions[i]` that holds `trace` (of
  ## SEG-D record `record`) in `panels[k]`, and selects the trace.
  let s = state.sessions[i]
  let trace = fileTrace(s, record, trace)
  let g = gatherOf(s, trace)
  if g < 0:
    state.log.add(sevWarning, s.name, s.name & " has no trace " & $trace & ".")
  else:
    if state.shownFile(k) != i: state.showReplacing(k, s.id, g)
    elif state.panels[k].layers[0].source.gather != g: state.show(state.panels[k].id, s.id, g)
    state.selection.select([s.base + trace], smReplace)

# ---------------------------------------------------------------- linking --

func keysOf(state: AppState; trace: int): (bool, TraceKeys) =
  ## Survey-wide trace `trace`'s keys as a tile of a panel that shows its
  ## file carries them (a copy); false when no tile holds it.
  result = (false, initTraceKeys())
  let i = state.findTrace(trace)
  if i < 0: return
  let t = trace - state.sessions[i].base
  for k in 0 ..< state.panels.len:
    if state.shownFile(k) == i:
      for j in countdown(state.tiles[k].high, 0):
        template tile: untyped = state.tiles[k][j]
        for row in 0 ..< min(tile.traces.len, tile.keys.len):
          if tile.traces[row] == t: return (true, tile.keys[row])

func pointsOfTrace(state: AppState; trace: int): seq[PointRef] =
  ## Where survey-wide trace `trace` was recorded, in every layer: from its
  ## keys as a tile carries them, so that a loaded relation file fills the
  ## stations they lack (`tracePoints`); else as its file's traces layer has
  ## it. None for -1.
  if trace < 0: return
  let (has, keys) = state.keysOf(trace)
  if has: state.survey.tracePoints(trace, keys) else: state.survey.tracePointsOf(trace)

func stationWords(line, point: float64): string =
  ## "line 100, point 105".
  func num(x: float64): string =
    if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)
  "line " & num(line) & ", point " & num(point)

func noPointNote(state: AppState): string =
  ## Why the source or receiver of the trace under the plot's pointer is not
  ## lit up on the map; "" when both are, or no trace is hovered.
  template sel: untyped = state.selection
  if sel.hover < 0: return ""
  var found: set[PointRole]
  for p in sel.hoverAt: found.incl p.role
  if found == {prSource, prReceiver}: return ""
  let i = state.findTrace(sel.hover)
  if i < 0: return ""
  let s = state.sessions[i]
  let name = "Trace " & $(sel.hover - s.base + 1)
  var (has, k) = state.keysOf(sel.hover)
  let seismic = if has: k.isSeismic else: s.file.index.isSeismic(sel.hover - s.base)
  if not seismic: return name & " is an auxiliary trace: it has no place on the map."
  let own = state.survey.findTraces(s.id)
  if own < 0:
    return name & " is not on the map yet: the positions of " & s.name & " are being read."
  var surveyFiles, relations = false
  for j in 0 ..< state.survey.layers.len: # by index: `for l in` copies every layer
    template l: untyped = state.survey.layers[j]
    if l.origin == loSurveyFile:
      surveyFiles = true
      if l.relationRuns > 0:
        relations = true
        if has: discard joinStations(k, l.relations[])
  var stations: array[PointRole, Station]
  for r in PointRole:
    stations[r] = if not has: state.survey.layers[own].stationOf(r, sel.hover - s.base)
                  elif r == prSource: Station(line: k.srcLine, point: k.srcPoint, index: k.srcIndex)
                  else: Station(line: k.rcvLine, point: k.rcvPoint, index: k.rcvIndex)
  let missing = {prSource, prReceiver} - found
  let unplaced = if relations: ", and the loaded relation file does not name its record " &
                   "and channel" else: ""
  proc reason(r: PointRole): string =
    let st = stations[r]
    if not st.known: "its header gives neither " & $r & " coordinates nor a " & $r & " station" &
      unplaced
    elif surveyFiles: "no loaded survey file has its " & $r & " station (" &
      stationWords(st.line, st.point) & ")"
    else: "its header gives no " & $r & " coordinates; load the survey's SPS or SEG P1 files " &
      "to place it by its station (" & stationWords(st.line, st.point) & ")"
  if missing.card == 2:
    let (a, b) = (stations[prSource], stations[prReceiver])
    let why = if not (a.known or b.known): "its headers give neither coordinates nor stations" &
                unplaced
              elif a.known and b.known and surveyFiles: "no loaded survey file has its stations " &
                "(source " & stationWords(a.line, a.point) & "; receiver " &
                stationWords(b.line, b.point) & ")"
              elif a.known and b.known: "its headers give no coordinates; load the survey's SPS " &
                "or SEG P1 files to place it by its stations"
              else: reason(prSource) & "; " & reason(prReceiver)
    result = name & " is not on the map: " & why & "."
  else:
    for r in missing:
      result = name & "'s " & $r & " is not on the map: " & reason(r) & "."

func noTraceNote(state: AppState): string =
  ## Why no trace lights up in the plot for the points under the map's
  ## pointer: none of the open files' traces was recorded there, or those
  ## that were are in other records; "" when the plot shows one, or no point
  ## is hovered.
  template sel: untyped = state.selection
  if sel.hoverPoints.len == 0: return ""
  let role = $sel.hoverPoints[0].role
  if sel.hoverTraces.len > 0:
    let (i, traces) = state.shownTraces(state.findPanel(MainPanel))
    if i < 0: return ""
    let base = state.sessions[i].base
    for t in sel.hoverTraces:
      if t - base in traces: return ""
    var records: seq[string]
    var seen: IntSet
    var looked = 0
    for t in sel.hoverTraces:
      if looked < 200 and records.len < 4:
        inc looked
        let j = state.findTrace(t)
        if j >= 0:
          let s = state.sessions[j]
          let g = s.gatherOf(t - s.base)
          if g >= 0 and j * 1_000_000_000 + g notin seen:
            seen.incl j * 1_000_000_000 + g
            let f = s.records[g].record
            records.add (if abs(f) < 1e15: "FFID " & $int64(f) else: "record " & $(g + 1))
    let named = if records.len > 3: records[0 .. 2].join(", ") & ", ..." else: records.join(", ")
    return plural(sel.hoverTraces.len, "trace") & " recorded at this " & role &
      ", none in the record shown" & (if named.len > 0: " (" & named & ")" else: "") & "."
  if state.sessions.len == 0: return "No trace here: no seismic file is open."
  if state.loading.anyIt(it.session != NoSession):
    return "No trace here yet: the open files' positions are being read."
  var stations = false
  for j in 0 ..< state.survey.layers.len:
    template l: untyped = state.survey.layers[j]
    if l.origin == loTraces and l.stationCount(sel.hoverPoints[0].role) > 0: stations = true
  if stations: "No trace of the open files was recorded at this " & role & "."
  else: "No trace is matched to this " & role & ": the open files' headers give no " & role &
    " stations."

proc relink(state: var AppState) =
  ## After every change: the hover's links found again once the survey has
  ## changed (a layer came or went: a survey file, an open file's
  ## positions), and the note on them made again when what it says of may
  ## have changed (the hover, the record shown, the survey).
  template sel: untyped = state.selection
  let now: Linked = (state.survey.revision, sel.revision, state.loading.len, sel.activeGather)
  if now == state.linked: return
  if state.survey.revision != state.linked.survey:
    sel.setHoverAt(state.pointsOfTrace(sel.hover))
    var points: seq[PointRef]
    var traces: IntSet
    for p in sel.hoverPoints:
      if state.survey.find(p.layer) >= 0:
        points.add p
        for t in state.survey.tracesAt(p): traces.incl t
    sel.setHoverPoints(points, traces)
  state.hoverNote = if sel.hover >= 0: state.noPointNote() else: state.noTraceNote()
  state.linked = (state.survey.revision, sel.revision, state.loading.len, sel.activeGather)

proc showPoints(state: var AppState; cmd: Command) =
  ## `ckShowPoints`: the main panel shows the record of the traces recorded
  ## at `cmd.points` (a source's shot record), in the file it shows when it
  ## has some, else in the file that has the first; nothing changes when it
  ## shows one of them already.
  let k = state.findPanel(MainPanel)
  var traces: seq[int]
  for p in cmd.points: traces.add state.survey.tracesAt(p)
  if traces.len == 0:
    state.ignore(cmd, "no trace of the open files was recorded there")
    return
  let (shown, gather) = state.shownTraces(k)
  var pick = -1
  for t in traces:
    if shown >= 0 and t in state.sessions[shown]:
      if t - state.sessions[shown].base in gather: return # on show already
      if pick < 0 or t < pick: pick = t
  if pick < 0:
    pick = traces[0]
    for t in traces: pick = min(pick, t)
  let i = state.findTrace(pick)
  if i < 0: return
  let s = state.sessions[i]
  let g = s.gatherOf(pick - s.base)
  if g < 0: return
  if state.shownFile(k) != i: state.showReplacing(k, s.id, g)
  else: state.show(MainPanel, s.id, g)

proc mark(state: var AppState; path: string; short, seen: bool) =
  ## Marks the file list's entry of `path`: with `short`, as ending before
  ## its last trace (when the watch finds it steady); with `seen`, as not new.
  let i = state.files.find(path)
  if i >= 0:
    template e: untyped = state.files.entries[i]
    let was = (e.status, e.isNew)
    if short and e.status == fsSteady: e.status = fsShort
    if seen: e.isNew = false
    if (e.status, e.isNew) != was: state.files.changedAt(i)

proc checkEdits(state: var AppState; s: Session) =
  ## Sets the edits of `s`'s path aside (as "Clear all edits" does, so Ctrl+Z
  ## brings them back) when they were made on the file as it was before
  ## another program changed it: by the trace's index, they may not fit.
  if s.path notin state.edits or state.edits[s.path].isEmpty: return
  let now = (size: s.size, modified: s.modified)
  let was = state.editStamps.getOrDefault(s.path, now)
  state.editStamps[s.path] = now
  if was != now and state.edits[s.path].clearAll():
    state.log.add(sevWarning, s.name, s.name & " changed on disk after its traces were " &
      "edited, so its kills and polarity reversals are set aside: by trace number they may " &
      "not fit the traces it holds now. Ctrl+Z (with the plot focused) brings them back.")

proc readPositions(state: var AppState; s: Session) =
  ## Reads the source and receiver positions of open file `s` on a job: its
  ## layer of the survey.
  let job = state.jobs.submit(JobSpec(title: "Read the positions in " & s.name,
    lane: jlInteractive, reads: @[s.path]), positionsWork(s.filePtr, s.path,
    fileKind(s.file.kind), s.id, s.base, state.inbox.poster))
  state.loading.add Loading(job: job, path: s.path, session: s.id)

func relationLayer(state: AppState): int =
  ## The first loaded survey file with relations (X records): what the
  ## records of the open files are checked against; -1 for none.
  for i in 0 ..< state.survey.layers.len: # indexed: a loop over the layers copies them
    template l: untyped = state.survey.layers[i]
    if l.origin == loSurveyFile and l.xRuns > 0: return i
  -1

proc checkRecords(state: var AppState; s: Session) =
  ## Checks the records of open file `s` against the loaded relation file
  ## on a job (the Records window's planned and missing stations), or
  ## clears the check when none is loaded.
  let r = state.relationLayer
  if r < 0:
    s.setChecks("", [], [])
    return
  template l: untyped = state.survey.layers[r]
  var gathers = newSeq[Slice[int]](s.gathers.len)
  for i, g in s.gathers: gathers[i] = g.traces
  # The job reads the layer's relations where they are (a copy of a large X
  # file's took a frame per file opened); they are kept until it ends, also
  # when the layer is unloaded meanwhile.
  let job = state.jobs.submit(JobSpec(title: "Check the records of " & s.name & " against " &
    l.name, lane: jlBackground, reads: @[s.path]), checkWork(s.filePtr, s.id, gathers,
    addr l.relations[], l.name, l.id, state.inbox.poster))
  state.checking.add (job, l.relations)

proc takeChecked(state: var AppState; m: sink Msg) =
  ## An open file's records checked against a relation file that is still
  ## the one loaded, with the file's keys as they were.
  let i = state.findSession(m.checkedSession)
  let r = state.relationLayer
  if i >= 0 and r >= 0 and state.survey.layers[r].id == m.againstLayer and
      state.sessions[i].file.keysRevision == m.keysRevision:
    state.sessions[i].setChecks(m.against, m.planned, m.plannedMissing)

proc loadSurvey(state: var AppState; path: string; quiet = false) =
  ## Loads survey file `path` (canonical) on a job, unless it is being
  ## loaded already, or is loaded as the file list says it is now; `quiet`
  ## says nothing then.
  let name = path.extractFilename
  let i = state.survey.findFile(path)
  let e = state.files.find(path)
  if state.surveyLoading(path):
    if not quiet: state.log.add(sevInfo, name, name & " is already being loaded.")
  elif i >= 0 and e >= 0 and state.files.entries[e].size == state.survey.layers[i].size and
      state.files.entries[e].modified == state.survey.layers[i].modified:
    if not quiet: state.log.add(sevInfo, name, name & " is loaded already, as it is now.")
  else:
    let job = state.jobs.submit(JobSpec(title: "Load " & name, lane: jlInteractive,
      reads: @[path]), surveyWork(path, state.inbox.poster))
    state.loading.add Loading(job: job, path: path)

proc takeSurvey(state: var AppState; layer: sink SurveyLayer; job: JobId) =
  ## A layer a job made: an open file's positions, kept while the file is
  ## open and its keys are as they were read; or a survey file, in place of
  ## its layer from before.
  for i, x in state.loading:
    if x.job == job:
      state.loading.delete(i)
      break
  let (name, path) = (layer.name, layer.path)
  let problems = layer.problems
  case layer.origin
  of loTraces:
    let i = state.findSession(layer.session)
    if i < 0 or state.sessions[i].file.keysRevision != layer.keysRevision: return
    let placed = layer.points[prSource].len + layer.points[prReceiver].len
    let stations = layer.stationCount(prSource) + layer.stationCount(prReceiver)
    discard state.survey.add(layer)
    if placed == 0:
      # Field records often carry stations only: said once a folder, and not
      # once survey files are loaded.
      let folder = "no coordinates: " & path.parentDir
      var surveyFiles = false # by index: `anyIt` would copy every layer
      for i in 0 ..< state.survey.layers.len:
        if state.survey.layers[i].origin == loSurveyFile: surveyFiles = true
      if folder notin state.saidPositions and not surveyFiles:
        state.saidPositions.incl folder
        state.log.add(sevInfo, name, name & " carries no source or receiver coordinates" &
          (if stations > 0: " (its traces name their stations): load its survey files " &
            "(SPS, P1) to place it on the map." else: "."))
    elif problems.len > 0 and path notin state.saidPositions:
      state.saidPositions.incl path
      state.log.add(sevInfo, name, name & ": " & problems.join("; ") & ". They are left " &
        "off the map.")
  of loSurveyFile:
    for i, p in state.opening:
      if p.job == job: # an open that found a survey file: no file to show
        let panel = p.panel
        state.opening.delete(i)
        if panel in [NoPanel, MainPanel]: state.chooseShown()
        break
    let failed = state.files.failed.find(path)
    if failed >= 0:
      state.files.failed.delete(failed)
      inc state.files.revision
    let again = state.survey.findFile(path) >= 0
    let text = "Loaded " & name & " (" & $layer.kind & ")" & (if again: " again" else: "") &
      ": " & layer.summary & "." & (if problems.len > 0: " " & problems.join("; ") & "." else: "")
    var lost = 0
    for c in layer.counts: lost += c.missing + c.zero + c.moved
    let before = state.relationLayer
    let wasId = if before >= 0: state.survey.layers[before].id else: NoSurveyLayer
    discard state.survey.add(layer)
    state.log.add(if lost > 0: sevWarning else: sevInfo, name, text)
    let now = state.relationLayer
    if now >= 0 and state.survey.layers[now].id != wasId:
      for s in state.sessions: state.checkRecords(s) # against the relation file now loaded

proc adopt(state: var AppState; s: sink Session; job: JobId) =
  ## Takes in a file an open job opened, and shows its first gather (or the
  ## gather the open asks for) in the panel the open was for (the main panel
  ## unless `ckShowFile` named another); drops it when no longer wanted, and
  ## when "Follow the latest" opened it and it is not whole yet.
  var panel = MainPanel
  var replacing = false # `ckShowFile`: in place of the file the panel shows
  var gather = 0
  var follow = false
  for p in state.opening:
    if p.job == job:
      if p.unwanted: return # another file was chosen meanwhile: closed here
      if p.panel != NoPanel: (panel, replacing) = (p.panel, true)
      (gather, follow) = (p.gather, p.follow)
  if follow and s.file.kind != skUnknown and s.file.cutShort:
    # Not shown early: it ends before its last trace. Shown when it changes and is whole.
    state.mark(s.path, short = true, seen = false)
    state.log.add(sevInfo, s.name, s.name & " is not shown yet: it ends before its last " &
      "trace, so it is still being written (or was cut short). It is shown once it has " &
      "changed and is whole; click it in Files to see it as it is.")
    if panel == MainPanel: state.chooseShown()
    return # `s` is closed here, on the UI thread: nothing else has it
  if s.file.kind == skUnknown:
    state.log.add(s.file.log, s.name)
    state.log.add(sevError, s.name, s.name & " is not a SEG-Y, SEG-D or SEG-2 file, " &
      "so it was not opened.")
    if panel == MainPanel:
      state.failed(s.path)
      state.chooseShown()
    return # `s` is closed here, on the UI thread: nothing else has it
  let id = SessionId(state.nextFile)
  inc state.nextFile
  s.register(id, state.nextBase)
  state.nextBase += s.len
  state.log.add(s.file.log, s.name)
  state.log.add(sevInfo, "open", "Opened " & s.name & ": " & plural(s.len, "trace") &
    " in " & plural(s.gathers.len, "gather") &
    (if s.file.fromCache: " (index from the cache)." else: "."))
  gather = if s.gathers.len == 0: -1 else: clamp(gather, 0, s.gathers.high)
  var st = state.settings
  st.recentFiles.addRecent(s.path, MaxRecent)
  st.recentFolders.addRecent(s.path.parentDir, MaxRecent)
  state.change st
  state.checkEdits(s)
  let path = s.path
  let short = s.file.cutShort
  state.onDiskSaid.del path
  state.sessions.add s
  state.readPositions(state.sessions[^1])
  if state.relationLayer >= 0: state.checkRecords(state.sessions[^1])
  state.watchOpen()
  let k = state.findPanel(panel)
  if replacing and k >= 0: state.showReplacing(k, id, gather)
  else: state.show(MainPanel, id, gather)
  if panel == MainPanel:
    state.choose(path)
    state.mark(path, short, seen = true)
  if state.jump.path == path and k >= 0: # a message's trace, asked for before the file opened
    state.showTrace(k, state.sessions.high, state.jump.trace, state.jump.record)
    state.jump = ("", -1, -1)

proc endOpening(state: var AppState; i: int; how: JobState; error = "") =
  ## Says how open job `opening[i]` ended, and forgets it. An open no longer
  ## wanted ends quietly.
  let o = state.opening[i]
  let p = o.path
  let name = p.extractFilename
  state.opening.delete(i)
  if o.unwanted: return
  case how
  of jsFailed: state.log.add(sevError, name, "Cannot open " & p & ": " & error)
  of jsCancelled: state.log.add(sevInfo, name, "Opening " & name & " was cancelled.")
  else: discard # done: `adopt` took the file
  if how in {jsFailed, jsCancelled} and o.panel == MainPanel:
    if how == jsFailed: state.failed(p)
    state.chooseShown()

proc notify(state: var AppState; severity: Severity; text: string) =
  ## A brief notice for the frontend to show: a background job ended.
  state.notices.add Notice(severity: severity, text: text, serial: state.nextNotice)
  inc state.nextNotice
  if state.notices.len > MaxNotices: state.notices.delete(0)

proc onFinished(state: var AppState; job: JobInfo) =
  ## Says how a job ended, and lets go of what the state kept for it.
  state.checking.keepItIf(it.job != job.id) # the relations a check read
  for i in 0 ..< state.loading.len:
    if state.loading[i].job == job.id: # (one that posted its layer was let go of then)
      let x = state.loading[i]
      state.loading.delete(i)
      let name = x.path.extractFilename
      if x.session == NoSession:
        case job.state
        of jsFailed:
          state.log.add(sevError, name, "Cannot load " & x.path & ": " & job.error & ".")
          state.failed(x.path)
        of jsCancelled: state.log.add(sevInfo, name, "Loading " & name & " was cancelled.")
        else: discard
      elif job.state == jsFailed:
        state.log.add(sevWarning, name, "Cannot read the positions in " & name & ": " &
          job.error & ".")
      return
  for i, p in state.opening:
    if p.job == job.id:
      state.endOpening(i, job.state, job.error)
      return
  for i, p in state.closing:
    if p.job == job.id:
      let name = p.path.extractFilename
      if job.state == jsDone and not p.quiet: state.log.add(sevInfo, name, "Closed " & name & ".")
      state.closing.delete(i) # the file is closed here, on the UI thread
      return
  let old = state.oldScans.find(job.id)
  if old >= 0: # replaced by a newer listing: nothing to say
    state.oldScans.delete(old)
    return
  if job.id == state.files.job:
    state.files.scanning = false
    state.files.job = NoJob
    case job.state
    of jsFailed:
      state.files.error = job.error
      state.log.add(sevError, "files", "Cannot list " & state.files.title & ": " & job.error &
        ".")
    of jsCancelled: state.files.error = "the listing was stopped before the end"
    else: discard
    inc state.files.revision
    return
  case job.state
  of jsFailed:
    state.log.add(sevError, "jobs", job.spec.title & " failed: " & job.error)
    if job.spec.lane == jlBackground:
      state.notify(sevError, job.spec.title & " failed: " & job.error)
  of jsCancelled: state.log.add(sevInfo, "jobs", job.spec.title & " was cancelled.")
  of jsDone:
    if job.spec.lane == jlBackground:
      state.log.add(sevInfo, "jobs", job.spec.title & " is done.")
      state.notify(sevInfo, job.spec.title & " is done.")
  of jsQueued, jsRunning: discard

proc showPath(state: var AppState; k: int; path: string; gather = 0; follow = false) =
  ## Shows the file at `path` (canonical) in `panels[k]`, in place of the
  ## one it shows: at once when it is open, else once an open job opened it
  ## (at `gather`; with `follow`, only if it is whole). An open started
  ## earlier for this panel and another file is no longer wanted: it is
  ## cancelled, and dropped if it comes all the same; so is the wait to show
  ## a changed file again.
  let panel = state.panels[k].id
  for o in state.opening.mitems:
    if o.panel == panel and o.path != path and not o.unwanted:
      o.unwanted = true
      discard state.jobs.cancel(o.job) # queued: never runs; running: asked to stop
  state.reopens.keepItIf(it.panel != panel or it.path == path)
  if panel == MainPanel: state.choose(path)
  var i = -1
  for j, s in state.sessions:
    if s.path == path: i = j
  if i >= 0:
    if state.shownFile(k) != i: state.showReplacing(k, state.sessions[i].id, 0)
  else:
    var o = -1
    for j, p in state.opening:
      if p.path == path and not p.unwanted: o = j
    if o >= 0:
      state.opening[o].panel = panel
      if not follow: state.opening[o].follow = false # the user's own choice: shown as it is
    else:
      let job = state.jobs.submit(JobSpec(title: "Open " & path.extractFilename,
        lane: jlInteractive, reads: @[path]), openFileWork(path, state.inbox.poster,
        indexCacheFile(state.indexCache, path), whole = follow))
      state.opening.add Pending(job: job, path: path, panel: panel, gather: gather,
        follow: follow)

proc startListing(state: var AppState; paths: seq[string]; title, folder: string) =
  ## Lists the files `paths` (canonical) name in the file list, in place of
  ## what it listed: a scan on the background lane (`scanWork`). The file
  ## chosen stays chosen.
  if state.files.job != NoJob:
    discard state.jobs.cancel(state.files.job)
    state.oldScans.add state.files.job # it ends quietly
  state.watch.unwatch() # until the scan is done
  let gen = state.files.gen + 1
  state.files = FileList(title: title, folder: folder, asked: paths, scanning: true, gen: gen,
    chosen: state.files.chosen, revision: state.files.revision + 1)
  state.files.job = state.jobs.submit(JobSpec(title: "List the files in " &
    (if folder.len > 0: folder.extractFilename else: title), lane: jlBackground),
    scanWork(gen, paths, state.inbox.poster))

proc takeListed(state: var AppState; m: sink Msg) =
  ## What a scan found for the file list; shows the first file found (or the
  ## file named) when asked to.
  if m.listGen != state.files.gen: return # a listing replaced since
  template f: untyped = state.files
  if m.listFolder.len > 0:
    f.folder = m.listFolder
    f.title = m.listFolder
    var st = state.settings
    st.recentFolders.addRecent(m.listFolder, MaxRecent)
    state.change st
  for e in m.listed:
    if e.kind.isSurvey and e.path in state.loadNamed: state.loadSurvey(e.path, quiet = true)
  f.merge(m.listed)
  f.others += m.others
  f.unreadable += m.unreadable
  if m.listDone:
    f.scanning = false
    # Watched from what the scan found: a folder listed, or the files chosen.
    let paths = if f.folder.len > 0: @[f.folder] else: f.asked
    state.folderWatch.watch(f.gen, paths, move m.listLooked)
  inc f.revision
  if state.showFound != NoPanel:
    var target = m.listChosen # (an open job finds it a survey file, if it is one)
    for e in f.entries:
      if target.len == 0 and e.kind.isSeismic: target = e.path
    if target.len > 0 or m.listDone:
      let k = state.findPanel(state.showFound)
      state.showFound = NoPanel
      if k >= 0 and target.len > 0: state.showPath(k, target)

proc followNewest(state: var AppState) =
  ## With "Follow the latest": shows in the main panel the newest file that
  ## appeared since the folder was listed and is steady, unless it was
  ## followed already (each is shown once, so a file the user stepped away
  ## from is not forced back), failed to open, or is older than the file
  ## followed last (new files that came with a newer one are not shown one
  ## after another, back in time, as the looks go on).
  if not state.settings.files.followLatest: return
  template f: untyped = state.files
  var best = -1
  for i, e in f.entries:
    if e.kind.isSeismic and e.isNew and e.status == fsSteady and e.path != f.chosen and
        e.path notin state.followed and e.path notin f.failed and
        e.modified > state.followedUpTo and
        (best < 0 or e.modified >= f.entries[best].modified):
      best = i
  let k = state.findPanel(MainPanel)
  if best >= 0 and k >= 0:
    let path = f.entries[best].path
    state.followed.incl path
    state.followedUpTo = f.entries[best].modified
    state.showPath(k, path, follow = true)

proc showAgain(state: var AppState; path: string) =
  ## Shows `path` again in the panels that wait for it (`reopens`).
  var waiting: seq[Reopen]
  for r in state.reopens:
    if r.path == path: waiting.add r
  state.reopens.keepItIf(it.path != path)
  for r in waiting:
    let k = state.findPanel(r.panel)
    if k >= 0: state.showPath(k, path, r.gather)

proc reopen(state: var AppState; i: int; now: bool) =
  ## Open file `sessions[i]` changed on disk: its panels let it go at once
  ## (keeping their display and view), and show it again, opened anew, now,
  ## or with `now` false once it stops changing.
  let s = state.sessions[i]
  let path = s.path
  for k in 0 ..< state.panels.len:
    template p: untyped = state.panels[k]
    if p.layers.len > 0 and p.layers[0].shows(s.id):
      state.reopens.add Reopen(path: path, panel: p.id, gather: p.layers[0].source.gather)
  state.closeSession(i, quiet = true, keepLayers = true)
  if now: state.showAgain(path)

proc onDisk(state: var AppState; w: WatchedFile) =
  ## What the watch saw of a file that is open, or that a panel waits for:
  ## a file another program changed is opened again once it stops changing,
  ## and one it cut short is let go of at once, so nothing reads past its new
  ## end (which would end the program); a file removed or renamed stays shown
  ## as it was read.
  let name = w.path.extractFilename
  var i = -1
  for j, s in state.sessions:
    if s.path == w.path: i = j
  if i >= 0:
    let s = state.sessions[i]
    if not w.exists:
      if state.onDiskSaid.getOrDefault(w.path) != "gone":
        state.onDiskSaid[w.path] = "gone"
        state.log.add(sevWarning, name, name & " was removed or renamed while it was open: " &
          "it stays shown as it was read.")
    elif w.size != s.size or w.modified != s.modified:
      let cut = w.size < s.size
      if cut:
        state.log.add(sevWarning, name, name & " was cut short by another program while it " &
          "was open (" & $s.size & " bytes, now " & $w.size & "), so it is no longer read: " &
          "reading past its new end would stop viewSEG. It is shown again once it stops " &
          "changing.")
        state.reopen(i, now = not w.changing)
      elif not w.changing:
        state.log.add(sevInfo, name, name & " changed on disk (" & $s.size & " bytes, now " &
          $w.size & "): it is shown again as it is now.")
        state.reopen(i, now = true)
      elif state.onDiskSaid.getOrDefault(w.path) != "changing":
        state.onDiskSaid[w.path] = "changing"
        state.log.add(sevInfo, name, name & " is being changed by another program: it is " &
          "shown again once it stops changing.")
  elif w.exists and not w.changing and state.reopens.anyIt(it.path == w.path):
    state.showAgain(w.path)

proc takeWatched(state: var AppState; m: sink Msg) =
  ## What a look at the folder found: files that appeared (marked new),
  ## changed (marked as being written until they stop), stopped changing or
  ## went; then the open files' changes, and "Follow the latest".
  template f: untyped = state.files
  let listing = m.watchGen != 0 and m.watchGen == f.gen
  if m.problemChanged and listing:
    if m.watchProblem.len > 0:
      state.log.add(sevWarning, "files", "Cannot look at the folder now: " & m.watchProblem &
        ". The list keeps what it had; the folder is looked at again until it can be read.")
    else:
      state.log.add(sevInfo, "files", "The folder " & f.title & " can be looked at again.")
  # Files gone and new are taken out and put in after the look's changes:
  # one by one when they are few, else in one pass (`replaceEntries`), as
  # one by one each moves every entry after it.
  var gone: seq[int]
  var fresh: seq[FileEntry]
  for w in m.watched:
    if listing and w.listed:
      let i = f.find(w.path)
      if not w.exists:
        if i >= 0: gone.add i
        let failed = f.failed.find(w.path)
        if failed >= 0: f.failed.delete(failed)
      elif i < 0:
        if w.kind != fkUnknown:
          fresh.add FileEntry(path: w.path, name: w.path.extractFilename,
            kind: w.kind, size: w.size, modified: w.modified,
            status: (if w.changing: fsWriting else: fsSteady), isNew: true)
      else:
        template e: untyped = f.entries[i]
        let same = e.size == w.size and e.modified == w.modified
        e.size = w.size
        e.modified = w.modified
        if w.changing:
          e.status = fsWriting
          state.followed.excl w.path # a file that changed is followed again once whole
          let failed = f.failed.find(w.path) # and may open now
          if failed >= 0: f.failed.delete(failed)
        elif e.status == fsWriting or not same:
          e.status = fsSteady # (steady and the same: an incomplete file stays marked)
        f.changedAt(i)
    state.onDisk(w)
  if gone.len + fresh.len > ManyChanges:
    f.replaceEntries(gone, move fresh)
  else:
    gone.sort(Descending) # each index as it is before those after it go
    for i in gone: f.removeAt(i)
    for e in fresh.mitems: discard f.insertEntry(move e)
  state.followNewest()

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

proc editTraces(state: var AppState; cmd: Command) =
  ## `ckEdit`, `ckUndoEdit`, `ckClearEdits` on the file `cmd.panel` shows;
  ## the panels that show a gather the change touches make their view's
  ## tiles again.
  let k = state.findPanel(cmd.panel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if k < 0:
    state.ignore(cmd, $cmd.panel & " does not exist")
    return
  if i < 0:
    state.ignore(cmd, $cmd.panel & " shows no file")
    return
  let s = state.sessions[i]
  var changed = LastEdit()
  var said = ""
  case cmd.kind
  of ckEdit:
    var traces: seq[int]
    for t in cmd.edited:
      if t in s: traces.add t - s.base
    if cmd.edited.len == 0: state.ignore(cmd, "no trace was named")
    elif traces.len < cmd.edited.len:
      state.ignore(cmd, plural(cmd.edited.len - traces.len, "trace") & " of " &
        $cmd.edited.len & " are not in " & s.name)
    if traces.len > 0:
      template e: untyped = state.edits.mgetOrPut(s.path, FileEdits())
      if e.change(cmd.edit, traces, cmd.on) > 0:
        changed = e.last
        said = describe(changed).capitalizeAscii & "."
        state.editStamps[s.path] = (s.size, s.modified) # made on the file as it is now
  of ckUndoEdit:
    if s.path in state.edits: changed = state.edits[s.path].undo()
    said = if changed.kind == lkNone: "Nothing to undo."
           else: "Undone: " & describe(changed) & "."
  of ckClearEdits:
    if s.path in state.edits and state.edits[s.path].clearAll():
      changed = state.edits[s.path].last
      said = "All edits cleared: the traces are shown as the file has them (Ctrl+Z " &
        "brings the edits back)."
    else: said = "No edits to clear."
  else: discard
  if said.len > 0: state.log.add(sevInfo, s.name, said)
  if changed.kind == lkNone: return
  for j in 0 ..< state.panels.len:
    let (shown, traces) = state.shownTraces(j)
    if shown == i and changed.changedIn(traces):
      state.resample(j, relevel = changed.touches(teKilled))

# ---------------------------------------------------------------- changes --

proc applyCommand(state: var AppState; cmd: Command)

proc apply*(state: var AppState; cmd: Command) =
  ## Carries out `cmd`. Anything slow it starts runs as a job; `drainInbox`
  ## takes in the result.
  assertUiThread()
  state.applyCommand(cmd)
  state.map.followed(state.survey) # a layer went (a file closed, a survey file unloaded)
  state.relink()

proc applyCommand(state: var AppState; cmd: Command) =
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
      elif state.opening.anyIt(it.path == path and not it.unwanted):
        state.log.add(sevInfo, name, name & " is already being opened.")
      else:
        let job = state.jobs.submit(JobSpec(title: "Open " & name, lane: jlInteractive,
          reads: @[path]), openFileWork(path, state.inbox.poster,
          indexCacheFile(state.indexCache, path)))
        state.opening.add Pending(job: job, path: path)
  of ckBrowse:
    var paths: seq[string]
    for p in cmd.paths:
      if p.len > 0: paths.add canonical(p)
    if paths.len == 0: state.ignore(cmd, "no file or folder was named")
    else:
      # A copy: as an argument beside `paths`, `paths[0]` would be moved.
      let title = if paths.len == 1: paths[0] else: $paths.len & " chosen files"
      state.loadNamed = paths # the survey files among them are loaded once listed
      state.startListing(paths, title, "")
      state.showFound = if cmd.showFirst: MainPanel else: NoPanel
  of ckShowTrace:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif cmd.path.len == 0 or cmd.traceIndex < 0: state.ignore(cmd, "no trace was named")
    else:
      let path = canonical(cmd.path)
      var i = -1
      for j, s in state.sessions:
        if s.path == path: i = j
      if i >= 0:
        state.jump = ("", -1, -1)
        state.showTrace(k, i, cmd.traceIndex, cmd.recordIndex)
      else: # opened first, then shown
        state.jump = (path, cmd.traceIndex, cmd.recordIndex)
        state.showPath(k, path)
  of ckExportLog:
    if not state.refusedExport(cmd):
      # The disk thread makes the lines: 10 000 of them take a tenth of a second.
      var entries = newSeqOfCap[LogEntry](state.log.len)
      for e in state.log: entries.add e
      state.diskIo.replace(cmd.docPath, "", "the exported messages",
        done = "Messages exported to " & cmd.docPath & ".", entries = entries)
  of ckShowFile:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif cmd.path.len == 0: state.ignore(cmd, "no file was named")
    else:
      let path = canonical(cmd.path)
      let e = state.files.find(path)
      if e >= 0 and state.files.entries[e].kind.isSurvey:
        state.loadSurvey(path) # a survey file: into the survey, the plot stays
      else:
        state.jump = ("", -1, -1) # another choice than a message's trace
        if cmd.panel == MainPanel: state.showFound = NoPanel # the user chose
        state.showPath(k, path)
      let folder = path.parentDir
      if cmd.listFolder and state.files.folder != folder:
        state.startListing(@[folder], folder, folder)
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
  of ckFilter:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    elif not (cmd.filter.seismic or cmd.filter.auxiliary):
      state.ignore(cmd, "a plot shows seismic or auxiliary traces, or both")
    elif cmd.filter != state.panels[k].layers[0].filter:
      # The record's traces again, through the new filter, at the same scales.
      state.panels[k].layers[0].filter = cmd.filter
      state.newSource(k)
  of ckView:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    else:
      # Never a view past the data, whoever asks (the frontend keeps its
      # own views inside already).
      var v = cmd.view
      if state.panels[k].layout.traces > 0:
        v = kept(v, state.panels[k].viewLimits(v.columns))
      if v != state.panels[k].view:
        if cmd.remember: state.remember(k)
        state.panels[k].view = v
        state.requestView(k)
        state.settleGain(k)
  of ckBack:
    # Nothing to go back to is not a mistake: the control is only disabled.
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].back.len > 0:
      template p: untyped = state.panels[k]
      var v = p.back.pop()
      v.columns = p.view.columns # the plot's size is its own
      v.rows = p.view.rows
      p.view = kept(v, p.viewLimits(v.columns)) # the limits of the mode drawn now
      inc p.jumps
      inc p.revision
      state.requestView(k)
      state.settleGain(k)
  of ckSettings:
    let (s, dropped) = cleaned(cmd.settings)
    if dropped > 0:
      state.log.add(sevWarning, "settings", $dropped & " of the settings given could not " &
        "be used (a calibration that is not a positive number, an entry given twice, a " &
        "sort preset without a name or keys) and were left out.")
    let follow = s.files.followLatest and not state.settings.files.followLatest
    let raw = (rfRawAmplitude in s.readout) != (rfRawAmplitude in state.settings.readout)
    state.change s
    if follow: state.followNewest() # the newest file whole now, at once
    if raw: # the tiles carry their raw samples, or no longer: made again from the samples held
      for k in 0 ..< state.panels.len: state.resample(k)
  of ckExportSettings:
    if not state.refusedExport(cmd):
      state.diskIo.replace(cmd.docPath, settingsDocument(state.settings),
        "the exported settings", done = "Settings exported to " & cmd.docPath & ".")
  of ckImportSettings:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    else: state.diskIo.read(cmd.docPath, rpImportSettings, MaxNifBytes)
  of ckLayout:
    if cmd.arrangement != state.arrangement:
      state.arrangement = cmd.arrangement
      inc state.layoutRev
      state.layoutAt = getMonoTime()
  of ckSaveLayout:
    let why = layoutNameProblem(cmd.layoutName)
    if why.len > 0: state.ignore(cmd, why)
    elif state.configDir.len == 0: state.ignore(cmd, "layouts are not kept in this run")
    elif state.arrangement.len == 0: state.ignore(cmd, "the window layout is not known yet")
    else: state.saveNamed(cmd.layoutName.strip, state.arrangement)
  of ckLoadLayout, ckImportLayout:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    else:
      state.diskIo.read(cmd.docPath, (if cmd.kind == ckLoadLayout: rpLoadLayout
        else: rpImportLayout), MaxNifBytes)
  of ckExportLayout:
    if state.refusedExport(cmd): discard
    elif state.arrangement.len == 0: state.ignore(cmd, "the window layout is not known yet")
    else:
      state.diskIo.replace(cmd.docPath, layoutDocument(Layout(
        name: cmd.docPath.splitFile.name, imgui: state.arrangement)), "the exported layout",
        done = "Layout exported to " & cmd.docPath & ".")
  of ckResetSettings:
    var s = state.defaults
    s.recentFiles = state.settings.recentFiles # memory, not preferences
    s.recentFolders = state.settings.recentFolders
    s.window = state.settings.window
    let file = state.settingsFile
    if file.len > 0:
      # Not a name asked for before: the disk thread may not have written
      # that backup yet, and a second reset must not write over the first's.
      let backup = backupPath(file, taken = state.backups)
      state.backups.add backup
      state.diskIo.replace(backup, settingsDocument(state.settings), "a copy of the settings")
      state.log.add(sevInfo, "settings", "Settings reset to their defaults; the settings " &
        "before are kept in " & backup & ".")
    else:
      state.log.add(sevInfo, "settings", "Settings reset to their defaults.")
    state.change s
  of ckDisplay:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    else:
      template p: untyped = state.panels[k]
      let was = p.layers[0].display
      let wasLimits = p.viewLimits(p.view.columns)
      let d = cmd.display.withGainDb(cmd.display.gainDb)
      p.layers[0].display = d
      inc p.revision
      var s = state.settings
      s.plot.display = remembered(d)
      state.change s
      # New limits (a wiggle mode's widest view, the margin of the overlap):
      # the view stays where it is, a wider one (from density) narrowed
      # keeping its left edge, and one that showed the whole record shows
      # the whole of it again; the frontend follows.
      if p.laidOut and p.layout.traces > 0:
        let v = relimited(p.view, wasLimits, p.viewLimits(p.view.columns))
        if v != p.view:
          p.view = v
          inc p.jumps
      # Only a change of the samples reads again: the gain amount, a Fixed
      # amplitude and a type that is a scale alone change only the drawing.
      if not d.sameProcessing(was, p.kind):
        state.refetch(k, keepTiles = false)
      else:
        state.requestView(k) # a new view, or the extremes wiggles need
      state.settleGain(k)
  of ckHeader:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif not cmd.header.auto and cmd.header.fields.len == 0:
      state.ignore(cmd, "a display header needs at least one field")
    else:
      state.panels[k].header = cmd.header
      var s = state.settings
      s.plot.header = cmd.header
      state.change s
      state.refetch(k, keepTiles = true)
  of ckSort:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    elif cmd.order != state.panels[k].layers[0].order:
      state.panels[k].layers[0].order = cmd.order
      var s = state.settings
      s.plot.order = cmd.order
      if cmd.order.len > 0 and presetOf(cmd.order, s.sortPresets) < 0:
        s.customOrder = cmd.order # the user's own keys, offered again
      state.change s
      state.reorder(k)
  of ckReverseAll:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    elif cmd.reverse != state.panels[k].layers[0].reversed:
      # An operation on the data, so not a setting: a new plot starts as recorded.
      state.panels[k].layers[0].reversed = cmd.reverse
      state.resample(k)
  of ckEdit, ckUndoEdit, ckClearEdits:
    state.editTraces(cmd)
  of ckHover:
    # The UI sends a hover on every move, so one on a trace of a file closed
    # in the same frame is no mistake the user could act on: it clears the
    # hover, and says nothing.
    # The map lights up where it was recorded.
    let known = cmd.trace >= 0 and state.findTrace(cmd.trace) >= 0
    let trace = if known: cmd.trace else: -1
    if trace != state.selection.hover:
      discard state.selection.setHover(trace, state.pointsOfTrace(trace))
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
  of ckLoadSurvey:
    if cmd.paths.len == 0: state.ignore(cmd, "no file was named")
    for given in cmd.paths:
      if given.len == 0: state.ignore(cmd, "a file name was empty")
      else: state.loadSurvey(canonical(given))
  of ckMapView:
    state.map.followed(state.survey)
    state.map.setView(keptMap(cmd.mapView, state.map.limits), cmd.mapRemember)
  of ckMapBack:
    discard state.map.goBack()
  of ckMapLayer:
    state.map.show(cmd.mapLayer, cmd.shown)
  of ckSelectPoints:
    # A range: the points along the line from the one clicked last.
    let anchor = state.selection.pointAnchor
    let points = if cmd.pointMode != smRange or cmd.points.len == 0: cmd.points
                 elif state.survey.find(anchor.layer) < 0: @[cmd.points[0]]
                 else: state.survey.lineRange(anchor, cmd.points[0])
    var traces: seq[int]
    var seen: IntSet
    for p in points:
      for t in state.survey.tracesAt(p):
        if t notin seen:
          seen.incl t
          traces.add t
    state.selection.selectPoints(points, cmd.pointMode)
    case cmd.pointMode
    of smReplace, smRange: # the points' own traces replace those selected
      var keep = state.selection.points
      state.selection.select(traces, smReplace)
      state.selection.selectPoints(keep, smReplace)
      # a range starts where the one before did
      if cmd.pointMode == smRange and state.survey.find(anchor.layer) >= 0:
        state.selection.pointAnchor = anchor
    of smAdd, smRemove: state.selection.select(traces, cmd.pointMode)
    of smToggle:
      let added = points.len > 0 and points[0].key in state.selection.pointKeys
      state.selection.select(traces, if added: smAdd else: smRemove)
  of ckHoverPoints:
    # Every move over the map: the plot draws their traces as it draws its
    # own hover. A point of a layer gone in the same frame is passed by.
    if cmd.points != state.selection.hoverPoints:
      var points: seq[PointRef]
      var traces: IntSet
      for p in cmd.points:
        if state.survey.find(p.layer) >= 0:
          points.add p
          for t in state.survey.tracesAt(p): traces.incl t
      state.selection.setHoverPoints(points, traces)
  of ckShowPoints:
    state.showPoints(cmd)
  of ckUnloadSurvey:
    let i = state.survey.find(cmd.layer)
    if i < 0: state.ignore(cmd, $cmd.layer & " is not loaded")
    elif state.survey.layers[i].origin != loSurveyFile:
      state.ignore(cmd, $cmd.layer & " holds an open file's positions: they go when it is closed")
    else:
      let name = state.survey.layers[i].name
      let checked = state.relationLayer
      discard state.survey.remove(cmd.layer)
      state.log.add(sevInfo, name, name & " was taken out of the survey.")
      if checked == i: # the records were checked against it
        for s in state.sessions: state.checkRecords(s)

proc takeLayout(state: var AppState; m: Msg) =
  ## A layout the disk thread read: shown, and with `rpImportLayout` kept
  ## among the user's layouts under its name.
  let file = m.readPath.extractFilename
  if m.readError.len > 0:
    state.log.add(sevError, "layouts", "Cannot load the layout in " & m.readPath & ": " &
      m.readError & ".")
    return
  var problems: seq[string]
  var l: Layout
  try:
    # The disk thread read the NIF tree: only taking it in is left here.
    if m.docError.len > 0: raise newException(NifError, m.docError)
    l = readLayout(m.doc, file, problems)
  except NifError as e:
    state.log.add(sevError, "layouts", "Cannot load the layout: " & e.msg & ".")
    return
  state.logProblems("layouts", problems)
  if l.name.len == 0 or layoutNameProblem(l.name).len > 0: l.name = m.readPath.splitFile.name
  if layoutNameProblem(l.name).len > 0: l.name = "Imported"
  state.loaded = l
  inc state.loads
  state.log.add(sevInfo, "layouts", "Layout \"" & l.name & "\" loaded.")
  if m.purpose == rpImportLayout and state.configDir.len > 0:
    var name = l.name
    var n = 2
    while state.layoutList.anyIt(not it.preset and it.name.toLowerAscii == name.toLowerAscii):
      name = l.name & " " & $n
      inc n
    state.saveNamed(name, l.imgui)

proc takeIn(state: var AppState; m: Msg) =
  ## A document the disk thread read: settings to import, a layout to load.
  let name = m.readPath.extractFilename
  case m.purpose
  of rpLoadLayout, rpImportLayout: state.takeLayout(m)
  of rpImportSettings:
    if m.readError.len > 0:
      state.log.add(sevError, "settings", "Cannot import the settings in " & m.readPath &
        ": " & m.readError & ".")
    else:
      var problems: seq[string]
      try:
        if m.docError.len > 0: raise newException(NifError, m.docError)
        let s = readSettings(m.doc, name, state.settings, problems)
        state.logProblems("settings", problems)
        state.change cleaned(s)[0]
        state.log.add(sevInfo, "settings", "Settings imported from " & m.readPath &
          (if problems.len > 0: ", except what is said above." else: "."))
      except NifError as e:
        state.log.add(sevError, "settings", "Cannot import the settings: " & e.msg &
          ". Nothing was changed.")

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
    of mkOpened: state.adopt(move m.session, m.job)
    of mkLog: state.log.add(move m.entry)
    of mkRead: state.takeIn(m)
    of mkListed: state.takeListed(move m)
    of mkWatched: state.takeWatched(move m)
    of mkSurvey: state.takeSurvey(move m.layer, m.job)
    of mkChecked: state.takeChecked(move m)
    of mkLayout:
      let k = state.findPanel(m.panel)
      if k >= 0 and m.sourceGen == state.panels[k].sourceGen:
        template p: untyped = state.panels[k]
        p.layout = m.layout
        p.laidOut = true
        p.known = m.known
        # The next gather at the scales of the one before; a first one fits
        # (in a wiggle mode, as far as its limit, from the first trace).
        p.view = if p.carry.traces.width > 0:
            carried(Viewport(traces: p.carry.traces, timeMs: p.carry.timeMs,
              columns: p.view.columns, rows: p.view.rows),
              p.viewLimits(p.carryLayout, p.view.columns), p.viewLimits(p.view.columns))
          else: fitted(p.viewLimits(p.view.columns), p.view.columns, p.view.rows)
        p.carry = Viewport()
        inc p.jumps
        inc p.revision
        state.requestView(k)
    of mkOrder:
      let k = state.findPanel(m.orderPanel)
      if k >= 0 and m.orderGen == max(state.panels[k].sourceGen, state.panels[k].orderGen):
        state.panels[k].shown = move m.positions
        inc state.panels[k].revision
    of mkTile:
      let k = state.findPanel(m.tile.panel)
      if k >= 0 and m.tile.request.gen == state.panels[k].requestGen:
        m.tile.id = state.nextTile
        inc state.nextTile
        if state.panels[k].level.clip.isNaN or state.panels[k].relevel:
          state.panels[k].level = m.tile.level
          state.panels[k].relevel = false
        # The first tile in a new order, or after the samples changed,
        # replaces every tile from before.
        let since = max(state.panels[k].orderGen, state.panels[k].samplesGen)
        state.tiles[k].keepItIf(it.request.gen >= since)
        state.tiles[k].add move m.tile
        if state.tiles[k].len > MaxTiles: state.tiles[k].delete(0)
        var values = 0
        for t in state.tiles[k]: values += t.data.len + t.envelope.len
        while state.tiles[k].len > 1 and values > MaxPanelValues: # the oldest go first
          values -= state.tiles[k][0].data.len + state.tiles[k][0].envelope.len
          state.tiles[k].delete(0)
        inc state.panels[k].revision
        state.settleGain(k)
        # The view may have moved on while the tile was read: the read-ahead
        # is filled again around it now.
        state.requestView(k)
  state.mail.setLen 0
  for job in finished:
    state.onFinished(job)
  state.map.followed(state.survey) # a layer came, or went with a file
  state.relink()
