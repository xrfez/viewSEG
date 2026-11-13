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
| `core` | `AppState` (open files, selection, view settings), `Command`s (each user intent as data, with undo), `Job`s (prefetch through parseSEG's `Prefetcher`, processing through processSEG plans and its pool; results posted to a main-thread inbox), kernels (colour maps, decimation, picking, cursor readout), map maths (tiles, projections, hit-testing) | `ui`, `gpu`, `platform`, any toolkit, SDL, OpenGL |
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
| UI (main) | `src/viewSEG.nim` | The frame loop: drains the inbox once per frame, applies `Command`s to `AppState`, reads one trace's headers, hex bytes or textual header, and makes every OpenGL call |
| Job | `core`: one runner, started at start-up, with a queue of `Job`s | Everything that blocks: open and index, `ensureKeys`, survey joins, whole-file columns and sorts, QC passes, brute stack, exports and patches |
| Panel | `core`, one per trace panel | Owns that panel's `Prefetcher`, raw chunk cache and plans; processes chunks and posts tiles |
| Prefetch workers | parseSEG: `newPrefetcher(workers = n)`, called on the panel thread | Decoding only; joined by the prefetcher's `close` |
| Pool workers | processSEG: one `ProcessPool`, made by `core` at start-up | The rows of `pool.apply`, `pool.pickInto` and `pool.traceAmplitudeInto`; destroyed at shutdown, once every caller has stopped |

### From file to pixels

1. **Open** (job). `openSeismic(path, keys = true, progress, OpenOptions(cache: path))`,
   then `saveIndex` at once if `not f.fromCache`. The job reads `summary`, `channelSets`,
   `gathers` and `crsText`, moves the file into a `Session` and posts the session. The
   progress hook is a `gcsafe` closure on the job thread: it stores `done` and `total` in
   atomics and returns `not cancelled`.
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
| Open, `ensureKeys`, `bruteStack`, exports | The progress hook returning false: `SegCancelledError` (a cancelled open leaves nothing mapped) |
| Prefetch | `seek`, which drops the old chunks; a worker drops a stale chunk within 8 traces |
| `pool.apply` | Nothing: a call takes a few ms per panel. The panel thread checks `requestGen` between chunks |

### Calls by thread

| Call | Thread | Returns; buffer owner |
|---|---|---|
| `openSeismic`, `saveIndex`, `summary`, `channelSets`, `gathers`, `crsText` | job | A move-only `SeismicFile`, kept in the `Session`; owned copies |
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
  The session first cancels its jobs, closes its prefetchers and waits. Afterwards it
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

### Core types (sketch)

```nim
type                         # FileId, PanelId, JobId: distinct int
  Selection = object         # read by the trace panel, the map and the header table
    hover: int               # trace id under the cursor; -1: none
    selected: IntSet         # trace ids: survey-wide (the file's base + the trace index),
                             # so views treat one file and a survey of many files alike
    activeGather: int        # index into the session's gathers; -1: none
    revision: int            # bumped on every change

  CommandKind = enum
    ckOpen, ckCancel, ckViewport, ckHover, ckSelect, ckGather, ckPipeline, ckJoin, ckEdit, ckUndo
  Command = object           # a user intent: the only way state changes
    case kind: CommandKind
    of ckOpen, ckJoin: paths: seq[string]   # a data file; SPS or P1 files
    of ckCancel: job: JobId
    of ckViewport:
      panel: PanelId
      traces, samples: Slice[int]
    of ckHover: trace: int
    of ckSelect: picked: seq[int]          # replaces the selection
    of ckGather: gather: int
    of ckPipeline: flow: Pipeline          # processSEG ops: plain data
    of ckEdit: change: HeaderChange        # kept in a patch until saved
    of ckUndo: discard

  Job = object               # on the shared heap; the UI keeps a ptr
    id: JobId
    command: Command
    cancelled: Atomic[bool]  # read by the job's progress hook
    done, total: Atomic[int64]

  Tile = object              # [traces, samples] float32 on the shared heap; move-only
    panel: PanelId
    gen: uint64              # the requestGen it answers
    data: ptr UncheckedArray[float32]
    firstTrace, traces, firstSample, samples: int

  MsgKind = enum mkOpened, mkTile, mkResult, mkFailed
  Msg = object               # the main-thread inbox
    job: JobId
    case kind: MsgKind
    of mkOpened: session: Session          # a ref, moved from the job thread
    of mkTile: tile: Tile
    of mkResult: result: JobResult         # FoldMap, StackResult, QC rows ...
    of mkFailed: error: string

  AppState = object
    sessions: seq[Session]   # refs: workers hold a ptr SeismicFile into them
    panels: seq[PanelState]  # each with its requestGen
    selection: Selection
    jobs: seq[ptr Job]
    undo: seq[Command]
```
