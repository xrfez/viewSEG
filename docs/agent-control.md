# Agent control

An AI agent can operate viewSEG while you watch it: open a folder, show a record, change
the gain, sort, select and kill traces, look at the result. It talks to the program through
the [Model Context Protocol](https://modelcontextprotocol.io) (MCP), which Claude Code,
Claude Desktop and most AI editors speak. What the agent does happens in the window in
front of you, through the same commands the window's own controls give, and every call it
makes is written in the Messages window.

It is **off by default**, and nothing in viewSEG reaches the network: the agent is a
program you run, on your own computer, that connects to a socket file.

## Turning it on

- Start the program with `--mcp`: `viewSEG --mcp samples/land`. With `--mcp=<socket>` it
  listens on the socket you name instead of the default one.
- Or, in a running program: **File > Agent control**. Click it again to turn it off.

It stays on for that run only; the next start has it off again. While it is on, the status
bar shows **agents: on** first, at its left end, dim. While an agent is connected it says
what the agent asked last, in the warning colour: **agent: state**, **agent: screenshot**,
**agent: command show file** (**agent connected** before its first call); after its last
call it stays for 5 seconds, halfway to dim, so that an agent calling from a shell
(`--mcp-call` connects, calls and disconnects within milliseconds) is seen too. Hover over
it for the socket's path and the agents' names. Messages says when it was turned on, which agent connected, each command it gave
with its arguments and what the program said, and what was refused. So that an agent that
asks over and over does not bury your own messages, a call that changes nothing (`state`,
`headers`, `screenshot`, `wait`), a connection or a disconnection like one written in the
last 10 seconds is counted instead, and the count is written ("12 more "state" calls in the
last 10 s").

The socket is, unless you name one:

1. next to the program when its folder is writable: `bin/viewSEG.sock` for a build in the
   repository, `viewSEG.sock` in a portable folder;
2. else `$XDG_RUNTIME_DIR/viewSEG/viewSEG.sock`;
3. else `viewSEG.sock` in the cache folder.

`viewSEG --paths` prints it (`agent socket: ...`).

## Connecting a client

An MCP client starts its server as a program and talks to it on its standard input and
output. That program is viewSEG itself, started with `--mcp-stdio`: it opens no window,
and passes the agent's calls to the viewSEG you are running.

**Claude Code** (a `.mcp.json` in the project, or `claude mcp add`):

```json
{
  "mcpServers": {
    "viewSEG": {
      "command": "/path/to/viewSEG/bin/viewSEG",
      "args": ["--mcp-stdio"]
    }
  }
}
```

```sh
claude mcp add viewSEG -- /path/to/viewSEG/bin/viewSEG --mcp-stdio
```

**Claude Desktop** (`claude_desktop_config.json`) and other clients (VS Code, Cursor, ...)
take the same command and arguments. Give `--mcp-stdio=<socket>` when the program was
started with `--mcp=<socket>`.

The client can be started before the program: it lists the tools at once, and a call made
while no viewSEG listens says how to start one. The client connects at its next call, and
again after the program is restarted.

### The program on the desktop, the agent in a container

When the agent runs in a devcontainer that shares the repository folder with your desktop
(Linux), start the program from the repository on the desktop:

```sh
cd ~/path/to/viewSEG
bin/viewSEG --mcp samples/land
```

The socket is `bin/viewSEG.sock`, inside the shared folder, so the client in the container
reaches it with the command above (`/workspaces/viewSEG/bin/viewSEG --mcp-stdio` in a
container that mounts the repository at `/workspaces/viewSEG`). A network port would not
work: a container and the desktop each have their own loopback. Two conditions: the
container's user has the same user id as yours (devcontainers set it so), and the folder is
shared by a Linux kernel (Docker Desktop on macOS or Windows does not pass sockets through
shared folders).

### From a shell

One call, its answer printed:

```sh
bin/viewSEG --mcp-call state '{"parts": ["panels"]}'
bin/viewSEG --mcp-call command '{"kind": "sort", "order": [{"field": "channel"}]}'
bin/viewSEG --mcp-call wait
bin/viewSEG --mcp-call screenshot '{"window": "plot"}' --png=plot.png
```

`--mcp-call=<socket>` names the socket. The arguments are one JSON object. The exit code is
0 when the call succeeded, 1 when it was refused or failed (arguments that are not a JSON
object are refused at once), 2 when no viewSEG of yours listens.

## The tools

| Tool | Arguments | Answers with |
|---|---|---|
| `command` | One command: its `kind` and the fields that kind takes (below) | What the program said while carrying it out; an error when the command was refused, or did not fit the state (a gather out of range) |
| `state` | `parts` (any of `program`, `fileList`, `files`, `panels`, `selection`, `map`, `jobs`, `messages`, `survey`, `headers`, `memory`, `spectra`, `displayPresets`, `plots`, `project`, `properties`, `compare`, `vendorMaps`; all when not given), `messages` (how many of the newest, 20), `since` (a message serial), `limit` (the longest list, 200) | The program's own folder and working folder (`program`: see "Paths" below; with the theme the settings name, `theme`, "" when it follows the system, the themes there are, `themes`, and the `versions` of viewSEG, parseSEG, processSEG and Nim, and the build, the `author`, `email` and `copyright` line Help > About shows, and `shortcuts`, the keyboard and mouse gestures Help lists, each with its `group`, `keys` and `what`), the file list, the open files (each with `firstTrace`, the survey-wide id of its first trace), the panels (file, record, layout, view: the traces and times shown and the plot's pixels along each, `columns` along the traces and `rows` along time whichever way it is turned; display and gain, with its `orientation`, display header, order, trace filter, polarity, its filters (`processing`) and which of the traces shown they reach (`filtersReach`: `none` when no filter is applied, `all`, `seismic` when the auxiliary traces shown are passed by, `no trace` when every trace shown is auxiliary and `aux` is off), `positions`: the trace index in its file at each position in the order shown, the killed and reversed traces, `allReversed`, what Undo and Redo would do (`undo`, `redo`), whether the file's identity is known and confirmed and the entry its edits are remembered in (`remembered`), and whether the picture is `complete`; its `level`, the record's, and `levelOver`, the traces it is taken over when not every one: "every 4th trace"), the selection, the map (its view, each layer with its points and whether it is shown, the points selected and hovered with where they are and their stations), the jobs, the newest messages, the survey's layers; the Headers window (`headers`: the tab shown, its toggles, what it has on screen, the traces its Trace tab is about with what its reader read of each (and the groups of its keys a geometry join gave), and the facts its Summary gives of the file the plot shows: the summary, the coordinate units and reference, the file headers, the join); what is remembered about files (`memory`: as File memory listed it last, each file's name, path, when opened, what is kept, sizes and whether it is gone, `unreached` (its folder not there), `looking` (not looked at yet) or `notAnswering` (its drive did not answer in 3 s)); the properties of the file the Seismic window shows (`properties`: the Headers window's Summary as `sections`, each a `title` and its `lines` of `label` and `value`: what the file is, how it was opened, its traces and timing, its coordinates, the join, the record shown; with the options it opens with, `openChoice`, and what its open did, `opened`: the standard it was read as and what detection says, the index from the cache or a sample of the headers, `access` mapped or unmapped, demultiplexed, samples wider than 4-byte floats; null when no file is shown); the display presets (`displayPresets`: each one's `name` and `display`, in their order); the analysis windows (`plots`, New plot: each one's id, title, view, settings, whether frozen, traces, reference, filters, cursor, `explain` (what its plots tell you, as their Explain icons say it; each plot has its own too), what it is of and was left out, and its numbers: each plot's curves at most `limit` points, its axes as they were drawn last frame (`xRange` and `yRange`, `[low, high]`, null when the plot was not drawn or an axis had no numbers; `zoomed`: whether the user moved `x` or `y` off its fit), a correlation's `peakLagMs` per trace (a row of its `table` each; null for the reference's own trace, which is not drawn beside others), an image's size and axes and, per column, the y of its largest value (an f-k's columns are wavenumbers, its rows frequencies); each curve's `style`, `line`, `limit` (with its own `xs`: its two ends) or `past a limit` (NaN but at the points past one); a vibrator signature's `table`, a row per signal after the columns' names, its force numbers in the stored unit, not the unit the window shows); the spectrum windows (`spectra`: the live panel first, id 0, then the FFT windows: each one's title, whether it is on screen, frozen, how it is shown, what chose its traces and which, its filters, whether it waits for an answer, and its spectrum: the traces asked about, averaged, and left out (killed, dead, unreadable, at another interval), how many were read from the file for it, the interval, the time window, the bins' spacing, Nyquist, and per curve (`raw`, `processed`) the amplitude at most `limit` points from 0 Hz to Nyquist, each the largest of `step` bins, and its peak's frequency, amplitude and dB; what the processed curve went through: `filtersAsked` (the plot's filters, in words; a trace's own filter is named in `filterWords`, not here), `processedWith` (the same when there is a processed curve, else ""), `filterAux`, `filtered` (traces through the filters, those the processed curve is of), `passedBy` (auxiliary traces the filters passed by, the Aux toggle off: in the raw curve only), `filterNote` (what Nyquist cut), `filterProblem` (why the filters did not run), `cursor` (`held` false, or held: its `bin`, `hz`, `curve`, and the `raw` and `processed` `amplitude` and `db` at it), `response` (the gain the filters apply, measured through them, on a grid of its own: `hz` and `gain` at most `limit` points, each the smallest of its run so a notch is kept, and `points`, the grid's size; null when they have no pass band or notch or did not run), and `filterWords`, the window's own line about it, and `explain`, what its plots tell you, as their Explain icons say it); the project open (`project`: `open`, its `path`, `name`, `readOnly` and `whyReadOnly`, its `dataFolders` each with its `state` (`found`, `missing`, `looking`, `notAnswering`) and where it was found, its `survey`: the copies with their originals' `state` (`asCopied`, `changed`, `notFound`), the survey's `state` (`none`, `loading`, `loaded`, `keeping`, `failed`), `updateOffered`, the options and units, `sources`, `receivers`, `relations`, `storeBytes` and `restoreMs`; whether it holds its own `displayPresets` (their count, -1 for the user's) and `filters`; and, with a project or without, `earlierOutputs`: what is remembered about other files once at the path of the file the plot shows (each `document`, what it `kept`, its `traces`, when `opened`), whose edits are not applied to it; docs/project.md); the vendor fields each trace read for the Headers window has (`headers`'s `trace.read` entries: `vendor`, the blocks the maps decode of its header extensions, each with its `map`, `block` and `fields`); the vendor header maps (`vendorMaps`: the project's rule, `choice` (`automatic`, `none` or a map's name); the `folders` they are loaded from in order of preference, each with its `path`, where it is `from`, whether it `exists` and how many `maps` it gave; the `maps` loaded, each with its `name`, `file`, `folder`, where it is `from` and what it `appliesTo`; the `problems` of maps that did not load or loaded with a note; the maps `shadowed` by one of the same name in an earlier folder; and `loads`, how many loads were taken in; docs/user/vendor-maps.md) |
| `headers` | A trace: `trace` (its survey-wide id), or `panel` and `position` (0 is the first shown: the leftmost, or the topmost when time runs across), or `file` (an open file's id) and `index` | The trace's keys (stations, coordinates, offset, channel, status) and every field of its headers: block, field, value, byte offset, and `vendor`: what the vendor header maps decode of the trace's own header blocks (each block with its `map`, `mapFile`, `block` and `fields`: `name`, `value`, `unit`, `label`, `flags`; empty when no map applies). Read from the file in the background, so the answer may come a few frames later; a file whose drive has not answered for 3 s is answered with an error saying so |
| `screenshot` | `window`: `window` (the whole window, default), `plot` (the Seismic window's picture of the traces alone, as drawn: turned when time runs across), `seismic`, `map` (the Map window), `files`, `records`, `headers` (the Headers window), `messages`, `jobs`, `toolbar`, `statusbar`, `spectrum` (the live Spectrum panel), `fft` (the FFT window opened last), `fft 2` (FFT window 2), `new plot 3` (analysis window 3), `compare` (the compare window); `maxSize`, the longest side in pixels (1600; larger pictures are scaled down) | A PNG. `plot` is refused, with what the window says instead, while the Seismic window shows no picture of traces (every trace hidden by the trace filter, a record being read, the window behind another tab) |
| `wait` | `timeout` in seconds (30; at most 300) | Whether everything is done: no job running or waiting, every panel's picture read, sorted and drawn (a panel whose trace filter hides every trace has `nothing to draw`, which counts as done), what the Headers window has on screen read, and every spectrum window's spectrum computed; else what is still going. Call it after a command that reads data, before `state` or `screenshot` |

### Commands

The `command` tool's arguments are a command, as the window's controls make them. Its
schema (in the tool list) gives every field and value; the most used:

| `kind` | Fields | Does |
|---|---|---|
| `browse` | `paths`, `showFirst` | Lists files and folders in Files (and shows the first) |
| `open` | `paths` | Opens files without showing them |
| `reopen` | `reopenPath`, `openChoice` (`standard`: `detect`, `SEG-Y`, `SEG-D`, `SEG-2`; `verifyAll`; `twosComplement`; `access`: `auto`, `mapped`, `unmapped`; each optional, the defaults detect everything) | Opens the file again with these options, as File > Reopen with options does: in the panels that show it, at the record they show (a file not open is opened and shown in the Seismic window); later opens of it this run take them too. The file is opened first and replaces the one shown only when it has traces (else it stays as it was, with one message, and the options are not kept); with the same trace count the selection and the FFT and plot windows are kept, and the survey join is matched again (kept once that match succeeds, dropped and said why if it fails). A missing or unopenable file gives one failure message and keeps no choice. Read-only, as every open; a folder for a demultiplexed copy (`demuxDir`) is refused. `state`'s `properties` says how the file was opened |
| `show file` | `path`, `panel` | Shows a file in a panel |
| `go to gather` | `gather` | Shows another record of the file shown |
| `view` | `view` (`traces` and `timeMs`, each `lo` and `hi`) | Zooms and pans, as you would |
| `display` | `display` (`orientation`: `time down` or `time across`; `mode`, `fills`, `overlap`, `gain`, `gainDb`, `agcWindowMs`, `clipPercentile` (the percentile of \|x\| drawn at full scale, the colour map's ends, 50 to 100), `colourMap` (density's: `grey`, `red-white-blue`, `viridis`, `red-black`), colours ...) | How the traces are drawn, and which way the plot is turned. A new `clipPercentile` or `colourMap` reads nothing from the file |
| `display preset` | `presetAction` (`apply`, `save`, `rename`, `delete`), `presetName`, `presetNewName` (rename) | Draws the panel as a named display preset says (its orientation kept), keeps the panel's display under a name (replacing one so named), renames or deletes one, as the gear's Display presets section does; for the session only. `state`'s `displayPresets` lists them, and each panel's `displayPreset` names the one it shows |
| `sort` | `order` (`field`, `descending`) | The traces' order; `[]` is the file's |
| `trace filter` | `filter` (`seismic`, `auxiliary`) | Which traces are shown |
| `processing` | `processing` (`dc`: `none`, `mean`, `mean and trend`; `band`: `none`, `low-cut`, `high-cut`, `band-pass`; `f1` .. `f4` in Hz, the low-cut ramp `f1` to `f2` and the high-cut ramp `f3` to `f4`; `notches`, each `on`, `hz`, `widthHz`, `harmonics`; `raw`; `aux`) | The filters the traces go through, as the strip's Filters drop-down sets them: `{"kind": "processing", "processing": {"band": "band-pass", "f1": 4, "f2": 8, "f3": 60, "f4": 80}}`; `raw` shows them unfiltered (`P`), `aux` filters the auxiliary traces too. `state` gives each panel's `processing`, and `processingNote` when the file's Nyquist cut a corner or notch, or when the file gives no sample interval (the pass band and notches are then not applied) |
| `select` | `traces` (survey-wide ids), `mode` (`replace`, `add`, `toggle`, `range`), `all` (true: every trace the Seismic window shows, with its Seismic / Aux switches and hidden killed traces applied, in place of `traces`; Edit > Select all traces) | The selection |
| `edit traces` | `edit` (`killed`, `reversed`), `edited`, `on`, `alsoDrop`, `alsoFilter` | Kills or reverses traces, beside the file, for this session (below). With `on` false, `alsoDrop` (other edits) and `alsoFilter` (the trace's own filter) are taken away in the same step |
| `own filter` | `edited`, `on`, `processing`, `filterPlace` (`after`, `instead`) | Sets a trace's own frequency filter (`on` true) or removes it. `processing` is the same object as `processing` (DC, pass band, corners, notches); `raw` and `aux` are ignored. `after` (the default) runs it after the plot's filters, `instead` instead of them. Omitted `edited` is the selection. `state`'s panel lists them in `ownFilters` (`trace`, `place`, `words`) |
| `undo edit`, `redo edit` | | Takes back the last change to the edits of the panel's file, or makes it again, as Edit > Undo and Redo; `state`'s panel says what each would do (`undo`, `redo`) |
| `list file memory` | | Reads again what is remembered about files, as File > File memory... does; `state`'s `memory` part gives it |
| `map view` | `mapView` (`centre`: `x`, `y`; `perPixel`: survey units a pixel) | Pans and zooms the map, as you would |
| `map layer` | `mapLayer` (as `state` names it), `shown` | Shows or hides a layer of the map (`shown` defaults to true) |
| `select points` | `points` (`layer`, `role`, `point`), `pointMode` | Selects points on the map, and their traces |
| `hover points`, `show points' record` | `points`; `shotPath` | Lights up the points' traces as the map's pointer does; shows the record of their traces (a source no open file has, its shot from a listed file: the newest, or the file `shotPath` names) |
| `join geometry` | `joinFiles` (each `path`, `kind`: `SPS`, `SEG P1` or `CSV table`, and a table's `role`); `joinFile` (a file's id, as `state` gives it; the plot's file when not given), `joinOptions` (the window's when not given), `joinUnits` (`survey`, `file`; when not given, what the headers say, worked out by the import from the files it reads: the survey files' units, and the seismic file's own following them where its headers say nothing or only feet; `state`'s Headers and map parts then say they came from the headers) | Imports a survey, as File > Import > Import survey does: its SPS and P1 files are put on the map (as `load survey` does; once: one already there is not loaded again) and matched to an open file's traces, in memory; with no file shown and none named, on the map only (no file is written; the kind keeps parseSEG's name for it, a join); `wait`, then `state`'s log and its map part say what it did |
| `select unmatched` | `unmatchedOf` (the id of the file the survey was imported for; the plot's when not given) | Selects the traces the survey did not match |
| `choose unit` | `unitChoice`: `survey` (the survey's files' paths, any order) or `file` (a seismic file's path), `unit`, `byHand` (false: back to what the headers say) | Chooses the unit of that survey's (or that file's) coordinates, as the Import survey window's dropdowns do, for the session; a survey of other files keeps its own. Nothing is converted |
| `read survey units` | `unitsOf` (survey files: each `path` and `kind`, as for `join geometry`) | Reads what each file's headers say of its coordinates' unit (SPS H20 and H201, SEG P1's H2000, a CSV table's comment or first row), from its first 64 KiB, on a job each, as the Import survey window does when a file is chosen; a file read once is not read again. Nothing is changed |
| `headers shown` | `inspect` (any of `record headers`, `trace headers`, `trace samples`, `trace table`), `table` (with `trace table`: `fields`, columns named as parseSEG names fields, `trace.sourceX`, or `keys.` and a key, `keys.rcvPoint`; `scope` `record` or `file`; `sortBy` a column, "" for the file's order, and `descending`; `findField` and `findValue`, a number or a range `a..b`; `rows` {`a`, `b`}, the rows wanted, at most 2048 (an int32 at the most); `fields` at most 32 (more are refused); `graph` a column graphed along the rows) | Has the Headers window's reader read those parts (of the record the plot shows; of the selected traces, else the trace under the pointer; the trace table's rows), as the window does for what it has on screen; `wait`, then `state`'s `headers` says what was read (`table`: the rows read, each its `row`, the trace's `index` in its file and its `values`, the `count` of rows Find keeps, the scope's `traces`, the graph's buckets and the problems). The window says it again when what it shows changes |
| `open spectrum` | `spectrumTraces` (survey-wide ids of the plot's file; the selected traces there when not given), `spectrumShow` (`scale`: `dB` or `linear`; `logFrequency`; `time`: `whole trace` or `visible time`; `raw`, `processed`, `response` (the filters' response drawn), `phase`), `spectrumOf` (the panel, 1) | Opens an FFT window, as "FFT in a new window" does: their amplitude spectrum (averaged), raw and through the plot's filters, killed traces left out; `wait`, then `state`'s `spectra` gives its numbers and `screenshot` `fft` its picture |
| `spectrum panel` | `onScreen` (true when not given) | Shows the live Spectrum panel, brought forward (as Window > Spectrum does), so it follows the plot's view or selection; `false` stops it asking (the window stays as the user left it) |
| `spectrum display` | `spectrum` (the window's id: 0 the live panel), `spectrumShow`, `frozen` | How a spectrum window shows its spectrum, over which time; a new time asks again. Frozen, it keeps the traces and the file it shows; not frozen, it follows the plot (the selection in the record on show, or the traces in view, and the filters) |
| `spectrum cursor` | `spectrum` (the window's id: 0 the live panel), `cursor` (`held`; `x` the frequency bin, `y` the curve as drawn, 0 the first in the legend) | Holds the window's cursor there, as Left / Right / Home / End / Up / Down do, within the bins its axis shows (not 0 Hz on a logarithmic one) and the curves it draws (a bin or curve past them is held at the nearest, and the reply's messages say so), or lets it go (`held` false), as Esc does. It is held at that bin's frequency and on that curve (`raw`, `processed`, `response`), and stays at them when the bins change (a notch's finer bins, another time) or curves appear or go: at the nearest bin, on the top curve while its own is not drawn. `state`'s `spectra` give its `cursor`: the bin, its frequency (`hz`), the frequency held (`heldHz`), the curve as drawn and by name (`curve`, `curveName`), and the raw and processed amplitude and dB there |
| `step trace` | `stepBy` (1 the next trace, -1 the previous; 1 when not given), `spectrum` (an FFT window's id: it steps from its own trace; a frozen one keeps that trace, steps the plot's selection and says so; one not frozen follows the new selection; 0, or not given: the plot's selection), `spectrumOf` (the panel, 1) | Selects the next or previous trace of the record shown, in the order shown, as Alt + arrow does: skipping traces the trace filter hides, not killed ones shown; the plot scrolled to keep it in view; "the record ends there" when there is none |
| `close spectrum` | `spectrum` (an FFT window's id) | Closes it, dropping its work |
| `open plot` | `plotView` (`spectrogram`, `envelope`, `phase spectrum`, `cross-correlation`, `vibrator signature`, `f-k`, `node orientation`), `plotTraces` (survey-wide ids of the plot's file; the selected traces there, else the trace under the pointer, when not given; a `node orientation` plot takes the traces the panel shows, in its order, when not given, and follows them whatever is selected), `plotOf` (the panel; 1 when not given), `plotParams` (`windowMs`, `overlap`, `floorDb`, `colourMap`: a spectrogram's frames, overlap %, lowest dB, colours; `phaseWithinDb`, `unwrap`: a phase spectrum's threshold and unwrapping; `phaseShow` (`Absolute`, the default, or `Signed`: how the envelope's phase against the reference, the correlation's and the vibrator signature's phase differences are shown; in `plotParams` of those three), `maxLagMs`: a correlation's (it correlates against the reference chosen with `select reference`, and no other; an old `reference` field in `plotParams` is ignored); `fkFromMs`, `fkToMs` (null: the traces' ends), `fkRaw`, with `floorDb` and `colourMap`: an f-k's (one opened on fewer than 4 traces is of the seismic traces of the record); `roles` (`reference`, `groundForce`, `mass`, `baseplate`: each role's place among the window's traces, 0 the first, -1 none; `groundForcePolarity`, `massPolarity`: `as recorded`, `reversed`, `automatic`), `reactionMassKg`, `baseplateMassKg` (null: none, no generated force), `harmonics`, `projectReference` (true, the default: measured against the project's chosen reference when there is one, the recorded Ref trace then measured against it as `Ref (recorded)`; false: against the recorded Ref trace; the plot's `measuredAgainst` says which), `limitsOn`, `limits` (`phaseDeg`, `meanPhaseDeg`, `thdPct`, `meanThdPct`, `harmonicPct`, `forceLow`, `forceHigh`, `peakForce`, null: none): a vibrator signature's; one opened on a single trace takes the record's next three too; a value out of the range the plot's boxes allow, or null where it must be a number, refuses the command and says the range: `windowMs` above 0 and at most 3600000, `overlap` 0 to 95, `floorDb` from -400 to below 0, `phaseWithinDb` above 0 and at most 400, `maxLagMs` above 0 and at most 3600000, the times (`fkFromMs`, `fkToMs`) within ±3600000, `harmonics` 2 to 16, the masses above 0 and at most 1e9 kg (or null; the window may show pounds, the command stays in kilograms), the limits within ±1e9 (or null; a force limit is in the stored unit, newtons or counts, not the unit the window shows)) | New plot: an analysis window of those traces (docs/plot-window.md, "New plot"), worked out off the UI thread, following the plot's filters and kills unless frozen. `state`'s `plots` gives it; `wait` waits for its numbers |
| `plot display` | `plot` (the window's id), `plotParams`, `plotFrozen` | An analysis window's settings, and whether it keeps what it shows. The options of its kind are what a new window of that kind opens with (for the session, as an agent's changes are; `open plot` with no `plotParams`, or the built-in ones, takes them) |
| `plot cursor` | `plot`, `plotCursor` (`held`, `x`, `y`: an image's column and row) | Where its cursor is held, as its keys hold it; `held` false lets it go |
| `close plot` | `plot` | Closes it, dropping its work |
| `new project` | `projectPath` (the project's folder, made), `projectName` ("" for the folder's), `dataFolders` (none: the folder the file list lists), `useSurvey`, `bringMemory`, `takePresets` | Makes a project as Project > New project does, and opens it; the files open stay open. It writes a new folder only, never into a data folder; what the agent then does in it is for the session (docs/project.md) |
| `open project` | `projectPath` (a project's folder, or its `project.nif`) | Opens a project as Project > Open project does: the files open and the survey on the map are closed, the project's opened, its survey made from what it keeps (no survey file read) and every file opened matched to it; `wait`, then `state`'s `project` |
| `close project` | (none) | Closes the project open, as Project > Close project does: its files and survey are closed, the user's windows, presets and filters come back |
| `vendor map` | `vendorMap` (a loaded map's name, `automatic` or `none`) | Sets the project's vendor map rule, as Project > Vendor map does: only that map is offered to decoding for the project's files (and only decodes those it matches), every map loaded (`automatic`), or none. A project must be open. For the session only: an agent's choice is not saved in the project. `state`'s `vendorMaps.choice` says the rule in force |
| `reload vendor maps` | (none) | Reads the vendor header maps again from every folder (File > Reload vendor maps): the project's, the user's settings folder, beside the program, the environment's; a map dropped in while the program runs is picked up and files open show the new decode. Reads the folders only. `wait`, then `state`'s `vendorMaps` and `messages` |
| `list references` | (none) | Reads the reference archive in force (the project's when one is open, otherwise the main archive) and, with a project open, the main archive too |
| `store reference` | `refStore` (`name`, `trace` a survey-wide id, `fromMs`, `toMs`; `toMs` below 0 keeps the trace's end) | Stores that trace's raw samples (no filters, no gain, no polarity edit), cut to the window, as a named reference. A name already used is refused |
| `generate reference` | `refGenerate` (`name`, `law`: `linear`, `exponential`, `dB/octave`, `dB/Hz`, `f1Hz`, `f2Hz`, `durationMs`, `dtMs` (0: the file on show), `taperStartMs`, `taperEndMs`, `taperShape` (`tpLinear`, `tpCosine`, `tpCos2`, `tpHamming`, `tpBlackman`, `tpBlackmanHarris`, `tpKaiser`, `tpGaussian`, `tpPower`; left out: `tpCos2`), `taperParam` (Kaiser beta, Gaussian sigma or the power exponent; left out or null: that shape's default), `phaseDeg` (degrees; left out: 0; 180 reverses the polarity; there is no separate polarity), `amplitude` (0 means 1), `boostDb`) | Makes a sweep and stores it. `name` empty: one made from the parameters. A shape, parameter or phase processSEG refuses is refused, and nothing is stored |
| `pilot reference` | `refPilot` (`name`, `aux`: true for auxiliary trace N of the record, false for trace N of it; `trace` N from 1; `startMs`; `spanMs`, more than 0) | Stores a rule, not samples: when this reference is the chosen one, each record uses its own trace by the rule, cut to the window (the Generate dialog's "A trace of the record"). `name` empty: one made from the rule. A record with no such trace says so in the correlation window |
| `pilot preview` | `refPilot` (as `pilot reference`) | Reads, off the UI thread, the pilot the rule takes from the record on show, for the Generate dialog's preview; nothing is stored, and what it reads is shown only in the Generate dialog |
| `select reference` | `refId` ("" : none) | The reference a cross-correlation uses, and a vibrator signature uses instead of the file's pilot. With none chosen a correlation says so and does not draw. Kept in the project when the user has one open, otherwise in the settings; an agent's choice is for the session |
| `rename reference` | `refId`, `refNewName` | Renames a reference. A name already used is refused |
| `delete reference` | `refId` | Removes a reference from the archive in force |
| `copy reference` | `refId` | Copies a reference of the main archive into the project open |
| `view reference` | `refId` | Opens that reference in its own window: samples against time, and its amplitude spectrum. The file under QC stays open |
| `close reference view` | `refWindow` | Closes that window |
| `set compare` | `compareSlot` (`A` or `B`), `compareTrace` (a survey-wide id) or `compareRef` (a reference id; `compareTrace` -1) | Copies that trace, or that stored reference, into the slot. The copy does not follow the plot, the selection or the file. Filling the second slot opens the window. `wait`, then `state`'s `compare` lists both slots and the table (peak, shift in ms, polarity) |
| `clear compare` | `compareSlot` (`A`, `B` or `both`) | Clears that slot, or both |
| `swap compare` | | Swaps the two slots |
| `compare display` | `compareShow` (`difference`, `shiftPeak`, `shiftMs` null for none, `matchRms`, `flip`, `fromMs` and `toMs` null for the span of both, `phasePicture`) | What the window draws and how B is aligned. A difference and a correlation need one sample grid; otherwise `compare` says why |
| `compare window` | `compareOpen` (true when not given) | Opens or closes the compare window. `screenshot` `compare` is its picture |
| `theme` | `theme` (a theme file's name, as View > Theme lists them: `tokyo-night`, `catppuccin-latte`; `""` follows the system) | Draws the program in that theme, as View > Theme does; for the session only. `state`'s `program` says the theme in effect (`theme`) and the themes there are (`themes`) |
| `clear edits`, `reverse all`, `back`, `map back`, `hover`, `clear selection`, `close`, `load survey`, `unload survey`, `cancel job`, ... | | As in the windows |

`panel` defaults to 1 (the Seismic window). A panel keeps whatever is not given:
`{"kind": "display", "display": {"mode": "density"}}` changes the mode alone. `edit
traces` without `edited` edits the selected traces of the panel's file, and `on` defaults
to true.

### Paths

The paths in commands are the program's, on the computer it runs on, which is not always
the agent's: a program on the desktop and an agent in a container see the same repository
under different paths (`/home/you/src/viewSEG` and `/workspaces/viewSEG`, say). So a
**relative path is read against the program's own folder**, the folder of the viewSEG it
runs (`state`'s `program.folder`; `bin/` of the repository for a build there). Name a file
by its place relative to that folder, and it is found on either side:

| The agent sees | The program sees | Give |
|---|---|---|
| `/workspaces/viewSEG/samples/land/shots.sgy` | `/home/you/src/viewSEG/samples/land/shots.sgy` | `../samples/land/shots.sgy` |

An absolute path is taken as it is. The paths `state` reports are the program's.

## What an agent can see and change

Turn agent control on for agents you would let do what you can do in the windows:

- **It reads what you can read.** It can list any folder and open any seismic or survey
  file your user can read, as File > Open can, and read their trace headers. `state`
  gives the paths of what is listed and open, the program's folder and working folder
  (your user name is often in them) and the newest messages; `screenshot` gives pictures
  of viewSEG's own window, nothing else on your screen.
- **It changes the plot as you would, for this session only.** What it does shows and
  acts exactly as if you had done it: the display, gain, filters, display header, sort and display presets
  it sets are what a new plot starts with until you quit, the theme it picks is the program's
  until then, and the files and folders it opens are
  in File > Open recent until then. Nothing of it is saved: not the defaults for new plots, not the
  recent files and folders, nothing in `settings.nif` or `layout.nif`. What you change by
  hand is saved as always, also while an agent is connected, and only your change: if an
  agent set the gain and you then pick another display mode, the mode is saved and the
  gain stays as you last set it. When viewSEG starts again, everything is as you last left
  it by hand, whatever agents did. An export of the settings writes yours. Messages and
  the session log still list every command an agent gave. Opening a file writes its index
  cache, as when you open it. Numbers no control would take are brought within the
  controls' ranges.
- **Its trace edits are for this session only too.** What an agent kills, reverses
  (one trace or all of them), filters, undoes, redoes or clears is shown as if you had done it,
  but is never remembered with the file: the next time the file is opened, it shows the
  edits as you last left them by hand. The rule, as built: a change keeps (is
  remembered) when it comes from a window, and is shown only when it comes from agent
  control; your own Undo or Redo of a step, the agent's included, is yours, and what it
  then shows is remembered for the traces it touches. So is your own edit of a trace an
  agent changed: a selection you kill that holds a trace the agent killed is remembered
  whole, and your "Clear all edits" clears what is remembered too, also what the agent's
  undo hid from the plot. Its edits are written nowhere: no entry of File memory is made,
  changed or removed by an agent, and an export of the file's trace edits (yours) leaves
  them out and says how many. The plot's row of edits marks them: **K\*** for an edit
  shown for the session only, **(K)** for one of yours an agent's undo hid.

## What an agent cannot do

- **Write a file of yours.** Exporting the settings, a layout, the messages or a file's
  trace edits, importing trace edits, removing entries of File memory, saving or
  importing a layout and resetting the settings (which keeps a backup) are refused. Killing
  and reversing traces never changes the file: the edits are kept beside it, as when you
  make them. A loaded file is never changed.
- **Change the rest of your preferences** or the windows' arrangement: the settings as a
  whole (units, readout fields, calibration), importing settings, loading a layout,
  and what the Window menu does (resetting the windows, bringing them onto a screen,
  showing and hiding them). Those are not commands at all: the windows are arranged by the
  window itself, which saves what it arranges as yours, so they stay with you.
- **Reach anything but this viewSEG.** The socket is a file only you can use (mode 0600);
  on Linux and macOS a client must run as your user, and `--mcp-stdio` and `--mcp-call`
  talk only to a viewSEG of your user. Nothing listens on the network. Every program that
  runs as your user can connect while agent control is on: in a devcontainer that shares
  the socket's folder, that is every program run in the container as your user id.

Limits: four agents at once, a message of 1 MiB at most (one JSON object, without
comments), sixteen calls waiting per agent; a call is answered within a minute or refused
(a `wait`, within its own time). Bad input is answered with an error and never stops the
program.

## When it does not connect

- *viewSEG is not running with agent control on at ...*: no viewSEG listens there. Start
  it with `--mcp`, or turn on File > Agent control, with the same socket on both sides
  (`viewSEG --paths` shows the default).
- *another program listens on ...*: another viewSEG has agent control on with that socket;
  give this one `--mcp=<another socket>`.
- *the socket path ... is longer than the 107 bytes*: give a shorter `--mcp=<socket>`.
- *... is not a socket*: a file of that name is in the way; viewSEG leaves it alone.
- *the program listening on ... runs as another user*: the socket is not your viewSEG's
  (another user's program listens there); give your own `--mcp=<socket>` on both sides, in
  a folder only you can write.

**Windows:** not available yet; the options say so.
