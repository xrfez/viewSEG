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
## **What is saved, and who changed it.** Every command says where it came
## from (`Command.origin`): a window, or agent control. A change from
## either changes what the program shows and uses, but only the user's own
## reaches what is saved for the next run (`keeps`): the state holds the
## settings in effect (`settings`) and those as the user left them by hand
## (`keptSettings`, what is saved), and every change of the settings goes
## through one template (`change`) that makes it on the second only when
## `keeps` says so. What a command starts and a job finishes (an open's
## recent file, a listing's recent folder, an import) carries its
## command's origin until then. The window arrangement an agent reports is
## not saved either. What an agent does is still written to the log.
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
import closer, diskio, edits, filejobs, filelist, filesystem, inbox, inspector, jobs, join, layouts,
  log, mapstate, panels, persist, pick, reader, recordqc, selection, session, settings, shots,
  spread, survey, surveyjobs, threads, tiles, watch, zoom

export edits, filelist, inbox, jobs, join, layouts, log, mapstate, panels, persist, pick, recordqc,
  selection, session, settings, shots, spread, survey, threads, tiles, zoom
export InspectPart, ChosenBy, Chosen, Inspection, MaxInspected, MaxInspectedValues
export WatchInterval

const
  MainPanel* = PanelId(1)
    ## The panel `initAppState` makes; opened files appear in it.
  MaxTiles* = 4         ## tiles kept per panel, newest last
  FloatValues* = 32_768 ## values in view the Float gain takes its level from, at most
  MaxNotices* = 20      ## notices kept
  MaxTraceReads* = 16
    ## traces read for agent control and not taken, kept at most
  MaxPanelValues* = 48 * 1024 * 1024
    ## the values (192 MiB, and as much on the GPU) a panel's tiles hold at
    ## most: the oldest are dropped first, the newest is always kept
  SlowPer64* = 30.0
    ## ms a read waits for 64 traces' samples, at least, on a slow drive: the
    ## panel then reads further ahead (`SlowReadAhead`), in larger reads
  SlowChunkTraces* = 256 ## traces per read from a slow drive (else the reader's 64)
  MaxPrepareBytes* = 2'i64 * 1024 * 1024 * 1024
    ## a file larger than this (2 GiB) is not prepared: its index and keys
    ## would hold too much memory beside the file shown

type
  CommandKind* = enum
    ckOpen = "open"                      ## open files (one interactive job each) and keep them open
    ckBrowse = "browse"                  ## list files and folders in the file list
    ckShowFile = "show file"             ## show a file in a panel, in place of the one it shows
    ckShowTrace = "show trace"           ## show a trace of a file (a message names it), selected
    ckClose = "close"                    ## close an open file
    ckCancelJob = "cancel job"           ## stop a running job, or one that waits
    ckReorderJob = "reorder job"         ## move a waiting job in its lane's queue
    ckRemoveJob = "remove job"           ## take a waiting or finished job off the list
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
    ckClearSelection = "clear selection" ## no trace selected
    ckLoadSurvey = "load survey"         ## read SPS or P1 files into the survey
    ckUnloadSurvey = "unload survey"     ## take a survey file's layer out of the survey
    ckMapView = "map view"               ## what the map shows (zoom, pan, size)
    ckMapBack = "map back"               ## the map's view before the last gesture
    ckMapLayer = "map layer"             ## show or hide a layer of the map
    ckSelectPoints = "select points"     ## change the points selected on the map, and their traces
    ckHoverPoints = "hover points"       ## the points under the map's pointer, and their traces
    ckShowPoints = "show points' record" ## show the record of the traces recorded at map points
    ckJoin = "join geometry"             ## import a survey: on the map, matched to a file's traces
    ckSelectUnmatched = "select unmatched"
      ## select the traces a join left unmatched
    ckRetry = "retry"                    ## open, read or list again what does not answer
    ckStopReading = "stop reading"       ## leave a panel's read that does not answer
    ckPrepare = "prepare"                ## the file the user is likely to step to next
    ckInspect = "headers shown"          ## what the Headers window has on screen, to be read for it

  Command* = object
    ## A user intent: the only way the UI changes the state.
    origin*: CommandOrigin
      ## where it came from: a window unless agent control says so
    case kind*: CommandKind
    of ckOpen, ckBrowse, ckLoadSurvey:
      paths*: seq[string]
        ## relative or absolute: one file opens once, however it is named
      showFirst*: bool                ## ckBrowse: show the first file found in the main panel
      quiet*: bool
        ## ckBrowse: a folder that is not there (any more) is said quietly, not
        ## as an error (the folder listed last, listed again at start)
    of ckClose: file*: SessionId
      ## the open file's id
    of ckCancelJob, ckRemoveJob: job*: JobId
      ## the job's id
    of ckReorderJob:
      reordered*: JobId               ## the job's id
      position*: int                  ## 0 runs next
    of ckGather, ckView, ckDisplay, ckHeader, ckSort, ckReverseAll, ckBack, ckShowFile,
        ckShowTrace, ckEdit, ckUndoEdit, ckClearEdits, ckFilter, ckRetry, ckStopReading,
        ckPrepare:
      panel*: PanelId                 ## the panel's id (1: the Seismic window; 0 retries the folder)
      gather*: int                    ## ckGather: index into the file's gathers
      path*: string                   ## ckShowFile, ckShowTrace: the file to show; ckPrepare: the next
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
      mode*: SelectMode               ## how they change the selection
    of ckClearSelection, ckResetSettings: discard
    of ckSettings: settings*: Settings
    of ckExportSettings, ckImportSettings, ckLoadLayout, ckExportLayout, ckImportLayout,
        ckExportLog:
      docPath*: string                ## the file written or read
    of ckLayout: arrangement*: string ## the toolkit's layout text
    of ckSaveLayout: layoutName*: string
      ## the name to keep it under
    of ckUnloadSurvey: layer*: SurveyLayerId
      ## the survey layer's id
    of ckMapView:
      mapView*: MapView               ## what the map shows now
      mapRemember*: bool              ## a gesture starts: keep the view it replaces for back
    of ckMapBack: discard
    of ckMapLayer:
      mapLayer*: MapLayerKey          ## the layer: its kind, file and role
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
    of ckJoin:
      joinFile*: SessionId
        ## the open file the survey is matched to; none: the map only
      joinFiles*: seq[JoinFile] ## SPS, SEG P1 files and CSV tables
      joinOptions*: JoinOptions
        ## the join's options: line names, components, the headers' coordinates
      joinUnits*: JoinUnits ## the units the user confirmed
    of ckSelectUnmatched:
      unmatchedOf*: SessionId
        ## the joined file
    of ckInspect:
      inspect*: set[InspectPart]
        ## the parts of the Headers window on screen, which its reader reads
        ## (off the UI thread) until they change: the SEG-D record's headers
        ## of the record the plot shows (File headers), the header fields or
        ## the samples of the traces its Trace tab is about (the selection,
        ## else the trace under the pointer); none when the window is hidden.
        ## Changes nothing else: what was read is in `state`'s `headers`

  CommandOrigin* = enum
    ## Where a command came from: what decides whether its changes are
    ## saved (`keeps`).
    coWindow = "a window"
      ## the user, in a window: saved as before
    coAgent = "agent control"
      ## an agent (`remote/tools`): for the session only

  Notice* = object
    ## A brief notice: a background job ended (the frontend shows it for a
    ## moment; the log keeps it).
    severity*: Severity
    text*: string
    serial*: int ## counts up from 0, never reused

  WaitKind* = enum
    ## What does not answer (`waiting`, `listingWait`).
    wkNone = "none"
    wkOpening = "opening"       ## the open of the file a panel is to show
    wkReading = "reading"       ## a panel's read of the file it shows
    wkUnreadable = "unreadable" ## the file a panel shows cannot be read now (its drive went away)
    wkListing = "listing"       ## the listing of the folder
    wkWatching = "watching"     ## a look at the folder listed
    wkHeaders = "headers"
      ## the Headers window's read of a file's headers or samples

  Waiting* = object
    ## Something the user waits for that the drive does not answer: what the
    ## plot and the Files window say, with Cancel and Retry.
    kind*: WaitKind
    path*: string     ## the file or the folder
    silent*: Duration ## how long it has not answered (on `fs.now`)
    job*: JobId       ## the job Cancel stops (an open, a listing); `NoJob` for none
    why*: string      ## wkUnreadable: why, in plain words
    cause*: UnreadCause ## wkUnreadable: a drive that fails, a file cut short, or a stop

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
    by: CommandOrigin
      ## an open: who asked for it (the user's goes to the recent files kept)

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

  JoinStep* = enum
    ## What a join is doing.
    jpReading = "reading the survey files" ## and working out what joining them does
    jpJoining = "matching"                 ## the readers stopped, the keys changed

  Joining = object
    ## The survey import under way (File > Import > Survey): one at a time.
    job: JobId = NoJob           ## the job of its step; `NoJob`: none under way
    step: JoinStep
    session: SessionId
      ## the file matched to; `NoSession`: the map only
    loads: seq[JobId]
      ## its files' loads onto the map, until their layers come
    added: seq[SurveyLayerId]
      ## the layers they gave (taken out again at a cancel)
    waits: bool
      ## the match is over (or none): the end waits for `loads`
    outcome: JoinOutcome
      ## how the match ended
    words: seq[string]
      ## what it did, in plain words
    path, name: string
    files: seq[JoinFile]
    options: JoinOptions
    units: JoinUnits
    geometry: ref SurveyGeometry ## once read: kept alive while the join reads it
    plan: JoinPlan
    survey: JoinSurvey
    joined: bool                 ## the join's job said it was done (`mkJoined`)
    revision: int                ## the file's keys' revision after the join (`mkJoined`)
    held: int = -1               ## the holds on the file its job found: none (-1: it never ran)
    paused: seq[PanelId]         ## the panels whose readers let go of the file for it

  Joined* = object
    ## An open file joined with survey files: what it was joined with and how.
    session*: SessionId
    files*: seq[JoinFile]
    options*: JoinOptions
    units*: JoinUnits
    plan*: JoinPlan              ## what the join did, trace by trace counted
    survey*: JoinSurvey          ## what the survey files gave
    words*: seq[string]          ## `plan` in plain words
    geometry: ref SurveyGeometry ## what its records are checked against

  JoinOutcome* = enum
    joNone = "none"
    joJoined = "joined"           ## its keys hold the survey's values now
    joNothing = "nothing matched" ## no trace matched: nothing changed
    joCancelled = "cancelled"     ## nothing changed
    joFailed = "failed"           ## nothing changed
    joMapOnly = "on the map"
      ## no file was open: the survey is on the map, no trace matched

  JoinReport* = object
    ## How the last join ended, for the dialog.
    serial*: int        ## goes up with each join that ends
    session*: SessionId
    name*: string       ## the file's name
    outcome*: JoinOutcome
    words*: seq[string] ## what it did, or why not, in plain words
    unmatched*: int     ## the traces it left unmatched
    heldAtJoin*: int = -1
      ## the holds on the file (readers) its keys were changed with: always
      ## none; -1 when they were not changed

  Asked = object
    ## What the Headers window's reader was asked for last.
    parts: set[InspectPart]
    traces: seq[int]
      ## survey-wide ids
    edits: seq[set[TraceEdit]]
      ## theirs, when shown as displayed
    displayed: bool
    shown: SessionId
      ## the file the plot shows, when traces are shown as displayed (only
      ## its traces are read so); NoSession otherwise
    record: (SessionId, int)
      ## a SEG-D record: its file and index; (NoSession, -1) for none
    flow: (bool, int, GatherKind)
      ## the plot's polarity, its pipeline's length, the gather's kind
    display: DisplaySettings
      ## the plot's display, compared by `sameProcessing`
    joins: int
      ## the geometry joins ended so far (`joinReport.serial`): a join
      ## changes the keys the Trace tab shows (read here, never the file's
      ## `keysRevision`, which a join's job writes)

  AppState* = object
    ## Everything the views show. Move-only.
    log: MessageLog
    selection: Selection
    hoverNote: string     ## why the hover lights nothing up; "" when it does
    linked: Linked
    inspect: Inspection
      ## what the Headers window shows of the files' bytes
    chosenFrom: (int, int, bool)
      ## what `chosen` is of: the selection's revision of its selected
      ## traces, of its hover while none is selected (-1 while some are),
      ## and "Follow the pointer"
    asked: Asked
      ## what its reader was asked for last
    inspectGen: uint64
      ## the newest request's
    answerGen: uint64
      ## the newest answer's taken in
    survey: Survey        ## the survey files loaded and the open files' positions
    map: MapState         ## the map's view and hidden layers
    loading: seq[Loading] ## the jobs that fill the survey
    droppedLoads: seq[JobId]
      ## loads a cancelled import started: a layer one still posts is not taken
    checking: seq[tuple[job: JobId; relations: ref SurveyGeometry]]
      ## the relations each record check reads in place, kept alive until it
      ## ends (destroyed after `jobs`, whose runners stop first)
    leftChecks: seq[tuple[job: JobId; relations: ref SurveyGeometry]]
      ## those of checks (and of the map's record checks, `qcHeld`) listed
      ## cancelled while their work still ran (abandoned, `Jobs.tend`): kept
      ## until the work is back (`Jobs.workingOn`)
    joining: Joining
      ## the join under way (its geometry, too, destroyed after `jobs`)
    joins: seq[Joined]
      ## the open files joined with survey files
    joinReport: JoinReport
      ## how the last join ended
    spreads: Spreads
      ## relation records made for the map's planned spreads (`core/spread`)
    shots: ShotIndex
      ## the folder listed's shots, matched to the survey's sources (`core/shots`)
    recordQc: RecordQc
      ## what the map's filters find in the record shown (`core/recordqc`)
    qcHeld: seq[tuple[job: JobId; relations: ref SurveyGeometry]]
      ## the relation records each filters' job reads in place, kept until it ends
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
    quietScan: JobId     ## a listing of the folder listed last: a missing folder is said quietly
    unread: seq[tuple[panel: PanelId; cause: UnreadCause; why: string]]
      ## the panels whose file cannot be read now, and why (`mkUnread`)
    speeds: seq[tuple[panel: PanelId; ms: float64]]
      ## per panel: ms its reads wait for 64 traces, smoothed (`SlowPer64`)
    prepareWanted: string ## the file to prepare (`ckPrepare`); "" for none
    preparing: tuple[job: JobId; path: string] ## the prepare job running; `NoJob` for none
    prepared: tuple[job: JobId; session: Session]
      ## the file prepared, opened and unshown until the user steps to it
    prepareFailed: string ## the file whose preparing failed last: not tried again
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
    traceReads: seq[tuple[job: JobId; keys: TraceKeys; rows: seq[HeaderRow]]]
      ## traces read for agent control (`readTraceHeaders`), oldest first, until taken
    mail: seq[Msg]
    indexCache: string ## the index cache folder; "" for none
    settings: Settings
    nextFile, nextPanel, nextBase: int
    tiles: seq[seq[Tile]] ## per panel, as `panels`: the newest last
    nextTile: uint64
    scratch: Workspace ## for the Float gain's level, on this thread
    inbox: Inbox
    disk: DiskIo ## writes the session log and the settings; none until needed
    closer: Closer ## closes the files the state lets go of; none until needed
    logFile: string ## the session log; "" for none
    logged: int ## the log's serial the session log has reached
    configDir: string ## where the settings and layouts are saved; "" for nowhere
    keepsSettings: bool ## the settings are saved there; false: their file is left alone
    savedLayouts: seq[SavedLayout] ## the layouts saved by name this run, kept in the list
    defaults: Settings ## what a reset goes back to
    settingsRev: int ## bumped on every change of `settings`
    kept: Settings ## the settings as the user left them by hand: what is saved (`keeps`)
    keptRev: int ## bumped on every change of `kept`
    savedRev: int ## the revision of `kept` saved last
    changedAt: MonoTime ## when `kept` last changed
    listedBy: CommandOrigin
      ## who asked for the listing: its folder goes to the recent ones kept
    openedBy: Table[string, CommandOrigin]
      ## per file open: who asked for it (a reopen after it changed is theirs)
    importsBy: seq[CommandOrigin]
      ## who asked for each settings import being read, oldest first
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
    inspector: Inspector
      ## the Headers window's reader; started when it is first asked. Last:
      ## it stops (and ends its holds) first.
    leftInspectors: seq[Inspector]
      ## readers of the Headers window left stuck in a drive that does not
      ## answer, until they end (their holds with them)

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
    files: FileList(job: NoJob), watchEvery: watchEvery, quietScan: NoJob,
    preparing: (NoJob, ""), prepared: (NoJob, nil))
  result.panels.add Panel(id: MainPanel)
  result.tiles.add newSeq[Tile]()
  result.readers.add PanelReader()

const SaveDelay* = initDuration(seconds = 1)
  ## settings are saved this long after their last change (and at shutdown)

proc diskIo(state: var AppState): lent DiskIo =
  ## The disk thread, started when first needed.
  if state.disk.isNil: state.disk = newDiskIo(state.inbox.poster)
  state.disk

proc release(state: var AppState; s: sink Session) =
  ## Lets go of `s`, which nothing reads any more: its file is closed on the
  ## closer's thread, never on this one (a share may hold a close).
  if s.isNil: return
  if state.closer.isNil: state.closer = newCloser()
  state.closer.drop(s)

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
  state.kept = state.settings
  state.defaults = cleaned(loaded.defaults)[0]
  state.configDir = dir
  state.keepsSettings = loaded.saveable
  inc state.settingsRev
  inc state.keptRev
  state.savedRev = if loaded.rewrite: state.keptRev - 1 else: state.keptRev
  state.changedAt = getMonoTime()
  discard state.diskIo

proc saveNamed(state: var AppState; name, imgui: string) =
  ## Keeps `imgui` as the user's layout `name`, replacing one of that name.
  let path = layoutPath(state.configDir, name)
  state.diskIo.replace(path, layoutDocument(Layout(name: name, imgui: imgui)),
    "the layout \"" & name & "\"", done = "Layout \"" & name & "\" saved in " & path & ".")
  state.layoutList = state.layoutList.added(SavedLayout(name: name, path: path))
  state.savedLayouts.add SavedLayout(name: name, path: path)

proc keepLayoutsIn*(state: var AppState; dir: string; presetDirs: openArray[string]) =
  ## From now on, saves the arrangement in `dir`'s `LayoutFileName` (a
  ## moment after it changes, and at `shutdown`) and named layouts in its
  ## `layouts/`; lists those and the presets in `presetDirs`' `layouts/`.
  assertUiThread()
  if state.configDir.len == 0: state.configDir = dir
  state.diskIo.listLayouts(dir, @presetDirs) # off this thread: the folders may be slow

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
    state.disk.replace(file, settingsDocument(state.kept), "the settings")
  state.savedRev = state.keptRev

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
  if state.savedRev != state.keptRev and now - state.changedAt >= SaveDelay:
    state.saveSettings()
  if state.layoutSaved != state.layoutRev and now - state.layoutAt >= SaveDelay:
    state.saveArrangement()

proc flushFiles*(state: var AppState) =
  ## Saves what is due now, without waiting for `SaveDelay`, and waits
  ## until the disk thread has written everything handed to it (tests).
  assertUiThread()
  state.writeLog()
  if state.savedRev != state.keptRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.disk.flush()

const
  QuitWait* = initDuration(milliseconds = 800)
    ## how long `shutdown` waits, at most, for the threads to end
  CloseWait* = initDuration(milliseconds = 200)
    ## and then for the files to be closed

proc keepForStragglers(state: var AppState) =
  ## A thread left running at the quit (held by a drive that does not
  ## answer, or a join's step of millions of traces) may still read an open
  ## file's map, a relation file or the survey a join applies: they stay, to
  ## the end of the process, instead of being released under it.
  for s in state.sessions: GC_ref(s)
  for p in state.closing: GC_ref(p.session)
  for c in state.checking: GC_ref(c.relations)
  for c in state.leftChecks: GC_ref(c.relations)
  for c in state.qcHeld: GC_ref(c.relations)
  if not state.joining.geometry.isNil: GC_ref(state.joining.geometry) # `joinApplyWork` reads it

proc shutdown*(state: var AppState; wait = QuitWait): bool {.discardable.} =
  ## Asks every thread to end at once (the panels' readers, the watch, the
  ## jobs: every job is cancelled), hands what is left to save to the disk
  ## thread (the settings, the layout, the session log), and waits for them
  ## all, together, at most `wait`, then `CloseWait` for the files to be
  ## closed (on the closer's thread): true when all ended. A thread held by
  ## a drive that does not answer is left to end on its own, with what it
  ## may read (`keepForStragglers`), so the quit never waits for a drive.
  ## Destroying the state does this too.
  assertUiThread()
  state.inspector.askStop()
  for r in state.readers: r.askStop()
  state.watch.askStop()
  state.jobs.askStop()
  if state.savedRev != state.keptRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.writeLog()
  state.disk.askStop()
  let deadline = getMonoTime() + wait
  result = true
  for r in state.readers:
    if not r.stop(deadline): result = false
  if not state.inspector.stop(deadline): result = false
  for x in state.leftInspectors:
    if not x.stop(deadline): result = false
  state.watch.stop(deadline)
  if not state.jobs.stop(deadline): result = false
  if not state.disk.stop(deadline): result = false
  # A reader left earlier to end on its own (stuck in a drive: Retry, Stop,
  # another file) is none of `readers`, and an abandoned job's work may have
  # ended its job: what they read is still held (their holds).
  if state.jobs.holdsLeft > 0: result = false
  # The files are closed on the closer's thread (a share may hold a close),
  # unless a thread left may still read them.
  if not result: state.keepForStragglers()
  else:
    var open = move state.sessions
    for s in open.mitems: state.release(move s)
    var closing = move state.closing
    for p in closing.mitems: state.release(move p.session)
  state.release(move state.prepared.session)
  if not state.closer.stop(getMonoTime() + CloseWait): result = false

# --------------------------------------------------------------- reading --

func log*(state: AppState): lent MessageLog {.inline.} =
  ## The message log.
  state.log

func selection*(state: AppState): lent Selection {.inline.} =
  ## The trace under the cursor, the selected traces, the gather on show.
  state.selection

func inspection*(state: AppState): lent Inspection {.inline.} =
  ## What the Headers window shows of the files' bytes: the traces its Trace
  ## tab is about, and the newest answer of its reader.
  state.inspect

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

func joins*(state: AppState): lent seq[Joined] {.inline.} =
  ## The open files joined with survey files, and how.
  state.joins

func joinedOf*(state: AppState; session: SessionId): int =
  ## The index in `joins` of open file `session`'s join; -1 when it is not
  ## joined.
  for i in 0 ..< state.joins.len:
    if state.joins[i].session == session: return i
  -1

func spreads*(state: AppState): lent Spreads {.inline.} =
  ## The relation records made for the map's planned spreads, and what was
  ## made in words (`core/spread`).
  state.spreads

func shots*(state: AppState): lent ShotIndex {.inline.} =
  ## The shots of the folder listed: each listed file's records, matched to
  ## the survey files' sources (`core/shots`).
  state.shots

func recordQc*(state: AppState): lent RecordQc {.inline.} =
  ## What the map's filters found in the record shown, as its job read it
  ## (`core/recordqc`); `filterHits` gives every filter.
  state.recordQc

func joinReport*(state: AppState): lent JoinReport {.inline.} =
  ## How the last join ended (its `serial` goes up with each).
  state.joinReport

func joinUnderWay*(state: AppState): tuple[job: JobId; step: JoinStep; session: SessionId] =
  ## The join under way: its job (`NoJob` for none), what it does, and the
  ## file it joins to.
  (state.joining.job, state.joining.step, state.joining.session)

func importing*(state: AppState): bool {.inline.} =
  ## Whether a survey import is under way: its match, or the loads of its
  ## files onto the map.
  state.joining.job != NoJob or state.joining.loads.len > 0 or state.joining.waits

func indexCache*(state: AppState): lent string {.inline.} =
  ## The folder of parseSEG's index caches; "" for none.
  state.indexCache

func settings*(state: AppState): lent Settings {.inline.} =
  ## The settings in effect (`core/settings`): the user's, with what agents
  ## changed this session.
  state.settings

func keptSettings*(state: AppState): lent Settings {.inline.} =
  ## The settings as the user left them by hand: what is saved, and what
  ## the next run starts with (`keeps`).
  state.kept

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

proc waiting*(state: AppState; panelIndex: int; now = fs.now()): Waiting =
  ## What `panels[panelIndex]` waits for that its drive does not answer: the
  ## open of the file it is to show, or its read, once either has been
  ## silent `StallAfter`; or why its file cannot be read now. None
  ## otherwise. Each frame: a few locks taken briefly.
  template p: untyped = state.panels[panelIndex]
  result = Waiting(job: NoJob)
  for o in state.opening:
    if not o.unwanted and (o.panel == p.id or (o.panel == NoPanel and p.id == MainPanel)):
      let info = state.jobs.info(o.job)
      if info.isSome:
        let silent = info.get.notAnsweringFor(now)
        if silent > initDuration():
          return Waiting(kind: wkOpening, path: o.path, silent: silent, job: o.job)
  let i = state.shownFile(panelIndex)
  if i < 0: return
  let silent = state.readers[panelIndex].silentFor(now)
  if silent >= StallAfter:
    return Waiting(kind: wkReading, path: state.sessions[i].path, silent: silent, job: NoJob)
  for u in state.unread:
    if u.panel == p.id:
      return Waiting(kind: wkUnreadable, path: state.sessions[i].path, job: NoJob, why: u.why,
        cause: u.cause)

func words*(w: Waiting): string =
  ## What the plot or the Files window says of `w`, in plain words; "" for
  ## none.
  let name = w.path.extractFilename
  let silent = "not answering for " & $max(1, w.silent.inSeconds) & " s"
  case w.kind
  of wkNone: ""
  of wkOpening: "Opening " & name & ": " & silent & " (its drive may be slow, or gone)."
  of wkReading: "Reading " & name & ": " & silent & " (its drive may be slow, or gone). " &
    "The plot shows what was read before."
  of wkUnreadable: w.why
  of wkListing: "Listing " & name & ": " & silent & " (its drive may be slow, or gone)."
  of wkWatching: name & ": " & silent & "; the list is as it was read last."
  of wkHeaders: "Reading " & name & " for the Headers window: " & silent & " (its drive may " &
    "be slow, or gone). The window shows what was read before; another file can be looked at " &
    "meanwhile."

proc headersWait*(state: AppState; now = fs.now()): Waiting =
  ## What the Headers window waits for that its drive does not answer: its
  ## reader's read of a file, once silent `StallAfter`. None otherwise.
  result = Waiting(job: NoJob)
  if not state.inspector.isNil:
    let silent = state.inspector.silentFor(now)
    if silent >= StallAfter:
      result = Waiting(kind: wkHeaders, path: state.inspector.readingPath, silent: silent,
        job: NoJob)

proc listingWait*(state: AppState; now = fs.now()): Waiting =
  ## What the file list waits for that its drive does not answer: the
  ## listing of the folder, or a look at it once listed. None otherwise.
  result = Waiting(job: NoJob)
  let title = if state.files.folder.len > 0: state.files.folder else: state.files.title
  if state.files.job != NoJob:
    let info = state.jobs.info(state.files.job)
    if info.isSome:
      let silent = info.get.notAnsweringFor(now)
      if silent > initDuration():
        return Waiting(kind: wkListing, path: title, silent: silent, job: state.files.job)
  let look = state.watch.lookingFor(now)
  if look >= StallAfter:
    result = Waiting(kind: wkWatching, path: title, silent: look, job: NoJob)

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

func keeps*(origin: CommandOrigin): bool {.inline.} =
  ## Whether a change a command from `origin` makes reaches what is saved
  ## for the next run (the settings, the recent files and folders, the
  ## window arrangement): the user's in a window does; an agent's is for
  ## the session only (the user's decision). The one place that decides.
  origin == coWindow

proc takeSettings(state: var AppState; s: sink Settings) =
  ## Makes `s` the settings in effect, noting a change when it is one (as
  ## saved: a value that is not a number equals itself).
  if settingsDocument(s) != settingsDocument(state.settings):
    state.settings = s
    inc state.settingsRev

proc keepSettings(state: var AppState; s: sink Settings) =
  ## Makes `s` the settings kept for the next run, saved `SaveDelay` later.
  if settingsDocument(s) != settingsDocument(state.kept):
    state.kept = s
    inc state.keptRev
    state.changedAt = getMonoTime()

template change(state: var AppState; by: CommandOrigin; s, edit: untyped) =
  ## Changes the settings by `edit`, made on `s`: those in effect, and,
  ## when `keeps(by)`, those kept for the next run the same way. Every
  ## change of the settings goes through here. `edit` runs on each copy in
  ## turn, with the state as it was before, so it says what changes (a file
  ## put first among the recent ones, the fields a window changed: `carried`
  ## from `state.settings`), not what the settings become.
  if keeps(by):
    var s = state.kept
    edit
    state.keepSettings(s)
  block:
    var s = state.settings
    edit
    state.takeSettings(s)

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
  state.unread.keepItIf(it.panel != p.id)
  # A reader stuck in a drive that does not answer would never take the new
  # source: it is left to end on its own, and a new one takes it.
  if not state.readers[k].isNil and state.readers[k].silentFor >= StallAfter:
    state.readers[k].abandon()
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
      elif s.path == state.joining.path and state.joining.step == jpJoining:
        busy = true # shown once the join is done
        if p.id notin state.joining.paused: state.joining.paused.add p.id
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

func slowDrive*(state: AppState; panel: PanelId): bool =
  ## Whether `panel`'s reads wait long for the drive (`SlowPer64`): it then
  ## reads further ahead, in larger reads.
  for s in state.speeds:
    if s.panel == panel: return s.ms >= SlowPer64
  false

proc timeRead(state: var AppState; t: Tile) =
  ## Takes in how long tile `t`'s read waited for the drive.
  if t.cached or t.chunks == 0 or t.request.count == 0: return
  let ms = t.readTime.inMicroseconds.float64 / 1000 * 64 / float64(t.request.count)
  for s in state.speeds.mitems:
    if s.panel == t.panel:
      s.ms = (s.ms + ms) / 2
      return
  state.speeds.add (t.panel, ms)

proc requestView(state: var AppState; k: int) =
  ## Asks `panels[k]`'s reader for its view, unless the request sent last
  ## already covers it. On a slow drive (`slowDrive`) it reads further
  ## ahead, in larger reads.
  template p: untyped = state.panels[k]
  if p.layers.len == 0 or p.layout.traces == 0 or state.readers[k].isNil: return
  let slow = state.slowDrive(p.id)
  let (ahead, kept, most) = if slow: (SlowReadAhead, SlowKeepAhead, SlowMaxAheadValues)
                            else: (ReadAhead, KeepAhead, MaxAheadValues)
  let flow = p.layers[0].displayPipeline(state.gatherKind(p.layers[0]))
  let margin = displayMargin(flow, p.layout.dtMs)
  let wiggles = p.layers[0].display.drawsWiggles
  if p.pending.gen == p.requestGen:
    # Enough on hand on every side: nothing to ask. The view itself on hand,
    # or on its way: the read-ahead is filled again once the request sent is
    # answered, so a key held down does not start a read every few frames
    # and finish none.
    if p.pending.covers(p.layout, p.view, margin, wiggles, keep = kept, readAhead = ahead,
        maxValues = most): return
    if p.pending.covers(p.layout, p.view, margin, wiggles) and
        not state.tiles[k].anyIt(it.request.gen == p.pending.gen):
      return
  var req = requestFor(p.layout, p.view, margin, readAhead = ahead, wiggles = wiggles,
    maxValues = most)
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
    raw: rfRawAmplitude in state.settings.readout, chunkTraces: if slow: SlowChunkTraces else: 0)

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

proc settleGain(state: var AppState; k: int; by: CommandOrigin) =
  ## After a change of display, view or tiles of `panels[k]` (`by` whom: a
  ## tile is the data's own): Fixed takes its amplitude from the data shown
  ## when it has none yet (and the settings keep it, for new plots and the
  ## next run, when they wait for one too), and Float takes its level from
  ## the data now in view (keeping the one before when no tile holds any of
  ## it yet).
  template p: untyped = state.panels[k]
  if p.layers.len == 0: return
  template d: untyped = state.panels[k].layers[0].display
  case d.effectiveGain(p.kind)
  of dgFixed:
    if not usable(d.fixedClip) and usable(p.level.clip):
      d.fixedClip = p.level.clip
      inc p.revision
      # kept for the next run too, as a typed amplitude is
      let clip = d.fixedClip
      state.change(by, s):
        if s.plot.display.gain == dgFixed and not usable(s.plot.display.fixedClip):
          s.plot.display.fixedClip = clip
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
  let joined = state.joinedOf(s.id)
  if joined >= 0: state.joins.delete(joined)
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
  if not keepLayers: state.openedBy.del s.path # kept for the file's reopen only
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

proc followInspect(state: var AppState) =
  ## After every change: the traces the Headers window's Trace tab is about
  ## found again when the selection changed, and its reader asked for what
  ## the window has on screen when that is not what it was asked for last
  ## (other traces, another record, their edits or the plot's processing
  ## when they are shown as displayed, their keys after a geometry join).
  ## Each file it reads is held first; a
  ## trace of a file that cannot be held (a job needs it to itself) is
  ## answered as busy. With nothing on screen, nothing is read.
  template ins: untyped = state.inspect
  let view = state.settings.headers
  # With traces selected, the tab is about them: the pointer moving (the
  # selection's hover) changes nothing, and costs nothing, however many.
  template sel: untyped = state.selection
  let basis = (sel.selectedRevision, (if sel.anySelected: -1 else: sel.revision),
    view.followPointer)
  if basis != state.chosenFrom:
    state.chosenFrom = basis
    var chosen = chosenTraces(state.selection, view.followPointer, ins.chosen)
    # (those pointed at last stay while their file is open)
    chosen.traces.keepItIf(state.findTrace(it) >= 0)
    if chosen.traces.len == 0: chosen = Chosen()
    if chosen != ins.chosen:
      ins.chosen = chosen
      inc ins.revision
  var want = Asked(parts: ins.parts, record: (NoSession, -1), shown: NoSession)
  let k = state.findPanel(MainPanel)
  let shown = state.shownFile(k)
  if ipRecord in ins.parts and shown >= 0:
    let s = state.sessions[shown]
    let g = state.panels[k].layers[0].source.gather
    if g in 0 ..< s.gathers.len:
      let r = s.file.segdRecordOf(s.gathers[g].traces.a)
      if r >= 0: want.record = (s.id, r)
  let traceParts = ins.parts * {ipTraceHeaders, ipTraceSamples}
  if traceParts != {}: want.traces = ins.chosen.traces
  want.joins = state.joinReport.serial
  want.displayed = view.asDisplayed and ipTraceSamples in ins.parts
  if want.displayed:
    for t in want.traces: want.edits.add state.traceEdits(t)
    if shown >= 0:
      let layer = state.panels[k].layers[0]
      want.shown = state.sessions[shown].id
      want.flow = (layer.reversed, layer.pipeline.len, state.gatherKind(layer))
      want.display = layer.display
  template was: untyped = state.asked
  if want.parts == was.parts and want.traces == was.traces and want.edits == was.edits and
      want.joins == was.joins and want.displayed == was.displayed and
      want.shown == was.shown and want.record == was.record and
      want.flow == was.flow and want.display.sameProcessing(was.display, want.flow[2]):
    return
  state.asked = want
  if want.record[0] == NoSession and want.traces.len == 0:
    if ins.answer.traces.len > 0 or ins.answer.recordPath.len > 0:
      ins.answer = Inspected()
      inc ins.revision
    ins.waiting = false
    # an answer still on its way is of what is no longer on screen: dropped
    state.answerGen = state.inspectGen
    return
  inc state.inspectGen
  var req = InspectRequest(gen: state.inspectGen, headers: ipTraceHeaders in ins.parts,
    samples: ipTraceSamples in ins.parts)
  var held: seq[SessionId] # by `req.files`' index; NoSession for a file that could not be held
  proc fileOf(state: var AppState; req: var InspectRequest; held: var seq[SessionId];
      i: int): int =
    ## The index in `req.files` of open file `sessions[i]`, held on first use;
    ## -1 when it cannot be held.
    let s = state.sessions[i]
    result = held.find(s.id)
    if result < 0 and state.jobs.hold(s.path):
      req.files.add InspectFile(file: s.filePtr, path: s.path, size: s.size)
      held.add s.id
      result = held.high
  if want.record[0] != NoSession:
    req.recordAt = state.fileOf(req, held, state.findSession(want.record[0]))
    req.record = want.record[1]
  if want.displayed and shown >= 0:
    let layer = state.panels[k].layers[0]
    req.flow = layer.displayPipeline(state.gatherKind(layer))
  for n, t in want.traces:
    let i = state.findTrace(t)
    if i >= 0:
      let s = state.sessions[i]
      req.traces.add InspectTrace(id: t, at: state.fileOf(req, held, i), trace: t - s.base,
        edits: (if want.displayed: want.edits[n] else: {}),
        displayed: want.displayed and i == shown)
  if not state.inspector.isNil and state.inspector.silentFor >= StallAfter:
    # Stuck in a drive that does not answer: a request that does not need
    # that file is read by a new inspector (the stuck one ends on its own,
    # with its holds, once the drive answers); one that does waits for it.
    let stuck = state.inspector.readingPath
    var needs = false
    for f in req.files:
      if f.path == stuck: needs = true
    if not needs:
      state.inspector.leave()
      state.leftInspectors.add move state.inspector
  if state.inspector.isNil:
    state.inspector = newInspector(state.inbox.poster, state.jobs.holdRelease)
  ins.waiting = true
  state.inspector.ask(req)

proc takeInspected(state: var AppState; m: sink Msg) =
  ## An answer of the Headers window's reader newer than the one shown (the
  ## newest asked or not: while the pointer moves, each answer is a request
  ## behind, and showing it beats waiting).
  if m.inspected.gen > state.answerGen:
    state.answerGen = m.inspected.gen
    state.inspect.answer = move m.inspected
    if state.answerGen >= state.inspectGen: state.inspect.waiting = false
    inc state.inspect.revision
proc showListedShot(state: var AppState; cmd: Command): bool

proc showPoints(state: var AppState; cmd: Command) =
  ## `ckShowPoints`: the main panel shows the record of the traces recorded
  ## at `cmd.points` (a source's shot record), in the file it shows when it
  ## has some, else in the file that has the first; nothing changes when it
  ## shows one of them already.
  let k = state.findPanel(MainPanel)
  var traces: seq[int]
  for p in cmd.points: traces.add state.survey.tracesAt(p)
  if traces.len == 0:
    if not state.showListedShot(cmd):
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

proc readTraceHeaders*(state: var AppState; i, index: int): JobId =
  ## Reads trace `index` of open file `sessions[i]` on a job: its keys and
  ## the fields of its headers, from the file's map, which may be on a drive
  ## that does not answer (never on this thread). `takeTraceRead` gives what
  ## it read once its job has posted it.
  let s = state.sessions[i]
  state.jobs.submit(JobSpec(title: "Read the headers of trace " & $(index + 1) & " of " & s.name,
    lane: jlInteractive, reads: @[s.path]), traceHeadersWork(s.filePtr, s.path, s.size, index,
    state.inbox.poster))

proc takeTraceRead*(state: var AppState; job: JobId; keys: var TraceKeys;
    rows: var seq[HeaderRow]): bool =
  ## What job `job` of `readTraceHeaders` read, once it has posted it (then
  ## it is given once); false until then, and for any other job.
  for i in 0 ..< state.traceReads.len:
    if state.traceReads[i].job == job:
      keys = state.traceReads[i].keys
      rows = move state.traceReads[i].rows
      state.traceReads.delete(i)
      return true
  false

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

func joinedRelations(state: AppState; session: SessionId): int =
  ## The index in `joins` of open file `session`'s join when its survey has
  ## relation records (what its records are then checked against); -1 when not.
  let j = state.joinedOf(session)
  if j >= 0 and state.joins[j].survey.relations > 0: j else: -1

func fileNames(files: openArray[JoinFile]): string =
  var names: seq[string]
  for f in files: names.add f.path.extractFilename
  names.join(", ")

proc checkRecords(state: var AppState; s: Session) =
  ## Checks the records of open file `s` on a job (the Records window's
  ## planned and missing stations): against the survey it was joined with
  ## when that has relation records, else against the loaded relation file;
  ## or clears the check when there is neither.
  var gathers = newSeq[Slice[int]](s.gathers.len)
  for i, g in s.gathers: gathers[i] = g.traces
  let j = state.joinedRelations(s.id)
  let opts = state.settings.join
  if j >= 0:
    template x: untyped = state.joins[j]
    let job = state.jobs.submit(JobSpec(title: "Check the records of " & s.name &
      " against the survey imported", lane: jlBackground, reads: @[s.path]), checkWork(s.filePtr,
      s.id, gathers, addr x.geometry[], fileNames(x.files), NoSurveyLayer, state.inbox.poster,
      x.options.recordMatch, x.options.traceMatch))
    state.checking.add (job, x.geometry)
    return
  let r = state.relationLayer
  if r < 0:
    s.setChecks("", [], [])
    return
  template l: untyped = state.survey.layers[r]
  # The job reads the layer's relations where they are (a copy of a large X
  # file's took a frame per file opened); they are kept until it ends, also
  # when the layer is unloaded meanwhile.
  let job = state.jobs.submit(JobSpec(title: "Check the records of " & s.name & " against " &
    l.name, lane: jlBackground, reads: @[s.path]), checkWork(s.filePtr, s.id, gathers,
    addr l.relations[], l.name, l.id, state.inbox.poster, opts.recordMatch, opts.traceMatch))
  state.checking.add (job, l.relations)

proc takeChecked(state: var AppState; m: sink Msg) =
  ## An open file's records checked against the survey it was joined with,
  ## or against a relation file that is still the one loaded, with the
  ## file's keys as they were.
  let i = state.findSession(m.checkedSession)
  if i < 0 or state.sessions[i].keysRevision != m.keysRevision: return
  let joined = state.joinedRelations(m.checkedSession) >= 0
  let r = state.relationLayer
  if (m.againstLayer == NoSurveyLayer and joined) or (not joined and r >= 0 and
      state.survey.layers[r].id == m.againstLayer):
    state.sessions[i].setChecks(m.against, m.planned, m.plannedMissing, m.unlisted,
      m.duplicates)

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

proc loaded(state: var AppState; job: JobId; layer: SurveyLayerId)

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
    if i < 0 or state.sessions[i].keysRevision != layer.keysRevision: return
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
    let dropped = state.droppedLoads.find(job)
    if dropped >= 0: # a cancelled import's: the map stays as it was
      state.droppedLoads.delete(dropped)
      return
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
    let id = state.survey.add(layer)
    state.log.add(if lost > 0: sevWarning else: sevInfo, name, text)
    let now = state.relationLayer
    if now >= 0 and state.survey.layers[now].id != wasId:
      for s in state.sessions: # against the relation file now loaded
        if state.joinedRelations(s.id) < 0: state.checkRecords(s)
    state.loaded(job, id)

proc adopt(state: var AppState; s: sink Session; job: JobId) =
  ## Takes in a file an open job opened, and shows its first gather (or the
  ## gather the open asks for) in the panel the open was for (the main panel
  ## unless `ckShowFile` named another); drops it when no longer wanted, and
  ## when "Follow the latest" opened it and it is not whole yet.
  var panel = MainPanel
  var replacing = false # `ckShowFile`: in place of the file the panel shows
  var gather = 0
  var follow = false
  var by = coWindow
  for p in state.opening:
    if p.job == job:
      if p.unwanted: # another file was chosen meanwhile
        state.release(s)
        return
      if p.panel != NoPanel: (panel, replacing) = (p.panel, true)
      (gather, follow, by) = (p.gather, p.follow, p.by)
  if follow and s.file.kind != skUnknown and s.file.cutShort:
    # Not shown early: it ends before its last trace. Shown when it changes and is whole.
    state.mark(s.path, short = true, seen = false)
    state.log.add(sevInfo, s.name, s.name & " is not shown yet: it ends before its last " &
      "trace, so it is still being written (or was cut short). It is shown once it has " &
      "changed and is whole; click it in Files to see it as it is.")
    if panel == MainPanel: state.chooseShown()
    state.release(s) # nothing else has it
    return
  if s.file.kind == skUnknown:
    state.log.add(s.file.log, s.name)
    state.log.add(sevError, s.name, s.name & " is not a SEG-Y, SEG-D or SEG-2 file, " &
      "so it was not opened.")
    if panel == MainPanel:
      state.failed(s.path)
      state.chooseShown()
    state.release(s) # nothing else has it
    return
  let id = SessionId(state.nextFile)
  inc state.nextFile
  s.register(id, state.nextBase)
  state.nextBase += s.len
  state.log.add(s.file.log, s.name)
  state.log.add(sevInfo, "open", "Opened " & s.name & ": " & plural(s.len, "trace") &
    " in " & plural(s.gathers.len, "gather") &
    (if s.file.fromCache: " (index from the cache)." else: "."))
  gather = if s.gathers.len == 0: -1 else: clamp(gather, 0, s.gathers.high)
  state.change(by, st):
    st.recentFiles.addRecent(s.path, MaxRecent)
    st.recentFolders.addRecent(s.path.parentDir, MaxRecent)
  state.openedBy[s.path] = by
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

# ------------------------------------------------------------------ join --

proc finishImport(state: var AppState)

proc startJoin(state: var AppState; i: int; cmd: Command) =
  ## `ckJoin`, the survey import: its SPS and P1 files not on the map yet
  ## are loaded onto it, as File > Open loads them (`loadSurvey`); with an
  ## open file `sessions[i]`, the files are read again and what matching
  ## them to its traces does is worked out on a job (`joinReadWork`), while
  ## the plot goes on reading the file. With none (`i` -1), the survey is
  ## put on the map only.
  var files: seq[JoinFile]
  var reads = if i >= 0: @[state.sessions[i].path] else: @[]
  for f in cmd.joinFiles:
    if f.path.len > 0:
      var c = f
      c.path = canonical(f.path)
      if c.path notin reads:
        reads.add c.path
        files.add c
  if files.len == 0:
    state.ignore(cmd, "no survey file was named")
    return
  var loads: seq[JobId]
  for f in files:
    if f.kind != jkCsv and state.survey.findFile(f.path) < 0 and
        not state.surveyLoading(f.path):
      state.loadSurvey(f.path, quiet = true)
      if state.loading.len > 0 and state.loading[^1].path == f.path:
        loads.add state.loading[^1].job
  if i < 0:
    state.joining = Joining(name: "the map", files: files, options: cmd.joinOptions,
      units: cmd.joinUnits, loads: loads, waits: true, outcome: joMapOnly, words: @[
      "No seismic file is open, so no trace was matched: open one and import the survey " &
      "again to match it."])
    state.log.add(sevInfo, "survey", "Importing the survey (" & fileNames(files) & "): no " &
      "seismic file is open, so it is put on the map only.")
    if loads.len == 0: state.finishImport()
  else:
    let s = state.sessions[i]
    let job = state.jobs.submit(JobSpec(title: "Import the survey for " & s.name,
      lane: jlInteractive, reads: reads), joinReadWork(s.filePtr, s.id, files, cmd.joinOptions,
      state.inbox.poster))
    state.joining = Joining(job: job, step: jpReading, session: s.id, path: s.path,
      name: s.name, files: files, options: cmd.joinOptions, units: cmd.joinUnits, loads: loads)
    state.log.add(sevInfo, s.name, "Importing the survey (" & fileNames(files) & ") for " &
      s.name & ".")

proc pauseReaders(state: var AppState; path: string) =
  ## Has the readers of the panels that show `path` let go of it, for the
  ## join that needs it to itself; their tiles stay drawn meanwhile.
  for k in 0 ..< state.panels.len:
    let i = state.shownFile(k)
    if i >= 0 and state.sessions[i].path == path:
      if state.panels[k].id notin state.joining.paused:
        state.joining.paused.add state.panels[k].id
      if not state.readers[k].isNil:
        state.readers[k].show(ReaderSource(gen: state.panels[k].sourceGen))

proc resumeReaders(state: var AppState) =
  ## The panels the join paused show their file again: the same gather at
  ## the same scales, the tiles from before drawn until the first new one
  ## (made from the joined keys) comes.
  for id in state.joining.paused:
    let k = state.findPanel(id)
    let i = if k >= 0: state.shownFile(k) else: -1
    if i >= 0:
      template p: untyped = state.panels[k]
      let s = state.sessions[i]
      let g = p.layers[0].source.gather
      if p.laidOut and p.layout.traces > 0 and not state.readers[k].isNil and
          g in 0 ..< s.gathers.len and state.jobs.hold(s.path):
        if p.view.traces.width > 0:
          p.carry = p.view
          p.carryLayout = p.layout
        inc p.requestGen
        p.sourceGen = p.requestGen
        p.samplesGen = p.requestGen # the first new tile replaces those from before
        p.pending = ReadRequest()
        inc p.revision
        state.readers[k].show(ReaderSource(gen: p.sourceGen, file: s.filePtr, path: s.path,
          size: s.size, traces: s.gathers[g].traces, filter: p.layers[0].filter,
          order: p.layers[0].order))
      else:
        state.newSource(k)
  state.joining.paused.setLen 0

proc onTheMap(state: AppState; files: openArray[JoinFile]): string =
  ## What of the survey files `files` is on the map now, in a sentence.
  var counts: array[PointRole, int]
  var names, tables: seq[string]
  for f in files:
    if f.kind == jkCsv: tables.add f.path.extractFilename
    else:
      let i = state.survey.findFile(f.path)
      if i >= 0:
        names.add f.path.extractFilename
        for r in PointRole: counts[r] += state.survey.layers[i].points[r].len
  result = if names.len == 0: "No point of the survey files is on the map."
    else: "On the map: " & plural(counts[prSource], "source point") & " and " &
      plural(counts[prReceiver], "receiver point") & " (" & names.join(", ") & ")."
  if tables.len > 0:
    result.add " " & (if tables.len == 1: "The CSV table " else: "The CSV tables ") &
      tables.join(", ") & (if tables.len == 1: " is" else: " are") & " matched to the " &
      "traces but not drawn on the map yet."

proc finishImport(state: var AppState) =
  ## The import ends once its match is over and its files are on the map:
  ## what it did, the points on the map and the traces matched, is said in
  ## the log and kept for the dialog.
  template j: untyped = state.joining
  var words = j.words
  if j.outcome != joCancelled and j.outcome != joFailed:
    words.insert(state.onTheMap(j.files), 0)
  let i = state.findSession(j.session)
  let unmatched = if j.outcome == joJoined: j.plan.unmatched.len else: 0
  case j.outcome
  of joJoined, joNothing:
    if i >= 0:
      let s = state.sessions[i]
      state.log.add(if j.outcome == joNothing: sevWarning else: sevInfo, s.name,
        (if j.outcome == joNothing: "The survey matches none of the traces of " & s.name
          else: "Survey imported for " & s.name) & " (" & fileNames(j.files) & "): " &
        words.join(" "))
  of joMapOnly:
    state.log.add(sevInfo, "survey", "Survey imported (" & fileNames(j.files) & "): " &
      words.join(" "))
  of joCancelled: state.log.add(sevInfo, j.name, words[0])
  of joFailed: state.log.add(sevError, j.name, words[0])
  of joNone: discard
  state.joinReport = JoinReport(serial: state.joinReport.serial + 1, session: j.session,
    name: j.name, outcome: j.outcome, words: words, unmatched: unmatched, heldAtJoin: j.held)
  state.joining = Joining()

proc endJoin(state: var AppState; outcome: JoinOutcome; error = "") =
  ## The match ends: the panels it paused read their file again, and what it
  ## did, or why it did nothing, is kept for the import's end (once its files
  ## are on the map: `finishImport`). A file joined keeps what it was joined
  ## with (its records are checked against that survey) and has its
  ## positions read again from its keys. A cancelled or failed import takes
  ## off the map what it put there, and stops the loads it started.
  template j: untyped = state.joining
  state.resumeReaders()
  let i = state.findSession(j.session)
  var words: seq[string]
  case outcome
  of joJoined, joNothing:
    words = planWords(j.plan, j.survey, j.options, j.units.survey)
    if i >= 0:
      let s = state.sessions[i]
      let before = state.joinedOf(s.id)
      if before >= 0: state.joins.delete(before)
      if outcome == joJoined:
        if j.joined: s.setKeysRevision(j.revision) # before the jobs below read the keys
        state.joins.add Joined(session: s.id, files: j.files, options: j.options,
          units: j.units, plan: j.plan, survey: j.survey, words: words, geometry: j.geometry)
        if j.plan.changes > 0: state.readPositions(s) # the map's, from the joined keys
        state.checkRecords(s)
      if j.survey.notes.len > 0:
        state.log.add(sevInfo, s.name, "The survey files' headers say: " &
          j.survey.notes.join("; ") & ".")
  of joCancelled:
    words = @["The survey import was cancelled: " & j.name & " is as it was, and so is the map."]
  of joFailed:
    words = @["The survey import failed: " & error & ". " & j.name & " is as it was, and " &
      "so is the map."]
  of joNone, joMapOnly: discard
  (j.job, j.outcome, j.words, j.waits) = (NoJob, outcome, words, true)
  if outcome in {joCancelled, joFailed}:
    for job in j.loads:
      discard state.jobs.cancel(job)
      state.droppedLoads.add job
    for id in j.added: discard state.survey.remove(id)
    if j.added.len > 0: state.map.followed(state.survey)
    j.loads.setLen 0
  if j.loads.len == 0: state.finishImport()

proc loaded(state: var AppState; job: JobId; layer: SurveyLayerId) =
  ## A load the import under way started is over (`layer` its layer;
  ## `NoSurveyLayer` when it failed): the import ends when it was the last.
  template j: untyped = state.joining
  let at = j.loads.find(job)
  if at >= 0:
    j.loads.delete(at)
    if layer != NoSurveyLayer: j.added.add layer
    if j.loads.len == 0 and j.waits: state.finishImport()

proc takeJoinPlan(state: var AppState; m: sink Msg) =
  ## The survey files read and what joining them does: when it changes some
  ## trace's keys, the readers of the file let go of it and the join's second
  ## job (`joinApplyWork`, the file to itself) does it; else it ends here.
  template j: untyped = state.joining
  if m.job != j.job or j.step != jpReading: return # (a join no longer wanted)
  let i = state.findSession(m.planSession)
  if i < 0: return # closed meanwhile: the job's end says so
  j.geometry = move m.geometry
  j.plan = move m.plan
  j.survey = move m.joinSurvey
  if j.plan.changes == 0:
    # Nothing to change (or nothing matched): the readers need not stop.
    let nothing = j.plan.found[prSource] + j.plan.found[prReceiver] == 0
    state.endJoin(if nothing: joNothing else: joJoined)
  else:
    let s = state.sessions[i]
    state.pauseReaders(s.path)
    let tableOnly = j.files.allIt(it.kind == jkCsv)
    j.job = state.jobs.submit(JobSpec(title: "Import the survey for " & s.name,
      lane: jlInteractive, exclusive: @[s.path]), joinApplyWork(s.filePtr, s.path, s.id,
      addr j.geometry[], j.plan.replace, tableOnly, state.jobs.holdRelease, state.inbox.poster))
    j.step = jpJoining

proc takeJoined(state: var AppState; m: Msg) =
  ## The join's second job did it (its end, `onFinished`, ends the join).
  template j: untyped = state.joining
  if m.job == j.job and j.step == jpJoining and m.joinedSession == j.session:
    j.joined = true
    j.held = m.heldAtJoin
    j.revision = m.joinedRevision
    if m.changed != j.plan.changes:
      state.log.add(sevWarning, j.name, "The import changed " & plural(m.changed, "trace") &
        " where " & $j.plan.changes & " were expected (parseSEG: " & $m.stats & ").")

proc selectUnmatched(state: var AppState; cmd: Command) =
  ## `ckSelectUnmatched`: the traces of a joined file the survey has no
  ## source or receiver for become the selection; the main panel shows the
  ## record of the first when it shows the file and none of them is on show.
  let j = state.joinedOf(cmd.unmatchedOf)
  let i = state.findSession(cmd.unmatchedOf)
  if j < 0 or i < 0:
    state.ignore(cmd, $cmd.unmatchedOf & " has no survey imported")
    return
  let s = state.sessions[i]
  var ids = newSeqOfCap[int](state.joins[j].plan.unmatched.len)
  for t in state.joins[j].plan.unmatched: ids.add s.base + t
  state.selection.select(ids, smReplace)
  let k = state.findPanel(MainPanel)
  let (shown, gather) = state.shownTraces(k)
  var onShow = 0
  if shown == i:
    for t in state.joins[j].plan.unmatched:
      if t in gather: inc onShow
  state.log.add(sevInfo, s.name, (if ids.len == 0: "No trace of " & s.name &
    " is unmatched." else: plural(ids.len, "unmatched trace") & " of " & s.name &
    " selected" & (if shown == i: ", " & $onShow & " in the record shown." else: ".")))
  if shown == i and onShow == 0 and ids.len > 0:
    let g = s.gatherOf(state.joins[j].plan.unmatched[0])
    if g >= 0: state.show(MainPanel, s.id, g)

# ------------------------------------------------------- the map's work --
# What the map shows besides the survey's layers, each made on a job that
# follows what it depends on (`followMapWork`, after every command and
# drained inbox): the relation records the planned spreads need.

func shownDomain*(state: AppState): RelationDomain =
  ## The domain of the record on show in the main panel: `rdReceiver` for a
  ## receiver gather, else `rdSource` (a shot, or no record).
  let g = state.selection.activeGather
  let i = state.findSession(g.file)
  if i >= 0 and g.gather in 0 ..< state.sessions[i].gathers.len and
      state.sessions[i].gathers[g.gather].kind == gkReceiver: rdReceiver
  else: rdSource

func shownPlace(state: AppState; s: Session; gather: int;
    domain: RelationDomain): Placed =
  ## For a record whose headers name no station of the role its relation
  ## record is found by (a shot's source, a receiver gather's receiver): the
  ## loaded survey files' station at the record's own place (`stationNear`).
  ## Not found when the headers name one, or nothing is there.
  let role = if domain == rdSource: prSource else: prReceiver
  let own = state.survey.findTraces(s.id)
  if own < 0: return
  template l: untyped = state.survey.layers[own]
  var placed = -1
  for t in s.gathers[gather].traces:
    if l.stationOf(role, t).known: return
    if placed < 0: placed = l.pointOf(role, t)
  if placed >= 0:
    let (found, st) = state.survey.stationNear(role, l.points[role].index.x(placed),
      l.points[role].index.y(placed))
    result = (found, st)

func shownSpread*(state: AppState): PlannedSpread =
  ## The spread planned for the record on show in the main panel (its
  ## receivers; for a receiver gather, the receiver's shots): that of the
  ## relation record its check found (`followRecordQc`, as the map's
  ## filters use it), in the loaded relation records or those made from
  ## the template; `record` -1 for none, and while the check runs.
  let domain = state.shownDomain
  result = PlannedSpread(domain: domain)
  let g = state.selection.activeGather
  template q: untyped = state.recordQc
  if q.key.file != g.file or q.key.gather != g.gather or q.key.domain != domain or
      q.record < 0:
    return
  result = state.survey.checkedSpread(state.spreads, domain, q.record)
  result.byPlace = q.byPlace

func spreadAt*(state: AppState; p: PointRef): PlannedSpread =
  ## The spread planned at map point `p` when records of the domain shown
  ## are keyed by its role (a source; in a file of receiver gathers, a
  ## receiver): its station's first record. `record` -1 for none.
  let domain = state.shownDomain
  result = PlannedSpread(domain: domain)
  let i = state.survey.find(p.layer)
  if p.role != (if domain == rdSource: prSource else: prReceiver) or i < 0 or
      p.point notin 0 ..< state.survey.layers[i].points[p.role].len:
    return
  template ps: untyped = state.survey.layers[i].points[p.role]
  let st = ps.station[p.point]
  # An open file's own point whose headers name no station: the survey file's at its place.
  let (has, key) = if st.known: (true, stationKeyOf(st))
                   else: state.survey.stationNear(p.role, ps.index.x(p.point), ps.index.y(p.point))
  if has: result = state.survey.plannedSpread(state.spreads, domain, key)

func wantedSpreads(state: AppState): SpreadInputs =
  ## The relation records the map's template box and its filter "missing
  ## from the template" need made: none while both are off or the loaded
  ## survey files have them; X records from the template when no X records
  ## are loaded (S and R files are); O records from the X records for a
  ## receiver gather when no O records are loaded. With the filter "spread
  ## not the template" on, the X records loaded compared with theirs.
  let planned = state.settings.map.templateBox or mfMissing in state.settings.map.filters
  let compare = mfSpreadDiffers in state.settings.map.filters
  if not (planned or compare): return
  var (sources, receivers, xs, os) = (false, false, false, false)
  var files: seq[tuple[path: string; size: int64; modified: Time]]
  for i in 0 ..< state.survey.layers.len:
    template l: untyped = state.survey.layers[i]
    if l.origin == loSurveyFile:
      files.add (l.path, l.size, l.modified)
      sources = sources or l.points[prSource].len > 0
      receivers = receivers or l.points[prReceiver].len > 0
      xs = xs or l.xRuns > 0
      os = os or l.relationRuns > l.xRuns
  if planned and not xs and sources and receivers:
    result = SpreadInputs(files: files, spec: state.settings.map.spreadTemplate,
      needs: {snGenerate})
  elif planned and xs and not os and state.shownDomain == rdReceiver:
    result = SpreadInputs(files: files, needs: {snReceivers})
  if compare and xs:
    result.files = files
    result.needs.incl snCompare

proc followSpreads(state: var AppState) =
  ## Makes the relation records the map needs on a job when what they are
  ## made from changed (the survey files, the template); the records made
  ## before stay until the new ones come, and go when none are needed.
  let want = state.wantedSpreads
  template sp: untyped = state.spreads
  if want == sp.inputs: return
  if sp.job != NoJob:
    discard state.jobs.cancel(sp.job)
    sp.replaced.add sp.job
  sp.job = NoJob
  sp.inputs = want
  if want.needs == {}:
    if not sp.relations.isNil or sp.words.len > 0 or sp.differing.len > 0:
      sp.relations = nil
      sp.words.setLen 0
      sp.differing.setLen 0
      sp.compared = 0
      inc sp.revision
  else:
    var paths: seq[string]
    for f in want.files: paths.add f.path
    sp.job = state.jobs.submit(JobSpec(title: "Plan the spreads for the map",
      lane: jlBackground, reads: paths), spreadWork(paths, want.spec, want.needs,
      state.inbox.poster))

proc takeSpreads(state: var AppState; m: sink Msg) =
  ## The relation records the job asked for last made.
  if m.job == state.spreads.job:
    state.spreads.relations = move m.spreads
    state.spreads.words = move m.spreadWords
    state.spreads.differing = move m.differing
    state.spreads.compared = m.compared
    inc state.spreads.revision

func wantsShots(state: AppState): bool =
  ## Whether the listed files' shots are read: while a survey file with
  ## sources is loaded (the map has nothing to match them to otherwise).
  for i in 0 ..< state.survey.layers.len:
    template l: untyped = state.survey.layers[i]
    if l.origin == loSurveyFile and l.points[prSource].len > 0: return true
  false

proc stillHangs(state: AppState; path: string): bool =
  ## Whether a shots job given up on file `path` (it did not answer) still
  ## runs: the file is not tried again meanwhile, as each try that hangs
  ## holds a thread until the drive answers.
  for s in state.shots.stuck:
    if s.path == path and state.jobs.workingOn(s.job): return true

proc queueShots(state: var AppState) =
  ## The listed files whose shots are to be read: seismic, steady, not read
  ## as they are now and not waiting already (later, for one a try given up
  ## on still hangs); and those no longer listed forgotten. Once per change
  ## of the list's entries.
  template x: untyped = state.shots
  if x.listedRev == state.files.entriesRev: return
  x.listedRev = state.files.entriesRev
  var listed: HashSet[string]
  for i in 0 ..< state.files.entries.len:
    template e: untyped = state.files.entries[i]
    if e.kind.isSeismic:
      listed.incl e.path
      if e.status == fsSteady and e.path notin x.queued:
        let now = e.path in x.files and x.files[e.path].size == e.size and
          x.files[e.path].modified == e.modified
        if not now:
          if state.stillHangs(e.path): x.later.add (e.path, fs.now() + RetryAfter)
          else: x.pending.add e.path
          x.queued.incl e.path
  var gone: seq[string]
  for path in x.files.keys:
    if path notin listed: gone.add path
  x.forget(state.survey, gone)
  if x.started == MonoTime() and x.pending.len > 0: x.started = fs.now()

proc followShots(state: var AppState) =
  ## Reads the listed files' shots on background jobs, a batch at a time,
  ## while the map can use them (`wantsShots`); a new listing starts again;
  ## a job that does not answer is given up, the file it was on tried again
  ## later and the rest read by the next job.
  template x: untyped = state.shots
  if x.gen != state.files.gen: # another listing
    if x.job != NoJob:
      discard state.jobs.cancel(x.job)
      x.replaced.add x.job
      x.givenUp.add x.job
    x = ShotIndex(gen: state.files.gen, replaced: move x.replaced, stuck: move x.stuck,
      givenUp: move x.givenUp, revision: x.revision + 1, listedRev: -1,
      surveyRev: state.survey.revision)
  if x.surveyRev != state.survey.revision: x.match(state.survey)
  if not state.wantsShots: return
  state.queueShots()
  let now = fs.now()
  var i = 0
  while i < x.later.len:
    if now >= x.later[i].at:
      let path = x.later[i].path
      if not state.stillHangs(path): # (else once that try is back)
        x.stuck.keepItIf(it.path != path)
        x.pending.add path
        x.later.delete(i)
        continue
    inc i
  if x.job != NoJob:
    let info = state.jobs.info(x.job)
    if info.isSome and info.get.state == jsRunning and
        info.get.notAnsweringFor(now) >= StallAfter:
      # The file it is on does not answer: tried again later, the rest now.
      discard state.jobs.cancel(x.job)
      x.replaced.add x.job
      x.givenUp.add x.job
      if x.jobPaths.len > 0:
        x.stuck.add (x.jobPaths[0], x.job)
        x.later.add (x.jobPaths[0], now + RetryAfter)
        x.pending.insert(x.jobPaths[1 .. ^1], 0)
      x.job = NoJob
      x.jobPaths.setLen 0
  # A job given up holds a thread while its drive does not answer: no more
  # than `MaxHanging` of them; the next starts when one comes back.
  if x.givenUp.len > 0: x.givenUp.keepItIf(state.jobs.workingOn(it))
  let waiting = x.job == NoJob and x.pending.len > 0 and x.givenUp.len >= MaxHanging
  if waiting != x.waiting:
    x.waiting = waiting
    inc x.revision
  if x.job == NoJob and x.pending.len > 0 and not waiting:
    let n = min(ShotBatch, x.pending.len)
    x.jobPaths = x.pending[0 ..< n]
    x.pending.delete(0 ..< n)
    x.job = state.jobs.submit(JobSpec(title: "Find the shots in the folder's files",
      lane: jlBackground, reads: x.jobPaths), shotsWork(x.gen, x.jobPaths, state.indexCache,
      state.inbox.poster))

proc takeShots(state: var AppState; m: sink Msg) =
  ## A listed file's shots, read by a job of this listing.
  template x: untyped = state.shots
  if m.shotsGen == x.gen:
    let path = m.shots.path
    x.queued.excl path
    x.take(state.survey, move m.shots)
    if x.pending.len == 0 and x.jobPaths.len == 0 and x.later.len == 0: x.finished = fs.now()

func qcRelations(state: AppState; domain: RelationDomain): (ref SurveyGeometry, string) =
  ## The relation records the record shown is checked against: the first
  ## loaded survey file's of `domain`, else those made from the template.
  let i = state.survey.listedLayer(domain)
  if i >= 0: (state.survey.layers[i].relations, state.survey.layers[i].name)
  elif not state.spreads.relations.isNil and state.spreads.relations[].relationCount(domain) > 0:
    (state.spreads.relations, "the template generated")
  else: (nil, "")

proc followRecordQc(state: var AppState) =
  ## Reads the record shown on a job for the map's filters when one of
  ## `TraceFilters` is on, or the template box (which draws the relation
  ## record the check finds), and the record (its file, its keys, the
  ## relation records it is checked against, how its traces are matched to
  ## them, the station at its place) changed; what it found before goes.
  ## The samples are read only for a filter that needs them.
  template q: untyped = state.recordQc
  let g = state.selection.activeGather
  let i = state.findSession(g.file)
  let shown = i >= 0 and g.gather in 0 ..< state.sessions[i].gathers.len
  let filters = state.settings.map.filters * TraceFilters
  if (filters == {} and not state.settings.map.templateBox) or not shown:
    if q.job != NoJob:
      discard state.jobs.cancel(q.job)
      q.replaced.add q.job
    if q.job != NoJob or q.key.file != NoSession:
      q = RecordQc(replaced: move q.replaced, revision: q.revision + 1)
    return
  let s = state.sessions[i]
  let domain = state.shownDomain
  let (rel, against) = state.qcRelations(domain)
  let placed = state.shownPlace(s, g.gather, domain)
  let samples = filters * SampleFilters != {}
  let key = (s.id, g.gather, s.keysRevision, (if rel.isNil: nil else: cast[pointer](rel)),
    domain, state.settings.join.recordMatch, state.settings.join.traceMatch, placed, samples)
  if key == q.key: return
  if q.job != NoJob:
    discard state.jobs.cancel(q.job)
    q.replaced.add q.job
  q.key = key
  for m in TraceFilters: q.hits[m] = FilterHits(state: fsComputing)
  (q.record, q.byPlace) = (-1'i64, false)
  inc q.revision
  q.job = state.jobs.submit(JobSpec(title: "Check the record shown for the map's filters",
    lane: jlBackground, reads: @[s.path]), recordQcWork(s.filePtr, s.path, s.id, s.base,
    g.gather, s.gathers[g.gather].traces, domain, (if rel.isNil: nil else: addr rel[]), against,
    state.settings.join.recordMatch, state.settings.join.traceMatch, placed, samples,
    state.inbox.poster))
  if not rel.isNil: state.qcHeld.add (q.job, rel)

proc takeRecordQc(state: var AppState; m: sink Msg) =
  ## What the filters' job found in the record it read, while that record,
  ## as it is now, is the one shown.
  template q: untyped = state.recordQc
  if m.job == q.job and m.qcSession == q.key.file and m.qcGather == q.key.gather and
      m.qcKeys == q.key.keys:
    for f in TraceFilters: q.hits[f] = move m.qcHits[f]
    (q.record, q.byPlace) = (m.qcRecord, m.qcByPlace)
    inc q.revision

func filterHits*(state: AppState): array[MapFilter, FilterHits] =
  ## What each filter the settings show marks now (the others `fsOff`): in
  ## the record shown, its job's findings (`TraceFilters`), its traces
  ## killed or reversed, its seismic traces the map cannot place (no point
  ## of the role its traces differ in: their receiver, in a receiver gather
  ## their source); and the shots whose listed spread is not the template's.
  let on = state.settings.map.filters
  for f in TraceFilters * on: result[f] = state.recordQc.hits[f]
  let g = state.selection.activeGather
  let i = state.findSession(g.file)
  if i >= 0 and g.gather in 0 ..< state.sessions[i].gathers.len:
    let s = state.sessions[i]
    let traces = s.gathers[g.gather].traces
    for (f, edit) in [(mfKilled, teKilled), (mfReversed, teReversed)]:
      if f in on:
        result[f] = FilterHits(state: fsDone, note: "traces")
        if s.path in state.edits:
          for t in state.edits[s.path].listIn(edit, traces): result[f].traces.add s.base + t
        result[f].count = result[f].traces.len
    if mfNoPosition in on:
      let role = if state.shownDomain == rdReceiver: prSource else: prReceiver
      result[mfNoPosition] = FilterHits(state: fsDone, note: "seismic traces whose " & $role &
        " the map cannot place")
      if state.survey.findTraces(s.id) < 0:
        (result[mfNoPosition].state, result[mfNoPosition].note) = (fsComputing, "")
      else:
        for t in traces:
          if s.file.index.isSeismic(t):
            var placed = false
            for p in state.survey.tracePointsOf(s.base + t):
              if p.role == role: placed = true
            if not placed: result[mfNoPosition].traces.add s.base + t
        result[mfNoPosition].count = result[mfNoPosition].traces.len
  else:
    for f in [mfKilled, mfReversed, mfNoPosition]:
      if f in on: result[f] = FilterHits(state: fsNotChecked, note: "no record is shown")
  if mfSpreadDiffers in on:
    template sp: untyped = state.spreads
    result[mfSpreadDiffers] = if snCompare notin sp.inputs.needs:
        FilterHits(state: fsNotChecked, note: "no relation (X) file is loaded")
      elif sp.job != NoJob: FilterHits(state: fsComputing)
      else: FilterHits(state: fsDone, count: sp.differing.len, note: "shots of the " &
        $sp.compared & " X records")
    if sp.job == NoJob:
      for d in sp.differing: result[mfSpreadDiffers].sources.add d.source

proc followMapWork(state: var AppState) =
  ## After every command and drained inbox: the map's jobs follow what they
  ## depend on.
  state.followSpreads()
  state.followShots()
  state.followRecordQc()

proc endMapWork(state: var AppState; job: JobInfo): bool =
  ## A job of the map's ended: forgotten, a failure said; false when `job`
  ## is none of them.
  if job.abandoned: # its work still runs, and reads them: kept until it is back
    for c in state.qcHeld:
      if c.job == job.id: state.leftChecks.add c
  state.qcHeld.keepItIf(it.job != job.id) # the relations it read
  template q: untyped = state.recordQc
  let gone = q.replaced.find(job.id)
  if gone >= 0:
    q.replaced.delete(gone)
    return true
  if job.id == q.job:
    q.job = NoJob
    if job.state in {jsFailed, jsCancelled}:
      for f in TraceFilters:
        if q.hits[f].state == fsComputing:
          q.hits[f] = FilterHits(state: fsNotChecked, note: (if job.state == jsFailed:
            "the record could not be read: " & job.error else: "the check was cancelled"))
      inc q.revision
    return true
  template x: untyped = state.shots
  let given = x.replaced.find(job.id)
  if given >= 0:
    x.replaced.delete(given)
    return true
  if job.id == x.job:
    # Its files not answered (it failed, or was cancelled in the Jobs
    # window): tried again later.
    if job.abandoned: x.givenUp.add job.id # its work still hangs
    x.job = NoJob
    for path in x.jobPaths: x.later.add (path, fs.now() + RetryAfter)
    x.jobPaths.setLen 0
    if job.state == jsFailed:
      state.log.add(sevWarning, "map", "The shots in the folder's files could not all be " &
        "read: " & job.error & ". They are tried again in a minute.")
    return true
  let replaced = state.spreads.replaced.find(job.id)
  if replaced >= 0:
    state.spreads.replaced.delete(replaced)
    return true
  result = job.id == state.spreads.job
  if result:
    state.spreads.job = NoJob
    if job.state == jsFailed:
      state.spreads.words = @["The planned spreads could not be made: " & job.error & "."]
      inc state.spreads.revision
      state.log.add(sevWarning, "map", state.spreads.words[0])

proc onFinished(state: var AppState; job: JobInfo) =
  ## Says how a job ended, and lets go of what the state kept for it.
  if state.endMapWork(job): return
  if job.id == state.joining.job:
    case job.state
    of jsDone:
      if state.joining.step == jpJoining:
        if state.joining.joined: state.endJoin(joJoined)
        else: state.endJoin(joFailed, "it ended without matching")
      else: state.endJoin(joCancelled) # the file was closed before its plan came
    of jsCancelled: state.endJoin(joCancelled)
    of jsFailed: state.endJoin(joFailed, job.error)
    of jsQueued, jsRunning: discard
  if job.id == state.preparing.job: # quietly: the user did not ask
    if job.state == jsFailed: state.prepareFailed = state.preparing.path
    state.preparing = (NoJob, "")
    return
  if job.abandoned: # its work still runs, and reads them: kept until it is back
    for c in state.checking:
      if c.job == job.id: state.leftChecks.add c
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
        let dropped = state.droppedLoads.find(job.id)
        if dropped >= 0: state.droppedLoads.delete(dropped)
        state.loaded(job.id, NoSurveyLayer)
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
      state.release(move state.closing[i].session) # nothing reads it now
      state.closing.delete(i)
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
      # The folder listed last, gone since (a drive not there at start): said, not an error.
      let severity = if job.id == state.quietScan: sevInfo else: sevError
      state.log.add(severity, "files", "Cannot list " & state.files.title & ": " & job.error &
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

proc preparedCurrent(state: AppState): bool =
  ## Whether the file prepared is as the folder's watch saw it last: steady,
  ## with the size and time it was opened with.
  let s = state.prepared.session
  let e = state.files.find(s.path)
  e >= 0 and state.files.entries[e].status == fsSteady and
    state.files.entries[e].size == s.size and state.files.entries[e].modified == s.modified

proc showPath(state: var AppState; k: int; path: string; gather = 0; follow = false;
    by: CommandOrigin) =
  ## Shows the file at `path` (canonical) in `panels[k]`, in place of the
  ## one it shows, as `by` asked: at once when it is open, else once an open
  ## job opened it (at `gather`; with `follow`, only if it is whole). An open started
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
      if keeps(by): state.opening[o].by = by # the user asked for it too
    elif not state.prepared.session.isNil and state.prepared.session.path == path and
        state.preparedCurrent():
      # Opened already, in the background, and not changed since: shown at once.
      let job = state.prepared.job
      var s = move state.prepared.session
      state.prepared = (NoJob, nil)
      state.opening.add Pending(job: job, path: path, panel: panel, gather: gather,
        follow: follow, by: by)
      state.adopt(s, job)
      state.opening.keepItIf(it.job != job)
    else:
      if not state.prepared.session.isNil and state.prepared.session.path == path:
        state.release(move state.prepared.session) # changed since it was prepared
        state.prepared = (NoJob, nil)
      let job = state.jobs.submit(JobSpec(title: "Open " & path.extractFilename,
        lane: jlInteractive, reads: @[path]), openFileWork(path, state.inbox.poster,
        indexCacheFile(state.indexCache, path), whole = follow))
      state.opening.add Pending(job: job, path: path, panel: panel, gather: gather,
        follow: follow, by: by)

proc showListedShot(state: var AppState; cmd: Command): bool =
  ## `ckShowPoints` on a survey source no open file's trace was recorded at:
  ## the main panel shows the record a listed file holds of its shot (opened
  ## first, as the user's click asked); false when no listed file has one.
  let k = state.findPanel(MainPanel)
  for p in cmd.points:
    let places = state.shots.shotsAt(p)
    if places.len > 0 and k >= 0:
      let (path, gather, _) = places[0]
      var i = -1
      for j, s in state.sessions:
        if s.path == path: i = j
      if i >= 0:
        let g = clamp(gather, 0, max(0, state.sessions[i].gathers.high))
        if state.shownFile(k) != i: state.showReplacing(k, state.sessions[i].id, g)
        else: state.show(MainPanel, state.sessions[i].id, g)
      else:
        state.jump = ("", -1, -1)
        state.showPath(k, path, gather, by = cmd.origin)
      return true
  false

proc startListing(state: var AppState; paths: seq[string]; title, folder: string;
    by: CommandOrigin) =
  ## Lists the files `paths` (canonical) name in the file list, in place of
  ## what it listed, as `by` asked: a scan on the background lane
  ## (`scanWork`). The file chosen stays chosen.
  if state.files.job != NoJob:
    discard state.jobs.cancel(state.files.job)
    state.oldScans.add state.files.job # it ends quietly
  state.watch.unwatch() # until the scan is done
  state.listedBy = by
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
    state.change(state.listedBy, st): st.recentFolders.addRecent(m.listFolder, MaxRecent)
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
      if k >= 0 and target.len > 0: state.showPath(k, target, by = state.listedBy)

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
    state.showPath(k, path, follow = true, by = coWindow) # the user's own setting

proc showAgain(state: var AppState; path: string) =
  ## Shows `path` again in the panels that wait for it (`reopens`).
  var waiting: seq[Reopen]
  for r in state.reopens:
    if r.path == path: waiting.add r
  state.reopens.keepItIf(it.path != path)
  for r in waiting:
    let k = state.findPanel(r.panel)
    if k >= 0: state.showPath(k, path, r.gather, by = state.openedBy.getOrDefault(path))

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

proc retry(state: var AppState; k: int) =
  ## Opens or reads again what `panels[k]` waits for: a new open of the file
  ## it is to show (the one before, cancelled, is left by its lane when it
  ## does not answer), or a new reader for the file it shows.
  template p: untyped = state.panels[k]
  var at = -1
  for j, o in state.opening:
    if not o.unwanted and (o.panel == p.id or (o.panel == NoPanel and p.id == MainPanel)):
      at = j
  if at >= 0:
    let (path, gather, follow, by) = (state.opening[at].path, state.opening[at].gather,
      state.opening[at].follow, state.opening[at].by)
    state.opening[at].unwanted = true
    discard state.jobs.cancel(state.opening[at].job)
    state.log.add(sevInfo, path.extractFilename, "Opening " & path.extractFilename & " again.")
    state.showPath(k, path, gather, follow, by) # the same open: whoever asked for it
    return
  if state.shownFile(k) >= 0:
    if not state.readers[k].isNil and state.readers[k].silentFor >= StallAfter:
      state.readers[k].abandon()
    state.newSource(k) # read again, at the same scales

proc prepareNext(state: var AppState) =
  ## Prepares the file the user is likely to step to next (`ckPrepare`), with
  ## "Prepare the next file" on (`Settings.files.prepareNext`): a background
  ## job opens it and reads its first view (`prepareWork`) once the main
  ## panel shows its own file with a tile (the drive is the user's first),
  ## and its session is kept unshown (`prepared`) until `showPath` takes it.
  ## What is no longer wanted is cancelled or closed. Only a listed seismic
  ## file of at most `MaxPrepareBytes`, not open, not opening, is prepared.
  let want = if state.settings.files.prepareNext: state.prepareWanted else: ""
  if state.preparing.job != NoJob and state.preparing.path != want:
    discard state.jobs.cancel(state.preparing.job) # its file is dropped if it comes
  if not state.prepared.session.isNil and state.prepared.session.path != want:
    state.release(move state.prepared.session) # nothing else has it
    state.prepared = (NoJob, nil)
  if want.len == 0 or want == state.prepareFailed or state.preparing.job != NoJob or
      not state.prepared.session.isNil:
    return
  if state.sessions.anyIt(it.path == want) or state.opening.anyIt(not it.unwanted):
    return
  let e = state.files.find(want)
  if e < 0 or not state.files.entries[e].kind.isSeismic or
      state.files.entries[e].status != fsSteady or state.files.entries[e].size > MaxPrepareBytes:
    return # (a file being written is opened when it is shown)
  let k = state.findPanel(MainPanel)
  if k < 0 or not state.panels[k].laidOut or state.tiles[k].len == 0: return
  let r = state.panels[k].pending # the first view's read, as the next file is shown alike
  let job = state.jobs.submit(JobSpec(title: "Prepare " & want.extractFilename,
    lane: jlBackground, reads: @[want]), prepareWork(want, state.inbox.poster,
    indexCacheFile(state.indexCache, want), r.first .. r.last, r.stride,
    r.firstSample ..< r.firstSample + r.samples))
  state.preparing = (job, want)

proc takePrepared(state: var AppState; s: sink Session; job: JobId) =
  ## The file a prepare job opened: kept unshown while it is still wanted,
  ## else closed (here, on this thread).
  if state.settings.files.prepareNext and s.path == state.prepareWanted and
      s.file.kind != skUnknown and not state.sessions.anyIt(it.path == s.path):
    state.prepared = (job, s)
  else:
    state.release(s)

proc retryListing(state: var AppState) =
  ## Lists the folder again: its listing, or the watch's look at it, did
  ## not answer. A look that does not answer leaves its thread to end on its
  ## own; a new watch takes over.
  template f: untyped = state.files
  if f.title.len == 0: return
  if state.watch.lookingFor >= StallAfter:
    state.watch.stop(getMonoTime()) # left: its memory stays with it
    state.watch = FolderWatch()
    state.watchOpen()
  let paths = if f.folder.len > 0: @[f.folder] else: f.asked
  state.log.add(sevInfo, "files", "Listing " & f.title & " again.")
  state.startListing(paths, f.title, f.folder, state.listedBy) # the same listing

proc apply*(state: var AppState; cmd: Command) =
  ## Carries out `cmd`. Anything slow it starts runs as a job; `drainInbox`
  ## takes in the result.
  assertUiThread()
  state.applyCommand(cmd)
  state.map.followed(state.survey) # a layer went (a file closed, a survey file unloaded)
  state.relink()
  state.followInspect()
  state.followMapWork()

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
        state.opening.add Pending(job: job, path: path, by: cmd.origin)
  of ckBrowse:
    var paths: seq[string]
    for p in cmd.paths:
      if p.len > 0: paths.add canonical(p)
    if paths.len == 0: state.ignore(cmd, "no file or folder was named")
    else:
      # A copy: as an argument beside `paths`, `paths[0]` would be moved.
      let title = if paths.len == 1: paths[0] else: $paths.len & " chosen files"
      state.loadNamed = paths # the survey files among them are loaded once listed
      state.startListing(paths, title, "", cmd.origin)
      state.quietScan = if cmd.quiet: state.files.job else: NoJob
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
        state.showPath(k, path, by = cmd.origin)
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
        state.showPath(k, path, by = cmd.origin)
      let folder = path.parentDir
      if cmd.listFolder and state.files.folder != folder:
        state.startListing(@[folder], folder, folder, cmd.origin)
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
        state.settleGain(k, cmd.origin)
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
      state.settleGain(k, cmd.origin)
  of ckSettings:
    let (s, dropped) = cleaned(cmd.settings)
    if dropped > 0:
      state.log.add(sevWarning, "settings", $dropped & " of the settings given could not " &
        "be used (a calibration that is not a positive number, an entry given twice, a " &
        "sort preset without a name or keys) and were left out.")
    let follow = s.files.followLatest and not state.settings.files.followLatest
    let raw = (rfRawAmplitude in s.readout) != (rfRawAmplitude in state.settings.readout)
    # The settings a window sends are those in effect with its change: only
    # that change is the user's (what an agent changed meanwhile is not).
    state.change(cmd.origin, x): x = carried(x, state.settings, s)
    if follow: state.followNewest() # the newest file whole now, at once
    state.prepareNext() # (turned on or off)
    if raw: # the tiles carry their raw samples, or no longer: made again from the samples held
      for k in 0 ..< state.panels.len: state.resample(k)
  of ckExportSettings:
    if not state.refusedExport(cmd):
      state.diskIo.replace(cmd.docPath, settingsDocument(state.kept),
        "the exported settings", done = "Settings exported to " & cmd.docPath & ".")
  of ckImportSettings:
    if cmd.docPath.len == 0: state.ignore(cmd, "no file was named")
    else:
      state.diskIo.read(cmd.docPath, rpImportSettings, MaxNifBytes)
      state.importsBy.add cmd.origin
  of ckLayout:
    if cmd.arrangement != state.arrangement:
      state.arrangement = cmd.arrangement
      if keeps(cmd.origin):
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
    let file = state.settingsFile
    if file.len > 0:
      # Not a name asked for before: the disk thread may not have written
      # that backup yet, and a second reset must not write over the first's.
      # The disk thread picks a name no file has (`fresh`): this thread never
      # looks at the disk, and a second reset never writes over the first's.
      state.diskIo.replace(backupName(file, now()), settingsDocument(state.kept),
        "a copy of the settings", done = "The settings before the reset are kept in ",
        fresh = true)
      state.log.add(sevInfo, "settings", "Settings reset to their defaults; a copy of the " &
        "settings before is kept beside them.")
    else:
      state.log.add(sevInfo, "settings", "Settings reset to their defaults.")
    state.change(cmd.origin, s):
      let was = s
      s = state.defaults
      s.recentFiles = was.recentFiles # memory, not preferences
      s.recentFolders = was.recentFolders
      s.window = was.window
  of ckDisplay:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    else:
      template p: untyped = state.panels[k]
      let was = p.layers[0].display
      let wasLimits = p.viewLimits(p.view.columns)
      let d = cmd.display.bounded # whoever sent it: the settings file takes it as it is
      p.layers[0].display = d
      inc p.revision
      if d.orientation != was.orientation:
        # Turned: the same traces and times, the plot's pixels along each
        # the other way round until the window says what they are now.
        swap(p.view.columns, p.view.rows)
      # what this command changed in the display; a new mode leaves the
      # gain as the user had it, whatever an agent made it meanwhile
      state.change(cmd.origin, s):
        s.plot.display = carried(s.plot.display, state.settings.plot.display, remembered(d))
      # New limits (a wiggle mode's widest view, the margin of the overlap,
      # a turn): the view stays where it is, a wider one (from density, or
      # a turn to fewer pixels along the traces) narrowed keeping its first
      # trace, and one that showed the whole record shows the whole of it
      # again; the frontend follows.
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
      state.settleGain(k, cmd.origin)
  of ckHeader:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif not cmd.header.auto and cmd.header.fields.len == 0:
      state.ignore(cmd, "a display header needs at least one field")
    else:
      var header = HeaderChoice(auto: cmd.header.auto) # each field once, as its menu gives
      for f in cmd.header.fields:
        if f notin header.fields: header.fields.add f
      state.panels[k].header = header
      state.change(cmd.origin, s): s.plot.header = header
      state.refetch(k, keepTiles = true)
  of ckSort:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    elif uniqueKeys(cmd.order) != state.panels[k].layers[0].order:
      let order = uniqueKeys(cmd.order) # each field once, as the sort dialog gives
      state.panels[k].layers[0].order = order
      state.change(cmd.origin, s):
        s.plot.order = order
        if order.len > 0 and presetOf(order, s.sortPresets) < 0:
          s.customOrder = order # the user's own keys, offered again
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
  of ckJoin:
    let i = state.findSession(cmd.joinFile)
    if i < 0 and cmd.joinFile != NoSession: state.ignore(cmd, $cmd.joinFile & " is not open")
    elif state.importing:
      state.ignore(cmd, "a survey import is under way: one at a time")
    elif cmd.joinFiles.len == 0: state.ignore(cmd, "no survey file was named")
    else: state.startJoin(i, cmd)
  of ckSelectUnmatched:
    state.selectUnmatched(cmd)
  of ckPrepare:
    state.prepareWanted = if cmd.path.len > 0: canonical(cmd.path) else: ""
    state.prepareNext()
  of ckRetry:
    if cmd.panel == NoPanel: state.retryListing()
    else:
      let k = state.findPanel(cmd.panel)
      if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
      else: state.retry(k)
  of ckStopReading:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif not state.readers[k].isNil:
      # Its late tiles answer an old request and are dropped; nothing is read
      # until Retry, another gather or another file.
      let name = state.windowTitle(cmd.panel)
      state.readers[k].abandon()
      inc state.panels[k].requestGen
      state.panels[k].pending = ReadRequest()
      inc state.panels[k].revision
      let i = state.shownFile(k)
      let file = if i >= 0: state.sessions[i].name else: "the file"
      state.unread.keepItIf(it.panel != cmd.panel)
      state.unread.add (cmd.panel, ucStopped, "Not reading " & file & ": the plot stopped " &
        "waiting for its drive, and shows what it had read.")
      state.log.add(sevInfo, "files", "The " & name & " window stopped waiting for the drive " &
        "of " & file & ": it shows what it had read. Retry reads again.")
  of ckInspect:
    state.inspect.parts = cmd.inspect # read for by `followInspect`, after every command
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
        for s in state.sessions:
          if state.joinedRelations(s.id) < 0: state.checkRecords(s)

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
  of rpLayouts:
    # Listed before the layouts saved since were written: they are kept.
    state.layoutList = m.layouts
    for l in state.savedLayouts: state.layoutList = state.layoutList.added(l)
  of rpLoadLayout, rpImportLayout: state.takeLayout(m)
  of rpImportSettings:
    var by = coWindow # the disk thread answers in the order it was asked
    if state.importsBy.len > 0:
      by = state.importsBy[0]
      state.importsBy.delete 0
    if m.readError.len > 0:
      state.log.add(sevError, "settings", "Cannot import the settings in " & m.readPath &
        ": " & m.readError & ".")
    else:
      var problems: seq[string]
      try:
        if m.docError.len > 0: raise newException(NifError, m.docError)
        state.change(by, s): # read over each, as over the settings in effect before
          problems.setLen 0
          s = cleaned(readSettings(m.doc, name, s, problems))[0]
        state.logProblems("settings", problems)
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
  # A job that does not answer: its lane goes on without it, a cancelled one is left.
  state.jobs.tend()
  var k = 0 # a reader of the Headers window left in a drive: gone once it has ended
  while k < state.leftInspectors.len:
    if state.leftInspectors[k].hasEnded: state.leftInspectors.delete(k)
    else: inc k
  # Finished jobs first: a job posts before it finishes, so every message of
  # a job seen finishing here is in the mail drained next.
  let finished = state.jobs.takeFinished()
  state.inbox.drainInto(state.mail)
  result = finished.len > 0 or state.mail.len > 0
  for m in state.mail.mitems:
    case m.kind
    of mkOpened:
      if m.job == state.preparing.job: state.takePrepared(move m.session, m.job)
      else: state.adopt(move m.session, m.job)
    of mkLog: state.log.add(move m.entry)
    of mkRead: state.takeIn(m)
    of mkListed: state.takeListed(move m)
    of mkWatched: state.takeWatched(move m)
    of mkSurvey: state.takeSurvey(move m.layer, m.job)
    of mkChecked: state.takeChecked(move m)
    of mkJoining: state.takeJoinPlan(move m)
    of mkJoined: state.takeJoined(m)
    of mkInspected: state.takeInspected(move m)
    of mkSpreads: state.takeSpreads(move m)
    of mkShots: state.takeShots(move m)
    of mkRecordQc: state.takeRecordQc(move m)
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
    of mkUnread:
      let k = state.findPanel(m.unreadPanel)
      if k >= 0 and m.unreadGen == state.panels[k].sourceGen:
        state.unread.keepItIf(it.panel != m.unreadPanel)
        state.unread.add (m.unreadPanel, m.cause, m.why)
        inc state.panels[k].revision
    of mkTraceRead:
      state.traceReads.add (m.job, m.readKeys, move m.headerRows)
      if state.traceReads.len > MaxTraceReads: state.traceReads.delete(0) # never taken
    of mkTile:
      let k = state.findPanel(m.tile.panel)
      if k >= 0 and m.tile.request.gen == state.panels[k].requestGen:
        state.unread.keepItIf(it.panel != m.tile.panel) # read again
        state.timeRead(m.tile)
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
        state.settleGain(k, coWindow) # the data's own: kept when the user's Fixed waits for it
        # The view may have moved on while the tile was read: the read-ahead
        # is filled again around it now.
        state.requestView(k)
  state.mail.setLen 0
  for job in finished:
    state.onFinished(job)
  if state.leftChecks.len > 0: state.leftChecks.keepItIf(state.jobs.workingOn(it.job))
  state.prepareNext() # (once the main panel has its tile; or a prepare ended)
  state.map.followed(state.survey) # a layer came, or went with a file
  state.relink()
  state.followInspect()
  state.followMapWork()
