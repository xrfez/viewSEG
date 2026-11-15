# viewSEG architecture

The GUI toolkit is Dear ImGui (docking branch) with ImPlot, through
[imguin](https://github.com/dinau/imguin), on SDL3 with OpenGL 3. The program is laid out so
that the toolkit can be replaced later by rewriting one directory. See `ui-toolkits.md` for
why this toolkit was chosen.

## Layers

Dependencies point down only. `tests/tlayers.nim` enforces the rules by reading the imports.

```
src/viewSEG.nim               entry point: picks the frontend (-d:frontend=imgui, the default)
src/viewSEG/ui/imgui/         THE ONLY CODE THAT KNOWS IMGUI, IMPLOT OR SDL
        │  (a future ui/<toolkit>/ replaces this directory)
        ├──────────────────▶ src/viewSEG/remote/   agent control: an MCP server on a thread
        │                                           of its own; posts Commands, answers from
        │                                           the state at frame boundaries (core only)
        ▼
src/viewSEG/gpu/              GPU resources for OpenGL frontends: float32 textures,
        │                     the density and wiggle shaders, the plot's image,
        │                     the map's points
        ▼
src/viewSEG/view/             view models: what each panel shows, toolkit-neutral
        ▼
src/viewSEG/core/             application state, commands, jobs, kernels; no UI, no OS windows
        ▼
parseSEG, processSEG          (deps/, bind-mounted in the devcontainer)

src/viewSEG/platform/         OS integration that needs raw OS APIs (Windows resources,
                              window chrome, config paths); used by the frontend
```

| Layer | Owns | Must not import |
|---|---|---|
| `core` | `AppState` (open files, panels and their layers, the selection, the message log, the survey: where sources and receivers are, with a spatial index), `Command`s (each user intent as data), jobs in two lanes (prefetch through parseSEG's `Prefetcher`, processing through processSEG plans and its pool; results posted to a main-thread inbox), thread guards and the frame watchdog, kernels (colour maps, decimation, picking, cursor readout), map maths (tiles, projections, hit-testing) | `ui`, `gpu`, `platform`, any toolkit, SDL, OpenGL |
| `view` | View models such as `PanelView`, `TableModel`, `TreeModel`, `PlotSeries` and the map's `MapLayerView`. Each has plain-Nim geometry (`Vec2`, `Rect`, `Rgba`) and a `revision` counter that bumps on change | `ui`, `gpu`, `platform`, any toolkit |
| `gpu` | OpenGL 3 objects behind small procs: upload a sample tile as `R32F` textures (`textures`), the density shader and its colour-map LUT (`density`), the wiggle shader (`wiggle`), the plot's image that draws a panel's tiles with them (`plotimage`), and the map's image of the survey's points (`mappoints`). It loads the GL functions it needs itself (`gpu/gl`), through a loader the frontend passes in (`SDL_GL_GetProcAddress`), so it imports no GL binding package | `ui`, any toolkit (OpenGL itself is allowed) |
| `platform` | `winres` (compile-time manifest, icon, version info), window chrome (DWM attributes on a native window handle), config paths, and whatever else needs raw OS APIs. Services the windowing library already has (SDL3: file dialogs, system theme, tray) are wrapped in `ui/<toolkit>/shell` instead, because only `ui` may import SDL | `ui`, `core`, any toolkit |
| `remote` | Agent control (below, "Agent control"): the Model Context Protocol subset, the server thread and its socket, the tools, the command schema made from `Command`, and the stdio bridge an MCP client starts. A front end beside the windows: it reads `AppState` and posts `Command`s, on the UI thread, when the frontend calls it once per frame | `ui`, `gpu`, `view`, `platform`, any toolkit |
| `ui/imgui` | The frame loop, docking layout and viewports, widgets that draw view models, input → `Command`, and `shell` (SDL3's file dialog, system theme and tray; results come back as inbox messages); starts agent control and gives it the screenshot and the drawn view | (top layer) |

## Rules that keep the toolkit replaceable

1. **No toolkit types outside `ui/`.** `core` and `view` use their own `Vec2`, `Rect`, `Rgba`
   and `Key`, never `ImVec2`, `SDL_Window` or `ImPlotPoint`. `platform` takes native handles
   (`HWND`, X11 `Window`) as pointers.
2. **The UI never mutates state.** It reads view models and issues `Command`s. An
   immediate-mode frontend reads everything each frame. A retained-mode frontend (Qt,
   GTK, Merenda) instead compares `revision` counters and updates only the widgets whose
   models changed. That is why the counters exist even though ImGui does not need them.
3. **Heavy work never runs on the UI thread.** `core` jobs run on workers and post results.
   The frontend drains the inbox once per frame (or per event-loop turn).
4. **Pixels are computed in `core`/`gpu`, not in widgets.** The sample-to-colour mapping,
   decimation, wiggle geometry and the cursor readout (screen point → trace, sample, value,
   header) are plain procs with tests. The widget only places the result.
5. **Platform features go through `platform`**, given a native window handle. The
   frontend passes `SDL_PROP_WINDOW_WIN32_HWND_POINTER` and similar. A different toolkit
   passes its own handle and gets the same Mica, dark title bar and tray.

Swapping toolkits means writing `ui/<toolkit>/` (widgets bound to the same view models and
commands), plus `gpu/` if the new toolkit is not OpenGL. `core`, `view`, `platform` and all
tests stay as they are.

## Windows: what makes the window look native

There are two parts, and both are needed. SDL and GLFW cannot supply the first.

- **Compile time** (`platform/winres.nim`, already in place). It embeds `res/viewSEG.exe.manifest`:
  - Common Controls v6: visual styles for native dialogs, menus and the tray menu;
  - per-monitor DPI v2;
  - the Windows 10/11 `supportedOS` entry;
  - UTF-8 code page and long paths.

  It also embeds the icon `res/viewSEG.ico` as resource 1 and version info taken from
  `viewSEG.nimble`, and links the GUI subsystem so no console window opens.
  - It works with MinGW (`windres`), MSVC (`rc`) and zig (`zig rc`).
  - The zig path works from the Linux container: `nim winRelease`.
  - `-d:console` keeps a console for debugging.
- **Run time** (`ui/imgui/shell` for what SDL3 provides, `platform/chrome` for the rest;
  still to do). This reads the system light/dark setting and accent colour and follows
  changes to them. On every window,
  including each ImGui viewport window, it sets these DWM attributes:
  - `DWMWA_USE_IMMERSIVE_DARK_MODE` (20);
  - `DWMWA_SYSTEMBACKDROP_TYPE` (38) for Mica on Windows 11 22H2+;
  - `DWMWA_WINDOW_CORNER_PREFERENCE` (33);
  - caption and border colours (35, 34).

  It also matches the ImGui style to the theme. SDL3 already follows the system theme for
  the title bar; the module applies the rest. For window and taskbar icons, set the hints
  `SDL_HINT_WINDOWS_INTRESOURCE_ICON` and `..._ICON_SMALL` to `"1"`.
  - Tray: SDL3's tray API. In SDL 3.4.x on Linux it uses AppIndicator through GTK.
  - Dialogs: `SDL_ShowOpenFileDialog` (since 3.2), which uses the native dialog on
    Windows and XDG portals on Linux.
- **Linux:** a `.desktop` file plus hicolor icons for the launcher. The window icon comes
  from `SDL_SetWindowIcon` (embed a PNG with `staticRead`).

## Threads

How rule 3 maps onto parseSEG (0.11) and processSEG (0.4). The contracts come from parseSEG's
`docs/guide/viewer.md` and `getting-started.md`, and from processSEG's `docs/integration.md`.

| Thread | Created and owned by | Runs |
|---|---|---|
| UI (main) | `src/viewSEG.nim`; `initAppState` marks it | The frame loop: drains the inbox once per frame (`drainInbox`), applies `Command`s to `AppState` (`apply`), hands the files it lets go of to the closer, and makes every OpenGL call; it reads no header and no sample from a file (a trace's headers for an agent are read on a job: Network drives, below) |
| Interactive jobs | `core/jobs`: a runner started by `initAppState`, with its own queue | Short work the user is waiting on: open and index, an open file's positions, survey files read, `ensureKeys`, survey joins, sorts across files |
| Background jobs | `core/jobs`: a second runner and queue | Long work: whole-file columns, QC passes (an open file's records against the loaded relation file, `checkWork`), folder scans, the listed files' shots (`shotsWork`), the map's planned spreads (`spreadWork`), the record shown for the map's filters (`recordQcWork`), brute stack, conversions, exports and patches, queued workflows |
| Disk | `core/diskio`, started by `AppState.logTo` | Writes the program's own files: appends the session log (making its lines from the log's entries), replaces settings and layouts atomically (a temporary file, flushed, then renamed), prunes old logs; lists the layouts; reads the documents the user imports and makes their NIF tree; failures come back as log messages |
| Folder watch | `core/watch`, started by `AppState` when a listing or an open file needs it | Looks at the folder listed and at the open files about once a second (names, then `stat`; the first 4 KiB of a file not known to be seismic when it appears or changes), and posts what changed (`mkWatched`); never opens what is not a regular file |
| Panel reader | `core/reader`, one per trace panel, started when the panel first shows a file | Owns that panel's `Prefetcher` and the samples it last read; applies the trace filter, sorts the traces in the layer's order (`core/sorting`), applies the file's edits and runs the display pipeline on each chunk (its own `Workspace`), cuts the tile and posts it |
| Agent server | `remote/server`, started only when agent control is turned on | Accepts MCP clients on the socket, reads and frames their messages, answers the handshake and the tool list itself, queues tool calls for the UI thread and writes the answers it is given; never reads or changes `AppState` |
| Headers reader | `core/inspector`, started by `AppState` when the Headers window first has something on screen to read | Reads what the Headers window shows of the files' bytes: a SEG-D record's headers (`recordHeaders`, `copyBytes`), the chosen traces' header fields (`traceHeaders`) and samples (`readTraces`, then the edits and the display pipeline when shown as displayed, its own `Workspace`), and posts them (`mkInspected`); newest request wins; a `stat` of each file first, and every read marked (`fs.mappedRead`): one stuck in a drive is left for a new one (Network drives, below) |
| Prefetch workers | parseSEG: `newPrefetcher(workers = n)`, called on the panel thread | Decoding only; joined by the prefetcher's `close` |
| Pool workers | processSEG: one `ProcessPool`, made by `core` at start-up | The rows of `pool.apply`, `pool.pickInto` and `pool.traceAmplitudeInto`; destroyed at shutdown, once every caller has stopped |

### Jobs

`core/jobs` runs everything that blocks, apart from a panel's own reads, in two lanes, so
the wait the user notices is never behind a long job.

- **Lanes.** Each lane has a runner thread and a queue; within a lane jobs run one at a
  time, in queue order. The interactive lane is for what the user waits on; the
  background lane for the rest. Background work uses its own processSEG workspaces, not
  the shared pool, so it cannot stall a panel.
- **A job** (`JobSpec`, `JobInfo`) has a title in plain words, a lane, a state (queued,
  running, done, failed, cancelled), progress (done of total, a phase label), and the
  files it reads or needs to itself. Queued jobs can be reordered, removed or cancelled;
  a running job can be asked to stop; finished jobs stay listed up to a history limit. A
  job submitted with `cancellable = false` (closing a file) can only be reordered until
  it has run; `stop` still cancels it.
- **Files.** A job does not start while a running job, or a job queued ahead of it in its
  lane, uses one of its files in a conflicting way: reading is shared, exclusive use is
  not. A job that must wait does not hold up the jobs behind it that need not.
- **Holds.** A reader that is not a job, such as a trace panel's thread, holds the file
  instead: the UI thread calls `hold(path)` before it hands the reader the file, and the
  reader calls `release(path)` once its prefetchers are closed. A job that needs the file
  to itself (a close, a join) does not start while the file is held, and `hold` is
  refused while such a job is queued or running, so readers cannot keep it waiting.
- **Progress and cancel.** The work gets a `JobContext`: `progress(done, total)` returns
  false once a cancel is asked for, so it serves as parseSEG's `Progress` callback;
  `checkCancelled` raises `JobCancelledError`. Work that returns is done; work that raises
  is failed, or cancelled if a cancel was asked for first.
- **Wake-ups.** Every change that can let a queued job start (a submission, a job
  finishing, a removal, a move, a cancel) wakes both runners.
- **Results** go to the UI thread through the inbox (`core/inbox`): `post` from any
  thread, `drainInto` once per frame, which only swaps two buffers under a lock.
  `drainInbox` takes the finished jobs first and then the messages, so a job's messages
  are always taken in no later than its end.
- **Stop.** `shutdown` (or destroying `AppState`) cancels the queued jobs, asks the
  running ones to stop and waits for the runners until a deadline; one held by a drive
  that does not answer is left (Network drives, below). Work must notice its cancel.
- **What the user sees.** The status bar shows the job the user most likely waits for
  (`view/jobstatus`); the Jobs window (`view/joblist`) lists the running, queued (in each
  lane's order, with up, down and remove) and finished ones, and turns its buttons into
  `ckCancelJob`, `ckReorderJob` and `ckRemoveJob`. A background job that ends (done or
  failed) also leaves a `Notice` (`AppState.notices`, the newest 20) that the frontend
  shows for a few seconds; a listing of the file list does not, the list shows it.

**Open and close.** An open is an interactive job that reads the file; its session comes
back as an `mkOpened` message, and `AppState` gives it a `SessionId` and the survey-wide id
of its first trace, logs parseSEG's diagnostics, and shows its first gather in the main
panel. The job reports progress ("indexing", or "reading the index cache") and stops at
its cancel: parseSEG's walk stops at the next progress call, and a cancel that comes
after the walk still closes the file on the job's thread and posts nothing. A close
takes the file out of every view at once, cancels the jobs that use it, and queues a
close job that needs the file exclusively; when that job ends (after every job that read
the file, and every hold on it), the UI thread hands the file to the closer's thread
(`core/closer`, Network drives below). The close job cannot be
cancelled or removed: until it has run, a job may still be reading the file. Paths are
made absolute and normalized when a file is opened, so every job names a file the same
way and one file is never opened twice.

**The file list** (`core/filelist`). `ckBrowse` lists folders or files: a job on the
background lane (`filejobs.scanWork`) reads each folder's names, puts them in natural order
("shot2" before "shot10"), reads the first 4 KiB of each file to tell SEG-Y, SEG-D and
SEG-2 apart (parseSEG's `detectKind`), and SPS (S, R, X) and SEG P1 survey files
(`core/filekinds`), and posts what it found in batches (`mkListed`), so
the list fills as the scan goes and no file is opened. Survey files are listed as what
they are; stepping through the list passes them by, and a click on one loads it into the
survey (below), as do the survey files among the files named to `ckBrowse` (a drop). What is not a regular file (a named
pipe, a socket, a device) is counted and never opened: opening a named pipe waits for a
writer, which would hold the scan, the background lane and the quit. One file named alone stands for its
folder. `ckShowFile` shows a file in a panel in place of the one it shows: at once when it
is open, else through an open job made for that panel; when the panel has shown it, the file
it showed before is closed unless another panel shows it, so stepping through a folder
keeps one file open, and the index cache makes stepping back quick. A file chosen while
another is still opening cancels that open (if it comes all the same, it is dropped). The
next file is shown at the scales of the one before (`zoom.carried`), with the same display,
order and display header. `FileList.chosen` is the file the main panel shows or is
opening; the frontend's file table (`view/filetable`) filters, sorts and steps from it.
The list notes each change of its entries (`FileList.changes`: a batch added at the end,
an entry added, changed or taken out), and the table follows them in the rows it has, so
a batch, or one file that appears, costs a pass over the rows instead of a sort of a
folder of 100 000 files.

**Watching the folder** (`core/watch`). When a scan is done, its last message carries every
file it looked at (`listLooked`), and the folder's watch, a thread of its own, starts from
that: about once a second (`WatchInterval`; ten looks' time when a look is slow, as on a
network share) it reads the folder's names and `stat`s each file, and posts what changed
(`mkWatched`): a seismic file that appeared (a file being written is too short to tell at
first, so a file not known to be seismic is sniffed again when it changes), one whose size
or time changed since the look before (`changing`), one that stopped changing, one that
went. No operating system notification is used, so it works the same on every system and
on shares. A folder that cannot be read is said once and keeps its list. It is its own
thread, not a job on the background lane, so a long background job (a QC pass) never
holds it up and the Jobs window is not filled with looks; its `stop` waits until a
deadline only, so a share that hangs a look cannot hold the quit. `AppState.takeWatched` updates
the entries: a new one is marked `isNew` until it is shown, one that changed is
`fsWriting` until a look finds it the same, one found cut short when opened is
`fsShort`. With **Follow the latest** (`Settings.files.followLatest`), the newest file
that is new and steady is shown in the main panel, once, through an open made with
`whole`: if parseSEG finds it cut short (a `truncated` diagnostic), it is not shown (and
not cached), and it is tried again once it has changed. Without it, nothing moves: the
plot stays on the file the user chose.

**An open file that changes on disk.** The watch also looks at the open files
(`watchOpen`), and `AppState` compares each with its size and time when it was opened
(`Session.size`, `modified`). One that grew or was written again is let go of and opened
anew once it stops changing, in the same panels, at the same record and scales, with the
same layers (`closeSession(keepLayers)`, `Reopen`); one that is shorter is let go of at
once, since reading the map past the file's new end ends the program (SIGBUS), and shown
again once it stops changing. The panel's reader also `stat`s the file before each read
from it, and reads nothing of a file shorter than it was opened. What remains (POSIX
only: Windows does not let a mapped file be cut): a file cut short by another program
while a read of it is under way still ends the program; only reading the samples with
`pread`, or a guard around decoding, in parseSEG, removes that. Edits made on a file are
kept with its size and time; when the file is opened again changed, they are set aside
as "Clear all edits" does, so Ctrl+Z brings them back.

**Network drives** (`core/filesystem`). A drive can answer slowly, stop answering for
minutes, or go away while a file is open; the window must stay alive, say what it waits
for, let the user go on, and quit.

- **The seam.** Every file-system call `core` makes goes through `fs` (`fs.getFileInfo`,
  `fs.walkDir`, `fs.open`, `fs.readFile`, `fs.moveFile` ...: the `std/os` calls of those
  names, behind a hook), and `fs.mappedRead` marks where parseSEG reads a seismic file's
  map (each step of the open's walk, each chunk a panel's reader takes, each read of the
  Headers reader; header blocks alone, `headers = true`: the file's own read with its
  open, a record's, a trace's), which cannot go through it. `fs.now` is the clock the waits on drives are measured with. Tests install a
  hook (`tests/utils/faultyfs`) that makes chosen paths slow (it moves `fs.now` on), hang
  (it blocks until released), fail (EIO) or wait for a round trip the test grants, and
  that keeps every call made on the UI thread; `tfilesystem` checks that no module of
  `core` calls the file system past the seam. A step that reads no file but takes long
  (a join's) is held the same way by `core/jobs`'s job hook (`setJobHook`, called at each
  phase a job names; `tests/utils/steps`), and `tstragglers` runs the quit with such a
  thread left, under AddressSanitizer. Outside it, by design: the program's own
  assets (themes, fonts), `platform/paths`' probe of its folders at start, and the
  settings and the window layout, read once before the main thread becomes the UI thread.
- **The UI thread never touches a drive.** Paths are made canonical without the disk;
  the folder listed last is listed again at start by the listing (a folder gone is said
  quietly); the layouts are listed on the disk thread; a settings reset's backup gets its
  free name there; the folder's watch makes no call under the lock the UI thread takes;
  native dialogs run outside this thread (SDL). The locks the UI thread takes (the inbox,
  the jobs, each reader's, the watch's, the disk thread's) are never held over a call.
- **Nothing waits for a stuck thread without a bound.** A running job beats as it
  reports (`progress`, `setPhase`); one silent for `StallAfter` (3 s) does not answer
  (`notAnsweringFor`). `Jobs.tend`, each frame, gives its lane a new runner when work
  waits behind it (it runs on, and its result is taken), and abandons it once cancelled
  and still silent (or after `CancelGrace`): listed as cancelled at once, its result
  dropped, its files held until its work comes back, so nothing it reads is closed under
  it (`docs/models/jobsabandon.nif`). A panel's reader beats per chunk; a reader silent
  for `StallAfter` is left when its panel is given something else, or on Cancel, and a new
  one takes over; its late tiles answer an old request and are dropped. The Headers
  reader (`core/inspector`) beats before each call, naming the file; one silent for
  `StallAfter` is left (`leave`, kept in `leftInspectors` until it ends) when the window
  wants another file read, and a new one reads it; a request on the stuck file waits for
  it. Its late answer is older than what was taken since, and dropped. Every thread's
  `stop` waits until a deadline; `AppState.shutdown` asks them all at once and waits for
  them together at most `QuitWait` (0.8 s); a thread left keeps its memory, and the open
  files and relation files it may read, to the end of the process
  (`docs/models/jobsquit.nif`).
- **What the user sees.** `AppState.waiting` (a panel: an open or a read not answering,
  or a file that cannot be read now, `mkUnread`) and `listingWait` (the listing, or the
  watch's look, not answering), worded by `words`; the plot and the Files window show them
  with Cancel (`ckCancelJob`, `ckStopReading`) and Retry (`ckRetry`: open again, read again
  with a new reader, list again with a new watch). `headersWait` (the Headers reader not
  answering) is a line above the Headers window's tabs, which keep what was read; a read
  the drive fails is said in the tab (the trace's or the record's problem), and the file's
  own headers that its open could not read in the Summary.
- **Agent control's socket** (`remote/server`) is made, and at the end removed, on threads
  of their own: finding the default socket writes a probe in the program's folder, and the
  socket is made there, a folder that may be on a share. Turning agent control on waits
  `StartWait` (0.5 s) for it, then says the folder does not answer yet and takes the
  server in a later frame; turning it off, and the quit, wait 0.2 to 0.5 s, then leave the
  removal to its thread. These calls are on a socket and its folder, outside `fs`.
- **Files are closed off the UI thread** (`core/closer`): a close can wait for a share,
  and parseSEG 0.11 unmaps and closes under one lock of its own, so one stuck close holds
  every other open and close (an open then says it does not answer). `AppState` hands a
  file it lets go of (after its close job, or one never handed to a reader) to the
  closer's thread, emptying its own list of cycle roots first; prefetchers are made and
  closed only on readers' and jobs' threads (`Prefetcher.close` joins its decoders with no
  bound). A file a thread left may still read is never closed: its hold keeps its close
  job waiting, and at the quit it is kept to the end of the process.
- **A drive that goes away.** The reader `stat`s the file before each read and reads
  nothing of a file it cannot look at (or that is shorter than it was opened): the plot
  keeps its picture and says why, a drive that fails apart from a file cut short
  (`UnreadCause`), as parseSEG's coming `readFailed` and `cutShort` will tell them apart. A fault in the middle of a read (the drive fails, or the
  file is cut short then) still ends the program, in parseSEG's mapped read, until
  parseSEG guards its maps.
- **Slow drives.** Each tile says how long its reader waited for the samples
  (`Tile.readTime`, on `fs.now`); a panel whose reads wait 30 ms or more for 64 traces
  (`SlowPer64`, smoothed) reads `SlowReadAhead` (3) views ahead, keeps `SlowKeepAhead`
  (2), in reads of `SlowChunkTraces` (256) traces, its read-ahead within
  `SlowMaxAheadValues` (128 MiB; the panel's tiles stay within 192 MiB). A request the
  view has left is given up between chunks (a newer note). With **Prepare the next file**
  (`Settings.files.prepareNext`, on by default) the Files window names the file a step
  down would show (`ckPrepare`); once the main panel shows its file with a tile, a
  background job opens it through the index cache (local: `<cache>/index`, never beside
  the file) and reads its first view's samples (`prepareWork`), and the session is kept
  unshown until the user steps to it (`showPath` takes it as an open). A file over 2 GiB is
  not prepared. Measured with the seam (`tslowdrive`, round trips counted): panning half
  a view a step, two round trips a step, 26 of 30 steps waited at the old read-ahead, 2 on
  a drive found slow; stepping through four files at 200 ms a call, 138 calls waited for
  without preparing, 30 with.

**The survey** (`core/survey`, `core/surveyjobs`, `core/spatial`). Where the sources and
receivers are, for the map and for linking traces to the places they were recorded at. One
model, two sources of positions, each a `SurveyLayer`:

- **an open file's traces:** when a file is opened, a job on the interactive lane
  (`positionsWork`, the file in its `reads`, so a close cancels it and waits for it) copies
  its keys (`traceKeysInto`: source and receiver coordinates with the SEG-Y scalar
  applied) a chunk at a time into a layer, which goes when the file closes;
- **survey files** loaded on their own, with or without a seismic file: SPS source,
  receiver and relation files and SEG P1 files (`ckLoadSurvey`). File → Open, a drop, the
  command line and a click in Files all reach them: the open job reads a file's first
  bytes and loads a survey file into the survey instead of opening it (`openFileWork`),
  and the plot stays as it is. An SPS file is read in 4 MiB chunks (`parseSps`, the
  revision and layout of the first chunk kept), each cut after its last line end, so
  any size is read in bounded memory, with progress and a cancel between chunks; lines
  that hold binary bytes are passed by, and a file that turns into other data (16 MiB in
  a row of binary lines or of lines that are no record) is read no further. A P1 file is
  read whole, up to 64 MiB. A file's problems go to the log by line, the first 20 one by
  one, then a count. A file that is not a survey file, or not a regular file (a named
  pipe is never opened), is refused with a message.

**Positions are per trace**, so land, marine and transition data all work: each trace's
source and receiver become points of its file's layer, merged only where they repeat, at
the same station and the same coordinates (a land receiver recorded in every shot); a
streamer's receivers move with every shot and stay apart. A survey file's station given
twice is one point, where it was given last (as parseSEG's join takes it). **Missing and
zero coordinates are data:** a position without coordinates, or at (0, 0), is counted per
role (`Positions`), said in the log, and left off the map; nothing raises. Each role's
points (`PointSet`) are kept in the order of a **uniform-grid spatial index**
(`SpatialIndex`: square cells over the points' bounds, about one point a cell, the points
of a cell side by side; a few points far from the rest, a wrong coordinate, lie in the
edge cells, which reach out without end, so they do not make the cells huge: `grid`):
`nearest(x, y, radius)` looks at rings of cells around the place until no nearer point
can be in the next ring, `within(box)` at the cells the box covers, and `bounds` gives
what fit needs. The levels of detail keep each far point as a point of every level. A traces layer also keeps each trace's point
and station and the traces of each point and station; a survey file's layer finds a
point by station as parseSEG's join finds one (the same index, then any index, then the
first position). **Links:** `tracePoints` gives the points a trace was recorded at in
every layer (its own file's by trace; the survey files' by its stations, filled from the
loaded relations with `joinStations` when its keys lack them), and `tracesAt` the traces
of the open files at a point. **The join:** `joinGeometry` makes parseSEG's
`SurveyGeometry` from loaded survey files (the first relation file's relations and every
file's stations) for `applySurvey`, so a join reads no file again. Layers are made off
the UI thread and never change once made: a file loaded again, or keys changed by a
join, make a new layer in place of the old (each layer's `keysRevision` says which keys
it was made from). A million traces become a layer in about 0.1 s (land) to 0.25 s
(marine, every receiver a point of its own) in an optimised build; a lookup takes a few
microseconds.

**The map** (`core/mapview`, `core/maplod`, `core/mapstate`, `view/maplayers`,
`gpu/mappoints`, `ui/imgui/mapwindow`; docs/plot-window.md, "The map window"). A
`MapView` is the survey point at the plot's centre and the survey units per pixel, the
same across and down, so the map is at equal aspect by construction; `core/mapview` moves
it (zoom about a point, pan, drag, box zoom, fit, a new plot size) and keeps it within the
survey: never zoomed out past the whole survey, never past its bounds by more than equal
aspect needs (`keptMap`). The frontend moves the view itself and reports it (`ckMapView`,
with `mapRemember` at a gesture's start, for `ckMapBack`); `AppState.map` (`MapState`)
holds it, the views before it and the layers hidden (`ckMapLayer`, by file and role, so a
file loaded again stays hidden; the groups of layers, Preplot and Recorded, `core/mapkinds`,
are hidden as a whole through the settings, `map.hiddenGroups`, and `drawn` says whether a
layer is drawn, found under the pointer and highlighted), and follows the survey after every command and every
drained inbox (`followed`): a map that showed the whole survey fits the new one, another
view is kept within the new bounds and the frontend follows `jumps`. **Levels of detail**
are made with each layer, on the worker that reads it (`SurveyLayer.levels`, `withLevels`:
`buildLevels` per role): grids twice, four times ... the spatial index's cells, a point per
cell (the first of the cell, a real position), each kept row by row so the points of a view
are a run per row (`runs`), the positions as `float32` relative to the layer's corner; and
how far apart its points typically are (`spacing`), from which the frontend sizes the
markers. `gpu/mappoints` uploads a layer's points and levels once, and each frame draws, per
layer, the coarsest level whose cells are no wider than two pixels (every point,
from the index's own runs, closer in), as point sprites made discs or rings in the fragment
shader, into an image the size of the plot, then the highlight; an image whose inputs did
not change is not drawn again. So no pan or zoom waits for anything: 1 000 000 points draw
about 60 000 at fit. The view models (`view/maplayers`) say what each layer is and its
colour, the highlight (the points of the record on show, `activePoints`: `recordPoints`, its
traces' own points and stations, or the stations its relation runs plan when its headers name
none; of the selection: `tracePointsOf` from a traces layer's stations, so it needs no keys;
and of the plot's hovered trace, `Selection.hoverAt`), what a click on a point does
(`opensRecord`: a source's click shows its record), the points near a place
(`pointsAt`: the nearest within a radius and the others on its spot) and in a box
(`pointsIn`), what the map says of a point (`pointInfo`: station, coordinates and units,
file, the open files' traces at it and their records, a source's field records from the
relation files, `recordsAt`), and the words of coordinates and lengths. **Selecting
points** (`ckSelectPoints`) keeps them in `Selection.points` beside the traces and selects
the traces recorded there (`Survey.tracesAt`), or, as a range, the stations along a line
from the point clicked last (`lineRange`, `Selection.pointAnchor`); a trace selection made
anew takes the points away, `ckClearSelection` takes both.

**The template box** (`core/spread`): the spread planned for the record on show
(`shownSpread`) and for the shot under the map's pointer (`spreadAt`), from the first
loaded survey file with relation records of the domain shown (X for shots, O for receiver
gathers: `shownDomain`), the record found as processSEG's `recordCompleteness` finds it
(`xRecordOf`), the box round the planned stations' places along their lines (`boxOf`).
When no relation file has them, a job on the background lane (`spreadWork`) reads the
survey files again (`surveyjobs.readGeometry`, quietly) and makes them: X records
generated from the user's template (`generateRelations`) and O records from them, or O
records from the loaded X records (`receiverRelations`); `AppState.spreads` keeps them,
the job is cancelled and another submitted when the survey files or the template change
(`followMapWork`, after every command and drained inbox), and the records made before stay
drawn until the new ones come.

**Linking the plot and the map** goes through the selection only. `ckHover` (the plot's
pointer) finds where the trace was recorded, `Selection.hoverAt`: from a copy of its keys
in the panel's tile (`tracePoints`, so a loaded relation file fills the stations the
headers lack with `joinStations`), else from its file's traces layer. `ckHoverPoints` (the
map's pointer) keeps the points and the traces of the open files recorded there,
`Selection.hoverTraces` (`hoveredRevision` goes up when they change), which the plot draws
as its hovered trace through a bit of each tile's marks. `ckShowPoints` shows, in the main
panel, the record of a point's traces (the file shown first, nothing when one is on show).
After every command and drained inbox, `relink` finds both again when the survey changed
and words `hoverNote`, why the hover lights nothing up in the other view (no position, no
station in a loaded file, no trace, traces only in other records), which the status bar
shows. None of it reads a trace or makes a layer again. Without the join, a survey file's
point finds the traces whose headers name its station; one whose headers name none is
linked one way only, from the trace (through the relation file), until the file is
joined with its survey (below). Code outside `core/survey` indexes the survey's layers
(`template l: untyped = st.survey.layers[i]`): a `for l in st.survey.layers` over the
accessor makes ARC copy the whole seq first, every layer (a hundred megabytes for a
million points), each time.

**The survey import** (`core/join`, `ckJoin`, File > Import > Survey...; `ui/imgui/joindialog`,
the "Import survey" window). The user imports a survey; the code keeps parseSEG's word for
what it does, a join. Its SPS and P1 files not on the map yet are loaded onto it as File >
Open loads them (`loadSurvey`, each a layer; their loads are `Joining.loads`), while the
join below runs; the import ends, and its report and log line are made (`finishImport`:
the points on the map, then the join's words), when both are done. With no file open
(`joinFile` none) it is the loads alone (`joMapOnly`). A cancel or a failure cancels the
loads and takes the layers they gave off the map again (a layer a cancelled load still
posts is dropped: `droppedLoads`). A CSV table is joined, not drawn: it has no layer yet.
Survey files (SPS S, R and X with parseSEG's `addSps`, SEG P1 with `addP1`, CSV tables of
stations with `addCsv`) are joined to an open file's trace keys in memory: the file is
never changed, and a file opened again is as it is on disk. Two jobs, so that the plot
stops reading the file only for the moment its keys change:

1. **Read and plan** (`joinReadWork`, interactive lane, the file and the survey files in
   `reads`): the survey files are read into one `SurveyGeometry` with the join's options
   (`mapLine`, `trailingDigits`, `multiComponent`), SPS a chunk at a time as the survey
   loads them (`eachSpsPart`), each file's problems logged; then the join is worked out on
   copies of the keys (`planJoin`, `traceKeysInto` a chunk at a time, with progress and a
   cancel): per trace, `joinStations` and `applySurvey` on the copy, so the plan is what
   the join will do, trace for trace: how each matched, which stations the survey has,
   how far the headers' coordinates are from the survey's, which traces stay unmatched,
   whether the headers' coordinates are replaced (when the user asks, or when every one
   they give is (0, 0)). Readers go on reading the file meanwhile (shared reads). The
   geometry and the plan come back as `mkJoining`.
2. **Join** (`joinApplyWork`, the file in `exclusive`), only when the plan changes some
   trace's keys: **the stop-the-readers protocol**. The UI thread tells each panel that
   shows the file to let go of it (`pauseReaders`: its reader is shown nothing, ends its
   hold; the panel keeps its tiles, layout and view); the job starts once no job reads
   the file and no reader holds it, checks that no hold is left (`HoldRelease.held`;
   it refuses to join otherwise), and runs `applySurvey(f, g, stats, overwrite)` (or
   `applyGeometry` for CSV tables alone), which bumps `keysRevision`; a cancel that comes
   before it joins stops it. When it ends, done or not, the panels read the file again
   (`resumeReaders`: the same gather at the same scales; the tiles from before are drawn
   until the first new one comes, through `samplesGen`), so new prefetchers and `rowsOf`
   views see the joined keys. A panel shown the file meanwhile waits for the join quietly.
   The step that changes the keys reads no file and runs to its end: the job commits to
   it (`JobContext.commit`), so a cancel then is refused and `Jobs.tend` never abandons
   it (abandoned there, it was said cancelled, "as it was", while it still changed the
   keys). An exclusive job abandoned before that keeps readers out until its work is back
   (`hold` refuses the file of an abandoned exclusive job). The protocol is modelled in `docs/models/joinreaders.nif`
   (a reader near the file while its keys change is never reached; without that refusal,
   it is).

A joined file keeps what it was joined with (`AppState.joins`: the files, options, units,
the plan, the geometry): its positions are read again from its keys (the map), its records
are checked against the joined relation records (`checkWork` with the join's
`RecordMatch` and `TraceMatch`, every relation file of the join merged, as a loaded layer
cannot), the units the user confirmed label the map and the status bar first
(`surveyUnit`: then a survey file's SPS H20 and H201, then a seismic file's headers; named
exactly, `m`, `ft`, `ftUS`, and never guessed; `shownLengths` converts the scale bar's and
the ruler's lengths when the map's settings ask for another unit), and
**Select unmatched traces** (`ckSelectUnmatched`) selects the traces the survey lacks a
station for. A tile carries the groups of each row's keys a join gave
(`Tile.joined`, parseSEG's `joinedGroups`), so the display header, the cursor's header box
and the status bar draw joined values in the accent colour. What the join did is said in
plain words (`planWords`), and a join that matches nothing says why (`whyUnmatched`: the
line numbering, text line names, record numbers not in the relation file) and changes
nothing. Units are labels: the dialog starts each at what the headers say
(`summary.coordinateUnits`, SPS H20 and H201) and shows the file's CRS text as read;
datum and projection as values are a parseSEG request.

**The Headers window** (`core/headers`, `core/fielddocs`, `core/inspector`,
`view/headerviews`, `ui/imgui/headerswindow`). What a file is and its file-level headers
are read by the open job with the session (`Session.facts`, `fileFacts`: parseSEG's
`summary`, `channelSets`, `crsText`, `fileHeaders`, `textHeader`, `extendedTextHeaders`, and
the bytes of the blocks without named fields), so the Summary tab and a SEG-Y file's File
headers cost the UI thread nothing. What depends on the record or the traces shown is read
by the Headers reader, a thread of its own (`core/inspector`, built like a panel's reader:
a request replaces the one not yet taken, one being served is given up between traces for
a newer, each file is held while it reads it, a file cut short is not read): a SEG-D
record's headers, and the chosen traces' header fields and samples. The window tells
`core` what it has on screen (`ckInspect`: the record's headers, the traces' fields, their
samples), and after every command and drained inbox `followInspect` works out the traces
the Trace tab is about (`chosenTraces`: the selection; else, with "Follow the pointer", the
trace under the plot's pointer or the traces at the map's; else those pointed at last; the
first `MaxInspected`) and asks the reader again when what is on screen, those traces, their
edits or the plot's processing (as displayed) changed. Each answer newer than the one shown
is taken in (`AppState.inspection`), the newest asked or not, so that a moving pointer
shows each trace a request behind rather than nothing. Every field becomes a `FieldRow`
(block, name, description in plain words from `fielddocs`, value as text and as a number,
the bytes in its block from 1, the file offset); `fieldTable` sets header listings side by
side (traces, a record's channel sets) and marks the fields whose values differ. Header
text is Latin-1 in the files and made UTF-8 for the toolkit. A joined file's trace keys
are not its headers' bytes: the reader gives each trace's keys and the groups a join gave
(parseSEG's `joinedGroups`), and `traceTable` puts a row per key the join gave (its
stations, coordinates, offset, midpoint) above the header's fields, marked per trace, so
the window draws them in the join's accent colour; the reader is asked again when a join
ends (`joinReport.serial`). The Summary's coordinates are the session's (`Session.crs`,
read with the open, as the join window shows them) and, once joined, the units confirmed
for the join (`AppState.joins`).

**Messages.** The Messages window shows `core/log`; its toggles (auto-scroll, the
severities hidden) are settings. A line whose location names a trace sends `ckShowTrace`
(the file, the trace, and the SEG-D record it counts in, as parseSEG's `Location` has
them): `core` shows the gather holding it, selected, and opens the file first when it is
not open (the request waits in `AppState.jump` for the open). `ckExportLog` hands a copy
of every entry to the disk thread, which writes each as a line of text: making a line
takes a few microseconds (the local time), so a full log made on the UI thread would hold
a frame for a tenth of a second. The session log is written the same way. An import
(settings, a layout) is read and parsed on the disk thread too (`mkRead` carries the NIF
tree), and a reader of these documents words only the first `WordedProblems` problems of
a hostile one.

**The folder's shots** (`core/shots`, `core/shotfiles`). While a survey file with sources
is loaded, the listed seismic files that are steady are read on background jobs, 64 files
a job (`shotsWork`): each through its index cache when that is current (a walk writes none),
for each shot gather's FFID, source station and source coordinates, the file closed on the
job's thread; each file posted as it is done (`mkShots`), and kept beside the index cache
(`<name>-<hash>.shots`), so a file whose size and time are unchanged is not opened again.
The UI thread takes each file in and matches its records to the survey files' sources
(`ShotIndex.matchOne`: by station, by place, by FFID through the relation files), all
again only when the survey changes; a job that has not answered for `StallAfter` is
cancelled (`Jobs.tend` abandons it), the file it was on tried again after `RetryAfter`, the
rest given to the next job; a new listing starts again (its jobs replaced end quietly).
The map rings the matched sources and a click on one shows its file (`ckShowPoints` falls
back to `showListedShot`, with the click's origin).

**The map's filters** (`core/recordqc`, `core/mapkinds`' `MapFilter`, `filterHits`). What
each filter shown marks: those of `TraceFilters` from a background job that reads the
record shown (`recordQcWork`: a chunk of 512 traces at a time, processSEG's
`traceAmplitudeInto`, then `recordAmplitude` over the seismic traces; the headers' dead and
auxiliary traces; the traces parseSEG could not decode; with the relation records of the
domain shown, the loaded file's or those made from the template, kept alive while the job
reads them in place (`AppState.qcHeld`), `recordCompleteness` and the same rules for the
traces), submitted again only when the record, its keys or those relation records change;
killed and reversed traces from the edits, traces without a position from the survey, and
the shots whose spread is not their template from the spreads job (`snCompare`), at once.
Each finding is a `FilterHits` (traces, stations, sources, a count, a note), so the
survey-wide QC passes can fill the same filters. The map marks them in the marked-points
buffer, a set per filter, made again only when what they come from changes.

**The index cache.** `initAppState(indexCache = dir)` names the folder for parseSEG's
index caches; the frontend passes `<cache>/index` from `platform/paths`, since `core`
does not import `platform`. One cache per file, named after the file plus a hash of its
full path (`filejobs.indexCacheFile`). The open job reads a cache when one exists
(parseSEG checks it against the file and walks the file instead when it is stale, saying
why in the log); after a walk it saves the index ("saving the index cache") before
posting the session, because a `SeismicFile` is used by one thread at a time. A file
whose index cannot be cached (a multiplexed SEG-D file's demultiplexed copy, a file that
changed while it was opened) opens all the same. The folder is kept under a budget
(4 GiB by default): after a save, the caches used longest ago are deleted; reading a
cache marks it used.

**ORC across threads.** ORC keeps a per-thread list of objects that may be in a cycle, and
marks each listed object with its place in that list. An object listed by one thread and
released by another corrupts the second thread's list. So a worker empties its list
(`clearCycleRoots`) after making what it hands over and before posting it, the runners do
it after every job, a panel reader does it after closing a prefetcher (before it ends its
hold on the file) and before it ends, and files are closed on the UI thread, never on a
worker. Tiles hold no `ref`, so they may be freed on either side.

**Guards.** `assertUiThread` and `assertWorkerThread` (`core/threads`) begin every proc
that belongs to one side; they are checked in debug builds (`-d:threadGuards` keeps them
in release). The frame watchdog (`core/watchdog`) times each frame's work in debug builds
(`-d:frameWatchdog` in release), leaving out waits such as the buffer swap, and logs every
frame over budget (50 ms) with its parts, longest first.

### The program's own files

Written by the disk thread (`core/diskio`), so the UI thread only hands text over.

- **Session log.** One file per run in the log folder (`platform/paths.logDir`), named
  `viewSEG-<start time>-<process id>.log` (`core/persist`); the newest 20 are kept. Every
  entry of the message log becomes one line (time, severity, source, text, then the file,
  the place in it and the byte offset), the entries logged before the file was opened
  first: `AppState.persist`, once per frame, hands over what was logged since
  (`MessageLog.since`), and `shutdown` the rest. The frontend echoes the log to stdout
  only when it is a terminal. Tests do not write one unless they ask
  (`RunOptions.persist`).
- **Settings.** One typed `Settings` object (`core/settings`), a default for every field:
  the theme, the main window's place and size, the recent files and folders, what a new
  plot window starts with (display mode, fills, overlap, colours, gain type, amount and
  settings, order, display header: whatever the user chose last; polarity is not kept),
  scale units, per-monitor calibrations, the status bar's fields, the sort presets, the
  user's own sort keys and the cursor time line. Changed only by commands: `ckSettings`, and the plot window's
  `ckDisplay`, `ckSort` and `ckHeader`, which the plot defaults follow; `ckExportSettings`,
  `ckImportSettings` (read on the disk thread, taken in as an `mkRead` message) and
  `ckResetSettings`. Kept as NIF in `<config>/settings.nif` (`core/settingsnif`, through
  the small reader and writer `core/nif`), read at start before the window opens
  (`persist.loadSettings`), and saved atomically by the disk thread a second after the
  last change (`SaveDelay`) and at shutdown (`AppState.keepSettingsIn`, `persist`). A file
  that cannot be read is moved aside as `settings.nif.<time>.bak` and the defaults are
  used (one that cannot be moved aside either is left as it is, and that run saves no
  settings); one with settings that cannot be used gives the others, and a copy is kept;
  the log says which, with the line, the first 20 problems one by one and a count of the
  rest. A reset keeps a backup of its own (no two resets share a name, even before the
  first is written). A release that is not portable may carry site defaults in its
  `config/settings.nif`. The exports (`ckExportSettings`, `ckExportLayout`, `ckExportLog`)
  never write over a seismic file the program has open, is opening or closing, or lists.
  In the menus every import is under File > Import (the survey, settings, a layout) and
  every export under File > Export (the messages, the settings, the layout), each there
  only (the Messages window's own Export... button aside).
- **Who changed it: what is saved.** Every `Command` carries where it came from
  (`origin`: `coWindow`, the default, or `coAgent`, which only agent control's `command`
  tool sets). A change from either changes what the program shows and uses; only the
  user's reaches what is saved for the next run, and one function decides it
  (`keeps`). So `AppState` holds the settings twice: those in effect (`settings`, what
  the windows read) and those as the user left them by hand (`keptSettings`, what is
  saved and exported). Every change of the settings goes through one template
  (`change`), which makes it on those in effect, and on those kept when `keeps` says so;
  it is written as what changes (a file put first among the recent ones), so it can be
  made on each. A window's `ckSettings` and `ckDisplay` send whole values built on what
  is in effect, which holds what an agent changed: only what the command changed is
  kept (`settings.carried`: a new plot's display field by field, every other setting
  whole), so a new display mode chosen after an agent's gain keeps the user's gain.
  What a command starts carries its origin to its end: an open's (`Pending.by`) to the
  recent file it adds, a listing's to its recent folder and the file it shows first, a
  file's open to its reopen after another program changed it, an import's to the
  settings read. A Fixed gain's amplitude taken from the data is kept only when the kept
  settings wait for one too. The arrangement an agent reports (`ckLayout`) is not saved.
  `tagentsession` lists every setting the settings file holds and the agent command that
  reaches each for the session, if any: a new setting fails it until it is decided on.
- **Layouts** (`core/layouts`): the toolkit's own layout text (Dear ImGui's `.ini` form,
  which `core` never reads) in a NIF document. The frontend reports the arrangement when
  Dear ImGui says it changed (`ckLayout`; `io.IniFilename` is nil, so ImGui writes no file
  itself) and at exit; `persist` saves it as `<config>/layout.nif` a second after a change,
  and the frontend applies it before the first frame (`loadLayoutFile`; a damaged file is
  moved aside as for the settings). Named layouts: `ckSaveLayout` writes
  `<config>/layouts/<name>.nif`; `ckLoadLayout` and `ckImportLayout` read a file on the disk
  thread, and the frontend arranges its windows when `AppState.layoutLoads` goes up
  (`igClearIniSettings`, `igLoadIniSettingsFromMemory`, between frames); `ckExportLayout`
  writes one anywhere (the frontend first reports the arrangement on screen, as for
  `ckSaveLayout`). Presets ship in `assets/layouts/`; a user's layout of the same name
  hides a preset. The main window's own place is in the settings (`window`), not in a
  layout: at start it is opened there when a screen still holds its top edge, made to fit
  the screen it is on when no screen is as large, and opened in the middle of the primary
  screen at its default size when it is off every screen (`core/screens.mainWindowAtStart`;
  the log says what was corrected, and the place it then has is saved). `--reset-windows`
  (`RunOptions.resetWindows`) reads no layout and opens the main window that last way;
  the settings are read as always. **Which windows are hidden** is in the toolkit's text too, in a section
  of the frontend's own (`[viewSEG][Windows]`, `Hidden=` and the windows' IDs), which Dear
  ImGui writes and reads through a settings handler (`ui/imgui/windows`): a layout without
  it (a preset, an earlier build's), or one that does not name a window, shows it.
- **The Window menu** (`ui/imgui/windows`, the frontend's alone: no command, so agents
  cannot rearrange the user's windows, and what it does is saved as the user's
  arrangement). *Reset the windows* builds the default arrangement again (every window
  shown and docked) and brings the main window onto a screen when it is off every one;
  *Bring all windows onto this screen* moves the main window wholly onto its screen and
  every window outside it (a window of the desktop's own) onto the same screen; each
  window's entry shows, hides or brings it forward. A window a layout does not name (one
  a later build added) is docked as a tab beside its neighbours of the default layout,
  else beside the plot; for a few frames after a layout is applied (the desktop's
  windows for those outside the main window report where they are only then), a window
  it puts off every screen is brought onto the main window's screen, and the log says so
  (Dear ImGui itself keeps only 19 pixels of such a window on a screen, too little to
  drag it by). The rules on rectangles (which screen holds a window, whether its top edge
  can be reached, putting it wholly on a screen) are `core/screens`, tested on made-up
  screens.

### From file to pixels

1. **Open** (interactive job). `openSeismic(path, keys = true, progress,
   OpenOptions(cache: path))`, then `saveIndex` if `not f.fromCache`; the job reads the
   gathers and makes the record list's rows (`core/records`: each gather's FFID, CDP,
   source and receiver from its first seismic trace; its seismic, auxiliary and dead
   traces from the keys; the seismic traces the file declares for it, from a SEG-D
   record's channel set descriptors or a SEG-Y file's traces per ensemble), moves the file
   into a `Session` and posts the session. When a relation file (SPS X) is loaded, each
   open file's records are checked against it on a background job (`checkWork`:
   processSEG's `recordCompleteness` per gather, from the keys; `mkChecked`), again for a
   file opened later or another relation file loaded, and the check goes with the
   relation file. No sample is read for any of it. The progress hook is a
   `gcsafe` closure on the job thread that calls `JobContext.progress`. The job also reads
   what the headers say of the coordinates (`summary.coordinateUnits`, `crsText`:
   `Session.crs`, for the join window, which so reads nothing from the file), and the
   Headers window's facts of the file (`summary`, `channelSets`, `crsText`, the file
   headers: `Session.facts`).
2. **Show** (UI). Pointing a panel at a gather bumps its `requestGen` (and `sourceGen`),
   holds the file (`Jobs.hold`) and hands the panel's reader the file, the gather and
   the trace filter. The reader lets go of what it showed (closes its prefetcher, ends
   its hold) and posts the panel's `PanelLayout` (`mkLayout`: positions, samples, interval)
   with the header fields the traces have values for. `AppState` takes it in only if its
   `sourceGen` is still the panel's, and fits the view to it. The reader then sorts the
   traces in layer 0's order (`Layer.order`: display header fields, each ascending or
   descending; none for the file's order) with parseSEG's `sortOrder` over the keys in
   the index, one key at a time, the last first (`core/sorting`), stopping between runs
   of traces when a newer source or order comes, and posts the traces in the order
   shown (`mkOrder`: each position's trace), which the panel keeps (`Panel.shown`) for
   what needs a position's trace beyond the tiles, a Shift + click's range. A position is then the place of a trace
   in that order, so every request, and each tile's traces, keys and header values,
   follow it; no request is served until the sort is done. **A new order** (`ckSort`)
   keeps the file and the view: `AppState` bumps the panel's `requestGen` (its
   `orderGen`), tells the reader (`sortBy`) and asks for the view again; the tiles in the
   old order stay drawn until the first tile in the new one comes, then are dropped, so
   the plot never goes blank (`sorting` says it is waiting).
3. **Request** (UI). The frontend moves the view itself, with `core/zoom` (zoom about
   the pointer along one axis or both, pan, drag, box zoom, a new plot size, the scroll
   bars, all kept within the data: never past the first and last trace or the record's
   start and end (but for the wiggle modes' margin of the edge traces' lobes, the
   overlap's swing past them: `traceMargin`), and in the wiggle modes never more traces
   across than the plot has pixel columns, `Panel.viewLimits`; a new display mode or
   overlap keeps the view where it is (`relimited`); `core` keeps any view it is sent inside too, and a
   record is first shown as wide as those limits allow, from its first trace:
   `fitted`) and `core/scales` (traces
   and ms per inch or cm, at the monitor's
   pixels per inch), and reports what its plot shows (`ckView`: the range in
   positions and the range in ms, and the plot's pixels along each, whichever way it is
   turned: see "One mapping between data and screen" below). The first view of a gesture comes
   with `remember`, and the panel keeps the view it replaces (at most 50) for `ckBack`;
   when `core` sets the view itself (back, the whole gather once it is laid out) it
   bumps the panel's `jumps` and the frontend follows. When the request sent last does
   not hold the view with a whole view more on each side where the data goes on
   (`covers` with `keep = KeepAhead`), `core/viewport.requestFor` makes a new one (but
   while the view itself is in a request not yet answered, it waits for that one, and
   asks again once a tile is taken in, so a key held down does not start a read every
   few frames and finish none): the visible positions plus a view and a half of
   read-ahead on each side (`ReadAhead`), so a step of a whole view (Shift + arrow, a
   click on a scroll bar's track) finds its data on hand, every `stride`-th
   position when zoomed out past a trace per pixel column (density only; never more
   than the pixel columns), the visible samples plus
   read-ahead, kept at `decimation` samples per column (at most two columns per pixel
   row), and the display pipeline's margin (`requiredMargin`, `decodeWindow`). The
   read-ahead of a large view shrinks on both axes alike to keep the tile within
   `MaxAheadValues` (64 MiB); the view itself is always read. The
   request carries the new `requestGen`. The reader acts only on the newest note.
4. **Prefetch and process** (reader). A selection-mode prefetcher over the request's
   traces (`uniform = true`, `quickFirst = true`) with the decode window as its sample
   window; per chunk, the display pipeline (`polarityOp` when every trace is reversed,
   then the layer's pipeline, then the part of the
   display gain that changes the samples: AGC, by default on pre-stack gathers,
   Exponential, Normalized per trace) runs in place (`chunkMeta(c)`), and each row is
   cut to the kept samples and peak-decimated into the tile; when the request asks for
   it (traces wide enough for wiggles, samples decimated), each column's smallest and
   largest sample are kept too, in the order they occur (`core/wiggle.minMaxInto`), so a
   wiggle keeps its peaks (the request asks for them when the layer draws wiggles).
   Before the pipeline, rows
   marked dead in the file are blanked, passed by as failed rows and marked in the tile
   (`Tile.dead`), so they are never drawn and never counted in a level, under any gain;
   samples that are not numbers are set to 0 (processSEG leaves such a row as it is, and
   it would be drawn at its raw amplitude among processed ones), and the log says so once
   per file shown.
   The file's **edits** come with each request (`core/edits`: the gather's killed and
   reversed traces): a killed row is blanked and passed to the pipeline and the level as
   a failed row, so neither sees it; a reversed row's live samples are negated
   (`reversePolarity`, as `polarityOp` does). The samples as decoded are kept
   (`RawCache`, up to 128 MiB): a request for the same traces whose samples lie among
   them (an edit, a gain change, a slightly shorter view) is served from them, with no
   prefetcher and no read of the file; the tile says so (`Tile.cached`).
   A newer note stops the read between chunks.
5. **Tile** (reader). A `Tile` (plain seqs, moved through the inbox, never shared)
   holds the values (and, for wiggles zoomed out in time, the columns' extremes), the
   display header's values per trace, the edits each row was made with, and its
   `Level`: the RMS, peak and clip percentile of |x| over its live traces that are not
   killed (`panelStats`; a trace marked dead is not live).
6. **Take in** (UI). A tile whose `request.gen` is not the panel's `requestGen` is
   dropped. `AppState` keeps the newest four per panel, and no more than
   `MaxPanelValues` (192 MiB) in all, the oldest dropped first (after a new order, or the
   polarity of every trace reversed, the tiles from before are drawn until the first
   one after the change comes, then dropped: `orderGen`, `samplesGen`; an edit of a
   trace in view is such a change); the first tile after a change of gather or processing
   sets the panel's level, so the brightness holds while the user pans, and so does the
   first after a kill or a restore (`relevel`). The gain type picks the *reference* drawn full black from it (`reference`):
   that level, a Fixed amplitude kept across gathers and files, 1 for traces normalized
   on the CPU, or, for Float, the level of the data in view, taken on the UI thread from
   at most 32 768 of the kept values (killed and dead traces left out) whenever the view or the
   tiles change.
7. **Draw** (UI, `gpu/plotimage`). Each kept tile is uploaded once, as `R32F` textures
   cut to the GPU's size limit (`splitBlocks`), with its columns' extremes when it has
   them and a small texture marking its selected traces, those the map's pointer lights
   up (drawn as the hovered trace), and those it was made with killed or that the file
   marks dead (drawn blank: the background, no wiggle). The tiles are drawn, oldest
   first, into an RGBA image the size of the plot: each tile's area as density (nearest
   trace, linear in time, the scale as a uniform: the gain amount in dB over the
   reference, `displayScale`; a colour-map texture) or as the plot's background, then
   its wiggles, one instanced quad per trace whose fragment shader computes the line's
   and the fills' coverage of each pixel, then its hovered and selected traces again,
   on top. A tile that a newer one covers in view is not drawn at all (`hidden`): it
   would be painted over (four tiles drawn in full cost llvmpipe 52 ms a frame at the
   wiggle limit, one 33 ms). The wiggle shader gets positions and times relative to the
   view's top-left corner (taken in float64), since float32 loses whole traces at
   position 10 000 000. Which of density and wiggles a layer shows depends on its mode
   alone (`drawsDensity`, `drawsWiggles`), never on the trace spacing.
   Everything but the tiles is a uniform, so a change of gain amount, of a type that is
   a scale alone, of the mode, the fills, the overlap or the colours, and a hover, draws
   again at once and reads nothing; a click, or a change of the traces the map's pointer
   lights up, uploads one byte per trace of each tile. An
   image whose inputs did not change is not drawn again; one whose hovered rows alone
   changed draws again only the stripes of the traces the hover left and reached (the
   scissor test; the same draws, so the same pixels), keeping the rest. The frontend shows the image
   in its plot. The CPU twins (`amplitudeAt`, `densityColour`, `traceInk`,
   `densityTint`) are what the shaders are tested against.
8. **Read out** (UI, `core/pick` and `core/readout`). The pointer's screen point goes
   to the data point under it (through the plot's `Turn`), then to the trace drawn there (the newest tile holding
   it), the nearest sample and the value drawn for it, and the trace's keys, which each
   tile carries per row, and the edits the trace was drawn with. Nothing is read from
   the file. The status bar formats the fields the user chose (`Settings.readout`) from
   that `Pick`, blank where a value is not known, and says whether the trace is killed or
   reversed (`editNote`). The trace under the pointer becomes the selection's hover (`ckHover`, a
   survey-wide id: the file's `base` plus the trace's index; `core` finds where it was
   recorded, `hoverAt`, for the map), and a click selects it (`ckSelect`).

| Work | Cancelled or dropped by |
|---|---|
| Open, `ensureKeys`, `bruteStack`, exports | The progress hook returning false: `SegCancelledError` (a cancelled open leaves nothing mapped); a queued job is cancelled before it starts |
| Prefetch | `seek`, which drops the old chunks; a worker drops a stale chunk within 8 traces |
| `pool.apply` | Nothing: a call takes a few ms per panel. The panel thread checks `requestGen` between chunks |
| A panel's tile | A newer note to its reader (between chunks); `AppState` drops a tile whose `request.gen` is not the panel's `requestGen` |

### One mapping between data and screen

A panel's view is in data coordinates, a span of positions and a span of ms, with the
plot's pixels along each (`Viewport.columns` along the positions, `rows` along time),
whichever way the plot is turned. Where those two axes lie on the screen is the plot's
`Turn` (`core/orientation`), chosen by layer 0's `DisplaySettings.orientation`: **time
down** (the positions across from the left, time down) or **time across** (time across
from the left, the positions down from the top, or up from the bottom with
`FirstTraceAtTop` false), and which way a positive amplitude swings along the positions
(`Turn.swing`). Every place where the plot meets the screen goes through it, and nothing
else knows which way the plot is turned:

| Where | Through |
|---|---|
| The plot's size | `sized`: its width and height in pixels to its pixels along each data axis |
| The pointer | `dataAt` (the pick, the zoom's anchor, a box zoom), `screenAt` (the display header's labels, the cursor's line and boxes) |
| Drags and keys | `dataDelta` (a move on the screen as moves along the data axes: a drag, the arrow keys), `axisAlong` (the data axis a screen axis shows: zooms along one axis, a box, the scroll bars) |
| The scroll bars | `thumbOf`, `scrolled`, `paged` with the turn: the thumb measured from the end of the track where the data starts on the screen |
| The image | `screenSize` (the image's width and height), `ndcOf` (density's quads), `ndcMap` (the wiggle shader's vertices), `screenRect` (a hover's stripes), `WiggleStyle.swing` (the wiggle shader and `traceInk` mirror each wiggle about its baseline) |

So the limits, the wiggle mode's zoom-out limit, the scales, a request's stride,
decimation and read-ahead (`requestFor`, `covers`), the tiles and their textures are the
same for either orientation. A turn (`ckDisplay` with another orientation) keeps the
view's spans and swaps its pixels along the two axes, and the frontend reports the real
ones in its next `ckView`; zoomed in, nothing new is read.

### Calls by thread

| Call | Thread | Returns; buffer owner |
|---|---|---|
| `openSeismic`, `saveIndex`, `summary`, `channelSets`, `gathers`, `crsText` | interactive job | A move-only `SeismicFile`, kept in the `Session`; owned copies |
| `close` | UI, once a job holding the file exclusively has ended | Unmaps the file |
| `ensureKeys`, `applySurvey`, `applyGeometry` | job, exclusive | Bump `keysRevision` |
| `parseSps` (a chunk at a time), `addSps` (its relations), `parseP1`; `traceKeysInto` (an open file's positions, while the job reads the file) | interactive job | A `SurveyLayer`, moved to the UI thread (`mkSurvey`) |
| `addSps` (a chunk at a time), `parseP1` and `addP1`, `addCsv`; `traceKeysInto`, then `joinStations` and `applySurvey` on copies of the keys (`planJoin`) | interactive job (a join's first) | A `SurveyGeometry` and a `JoinPlan`, moved to the UI thread (`mkJoining`) |
| `joinStations` (a copy of a hovered trace's keys) | UI | Fills the copy's stations from a loaded relation file |
| `newPrefetcher`, `seek`, `nextInto`, `tryNextInto`, `recycle`, `close` | panel reader (the thread that made it) | `PrefetchChunk.samples` is the caller's until recycled |
| `rowsOf`, `traceKeys`, `maxSamples`, `isSeismic` (the index in memory) | panel reader, while it holds the file | Views and copies of keys; nothing changes the index while the file is held |
| `chunkMeta(c)`, `flow.compile`, `requiredMargin` | panel | A view of `c.rows` (no copy); a plan owned by the panel |
| `pool.apply(plan, raw, processed, meta)` | panel (blocks) | Writes the caller's `processed` |
| `traceStatsInto`, `panelStats`, `moveoutColumnsInto`, `checkGeometryInto` | panel | Fill the caller's seqs; ticks and flags tagged with `keysRevision` |
| `readTracesInto`, `traceKeysInto`, `traceFieldColumnInto` | any | Fill the caller's buffer |
| `summary`, `channelSets`, `crsText`, `fileHeaders`, `textHeader`, `extendedTextHeaders`, `copyBytes` (the Headers window's facts of a file) | interactive job (open) | Owned copies, kept in the `Session` |
| `traceHeaders`, `recordHeaders`, `copyBytes`, `readTraces`, `traceKeys`, `joinedGroups` (the Headers window's record and traces) | Headers reader (`core/inspector`), holding the file | Owned copies, moved to the UI thread (`mkInspected`) |
| `traceField` | UI | Owned copies |
| `traceFieldColumnInto`, then `sortOrder` (a sorted view) | job | A `seq[int]` selection |
| `rowsOf(list)` keys, then `sortOrder` (a panel's order, `core/sorting`) | panel reader, while it holds the file | Positions: a `seq[int]` of trace numbers |
| `pool.pickInto`, `fitShot`, `traceAmplitudeInto`, `recordAmplitude`, `windowSnrInto`, `recordCompleteness`, `addFold`, `preplotFold` | job | The caller's seqs; a `FoldMap` (moved, never copied) |
| `initSpectrumPlan`, `averageAmplitudeInto` | panel or job | The caller's `amp` |
| `bruteStack(f, T, binning, velocity, opts, progress)` | job (blocks) | A `StackResult`, moved to the UI through the inbox |
| `writeHeaderPatch`; `openEditor(move f)`, `release(move ed)` | job (the editor: exclusive) | A patch file; the editor owns the file until `release` |

### Thread-safety rules

- **Shared reads.** `readTraces`, `readTracesInto`, `traceKeysInto` and
  `traceFieldColumnInto` may run on several threads at once on one file, and each thread
  may make, use and close its own prefetchers (parseSEG 0.10 or later). Threads hold a
  `ptr SeismicFile`, so a `Session` is a `ref` with a stable address.
- **One thread at a time:** every other call on a `SeismicFile`, and every `HeaderEditor`,
  `SeismicWriter` and `SurveyGeometry`. The open job makes these calls before it publishes
  the file; after that, only the UI thread does.
- **Exclusive:** `ensureKeys`, `applySurvey`, `applyGeometry`, `openEditor` and `close`.
  The session first cancels its jobs, closes its prefetchers and waits, without blocking
  the UI thread: the call runs in (or, for `close`, after) a job that names the file in
  `JobSpec.exclusive`, which starts only once no job reads the file and no reader holds
  it (`hold` / `release`). Afterwards it
  makes new `rowsOf` views and prefetchers (a prefetcher made before `ensureKeys` never
  gets keys) and marks processed buffers and overlays stale. Raw samples stay valid.
- **Views.** `TraceRows` and `ChunkMeta` hold raw pointers into the index. They may be
  copied to other threads, and stay valid while the file is open and its index is
  unchanged. The list given to `rowsOf(f, list)` must outlive them.
- **Plans** are immutable but hold seqs, so they are passed by pointer, never copied
  across threads. Each thread that calls `plan.apply` has its own `Workspace`.
- **Tensors** are reference counted without atomics: none is shared between threads. Only
  `Tile`s and moved results cross a thread.
- **Buffers.** `tryNextInto` and `recycle(move c)` give a chunk's buffer back for reuse;
  keep no raw pointer into it. Chunks kept in the raw cache are recycled only when evicted.
  A `quickFirst` chunk is a view of a whole chunk buffer: `clone` it before caching it.
- **The pool** runs one job at a time, and a second caller waits. A long job therefore uses
  `plan.apply` with its own `Workspace` instead of holding the pool.

### Core types

What `core` holds (`core/state` and the modules it re-exports). Ids are `distinct int` and
never reused; 0 (`NoSession`, `NoPanel`) names none.

```nim
type
  Selection = object         # core/selection: read by the trace panel, the map, the header table
    hover: int = -1          # survey-wide trace id under the plot's pointer; -1: none
    hoverAt: seq[PointRef]   # where it was recorded: its source and receiver, every layer
    hoverPoints: seq[PointRef] # the points under the map's pointer
    hoverTraces: IntSet      # the open files' traces recorded there: the plot lights them up
    hoveredRevision: int     # bumped when `hoverTraces` changes
    selected: IntSet         # survey-wide trace ids: the file's base + the trace's index
    anchor: int = -1         # the trace clicked last: where a Shift + click's range starts
    pointAnchor: PointRef    # the point clicked last: where a range along its line starts
    activeGather: GatherRef  # (file: SessionId, gather: int = -1)
    revision: int            # bumped on every change
    points: seq[PointRef]    # points selected on the map (with `pointKeys` to find them)
    selectedRevision: int    # bumped when `selected` or `points` changes (a hover does not)

  Session = ref object       # core/session: an open file; workers may hold a ptr SeismicFile
    id: SessionId
    base: int                # survey-wide id of trace 0; bases are never reused
    path: string
    size: int64              # the file's size and time just before it was opened
    modified: Time
    file: SeismicFile        # parseSEG, move-only
    gathers: seq[Gather]
    records: seq[RecordRow]  # core/records: one row per gather for the record list: what
                             # tells it apart; its seismic, auxiliary and dead traces; the
                             # seismic traces the file declares for it; the stations a loaded
                             # relation file plans and those missing (`setChecks`)
    checkedAgainst: string   # the relation file the records were checked against
    crs: FileCrs             # what its headers say of its coordinates: units, CRS text
    facts: FileFacts         # core/headers: what the Headers window's Summary and File
                             # headers show of it, read with it

  FileList = object          # core/filelist: what the Files window lists
    title, folder: string    # the folder listed ("" for files chosen one by one)
    entries: seq[FileEntry]  # path, name, kind (SEG-Y, SEG-D, SEG-2, SPS S / R / X, P1:
                             # core/filekinds), size, modified,
                             # status (steady, writing, incomplete), isNew
    changes: seq[EntryChange] # the newest changes of `entries`, for the file table
    others, unreadable: int  # files not listed
    scanning: bool
    gen: uint64              # bumped by each listing; a scan's messages carry it
    chosen: string           # the file the main panel shows or is opening
    failed: seq[string]      # files that could not be opened

  Panel = object             # core/panels
    id: PanelId
    shows: PanelShows        # traces, spectra or f-k: with layer 0's filter, it names the
                             # window ("Seismic", "Aux", "FFT", "F-K": windowTitle)
    layers: seq[Layer]       # drawn in order; layer 0 is the one gather navigation moves
    header: HeaderChoice     # the display header's rows: automatic, or the user's fields
    requestGen: uint64       # bumped whenever the panel needs new data; tiles carry it
    sourceGen: uint64        # requestGen when layer 0's source last changed; layouts carry it
    layout: PanelLayout      # from the reader: positions, samples, interval, t0
    view: Viewport           # what the plot shows (ckView)
    back: seq[Viewport]      # the views before the last gestures, for ckBack (at most 50)
    jumps: int               # bumped when core sets the view (back, a new gather): the UI follows
    pending: ReadRequest     # the request sent last
    level: Level             # RMS, peak, clip percentile: the first tile's after a change
    viewLevel: Level         # Float: the data in view
    orderGen: uint64         # requestGen when layer 0's order last changed
    samplesGen: uint64       # requestGen when its samples last changed (polarity, edits)
    relevel: bool            # the next tile sets `level` again (a kill or a restore)
    carry: Viewport          # the view of the gather before, until the next is laid out
                             # and shown at the same scales (zoom.carried)
    shown: seq[int]          # per position, the trace's index in its file, in the order
                             # shown (from the reader: mkOrder); a Shift + click's range
    revision: int

  Layer = object             # one is the usual case; more are overlays
    source: LayerSource      # lsRecord (file, gather) or lsGenerated (a processSEG SweepSpec)
    filter: TraceFilter      # seismic / auxiliary, channel sets, channels, components
    order: seq[SortKey]      # display header fields, each ascending or descending; empty:
                             # the file's order (SortPresets: the plot window's buttons)
    pipeline: Pipeline       # processSEG operations; empty shows raw samples
    reversed: bool           # every trace's polarity reversed: polarityOp runs first
    display: DisplaySettings # the orientation (time down or across), density, wiggle or
                             # wiggle over density, the fills (positive,
                             # negative), the trace overlap, "paper", theme or own colours,
                             # gain type (automatic, none, fixed, normalized, exponential,
                             # float, AGC) and its settings, gain amount in dB, clip
                             # percentile, overlap

  CommandKind = enum         # core/state: every user intent, the only way state changes
    ckOpen, ckBrowse, ckShowFile, ckShowTrace, ckClose, ckCancelJob, ckReorderJob,
    ckRemoveJob, ckGather, ckView, ckDisplay, ckHeader, ckSort, ckFilter, ckReverseAll, ckBack,
    ckEdit, ckUndoEdit, ckClearEdits, ckHover, ckSelect,
    ckClearSelection, ckSettings, ckExportSettings, ckImportSettings, ckResetSettings,
    ckLayout, ckSaveLayout, ckLoadLayout, ckExportLayout, ckImportLayout, ckExportLog,
    ckLoadSurvey, ckUnloadSurvey, ckMapView, ckMapBack, ckMapLayer, ckSelectPoints,
    ckHoverPoints, ckShowPoints, ckJoin, ckSelectUnmatched, ckRetry, ckStopReading, ckPrepare,
    ckInspect
  Command = object           # one of them: its kind and fields, and its origin
    origin: CommandOrigin    # coWindow (the default) or coAgent: what is saved (`keeps`)

  JobInfo = object           # core/jobs: what the Jobs window and the status bar show
    id: JobId
    spec: JobSpec            # title, lane (jlInteractive, jlBackground), reads, exclusive,
                             # cancellable
    state: JobState          # jsQueued, jsRunning, jsDone, jsFailed, jsCancelled
    progress: JobProgress    # done, total, phase, since (the phase's start)
    error: string
    cancelRequested: bool
    queuedAt, startedAt, finishedAt: MonoTime

  Msg = object               # core/inbox: from a worker to the UI thread
    job: JobId
    case kind: MsgKind
    of mkOpened: session: Session  # moved, never shared
    of mkLog: entry: LogEntry      # time, severity, source, text, location, offset
    of mkLayout: panel, sourceGen, layout, known   # from a panel's reader
    of mkOrder: orderPanel, orderGen, positions    # the traces in the order shown, from it
    of mkTile: tile: Tile          # moved, never shared
    of mkRead: purpose, readPath, content, readError # a document the disk thread read
    of mkListed: listGen, listed, others, unreadable, listDone, listFolder, listChosen,
      listLooked                   # with listDone: every file looked at, for the watch
    of mkWatched: watchGen, watched, watchProblem, problemChanged # what a look found changed
    of mkSurvey: layer: SurveyLayer # a survey file read, or an open file's positions; moved
    of mkChecked: checkedSession, against, againstLayer, keysRevision, planned,
      plannedMissing, unlisted, duplicates # an open file's records against relation records
    of mkJoining: planSession, geometry, plan, joinSurvey # survey files read for a join, its plan
    of mkJoined: joinedSession, stats, changed, joinedRevision, heldAtJoin # a join done
    of mkInspected: inspected: Inspected # the Headers reader's answer: a SEG-D record's
                                 # headers, the chosen traces' fields and samples; moved
    # to come: mkResult (FoldMap, StackResult, QC rows ...)

  AppState = object          # move-only; owned by the UI thread
    log: MessageLog          # core/log: bounded (10 000 by default), oldest dropped, serials
    selection: Selection
    panels: seq[Panel]       # MainPanel first
    sessions: seq[Session]
    files: FileList          # the file list
    edits: Table[string, FileEdits] # core/edits, per file's path: the traces killed and
                             # reversed, and the last change for the undo
    survey: Survey           # core/survey: the survey files loaded, the open files' positions
    joining: Joining         # the join under way: its jobs, plan, geometry, paused panels
    joins: seq[Joined]       # the open files joined with survey files, and how
    map: MapState            # core/mapstate: the map's view, the views before it, the
                             # layers hidden; follows the survey
    inbox: Inbox             # Poster handles for workers; freed with the last handle
    disk: DiskIo             # core/diskio: the session log, settings and layouts, off this thread
    watch: FolderWatch       # core/watch: the folder listed and the open files, looked at
    indexCache: string       # the folder of parseSEG's index caches; "" for none
    settings: Settings       # in effect: the user's, with what agents changed this session
    kept: Settings           # as the user left them by hand: saved by `persist` (`keeps`)
    tiles: seq[seq[Tile]]    # per panel: the newest four, oldest first
    inspection: Inspection   # core/inspector: what the Headers window has on screen, the
                             # traces its Trace tab is about, its reader's newest answer
    jobs: Jobs               # destroyed after the readers, before the sessions
    readers: seq[PanelReader] # per panel; they stop (and end their holds) before the jobs
    inspector: Inspector     # the Headers reader; declared last: it stops first
    leftInspectors: seq[Inspector] # Headers readers left stuck in a drive, until they end

  Settings = object          # core/settings: changed only by commands; settings.nif
    theme: string            # the theme file; "" follows the system
    window: WindowPlacement  # x, y, width, height (0: never saved), maximized
    recentFiles, recentFolders: seq[string] # newest first
    plot: PlotDefaults       # display, order, display header for a new plot window
    scale: ScaleUnits        # per inch or per cm; time as ms per length or as speed
    calibrations: seq[Calibration] # per monitor (its name and size): pixels per inch
    readout: seq[ReadoutField]     # the status bar's fields, in order
    sortPresets: seq[SortPreset]   # the sort buttons
    customOrder: seq[SortKey]      # the user's own keys, used last
    messages: MessagesView         # the Messages window's toggles: auto-scroll, hidden severities
    cursorLine: bool               # the plot's cursor time line is on
    files: FilesView               # the Files window: followLatest
    map: MapOptions                # the map: where the point under the pointer is described,
                                   # the unit of its lengths (the survey's, or m, ft, ftUS)
    join: JoinOptions              # the geometry join's options, as set last
    headers: HeadersView           # the Headers window: the tab and Trace tab shown, Follow
                                   # the pointer, As displayed, the columns shown

  Pick = object              # core/pick: what lies under the pointer
    inside, found: bool      # over the plot; a tile holds the trace there
    at: DataPoint            # positions and ms
    sample, position, trace: int   # -1 when not known
    keys: TraceKeys          # NaN where not known
    amplitude: float32       # as drawn; NaN when not held
    binned: int              # samples behind it, zoomed out
    edits: set[TraceEdit]    # the trace's edits, as drawn: killed, reversed
    joined: set[JoinGroup]   # the groups of its keys a geometry join gave

  SurveyLayer = object       # core/survey: where one file's sources and receivers are
    id: SurveyLayerId        # never reused
    origin: LayerOrigin      # an open file's traces, or a survey file
    kind: FileKind           # SPS S / R / X, P1, or the seismic file's standard
    path, name: string
    session: SessionId       # traces: the open file, its `base`, its `keysRevision`
    points: array[PointRole, PointSet] # sources, receivers: a SpatialIndex (positions in
                             # its order), elevation and station per point
    counts: array[PointRole, Positions] # given, placed, missing, zero, merged, replaced,
                             # moved, without a station
    relations: SurveyGeometry # survey files: X / O records, as parseSEG's join reads them
    gridUnit: GridUnit       # survey files: what the SPS header says the units are
    bounds: Bounds
    levels: array[PointRole, PointLevels] # core/maplod: the map's levels of detail, the
                             # positions for the GPU, the points' typical spacing

  Tile = object              # core/tiles: one request's samples, moved, never shared
    id: uint64               # given when taken in; the GPU keys its textures on it
    panel: PanelId
    request: ReadRequest     # first, count, stride, firstSample, samples, decimation, gen
    dtMs, t0Ms: float64
    columns: int             # values per trace
    data: seq[float32]       # count × columns, trace by trace
    envelope: seq[float32]   # with request.envelope: each column's extremes, 2 per column
    traces: seq[int]         # per row: the trace's index in its file
    keys: seq[TraceKeys]     # per row: its keys, for the readout
    fields: seq[HeaderField]
    header: seq[seq[float64]] # per field, one value per trace
    edits: seq[set[TraceEdit]] # per row: the edits it was made with; empty for none
    dead: seq[bool]          # per row: marked dead in the file (drawn blank); empty for none
    level: Level             # RMS, peak, clip percentile of |x| over the live traces
                             # that are not killed
    cached: bool             # made from the samples the reader held, not read
    raw: seq[float32]        # with the raw amplitude field on: the file's own samples, cut
                             # and decimated as `data` (before polarity, edits and gain)
    joined: seq[set[JoinGroup]] # per row: what a geometry join gave its keys; empty for none
```

**No undo history.** Edits to traces (kill, reverse polarity) are lists kept beside an
untouched file (`core/edits`, `AppState.edits`, by the file's path and the trace's index
in it, so they outlive the file's session when the user steps away and back), so each is
undone by its inverse: a file keeps only its last change, which `ckUndoEdit` reverts;
`ckClearEdits` empties the lists and is undone the same way. Header edits are a patch,
undone by removing an entry; views have "back". None of them needs a history of
commands.

## Agent control

An agent (any client of the Model Context Protocol, MCP: Claude Code, Claude Desktop, an
editor) can operate the running program while the user watches. It is a third front end
beside the windows and the tests: it posts the same `Command`s the windows post and reads
the same `AppState`, so what an agent does happens on screen, and `core` does not change
for it. How to turn it on and connect a client, and the tools, are in `agent-control.md`.

### Where it sits

`src/viewSEG/remote/` imports `core` (and parseSEG, for a trace's header rows) and nothing
above it; `tests/tlayers.nim` checks that, and that nothing below imports it.

| Module | Holds |
|---|---|
| `remote/protocol` | JSON-RPC 2.0 framing (one message per line), bounded reading and parsing, the MCP handshake, the tool list |
| `remote/schema` | JSON for core's types, the command tool's schema and decoder, made from `Command` |
| `remote/tools` | The five tools, answered from `AppState` on the UI thread |
| `remote/server` | The server thread: the socket, its clients, the queue of calls between the threads |
| `remote/control` | What the frontend owns: start, stop, `serve` once per frame, the sign's state |
| `remote/client` | The other end: `--mcp-stdio` (the bridge an MCP client starts) and `--mcp-call` |

The frontend owns an `AgentControl` beside its `AppState`. It calls `serve` once per frame,
after the frame is rendered and before the buffers swap, with two hooks only a toolkit can
give (`Frontend`): `shoot`, the pixels of a part of that frame, `drawnView`, the view the
plot image was last drawn for, and `showView` and `showMapView`, a view shown in the plot
or the map as the user's pan or zoom would (each window owns its view: a view set in
`core` alone is undone by the window's next report). It also gives `start` a PNG encoder, which runs on the server thread.

### A call, from the socket to the frame

1. **Server thread** (`remote/server`). One thread `poll`s the listening socket, its
   clients and a wake pipe. It reads, cuts the bytes into lines, and parses each with
   the bounds below. It answers `initialize`, `ping`, `tools/list` and notifications
   itself: they need no state. A `tools/call` becomes a `Call` (the client, a serial,
   the request's id as JSON text, the tool, its arguments as JSON text), queued under
   the queue's lock. It never touches `AppState`.
2. **Frame boundary** (`remote/control`, UI thread). `serve` takes what was queued (a
   swap under the lock, as `drainInbox` does) and answers the calls in turn, at most 8
   a frame: `command` is decoded and given to `apply`, as a window's command is; `state`
   and `headers` read the accessors; `screenshot` has the frontend read the pixels
   back (a few milliseconds), and the server thread scales them down and encodes the
   PNG (`pictureAnswer`, with the frontend's `PngEncoder`); `wait` is kept and
   looked at every frame until it holds on two frames in a row (a job that ended
   between a frame's inbox and its answers has what it posted taken in by the next
   frame's) or its time is up. Once a call has applied a
   command, the calls after it wait for the next frame, so they see its effect drawn;
   at most one screenshot is taken a frame. Each answer, JSON text, goes back under the
   lock, and a byte on the wake pipe has the server thread write it out.
3. **Only strings cross.** Each side parses what it reads itself; no `JsonNode` (a `ref`)
   leaves the thread that made it (ORC, "ORC across threads" above).
4. **Nobody waits for the other.** The UI thread only swaps queues (the wake pipe and the
   stop are modelled in `docs/models/agentwake.nif`: no wakeup is lost, even with the pipe
   full and poll's timeout left out). The server thread
   gives each call a deadline (60 s; a wait's own time plus 10 s) and answers an error
   when it passes; an answer that comes later is dropped, by its serial.
5. **What the user sees.** What agents do is written to Messages (source `agent`) by the
   UI thread: every command, with what the program said, and every failure; a call that
   changes nothing (`state`, `headers`, `screenshot`, `wait`), a connection, a
   disconnection or a refused message like one written less than `QuietFor` (10 s) before,
   by the same agent's name, is counted, and the count written when that time has passed,
   so an agent that polls does not bury the user's messages. The status bar shows a sign,
   first in the bar so nothing pushes it out of view, while the server listens, and
   another while a client is connected.

### Transport: a socket, and the program as its own stdio bridge

Messages are JSON-RPC 2.0, one per line, which is the framing of MCP's stdio transport,
over a **Unix-domain socket**.

- **Why a socket.** The user runs the program on the desktop, and agents often run in a
  devcontainer that shares only the repository folder with it. Loopback TCP is not
  shared between the two (each has its own network namespace), and a port is open to
  every program on the machine. A socket is a file: it is reachable wherever its folder
  is (a bind mount included), and file permissions guard it.
- **Where.** The path given (`--mcp=<path>`); else next to the executable when its folder
  is writable (`bin/viewSEG.sock` for a build in the repository, whose `bin/` is inside
  the shared folder, so the program on the host and a client in the container find the
  same socket with no path given); else `$XDG_RUNTIME_DIR/viewSEG/viewSEG.sock`; else
  the cache folder. `--paths` prints it.
- **The bridge.** MCP clients start a server as a subprocess and talk to it on stdio:
  `viewSEG --mcp-stdio[=<path>]`, the same binary, is that subprocess. It answers the
  handshake and the tool list itself, from its own copy; on the first tool call it
  connects (and again after the program restarts), sends the client's own `initialize`
  on, then copies calls and answers. While no program listens, a call is answered with
  an error saying how to start one, so a client started first works once the user
  starts the program.
- **From a shell.** `viewSEG --mcp-call[=<path>] <tool> [<arguments>]` makes one call and
  prints its text; `--png=<file>` writes an image it returns to that file (for scripts and
  for checking a change in the running program).
- **Windows** is not built yet: Nim's `std/net` has no `AF_UNIX` there. What is left:
  Windows 10's `AF_UNIX` through Winsock, or a named pipe, behind the same framing; the
  options say it is not available.

### What keeps it safe

- **Off by default.** No thread and no socket until `--mcp` or File > Agent control turns
  it on, for that run only (it is not a setting); turned off, its clients are disconnected
  and the socket removed.
- **Local only.** The socket's mode is 0600 (its owner only), in a folder made 0700 when
  the program makes it; the client's user id must be the program's (`SO_PEERCRED` on
  Linux, `getpeereid` elsewhere), and the bridge and `--mcp-call` take only a server of
  their own user (one another user listens with could feed an agent what it likes).
  Never a network port. Any program of the user's can connect while it is on: in a
  container sharing the socket's folder, any program running there as the user's id.
- **The path.** A socket left by a run that crashed (nobody listens on it) is replaced;
  one another program listens on is left alone and the start refused; anything that is
  not a socket is never removed. The socket is removed at shutdown.
- **Bounded.** 4 clients; a message of 1 MiB at most (a longer one is answered with an
  error and its client disconnected); JSON nested 64 deep at most, checked before
  it is parsed, and no comments (`std/json` skips them, and one could hide brackets from
  the check); 16 calls in flight per client; 64 MiB of answers
  waiting for a client to read them (one that does not read is disconnected); a
  screenshot of 16 MiB at most. Bad input gets a JSON-RPC error, never an exception out
  of the thread.
- **What an agent may do.** The commands that change what is shown: open, browse, show a
  file or a trace, close, the jobs, gathers, the view, display, display header, sort,
  trace filter, polarity, back, the trace edits, hover and selection, survey files, and
  the map's view, layers, points selected and hovered (what a user does in a window).
  A relative path in a command is read against the program's own folder, which an agent
  elsewhere (a container) can name, unlike the program's absolute paths.
  **Refused:** whatever writes a file (the exports, saving or importing a layout, a
  settings reset, which keeps a backup) and the user's preferences and window
  arrangement (`ckSettings`, `ckImportSettings`, `ckLayout`, `ckLoadLayout`). Trace
  edits are the lists beside the file (`core/edits`): a loaded file is never changed.
  **For the session only:** the `command` tool marks each command it gives as an
  agent's (`origin: coAgent`), and `core` changes nothing saved for it (`keeps`, under
  "Settings" above): what a panel's display, display header and sort become is what new
  plots start with until the program quits, and an open adds to the recent files of the
  session, but neither reaches `settings.nif`; nothing reaches `layout.nif`. Messages and
  the session log still list each command. `core` brings a display's numbers within the
  ranges the controls and the settings file take (`bounded`: a NaN or an infinity, which
  the settings file has no literal for, ended the program) and takes a header field or
  sort key given twice once.
- No AI code, key or network access is in viewSEG itself.

### The command tool's schema

`remote/schema` makes the `command` tool's JSON Schema from `Command` at compile time: one
property per field of the variant (Nim keeps field names unique across its branches),
`kind` an enum of the names of the kinds offered, each property's description naming the
kinds that take it. A field's schema comes from its type through generic procs: integers
(the ids too), numbers, booleans, strings, enums by their names, sets and seqs as arrays,
objects as their fields. The decoder is made the same way, so a new field, or a new
command once it is put in `Offered`, needs no glue, and a field of a type those procs do
not know fails the build. `Offered` names the kinds one by one: a kind added to `Command`
(an export, editing headers in place) is refused to agents until it is offered, or listed
among those refused, on purpose (`tagenttools` fails until then).
An object given in part changes only the fields given: a panel's display, display header,
view and trace filter are first taken from the panel, so `{"kind": "display", "panel": 1,
"display": {"mode": "density"}}` changes the mode alone. An unknown field, a wrong type or
an unknown name is refused, saying where; `apply` checks the rest as it does for the
windows. A number that is not one (NaN) is written as `null`, and `null` read as NaN.
