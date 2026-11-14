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
        ▼
src/viewSEG/gpu/              GPU resources for OpenGL frontends: float32 textures,
        │                     the density and wiggle shaders, the plot's image
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
| `view` | View models such as `PanelView`, `TableModel`, `TreeModel`, `PlotSeries` and `MapLayer`. Each has plain-Nim geometry (`Vec2`, `Rect`, `Rgba`) and a `revision` counter that bumps on change | `ui`, `gpu`, `platform`, any toolkit |
| `gpu` | OpenGL 3 objects behind small procs: upload a sample tile as `R32F` textures (`textures`), the density shader and its colour-map LUT (`density`), the wiggle shader (`wiggle`), and the plot's image that draws a panel's tiles with them (`plotimage`). It loads the GL functions it needs itself (`gpu/gl`), through a loader the frontend passes in (`SDL_GL_GetProcAddress`), so it imports no GL binding package | `ui`, any toolkit (OpenGL itself is allowed) |
| `platform` | `winres` (compile-time manifest, icon, version info), window chrome (DWM attributes on a native window handle), config paths, and whatever else needs raw OS APIs. Services the windowing library already has (SDL3: file dialogs, system theme, tray) are wrapped in `ui/<toolkit>/shell` instead, because only `ui` may import SDL | `ui`, `core`, any toolkit |
| `ui/imgui` | The frame loop, docking layout and viewports, widgets that draw view models, input → `Command`, and `shell` (SDL3's file dialog, system theme and tray; results come back as inbox messages) | (top layer) |

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
| UI (main) | `src/viewSEG.nim`; `initAppState` marks it | The frame loop: drains the inbox once per frame (`drainInbox`), applies `Command`s to `AppState` (`apply`), reads one trace's headers, hex bytes or textual header, closes files, and makes every OpenGL call |
| Interactive jobs | `core/jobs`: a runner started by `initAppState`, with its own queue | Short work the user is waiting on: open and index, an open file's positions, survey files read, `ensureKeys`, survey joins, sorts across files |
| Background jobs | `core/jobs`: a second runner and queue | Long work: whole-file columns, QC passes, folder scans, brute stack, conversions, exports and patches, queued workflows |
| Disk | `core/diskio`, started by `AppState.logTo` | Writes the program's own files: appends the session log (making its lines from the log's entries), replaces settings and layouts atomically (a temporary file, flushed, then renamed), prunes old logs; reads the documents the user imports and makes their NIF tree; failures come back as log messages |
| Folder watch | `core/watch`, started by `AppState` when a listing or an open file needs it | Looks at the folder listed and at the open files about once a second (names, then `stat`; the first 4 KiB of a file not known to be seismic when it appears or changes), and posts what changed (`mkWatched`); never opens what is not a regular file |
| Panel reader | `core/reader`, one per trace panel, started when the panel first shows a file | Owns that panel's `Prefetcher` and the samples it last read; applies the trace filter, sorts the traces in the layer's order (`core/sorting`), applies the file's edits and runs the display pipeline on each chunk (its own `Workspace`), cuts the tile and posts it |
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
  running ones to stop and joins both runners. Work must notice its cancel.
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
the file, and every hold on it), the UI thread closes the file. The close job cannot be
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
holds it up and the Jobs window is not filled with looks; its `stop` waits two seconds at
most, so a share that hangs a look cannot hold the quit. `AppState.takeWatched` updates
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
of a cell side by side): `nearest(x, y, radius)` looks at rings of cells around the place
until no nearer point can be in the next ring, `within(box)` at the cells the box
covers, and `bounds` gives what fit needs. A traces layer also keeps each trace's point
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
- **Layouts** (`core/layouts`): the toolkit's own layout text (Dear ImGui's `.ini` form,
  which `core` never reads) in a NIF document. The frontend reports the arrangement when
  Dear ImGui says it changed (`ckLayout`; `io.IniFilename` is nil, so ImGui writes no file
  itself) and at exit; `persist` saves it as `<config>/layout.nif` a second after a change,
  and the frontend applies it before the first frame (`loadLayoutFile`; a damaged file is
  moved aside as for the settings). Named layouts: `ckSaveLayout` writes
  `<config>/layouts/<name>.nif`; `ckLoadLayout` and `ckImportLayout` read a file on the disk
  thread, and the frontend arranges its windows when `AppState.layoutLoads` goes up
  (`igClearIniSettings`, `igLoadIniSettingsFromMemory`, between frames); `ckExportLayout`
  writes one anywhere. Presets ship in `assets/layouts/`; a user's layout of the same name
  hides a preset.

### From file to pixels

1. **Open** (interactive job). `openSeismic(path, keys = true, progress,
   OpenOptions(cache: path))`, then `saveIndex` if `not f.fromCache`; the job reads the
   gathers and makes the record list's rows (`core/records`: each gather's FFID, CDP,
   source and receiver from its first seismic trace), moves the file into a `Session` and
   posts the session. The progress hook is a
   `gcsafe` closure on the job thread that calls `JobContext.progress`. Not yet: reading
   `summary`, `channelSets` and `crsText` on the job.
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
   pixels per inch), and reports what its plot shows (`ckView`: the x range in
   positions, the y range in ms, the size in pixels). The first view of a gesture comes
   with `remember`, and the panel keeps the view it replaces (at most 50) for `ckBack`;
   when `core` sets the view itself (back, the whole gather once it is laid out) it
   bumps the panel's `jumps` and the frontend follows. When the request
   sent last does not cover it (`covers`), `core/viewport.requestFor` makes a new one:
   the visible positions plus half a view of read-ahead on each side, every `stride`-th
   position when zoomed out past a trace per pixel column (density only; never more
   than the pixel columns), the visible samples plus
   read-ahead, kept at `decimation` samples per column (at most two columns per pixel
   row), and the display pipeline's margin (`requiredMargin`, `decodeWindow`). The
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
   dropped. `AppState` keeps the newest four per panel (after a new order, or the
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
   them and a small texture marking its selected traces and those it was made with
   killed or that the file marks dead (drawn blank: the background, no wiggle). The tiles are drawn, oldest
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
   again at once and reads nothing; a click uploads one byte per trace of each tile. An
   image whose inputs did not change is not drawn again. The frontend shows the image
   in its plot. The CPU twins (`amplitudeAt`, `densityColour`, `traceInk`,
   `densityTint`) are what the shaders are tested against.
8. **Read out** (UI, `core/pick` and `core/readout`). The pointer's screen point goes
   to the data point under it, then to the trace drawn there (the newest tile holding
   it), the nearest sample and the value drawn for it, and the trace's keys, which each
   tile carries per row, and the edits the trace was drawn with. Nothing is read from
   the file. The status bar formats the fields the user chose (`Settings.readout`) from
   that `Pick`, blank where a value is not known, and says whether the trace is killed or
   reversed (`editNote`). The trace under the pointer becomes the selection's hover (`ckHover`, a
   survey-wide id: the file's `base` plus the trace's index), and a click selects it
   (`ckSelect`).

| Work | Cancelled or dropped by |
|---|---|
| Open, `ensureKeys`, `bruteStack`, exports | The progress hook returning false: `SegCancelledError` (a cancelled open leaves nothing mapped); a queued job is cancelled before it starts |
| Prefetch | `seek`, which drops the old chunks; a worker drops a stale chunk within 8 traces |
| `pool.apply` | Nothing: a call takes a few ms per panel. The panel thread checks `requestGen` between chunks |
| A panel's tile | A newer note to its reader (between chunks); `AppState` drops a tile whose `request.gen` is not the panel's `requestGen` |

### Calls by thread

| Call | Thread | Returns; buffer owner |
|---|---|---|
| `openSeismic`, `saveIndex`, `summary`, `channelSets`, `gathers`, `crsText` | interactive job | A move-only `SeismicFile`, kept in the `Session`; owned copies |
| `close` | UI, once a job holding the file exclusively has ended | Unmaps the file |
| `ensureKeys`, `applySurvey`, `applyGeometry` | job, exclusive | Bump `keysRevision` |
| `parseSps` (a chunk at a time), `addSps` (its relations), `parseP1`; `traceKeysInto` (an open file's positions, while the job reads the file) | interactive job | A `SurveyLayer`, moved to the UI thread (`mkSurvey`) |
| `joinStations` (a copy of a hovered trace's keys) | UI | Fills the copy's stations from a loaded relation file |
| `newPrefetcher`, `seek`, `nextInto`, `tryNextInto`, `recycle`, `close` | panel reader (the thread that made it) | `PrefetchChunk.samples` is the caller's until recycled |
| `rowsOf`, `traceKeys`, `maxSamples`, `isSeismic` (the index in memory) | panel reader, while it holds the file | Views and copies of keys; nothing changes the index while the file is held |
| `chunkMeta(c)`, `flow.compile`, `requiredMargin` | panel | A view of `c.rows` (no copy); a plan owned by the panel |
| `pool.apply(plan, raw, processed, meta)` | panel (blocks) | Writes the caller's `processed` |
| `traceStatsInto`, `panelStats`, `moveoutColumnsInto`, `checkGeometryInto` | panel | Fill the caller's seqs; ticks and flags tagged with `keysRevision` |
| `readTracesInto`, `traceKeysInto`, `traceFieldColumnInto` | any | Fill the caller's buffer |
| `traceHeaders`, `recordHeaders`, `fileHeaders`, `copyBytes`, `textHeader`, `traceField` | UI | Owned copies |
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
    hover: int = -1          # survey-wide trace id under the cursor; -1: none
    selected: IntSet         # survey-wide trace ids: the file's base + the trace's index
    anchor: int = -1         # the trace clicked last: where a Shift + click's range starts
    activeGather: GatherRef  # (file: SessionId, gather: int = -1)
    revision: int            # bumped on every change
    selectedRevision: int    # bumped when `selected` changes (a hover does not)

  Session = ref object       # core/session: an open file; workers may hold a ptr SeismicFile
    id: SessionId
    base: int                # survey-wide id of trace 0; bases are never reused
    path: string
    size: int64              # the file's size and time just before it was opened
    modified: Time
    file: SeismicFile        # parseSEG, move-only
    gathers: seq[Gather]
    records: seq[RecordRow]  # core/records: one row per gather for the record list

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
    display: DisplaySettings # density, wiggle or wiggle over density, the fills (positive,
                             # negative), the trace overlap, "paper", theme or own colours,
                             # gain type (automatic, none, fixed, normalized, exponential,
                             # float, AGC) and its settings, gain amount in dB, clip
                             # percentile, overlap

  CommandKind = enum         # core/state: every user intent, the only way state changes
    ckOpen, ckBrowse, ckShowFile, ckShowTrace, ckClose, ckCancelJob, ckReorderJob,
    ckRemoveJob, ckGather, ckView, ckDisplay, ckHeader, ckSort, ckReverseAll, ckBack,
    ckEdit, ckUndoEdit, ckClearEdits, ckHover, ckSelect,
    ckClearSelection, ckSettings, ckExportSettings, ckImportSettings, ckResetSettings,
    ckLayout, ckSaveLayout, ckLoadLayout, ckExportLayout, ckImportLayout, ckExportLog,
    ckLoadSurvey, ckUnloadSurvey

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
    inbox: Inbox             # Poster handles for workers; freed with the last handle
    disk: DiskIo             # core/diskio: the session log, settings and layouts, off this thread
    watch: FolderWatch       # core/watch: the folder listed and the open files, looked at
    indexCache: string       # the folder of parseSEG's index caches; "" for none
    settings: Settings       # what is remembered between runs; saved by `persist`
    tiles: seq[seq[Tile]]    # per panel: the newest four, oldest first
    jobs: Jobs               # destroyed after the readers, before the sessions
    readers: seq[PanelReader] # per panel; declared last: they stop (and end their holds) first

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

  Pick = object              # core/pick: what lies under the pointer
    inside, found: bool      # over the plot; a tile holds the trace there
    at: DataPoint            # positions and ms
    sample, position, trace: int   # -1 when not known
    keys: TraceKeys          # NaN where not known
    amplitude: float32       # as drawn; NaN when not held
    binned: int              # samples behind it, zoomed out
    edits: set[TraceEdit]    # the trace's edits, as drawn: killed, reversed

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
```

**No undo history.** Edits to traces (kill, reverse polarity) are lists kept beside an
untouched file (`core/edits`, `AppState.edits`, by the file's path and the trace's index
in it, so they outlive the file's session when the user steps away and back), so each is
undone by its inverse: a file keeps only its last change, which `ckUndoEdit` reverts;
`ckClearEdits` empties the lists and is undone the same way. Header edits are a patch,
undone by removing an entry; views have "back". None of them needs a history of
commands.
