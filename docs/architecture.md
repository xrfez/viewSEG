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
| `gpu` | OpenGL 3 objects behind small procs: upload a sample tile as an `R32F` texture, the colour-map LUT texture and shader, line buffers | `ui`, any toolkit (OpenGL itself is allowed) |
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
| Panel | `core`, one per trace panel | Owns that panel's `Prefetcher`, raw chunk cache and plans; processes chunks and posts tiles |
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
  a running job can be asked to stop; finished jobs stay listed up to a history limit.
- **Files.** A job does not start while a running job, or a job queued ahead of it in its
  lane, uses one of its files in a conflicting way: reading is shared, exclusive use is
  not. A job that must wait does not hold up the jobs behind it that need not.
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
panel. A close takes the file out of every view at once, cancels the jobs that use it, and
queues a close job that needs the file exclusively; when that job ends, the UI thread
closes the file.

**ORC across threads.** ORC keeps a per-thread list of objects that may be in a cycle, and
marks each listed object with its place in that list. An object listed by one thread and
released by another corrupts the second thread's list. So a worker empties its list
(`clearCycleRoots`) after making what it hands over and before posting it, the runners do
it after every job, and files are closed on the UI thread, never on a worker.

**Guards.** `assertUiThread` and `assertWorkerThread` (`core/threads`) begin every proc
that belongs to one side; they are checked in debug builds (`-d:threadGuards` keeps them
in release). The frame watchdog (`core/watchdog`) times each frame's work in debug builds
(`-d:frameWatchdog` in release), leaving out waits such as the buffer swap, and logs every
frame over budget (50 ms) with its parts, longest first.

### From file to pixels

1. **Open** (interactive job). `openSeismic(path, keys = true, progress)`; the job reads
   the gathers, moves the file into a `Session` and posts the session. The progress hook is
   a `gcsafe` closure on the job thread that calls `JobContext.progress`. Not yet: the index
   cache (`OpenOptions(cache: path)`, then `saveIndex` if `not f.fromCache`) and reading
   `summary`, `channelSets` and `crsText` on the job.
2. **Request** (UI). A scroll or zoom is a `Command`. `core` bumps the panel's `requestGen`
   and sends the panel thread the trace range or selection, the sample window, the
   `Pipeline` and the gain. The panel thread acts only on the newest request.
3. **Prefetch** (panel). One range-mode prefetcher per panel (`uniform = true`,
   `quickFirst = true`) follows every scroll through `seek`. The sample window
   (`firstSample`, `cols`) and a selection (a gather, a sort order) are fixed when a
   prefetcher is made, so changing either means making a new one. A zoom decodes
   `decodeWindow(shown, flow.requiredMargin(dtMs), traceLen)`. The raw cache keeps the
   chunks, so a slider change reprocesses them without decoding again.
4. **Process** (panel, optional). The panel thread compiles one plan per sample interval,
   row width and record length (`flow.compile(float32, dtMs, cols, recordSamples)`) and
   runs `pool.apply(plan, raw, processed, chunkMeta(c))`. Each processed buffer is tagged
   with `plan.generation` and `f.keysRevision`, and is redone when either changes.
5. **Tile** (panel). The visible block is copied into a `Tile` (float32, on the shared heap,
   moved and never shared), with its gain statistics (`traceStatsInto`, `panelStats`).
6. **Upload** (UI). A tile whose `gen` is not the panel's `requestGen` is dropped. Any
   other tile goes into the panel's `R32F` texture (`gpu`, `glTexSubImage2D`). Fixed or
   normalized gain is a shader uniform. The tile then goes back to the panel's free list.

| Work | Cancelled or dropped by |
|---|---|
| Open, `ensureKeys`, `bruteStack`, exports | The progress hook returning false: `SegCancelledError` (a cancelled open leaves nothing mapped); a queued job is cancelled before it starts |
| Prefetch | `seek`, which drops the old chunks; a worker drops a stale chunk within 8 traces |
| `pool.apply` | Nothing: a call takes a few ms per panel. The panel thread checks `requestGen` between chunks |

### Calls by thread

| Call | Thread | Returns; buffer owner |
|---|---|---|
| `openSeismic`, `saveIndex`, `summary`, `channelSets`, `gathers`, `crsText` | interactive job | A move-only `SeismicFile`, kept in the `Session`; owned copies |
| `close` | UI, once a job holding the file exclusively has ended | Unmaps the file |
| `ensureKeys`, `applySurvey`, `applyGeometry` | job, exclusive | Bump `keysRevision` |
| `readSps`, `addSps`, `readP1` | job | `SurveyGeometry`, moved to the session |
| `newPrefetcher`, `seek`, `tryNextInto`, `recycle`, `close` | panel (the thread that made it) | `PrefetchChunk.samples` is the caller's until recycled |
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
  `JobSpec.exclusive`, which starts only once no job reads the file. Afterwards it
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
    requestGen: uint64       # bumped whenever the panel needs new data; tiles carry it
    revision: int

  Layer = object             # one is the usual case; more are overlays
    source: LayerSource      # lsRecord (file, gather) or lsGenerated (a processSEG SweepSpec)
    filter: TraceFilter      # seismic / auxiliary, channel sets, channels, components
    pipeline: Pipeline       # processSEG operations; empty shows raw samples
    display: DisplaySettings # density or wiggle (positive / negative fill), "paper" colours,
                             # clip percentile, overlap, reversed polarity

  CommandKind = enum         # core/state: every user intent, the only way state changes
    ckOpen, ckClose, ckCancelJob, ckReorderJob, ckRemoveJob, ckGather, ckHover, ckSelect,
    ckClearSelection

  JobInfo = object           # core/jobs: what the Jobs window and the status bar show
    id: JobId
    spec: JobSpec            # title, lane (jlInteractive, jlBackground), reads, exclusive
    state: JobState          # jsQueued, jsRunning, jsDone, jsFailed, jsCancelled
    progress: JobProgress    # done, total, phase
    error: string
    cancelRequested: bool
    queuedAt, startedAt, finishedAt: MonoTime

  Msg = object               # core/inbox: from a worker to the UI thread
    job: JobId
    case kind: MsgKind
    of mkOpened: session: Session  # moved, never shared
    of mkLog: entry: LogEntry      # time, severity, source, text, location, offset
    # to come: mkTile (a panel's Tile), mkResult (FoldMap, StackResult, QC rows ...)

  AppState = object          # move-only; owned by the UI thread
    log: MessageLog          # core/log: bounded (10 000 by default), oldest dropped, serials
    selection: Selection
    panels: seq[Panel]       # MainPanel first
    sessions: seq[Session]
    inbox: Inbox             # Poster handles for workers; freed with the last handle
    jobs: Jobs               # declared last: destroyed first, so the runners stop first

  Tile = object              # not built yet: [traces, samples] float32, moved, never shared
    panel: PanelId
    gen: uint64              # the requestGen it answers
    data: ptr UncheckedArray[float32]
    firstTrace, traces, firstSample, samples: int
```

**No undo history.** Edits to traces (kill, reverse polarity) are lists kept beside an
untouched file, so each is undone by its inverse; header edits are a patch, undone by
removing an entry; views have "back". None of them needs a history of commands.
