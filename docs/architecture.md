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
        │                     colour-map shaders, wiggle vertex buffers
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
| `core` | `AppState` (open files, panels and their layers, the selection, the message log), `Command`s (each user intent as data), jobs in two lanes (prefetch through parseSEG's `Prefetcher`, processing through processSEG plans and its pool; results posted to a main-thread inbox), thread guards and the frame watchdog, kernels (colour maps, decimation, picking, cursor readout), map maths (tiles, projections, hit-testing) | `ui`, `gpu`, `platform`, any toolkit, SDL, OpenGL |
| `view` | View models such as `PanelView`, `TableModel`, `TreeModel`, `PlotSeries` and `MapLayer`. Each has plain-Nim geometry (`Vec2`, `Rect`, `Rgba`) and a `revision` counter that bumps on change | `ui`, `gpu`, `platform`, any toolkit |
| `gpu` | OpenGL 3 objects behind small procs: upload a sample tile as `R32F` textures, the colour-map LUT texture and shader, line buffers. It loads the GL functions it needs itself (`gpu/gl`), through a loader the frontend passes in (`SDL_GL_GetProcAddress`), so it imports no GL binding package | `ui`, any toolkit (OpenGL itself is allowed) |
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
| Interactive jobs | `core/jobs`: a runner started by `initAppState`, with its own queue | Short work the user is waiting on: open and index, `ensureKeys`, survey joins, sorts |
| Background jobs | `core/jobs`: a second runner and queue | Long work: whole-file columns, QC passes, folder scans, brute stack, conversions, exports and patches, queued workflows |
| Panel reader | `core/reader`, one per trace panel, started when the panel first shows a file | Owns that panel's `Prefetcher`; applies the trace filter, runs the display pipeline on each chunk (its own `Workspace`), cuts the tile and posts it |
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

### From file to pixels

1. **Open** (interactive job). `openSeismic(path, keys = true, progress,
   OpenOptions(cache: path))`, then `saveIndex` if `not f.fromCache`; the job reads the
   gathers, moves the file into a `Session` and posts the session. The progress hook is a
   `gcsafe` closure on the job thread that calls `JobContext.progress`. Not yet: reading
   `summary`, `channelSets` and `crsText` on the job.
2. **Show** (UI). Pointing a panel at a gather bumps its `requestGen` (and `sourceGen`),
   holds the file (`Jobs.hold`) and hands the panel's reader the file, the gather and
   the trace filter. The reader lets go of what it showed (closes its prefetcher, ends
   its hold) and posts the panel's `PanelLayout` (`mkLayout`: positions, samples, interval)
   with the header fields the traces have values for. `AppState` takes it in only if its
   `sourceGen` is still the panel's, and fits the view to it.
3. **Request** (UI). The frontend moves the view itself, with `core/zoom` (zoom about
   the pointer along one axis or both, pan, drag, box zoom, a new plot size, the scroll
   bars, all kept within the data: never past the first and last trace or the record's
   start and end; `core` keeps any view it is sent inside too) and `core/scales` (traces
   and ms per inch or cm, at the monitor's
   pixels per inch), and reports what its plot shows (`ckView`: the x range in
   positions, the y range in ms, the size in pixels). The first view of a gesture comes
   with `remember`, and the panel keeps the view it replaces (at most 50) for `ckBack`;
   when `core` sets the view itself (back, the whole gather once it is laid out) it
   bumps the panel's `jumps` and the frontend follows. When the request
   sent last does not cover it (`covers`), `core/viewport.requestFor` makes a new one:
   the visible positions plus half a view of read-ahead on each side, every `stride`-th
   position when zoomed out (never more than the pixel columns), the visible samples plus
   read-ahead, kept at `decimation` samples per column (at most two columns per pixel
   row), and the display pipeline's margin (`requiredMargin`, `decodeWindow`). The
   request carries the new `requestGen`. The reader acts only on the newest note.
4. **Prefetch and process** (reader). A selection-mode prefetcher over the request's
   traces (`uniform = true`, `quickFirst = true`) with the decode window as its sample
   window; per chunk, the display pipeline (the layer's pipeline, then the display gain:
   AGC by default on pre-stack gathers) runs in place (`chunkMeta(c)`), and each row is
   cut to the kept samples and peak-decimated into the tile. A newer note stops the
   read between chunks.
5. **Tile** (reader). A `Tile` (plain seqs, moved through the inbox, never shared)
   holds the values, the display header's values per trace and the clip percentile of
   |x| (`panelStats`).
6. **Take in** (UI). A tile whose `request.gen` is not the panel's `requestGen` is
   dropped. `AppState` keeps the newest four per panel; the first tile after a change of
   gather or gain sets the panel's clip, so the brightness holds while the user pans.
7. **Draw** (UI, `gpu/density`). Each kept tile is uploaded once, as `R32F` textures
   cut to the GPU's size limit (`splitBlocks`). Each frame the tiles are drawn, oldest
   first, into an RGBA image the size of the plot, with one shader (nearest trace,
   linear in time, the gain and clip as a uniform, a colour-map texture); the frontend
   shows the image in its plot. The CPU twins (`amplitudeAt`, `densityColour`) are what
   the shader is tested against.
8. **Read out** (UI, `core/pick` and `core/readout`). The pointer's screen point goes
   to the data point under it, then to the trace drawn there (the newest tile holding
   it), the nearest sample and the value drawn for it, and the trace's keys, which each
   tile carries per row. Nothing is read from the file. The status bar formats the
   fields the user chose (`Settings.readout`) from that `Pick`, blank where a value is
   not known.

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
| `readSps`, `addSps`, `readP1` | job | `SurveyGeometry`, moved to the session |
| `newPrefetcher`, `seek`, `nextInto`, `tryNextInto`, `recycle`, `close` | panel reader (the thread that made it) | `PrefetchChunk.samples` is the caller's until recycled |
| `rowsOf`, `traceKeys`, `maxSamples`, `isSeismic` (the index in memory) | panel reader, while it holds the file | Views and copies of keys; nothing changes the index while the file is held |
| `chunkMeta(c)`, `flow.compile`, `requiredMargin` | panel | A view of `c.rows` (no copy); a plan owned by the panel |
| `pool.apply(plan, raw, processed, meta)` | panel (blocks) | Writes the caller's `processed` |
| `traceStatsInto`, `panelStats`, `moveoutColumnsInto`, `checkGeometryInto` | panel | Fill the caller's seqs; ticks and flags tagged with `keysRevision` |
| `readTracesInto`, `traceKeysInto`, `traceFieldColumnInto` | any | Fill the caller's buffer |
| `traceHeaders`, `recordHeaders`, `fileHeaders`, `copyBytes`, `textHeader`, `traceField` | UI | Owned copies |
| `traceFieldColumnInto`, then `sortOrder` (a sorted view) | job | A `seq[int]` selection |
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
    activeGather: GatherRef  # (file: SessionId, gather: int = -1)
    revision: int            # bumped on every change

  Session = ref object       # core/session: an open file; workers may hold a ptr SeismicFile
    id: SessionId
    base: int                # survey-wide id of trace 0; bases are never reused
    path: string
    file: SeismicFile        # parseSEG, move-only
    gathers: seq[Gather]

  Panel = object             # core/panels
    id: PanelId
    layers: seq[Layer]       # drawn in order; layer 0 is the one gather navigation moves
    header: HeaderChoice     # the display header's rows: automatic, or the user's fields
    requestGen: uint64       # bumped whenever the panel needs new data; tiles carry it
    sourceGen: uint64        # requestGen when layer 0's source last changed; layouts carry it
    layout: PanelLayout      # from the reader: positions, samples, interval, t0
    view: Viewport           # what the plot shows (ckView)
    back: seq[Viewport]      # the views before the last gestures, for ckBack (at most 50)
    jumps: int               # bumped when core sets the view (back, a new gather): the UI follows
    pending: ReadRequest     # the request sent last
    clip: float64            # the display clip, from the first tile after a change
    revision: int

  Layer = object             # one is the usual case; more are overlays
    source: LayerSource      # lsRecord (file, gather) or lsGenerated (a processSEG SweepSpec)
    filter: TraceFilter      # seismic / auxiliary, channel sets, channels, components
    pipeline: Pipeline       # processSEG operations; empty shows raw samples
    display: DisplaySettings # density or wiggle (positive / negative fill), "paper" colours,
                             # display gain (auto, none, trace balance, AGC), clip
                             # percentile, overlap, reversed polarity

  CommandKind = enum         # core/state: every user intent, the only way state changes
    ckOpen, ckClose, ckCancelJob, ckReorderJob, ckRemoveJob, ckGather, ckView, ckDisplay,
    ckHeader, ckBack, ckHover, ckSelect, ckClearSelection, ckSettings

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
    of mkTile: tile: Tile          # moved, never shared
    # to come: mkResult (FoldMap, StackResult, QC rows ...)

  AppState = object          # move-only; owned by the UI thread
    log: MessageLog          # core/log: bounded (10 000 by default), oldest dropped, serials
    selection: Selection
    panels: seq[Panel]       # MainPanel first
    sessions: seq[Session]
    inbox: Inbox             # Poster handles for workers; freed with the last handle
    indexCache: string       # the folder of parseSEG's index caches; "" for none
    settings: Settings       # scale units, monitor calibrations, the readout's fields
    tiles: seq[seq[Tile]]    # per panel: the newest four, oldest first
    jobs: Jobs               # destroyed after the readers, before the sessions
    readers: seq[PanelReader] # per panel; declared last: they stop (and end their holds) first

  Settings = object          # core/settings: changed only by ckSettings
    scale: ScaleUnits        # per inch or per cm; time as ms per length or as speed
    calibrations: seq[Calibration] # per monitor (its name and size): pixels per inch
    readout: seq[ReadoutField]     # the status bar's fields, in order

  Pick = object              # core/pick: what lies under the pointer
    inside, found: bool      # over the plot; a tile holds the trace there
    at: DataPoint            # positions and ms
    sample, position, trace: int   # -1 when not known
    keys: TraceKeys          # NaN where not known
    amplitude: float32       # as drawn; NaN when not held
    binned: int              # samples behind it, zoomed out

  Tile = object              # core/tiles: one request's samples, moved, never shared
    id: uint64               # given when taken in; the GPU keys its textures on it
    panel: PanelId
    request: ReadRequest     # first, count, stride, firstSample, samples, decimation, gen
    dtMs, t0Ms: float64
    columns: int             # values per trace
    data: seq[float32]       # count × columns, trace by trace
    traces: seq[int]         # per row: the trace's index in its file
    keys: seq[TraceKeys]     # per row: its keys, for the readout
    fields: seq[HeaderField]
    header: seq[seq[float64]] # per field, one value per trace
    clip: float64            # the clip percentile of |x| over the live traces
```

**No undo history.** Edits to traces (kill, reverse polarity) are lists kept beside an
untouched file, so each is undone by its inverse; header edits are a patch, undone by
removing an entry; views have "back". None of them needs a history of commands.
