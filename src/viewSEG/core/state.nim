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

import std/[algorithm, math, monotimes, options, os, sequtils, sets, strutils, tables, times]
from std/unicode import runeSubStr, cmpRunesIgnoreCase
import parseSEG
from processSEG/core/types import sameInterval
from processSEG/core/workspace import Workspace, initWorkspace
from processSEG/pipeline import Pipeline, items, initPipeline
from processing import changesSamples, ownShownWords, reverseShownWords
from editmarks import shiftNote
from shotfollow import ShotQuery, ShotMatch
import signatures, sweeppairs
import analysis, analysisreader, closer, compare, comparejobs, components, correlatejobs,
  correlateread, cutgather, cutgatherjobs, diskio,
  edits, filejobs,
  filelist, filememory, filesystem, firstbreakjobs, firstbreaks, identity, inbox, inspector, jobs,
      join, layouts, leapfile, log,
  mapstate, memoryjobs, panels, persist, pick, project, projectjobs, projectnif,
    outputbinary, outputnames, outputtext, reader,
  recordingkind, recordqc, referencejobs, references, selection, session, settings,
      shotfollowtarget, shotlog,
  ofile, shotlogjobs, shotlogsps, shotselect, shotselectjobs, shotspsjobs,
  shots, spectra,
  spectrumreader, spread, stationmoves, survey, surveyjobs, threads, tiles, traceids,
      vendorfieldjobs,
  traceorder, treatas, vendorfieldlist, vendorjobs, vendormaps, vibprofile, watch, zoom

export analysis, compare, edits, filelist, filememory, firstbreaks, identity, inbox, jobs, join,
    shotfollowtarget, shotselect,
    layouts, log,
  mapstate, panels, persist, pick, project, outputnames, recordqc, references, selection, session,
    settings,
  shots, spectra, spread, survey, threads, tiles, traceids, vendorfieldlist, vendormaps, zoom
export CutOptions, CutOrder, CutStandard, initCutOptions
export InspectPart, ChosenBy, Chosen, Inspection, MaxInspected, MaxInspectedValues, MaxTableRows
export tracetable
export WatchInterval

const
  MainPanel* = PanelId(1)
    ## The panel `initAppState` makes; opened files appear in it.
  MaxTiles* = 4          ## tiles kept per panel, newest last
  FloatValues* = 32_768  ## values in view the Float gain takes its level from, at most
  MaxNotices* = 20       ## notices kept
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
  NamePatternAction* = enum
    ## What a name-pattern command does.
    npaSave = "save"
      ## add the pattern, or replace the one with the same label, case ignored
    npaDelete = "delete"
      ## forget the pattern named
    npaChoose = "choose"
      ## use the pattern named; an empty name is today's naming

  OutputTextAction* = enum
    ## What an output-text command does.
    otaSave = "save"
      ## add the template, or replace the one with the same name, case ignored
    otaDelete = "delete"
      ## forget the template named
    otaChoose = "choose"
      ## use the template named; an empty name is the writer's own text

  OutputBinaryAction* = enum
    ## What an output-binary command does.
    obaSave = "save"
      ## add the set, or replace the one with the same name, case ignored
    obaDelete = "delete"
      ## forget the set named
    obaChoose = "choose"
      ## use the set named; an empty name sets no binary header value

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
    ckProcessing = "processing"          ## the filters a panel's traces go through, raw or processed
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
    ckOwnFilter = "own filter"           ## set or remove a trace's own frequency filter
    ckTimeShift = "time shift"           ## set or remove a trace's time shift
    ckUndoEdit = "undo edit"             ## take back the newest change to the edits of a panel's file
    ckRedoEdit = "redo edit"             ## make the change to its edits undone last again
    ckClearEdits = "clear edits"         ## take every edit of a panel's file away
    ckExportEdits = "export edits"       ## write the edits of a panel's file to a file of the user's
    ckImportEdits = "import edits"       ## take in edits for a panel's file from such a file
    ckFileMemory = "list file memory"    ## read what is remembered about files, for its window
    ckForgetFiles = "forget files"       ## remove what is remembered about some files
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
    ckSelectShotRows = "select shot log rows"
      ## choose rows of a loaded shot log: their points on the map are selected, and with
      ## `shotTraces` the traces of the file shown that belong to those shots, the first shown
    ckJoin = "join geometry" ## import a survey: on the map, matched to a file's traces
    ckSelectUnmatched = "select unmatched"
      ## select the traces a join left unmatched
    ckSurveyUnits = "read survey units"
      ## read what survey files' headers say of their unit, for the import's window
    ckChooseUnit = "choose unit"
      ## the unit of a survey's or a seismic file's coordinates, chosen by hand or taken back
    ckRetry = "retry" ## open, read or list again what does not answer
    ckStopReading = "stop reading" ## leave a panel's read that does not answer
    ckPrepare = "prepare" ## the file the user is likely to step to next
    ckOpenPair = "open pair"
      ## show the other file of a vibrator signature file's sweep (a `.dat`'s `.vib`, a
      ## `.vib`'s `.dat`) in the panel, in place of the one it shows; searched for when the list
      ## does not know it
    ckInspect = "headers shown" ## what the Headers window has on screen, to be read for it
    ckSpectrum = "open spectrum" ## an FFT window of traces: their amplitude spectrum, raw and processed
    ckSpectrumDisplay = "spectrum display"
      ## how a spectrum window shows its spectrum, over which time; the live panel frozen or not
    ckCloseSpectrum = "close spectrum" ## close an FFT window
    ckSpectrumPanel = "spectrum panel" ## the live spectrum panel on screen, or not
    ckAuxWindow = "aux window"
      ## the Aux window open or closed: its panel then shows the auxiliary traces of the
      ## record the Seismic window shows, or nothing
    ckSpectrumCursor = "spectrum cursor"
      ## hold a spectrum window's cursor at a frequency bin and curve, or let it go
    ckStepTrace = "step trace"
      ## select the next or previous trace of the record shown (Alt + arrow)
    ckOpenPlot = "open plot" ## New plot: an analysis window of traces (a spectrogram, ...)
    ckPlotDisplay = "plot display" ## an analysis window's settings, frozen or not
    ckPlotCursor = "plot cursor" ## where an analysis window's cursor is held
    ckClosePlot = "close plot" ## close an analysis window
    ckDisplayPreset = "display preset"
      ## draw a panel as a named display says; keep, rename or forget one
    ckNamePattern = "name pattern"
      ## save a file-name pattern into the project, delete one by its label,
      ## or choose one (an empty label is today's naming)
    ckOutputText = "output text"
      ## save a SEG-Y text header template into the project, delete one by its
      ## name, or choose one (an empty name is the writer's own text)
    ckOutputBinary = "output binary"
      ## save a SEG-Y binary header set into the project, delete one by its
      ## name, or choose one (an empty name sets no binary header value)
    ckTheme = "theme" ## the theme the program is drawn in, as View > Theme picks it
    ckNewProject = "new project"
      ## make a project folder (Project > New project) and open it: the session's files stay open
    ckOpenProject = "open project"
      ## open a project (its folder, or the project.nif in it): the files open and the survey
      ## on the map are closed, and the project's opened
    ckCloseProject = "close project"
      ## close the project open: back to working without one (its files and survey closed)
    ckProjectFolder = "project folder"
      ## add or remove a data folder of the project open, or say where a missing one is now
    ckClearSurvey = "clear survey"
      ## take the imported survey away: the open files' traces have their own
      ## coordinates again, the map its survey files out, the project (if open)
      ## no survey; an import under way is cancelled. No file is changed
    ckUpdateSurvey = "update survey"
      ## copy the project's survey files again from the originals that changed, and read them
    ckReopen = "reopen"
      ## open a file again with other options (its standard, its headers all checked,
      ## two's-complement mantissas, mapped or not), in the panels that show it
    ckVendorMap = "vendor map"
      ## the project's vendor map: a map's name, "automatic" or "none" (a project must be open)
    ckReloadVendors = "reload vendor maps"
      ## read the vendor header maps again (the project's, the user's, the program's, the
      ## environment's): files open show the new decode
    ckListReferences = "list references"
      ## read the reference archive in force (and the main one, when a project is open)
    ckStoreReference = "store reference"
      ## store a trace (as recorded, reversed when the trace is), cut to a time window, as a named reference
    ckGenerateReference = "generate reference"
      ## make a sweep with processSEG and store it as a named reference
    ckPilotReference = "pilot reference"
      ## store a rule as a named reference: a trace of the record (an auxiliary
      ## one, or a numbered one) and a window of it, taken from each record
      ## when the reference is the chosen one
    ckPilotPreview = "pilot preview"
      ## ask for the pilot a rule would take from the record on show (the
      ## Generate dialog's preview); read off the UI thread
    ckSelectReference = "select reference"
      ## the reference the plots use; "" is none (a correlation draws nothing;
      ## a vibrator signature uses the file's pilot)
    ckDeleteReference = "delete reference"
      ## remove a reference from the archive in force
    ckRenameReference = "rename reference"
      ## give a reference another name (a name already used is refused)
    ckCopyReference = "copy reference"
      ## copy a reference of the main archive into the project open
    ckViewReference = "view reference"
      ## open a reference in its own window: samples against time, and its
      ## amplitude spectrum. The file under QC stays open
    ckCloseRefView = "close reference view"
      ## close that window
    ckSetCompare = "set compare"
      ## copy one trace into compare slot A or B. The slot keeps that copy:
      ## it does not follow the plot, the selection or the file. Filling the
      ## second slot opens the compare window
    ckClearCompare = "clear compare"
      ## clear compare slot A, B, or both
    ckSwapCompare = "swap compare"
      ## swap compare slots A and B
    ckCompareDisplay = "compare display"
      ## what the compare window draws, and how B is aligned
    ckCompareWindow = "compare window"
      ## open or close the compare window
    ckCorrelate = "correlate"
      ## show the correlated record of the file the Seismic window shows, or the raw one
    ckTreatAs = "treat as"
      ## force the kind of recording and the order of the traces a file is treated as, or give
      ## them back to what is told from the file; remembered for the file
    ckFileAuxMark = "file aux mark"
      ## mark an auxiliary trace position of a file for correlation (with its shift), make it
      ## explicitly not marked, or forget the mark; remembered with the file's edits
    ckProjectAuxMark = "project aux mark"
      ## mark an auxiliary trace position for correlation in every file of the project (with
      ## its shift), or forget the mark; kept in the project
    ckSubfolders = "subfolders"
      ## the file list includes the subfolders' files, or not; the folder is listed again
    ckVibProfile = "vibrator profile"
      ## keep these settings as the project's vibrator QC profile
    ckVibWeights = "vibrator weights"
      ## keep these as the project's vibrator QC job weights
    ckImportShotLog = "import shot log"
      ## read a shot log and keep it; stored in the project when one is open and writable
    ckRemoveShotLog = "remove shot log"
      ## drop a loaded shot log; a writable project also drops its copy
    ckRemapShotLog = "remap shot log"
      ## parse a loaded shot log again with another map, on a job
    ckEditShotCell = "edit shot log cell"
      ## overlay one cell of a loaded shot log; a writable project writes the copy
    ckUndoShotEdit = "undo shot log edit"
      ## put back the text a cell of a loaded shot log had before the last edit
    ckRedoShotEdit = "redo shot log edit"
      ## apply again a shot-log cell edit that was undone
    ckAddLeap = "add leap second"
      ## add a leap second at the first of a month, after the last entry
    ckRemoveLeap = "remove leap second"
      ## remove the last leap second, when it was added here
    ckReloadLeaps = "reload leap seconds"
      ## read the leap-second file again
    ckResetLeaps = "reset leap seconds"
      ## the leap-second table shipped with the program
    ckCutGather = "slice by shot log"
      ## slice the continuous recording the Seismic window shows into one record per shot of a
      ## loaded shot log, and write them to a new file, on a job
    ckExportShotSps = "export SPS"
      ## write the shots of a loaded shot log, with its edits, as an SPS file of source points,
      ## on a job; an existing file is never replaced
    ckGenerateOFile = "generate O file"
      ## write the receiver-domain (O) records of the imported survey's X records as an SPS file,
      ## on a job; never one of the survey's own files or an open file

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
      reordered*: JobId ## the job's id
      position*: int ## 0 runs next
    of ckGather, ckView, ckDisplay, ckHeader, ckSort, ckReverseAll, ckBack, ckShowFile,
        ckShowTrace, ckEdit, ckUndoEdit, ckRedoEdit, ckClearEdits, ckExportEdits, ckImportEdits,
        ckFilter, ckRetry, ckStopReading, ckPrepare, ckProcessing, ckDisplayPreset, ckOwnFilter,
        ckTimeShift, ckOpenPair, ckCorrelate:
      panel*: PanelId ## the panel's id (1: the Seismic window; 0 retries the folder)
      gather*: int ## ckGather: index into the file's gathers
      path*: string
        ## ckShowFile, ckShowTrace: the file to show; ckPrepare: the next; ckOpenPair: the
        ## signature file whose partner is wanted ("": the file the panel shows)
      traceIndex*: int ## ckShowTrace: the trace's index (in its record)
      recordIndex*: int ## ckShowTrace: the SEG-D record it counts in; -1: the file
      listFolder*: bool ## ckShowFile: the file list lists its folder too
      view*: Viewport ## ckView: what the panel's plot shows now
      remember*: bool ## ckView: a gesture starts; keep the view it replaces for back
      display*: DisplaySettings ## ckDisplay: how layer 0 is drawn
      header*: HeaderChoice ## ckHeader: the display header's rows
      order*: seq[SortKey] ## ckSort: layer 0's keys, the first first; empty: the file's order
      reverse*: bool ## ckReverseAll: every trace of layer 0 reversed, or none
      edit*: TraceEdit ## ckEdit: killed, or reversed
      edited*: seq[int]
        ## ckEdit, ckOwnFilter, ckTimeShift: survey-wide ids of traces of the panel's file
      on*: bool ## ckEdit, ckOwnFilter, ckTimeShift: given (true) or taken away
      alsoDrop*: set[TraceEdit]
        ## ckEdit: other edits taken away with `edit` in the same step, when `on` is false
      alsoFilter*: bool
        ## ckEdit: the trace's own filter taken away in the same step, when `on` is false
      alsoShift*: bool
        ## ckEdit: the trace's own time shift taken away in the same step, when `on` is false
      filter*: TraceFilter ## ckFilter: layer 0's traces (seismic, auxiliary, components)
      listPath*: string
        ## ckExportEdits, ckImportEdits: the list's file (`.nif`, or `.csv`)
      replaceEdits*: bool
        ## ckImportEdits: the file's edits become the list's, what it has that
        ## the list does not taken off (one step), instead of the list's added
      processing*: Processing
        ## ckProcessing: layer 0's filters (DC removal, pass band, notches),
        ## shown raw or processed, the auxiliary traces filtered or not;
        ## ckOwnFilter: the trace's own frequency filters (raw and aux are not used)
      filterPlace*: FilterPlace
        ## ckOwnFilter: after the plot's filters, or instead of them
      ms*: float64
        ## ckTimeShift: the shift in milliseconds, positive later; snapped to the
        ## sample interval. 0, or absent, or `on` false, takes the shift away
      presetAction*: PresetAction
        ## ckDisplayPreset: draw the panel as the preset says (its orientation
        ## kept), save the panel's display under the name (replacing a preset
        ## so named), rename the preset, or delete it
      presetName*: string ## ckDisplayPreset: the preset's name, in any case
      presetNewName*: string ## ckDisplayPreset: the new name, to rename
      correlate*: bool
        ## ckCorrelate: true shows the correlated record of the file the Seismic
        ## window shows; false shows the raw record and closes the derived view
    of ckHover: trace*: int ## survey-wide trace id; -1 for none
    of ckSelect:
      traces*: seq[int] ## survey-wide trace ids
      mode*: SelectMode ## how they change the selection
      all*: bool
        ## true: `traces` is every trace the Seismic window shows (the Seismic / Aux choice
        ## and the hidden killed traces applied), whatever `traces` says (Edit > Select all)
    of ckClearSelection, ckResetSettings, ckFileMemory: discard
    of ckForgetFiles:
      forget*: seq[string]
        ## the store's documents (`FileRecord.doc`) whose files are forgotten
    of ckSettings: settings*: Settings
    of ckExportSettings, ckImportSettings, ckLoadLayout, ckExportLayout, ckImportLayout,
        ckExportLog:
      docPath*: string ## the file written or read
    of ckLayout: arrangement*: string ## the toolkit's layout text
    of ckSaveLayout: layoutName*: string
      ## the name to keep it under
    of ckTheme: theme*: string
      ## the theme file's name, as View > Theme lists them (`tokyo-night`,
      ## without `.toml`); "" follows the system (Everforest Dark or Light)
    of ckReopen:
      reopenPath*: string
        ## the file: one open is closed and opened again in the panels that
        ## show it; another is opened and shown in the Seismic window
      openChoice*: OpenChoice
        ## the options it is opened with from now on, this run (the defaults
        ## detect everything; given in part, the rest are the defaults)
      reopenAll*: bool
        ## a signature file's options (`openChoice.signature`) for every file of its kind in
        ## the listing, this run only
    of ckUnloadSurvey: layer*: SurveyLayerId
      ## the survey layer's id
    of ckMapView:
      mapView*: MapView ## what the map shows now
      mapRemember*: bool ## a gesture starts: keep the view it replaces for back
    of ckMapBack: discard
    of ckMapLayer:
      mapLayer*: MapLayerKey ## the layer: its kind, file and role
      shown*: bool ## drawn, or hidden
    of ckSelectPoints, ckHoverPoints, ckShowPoints:
      points*: seq[PointRef]
        ## ckSelectPoints: the points; ckHoverPoints: those under the
        ## pointer (none: off every point); ckShowPoints: those on the spot
        ## clicked, whose traces' record the main panel shows
      pointMode*: SelectMode
        ## ckSelectPoints: replace, add, toggle or remove, their traces
        ## likewise; or a range, from the point clicked last along its line
        ## to the first of `points`
      shotPath*: string
        ## ckShowPoints: of the listed files that hold a source's shot, the
        ## one to show it from; "" the first (the latest, `ShotIndex.points`)
      jump*: bool
        ## ckSelectPoints: the main panel also shows the record of the traces selected,
        ## as ckShowPoints does (a click on a source of a receiver gather)
    of ckSelectShotRows:
      shotLogId*: int ## the loaded log's id
      shotRows*: seq[int] ## its data rows; none: nothing chosen
      shotTraces*: bool
        ## also select the traces of the file shown that belong to those shots (the
        ## rule of the Shot log window's follow), and show the first
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
    of ckChooseUnit:
      unitChoice*: UnitChoice
        ## the survey (its files) or the seismic file, and its unit by hand
        ## or back to what the headers say
    of ckSurveyUnits:
      unitsOf*: seq[JoinFile]
        ## survey files whose headers are read (from their first bytes, on a
        ## job each) for what they say of their coordinates' unit; a file
        ## read once is not read again
    of ckInspect:
      inspect*: set[InspectPart]
        ## the parts of the Headers window on screen, which its reader reads
        ## (off the UI thread) until they change: the SEG-D record's headers
        ## of the record the plot shows (File headers), the header fields or
        ## the samples of the traces its Trace tab is about (the selection,
        ## else the trace under the pointer), the trace table's rows; none
        ## when the window is hidden. Changes nothing else: what was read is
        ## in `state`'s `headers`
      table*: TableView
        ## the trace table's columns, scope, order, Find, rows on screen and
        ## graph, while it is on screen
    of ckSpectrum, ckSpectrumDisplay, ckCloseSpectrum, ckSpectrumPanel, ckAuxWindow,
        ckSpectrumCursor,
        ckStepTrace:
      spectrum*: int
        ## ckSpectrumDisplay, ckCloseSpectrum, ckSpectrumCursor, ckStepTrace:
        ## the window (0 the live panel; FFT windows from 1, as `state`'s
        ## `spectra` lists them); ckStepTrace: an FFT window of one trace
        ## steps from its trace and shows the new one, one of a selection
        ## from the selection; a frozen one keeps its trace and steps the
        ## plot's selection; 0 steps the plot's selection
      spectrumOf*: PanelId
        ## ckSpectrum, ckStepTrace: the panel whose file, view and filters it
        ## is of (1: the Seismic window)
      stepBy*: int
        ## ckStepTrace: 1 the next trace of the record in the order shown,
        ## -1 the previous one (traces the trace filter hides are skipped,
        ## killed ones shown are not)
      cursor*: PlotCursor
        ## ckSpectrumCursor: `held` true holds the cursor at bin `x`'s
        ## frequency (`state`'s spectra give `binHz`) and on curve `y` as
        ## drawn (0 the first in the legend), which it then keeps when the
        ## bins or the curves drawn change; false lets it go to the pointer
      spectrumTraces*: seq[int]
        ## ckSpectrum: survey-wide ids of traces of the panel's file; none:
        ## its selected traces there
      spectrumShow*: SpectrumDisplay
        ## ckSpectrum, ckSpectrumDisplay: dB or linear, the frequency axis
        ## logarithmic, the whole trace or the plot's visible time, the raw
        ## and processed curves drawn
      frozen*: bool
        ## ckSpectrumDisplay: the window keeps the traces and the file it
        ## shows; off, it follows the plot again
      onScreen*: bool
        ## ckAuxWindow: the Aux window is open; ckSpectrumPanel: the live panel is on screen (it follows the
        ## Seismic window's view or selection, off the UI thread, only then)
    of ckOpenPlot, ckPlotDisplay, ckPlotCursor, ckClosePlot:
      plot*: int
        ## ckPlotDisplay, ckPlotCursor, ckClosePlot: the window (from 1, as
        ## `state`'s `plots` lists them)
      plotView*: AnalysisView
        ## ckOpenPlot: what it shows: a spectrogram, the envelope and
        ## instantaneous phase, the phase spectrum, a cross-correlation
      plotOf*: PanelId
        ## ckOpenPlot: the panel whose file and filters it is of (1: the
        ## Seismic window)
      plotTraces*: seq[int]
        ## ckOpenPlot: survey-wide ids of traces of the panel's file; none:
        ## its selected traces there, else the trace under the pointer
      plotParams*: AnalysisParams
        ## ckOpenPlot, ckPlotDisplay: its settings (frame length and overlap,
        ## the phase's dB threshold, the lags, ...). A cross-correlation uses
        ## the reference chosen with ckSelectReference, and no other; an old
        ## `reference` field here is ignored
      plotFrozen*: bool ## ckPlotDisplay: it keeps what it shows
      plotCursor*: PlotCursor ## ckPlotCursor: where its cursor is held
      plotCursorOn*: int
        ## ckPlotCursor: the plot of the window it is held in (a curve view's:
        ## 0 the top one), whose x and curve `plotCursor` counts
    of ckNewProject, ckOpenProject:
      projectPath*: string
        ## ckOpenProject: the project folder, or the project.nif in it;
        ## ckNewProject: the folder to make, whose name is the project's
      projectName*: string
        ## ckNewProject: the project's name; "" for the folder's
      dataFolders*: seq[string]
        ## ckNewProject: its data folders; none: the folder the file list lists
      useSurvey*: bool
        ## ckNewProject: the survey files on the map now are imported into it
      bringMemory*: bool
        ## ckNewProject: what is remembered about the files of its data
        ## folders (their kills and reversals) is copied into it
      takePresets*: bool
        ## ckNewProject: the display presets are copied into it
    of ckProjectFolder:
      folderAction*: FolderAction ## add, remove, or locate (found at `folderPath`)
      folderPath*: string ## the folder added or removed, or where a missing one is now
      folderWas*: string ## locate: the missing folder, as the project names it
    of ckCloseProject, ckUpdateSurvey, ckClearSurvey, ckListReferences, ckReloadVendors:
      discard
    of ckVendorMap:
      vendorMap*: string
        ## ckVendorMap: "automatic", "none", or the name of a loaded map (a map named
        ## so cannot be chosen: its name is the rule)
    of ckStoreReference:
      refStore*: StoredReference
        ## ckStoreReference: the trace (a survey-wide id), the window in ms
        ## (the trace as the file has it, turned over when it is reversed on its own,
        ## nothing else the plot decides; `phaseDeg` 180 turns it over after the cut)
        ## (`toMs` below 0: the trace's end) and the name
    of ckGenerateReference:
      refGenerate*: GeneratedReference
        ## ckGenerateReference: the sweep (frequencies, length, sample interval,
        ## tapers and their shape and parameter, type, amplitude, phase in
        ## degrees). `dtMs` 0: the file on show. `name` "": one made from the
        ## parameters. `taperShape` left out: cosine squared. `taperParam`
        ## left out or null: the shape's default. `phaseDeg` left out: 0;
        ## 180 degrees reverses the polarity. There is no separate polarity.
        ## `filter` left out: none (the sweep as it is). Else `kind`
        ## "linear phase" (`taps`, `highCutHz`, `highSlopeDb`, `lowCutHz`,
        ## `lowSlopeDb`) or "minimum phase" (`coefficients`, the filter's
        ## taps; or `family` "Butterworth" or "Chebyshev" with `highOrder`,
        ## `lowOrder`, the cutoffs and, for Chebyshev, `rippleDb`); a cutoff
        ## of 0 is off. `shiftSamples`: the bulk delay to back out, in whole
        ## samples, used when `shiftTyped` is true (else linear phase uses
        ## (taps - 1) / 2, and a minimum-phase filter none). Nothing is read from a file's headers
    of ckPilotReference, ckPilotPreview:
      refPilot*: PilotRule
        ## ckPilotReference, ckPilotPreview: `aux` true: auxiliary trace `trace`
        ## of the record, else trace `trace` of the record (from 1); the window
        ## from `startMs` for `spanMs`; `phaseDeg` 0 (left out) or 180 (turned
        ## over after the cut); `name` "": one made from the rule
    of ckSelectReference, ckDeleteReference, ckRenameReference, ckCopyReference,
        ckViewReference, ckCloseRefView:
      refId*: string
        ## ckSelectReference, ckDeleteReference, ckRenameReference, ckCopyReference,
        ## ckViewReference: the reference's id; "" for ckSelectReference is none
        ## (a correlation draws nothing; a vibrator signature uses the file's pilot)
      refNewName*: string
        ## ckRenameReference: the new name
      refWindow*: int
        ## ckCloseRefView: the window
    of ckSetCompare, ckClearCompare, ckSwapCompare, ckCompareDisplay, ckCompareWindow:
      compareSlot*: CompareWhich
        ## ckSetCompare, ckClearCompare: A, B, or both (clear)
      compareTrace*: int
        ## ckSetCompare: a survey-wide trace id; -1 when compareRef is set
      compareRef*: string
        ## ckSetCompare: a reference's id; "" for a trace of an open file
      compareShow*: CompareOptions
        ## ckCompareDisplay: the window's alignment and what it draws
      compareOpen*: bool
        ## ckCompareWindow: true opens the window, false closes it
    of ckSubfolders:
      subfolders*: bool ## true: the subfolders' files are listed too
    of ckTreatAs:
      treatPath*: string ## the file
      treatKind*: string
        ## "shot", "continuous" or "sliced" forces the kind of recording; "automatic" takes the
        ## force off; "" leaves it as it is
      treatGrouping*: string
        ## "none", "flag" or "component" forces the grouping of the traces; "automatic"; ""
      treatSubSort*: string ## "station" or "time" forces the sort inside it; "automatic"; ""
    of ckFileAuxMark, ckProjectAuxMark:
      auxFile*: string ## ckFileAuxMark: the open file whose mark it is
      auxPosition*: int
        ## the auxiliary trace's position, from 1, counted among a record's auxiliary traces in
        ## file order: the mark holds for that position in every record
      auxMarked*: AuxMarkState
        ## "yes": marked for correlation; "no": explicitly not marked (a file's, over the
        ## project's mark); "forget": no entry (a project's takes only "yes" and "forget")
      auxShiftMs*: float64
        ## the shift before correlating, in milliseconds, positive later; 0 for none
    of ckVibProfile:
      vibProfile*: VibQcProfile
        ## the settings to keep as the project's vibrator QC profile
    of ckVibWeights:
      vibWeights*: VibJobWeights
        ## the hold-down, baseplate and reaction-mass weights, kilograms; NaN is not set
    of ckImportShotLog, ckRemoveShotLog, ckRemapShotLog, ckEditShotCell,
        ckUndoShotEdit, ckRedoShotEdit:
      logPath*: string ## ckImportShotLog: the file to read
      logMap*: ShotLogMap ## ckImportShotLog when logMapped; ckRemapShotLog: the new map
      logMapped*: bool ## ckImportShotLog: a map was given (else the last map, or a guess)
      logIndex*: int ## which loaded shot log
      logRow*: int ## ckEditShotCell: the data row
      logCol*: int ## ckEditShotCell: the column
      logCell*: string ## ckEditShotCell: the new cell text
    of ckAddLeap, ckRemoveLeap, ckReloadLeaps, ckResetLeaps:
      leapYear*: int ## ckAddLeap: the year
      leapMonth*: int ## ckAddLeap: the month
      leapStep*: int ## ckAddLeap: +1 or -1
    of ckCutGather:
      cutLog*: int ## the loaded shot log whose shots are cut (its index)
      cutOptions*: CutOptions
        ## the record's length and start, the alignment, the format, the order of its traces
      cutDest*: string ## the file to write: a new name, in a folder that exists
    of ckExportShotSps:
      spsLog*: int ## the loaded shot log to write (its index)
      spsOptions*: ShotSpsOptions ## the revision, defaults, point code and time
      spsDest*: string ## the file to write: a new name, in a folder that exists
    of ckGenerateOFile:
      oDest*: string ## the file to write: not one of the survey's files or an open file
    of ckNamePattern:
      patternAction*: NamePatternAction
        ## ckNamePattern: save (add, or replace the one with the same label,
        ## case ignored), delete by label, or choose by label
      namePattern*: OutputPattern
        ## ckNamePattern: the pattern to save; for delete and choose, `name`
        ## is the label (empty chooses today's naming). A part of kind `npVendor` takes
        ## a vendor map's field by name, written in the part's `text`
    of ckOutputText:
      textAction*: OutputTextAction
        ## ckOutputText: save (add, or replace the one with the same name,
        ## case ignored), delete by name, or choose by name
      textTemplate*: OutputText
        ## ckOutputText: the template to save; for delete and choose, `name`
        ## is the name (empty chooses the writer's own text). A line may hold
        ## `{vendor:NAME}`, a vendor map's field by name
    of ckOutputBinary:
      binaryAction*: OutputBinaryAction
        ## ckOutputBinary: save (add, or replace the one with the same name,
        ## case ignored), delete by name, or choose by name
      binarySet*: OutputBinary
        ## ckOutputBinary: the set to save; for delete and choose, `name` is
        ## the name (empty chooses no binary header value)

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
    path*: string ## the file or the folder
    silent*: Duration ## how long it has not answered (on `fs.now`)
    job*: JobId ## the job Cancel stops (an open, a listing); `NoJob` for none
    why*: string ## wkUnreadable: why, in plain words
    cause*: UnreadCause ## wkUnreadable: a drive that fails, a file cut short, or a stop

  Pending = object
    ## An open or close job the state waits for.
    job: JobId
    path: string
    session: Session  ## a closing file's session, kept until its close job ends
    panel: PanelId    ## an open: the panel it is shown in (`ckShowFile`); NoPanel: the main one
    gather: int       ## an open: the gather shown first (a file opened again: the one it showed)
    unwanted: bool    ## an open no longer wanted (another file was chosen): dropped when it comes
    follow: bool      ## an open "Follow the latest" made: shown only when the file is whole
    quiet: bool       ## a close of a file the plot stepped away from: not logged
    by: CommandOrigin
      ## an open: who asked for it (the user's goes to the recent files kept)
    reopened: bool
      ## an open "Reopen with options" made: its file takes the place of the open
      ## one only when it opened with traces, else the file stays as it was
    tried: OpenChoice ## a reopen: the choice it asks for, written only once it is taken in
    replacesOpen: bool
      ## a reopen of a file that was open: the new session is dropped when
      ## that session is gone before it arrives (the file was closed)
    revived: bool
      ## the file was let go of to be shown again (it changed on disk) while
      ## this reopen was still reading: the new session is shown all the same
    swapped: bool ## a reopen: its file took the place of the open one (its job ends quietly)
    hold: bool
      ## an open made so a correlation can run again: not shown; the derived view stays

  Carry = object
    ## What a file that is opened again keeps, taken from the open file when
    ## the new one takes its place: its selection, geometry join and the
    ## analysis windows of its traces.
    oldBase, count: int ## the old file's first survey-wide id, and its traces
    selected: seq[int] ## the selected traces (indices in the file)
    joined: bool
    join: Joined
    plots, spectra: seq[int] ## the ids of the windows of its traces

  Reopen = object
    ## A panel that showed a file another program changed: it shows the
    ## file again once the file stops changing.
    path: string
    panel: PanelId
    gather: int
    held: bool ## the derived view stays; the file is opened and correlated, not shown raw

  SurveyHolds = ref object
    ## The project's survey a batch write joins from, kept alive for its job.
    ## A ref so the window, which holds the state read-only, can add to it.
    held: seq[tuple[job: JobId; geometry: ref SurveyGeometry]]
      ## per running job
    left: seq[tuple[job: JobId; geometry: ref SurveyGeometry]]
      ## those of jobs abandoned while their work still ran, until it is back

  CorrelateHold = ref object
    ## One correlation, kept until its job has ended. A ref, not shared memory:
    ## `result.opened` is a `Session`, and a `Session` in shared memory is not traced.
    job: JobId
    result: CorrelateResult
    origin: string ## the file on disk
    refId: string ## the reference it was made from
    gen: uint64 ## `correlateGen` when it was submitted; a newer one drops this result

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
    ## The survey import under way (Project > Import survey): one at a time.
    job: JobId = NoJob           ## the job of its step; `NoJob`: none under way
    step: JoinStep
    session: SessionId
      ## the file matched to; `NoSession`: the map only
    loads: seq[JobId]
      ## its files' loads onto the map, until their layers come
    added: seq[SurveyLayerId]
      ## the layers they gave (taken out again at a cancel)
    replaced: seq[tuple[by: SurveyLayerId; layer: SurveyLayer]]
      ## the layers of the same files they took the place of (put back at a
      ## cancel or a failure)
    checkLater: bool
      ## a relation file loaded meanwhile: the file's records are checked
      ## once, when the match ends (against the survey imported, or that file)
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
    relations: ref SurveyGeometry
      ## its relation records, when kept apart from `geometry`
      ## (`SharedRelations`): a relation file's map layer's; nil for none
    reused: seq[ref SurveyGeometry]
      ## the loaded layers' relations its read uses where they are: kept
      ## alive until it ends
    plan: JoinPlan
    survey: JoinSurvey
    joined: bool ## the join's job said it was done (`mkJoined`)
    revision: int ## the file's keys' revision after the join (`mkJoined`)
    movesTouched: bool ## the join's moves changed a receiver field
    movesCount: int ## traces whose receiver fields those moves changed
    held: int = -1 ## the holds on the file its job found: none (-1: it never ran)
    paused: seq[PanelId] ## the panels whose readers let go of the file for it
    auto: bool ## a file opened in a project, matched to its survey without the window
    carried: bool
      ## a file opened again: the match is said to start then, and kept or
      ## dropped only once it ends
    by: CommandOrigin ## who asked for the import (the user's is kept in the project)
    cleared: bool
      ## Clear survey came while it ran: it is cancelled, and whatever its job
      ## still does is undone (its end never records a join)

  Joined* = object
    ## An open file joined with survey files: what it was joined with and how.
    session*: SessionId
    files*: seq[JoinFile]
    options*: JoinOptions
    units*: JoinUnits
    plan*: JoinPlan              ## what the join did, trace by trace counted
    survey*: JoinSurvey          ## what the survey files gave
    words*: seq[string]          ## `plan` in plain words
    geometry: ref SurveyGeometry ## the stations it was joined with
    relations: ref SurveyGeometry
      ## the relation records it was joined with, when apart from `geometry`
      ## (a relation file's map layer's); what its records are checked against

  SurveyRestore* = enum
    ## Where a project's survey stands.
    srNone = "none"       ## none imported
    srLoading = "loading" ## being made from `survey.bin`
    srLoaded = "loaded"   ## on the map, and every file opened is matched to it
    srKeeping = "keeping" ## being copied into the project, `survey.bin` written
    srFailed = "failed"   ## could not be made (`ProjectState.surveyNote` says why)

  ProjectState* = object
    ## The project open (`core/project`): none while `dir` is "".
    dir*: string                    ## the project folder
    doc*: ProjectDoc                ## its document as this run has it
    readOnly*: bool                 ## another program has it open, or it is of a newer version: nothing is written
    whyReadOnly*: string
    owner*: Owner                   ## who holds its lock, when this program does not
    folders*: seq[PlaceLook]        ## where each data folder was found
    originals*: seq[OriginalLook]   ## each survey file's original against its copy
    offer*: bool ## originals changed since they were copied: "Update from the original" is offered
    survey*: SurveyRestore
    surveyNote*: string             ## why the survey failed
    restoreMs*: float64             ## how long its survey took to be made from `survey.bin` last
    revision*: int                  ## bumped on every change
    lock: FileLock
    job: JobId = NoJob              ## the open (or the making) of a project under way; `NoJob` for none
    jobDir: string
    jobBy: CommandOrigin
    useSurvey: bool                 ## the project being made takes the session's survey once open
    surveyJob: JobId = NoJob        ## its survey's job (made, kept, updated)
    lookJob: JobId = NoJob
    originalsJob: JobId = NoJob     ## the look at its survey originals (a job of their own)
    geometry: ref SurveyGeometry    ## its survey, as the joins read it; nil until made
    joinSurvey: JoinSurvey
    queue: seq[SessionId]           ## files opened, to be matched to its survey
    rebuilding: bool                ## survey.bin was rejected and is being made again from the copies
    layersAfterKeep: bool           ## the copy under way began at the open: the map's layers follow it
    docRev, savedRev: int
    changedAt: MonoTime
    userArrangement: string         ## the user's own window arrangement, back when the project closes
    userPresets: seq[DisplayPreset] ## the presets in effect before it opened, back when it closes
    userProcessing: Processing      ## the plot's filters in effect before it opened, back when it closes
    userBreakModel: BreakModel      ## the first-break model in effect before it opened, back when it closes
    by: CommandOrigin               ## who opened it

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
    own: seq[OwnFilter]
      ## each trace's own filter, when shown as displayed; the default for none
    hasOwn: seq[bool]
    shiftMs: seq[float64] ## each trace's time shift, when shown as displayed; 0 for none
    displayed: bool
    shown: SessionId
      ## the file the plot shows, when traces are shown as displayed (only
      ## its traces are read so); NoSession otherwise
    record: (SessionId, int)
      ## a SEG-D record: its file and index; (NoSession, -1) for none
    vendor: (SessionId, int)
      ## the file whose vendor blocks the File headers tab shows, and its SEG-D
      ## record (-1 for another standard); (NoSession, -1) for none
    vendorGen: int ## the maps' load it was asked with
    flow: (bool, string, GatherKind)
      ## the plot's polarity, its pipeline's steps (`stepsText`), the
      ## gather's kind
    display: DisplaySettings
      ## the plot's display, compared by `sameProcessing`
    joins: int
      ## the geometry joins ended so far (`joinReport.serial`): a join
      ## changes the keys the Trace tab shows (read here, never the file's
      ## `keysRevision`, which a join's job writes)
    keysRev: seq[int]
      ## the shown files' keys revisions (`Session.keysRevision`), in the
      ## order of the traces asked for, then the table's file if it is
      ## another: a station move changes those keys. Not the file's own
      ## `keysRevision` (a join's or a move's job writes it)
    table: TableView ## the trace table's, when on screen
    tableOf: (SessionId, Slice[int])
      ## the trace table's file and the traces it has rows for; NoSession for none

  LiveKey = object
    ## What the live spectrum panel was asked for: a new request when it
    ## changes.
    session: SessionId
    traces: seq[int]
    window: (float64, float64)
    processing: Processing
    killed: seq[int]
    own: string ## the own filters of `traces` (`ownKeyOf`)

  VendorState* = object
    ## The vendor header maps (`core/vendormaps`).
    folders: seq[VendorFolder]
      ## the program's, the user's and the environment's, as the frontend gave them
    load: VendorLoad        ## the newest load taken in
    asked: int              ## loads asked for; a load older than the last asked is dropped
    gen: int                ## the load taken in: what a decode of a file was made with
    job: JobId
    saidNone: bool          ## "no maps" was said, and no map has been found since
    choice: VendorChoice    ## the project's rule for the maps; automatic outside a project
    loud: bool              ## the load asked for last was the user's (Reload vendor maps): said always
    lastSaid: string        ## what the last load said: a load that says the same is quiet
    mismatched: seq[string] ## the files the project's map was said not to apply to

  Remembered = object
    ## An opened file's place in what is remembered (`core/filememory`).
    path: string
    identity: FileIdentity ## known once `job` has posted it
    known: bool            ## `identity` is known (the quick one at least)
    modified: Time         ## the file's modification time as it was identified
    size: int64            ## its size as the session opened it
    job: JobId             ## the identification under way; `NoJob` for none
    hashJob: JobId         ## the full hash under way; `NoJob` for none
    hashed: bool           ## `identity.full` known
    doc: string            ## the store's document its edits are kept in; "" for none yet
    waiting: seq[FileRecord]
      ## documents of its quick identity that wait for the full hash to say
      ## whether they are about this file
    taken: seq[string]
      ## every document name of its quick identity in the store, read or not
      ## (one that could not be read is never written over)
    brought: FileRecord
      ## the document `doc` as it was brought back before the hash of every
      ## byte confirmed it: written back as it was when the hash says it
      ## was another file's
    heldEarlier: seq[FileRecord]
      ## earlier outputs of its name found while a record of the same quick
      ## identity still waits for the hash (it may be the file's own, and
      ## cover them): said once it has come
    provDocs: seq[string]
      ## the documents holding edits that are not confirmed by a hash of every
      ## byte: those made while `brought` was being checked (written here, never
      ## into the brought document), and those a run that quit during a check
      ## left. Joined into the file's document once the hash agrees, or made its
      ## own record when it differs; removed after.
    savedRev: int ## the edits' `keptRevision` written last
    changedAt: MonoTime ## when its kept edits changed last
    opened: Time ## when it was opened
    saidWaiting: bool ## said that its edits wait for its identity
    ownDoc: bool
      ## `doc` was made in this run for edits made before the hash of every
      ## byte came (not one brought back): a document waiting for that hash
      ## may still be this file's
    openModified: Time ## the file's modification time as the session opened it
    pendingRev: int
      ## the edits' `keptRevision` its pending document (`pendingName`) was
      ## written with, while its identity is not known; -1 for none
    pending: bool
      ## its pending document is on disk (or handed to the disk thread):
      ## removed once its edits are written in its own document
    seenAside: bool
      ## `doc` has parts that cannot be read, so it is not written again:
      ## when the file was opened is in its side file (`seenName`), removed
      ## when the document is written

  MemoryList* = object
    ## What the File memory window lists: every file the store remembers.
    records*: seq[FileRecord] ## the newest opened first
    problems*: seq[string]    ## documents that could not be read
    listing*: bool            ## a listing is under way
    listed*: bool             ## a listing came
    revision*: int            ## bumped when it changes

  BreakView = object
    ## A record panel's first-break overlay as it shows it (`shownBreaks`): of the result with
    ## `key` at `revision`, with `model`, and whose picks those are.
    key: BreakKey
    revision: int
    model: BreakModel
    guided: GuideState
    why: string
    shown: FirstBreaks

  ShotCellEdit = object
    ## One cell edit of a loaded shot log, for undo. Not saved with the project.
    row, col: int
    before, after: string

  LoadedShotLog = ref object
    ## A shot log read into this run. Its text is `log`'s, not a second copy.
    id: int
    name: string
    source: string          ## the file it was read from
    stored: string          ## the copy's file name under shotlogs/; "" when not stored
    map: ShotLogMap
    log: ShotLog
    view: ShotView
    revision: int           ## bumps when a job assigns a new view
    busy: bool              ## a job is reading it: a cell edit waits
    undo: seq[ShotCellEdit] ## cell edits that can be taken back; capped
    redo: seq[ShotCellEdit] ## edits undone, until a new edit clears them

  ShotLogJobKind = enum
    sjImport, sjLoad, sjSave, sjRemap, sjRebuild, sjDelete

  ShotLogWork = object
    job: JobId
    kind: ShotLogJobKind
    id: int ## the loaded log, or -1 before an import has one
    sink: ShotLogSink
    name: string
    source: string
    stored: string
    map: ShotLogMap

  AppState* = object
    ## Everything the views show. Move-only.
    log: MessageLog
    selection: Selection
    hoverNote: string                          ## why the hover lights nothing up; "" when it does
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
    survey: Survey ## the survey files loaded and the open files' positions
    map: MapState ## the map's view and hidden layers
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
    moveBases: seq[tuple[session: SessionId; bases: seq[ReceiverBase]]]
      ## per open file, the receiver fields a station move replaced
    moveQueue: seq[SessionId]
      ## open files waiting for a station-move job
    movesJob: JobId = NoJob
      ## the station-move job under way; `NoJob` for none
    movesPaused: seq[PanelId]
      ## the panels whose readers let go of the file for that job
    movesSession: SessionId
    movesRevision: int
    movesChanged: int
    movesDone: bool ## the job posted what it did (`mkMoves`)
    leapGen: int
      ## how many times the leap table has been adopted; only increases
    leapQueue: seq[SessionId]
      ## open files waiting for their times to be read again
    leapJob: JobId = NoJob
      ## the leap-second re-read under way; `NoJob` for none
    leapPaused: seq[PanelId]
      ## the panels whose readers let go of the file for that job
    leapSession: SessionId
    leapName: string
      ## the file the re-read is for, so a cancel can name it after it is closed
    leapRevision: int
    leapChanged: bool
    leapDone: bool ## the job posted what it did (`mkLeap`)
    cutJob: JobId = NoJob
      ## the slice by shot log under way; `NoJob` for none
    cutSink: CutSink
      ## what that job found, read once the job has ended
    cutOutcome: string
      ## the last cut's outcome line, for the dialog; "" before any
    cutPath: string
      ## the file the last slice wrote; "" when it wrote none
    spsJob: JobId = NoJob
      ## the SPS export under way; `NoJob` for none
    spsSink: SpsSink
      ## what that job found, read once the job has ended
    spsOutcome: string
      ## the last export's outcome line, for the shot log window; "" before any
    spsPath: string
      ## the file the last export wrote; "" when it wrote none
    spsLogId: int = -1
      ## the id of the shot log the last export was of; -1 before any
    oJob: JobId = NoJob
      ## the O file generation under way; `NoJob` for none
    oSink: OFileSink
      ## what that job found, read once the job has ended
    oOutcome: string
      ## the last generation's outcome line, for the Imported Survey window; "" before any
    oPath: string
      ## the file the last generation wrote; "" when it wrote none
    recJob: JobId = NoJob
      ## the job that describes the shown file as a recording for the cut dialog
    recSink: RecordingSink
    recPath: string ## the file `recJob` reads (its row of the file list takes the kind)
    recKey: tuple[session, revision, vendors: int]
      ## the file, its keys revision and the vendor maps' load `recFacts` (or the job) is for
    recFacts: RecordingFacts
    recHave: bool ## `recFacts` is the answer for `recKey`
    recWhy: string ## why `recFacts` is not `ready` when `recHave`: what the job said
    vfJob: JobId = NoJob
      ## the job that lists the vendor fields of one open file (`watchVendorFields`)
    vfKey: tuple[session: SessionId; vendors: int]
      ## the file and the vendor maps' load `vfJob` is for
    vfLists: seq[VendorFieldList]
      ## the fields of each shown file, as read for the maps' load now in force
    joins: seq[Joined]
      ## the open files joined with survey files
    project: ProjectState
      ## the project open, if any (`dir` "" for none)
    earlier: Table[string, seq[FileRecord]]
      ## per open file (by path): what is remembered about earlier outputs of
      ## its name, other files whose edits are not its own
    earlierSaid: HashSet[string]
      ## the documents of earlier outputs said in the log, once each
    userStore: string
      ## the program's own store of what is remembered (`rememberFilesIn`),
      ## its home without a project
    joinReport: JoinReport
      ## how the last join ended
    heads: seq[SurveyHead]
      ## what survey files' headers say of their unit, as read for the
      ## import's window (`ckSurveyUnits`), by the path it named
    headJobs: seq[tuple[job: JobId; path: string]]
      ## the job reading each of `heads` that is not done
    unitChoices: ImportUnits
      ## the units the user chose by hand in the import's window
    spreads: Spreads
      ## relation records made for the map's planned spreads (`core/spread`)
    shots: ShotIndex
      ## the folder listed's shots, matched to the survey's sources (`core/shots`)
    recordQc: RecordQc
      ## what the map's filters find in the record shown (`core/recordqc`)
    breaks: seq[FirstBreaks]
      ## the first-break overlay's results, one per record and guide (the given model the
      ## picks were guided by) a panel with the overlay on shows (and the last few it
      ## showed), oldest first
    breaksReplaced: seq[JobId] ## jobs given up for a newer key: they end quietly
    breakRevisions: int ## the last `FirstBreaks.revision` given: each change gets a new one
    breakViews: seq[BreakView]
      ## each record panel's overlay as it shows it (`shownBreaks`), made when its result or
      ## its model changes rather than on every frame
    batchSurvey: SurveyHolds
      ## the survey each batch write's job joins from (`holdSurvey`), until it ends
    qcHeld: seq[tuple[job: JobId; relations: ref SurveyGeometry]]
      ## the relation records each filters' job reads in place, kept until it ends
    unitsWarned: string
    unitsSaid: HashSet[string] ## the units said to disagree, once a session
                                 ## the disagreement of the units the loaded files name said last
                                 ## (`unitsDisagree`); "" while they agree
    loadNamed: seq[string]
      ## the files the listing was asked for: loaded when it finds them survey files
    saidPositions: HashSet[string]
      ## files whose positions' problems were said; folders said to hold no coordinates
    panels: seq[Panel]
    auxOpen: bool ## the Aux window is open: its panel follows the Seismic window's record
    heldBack: seq[PanelId]
    auxOnNoted: seq[string] ## the first file whose all-auxiliary record switched Aux on: said once a session
                              ## panels that could not show their file: a job had it to itself
    sessions: seq[Session]
    opening, closing: seq[Pending]
    files: FileList ## the file list
    edits: Table[string, FileEdits]
      ## per file (by `keyOf` its path): the traces killed and reversed
    editKey: Table[string, string]
      ## a path opened this run of a file opened under another too (a copy,
      ## a link: the same bytes), to the path whose `edits` it shares
      ## (`linkSame`); a path not in it has its own
    noEdits: FileEdits ## always empty: `editsOf` for a file with none
    showFound: PanelId ## show the first file the listing finds here; NoPanel for none
    jump: tuple[path: string; trace, record: int]
      ## a trace to show once its file is open (`ckShowTrace`); "" for none
    unmatched: HashSet[string]
      ## the file and the words of each warning a plot window gave of a trace that cannot be
      ## matched to its whole reference (`core/signalend`): said in Messages once each
    oldScans: seq[JobId] ## scans replaced by a newer listing: they end quietly
    quietScan: JobId ## a listing of the folder listed last: a missing folder is said quietly
    kindJob: JobId = NoJob
      ## the job reading the kinds of the listed files (`startKinds`); one at a time
    kindCache: KindCache
      ## the kinds read this session: a folder listed again reads only the files without one
    treats: Table[string, TreatAs]
      ## what the user forced for a file (by its path) as the listing and the commands know it
    treatsKept: Table[string, TreatAs]
      ## the part of `treats` that is the user's own, which the store keeps: an agent's choice is
      ## for the session only and never reaches a document the edits are written to
    treatsPending: Table[string, TreatAs]
      ## what a listing found for a file in a document the file's hash has not confirmed (it
      ## may be another content's), without the parts a command set: shown beneath what the
      ## commands set (`shownTreat`), but no job uses it (`treatInForce`)
    treatsOwn: Table[string, set[TreatPart]]
      ## the parts of a file's choice that a command set this session (`treatsTouched`)
    treatsOwnKept: Table[string, set[TreatPart]]
      ## those of them that a command of the user's window set (`keeps`): only these override
      ## what the document says in `treatsKept`
    treatsTouched: HashSet[string]
      ## the paths a command changed this session: a late answer of the kinds job does not
      ## put back what it read before
    treatJobs: Table[string, JobId]
      ## by path, the job looking up which document keeps the user's choice (`treatWork`): one at
      ## a time for a file, and what it hands the disk thread is the choice as it is then
    treatParts: Table[string, set[TreatPart]]
      ## by path, the parts of the user's choice changed since it was last handed to the disk
      ## thread: those it sets in the document (a second viewSEG's other parts stay)
    treatDocs: Table[string, FileRecord]
      ## by path, the document the user's choice was last handed to the disk thread for (its
      ## name, the file's identity and time): the next choice goes to it
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
    openChoices: Table[string, OpenChoice]
      ## per file: the options "Reopen with options" gave it, used by every
      ## later open of it this run; a file not in it opens with the defaults
    sigChoices: array[2, SignatureChoice]
      ## "Use these for every .dat (.vib) file of this listing": the options a signature file of
      ## that kind opens with when it has none of its own; this run, and only while the
      ## folder listed stays
    pairSearch: tuple[job: JobId; path: string; panel: PanelId; by: CommandOrigin]
      ## the search for a file's partner running (`findPairWork`); `NoJob` for none
    pairAnswers: Table[string, PairAnswer]
      ## per file: what a search for its partner found (both ways round when it found one)
    stoppedWaiting: bool
      ## a stopped `.dat` is listed and new: Follow shows it after it has stayed so for
      ## `StoppedShowAfter` (`followNewest` says so), so the program looks again each frame
    followed: HashSet[string]
      ## files "Follow the latest" opened (each is shown once)
    followedUpTo: int64
      ## the modification time of the file "Follow the latest" showed last:
      ## an older one is never followed after it (it would step back in time)
    onDiskSaid: Table[string, string]
      ## per open file: what was said last of its changes
    editStamps: Table[string, tuple[size: int64; modified: Time]]
      ## per file with edits: its size and time when they were made
    store: Store
      ## where what is remembered about files is kept; nowhere until `rememberFilesIn`
    refsHome: string
      ## the archive in force (`references` of the project, or the program's own)
    mainRefsHome: string ## the program's own archive
    refs: ReferenceIndex ## the archive in force, as last read
    mainRefs: ReferenceIndex ## the program's own, listed beside a project's
    chosenRef: string
      ## the reference the plots use; "" is none (a vibrator signature then
      ## uses the file's pilot; a correlation draws nothing)
    lastFolderTried: (string, string)
      ## a project opened on the folder listed last (the first), and the data folder to list
      ## instead should that listing fail
    vibLayouts: seq[string]
      ## the vibrator signature's roles chosen by hand, per file layout, in force (the
      ## project's, else the settings'; `choiceText`)
    refsLoaded: bool
    mainRefsLoaded: bool
    refsRev: int ## bumps when the archive or the choice changes, so a plot asks again
    correlateOn: bool ## the Seismic window shows the correlated record
    correlateNote: string ## a status sentence (no reference, a failure); not the hover
    profileNoted: bool ## the status line says the vibrator QC profile was stored
    profileNoteBase: VibQcProfile ## the stored profile as the Messages window last heard of it
    profileNoteAt: MonoTime ## when the stored profile last changed, once not yet said
    profileNoteFile: string ## the file of the window that changed it
    correlateSaid: string ## the sentence logged last, so the same one is not said again
    picksSaid: bool ## the picks sentence was said this run
    correlateLimit: int64
      ## a correlated copy larger than this many bytes is shown as a view, not held
    correlateRef: string ## the reference the derived view was made from
    correlateGen: uint64 ## bumps when a new correlation replaces one running
    correlate: CorrelateHold ## the correlation running; nil for none
    correlateRetired: seq[CorrelateHold]
      ## cancelled correlations kept until their jobs end, so the result is freed here
    refViews: seq[RefView] ## windows showing a reference, until closed
    pilotShown: PilotPreview ## the dialog's pilot of the record on show
    compareA, compareB: CompareSlot
      ## the two traces held for comparison; session only, not saved
    compareOptions: CompareOptions
    comparePicture: ComparePicture
    compareOpen: bool
    compareRevision: int
    compareGen: uint64
    comparePicGen: uint64 ## the picture ask in force; an older answer is dropped
    compareJobA, compareJobB, comparePicJob: JobId
    remembered: seq[Remembered]
      ## the files opened this run, by path, and where their edits are kept
    knownDocs: Table[string, FileRecord]
      ## the store's documents as this run last wrote or read them, by name
      ## (newer than the disk until the disk thread has written them)
    memoryList: MemoryList
    memoryJob: JobId ## the listing under way; `NoJob` for none
    vendor: VendorState
    memoryLooks: seq[JobId]
      ## the looks of the listing shown at its files (`lookWork`), the one
      ## under way last: what they post is taken, also late (a drive that
      ## answers again)
    lookGiven: seq[LookFolder]
      ## the folders the look under way was given, in its order
    memoryWork: seq[JobId]
      ## the identifications and hashes under way: they end quietly
    exports: seq[JobId] ## the exports of edits under way
    editImports: seq[tuple[job: JobId; path: string; by: CommandOrigin; replace: bool;
      label: string]]
      ## the imports of edits under way: each job, and the file it is for
    notices: seq[Notice] ## the newest `MaxNotices`
    nextNotice: int
    traceReads: seq[tuple[job: JobId; keys: TraceKeys; rows: seq[HeaderRow];
      vendor: VendorShown]]
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
    themeNames: seq[string] ## the theme files the frontend found (`offerThemes`)
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
    shotLogs: seq[LoadedShotLog]
      ## shot logs read this run, in the order they were imported or loaded
    follow: ShotFollow ## per loaded log, its index and its own last answer
    shotRows: ShotRows ## the rows chosen in a loaded shot log (`ckSelectShotRows`)
    stJob: JobId = NoJob
      ## the job that makes `stMap`, the traces of the file shown told to the rows of a log
    stSink: ShotTraceSink
    stKey: tuple[session, keys, log, revision: int]
      ## the file, its keys' revision, the log and its revision `stMap` (or the job) is for
    stMap: ShotTraceMap
    stHave: bool ## `stMap` is the answer for `stKey`
    stWant: int = -1
    stSelRev: int
      ## the trace selection's revision once the click `stWant` is for had made its changes: the
      ## answer is dropped when it is not the same (something else changed the selection)
    stShown: tuple[file, gather: int]
      ## the file and gather the main panel showed at that click: the answer does not jump when
      ## the user stepped to another record
    stRemoved: seq[int]
      ## rows taken out of the choice while the map was not ready: their traces are taken out
      ## when it answers
      ## the revision of the rows chosen whose traces are selected when the job answers; -1 none
    followTrace: int = -1
      ## last seismic trace hovered while this file is on show; -1 until one is
    followShown: int
      ## id of the file on show when `followTrace` was taken; 0 when none is
    shotLogsRev: int ## bumps when that list, or a log's view, changes
    nextShotId: int
    shotWork: seq[ShotLogWork]
      ## jobs reading or writing a shot log; the sink is read when the job ends
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
    spectra: seq[SpectrumWindow]
      ## the live spectrum panel first, then the FFT windows in the order opened
    spectrumGen: uint64 ## the newest spectrum request's
    liveKey: LiveKey ## what the live panel asked for last
    spectrumReader: SpectrumReader
      ## computes the spectra; started when first asked. Last: it stops (and
      ## ends its holds) first.
    leftSpectrumReaders: seq[SpectrumReader]
      ## spectrum readers left stuck in a drive that does not answer
    plots: seq[AnalysisWindow] ## the analysis windows (New plot), in the order opened
    plotGen: uint64 ## the newest analysis request's
    analysisReader: AnalysisReader
      ## works the analysis windows out; started when first asked
    leftAnalysisReaders: seq[AnalysisReader]
      ## analysis readers left stuck in a drive that does not answer

proc addPanel*(state: var AppState; role = prSeismic): PanelId =
  ## Another trace panel, empty until a file is shown in it.
  result = PanelId(state.nextPanel)
  inc state.nextPanel
  state.panels.add Panel(id: result, role: role)
  state.tiles.add newSeq[Tile]()
  state.readers.add PanelReader()

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
    batchSurvey: SurveyHolds(),
    jobs: initJobs(jobHistory), indexCache: indexCache, nextFile: 1,
    nextPanel: int(MainPanel) + 1, nextTile: 1, scratch: initWorkspace(),
    files: FileList(job: NoJob), watchEvery: watchEvery, quietScan: NoJob, kindJob: NoJob,
    pairSearch: (NoJob, "", NoPanel, coWindow),
    preparing: (NoJob, ""), prepared: (NoJob, nil), memoryJob: NoJob,
    compareJobA: NoJob, compareJobB: NoJob, comparePicJob: NoJob,
    vendor: VendorState(job: NoJob), correlateLimit: MaxPrepareBytes)
  result.panels.add Panel(id: MainPanel)
  result.tiles.add newSeq[Tile]()
  result.readers.add PanelReader()
  result.spectra.add SpectrumWindow(id: LiveSpectrum, chosen: soNothing,
    display: result.settings.spectrum.live, panel: MainPanel)

let ProgramStart* = getTime()
  ## when the program started: a temporary file of the store last written
  ## well before it is what a write cut short left (`DiskIo.sweep`)

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

proc leapFilePath*(state: AppState): string =
  ## Where the leap-second table is saved; "" when settings are not kept.
  if state.configDir.len == 0 or not state.keepsSettings: ""
  else: leapPath(state.configDir)

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
  if state.project.dir.len == 0: state.vibLayouts = state.settings.vibRoles
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

proc offerThemes*(state: var AppState; names: seq[string]) =
  ## The themes the frontend can draw in (its theme files' names, as View >
  ## Theme lists them): `ckTheme` takes one of them, and agents are told.
  state.themeNames = names

func themeNames*(state: AppState): lent seq[string] {.inline.} =
  ## The themes `offerThemes` gave; none when no frontend said.
  state.themeNames

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

proc saveSettings(state: var AppState; first = false) =
  ## Hands the settings to the disk thread; `first`: before what waits there.
  let file = state.settingsFile
  if file.len > 0:
    state.disk.replace(file, settingsDocument(state.kept), "the settings", first = first)
  state.savedRev = state.keptRev

proc saveArrangement(state: var AppState; first = false) =
  ## Hands the window layout to the disk thread; `first`: before what waits
  ## there. While a project is open, it is the project's (in its folder).
  if state.arrangement.len > 0:
    if state.project.dir.len > 0:
      if not state.project.readOnly:
        state.diskIo.replace(state.project.dir / ProjectLayoutName,
          layoutDocument(Layout(imgui: state.arrangement)), "the project's window layout",
          first = first)
    elif state.configDir.len > 0:
      state.disk.replace(state.configDir / LayoutFileName,
        layoutDocument(Layout(imgui: state.arrangement)), "the window layout", first = first)
  state.layoutSaved = state.layoutRev

proc saveProject(state: var AppState; first = false) =
  ## Hands the project's document to the disk thread, when it changed;
  ## `first`: before what waits there. A project opened read-only is never
  ## written.
  template p: untyped = state.project
  if p.dir.len > 0 and not p.readOnly and p.docRev != p.savedRev:
    state.diskIo.replace(documentOf(p.dir), projectDocument(p.doc), "the project " &
      p.doc.name, first = first)
  p.savedRev = p.docRev

# ----------------------------------------------------------- file memory --

proc loadReferences(state: var AppState; folder: string; main: bool)

proc rememberFilesIn*(state: var AppState; dir: string) =
  ## From now on, remembers the trace edits of the files opened (the user's
  ## own: `keeps`) in `dir`'s `StoreFolder` (`core/filememory`), by each
  ## file's identity, and brings them back when a file of that identity is
  ## opened again, under any name. Without it nothing is remembered. The
  ## temporary files a write cut short left there are removed
  ## (`DiskIo.sweep`).
  assertUiThread()
  state.store = Store(home: dir / StoreFolder)
  state.userStore = state.store.home
  state.diskIo.sweep(state.store.home, ProgramStart) # what a write cut short left
  state.mainRefsHome = referencesFolder(dir)
  if state.project.dir.len == 0:
    state.refsHome = state.mainRefsHome
    state.chosenRef = state.settings.referenceId
    state.vibLayouts = state.settings.vibRoles
    state.loadReferences(state.mainRefsHome, main = true)

func store*(state: AppState): lent Store {.inline.} =
  ## Where what is remembered about files is kept.
  state.store

func references*(state: AppState): lent ReferenceIndex {.inline.} =
  ## The reference archive in force, as last read.
  state.refs

func mainReferences*(state: AppState): lent ReferenceIndex {.inline.} =
  ## The program's own reference archive, listed beside a project's.
  state.mainRefs

func chosenReference*(state: AppState): string {.inline.} =
  ## The reference the plots use; "" is none.
  state.chosenRef

proc setCorrelateLimit*(state: var AppState; bytes: int64) =
  ## A correlated copy of more than `bytes` bytes is not held in memory: Correlate then
  ## shows a view that correlates what is read. Starts at `MaxPrepareBytes`.
  state.correlateLimit = bytes

func correlateOn*(state: AppState): bool {.inline.} =
  ## Whether the Seismic window is set to show the correlated record.
  state.correlateOn

func correlateNote*(state: AppState): string {.inline.} =
  ## A sentence for the status line while correlating; "" for none. Not the hover.
  state.correlateNote

func profileNoted*(state: AppState): bool {.inline.} =
  ## Whether the status line should say the vibrator QC profile was stored.
  state.profileNoted

func correlating*(state: AppState): bool {.inline.} =
  ## Whether a correlation is running.
  not state.correlate.isNil and state.correlate.job != NoJob

func referencesHome*(state: AppState): string {.inline.} =
  ## The folder of the archive in force; "" when none was set.
  state.refsHome

func referencesLoaded*(state: AppState): bool {.inline.} =
  ## Whether the archive in force has been read this run.
  state.refsLoaded

func pilotPreview*(state: AppState): lent PilotPreview {.inline.} =
  ## The pilot of the record on show that the Generate dialog asked for.
  state.pilotShown

func refViews*(state: AppState): lent seq[RefView] {.inline.} =
  ## The windows showing a reference.
  state.refViews

func referenceArchiveTitle*(state: AppState): string =
  ## Which archive the window shows: the project's name, or the main one.
  if state.project.dir.len > 0: "project " & state.project.doc.name else: "main"

func keyOf(state: AppState; path: string): string =
  ## The key of `edits` of the file at `path`: the file on disk (a derived
  ## session's origin), or that of another path of the same file opened this
  ## run (`linkSame`).
  let path = diskOf(path)
  state.editKey.getOrDefault(path, path)

func rememberedAt(state: AppState; path: string): int =
  let path = diskOf(path)
  for i, r in state.remembered:
    if r.path == path: return i
  -1

func remembering*(state: AppState; path: string): tuple[known, confirmed, looking: bool;
    doc: string; identity: FileIdentity] =
  ## Where the file at `path` (opened this run) stands in what is
  ## remembered: its identity `known` (the quick one), `confirmed` by the
  ## hash of every byte, the jobs still `looking`, and the store's document
  ## its edits are kept in ("" for none).
  let i = state.rememberedAt(path)
  if i >= 0:
    let r = state.remembered[i]
    result = (r.known, r.hashed, r.job != NoJob or r.hashJob != NoJob, r.doc, r.identity)

func recordOf(state: AppState; i: int): FileRecord =
  ## What the document of `remembered[i]` holds now: the file's identity,
  ## where and when it was seen, and the edits kept.
  let r = state.remembered[i]
  result = FileRecord(identity: r.identity, name: r.path.extractFilename, path: r.path,
    opened: r.opened, modified: r.modified, doc: r.doc)
  for s in state.sessions:
    if s.path == r.path: result.traces = s.len
  if state.keyOf(r.path) in state.edits: result.edits = state.edits[state.keyOf(r.path)].kept
  if r.doc in state.knownDocs:
    result.later = state.knownDocs[r.doc].later # a later version's
    # (as the document was read: the disk thread keeps it as it is on disk, `DiskIo.treat`)
    result.treat = state.knownDocs[r.doc].treat

func treatInForce(state: AppState; path: string): TreatAs =
  ## What jobs use as the file's forced treatment: what the commands set and what the file's
  ## hash confirmed, never what a listing found in a document not yet confirmed.
  state.treats.getOrDefault(path)

func shownTreat(state: AppState; path: string): TreatAs =
  ## What the file is shown as treated as: what is in force, and under it, for the parts none
  ## of it sets, what a listing found in a document not yet confirmed.
  result = state.treats.getOrDefault(path)
  let p = state.treatsPending.getOrDefault(path)
  if result.kind.isNone: result.kind = p.kind
  if result.grouping.isNone: result.grouping = p.grouping
  if result.subSort.isNone: result.subSort = p.subSort

func pendingParts(state: AppState; path: string): set[TreatPart] =
  ## The parts of the choice shown for the file at `path` (canonical) that no job uses yet: a
  ## listing found them in a document that may be another content's (`treatsPending`).
  let p = state.treatsPending.getOrDefault(path)
  if p.kind.isSome: result.incl tpKind
  if p.grouping.isSome: result.incl tpGrouping
  if p.subSort.isSome: result.incl tpSubSort

func showTreat(state: AppState; e: var FileEntry) =
  e.treat = state.shownTreat(e.path)
  e.treatPending = state.pendingParts(e.path)

proc loadTreat(state: var AppState; path: string; t: TreatAs; pending = false) =
  ## What the store keeps of what the user forced for the file at `path`, as its document was
  ## read: by the kinds of a listing (`takeKinds`), or with the document an open takes
  ## (`applyRecord`). A choice made by a command this session stays.
  let own = state.treatsOwn.getOrDefault(path)
  if pending:
    # (only the parts no command of this session set)
    let rest = t.merged(TreatAs(), own)
    if rest.isSet: state.treatsPending[path] = rest else: state.treatsPending.del path
    if path notin state.treatsTouched:
      state.treats.del path
      state.treatsKept.del path
  else:
    state.treatsPending.del path
    # (the commands' parts stay over what the document says)
    let now = t.merged(state.treats.getOrDefault(path), own)
    let kept = t.merged(state.treatsKept.getOrDefault(path),
      state.treatsOwnKept.getOrDefault(path))
    if now.isSet: state.treats[path] = now else: state.treats.del path
    if kept.isSet: state.treatsKept[path] = kept else: state.treatsKept.del path
  let i = state.files.find(path)
  if i >= 0:
    let shown = state.shownTreat(path)
    if state.files.entries[i].treat != shown or
        state.files.entries[i].treatPending != state.pendingParts(path):
      state.showTreat(state.files.entries[i])
      state.files.changedAt(i)

func checking(r: Remembered): bool {.inline.} =
  ## Whether the edits brought back for `r`'s file wait for the hash of every
  ## byte to be confirmed. A document brought back with none (only what the
  ## file is treated as) and without a hash of its own has nothing to confirm,
  ## and nothing could tell it from another file's: edits are written into it,
  ## as into a document of the file's own.
  not r.hashed and r.brought.doc.len > 0 and
    (not r.brought.edits.isEmpty or r.brought.identity.fullKnown)

func knownIdentity(state: AppState; path: string): FileIdentity =
  ## The identity of the file at `path` as this run knows it: an open file's, else that of the
  ## last choice remembered for it (`treatDocs`); the hash of every byte only when one was taken.
  let i = state.rememberedAt(path)
  if i >= 0 and state.remembered[i].known and state.remembered[i].hashed:
    state.remembered[i].identity
  else: state.treatDocs.getOrDefault(path).identity

func treatHint(state: AppState; path: string): FileRecord =
  ## What this run knows of the document that keeps the user's choice for the file at `path`:
  ## an open file's document (unless its edits brought back are being checked), else the one
  ## the last choice went to; with the file's identity, and the hash of every byte when one was
  ## taken.
  result = FileRecord(identity: state.knownIdentity(path))
  let i = state.rememberedAt(path)
  if i >= 0 and state.remembered[i].known and state.remembered[i].doc.len > 0 and
      not state.remembered[i].checking:
    result = FileRecord(doc: state.remembered[i].doc, identity: state.remembered[i].identity)
  elif path in state.treatDocs: result = state.treatDocs[path]

proc carryTreat(state: var AppState; carried: TreatAs; doc, path: string) =
  ## Puts the parts of `carried` (what a document that goes said its file is treated as) into
  ## the document `doc` of the same file, where that one says none (`DiskIo.treat`); nothing
  ## for a document this run neither read nor wrote. A part the user set for the file at `path`
  ## this session is theirs, not carried.
  if state.store.isNowhere or (state.project.dir.len > 0 and state.project.readOnly) or
      doc notin state.knownDocs:
    return
  let kept = state.knownDocs[doc]
  var parts: set[TreatPart] = {}
  if carried.kind.isSome and kept.treat.kind.isNone: parts.incl tpKind
  if carried.grouping.isSome and kept.treat.grouping.isNone: parts.incl tpGrouping
  if carried.subSort.isSome and kept.treat.subSort.isNone: parts.incl tpSubSort
  parts = parts - state.treatsOwnKept.getOrDefault(path)
  state.diskIo.treat(state.store.docPath(doc), FileRecord(identity: kept.identity,
    name: kept.name, path: kept.path, opened: kept.opened, modified: kept.modified, doc: doc,
    treat: carried), parts, "what is remembered about " & kept.name,
    if kept.stamp.modified == Time(): NoDoc else: kept.stamp)
  state.knownDocs[doc].treat = kept.treat.merged(carried, parts)

proc takeTreatFrom(state: var AppState; other: FileRecord; doc, path: string) =
  ## What the document `other` of the same content says the file is treated as joins the document
  ## `doc` (as `carryTreat` does) once, and goes from `other`, which stays (it has edits): a
  ## later choice of automatic in `doc` is then not undone by it. The disk thread leaves it out
  ## of `other` only once `doc` holds it; nothing for a document this run neither read nor wrote.
  if not other.treat.isSet or state.store.isNowhere or
      (state.project.dir.len > 0 and state.project.readOnly) or doc notin state.knownDocs:
    return
  let kept = state.knownDocs[doc]
  let carried = other.treat
  var parts: set[TreatPart] = {}
  if carried.kind.isSome and kept.treat.kind.isNone: parts.incl tpKind
  if carried.grouping.isSome and kept.treat.grouping.isNone: parts.incl tpGrouping
  if carried.subSort.isSome and kept.treat.subSort.isNone: parts.incl tpSubSort
  parts = parts - state.treatsOwnKept.getOrDefault(path) # (the user's choice for the file)
  var leaves: set[TreatPart] = {}
  if carried.kind.isSome: leaves.incl tpKind
  if carried.grouping.isSome: leaves.incl tpGrouping
  if carried.subSort.isSome: leaves.incl tpSubSort
  var bare = other
  bare.treat = TreatAs()
  state.diskIo.moveTreat(state.store.docPath(doc), FileRecord(identity: kept.identity,
    name: kept.name, path: kept.path, opened: kept.opened, modified: kept.modified, doc: doc,
    treat: carried), parts, state.store.docPath(other.doc), bare, leaves,
    "what is remembered about " & kept.name,
    if kept.stamp.modified == Time(): NoDoc else: kept.stamp,
    if other.stamp.modified == Time(): NoDoc else: other.stamp)
  state.knownDocs[doc].treat = kept.treat.merged(carried, parts)

proc handTreat(state: var AppState; path, doc: string; id: FileIdentity; modified: Time) =
  ## Hands the disk thread the parts of the user's choice for the file at `path` changed since
  ## the last time (`treatParts`), as they are now, for its document `doc` (`DiskIo.treat`).
  if state.store.isNowhere or (state.project.dir.len > 0 and state.project.readOnly): return
  let name = path.extractFilename
  state.treatDocs[path] = FileRecord(doc: doc, identity: id, modified: modified)
  # an open file without a document yet takes this one, so its edits join the choice
  let i = state.rememberedAt(path)
  if i >= 0 and state.remembered[i].known and state.remembered[i].doc.len == 0 and
      state.remembered[i].identity.size == id.size and
      state.remembered[i].identity.quick == id.quick:
    (state.remembered[i].doc, state.remembered[i].ownDoc) = (doc, true)
  var parts: set[TreatPart] = {}
  discard state.treatParts.pop(path, parts)
  let was = state.knownDocs.getOrDefault(doc)
  state.diskIo.treat(state.store.docPath(doc), FileRecord(identity: id, name: name, path: path,
    opened: getTime(), modified: modified, doc: doc, treat: state.treatsKept.getOrDefault(path),
    stamp: (-1'i64, Time(), 0'i64)), parts, "what is remembered about " & name,
    if was.stamp.modified == Time(): NoDoc else: was.stamp)
  if doc in state.knownDocs: # (what later decisions see of it: what was handed over)
    state.knownDocs[doc].treat = state.knownDocs[doc].treat.merged(
      state.treatsKept.getOrDefault(path), parts)

proc hashFile(state: var AppState; i: int) =
  ## Hashes every byte of `remembered[i]`'s file, on the lane of hashes (a
  ## large file's hash never holds the background work), unless that is
  ## known or under way.
  template r: untyped = state.remembered[i]
  if r.known and not r.hashed and r.hashJob == NoJob:
    let name = r.path.extractFilename
    r.hashJob = state.jobs.submit(JobSpec(title: "Confirm what " & name & " holds",
      lane: jlHashes), fullHashWork(r.path, FileIdentity(size: r.identity.size,
      quick: r.identity.quick), r.modified, state.inbox.poster))
    state.memoryWork.add r.hashJob

proc readOnlyProject(state: AppState): bool =
  ## A project is open and another program has it: nothing is written into
  ## its store (what is remembered is kept in memory for the session).
  state.project.dir.len > 0 and state.project.readOnly

proc dropPending(state: var AppState; i: int) =
  ## Removes `remembered[i]`'s pending document, if it has one.
  template r: untyped = state.remembered[i]
  if r.pending:
    if not state.readOnlyProject:
      state.diskIo.remove(state.store.docPath(pendingName(r.path)),
        "the edits of " & r.path.extractFilename & " kept by its path")
    r.pending = false

proc writePending(state: var AppState; i: int) =
  ## Keeps the edits of `remembered[i]`'s file, whose identity is not known
  ## yet, by its path, size and modification time (`pendingName`), so that
  ## a quit before the identity comes loses none of them.
  template r: untyped = state.remembered[i]
  if state.keyOf(r.path) notin state.edits: return
  template e: untyped = state.edits[state.keyOf(r.path)]
  r.pendingRev = e.keptRevision
  if e.kept.isEmpty: state.dropPending(i)
  else:
    # Merged by the disk thread with a pending document an earlier run left
    # (its drive did not answer then either), never written over: what that
    # one kept comes back as an `mkMemoryMerged` (`takeMerged`).
    state.diskIo.replace(state.store.docPath(pendingName(r.path)), FileRecord(
      identity: FileIdentity(size: r.size), name: r.path.extractFilename, path: r.path,
      opened: r.opened, modified: r.openModified, edits: e.kept),
      "the edits of " & r.path.extractFilename & " kept by its path", EditLists(), NoDoc)
    r.pending = true

proc dropProvisional(state: var AppState; i: int) =
  ## Removes the documents of `remembered[i]`'s edits that no hash has
  ## confirmed (`provDocs`): their edits are in its own document by now.
  template r: untyped = state.remembered[i]
  for d in r.provDocs:
    if not state.readOnlyProject:
      state.diskIo.remove(state.store.docPath(d), "what is remembered about " &
        r.path.extractFilename & " (unconfirmed)")
    state.knownDocs.del d
    for path, list in state.earlier.mpairs: # perhaps offered to another file meanwhile
      list.keepItIf(it.doc != d)
  r.provDocs.setLen 0

proc writeProvisional(state: var AppState; i: int) =
  ## While `remembered[i]`'s brought document is being checked: the document
  ## itself is not written. When the user changed anything since it was
  ## brought back (an edit given or taken off), the whole state as the user
  ## has it goes into an unconfirmed record of its own (the quick identity
  ## and modification time, no hash of every byte): never applied by itself
  ## when the file is opened again. None when nothing changed.
  template r: untyped = state.remembered[i]
  let key = state.keyOf(r.path)
  r.savedRev = if key in state.edits: state.edits[key].keptRevision else: 0
  let now = if key in state.edits: state.edits[key].kept else: EditLists()
  if now == r.brought.edits:
    state.dropProvisional(i)
    return
  var rec = FileRecord(identity: FileIdentity(size: r.identity.size, quick: r.identity.quick),
    name: r.path.extractFilename, path: r.path, opened: getTime(), modified: r.modified,
    edits: now, unconfirmed: true)
  for s in state.sessions:
    if s.path == r.path: rec.traces = s.len
  if r.provDocs.len == 0:
    var taken = r.waiting.mapIt(it.doc) & r.taken
    for x in state.remembered:
      taken.add x.doc
      taken.add x.provDocs
    for d in state.knownDocs.keys: taken.add d
    r.provDocs.add freeDocName(rec.identity, taken)
  rec.doc = r.provDocs[0]
  state.knownDocs[rec.doc] = rec
  state.diskIo.replace(state.store.docPath(rec.doc), move rec, "the edits made on " &
    r.path.extractFilename & " while what is remembered was being checked")
  for d in r.provDocs[1 .. ^1]:
    state.diskIo.remove(state.store.docPath(d), "what is remembered about " &
      r.path.extractFilename & " (unconfirmed)")
    state.knownDocs.del d
  r.provDocs.setLen 1

proc writeMemoryDoc(state: var AppState; i: int) =
  ## Hands `remembered[i]`'s document to the disk thread, or its removal
  ## when it keeps nothing.
  template r: untyped = state.remembered[i]
  if r.checking:
    state.writeProvisional(i)
    return
  let name = r.path.extractFilename
  var rec = state.recordOf(i)
  let key = state.keyOf(r.path)
  r.savedRev = if key in state.edits: state.edits[key].keptRevision else: 0
  if r.seenAside: # the document is written whole now: its own time
    state.diskIo.remove(state.store.docPath(r.doc).seenName, "when " & name & " was opened")
    r.seenAside = false
  if r.doc.len == 0 and not rec.edits.isEmpty:
    # A document of only what the file is treated as, without a hash, that waits for the
    # file's (it saw another time): the edits join it, as `takeHashed` would have it.
    let bare = r.waiting.filterIt(not it.identity.fullKnown and it.edits.isEmpty)
    if bare.len == 1:
      (r.doc, r.ownDoc) = (bare[0].doc, true)
      state.knownDocs[r.doc] = bare[0]
      (rec.doc, rec.later, rec.treat) = (r.doc, bare[0].later, bare[0].treat)
  # What the document held as this run last read or wrote it: another
  # viewSEG's change since is merged in by the disk thread.
  let (base, expect) = block:
    let was = state.knownDocs.getOrDefault(r.doc)
    (was.edits, if was.stamp.modified == Time(): NoDoc else: was.stamp)
  if rec.edits.isEmpty: # (the disk thread keeps a document that says what the file is treated as)
    if r.doc.len > 0:
      state.diskIo.removeMerging(state.store.docPath(r.doc), move rec, "what is remembered about " &
        name, base, expect)
      state.knownDocs.del r.doc
    state.dropPending(i)
    state.dropProvisional(i)
    return
  if r.doc.len == 0: # the same file under another path may have one
    for x in state.remembered:
      if x.doc.len > 0 and r.doc.len == 0 and state.keyOf(x.path) == state.keyOf(r.path):
        (r.doc, r.ownDoc) = (x.doc, x.ownDoc)
    rec.doc = r.doc
  if r.doc.len == 0:
    var taken = r.waiting.mapIt(it.doc) & r.taken
    for x in state.remembered:
      taken.add x.doc
      taken.add x.provDocs
    for d in state.knownDocs.keys: taken.add d
    r.doc = freeDocName(r.identity, taken)
    r.ownDoc = true
    rec.doc = r.doc
  state.knownDocs[r.doc] = rec
  state.diskIo.replace(state.store.docPath(r.doc), move rec, "what is remembered about " & name,
    base, expect)
  state.dropPending(i) # written after the document: the edits are never on neither
  state.dropProvisional(i)
  for x in state.remembered.mitems: # the other paths of the file: written with it
    if x.doc == r.doc: x.savedRev = r.savedRev
  if not r.identity.fullKnown: state.hashFile(i)

proc saveMemory(state: var AppState; now: MonoTime; force: bool) =
  ## Hands the disk thread the documents of the files whose kept edits
  ## changed `SaveDelay` ago or more (with `force`, every one changed). A
  ## file whose identity is not known yet waits for it. A project opened
  ## read-only keeps them for the session.
  if state.store.isNowhere or (state.project.dir.len > 0 and state.project.readOnly): return
  for i in 0 ..< state.remembered.len:
    template r: untyped = state.remembered[i]
    if not r.known and state.keyOf(r.path) in state.edits and
        state.edits[state.keyOf(r.path)].keptRevision != r.pendingRev and
        state.edits[state.keyOf(r.path)].keptRevision != r.savedRev:
      if r.changedAt == MonoTime(): r.changedAt = now
      if force or now - r.changedAt >= SaveDelay:
        state.writePending(i)
        r.changedAt = MonoTime()
    elif r.known and state.keyOf(r.path) in state.edits:
      let rev = state.edits[state.keyOf(r.path)].keptRevision
      if rev != r.savedRev:
        if r.changedAt == MonoTime(): r.changedAt = now
        if force or now - r.changedAt >= SaveDelay:
          state.writeMemoryDoc(i)
          r.changedAt = MonoTime()

proc sayProfileChange(state: var AppState; now: MonoTime; force: bool) =
  ## Tells the Messages window, once and in words, what changed in the project's
  ## vibrator QC profile since it was last said, when it has stayed as it is for
  ## `SaveDelay` (a drag or typing is one note, not one per step).
  if state.profileNoteAt == MonoTime(): return
  if not force and now - state.profileNoteAt < SaveDelay: return
  state.profileNoteAt = MonoTime()
  let words = changeWords(state.profileNoteBase, state.project.doc.vibProfile)
  if words.len > 0:
    state.log.add(sevInfo, "vibrator QC", "Vibrator QC profile: " & words.join(", ") &
      (if state.profileNoteFile.len > 0: " (from " & state.profileNoteFile & ")" else: ""))

proc persist*(state: var AppState; now = getMonoTime()) =
  ## Hands what is due to the disk thread: what was logged since the last
  ## call, and the settings and the arrangement once `SaveDelay` has passed
  ## since they last changed. Call it once per frame, after the frame's
  ## commands; it never waits.
  assertUiThread()
  state.sayProfileChange(now, force = false)
  state.writeLog()
  if state.savedRev != state.keptRev and now - state.changedAt >= SaveDelay:
    state.saveSettings()
  if state.layoutSaved != state.layoutRev and now - state.layoutAt >= SaveDelay:
    state.saveArrangement()
  if state.project.docRev != state.project.savedRev and
      now - state.project.changedAt >= SaveDelay:
    state.saveProject()
  state.saveMemory(now, force = false)

proc flushFiles*(state: var AppState) =
  ## Saves what is due now, without waiting for `SaveDelay`, and waits
  ## until the disk thread has written everything handed to it (tests).
  assertUiThread()
  state.sayProfileChange(getMonoTime(), force = true)
  state.writeLog()
  if state.savedRev != state.keptRev: state.saveSettings()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  state.saveProject()
  state.saveMemory(getMonoTime(), force = true)
  state.disk.flush()

const
  QuitWait* = initDuration(milliseconds = 800)
    ## how long `shutdown` waits, at most, for the threads to end, and for
    ## any one write of the disk thread
  DiskQuitLimit* = initDuration(seconds = 5)
    ## how long `shutdown` waits, at most, for a disk thread that goes on
    ## writing (a slow disk, a loaded machine): the settings, the layout
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
  for c in state.batchSurvey.held: GC_ref(c.geometry) # a batch write joins from it
  for c in state.batchSurvey.left: GC_ref(c.geometry)
  if not state.joining.geometry.isNil: GC_ref(state.joining.geometry) # `joinApplyWork` reads it
  if not state.joining.relations.isNil: GC_ref(state.joining.relations)
  for r in state.joining.reused: GC_ref(r) # `joinReadWork` reads them
  if not state.project.geometry.isNil: GC_ref(state.project.geometry) # `planWork` reads it
  # A correlation writes through `addr hold.result` until its job returns.
  # Toggle off, a close and a second correlate retire the hold (`dropHold`);
  # only the quit frees `AppState` under a job that has not returned.
  if not state.correlate.isNil: GC_ref(state.correlate)
  for h in state.correlateRetired:
    if not h.isNil: GC_ref(h)

proc shutdown*(state: var AppState; wait = QuitWait; diskLimit = DiskQuitLimit;
    tick: proc () {.closure, raises: [].} = nil): bool {.discardable.} =
  ## Asks every thread to end at once (the panels' readers, the watch, the
  ## jobs: every job is cancelled), hands what is left to save to the disk
  ## thread (the settings and the layout before what waits there, then the
  ## documents of what is remembered and the session log), and waits for
  ## them all, together, at most `wait`; the disk thread, while it goes on
  ## writing, up to `diskLimit`, but no longer than `wait` for any one write;
  ## then `CloseWait` for the files to be closed (on the closer's thread):
  ## true when all ended. A thread held by a drive that does not answer is
  ## left to end on its own, with what it may read (`keepForStragglers`), so
  ## the quit never waits for a drive; what the disk thread did not write is
  ## said (the log, and standard error: the window is gone). `tick`, when
  ## given, is called about every 16 ms while the disk thread is waited for
  ## (the frontend draws). Destroying the state does this too.
  assertUiThread()
  state.analysisReader.askStop()
  state.spectrumReader.askStop()
  state.inspector.askStop()
  for r in state.readers: r.askStop()
  state.watch.askStop()
  state.jobs.askStop()
  if state.savedRev != state.keptRev: state.saveSettings(first = true)
  if state.layoutSaved != state.layoutRev: state.saveArrangement(first = true)
  state.saveProject(first = true)
  state.saveMemory(getMonoTime(), force = true)
  for path in toSeq(state.treatJobs.keys): # a choice whose look-up had not ended
    let hint = state.treatHint(path)
    let name = path.extractFilename
    if hint.doc.len > 0: state.handTreat(path, hint.doc, hint.identity, hint.modified)
    else:
      state.log.add(sevWarning, name, "The choice for " & name & " is kept for this session " &
        "only: viewSEG quit before its look-up ended.")
  state.treatJobs.clear()
  for r in state.remembered:
    if not r.known and r.pending:
      let name = r.path.extractFilename
      state.log.add(sevInfo, name, "The edits of " & name & " are kept by its path: viewSEG " &
        "could not read its first and last bytes before the quit. Opened again, unchanged, " &
        "it shows them, and they are remembered with it then.")
  state.writeLog()
  state.disk.askStop()
  let deadline = getMonoTime() + wait
  result = true
  for r in state.readers:
    if not r.stop(deadline): result = false
  if not state.inspector.stop(deadline): result = false
  for x in state.leftInspectors:
    if not x.stop(deadline): result = false
  if not state.spectrumReader.stop(deadline): result = false
  for x in state.leftSpectrumReaders:
    if not x.stop(deadline): result = false
  if not state.analysisReader.stop(deadline): result = false
  for x in state.leftAnalysisReaders:
    if not x.stop(deadline): result = false
  state.watch.stop(deadline)
  if not state.jobs.stop(deadline): result = false
  # The disk thread: as long as it goes on writing (what the user set must
  # not be lost to a slow disk or a loaded machine), but not on a write a
  # drive does not answer.
  let began = deadline - wait
  if state.project.lock.locked: fs.unlock(state.project.lock) # (the quit lets it go anyway)
  if not state.disk.stop(began + diskLimit, stuckAfter = wait, tick = tick):
    result = false
    let held = state.disk.stuckOn
    let why = if getMonoTime() >= began + diskLimit:
                "the disk had not finished in " & $diskLimit.inSeconds & " s"
              else: "the drive did not answer for " & $wait.inMilliseconds & " ms"
    let text = "Quit without waiting longer: " & why & (if held.len > 0: "; not written: " &
      held else: "") & "."
    state.log.add(sevWarning, "files", text)
    try:
      stderr.writeLine "viewSEG: ", text
    except IOError:
      discard # no standard error: the log has it
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

func compareA*(state: AppState): lent CompareSlot {.inline.} =
  ## Compare slot A. Its copy does not follow the plot or the file.
  state.compareA

func compareB*(state: AppState): lent CompareSlot {.inline.} =
  ## Compare slot B.
  state.compareB

func compareOptions*(state: AppState): lent CompareOptions {.inline.} =
  ## How the compare window aligns B and what it draws.
  state.compareOptions

func comparePicture*(state: AppState): lent ComparePicture {.inline.} =
  ## The curves and the table of the two slots, as last worked out.
  state.comparePicture

func compareOpen*(state: AppState): bool {.inline.} =
  ## Whether the compare window is open.
  state.compareOpen

func compareRevision*(state: AppState): int {.inline.} =
  ## Bumps when a new picture arrives. The one on screen stays until then.
  state.compareRevision

func compareChip*(state: AppState; which: CompareWhich): string =
  ## The chip of slot `which`: file, trace, time window, and B's alignment.
  let align = if which == cwB: state.comparePicture.alignNote else: ""
  chipText(if which == cwB: state.compareB else: state.compareA, which, align)

func compareLetters*(state: AppState; path: string; trace: int): string =
  ## "A", "B" or "AB" when a filled slot was fed by file-index `trace`
  ## (from 0) of `path`; "" otherwise.
  if path.len == 0: return ""
  if state.compareA.filled and state.compareA.path == path and
      state.compareA.trace == trace + 1:
    result.add "A"
  if state.compareB.filled and state.compareB.path == path and
      state.compareB.trace == trace + 1:
    result.add "B"

func compareBadge*(state: AppState; path: string): string =
  ## "A", "B" or "AB" when a filled slot was fed by the file at `path`.
  if path.len == 0: return ""
  if state.compareA.filled and state.compareA.path == path: result.add "A"
  if state.compareB.filled and state.compareB.path == path: result.add "B"

func compareWaiting*(state: AppState): bool {.inline.} =
  ## Whether a slot is still being copied.
  state.compareA.waiting or state.compareB.waiting

func spectra*(state: AppState): lent seq[SpectrumWindow] {.inline.} =
  ## The spectrum windows: the live panel first (id 0), then the FFT
  ## windows in the order opened.
  state.spectra

func findSpectrum*(state: AppState; id: int): int =
  ## The index in `spectra` of window `id`; -1 when there is none.
  for i, w in state.spectra:
    if w.id == id: return i
  -1

proc spectrumSamplesHeld*(state: AppState): int =
  ## The samples of traces the spectrum reader keeps at hand (none once no
  ## spectrum window needs them).
  state.spectrumReader.held

func spectraWaiting*(state: AppState): bool =
  ## Whether a spectrum window waits for its spectrum.
  for w in state.spectra:
    if w.waiting: return true
  false

func cachedTraceColumns*(state: AppState): int =
  ## Whole columns the trace table still holds, plus its order and catalogue.
  if state.inspector.isNil: 0 else: state.inspector.cachedColumns

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

func auxOpen*(state: AppState): bool {.inline.} =
  ## Whether the Aux window is open (`ckAuxWindow`).
  state.auxOpen

func auxIndex*(state: AppState): int =
  ## The index in `panels` of the Aux window's panel; -1 while it was never opened.
  result = -1
  for i, p in state.panels:
    if p.role == prAux: return i

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

const
  CutNeedFile* = "Show a seismic file first: it is the recording that is sliced."
  CutNeedLog* = "Load a shot log first (Project > Import shot log): its times are where " &
    "the recording is sliced."
  CutNeedBoth* = "Show a seismic file and load a shot log first."
  CutRunning* = "A slice is already running."
  CutDerived* = "The window shows a correlated view: show the file itself to slice it."
  CutSignature* = "A signature file is not a recording that can be sliced."

func notices*(state: AppState): lent seq[Notice] {.inline.} =
  ## The newest notices, oldest first: what background jobs had to say
  ## when they ended. Each has its own `serial`.
  state.notices

func project*(state: AppState): lent ProjectState {.inline.} =
  ## The project open; `dir` "" for none.
  state.project

func projectSurvey*(state: AppState): ptr SurveyGeometry =
  ## The project's survey as its joins read it, or nil when the project has
  ## none that can be matched (no project, none made yet, or it failed to be
  ## restored). The state keeps it alive; a job that reads it must end first
  ## when the project closes.
  if state.project.dir.len > 0 and state.project.doc.hasSurvey and
      state.project.survey != srFailed and not state.project.geometry.isNil:
    cast[ptr SurveyGeometry](state.project.geometry)
  else: nil

func projectSurveyLoading*(state: AppState): bool =
  ## Whether the project has a survey that is not ready to be joined yet.
  state.project.dir.len > 0 and state.project.doc.hasSurvey and
    state.project.survey != srFailed and state.project.geometry.isNil

func projectTableOnly*(state: AppState): bool =
  ## Whether the project's survey is CSV tables only, which a file joins with
  ## the table alone (`applyGeometry`), as the session decides it.
  state.project.doc.survey.len > 0 and state.project.doc.survey.allIt(it.kind == jkCsv)

proc holdSurvey*(state: AppState; job: JobId) =
  ## Keeps the project's survey (the one `projectSurvey` gave when `job` was
  ## submitted, in the same frame) alive until `job` has ended, whatever the
  ## project does meanwhile: a close, a clear, an update or a new import
  ## frees the state's own copy. Released when the job is seen finished or
  ## cancelled, and, for one abandoned, when its work is back.
  assertUiThread()
  if job != NoJob and not state.project.geometry.isNil:
    state.batchSurvey.held.add (job, state.project.geometry)

func inProject*(state: AppState): bool {.inline.} =
  ## Whether a project is open.
  state.project.dir.len > 0

func shotLogCount*(state: AppState): int {.inline.} =
  ## How many shot logs are loaded.
  state.shotLogs.len

func shotLogsRevision*(state: AppState): int {.inline.} =
  ## Bumps when a shot log is added, removed, or its view changes.
  state.shotLogsRev

func findTrace*(state: AppState; trace: int): int {.raises: [].}

proc sameDisk(s: Session; path: string): bool {.inline.} =
  ## Whether `s` is the file at `path`. Does not build a new path string.
  if s.origin.len > 0: s.origin == path else: s.path == path

proc followStamp(state: AppState): tuple[hover, hoverSession, hoverKeys, chosenSession,
    chosenKeys, filesRev, sessions: int] {.raises: [].} =
  result.hover = state.selection.hover
  result.hoverSession = -1
  result.chosenSession = -1
  if result.hover >= 0:
    let i = state.findTrace(result.hover)
    if i >= 0:
      result.hoverSession = int(state.sessions[i].id)
      result.hoverKeys = state.sessions[i].keysRevision
  if state.files.chosen.len > 0:
    for i in 0 ..< state.sessions.len:
      let hit = sameDisk(state.sessions[i], state.files.chosen)
      if hit:
        result.chosenSession = int(state.sessions[i].id)
        result.chosenKeys = state.sessions[i].keysRevision
        break
  result.filesRev = state.fileList.revision
  result.sessions = state.sessions.len

proc pointerQuery(state: AppState; trace: int; q: var ShotQuery): bool =
  ## Trace `trace`, when it is a trace of an open seismic file.
  if trace < 0: return false
  let i = state.findTrace(trace)
  if i < 0: return false
  let s = state.sessions[i]
  if s.isSignature: return false
  q = traceQuery(s.file, trace - s.base)
  true

proc signatureQueryOf(state: AppState; q: var ShotQuery): bool =
  ## The selected signature, from the open session when it has one, else the list.
  let chosen = state.files.chosen
  if chosen.len == 0: return false
  for s in state.sessions:
    if s.isSignature and sameDisk(s, chosen):
      let facts = s.signature
      q = signatureQuery(facts.info, facts.pairTriggerNs, facts.pairFileNumber)
      return true
  let at = state.files.find(chosen)
  if at < 0: return false
  let e = state.files.entries[at]
  if e.kind notin SignatureFileKinds: return false
  if e.sweep.triggerNs == 0 and e.sweep.problem.len > 0: return false
  var pairNs = 0'i64
  var pairFile = -1'i64
  if e.kind == fkVib:
    let partner = state.files.pairs.getOrDefault(chosen)
    let p = if partner.len == 0: -1 else: state.files.find(partner)
    if p >= 0:
      pairNs = state.files.entries[p].sweep.triggerNs
      pairFile = state.files.entries[p].sweep.fileNumber
  q = signatureQuery(e.sweep, pairNs, pairFile)
  true

proc fileQueryOf(state: AppState; q: var ShotQuery): bool =
  ## The selected file's first trace, when that file is open and not a signature.
  let chosen = state.files.chosen
  if chosen.len == 0: return false
  for s in state.sessions:
    if not s.isSignature and s.len > 0 and sameDisk(s, chosen):
      q = traceQuery(s.file, 0)
      return true
  false

proc shownId(state: AppState): int =
  ## The id of the file the main panel shows, or 0 when it shows none.
  result = 0
  var k = -1
  for i in 0 ..< state.panels.len:
    if state.panels[i].id == MainPanel:
      k = i
      break
  if k < 0: return
  let i = state.shownFile(k)
  if i < 0: return
  result = int(state.sessions[i].id)

proc seismicTrace(state: AppState; trace: int): bool =
  ## Whether `trace` is a trace of an open seismic file.
  if trace < 0: return false
  let i = state.findTrace(trace)
  if i < 0: return false
  not state.sessions[i].isSignature

proc followedTrace(state: var AppState): int =
  ## The seismic trace under the pointer, or the last one hovered while the
  ## file on show is unchanged and that trace is still open. -1 when none has
  ## been hovered since this file was shown.
  let shown = state.shownId()
  if shown == 0 or shown != state.followShown:
    state.followTrace = -1
    state.followShown = shown
  let hover = state.selection.hover
  if hover >= 0:
    if state.seismicTrace(hover):
      state.followTrace = hover
      state.followShown = shown
      return hover
    state.followTrace = -1
    return -1
  if state.seismicTrace(state.followTrace): return state.followTrace
  state.followTrace = -1
  -1

proc followAnswer*(state: var AppState; logIndex: int): ShotFollowAnswer {.raises: [].} =
  ## The shot loaded log `logIndex` follows: the trace under the pointer, or
  ## the last one hovered while this file is still on show, then the selected
  ## signature, then the selected open file. Leaving the plot does not jump
  ## until the shown file changes, that file is closed, or another trace is
  ## hovered. An index that is not a loaded log is none and does not change
  ## another log's answer. Nothing is moved or scrolled.
  ## No allocation when the pointer, the chosen file and that log are unchanged.
  if logIndex < 0 or logIndex >= state.shotLogs.len:
    return ShotFollowAnswer(source: sfNone, match: noMatch(), logId: -1)
  let id = state.shotLogs[logIndex].id
  let logRev = state.shotLogs[logIndex].revision
  let trace = state.followedTrace()
  var stamp = followStamp(state)
  stamp.hover = trace
  if trace >= 0:
    let i = state.findTrace(trace)
    if i >= 0:
      stamp.hoverSession = int(state.sessions[i].id)
      stamp.hoverKeys = state.sessions[i].keysRevision
    else:
      stamp.hoverSession = -1
      stamp.hoverKeys = 0
  else:
    stamp.hoverSession = -1
    stamp.hoverKeys = 0
  if state.follow.unchanged(id, logRev, stamp.hover, stamp.hoverSession, stamp.hoverKeys,
      stamp.chosenSession, stamp.chosenKeys, stamp.filesRev, stamp.sessions):
    return state.follow.lastAnswer(id)
  let none = noMatch()
  template put(source: ShotFollowSource; matched: ShotMatch): ShotFollowAnswer =
    state.follow.publish(id, logRev, source, matched, stamp.hover, stamp.hoverSession,
      stamp.hoverKeys, stamp.chosenSession, stamp.chosenKeys, stamp.filesRev, stamp.sessions)
  let index = state.follow.indexOf(id)
  if index == nil: return put(sfNone, none)
  var q = ShotQuery()
  if pointerQuery(state, trace, q): return put(sfPointer, matched(index, q))
  if signatureQueryOf(state, q): return put(sfSignature, matched(index, q))
  if fileQueryOf(state, q): return put(sfFile, matched(index, q))
  put(sfNone, none)

func shotView*(state: AppState; i: int): lent ShotView =
  ## The typed rows of loaded shot log `i`, without copying them.
  state.shotLogs[i].view

func shotRevision*(state: AppState; i: int): int {.inline.} =
  ## The revision of loaded shot log `i`.
  state.shotLogs[i].revision

func shotLogName*(state: AppState; i: int): string {.inline.} =
  ## The short name of loaded shot log `i`.
  state.shotLogs[i].name

func shotLogStored*(state: AppState; i: int): string {.inline.} =
  ## The copy's file name under `shotlogs/`, or "" when it is not stored.
  state.shotLogs[i].stored

func shotLogSource*(state: AppState; i: int): string {.inline.} =
  ## The file loaded shot log `i` was read from.
  state.shotLogs[i].source

func shotLogId*(state: AppState; i: int): int =
  ## The id of loaded shot log `i`, or -1 when `i` is not a loaded log.
  if i < 0 or i >= state.shotLogs.len: -1 else: state.shotLogs[i].id

func shotLogBusy*(state: AppState; i: int): bool =
  ## Whether a job is reading loaded shot log `i`.
  if i < 0 or i >= state.shotLogs.len: false else: state.shotLogs[i].busy

func shotLogWidth*(state: AppState; i: int): int =
  ## Columns of loaded shot log `i`, or 0 when it has no text yet.
  if i < 0 or i >= state.shotLogs.len or state.shotLogs[i].log == nil: 0
  else: state.shotLogs[i].log.width

proc shotLogColumn*(state: AppState; i, col: int): string =
  ## The header name of column `col` of loaded shot log `i`, or "".
  if i < 0 or i >= state.shotLogs.len or state.shotLogs[i].log == nil: ""
  else: state.shotLogs[i].log.columnName(col)

proc shotLogGuess*(state: AppState; i: int): ShotLogMap =
  ## A map guessed from loaded shot log `i`'s text. The text is not copied.
  if i < 0 or i >= state.shotLogs.len or state.shotLogs[i].log == nil: initShotLogMap()
  else: guessMap(state.shotLogs[i].log.text)

proc findShotLog*(state: AppState; id: int): int =
  ## The index of the loaded shot log with `id`, or -1.
  result = -1
  for i, s in state.shotLogs:
    if s.id == id: return i

func shotLogReading*(state: AppState): bool =
  ## An import or a load is under way and has not joined the loaded logs yet.
  for w in state.shotWork:
    if w.kind in {sjImport, sjLoad}: return true
  false

func shotLogMap*(state: AppState; i: int): ShotLogMap {.inline.} =
  ## The map loaded shot log `i` was parsed with.
  state.shotLogs[i].map

proc shotCell*(state: AppState; i, row, col: int): string =
  ## One cell of loaded shot log `i`, as a grid shows it.
  if i < 0 or i >= state.shotLogs.len or state.shotLogs[i].log == nil: return ""
  state.shotLogs[i].log.cell(row, col)

proc shotFileCell*(state: AppState; i, row, col: int): string =
  ## The cell as the file has it, ignoring an overlay.
  if i < 0 or i >= state.shotLogs.len or state.shotLogs[i].log == nil: return ""
  state.shotLogs[i].log.fileCell(row, col)

proc shotCellDiffers*(state: AppState; i, row, col: int): bool =
  ## Whether the cell the grid shows is not the file's own text.
  if i < 0 or i >= state.shotLogs.len or state.shotLogs[i].log == nil: return false
  state.shotLogs[i].log.cellDiffers(row, col)

func shotUndoCount*(state: AppState; i: int): int =
  ## Cell edits that can be undone on loaded shot log `i`.
  if i < 0 or i >= state.shotLogs.len: 0 else: state.shotLogs[i].undo.len

func shotRedoCount*(state: AppState; i: int): int =
  ## Cell edits that can be redone on loaded shot log `i`.
  if i < 0 or i >= state.shotLogs.len: 0 else: state.shotLogs[i].redo.len

func projectOpening*(state: AppState): string =
  ## The project folder being opened (or made); "" for none.
  if state.project.job != NoJob: state.project.jobDir else: ""

func joins*(state: AppState): lent seq[Joined] {.inline.} =
  ## The open files joined with survey files, and how.
  state.joins

type
  SurveyStatus* = enum
    ## What the project's survey did for a trace, when its file is matched.
    ssUnmatched = "none"
      ## no match covers it, or the survey changed some of its keys (the
      ## "From the survey" rows show those)
    ssAgrees = "agrees" ## its stations are in the survey and its headers already agree
    ssAux = "auxiliary" ## an auxiliary trace: the survey leaves it alone
    ssNotIn = "notInSurvey" ## its source or receiver is not in the survey

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

func firstBreaks*(state: AppState): lent seq[FirstBreaks] {.inline.} =
  ## The first-break overlay's results (`core/firstbreaks`), oldest first.
  state.breaks

func breaksOn*(state: AppState; id: PanelId): bool =
  ## Whether panel `id` has the first-break overlay on.
  for p in state.panels:
    if p.id == id: return p.layers.len > 0 and p.layers[0].display.firstBreaks

func panelGuide(state: AppState; k: int): BreakModel =
  ## The model the picks of record panel `panels[k]`'s overlay are to be guided by: its given
  ## model, or `BreakModel()` (the record's fit).
  let m = state.panels[k].layers[0].display.breakModel.bounded
  if m.given: m else: BreakModel()

func guidedIndex(state: AppState; k: int): tuple[exact, other: int] =
  ## The results in `firstBreaks` of the record panel `panels[k]` shows: the newest of its own
  ## guide (`exact`) and the newest done one of another (`other`); -1 for none.
  result = (-1, -1)
  if k < 0 or k >= state.panels.len or state.panels[k].layers.len == 0: return
  let src = state.panels[k].layers[0].source
  if src.kind != lsRecord: return
  let guide = state.panelGuide(k)
  let pick = state.panels[k].layers[0].display.breakPickOn
  for i in countdown(state.breaks.high, 0):
    template b: untyped = state.breaks[i]
    if b.key.file == src.file and b.key.gather == src.gather and b.key.pick == pick:
      if b.key.guide == guide:
        if result.exact < 0: result.exact = i
      elif b.state == bkDone and result.other < 0: result.other = i

func breaksIndex*(state: AppState; k: int): int =
  ## The index in `firstBreaks` of the result the record panel `panels[k]` shows; -1 when it
  ## has none (the overlay is off, or no record is shown). That of its own guide when it is
  ## done; while that is being made, or when it failed, a done one of another guide, if any
  ## (`shownBreaks` says so: `FirstBreaks.guided`).
  let (exact, other) = state.guidedIndex(k)
  if exact >= 0 and (state.breaks[exact].state == bkDone or other < 0): exact
  else: other

func surveyHead*(state: AppState; path: string): int =
  ## The index in `heads` of what survey file `path`'s headers say (as
  ## `ckSurveyUnits` named it); -1 when it was never asked for.
  for i in 0 ..< state.heads.len:
    if state.heads[i].file.path == path: return i
  -1

func sigIndex(k: SignatureKind): int {.inline.} = (if k == sgVib: 1 else: 0)

func openChoiceOf*(state: AppState; path: string): OpenChoice =
  ## The options file `path` (canonical) opens with this run: those
  ## "Reopen with options" gave it, else (for a signature file) those given for every file of
  ## its kind in the listing, else the defaults.
  if path in state.openChoices: return state.openChoices[path]
  let e = state.files.find(path)
  if e >= 0 and state.files.entries[e].kind in SignatureFileKinds:
    result.signature = state.sigChoices[sigIndex(state.files.entries[e].kind.sweepKindOf)]

func hasPrepared*(state: AppState; path: string): bool =
  ## Whether the file `path` is prepared: decoded or opened in the background, not yet shown.
  not state.prepared.session.isNil and state.prepared.session.path == path

func partnerOf*(state: AppState; path: string): string =
  ## The other file of the sweep of signature file `path`: the list's pair, else what a search
  ## found; "" when none is known.
  result = state.files.pairs.getOrDefault(path)
  if result.len == 0 and path in state.pairAnswers: result = state.pairAnswers[path].partner

func pairArgOf(state: AppState; path: string): SignaturePair =
  ## The `.dat` of the sweep of `.vib` `path` as an open job is given it; none for any other file
  ## or when no `.dat` is known.
  let e = state.files.find(path)
  var vib = e >= 0 and state.files.entries[e].kind == fkVib
  if not vib and path in state.pairAnswers: vib = state.pairAnswers[path].info.kind == sgDat
  let partner = if vib: state.partnerOf(path) else: ""
  if partner.len > 0:
    var info = SweepInfo()
    let d = state.files.find(partner)
    if d >= 0 and state.files.entries[d].kind == fkDat: info = state.files.entries[d].sweep
    elif path in state.pairAnswers and state.pairAnswers[path].info.kind == sgDat:
      info = state.pairAnswers[path].info
    if info.kind == sgDat and info.problem.len == 0:
      result = SignaturePair(path: partner, triggerNs: info.triggerNs,
        controller: info.controller, vibrator: info.vibrator,
        fileNumber: info.fileNumber, qc: info.qc)

func signatureKindOfPath(state: AppState; path: string): SignatureKind =
  ## Which signature file `path` is, as an open session or the file list knows it; `sgNone` when
  ## it is neither (a file opened alone and not listed is told by its open).
  for s in state.sessions:
    if s.path == path: return s.signature.kind
  let e = state.files.find(path)
  if e >= 0: result = state.files.entries[e].kind.sweepKindOf

func pairText*(state: AppState; path: string): string =
  ## What the Summary's Pair line says of signature file `path`: its partner, "not found
  ## (looked ...)", or "not looked for yet". "" for a file that is not a signature file.
  let e = state.files.find(path)
  var kind = if e >= 0: state.files.entries[e].kind.sweepKindOf else: sgNone
  for s in state.sessions:
    if s.path == path and s.isSignature: kind = s.signature.kind
  let partner = state.partnerOf(path)
  if kind == sgNone and partner.len > 0:
    # (a file opened alone that another has replaced: its partner's kind says its own)
    let p = state.files.find(partner)
    let pk = if p >= 0: state.files.entries[p].kind.sweepKindOf
      elif path in state.pairAnswers: state.pairAnswers[path].info.kind else: sgNone
    kind = if pk == sgDat: sgVib elif pk == sgVib: sgDat else: sgNone
  if kind == sgNone: return ""
  let other = if kind == sgDat: ".vib" else: ".dat"
  if partner.len > 0:
    result = partner.extractFilename & " (the " & other & " of this sweep)"
  elif path in state.pairAnswers:
    result = "not found (" & state.pairAnswers[path].words & ")"
  elif path in state.files.pairNotes: result = state.files.pairNotes[path]
  else:
    result = "not looked for yet"

func unitChoices*(state: AppState): lent ImportUnits {.inline.} =
  ## The units the user chose by hand (`ckChooseUnit`): per survey (its
  ## files) and per seismic file; what the headers say never replaces them.
  state.unitChoices

func heads*(state: AppState): lent seq[SurveyHead] {.inline.} =
  ## What survey files' headers say of their unit (`ckSurveyUnits`); `done`
  ## false while a file's job runs.
  state.heads

func joinReport*(state: AppState): lent JoinReport {.inline.} =
  ## How the last join ended (its `serial` goes up with each).
  state.joinReport

func joinUnderWay*(state: AppState): tuple[job: JobId; step: JoinStep; session: SessionId] =
  ## The join under way: its job (`NoJob` for none), what it does, and the
  ## file it joins to.
  (state.joining.job, state.joining.step, state.joining.session)

func surveyInEffect*(state: AppState): bool =
  ## Whether a survey is imported: a file joined with one, a survey file on the
  ## map, one kept in the project open, or an import under way (Clear survey
  ## has something to take away).
  if state.joins.len > 0 or state.joining.job != NoJob or state.joining.loads.len > 0 or
      state.joining.waits or state.project.doc.hasSurvey or state.project.doc.hasImport:
    return true
  for i in 0 ..< state.survey.layers.len: # by index: `for l in` copies every layer
    if state.survey.layers[i].origin == loSurveyFile: return true

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

func cutProblem*(state: AppState): string =
  ## Why Project > Slice by shot log cannot start, in a sentence; "" when it can.
  let shown = state.shownFile(state.findPanel(MainPanel))
  let haveFile = shown >= 0
  let haveLog = state.shotLogs.len > 0
  if not haveFile and not haveLog: CutNeedBoth
  elif not haveFile: CutNeedFile
  elif not haveLog: CutNeedLog
  elif state.sessions[shown].derived: CutDerived
  elif state.sessions[shown].isSignature: CutSignature
  elif state.cutJob != NoJob: CutRunning
  else: ""

func spsRunning*(state: AppState): bool {.inline.} =
  ## Whether an SPS export of a shot log is under way.
  state.spsJob != NoJob

func spsOutcome*(state: AppState): string {.inline.} =
  ## The last SPS export's outcome in a few sentences; "" before any.
  state.spsOutcome

func spsOutcomeLog*(state: AppState): int {.inline.} =
  ## The id of the shot log the last export (or the one under way) was of; -1 before any.
  state.spsLogId

func oFileRunning*(state: AppState): bool {.inline.} =
  ## Whether an O file is being generated.
  state.oJob != NoJob

func oFileOutcome*(state: AppState): string {.inline.} =
  ## The last generation's outcome in a few sentences; "" before any.
  state.oOutcome

func oFileWritten*(state: AppState): string {.inline.} =
  ## The file the last generation wrote; "" when it wrote none.
  state.oPath

func spsWritten*(state: AppState): string {.inline.} =
  ## The file the last SPS export wrote; "" when it wrote none.
  state.spsPath

func recordingFacts*(state: AppState): RecordingFacts {.inline.} =
  ## What the shown file is as a recording, once `watchRecording` has had it
  ## read; not `ready` before that.
  if state.recHave: state.recFacts.applied(state.treatInForce(state.recPath))
  else: RecordingFacts()

func recordingWhy*(state: AppState): string {.inline.} =
  ## Why the shown file has no ready facts once the job has ended: no live trace
  ## with a start time, or what failed; "" while it is read or when they are ready.
  if state.recHave: state.recWhy else: ""

func vendorFields*(state: AppState; session: SessionId): Option[VendorFieldList] =
  ## The vendor fields open file `session` has under the vendor maps in force, once
  ## `watchVendorFields` has had them listed; none before that (the menu says it is reading).
  for l in state.vfLists:
    if l.session == session and l.vendors == state.vendor.gen: return some(l)

func vendorFieldsBusy*(state: AppState): bool {.inline.} =
  ## The vendor fields of a shown file are being listed.
  state.vfJob != NoJob

func recordingBusy*(state: AppState): bool {.inline.} =
  ## The shown file is being read as a recording.
  state.recJob != NoJob

func cutRunning*(state: AppState): bool {.inline.} =
  ## Whether a slice by shot log is under way.
  state.cutJob != NoJob

func cutOutcome*(state: AppState): string {.inline.} =
  ## The last slice's outcome in a sentence; "" before any.
  state.cutOutcome

func cutWritten*(state: AppState): string {.inline.} =
  ## The file the last slice wrote; "" when it wrote none.
  state.cutPath

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

func findTrace*(state: AppState; trace: int): int {.raises: [].} =
  ## The index in `sessions` of the file that holds survey-wide trace id
  ## `trace`; -1 when no open file does.
  for i, s in state.sessions:
    if trace in s: return i
  -1

func surveyStatus*(j: Joined; d: TraceDetail): SurveyStatus =
  ## What the join `j` of a trace's file did for `d`: `ssUnmatched` when it
  ## changed some of its keys (the survey rows show them) or when no match
  ## covers it.
  if j.plan.traces == 0 or d.joined != {}: return ssUnmatched
  if not d.keys.isSeismic: return ssAux
  if j.plan.unmatched.binarySearch(d.trace) >= 0: ssNotIn else: ssAgrees

proc surveyStatuses*(st: AppState; traces: openArray[TraceDetail]): seq[SurveyStatus] =
  ## `surveyStatus` of each trace, by the join of its file.
  result = newSeq[SurveyStatus](traces.len)
  for k, d in traces:
    let i = st.findTrace(d.id)
    if i >= 0 and d.problem.len == 0:
      let j = st.joinedOf(st.sessions[i].id)
      if j >= 0: result[k] = surveyStatus(st.joins[j], d)

func traceEdits*(state: AppState; trace: int): set[TraceEdit] =
  ## The edits of survey-wide trace `trace` now; none for a trace no open
  ## file has.
  let i = state.findTrace(trace)
  if i >= 0 and state.keyOf(state.sessions[i].path) in state.edits:
    result = state.edits[state.keyOf(state.sessions[i].path)].editsOf(trace - state.sessions[i].base)

func editsAt*(state: AppState; path: string): lent FileEdits =
  ## The edits of the file at `path`; none when it has none. Not a copy
  ## (`getOrDefault` copies the lists and the whole history).
  if state.keyOf(path) in state.edits:
    return state.edits[state.keyOf(path)]
  state.noEdits

type
  EditsSnapshot* = object
    ## A copy of the per-file edits, for a worker. `byKey` is `edits`;
    ## `alias` is `editKey` (a path opened under another name, to the key).
    byKey*: Table[string, FileEdits]
    alias*: Table[string, string]

proc editsSnapshot*(state: AppState): EditsSnapshot =
  ## Copies the edits and their path aliases. The UI thread takes this
  ## before a job is submitted; the worker must not read `AppState`.
  result.byKey = state.edits
  result.alias = state.editKey

func ownAt*(state: AppState; path: string; trace: int): tuple[has: bool; filter: OwnFilter] =
  ## The own filter of file-index `trace` at `path`; none when the file has none.
  if state.keyOf(path) in state.edits:
    result = state.edits[state.keyOf(path)].ownOf(trace)

func ownLine*(state: AppState; p: Panel): string =
  ## What the plot says of the own filters of the traces it shows, in the
  ## place it names its filters: "Trace 12: own filter, band-pass 10-60 Hz",
  ## or "N traces have their own filter". "" when none change the samples.
  if p.layers.len == 0 or not p.laidOut or p.shown.len == 0: return ""
  let i = state.findSession(p.layers[0].source.file)
  if i < 0: return ""
  let e = state.editsAt(state.sessions[i].path)
  var own = newSeq[OwnFilter](p.shown.len)
  for k, t in p.shown:
    let (has, f) = e.ownOf(t)
    if has: own[k] = f
  ownShownWords(p.shown[0], own)

func reverseLine*(state: AppState; p: Panel): string =
  ## What the plot says of the reversed traces it shows, in the place it
  ## names an own filter: "Trace 12: reversed", or how many. "" for none.
  if p.layers.len == 0 or not p.laidOut or p.shown.len == 0: return ""
  let i = state.findSession(p.layers[0].source.file)
  if i < 0: return ""
  let e = state.editsAt(state.sessions[i].path)
  var on = newSeq[bool](p.shown.len)
  for k, t in p.shown:
    if e.has(teReversed, t): on[k] = true
  reverseShownWords(p.shown[0], on)

func shiftLine*(state: AppState; p: Panel): string =
  ## What the plot says of the time shifts of the traces it shows, in the
  ## place it names an own filter: "Trace 12: shifted +8 ms", or how many.
  ## "" when none is shifted.
  if p.layers.len == 0 or not p.laidOut or p.shown.len == 0: return ""
  let i = state.findSession(p.layers[0].source.file)
  if i < 0: return ""
  let e = state.editsAt(state.sessions[i].path)
  var ms = newSeq[float64](p.shown.len)
  for k, t in p.shown:
    ms[k] = e.shiftOf(t)
  shiftNote(p.shown[0], ms)

func traceIsSeismic*(state: AppState; id: int): bool =
  ## Whether survey-wide trace `id` is seismic data. An auxiliary trace, or
  ## one whose file is not open, is not.
  let i = state.findTrace(id)
  if i < 0: return false
  let s = state.sessions[i]
  let local = id - s.base
  let f = s.filePtr
  f != nil and local in 0 ..< f[].len and isSeismic(f[].index, local)

func seismicIds*(state: AppState; ids: openArray[int]): seq[int] =
  ## The seismic traces of `ids` (survey-wide). An auxiliary trace is left out.
  for id in ids:
    if state.traceIsSeismic(id): result.add id

func shownShift*(state: AppState; id: int): float64 =
  ## The time shift of survey-wide trace `id`, in milliseconds; 0 for none.
  let i = state.findTrace(id)
  if i < 0: return 0.0
  let s = state.sessions[i]
  state.editsAt(s.path).shiftOf(id - s.base)

func firstAux*(state: AppState; file: int): int =
  ## The file index of the first auxiliary trace of `sessions[file]`, or -1.
  if file < 0 or file > state.sessions.high: return -1
  let s = state.sessions[file]
  let f = s.filePtr
  if f == nil: return -1
  for t in 0 ..< f[].len:
    if not isSeismic(f[].index, t): return t
  -1

func ownChangesSamples*(state: AppState; w: SpectrumWindow): bool =
  ## Whether a trace `w` shows has an own filter that changes its samples
  ## (a frequency filter, or one that runs instead of the plot's).
  for t in w.traces:
    let i = state.findTrace(t)
    if i >= 0:
      let s = state.sessions[i]
      let (has, f) = state.ownAt(s.path, t - s.base)
      if has and f.changesSamples: return true
  false

func hasEditAt*(state: AppState; path: string; trace: int; edit: TraceEdit): bool =
  ## Whether file-index `trace` at `path` has edit `edit`.
  state.keyOf(path) in state.edits and state.edits[state.keyOf(path)].has(edit, trace)

func editsOf*(state: AppState; panelIndex: int): lent FileEdits =
  ## The edits of the file `panels[panelIndex]` shows; none when it shows
  ## none or the file has none. Not a copy: the screen asks every frame, so
  ## pass it on rather than keep it in a `let`, which copies.
  # Not an `if` expression: Nim 2.4.2 copies its branch into a temporary
  # and returns a view of that, freed on return.
  let i = state.shownFile(panelIndex)
  if i >= 0 and state.keyOf(state.sessions[i].path) in state.edits:
    return state.edits[state.keyOf(state.sessions[i].path)]
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

func compareOnGather*(state: AppState; panelIndex: int): bool =
  ## Whether a trace of the gather the panel shows fed a filled slot.
  let (i, traces) = state.shownTraces(panelIndex)
  if i < 0: return false
  let path = state.sessions[i].path
  template hit(slot: CompareSlot): bool =
    slot.filled and slot.path == path and slot.trace >= 1 and (slot.trace - 1) in traces
  hit(state.compareA) or hit(state.compareB)

func gatherEdited*(state: AppState; panelIndex: int): bool =
  ## Whether a trace of the gather `panels[panelIndex]` shows has an edit,
  ## shown or kept (an edit an agent hid for the session): then the display
  ## header has a row for them.
  let (i, traces) = state.shownTraces(panelIndex)
  i >= 0 and state.keyOf(state.sessions[i].path) in state.edits and
    (state.edits[state.keyOf(state.sessions[i].path)].anyIn(traces) or
    state.edits[state.keyOf(state.sessions[i].path)].anyKeptIn(traces))

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

proc enqueueMoves(state: var AppState; id: SessionId)
proc dropMoveBases(state: var AppState; id: SessionId)
proc queueOpenMoves(state: var AppState)

func surveyMatchable(state: AppState): bool =
  ## Whether a file can still be matched to the project's survey. Station
  ## moves do not wait for a survey that failed to be restored.
  state.project.dir.len > 0 and state.project.doc.hasSurvey and
    state.project.survey != srFailed

proc canonical*(path: string): string =
  ## `path` made absolute and normalized ("./a.sgy", "data/../a.sgy" and the
  ## full path name one file), without touching the disk: jobs compare files
  ## by these strings. As given, normalized, when there is no current
  ## directory to resolve it against.
  try:
    absolutePath(path).normalizedPath
  except OSError, ValueError:
    path.normalizedPath

proc treatOf*(state: AppState; path: string): TreatAs =
  ## What the user forced for the file at `path` (kind and order); nothing is forced for a
  ## file that has no choice.
  state.shownTreat(canonical(path))

proc treatPendingOf*(state: AppState; path: string): set[TreatPart] =
  ## The parts of what `treatOf` says that no job uses yet: a listing found them in a document
  ## that may be another content's, and the file's hash has not confirmed it.
  state.pendingParts(canonical(path))

proc ignore(state: var AppState; cmd: Command; why: string) =
  state.log.add(sevWarning, "commands", "Ignored \"" & $cmd.kind & "\": " & why & ".")

proc logProblems(state: var AppState; source: string; problems: openArray[string]) =
  ## Logs `problems` as warnings, the first `MaxProblemLines` one by one and
  ## a count of the rest (`addProblems`).
  var notes: seq[Note]
  notes.addProblems(problems)
  for (severity, text) in notes: state.log.add(severity, source, text)

func samePath*(a, b: string): bool =
  ## Whether two canonical paths (`canonical`) name one file: on Windows,
  ## where a drive's names are not case-sensitive, those that differ in case
  ## only do; elsewhere none do.
  when defined(windows): cmpIgnoreCase(a, b) == 0
  else: a == b

proc seismicAt(state: AppState; path: string): bool =
  ## Whether `path` names a seismic file the program has open, is opening or
  ## closing, or lists: what it writes of its own never goes over one
  ## (Working rules: a loaded file is never changed). On Windows `C:\Data\A.SGY`
  ## and `c:\data\a.sgy` are one file (`samePath`).
  let p = canonical(path)
  result = state.sessions.anyIt(samePath(it.path, p)) or
    state.opening.anyIt(samePath(it.path, p)) or
    state.closing.anyIt(samePath(it.path, p)) or state.files.find(p) >= 0 or
    state.survey.findFile(p) >= 0
  when defined(windows):
    result = result or state.files.entries.anyIt(samePath(it.path, p)) or
      state.survey.layers.anyIt(it.origin == loSurveyFile and samePath(it.path, p))

proc refusedWrite(state: var AppState; cmd: Command; path: string): bool =
  ## Says why `cmd` (an export) writes nothing to `path`, when it may not:
  ## no file named, or a seismic file named.
  result = true
  if path.len == 0: state.ignore(cmd, "no file was named")
  elif state.seismicAt(path):
    state.ignore(cmd, path & " is a seismic file viewSEG has open or lists, and " &
      "viewSEG never writes over one; choose another name")
  else: result = false

proc refusedExport(state: var AppState; cmd: Command): bool =
  ## `refusedWrite` of the document `cmd` names.
  state.refusedWrite(cmd, cmd.docPath)

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

func wantsTemplate(state: AppState): bool =
  ## Whether a plot leaves out the traces the record's template does not list.
  state.panels.anyIt(it.layers.len > 0 and it.layers[0].filter.templateOnly)

func templateTraces(state: AppState; k: int): (bool, seq[int], int) =
  ## What the template of the record `panels[k]` shows says of its traces, when its check
  ## (`recordQc`) is of that record as it is now and found the traces' stations: whether it
  ## is known, the file's traces the template does not list (ascending), and how many seismic
  ## traces the record holds.
  let (i, traces) = state.shownTraces(k)
  if i < 0: return
  let s = state.sessions[i]
  let q = state.recordQc
  if q.job == NoJob and q.key.file == s.id and q.key.keys == s.keysRevision and
      q.key.gather == state.panels[k].layers[0].source.gather and q.onStations and
      q.hits[mfUnlisted].state == fsDone:
    result[0] = true
    for t in q.hits[mfUnlisted].traces: result[1].add t - s.base
    result[1].sort()
    result[2] = traces.len - (if q.hits[mfAuxiliary].state == fsDone: q.hits[mfAuxiliary].traces.len
      else: 0)

func hiddenOf(state: AppState; k: int; path: string; traces: Slice[int]): seq[int] =
  ## The traces of `traces` (the gather `panels[k]` shows, of the file at `path`) its reader
  ## leaves out, ascending: the killed ones when they are hidden (a setting), and, with the
  ## filter's `templateOnly` and a template known for the record, those the template does
  ## not list.
  if state.settings.hideKilled:
    result = state.editsAt(path).listIn(teKilled, traces)
  if state.panels[k].layers.len > 0 and state.panels[k].layers[0].filter.templateOnly:
    let (known, unlisted, _) = state.templateTraces(k)
    if known:
      if result.len == 0: result = unlisted
      else:
        result.add unlisted
        result.sort()
        result = result.deduplicate(isSorted = true)

func templateAvailable(state: AppState; k: int): bool

func templatePending(state: AppState; k: int): bool =
  ## Whether `panels[k]` asks for the template's traces only, for the record the check
  ## (`recordQc`) is to look at, and the check has not answered yet: the plot is read once it
  ## has, with the traces the template lists. An answer that finds no template, a failed or a
  ## stopped check end the wait. Nothing is asked while the option is off.
  if k < 0 or k >= state.panels.len or state.panels[k].layers.len == 0: return false
  template layer: untyped = state.panels[k].layers[0]
  if not layer.filter.templateOnly or layer.source.kind != lsRecord: return false
  let g = state.selection.activeGather
  if g.file != layer.source.file or g.gather != layer.source.gather: return false
  let i = state.findSession(g.file)
  if i < 0 or g.gather notin 0 ..< state.sessions[i].gathers.len: return false
  if state.templateTraces(k)[0] or not state.templateAvailable(k): return false
  let q = state.recordQc
  # (the answer of this record as it is now, found or not)
  let answered = q.job == NoJob and q.key.file == state.sessions[i].id and
    q.key.keys == state.sessions[i].keysRevision and q.key.gather == g.gather and
    q.hits[mfUnlisted].state != fsComputing
  not answered

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
  p.relevel = true # the new record's
  p.levelSince = p.requestGen
  p.levelAsked = false
  p.basis = ReadRequest()
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
  p.templateWait = false
  if p.layers.len > 0 and p.layers[0].source.kind == lsRecord:
    let i = state.findSession(p.layers[0].source.file)
    let g = p.layers[0].source.gather
    if i >= 0 and g in 0 ..< state.sessions[i].gathers.len:
      let s = state.sessions[i]
      p.kind = s.gathers[g].kind
      p.hidden = state.hiddenOf(k, s.path, s.gathers[g].traces)
      if state.templatePending(k):
        # which traces the template lists is not known: read once it is, not twice
        p.templateWait = true
        busy = true
      elif state.jobs.hold(s.path):
        src = ReaderSource(gen: p.sourceGen, file: s.filePtr, session: s.id, path: s.path,
          size: s.size, traces: s.gathers[g].traces, filter: p.layers[0].filter,
          order: p.layers[0].order, hidden: p.hidden, traceNames: s.traceNames)
        state.heldBack.keepItIf(it != p.id)
      elif s.path == state.joining.path and state.joining.step == jpJoining:
        busy = true # shown once the join is done
        if p.id notin state.joining.paused: state.joining.paused.add p.id
      else:
        busy = true
        if p.id notin state.heldBack: state.heldBack.add p.id
        state.log.add(sevWarning, s.name, s.name & " is busy (a job needs it to itself), " &
          "so it is not shown.")
  # Nothing to read (no file, or a file with no traces): the reader posts no
  # layout, so the empty one stands, and the panel says so instead of waiting.
  p.laidOut = src.file.isNil and not busy
  if not src.file.isNil or not state.readers[k].isNil:
    state.reader(k).show(src)

proc followHidden(state: var AppState) =
  ## After every change: a panel whose gather's killed traces, hidden (a
  ## setting), are not those its reader leaves out (a kill, a restore, an
  ## undo, the setting turned on or off) shows its gather again without
  ## them (or with them), at the same scales and place.
  for k in 0 ..< state.panels.len:
    if state.panels[k].templateWait:
      if not state.templatePending(k): state.newSource(k) # the check answered: read it now
      continue
    let (i, traces) = state.shownTraces(k)
    if i >= 0:
      if state.templatePending(k): continue # the check is made again: the plot stays as it is
      let want = state.hiddenOf(k, state.sessions[i].path, traces)
      if want != state.panels[k].hidden: state.newSource(k)

func fileHasAuxiliary(state: AppState; file: SessionId): bool =
  ## Whether `file` holds an auxiliary trace, from the record list's counts.
  let i = state.findSession(file)
  if i >= 0:
    for r in state.sessions[i].records:
      if r.aux > 0: return true
  false

func auxEmptyText*(state: AppState; k: int): string =
  ## What the Aux window says in place of the plot when that record's auxiliary
  ## traces are not drawn. "" when this is not the Aux window, the layout is not
  ## known, or traces are drawn.
  ## The Aux window keeps only auxiliary traces, and the only other traces it
  ## leaves out are the killed ones when they are hidden. An empty layout of a
  ## record that has auxiliary traces, with killed traces hidden, is every
  ## auxiliary trace killed and hidden. A record with none says it has none.
  result = ""
  if k < 0 or k >= state.panels.len: return
  template p: untyped = state.panels[k]
  if p.role != prAux or not p.laidOut or p.layers.len == 0 or p.layout.traces > 0:
    return
  result = "This record has no auxiliary traces."
  if p.layers[0].source.kind != lsRecord: return
  let i = state.findSession(p.layers[0].source.file)
  let g = p.layers[0].source.gather
  if i >= 0 and g in 0 ..< state.sessions[i].records.len and
      state.sessions[i].records[g].aux > 0 and state.settings.hideKilled:
    result = "Every auxiliary trace of this record is killed and hidden."

proc applyRememberedTraces(state: AppState; file: SessionId; filter: var TraceFilter) =
  ## The Seismic / Aux choice a plot of `file` shows. A file with auxiliary
  ## traces takes the choice a new plot starts with. A file with none shows
  ## its seismic traces; the remembered choice is not written here.
  if state.fileHasAuxiliary(file):
    filter.seismic = state.settings.plot.seismic
    filter.auxiliary = state.settings.plot.auxiliary
  else:
    filter.seismic = true
    filter.auxiliary = false
  filter.templateOnly = state.settings.plot.templateOnly

const SignatureOverlap = 0.45

const SignatureHeader = HeaderChoice(auto: false, fields: @[hfTraceId, hfTrace])
  ## a signature file's display header: the trace's name from its layout, then its number

proc followAux(state: var AppState) =
  ## The Aux window's panel shows the auxiliary traces of the record the Seismic window
  ## shows, and nothing while the window is closed or the Seismic window shows no file. Called
  ## when the Seismic window's source changes and after every command: it starts no read
  ## while it already shows that record, and none while closed. It sets neither the
  ## selection's active record nor anything a record-level job keys on.
  let a = state.auxIndex
  if a < 0: return
  let m = state.findPanel(MainPanel)
  let on = state.auxOpen and m >= 0 and state.shownFile(m) >= 0
  if not on:
    if state.panels[a].layers.len > 0:
      state.panels[a].layers.setLen 0
      state.newSource(a)
    return
  let src = state.panels[m].layers[0].source
  let i = state.findSession(src.file)
  let reversed = state.editsAt(state.sessions[i].path).allReversed
  if state.panels[a].layers.len == 0:
    var layer = recordLayer(src.file, src.gather)
    layer.display = state.settings.aux.display
    layer.filter = auxFilter()
    layer.reversed = reversed
    state.panels[a].layers.add layer
    state.panels[a].header = state.settings.aux.header
    state.newSource(a)
  else:
    template layer: untyped = state.panels[a].layers[0]
    if layer.source.kind != lsRecord or layer.source.file != src.file or
        layer.source.gather != src.gather:
      if layer.source.kind != lsRecord or layer.source.file != src.file:
        layer.filter.components = {}
        state.panels[a].componentCodes.setLen 0
        state.panels[a].componentCounts.setLen 0
        state.panels[a].componentSensors.setLen 0
      layer.source = LayerSource(kind: lsRecord, file: src.file, gather: src.gather)
      layer.reversed = reversed
      state.newSource(a)

proc show(state: var AppState; panel: PanelId; file: SessionId; gather: int) =
  ## Points layer 0 of `panel` at `gather` of `file`. A later record of the
  ## same file keeps the filter, including which components are off. Another
  ## file, or a new plot, takes the Seismic / Aux choice a new plot starts
  ## with (a file with no auxiliary traces shows its seismic traces, and that
  ## does not change the choice) and starts its component buttons all on. A
  ## new plot also takes the display, order and filters chosen last.
  let k = state.findPanel(panel)
  if k < 0: return
  if state.panels[k].layers.len == 0: # a new plot: as the user last had one
    var layer = recordLayer(file, gather)
    layer.display = state.settings.plot.display
    layer.processing = state.settings.plot.processing
    layer.order = state.settings.plot.order
    state.applyRememberedTraces(file, layer.filter)
    state.panels[k].layers.add layer
    state.panels[k].header = state.settings.plot.header
  else:
    # Another file: the component buttons start all on, and the Seismic / Aux
    # choice is the one remembered. A later record of this file keeps both.
    var otherFile = true
    if state.panels[k].layers[0].source.kind == lsRecord:
      otherFile = state.panels[k].layers[0].source.file != file
    if otherFile:
      state.panels[k].layers[0].filter.components = {}
      state.panels[k].componentCodes.setLen 0
      state.panels[k].componentCounts.setLen 0
      state.panels[k].componentSensors.setLen 0
      state.applyRememberedTraces(file, state.panels[k].layers[0].filter)
    state.panels[k].layers[0].source = LayerSource(kind: lsRecord, file: file, gather: gather)
  # Reversing every trace is an edit of the file: each file shows its own.
  let i = state.findSession(file)
  state.panels[k].layers[0].reversed = i >= 0 and
    state.editsAt(state.sessions[i].path).allReversed
  # A record whose traces are all auxiliary opens with Aux on, not as an empty panel.
  if i >= 0 and gather in 0 ..< state.sessions[i].records.len:
    let r = state.sessions[i].records[gather]
    if r.seismic == 0 and r.aux > 0 and not state.panels[k].layers[0].filter.auxiliary:
      state.panels[k].layers[0].filter.auxiliary = true
      let s = state.sessions[i]
      if state.auxOnNoted.len == 0: # once a session: the next file says the same
        state.auxOnNoted.add s.diskPath
        state.log.add(sevInfo, s.name, "Every trace of " & s.name & "'s record is " &
          "auxiliary (pilot, reference or monitor channels), so Aux is switched on: " &
          "there are no seismic traces to show.")
  # A signature file's traces differ in scale by orders of magnitude (counts, forces, a
  # per-cycle value near 1e9): each is scaled on its own at first, and the display header names
  # the trace. A choice already made (any other gain; another header) wins; nothing but the
  # display changes, no sample.
  if i >= 0 and (state.panels[k].layers.len > 0):
    template layer: untyped = state.panels[k].layers[0]
    if state.sessions[i].isSignature:
      if layer.display.gain == dgAuto:
        layer.display.gain = dgNormalized
        if layer.display.fills == {wfPositive}: layer.display.fills = {}
        if layer.display.overlap == 1.0: layer.display.overlap = SignatureOverlap # (bands that do not touch)
      if state.panels[k].header.auto: state.panels[k].header = SignatureHeader
    else:
      # (left a signature file: what its first look set goes back to the user's)
      if state.panels[k].header == SignatureHeader:
        state.panels[k].header = state.settings.plot.header
      if layer.display.gain == dgNormalized and layer.display.overlap == SignatureOverlap and
          layer.display.fills == {}:
        let d = state.settings.plot.display
        (layer.display.gain, layer.display.overlap, layer.display.fills) = (d.gain, d.overlap,
          d.fills)
  state.selection.activeGather = GatherRef(file: file, gather: gather) # (before the read: it
  inc state.selection.revision # asks whether the record's template is known)
  state.newSource(k)
  if panel == MainPanel: state.followAux()

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

proc requestView(state: var AppState; k: int; readAhead = true) =
  ## Asks `panels[k]`'s reader for its view, unless the request sent last
  ## already covers it. On a slow drive (`slowDrive`) it reads further
  ## ahead, in larger reads. Without `readAhead`, and while the filters
  ## change one after another (`filterRun`), the view alone: each change
  ## filters what is on screen, a quarter of the work, and the read-ahead
  ## comes back with the next view.
  template p: untyped = state.panels[k]
  if p.layers.len == 0 or p.layout.traces == 0 or state.readers[k].isNil: return
  let slow = state.slowDrive(p.id)
  let sliding = not readAhead or (p.filterRun > 0 and p.requestGen == p.filterGen)
  let (ahead, kept, most) = if sliding: (0.0, 0.0, MaxAheadValues)
                            elif slow: (SlowReadAhead, SlowKeepAhead, SlowMaxAheadValues)
                            else: (ReadAhead, KeepAhead, MaxAheadValues)
  let flow = p.layers[0].displayPipeline(state.gatherKind(p.layers[0]))
  let filters = p.layers[0].processing.filterPipeline(p.layout)
  var reversed, killed, excluded: seq[int]
  var own: seq[FilterEntry]
  var shifts: seq[ShiftEntry]
  let (i, traces) = state.shownTraces(k)
  if i >= 0 and state.keyOf(state.sessions[i].path) in state.edits:
    template e: untyped = state.edits[state.keyOf(state.sessions[i].path)]
    reversed = e.listIn(teReversed, traces)
    killed = e.listIn(teKilled, traces)
    excluded = e.listIn(teExcluded, traces)
    own = e.plotFiltersIn(traces)
    shifts = e.shiftsIn(traces)
  let ownHz = i >= 0 and state.keyOf(state.sessions[i].path) in state.edits and
    state.edits[state.keyOf(state.sessions[i].path)].ownNeedsWhole(traces)
  let shiftExtra = if i < 0 or state.keyOf(state.sessions[i].path) notin state.edits: 0
                   else: state.edits[state.keyOf(state.sessions[i].path)].shiftMargin(
                     traces, p.layout.dtMs)
  # While it filters, whole traces: a filter's margin grows as its ramp
  # narrows, and the samples the reader holds must still be enough after
  # a slider has moved, so that it filters them again without a read. The
  # filters' own margin is not worked out here: whole traces hold it, and
  # working it out takes processSEG long for narrow notches (seconds for a
  # few with many harmonics), on this thread, at every view. A trace's own
  # frequency filter asks for the same, so its edges are outside the window.
  # A time shift of k samples needs k more on each side (the move is one
  # way, and the margin is on both), added to the margin already asked for:
  # the shift runs before the display flow, which still needs its own margin
  # of the shifted samples, so the two add. An own filter does not combine
  # a margin here; it asks for the whole trace, as the plot's filters do.
  # Normalized for each trace takes its level from the whole trace, so a
  # zoom does not change it: whole traces here too.
  let wholeTraces = filters.len > 0 or ownHz or
    p.layers[0].normalizesWhole(state.gatherKind(p.layers[0]))
  let base = if wholeTraces:
               max(displayMargin(flow, p.layout.dtMs), p.layout.samples)
             else: displayMargin(flow, p.layout.dtMs)
  let margin = if shiftExtra <= 0: base
               elif base > high(int) - shiftExtra: high(int)
               else: base + shiftExtra
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
  # The record's level is taken over all of the record (`basis`), whatever
  # the view later: its first request when that is all of it (a tile of it
  # gives the level), else every trace or every few, a few reads
  # (`recordRequest`): the reader works it out once the view is drawn, and
  # its first tile stands in meanwhile. The reader keeps those samples.
  let first = p.basis.isEmpty
  if first: p.basis = if req.wholeRecord(p.layout): req else: p.recordRequest(margin)
  let asked = ReaderRequest(read: req, fields: p.shownFields, flow: flow,
    filters: filters, filterAux: p.layers[0].processing.aux,
    flowAux: p.layers[0].flowReachesAux(state.gatherKind(p.layers[0])),
    clipPercentile: p.layers[0].display.clipPercentile, reversed: reversed, killed: killed,
    excluded: excluded, own: own, shifts: shifts,
    raw: rfRawAmplitude in state.settings.readout, chunkTraces: if slow: SlowChunkTraces else: 0,
    basis: first and req.sameReach(p.basis))
  if p.relevel and not p.levelAsked and not req.sameReach(p.basis):
    var whole = asked
    whole.read = p.basis
    (whole.read.gen, whole.read.margin, whole.read.envelope) = (req.gen, req.margin, false)
    whole.fields.setLen 0
    (whole.raw, whole.basis) = (false, false)
    state.readers[k].askLevel(whole)
    p.levelAsked = true
  state.readers[k].request asked

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
    (p.relevel, p.levelSince, p.levelAsked) = (true, p.requestGen, false)
  inc p.revision
  state.requestView(k)

proc resample(state: var AppState; k: int; relevel = false; readAhead = true) =
  ## Asks again for `panels[k]`'s view: what its samples hold has changed
  ## (the polarity, an edit, the filters). The tiles from before are drawn
  ## until the first one after the change comes (`drainInbox`), so the plot
  ## never goes blank; with `relevel`, that tile sets the panel's level
  ## again; without `readAhead`, the view alone is asked for.
  template p: untyped = state.panels[k]
  inc p.requestGen
  p.samplesGen = p.requestGen
  if relevel: (p.relevel, p.levelSince, p.levelAsked) = (true, p.requestGen, false)
  p.pending = ReadRequest()
  inc p.revision
  state.requestView(k, readAhead)

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
    # (the record's: not one that stands in for it while it is worked out)
    if not usable(d.fixedClip) and usable(p.level.clip) and not p.relevel:
      d.fixedClip = p.level.clip
      inc p.revision
      # kept for the next run too, as a typed amplitude is
      let clip = d.fixedClip
      if p.role == prAux:
        state.change(by, s):
          if s.aux.display.gain == dgFixed and not usable(s.aux.display.fixedClip):
            s.aux.display.fixedClip = clip
      else:
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
  state.choose(if i >= 0: state.sessions[i].diskPath else: "")

proc watchOpen(state: var AppState) =
  ## Tells the folder's watch which files are open now, or are to be shown
  ## again once they stop changing.
  var paths: seq[string]
  for s in state.sessions:
    let p = s.diskPath
    if p notin paths: paths.add p
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
  state.dropMoveBases(s.id)
  state.moveQueue.keepItIf(it != s.id)
  state.leapQueue.keepItIf(it != s.id)
  for job in state.jobs.list:
    if job.state in {jsQueued, jsRunning} and
        (s.path in job.spec.reads or s.path in job.spec.exclusive):
      # A file changing on disk is let go of to be shown again. The reopen
      # the user asked for is that showing: cancelling it and then attaching
      # to the cancelled open would leave the file closed.
      var kept = false
      if keepLayers:
        for o in state.opening:
          if o.job == job.id and o.reopened and not o.unwanted: kept = true
      if not kept:
        if not state.correlate.isNil and state.correlate.job == job.id:
          state.correlateRetired.add state.correlate
          state.correlate = nil
        discard state.jobs.cancel(job.id)
  state.selection.forget(s.id, s.traceIds)
  if not state.inspector.isNil: state.inspector.dropSession(int(s.id))
  # the pilots taken from this file's records: the dialog's preview, and the windows of
  # references (their reads were cancelled with the file's jobs; a late answer is dropped)
  if state.pilotShown.key.startsWith(s.path & "|"):
    inc state.pilotShown.gen
    state.pilotShown = PilotPreview(key: "none", problem: NoFilePilot, gen: state.pilotShown.gen)
  for w in state.refViews.mitems:
    if w.pilot.trace > 0 and w.pilotTrace >= 0 and w.pilotTrace in s:
      w = RefView(id: w.id, refId: w.refId, name: w.name, pilot: w.pilot, pilotTrace: -1,
        note: NoFilePilot, noFile: true, revision: w.revision + 1)
  # the analysis windows of the file: what is being worked out for them stops,
  # and a window waiting for it says why and waits for nothing
  for k in 0 ..< state.plots.len:
    template pw: untyped = state.plots[k]
    let ofFile = pw.traces.len > 0 and pw.traces[0] in s
    if ofFile:
      if not state.analysisReader.isNil: state.analysisReader.cancel(pw.id)
      if not pw.frozen and pw.pilotKey.len > 0:
        # taken against a pilot of this file's records: nothing of it is kept, and
        # the window says there is no file (a frozen one keeps what it showed)
        inc state.plotGen
        pw.asked = state.plotGen
        pw.result = AnalysisResult(view: pw.view, gen: state.plotGen, id: pw.id,
          problem: NoFilePilot)
        pw.pilotKey = ""
        pw.since = state.plotGen
        inc pw.revision
      if pw.waiting:
        pw.waiting = false
        # A window that already has numbers keeps them (a frozen one, as a
        # frozen spectrum window does). One still waiting for its first
        # answer says why.
        if pw.result.gen == 0:
          pw.result.problem = "its file was closed"
        inc pw.revision
  for k in 0 ..< state.spectra.len:
    template sw: untyped = state.spectra[k]
    if sw.traces.len > 0 and sw.traces[0] in s:
      if not state.spectrumReader.isNil: state.spectrumReader.cancel(sw.id)
      if sw.waiting:
        sw.waiting = false
        if sw.spectrum.raw.len == 0:
          sw.spectrum.problem = "its file was closed"
        inc sw.revision
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
  if not keepLayers and state.files.chosen == s.diskPath and
      state.shownFile(state.findPanel(MainPanel)) < 0:
    state.choose("")
  # A derived view was never the file the user opened. Deleting by its key
  # would forget who opened the file on disk.
  if not keepLayers and not s.derived: state.openedBy.del s.path
  state.closing.add Pending(job: job, path: s.path, session: s, quiet: quiet)
  state.watchOpen()

proc failed(state: var AppState; path: string) =
  ## Notes that `path` of the file list could not be shown.
  if path notin state.files.failed:
    state.files.failed.add path
    inc state.files.revision

func plotsUse(state: AppState; file: SessionId): bool

func spectraUse(state: AppState; file: SessionId): bool =
  ## Whether a spectrum window is of traces of open file `file`: then
  ## showing another file in the plot keeps it open (a frozen one, or one
  ## not yet followed onto the new file).
  let i = state.findSession(file)
  if i < 0: return false
  let s = state.sessions[i]
  for w in state.spectra:
    if w.traces.len > 0 and w.traces[0] in s: return true
  false

proc closeIfUnused(state: var AppState; id: SessionId) =
  ## Closes open file `id` when no panel shows it and no analysis window
  ## uses it. A derived view is closed before its origin.
  if id == NoSession: return
  if state.panels.anyIt(it.layers.anyIt(it.shows(id))): return
  if state.plotsUse(id) or state.spectraUse(id): return
  let i = state.findSession(id)
  if i >= 0: state.closeSession(i, quiet = true)

proc showReplacing(state: var AppState; k: int; file: SessionId; gather: int) =
  ## Shows `gather` of `file` in `panels[k]`, in place of what it showed,
  ## and closes the file it showed when no other panel shows it and no
  ## analysis window uses it (a pilot it correlates against): stepping
  ## through a folder keeps one file open, not every file seen. A derived
  ## view of the same file on disk does not close that file; leaving it
  ## closes the derived view first, then the file on disk.
  let shown = state.shownFile(k)
  let old = if shown >= 0: state.sessions[shown].id else: NoSession
  let oldDisk = if shown >= 0: state.sessions[shown].diskPath else: ""
  let oldDerived = shown >= 0 and state.sessions[shown].derived
  state.show(state.panels[k].id, file, gather)
  if old == NoSession or old == file: return
  let ni = state.findSession(file)
  let newDisk = if ni >= 0: state.sessions[ni].diskPath else: ""
  if newDisk.len > 0 and newDisk == oldDisk:
    if oldDerived: state.closeIfUnused(old)
    return
  if oldDerived:
    state.closeIfUnused(old)
    var origin = NoSession
    for s in state.sessions:
      if not s.derived and s.diskPath == oldDisk: origin = s.id
    state.closeIfUnused(origin)
  else:
    var derived = NoSession
    for s in state.sessions:
      if s.derived and s.diskPath == oldDisk: derived = s.id
    if derived != NoSession: state.closeIfUnused(derived)
    state.closeIfUnused(old)

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

func auxPositionOf*(state: AppState; id: int): int =
  ## The position, from 1, of survey-wide trace `id` among the auxiliary traces of its
  ## record in file order (the position an auxiliary mark names); 0 for a seismic trace
  ## or a trace that is in no record.
  let i = state.findTrace(id)
  if i < 0: return 0
  let s = state.sessions[i]
  let local = id - s.base
  let f = s.filePtr
  if f == nil or local notin 0 ..< f[].len or isSeismic(f[].index, local): return 0
  let g = s.gatherOf(local)
  if g < 0: return 0
  for t in max(s.gathers[g].traces.a, 0) .. local:
    if not isSeismic(f[].index, t): inc result

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

func stepsText(p: Pipeline): string =
  ## A pipeline's steps and their parameters, as text, to compare (a step
  ## has no `==`): another step or parameter is another text; "" for none.
  for op in p: result.add $op & ";"

proc followInspect(state: var AppState) =
  ## After every change: the traces the Headers window's Trace tab is about
  ## found again when the selection changed, and its reader asked for what
  ## the window has on screen when that is not what it was asked for last
  ## (other traces, another record, their edits or the plot's processing
  ## when they are shown as displayed, their keys after a geometry join
  ## or a station move).
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
  want.vendor = (NoSession, -1)
  want.vendorGen = state.vendor.gen
  if ipRecord in ins.parts and shown >= 0:
    let s = state.sessions[shown]
    let g = state.panels[k].layers[0].source.gather
    want.vendor = (s.id, if g in 0 ..< s.gathers.len: s.file.segdRecordOf(s.gathers[g].traces.a)
                         else: -1)
  let traceParts = ins.parts * {ipTraceHeaders, ipTraceSamples}
  if traceParts != {}: want.traces = ins.chosen.traces
  want.tableOf = (NoSession, 0 .. -1)
  if ipTable in ins.parts and shown >= 0:
    let s = state.sessions[shown]
    let g = state.panels[k].layers[0].source.gather
    let scope = if ins.table.scope == tsFile: 0 ..< s.len
                elif g in 0 ..< s.gathers.len: s.gathers[g].traces
                else: 0 .. -1
    want.tableOf = (s.id, scope)
    want.table = ins.table
  want.joins = state.joinReport.serial
  block shownKeys:
    var seen: seq[SessionId] = @[]
    for t in want.traces:
      let i = state.findTrace(t)
      if i >= 0:
        let id = state.sessions[i].id
        if id notin seen:
          seen.add id
          want.keysRev.add state.sessions[i].keysRevision
    if want.tableOf[0] != NoSession and want.tableOf[0] notin seen:
      let i = state.findSession(want.tableOf[0])
      if i >= 0: want.keysRev.add state.sessions[i].keysRevision
  want.displayed = view.asDisplayed and ipTraceSamples in ins.parts
  if want.displayed:
    for t in want.traces:
      want.edits.add state.traceEdits(t)
      let i = state.findTrace(t)
      if i >= 0:
        let s = state.sessions[i]
        let e = state.editsAt(s.path)
        var (has, f) = e.ownOf(t - s.base)
        if e.has(teExcluded, t - s.base): # the plot's filters never touch it: its own run instead
          has = true
          f.place = fpInstead
        want.hasOwn.add has
        want.own.add f
        want.shiftMs.add e.shiftOf(t - s.base)
      else:
        want.hasOwn.add false
        want.own.add OwnFilter()
        want.shiftMs.add 0.0
    if shown >= 0:
      let layer = state.panels[k].layers[0]
      want.shown = state.sessions[shown].id
      let filters = layer.processing.filterPipeline(state.panels[k].layout)
      want.flow = (layer.reversed, stepsText(layer.pipeline) & "|" & stepsText(filters) &
        (if layer.processing.aux: "|aux" else: ""), state.gatherKind(layer))
      want.display = layer.display
  template was: untyped = state.asked
  if want.parts == was.parts and want.traces == was.traces and want.edits == was.edits and
      want.own == was.own and want.hasOwn == was.hasOwn and want.shiftMs == was.shiftMs and
      want.joins == was.joins and want.keysRev == was.keysRev and
      want.displayed == was.displayed and
      want.table == was.table and want.tableOf == was.tableOf and
      want.shown == was.shown and want.record == was.record and
      want.vendor == was.vendor and want.vendorGen == was.vendorGen and
      want.flow == was.flow and want.display.sameProcessing(was.display, want.flow[2]):
    return
  state.asked = want
  if want.record[0] == NoSession and want.traces.len == 0 and want.tableOf[0] == NoSession and
      want.vendor[0] == NoSession:
    if ins.answer.traces.len > 0 or ins.answer.recordPath.len > 0 or
        ins.answer.vendor.path.len > 0 or
        ins.answer.table.path.len > 0:
      ins.answer = Inspected()
      inc ins.revision
    ins.waiting = false
    # an answer still on its way is of what is no longer on screen: dropped
    state.answerGen = state.inspectGen
    return
  inc state.inspectGen
  var req = InspectRequest(gen: state.inspectGen, headers: ipTraceHeaders in ins.parts,
    samples: ipTraceSamples in ins.parts, vendorGen: want.vendorGen)
  var held: seq[SessionId] # by `req.files`' index; NoSession for a file that could not be held
  proc fileOf(state: var AppState; req: var InspectRequest; held: var seq[SessionId];
      i: int): int =
    ## The index in `req.files` of open file `sessions[i]`, held on first use;
    ## -1 when it cannot be held.
    let s = state.sessions[i]
    result = held.find(s.id)
    if result < 0 and state.jobs.hold(s.path):
      req.files.add InspectFile(file: s.filePtr, path: s.path, session: s.id, size: s.size,
        view: s.correlatedView)
      held.add s.id
      result = held.high
  if want.record[0] != NoSession:
    req.recordAt = state.fileOf(req, held, state.findSession(want.record[0]))
    req.record = want.record[1]
  if want.vendor[0] != NoSession:
    req.vendorAt = state.fileOf(req, held, state.findSession(want.vendor[0]))
    req.vendorRecord = want.vendor[1]
  if want.displayed and shown >= 0:
    let layer = state.panels[k].layers[0]
    req.flow = layer.displayPipeline(state.gatherKind(layer))
    req.filters = layer.processing.filterPipeline(state.panels[k].layout)
    req.filterAux = layer.processing.aux
    req.flowAux = layer.flowReachesAux(state.gatherKind(layer))
  if want.tableOf[0] != NoSession:
    req.table = TableAsk(at: state.fileOf(req, held, state.findSession(want.tableOf[0])),
      traces: want.tableOf[1], view: want.table, joins: want.joins)
  for n, t in want.traces:
    let i = state.findTrace(t)
    if i >= 0:
      let s = state.sessions[i]
      req.traces.add InspectTrace(id: t, at: state.fileOf(req, held, i), trace: t - s.base,
        edits: (if want.displayed: want.edits[n] else: {}),
        own: (if want.displayed and n < want.own.len: want.own[n] else: OwnFilter()),
        hasOwn: want.displayed and n < want.hasOwn.len and want.hasOwn[n],
        shiftMs: (if want.displayed and n < want.shiftMs.len: want.shiftMs[n] else: 0.0),
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

proc sayMismatch(state: var AppState; path: string) =
  ## Says once for each file that the project's vendor map does not apply to it.
  if path.len == 0 or path in state.vendor.mismatched: return
  state.vendor.mismatched.add path
  state.log.add(sevWarning, "vendor maps", "The project's vendor map " &
    state.vendor.choice.name & " does not apply to " & path.extractFilename & " (its format, " &
    "revision, manufacturer or serial number is not the one the map says, and a map is never " &
    "forced onto a file it does not match): no vendor field is shown for it.")

proc takeInspected(state: var AppState; m: sink Msg) =
  ## An answer of the Headers window's reader newer than the one shown (the
  ## newest asked or not: while the pointer moves, each answer is a request
  ## behind, and showing it beats waiting).
  if m.inspected.gen > state.answerGen:
    state.answerGen = m.inspected.gen
    if m.inspected.vendor.mismatch: state.sayMismatch(m.inspected.vendor.path)
    for d in m.inspected.traces:
      if d.vendor.mismatch: state.sayMismatch(d.vendor.path)
    state.inspect.answer = move m.inspected
    if state.answerGen >= state.inspectGen: state.inspect.waiting = false
    inc state.inspect.revision
# ------------------------------------------------------------- spectra --

proc spectrumReaderFor(state: var AppState; path: string): lent SpectrumReader =
  ## The spectrum reader, started when first needed; one stuck in a drive
  ## that does not answer is left to end on its own when `path` is another
  ## file (a request of that file waits for it).
  if not state.spectrumReader.isNil and state.spectrumReader.silentFor >= StallAfter and
      state.spectrumReader.readingPath != path:
    state.spectrumReader.leave()
    state.leftSpectrumReaders.add move state.spectrumReader
  if state.spectrumReader.isNil:
    state.spectrumReader = newSpectrumReader(state.inbox.poster, state.jobs.holdRelease)
  state.spectrumReader

proc spectrumAsked*(state: AppState): tuple[path: string; session: int] =
  ## The path and session of the newest spectrum request; ("", -1) when none
  ## was asked, or the reader was never started.
  if state.spectrumReader.isNil: return ("", -1)
  state.spectrumReader.asked

func spectrumFilters(p: Panel): Processing =
  ## The filters a spectrum of `p`'s traces is processed with: its layer
  ## 0's, shown raw or not (the two curves compare), with whether its
  ## auxiliary traces go through them. The spectrum's reader makes them for
  ## the traces' own interval.
  result = p.layers[0].processing
  result.raw = false

func shownKinds*(state: AppState; p: Panel): (int, int) =
  ## The seismic and the auxiliary traces `p` shows: its positions, so as
  ## its reader laid them out (the trace filter, killed traces hidden);
  ## (0, 0) while it is not laid out or shows no file. Reads the file's
  ## index only.
  result = (0, 0)
  if p.layers.len > 0 and p.laidOut and p.shown.len == p.layout.traces:
    let i = state.findSession(p.layers[0].source.file)
    if i >= 0:
      let f = state.sessions[i].filePtr
      for t in p.shown:
        if t in 0 ..< f[].len:
          if isSeismic(f[].index, t): inc result[0] else: inc result[1]

func filterReach*(state: AppState; p: Panel): FilterReach =
  ## Which of the traces `p` shows its filters reach (`Processing.reach`):
  ## `frNoTrace` when they are all auxiliary and the Aux toggle is off.
  if p.layers.len == 0: return frNone
  let (seismic, aux) = state.shownKinds(p)
  p.layers[0].processing.reach(seismic, aux)

func filtersText(pr: Processing): string =
  ## `pr` in words; "" for no filter.
  if pr.hasFilters: pr.describe else: ""

func recordText(s: Session; trace: int): string =
  ## The record trace `trace` (in the file) is in, as the windows name it:
  ## "FFID 151", or "record 3" when its FFID is not known.
  let g = s.gatherOf(trace)
  if g < 0 or g >= s.records.len: ""
  elif abs(s.records[g].record) < 1e15: "FFID " & $int64(s.records[g].record)
  else: "record " & $(g + 1)

func ownKeyOf(e: FileEdits; traces: openArray[int]): string =
  ## The own filters of `traces`, which of them are reversed on their own,
  ## their time shifts, and whether every trace is reversed, as a key: a
  ## change of one asks a spectrum or an analysis again. Reverse-all is one
  ## mark, not a list of every trace.
  if e.allReversed: result.add "all;"
  for t in traces:
    let (has, f) = e.ownOf(t)
    if has: result.add $t & ":" & $f.place & ":" & $f.spec & ";"
    if e.has(teReversed, t): result.add $t & ":r;"
    if e.has(teExcluded, t): result.add $t & ":e;"
    let ms = e.shiftOf(t)
    if ms != 0.0: result.add $t & ":s:" & $ms & ";"

func pilotKeyOf(e: FileEdits; trace: int): string =
  ## What a pilot taken by a rule depends on in its trace's edits: its own reversal
  ## and its time shift, nothing the plot decides.
  if e.has(teReversed, trace): result.add "r;"
  let ms = e.shiftOf(trace)
  if ms != 0.0: result.add "s:" & $ms & ";"

proc reversedOf(e: FileEdits; traces: openArray[int]): seq[int] =
  ## Those of `traces` effectively reversed (`effectivelyReversed`: own
  ## reversal or reverse all, not both), ascending. The one list every graph
  ## flips.
  for t in traces:
    if e.effectivelyReversed(t): result.add t
  result.sort()

func shiftsOfTraces(e: FileEdits; traces: openArray[int]): seq[ShiftEntry] =
  ## The time shifts of `traces`, ascending. Empty when none is shifted.
  if traces.len == 0: return
  var lo = traces[0]
  var hi = traces[0]
  for t in traces:
    if t < lo: lo = t
    if t > hi: hi = t
  for s in e.shiftsIn(lo .. hi):
    if s.trace in traces: result.add s

func ownOfTraces(e: FileEdits; traces: openArray[int]): seq[FilterEntry] =
  ## The own filters of `traces` as the readers of the plot's filters need them,
  ## ascending: a trace excluded from the plot's filters has its own run instead
  ## of them (`plotFiltersIn`).
  if traces.len == 0: return
  var lo = traces[0]
  var hi = traces[0]
  for t in traces:
    if t < lo: lo = t
    if t > hi: hi = t
  for f in e.plotFiltersIn(lo .. hi):
    if f.trace in traces: result.add f

proc pilotOfRecord(s: Session; g: int; rule: PilotRule; e: FileEdits): tuple[trace: int;
    record, problem: string] =
  ## The trace of file `s` that `rule` takes from its gather `g` (the record):
  ## its index in the file and the record's name; else a `problem` saying what
  ## the record lacks, or that the trace is killed or marked dead (`e`: the
  ## file's edits). Reads the keys already held, never the file.
  result.trace = -1
  if g notin 0 ..< s.gathers.len:
    result.problem = "There is no record on show."
    return
  let span = s.gathers[g].traces
  result.record = s.recordText(span.a)
  let picked = pilotInSpan(s.filePtr, span, result.record, rule, e)
  result.trace = picked.trace
  result.problem = picked.problem

func killedOf(e: FileEdits; traces: openArray[int]): seq[int] =
  ## Those of `traces` killed in `e`, in their order. `e` comes from
  ## `editsAt`, which finds a file's edits under any of its paths.
  for t in traces:
    if e.has(teKilled, t): result.add t

func axisT0Of(state: AppState; k: int): float64 =
  ## The time of sample 0 on the time axis of `panels[k]` (NaN until it is laid out).
  if k >= 0 and state.panels[k].laidOut: state.panels[k].layout.t0Ms else: NaN

proc askSpectrum(state: var AppState; w: int; i: int; traces: seq[int];
    window: (float64, float64); processing: Processing): bool =
  ## Asks the spectrum reader for window `spectra[w]`'s spectrum of
  ## `traces` (indices in open file `sessions[i]`, killed ones left out)
  ## over `window` (ms; NaN: the whole trace); false when the file cannot
  ## be held (a job needs it to itself).
  let s = state.sessions[i]
  if not state.jobs.hold(s.path): return false
  let e = state.editsAt(s.path)
  var killed = killedOf(e, traces) # (under its key: `keyOf`)
  killed.sort()
  let own = ownOfTraces(e, traces)
  let reversed = reversedOf(e, traces)
  let shifts = shiftsOfTraces(e, traces)
  inc state.spectrumGen
  template sw: untyped = state.spectra[w]
  let axisT0 = sw.axisT0Ms
  sw.asked = state.spectrumGen
  sw.waiting = true
  sw.killed = killed
  sw.editsSeen = e.revision
  sw.ownKey = ownKeyOf(e, traces)
  sw.filters = filtersText(processing)
  inc sw.asks
  inc sw.revision
  state.spectrumReaderFor(s.path).ask SpectrumAsk(id: sw.id, gen: state.spectrumGen,
    session: int(s.id), file: s.filePtr, view: s.correlatedView, path: s.path, size: s.size,
    traces: traces,
    killed: killed, reversed: reversed, allReversed: e.allReversed, own: own,
    shifts: shifts,
    fromMs: window[0], toMs: window[1], axisT0Ms: axisT0, processing: processing)
  true

func spread(list: var seq[int]; samples: int) =
  ## `list` (ascending) cut to the traces a spectrum takes of traces of
  ## `samples` samples (`spectrumTraces`), spread evenly over it.
  let most = spectrumTraces(samples)
  if list.len > most:
    var kept = newSeq[int]()
    for j in evenly(list.len, most): kept.add list[j]
    list = kept

func liveTraces(state: AppState; k, i: int): (seq[int], SpectrumOf, int) =
  ## What a spectrum that follows the plot is of: the selected traces of the
  ## record `panels[k]` shows (`sessions[i]`), else the traces in its view;
  ## at most what a spectrum takes (`spectrumTraces`), spread evenly;
  ## indices in the file, ascending; and how many were chosen. A selection
  ## in another record is not this record's.
  template p: untyped = state.panels[k]
  let s = state.sessions[i]
  var list: seq[int]
  var chosen = soNothing
  if state.selection.anySelected:
    var order: seq[int] = @[]
    if p.shown.len > 0: order = p.shown
    elif p.layers.len > 0:
      let g = p.layers[0].source.gather
      if g in 0 ..< s.gathers.len:
        for t in s.gathers[g].traces: order.add t
    for t in order:
      if s.base + t in state.selection.selected: list.add t
    if list.len > 0: chosen = soSelection
  if list.len == 0 and p.laidOut and p.shown.len == p.layout.traces:
    let vis = visiblePositions(p.layout, p.view)
    for pos in vis: list.add p.shown[pos]
    if list.len > 0: chosen = soVisible
  list.sort()
  let count = list.len
  list.spread(p.layout.samples)
  (list, chosen, count)

proc askAgain(state: var AppState; w: int): bool =
  ## FFT window `spectra[w]` asked again for its traces over its time, with
  ## the filters it has (`processing`); false when its file is not open any
  ## more or cannot be held now.
  template sw: untyped = state.spectra[w]
  let i = state.findTrace(if sw.traces.len > 0: sw.traces[0] else: -1)
  if i < 0: return false
  let s = state.sessions[i]
  let window = if sw.display.time == stVisible and sw.visibleMs.hi > sw.visibleMs.lo:
                 (sw.visibleMs.lo, sw.visibleMs.hi)
               else: (NaN, NaN)
  var traces: seq[int]
  for t in sw.traces:
    if t in s: traces.add t - s.base
  state.askSpectrum(w, i, traces, window, sw.processing)

func sameFollow(a, b: LiveKey): bool =
  ## Whether two follow keys are the same request. A window whose time is
  ## not a number compares equal to another (both are the whole trace).
  a.session == b.session and a.traces == b.traces and a.processing == b.processing and
    a.killed == b.killed and a.own == b.own and
    (a.window == b.window or (a.window[0].isNaN and b.window[0].isNaN))

func killedNow(state: AppState; sw: SpectrumWindow): (bool, seq[int], int) =
  ## Whether the kills among FFT window `sw`'s traces changed since it
  ## asked (its file's edits moved on); the killed ones now, ascending, and
  ## the edits' revision. Its file not open: unchanged.
  result = (false, @[], sw.editsSeen)
  let i = state.findTrace(if sw.traces.len > 0: sw.traces[0] else: -1)
  if i >= 0:
    let s = state.sessions[i]
    let e = state.editsAt(s.path)
    if e.revision != sw.editsSeen:
      var traces: seq[int] = @[]
      for t in sw.traces:
        if t in s: traces.add t - s.base
      var killed = killedOf(e, traces)
      killed.sort()
      result = (killed != sw.killed, killed, e.revision)

proc followLive(state: var AppState) =
  ## The live panel, while on screen and not frozen, asked again when what
  ## it is of changed (the traces in view or selected, the record, the
  ## file, the time in view, the filters, a kill, a shown trace's own
  ## filter or reversal, reverse-all). Nothing is asked while it is hidden.
  template live: untyped = state.spectra[0]
  if live.display != state.settings.spectrum.live:
    live.display = state.settings.spectrum.live
    inc live.revision
  if not live.shown or live.frozen: return
  let k = state.findPanel(MainPanel)
  let i = if k >= 0: state.shownFile(k) else: -1
  var key = LiveKey(session: NoSession)
  var chosen = soNothing
  var count = 0
  if i >= 0 and state.panels[k].layers.len > 0:
    template p: untyped = state.panels[k]
    (key.traces, chosen, count) = state.liveTraces(k, i)
    key.session = state.sessions[i].id
    key.window = if live.display.time == stVisible and p.view.timeMs.hi > p.view.timeMs.lo:
                   (p.view.timeMs.lo, p.view.timeMs.hi)
                 else: (NaN, NaN)
    key.processing = spectrumFilters(p)
    let e = state.editsAt(state.sessions[i].path)
    key.killed = killedOf(e, key.traces)
    key.own = ownKeyOf(e, key.traces)
  if sameFollow(key, state.liveKey): return
  state.liveKey = key
  if key.traces.len == 0:
    # Nothing to show: what is shown goes, and an answer on its way is dropped.
    if not state.spectrumReader.isNil: state.spectrumReader.cancel(LiveSpectrum)
    live.traces.setLen 0
    live.chosen = soNothing
    live.file = ""
    live.record = ""
    live.spectrum = Spectrum()
    live.waiting = false
    live.since = state.spectrumGen + 1 # nothing asked before is taken
    inc live.revision
    return
  let s = state.sessions[i]
  if state.askSpectrum(0, i, key.traces, key.window, key.processing):
    live.chosen = chosen
    live.file = s.name
    live.record = s.recordText(key.traces[0])
    live.traces = key.traces.mapIt(it + s.base)
    live.first = key.traces[0]
    live.chosenCount = count
    live.processing = key.processing
    live.visibleMs = state.panels[k].view.timeMs
    live.axisT0Ms = state.axisT0Of(k)
  else:
    state.liveKey = LiveKey(session: NoSession) # asked again once it can be held

proc stampSpectrum(state: var AppState; w, k, i: int)

proc openSpectrum(state: var AppState; cmd: Command) =
  ## `ckSpectrum`: a new FFT window of `cmd.spectrumTraces` (else the
  ## selected traces) of the panel's file, a snapshot asked for at once.
  let k = state.findPanel(if cmd.spectrumOf == NoPanel: MainPanel else: cmd.spectrumOf)
  let i = if k >= 0: state.shownFile(k) else: -1
  if k < 0:
    state.ignore(cmd, $cmd.spectrumOf & " does not exist")
    return
  if i < 0:
    state.ignore(cmd, "the panel shows no file")
    return
  if state.spectra.len > MaxSpectrumWindows:
    state.ignore(cmd, $MaxSpectrumWindows & " FFT windows are open; close one first")
    return
  let s = state.sessions[i]
  var ids = cmd.spectrumTraces
  var chosen = soTrace
  if ids.len == 0:
    for t in state.selection.selected:
      if t in s: ids.add t
    chosen = soSelection
  var traces: seq[int]
  var outside = 0
  for t in ids:
    if t in s: traces.add t - s.base
    else: inc outside
  traces.sort()
  traces = deduplicate(traces, isSorted = true)
  let count = traces.len
  traces.spread(state.panels[k].layout.samples)
  if traces.len == 0 and ids.len == 0:
    # nothing selected: the window opens saying what to click, and the selection fills it
    template p: untyped = state.panels[k]
    state.spectra.add SpectrumWindow(id: freeSpectrumId(state.spectra),
      display: cmd.spectrumShow, chosen: soNothing, heldOpen: true, file: s.name, panel: p.id,
      visibleMs: p.view.timeMs, axisT0Ms: state.axisT0Of(k), processing: spectrumFilters(p),
      since: state.spectrumGen + 1)
    state.spectra[^1].filters = filtersText(state.spectra[^1].processing)
    state.stampSpectrum(state.spectra.high, k, i)
    state.change(cmd.origin, x):
      x.spectrum.window = cmd.spectrumShow
    return
  if traces.len == 0:
    state.ignore(cmd, "none of the traces is in " & s.name)
    return
  if traces.len > 1 and chosen == soTrace: chosen = soSelection
  template p: untyped = state.panels[k]
  var w = SpectrumWindow(id: freeSpectrumId(state.spectra), display: cmd.spectrumShow,
    chosen: chosen, heldOpen: true, file: s.name, record: s.recordText(traces[0]),
    traces: traces.mapIt(it + s.base), first: traces[0], chosenCount: count,
    visibleMs: p.view.timeMs, axisT0Ms: state.axisT0Of(k), panel: p.id,
    processing: spectrumFilters(p))
  w.filters = filtersText(w.processing)
  state.spectra.add w
  let window = if w.display.time == stVisible and p.view.timeMs.hi > p.view.timeMs.lo:
                 (p.view.timeMs.lo, p.view.timeMs.hi)
               else: (NaN, NaN)
  state.spectra[^1].since = state.spectrumGen + 1 # a closed window's answers are not its
  if not state.askSpectrum(state.spectra.high, i, traces, window, w.processing):
    state.spectra.delete state.spectra.high
    state.ignore(cmd, s.name & " is busy (a job needs it to itself)")
    return
  state.stampSpectrum(state.spectra.high, k, i)
  state.change(cmd.origin, x):
    x.spectrum.window = cmd.spectrumShow
  if outside > 0:
    state.log.add(sevWarning, s.name, $outside & " of the traces given are not in " & s.name &
      ": left out of the spectrum.")

proc followSpectrum(state: var AppState) =
  ## After every change: the live panel follows what it is of
  ## (`followLive`). FFT windows follow with the New plot windows
  ## (`followSpectra`, the same pick). Each window's held cursor stays at
  ## its frequency and on its curve when the spectrum changes or the curves
  ## drawn do (`followCursor`).
  state.followLive()
  for sw in state.spectra.mitems:
    if sw.followCursor(): inc sw.revision

proc showSpectrum(state: var AppState; cmd: Command) =
  ## `ckSpectrumDisplay`: how a window shows its spectrum, and whether it is
  ## frozen. A new time window asks again (an FFT window over the time it
  ## shows); the live panel keeps it for the next run, a new FFT window
  ## starts as the last one changed. Frozen, a window keeps the traces and
  ## the file it shows; unfrozen, it follows the plot at once.
  let w = state.findSpectrum(cmd.spectrum)
  if w < 0:
    state.ignore(cmd, "there is no spectrum window " & $cmd.spectrum)
    return
  template sw: untyped = state.spectra[w]
  let was = sw.display
  if cmd.spectrum == LiveSpectrum:
    if cmd.frozen != sw.frozen:
      sw.frozen = cmd.frozen
      inc sw.freezeApplies
      inc sw.revision
    state.change(cmd.origin, x):
      x.spectrum.live = cmd.spectrumShow
    return # `followSpectrum` asks again
  sw.display = cmd.spectrumShow
  let wasFrozen = sw.frozen
  sw.frozen = cmd.frozen # unfrozen, `followSpectra` follows the plot at once
  if sw.frozen != wasFrozen: inc sw.freezeApplies
  if wasFrozen and not sw.frozen: sw.heldOpen = false
  inc sw.revision
  state.change(cmd.origin, x):
    x.spectrum.window = cmd.spectrumShow
  if was.time != sw.display.time:
    if state.findTrace(if sw.traces.len > 0: sw.traces[0] else: -1) < 0:
      state.log.add(sevWarning, "spectrum", "The file of " & sw.title & " is not " &
        "open any more: its spectrum stays over the time it had.")
      return
    discard state.askAgain(w) # the filters it has (frozen or not)

proc closeSpectrum(state: var AppState; cmd: Command) =
  ## `ckCloseSpectrum`: the FFT window goes, its work with it.
  let w = state.findSpectrum(cmd.spectrum)
  if cmd.spectrum == LiveSpectrum:
    state.ignore(cmd, "the live spectrum panel is hidden from the Window menu")
    return
  if w < 0:
    state.ignore(cmd, "there is no FFT window " & $cmd.spectrum)
    return
  if not state.spectrumReader.isNil: state.spectrumReader.cancel(cmd.spectrum)
  state.spectra.delete w
  if state.spectra.len == 1 and not state.spectra[0].shown:
    state.spectrumReader.forget() # no window needs the traces at hand

proc takeSpectrum(state: var AppState; m: sink Msg) =
  ## A spectrum for a window still open, newer than the one it shows (an
  ## older one is stale: dropped); while the live panel follows a pan, each
  ## answer is a request behind, and showing it beats waiting.
  let w = state.findSpectrum(m.spectrum.id)
  if w >= 0 and m.spectrum.gen > state.spectra[w].spectrum.gen and
      m.spectrum.gen >= state.spectra[w].since and m.spectrum.gen <= state.spectra[w].asked:
    template sw: untyped = state.spectra[w]
    sw.waiting = m.spectrum.gen < sw.asked
    let words = m.spectrum.filters
    sw.spectrum = move m.spectrum
    if words.len > 0: sw.filters = words
    inc sw.revision

include stateplots

proc showListedShot(state: var AppState; cmd: Command): bool

proc showPoints(state: var AppState; cmd: Command) =
  ## `ckShowPoints`: the main panel shows the record of the traces recorded
  ## at `cmd.points` (a source's shot record), in the file it shows when it
  ## has some, else in the file that has the first; nothing changes when it
  ## shows one of them already. With `shotPath`, that listed file's record of
  ## the shot (the point's menu chose it).
  let k = state.findPanel(MainPanel)
  if cmd.shotPath.len > 0 and state.showListedShot(cmd): return
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

func shotRowsChosen*(state: AppState): lent ShotRows {.inline.} =
  ## The rows chosen in a loaded shot log, from the map or the grid; `log` is -1 for none.
  state.shotRows

func shotIndexOf*(state: AppState; log: int): typeof(state.follow.indexOf(0)) {.inline.} =
  ## The lookup of loaded shot log `log` (by time, station and file number), or nil while it is
  ## not built.
  state.follow.indexOf(log)

func hoveredShotRows*(state: AppState; log: int): seq[int] =
  ## The rows of loaded shot log `log` at the map points under the pointer, each once.
  for p in state.selection.hoverPoints:
    let i = state.survey.find(p.layer)
    if i >= 0 and state.survey.layers[i].origin == loShotLog and
        state.survey.layers[i].shotLog == log:
      for row in state.survey.layers[i].rowsAtPoint(p.point, state.follow.indexOf(log)):
        if row notin result: result.add row

proc showShotTraces(state: var AppState; k: int; found: seq[int]) =
  ## The main panel `k` shows the record that holds the first of survey-wide traces `found`
  ## (ascending); a record on show that holds one of them stays.
  let (shown, gather) = state.shownTraces(k)
  for t in found:
    if shown >= 0 and t in state.sessions[shown] and t - state.sessions[shown].base in gather:
      return
  let i = state.findTrace(found[0])
  let g = if i >= 0: state.sessions[i].gatherOf(found[0] - state.sessions[i].base) else: -1
  if g >= 0:
    if state.shownFile(k) != i: state.showReplacing(k, state.sessions[i].id, g)
    else: state.show(MainPanel, state.sessions[i].id, g)

func shotTraceKey(state: AppState; i, log: int): tuple[session, keys, log, revision: int] =
  ## What a map of the traces of `sessions[i]` against shot log index `log` is for.
  (int(state.sessions[i].id), state.sessions[i].keysRevision, state.shotLogs[log].id,
    state.shotLogs[log].revision)

func shownGather(state: AppState; k: int): tuple[file, gather: int] =
  ## The file (its session id) and the gather panel `k` shows; (-1, -1) for none.
  let i = state.shownFile(k)
  if i < 0: (-1, -1) else: (int(state.sessions[i].id), state.panels[k].layers[0].source.gather)

proc stopShotTraces(state: var AppState) =
  ## Lets go of the map of traces, and of the job that makes one.
  if state.stJob != NoJob: discard state.jobs.cancel(state.stJob)
  state.stJob = NoJob
  state.stSink = nil
  state.stHave = false
  state.stMap = ShotTraceMap()
  state.stWant = -1
  state.stRemoved.setLen 0

proc shotTracesFor(state: var AppState; k, log: int; rows: seq[int]; found: var seq[int];
    removing: bool): string =
  ## The traces (survey-wide, ascending) of the file panel `k` shows that belong to `rows` of
  ## loaded log index `log`, in `found`: by look-up in the map of the file against the log,
  ## which a job makes once (`ShotTraceMap`; until it answers `found` stays empty and the
  ## answer is applied then, `applyShotTraces`). Else why there are none, as a sentence.
  let i = state.shownFile(k)
  if i < 0: return "No file is shown, so no trace was chosen."
  let s = state.sessions[i]
  if s.isSignature: return s.name & " is a signature file: it has no shots to choose."
  let e = state.files.find(s.diskPath)
  if e >= 0 and state.files.entries[e].recordingOf == some(rkReceiverContinuous):
    return s.name & " is a continuous receiver gather: its traces are not shots; " &
      "slice it by the shot log first."
  let key = state.shotTraceKey(i, log)
  if state.stHave and state.stKey == key:
    if state.stMap.unreadable:
      return s.name & " was opened without trace keys, so its traces cannot be told to " &
        "shots; no trace was chosen."
    for t in state.stMap.tracesOfRows(rows): found.add s.base + t
    if found.len == 0 and not removing:
      result = "No trace of " & s.name & " belongs to " &
        (if rows.len == 1: "that shot." else: "those shots.")
  else:
    if state.stHave or (state.stJob != NoJob and state.stKey != key): state.stopShotTraces()
    if state.stJob == NoJob:
      let index = state.follow.indexOf(state.shotLogs[log].id)
      if index == nil: return
      state.stKey = key
      state.stSink = ShotTraceSink()
      state.stJob = state.jobs.submit(traceMapSpec(s.name, s.diskPath),
        traceMapWork(s.filePtr, index, state.shotLogs[log].view.rows.len, state.stSink))
    state.stWant = state.shotRows.revision

proc applyShotTraces(state: var AppState) =
  ## The map of traces is ready: the traces of the rows chosen are selected (those of rows taken
  ## out meanwhile unselected) and shown, when nothing has changed since the click that asked:
  ## the same rows, the same trace selection, the file and the log the map is for. The record
  ## is not changed when the user stepped to another meanwhile.
  let want = state.stWant
  state.stWant = -1
  let removed = state.stRemoved
  state.stRemoved.setLen 0
  if want != state.shotRows.revision or state.shotRows.log < 0: return
  if state.selection.selectedRevision != state.stSelRev: return
  let k = state.findPanel(MainPanel)
  let i = state.shownFile(k)
  let log = state.findShotLog(state.shotRows.log)
  if i < 0 or log < 0 or state.shotTraceKey(i, log) != state.stKey: return
  var found: seq[int]
  var why = ""
  if state.stMap.unreadable:
    why = state.sessions[i].name & " was opened without trace keys, so its traces cannot be " &
      "told to shots; no trace was chosen."
  else:
    var gone: seq[int]
    for r in removed:
      if r notin state.shotRows.rows: gone.add r
    var taken: seq[int]
    for t in state.stMap.tracesOfRows(gone): taken.add state.sessions[i].base + t
    if taken.len > 0: state.selection.select(taken, smRemove)
    for t in state.stMap.tracesOfRows(state.shotRows.rows): found.add state.sessions[i].base + t
    if found.len == 0:
      why = "No trace of " & state.sessions[i].name & " belongs to " &
        (if state.shotRows.rows.len == 1: "that shot." else: "those shots.")
  if found.len > 0:
    state.selection.select(found, smAdd)
    if state.shownGather(k) == state.stShown: state.showShotTraces(k, found)
  elif why.len > 0: state.log.add(sevInfo, "Shot log", why)

proc selectShotRows(state: var AppState; logId: int; wanted: seq[int]; traces: bool;
    mode = smReplace; others = false) =
  ## `ckSelectShotRows`: `wanted` rows of loaded log `logId` become the rows chosen (a replace;
  ## with `mode` add, remove or toggle (their shot's rows in or out), the choice changes by
  ## them), their points on the map selected, and, with `traces`, the traces of the file shown
  ## that belong to those shots, the main panel showing the first. A replace with no row in the
  ## log clears the choice, the points and the traces. `others`: the command selected points of
  ## other layers already, which a replace leaves. A sentence says why, once, when no trace was
  ## chosen.
  let at = state.findShotLog(logId)
  var valid: seq[int]
  if at >= 0:
    let n = state.shotLogs[at].view.rows.len
    for r in wanted.sorted:
      if r in 0 ..< n and (valid.len == 0 or valid[^1] != r): valid.add r
  let was = if state.shotRows.log == logId: state.shotRows.rows else: @[]
  let op = case mode
    of smReplace, smRange: smReplace
    of smAdd: smAdd
    of smRemove: smRemove
    of smToggle: (if valid.len > 0 and valid[0] in was: smRemove else: smAdd)
  var final = valid
  if op == smAdd:
    final = was & valid
    final.sort()
    final = final.deduplicate(isSorted = true)
  elif op == smRemove:
    final = @[]
    for r in was:
      if r notin valid: final.add r
  elif valid.len == 0 and op != smReplace: return
  state.shotRows = ShotRows(log: (if final.len > 0: logId else: -1), rows: final,
    revision: state.shotRows.revision + 1)
  let k = state.findPanel(MainPanel)
  let asked = if op == smReplace: final else: valid
  var found: seq[int]
  var why = ""
  if op == smReplace: state.stRemoved.setLen 0
  if traces and asked.len > 0:
    why = state.shotTracesFor(k, at, asked, found, op == smRemove)
    if state.stWant == state.shotRows.revision: # the map is not ready: its answer settles it
      if op == smRemove: state.stRemoved.add valid
      else: state.stRemoved.keepItIf(it notin valid)
  var points: seq[PointRef]
  let layer = state.survey.findShotLog(logId)
  if layer >= 0:
    template l: untyped = state.survey.layers[layer]
    for p in l.pointsOfRows(asked): points.add PointRef(layer: l.id, role: prSource, point: p)
  case op
  of smReplace:
    if traces or final.len == 0: state.selection.select(found, if others: smAdd else: smReplace)
    state.selection.selectPoints(points, if others: smAdd else: smReplace)
  of smRemove:
    state.selection.selectPoints(points, smRemove)
    if traces: state.selection.select(found, smRemove)
  else:
    state.selection.selectPoints(points, smAdd)
    if traces: state.selection.select(found, smAdd)
  if found.len > 0 and op != smRemove: state.showShotTraces(k, found)
  elif why.len > 0 and found.len == 0: state.log.add(sevInfo, "Shot log", why)
  if state.stWant == state.shotRows.revision:
    state.stSelRev = state.selection.selectedRevision
    state.stShown = state.shownGather(k)

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

proc unlink(state: var AppState; path: string) =
  ## `path` no longer shares its edits with the other paths of its file
  ## (it changed on disk, or holds another file now): it keeps a copy of
  ## them, and the others keep theirs.
  let key = state.keyOf(path)
  var others: seq[string]
  for p, k in state.editKey:
    if k == key and p != path: others.add p
  if key != path:
    state.editKey.del path
    if key in state.edits: state.edits[path] = state.edits[key]
  elif others.len > 0: # it was the key: the others move to one of theirs
    let next = others[0]
    state.editKey.del next
    if path in state.edits: state.edits[next] = state.edits[path]
    for p in others[1 .. ^1]: state.editKey[p] = next

proc checkEdits(state: var AppState; s: Session) =
  ## Sets the edits of `s`'s path aside (as "Clear all edits" does, so Ctrl+Z
  ## brings them back) when they were made on the file as it was before
  ## another program changed it: by the trace's index, they may not fit.
  ## A derived view is not a file on disk: its origin was checked when opened.
  if s.derived: return
  if state.keyOf(s.path) notin state.edits or state.edits[state.keyOf(s.path)].isEmpty: return
  let now = (size: s.size, modified: s.modified)
  let was = state.editStamps.getOrDefault(s.diskPath, now)
  state.editStamps[s.diskPath] = now
  if was != now: state.unlink(s.diskPath) # its other paths, a copy, did not change
  if was != now and state.edits[state.keyOf(s.path)].clearAll(kind = skSetAside):
    state.log.add(sevWarning, s.name, s.name & " changed on disk after its traces were " &
      "edited, so its kills, polarity reversals and trace filters are set aside: by trace " &
      "number they may not fit the traces it holds now. Edit > Undo (Ctrl+Z) brings them " &
      "back. They stay " &
      "remembered for the file as it was.")

proc stampEdits(state: var AppState; s: Session) =
  ## Notes the file on disk the edits were made against. A derived view
  ## stamps its origin's size and time, not the correlated bytes.
  var size = s.size
  var modified = s.modified
  if s.derived:
    for x in state.sessions:
      if not x.derived and x.diskPath == s.diskPath:
        size = x.size
        modified = x.modified
        break
  state.editStamps[s.diskPath] = (size, modified)

proc askCorrelateAgain(state: var AppState; path: string)

proc editsChanged(state: var AppState; path: string; step = EditStep(kind: skChange)) =
  ## The panels that show the file at `path` follow its edits: its polarity
  ## reversed or not as a whole, and their view's tiles made again when
  ## `step` changed a trace of the gather they show (any step when it is
  ## `skChange` with no traces: what is remembered came). A step that moved an auxiliary
  ## mark (or any step of that kind, as what is remembered came) asks for the correlated
  ## view again, which is a no-op when the marks it is made with are the same.
  template e: untyped = state.editsAt(path)
  let any = step.kind == skChange and step.traces.len == 0
  for j in 0 ..< state.panels.len:
    let (i, traces) = state.shownTraces(j)
    if i >= 0 and state.keyOf(state.sessions[i].path) == state.keyOf(path):
      template layer: untyped = state.panels[j].layers[0]
      let relevel = any or step.touches(teKilled) or step.filterOn.len > 0 or
        step.filterOff.len > 0 or step.shiftOn.len > 0 or step.shiftOff.len > 0
      if layer.reversed != e.allReversed:
        layer.reversed = e.allReversed
        state.resample(j, relevel = relevel)
      elif any or step.changedIn(traces):
        state.resample(j, relevel = relevel)
  if any or step.auxOn.len > 0 or step.auxOff.len > 0: state.askCorrelateAgain(path)

proc sayNotYetRemembered(state: var AppState; i: int) =
  ## Says once, when the user edits `remembered[i]`'s file before its
  ## identity is known, that the edits are not remembered until it is.
  template r: untyped = state.remembered[i]
  if not r.known and r.job != NoJob and not r.saidWaiting:
    r.saidWaiting = true
    let name = r.path.extractFilename
    state.log.add(sevInfo, name, "The edits of " & name & " are kept by its path until " &
      "viewSEG has read its first and last bytes, which its drive has not given yet; then " &
      "they are remembered with it, under any name. A quit before keeps them for it.")

proc identify(state: var AppState; s: Session) =
  ## Looks up what is remembered about the file `s` opened, by its
  ## identity, on a job (`identifyWork`); a file identified before in this
  ## run and unchanged since is known already. A derived view is not a file
  ## on disk: its origin was identified when it was opened.
  if s.derived or state.store.isNowhere: return
  var i = state.rememberedAt(s.path)
  if i >= 0 and state.remembered[i].known and state.remembered[i].size == s.size and
      state.remembered[i].modified == s.modified:
    state.remembered[i].opened = getTime()
    return
  if i < 0:
    state.remembered.add Remembered(path: s.path, job: NoJob, hashJob: NoJob)
    i = state.remembered.high
  else: state.unlink(s.path) # perhaps another file under this name now
  template r: untyped = state.remembered[i]
  for j in [r.job, r.hashJob]:
    if j != NoJob: discard state.jobs.cancel(j)
  # Another file under this name, or the first look: nothing is written
  # until its identity is known (the edits set aside stay with the file as
  # it was).
  let pending = r.pending
  r = Remembered(path: s.path, size: s.size, opened: getTime(), hashJob: NoJob,
    savedRev: state.editsAt(s.path).keptRevision, openModified: s.modified, pendingRev: -1,
    pending: pending)
  r.job = state.jobs.submit(JobSpec(title: "Look up what is remembered about " & s.name,
    lane: jlInteractive), identifyWork(s.path, state.store, state.inbox.poster))
  state.memoryWork.add r.job

proc applyRecord(state: var AppState; i: int; c: FileRecord) =
  ## Brings back what document `c` remembers about `remembered[i]`'s file,
  ## and says so.
  template r: untyped = state.remembered[i]
  let name = r.path.extractFilename
  r.doc = c.doc
  r.ownDoc = false
  r.waiting.setLen 0
  if c.identity.fullKnown and not r.hashed:
    (r.identity.full, r.identity.fullKnown) = (c.identity.full, true)
  r.brought = if r.hashed: FileRecord() else: c
  state.knownDocs[c.doc] = c
  # (a document that knows its file's hash of every byte says what that file is treated as once
  # this one's says it is the same: `takeHashed`)
  if r.hashed or not c.identity.fullKnown: state.loadTreat(r.path, c.treat)
  # Written again (seen now, under this name), unless it had parts that
  # could not be read: those stay on disk until the user changes the edits,
  # and when it was opened is kept beside it, so that File memory never
  # takes a file in use for one not opened for months.
  if not c.damaged: r.savedRev = -1
  else:
    state.knownDocs[c.doc].opened = r.opened
    if not state.readOnlyProject:
      state.diskIo.replace(state.store.docPath(c.doc).seenName, seenDocument(r.opened),
        "when " & name & " was opened")
    r.seenAside = true
  if c.edits.isEmpty: return
  state.edits.mgetOrPut(state.keyOf(r.path), FileEdits()).remembered(c.edits)
  var said = name & ": " & keptWords(c.edits) & ", as you left " &
    (if c.name.len > 0 and c.name != name: "it as " & c.name else: "it")
  if c.opened != Time(): said.add " (" & c.opened.local.format("yyyy-MM-dd HH:mm") & ")"
  if not r.hashed:
    said.add "; being checked: its whole content is compared with the file's they were " &
      "made on, and they are taken back if it differs"
  state.log.add(sevInfo, name, said & ". The file itself holds none of it.")
  state.editsChanged(r.path)

proc takePending(state: var AppState; i: int; p: FileRecord; fits: bool): string =
  ## The edits kept by `remembered[i]`'s path in a run that could not read
  ## its identity. When the file is as it was then (`fits`: its path, size
  ## and time), they are not applied by themselves: the path says nothing of
  ## the content. They become a record of the file's quick identity, with
  ## the hash of every byte if one was kept with them (brought back at once,
  ## then confirmed by that hash, as any record), else unconfirmed (listed
  ## to apply or forget, said once); the pending document goes. Returns that
  ## record's document name, "" when there is none. When the file changed
  ## since, the edits are said in full and removed. One this run wrote (or
  ## took in) is older than what it shows: the edits as they are now go to
  ## the file's document, and it is removed after.
  template r: untyped = state.remembered[i]
  let name = r.path.extractFilename
  if r.pending:
    # A kill taken back since it was written (a second before the drive
    # answered) would come back from it; what an earlier run left in it was
    # merged in when this run first wrote it (`takeMerged`).
    r.savedRev = -1
    return
  if fits:
    if not state.readOnlyProject:
      state.diskIo.remove(state.store.docPath(p.doc), "the edits of " & name & " kept by its path")
    if p.edits.isEmpty: return
    var rec = FileRecord(identity: FileIdentity(size: r.identity.size, quick: r.identity.quick),
      name: p.name, path: r.path, opened: p.opened, modified: r.modified, edits: p.edits,
      unconfirmed: not p.identity.fullKnown)
    if p.identity.fullKnown:
      (rec.identity.full, rec.identity.fullKnown) = (p.identity.full, true)
    for s in state.sessions:
      if s.path == r.path: rec.traces = s.len
    var taken = r.waiting.mapIt(it.doc) & r.taken
    for x in state.remembered:
      taken.add x.doc
      taken.add x.provDocs
    for d in state.knownDocs.keys: taken.add d
    rec.doc = freeDocName(rec.identity, taken)
    state.knownDocs[rec.doc] = rec
    if not state.readOnlyProject:
      state.diskIo.replace(state.store.docPath(rec.doc), rec, "the edits of " & name &
        " kept by its path")
    return rec.doc
  r.pending = true # removed now
  var lists: seq[string]
  for edit in [teKilled, teReversed, teExcluded]:
    if p.edits.lists[edit].len > 0: lists.add $edit & " " & runsText(p.edits.lists[edit])
  if p.edits.filters.len > 0: lists.add $p.edits.filters.len & " filtered"
  if p.edits.allReversed: lists.add "all reversed"
  state.log.add(sevWarning, name, "The edits of " & name & " made when its drive did not " &
    "give its first and last bytes (" & p.opened.local.format("yyyy-MM-dd HH:mm") &
    ") are not applied: it changed since (its size or time is not the same). They were: " &
    lists.join("; ") & ".")
  state.dropPending(i)

proc link(state: var AppState; i, j: int) =
  ## `remembered[i]`'s file is `remembered[j]`'s, opened under another path
  ## (a copy, a link): from now on their paths share one `FileEdits`, the
  ## edits of both kept (`merge`), and one document.
  let key = state.keyOf(state.remembered[j].path)
  let was = state.keyOf(state.remembered[i].path)
  var moved = @[was]
  for p, k in state.editKey:
    if k == was: moved.add p
  var mine: FileEdits
  if state.edits.pop(was, mine):
    # Taken in only when this path has edits of its own. Compared with what
    # it brought back, not with the document as a save wrote it since: that
    # save may have taken a kill back, and merging the copy brought back
    # would put it back. What was brought back is taken off first, so a
    # kill taken back during the check is not put back, and an edit made
    # during it still joins. What this path no longer has of that snapshot
    # is taken off the other path after the union, so a kill taken back
    # while the other path had already confirmed does not return, unless the
    # user set it again there in this session. A filter or shift changed
    # during the check, different from that snapshot, wins.
    let snap = state.remembered[i].brought.doc.len > 0
    let baseline = if snap: state.remembered[i].brought.edits
      elif state.remembered[i].doc.len > 0:
        state.knownDocs.getOrDefault(state.remembered[i].doc).edits
      else: EditLists()
    if mine.steps != (0, 0) or mine.kept != baseline:
      let gone = baseline.minus(mine.kept)
      if snap: mine.dropBrought(baseline)
      let incomingShown = mine.shown
      let incomingKept = mine.kept
      let incoming = mine.steps.undos
      let spared = state.edits.mgetOrPut(key, FileEdits()).setInSession
      state.edits[key].merge(move mine)
      if snap: state.edits[key].keepIncoming(incomingShown, incomingKept, baseline)
      state.edits[key].takeOff(gone, spared, incoming)
  for p in moved: state.editKey[p] = key
  state.editKey.del key
  # One document for the file: the one its other path has, else this one's.
  var doc, theirs = ""
  var own, theirsOwn = false
  for x in state.remembered:
    if x.doc.len > 0 and doc.len == 0 and state.keyOf(x.path) == key and x.path notin moved:
      (doc, own) = (x.doc, x.ownDoc)
    if x.doc.len > 0 and theirs.len == 0 and x.path in moved: (theirs, theirsOwn) = (x.doc, x.ownDoc)
  if doc.len == 0: (doc, own) = (theirs, theirsOwn)
  elif theirs.len > 0 and theirs != doc and not state.knownDocs.getOrDefault(theirs).damaged:
    if not state.readOnlyProject:
      # what it says the file is treated as goes to the other, in the parts that one leaves
      state.carryTreat(state.knownDocs.getOrDefault(theirs).treat, doc, "")
      state.diskIo.remove(state.store.docPath(theirs), "what is remembered about " &
        state.remembered[i].path.extractFilename) # its edits are in the other now
    state.knownDocs.del theirs
  for x in state.remembered.mitems:
    if state.keyOf(x.path) == key:
      if doc.len > 0: (x.doc, x.ownDoc) = (doc, own)
      x.savedRev = -1 # written with what both kept
  let (a, b) = (state.remembered[j].path.extractFilename,
    state.remembered[i].path.extractFilename)
  state.log.add(sevInfo, b, b & " holds what " & a & " holds (a copy or a link of it, " &
    "opened under two paths): they share their kills and polarity reversals now, and " &
    "they are remembered once, for both.")
  state.editsChanged(state.remembered[j].path)

proc linkSame(state: var AppState; i: int) =
  ## Links `remembered[i]`'s file to another path opened this run that holds
  ## the same bytes (`link`): at once when their size, ends and modification
  ## time agree (a link, or a copy that kept its time), as what is
  ## remembered is brought back; otherwise once the hash of every byte of
  ## both says so (both are hashed then).
  template r: untyped = state.remembered[i]
  if not r.known: return
  for j in 0 ..< state.remembered.len:
    template o: untyped = state.remembered[j]
    if j != i and o.known and o.identity.size == r.identity.size and
        o.identity.quick == r.identity.quick and state.keyOf(o.path) != state.keyOf(r.path):
      if r.hashed and o.hashed:
        if r.identity.full == o.identity.full: state.link(i, j)
      elif r.modified == o.modified and not r.checking and not o.checking: state.link(i, j)
      else: # while edits brought back are checked, each waits for its own hash
        state.hashFile(i)
        state.hashFile(j)

proc sayEarlier(state: var AppState; path: string; c: FileRecord) =
  ## An earlier output of `path`'s name, whose edits are not this file's:
  ## listed with the file, and said once.
  let name = path.extractFilename
  var list = state.earlier.getOrDefault(path)
  var known = false
  for x in list:
    if x.doc == c.doc: known = true
  if not known:
    list.add c
    state.earlier[path] = list
  if c.doc notin state.earlierSaid and not c.edits.isEmpty:
    state.earlierSaid.incl c.doc
    state.log.add(sevWarning, name, name & " is not the file your edits were made on " &
      "(output again since " & (if c.opened != Time(): c.opened.local.format(
      "yyyy-MM-dd HH:mm") else: "it was last opened") & ": other contents): its " &
      keptWords(c.edits) & " are not applied. They are kept as an earlier output of " & name &
      ", to look at, apply or forget (Project > Project...).")

proc sayUnconfirmed(state: var AppState; i: int; c: FileRecord; why = "") =
  ## The edits an earlier run left, unconfirmed, for a file of `remembered[i]`'s
  ## quick identity (the program closed while its brought-back record was
  ## being checked): nothing of them is applied. They are listed with the
  ## earlier outputs, to apply or to forget, and said once. Edits that are
  ## the file's own already (applied) are not offered again.
  template r: untyped = state.remembered[i]
  let name = r.path.extractFilename
  if c.edits == state.editsAt(r.path).kept:
    if not state.readOnlyProject:
      state.diskIo.remove(state.store.docPath(c.doc), "what is remembered about " & name &
        " (unconfirmed, applied)")
    state.knownDocs.del c.doc
    return
  var list = state.earlier.getOrDefault(r.path)
  for x in list:
    if x.doc == c.doc: return
  list.add c
  state.earlier[r.path] = list
  state.log.add(sevWarning, name, name & ": the edits you made on " &
    (if c.opened != Time(): c.opened.local.format("yyyy-MM-dd HH:mm") else: "an earlier day") &
    " (" & keptWords(c.edits) & ") " & (if why.len > 0: why else:
    "were not yet confirmed as this file's when viewSEG closed") &
    ": they are kept apart (Project window: Apply or Forget).")

proc sayEarlierNew(state: var AppState; path: string; c: FileRecord; own: EditLists) =
  ## `sayEarlier`, unless the edits of `c` are on the file already (`own`:
  ## applied with "Apply them to this file", or the same made again): those
  ## are no earlier output's to say.
  if c.edits.isEmpty or not c.edits.minus(own).isEmpty: state.sayEarlier(path, c)

func earlierOf*(state: AppState; path: string): seq[FileRecord] =
  ## What is remembered about earlier outputs of the name of open file
  ## `path`: other files, whose edits are not its own.
  state.earlier.getOrDefault(path)

func replaceCounts*(state: AppState; path: string; l: EditLists): tuple[given, takenOff: int] =
  ## What making the edits of open file `path` those of `l` does: how many
  ## edits it gives and how many it takes off (`FileEdits.setTo`).
  (l.minus(state.editsAt(path).shown).count,
    state.editsAt(path).shown.minus(l).count)

func editsChecking*(state: AppState; path: string): bool =
  ## Whether the edits brought back for open file `path` are being checked:
  ## taken on its size, ends and time, waiting for the hash of every byte.
  let i = state.rememberedAt(path)
  i >= 0 and state.remembered[i].known and state.remembered[i].checking

proc takeEarlier(state: var AppState; m: sink Msg) =
  ## Earlier outputs of an open file's name (`earlierWork`; its end is quiet,
  ## `endMemoryWork`).
  let i = state.rememberedAt(m.earlierPath)
  if i < 0 or not sameData(state.remembered[i].identity, m.earlierOf): return
  for p in m.earlierProblems:
    state.log.add(sevWarning, m.earlierPath.extractFilename, "What is remembered: " & p & ".")
  for c in m.earlier:
    if state.remembered.anyIt(c.doc in it.provDocs): continue # an open file's live record
    # Edits that are on this file already (applied with "Apply them to this
    # file", or the same made again) are no earlier output's to say.
    if c.unconfirmed: state.sayUnconfirmed(i, c)
    elif not state.remembered[i].hashed and state.remembered[i].waiting.len > 0:
      state.remembered[i].heldEarlier.add c
    else: state.sayEarlierNew(m.earlierPath, c, state.editsAt(m.earlierPath).kept)

proc takeIdentified(state: var AppState; m: sink Msg) =
  ## A file's quick identity and the documents of it: those that are about
  ## it (the same quick identity, size and modification time: a file moved
  ## or renamed keeps them) are brought back at once, and the hash of every
  ## byte confirms them; the others wait for that hash.
  let i = state.rememberedAt(m.identPath)
  if i < 0 or state.remembered[i].job != m.job: return
  template r: untyped = state.remembered[i]
  r.job = NoJob
  (r.identity, r.known, r.modified, r.hashed) = (m.identity, true, m.identModified, false)
  r.taken = move m.taken
  let name = r.path.extractFilename
  for p in m.memoryProblems:
    state.log.add(sevWarning, name, "What is remembered about " & name & ": " & p & ".")
  # What the path kept comes first: a record of its own, found below like any
  let fromPending = if m.pending.doc.len > 0: state.takePending(i, m.pending, m.pendingFits)
    else: ""
  var live = initHashSet[string]() # the live record of an open file's edits: not an earlier run's
  for x in state.remembered:
    for d in x.provDocs: live.incl d
  var cands, unconfirmed: seq[FileRecord]
  for c in m.candidates: # what this run wrote is newer than the disk
    let x = if c.doc in state.knownDocs: state.knownDocs[c.doc] else: c
    if x.doc in live: continue
    if x.unconfirmed: unconfirmed.add x else: cands.add x
  for d, c in state.knownDocs:
    if d notin r.taken and d notin live and c.identity.size == r.identity.size and
        c.identity.quick == r.identity.quick:
      if c.unconfirmed: unconfirmed.add c else: cands.add c
  var at = -1
  for j, c in cands:
    if at < 0 and c.modified == r.modified: at = j
  # (the others wait for the hash: the one taken may be another content's)
  if at >= 0:
    state.applyRecord(i, cands[at])
    r.waiting = cands
    r.waiting.delete at
  else: r.waiting = cands
  for c in unconfirmed:
    state.sayUnconfirmed(i, c, if c.doc == fromPending and fromPending.len > 0:
      "were made when its drive did not give its first and last bytes, so nothing says " &
      "they were made on this file" else: "")
  # (the one document of the file, taken at once, that keeps only what it is treated as has no
  # edits to confirm: it is hashed once the user edits the file, `writeMemoryDoc`)
  let own = state.editsAt(r.path).kept
  if not (cands.len == 1 and at == 0 and cands[0].edits.isEmpty and
      not cands[0].identity.fullKnown and own.isEmpty) and (cands.len > 0 or not own.isEmpty):
    state.hashFile(i)
  state.linkSame(i)
  # Other files once at this path (output again under the same name): their
  # edits are not this file's; listed and said.
  if not state.store.isNowhere:
    let job = state.jobs.submit(JobSpec(title: "Look for earlier outputs of " & name,
      lane: jlBackground, auto: true), earlierWork(state.store, r.path, r.identity,
          state.inbox.poster))
    state.memoryWork.add job

proc takeHashed(state: var AppState; m: sink Msg) =
  ## The hash of every byte of a file: what was brought back is confirmed,
  ## or taken away again when it was another file's; what waited for it is
  ## brought back when it is about this file.
  let i = state.rememberedAt(m.hashedPath)
  if i < 0 or state.remembered[i].hashJob != m.job: return
  template r: untyped = state.remembered[i]
  r.hashJob = NoJob
  if not r.known or m.hashed.size != r.identity.size or m.hashed.quick != r.identity.quick:
    return # another file under this name since
  let name = r.path.extractFilename
  for j in 0 ..< state.remembered.len:
    template o: untyped = state.remembered[j]
    if j != i and o.hashed and o.identity.full != m.hashed.full and
        state.keyOf(o.path) == state.keyOf(r.path) and state.keyOf(r.path) in state.edits:
      # taken at once for the file at another path (the same size, ends and
      # time), but its content differs: another file
      state.log.add(sevWarning, name, name & " begins and ends as " & o.path.extractFilename &
        " does, but its content differs: the edits of that file are taken away from it.")
      state.unlink(r.path)
      state.edits[state.keyOf(r.path)].forget()
      r.savedRev = state.edits[state.keyOf(r.path)].keptRevision
      (r.doc, r.ownDoc, r.brought) = ("", false, FileRecord())
      state.dropProvisional(i)
      state.editsChanged(r.path)
  let wasChecking = r.brought.doc.len > 0
  if r.doc.len > 0 and r.identity.fullKnown and r.identity.full != m.hashed.full:
    state.unlink(r.path) # the other paths of the file keep their edits
    let other = state.knownDocs.getOrDefault(r.doc)
    let key = state.keyOf(r.path)
    # What the user did on this file since the other's edits were brought
    # back is this file's own: kept, as its record.
    let own = if r.brought.doc == r.doc and key in state.edits:
        state.edits[key].kept.minus(r.brought.edits)
      else: EditLists()
    state.log.add(sevWarning, name, name & " begins and ends as the file remembered as " &
      other.name & " did, but its content differs: the edits remembered for that file, " &
      "brought back while it was checked, are taken away from it (they stay remembered for " &
      "that file)" & (if own.isEmpty: "." else: "; your own edits made on " & name &
      " meanwhile (" & keptWords(own) & ") stay with it."))
    var was = if r.brought.doc == r.doc: r.brought else: other
    if was.path == r.path:
      state.sayEarlierNew(r.path, was, own)
    if r.seenAside: # the time this file was opened is not that one's
      if not state.readOnlyProject:
        state.diskIo.remove(state.store.docPath(r.doc).seenName, "when " & name & " was opened")
      r.seenAside = false
    # The other file's document was never written while it was checked
    # (`writeProvisional`): it stands as it was.
    if r.brought.doc == r.doc: state.knownDocs[r.doc] = r.brought
    else: state.knownDocs.del r.doc
    r.brought = FileRecord()
    r.doc = "" # (what that file is treated as goes below: no document is this one's)
    state.edits.mgetOrPut(key, FileEdits()).forget()
    if own.isEmpty:
      r.savedRev = state.edits[key].keptRevision
      state.dropProvisional(i)
    else:
      state.edits[key].remembered(own)
      r.savedRev = -1 # a record of its own, with the hash it gets below
    state.editsChanged(r.path)
  r.identity = m.hashed
  r.hashed = true
  # `brought` stays until after `linkSame`: the link compares against what
  # was brought back, not against a document a save wrote during the check.
  if wasChecking and r.doc.len > 0 and not state.knownDocs.getOrDefault(r.doc).damaged:
    r.savedRev = -1 # seen now, but never a damaged document
  if r.doc.len == 0 or r.ownDoc:
    # What waited for the hash; also when edits made meanwhile have a
    # document of their own already: that one then gives way to the one
    # brought back, which takes them.
    let own = if r.ownDoc: r.doc else: ""
    let waiting = move r.waiting
    var others: seq[FileRecord] = @[]
    for c in waiting:
      if (r.doc.len == 0 or r.ownDoc) and c.identity.fullKnown and
          c.identity.full == r.identity.full:
        state.applyRecord(i, c)
      elif c.path == r.path and c.identity.fullKnown and c.identity.full != r.identity.full:
        others.add c # the same size and ends, other contents
    # A document of only what the file is treated as, without the hash of every byte (made
    # by a choice in the list, the file touched since): the only one of its quick identity
    # that none other was taken for, it is the file's, and gains the hash.
    let bare = waiting.filterIt(not it.identity.fullKnown and it.edits.isEmpty)
    if (r.doc.len == 0 or r.ownDoc) and bare.len == 1 and
        not waiting.anyIt(it.identity.fullKnown and it.identity.full == r.identity.full):
      state.applyRecord(i, bare[0])
    others.add move(r.heldEarlier)
    for c in others: # said once the file's own are in: those of it are no earlier output's
      state.sayEarlierNew(r.path, c, state.editsAt(r.path).kept)
    if own.len > 0 and r.doc != own:
      if not state.readOnlyProject:
        state.diskIo.remove(state.store.docPath(own), "what is remembered about " & name)
      # what it said the file is treated as (the choice made this session, kept there or not
      # yet), to the document taken now
      var carried = state.knownDocs.getOrDefault(own).treat
      if r.path in state.treatsTouched:
        carried = state.treatsKept.getOrDefault(r.path)
        state.treatParts[r.path] = {tpKind, tpGrouping, tpSubSort}
        state.handTreat(r.path, r.doc, r.identity, r.modified)
      else: state.carryTreat(carried, r.doc, r.path)
      state.knownDocs.del own
    elif own.len > 0: r.savedRev = -1 # its document gets the hash
  elif not state.knownDocs.getOrDefault(r.doc).identity.fullKnown and
      not state.knownDocs.getOrDefault(r.doc).damaged:
    r.savedRev = -1 # its document gets the hash (not one with parts it cannot read)
  if r.doc.len == 0 and not state.editsAt(r.path).kept.isEmpty:
    r.savedRev = -1 # edits made before it was known: a document of its own
  for c in move(r.heldEarlier): state.sayEarlierNew(r.path, c, state.editsAt(r.path).kept)
  if r.doc.len > 0 and not r.ownDoc:
    # A second document of this content: what it says the file is treated as joins the one
    # taken (that one's own choice stands); with no edits it goes, else it stays as it was.
    for c in move(r.waiting):
      if c.doc != r.doc and c.identity.fullKnown and c.identity.full == r.identity.full and
          not c.damaged and not state.readOnlyProject:
        if c.edits.isEmpty:
          state.carryTreat(c.treat, r.doc, r.path)
          state.diskIo.remove(state.store.docPath(c.doc), "what is remembered about " & name)
        else: state.takeTreatFrom(c, r.doc, r.path)
  # confirmed: what its document says it is treated as; none when no document is the file's
  state.loadTreat(r.path, if r.doc.len > 0: state.knownDocs.getOrDefault(r.doc).treat
    else: TreatAs())
  state.linkSame(i)
  r.brought = FileRecord() # confirmed

proc endMemoryWork(state: var AppState; job: JobInfo): bool =
  ## Says how a job of what is remembered ended (quietly when it did);
  ## true when `job` was one.
  let w = state.memoryWork.find(job.id)
  if w >= 0: state.memoryWork.delete(w)
  var ended = ""
  for path, j in state.treatJobs:
    if j == job.id: ended = path
  if ended.len > 0: # (one that ended without its message: the next choice looks again)
    state.treatJobs.del ended
    let name = ended.extractFilename
    if job.state == jsFailed:
      state.log.add(sevWarning, name, "What " & name & " is treated as is kept for this " &
        "session only: " & job.error & ".")
    elif job.state == jsCancelled:
      state.log.add(sevWarning, name, "The choice for " & name & " is kept for this session " &
        "only: its look-up was stopped.")
  for r in state.remembered.mitems:
    let name = r.path.extractFilename
    if job.id == r.job:
      r.job = NoJob
      if job.state == jsFailed:
        state.log.add(sevWarning, name, "What is remembered about " & name & " cannot be " &
          "looked up: " & job.error & ". Its edits are kept for this session only, until " &
          "it is opened again.")
      return true
    if job.id == r.hashJob:
      r.hashJob = NoJob
      if job.state == jsFailed:
        state.log.add(sevInfo, name, name & " could not be read whole to confirm what it " &
          "holds (" & job.error & "); it is known by its first and last bytes.")
      return true
  if w >= 0: return true # its message came: said then
  if job.id in state.memoryLooks:
    if state.memoryLooks.len > 0 and job.id == state.memoryLooks[^1] and job.state != jsDone:
      # it ended without a word of some folders (failed): they are not
      # looked at, so never taken as gone
      for r in state.memoryList.records.mitems:
        if r.looking: (r.looking, r.unreached) = (false, true)
      inc state.memoryList.revision
    return true
  if job.id == state.memoryJob:
    state.memoryJob = NoJob
    state.memoryList.listing = false
    if job.state == jsFailed:
      state.memoryList.problems.add "what is remembered cannot be read: " & job.error
    inc state.memoryList.revision
    return true
  for j, x in state.editImports:
    if x.job == job.id:
      if job.state == jsFailed:
        state.log.add(sevError, "edits", "Cannot import the edits: " & job.error & ".")
      if job.state != jsDone: state.editImports.delete j # its message never comes
      return true
  let x = state.exports.find(job.id)
  if x >= 0:
    state.exports.delete(x)
    if job.state == jsFailed:
      state.log.add(sevError, "edits", "Cannot export the edits: " & job.error & ".")
    return true
  false

proc exportEdits(state: var AppState; cmd: Command) =
  ## `ckExportEdits`: the edits kept of the file `cmd.panel` shows (what
  ## its memory holds: an agent's edits, for the session only, are left
  ## out, and said), written to `cmd.listPath` (CSV when it ends in
  ## `.csv`, else NIF) by a job that adds each trace's record and channel
  ## from the keys, then the disk thread.
  let k = state.findPanel(cmd.panel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if i < 0:
    state.ignore(cmd, $cmd.panel & " shows no file")
    return
  if state.refusedWrite(cmd, cmd.listPath): return
  var s = state.sessions[i]
  if s.derived:
    var oi = -1
    for j, x in state.sessions:
      if not x.derived and x.diskPath == s.diskPath: oi = j
    if oi < 0:
      state.ignore(cmd, "the file on disk is not open")
      return
    s = state.sessions[oi]
  let disk = s.diskPath
  template e: untyped = state.editsAt(disk)
  # What is kept, as the next run shows it: an export is handed on and
  # outlives the session, which an agent's edit does not.
  var r = FileRecord(name: s.name, path: disk, opened: getTime(), modified: s.modified,
    edits: e.kept)
  let left = e.shown.minus(e.kept).count
  let hidden = e.kept.minus(e.shown).count
  if left > 0 or hidden > 0:
    var said = "The export of the edits of " & s.name
    if left > 0:
      said.add " leaves out " & plural(left, "edit") & " shown for this session only " &
        "(made through agent control: not remembered; make them yourself to keep them)"
    if hidden > 0:
      said.add (if left > 0: ", and" else: "") & " holds " & plural(hidden, "remembered edit") &
        " that agent control hid for this session"
    state.log.add(sevInfo, s.name, said & ".")
  let at = state.rememberedAt(disk)
  if at >= 0 and state.remembered[at].known: r.identity = state.remembered[at].identity
  else: r.identity.size = s.size
  state.exports.add state.jobs.submit(JobSpec(title: "Export the edits of " & s.name,
    lane: jlInteractive, reads: @[disk]), exportEditsWork(s.filePtr, r, cmd.listPath,
    state.inbox.poster))

proc takeEditsList(state: var AppState; m: sink Msg) =
  ## An export's text, handed to the disk thread.
  state.diskIo.replace(m.listDest, move m.listText, "the edits of " & m.listName,
    done = "The edits of " & m.listName & " are written in " & m.listDest & ".")

proc importEdits(state: var AppState; cmd: Command) =
  ## `ckImportEdits`: reads and takes apart `cmd.listPath` on a job
  ## (`importEditsWork`), for the file `cmd.panel` shows (`takeImported`).
  let k = state.findPanel(cmd.panel)
  if k < 0 or state.shownFile(k) < 0:
    state.ignore(cmd, $cmd.panel & " shows no file")
  elif cmd.listPath.len == 0: state.ignore(cmd, "no file was named")
  else:
    let job = state.jobs.submit(JobSpec(title: "Import the edits in " &
      cmd.listPath.extractFilename, lane: jlInteractive), importEditsWork(cmd.listPath,
      state.sessions[state.shownFile(k)].len, state.inbox.poster))
    let path = state.sessions[state.shownFile(k)].diskPath
    var label = ""
    if cmd.replaceEdits: # a record kept apart, said in the user's terms: not the store's file name
      for c in state.earlier.getOrDefault(path):
        if state.store.docPath(c.doc) == cmd.listPath:
          label = "the edits made on " & (if c.name.len > 0: c.name else: path.extractFilename) &
            " on " & (if c.opened == Time(): "an earlier day" else:
            c.opened.local.format("yyyy-MM-dd HH:mm"))
    state.editImports.add (job, path, cmd.origin, cmd.replaceEdits, label)

proc takeImported(state: var AppState; m: sink Msg) =
  ## A file's list a job read: its edits added to those of the file it was
  ## asked for, as one step (undone at once with Ctrl+Z).
  var w = -1
  for j, x in state.editImports:
    if x.job == m.job: w = j
  if w < 0: return
  let (_, path, by, replace, label) = state.editImports[w]
  state.editImports.delete w
  let disk = diskOf(path)
  let name = m.importedList.extractFilename
  let target = disk.extractFilename
  if m.importFailure.len > 0:
    state.log.add(sevError, "edits", "Cannot import the edits in " & m.importedList & ": " &
      m.importFailure & ". Nothing was changed.")
    return
  var problems = move m.importProblems
  let id = m.importIdentity
  let hasId = m.importHasIdentity
  var l = move m.importedEdits
  state.logProblems("edits", problems)
  let i = block:
    var at = -1
    for j, s in state.sessions:
      if not s.derived and s.diskPath == disk: at = j
    at
  if i < 0:
    state.log.add(sevWarning, "edits", target & " was closed before its edits in " & name &
      " were read: nothing was changed.")
    return
  let s = state.sessions[i]
  var outside = m.importOutside # left out by the job: past the last trace
  for edit in TraceEdit: # a file of that name opened again since, shorter
    let before = l.lists[edit].len
    l.lists[edit].keepItIf(it < s.len)
    outside += before - l.lists[edit].len
  if outside > 0:
    state.log.add(sevWarning, "edits", plural(outside, "trace") & " of " & name &
      " are past the last trace of " & target & " (" & $s.len & "): left out.")
  let at = state.rememberedAt(path)
  if hasId and at >= 0 and state.remembered[at].known and
      not sameData(id, state.remembered[at].identity):
    state.log.add(sevWarning, "edits", name & " was made on another file than " & target &
      " (its size or its bytes differ): its edits are applied by trace number all the same; " &
      "Edit > Undo (Ctrl+Z) takes them away.")
  template e: untyped = state.edits.mgetOrPut(state.keyOf(path), FileEdits())
  let given = l.minus(e.shown).count
  let takenOff = e.shown.minus(l).count
  let what = if replace and label.len > 0: label else: name
  let n = if replace: e.setTo(l, what, keeps(by)) else: e.takeIn(l, what, keeps(by))
  if n == 0:
    state.log.add(sevInfo, "edits", (if replace and label.len > 0: "The edits of " & label &
      " were on " & target & " already." else: "Every edit in " & name & " was on " & target &
      " already."))
  else:
    state.editStamps[disk] = (s.size, s.modified)
    state.log.add(sevInfo, target, (if replace and label.len > 0: target & "'s edits became " &
      label & ": " & plural(given, "edit") & " given, " & plural(takenOff, "edit") &
      " taken off. Edit > Undo takes it back." else: e.undoText.capitalizeAscii & "."))
    state.editsChanged(path, e.nextUndo)

proc listMemory(state: var AppState) =
  ## `ckFileMemory`: lists what is remembered, on a job (`memoryList`).
  if state.store.isNowhere:
    state.memoryList = MemoryList(listed: true, revision: state.memoryList.revision + 1,
      problems: @["nothing is remembered in this run (it keeps no settings)"])
    return
  if state.memoryJob != NoJob: return
  state.memoryList.listing = true
  inc state.memoryList.revision
  state.memoryJob = state.jobs.submit(JobSpec(title: "List what is remembered about files",
    lane: jlInteractive), listMemoryWork(state.store, state.inbox.poster))

proc lookAt(state: var AppState; folders: sink seq[LookFolder]) =
  ## Looks at the files of `folders` on a job (`lookWork`).
  if folders.len > 0:
    state.memoryLooks.add state.jobs.submit(JobSpec(title: "Look for the files File memory " &
      "lists", lane: jlInteractive), lookWork(folders, state.inbox.poster))
    state.lookGiven = folders

proc takeMerged(state: var AppState; m: sink Msg) =
  ## A document another viewSEG changed since this run read or wrote it,
  ## written with the edits of both: the file's paths show what the other
  ## kept too (with what was changed here since the write was asked for).
  let doc = m.mergedDoc
  if doc in state.knownDocs: state.knownDocs[doc].edits = m.mergedEdits
  var done: seq[string]
  for i in 0 ..< state.remembered.len:
    template r: untyped = state.remembered[i]
    let key = state.keyOf(r.path)
    if r.doc == doc and key notin done:
      done.add key
      template e: untyped = state.edits.mgetOrPut(key, FileEdits())
      let now = merged(m.mergedSent, e.kept, m.mergedEdits)
      e.adopt(now)
      # written as it is, unless changed here since the write was asked for
      r.savedRev = if now == m.mergedEdits: e.keptRevision else: -1
      if m.mergedRemoved and now == m.mergedEdits: state.knownDocs[doc] = FileRecord(
        identity: r.identity, name: r.path.extractFilename, path: r.path, edits: now, doc: doc)
      let name = r.path.extractFilename
      state.log.add(sevInfo, name, "Another viewSEG changed the edits remembered for " & name &
        " meanwhile; both are kept: " & keptWords(e.kept) & " now.")
      state.editsChanged(r.path)
    elif doc == pendingName(r.path) and key notin done:
      # the pending document an earlier run left, its drive not answering
      # then either: what it kept is this file's too
      done.add key
      template e: untyped = state.edits.mgetOrPut(key, FileEdits())
      e.adopt(merged(m.mergedSent, e.kept, m.mergedEdits))
      if r.known: r.savedRev = -1 # its own document takes them
      let name = r.path.extractFilename
      state.log.add(sevInfo, name, name & ": the edits kept by its path in an earlier run, " &
        "when its drive did not give its first and last bytes either, are back beside these: " &
        keptWords(e.kept) & " now.")
      state.editsChanged(r.path)

proc takeLooked(state: var AppState; m: sink Msg) =
  ## Where the files remembered in one folder stand.
  if m.job notin state.memoryLooks: return # a listing before
  var at = initTable[string, int]()
  for i, r in state.memoryList.records: at[r.doc] = i
  for x in m.looked:
    if x.doc in at:
      template r: untyped = state.memoryList.records[at[x.doc]]
      (r.gone, r.unreached, r.looking, r.silent) = (x.gone, x.unreached, false, false)
  inc state.memoryList.revision

proc followMemoryLook(state: var AppState) =
  ## Once a frame: a look whose folder's drive has not answered for
  ## `StallAfter` has that folder's files said "not answering" (never gone),
  ## and the folders after it looked at by a new job; the one held is left
  ## (cancelled), and what it posts if its drive answers is still taken.
  if state.memoryLooks.len == 0: return
  let job = state.memoryLooks[^1]
  let info = state.jobs.info(job)
  if info.isNone or info.get.state != jsRunning or
      info.get.notAnsweringFor < StallAfter: return
  let i = int(info.get.progress.done)
  if i notin 0 ..< state.lookGiven.len: return
  var docs = initHashSet[string]()
  for f in state.lookGiven[i].files: docs.incl f.doc
  for r in state.memoryList.records.mitems:
    if r.doc in docs and r.looking: (r.looking, r.silent) = (false, true)
  inc state.memoryList.revision
  discard state.jobs.cancel(job)
  let rest = state.lookGiven[i + 1 .. ^1]
  state.lookGiven.setLen 0
  state.lookAt(rest)

proc takeMemoryList(state: var AppState; m: sink Msg) =
  ## What the listing read; the documents this run wrote are newer.
  var records = move m.records
  for r in records.mitems:
    if r.doc in state.knownDocs:
      let (bytes, gone, looking) = (r.bytes, r.gone, r.looking)
      r = state.knownDocs[r.doc]
      (r.bytes, r.gone, r.looking) = (bytes, gone, looking)
  # Whether each file is where it was seen: on a job, folder by folder, so
  # that a drive that does not answer holds none of the listing
  # (`followMemoryLook`).
  var at = initTable[string, int]()
  var folders: seq[LookFolder]
  for r in records:
    if r.looking:
      let dir = r.path.parentDir
      if dir notin at:
        at[dir] = folders.len
        folders.add (dir, @[])
      folders[at[dir]].files.add (r.doc, r.path, r.identity.size)
  folders.sort(proc (a, b: LookFolder): int = cmp(a.folder, b.folder))
  state.memoryList = MemoryList(records: records, problems: move m.listProblems,
    listed: true, revision: state.memoryList.revision + 1)
  state.memoryLooks.setLen 0
  state.lookAt(folders)

func memoryList*(state: AppState): lent MemoryList {.inline.} =
  ## What the File memory window lists (`ckFileMemory` reads it again).
  state.memoryList

proc forgetFiles(state: var AppState; cmd: Command) =
  ## `ckForgetFiles`: the documents named are removed, each said in the
  ## log; a file open now that they were about is shown as it is on disk.
  if not keeps(cmd.origin):
    state.ignore(cmd, "what is remembered about files is the user's: an agent cannot remove it")
    return
  if state.readOnlyProject:
    state.ignore(cmd, "the project is open read-only (" & state.project.whyReadOnly & ")")
    return
  for doc in cmd.forget:
    if not doc.isDocName:
      state.ignore(cmd, "\"" & doc & "\" is not a document of what is remembered")
    else:
      var rec = state.knownDocs.getOrDefault(doc)
      for r in state.memoryList.records:
        if r.doc == doc and rec.doc.len == 0: rec = r
      for path, list in state.earlier.mpairs:
        for x in list:
          if x.doc == doc and rec.doc.len == 0: rec = x
        list.keepItIf(it.doc != doc)
      for i in 0 ..< state.remembered.len:
        template r: untyped = state.remembered[i]
        if r.doc == doc:
          r.doc = ""
          r.seenAside = false
          if state.keyOf(r.path) in state.edits:
            state.edits[state.keyOf(r.path)].forget()
            r.savedRev = state.edits[state.keyOf(r.path)].keptRevision
            state.editsChanged(r.path)
      state.knownDocs.del doc
      let name = if rec.name.len > 0: rec.name else: doc
      state.diskIo.remove(state.store.docPath(doc), "what is remembered about " & name)
      state.diskIo.remove(state.store.docPath(doc).seenName, "when " & name & " was opened")
      state.log.add(sevInfo, "file memory", "Forgot " & name & " (" & keptWords(rec.edits) &
        (if rec.path.len > 0: ", last seen at " & rec.path else: "") & ").")
      state.memoryList.records.keepItIf(it.doc != doc)
      inc state.memoryList.revision

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
    rows: var seq[HeaderRow]; vendor: var VendorShown): bool =
  ## What job `job` of `readTraceHeaders` read, once it has posted it (then
  ## it is given once); false until then, and for any other job.
  for i in 0 ..< state.traceReads.len:
    if state.traceReads[i].job == job:
      keys = state.traceReads[i].keys
      rows = move state.traceReads[i].rows
      vendor = move state.traceReads[i].vendor
      state.traceReads.delete(i)
      return true
  false

proc readPositions(state: var AppState; s: Session) =
  ## Reads the source and receiver positions of open file `s` on a job: its
  ## layer of the survey. A derived view has no layer of its own: the file
  ## on disk was read when it was opened.
  if s.derived: return
  let job = state.jobs.submit(JobSpec(title: "Read the positions in " & s.name,
    lane: jlInteractive, reads: @[s.path]), positionsWork(s.filePtr, s.path,
    fileKind(s.file.kind), s.id, s.base, state.inbox.poster))
  state.loading.add Loading(job: job, path: s.path, session: s.id)

func relationLayer*(state: AppState): int =
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
  if s.noSeismic:
    s.setChecks("", [], []) # nothing of it is on a survey's stations
    return
  var gathers = newSeq[Slice[int]](s.gathers.len)
  for i, g in s.gathers: gathers[i] = g.traces
  let j = state.joinedRelations(s.id)
  let opts = state.settings.join
  if j >= 0:
    template x: untyped = state.joins[j]
    let g = if x.relations.isNil: x.geometry else: x.relations
    let job = state.jobs.submit(JobSpec(title: "Check the records of " & s.name &
      " against the survey imported", lane: jlBackground, auto: true, reads: @[s.path]), checkWork(
      s.filePtr,
      s.id, gathers, addr g[], fileNames(x.files), NoSurveyLayer, state.inbox.poster,
      x.options.recordMatch, x.options.traceMatch))
    state.checking.add (job, g)
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
    l.name, lane: jlBackground, auto: true, reads: @[s.path]), checkWork(s.filePtr, s.id, gathers,
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

func readAs(l: SurveyLayer; lines: JoinOptions): bool =
  ## Whether survey file layer `l` was read with `lines`' line names and
  ## trailing digits.
  l.sameLineNames(lines.lineNaming, lines.trailingDigits)

proc loadSurvey(state: var AppState; path: string; quiet = false;
    lines = state.settings.join) =
  ## Loads survey file `path` (canonical) on a job, its text line names made
  ## numbers as the import's options `lines` say, unless it is being loaded
  ## already, or is loaded as the file list says it is now with those
  ## options; `quiet` says nothing then.
  let name = path.extractFilename
  let i = state.survey.findFile(path)
  let e = state.files.find(path)
  if state.surveyLoading(path):
    if not quiet: state.log.add(sevInfo, name, name & " is already being loaded.")
  elif i >= 0 and e >= 0 and state.files.entries[e].size == state.survey.layers[i].size and
      state.files.entries[e].modified == state.survey.layers[i].modified and
      state.survey.layers[i].readAs(lines):
    if not quiet: state.log.add(sevInfo, name, name & " is loaded already, as it is now.")
  else:
    let job = state.jobs.submit(JobSpec(title: "Load " & name, lane: jlInteractive,
      reads: @[path]), surveyWork(path, state.inbox.poster, lines))
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
    let located = layer.auxLocated
    discard state.survey.add(layer)
    if placed == 0:
      # Field records often carry stations only: said once a folder, and not
      # once survey files are loaded.
      let folder = (if located > 0: "only auxiliary coordinates: " else: "no coordinates: ") &
        path.parentDir
      var surveyFiles = false # by index: `anyIt` would copy every layer
      for i in 0 ..< state.survey.layers.len:
        if state.survey.layers[i].origin == loSurveyFile: surveyFiles = true
      if folder notin state.saidPositions and (located > 0 or not surveyFiles):
        state.saidPositions.incl folder
        if located > 0:
          # the headers do give coordinates, on traces that are not seismic
          state.log.add(sevInfo, name, "Only auxiliary traces of " & name & " carry " &
            "coordinates (" & plural(located, "trace") & "), and auxiliary traces " &
            "are not placed on the map.")
        else:
          state.log.add(sevInfo, name, name & " carries no source or receiver coordinates" &
            (if stations > 0: " (its traces name their stations): load its survey files " &
              "(SPS, P1) to place it on the map." else: "."))
    elif problems.len > 0:
      # the same words for the same folder once: a folder of files of one kind does not
      # say them again at every file
      let said = "unplaced: " & path.parentDir & ": " & problems.join("; ")
      if said notin state.saidPositions:
        state.saidPositions.incl said
        state.log.add(sevInfo, name, name & ": " & problems.join("; ") & ". They are left " &
          "off the map.")
  of loShotLog: discard # made with its log's job (`setShotLayer`), never posted as a layer
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
    # An import's layer in place of the same file's keeps the one it
    # replaces until the import ends: a cancel or a failure puts it back.
    template j: untyped = state.joining
    let ours = j.loads.find(job) >= 0 or (job != NoJob and job == j.job)
    var replaced: SurveyLayer
    let id = if ours: state.survey.add(layer, replaced) else: state.survey.add(layer)
    if ours and replaced.id != NoSurveyLayer: j.replaced.add (id, move replaced)
    state.log.add(if lost > 0: sevWarning else: sevInfo, name, text)
    let now = state.relationLayer
    if now >= 0 and state.survey.layers[now].id != wasId:
      for s in state.sessions: # against the relation file now loaded
        if state.joining.job != NoJob and state.joining.session == s.id:
          state.joining.checkLater = true # its import checks it once, at its end
        elif state.joinedRelations(s.id) < 0: state.checkRecords(s)
    state.loaded(job, id)

proc notify(state: var AppState; severity: Severity; text: string)
proc reopen(state: var AppState; i: int; now: bool)
proc showAgain(state: var AppState; path: string)
proc showPath(state: var AppState; k: int; path: string; gather = 0; follow = false;
  by: CommandOrigin; asked = OpenChoice(); forced = false)
proc startJoin(state: var AppState; i: int; cmd: Command; carried = false)
proc dropKeys(state: var AppState; session: SessionId)

proc carryOf(state: AppState; s: Session): Carry =
  ## What `s`, an open file about to be replaced by the same file opened
  ## again, has that is to be kept.
  result = Carry(oldBase: s.base, count: s.len)
  for t in state.selection.selected:
    if t in s: result.selected.add t - s.base
  result.selected.sort()
  let j = state.joinedOf(s.id)
  if j >= 0: (result.joined, result.join) = (true, state.joins[j])
  for w in state.plots:
    if w.traces.len > 0 and w.traces[0] in s: result.plots.add w.id
  for w in state.spectra:
    if w.id != LiveSpectrum and w.traces.len > 0 and w.traces[0] in s: result.spectra.add w.id

proc carryOver(state: var AppState; c: Carry; i: int) =
  ## Puts what `c` kept on the file `sessions[i]`, which replaced the one it
  ## was taken from: with the same trace count, the selection, the join and
  ## the windows of its traces (at the new ids; an id that lay in another
  ## file is left where it is). A frozen window keeps the picture it had.
  ## With another trace count, none of them.
  ## Says in one line what was kept or dropped.
  let s = state.sessions[i]
  var kept, dropped: seq[string]
  let windows = c.plots.len + c.spectra.len
  let wordsOf = if windows == 1: "1 plot window" else: $windows & " plot windows"
  if c.selected.len > 0 or c.joined or windows > 0:
    if c.count == s.len:
      let shift = s.base - c.oldBase
      let old = c.oldBase ..< c.oldBase + c.count
      if c.selected.len > 0:
        var ids = newSeq[int](c.selected.len)
        for k, t in c.selected: ids[k] = s.base + t
        # the old ids are already gone (`closeSession`); other files' traces
        # and the map's points stay
        state.selection.select(ids, smAdd)
        kept.add "the selection"
      for id in c.plots:
        let w = state.findPlot(id)
        if w >= 0:
          # A window may mix this file's traces with another's: only this
          # file's ids move.
          for t in state.plots[w].traces.mitems:
            if t in old: t += shift
          inc state.plots[w].revision
          # Frozen: the picture it had stays. Asking again would recompute it.
          if not state.plots[w].frozen: discard state.askPlot(w)
      for id in c.spectra:
        let w = state.findSpectrum(id)
        if w >= 0:
          for t in state.spectra[w].traces.mitems:
            if t in old: t += shift
          inc state.spectra[w].revision
          discard state.askAgain(w)
      if windows > 0: kept.add wordsOf
      if c.joined:
        if state.importing:
          dropped.add "the survey join (an import is under way)"
        else:
          state.startJoin(i, Command(kind: ckJoin, joinFile: s.id, joinFiles: c.join.files,
            joinOptions: c.join.options, joinUnits: c.join.units, origin: coWindow),
            carried = true)
          kept.add "matching the survey again"
    else:
      if c.selected.len > 0: dropped.add "the selection"
      if c.joined: dropped.add "the survey join"
      for id in c.plots:
        let w = state.findPlot(id)
        if w >= 0:
          if not state.analysisReader.isNil: state.analysisReader.cancel(id)
          state.plots.delete w
      for id in c.spectra:
        let w = state.findSpectrum(id)
        if w >= 0:
          if not state.spectrumReader.isNil: state.spectrumReader.cancel(id)
          state.spectra.delete w
      if windows > 0: dropped.add wordsOf
  if kept.len > 0 or dropped.len > 0:
    var text = s.name & " opened again:"
    if kept.len > 0: text &= " kept " & kept.join(", ")
    if dropped.len > 0:
      text &= (if kept.len > 0: ";" else: "") & " dropped " & dropped.join(", ")
      if c.count != s.len:
        text &= " (it has " & plural(s.len, "trace") & ", it had " & plural(c.count, "trace") & ")"
    state.log.add(sevInfo, s.name, text & ".")

proc openAsItWas(state: var AppState; o: Pending) =
  ## The file was let go of to be shown again, and the reopen did not take:
  ## open it with the choice in force, so it is not left closed.
  let panel = if o.panel == NoPanel: MainPanel else: o.panel
  let k = state.findPanel(panel)
  if k >= 0: state.showPath(k, o.path, o.gather, by = o.by)

proc reopenFailed(state: var AppState; o: Pending; s: Session; why: string) =
  ## A reopen with options whose file did not open with traces: the file is
  ## as it was, the choice too (it is written only once a reopen is taken
  ## in), and the log says so once. One the watch already let go of is
  ## opened again as it was.
  var problems, errors = 0
  var first = ""
  for d in s.file.log:
    if d.severity in {sevError, sevFatal}:
      inc errors
      if first.len == 0: first = d.msg
    if d.severity >= sevWarning: inc problems
  let name = o.path.extractFilename
  let text = "Reopening " & name & " with " & choiceText(o.tried) & " failed: " & why &
    (if first.len > 0: " (" & first & (if problems > 1: "; and " & $(problems - 1) &
      " more problems" else: "") & ")" else: "") &
    (if o.revived: ". It is opened again as it was." else: ". It stays as it was.")
  state.log.add(sevError, name, text)
  state.notify(sevError, text)
  if o.revived:
    for p in state.opening.mitems:
      if p.job == o.job: p.unwanted = true
    state.openAsItWas(o)

proc ended(text: string): string =
  ## `text` as a sentence: a full stop when it has none.
  if text.len == 0: return
  if text[^1] in {'.', '!', '?'}: text else: text & "."

proc sayCorrelate(state: var AppState; text: string; failure = false) =
  ## Shows `text` on the status line, and logs it once until the reason changes.
  let text = ended(text)
  state.correlateNote = text
  if text.len == 0 or text == state.correlateSaid: return
  state.correlateSaid = text
  state.log.add(if failure: sevWarning else: sevInfo, "correlate", text)

proc derivedShown(state: AppState; path: string): bool =
  ## Whether the Seismic window shows a derived view of the file at `path`.
  let k = state.findPanel(MainPanel)
  if k < 0: return false
  let i = state.shownFile(k)
  i >= 0 and state.sessions[i].derived and state.sessions[i].diskPath == diskOf(path)

proc originIndex(state: AppState; path: string): int =
  ## The open raw session of the file at `path`; -1 when it is not open.
  result = -1
  let path = diskOf(path)
  for j, s in state.sessions:
    if not s.derived and s.diskPath == path: return j

proc showRawOf(state: var AppState; path: string) =
  ## Shows the raw session of `path` in the Seismic window, keeping its gather.
  let path = diskOf(path)
  let k = state.findPanel(MainPanel)
  if k < 0: return
  let i = state.originIndex(path)
  if i < 0 or state.shownFile(k) == i: return
  var gather = 0
  if state.panels[k].layers.len > 0: gather = state.panels[k].layers[0].source.gather
  state.showReplacing(k, state.sessions[i].id, gather)

proc dropHold(state: var AppState) =
  ## Cancels the correlation running and keeps its hold until the job ends.
  if state.correlate.isNil: return
  if state.correlate.job != NoJob: discard state.jobs.cancel(state.correlate.job)
  state.correlateRetired.add state.correlate
  state.correlate = nil

proc discardHold(state: var AppState; hold: CorrelateHold) =
  ## Lets go of a result that will not be shown. The file is closed on the closer's thread.
  if hold.isNil: return
  if not hold.result.opened.isNil:
    var opened = hold.result.opened
    hold.result.opened = nil
    state.release(opened)

type
  RefPlan = object
    why: string
    refId: string
    load: CorrelateLoad
    marked: seq[AuxMark]
    notes: seq[string]

func projectAuxMarks*(state: AppState): seq[AuxMarkEntry] =
  ## The auxiliary positions marked for correlation in the project open; none when no
  ## project is open.
  if state.inProject: state.project.doc.auxMarks else: @[]

func marksKey(marked: openArray[AuxMark]): string =
  ## The marks a correlation was made with, as text: a change of a mark is a change of the key.
  for m in marked: result.add "|" & $m.trace & ":" & $m.shiftMs

proc planReferenceOf(state: AppState; i: int): RefPlan =
  ## The chosen reference as a correlation takes it, or why it cannot. Reads no file.
  let s = state.sessions[i]
  let picked = markedAuxiliaries(s.filePtr, s.gathers, s.records,
    state.editsAt(s.path).auxMarks, state.projectAuxMarks)
  result.marked = picked.marked
  result.notes = picked.notes
  result.load.pilotTrace = -1
  if state.chosenRef.len == 0:
    result.why = NoReferenceChosen
    return
  if not state.refsLoaded:
    result.why = "The reference archive has not been read"
    return
  let e = state.refs.findId(state.chosenRef)
  if e < 0:
    result.why = referenceGone(state.chosenRef)
    return
  let entry = state.refs.entries[e]
  result.refId = entry.id
  if entry.missing or entry.blocked:
    result.why = referenceGone(entry.name)
    return
  if entry.isPilot:
    let k = state.findPanel(MainPanel)
    var gather = 0
    if k >= 0 and state.panels[k].layers.len > 0:
      gather = state.panels[k].layers[0].source.gather
    let rule = entry.pilotRuleOf
    let edits = state.editsAt(s.path)
    let picked = s.pilotOfRecord(gather, rule, edits)
    if picked.trace < 0:
      result.why = if picked.problem.len > 0: picked.problem else: "the record has no pilot"
      return
    result.load = CorrelateLoad(pilotTrace: picked.trace, pilot: rule,
      flip: edits.has(teReversed, picked.trace), shiftMs: edits.shiftOf(picked.trace),
      record: picked.record)
    return
  let dt = markedDtMs(s.filePtr, result.marked)
  let refMs = if entry.intervalUs > 0 and entry.intervalUs < Inf: entry.intervalUs / 1000.0
              else: NaN
  if refMs > 0 and dt > 0 and not sameInterval(refMs, dt):
    result.why = intervalRefusal(refMs, dt)
    return
  if entry.file.len == 0 or state.refsHome.len == 0:
    result.why = referenceGone(entry.name)
    return
  result.load = CorrelateLoad(refPath: state.refsHome / entry.file, pilotTrace: -1)

proc planReference(state: AppState; i: int): RefPlan =
  ## `planReferenceOf`, its `refId` also naming the marks, so a change of a mark is a new
  ## correlation.
  result = state.planReferenceOf(i)
  result.refId.add marksKey(result.marked)

proc startCorrelate(state: var AppState; originIndex: int; keepView: bool) =
  ## Correlates open raw session `originIndex` with the chosen reference.
  ## `keepView`: leave a derived view of that file shown until the new one is ready.
  if not state.correlateOn: return
  if originIndex notin 0 ..< state.sessions.len: return
  let s = state.sessions[originIndex]
  if s.derived: return
  if alreadyCorrelated(s.filePtr):
    state.showRawOf(s.diskPath)
    state.sayCorrelate(s.name & " is already correlated (its header says so): shown as it is")
    return
  let plan = state.planReference(originIndex)
  if plan.why.len > 0:
    if not keepView or not state.derivedShown(s.diskPath): state.showRawOf(s.diskPath)
    state.sayCorrelate(plan.why)
    return
  if not state.correlate.isNil and state.correlate.origin == s.diskPath and
      state.correlate.refId == plan.refId:
    return
  if state.correlateRef == plan.refId:
    var derived = -1
    for j, x in state.sessions:
      if x.derived and x.diskPath == s.diskPath: derived = j
    if derived >= 0:
      let k = state.findPanel(MainPanel)
      if k >= 0 and not (keepView and state.shownFile(k) == derived):
        var gather = 0
        if state.panels[k].layers.len > 0: gather = state.panels[k].layers[0].source.gather
        state.showReplacing(k, state.sessions[derived].id, gather)
      state.correlateNote = ""
      return
  state.dropHold()
  inc state.correlateGen
  let hold = CorrelateHold(origin: s.diskPath, refId: plan.refId, gen: state.correlateGen,
    job: NoJob)
  var ask = CorrelateAsk(file: s.filePtr, path: s.diskPath, marked: plan.marked,
    markNotes: plan.notes)
  let load = plan.load
  let slot = addr hold.result
  let job = state.jobs.submit(JobSpec(title: "Correlate " & s.diskPath.extractFilename,
    lane: jlBackground, reads: @[s.diskPath], auto: true),
    correlateOrView(ask, load, state.correlateLimit, slot))
  hold.job = job
  state.correlate = hold
  state.correlateNote = ""

proc openHeld(state: var AppState; path: string) =
  ## Opens `path` again without showing it, then correlates it. The derived view stays
  ## until the new one is ready. An origin already open is correlated at once.
  let i = state.originIndex(path)
  if i >= 0:
    state.startCorrelate(i, keepView = true)
    return
  for o in state.opening.mitems:
    if o.path == path and not o.unwanted:
      o.hold = true
      o.panel = NoPanel
      return
  let job = state.jobs.submit(JobSpec(title: "Open " & path.extractFilename,
    lane: jlInteractive, reads: @[path]), openFileWork(path, state.inbox.poster,
    indexCacheFile(state.indexCache, path), lines = state.settings.join,
    choice = state.openChoiceOf(path), pair = state.pairArgOf(path)))
  state.opening.add Pending(job: job, path: path, panel: NoPanel, hold: true,
    by: state.openedBy.getOrDefault(path))

proc stopCorrelate(state: var AppState) =
  ## Turns correlation off: the raw record is shown and the derived view is closed.
  state.correlateOn = false
  state.correlateNote = ""
  state.dropHold()
  let k = state.findPanel(MainPanel)
  if k < 0: return
  let i = state.shownFile(k)
  if i < 0 or not state.sessions[i].derived: return
  let id = state.sessions[i].id
  state.showRawOf(state.sessions[i].diskPath)
  state.closeIfUnused(id)

proc followLeap(state: var AppState)

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
  var holdOpen = false # opened so a correlation can run again: not shown raw
  var reopened = -1 # `opening[reopened]`: a reopen with options
  for j, p in state.opening:
    if p.job == job:
      if p.unwanted: # another file was chosen meanwhile
        state.release(s)
        return
      if p.panel != NoPanel: (panel, replacing) = (p.panel, true)
      (gather, follow, by, holdOpen) = (p.gather, p.follow, p.by, p.hold)
      if p.reopened: reopened = j
  var carry = Carry()
  var swap = false
  if reopened >= 0:
    let o = state.opening[reopened]
    let bad = if s.file.kind == skUnknown: "it is not read as a SEG-Y, SEG-D or SEG-2 file"
              elif s.len == 0: "read so it has no traces"
              else: ""
    if bad.len > 0:
      state.reopenFailed(o, s, bad)
      state.release(s) # nothing else has it
      if panel == MainPanel: state.chooseShown()
      return
    var old = -1
    for j, x in state.sessions:
      if x.path == s.path: old = j
    if o.replacesOpen and old < 0 and not o.revived:
      # Closed before this open arrived, and nothing asked to show it again:
      # the close stands. Not swapped, so the job's end says nothing of an
      # open that was not taken in.
      state.release(s)
      if panel == MainPanel: state.chooseShown()
      return
    # Opened: takes the open file's place, which lets go of its panels. The
    # file's shots are read again, as the options say. The choice is in force
    # only now.
    state.opening[reopened].swapped = true
    if o.tried.isDefault: state.openChoices.del o.path
    else: state.openChoices[o.path] = o.tried
    state.log.add(sevInfo, s.name, s.name & " is opened again" & (if o.tried.isDefault:
      " with the defaults." else: ": " & choiceText(o.tried) & "."))
    state.shots.forget(state.survey, @[s.path])
    state.shots.listedRev = -1
    if old >= 0:
      swap = true
      carry = state.carryOf(state.sessions[old])
      state.reopen(old, now = false)
      for r in state.reopens: # the first panel that showed it gets it, at its record
        if r.path == s.path:
          (panel, replacing, gather) = (r.panel, true, r.gather)
          break
  if follow and s.file.kind != skUnknown and filejobs.endsEarly(s.file):
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
  if s.isSignature:
    state.log.add(sevInfo, "open", signatureOpened(s.name, s.signature, s.len))
    for w in s.signature.warnings: state.log.add(sevWarning, s.name, w)
    for w in s.signature.notes: state.log.add(sevInfo, s.name, w)
  else:
    state.log.add(s.file.log, s.name)
    state.log.add(sevInfo, "open", "Opened " & s.name & ": " & plural(s.len, "trace") &
      " in " & plural(s.gathers.len, "gather") &
      (if s.file.fromCache: " (index from the cache)." else: "."))
  if s.zeroKept > 0:
    state.log.add(sevInfo, s.name, plural(s.zeroKept, "trace") & " with field record number " &
      "0 " & (if s.zeroKept == 1: "was" else: "were") & " kept with the record before " &
      (if s.zeroKept == 1: "it" else: "them") & ".")
  gather = if s.gathers.len == 0: -1 else: clamp(gather, 0, s.gathers.high)
  if not s.derived:
    state.change(by, st):
      st.recentFiles.addRecent(s.path, MaxRecent)
      st.recentFolders.addRecent(s.path.parentDir, MaxRecent)
    state.openedBy[s.path] = by
  state.checkEdits(s)
  state.identify(s)
  let path = s.diskPath
  let short = filejobs.endsEarly(s.file)
  state.onDiskSaid.del path
  state.sessions.add s
  if not state.sessions[^1].isSignature and
      state.sessions[^1].leapRead != state.leapGen:
    let id = state.sessions[^1].id
    if id notin state.leapQueue: state.leapQueue.add id
    state.followLeap()
  if state.surveyMatchable:
    state.project.queue.add id # matched to the project's survey (`followProject`)
  elif not s.isSignature and not s.noSeismic and state.project.doc.stationMoves.len > 0:
    state.enqueueMoves(id)
  if not state.sessions[^1].isSignature: # (a signature file has no place on the map)
    state.readPositions(state.sessions[^1])
  if state.relationLayer >= 0: state.checkRecords(state.sessions[^1])
  state.watchOpen()
  let k = state.findPanel(panel)
  if holdOpen and state.correlateOn:
    state.startCorrelate(state.sessions.high, keepView = true)
  elif holdOpen:
    # The toggle was turned off before this open finished: show the raw file.
    state.show(MainPanel, id, gather)
    state.choose(path)
    state.mark(path, short, seen = true)
  elif replacing and k >= 0: state.showReplacing(k, id, gather)
  else: state.show(MainPanel, id, gather)
  if not holdOpen and panel == MainPanel and state.correlateOn and
      not state.sessions[^1].isSignature:
    state.startCorrelate(state.sessions.high, keepView = false)
  if panel == MainPanel:
    state.choose(path)
    state.mark(path, short, seen = true)
  if state.jump.path == path and k >= 0: # a message's trace, asked for before the file opened
    state.showTrace(k, state.sessions.high, state.jump.trace, state.jump.record)
    state.jump = ("", -1, -1)
  if swap:
    state.showAgain(path) # the other panels that showed the file
    state.carryOver(carry, state.sessions.high)

proc adoptDerived*(state: var AppState; s: sink Session) =
  ## Shows a session already bound with `asDerived` in the main panel. The
  ## file on disk stays open. Not identified, not added to the recent files,
  ## and not watched under its own path. A derived view of that file already
  ## open is closed once this one is shown.
  if s.isNil or not s.derived: return
  let origin = s.diskPath
  var previous = NoSession
  for x in state.sessions:
    if x.derived and x.diskPath == origin: previous = x.id
  var gather = 0
  let k = state.findPanel(MainPanel)
  if k >= 0 and state.panels[k].layers.len > 0:
    let shown = state.shownFile(k)
    if shown >= 0 and state.sessions[shown].diskPath == origin:
      gather = state.panels[k].layers[0].source.gather
  let id = SessionId(state.nextFile)
  inc state.nextFile
  s.register(id, state.nextBase)
  state.nextBase += s.len
  gather = if s.gathers.len == 0: -1 else: clamp(gather, 0, s.gathers.high)
  state.sessions.add s
  state.watchOpen()
  if k >= 0: state.showReplacing(k, id, gather)
  state.choose(origin)
  if previous != NoSession: state.closeIfUnused(previous)

proc notePicks(state: var AppState; origin: string) =
  ## Once, that first-break picks of this file are not drawn on the correlated record.
  if state.picksSaid: return
  var ids: seq[SessionId] = @[]
  for s in state.sessions:
    if s.diskPath == origin: ids.add s.id
  for b in state.breaks:
    if b.key.file in ids and b.picked > 0:
      state.picksSaid = true
      state.sayCorrelate(
        "First-break picks were made on the raw record and are not drawn on the correlated record")
      return

proc takeCorrelate(state: var AppState; job: JobInfo): bool =
  ## A correlation job ended. True when `job` was one: a stale or cancelled result is
  ## dropped, a failure turns the toggle off, and a result is shown.
  var hold: CorrelateHold = nil
  var current = false
  if not state.correlate.isNil and state.correlate.job == job.id:
    hold = state.correlate
    state.correlate = nil
    current = true
  else:
    var kept: seq[CorrelateHold] = @[]
    for h in state.correlateRetired:
      if h.job == job.id: hold = h
      else: kept.add h
    if not hold.isNil: state.correlateRetired = kept
  if hold.isNil: return false
  result = true
  let stale = not current or not state.correlateOn or hold.gen != state.correlateGen or
    job.state == jsCancelled or hold.result.cancelled
  if stale:
    state.discardHold(hold)
    return
  if job.state != jsDone or not hold.result.ok or
      (hold.result.opened.isNil and not hold.result.onDemand):
    let why = if hold.result.failure.len > 0: hold.result.failure
              elif job.error.len > 0: job.error
              else: "the correlation failed"
    state.correlateOn = false
    state.sayCorrelate(why, failure = true)
    state.showRawOf(hold.origin)
    state.discardHold(hold)
    return
  var opened = hold.result.opened
  hold.result.opened = nil
  if hold.result.onDemand:
    let raw = state.originIndex(hold.origin)
    if raw < 0:
      state.discardHold(hold)
      return
    state.sayCorrelate("Correlated on demand: the correlated copy would be " &
      formatSize(hold.result.estimate, includeSpace = true) &
      ", more than fits in memory at once")
    opened = asCorrelatedView(state.sessions[raw], hold.result.view)
  else:
    opened.asDerived()
  state.correlateRef = hold.refId
  for line in hold.result.lines:
    state.log.add(sevInfo, "correlate", ended(line))
  state.adoptDerived(opened)
  state.notePicks(hold.origin)
  state.discardHold(hold)

proc closeDerivedOf(state: var AppState; path: string) =
  ## The held reopen of `path` failed or was cancelled: the correlated picture
  ## has no raw session under it, so it is closed.
  var i = -1
  for j, s in state.sessions:
    if s.derived and s.diskPath == path: i = j
  if i < 0: return
  state.closeSession(i, quiet = true)
  let name = path.extractFilename
  state.log.add(sevWarning, name, name & ": the correlated view was closed because " &
    "the file changed.")

proc endOpening(state: var AppState; i: int; how: JobState; error = "") =
  ## Says how open job `opening[i]` ended, and forgets it. An open no longer
  ## wanted ends quietly. A held reopen (no panel) that fails or is cancelled
  ## closes the derived view and shows the same failure a shown file would.
  let o = state.opening[i]
  let p = o.path
  let name = p.extractFilename
  state.opening.delete(i)
  if o.unwanted or o.swapped: return
  case how
  of jsFailed:
    # (a signature file's refusal is a sentence of its own, naming the file)
    let said = if error.startsWith(name & " "): error else: "Cannot open " & p & ": " & error
    if o.reopened and o.revived:
      state.log.add(sevError, name, said & ". It is opened again as it was.")
      state.openAsItWas(o)
    else:
      state.log.add(sevError, name, said)
  of jsCancelled: state.log.add(sevInfo, name, "Opening " & name & " was cancelled.")
  else: discard # done: `adopt` took the file
  if how in {jsFailed, jsCancelled} and (o.panel == MainPanel or o.hold):
    if o.hold: state.closeDerivedOf(p)
    if how == jsFailed: state.failed(p)
    state.chooseShown()

proc notify(state: var AppState; severity: Severity; text: string) =
  ## A brief notice for the frontend to show: a background job ended.
  state.notices.add Notice(severity: severity, text: text, serial: state.nextNotice)
  inc state.nextNotice
  if state.notices.len > MaxNotices: state.notices.delete(0)

# ------------------------------------------------------------------ join --

proc finishImport(state: var AppState)

proc startJoin(state: var AppState; i: int; cmd: Command; carried = false) =
  ## `ckJoin`, the survey import. With an open file `sessions[i]`, the files
  ## are read once, on a job (`joinReadWork`), while the plot goes on reading
  ## the file: those not on the map yet (or read with other line names) are
  ## put on it from what that read reads, a relation file on it as it is now
  ## is not read again (its records are used where they are), and what
  ## matching them to its traces does is worked out. With none (`i` -1),
  ## the survey is put on the map only: its SPS and P1 files not on it yet
  ## are loaded, as File > Open loads them (`loadSurvey`).
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
  var layers = newSeq[bool](files.len) # made by the import's read (a file open)
  var reuse = newSeq[ptr SurveyGeometry](files.len)
  var reused: seq[ref SurveyGeometry]
  for k, f in files:
    # Not on the map yet, or read with other line names than the import's.
    let l = state.survey.findFile(f.path)
    if f.kind != jkCsv and (l < 0 or not state.survey.layers[l].readAs(cmd.joinOptions)) and
        not state.surveyLoading(f.path):
      if i >= 0: layers[k] = true # its layer is made from what the join reads
      else:
        state.loadSurvey(f.path, quiet = true, lines = cmd.joinOptions)
        if state.loading.len > 0 and state.loading[^1].path == f.path:
          loads.add state.loading[^1].job
    elif SharedRelations and f.kind == jkSps and l >= 0 and not cmd.joinOptions.multiComponent:
      # A relation file on the map as it is now: the join uses its records
      # where they are, and does not read it again.
      template layer: untyped = state.survey.layers[l]
      let e = state.files.find(f.path)
      if layer.relationRuns > 0 and layer.points[prSource].len + layer.points[prReceiver].len +
          layer.counts[prSource].given + layer.counts[prReceiver].given == 0 and
          layer.readAs(cmd.joinOptions) and e >= 0 and
          state.files.entries[e].size == layer.size and
          state.files.entries[e].modified == layer.modified:
        reuse[k] = addr layer.relations[]
        reused.add layer.relations
  if i < 0:
    state.joining = Joining(name: "the map", files: files, options: cmd.joinOptions,
      units: cmd.joinUnits, loads: loads, waits: true, outcome: joMapOnly, by: cmd.origin, words: @[
      "No seismic file is open, so no trace was matched: open one and import the survey " &
      "again to match it."])
    state.log.add(sevInfo, "survey", "Importing the survey (" & fileNames(files) & "): no " &
      "seismic file is open, so it is put on the map only.")
    if loads.len == 0: state.finishImport()
  else:
    let s = state.sessions[i]
    let job = state.jobs.submit(JobSpec(title: "Import the survey for " & s.name,
      lane: jlInteractive, reads: reads), joinReadWork(s.filePtr, s.id, files, cmd.joinOptions,
      state.inbox.poster, layers, reuse))
    state.joining = Joining(job: job, step: jpReading, session: s.id, path: s.path,
      name: s.name, files: files, options: cmd.joinOptions, units: cmd.joinUnits, loads: loads,
      reused: reused, by: cmd.origin, carried: carried)
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
        state.readers[k].show(ReaderSource(gen: p.sourceGen, file: s.filePtr, session: s.id,
          path: s.path, size: s.size, traces: s.gathers[g].traces, filter: p.layers[0].filter,
          order: p.layers[0].order))
      else:
        state.newSource(k)
  state.joining.paused.setLen 0

proc pauseMoveReaders(state: var AppState; path: string) =
  ## Has the readers of the panels that show `path` let go of it, for the
  ## station-move job that needs it to itself; their tiles stay drawn meanwhile.
  for k in 0 ..< state.panels.len:
    let i = state.shownFile(k)
    if i >= 0 and state.sessions[i].path == path:
      if state.panels[k].id notin state.movesPaused:
        state.movesPaused.add state.panels[k].id
      if not state.readers[k].isNil:
        state.readers[k].show(ReaderSource(gen: state.panels[k].sourceGen))

proc resumeMoveReaders(state: var AppState) =
  ## The panels the station-move job paused show their file again: the same
  ## gather at the same scales, the tiles from before drawn until the first
  ## new one (made from the moved keys) comes.
  for id in state.movesPaused:
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
        state.readers[k].show(ReaderSource(gen: p.sourceGen, file: s.filePtr, session: s.id,
          path: s.path, size: s.size, traces: s.gathers[g].traces, filter: p.layers[0].filter,
          order: p.layers[0].order))
      else:
        state.newSource(k)
  state.movesPaused.setLen 0

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

proc keepImport(state: var AppState)

proc finishImport(state: var AppState) =
  ## The import ends once its match is over and its files are on the map:
  ## what it did, the points on the map and the traces matched, is said in
  ## the log and kept for the dialog. The user's import while a project is
  ## open is kept in the project (`keepImport`).
  template j: untyped = state.joining
  if not j.auto: state.keepImport()
  var words = j.words
  if j.outcome != joCancelled and j.outcome != joFailed and not j.auto:
    words.insert(state.onTheMap(j.files), 0)
  let i = state.findSession(j.session)
  let unmatched = if j.outcome == joJoined: j.plan.unmatched.len else: 0
  case j.outcome
  of joJoined, joNothing:
    # A carried rematch that matched nothing is the drop line below, once:
    # not this line as well.
    if i >= 0 and not (j.carried and j.outcome == joNothing):
      let s = state.sessions[i]
      state.log.add(if j.outcome == joNothing: sevWarning else: sevInfo, s.name,
        (if j.outcome == joNothing: "The survey matches none of the traces of " & s.name
          elif j.auto: "Matched " & s.name & " to the project's survey, without reading a " &
            "survey file"
          else: "Survey imported for " & s.name) & " (" & fileNames(j.files) & "): " &
        words.join(" "))
  of joMapOnly:
    state.log.add(sevInfo, "survey", "Survey imported (" & fileNames(j.files) & "): " &
      words.join(" "))
  of joCancelled:
    if not j.carried and words.len > 0: state.log.add(sevInfo, j.name, words[0])
  of joFailed:
    if not j.carried and words.len > 0: state.log.add(sevError, j.name, words[0])
  of joNone: discard
  if j.carried:
    case j.outcome
    of joJoined:
      state.log.add(sevInfo, j.name, j.name & " kept the survey join.")
    of joNothing:
      state.log.add(sevWarning, j.name, j.name & " dropped the survey join: the survey " &
        "matches none of its traces.")
      words.setLen 0 # the plan's "keys changed" was not applied; the line says it
    of joFailed, joCancelled:
      # One sentence, not the words again (they would say the same thing).
      let why = if j.outcome == joCancelled: "the match was cancelled."
                elif words.len > 0: "the match failed: " & words[0] & "."
                else: "the match failed."
      state.log.add(sevWarning, j.name, j.name & " dropped the survey join: " & why)
      words.setLen 0
    of joMapOnly, joNone: discard
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
  var words: seq[string] = @[]
  case outcome
  of joJoined, joNothing:
    # The distances in the unit confirmed, else the survey files' or the file's.
    # (the grid unit only: an `if` that gives the geometry copies it, every
    # relation record of a large X file, on the UI thread)
    let unit = wordsUnit(j.units.survey, (if j.geometry.isNil: GridUnit()
      else: j.geometry.gridUnit), (if i >= 0: headerUnitOf(state.sessions[i].crs) else: suNotGiven))
    words = planWords(j.plan, j.survey, j.options, unit)
    if i >= 0:
      let s = state.sessions[i]
      let before = state.joinedOf(s.id)
      if before >= 0: state.joins.delete(before)
      if outcome == joJoined:
        if j.joined: s.setKeysRevision(j.revision) # before the jobs below read the keys
        state.joins.add Joined(session: s.id, files: j.files, options: j.options,
          units: j.units, plan: j.plan, survey: j.survey, words: words, geometry: j.geometry,
          relations: j.relations)
        if j.plan.changes > 0 or j.movesTouched: state.readPositions(s) # the map's, from the keys
        if j.movesCount > 0:
          state.log.add(sevInfo, s.name, "Station moves applied to " & plural(j.movesCount,
              "trace") &
            " of " & s.name & ".")
        state.checkRecords(s)
      if j.survey.notes.len > 0:
        state.log.add(sevInfo, s.name, "The survey files' headers say: " &
          j.survey.notes.join("; ") & ".")
  of joCancelled:
    if not j.carried:
      words = @["The survey import was cancelled: " & j.name & " is as it was, and so is the map."]
  of joFailed:
    if j.carried: words = @[error] # the drop line names it; not shown as the words too
    else:
      words = @["The survey import failed: " & error & ". " & j.name & " is as it was, and " &
        "so is the map."]
  of joNone, joMapOnly: discard
  (j.job, j.outcome, j.words, j.waits) = (NoJob, outcome, words, true)
  if outcome in {joCancelled, joFailed}:
    for job in j.loads:
      discard state.jobs.cancel(job)
      state.droppedLoads.add job
    # its layers taken off, those they replaced put back as they were
    let before = state.relationLayer
    let wasId = if before >= 0: state.survey.layers[before].id else: NoSurveyLayer
    for id in j.added:
      var back = -1
      for k in 0 ..< j.replaced.len:
        if j.replaced[k].by == id: back = k
      if back >= 0: state.survey.putBack(id, move j.replaced[back].layer)
      else: discard state.survey.remove(id)
    if j.added.len > 0:
      state.map.followed(state.survey)
      let now = state.relationLayer
      if now >= 0 and state.survey.layers[now].id != wasId:
        for s in state.sessions: # against the relation file the map has again
          if s.id == j.session: j.checkLater = true # (below)
          elif state.joinedRelations(s.id) < 0: state.checkRecords(s)
    j.loads.setLen 0
  # A relation file loaded while it ran: checked against now, once (a file
  # joined was checked above).
  if j.checkLater and outcome != joJoined and i >= 0 and
      state.joinedRelations(state.sessions[i].id) < 0:
    state.checkRecords(state.sessions[i])
  j.checkLater = false
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
  elif job != NoJob and job == j.job and layer != NoSurveyLayer:
    j.added.add layer # a layer the import's read made (taken out again at a cancel)

proc moveBasesOf(state: AppState; id: SessionId): seq[ReceiverBase] =
  ## The receiver fields a station move replaced in open file `id`; empty when none.
  for b in state.moveBases:
    if b.session == id: return b.bases

proc putMoveBases(state: var AppState; id: SessionId; bases: seq[ReceiverBase]) =
  ## Remembers `bases` for open file `id`. Empty forgets them.
  var i = 0
  while i < state.moveBases.len:
    if state.moveBases[i].session == id:
      if bases.len == 0: state.moveBases.delete(i)
      else: state.moveBases[i].bases = bases
      return
    inc i
  if bases.len > 0: state.moveBases.add (session: id, bases: bases)

proc dropMoveBases(state: var AppState; id: SessionId) =
  ## Forgets the receiver fields remembered for open file `id`.
  state.moveBases.keepItIf(it.session != id)

proc enqueueMoves(state: var AppState; id: SessionId) =
  ## Has open file `id` take the project's station moves, once no join runs.
  if id notin state.moveQueue: state.moveQueue.add id

proc drainProjectMoves(state: var AppState) =
  ## The project's survey will not be matched. Every file waiting for that
  ## join takes the station moves on its own.
  for id in state.project.queue: state.enqueueMoves(id)
  state.project.queue.setLen 0

proc takeJoinPlan(state: var AppState; m: sink Msg) =
  ## The survey files read and what joining them does: when it changes some
  ## trace's keys, the readers of the file let go of it and the join's second
  ## job (`joinApplyWork`, the file to itself) does it; else it ends here.
  template j: untyped = state.joining
  if m.job != j.job or j.step != jpReading or j.cleared: return # (a join no longer wanted)
  let i = state.findSession(m.planSession)
  if i < 0: return # closed meanwhile: the job's end says so
  if not m.geometry.isNil: j.geometry = move m.geometry # (a project's match keeps its own)
  j.relations = move m.relations
  if j.relations.isNil and m.reusedAt >= 0 and m.reusedAt < j.files.len:
    let l = state.survey.findFile(j.files[m.reusedAt].path)
    for r in j.reused: # (the one the read used, kept alive since)
      if l >= 0 and state.survey.layers[l].relations == r: j.relations = r
    if j.relations.isNil and j.reused.len == 1: j.relations = j.reused[0]
  j.plan = move m.plan
  j.survey = move m.joinSurvey
  # The units not chosen: what the headers say, as the import read them.
  j.units = j.units.resolved(j.survey.heads, headerUnitOf(state.sessions[i].crs))
  # A carried rematch that matches no seismic trace is dropped, not applied:
  # filling stations the headers lack still counts as a key change, so
  # `changes` alone would keep a join that matched nothing.
  let noTrace = j.carried and j.plan.matched == 0
  let moves = state.project.doc.stationMoves
  let bases = state.moveBasesOf(j.session)
  let needMoves = moves.len > 0 or bases.len > 0
  if noTrace:
    # A carried rematch that matches no trace is dropped. Moves still waiting
    # are applied on their own once the join has ended.
    state.endJoin(joNothing)
    if needMoves: state.enqueueMoves(j.session)
  elif j.plan.changes == 0 and not needMoves:
    # Nothing to change: the readers need not stop.
    let nothing = j.plan.found[prSource] + j.plan.found[prReceiver] == 0
    state.endJoin(if nothing: joNothing else: joJoined)
  else:
    let s = state.sessions[i]
    state.moveQueue.keepItIf(it != j.session)
    state.pauseReaders(s.path)
    let tableOnly = j.files.allIt(it.kind == jkCsv)
    let relations = if j.relations.isNil: nil else: addr j.relations[]
    j.job = state.jobs.submit(JobSpec(title: "Import the survey for " & s.name,
      lane: jlInteractive, exclusive: @[s.path]), joinApplyWork(s.filePtr, s.path, s.id,
      addr j.geometry[], j.plan.replace, tableOnly, state.jobs.holdRelease, state.inbox.poster,
      relations, moves, bases))
    j.step = jpJoining

proc takeJoined(state: var AppState; m: Msg) =
  ## The join's second job did it (its end, `onFinished`, ends the join).
  template j: untyped = state.joining
  if m.job == j.job and j.step == jpJoining and m.joinedSession == j.session:
    j.joined = true
    j.held = m.heldAtJoin
    j.revision = m.joinedRevision
    j.movesTouched = m.joinedMoves > 0
    j.movesCount = m.joinedMoves
    if state.findSession(m.joinedSession) >= 0:
      state.putMoveBases(m.joinedSession, m.joinedBases)
    if m.changed != j.plan.changes:
      state.log.add(sevWarning, j.name, "The import changed " & plural(m.changed, "trace") &
        " where " & $j.plan.changes & " were expected (parseSEG: " & $m.stats & ").")

proc takeMoves(state: var AppState; m: Msg) =
  ## A station-move job did it (its end, `finishMoves`, refreshes the map).
  if m.job != state.movesJob or m.movedSession != state.movesSession: return
  state.movesDone = true
  state.movesChanged = m.movedCount
  state.movesRevision = m.movedRevision
  if state.findSession(m.movedSession) >= 0:
    state.putMoveBases(m.movedSession, m.movedBases)

proc takeLeap(state: var AppState; m: Msg) =
  ## A leap-second re-read did it (its end, `finishLeap`, publishes the revision).
  if m.job != state.leapJob or m.leapSession != state.leapSession: return
  state.leapDone = true
  state.leapChanged = m.leapChanged
  state.leapRevision = m.leapRevision

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

# --------------------------------------------------------------- project --
# A project (docs/project.md): the store's home, the survey kept and every
# file opened matched to it, the presets, the filters and the windows' own
# arrangement. Its jobs are `core/projectjobs`.

proc startListing(state: var AppState; paths: seq[string]; title, folder: string;
    by: CommandOrigin)

proc projectChanged(state: var AppState) =
  ## The project's document changed: written `SaveDelay` later.
  inc state.project.docRev
  inc state.project.revision
  state.project.changedAt = getMonoTime()

proc lastFolderText(p: ProjectState; folder: string): string =
  ## `folder` as the project keeps its last folder: "N|rest", under the found data folder
  ## N; "" when it lies under none (a string check, no file system).
  for i, f in p.folders:
    if f.state == psFound and f.path.len > 0:
      if folder == f.path: return $i & "|"
      if folder.startsWith(f.path & DirSep): return $i & "|" & folder[f.path.len + 1 .. ^1]

proc lastFolderStart(p: ProjectState; first: string): string =
  ## The folder a project opens listing: its last one when it lies under a data folder that
  ## was found, else `first`, the first data folder found.
  result = first
  let at = p.doc.lastFolder.find('|')
  if at > 0:
    try:
      let i = parseInt(p.doc.lastFolder[0 ..< at])
      if i in 0 ..< p.folders.len and p.folders[i].state == psFound:
        let rest = p.doc.lastFolder[at + 1 .. ^1]
        result = if rest.len == 0: p.folders[i].path else: p.folders[i].path / rest
    except ValueError:
      discard

proc forgetFileMemory(state: var AppState) =
  ## What is remembered about the files opened this run, written to the
  ## store it came from, then forgotten here: the next store is another's.
  state.saveMemory(getMonoTime(), force = true)
  state.edits.clear()
  state.editKey.clear()
  state.remembered.setLen 0
  state.knownDocs.clear()

const
  ReadOnlyShotLog* = "The project is open read-only: the shot log is not saved."
  ShotLogNotStored* = "The shot log is not stored: no project is open."
  ShotLogEditsDropped* = "The column count changed: the edited cells were dropped."
  ShotLogLineBreak* = "The cell was not changed: it cannot hold a line break."
  ColumnsAsLast* = "Columns set as in the last shot log."

proc findShot(state: AppState; id: int): int =
  result = -1
  for i, s in state.shotLogs:
    if s.id == id: return i

proc setShotLayer(state: var AppState; loaded: LoadedShotLog; layer: ref SurveyLayer) =
  ## Puts the map layer a job made of loaded shot log `loaded` in the survey, in place
  ## of the one before; none (`layer` nil) takes the old one off.
  let at = state.survey.findShotLog(loaded.id)
  if layer == nil:
    if at >= 0: discard state.survey.remove(state.survey.layers[at].id)
  else:
    layer.shotLog = loaded.id
    layer.path = if loaded.source.len > 0: loaded.source else: loaded.name
    layer.name = loaded.name
    discard state.survey.add(move layer[])

proc dropShotLayers(state: var AppState) =
  ## Takes every shot log's layer off the map.
  var ids: seq[SurveyLayerId] = @[]
  for i in 0 ..< state.survey.layers.len:
    if state.survey.layers[i].origin == loShotLog: ids.add state.survey.layers[i].id
  for id in ids: discard state.survey.remove(id)

proc dropShotLogs(state: var AppState) =
  ## Cancels a shot log's jobs and drops the loaded logs. A close, or a
  ## project opening, starts from none. A delete already asked for is left
  ## running: the document no longer names the copy, and cancelling it would
  ## leave the file.
  var kept: seq[ShotLogWork] = @[]
  for w in state.shotWork:
    if w.kind == sjDelete: kept.add w
    elif w.job != NoJob: discard state.jobs.cancel(w.job)
  state.shotWork = kept
  state.follow.dropAll()
  state.stopShotTraces()
  state.dropShotLayers()
  state.shotLogs.setLen 0
  inc state.shotLogsRev

proc takenShotFiles(state: AppState): seq[string] =
  for s in state.project.doc.shotLogs: result.add s.file
  for w in state.shotWork:
    if w.stored.len == 0: continue
    if w.kind == sjDelete and w.source != state.project.dir: continue
    result.add w.stored
  for s in state.shotLogs:
    if s.stored.len > 0: result.add s.stored

proc submitShotSave(state: var AppState; i: int) =
  let loaded = state.shotLogs[i]
  loaded.busy = true
  let sink = ShotLogSink()
  let path = state.project.dir.partOf(loaded.stored.shotLogCopy)
  let job = state.jobs.submit(saveSpec(path),
    saveShotLog(state.project.dir, loaded.stored, loaded.log, loaded.map, sink))
  state.shotWork.add ShotLogWork(job: job, kind: sjSave, id: loaded.id, sink: sink,
    name: loaded.name, source: loaded.source, stored: loaded.stored, map: loaded.map)

proc submitShotDelete(state: var AppState; stored: string) =
  ## Removes the project copy `stored` on a job. The name stays taken until
  ## that job ends, so a new copy is not written there first.
  if stored.len == 0 or not state.inProject or state.readOnlyProject: return
  let path = state.project.dir.partOf(stored.shotLogCopy)
  let sink = ShotLogSink()
  let job = state.jobs.submit(removeSpec(path), removeShotLogCopy(path, sink))
  state.shotWork.add ShotLogWork(job: job, kind: sjDelete, id: -1, sink: sink,
    name: stored, source: state.project.dir, stored: stored)

proc submitShotRebuild(state: var AppState; i: int) =
  let loaded = state.shotLogs[i]
  loaded.busy = true
  let sink = ShotLogSink()
  let job = state.jobs.submit(remapSpec(loaded.source),
    rebuildShotLog(loaded.log, loaded.map, sink))
  state.shotWork.add ShotLogWork(job: job, kind: sjRebuild, id: loaded.id, sink: sink,
    name: loaded.name, source: loaded.source, stored: loaded.stored, map: loaded.map)

proc storeOrSay(state: var AppState; i: int) =
  ## Copies a loaded log into the project, or says why it is not stored.
  ## A file that already sits where the copy would be written is not that
  ## copy: its name is taken, so the copy is written beside it.
  let loaded = state.shotLogs[i]
  if not state.inProject:
    state.log.add(sevInfo, "shot log", ShotLogNotStored)
    return
  if state.readOnlyProject:
    state.log.add(sevWarning, "shot log", ReadOnlyShotLog)
    return
  var taken = state.takenShotFiles()
  var file = copyName(loaded.source.extractFilename, taken)
  if samePath(canonical(loaded.source), canonical(state.project.dir.partOf(file.shotLogCopy))):
    taken.add file
    file = copyName(loaded.source.extractFilename, taken)
  if not file.isShotLogFile:
    state.log.add(sevWarning, "shot log", file & " could not be saved.")
    return
  loaded.stored = file
  state.submitShotSave(i)

proc loadStoredShotLogs(state: var AppState) =
  ## Reads each shot log the open project stores, on a job.
  if not state.inProject: return
  for s in state.project.doc.shotLogs:
    let path = state.project.dir.partOf(s.file.shotLogCopy)
    let sink = ShotLogSink()
    let job = state.jobs.submit(loadSpec(path), loadShotLog(path, s.map, sink))
    state.shotWork.add ShotLogWork(job: job, kind: sjLoad, id: -1, sink: sink,
      name: s.name, source: path, stored: s.file, map: s.map)

proc importShotLogCmd(state: var AppState; cmd: Command) =
  if cmd.logPath.len == 0:
    state.ignore(cmd, "no file was named")
    return
  let path = canonical(cmd.logPath)
  var name = path.extractFilename.splitFile.name
  if name.len == 0: name = path.extractFilename
  if name.len > MaxShotLogName: name.setLen(MaxShotLogName)
  var remembered = ShotLogMap()
  var headers: seq[string] = @[]
  var remember = false
  if not cmd.logMapped and state.inProject and state.project.doc.lastShotMap.isSome:
    let kept = state.project.doc.lastShotMap.get
    remembered = kept.map
    headers = kept.headers
    remember = true
  let sink = ShotLogSink()
  let job = state.jobs.submit(importSpec(path),
    importShotLog(path, cmd.logMap, cmd.logMapped, sink, remembered, remember, headers))
  state.shotWork.add ShotLogWork(job: job, kind: sjImport, id: -1, sink: sink,
    name: name, source: path, map: cmd.logMap)

proc removeShotLogCmd(state: var AppState; cmd: Command) =
  if cmd.logIndex < 0 or cmd.logIndex >= state.shotLogs.len:
    state.ignore(cmd, "no such shot log")
    return
  let loaded = state.shotLogs[cmd.logIndex]
  let stored = loaded.stored
  let id = loaded.id
  var kept: seq[ShotLogWork] = @[]
  for w in state.shotWork:
    if w.id == id and state.jobs.cancel(w.job): discard
    else: kept.add w
  state.shotWork = kept
  state.follow.drop(id)
  if state.stKey.log == id: state.stopShotTraces()
  state.setShotLayer(loaded, nil)
  state.shotLogs.delete(cmd.logIndex)
  inc state.shotLogsRev
  if stored.len == 0 or not state.inProject: return
  if state.readOnlyProject:
    state.log.add(sevWarning, "shot log", ReadOnlyShotLog)
    return
  var left: seq[StoredShotLog] = @[]
  for s in state.project.doc.shotLogs:
    if s.file != stored: left.add s
  state.project.doc.shotLogs = left
  state.projectChanged()
  state.submitShotDelete(stored)

proc remapShotLogCmd(state: var AppState; cmd: Command) =
  if cmd.logIndex < 0 or cmd.logIndex >= state.shotLogs.len:
    state.ignore(cmd, "no such shot log")
    return
  let loaded = state.shotLogs[cmd.logIndex]
  if loaded.busy:
    state.ignore(cmd, "the shot log is still being read")
    return
  if loaded.log == nil:
    state.ignore(cmd, "the shot log is not loaded")
    return
  loaded.undo.setLen 0
  loaded.redo.setLen 0
  loaded.busy = true
  let sink = ShotLogSink()
  let job = state.jobs.submit(remapSpec(loaded.source),
    remapShotLog(loaded.log, cmd.logMap, sink))
  state.shotWork.add ShotLogWork(job: job, kind: sjRemap, id: loaded.id, sink: sink,
    name: loaded.name, source: loaded.source, stored: loaded.stored, map: cmd.logMap)

const ShotEditCap = 1000

proc finishShotCell(state: var AppState; index: int) =
  let loaded = state.shotLogs[index]
  if loaded.stored.len > 0 and state.inProject and state.readOnlyProject:
    state.log.add(sevWarning, "shot log", ReadOnlyShotLog)
    state.submitShotRebuild(index)
  elif loaded.stored.len > 0 and state.inProject:
    state.submitShotSave(index)
  else:
    state.submitShotRebuild(index)

proc noteShotEdit(loaded: LoadedShotLog; row, col: int; before, after: string) =
  loaded.redo.setLen 0
  if before == after: return
  if loaded.undo.len >= ShotEditCap: loaded.undo.delete(0)
  loaded.undo.add ShotCellEdit(row: row, col: col, before: before, after: after)

proc shotLogReady(state: var AppState; cmd: Command): bool =
  if cmd.logIndex < 0 or cmd.logIndex >= state.shotLogs.len:
    state.ignore(cmd, "no such shot log")
    return false
  let loaded = state.shotLogs[cmd.logIndex]
  if loaded.busy:
    state.ignore(cmd, "the shot log is still being read")
    return false
  if loaded.log == nil:
    state.ignore(cmd, "the shot log is not loaded")
    return false
  true

proc editShotCellCmd(state: var AppState; cmd: Command) =
  if not state.shotLogReady(cmd): return
  let loaded = state.shotLogs[cmd.logIndex]
  let before = loaded.log.cell(cmd.logRow, cmd.logCol)
  if not loaded.log.setCell(cmd.logRow, cmd.logCol, cmd.logCell):
    state.log.add(sevWarning, "shot log", ShotLogLineBreak)
    return
  loaded.noteShotEdit(cmd.logRow, cmd.logCol, before, cmd.logCell)
  state.finishShotCell(cmd.logIndex)

proc undoShotEditCmd(state: var AppState; cmd: Command) =
  if not state.shotLogReady(cmd): return
  let loaded = state.shotLogs[cmd.logIndex]
  if loaded.undo.len == 0: return
  let step = loaded.undo[^1]
  if not loaded.log.setCell(step.row, step.col, step.before):
    state.log.add(sevWarning, "shot log", ShotLogLineBreak)
    return
  loaded.undo.setLen(loaded.undo.len - 1)
  if loaded.redo.len >= ShotEditCap: loaded.redo.delete(0)
  loaded.redo.add step
  state.finishShotCell(cmd.logIndex)

proc redoShotEditCmd(state: var AppState; cmd: Command) =
  if not state.shotLogReady(cmd): return
  let loaded = state.shotLogs[cmd.logIndex]
  if loaded.redo.len == 0: return
  let step = loaded.redo[^1]
  if not loaded.log.setCell(step.row, step.col, step.after):
    state.log.add(sevWarning, "shot log", ShotLogLineBreak)
    return
  loaded.redo.setLen(loaded.redo.len - 1)
  if loaded.undo.len >= ShotEditCap: loaded.undo.delete(0)
  loaded.undo.add step
  state.finishShotCell(cmd.logIndex)

proc headerTooLong(log: ShotLog): bool =
  ## Whether any header name is longer than a shot log's name. `columnName`
  ## has already trimmed the ends.
  if log == nil: return false
  for col in 0 ..< log.width:
    if log.columnName(col).len > MaxShotLogName: return true
  false

proc headerNamesOf(log: ShotLog; map: ShotLogMap): seq[string] =
  ## Header names of `log`, as `columnName` returns them. Empty when `map`
  ## has no header. A name longer than a shot log's name is not stored: the
  ## caller does not remember that file.
  result = @[]
  if log == nil or not map.hasHeader: return
  let n = min(log.width, MaxShotLogColumns)
  for col in 0 ..< n:
    result.add log.columnName(col)

proc settleShotMap(state: var AppState; log: ShotLog; map: ShotLogMap) =
  ## Remembers the column map a shot log ended with. A read-only project, or
  ## none, remembers nothing. A file with a header name longer than a shot
  ## log's name, after trimming, is not remembered. Removing a log does not
  ## call this.
  if not state.inProject or state.readOnlyProject: return
  if log.headerTooLong: return
  var kept = LastShotMap()
  if state.project.doc.lastShotMap.isSome:
    kept = state.project.doc.lastShotMap.get
  state.project.doc.lastShotMap = some(LastShotMap(map: map,
    headers: headerNamesOf(log, map), mapLater: kept.mapLater, later: kept.later))
  state.projectChanged()

proc tookShotImport(state: var AppState; w: ShotLogWork) =
  let r = w.sink.result
  let loaded = LoadedShotLog(id: state.nextShotId, name: w.name, source: w.source,
    map: r.map, log: r.log, view: r.view, revision: 1)
  inc state.nextShotId
  state.shotLogs.add loaded
  state.follow.keep(loaded.id, r.index)
  state.setShotLayer(loaded, r.layer)
  inc state.shotLogsRev
  state.settleShotMap(r.log, r.map)
  if r.usedLast: state.log.add(sevInfo, "shot log", ColumnsAsLast)
  state.storeOrSay(state.shotLogs.high)

proc tookShotLoad(state: var AppState; w: ShotLogWork) =
  if not state.inProject: return
  let r = w.sink.result
  let loaded = LoadedShotLog(id: state.nextShotId, name: w.name, source: w.source,
    stored: w.stored, map: r.map, log: r.log, view: r.view, revision: 1)
  inc state.nextShotId
  state.shotLogs.add loaded
  state.follow.keep(loaded.id, r.index)
  state.setShotLayer(loaded, r.layer)
  inc state.shotLogsRev

proc tookShotSave(state: var AppState; w: ShotLogWork) =
  let i = state.findShot(w.id)
  if i < 0:
    state.submitShotDelete(w.stored)
    return
  let loaded = state.shotLogs[i]
  loaded.busy = false
  if w.sink.result.ok:
    state.follow.keep(loaded.id, w.sink.result.index)
    state.setShotLayer(loaded, w.sink.result.layer)
    loaded.view = w.sink.result.view
    inc loaded.revision
    inc state.shotLogsRev
  if not state.inProject or state.readOnlyProject: return
  var found = false
  for s in state.project.doc.shotLogs.mitems:
    if s.file == w.stored:
      s.map = w.map
      s.name = w.name
      found = true
  if not found:
    state.project.doc.shotLogs.add StoredShotLog(name: w.name, file: w.stored, map: w.map)
  state.projectChanged()

proc tookShotRemap(state: var AppState; w: ShotLogWork) =
  let i = state.findShot(w.id)
  if i < 0: return
  let loaded = state.shotLogs[i]
  loaded.busy = false
  let r = w.sink.result
  state.follow.keep(loaded.id, r.index)
  state.setShotLayer(loaded, r.layer)
  loaded.log = r.log
  loaded.view = r.view
  loaded.map = r.map
  inc loaded.revision
  inc state.shotLogsRev
  state.settleShotMap(r.log, r.map)
  if r.dropped: state.log.add(sevWarning, "shot log", ShotLogEditsDropped)
  if loaded.stored.len == 0 or not state.inProject: return
  if state.readOnlyProject:
    state.log.add(sevWarning, "shot log", ReadOnlyShotLog)
  else:
    state.submitShotSave(i)

proc tookShotRebuild(state: var AppState; w: ShotLogWork) =
  let i = state.findShot(w.id)
  if i < 0: return
  let loaded = state.shotLogs[i]
  loaded.busy = false
  if w.sink.result.ok:
    state.follow.keep(loaded.id, w.sink.result.index)
    state.setShotLayer(loaded, w.sink.result.layer)
    loaded.view = w.sink.result.view
    inc loaded.revision
    inc state.shotLogsRev

proc takeShotLog(state: var AppState; job: JobInfo): bool =
  ## A shot log's job ended. The sink is read only here, after the job ended.
  ## A cancel leaves it unread. True when `job` was one.
  var at = -1
  for i, w in state.shotWork:
    if w.job == job.id: at = i
  if at < 0: return false
  result = true
  let w = state.shotWork[at]
  state.shotWork.delete(at)
  if job.state == jsCancelled:
    let i = state.findShot(w.id)
    if i >= 0: state.shotLogs[i].busy = false
    return
  if job.state != jsDone or w.sink == nil or not w.sink.result.ok:
    let i = state.findShot(w.id)
    if i >= 0: state.shotLogs[i].busy = false
    let why = if w.sink != nil and w.sink.result.reason.len > 0: w.sink.result.reason
              elif job.error.len > 0: job.error else: "The shot log could not be read."
    state.log.add(sevError, "shot log", if why.endsWith('.'): why else: why & ".")
    return
  case w.kind
  of sjImport: state.tookShotImport(w)
  of sjLoad: state.tookShotLoad(w)
  of sjSave: state.tookShotSave(w)
  of sjRemap: state.tookShotRemap(w)
  of sjRebuild: state.tookShotRebuild(w)
  of sjDelete: discard

proc clearSession(state: var AppState) =
  ## Every open file closed, the survey files taken off the map, an import
  ## under way cancelled: a project begins, or ends, with nothing of before.
  state.dropShotLogs()
  if state.joining.job != NoJob: discard state.jobs.cancel(state.joining.job)
  if state.movesJob != NoJob: discard state.jobs.cancel(state.movesJob)
  if state.leapJob != NoJob: discard state.jobs.cancel(state.leapJob)
  if state.cutJob != NoJob: discard state.jobs.cancel(state.cutJob)
  if state.spsJob != NoJob: discard state.jobs.cancel(state.spsJob)
  if state.oJob != NoJob: discard state.jobs.cancel(state.oJob)
  if state.recJob != NoJob: discard state.jobs.cancel(state.recJob)
  state.recJob = NoJob
  state.stopShotTraces()
  state.recHave = false
  state.recWhy = ""
  if state.vfJob != NoJob: discard state.jobs.cancel(state.vfJob)
  state.vfJob = NoJob
  state.vfLists.setLen 0
  state.moveQueue.setLen 0
  state.leapQueue.setLen 0
  state.moveBases.setLen 0
  for x in state.loading:
    if x.session == NoSession:
      discard state.jobs.cancel(x.job)
      state.droppedLoads.add x.job
  for o in state.opening.mitems: o.unwanted = true
  while state.sessions.len > 0: state.closeSession(state.sessions.high, quiet = true)
  var ids: seq[SurveyLayerId] = @[]
  for i in 0 ..< state.survey.layers.len:
    if state.survey.layers[i].origin == loSurveyFile: ids.add state.survey.layers[i].id
  for id in ids: discard state.survey.remove(id)
  state.map.followed(state.survey)

proc releaseLock(state: var AppState) =
  ## Lets the project's lock go, on a job (a close on a share may wait).
  if state.project.lock.locked:
    discard state.jobs.submit(JobSpec(title: "Let the project go", lane: jlInteractive,
      cancellable: false), unlockWork(stageRelease(state.project.dir, state.project.lock)))
    state.project.lock = FileLock()

proc leaveProject(state: var AppState; restoreUser: bool) =
  ## Writes what the project open has pending (its document, its files'
  ## edits, its window arrangement), closes its files and survey, lets its
  ## lock go and goes back to the program's own store, presets and filters;
  ## with `restoreUser`, to the user's own window arrangement.
  template p: untyped = state.project
  if p.dir.len == 0: return
  state.saveProject()
  if state.layoutSaved != state.layoutRev: state.saveArrangement()
  if p.surveyJob != NoJob and p.survey == srKeeping and p.doc.hasImport:
    state.log.add(sevWarning, "project", "The survey was still being copied into the project " &
      p.doc.name & ": the copy stops here, and is taken up when the project is next opened.")
  state.clearSession()
  state.forgetFileMemory()
  for job in [p.surveyJob, p.lookJob, p.originalsJob]:
    if job != NoJob: discard state.jobs.cancel(job)
  state.releaseLock()
  state.store = Store(home: state.userStore)
  state.refsHome = state.mainRefsHome
  state.refs = state.mainRefs
  state.refsLoaded = state.mainRefsLoaded
  state.chosenRef = state.settings.referenceId
  state.vibLayouts = state.settings.vibRoles
  inc state.refsRev
  var s = state.settings
  if p.doc.hasPresets: s.displayPresets = p.userPresets
  if p.doc.hasProcessing: s.plot.processing = p.userProcessing
  if p.doc.hasBreakModel: s.plot.display.breakModel = p.userBreakModel
  state.takeSettings(s)
  if restoreUser and p.userArrangement.len > 0:
    state.loaded = Layout(imgui: p.userArrangement)
    inc state.loads
    state.arrangement = p.userArrangement
    state.layoutSaved = state.layoutRev # the user's own, as saved
  let (job, jobDir, jobBy) = (p.job, p.jobDir, p.jobBy)
  state.project = ProjectState(job: job, jobDir: jobDir, jobBy: jobBy, surveyJob: NoJob,
    lookJob: NoJob, originalsJob: NoJob)

proc openProject(state: var AppState; dir: string; by: CommandOrigin; make = false;
    np = NewProject(); useSurvey = false) =
  ## Opens (with `make`, first makes) the project in folder `dir`, on a job
  ## (`openProjectWork`); `takeOpened` takes it in.
  template p: untyped = state.project
  if p.job != NoJob:
    state.log.add(sevWarning, "project", "The project " & p.jobDir.untitled & " is being " &
      "opened; " & dir.untitled & " waits until it is (one at a time).")
    return
  if not make and p.dir == dir:
    state.log.add(sevInfo, "project", "The project " & p.doc.name & " is open already.")
    return
  p.job = state.jobs.submit(JobSpec(title: (if make: "Make the project " else:
    "Open the project ") & dir.untitled, lane: jlInteractive),
    openProjectWork(dir, state.inbox.poster, make, np, addr state.disk))
  (p.jobDir, p.jobBy, p.useSurvey) = (dir, by, useSurvey)

proc restoreSurvey(state: var AppState; layers: bool) =
  ## Makes the project's survey from its `survey.bin` (`restoreWork`), with
  ## `layers` its map's layers too.
  template p: untyped = state.project
  p.survey = srLoading
  p.surveyJob = state.jobs.submit(JobSpec(title: "Load the project's survey",
    lane: jlBackground, exclusive: @[p.dir.partOf(SurveyFolder)]),
    restoreWork(p.dir, p.doc, layers, state.inbox.poster))
  inc p.revision

proc keepSurvey(state: var AppState; files: seq[JoinFile]; resume: seq[ImportFile] = @[]) =
  ## Copies survey files `files` into the project and writes its
  ## `survey.bin` (`keepSurveyWork`).
  template p: untyped = state.project
  if p.surveyJob != NoJob: discard state.jobs.cancel(p.surveyJob)
  p.survey = srKeeping
  let found = p.folders.filterIt(it.state == psFound).mapIt(it.path)
  p.surveyJob = state.jobs.submit(JobSpec(title: "Keep the survey in the project",
    lane: jlBackground, exclusive: @[p.dir.partOf(SurveyFolder)]), keepSurveyWork(p.dir, files,
    p.doc.survey, state.inbox.poster, resume, found))
  inc p.revision

proc markImporting(state: var AppState; files: seq[JoinFile]) =
  ## Writes the import to the project document at once (its files, as
  ## their originals, with the options and units): a close or a quit before
  ## the copy is whole leaves it there, and the next open copies it.
  template p: untyped = state.project
  p.doc.importing.setLen 0
  for f in files:
    if p.doc.importing.len < 4096:
      p.doc.importing.add ImportFile(kind: f.kind, role: f.role, original: placeOf(p.dir, f.path))

proc keepImport(state: var AppState) =
  ## The import ending now, the user's, kept in the project open: its files
  ## copied in, its options and units; its geometry joins the files opened
  ## next.
  template j: untyped = state.joining
  template p: untyped = state.project
  if p.dir.len == 0 or p.readOnly or not keeps(j.by) or
      j.outcome notin {joJoined, joNothing, joMapOnly}:
    return
  p.doc.options = j.options
  p.doc.units = j.units
  p.doc.notes = j.survey.notes
  p.doc.imported = getTime()
  if not j.geometry.isNil and j.relations.isNil: # (stations and relations in one)
    p.geometry = j.geometry
    p.joinSurvey = j.survey
  state.markImporting(j.files)
  state.projectChanged()
  state.keepSurvey(j.files)
  state.log.add(sevInfo, "project", "The survey (" & fileNames(j.files) & ") is being copied " &
    "into the project " & p.doc.name & ": it is not imported again. If the project is closed " &
    "or the program quits first, the copy is taken up at the next open.")

proc lookAtOriginals(state: var AppState) =
  ## Looks at the survey originals on a job of the hashes' lane, with
  ## progress and a cancel (`originalsWork`): no open waits for them.
  template p: untyped = state.project
  if p.originalsJob != NoJob: discard state.jobs.cancel(p.originalsJob)
  if p.doc.survey.len == 0:
    p.originals.setLen 0
    return
  p.originals = p.doc.survey.mapIt(OriginalLook(state: osLooking))
  p.originalsJob = state.jobs.submit(JobSpec(title: "Look at the survey's original files",
    lane: jlOriginals), originalsWork(p.dir, p.doc, state.inbox.poster))
  inc p.revision

proc lookAgain(state: var AppState) =
  template p: untyped = state.project
  if p.lookJob != NoJob: discard state.jobs.cancel(p.lookJob)
  p.lookJob = state.jobs.submit(JobSpec(title: "Look at the project's folders",
    lane: jlInteractive), lookWork(p.dir, p.doc, state.inbox.poster))

proc sayOriginals(state: var AppState) =
  ## Says which survey originals changed since they were copied in, and
  ## offers "Update from the original" (never done unasked).
  template p: untyped = state.project
  var changed: seq[string] = @[]
  for i, o in p.originals:
    if o.state == osChanged and i < p.doc.survey.len: changed.add o.path.extractFilename
  p.offer = changed.len > 0 and not p.readOnly
  if changed.len > 0:
    state.log.add(sevWarning, "project", (if changed.len == 1: changed[0] & " has" else:
      changed.join(", ") & " have") & " changed since " & (if changed.len == 1: "it was" else:
      "they were") & " copied into the project " & p.doc.name & "; the project uses its " &
      "copy until you choose Update from the original (the Project window).")

proc vendorFolders(state: AppState): seq[VendorFolder] =
  ## The folders the maps are loaded from, in order of preference: the
  ## project's, then those the frontend gave.
  if state.project.dir.len > 0:
    result.add VendorFolder(dir: state.project.dir.partOf(VendorFolderName), origin: voProject)
  result.add state.vendor.folders

proc reloadVendorMaps(state: var AppState; loud = false) =
  ## Reads the vendor header maps again, on a job; `takeVendor` takes them in.
  ## A load that says what the one before did (a project opened without maps of
  ## its own) is quiet unless it was asked for (`loud`).
  state.vendor.loud = loud
  inc state.vendor.asked
  state.vendor.job = state.jobs.submit(JobSpec(title: "Read the vendor header maps",
    lane: jlInteractive), vendorWork(state.vendorFolders, state.vendor.asked,
    state.inbox.poster))

proc setVendorFolders*(state: var AppState; folders: sink seq[VendorFolder]) =
  ## The folders to load vendor header maps from besides the project's (the
  ## user's settings folder, beside the program, the environment's), in order
  ## of preference; loads them.
  state.vendor.folders = folders
  state.reloadVendorMaps()

func missingMap(state: AppState): bool =
  ## The project names a vendor map that is not among those loaded.
  if state.vendor.choice.mode != vmNamed: return false
  for m in state.vendor.load.maps:
    if m.name == state.vendor.choice.name: return false
  true

func missingWords(state: AppState): string =
  "The project's vendor map " & state.vendor.choice.name & " is not among the vendor " &
    "header maps loaded: no vendor block is decoded in this project, and the choice is " &
    "kept (it is used again when the map is there)."

proc rereadKinds(state: var AppState)

proc refetchVendorLines(state: var AppState) =
  ## The panels with a vendor field on a display line read it again: the maps
  ## it was read with are not the ones in force (the reader drops its columns).
  for k in 0 ..< state.panels.len:
    if state.panels[k].layers.len > 0 and
        state.panels[k].layers[0].order.anyIt(it.field == hfVendor):
      state.reorder(k) # the sort reads the columns again, then the view is asked for
    elif state.panels[k].shownFields.anyIt(it.field == hfVendor):
      state.refetch(k, keepTiles = true)

proc takeVendor(state: var AppState; m: sink Msg) =
  ## A load of the vendor maps: made the registry in force under the project's
  ## rule, and said in a line of Messages each (what it loaded, what it left
  ## out, and why).
  if m.vendorGen < state.vendor.asked: return # a newer load is on its way
  state.vendor.job = NoJob
  state.vendor.load = move m.vendorLoad
  inc state.vendor.gen
  template load: untyped = state.vendor.load
  publishVendors(load.registry, state.vendor.choice)
  state.refetchVendorLines()
  state.rereadKinds()
  state.vendor.mismatched.setLen 0
  var said: seq[(Severity, string, string)] = @[]
  if load.maps.len > 0:
    said.add (sevInfo, load.summaryLine & ".", "")
  elif load.folders.len > 0:
    said.add (sevInfo, "No vendor header maps found (looked in " & load.foldersText &
      "): the vendor blocks of a file stay as bytes.", "")
  for p in load.problems: said.add (sevWarning, p.problemLine, p.file)
  for line in load.shadowed: said.add (sevInfo, "The vendor header map " & line & ".", "")
  if state.missingMap: said.add (sevWarning, state.missingWords, "")
  var signature = ""
  for (_, text, _) in said: signature.add text & "\n"
  if state.vendor.loud or signature != state.vendor.lastSaid:
    for (severity, text, file) in said:
      # (no map anywhere is said once, however many loads find none)
      if text.startsWith("No vendor header maps found") and state.vendor.saidNone: continue
      state.log.add(severity, "vendor maps", text, Location(file: file))
  state.vendor.saidNone = load.maps.len == 0
  state.vendor.lastSaid = signature

proc storeVibProfile(state: var AppState; origin: CommandOrigin; p: VibQcProfile) =
  ## Keeps `p` in the project's document when the user asked and the project
  ## can be written. `profileNoted` is set when the document accepts it,
  ## including when the stored profile is already `p`.
  if not state.inProject:
    state.log.add(sevWarning, "vibrator QC",
      "No project is open: the vibrator QC profile was not stored.")
    return
  if not keeps(origin):
    state.log.add(sevWarning, "vibrator QC",
      "This change is for this run only: the vibrator QC profile was not stored.")
    return
  if state.project.readOnly:
    state.log.add(sevWarning, "vibrator QC",
      "The project is read-only: the vibrator QC profile was not stored.")
    return
  if not state.project.doc.hasVibProfile or state.project.doc.vibProfile != p:
    state.project.doc.vibProfile = p
    state.project.doc.hasVibProfile = true
    state.projectChanged()
  state.profileNoted = true

proc storeVibWeights(state: var AppState; origin: CommandOrigin; w: VibJobWeights) =
  ## Keeps `w` in the project's document when the user asked and the project
  ## can be written. A NaN weight is not set. The core compares these with a
  ## file's header and never applies them.
  if not state.inProject:
    state.log.add(sevWarning, "vibrator QC",
      "No project is open: the vibrator QC weights were not stored.")
    return
  if not keeps(origin):
    state.log.add(sevWarning, "vibrator QC",
      "This change is for this run only: the vibrator QC weights were not stored.")
    return
  if state.project.readOnly:
    state.log.add(sevWarning, "vibrator QC",
      "The project is read-only: the vibrator QC weights were not stored.")
    return
  if state.project.doc.vibJobWeights != w:
    state.project.doc.vibJobWeights = w
    state.projectChanged()

proc setVendorChoice(state: var AppState; origin: CommandOrigin; c: VendorChoice) =
  ## The project's rule for the vendor maps: kept in its document when the user
  ## chose it (an agent's is for the session), used from now on by every file.
  if c == state.vendor.choice: return
  state.vendor.choice = c
  if keeps(origin) and not state.project.readOnly:
    state.project.doc.vendorChoice = c
    state.projectChanged()
  elif keeps(origin):
    state.log.add(sevWarning, "vendor maps", "The project is read-only: this choice is for " &
      "this run only.")
  publishVendors(state.vendor.load.registry, c)
  state.refetchVendorLines()
  state.vendor.mismatched.setLen 0
  inc state.vendor.gen
  state.rereadKinds()
  state.log.add(sevInfo, "vendor maps", (case c.mode
    of vmAutomatic: "The project's vendor map is automatic: every map loaded is offered, the " &
      "most specific that matches a file decodes it."
    of vmNone: "The project uses no vendor map: no vendor block is decoded."
    of vmNamed: "The project uses the vendor map " & c.name & " alone."))
  if state.missingMap: state.log.add(sevWarning, "vendor maps", state.missingWords)

func vendorLoad*(state: AppState): lent VendorLoad {.inline.} =
  ## The vendor maps loaded, what they apply to and what went wrong.
  state.vendor.load

func vendorChoice*(state: AppState): VendorChoice {.inline.} =
  ## The project's rule for the vendor maps; automatic outside a project.
  state.vendor.choice

func vendorGen*(state: AppState): int {.inline.} =
  ## How many loads of the maps were taken in; a decode made with an earlier one is stale.
  state.vendor.gen

proc takeOpened(state: var AppState; m: sink Msg) =
  ## A project opened (or made) by its job: the session becomes its own.
  template p: untyped = state.project
  template news: untyped = m.news
  if m.job != p.job:
    if news.lock.locked:
      discard state.jobs.submit(JobSpec(title: "Let the project go", lane: jlInteractive,
        cancellable: false), unlockWork(stageRelease(news.dir, news.lock)))
    return
  p.job = NoJob
  let by = p.jobBy
  let useSurvey = p.useSurvey
  let dir = news.dir
  if news.failure.len > 0:
    state.log.add(sevError, "project", "Cannot " & (if news.created: "make" else: "open") &
      " the project " & dir & ": " & news.failure & ".")
    return
  let wasIn = p.dir.len > 0
  let userArrangement = if wasIn: p.userArrangement else: state.arrangement
  let userPresets = if wasIn and p.doc.hasPresets: p.userPresets else: state.settings.displayPresets
  let userProcessing = if wasIn and p.doc.hasProcessing: p.userProcessing
                       else: state.settings.plot.processing
  let userBreakModel = if wasIn and p.doc.hasBreakModel: p.userBreakModel
                       else: state.settings.plot.display.breakModel
  if wasIn: state.leaveProject(restoreUser = false)
  elif not news.created:
    state.saveProject()
    if state.layoutSaved != state.layoutRev: state.saveArrangement() # the user's own
    state.clearSession()
    state.forgetFileMemory()
  elif state.layoutSaved != state.layoutRev: state.saveArrangement()
  if news.created and wasIn: discard
  elif news.created: state.saveMemory(getMonoTime(), force = true)
  p = ProjectState(dir: dir, doc: move news.doc, lock: news.lock, owner: news.owner,
    folders: move news.folders, originals: move news.originals, by: by,
    userArrangement: userArrangement, userPresets: userPresets,
    userProcessing: userProcessing, userBreakModel: userBreakModel, surveyJob: NoJob,
    lookJob: NoJob, originalsJob: NoJob, job: NoJob)
  p.readOnly = not p.lock.locked or p.doc.version > ProjectVersion
  p.whyReadOnly = if not p.lock.locked and p.lock.failure.len > 0:
                    "the project's lock file cannot be opened (" & p.lock.failure & ")"
                  elif not p.lock.locked: news.owner.words & " has it open"
                  elif p.doc.version > ProjectVersion: "a newer viewSEG made it"
                  else: ""
  inc p.revision
  state.store = Store(home: dir / ProjectStoreFolder)
  if not p.readOnly: state.diskIo.sweep(state.store.home, ProgramStart)
  if state.refsHome == state.mainRefsHome:
    state.mainRefs = state.refs
    state.mainRefsLoaded = state.refsLoaded
  state.refsHome = referencesFolder(dir)
  state.refs = ReferenceIndex()
  state.refsLoaded = false
  state.chosenRef = p.doc.referenceId
  state.vibLayouts = p.doc.vibRoles
  inc state.refsRev
  state.loadReferences(state.refsHome, main = false)
  state.change(by, s):
    s.recentProjects.addRecent(dir, MaxRecent)
    s.lastProject = dir
  var s = state.settings
  if p.doc.hasPresets: s.displayPresets = p.doc.displayPresets
  if p.doc.hasProcessing: s.plot.processing = p.doc.processing
  if p.doc.hasBreakModel: s.plot.display.breakModel = p.doc.breakModel
  state.takeSettings(s)
  if news.layout.len > 0:
    state.loaded = Layout(imgui: news.layout)
    inc state.loads
    state.arrangement = news.layout
    state.layoutSaved = state.layoutRev
  elif not p.readOnly and state.arrangement.len > 0:
    inc state.layoutRev # the windows as they are, the project's own from now on
    state.layoutAt = getMonoTime()
  state.logProblems("project", news.problems)
  state.vendor.choice = p.doc.vendorChoice
  state.reloadVendorMaps()
  state.log.add(sevInfo, "project", (if news.created: "Made the project " else:
    "Opened the project ") & p.doc.name & " (" & dir & ")" &
    (if p.readOnly: ", read-only: " & p.whyReadOnly & "; nothing is written to it" else: "") &
    (if news.brought > 0: "; what is remembered about " & $news.brought &
      (if news.brought == 1: " file" else: " files") & " was copied into it" else: "") & ".")
  var missing: seq[string] = @[]
  var first = ""
  for i, f in p.folders:
    if f.state == psFound and first.len == 0: first = f.path
    elif f.state == psMissing and i < p.doc.data.len: missing.add p.doc.data[i].displayName
  if missing.len > 0:
    state.log.add(sevWarning, "project", "The data " & (if missing.len == 1: "folder " &
      missing[0] & " is" else: "folders " & missing.join(", ") & " are") & " not where the " &
      "project last found " & (if missing.len == 1: "it" else: "them") & ": Locate... in the " &
      "Project window says where " & (if missing.len == 1: "it is" else: "they are") & " now.")
  if not news.created and first.len > 0:
    # the folder the Files panel listed last in this project, else its first data folder
    # (the scan finds out whether the last one is still there)
    let start = p.lastFolderStart(first)
    state.lastFolderTried = (start, if start != first: first else: "")
    state.startListing(@[start], start, "", by)
  state.lookAtOriginals()
  if p.doc.hasImport:
    # An import was being copied in when the project was closed or the
    # program quit: copied again from the originals.
    if p.readOnly:
      p.survey = srFailed
      p.surveyNote = "a survey was being copied in, and the project is read-only"
    else:
      var files: seq[JoinFile] = @[]
      for f in p.doc.importing: files.add JoinFile(kind: f.kind, role: f.role)
      p.layersAfterKeep = true
      state.log.add(sevInfo, "project", "The survey of the project " & p.doc.name & " was " &
        "being copied in when it was last open: it is copied again now.")
      state.keepSurvey(files, p.doc.importing)
  elif p.doc.hasSurvey:
    if news.storeThere: state.restoreSurvey(layers = true)
    else:
      # The survey kept is not there (a copy without it): made again from the copies.
      var files: seq[JoinFile] = @[]
      for c in p.doc.survey:
        files.add JoinFile(path: dir.partOf(c.copy), kind: c.kind, role: c.role)
      if p.readOnly:
        p.survey = srFailed
        p.surveyNote = "survey.bin is not there, and the project is read-only"
        state.drainProjectMoves()
      else:
        p.layersAfterKeep = true
        state.keepSurvey(files)
  if news.created and useSurvey:
    var files: seq[JoinFile] = @[]
    for i in 0 ..< state.survey.layers.len:
      template l: untyped = state.survey.layers[i]
      if l.origin == loSurveyFile:
        files.add JoinFile(path: l.path, kind: if l.kind == fkP1: jkP1 else: jkSps)
    if files.len > 0:
      p.doc.options = state.settings.join
      if state.joins.len > 0:
        template last: untyped = state.joins[^1]
        p.doc.units = last.units
        p.doc.notes = last.survey.notes
        if not last.geometry.isNil and last.relations.isNil:
          p.geometry = last.geometry
          p.joinSurvey = last.survey
      p.doc.imported = getTime()
      if p.readOnly:
        state.log.add(sevWarning, "project", "The survey is not kept in the project " &
          p.doc.name & ": it is open read-only (" & p.whyReadOnly & ").")
      else:
        state.markImporting(files)
        state.projectChanged()
        state.keepSurvey(files)
  if news.created:
    for s in state.sessions:
      if state.surveyMatchable and state.joinedOf(s.id) < 0: p.queue.add s.id
    state.queueOpenMoves()
  if news.created and not wasIn: state.dropShotLogs()
  state.loadStoredShotLogs()

proc takeKept(state: var AppState; m: sink Msg) =
  ## The survey copied into the project and `survey.bin` written.
  template p: untyped = state.project
  template news: untyped = m.news
  if m.job != p.surveyJob or news.dir != p.dir: return
  p.surveyJob = NoJob
  inc p.revision
  let layers = p.layersAfterKeep
  p.layersAfterKeep = false
  if news.keptFailure.len > 0:
    p.rebuilding = false
    # An update that was refused leaves the survey as it was, on the map.
    p.survey = if news.updated and not p.geometry.isNil: srLoaded else: srFailed
    p.surveyNote = news.keptFailure
    if p.doc.hasImport: # not taken up again at every open: the user imports it again
      p.doc.importing.setLen 0
      state.projectChanged()
    state.log.add(sevError, "project", "The survey could not be kept in the project " &
      p.doc.name & ": " & news.keptFailure & ".")
    if p.survey == srFailed: state.drainProjectMoves()
    return
  var gone: seq[string] = @[]
  if not news.updated:
    for c in p.doc.survey:
      if news.copies.allIt(it.copy != c.copy): gone.add c.copy.extractFilename
  let before = p.doc.store
  p.doc.survey = move news.copies
  p.doc.store = news.store
  p.doc.importing.setLen 0
  state.projectChanged()
  if gone.len > 0:
    var said = "No longer in the survey: " & gone.join(", ") & "."
    if before.splitKnown and before.relations > 0 and news.store.relations == 0:
      said.add " The survey now has no X records."
    if before.splitKnown and before.receiverRelations > 0 and news.store.receiverRelations == 0:
      said.add " The survey now has no O records."
    state.log.add(sevWarning, "project", said)
  state.log.add(sevInfo, "project", (if news.updated: "The survey files that changed were " &
    "copied into the project again; the survey" else: "The survey") & " is kept in the project " &
    p.doc.name & " (" & $p.doc.survey.len & (if p.doc.survey.len == 1: " file" else: " files") &
    ", " & formatSize(news.store.bytes, includeSpace = true) & ").")
  state.lookAgain()
  state.lookAtOriginals() # its originals, as copied now
  if news.updated: state.restoreSurvey(layers = true)
  elif p.geometry.isNil or p.rebuilding: state.restoreSurvey(layers = layers)
  else: p.survey = srLoaded
  for s in state.sessions:
    if state.joinedOf(s.id) < 0 and s.id notin p.queue: p.queue.add s.id

proc takeRestored(state: var AppState; m: sink Msg) =
  ## The project's survey made from `survey.bin`: every open file not
  ## matched yet is matched to it.
  template p: untyped = state.project
  template news: untyped = m.news
  if m.job != p.surveyJob or news.dir != p.dir: return
  p.surveyJob = NoJob
  inc p.revision
  if news.surveyFailure.len > 0 or news.geometry.isNil:
    if p.doc.hasSurvey and not p.readOnly and not p.rebuilding:
      # survey.bin is rejected (damaged, cut short, of a newer format), but
      # the copies are in the project: it is made again from them.
      p.rebuilding = true
      p.layersAfterKeep = true
      var files: seq[JoinFile] = @[]
      for c in p.doc.survey:
        files.add JoinFile(path: p.dir.partOf(c.copy), kind: c.kind, role: c.role)
      state.log.add(sevWarning, "project", "The survey kept in the project " & p.doc.name &
        " could not be read (" & news.surveyFailure & "): it is made again from the copies " &
        "of the survey files in the project.")
      state.keepSurvey(files)
      return
    p.rebuilding = false
    p.survey = srFailed
    p.surveyNote = news.surveyFailure
    state.log.add(sevError, "project", "The survey kept in the project " & p.doc.name &
      " could not be read: " & news.surveyFailure & ". Import the survey again.")
    state.drainProjectMoves()
    return
  p.rebuilding = false
  let updated = not p.geometry.isNil
  p.geometry = move news.geometry
  p.joinSurvey = move news.survey
  p.survey = srLoaded
  p.restoreMs = news.restoreMs
  state.log.add(sevInfo, "project", "The project's survey is ready (" &
    $p.joinSurvey.stations[prSource] & " sources, " & $p.joinSurvey.stations[prReceiver] &
    " receivers, " & $p.joinSurvey.xRelations & " X records, " & $p.joinSurvey.oRelations &
    " O records), made from what the " &
    "project keeps in " & formatFloat(p.restoreMs, ffDecimal, 1) & " ms: no survey file was read.")
  for s in state.sessions:
    if (updated or state.joinedOf(s.id) < 0) and s.id notin p.queue: p.queue.add s.id

proc takeProject(state: var AppState; m: sink Msg) =
  case m.news.kind
  of pnOpened: state.takeOpened(move m)
  of pnKept: state.takeKept(move m)
  of pnSurvey: state.takeRestored(move m)
  of pnLooked:
    template p: untyped = state.project
    if m.job == p.lookJob and m.news.dir == p.dir:
      p.lookJob = NoJob
      p.folders = move m.news.folders
      inc p.revision
  of pnImporting:
    template p: untyped = state.project
    if m.job == p.surveyJob and m.news.dir == p.dir and p.doc.hasImport and not p.readOnly:
      # what the originals were when the copy began: the document keeps it,
      # for an open that finds the copy cut short
      for i, f in m.news.identities:
        if i < p.doc.importing.len and p.doc.importing[i].original.path == f.original.path and
            p.doc.importing[i].original.absolute == f.original.absolute:
          p.doc.importing[i] = f
      state.projectChanged()
  of pnOriginals:
    template p: untyped = state.project
    if m.job == p.originalsJob and m.news.dir == p.dir:
      p.originalsJob = NoJob
      p.originals = move m.news.originals
      # An original whose time moved but whose content is the copy's: the new
      # time is recorded, so that no later open reads it whole again.
      for i, o in p.originals:
        if i < p.doc.survey.len and not p.readOnly:
          if o.confirmed and p.doc.survey[i].modified != o.modified:
            p.doc.survey[i].modified = o.modified
            state.projectChanged()
          elif o.readChanged and p.doc.survey[i].changedModified != o.modified:
            # found changed by reading it whole: not read again until it moves
            p.doc.survey[i].changedModified = o.modified
            state.projectChanged()
      inc p.revision
      state.sayOriginals()

proc endProjectWork(state: var AppState; job: JobInfo): bool =
  ## A project's job that ended without posting (failed or cancelled):
  ## said, and forgotten.
  template p: untyped = state.project
  result = true
  if job.id == p.job:
    p.job = NoJob
    if job.state == jsFailed:
      state.log.add(sevError, "project", "Cannot open the project " & p.jobDir & ": " &
        job.error & ".")
  elif job.id == p.surveyJob:
    p.surveyJob = NoJob
    if job.state in {jsFailed, jsCancelled}:
      p.survey = if job.state == jsFailed: srFailed else: srNone
      p.surveyNote = job.error
      inc p.revision
      if job.state == jsFailed:
        state.log.add(sevError, "project", "The project's survey: " & job.error & ".")
        state.drainProjectMoves()
  elif job.id == p.lookJob: p.lookJob = NoJob
  elif job.id == p.originalsJob:
    p.originalsJob = NoJob
    if job.state == jsFailed:
      state.log.add(sevWarning, "project", "The survey's original files could not be looked " &
        "at: " & job.error & ".")
  else: result = false

proc startAutoJoin(state: var AppState; i: int) =
  ## Matches open file `sessions[i]` to the project's survey, as the import
  ## does, from the geometry made already (`planWork`): no window, no survey
  ## file read.
  template p: untyped = state.project
  let s = state.sessions[i]
  var files: seq[JoinFile] = @[]
  for c in p.doc.survey: files.add JoinFile(path: p.dir.partOf(c.copy), kind: c.kind, role: c.role)
  let job = state.jobs.submit(JobSpec(title: "Match " & s.name & " to the project's survey",
    lane: jlInteractive, reads: @[s.path]), planWork(s.filePtr, s.id, addr p.geometry[],
    p.joinSurvey.files, p.doc.notes, p.doc.options, state.inbox.poster))
  state.joining = Joining(job: job, step: jpReading, session: s.id, path: s.path, name: s.name,
    files: files, options: p.doc.options, units: p.doc.units, geometry: p.geometry,
    survey: p.joinSurvey, auto: true, by: coWindow)

proc queueOpenMoves(state: var AppState) =
  ## Has every open file take the project's station moves. A project whose
  ## survey can still be matched is joined again, so the survey is applied
  ## and the moves win after it; a file with no survey, or one whose survey
  ## failed to be restored, gets a job of its own. A file whose join is
  ## still reading is left: that join reads the list when it applies.
  let moves = state.project.doc.stationMoves
  let matchable = state.surveyMatchable
  for s in state.sessions:
    if s.isSignature or s.noSeismic: continue
    if moves.len == 0 and state.moveBasesOf(s.id).len == 0: continue
    if matchable:
      if state.joining.job != NoJob and state.joining.session == s.id and
          state.joining.step == jpReading: continue
      state.moveQueue.keepItIf(it != s.id)
      if s.id notin state.project.queue: state.project.queue.add s.id
    else:
      state.enqueueMoves(s.id)

proc setStationMoves*(state: var AppState; moves: StationMoves) =
  ## Replaces the project's station moves and has every open file take them.
  ## A project with a folder records the change; without one the list is kept
  ## for this run. Never reads a file on this thread.
  assertUiThread()
  state.project.doc.stationMoves = moves
  if state.project.dir.len > 0 and not state.project.readOnly: state.projectChanged()
  elif state.project.dir.len > 0:
    state.log.add(sevWarning, "project", "The project is read-only: the station moves are for " &
      "this run only.")
  state.queueOpenMoves()

proc followMoves(state: var AppState) =
  ## The next open file takes the project's station moves, once no import and
  ## no other move job runs. A file a project survey can still match is left
  ## on that queue instead.
  if state.movesJob != NoJob or state.importing or state.leapJob != NoJob: return
  while state.moveQueue.len > 0:
    let id = state.moveQueue[0]
    state.moveQueue.delete(0)
    let i = state.findSession(id)
    if i < 0: continue
    let s = state.sessions[i]
    if s.isSignature or s.noSeismic: continue
    if state.surveyMatchable:
      if id notin state.project.queue: state.project.queue.add id
      continue
    let moves = state.project.doc.stationMoves
    let bases = state.moveBasesOf(id)
    if moves.len == 0 and bases.len == 0: continue
    state.pauseMoveReaders(s.path)
    state.movesSession = id
    state.movesDone = false
    state.movesChanged = 0
    state.movesJob = state.jobs.submit(JobSpec(title: "Apply station moves for " & s.name,
      lane: jlInteractive, exclusive: @[s.path]), movesApplyWork(s.filePtr, s.path, s.id, moves,
      bases, state.jobs.holdRelease, state.inbox.poster))
    return

proc followProject(state: var AppState) =
  ## After every command and drained inbox: the next file opened in the
  ## project is matched to its survey, once no import runs and no station-move
  ## job holds a file.
  template p: untyped = state.project
  if p.dir.len == 0 or p.geometry.isNil or state.importing or state.movesJob != NoJob or
      state.leapJob != NoJob: return
  while p.queue.len > 0:
    let id = p.queue[0]
    p.queue.delete(0)
    let i = state.findSession(id)
    if i >= 0 and not state.sessions[i].noSeismic: # auxiliary traces are never matched
      state.startAutoJoin(i)
      return

proc newProject(state: var AppState; cmd: Command) =
  ## `ckNewProject`: the folder made, with its document, and opened; the
  ## session's files stay open and are its own.
  if cmd.projectPath.len == 0:
    state.ignore(cmd, "no folder was named for the project")
    return
  let dir = canonical(cmd.projectPath)
  let name = if cmd.projectName.strip.len > 0: cmd.projectName.strip else: dir.untitled
  let why = projectNameProblem(name)
  if why.len > 0:
    state.ignore(cmd, "the project's name cannot be \"" & name & "\": " & why)
    return
  var data: seq[string] = @[]
  for d in cmd.dataFolders:
    if d.len > 0 and canonical(d) notin data: data.add canonical(d)
  if data.len == 0 and state.files.folder.len > 0: data.add state.files.folder
  for d in data:
    if dir.isInside(d):
      state.log.add(sevWarning, "project", "A project cannot be made inside its data folder " &
        d & ": data folders are never written to. Choose another place.")
      return
  let np = NewProject(name: name, data: data,
    bringFrom: if cmd.bringMemory: state.userStore else: "",
    presets: state.kept.displayPresets, takePresets: cmd.takePresets,
    processing: state.settings.plot.processing, takeProcessing: true)
  state.openProject(dir, cmd.origin, make = true, np = np, useSurvey = cmd.useSurvey)

proc projectFolder(state: var AppState; cmd: Command) =
  ## `ckProjectFolder`: a data folder added, removed or re-pointed.
  template p: untyped = state.project
  if p.dir.len == 0:
    state.ignore(cmd, "no project is open")
    return
  if p.readOnly:
    state.ignore(cmd, "the project is open read-only (" & p.whyReadOnly & ")")
    return
  let path = if cmd.folderPath.len > 0: canonical(cmd.folderPath) else: ""
  case cmd.folderAction
  of faAdd:
    if path.len == 0: state.ignore(cmd, "no folder was named")
    elif p.dir.isInside(path) or path.isInside(p.dir):
      state.ignore(cmd, "a project's data folder cannot hold the project, nor be inside it")
    elif p.folders.anyIt(it.path == path) or p.doc.data.anyIt(it.absolute == path):
      state.ignore(cmd, path & " is a data folder of the project already")
    elif p.doc.data.len >= MaxProjectData:
      state.ignore(cmd, "a project has at most " & $MaxProjectData & " data folders")
    else:
      p.doc.data.add placeOf(p.dir, path)
      state.log.add(sevInfo, "project", path & " is a data folder of the project " & p.doc.name &
        " now.")
  of faRemove:
    var at = -1
    for i, d in p.doc.data:
      if d.absolute == path or (i < p.folders.len and p.folders[i].path == path): at = i
    if at < 0: state.ignore(cmd, path & " is not a data folder of the project")
    else:
      p.doc.data.delete(at)
      if at < p.folders.len: p.folders.delete(at)
      state.log.add(sevInfo, "project", path & " is no longer a data folder of the project " &
        p.doc.name & " (nothing in it was changed).")
  of faLocate:
    var at = -1
    for i, d in p.doc.data:
      if d.absolute == cmd.folderWas or d.path == cmd.folderWas or d.displayName == cmd.folderWas:
        at = i
    if at < 0 or path.len == 0:
      state.ignore(cmd, "the project has no data folder " & cmd.folderWas)
      return
    if p.dir.isInside(path) or path.isInside(p.dir):
      state.ignore(cmd, "a project's data folder cannot hold the project, nor be inside it")
      return
    let old = p.doc.data[at].absolute
    p.doc.data[at] = placeOf(p.dir, path)
    var moved = 0
    if old.len > 0:
      for i, d in p.doc.data.mpairs:
        if i != at and (i >= p.folders.len or p.folders[i].state != psFound) and
            d.absolute.isInside(old.parentDir):
          d = placeOf(p.dir, d.moved(old.parentDir, path.parentDir).absolute)
          inc moved
    state.log.add(sevInfo, "project", p.doc.data[at].displayName & " is at " & path & " now" &
      (if moved > 0: "; " & $moved & " more data " & (if moved == 1: "folder that was" else:
        "folders that were") & " beside it " & (if moved == 1: "is" else: "are") &
        " looked for beside it there" else: "") & ".")
  state.projectChanged()
  state.lookAgain()

# ------------------------------------------------------- the map's work --
# What the map shows besides the survey's layers, each made on a job that
# follows what it depends on (`followMapWork`, after every command and
# drained inbox): the relation records the planned spreads need.

func unitSources*(state: AppState): seq[tuple[what: string; unit: SurveyUnit]] =
  ## Each unit the data name for the survey's coordinates, in the order the
  ## map takes them (the first is the map's): the units confirmed with an
  ## import (or worked out by it from the headers), then each survey file's
  ## (SPS H20, H201), then each open seismic file's: the unit it was
  ## imported with, else its headers' (SEG-Y's measurement system, a CRS:
  ## `headerUnitOf`).
  for j in state.joins:
    if j.units.survey != suNotGiven:
      let i = state.findSession(j.session)
      result.add ((if j.units.surveyFromHeaders: "the survey imported for "
        else: "the units confirmed for ") & (if i >= 0: state.sessions[i].name
        else: "an import"), j.units.survey)
  for i in 0 ..< state.survey.layers.len:
    template l: untyped = state.survey.layers[i]
    if l.origin == loSurveyFile and l.gridUnit.known and unitOf(l.gridUnit) != suNotGiven:
      result.add (l.name, unitOf(l.gridUnit))
  for s in state.sessions:
    if s.noSeismic: continue # auxiliary traces have no place on the map
    let j = state.joinedOf(s.id)
    if j >= 0 and state.joins[j].units.file != suNotGiven:
      result.add ((if state.joins[j].units.fileFromHeaders: s.name & "'s headers, as imported"
        else: "the units confirmed for " & s.name & "'s headers"), state.joins[j].units.file)
    else:
      let u = headerUnitOf(s.crs)
      if u != suNotGiven: result.add (s.name & "'s headers", u)

func differingUnits(state: AppState; all: seq[tuple[what: string; unit: SurveyUnit]]):
    seq[SurveyUnit] =
  ## The different units the sources name, the map's first; none when they agree.
  var units: seq[SurveyUnit]
  for (what, u) in all:
    # A seismic file's headers' "feet" may be US survey feet (SEG-Y cannot
    # tell them apart): no disagreement with a survey in US survey feet.
    let loose = u == suFeet and what.endsWith("'s headers") and
      not what.startsWith("the units confirmed")
    if u notin units and not (loose and suUsFeet in all.mapIt(it.unit)): units.add u
  if units.len >= 2: units
  else: @[]

func unitsDisagree*(state: AppState): string =
  ## When the loaded files name different units: what each says and which
  ## the map uses, "map.s says US survey feet, shot.sgy's headers metres:
  ## the map uses US survey feet"; "" when they agree (or none says).
  let all = state.unitSources
  let units = state.differingUnits(all)
  if units.len < 2: return
  var parts: seq[string]
  for u in units:
    var names: seq[string]
    for (what, v) in all:
      if v == u and names.len < 3: names.add what
    parts.add names.join(", ") & " " & $u
  "The coordinates' units disagree (" & parts.join("; ") & "): the map uses " & $units[0] &
    ", the first, and converts nothing"

proc followUnits(state: var AppState) =
  ## Says once in the log when the loaded files' units come to disagree.
  let words = state.unitsDisagree
  if words != state.unitsWarned:
    state.unitsWarned = words
    # Once a session for the same units (stepping through files that say the same
    # does not repeat it with another file's name).
    let kind = state.differingUnits(state.unitSources).mapIt($it).join(",")
    if words.len > 0 and kind notin state.unitsSaid:
      state.unitsSaid.incl kind
      state.log.add(sevWarning, "map", words & ".")

func shownDomain*(state: AppState): RelationDomain =
  ## The domain of the record on show in the main panel: `rdReceiver` for a
  ## receiver gather, else `rdSource` (a shot, or no record).
  let g = state.selection.activeGather
  let i = state.findSession(g.file)
  if i >= 0 and g.gather in 0 ..< state.sessions[i].gathers.len and
      state.sessions[i].gathers[g.gather].kind == gkReceiver: rdReceiver
  else: rdSource

func shownPlace*(state: AppState; s: Session; gather: int;
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
      lane: jlBackground, auto: true, reads: paths), spreadWork(paths, want.spec, want.needs,
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
    # (a signature file is decoded in memory: it has no shots)
    if e.kind.isSeismic and e.kind notin SignatureFileKinds:
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
    var choices: seq[OpenChoice]
    for p in x.jobPaths: choices.add state.openChoices.getOrDefault(p)
    x.job = state.jobs.submit(JobSpec(title: "Find the shots in the folder's files",
      lane: jlBackground, auto: true, reads: x.jobPaths), shotsWork(x.gen, x.jobPaths,
      state.indexCache,
      state.inbox.poster, choices))

proc takeShots(state: var AppState; m: sink Msg) =
  ## A listed file's shots, read by a job of this listing.
  template x: untyped = state.shots
  if m.shotsGen == x.gen:
    let path = m.shots.path
    x.queued.excl path
    x.take(state.survey, move m.shots)
    if x.pending.len == 0 and x.jobPaths.len == 0 and x.later.len == 0:
      x.finished = fs.now()
      let n = x.unplacedShots
      if n > 0 and n != x.unplacedSaid:
        state.log.add(sevInfo, "map", $n & (if n == 1: " shot has" else: " shots have") &
          " no source line and point and " & (if n == 1: "is" else: "are") &
          " not on the map.")
      x.unplacedSaid = n

func qcRelations(state: AppState; domain: RelationDomain): (ref SurveyGeometry, string) =
  ## The relation records the record shown is checked against: the first
  ## loaded survey file's of `domain`, else those made from the template.
  let i = state.survey.listedLayer(domain)
  if i >= 0: (state.survey.layers[i].relations, state.survey.layers[i].name)
  elif not state.spreads.relations.isNil and state.spreads.relations[].relationCount(domain) > 0:
    (state.spreads.relations, "the template generated")
  else: (nil, "")

func viewOfPanel(state: AppState; k: int): tuple[bi: int; view: BreakView] =
  ## What `shownBreaks` shows for record panel `panels[k]`, without its lists: the result
  ## `bi`, the model, and whether the picks are the model's own.
  let exact = state.guidedIndex(k).exact
  let bi = state.breaksIndex(k)
  result.bi = bi
  if bi < 0: return
  let b = state.breaks[bi]
  result.view = BreakView(key: b.key, revision: b.revision,
    model: state.panels[k].layers[0].display.breakModel, guided: gdOwn)
  if bi != exact:
    result.view.guided = if exact >= 0 and state.breaks[exact].state == bkFailed: gdFailed
                         else: gdMaking
    if result.view.guided == gdFailed: result.view.why = state.breaks[exact].why

func sameView(a, b: BreakView): bool =
  a.key == b.key and a.revision == b.revision and a.model == b.model and a.guided == b.guided and
    a.why == b.why

func madeView(state: AppState; bi: int; v: BreakView): FirstBreaks =
  ## The result `bi` as view `v` says: with its model applied (`withModel`) and the note on
  ## whose picks they are.
  result = state.breaks[bi].withModel(v.model)
  result.guided = v.guided
  if v.guided != gdOwn:
    result.guidedBy = state.breaks[bi].key.guide
    result.guideWhy = v.why

func shownBreaksKept*(state: AppState; k: int): bool =
  ## Whether what `shownBreaks` gives record panel `panels[k]` is kept made (`breakViews`), so
  ## that drawing it on every frame does not apply the rule again.
  let (bi, v) = state.viewOfPanel(k)
  if bi < 0: return false
  for c in state.breakViews:
    if c.sameView(v): return true

type
  TemplateView* = object
    ## What the "Only traces in the template" button of a plot says.
    available*: bool    ## a relation file (or a generated template) is there to check against
    on*: bool           ## the plot's filter asks for it
    known*: bool
      ## the record's template was found, and which of its traces it lists (`shown`, `total`)
    waiting*: bool      ## on, and the record's check has not ended
    shown*, total*: int ## seismic traces the template lists, and seismic traces in the record

func templateAvailable(state: AppState; k: int): bool =
  ## Whether a relation file (or a generated template) is there to check the record
  ## `panels[k]` shows against.
  let i = state.shownFile(k)
  if i < 0: return false
  let domain = if state.sessions[i].gathers.len > state.panels[k].layers[0].source.gather and
      state.sessions[i].gathers[state.panels[k].layers[0].source.gather].kind == gkReceiver:
        rdReceiver
      else: rdSource
  not state.sessions[i].noSeismic and not state.sessions[i].isSignature and
    not state.qcRelations(domain)[0].isNil

func templateView*(state: AppState; k: int): TemplateView =
  ## The template of the record plot `panels[k]` shows: whether there is a relation file for
  ## it, whether the plot asks for the template's traces only, and, once the record is
  ## checked, how many of its seismic traces the template lists.
  if k < 0 or k >= state.panels.len or state.panels[k].layers.len == 0: return
  if state.shownFile(k) < 0: return
  result.available = state.templateAvailable(k)
  result.on = state.panels[k].layers[0].filter.templateOnly
  let (known, unlisted, total) = state.templateTraces(k)
  result.known = known
  result.total = total
  result.shown = total - unlisted.len
  result.waiting = result.on and not known and
    (state.recordQc.job != NoJob or state.panels[k].templateWait)

func shownBreaks*(state: AppState; k: int): FirstBreaks =
  ## The first-break result of record panel `panels[k]` as its overlay shows it: with the
  ## model it was given, when the panel's display gives one (`withModel`); an empty
  ## result (`bkComputing`) when it has none. While the picks guided by the panel's model are
  ## being made, or when they could not be, another guide's picks are shown and `guided` says
  ## so. Made once for each result and model (`breakViews`), not on every frame.
  let (bi, v) = state.viewOfPanel(k)
  if bi < 0: return FirstBreaks()
  for c in state.breakViews:
    if c.sameView(v): return c.shown
  state.madeView(bi, v)

func lengthUnitKnown(u: SurveyUnit): bool {.inline.} = u in {suMetres, suFeet, suUsFeet}

func fileOffsetUnit(state: AppState; k: int): SurveyUnit =
  ## The unit the file names for the offsets of the record panel `panels[k]`: the import's
  ## when the file is joined, else its header's measurement system; not given when it names
  ## none.
  if k < 0 or k >= state.panels.len or state.panels[k].layers.len == 0: return suNotGiven
  let src = state.panels[k].layers[0].source
  if src.kind != lsRecord: return suNotGiven
  let i = state.findSession(src.file)
  if i < 0: return suNotGiven
  let joined = state.joinedOf(src.file)
  if joined >= 0 and state.joins[joined].units.file != suNotGiven: state.joins[joined].units.file
  else: offsetUnitOf(state.sessions[i].crs)

func surveyLengthUnit(state: AppState): SurveyUnit =
  ## The unit of the project's survey, when it is a length: the one an import confirmed or
  ## read from its headers, else the first survey file's; not given otherwise.
  result = suNotGiven
  for j in state.joins:
    if result == suNotGiven and j.units.survey.lengthUnitKnown: result = j.units.survey
  for l in state.survey.layers:
    if result == suNotGiven and l.origin == loSurveyFile and l.gridUnit.known and
        unitOf(l.gridUnit).lengthUnitKnown:
      result = unitOf(l.gridUnit)

func breakOffsetUnit*(state: AppState; k: int): SurveyUnit =
  ## The unit of the offsets the first-break model of the record panel `panels[k]` shows
  ## was fitted on, as a label (nothing is converted): the survey's when the offsets are the
  ## distance between its positions, else the file's (the import's when the
  ## file is joined, else its header's measurement system, as an analysis reads them); when
  ## the file names none, the project's survey's, if it names a length.
  result = state.fileOffsetUnit(k)
  if result == suNotGiven: result = state.surveyLengthUnit
  # offsets taken from the survey's positions are in the survey's unit
  if state.shownBreaks(k).fromPositions > 0:
    let src = state.panels[k].layers[0].source
    let joined = if src.kind == lsRecord: state.joinedOf(src.file) else: -1
    if joined >= 0 and state.joins[joined].units.survey.lengthUnitKnown:
      result = state.joins[joined].units.survey

func breakUnitFromSurvey*(state: AppState; k: int): bool =
  ## Whether `breakOffsetUnit` is the project's survey's because the file names none.
  state.fileOffsetUnit(k) == suNotGiven and state.surveyLengthUnit != suNotGiven

proc breakKeyOf(state: AppState; k: int): (bool, BreakKey, int) =
  ## What the first-break overlay of `panels[k]` is of, when it is on and the
  ## panel shows a record: its key, and the session's index.
  result[2] = -1
  template p: untyped = state.panels[k]
  if p.shows != psTraces or p.layers.len == 0 or not p.layers[0].display.firstBreaks: return
  let src = p.layers[0].source
  if src.kind != lsRecord: return
  let i = state.findSession(src.file)
  if i < 0 or src.gather notin 0 ..< state.sessions[i].gathers.len: return
  let s = state.sessions[i]
  var off: seq[uint8]
  for c in 0 .. 255:
    if uint8(c) in p.layers[0].filter.components: off.add uint8(c)
  let model = p.layers[0].display.breakModel.bounded
  result = (true, (src.file, src.gather, s.keysRevision,
    state.editsAt(s.path).listIn(teKilled, s.gathers[src.gather].traces), off,
    (if model.given: model else: BreakModel()), p.layers[0].display.breakPickOn), i)

proc breakKeyFor(state: AppState; i, gather: int): BreakKey =
  ## The key of the first breaks of record `gather` of session `i`: that of a
  ## panel showing it with the overlay on (so the noisy-trace test and the
  ## overlay share one result), else its file's keys with the traces killed in it
  ## and no component switched off.
  for k in 0 ..< state.panels.len:
    let (on, key, j) = state.breakKeyOf(k)
    if on and j == i and key.gather == gather:
      # the record's check is not of the given model: it must not start again when that changes
      result = key
      result.guide = BreakModel()
      return
  let s = state.sessions[i]
  (s.id, gather, s.keysRevision, state.editsAt(s.path).listIn(teKilled, s.gathers[gather].traces),
    newSeq[uint8](), BreakModel(), pbSmoothed)

const SignatureNoFilters = NoiseFilters + {mfMissing, mfUnlisted}
  ## the filters a signature file has no receivers for: the noise test and the template's

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
  var filters = state.settings.map.filters * TraceFilters
  var box = state.settings.map.templateBox or state.wantsTemplate
  if shown and state.sessions[i].isSignature:
    # no receivers: no noise test and no template check (`filterHits` says so)
    filters = filters - SignatureNoFilters
    box = false
  if (filters == {} and not box) or not shown:
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
  let tr = s.gathers[g.gather].traces
  var gatherTraces = newSeq[int](tr.len)
  for i in 0 ..< tr.len: gatherTraces[i] = tr.a + i
  let own = ownOfTraces(state.editsAt(s.path), gatherTraces)
  let reversed = reversedOf(state.editsAt(s.path), gatherTraces)
  let shifts = shiftsOfTraces(state.editsAt(s.path), gatherTraces)
  var work = NoiseWork(on: samples and filters * NoiseFilters != {})
  var share = 0
  if work.on:
    work.settings = state.settings.noise.bounded
    work.key = state.breakKeyFor(i, g.gather)
    # (the record's check uses the picks guided by the record's fit, `FirstBreaks.picks`: any
    # guide's result has them; a done one first)
    for b in state.breaks:
      if b.key.sameRecord(work.key) and share != 2:
        if b.state == bkDone: (work.shared, share) = (b, 2)
        elif b.state == bkComputing: share = 1
    if share == 0:
      for b in state.breaks:
        if b.key.sameRecord(work.key):
          share = 2 # failed or stopped: a result too, the job does not ask again
  let key = (s.id, g.gather, s.keysRevision, (if rel.isNil: nil else: cast[pointer](rel)),
    domain, state.settings.join.recordMatch, state.settings.join.traceMatch, placed, samples,
    ownKeyOf(state.editsAt(s.path), gatherTraces), work.settings, work.key, share)
  if key == q.key: return
  if q.job != NoJob:
    discard state.jobs.cancel(q.job)
    q.replaced.add q.job
  q.key = key
  for m in TraceFilters: q.hits[m] = FilterHits(state: fsComputing)
  (q.record, q.byPlace, q.onStations) = (-1'i64, false, false)
  q.noise = NoiseSummary()
  q.picks = work.on and share == 0
  q.pickKey = work.key
  q.job = NoJob
  inc q.revision
  if share == 1: return # the overlay's job is finding the first breaks: this one follows it
  q.job = state.jobs.submit(JobSpec(title: "Check the record shown for the map's filters",
    lane: jlBackground, auto: true, reads: @[s.path]), recordQcWork(s.filePtr, s.path, s.id, s.base,
    g.gather, s.gathers[g.gather].traces, domain, (if rel.isNil: nil else: addr rel[]), against,
    state.settings.join.recordMatch, state.settings.join.traceMatch, placed, samples,
    own, reversed, shifts, work, state.inbox.poster, s.correlatedView))
  if not rel.isNil: state.qcHeld.add (q.job, rel)

proc nextBreakRevision(state: var AppState): int =
  ## A revision no result had before: a view made of a result is of that result as it was.
  inc state.breakRevisions
  state.breakRevisions

proc keepBreaks(state: var AppState; found: sink FirstBreaks) =
  ## The first breaks a record's check found for itself (`core/recordqc`): kept
  ## for the overlay, which then does not look for them. A result of the same key
  ## that is not done (a job started at the same time) is given up for it.
  for b in state.breaks.mitems:
    if b.key == found.key:
      if b.state == bkDone: return
      if b.job != NoJob:
        discard state.jobs.cancel(b.job)
        state.breaksReplaced.add b.job
      let rev = state.nextBreakRevision
      b = move found
      (b.job, b.revision) = (NoJob, rev)
      return
  found.revision = state.nextBreakRevision
  state.breaks.add found

proc takeRecordQc(state: var AppState; m: sink Msg) =
  ## What the filters' job found in the record it read, while that record,
  ## as it is now, is the one shown.
  template q: untyped = state.recordQc
  if m.job == q.job and m.qcSession == q.key.file and m.qcGather == q.key.gather and
      m.qcKeys == q.key.keys:
    for f in TraceFilters: q.hits[f] = move m.qcHits[f]
    (q.record, q.byPlace, q.onStations) = (m.qcRecord, m.qcByPlace, m.qcOnStations)
    q.noise = move m.qcNoise
    q.picks = false
    inc q.revision
    if m.qcPicked:
      state.keepBreaks(move m.qcBreaks)
      q.key.share = 2 # the result it posted is the shared one now: no second job for it

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
  if i >= 0 and state.sessions[i].isSignature:
    for f in SignatureNoFilters * on:
      result[f] = FilterHits(state: fsDone, note: "does not apply to a signature file")
  if i >= 0 and g.gather in 0 ..< state.sessions[i].gathers.len:
    let s = state.sessions[i]
    let traces = s.gathers[g.gather].traces
    for (f, edit) in [(mfKilled, teKilled), (mfReversed, teReversed)]:
      if f in on:
        result[f] = FilterHits(state: fsDone, note: "traces")
        if state.keyOf(s.path) in state.edits:
          for t in state.edits[state.keyOf(s.path)].listIn(edit, traces):
            result[f].traces.add s.base + t
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

proc followFirstBreaks(state: var AppState) =
  ## The first-break overlay's jobs follow what the panels show: a record a
  ## panel with the overlay on shows, as its file's keys and killed traces
  ## are now, is found once (`core/firstbreakjobs`) and kept (the last few
  ## records stay, so stepping back is instant); a result or a job of a key
  ## no panel wants any more (an edit, a join, another record of the same
  ## panel) is dropped, and a job still running is cancelled.
  var wanted: seq[(BreakKey, int)]
  for k in 0 ..< state.panels.len:
    let (on, key, i) = state.breakKeyOf(k)
    if on and (key, i) notin wanted: wanted.add (key, i)
  # one result per record and guide: two panels on one record with different models each keep
  # theirs, and neither is given up for the other's
  var kept: seq[FirstBreaks]
  for b in state.breaks.mitems:
    var superseded = state.findSession(b.key.file) < 0
    var wantedNow = false
    for (key, _) in wanted:
      if key == b.key: wantedNow = true
      elif b.key.supersededBy(key):
        superseded = true
    # a result no panel wants is kept only when done (to show while another guide's picks are
    # made, or to step back to); a failed one goes, so asking again picks again
    if superseded or (not wantedNow and b.state != bkDone):
      if b.job != NoJob:
        discard state.jobs.cancel(b.job)
        state.breaksReplaced.add b.job
    else: kept.add move b
  func wantedKey(wanted: seq[(BreakKey, int)]; key: BreakKey): bool =
    for (k, _) in wanted:
      if k == key: return true
  for (key, _) in wanted: # at most a few guides a record: the oldest no panel wants go
    var count = 0
    for b in kept:
      if b.key.sameRecord(key): inc count
    var j = 0
    while count > MaxGuidesPerRecord and j < kept.len:
      if kept[j].key.sameRecord(key) and kept[j].state != bkComputing and
          not wanted.wantedKey(kept[j].key):
        kept.delete j
        dec count
      else: inc j
  var j = 0
  while kept.len > MaxBreakRecords and j < kept.len:
    if kept[j].state != bkComputing and not wanted.wantedKey(kept[j].key): kept.delete j
    else: inc j
  state.breaks = kept
  for (key, i) in wanted:
    var have = false
    let s = state.sessions[i]
    let traces = s.gathers[key.gather].traces
    for b in state.breaks:
      if b.key == key: have = true # computing, done or failed: an answer, never asked again
    # the record's check is finding them itself (`RecordQc.picks`, guided by the record's fit):
    # its answer is kept
    have = have or (not key.guide.given and state.recordQc.job != NoJob and
      state.recordQc.picks and state.recordQc.pickKey == key)
    if not have and not s.derived:
      var b = FirstBreaks(key: key, state: bkComputing, first: traces.a)
      b.job = state.jobs.submit(JobSpec(title: "Find the first breaks of the record shown",
        lane: jlBackground, auto: true, reads: @[s.path]), firstBreaksWork(s.filePtr, s.path,
        key, traces, state.inbox.poster))
      state.breaks.add b
  # what each panel's overlay shows, made again only when its result or model changed
  var views: seq[BreakView]
  for k in 0 ..< state.panels.len:
    var (bi, v) = state.viewOfPanel(k)
    if bi >= 0:
      var found = false
      for c in state.breakViews.mitems:
        if not found and c.sameView(v):
          views.add move c
          found = true
      if not found:
        v.shown = state.madeView(bi, v)
        views.add v
  state.breakViews = views

proc takeFirstBreaks(state: var AppState; m: sink Msg) =
  ## A record's first breaks, while its key is still wanted; the answer of a
  ## job given up for a newer key is dropped.
  for b in state.breaks.mitems:
    if b.job == m.job and b.job != NoJob:
      let (job, key, rev) = (b.job, b.key, state.nextBreakRevision)
      b = move m.breaks
      (b.job, b.key, b.revision) = (job, key, rev)
      return

proc endBreaksWork(state: var AppState; job: JobInfo): bool =
  ## A first-break job ended: forgotten, a failure or a stop said on its
  ## result; false when `job` is none of them.
  let gone = state.breaksReplaced.find(job.id)
  if gone >= 0:
    state.breaksReplaced.delete gone
    return true
  for b in state.breaks.mitems:
    if b.job == job.id:
      b.job = NoJob
      if b.state == bkComputing:
        b.state = bkFailed
        b.why = if job.state == jsFailed: "the record could not be read: " & job.error
                else: "stopped"
        b.revision = state.nextBreakRevision
      return true

proc followMapWork(state: var AppState) =
  ## After every command and drained inbox: the map's jobs follow what they
  ## depend on.
  state.followSpreads()
  state.followShots()
  state.followRecordQc()
  state.followFirstBreaks()
  state.followUnits()

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

proc showHeldBack(state: var AppState; path: string) =
  ## Panels that could not show `path` while a job had it to itself (the close
  ## of the open it replaced, still queued when the new one was shown) are
  ## shown now that the job has ended.
  var again: seq[int]
  var kept: seq[PanelId]
  for id in state.heldBack:
    let k = state.findPanel(id)
    if k < 0: continue
    var mine = false
    if state.panels[k].layers.len > 0:
      let src = state.panels[k].layers[0].source
      if src.kind == lsRecord:
        let i = state.findSession(src.file)
        if i >= 0 and state.sessions[i].path == path: mine = true
    if mine: again.add k
    else: kept.add id
  state.heldBack = kept
  for k in again: state.newSource(k)

proc refreshCompare(state: var AppState)

proc pauseLeapReaders(state: var AppState; path: string) =
  ## Has the readers of the panels that show `path` let go of it, for the
  ## leap-second re-read that needs it to itself; their tiles stay drawn.
  for k in 0 ..< state.panels.len:
    let i = state.shownFile(k)
    if i >= 0 and state.sessions[i].path == path:
      if state.panels[k].id notin state.leapPaused:
        state.leapPaused.add state.panels[k].id
      if not state.readers[k].isNil:
        state.readers[k].show(ReaderSource(gen: state.panels[k].sourceGen))

proc resumeLeapReaders(state: var AppState) =
  ## The panels the leap-second re-read paused show their file again.
  for id in state.leapPaused:
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
        p.samplesGen = p.requestGen
        p.pending = ReadRequest()
        inc p.revision
        state.readers[k].show(ReaderSource(gen: p.sourceGen, file: s.filePtr, session: s.id,
          path: s.path, size: s.size, traces: s.gathers[g].traces, filter: p.layers[0].filter,
          order: p.layers[0].order))
      else:
        state.newSource(k)
  state.leapPaused.setLen 0

proc followLeap(state: var AppState) =
  ## The next open file has its times read again, once no import, station-move
  ## job or other leap job holds a file.
  if state.leapJob != NoJob or state.movesJob != NoJob or state.importing: return
  while state.leapQueue.len > 0:
    let id = state.leapQueue[0]
    state.leapQueue.delete(0)
    let i = state.findSession(id)
    if i >= 0:
      let s = state.sessions[i]
      if not s.isSignature:
        state.pauseLeapReaders(s.path)
        state.leapSession = id
        state.leapName = s.name
        state.leapDone = false
        state.leapChanged = false
        state.leapJob = state.jobs.submit(JobSpec(title: "Read times again for " & s.name,
          lane: jlInteractive, exclusive: @[s.path]), leapRereadWork(s.filePtr, s.path, s.id,
          state.jobs.holdRelease, state.inbox.poster))
        return

proc queueLeapReads(state: var AppState) =
  ## Every open file that is not a signature waits to have its times read again.
  for s in state.sessions:
    if not s.isSignature and s.id notin state.leapQueue:
      state.leapQueue.add s.id

proc adoptLeap(state: var AppState; table: LeapTable; said: string; save = true) =
  ## Makes `table` the one in use, writes it when `save` and a settings folder
  ## is kept, says `said`, and reads open files' times again. A file that was
  ## read and refused is adopted with `save` false: the file is left as it is.
  useLeapTable(table)
  inc state.leapGen
  publishLeapGen(state.leapGen)
  let path = state.leapFilePath()
  if save and path.len == 0:
    state.log.add(sevWarning, "leap seconds",
      "There is no settings folder, so the leap-second table was not saved.")
  elif save:
    state.diskIo.replace(path, leapTableNif(table), "the leap-second table",
      failNote = "The table is used for this run only.")
  if said.len > 0: state.log.add(sevInfo, "leap seconds", said)
  state.queueLeapReads()
  state.followLeap()

proc reloadLeaps(state: var AppState) =
  ## Reads the leap-second file again, off this thread. A missing settings
  ## folder is said and changes nothing.
  let path = state.leapFilePath()
  if path.len == 0:
    state.log.add(sevWarning, "leap seconds",
      "There is no settings folder, so there is no leap-second file to read.")
    return
  state.diskIo.read(path, rpLeapFile, 1 shl 20)

proc finishMoves(state: var AppState; job: JobInfo) =
  ## The station-move job ended: the panels it paused read their file again,
  ## and a file whose keys changed has its positions read again.
  state.resumeMoveReaders()
  let session = state.movesSession
  let changed = state.movesChanged
  let revision = state.movesRevision
  let done = state.movesDone
  state.movesJob = NoJob
  state.movesDone = false
  state.movesChanged = 0
  if job.state == jsDone and done:
    let i = state.findSession(session)
    if i >= 0 and changed > 0:
      let s = state.sessions[i]
      s.setKeysRevision(revision)
      state.readPositions(s)
      state.log.add(sevInfo, s.name, "Station moves applied to " & plural(changed, "trace") &
        " of " & s.name & ".")
  elif job.state == jsFailed:
    state.log.add(sevError, "station moves", "Station moves were not applied: " & job.error & ".")

proc finishLeap(state: var AppState; job: JobInfo) =
  ## The leap-second re-read ended: the panels it paused show their file again,
  ## and a file whose keys changed publishes the new revision. A failure or a
  ## cancel is said. A file gone meanwhile is left.
  state.resumeLeapReaders()
  let session = state.leapSession
  let changed = state.leapChanged
  let revision = state.leapRevision
  let done = state.leapDone
  state.leapJob = NoJob
  state.leapDone = false
  state.leapChanged = false
  if job.state == jsDone and done:
    let i = state.findSession(session)
    if i >= 0 and changed:
      state.sessions[i].setKeysRevision(revision)
  elif job.state == jsFailed:
    state.log.add(sevError, "leap seconds", "Times were not read again: " & job.error & ".")
  elif job.state == jsCancelled:
    state.log.add(sevWarning, "leap seconds", "Times of " & state.leapName &
      " were not read again; they use the earlier leap-second table until it is reopened.")

proc finishCut(state: var AppState; job: JobInfo) =
  ## The slice by shot log ended: its sentences go to the log, and the dialog
  ## has its outcome line and, when a file was written, the file's path.
  let res = if state.cutSink.isNil: CutResult() else: state.cutSink.result
  state.cutJob = NoJob
  state.cutSink = nil
  state.cutPath = ""
  let name = res.path.extractFilename
  if job.state == jsDone and res.ok:
    for line in res.lines: state.log.add(sevInfo, "slice by shot log", line)
    state.cutPath = res.path
    state.cutOutcome = (if res.lines.len > 0: res.lines[0] else: "Sliced.") & " Written to " &
      name & "."
  elif job.state == jsCancelled:
    state.cutOutcome = "The slice was cancelled" &
      (if res.removed: "; the partial file was removed." else: ".")
    state.log.add(sevWarning, "slice by shot log", state.cutOutcome)
  else:
    let why = if res.reason.len > 0: res.reason
              elif job.error.len > 0: job.error
              else: "the slice did not finish"
    state.cutOutcome = "The slice failed: " & why
    state.log.add(sevError, "slice by shot log", state.cutOutcome)

proc finishSps(state: var AppState; job: JobInfo) =
  ## The SPS export ended: the Messages say what was written and what was left
  ## out, and the shot log window has the outcome and the file's path.
  let res = if state.spsSink.isNil: ShotSpsResult() else: state.spsSink.result
  let dest = if state.spsSink.isNil: "" else: state.spsSink.dest
  state.spsJob = NoJob
  state.spsSink = nil
  state.spsPath = ""
  let name = dest.extractFilename
  if job.state == jsDone and res.error.len == 0:
    state.spsPath = dest
    state.spsOutcome = spsSentences(res, name)
    state.log.add(sevInfo, "export SPS", state.spsOutcome)
  elif job.state == jsCancelled:
    state.spsOutcome = "The SPS export was cancelled."
    state.log.add(sevWarning, "export SPS", state.spsOutcome)
  else:
    let why = if res.error.len > 0: res.error
              elif job.error.len > 0: job.error
              else: "the export did not finish"
    state.spsOutcome = "The SPS export failed: " & why
    state.log.add(sevError, "export SPS", state.spsOutcome)

proc finishO(state: var AppState; job: JobInfo) =
  ## The O file generation ended: the Messages say what was written and what
  ## the O records leave out.
  let sink = state.oSink
  let res = if sink.isNil: OFileSummary() else: sink.summary
  let dest = if sink.isNil: "" else: sink.dest
  let source = if sink.isNil: "" else: sink.source.extractFilename
  state.oJob = NoJob
  state.oSink = nil
  state.oPath = ""
  if job.state == jsDone and res.error.len == 0:
    state.oPath = dest
    state.oOutcome = oFileSentences(res, dest.extractFilename, source)
    state.log.add(sevInfo, "generate O file", state.oOutcome)
  elif job.state == jsCancelled:
    state.oOutcome = "The O file was not written: generating it was cancelled."
    state.log.add(sevWarning, "generate O file", state.oOutcome)
  else:
    let why = if res.error.len > 0: res.error
              elif job.error.len > 0: job.error
              else: "it did not finish"
    state.oOutcome = "The O file was not written: " & why
    state.log.add(sevError, "generate O file", state.oOutcome)

proc releaseSurvey(state: AppState; job: JobInfo) =
  ## Lets go of the survey a batch write's job joined from.
  for c in state.batchSurvey.held:
    if c.job == job.id and job.abandoned: state.batchSurvey.left.add c # its work still runs
  state.batchSurvey.held.keepItIf(it.job != job.id)

proc kindFromOpen(state: var AppState) =
  ## The shown file's facts (`recFacts`, read from its own header keys) give its row of Files
  ## its kind: the whole file read as the probe reads it, so it wins over the probe's answer.
  ## Only for the file as listed (its size and time as the session opened it) and the keys and
  ## vendor maps the facts were made with; a joined or moved file keeps the probe's answer.
  let s = state.findSession(SessionId(state.recKey.session))
  let i = state.files.find(state.recPath)
  if s < 0 or i < 0 or state.recKey.vendors != state.vendor.gen or
      state.sessions[s].keysRevision != state.recKey.revision: return
  template e: untyped = state.files.entries[i]
  let sz = state.sessions[s].size
  if sz < 0 or sz != e.size or state.sessions[s].modified != e.modified: return
  if e.kindState != ksKnown or e.recording != state.recFacts.kind or
      e.traceOrder != state.recFacts.order:
    e.kindState = ksKnown
    e.recording = state.recFacts.kind
    e.traceOrder = state.recFacts.order
    state.files.changedAt(i)
  state.kindCache.remember(KindAnswer(path: e.path, size: e.size, modified: e.modified,
    state: ksKnown, kind: e.recording, order: e.traceOrder), state.vendor.gen, state.files)

proc startKinds(state: var AppState) =
  ## Starts a job on the peeks lane (the file headers read for what they say, a lane of its own
  ## so that it holds no record QC, first breaks or next-file preparation, and a drive that does
  ## not answer holds nothing but this and the survey units) that reads the kind of recording
  ## of the listed seismic
  ## files not read yet (`kindsWork`), unless one runs: it ends, and this runs again, so files
  ## listed or changed meanwhile are read too. A job reads at most `KindBatch` files (and gives
  ## way after `KindTurn`): the next job is submitted when it ends, behind what was queued on the
  ## lane meanwhile (a survey file's units), so that waits for one batch, not for the folder. A
  ## file being written waits until it is steady.
  ## A file whose kind was read before, as it is now and under the vendor maps in force
  ## (`kindCache`), takes that answer and is not read again.
  if state.kindJob != NoJob: return
  var asks: seq[WatchedFile] = @[]
  for i in 0 ..< state.files.entries.len:
    template e: untyped = state.files.entries[i]
    if e.kind.isSeismic and e.kindState == ksUnread and e.status != fsWriting:
      let had = state.kindCache.cachedKind(e, state.vendor.gen)
      if had.isSome:
        e.kindState = had.get.state
        e.recording = had.get.kind
        e.traceOrder = had.get.order
        state.showTreat(e)
        state.files.changedAt(i)
      elif asks.len < KindBatch:
        asks.add WatchedFile(path: e.path, size: e.size, modified: e.modified)
  if asks.len > 0:
    var known: seq[tuple[path: string; id: FileIdentity]] = @[]
    for a in asks:
      let id = state.knownIdentity(a.path)
      if id.fullKnown: known.add (a.path, id)
    state.kindJob = state.jobs.submit(JobSpec(title: "Read what the files are",
      lane: jlPeeks), kindsWork(state.files.gen, state.vendor.gen, asks, currentVendors(),
      state.store, known, state.inbox.poster))

proc rereadKinds(state: var AppState) =
  ## The vendor maps in force changed: a start time may now come from a vendor block, so every
  ## kind read is stale. The job reading them stops, every row is unread again, and the kinds
  ## are read anew.
  if state.kindJob != NoJob:
    discard state.jobs.cancel(state.kindJob)
    state.oldScans.add state.kindJob # it ends quietly
    state.kindJob = NoJob
  for i in 0 ..< state.files.entries.len:
    if state.files.entries[i].kindState != ksUnread:
      state.files.entries[i].kindState = ksUnread
      state.files.changedAt(i)
  state.startKinds()

proc onFinished(state: var AppState; job: JobInfo) =
  ## Says how a job ended, and lets go of what the state kept for it.
  if job.id == state.cutJob:
    state.finishCut(job)
    return
  if job.id == state.spsJob:
    state.finishSps(job)
    return
  if job.id == state.oJob:
    state.finishO(job)
    return
  if job.id == state.stJob:
    state.stJob = NoJob
    if job.state == jsDone and state.stSink != nil:
      state.stMap = state.stSink.map
      state.stHave = true
      state.stSink = nil
      state.applyShotTraces()
    else:
      state.stSink = nil
      state.stWant = -1
      if job.state == jsFailed:
        state.log.add(sevWarning, "Shot log", "The traces could not be told to shots: " &
          job.error.splitLines()[0])
    return
  if job.id == state.recJob:
    state.recJob = NoJob
    # whatever the end, this is the answer for `recKey`: the job is not started again
    state.recFacts = RecordingFacts()
    state.recWhy = ""
    var ownKeys = false
    if job.state == jsDone and state.recSink != nil:
      state.recFacts = state.recSink.facts
      ownKeys = state.recSink.ownKeys
      if not state.recFacts.ready: state.recWhy = NoLiveTraceWords
    else:
      state.recWhy = if job.error.len > 0: job.error.splitLines()[0]
                     else: "The recording could not be read."
    state.recHave = true
    state.recSink = nil
    if state.recFacts.ready and ownKeys: state.kindFromOpen()
    return
  if job.id == state.vfJob:
    state.vfJob = NoJob
    # a job that failed gives the answer "none", so the file is not asked again every frame
    if state.vendorFields(state.vfKey.session).isNone and state.vfKey.vendors == state.vendor.gen:
      state.vfLists.add VendorFieldList(session: state.vfKey.session,
        vendors: state.vfKey.vendors)
    return
  if job.id == state.leapJob:
    state.finishLeap(job)
    return
  if job.id == state.movesJob:
    state.finishMoves(job)
    return
  if state.takeShotLog(job): return
  if state.takeCorrelate(job): return
  if job.id == state.comparePicJob and job.state == jsFailed:
    state.comparePicJob = NoJob
    if job.error.len > 0:
      state.log.add(sevWarning, "compare", "The comparison could not be drawn: " &
        job.error & ".")
  if job.state in {jsCancelled, jsFailed}:
    let waiting = state.compareA.waiting or state.compareB.waiting
    let why = if job.error.len > 0: job.error else: "the copy was cancelled"
    if state.compareA.waiting and state.compareJobA == job.id:
      state.compareA.waiting = false
      state.compareA.filled = false
      state.compareA.problem = why
    if state.compareB.waiting and state.compareJobB == job.id:
      state.compareB.waiting = false
      state.compareB.filled = false
      state.compareB.problem = why
    if waiting and not (state.compareA.waiting or state.compareB.waiting):
      state.refreshCompare()
  if state.endProjectWork(job): return
  if state.endMapWork(job): return
  if state.endBreaksWork(job): return
  if state.endMemoryWork(job): return
  for k, h in state.headJobs:
    if h.job == job.id:
      # Its head was posted before it finished, unless it was cancelled or failed.
      let i = state.surveyHead(h.path)
      if i >= 0 and not state.heads[i].done:
        state.heads[i].done = true
        state.heads[i].problem = if job.state == jsFailed: "its headers cannot be read (" &
          job.error & ")" else: "its headers were not read (the reading was stopped)"
      state.headJobs.delete(k)
      return
  # A carried join's end is said by endJoin's drop line alone (not again here).
  let carriedEnd = job.id == state.joining.job and state.joining.carried
  if job.id == state.joining.job:
    case job.state
    of jsDone:
      if state.joining.cleared:
        # Clear survey came meanwhile: never recorded, and keys it changed go
        let session = state.joining.session
        let changed = state.joining.joined
        state.endJoin(joCancelled)
        if changed: state.dropKeys(session)
      elif state.joining.step == jpJoining:
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
      let path = p.path
      let name = path.extractFilename
      if job.state == jsDone and not p.quiet: state.log.add(sevInfo, name, "Closed " & name & ".")
      state.release(move state.closing[i].session) # nothing reads it now
      state.closing.delete(i)
      state.showHeldBack(path)
      return
  let old = state.oldScans.find(job.id)
  if old >= 0: # replaced by a newer listing: nothing to say
    state.oldScans.delete(old)
    return
  if job.id == state.kindJob:
    state.kindJob = NoJob
    if job.state == jsDone:
      state.startKinds() # the files it left, and those listed or changed meanwhile
      # the next one goes on with the folder: the Jobs window keeps a row for the newest only
      if state.kindJob != NoJob: discard state.jobs.remove(job.id)
    return
  if job.id == state.files.job:
    state.files.scanning = false
    state.files.job = NoJob
    case job.state
    of jsFailed:
      let (tried, instead) = state.lastFolderTried
      state.lastFolderTried = ("", "")
      if instead.len > 0 and state.files.title == tried:
        # the folder listed last is gone: the project's data folder is listed in its place
        state.startListing(@[instead], instead, "", state.listedBy)
        return
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
    if not carriedEnd: state.log.add(sevError, "jobs", job.spec.title & " failed: " & job.error)
    if job.spec.lane == jlBackground:
      state.notify(sevError, job.spec.title & " failed: " & job.error)
  of jsCancelled:
    if not carriedEnd: state.log.add(sevInfo, "jobs", job.spec.title & " was cancelled.")
  of jsDone:
    if job.spec.lane == jlBackground and not job.spec.auto:
      state.log.add(sevInfo, "jobs", job.spec.title & " is done.")
      state.notify(sevInfo, job.spec.title & " is done.")
  of jsQueued, jsRunning: discard

func chosenSignature(c: SignatureChoice; kind: SignatureKind): SignatureChoice =
  ## `c` with the interval resolved, as a decoded session states it.
  result = c
  if result.intervalUs <= 0: result.intervalUs = defaultIntervalUs(kind)

proc preparedAsWanted(state: AppState; path: string): bool =
  ## Whether the file prepared was decoded as `path` opens now: a signature file with the
  ## options and the pair that its open would give it (the list's choice may have changed, or a
  ## `.dat` have been found, since).
  let s = state.prepared.session
  if not s.isSignature: return true
  s.signature.choice == chosenSignature(state.openChoiceOf(path).signature, s.signature.kind) and
    s.signature.pair == state.pairArgOf(path).path

proc preparedCurrent(state: AppState): bool =
  ## Whether the file prepared is as the folder's watch saw it last: steady,
  ## with the size and time it was opened with.
  let s = state.prepared.session
  let e = state.files.find(s.path)
  e >= 0 and state.files.entries[e].status == fsSteady and
    state.files.entries[e].size == s.size and state.files.entries[e].modified == s.modified

proc showPath(state: var AppState; k: int; path: string; gather = 0; follow = false;
    by: CommandOrigin; asked = OpenChoice(); forced = false) =
  ## Shows the file at `path` (canonical) in `panels[k]`, in place of the
  ## one it shows, as `by` asked: at once when it is open, else once an open
  ## job opened it (at `gather`; with `follow`, only if it is whole). With
  ## `forced`, that open uses `asked` rather than the choice already in
  ## force. An open started earlier for this panel and another file is no
  ## longer wanted: it is cancelled, and dropped if it comes all the same;
  ## so is the wait to show a changed file again. A derived session's key
  ## is the file on disk: it is never opened or watched as a path.
  let path = diskOf(path)
  let panel = state.panels[k].id
  for o in state.opening.mitems:
    if o.panel == panel and o.path != path and not o.unwanted:
      o.unwanted = true
      discard state.jobs.cancel(o.job) # queued: never runs; running: asked to stop
  state.reopens.keepItIf(it.panel != panel or it.path == path)
  if panel == MainPanel: state.choose(path)
  if panel == MainPanel and state.correlateOn and state.derivedShown(path):
    let oi = state.originIndex(path)
    if oi >= 0: state.startCorrelate(oi, keepView = true)
    else: state.openHeld(path)
    return
  var i = -1
  for j, s in state.sessions:
    if not s.derived and s.diskPath == path: i = j
  if i >= 0:
    if state.shownFile(k) != i: state.showReplacing(k, state.sessions[i].id, gather)
    if panel == MainPanel and state.correlateOn:
      state.startCorrelate(i, keepView = false)
  else:
    var o = -1
    for j, p in state.opening:
      if p.path == path and not p.unwanted:
        let info = state.jobs.info(p.job)
        if info.isNone or info.get.state != jsCancelled: o = j
    if o >= 0:
      state.opening[o].panel = panel
      if state.opening[o].reopened: state.opening[o].revived = true
      if not follow: state.opening[o].follow = false # the user's own choice: shown as it is
      if keeps(by): state.opening[o].by = by # the user asked for it too
    elif not forced and not state.prepared.session.isNil and state.prepared.session.path == path and
        state.preparedCurrent() and path notin state.openChoices and
        state.preparedAsWanted(path):
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
        indexCacheFile(state.indexCache, path), whole = follow, lines = state.settings.join,
        choice = if forced: asked else: state.openChoiceOf(path),
        pair = state.pairArgOf(path)))
      state.opening.add Pending(job: job, path: path, panel: panel, gather: gather,
        follow: follow, by: by)

proc showListedShot(state: var AppState; cmd: Command): bool =
  ## `ckShowPoints` on a survey source no open file's trace was recorded at:
  ## the main panel shows the record a listed file holds of its shot (opened
  ## first, as the user's click asked): the latest (the first listed), or
  ## the one of file `cmd.shotPath`; false when no listed file has one.
  let k = state.findPanel(MainPanel)
  for p in cmd.points:
    let places = state.shots.shotsAt(p)
    if places.len > 0 and k >= 0:
      var chosen = 0
      if cmd.shotPath.len > 0:
        let wanted = canonical(cmd.shotPath)
        for j in countdown(places.high, 0):
          if places[j].path == wanted: chosen = j
      let (path, gather, _) = places[chosen]
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

func includesSubfolders*(state: AppState): bool =
  ## Whether the file list lists the subfolders' files too: the open project's
  ## choice, else the settings'.
  if state.project.dir.len > 0: state.project.doc.includeSubfolders
  else: state.settings.files.subfolders

proc startListing(state: var AppState; paths: seq[string]; title, folder: string;
    by: CommandOrigin) =
  ## Lists the files `paths` (canonical) name in the file list, in place of
  ## what it listed, as `by` asked: a scan on the background lane
  ## (`scanWork`). The file chosen stays chosen.
  if state.files.job != NoJob:
    discard state.jobs.cancel(state.files.job)
    state.oldScans.add state.files.job # it ends quietly
  if state.kindJob != NoJob:
    discard state.jobs.cancel(state.kindJob)
    state.oldScans.add state.kindJob
    state.kindJob = NoJob
  state.watch.unwatch() # until the scan is done
  state.listedBy = by
  if folder != state.files.folder:
    state.sigChoices = [SignatureChoice(), SignatureChoice()] # (for this listing only)
    state.pairAnswers.clear()
  let gen = state.files.gen + 1
  let recursive = state.includesSubfolders
  state.files = FileList(title: title, folder: folder, asked: paths, scanning: true, gen: gen,
    recursive: recursive, chosen: state.files.chosen, revision: state.files.revision + 1)
  state.files.job = state.jobs.submit(JobSpec(title: "List the files in " &
    (if folder.len > 0: folder.extractFilename else: title), lane: jlBackground),
    scanWork(gen, paths, state.inbox.poster, recursive))

proc openPair(state: var AppState; cmd: Command) =
  ## `ckOpenPair`: shows the other file of a signature file's sweep in the panel, in place of
  ## the one it shows (a click in Files does the same: the selection follows, and the partner's
  ## own offer leads back). When the list does not know the partner, a background job looks for
  ## it (`findPairWork`) and the partner is shown when it is found.
  let k = state.findPanel(cmd.panel)
  if k < 0:
    state.ignore(cmd, $cmd.panel & " does not exist")
    return
  var path = if cmd.path.len > 0: canonical(cmd.path) else: ""
  if path.len == 0:
    let i = state.shownFile(k)
    if i >= 0: path = state.sessions[i].path
  if path.len == 0:
    state.ignore(cmd, $cmd.panel & " shows no file")
    return
  let kind = state.signatureKindOfPath(path)
  if kind == sgNone:
    state.ignore(cmd, path.extractFilename & " is not a vibrator signature file")
    return
  let partner = state.partnerOf(path)
  if partner.len > 0:
    state.jump = ("", -1, -1)
    if cmd.panel == MainPanel: state.showFound = NoPanel
    state.showPath(k, partner, by = cmd.origin)
  elif state.pairSearch.job != NoJob and state.pairSearch.path == path:
    discard # the search for it is running
  else:
    if state.pairSearch.job != NoJob: discard state.jobs.cancel(state.pairSearch.job)
    let job = state.jobs.submit(JobSpec(title: "Look for the " &
      (if kind == sgDat: ".vib" else: ".dat") & " of " & path.extractFilename,
      lane: jlBackground, reads: @[path]), findPairWork(path, state.inbox.poster))
    state.pairSearch = (job, path, cmd.panel, cmd.origin)

proc takePaired(state: var AppState; m: sink Msg) =
  ## What a search for a file's partner found: kept, so that every offer and the Summary say
  ## it, and the partner shown in the panel that asked when one was found; else said once.
  if state.pairSearch.job != m.job: return # a search replaced since
  let (panel, by) = (state.pairSearch.panel, state.pairSearch.by)
  state.pairSearch = (NoJob, "", NoPanel, coWindow)
  state.pairAnswers[m.pairFor] = PairAnswer(partner: m.pairPath, info: m.pairInfo,
    words: m.pairWords, candidates: m.pairCandidates, looked: m.pairLooked)
  if m.pairPath.len > 0:
    state.pairAnswers[m.pairPath] = PairAnswer(partner: m.pairFor, info: m.pairSelf)
    let k = state.findPanel(panel)
    if k >= 0:
      state.jump = ("", -1, -1)
      if panel == MainPanel: state.showFound = NoPanel
      state.showPath(k, m.pairPath, by = by)
  else:
    state.log.add(sevInfo, m.pairFor.extractFilename, m.pairWords)

proc refreshPairs(state: var AppState) =
  ## Pairs the listed signature files again (`pairSweeps`: sorted by time, two pointers). Run on
  ## the UI thread when a scan ends and when the watch adds, removes or changes a signature
  ## file: at most `MaxTreeFiles` entries, a few milliseconds, no file read.
  template f: untyped = state.files
  var keys: seq[PairKey] = @[]
  for e in f.entries:
    if e.kind in SignatureFileKinds and e.sweep.problem.len == 0:
      keys.add pairKeyOf(e.path, e.sweep)
  let r = pairSweeps(keys)
  if r.pairs != f.pairs or r.notes != f.pairNotes:
    f.pairs = r.pairs
    f.pairNotes = r.notes
    inc f.pairsRev
    inc f.revision

proc takeKinds(state: var AppState; m: sink Msg) =
  ## The kinds a job read: each is kept for the entry it was read for, unless that file changed
  ## meanwhile (the watch asks for it again).
  if m.kindsGen != state.files.gen or m.kindsVendors != state.vendor.gen:
    return # a listing, or the vendor maps, replaced since
  template f: untyped = state.files
  for a in m.kinds:
    let i = f.find(a.path)
    if i >= 0 and f.entries[i].size == a.size and f.entries[i].modified == a.modified:
      template e: untyped = f.entries[i]
      e.kindState = a.state
      if a.state == ksKnown:
        e.recording = a.kind
        e.traceOrder = a.order
      # (an open file's own document, once it took one, says what it is treated as)
      let r = state.rememberedAt(a.path)
      # (and once its hash says no document is its own, none is: `takeHashed`)
      if r < 0 or not state.remembered[r].known or
          (state.remembered[r].doc.len == 0 and not state.remembered[r].hashed):
        state.loadTreat(a.path, a.treat, a.treatUnconfirmed)
      state.showTreat(e)
      f.changedAt(i)
      state.kindCache.remember(a, m.kindsVendors, f)

proc takeVendorFields(state: var AppState; m: sink Msg) =
  ## The vendor fields a job listed for an open file: kept, unless the maps were loaded again
  ## or the file closed meanwhile.
  if m.vendorFields.vendors != state.vendor.gen or
      state.findSession(m.vendorFields.session) < 0:
    return
  state.vfLists.keepItIf(it.session != m.vendorFields.session)
  state.vfLists.add move m.vendorFields

proc takeListed(state: var AppState; m: sink Msg) =
  ## What a scan found for the file list; shows the first file found (or the
  ## file named) when asked to.
  if m.listGen != state.files.gen: return # a listing replaced since
  template f: untyped = state.files
  if m.listProject.len > 0: # a project's folder, named as a folder: the project opens
    f.scanning = false
    inc f.revision
    state.openProject(m.listProject, state.listedBy)
    return
  if m.listFolder.len > 0:
    f.folder = m.listFolder
    f.title = m.listFolder
    state.change(state.listedBy, st): st.recentFolders.addRecent(m.listFolder, MaxRecent)
    if state.project.dir.len > 0 and keeps(state.listedBy) and not state.project.readOnly:
      let text = state.project.lastFolderText(m.listFolder)
      if text.len > 0 and text != state.project.doc.lastFolder:
        state.project.doc.lastFolder = text # the project opens on it again
        state.projectChanged()
  for e in m.listed:
    if e.kind.isSurvey and e.path in state.loadNamed: state.loadSurvey(e.path, quiet = true)
  f.looked = max(f.looked, m.listVisited)
  if m.listCapped: f.capped = true
  f.merge(m.listed)
  f.others += m.others
  f.unreadable += m.unreadable
  f.subfolders += m.subfolders
  if m.listDone:
    f.scanning = false
    state.refreshPairs()
    # Watched from what the scan found: a folder listed, or the files chosen.
    let paths = if f.folder.len > 0: @[f.folder] else: f.asked
    state.folderWatch.watch(f.gen, paths, move m.listLooked, f.recursive)
  inc f.revision
  state.startKinds()
  if state.showFound != NoPanel:
    var target = m.listChosen # (an open job finds it a survey file, if it is one)
    for e in f.entries:
      if target.len == 0 and e.kind.isSeismic: target = e.path
    if target.len > 0 or m.listDone:
      let k = state.findPanel(state.showFound)
      state.showFound = NoPanel
      if k >= 0 and target.len > 0: state.showPath(k, target, by = state.listedBy)

func newerSameController(f: FileList; e: FileEntry): bool =
  ## Whether a `.dat` of the same controller with a later trigger is listed: the controller
  ## has moved on, so a stopped recording of it will not be written to again.
  for o in f.entries:
    if o.kind == fkDat and o.sweep.problem.len == 0 and o.sweep.controller == e.sweep.controller and
        o.sweep.triggerNs > e.sweep.triggerNs:
      return true

proc followable(state: var AppState; e: FileEntry): bool =
  ## Whether "Follow the latest" may show `e` now, beyond what every file needs (new, steady,
  ## not shown yet). A signature file is shown only when its sweep is whole, or is a stopped
  ## `.dat` that will not grow: a newer `.dat` of its controller is listed, or it has stayed as
  ## it is for `StoppedShowAfter`. A `.vib` cut inside a frame, or a file its library refuses,
  ## waits (it is tried again once it has changed).
  if e.kind notin SignatureFileKinds: return true
  if not state.settings.files.listSignatureFiles or e.sweep.problem.len > 0: return false
  if e.sweep.complete: return true
  if e.kind != fkDat: return false
  if state.files.newerSameController(e): return true
  if e.steadySince != MonoTime() and fs.now() - e.steadySince >= StoppedShowAfter: return true
  state.stoppedWaiting = true # (nothing will say when the time is up: asked again each frame)

func followKey(e: FileEntry): int64 =
  ## How new a file is for "Follow the latest": a signature file by its trigger (the copy's or
  ## the radio transfer's modification time says nothing), any other by its modification time.
  if e.kind in SignatureFileKinds: sweepKey(e)
  else: int64(e.modified.toUnix) * 1_000_000_000 + e.modified.nanosecond

proc followNewest(state: var AppState) =
  ## With "Follow the latest": shows in the main panel the newest file that
  ## appeared since the folder was listed and is steady, unless it was
  ## followed already (each is shown once, so a file the user stepped away
  ## from is not forced back), failed to open, or is older than the file
  ## followed last (new files that came with a newer one are not shown one
  ## after another, back in time, as the looks go on). A signature file is the newest by
  ## its trigger, and a stopped recording is shown by the rule of `followable`.
  if not state.settings.files.followLatest: return
  template f: untyped = state.files
  state.stoppedWaiting = false
  var best = -1
  for i, e in f.entries:
    if e.kind.isSeismic and e.isNew and e.status == fsSteady and e.path != f.chosen and
        e.path notin state.followed and e.path notin f.failed and
        followKey(e) > state.followedUpTo and state.followable(e) and
        (best < 0 or followKey(e) >= followKey(f.entries[best])):
      best = i
  let k = state.findPanel(MainPanel)
  if best >= 0 and k >= 0:
    let path = f.entries[best].path
    state.followed.incl path
    state.followedUpTo = followKey(f.entries[best])
    state.showPath(k, path, follow = true, by = coWindow) # the user's own setting

proc showAgain(state: var AppState; path: string) =
  ## Shows `path` again in the panels that wait for it (`reopens`).
  var waiting: seq[Reopen]
  for r in state.reopens:
    if r.path == path: waiting.add r
  state.reopens.keepItIf(it.path != path)
  var held = false
  for r in waiting:
    if r.held:
      held = true
      continue
    let k = state.findPanel(r.panel)
    if k >= 0: state.showPath(k, path, r.gather, by = state.openedBy.getOrDefault(path))
  if held: state.openHeld(path)

proc reopen(state: var AppState; i: int; now: bool) =
  ## Open file `sessions[i]` changed on disk: its panels let it go at once
  ## (keeping their display and view), and show it again, opened anew, now,
  ## or with `now` false once it stops changing. A derived view is not a
  ## file on disk: the origin is opened again.
  if state.sessions[i].derived:
    let path = state.sessions[i].diskPath
    var oi = -1
    for j, x in state.sessions:
      if not x.derived and x.diskPath == path: oi = j
    if oi >= 0: state.reopen(oi, now)
    return
  let s = state.sessions[i]
  let path = s.diskPath
  let held = state.correlateOn and state.derivedShown(path)
  for k in 0 ..< state.panels.len:
    template p: untyped = state.panels[k]
    if p.layers.len > 0 and p.layers[0].shows(s.id):
      if held and p.id == MainPanel: continue
      state.reopens.add Reopen(path: path, panel: p.id, gather: p.layers[0].source.gather)
  if held:
    state.reopens.add Reopen(path: path, panel: MainPanel, held: true)
  state.closeSession(i, quiet = true, keepLayers = true)
  if now: state.showAgain(path)

proc reopenWith(state: var AppState; path: string; choice: OpenChoice; by: CommandOrigin) =
  ## "Reopen with options": `path` (canonical) opened anew with `choice`,
  ## which its later opens this run take too, in the panels that show it
  ## (keeping their display, view and record), or in the main panel when
  ## none does. The new open runs first, on the open job; it takes the open
  ## file's place only when it opened with traces (`adopt`), keeping the
  ## selection, the geometry join and the windows of the traces when it has
  ## as many. Else the file stays as it was, and so does its choice: the
  ## choice is written only once the new open is taken in, so a reopen that
  ## is superseded or cancelled leaves the one that was in force. An open
  ## of it under way is no longer wanted.
  let name = path.extractFilename
  for o in state.opening.mitems:
    if o.path == path and not o.unwanted:
      o.unwanted = true
      discard state.jobs.cancel(o.job)
  if not state.prepared.session.isNil and state.prepared.session.path == path:
    state.release(move state.prepared.session) # opened with the options before
    state.prepared = (NoJob, nil)
  var i = -1
  for j, s in state.sessions:
    if not s.derived and s.diskPath == path: i = j
  if i < 0:
    let k = state.findPanel(MainPanel)
    if k >= 0:
      state.showPath(k, path, by = by, asked = choice, forced = true)
      if state.opening.len > 0 and state.opening[^1].path == path:
        template o: untyped = state.opening[^1]
        (o.reopened, o.tried) = (true, choice)
    return
  let id = state.sessions[i].id
  var panel = NoPanel
  var gather = 0
  for p in state.panels:
    if panel == NoPanel and p.layers.len > 0 and p.layers[0].shows(id):
      (panel, gather) = (p.id, p.layers[0].source.gather)
  if keeps(by): state.openedBy[path] = by
  let job = state.jobs.submit(JobSpec(title: "Open " & name, lane: jlInteractive,
    reads: @[path]), openFileWork(path, state.inbox.poster, indexCacheFile(state.indexCache, path),
    whole = false, lines = state.settings.join, choice = choice, pair = state.pairArgOf(path)))
  state.opening.add Pending(job: job, path: path, panel: if panel == NoPanel: MainPanel
    else: panel, gather: gather, by: by, reopened: true, tried: choice, replacesOpen: true)

proc dropKeys(state: var AppState; session: SessionId) =
  ## The keys of open file `session` hold a survey's coordinates (a join): the
  ## file is read again, so that its traces have its own. A file a panel
  ## shows is opened anew and takes its place (`reopenWith`: its selection and
  ## windows stay); another is closed. The file on disk is not changed.
  let i = state.findSession(session)
  if i >= 0:
    let s = state.sessions[i]
    var shown = false
    for p in state.panels:
      if p.layers.len > 0 and p.layers[0].shows(s.id): shown = true
    if s.derived:
      var oi = -1
      for j, x in state.sessions:
        if not x.derived and x.diskPath == s.diskPath: oi = j
      if oi >= 0: state.dropKeys(state.sessions[oi].id)
    elif shown: state.reopenWith(s.diskPath, state.openChoiceOf(s.diskPath), coWindow)
    else: state.closeSession(i, quiet = true)

proc clearSurvey(state: var AppState; cmd: Command) =
  ## `ckClearSurvey`: the survey is taken away wherever it is held. An import
  ## under way is cancelled, and nothing of it is applied later. The files
  ## joined are read again (`dropKeys`), the survey files go off the map, and
  ## the project open forgets its survey (its document, and on a job its
  ## copies and `survey.bin`), so that it does not come back at the next open.
  template p: untyped = state.project
  let keptInProject = state.inProject and (p.doc.hasSurvey or p.doc.hasImport)
  if not state.surveyInEffect: state.ignore(cmd, "no survey is imported")
  elif keptInProject and cmd.origin == coAgent:
    state.ignore(cmd, "agent control writes nothing into a project, and the survey is kept in " &
      "this one")
  elif keptInProject and p.readOnly:
    state.ignore(cmd, "the project is open read-only (" & p.whyReadOnly & ")")
  else:
    # An import under way: cancelled, and what its job does after this is undone.
    if state.joining.job != NoJob:
      state.joining.cleared = true
      discard state.jobs.cancel(state.joining.job)
    elif state.importing:
      for job in state.joining.loads:
        discard state.jobs.cancel(job)
        state.droppedLoads.add job
      state.joining = Joining()
    # The project's survey.
    if state.inProject:
      if p.surveyJob != NoJob: discard state.jobs.cancel(p.surveyJob)
      if p.originalsJob != NoJob: discard state.jobs.cancel(p.originalsJob)
      p.surveyJob = NoJob
      p.originalsJob = NoJob
      p.originals.setLen 0
      p.offer = false
      p.geometry = nil
      p.joinSurvey = JoinSurvey()
      p.queue.setLen 0
      p.survey = srNone
      p.surveyNote = ""
      p.restoreMs = 0
      p.rebuilding = false
      p.layersAfterKeep = false
      if keptInProject:
        p.doc.survey.setLen 0
        p.doc.importing.setLen 0
        p.doc.notes.setLen 0
        p.doc.units = JoinUnits()
        p.doc.imported = Time()
        p.doc.store = StoreInfo()
        state.projectChanged()
        discard state.jobs.submit(JobSpec(title: "Remove the survey from the project",
          lane: jlBackground, exclusive: @[p.dir.partOf(SurveyFolder)]),
          clearSurveyWork(p.dir))
      inc p.revision
    # The files joined: read again, with their own coordinates. Not the one an
    # import under way will undo when its job ends.
    var joined: seq[SessionId]
    for j in state.joins: joined.add j.session
    state.joins.setLen 0
    # The map's survey files.
    var ids: seq[SurveyLayerId]
    for i in 0 ..< state.survey.layers.len:
      if state.survey.layers[i].origin == loSurveyFile: ids.add state.survey.layers[i].id
    for id in ids: discard state.survey.remove(id)
    state.map.followed(state.survey)
    for id in joined: state.dropKeys(id)
    for s in state.sessions: # the records are checked against no survey now
      if s.id notin joined and state.joinedRelations(s.id) < 0: state.checkRecords(s)
    state.joinReport = JoinReport(serial: state.joinReport.serial + 1, session: NoSession,
      outcome: joNone, words: @["The survey was removed: the traces show their own file's " &
      "coordinates again."])
    state.log.add(sevInfo, "survey", "The survey was removed" & (if joined.len > 0:
      ": " & plural(joined.len, "open file") & " read again, with its own coordinates" else: "") &
      (if keptInProject: "; the project " & p.doc.name & " keeps no survey now" else: "") & ".")

proc onDisk(state: var AppState; w: WatchedFile) =
  ## What the watch saw of a file that is open, or that a panel waits for:
  ## a file another program changed is opened again once it stops changing,
  ## and one it cut short is let go of at once, so nothing reads past its new
  ## end (which would end the program); a file removed or renamed stays shown
  ## as it was read.
  let name = w.path.extractFilename
  var i = -1
  for j, s in state.sessions:
    if not s.derived and s.diskPath == w.path: i = j
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
  var sweepsChanged = false # a signature file came, went or changed: the pairs are made again
  for w in m.watched:
    if listing and w.listed:
      let i = f.find(w.path)
      if w.kind in SignatureFileKinds: sweepsChanged = true
      if not w.exists:
        if i >= 0:
          gone.add i
          sweepsChanged = sweepsChanged or f.entries[i].kind in SignatureFileKinds
        let failed = f.failed.find(w.path)
        if failed >= 0: f.failed.delete(failed)
      elif i < 0:
        if w.kind != fkUnknown:
          fresh.add FileEntry(path: w.path, name: w.path.extractFilename,
            folder: if f.recursive: f.folder.folderOf(w.path) else: "", kind: w.kind, size: w.size,
                modified: w.modified,
            status: (if w.changing: fsWriting else: fsSteady), isNew: true, sweep: w.sweep,
            steadySince: (if w.changing: MonoTime() else: fs.now()))
      else:
        template e: untyped = f.entries[i]
        let same = e.size == w.size and e.modified == w.modified
        if not same: e.kindState = ksUnread # its traces may have changed: read again
        e.size = w.size
        e.modified = w.modified
        if w.kind in SignatureFileKinds: e.sweep = w.sweep
        if w.changing: e.steadySince = MonoTime()
        elif e.steadySince == MonoTime(): e.steadySince = fs.now()
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
  if sweepsChanged: state.refreshPairs()
  state.startKinds()
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
  ## `ckEdit`, `ckReverseAll`, `ckUndoEdit`, `ckRedoEdit`, `ckClearEdits`
  ## on the file `cmd.panel` shows: a step of its history, kept with the
  ## file when `keeps(cmd.origin)` (an agent's is shown for the session
  ## only); the panels that show a gather the step touches make their
  ## view's tiles again.
  let k = state.findPanel(cmd.panel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if k < 0:
    state.ignore(cmd, $cmd.panel & " does not exist")
    return
  if i < 0:
    state.ignore(cmd, $cmd.panel & (if cmd.kind == ckReverseAll: " shows nothing"
      else: " shows no file"))
    return
  let s = state.sessions[i]
  let keep = keeps(cmd.origin)
  var changed = EditStep()
  var said = ""
  template e: untyped = state.edits.mgetOrPut(state.keyOf(s.path), FileEdits())
  case cmd.kind
  of ckEdit:
    var traces: seq[int]
    for t in cmd.edited:
      if t in s: traces.add t - s.base
    if cmd.edited.len == 0: state.ignore(cmd, "no trace was named")
    elif traces.len < cmd.edited.len:
      state.ignore(cmd, plural(cmd.edited.len - traces.len, "trace") & " of " &
        $cmd.edited.len & " are not in " & s.name)
    var n = 0
    if traces.len > 0 and not cmd.on and (cmd.alsoDrop != {} or cmd.alsoFilter or
        cmd.alsoShift):
      var kinds = cmd.alsoDrop
      kinds.incl cmd.edit
      n = e.dropEdits(traces, kinds, cmd.alsoFilter, keep, shifts = cmd.alsoShift)
    elif traces.len > 0:
      n = e.change(cmd.edit, traces, cmd.on, keep)
    if n > 0:
      changed = e.nextUndo
      said = describe(changed).capitalizeAscii & "."
      state.stampEdits(s) # made on the file as it is now
  of ckOwnFilter:
    var traces: seq[int]
    for t in cmd.edited:
      if t in s: traces.add t - s.base
    if cmd.edited.len == 0: state.ignore(cmd, "no trace was named")
    elif traces.len < cmd.edited.len:
      state.ignore(cmd, plural(cmd.edited.len - traces.len, "trace") & " of " &
        $cmd.edited.len & " are not in " & s.name)
    let n = if cmd.on: e.setOwnFilters(traces, bounded(OwnFilter(spec: cmd.processing,
      place: cmd.filterPlace)), keep)
            else: e.clearOwnFilters(traces, keep)
    if n > 0:
      changed = e.nextUndo
      said = describe(changed).capitalizeAscii & "."
      state.stampEdits(s)
  of ckTimeShift:
    var traces: seq[int]
    for t in cmd.edited:
      if t in s: traces.add t - s.base
    if cmd.edited.len == 0: state.ignore(cmd, "no trace was named")
    elif traces.len < cmd.edited.len:
      state.ignore(cmd, plural(cmd.edited.len - traces.len, "trace") & " of " &
        $cmd.edited.len & " are not in " & s.name)
    var dt = 0.0
    if state.panels[k].laidOut and not state.panels[k].layout.noInterval:
      dt = state.panels[k].layout.dtMs
    if not (dt > 0) and traces.len > 0 and s.filePtr != nil:
      let f = s.filePtr
      for t in traces:
        if t in 0 ..< f[].len and isSeismic(f[].index, t):
          let us = f[].sampleIntervalUs(t)
          if us > 0 and us < Inf:
            dt = us / 1000.0
            break
    if traces.len > 0 and cmd.on and not shiftStorable(cmd.ms):
      state.ignore(cmd, shiftRefusal(cmd.ms))
    elif traces.len > 0 and cmd.on and not (dt > 0):
      state.ignore(cmd, "the sample interval is not known")
    elif traces.len > 0:
      let n = if cmd.on: e.setTimeShifts(traces, cmd.ms, dt, keep)
              else: e.clearTimeShifts(traces, keep)
      let snapped = if cmd.on: e.shiftOf(traces[0]) else: 0.0
      let text = if snapped == trunc(snapped) and abs(snapped) < 1e15: $int64(snapped)
                 else: formatFloat(snapped, ffDecimal, 3)
      said = "Shifted " & plural(traces.len, "trace") & " by " & text & " ms."
      if n > 0:
        changed = e.nextUndo
        state.stampEdits(s)
  of ckReverseAll:
    if e.setAllReversed(cmd.reverse, keep):
      changed = e.nextUndo
      said = describe(changed).capitalizeAscii & "."
      state.stampEdits(s)
  of ckUndoEdit:
    if state.keyOf(s.path) in state.edits: changed = state.edits[state.keyOf(s.path)].undo(keep)
    said = if changed.kind == skNone: "Nothing to undo."
           else: "Undone: " & describe(changed) & "."
  of ckRedoEdit:
    if state.keyOf(s.path) in state.edits: changed = state.edits[state.keyOf(s.path)].redo(keep)
    said = if changed.kind == skNone: "Nothing to redo."
           else: "Redone: " & describe(changed) & "."
  of ckClearEdits:
    if state.keyOf(s.path) in state.edits and state.edits[state.keyOf(s.path)].clearAll(keep):
      changed = state.edits[state.keyOf(s.path)].nextUndo
      said = "All edits cleared: the traces are shown as the file has them (Edit > Undo, " &
        "Ctrl+Z, brings the edits back)."
    else: said = "No edits to clear."
  else: discard
  if said.len > 0:
    state.log.add(sevInfo, s.name, said & (if keep or changed.kind == skNone: ""
      else: " (For this session only: an agent's change is not remembered with the file.)"))
  if changed.kind != skNone:
    state.editsChanged(s.diskPath, changed)
    let at = state.rememberedAt(s.path)
    if keep and at >= 0:
      state.hashFile(at) # its document will name every byte
      state.sayNotYetRemembered(at)

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
  let shown = state.shownFile(k)
  if shown >= 0:
    if state.sessions[shown].file.readFailed:
      # A mapped file whose read failed reads as cut for as long as it is
      # mapped (parseSEG's guard): only a new open reads it again.
      state.log.add(sevInfo, state.sessions[shown].name, "Opening " &
        state.sessions[shown].name & " again: a read of it failed, and a mapped file " &
        "stays unread until it is opened again.")
      state.reopen(shown, now = true)
      return
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
  if state.sessions.anyIt(it.path == want) or state.opening.anyIt(not it.unwanted) or
      want in state.openChoices: # (opened as its options say when it is shown)
    return
  let e = state.files.find(want)
  if e < 0 or not state.files.entries[e].kind.isSeismic or
      state.files.entries[e].status != fsSteady or state.files.entries[e].size > MaxPrepareBytes:
    return # (a file being written is opened when it is shown)
  let k = state.findPanel(MainPanel)
  if k < 0 or not state.panels[k].laidOut or state.tiles[k].len == 0: return
  if state.files.entries[e].kind in SignatureFileKinds:
    # A signature file is decoded whole (there is no first view to read): the same open job as
    # a click's, with the options and the pair a click would give it.
    if state.files.entries[e].sweep.problem.len > 0: return
    let job = state.jobs.submit(JobSpec(title: "Prepare " & want.extractFilename,
      lane: jlBackground, auto: true, reads: @[want]), openSignatureWork(want,
      state.inbox.poster, state.openChoiceOf(want).signature, state.pairArgOf(want)))
    state.preparing = (job, want)
    return
  let r = state.panels[k].pending # the first view's read, as the next file is shown alike
  let job = state.jobs.submit(JobSpec(title: "Prepare " & want.extractFilename,
    lane: jlBackground, auto: true, reads: @[want]), prepareWork(want, state.inbox.poster,
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
  state.followHidden()
  state.followAux()
  state.followInspect()
  let followed = state.filesHeldByFollow()
  state.followSpectrum()
  state.followPlots()
  state.releaseFollowed(followed)
  state.followMapWork()
  state.followProject()
  state.followMoves()

const
  NeedProjectPatterns* = "Open or make a project to keep name patterns."
    ## said when a name pattern is saved, deleted or chosen with no project open
  ReadOnlyPatterns* = "The project is open read-only."
    ## said when the project open cannot be written

func namePatternCap*(): string =
  ## Why one more name pattern cannot be kept.
  "at most " & $MaxOutputPatterns & " name patterns are kept; delete one first"

func noNamePattern*(name: string): string =
  ## Why a label that names nothing cannot be deleted or chosen.
  "no name pattern is named \"" & name & "\""

func findPattern(patterns: openArray[OutputPattern]; name: string): int =
  # The pattern whose label matches `name`, spaces stripped, case ignored.
  # -1 when `name` is empty or names nothing.
  let want = strip(name)
  if want.len == 0: return -1
  for i, p in patterns:
    if cmpRunesIgnoreCase(p.name, want) == 0: return i
  -1

proc namePattern(state: var AppState; cmd: Command) =
  ## Save, delete or choose a file-name pattern in the project open. Kept
  ## whoever asks: the project is the only copy. What cannot be done is said,
  ## and the project is not marked changed.
  if not state.inProject:
    state.log.add(sevWarning, "commands", NeedProjectPatterns)
    return
  if state.project.readOnly:
    state.log.add(sevWarning, "commands", ReadOnlyPatterns)
    return
  template say(sentence: string) =
    state.log.add(sevWarning, "commands", sentence)
  case cmd.patternAction
  of npaSave:
    var p = cmd.namePattern
    p.name = strip(p.name)
    let why = patternProblem(p)
    if why.len > 0:
      say(why)
      return
    let i = findPattern(state.project.doc.outputPatterns, p.name)
    if i < 0 and state.project.doc.outputPatterns.len >= MaxOutputPatterns:
      say(namePatternCap())
      return
    if i >= 0:
      let was = state.project.doc.outputPatterns[i].name
      state.project.doc.outputPatterns[i] = p
      if cmpRunesIgnoreCase(state.project.doc.outputPattern, was) == 0:
        state.project.doc.outputPattern = p.name
    else:
      state.project.doc.outputPatterns.add p
      state.project.doc.outputPatternLater.setLen(state.project.doc.outputPatterns.len)
    state.project.doc.hasOutputPatterns = true
    state.projectChanged()
  of npaDelete:
    let label = strip(cmd.namePattern.name)
    if label.len == 0:
      say(patternProblem(cmd.namePattern))
      return
    let i = findPattern(state.project.doc.outputPatterns, label)
    if i < 0:
      say(noNamePattern(label))
      return
    let was = state.project.doc.outputPatterns[i].name
    state.project.doc.outputPatterns.delete(i)
    if i < state.project.doc.outputPatternLater.len:
      state.project.doc.outputPatternLater.delete(i)
    if cmpRunesIgnoreCase(state.project.doc.outputPattern, was) == 0:
      state.project.doc.outputPattern = ""
    state.project.doc.hasOutputPatterns = true
    state.projectChanged()
  of npaChoose:
    let label = strip(cmd.namePattern.name)
    if label.len == 0:
      if state.project.doc.outputPattern.len > 0:
        state.project.doc.outputPattern = ""
        state.projectChanged()
      return
    let i = findPattern(state.project.doc.outputPatterns, label)
    if i < 0:
      say(noNamePattern(label))
      return
    let stored = state.project.doc.outputPatterns[i].name
    if state.project.doc.outputPattern != stored:
      state.project.doc.outputPattern = stored
      state.projectChanged()

const
  NeedProjectTexts* = "Open or make a project to keep text header templates."
    ## said when an output text is saved, deleted or chosen with no project open

func outputTextCap*(): string =
  ## Why one more text header template cannot be kept.
  "at most " & $MaxOutputTexts & " text header templates are kept; delete one first"

func noOutputText*(name: string): string =
  ## Why a name that names no template cannot be deleted or chosen.
  "no text header template is named \"" & name & "\""

func findText(texts: openArray[OutputText]; name: string): int =
  # The template whose name matches `name`, spaces stripped, case ignored.
  # -1 when `name` is empty or names nothing.
  let want = strip(name)
  if want.len == 0: return -1
  for i, t in texts:
    if cmpRunesIgnoreCase(t.name, want) == 0: return i
  -1

proc outputText(state: var AppState; cmd: Command) =
  ## Save, delete or choose a text header template in the project open, as
  ## `namePattern` does for a name pattern: the project is the only copy;
  ## what cannot be done is said and the project is not marked changed.
  if not state.inProject:
    state.log.add(sevWarning, "commands", NeedProjectTexts)
    return
  if state.project.readOnly:
    state.log.add(sevWarning, "commands", ReadOnlyPatterns)
    return
  template say(sentence: string) =
    state.log.add(sevWarning, "commands", sentence)
  case cmd.textAction
  of otaSave:
    var t = cmd.textTemplate
    t.name = strip(t.name)
    let why = textProblem(t)
    if why.len > 0:
      say(why)
      return
    let i = findText(state.project.doc.outputTexts, t.name)
    if i < 0 and state.project.doc.outputTexts.len >= MaxOutputTexts:
      say(outputTextCap())
      return
    if i >= 0:
      let was = state.project.doc.outputTexts[i].name
      state.project.doc.outputTexts[i] = t
      if cmpRunesIgnoreCase(state.project.doc.outputText, was) == 0:
        state.project.doc.outputText = t.name
    else:
      state.project.doc.outputTexts.add t
      state.project.doc.outputTextLater.setLen(state.project.doc.outputTexts.len)
    state.project.doc.hasOutputTexts = true
    state.projectChanged()
  of otaDelete:
    let label = strip(cmd.textTemplate.name)
    if label.len == 0:
      say(textProblem(cmd.textTemplate))
      return
    let i = findText(state.project.doc.outputTexts, label)
    if i < 0:
      say(noOutputText(label))
      return
    let was = state.project.doc.outputTexts[i].name
    state.project.doc.outputTexts.delete(i)
    if i < state.project.doc.outputTextLater.len:
      state.project.doc.outputTextLater.delete(i)
    if cmpRunesIgnoreCase(state.project.doc.outputText, was) == 0:
      state.project.doc.outputText = ""
    state.project.doc.hasOutputTexts = true
    state.projectChanged()
  of otaChoose:
    let label = strip(cmd.textTemplate.name)
    if label.len == 0:
      if state.project.doc.outputText.len > 0:
        state.project.doc.outputText = ""
        state.projectChanged()
      return
    let i = findText(state.project.doc.outputTexts, label)
    if i < 0:
      say(noOutputText(label))
      return
    let stored = state.project.doc.outputTexts[i].name
    if state.project.doc.outputText != stored:
      state.project.doc.outputText = stored
      state.projectChanged()

const
  NeedProjectAuxMarks* = "Open or make a project to keep auxiliary marks in it."
    ## said when a project's auxiliary mark is set with no project open

proc askCorrelateAgain(state: var AppState; path: string) =
  ## A mark in force for the file at `path` changed: the correlated view of it on show, or
  ## the one being made, if any, is asked for again, as a change of the reference is.
  let oi = state.originIndex(path)
  if oi >= 0 and state.correlateOn and (state.derivedShown(state.sessions[oi].diskPath) or
      (not state.correlate.isNil and state.correlate.origin == state.sessions[oi].diskPath)):
    state.startCorrelate(oi, keepView = true)

func auxMarkWords(position: int; state: AuxMarkState; ms: float64): string =
  let what = "Auxiliary trace " & $position
  case state
  of amMarked:
    let text = if ms == trunc(ms) and abs(ms) < 1e15: $int64(ms) else: formatFloat(ms, ffDecimal, 3)
    what & " is marked for correlation, shifted by " & text & " ms"
  of amNotMarked: what & " is marked not for correlation"
  of amForget: what & " has no mark"

proc fileAuxMark(state: var AppState; cmd: Command) =
  ## `ckFileAuxMark`: the mark of an auxiliary position of an open file, a step of the file's
  ## edits (undo takes it back), kept with them when `keeps(cmd.origin)`.
  let path = canonical(cmd.auxFile)
  let oi = state.originIndex(path)
  if oi < 0:
    state.ignore(cmd, path & " is not open")
    return
  if not auxPositionStorable(cmd.auxPosition):
    state.ignore(cmd, "the auxiliary trace position is from 1 to " & $MaxAuxPosition)
    return
  if cmd.auxMarked == amMarked and not shiftStorable(cmd.auxShiftMs):
    state.ignore(cmd, shiftRefusal(cmd.auxShiftMs))
    return
  let s = state.sessions[oi]
  let keep = keeps(cmd.origin)
  template e: untyped = state.edits.mgetOrPut(state.keyOf(s.path), FileEdits())
  if e.setAuxMark(cmd.auxPosition, cmd.auxMarked, cmd.auxShiftMs, keep) > 0:
    let changed = e.nextUndo
    state.stampEdits(s)
    state.log.add(sevInfo, s.name, auxMarkWords(cmd.auxPosition, cmd.auxMarked,
      cmd.auxShiftMs) & (if keep: "." else:
      " (For this session only: an agent's change is not remembered with the file.)"))
    state.editsChanged(s.diskPath, changed)
    let at = state.rememberedAt(s.path)
    if keep and at >= 0:
      state.hashFile(at)
      state.sayNotYetRemembered(at)

proc projectAuxMark(state: var AppState; cmd: Command) =
  ## `ckProjectAuxMark`: the mark of an auxiliary position for every file of the project open,
  ## kept in the project document as a project's list is; what cannot be done is said.
  if not state.inProject:
    state.log.add(sevWarning, "commands", NeedProjectAuxMarks)
    return
  if state.project.readOnly:
    state.log.add(sevWarning, "commands", ReadOnlyPatterns)
    return
  if not auxPositionStorable(cmd.auxPosition):
    state.ignore(cmd, "the auxiliary trace position is from 1 to " & $MaxAuxPosition)
    return
  if cmd.auxMarked == amNotMarked:
    state.ignore(cmd, "a project's mark is \"yes\" or \"forget\"; a file's \"no\" overrides it")
    return
  if cmd.auxMarked == amMarked and not shiftStorable(cmd.auxShiftMs):
    state.ignore(cmd, shiftRefusal(cmd.auxShiftMs))
    return
  var marks = state.project.doc.auxMarks
  var at = -1
  for i, m in marks:
    if m.position == cmd.auxPosition: at = i
  let want = AuxMarkEntry(position: cmd.auxPosition, marked: true, ms: cmd.auxShiftMs)
  if cmd.auxMarked == amMarked:
    if at < 0:
      marks.add want
      marks.sort(proc (a, b: AuxMarkEntry): int = cmp(a.position, b.position))
    elif marks[at] != want: marks[at] = want
    else: return
  elif at >= 0: marks.delete(at)
  else: return
  state.project.doc.auxMarks = marks
  state.projectChanged()
  state.log.add(sevInfo, "project", auxMarkWords(cmd.auxPosition, cmd.auxMarked,
    cmd.auxShiftMs) & " in every file of the project.")
  for s in state.sessions:
    if not s.derived: state.askCorrelateAgain(s.diskPath)

const
  NeedProjectBinaries* = "Open or make a project to keep binary header sets."
    ## said when a binary header set is saved, deleted or chosen with no project open

func outputBinaryCap*(): string =
  ## Why one more binary header set cannot be kept.
  "at most " & $MaxOutputBinaries & " binary header sets are kept; delete one first"

func noOutputBinary*(name: string): string =
  ## Why a name that names no set cannot be deleted or chosen.
  "no binary header set is named \"" & name & "\""

func findBinary(sets: openArray[OutputBinary]; name: string): int =
  # The set whose name matches `name`, spaces stripped, case ignored.
  # -1 when `name` is empty or names nothing.
  let want = strip(name)
  if want.len == 0: return -1
  for i, b in sets:
    if cmpRunesIgnoreCase(b.name, want) == 0: return i
  -1

proc outputBinary(state: var AppState; cmd: Command) =
  ## Save, delete or choose a binary header set in the project open, as
  ## `outputText` does for a text header template: the project is the only
  ## copy; what cannot be done is said and the project is not marked changed.
  if not state.inProject:
    state.log.add(sevWarning, "commands", NeedProjectBinaries)
    return
  if state.project.readOnly:
    state.log.add(sevWarning, "commands", ReadOnlyPatterns)
    return
  template say(sentence: string) =
    state.log.add(sevWarning, "commands", sentence)
  case cmd.binaryAction
  of obaSave:
    var b = cmd.binarySet
    b.name = strip(b.name)
    let why = binaryProblem(b)
    if why.len > 0:
      say(why)
      return
    let i = findBinary(state.project.doc.outputBinaries, b.name)
    if i < 0 and state.project.doc.outputBinaries.len >= MaxOutputBinaries:
      say(outputBinaryCap())
      return
    if i >= 0:
      let was = state.project.doc.outputBinaries[i].name
      state.project.doc.outputBinaries[i] = b
      if cmpRunesIgnoreCase(state.project.doc.outputBinary, was) == 0:
        state.project.doc.outputBinary = b.name
    else:
      state.project.doc.outputBinaries.add b
      state.project.doc.outputBinaryLater.setLen(state.project.doc.outputBinaries.len)
    state.project.doc.hasOutputBinaries = true
    state.projectChanged()
  of obaDelete:
    let label = strip(cmd.binarySet.name)
    if label.len == 0:
      say(binaryProblem(cmd.binarySet))
      return
    let i = findBinary(state.project.doc.outputBinaries, label)
    if i < 0:
      say(noOutputBinary(label))
      return
    let was = state.project.doc.outputBinaries[i].name
    state.project.doc.outputBinaries.delete(i)
    if i < state.project.doc.outputBinaryLater.len:
      state.project.doc.outputBinaryLater.delete(i)
    if cmpRunesIgnoreCase(state.project.doc.outputBinary, was) == 0:
      state.project.doc.outputBinary = ""
    state.project.doc.hasOutputBinaries = true
    state.projectChanged()
  of obaChoose:
    let label = strip(cmd.binarySet.name)
    if label.len == 0:
      if state.project.doc.outputBinary.len > 0:
        state.project.doc.outputBinary = ""
        state.projectChanged()
      return
    let i = findBinary(state.project.doc.outputBinaries, label)
    if i < 0:
      say(noOutputBinary(label))
      return
    let stored = state.project.doc.outputBinaries[i].name
    if state.project.doc.outputBinary != stored:
      state.project.doc.outputBinary = stored
      state.projectChanged()

proc displayPreset(state: var AppState; cmd: Command) =
  ## A named display preset (`core/displaypresets`) applied to a panel, or
  ## saved, renamed or deleted: in the settings in effect, and in those kept
  ## when a window asks (`change`). What cannot be done is said, checked on
  ## the presets in effect. While a project is open the presets are its
  ## own: a window's change is kept in the project, not in the settings.
  let inProject = state.inProject
  let by = if inProject: coAgent else: cmd.origin # (in effect only: the project keeps them)
  defer:
    if inProject and keeps(cmd.origin) and not state.project.readOnly and
        state.settings.displayPresets != state.project.doc.displayPresets:
      state.project.doc.displayPresets = state.settings.displayPresets
      state.project.doc.hasPresets = true
      state.projectChanged()
  let k = state.findPanel(cmd.panel)
  var why = ""
  if cmd.presetAction in {paApply, paSave} and k < 0:
    state.ignore(cmd, $cmd.panel & " does not exist")
  elif cmd.presetAction in {paApply, paSave} and state.panels[k].layers.len == 0:
    state.ignore(cmd, $cmd.panel & " shows nothing")
  else:
    let (name, newName) = (cmd.presetName, cmd.presetNewName)
    case cmd.presetAction
    of paApply:
      let i = state.settings.displayPresets.find(name)
      if i < 0: state.ignore(cmd, "no display preset is named \"" & cleanName(name) & "\"")
      else:
        state.applyCommand Command(origin: cmd.origin, kind: ckDisplay, panel: cmd.panel,
          display: withPreset(state.panels[k].layers[0].display,
          state.settings.displayPresets[i].display))
    of paSave:
      let d = state.panels[k].layers[0].display
      discard saved(state.settings.displayPresets, name, d, why)
      if why.len > 0: state.ignore(cmd, why)
      else: state.change(by, s): s.displayPresets = saved(s.displayPresets, name, d, why)
    of paRename:
      discard renamed(state.settings.displayPresets, name, newName, why)
      if why.len > 0: state.ignore(cmd, why)
      else:
        state.change(by, s):
          s.displayPresets = renamed(s.displayPresets, name, newName, why)
    of paDelete:
      discard deleted(state.settings.displayPresets, name, why)
      if why.len > 0: state.ignore(cmd, why)
      else: state.change(by, s): s.displayPresets = deleted(s.displayPresets, name, why)

proc holdCursor(state: var AppState; cmd: Command) =
  ## `ckSpectrumCursor`: a spectrum window's cursor held at a bin's
  ## frequency and on a curve (within those its plot shows), or let go.
  let w = state.findSpectrum(cmd.spectrum)
  if w < 0:
    state.ignore(cmd, "there is no spectrum window " & $cmd.spectrum)
    return
  template sw: untyped = state.spectra[w]
  if cmd.cursor.held and sw.spectrum.raw.len == 0:
    state.ignore(cmd, sw.title & " has no spectrum to put its cursor on")
    return
  let was = (sw.cursor, sw.cursorHz, sw.cursorCurve)
  let moved = sw.holdAt(cmd.cursor) # a frequency and a curve, kept so by `followSpectrum`
  if cmd.origin == coAgent: # the keys never ask past the plot
    for words in moved: state.log.add(sevInfo, "spectrum", sw.title & "'s cursor: " & words)
  if (sw.cursor, sw.cursorHz, sw.cursorCurve) != was: inc sw.revision

proc stepTrace(state: var AppState; cmd: Command) =
  ## `ckStepTrace`: the next (or previous) trace of the record, in the
  ## order shown, selected alone, and the plot scrolled to keep it in view.
  ## From an FFT window of one trace: from its trace; else from the
  ## selection (the trace clicked last; else its last, or its first going
  ## back: `stepStart`), else the trace under the pointer, else the first in
  ## view. A frozen FFT window keeps its trace and steps the plot's
  ## selection (from its own trace while nothing is selected or under the
  ## pointer). One not frozen follows that selection, as every other change
  ## of the plot (`followSpectra`).
  if cmd.stepBy == 0:
    state.ignore(cmd, "a step of 0 traces")
    return
  let w = if cmd.spectrum != LiveSpectrum: state.findSpectrum(cmd.spectrum) else: 0
  if w < 0:
    state.ignore(cmd, "there is no FFT window " & $cmd.spectrum)
    return
  let panel = if w > 0: state.spectra[w].panel
              elif cmd.spectrumOf == NoPanel: MainPanel
              else: cmd.spectrumOf
  let k = state.findPanel(panel)
  let i = if k >= 0: state.shownFile(k) else: -1
  if i < 0 or not state.panels[k].laidOut or state.panels[k].shown.len == 0:
    state.ignore(cmd, "the plot shows no trace to step through")
    return
  template p: untyped = state.panels[k]
  let s = state.sessions[i]
  # A frozen FFT window keeps its trace: it steps the plot's selection (from
  # its own trace while nothing is selected or under the pointer).
  let frozen = w > 0 and state.spectra[w].frozen
  let own = if w > 0 and state.spectra[w].traces.len == 1 and state.spectra[w].traces[0] in s:
              p.shown.find(state.spectra[w].traces[0] - s.base)
            else: -1
  var start = if frozen: -1 else: own
  if start < 0: start = state.selection.stepStart(p.shown, s.base, cmd.stepBy)
  if start < 0: start = own
  let to = if start >= 0: start + cmd.stepBy
           else: visiblePositions(p.layout, p.view).a
  if to notin 0 ..< p.shown.len:
    state.ignore(cmd, "the record " & (if to < 0: "starts" else: "ends") & " there")
    return
  let trace = s.base + p.shown[to]
  state.selection.select([trace], smReplace)
  # The plot keeps it in view: scrolled by as little as it takes.
  var v = p.view
  let width = v.traces.hi - v.traces.lo
  if float64(to) - 0.5 < v.traces.lo: v.traces = Span(lo: float64(to) - 0.5,
    hi: float64(to) - 0.5 + width)
  elif float64(to) + 0.5 > v.traces.hi: v.traces = Span(lo: float64(to) + 0.5 - width,
    hi: float64(to) + 0.5)
  v = kept(v, p.viewLimits(v.columns))
  if v != p.view:
    p.view = v
    inc p.jumps # set by `core`: the frontend follows
    state.requestView(k)
    state.settleGain(k, cmd.origin)
  # A frozen FFT window keeps its trace; one not frozen follows the selection
  # `followSpectra` picks from this step.
  if frozen and cmd.origin == coAgent:
    state.log.add(sevInfo, "spectrum", state.spectra[w].title & " is frozen: it keeps its " &
      "trace (the plot's selection stepped to trace " & $(p.shown[to] + 1) & ")")

proc loadReferences(state: var AppState; folder: string; main: bool) =
  ## Reads the archive in `folder`, off this thread.
  if folder.len == 0: return
  discard state.jobs.submit(JobSpec(title: "Read the reference archive", lane: jlInteractive),
    listWork(folder, main, state.inbox.poster))

proc refsWritable(state: AppState): string =
  ## Why the archive in force cannot be written; "" when it can.
  if state.refsHome.len == 0: "there is no reference archive in this run"
  elif state.inProject and state.project.readOnly:
    "the project is open read-only (" & state.project.whyReadOnly & ")"
  else: ""

proc keepChoice(state: var AppState; origin: CommandOrigin; id: string) =
  ## The plots use reference `id` ("" : none). Kept in the
  ## project when one is open, else in the settings, and only when the user
  ## asked (`keeps`).
  state.chosenRef = id
  inc state.refsRev
  if state.inProject:
    if keeps(origin) and not state.project.readOnly:
      state.project.doc.referenceId = id
      state.projectChanged()
    elif keeps(origin) and state.project.readOnly:
      state.log.add(sevWarning, "references", "The project is read-only: this choice is " &
        "for this run only.")
  else:
    state.change(origin, s): s.referenceId = id

proc shownDtMs(state: AppState): float64 =
  ## The sample interval of the file the Seismic window shows, in ms; 0 when
  ## it shows none, or the headers give none.
  let k = state.findPanel(MainPanel)
  if k < 0 or not state.panels[k].laidOut or state.panels[k].layout.noInterval: return 0
  state.panels[k].layout.dtMs

func shownLengthMs*(state: AppState): float64 =
  ## The length of the longest trace of the record the Seismic window shows, in ms
  ## (samples × interval, 12 000 samples at 1 ms are 12 000 ms); 0 when it shows none, or the
  ## headers give no interval.
  let k = state.findPanel(MainPanel)
  if k < 0 or not state.panels[k].laidOut or state.panels[k].layout.noInterval or
      state.panels[k].layout.samples < 2: return 0
  float64(state.panels[k].layout.samples) * state.panels[k].layout.dtMs

func shownIntervalMs*(state: AppState): float64 {.inline.} =
  ## `shownDtMs`, for the Generate dialog's default.
  state.shownDtMs

proc storeReference(state: var AppState; cmd: Command) =
  let why = state.refsWritable
  if why.len > 0:
    state.ignore(cmd, why)
    return
  let name = cmd.refStore.name.strip
  if name.len == 0:
    state.ignore(cmd, "a reference needs a name")
    return
  if state.refsLoaded:
    let problem = state.refs.nameProblem(name)
    if problem.len > 0:
      state.ignore(cmd, problem)
      return
  let i = state.findTrace(cmd.refStore.trace)
  if i < 0:
    state.ignore(cmd, "the trace is in no open file")
    return
  var s = state.sessions[i]
  let local = cmd.refStore.trace - s.base
  if s.derived:
    let oi = state.originIndex(s.diskPath)
    if oi < 0 or local notin 0 ..< state.sessions[oi].len:
      state.ignore(cmd, "the raw record is not open")
      return
    s = state.sessions[oi]
  let edits = state.editsAt(s.path)
  if cmd.refStore.phaseDeg != 0 and cmd.refStore.phaseDeg != 180:
    state.ignore(cmd, "the phase of a recorded trace is 0 or 180 degrees")
    return
  if edits.has(teKilled, local):
    state.ignore(cmd, "the trace is killed")
    return
  if local in 0 ..< s.filePtr[].index.keys.len and s.filePtr[].index.keys[local].status == tsDead:
    state.ignore(cmd, "the trace is marked dead")
    return
  var record = NaN
  let g = s.gatherOf(local)
  if g >= 0 and g < s.records.len: record = s.records[g].record
  let span = indexedSpan(s.filePtr, local)
  discard state.jobs.submit(JobSpec(title: "Store a reference", lane: jlInteractive,
    reads: @[s.path]), storeWork(s.filePtr, s.path, s.size, local, cmd.refStore.fromMs,
    cmd.refStore.toMs, span.intervalUs, record, s.name, name, state.refsHome, local + 1,
    edits.has(teReversed, local), edits.shiftOf(local), cmd.refStore.phaseDeg,
    state.inbox.poster))

proc generateReference(state: var AppState; cmd: Command) =
  let why = state.refsWritable
  if why.len > 0:
    state.ignore(cmd, why)
    return
  var g = cmd.refGenerate
  if not (g.dtMs > 0): g.dtMs = state.shownDtMs
  if not (g.dtMs > 0):
    state.ignore(cmd, "no sample interval: name one, or show a file that has one")
    return
  let tooLong = sweepTooLong(g)
  if tooLong.len > 0:
    state.ignore(cmd, tooLong)
    return
  if g.name.strip.len == 0: g.name = defaultGenerateName(g)
  if state.refsLoaded:
    let problem = state.refs.nameProblem(g.name)
    if problem.len > 0:
      state.ignore(cmd, problem)
      return
  discard state.jobs.submit(JobSpec(title: "Generate a reference", lane: jlInteractive),
    generateWork(g, state.refsHome, state.inbox.poster))

proc pilotKey(rule: PilotRule; file, record: string; trace: int; flip: bool;
    filters, own: string): string =
  ## What a pilot of the record depends on, so a late answer is dropped and a
  ## change of its reversal, filters or own filter asks again.
  file & "|" & record & "|" & $trace & "|" & $flip & "|" & $rule.aux & "|" & $rule.trace &
    "|" & $rule.startMs & "|" & $rule.spanMs & "|" & $rule.phaseDeg & "|" & filters & "|" & own

proc shownRecord(state: AppState): tuple[i, g: int] =
  ## The file and the gather (record) the Seismic window shows; -1 for none.
  result = (-1, -1)
  let k = state.findPanel(MainPanel)
  if k < 0 or not state.panels[k].laidOut or state.panels[k].layers.len == 0: return
  let i = state.shownFile(k)
  if i < 0: return
  result = (i, state.panels[k].layers[0].source.gather)

func pilotShownKey*(state: AppState): string =
  ## Which record the Seismic window shows (its file and gather): what the Generate
  ## dialog's pilot preview must follow.
  let (i, g) = state.shownRecord
  if i < 0: "" else: state.sessions[i].path & "#" & $g

proc pilotPreviewAsk(state: var AppState; cmd: Command) =
  ## The pilot `cmd.refPilot` would take from the record on show, read off the
  ## UI thread; what the dialog keeps until the new one is ready.
  let rule = cmd.refPilot
  let (i, g) = state.shownRecord
  template shown: untyped = state.pilotShown
  proc say(state: var AppState; problem, record: string; key: string) =
    inc state.pilotShown.gen
    state.pilotShown = PilotPreview(key: key, record: record, problem: problem,
      gen: state.pilotShown.gen)
  let bad = pilotProblem(rule)
  if bad.len > 0:
    state.say(bad, "", "bad")
    return
  if i < 0:
    state.say(NoFilePilot, "", "none")
    return
  let s = state.sessions[i]
  let edits = state.editsAt(s.path)
  let (trace, record, problem) = s.pilotOfRecord(g, rule, edits)
  let flip = trace >= 0 and edits.has(teReversed, trace)
  let key = pilotKey(rule, s.path, record, trace, flip, "",
    if trace >= 0: pilotKeyOf(edits, trace) else: "")
  if problem.len > 0:
    state.say(problem, record, key)
    return
  if shown.key == key and (shown.waiting or shown.problem.len == 0): return
  shown.key = key
  shown.waiting = true
  shown.record = record
  shown.problem = ""
  discard state.jobs.submit(JobSpec(title: "Read the pilot of the record", lane: jlInteractive,
    reads: @[s.path]), pilotWork(s.filePtr, s.path, s.size, trace, rule, flip,
    (if trace >= 0: edits.shiftOf(trace) else: 0.0), record, s.base + trace, 0, key,
    rule.name, state.refsHome, state.inbox.poster))

proc pilotReference(state: var AppState; cmd: Command) =
  let why = state.refsWritable
  if why.len > 0:
    state.ignore(cmd, why)
    return
  var rule = cmd.refPilot
  let bad = pilotProblem(rule)
  if bad.len > 0:
    state.ignore(cmd, bad)
    return
  if rule.name.strip.len == 0: rule.name = defaultPilotName(rule)
  if state.refsLoaded:
    let problem = state.refs.nameProblem(rule.name)
    if problem.len > 0:
      state.ignore(cmd, problem)
      return
  discard state.jobs.submit(JobSpec(title: "Store a pilot reference", lane: jlInteractive),
    pilotRuleWork(rule, state.refsHome, state.inbox.poster))

proc selectReference(state: var AppState; cmd: Command) =
  let id = cmd.refId
  if id.len > 0 and state.refsLoaded and state.refs.findId(id) < 0:
    state.ignore(cmd, "there is no reference \"" & id & "\" in the archive")
    return
  state.keepChoice(cmd.origin, id)
  if id.len == 0:
    state.log.add(sevInfo, "references", NoReferenceChosen)
  else:
    let i = state.refs.findId(id)
    let name = if i >= 0: state.refs.entries[i].name else: id
    state.log.add(sevInfo, "references", "The plots use the reference \"" & name & "\".")
  if state.correlateOn:
    let k = state.findPanel(MainPanel)
    if k >= 0:
      let shown = state.shownFile(k)
      if shown >= 0:
        let path = state.sessions[shown].diskPath
        let oi = state.originIndex(path)
        if oi >= 0: state.startCorrelate(oi, keepView = state.derivedShown(path))

proc deleteReference(state: var AppState; cmd: Command) =
  let why = state.refsWritable
  if why.len > 0:
    state.ignore(cmd, why)
    return
  if cmd.refId.len == 0:
    state.ignore(cmd, "no reference was named")
    return
  discard state.jobs.submit(JobSpec(title: "Delete a reference", lane: jlInteractive),
    deleteWork(state.refsHome, cmd.refId, state.inbox.poster))

proc renameReference(state: var AppState; cmd: Command) =
  let why = state.refsWritable
  if why.len > 0:
    state.ignore(cmd, why)
    return
  if cmd.refId.len == 0:
    state.ignore(cmd, "no reference was named")
    return
  if cmd.refNewName.strip.len == 0:
    state.ignore(cmd, "a reference needs a name")
    return
  discard state.jobs.submit(JobSpec(title: "Rename a reference", lane: jlInteractive),
    renameWork(state.refsHome, cmd.refId, cmd.refNewName, state.inbox.poster))

proc nextRefView(state: AppState): int =
  result = 1
  var taken = true
  while taken:
    taken = false
    for w in state.refViews:
      if w.id == result:
        taken = true
        inc result

proc readPilotView(state: var AppState; wi: int; s: Session; trace: int; edits: FileEdits) =
  ## Reads the pilot of trace `trace` of `s` for the window `refViews[wi]`, with the trace's
  ## own reversal and time shift as they are now.
  template w: untyped = state.refViews[wi]
  w.waiting = true
  w.noFile = false
  w.pilotTrace = s.base + trace
  w.pilotFlip = edits.has(teReversed, trace)
  w.pilotShiftMs = edits.shiftOf(trace)
  discard state.jobs.submit(JobSpec(title: "Read the reference " & w.name,
    lane: jlInteractive, reads: @[s.path]), pilotWork(s.filePtr, s.path, s.size, trace,
    w.pilot, w.pilotFlip, w.pilotShiftMs, w.record, s.base + trace, w.id, "", w.name,
    state.refsHome, state.inbox.poster))

proc refreshPilotViews(state: var AppState) =
  ## The View windows of pilot rules follow the pilot trace's own reversal and time shift
  ## (the correlation does), so that a window, the preview and a fixed copy always agree;
  ## one whose file was closed takes the next file shown.
  for wi in 0 ..< state.refViews.len:
    template w: untyped = state.refViews[wi]
    if w.pilot.trace <= 0 or w.waiting: continue
    if w.pilotTrace >= 0:
      let i = state.findTrace(w.pilotTrace)
      if i >= 0:
        let s = state.sessions[i]
        let edits = state.editsAt(s.path)
        if edits.has(teReversed, w.pilotTrace - s.base) != w.pilotFlip or
            edits.shiftOf(w.pilotTrace - s.base) != w.pilotShiftMs:
          state.readPilotView(wi, s, w.pilotTrace - s.base, edits)
    elif w.noFile:
      let (si, g) = state.shownRecord
      if si >= 0:
        let s = state.sessions[si]
        let edits = state.editsAt(s.path)
        let (trace, record, problem) = s.pilotOfRecord(g, w.pilot, edits)
        w.record = record
        w.noFile = false
        if problem.len > 0:
          w.note = problem
        else:
          w.note = ""
          state.readPilotView(wi, s, trace, edits)

proc viewReference(state: var AppState; cmd: Command) =
  ## Opens `cmd.refId` in its own window. The file under QC is not closed
  ## and no plot is retargeted.
  if not state.refsLoaded:
    state.ignore(cmd, "the reference archive is still being read")
    return
  let i = state.refs.findId(cmd.refId)
  if i < 0:
    state.ignore(cmd, "there is no reference \"" & cmd.refId & "\" in the archive")
    return
  let e = state.refs.entries[i]
  if e.isPilot:
    let id = state.nextRefView()
    let rule = pilotRuleOf(e)
    var w = RefView(id: id, refId: e.id, name: e.name, pilot: rule, pilotTrace: -1)
    let (si, g) = state.shownRecord
    if si < 0:
      w.note = NoFilePilot
      w.noFile = true
      state.refViews.add w
      return
    let s = state.sessions[si]
    let edits = state.editsAt(s.path)
    let (trace, record, problem) = s.pilotOfRecord(g, rule, edits)
    w.record = record
    if problem.len > 0:
      w.note = problem
      state.refViews.add w
      return
    state.refViews.add w
    state.readPilotView(state.refViews.high, s, trace, edits)
    return
  if e.blocked or not singleFileName(e.file):
    state.ignore(cmd, "the reference \"" & e.name &
      "\" names a file outside the archive: it was not opened")
    return
  if e.missing:
    state.ignore(cmd, "the reference \"" & e.name & "\" has no file: it was not opened")
    return
  let id = state.nextRefView()
  state.refViews.add RefView(id: id, refId: e.id, name: e.name, waiting: true,
    fromMs: timeStart(e), dtMs: (if e.intervalUs > 0: e.intervalUs / 1000 else: 0.0))
  discard state.jobs.submit(JobSpec(title: "Read the reference " & e.name,
    lane: jlInteractive), viewWork(state.refsHome, e.file, e.id, e.name, id,
    timeStart(e), state.inbox.poster))

proc closeRefView(state: var AppState; cmd: Command) =
  let i = state.refViews.findIt(it.id == cmd.refWindow)
  if i >= 0: state.refViews.delete i

proc copyReference(state: var AppState; cmd: Command) =
  if not state.inProject:
    state.ignore(cmd, "no project is open")
    return
  let why = state.refsWritable
  if why.len > 0:
    state.ignore(cmd, why)
    return
  if state.mainRefsHome.len == 0:
    state.ignore(cmd, "there is no main archive in this run")
    return
  if cmd.refId.len == 0:
    state.ignore(cmd, "no reference was named")
    return
  discard state.jobs.submit(JobSpec(title: "Copy a reference into the project",
    lane: jlInteractive), copyWork(state.mainRefsHome, state.refsHome, cmd.refId,
    state.inbox.poster))

proc clearGoneChoice(state: var AppState; name: string) =
  ## The chosen reference was deleted: the choice goes back to none. An open
  ## correlation that is not frozen says the name and draws nothing. The log
  ## says to choose one in References: a correlation does not use the file's
  ## pilot. A vibrator signature does, and its note says so.
  if state.chosenRef.len == 0: return
  let sentence = referenceGone(name)
  state.chosenRef = ""
  inc state.refsRev
  if state.inProject:
    if not state.project.readOnly:
      state.project.doc.referenceId = ""
      state.projectChanged()
  else:
    state.change(coWindow, s): s.referenceId = ""
  state.log.add(sevInfo, "references", sentence & " " & NoReferenceChosen)
  for w in 0 ..< state.plots.len:
    if state.plots[w].view == avCorrelation and not state.plots[w].frozen:
      state.showCorrelationProblem(w, sentence, name)
    elif state.plots[w].view == avVibrator:
      state.plots[w].goneNote = sentence & " The choice is the file's own pilot."
      state.plots[w].result.note = state.plots[w].goneNote
      state.plots[w].reference = ""
      inc state.plots[w].revision

proc takeReferences(state: var AppState; m: sink Msg) =
  ## A reference job's result.
  let n = m.refNews
  if n.act in {raPilotShown, raViewed} and n.pilotTrace >= 0 and
      state.findTrace(n.pilotTrace) < 0:
    return # a pilot of a file closed since: dropped
  if n.act == raPilotShown:
    if n.key == state.pilotShown.key:
      inc state.pilotShown.gen
      state.pilotShown.waiting = false
      state.pilotShown.record = n.record
      state.pilotShown.problem = n.failure
      state.pilotShown.samples = @[]
      state.pilotShown.hz = n.hz
      state.pilotShown.db = n.amps
      state.pilotShown.dtMs = n.dtMs
      state.pilotShown.note = n.note
      if n.failure.len == 0:
        state.pilotShown.samples = newSeq[float32](n.ys.len)
        for k, v in n.ys: state.pilotShown.samples[k] = float32(v)
    return
  if n.act == raViewed or (n.act == raFailed and n.window > 0):
    let i = state.refViews.findIt(it.id == n.window)
    if i >= 0:
      if n.act == raFailed or n.failure.len > 0:
        state.refViews[i].waiting = false
        state.refViews[i].note = n.failure
      else:
        state.refViews[i].waiting = false
        state.refViews[i].name = n.name
        state.refViews[i].fromMs = n.fromMs
        state.refViews[i].dtMs = n.dtMs
        state.refViews[i].ys = n.ys
        state.refViews[i].hz = n.hz
        state.refViews[i].amps = n.amps
        state.refViews[i].note = ""
        if n.record.len > 0: state.refViews[i].record = n.record
        if n.pilotTrace >= 0:
          state.refViews[i].pilotTrace = n.pilotTrace
          state.refViews[i].pilotNote = n.note
          state.refViews[i].pilotTraceMs = n.pilotTraceMs
          state.refViews[i].pilotFrom = n.pilotFrom
          state.refViews[i].pilotTo = n.pilotTo
      inc state.refViews[i].revision
    if n.act == raFailed and n.failure.len > 0:
      state.log.add(sevWarning, "references", n.failure & ".")
    return
  if n.home.len > 0 and n.home == state.mainRefsHome:
    state.mainRefs = n.index
    state.mainRefsLoaded = true
  if n.home.len > 0 and n.home == state.refsHome:
    state.refs = n.index
    state.refsLoaded = true
    inc state.refsRev
  var clearedChoice = false
  if n.act == raRenamed:
    for w in state.refViews.mitems:
      if w.refId == n.id: w.name = n.name
  elif n.act == raDeleted:
    for w in state.refViews.mitems:
      if w.refId == n.id:
        w.gone = true
        w.name = n.name
        w.note = "The reference \"" & n.name & "\" was deleted."
    if state.chosenRef == n.id:
      state.clearGoneChoice(n.name)
      clearedChoice = true
  if n.act == raFailed or (n.act == raListed and n.failure.len > 0):
    if n.failure.len > 0:
      state.log.add(sevWarning, "references", n.failure & ".")
  elif n.act == raStored:
    state.log.add(sevInfo, "references", "Stored the reference \"" & n.name & "\"" &
      n.index.lengthSaid(n.id) & ".")
  elif n.act == raGenerated:
    state.log.add(sevInfo, "references", "Generated the reference \"" & n.name & "\"" &
      n.index.lengthSaid(n.id) & ".")
  elif n.act == raRuleStored:
    state.log.add(sevInfo, "references", "Stored the pilot reference \"" & n.name & "\".")
  elif n.act == raRenamed:
    state.log.add(sevInfo, "references", "Renamed the reference to \"" & n.name & "\".")
  elif n.act == raDeleted:
    if not clearedChoice:
      state.log.add(sevInfo, "references", "Deleted the reference \"" & n.name & "\".")
  elif n.act == raCopied:
    state.log.add(sevInfo, "references", "Copied \"" & n.name & "\" into the project.")

proc refreshCompare(state: var AppState) =
  ## Asks a job for the picture. The one on screen stays until the new one
  ## arrives. A newer ask cancels the older job; a late answer is dropped.
  inc state.comparePicGen
  let gen = state.comparePicGen
  if state.comparePicJob != NoJob:
    discard state.jobs.cancel(state.comparePicJob)
  let a = state.compareA
  let b = state.compareB
  let opt = state.compareOptions
  state.comparePicJob = state.jobs.submit(JobSpec(title: "Compare the two traces",
    lane: jlInteractive), comparePictureWork(a, b, opt, gen, state.inbox.poster))

proc armCompare(state: var AppState; which: CompareWhich): uint64 =
  ## Marks `which` waiting for a new copy, and returns the generation the
  ## job must answer with. A late copy of an older ask is dropped.
  inc state.compareGen
  result = state.compareGen
  if which == cwB:
    state.compareB = CompareSlot(waiting: true, gen: result)
    state.compareJobB = NoJob
  else:
    state.compareA = CompareSlot(waiting: true, gen: result)
    state.compareJobA = NoJob
  state.refreshCompare()

proc stampCompare(state: var AppState; which: CompareWhich; path, fileName, record: string;
    trace: int) =
  if which == cwB:
    state.compareB.path = path
    state.compareB.fileName = fileName
    state.compareB.trace = trace
    state.compareB.recordText = record
  else:
    state.compareA.path = path
    state.compareA.fileName = fileName
    state.compareA.trace = trace
    state.compareA.recordText = record

proc setCompareTrace(state: var AppState; cmd: Command) =
  if cmd.compareSlot == cwBoth:
    state.ignore(cmd, "name slot A or slot B")
    return
  let i = state.findTrace(cmd.compareTrace)
  if i < 0:
    state.ignore(cmd, "the trace is in no open file")
    return
  let s = state.sessions[i]
  let local = cmd.compareTrace - s.base
  if local < 0 or local >= s.len:
    state.ignore(cmd, "the trace is in no open file")
    return
  let gen = state.armCompare(cmd.compareSlot)
  state.stampCompare(cmd.compareSlot, s.path, s.name, recordText(s, local), local + 1)
  let own = state.ownAt(s.path, local)
  let filt = if own.has: own.filter else: OwnFilter()
  let reversed = state.editsAt(s.path).effectivelyReversed(local)
  let shiftMs = state.editsAt(s.path).shiftOf(local)
  let job = state.jobs.submit(JobSpec(title: "Copy a trace for compare", lane: jlInteractive,
    reads: @[s.path]), compareTraceWork(s.filePtr, s.path, s.size, local, filt, reversed,
    shiftMs, gen, state.inbox.poster))
  if cmd.compareSlot == cwB: state.compareJobB = job else: state.compareJobA = job

proc setCompareRef(state: var AppState; cmd: Command) =
  if cmd.compareSlot == cwBoth:
    state.ignore(cmd, "name slot A or slot B")
    return
  if not state.refsLoaded:
    state.ignore(cmd, "the reference archive is still being read")
    return
  let i = state.refs.findId(cmd.compareRef)
  if i < 0:
    state.ignore(cmd, "there is no reference \"" & cmd.compareRef & "\" in the archive")
    return
  let e = state.refs.entries[i]
  if e.isPilot:
    state.ignore(cmd, "the reference \"" & e.name & "\" is a trace of each record, not " &
      "one waveform: store it as a fixed reference first")
    return
  if e.blocked or not singleFileName(e.file):
    state.ignore(cmd, "the reference \"" & e.name & "\" names a file outside the archive")
    return
  if e.missing:
    state.ignore(cmd, "the reference \"" & e.name & "\" has no file")
    return
  var fileName = e.name
  var trace = 1
  var record = ""
  if not e.origin.generated:
    if e.origin.fileName.len > 0: fileName = e.origin.fileName
    if e.origin.trace > 0: trace = e.origin.trace
    if e.origin.record == e.origin.record and abs(e.origin.record) < 1e15:
      record = "FFID " & $int64(e.origin.record)
  let gen = state.armCompare(cmd.compareSlot)
  state.stampCompare(cmd.compareSlot, "", fileName, record, trace)
  let job = state.jobs.submit(JobSpec(title: "Copy a reference for compare",
    lane: jlInteractive), compareRefWork(state.refsHome / e.file, gen, timeStart(e),
    state.inbox.poster))
  if cmd.compareSlot == cwB: state.compareJobB = job else: state.compareJobA = job

proc setCompare(state: var AppState; cmd: Command) =
  if cmd.compareRef.len > 0: state.setCompareRef(cmd)
  else: state.setCompareTrace(cmd)

proc clearCompare(state: var AppState; cmd: Command) =
  if cmd.compareSlot in {cwA, cwBoth}:
    state.compareA = CompareSlot()
    state.compareJobA = NoJob
  if cmd.compareSlot in {cwB, cwBoth}:
    state.compareB = CompareSlot()
    state.compareJobB = NoJob
  state.refreshCompare()

proc swapCompare(state: var AppState) =
  swap(state.compareA, state.compareB)
  swap(state.compareJobA, state.compareJobB)
  state.refreshCompare()

proc showCompare(state: var AppState; cmd: Command) =
  state.compareOptions = cmd.compareShow
  state.refreshCompare()

proc setSubfolders(state: var AppState; cmd: Command) =
  ## "Include subfolders": kept in the open project, else in the settings (an
  ## agent's choice is for the session only), and the folder listed again when
  ## the choice changed.
  if cmd.subfolders == state.includesSubfolders: return
  if state.project.dir.len > 0:
    state.project.doc.includeSubfolders = cmd.subfolders
    if keeps(cmd.origin) and not state.project.readOnly: state.projectChanged()
  else:
    state.change(cmd.origin, x): x.files.subfolders = cmd.subfolders
  template f: untyped = state.files
  if f.title.len > 0:
    let paths = if f.folder.len > 0: @[f.folder] else: f.asked
    if paths.len > 0: state.startListing(paths, f.title, f.folder, state.listedBy)

proc submitTreat(state: var AppState; path: string; hashing: bool) =
  ## Starts the look-up of the document that keeps what the user forced for the file at `path`
  ## (`treatWork`), with what this run knows of the file: an open file's document (unless its
  ## edits brought back are being checked), else the one the last choice went to, and the hash
  ## of every byte when one was taken.
  let hint = state.treatHint(path)
  var taken: seq[string] = @[]
  for x in state.remembered:
    taken.add x.doc
    taken.add x.provDocs
  for d in state.knownDocs.keys: taken.add d
  let job = state.jobs.submit(JobSpec(title: "Remember what " & path.extractFilename &
    " is treated as", lane: if hashing: jlHashes else: jlInteractive, auto: true),
    treatWork(path, state.store, hint, taken, hashing, state.inbox.poster))
  state.treatJobs[path] = job
  state.memoryWork.add job

proc rememberTreat(state: var AppState; path: string) =
  ## Has the user's choice for the file at `path` kept in its document of the store: by a
  ## look-up (`submitTreat`), unless one is under way for the file, whose answer hands the
  ## choice as it is then.
  if state.store.isNowhere or state.readOnlyProject or path in state.treatJobs: return
  state.submitTreat(path, hashing = false)

proc treatAs(state: var AppState; cmd: Command) =
  ## `ckTreatAs`: forces, or gives back to the file, the kind and the order a file is treated as,
  ## and has the choice remembered for the file (its document in the store, found by its
  ## identity, made on demand: `treatWork`).
  let path = canonical(cmd.treatPath)
  # a seismic file of the list, or one open: known to be there and to be seismic without a look
  # at the disk here
  let listed = state.files.find(path)
  if not (listed >= 0 and state.files.entries[listed].kind.isSeismic or
      state.sessions.anyIt(it.path == path and not it.derived)):
    state.ignore(cmd, path & " is not a seismic file listed in Files or open")
    return
  let kept = keeps(cmd.origin)
  var t = (if kept: state.treatsKept else: state.treats).getOrDefault(path)
  let before = t
  var bad = ""
  if cmd.treatKind == "automatic": t.kind = none(RecordingKind)
  elif cmd.treatKind.len > 0:
    var k: RecordingKind
    if parseKindName(cmd.treatKind, k): t.kind = some k
    else: bad = cmd.treatKind & " is not a kind (shot, continuous, sliced or automatic)"
  if cmd.treatGrouping == "automatic": t.grouping = none(TraceGrouping)
  elif cmd.treatGrouping.len > 0:
    var g: TraceGrouping
    if parseGroupingName(cmd.treatGrouping, g): t.grouping = some g
    else: bad = cmd.treatGrouping & " is not a grouping (none, flag, component or automatic)"
  if cmd.treatSubSort == "automatic": t.subSort = none(TraceSubSort)
  elif cmd.treatSubSort.len > 0:
    var s: TraceSubSort
    if parseSubSortName(cmd.treatSubSort, s): t.subSort = some s
    else: bad = cmd.treatSubSort & " is not a sort (station, time or automatic)"
  if bad.len > 0:
    state.ignore(cmd, bad)
    return
  if cmd.treatKind.len == 0 and cmd.treatGrouping.len == 0 and cmd.treatSubSort.len == 0:
    state.ignore(cmd, "nothing was given to treat the file as")
    return
  # (the user's own choice picked again after an agent's: the agent's goes; and the user's is
  # written whatever this run knew: another viewSEG may have set the part since)
  if t == before and state.treats.getOrDefault(path) == t and not kept: return
  state.treatsTouched.incl path
  var named: set[TreatPart] = {}
  if cmd.treatKind.len > 0: named.incl tpKind
  if cmd.treatGrouping.len > 0: named.incl tpGrouping
  if cmd.treatSubSort.len > 0: named.incl tpSubSort
  state.treatsOwn[path] = state.treatsOwn.getOrDefault(path) + named
  if kept: state.treatsOwnKept[path] = state.treatsOwnKept.getOrDefault(path) + named
  if path in state.treatsPending: # (what this command names is the user's now)
    let rest = state.treatsPending[path].merged(TreatAs(), named)
    if rest.isSet: state.treatsPending[path] = rest else: state.treatsPending.del path
  if t.isSet: state.treats[path] = t else: state.treats.del path
  if kept:
    if t.isSet: state.treatsKept[path] = t else: state.treatsKept.del path
  if listed >= 0:
    state.showTreat(state.files.entries[listed])
    state.files.changedAt(listed)
  if kept:
    var parts = state.treatParts.getOrDefault(path)
    if cmd.treatKind.len > 0: parts.incl tpKind
    if cmd.treatGrouping.len > 0: parts.incl tpGrouping
    if cmd.treatSubSort.len > 0: parts.incl tpSubSort
    state.treatParts[path] = parts
    state.rememberTreat(path)

proc takeTreated(state: var AppState; m: sink Msg) =
  ## Which document keeps what the user forced for a file (`treatWork`): the choice as it is now
  ## is handed to the disk thread, which sets it alone in the document as it is then
  ## (`DiskIo.treat`). The hash of every byte, when it was needed, is taken on its lane first.
  let path = m.treatPath
  let name = path.extractFilename
  if state.treatJobs.getOrDefault(path) == m.job: state.treatJobs.del path
  if m.treatHash:
    if path notin state.treatJobs:
      state.submitTreat(path, hashing = true)
  elif m.treatFailure.len > 0:
    state.log.add(sevWarning, name, "What " & name & " is treated as is kept for this session " &
      "only: " & m.treatFailure & ".")
  else: state.handTreat(path, m.treatDoc, m.treatIdentity, m.treatModified)

proc setCompareWindow(state: var AppState; cmd: Command) =
  state.compareOpen = cmd.compareOpen

proc fillCompare(slot: var CompareSlot; n: CompareNews) =
  slot.waiting = false
  if n.failure.len > 0:
    slot.filled = false
    slot.problem = n.failure
    slot.samples.setLen 0
    return
  slot.filled = true
  slot.problem = ""
  slot.samples = n.samples
  slot.dtMs = n.dtMs
  slot.t0Ms = n.t0Ms
  slot.fromMs = n.fromMs
  slot.toMs = n.toMs
  if n.channelText.len > 0: slot.channelText = n.channelText
  if n.stationText.len > 0: slot.stationText = n.stationText
  slot.reversed = n.reversed
  slot.filtered = n.filtered
  slot.filterWords = n.filterWords
  slot.shiftWords = n.shiftWords

proc takeComparePicture(state: var AppState; m: sink Msg) =
  ## The picture a job worked out. One the user has since replaced is
  ## dropped. A typed shift is stored as the whole-sample time applied, so
  ## the box shows that.
  if m.comparePicGen != state.comparePicGen: return
  if not state.compareOptions.shiftMs.isNaN and not m.comparePicture.appliedShiftMs.isNaN:
    state.compareOptions.shiftMs = m.comparePicture.appliedShiftMs
  state.comparePicture = move m.comparePicture
  if state.comparePicJob == m.job: state.comparePicJob = NoJob
  inc state.compareRevision

proc takeCompare(state: var AppState; m: sink Msg) =
  ## A compare job's copy. A generation that is no longer the slot's is a
  ## copy the user has since replaced, and is dropped.
  let n = m.compareNews
  if state.compareA.waiting and state.compareA.gen == n.gen:
    state.compareA.fillCompare(n)
  elif state.compareB.waiting and state.compareB.gen == n.gen:
    state.compareB.fillCompare(n)
  else:
    return
  state.refreshCompare()
  if state.compareA.filled and state.compareB.filled and not state.compareA.waiting and
      not state.compareB.waiting:
    state.compareOpen = true
  if n.failure.len > 0:
    state.log.add(sevWarning, "compare", n.failure & ".")

proc setCorrelate(state: var AppState; cmd: Command) =
  ## Shows the correlated record of the file the Seismic window shows, or the raw one.
  if not cmd.correlate:
    if state.correlateOn: state.stopCorrelate()
    return
  state.correlateOn = true
  let k = state.findPanel(MainPanel)
  if k < 0:
    state.sayCorrelate("Open a file to correlate")
    return
  let shown = state.shownFile(k)
  if shown < 0:
    state.sayCorrelate("Open a file to correlate")
    return
  let path = state.sessions[shown].diskPath
  let oi = state.originIndex(path)
  if oi < 0:
    state.sayCorrelate("Open a file to correlate")
    return
  state.startCorrelate(oi, keepView = state.derivedShown(path))

const AuxRefused = {ckGather, ckShowFile, ckShowTrace, ckSort, ckFilter, ckProcessing,
  ckDisplayPreset, ckOwnFilter, ckTimeShift, ckPrepare, ckOpenPair, ckCorrelate}
  ## what the Aux window's panel does not take: it follows the Seismic window's record and
  ## shows the auxiliary traces as recorded, with no filter, sort or preset

proc cutGatherCmd(state: var AppState; cmd: Command) =
  ## Starts the cut of the shown recording at the shots of a loaded log.
  let why = state.cutProblem()
  if why.len > 0:
    state.ignore(cmd, why)
    return
  if cmd.cutLog notin 0 ..< state.shotLogs.len:
    state.ignore(cmd, "there is no such shot log")
    return
  if cmd.cutDest.len == 0:
    state.ignore(cmd, "no file name was given")
    return
  let shots = shotsInTime(state.shotLogs[cmd.cutLog].view.rows)
  if shots.shots.len == 0:
    state.ignore(cmd, "the shot log has no shot with a time")
    return
  let s = state.sessions[state.shownFile(state.findPanel(MainPanel))]
  let dest = canonical(cmd.cutDest)
  var others: seq[string] = @[]
  for x in state.sessions: others.add x.diskPath
  state.cutSink = CutSink()
  state.cutOutcome = ""
  state.cutPath = ""
  var opts = cmd.cutOptions
  opts.treatKind = state.treatInForce(s.path).kind # what the user forced for the file
  opts.logName = extractFilename(state.shotLogs[cmd.cutLog].source)
  if opts.logName.len == 0: opts.logName = state.shotLogs[cmd.cutLog].name
  state.cutJob = state.jobs.submit(cutGatherSpec(s.diskPath, dest),
    cutGatherWork(s.filePtr, s.diskPath, dest, shots, opts, state.cutSink, others))

proc exportShotSpsCmd(state: var AppState; cmd: Command) =
  ## Starts the write of a loaded shot log's source points as an SPS file.
  if state.spsJob != NoJob:
    state.ignore(cmd, "an SPS export is already running")
    return
  if cmd.spsLog notin 0 ..< state.shotLogs.len:
    state.ignore(cmd, "there is no such shot log")
    return
  if cmd.spsDest.len == 0:
    state.ignore(cmd, "no file name was given")
    return
  let dest = canonical(cmd.spsDest)
  if fs.fileExists(dest) or fs.dirExists(dest):
    state.ignore(cmd, extractFilename(dest) & " already exists; choose a new name")
    return
  state.spsSink = SpsSink(dest: dest)
  state.spsLogId = state.shotLogs[cmd.spsLog].id
  state.spsOutcome = ""
  state.spsPath = ""
  state.spsJob = state.jobs.submit(spsExportSpec(dest),
    spsExportWork(state.shotLogs[cmd.spsLog].view, cmd.spsOptions, dest, state.spsSink))

proc generateOFileCmd(state: var AppState; cmd: Command) =
  ## Starts the write of the O records of the imported survey's X records.
  if state.oJob != NoJob:
    state.ignore(cmd, "an O file is already being generated")
    return
  let r = state.relationLayer
  if r < 0:
    state.ignore(cmd, "the imported survey has no X records to take O records from")
    return
  if cmd.oDest.len == 0:
    state.ignore(cmd, "no file name was given")
    return
  let dest = canonical(cmd.oDest)
  if fs.dirExists(dest):
    state.ignore(cmd, extractFilename(dest) & " is a folder")
    return
  var own: seq[string]
  for l in state.survey.layers:
    if l.origin == loSurveyFile: own.add l.path
  for x in state.joins:
    for f in x.files: own.add canonical(f.path)
  for s in state.sessions: own.add canonical(s.path)
  for l in state.shotLogs: own.add canonical(l.source)
  let why = refusedTarget(dest, own)
  if why.len > 0:
    state.oOutcome = "The O file was not written: " & why & "."
    state.log.add(sevError, "generate O file", state.oOutcome)
    state.ignore(cmd, why)
    return
  template l: untyped = state.survey.layers[r]
  state.oSink = OFileSink(source: l.path, dest: dest)
  state.oOutcome = ""
  state.oPath = ""
  state.oJob = state.jobs.submit(oFileSpec(dest), oFileWork(l.relations, state.oSink))

proc watchRecording*(state: var AppState; wanted: bool) =
  ## Keeps a job reading the shown file as a recording (`describeRecording`)
  ## while `wanted` (the cut dialog is open) or while the Files panel does not know the
  ## file's kind (it was too large to be opened for it, `ksNotKnown`, or is multiplexed,
  ## `ksMultiplexed`; the facts give the
  ## row its kind): started once its keys are read
  ## and again when the shown file or its keys change, cancelled when no longer
  ## wanted or the file changes. Call it every frame; it does nothing when
  ## nothing changed.
  let shown = state.shownFile(state.findPanel(MainPanel))
  let row = if shown >= 0: state.files.find(state.sessions[shown].path) else: -1
  let rowAsks = row >= 0 and state.files.entries[row].kindState in {ksNotKnown, ksMultiplexed}
  let usable = (wanted or rowAsks) and shown >= 0 and not state.sessions[shown].derived and
    not state.sessions[shown].isSignature and state.sessions[shown].filePtr[].hasKeys
  let key = if usable: (int(state.sessions[shown].id), state.sessions[shown].keysRevision,
                state.vendor.gen)
            else: (-1, 0, 0)
  if state.recJob != NoJob and (not usable or key != state.recKey):
    discard state.jobs.cancel(state.recJob)
    state.recJob = NoJob
    state.recSink = nil
  if not usable:
    state.recHave = false
    state.recKey = key
  elif state.recJob == NoJob and (key != state.recKey or not state.recHave):
    let s = state.sessions[shown]
    let dtMs = seismicDtMs(s.filePtr)
    state.recKey = key
    state.recPath = s.path
    state.recHave = false
    if dtMs.isNaN or dtMs <= 0:
      # the answer for this key: not asked again, so no trace is walked every frame
      state.recFacts = RecordingFacts()
      state.recWhy = NoSampleIntervalWords
      state.recHave = true
    else:
      state.recSink = RecordingSink()
      state.recJob = state.jobs.submit(JobSpec(title: "Read " & s.name & " as a recording",
        lane: jlBackground, reads: @[s.diskPath]),
        recordingFactsWork(s.filePtr, s.diskPath, dtMs, currentVendors(), state.recSink))

proc watchVendorFields*(state: var AppState) =
  ## Keeps the vendor fields of the files the panels show listed, for the display-line menu
  ## (`vendorFields`): one job at a time lists the fields of the first shown file that has no
  ## answer for the vendor maps in force. A list of the maps of an older load, or of a file no
  ## panel shows, is let go; a job whose file is no longer shown, or whose maps were replaced, is
  ## cancelled. Call it every frame; it does nothing when nothing changed.
  var shown: seq[int] = @[] # the indices in `sessions` of the files shown
  var ids: seq[SessionId] = @[]
  for k in 0 ..< state.panels.len:
    let i = state.shownFile(k)
    if i >= 0 and i notin shown and not state.sessions[i].isSignature:
      shown.add i
      ids.add state.sessions[i].id
  state.vfLists.keepItIf(it.vendors == state.vendor.gen and it.session in ids)
  if state.vfJob != NoJob and (state.vfKey.vendors != state.vendor.gen or
      state.vfKey.session notin ids):
    discard state.jobs.cancel(state.vfJob)
    state.vfJob = NoJob
  if state.vfJob == NoJob:
    for i in shown:
      let s = state.sessions[i]
      if state.vendorFields(s.id).isNone:
        state.vfKey = (s.id, state.vendor.gen)
        state.vfJob = state.jobs.submit(JobSpec(title: "List the vendor fields of " & s.name,
          lane: jlBackground, reads: @[s.diskPath]),
          vendorFieldsWork(s.filePtr, s.id, state.vendor.gen, currentVendors(),
            state.inbox.poster))
        break

proc applyCommand(state: var AppState; cmd: Command) =
  if cmd.kind in AuxRefused:
    let a = state.findPanel(cmd.panel)
    if a >= 0 and state.panels[a].role == prAux:
      state.ignore(cmd, $cmd.panel & " is the Aux window: it follows the Seismic window's " &
        "record and shows the auxiliary traces as recorded, so it takes no " & $cmd.kind)
      return
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
          indexCacheFile(state.indexCache, path), lines = state.settings.join,
          choice = state.openChoiceOf(path), pair = state.pairArgOf(path)))
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
    elif not keepsOne(state.panels[k].componentCodes, cmd.filter.components):
      state.ignore(cmd, "a plot keeps at least one component on")
    elif cmd.filter != state.panels[k].layers[0].filter:
      # The record's traces again, through the new filter, at the same scales.
      # Seismic / Aux is a way of looking, kept for the next plot as the
      # display is; which components are off stays with this file only.
      let was = state.panels[k].layers[0].filter
      state.panels[k].layers[0].filter = cmd.filter
      if cmd.filter.seismic != was.seismic or cmd.filter.auxiliary != was.auxiliary or
          cmd.filter.templateOnly != was.templateOnly:
        state.change(cmd.origin, s):
          s.plot.seismic = cmd.filter.seismic
          s.plot.auxiliary = cmd.filter.auxiliary
          s.plot.templateOnly = cmd.filter.templateOnly
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
    let scaled = not sameScale(s.forceScale, state.settings.forceScale)
    state.change(cmd.origin, x): x = carried(x, state.settings, s)
    if scaled:
      # a signature file's force scale changed: its Vibrator windows are worked out again
      for w in 0 ..< state.plots.len:
        if state.plots[w].view == avVibrator and state.vibSignature(w) != sgNone:
          discard state.askPlot(w)
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
      let aux = p.role == prAux
      # whoever sent it: the settings file takes it as it is; the Aux window's is wiggles
      # with the gain types it offers
      let d = if aux: cmd.display.bounded.forAux else: cmd.display.bounded
      p.layers[0].display = d
      inc p.revision
      if d.orientation != was.orientation:
        # Turned: the same traces and times, the plot's pixels along each
        # the other way round until the window says what they are now.
        swap(p.view.columns, p.view.rows)
      # what this command changed in the display; a new mode leaves the
      # gain as the user had it, whatever an agent made it meanwhile
      var kept = remembered(d)
      let modelChanged = d.breakModel != was.breakModel
      if aux:
        state.change(cmd.origin, s):
          s.aux.display = carried(s.aux.display, state.settings.aux.display, kept)
      else:
        if state.inProject: kept.breakModel = state.settings.plot.display.breakModel
        state.change(cmd.origin, s):
          s.plot.display = carried(s.plot.display, state.settings.plot.display, kept)
      if modelChanged and state.inProject and not aux:
        # the project's model: kept in it, not in the user's settings
        state.change(coAgent, s): s.plot.display.breakModel = d.breakModel
        if keeps(cmd.origin) and not state.project.readOnly:
          state.project.doc.breakModel = d.breakModel
          state.project.doc.hasBreakModel = true
          state.projectChanged()
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
      if d.onlyClipDiffers(was, p.kind):
        # a new clip percentile: the same samples, another level, made by
        # the reader from those it holds; the picture before stays meanwhile
        state.resample(k, relevel = true)
      elif not d.sameProcessing(was, p.kind):
        state.refetch(k, keepTiles = false)
      else:
        state.requestView(k) # a new view, or the extremes wiggles need
      state.settleGain(k, cmd.origin)
  of ckDisplayPreset: state.displayPreset(cmd)
  of ckNamePattern: state.namePattern(cmd)
  of ckOutputText: state.outputText(cmd)
  of ckOutputBinary: state.outputBinary(cmd)
  of ckReopen:
    if cmd.reopenPath.len == 0: state.ignore(cmd, "no file was named")
    elif cmd.origin == coAgent and cmd.openChoice.demuxDir.len > 0:
      state.ignore(cmd, "agent control writes no file, and a demultiplexed copy is one: " &
        "its folder is the user's to choose")
    else:
      let path = canonical(cmd.reopenPath)
      let kind = state.signatureKindOfPath(path)
      let c = cmd.openChoice
      if kind != sgNone and (c.standard != scDetect or c.verifyAll or c.twosComplement or
          c.access != acAuto or c.demuxDir.len > 0):
        state.ignore(cmd, "a vibrator signature file is decoded, not read as SEG-Y or SEG-D: " &
          "only its sample interval and its force channels (a .dat) or its time zero (a .vib) " &
          "can be chosen")
      elif kind == sgVib and c.signature.swapForces:
        state.ignore(cmd, "a .vib's channels are named by the file; choose the accelerometer " &
          "set in the Vibrator window")
      elif kind == sgDat and c.signature.fromFirstFrame:
        state.ignore(cmd, "t = 0 at the first frame is a .vib's option: a .dat's t = 0 is its " &
          "trigger")
      elif kind == sgNone and c.signature != SignatureChoice():
        state.ignore(cmd, "the sample interval, force-channel and time-zero options are for " &
          "vibrator signature files; this file is not one")
      elif c.signature.intervalUs != 0 and not (c.signature.intervalUs > 0 and
          c.signature.intervalUs < Inf):
        state.ignore(cmd, "the sample interval must be more than 0 us and finite")
      else:
        if cmd.reopenAll and kind != sgNone:
          state.sigChoices[sigIndex(kind)] = c.signature
          if not state.prepared.session.isNil:
            state.release(move state.prepared.session) # decoded as it was before
            state.prepared = (NoJob, nil)
        state.reopenWith(path, c, cmd.origin)
  of ckTheme:
    if cmd.theme.len > 64 or not cmd.theme.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_',
        ' ', '.'}) or ".." in cmd.theme:
      let shown = if cmd.theme.len > 40: runeSubStr(cmd.theme, 0, 40) & "..." else: cmd.theme
      state.ignore(cmd, "a theme is named by its file's name (`tokyo-night`), not `" &
        shown & "`")
    elif cmd.theme.len > 0 and state.themeNames.len > 0 and cmd.theme notin state.themeNames:
      state.ignore(cmd, "there is no theme `" & cmd.theme & "`; there are " &
        state.themeNames.join(", "))
    else:
      state.change(cmd.origin, s): s.theme = cmd.theme
  of ckNewProject: state.newProject(cmd)
  of ckOpenProject:
    if cmd.projectPath.len == 0: state.ignore(cmd, "no project was named")
    else: state.openProject(projectDirOf(canonical(cmd.projectPath)), cmd.origin)
  of ckListReferences:
    state.loadReferences(state.refsHome, main = false)
    if state.inProject and state.mainRefsHome.len > 0:
      state.loadReferences(state.mainRefsHome, main = true)
  of ckStoreReference: state.storeReference(cmd)
  of ckGenerateReference: state.generateReference(cmd)
  of ckPilotReference: state.pilotReference(cmd)
  of ckPilotPreview: state.pilotPreviewAsk(cmd)
  of ckSelectReference: state.selectReference(cmd)
  of ckDeleteReference: state.deleteReference(cmd)
  of ckRenameReference: state.renameReference(cmd)
  of ckCopyReference: state.copyReference(cmd)
  of ckViewReference: state.viewReference(cmd)
  of ckCloseRefView: state.closeRefView(cmd)
  of ckCloseProject:
    if not state.inProject: state.ignore(cmd, "no project is open")
    else:
      let name = state.project.doc.name
      state.leaveProject(restoreUser = true)
      state.change(cmd.origin, s): s.lastProject = ""
      state.log.add(sevInfo, "project", "Closed the project " & name & ".")
      state.vendor.choice = VendorChoice()
      state.reloadVendorMaps()
  of ckReloadVendors: state.reloadVendorMaps(loud = true)
  of ckVendorMap:
    if not state.inProject:
      state.ignore(cmd, "no project is open: outside a project the vendor maps are chosen " &
        "automatically")
    else: state.setVendorChoice(cmd.origin, parseChoice(cmd.vendorMap))
  of ckProjectFolder: state.projectFolder(cmd)
  of ckClearSurvey: state.clearSurvey(cmd)
  of ckUpdateSurvey:
    template p: untyped = state.project
    if not state.inProject: state.ignore(cmd, "no project is open")
    elif p.readOnly: state.ignore(cmd, "the project is open read-only (" & p.whyReadOnly & ")")
    elif p.survey == srKeeping:
      state.ignore(cmd, "the survey is being copied into the project: update it when it is")
    elif not p.originals.anyIt(it.state == osChanged):
      state.ignore(cmd, "no survey file of the project changed since it was copied in")
    else:
      if p.surveyJob != NoJob: discard state.jobs.cancel(p.surveyJob)
      p.offer = false
      p.survey = srKeeping
      p.surveyJob = state.jobs.submit(JobSpec(title: "Update the project's survey",
        lane: jlBackground, exclusive: @[p.dir.partOf(SurveyFolder)]), updateSurveyWork(p.dir,
        p.doc.survey, p.originals,
        state.inbox.poster))
      inc p.revision
  of ckHeader:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif not cmd.header.auto and cmd.header.fields.len == 0:
      state.ignore(cmd, "a display header needs at least one field")
    elif cmd.header.fields.anyIt(it.field == hfVendor and not usableLineName(it.name)):
      state.ignore(cmd, "a vendor field's name is 1 to 200 characters, with no control character")
    elif uniqueLines(cmd.header.fields).len > MaxHeaderLines:
      state.ignore(cmd, "a display header has at most " & $MaxHeaderLines & " lines")
    else:
      # each field once, as its menu gives
      let header = HeaderChoice(auto: cmd.header.auto, fields: uniqueLines(cmd.header.fields))
      state.panels[k].header = header
      if state.panels[k].role == prAux:
        state.change(cmd.origin, s): s.aux.header = header
      else:
        state.change(cmd.origin, s): s.plot.header = header
      state.refetch(k, keepTiles = true)
  of ckSort:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    elif cmd.order.len > MaxSortKeys:
      state.ignore(cmd, "a sort has at most " & $MaxSortKeys & " keys")
    elif cmd.order.anyIt(it.field == hfVendor and not usableLineName(it.name)):
      state.ignore(cmd, "a vendor field's name is 1 to 200 characters, with no control character")
    elif uniqueKeys(cmd.order) != state.panels[k].layers[0].order:
      let order = uniqueKeys(cmd.order) # each field once, as the sort dialog gives
      state.panels[k].layers[0].order = order
      state.change(cmd.origin, s):
        s.plot.order = order
        if order.len > 0 and presetOf(order, s.sortPresets) < 0:
          s.customOrder = order # the user's own keys, offered again
      state.reorder(k)
  of ckProcessing:
    let k = state.findPanel(cmd.panel)
    if k < 0: state.ignore(cmd, $cmd.panel & " does not exist")
    elif state.panels[k].layers.len == 0: state.ignore(cmd, $cmd.panel & " shows nothing")
    else:
      template p: untyped = state.panels[k]
      let pr = cmd.processing.bounded # whoever sent it
      let was = p.layers[0].processing
      if pr != was:
        p.layers[0].processing = pr
        inc p.revision
        if state.inProject: # the project's filters: kept in it, not in the settings
          state.change(coAgent, s): s.plot.processing = remembered(pr)
          if keeps(cmd.origin) and not state.project.readOnly:
            state.project.doc.processing = remembered(pr)
            state.project.doc.hasProcessing = true
            state.projectChanged()
        else:
          state.change(cmd.origin, s): s.plot.processing = remembered(pr)
        if cmd.origin == coAgent: # the popover's warning for a width the record cannot resolve
          for n in pr.notches:
            if n.on and n notin was.notches:
              let words = narrowNotchWarning(n.widthHz, p.layout.samples, p.layout.dtMs)
              if words.len > 0: state.log.add(sevWarning, "filters", words)
        # Only another set of filters (or of the traces they take) reads
        # again, from the samples at hand: the plot from before stays until
        # the first new tile, which sets the level again (a filter changes
        # the amplitudes).
        let lay = p.layout
        if pr.filterPipeline(lay).stepsText != was.filterPipeline(lay).stepsText or
            (pr.aux != was.aux and pr.filtering):
          let first = p.requestGen != p.filterGen or p.filterRun == 0
          if first: p.filterRun = p.requestGen + 1 # the first of a run of filter changes
          # The first change keeps the read-ahead (one change, a click): the
          # next ones of a run (a slider dragged) ask for the view alone.
          state.resample(k, relevel = true, readAhead = first)
          p.filterGen = p.requestGen
  of ckEdit, ckReverseAll, ckUndoEdit, ckRedoEdit, ckClearEdits, ckOwnFilter, ckTimeShift:
    # Reversing every trace is an edit of the file, so not a setting: kept with it.
    state.editTraces(cmd)
  of ckExportEdits: state.exportEdits(cmd)
  of ckImportEdits: state.importEdits(cmd)
  of ckFileMemory: state.listMemory()
  of ckForgetFiles: state.forgetFiles(cmd)
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
    var asked = cmd.traces
    if cmd.all:
      let k = state.findPanel(MainPanel)
      let i = if k >= 0: state.shownFile(k) else: -1
      asked = if i >= 0: state.panels[k].allShown(state.sessions[i].base) else: @[]
    for t in asked:
      if state.findTrace(t) >= 0: known.add t
    if known.len < asked.len:
      state.ignore(cmd, plural(asked.len - known.len, "trace") & " of " &
        $asked.len & " are in no open file")
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
    # A point of a shot log chooses the rows of its shot, all of them (a shot taken twice has
    # two), and the traces of the file shown that belong to them, in the mode the others are
    # selected in; the points of other layers are selected as ever.
    var plain: seq[PointRef]
    var shotLogId = -1
    var shotRows: seq[int]
    for p in points:
      let li = state.survey.find(p.layer)
      if li >= 0 and state.survey.layers[li].origin == loShotLog and
          (shotLogId < 0 or shotLogId == state.survey.layers[li].shotLog):
        shotLogId = state.survey.layers[li].shotLog
        for row in state.survey.layers[li].rowsAtPoint(p.point, state.follow.indexOf(shotLogId)):
          if row notin shotRows: shotRows.add row
      else: plain.add p
    var traces: seq[int]
    if plain.len > 0 or shotLogId < 0:
      traces = state.survey.tracesAt(plain)
      case cmd.pointMode
      of smReplace, smRange: # the points' own traces replace those selected
        # (the traces first: a replace of them takes the points out too; the
        # points once, not kept and selected again: half a million of them
        # took a frame each time)
        state.selection.select(traces, smReplace)
        state.selection.selectPoints(plain, smReplace)
      of smAdd, smRemove:
        state.selection.selectPoints(plain, cmd.pointMode)
        state.selection.select(traces, cmd.pointMode)
      of smToggle:
        state.selection.selectPoints(plain, cmd.pointMode)
        let added = plain.len > 0 and plain[0].key in state.selection.pointKeys
        state.selection.select(traces, if added: smAdd else: smRemove)
    if shotLogId >= 0:
      state.selectShotRows(shotLogId, shotRows, traces = true, mode = cmd.pointMode,
        others = plain.len > 0)
    # a range starts where the one before did
    if cmd.pointMode == smRange and state.survey.find(anchor.layer) >= 0:
      state.selection.pointAnchor = anchor
    if cmd.jump and traces.len > 0 and shotLogId < 0: state.showPoints(cmd)
  of ckSelectShotRows:
    if state.findShotLog(cmd.shotLogId) < 0:
      state.ignore(cmd, "no shot log has the id " & $cmd.shotLogId)
    else: state.selectShotRows(cmd.shotLogId, cmd.shotRows, cmd.shotTraces)
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
    var i = state.findSession(cmd.joinFile)
    var blocked = false
    if i >= 0 and state.sessions[i].derived:
      let origin = state.sessions[i].diskPath
      i = -1
      for j, s in state.sessions:
        if not s.derived and s.diskPath == origin: i = j
      if i < 0:
        state.ignore(cmd, "the file on disk is not open")
        blocked = true
    if blocked: discard
    elif i < 0 and cmd.joinFile != NoSession:
      state.ignore(cmd, $cmd.joinFile & " is not open")
    elif state.importing:
      state.ignore(cmd, "a survey import is under way: one at a time")
    elif cmd.joinFiles.len == 0: state.ignore(cmd, "no survey file was named")
    else: state.startJoin(i, cmd)
  of ckSelectUnmatched:
    state.selectUnmatched(cmd)
  of ckChooseUnit:
    if cmd.unitChoice.survey.len == 0 and cmd.unitChoice.file.len == 0:
      state.ignore(cmd, "it names no survey file and no seismic file")
    else: state.unitChoices.choose(cmd.unitChoice)
  of ckSurveyUnits:
    for f in cmd.unitsOf:
      if f.path.len == 0: state.ignore(cmd, "a file name was empty")
      elif state.surveyHead(f.path) < 0 or state.heads[state.surveyHead(f.path)].problem.len > 0:
        # A short job each, on a lane of their own: one file on a drive that
        # does not answer holds the lane until it is said not to answer
        # (`StallAfter`), and nothing else.
        let job = state.jobs.submit(JobSpec(title: "Read the units of " &
          f.path.extractFilename, lane: jlPeeks, reads: @[f.path]),
          surveyHeadWork(f, state.inbox.poster))
        let i = state.surveyHead(f.path)
        if i >= 0: state.heads[i] = SurveyHead(file: f)
        else: state.heads.add SurveyHead(file: f)
        state.headJobs.add (job, f.path)
  of ckPrepare:
    state.prepareWanted = if cmd.path.len > 0: canonical(cmd.path) else: ""
    state.prepareNext()
  of ckOpenPair: state.openPair(cmd)
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
    if cmd.table.fields.len > MaxTableColumns:
      state.ignore(cmd, $cmd.table.fields.len & " columns asked: a table shows " &
        $MaxTableColumns & " at most")
    else:
      state.inspect.parts = cmd.inspect # read for by `followInspect`, after every command
      state.inspect.table = cmd.table
      # The rows asked for: an int32 at most, and at most MaxTableRows of them.
      template rows: untyped = state.inspect.table.rows
      rows.a = clamp(rows.a, 0, int(int32.high))
      rows.b = clamp(rows.b, 0, int(int32.high))
      rows.b = min(rows.b, rows.a + MaxTableRows - 1)
  of ckSpectrum: state.openSpectrum(cmd)
  of ckSpectrumDisplay: state.showSpectrum(cmd)
  of ckCloseSpectrum: state.closeSpectrum(cmd)
  of ckSpectrumCursor: state.holdCursor(cmd)
  of ckStepTrace: state.stepTrace(cmd)
  of ckOpenPlot: state.openPlot(cmd)
  of ckPlotDisplay: state.showPlot(cmd)
  of ckPlotCursor: state.holdPlotCursor(cmd)
  of ckClosePlot: state.closePlot(cmd)
  of ckAuxWindow:
    if cmd.onScreen != state.auxOpen:
      state.auxOpen = cmd.onScreen
      if state.auxOpen and state.auxIndex < 0: discard state.addPanel(prAux)
      state.followAux()
  of ckSpectrumPanel:
    template live: untyped = state.spectra[0]
    if cmd.onScreen != live.shown:
      live.shown = cmd.onScreen
      inc live.revision
      if not live.shown:
        # Hidden: nothing more is asked, and the work under way is dropped.
        if not state.spectrumReader.isNil: state.spectrumReader.cancel(LiveSpectrum)
        live.waiting = false
        state.liveKey = LiveKey(session: NoSession)
        if state.spectra.len == 1: state.spectrumReader.forget() # no window needs them
    if cmd.onScreen and cmd.origin == coAgent: inc live.front # the window brought forward
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
  of ckSetCompare: state.setCompare(cmd)
  of ckClearCompare: state.clearCompare(cmd)
  of ckSwapCompare: state.swapCompare()
  of ckCompareDisplay: state.showCompare(cmd)
  of ckCompareWindow: state.setCompareWindow(cmd)
  of ckCorrelate: state.setCorrelate(cmd)
  of ckSubfolders: state.setSubfolders(cmd)
  of ckTreatAs: state.treatAs(cmd)
  of ckFileAuxMark: state.fileAuxMark(cmd)
  of ckProjectAuxMark: state.projectAuxMark(cmd)
  of ckVibProfile: state.storeVibProfile(cmd.origin, cmd.vibProfile)
  of ckVibWeights: state.storeVibWeights(cmd.origin, cmd.vibWeights)
  of ckImportShotLog: state.importShotLogCmd(cmd)
  of ckRemoveShotLog: state.removeShotLogCmd(cmd)
  of ckRemapShotLog: state.remapShotLogCmd(cmd)
  of ckEditShotCell: state.editShotCellCmd(cmd)
  of ckUndoShotEdit: state.undoShotEditCmd(cmd)
  of ckRedoShotEdit: state.redoShotEditCmd(cmd)
  of ckAddLeap:
    let date = LeapDate(year: cmd.leapYear, month: cmd.leapMonth, day: 1)
    try:
      var next = currentLeapTable().withLeap(date, cmd.leapStep)
      if (date.year, date.month, date.day) >
          (next.checkedTo.year, next.checkedTo.month, next.checkedTo.day):
        next.checkedTo = date
      state.adoptLeap(next, addedSentence(date, next.entries[^1].gpsMinusUtc))
    except ValueError as e:
      state.ignore(cmd, e.msg)
  of ckRemoveLeap:
    let why = removeLeapProblem()
    if why.len > 0: state.ignore(cmd, why)
    else:
      var next = currentLeapTable()
      let last = next.entries[^1]
      let date = LeapDate(year: last.year, month: last.month, day: last.day)
      next.entries.setLen(next.entries.len - 1)
      state.adoptLeap(next, removedSentence(date))
  of ckReloadLeaps: state.reloadLeaps()
  of ckResetLeaps:
    let shipped = defaultLeapTable()
    state.adoptLeap(shipped, resetSentence(shipped.checkedTo))
  of ckCutGather: state.cutGatherCmd(cmd)
  of ckExportShotSps: state.exportShotSpsCmd(cmd)
  of ckGenerateOFile: state.generateOFileCmd(cmd)

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
  of rpLeapFile:
    if m.readError.len > 0:
      state.log.add(sevWarning, "leap seconds", "Cannot read " & m.readPath & ": " &
        m.readError & ". The table in use is unchanged.")
    else:
      let parsed = parseLeapTable(m.content)
      let chosen = chooseLeap(parsed.table, parsed.problems, m.readPath)
      for n in chosen.notes: state.log.add(n.severity, "leap seconds", n.text)
      if chosen.notes.len == 0:
        state.adoptLeap(chosen.table, "Read " & m.readPath.extractFilename & " again: " &
          $chosen.table.entries.len & " leap seconds, known complete through " &
          dateText(chosen.table.checkedTo) & ".")
      else:
        state.adoptLeap(chosen.table, "", save = false)

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
  k = 0
  while k < state.leftSpectrumReaders.len:
    if state.leftSpectrumReaders[k].hasEnded: state.leftSpectrumReaders.delete(k)
    else: inc k
  # Finished jobs first: a job posts before it finishes, so every message of
  # a job seen finishing here is in the mail drained next.
  let finished = state.jobs.takeFinished()
  state.inbox.drainInto(state.mail)
  result = finished.len > 0 or state.mail.len > 0
  state.refreshPilotViews()
  for m in state.mail.mitems:
    case m.kind
    of mkOpened:
      if m.job == state.preparing.job: state.takePrepared(move m.session, m.job)
      else: state.adopt(move m.session, m.job)
    of mkLog: state.log.add(move m.entry)
    of mkRead: state.takeIn(m)
    of mkListed: state.takeListed(move m)
    of mkWatched: state.takeWatched(move m)
    of mkKinds: state.takeKinds(move m)
    of mkVendorFields: state.takeVendorFields(move m)
    of mkPaired: state.takePaired(move m)
    of mkSurvey: state.takeSurvey(move m.layer, m.job)
    of mkChecked: state.takeChecked(move m)
    of mkJoining: state.takeJoinPlan(move m)
    of mkJoined: state.takeJoined(m)
    of mkMoves: state.takeMoves(m)
    of mkLeap: state.takeLeap(m)
    of mkInspected: state.takeInspected(move m)
    of mkSpectrum: state.takeSpectrum(move m)
    of mkAnalysis: state.takeAnalysis(move m)
    of mkSurveyHead:
      let i = state.surveyHead(m.surveyHead.file.path)
      if i >= 0: state.heads[i] = move m.surveyHead
    of mkProject: state.takeProject(move m)
    of mkVendor: state.takeVendor(move m)
    of mkEarlier: state.takeEarlier(move m)
    of mkTreated: state.takeTreated(move m)
    of mkReferences: state.takeReferences(move m)
    of mkCompare: state.takeCompare(move m)
    of mkComparePicture: state.takeComparePicture(move m)
    of mkSpreads: state.takeSpreads(move m)
    of mkShots: state.takeShots(move m)
    of mkRecordQc: state.takeRecordQc(move m)
    of mkFirstBreaks: state.takeFirstBreaks(move m)
    of mkIdentified: state.takeIdentified(move m)
    of mkHashed: state.takeHashed(move m)
    of mkMemoryList: state.takeMemoryList(move m)
    of mkMemoryLooked: state.takeLooked(move m)
    of mkMemoryMerged: state.takeMerged(move m)
    of mkEditsList: state.takeEditsList(move m)
    of mkEditsRead: state.takeImported(move m)
    of mkLayout:
      let k = state.findPanel(m.panel)
      if k >= 0 and m.sourceGen == state.panels[k].sourceGen:
        template p: untyped = state.panels[k]
        p.layout = m.layout
        p.laidOut = true
        p.known = m.known
        p.widest = m.widest
        p.componentCodes = m.components
        p.componentCounts = m.componentCounts
        p.componentSensors = m.componentSensors
        if m.componentsCleared and p.layers.len > 0:
          p.layers[0].filter.components = {}
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
      state.traceReads.add (m.job, m.readKeys, move m.headerRows, move m.readVendor)
      if state.traceReads.len > MaxTraceReads: state.traceReads.delete(0) # never taken
    of mkTile:
      let k = state.findPanel(m.tile.panel)
      # The newest request's tile; or, while the filters change frame after
      # frame with nothing else between (a slider dragged), one asked for
      # since they began, newer than those held: the plot follows the
      # slider rather than wait for it to stop.
      let following = k >= 0 and state.panels[k].filterRun > 0 and
        state.panels[k].requestGen == state.panels[k].filterGen and
        m.tile.request.gen >= state.panels[k].filterRun and
        m.tile.request.gen < state.panels[k].requestGen and
        state.tiles[k].allIt(it.request.gen < m.tile.request.gen)
      if k >= 0 and m.tile.levelOnly:
        # the record's level, from its reader, for the changes since it was asked for
        template p: untyped = state.panels[k]
        if p.relevel and m.tile.request.gen >= p.levelSince:
          if not m.tile.request.isEmpty: p.level = m.tile.level # (else none could be had)
          p.relevel = false
          inc p.revision
          state.settleGain(k, coWindow)
      elif k >= 0 and (m.tile.request.gen == state.panels[k].requestGen or following):
        state.unread.keepItIf(it.panel != m.tile.panel) # read again
        state.timeRead(m.tile)
        m.tile.id = state.nextTile
        inc state.nextTile
        # The record's level: a tile of its basis gives it (one of
        # filters already replaced for now, and the newest request's again:
        # the level the plot keeps is of the filters it ends with); a tile
        # of a part of it stands in only while there is none.
        let whole = m.tile.request.sameReach(state.panels[k].basis)
        if state.panels[k].level.clip.isNaN or (state.panels[k].relevel and whole):
          state.panels[k].level = m.tile.level
          if whole and not following: state.panels[k].relevel = false
        # The first tile in a new order, or after the samples changed,
        # replaces every tile from before.
        let since = if following: m.tile.request.gen
                    else: max(state.panels[k].orderGen, state.panels[k].samplesGen)
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
    state.releaseSurvey(job)
  if state.batchSurvey.left.len > 0:
    state.batchSurvey.left.keepItIf(state.jobs.workingOn(it.job))
  if state.leftChecks.len > 0: state.leftChecks.keepItIf(state.jobs.workingOn(it.job))
  state.prepareNext() # (once the main panel has its tile; or a prepare ended)
  if state.stoppedWaiting: state.followNewest() # (a stopped .dat's time may be up)
  state.map.followed(state.survey) # a layer came, or went with a file
  state.relink()
  state.followHidden()
  state.followAux()
  state.followInspect()
  let followed = state.filesHeldByFollow()
  state.followSpectrum()
  state.followPlots()
  state.releaseFollowed(followed)
  state.followMapWork()
  state.followMemoryLook()
  state.followProject()
  state.followMoves()
  state.followLeap()
