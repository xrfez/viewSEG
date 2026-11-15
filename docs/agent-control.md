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

- Start the program with `--mcp`: `viewSEG --mcp exampleFiles`. With `--mcp=<socket>` it
  listens on the socket you name instead of the default one.
- Or, in a running program: **File > Agent control**. Click it again to turn it off.

It stays on for that run only; the next start has it off again. While it is on, the status
bar shows **agents: on** first, at its left end, and **agent connected** (in the warning
colour) while an agent is connected; hover over it for the socket's path and the agents'
names. Messages says when it was turned on, which agent connected, each command it gave
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
bin/viewSEG --mcp exampleFiles
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
| `state` | `parts` (any of `program`, `fileList`, `files`, `panels`, `selection`, `map`, `jobs`, `messages`, `survey`, `headers`, `memory`, `spectra`, `displayPresets`; all when not given), `messages` (how many of the newest, 20), `since` (a message serial), `limit` (the longest list, 200) | The program's own folder and working folder (`program`: see "Paths" below), the file list, the open files (each with `firstTrace`, the survey-wide id of its first trace), the panels (file, record, layout, view: the traces and times shown and the plot's pixels along each, `columns` along the traces and `rows` along time whichever way it is turned; display and gain, with its `orientation`, display header, order, trace filter, polarity, its filters (`processing`) and which of the traces shown they reach (`filtersReach`: `none` when no filter is applied, `all`, `seismic` when the auxiliary traces shown are passed by, `no trace` when every trace shown is auxiliary and `aux` is off), `positions`: the trace index in its file at each position in the order shown, the killed and reversed traces, `allReversed`, what Undo and Redo would do (`undo`, `redo`), whether the file's identity is known and confirmed and the entry its edits are remembered in (`remembered`), and whether the picture is `complete`), the selection, the map (its view, each layer with its points and whether it is shown, the points selected and hovered with where they are and their stations), the jobs, the newest messages, the survey's layers; the Headers window (`headers`: the tab shown, its toggles, what it has on screen, the traces its Trace tab is about with what its reader read of each (and the groups of its keys a geometry join gave), and the facts its Summary gives of the file the plot shows: the summary, the coordinate units and reference, the file headers, the join); what is remembered about files (`memory`: as File memory listed it last, each file's name, path, when opened, what is kept, sizes and whether it is gone, `unreached` (its folder not there), `looking` (not looked at yet) or `notAnswering` (its drive did not answer in 3 s)); the display presets (`displayPresets`: each one's `name` and `display`, in their order); the spectrum windows (`spectra`: the live panel first, id 0, then the FFT windows: each one's title, whether it is on screen, frozen, how it is shown, what chose its traces and which, its filters, whether it waits for an answer, and its spectrum: the traces asked about, averaged, and left out (killed, dead, unreadable, at another interval), how many were read from the file for it, the interval, the time window, the bins' spacing, Nyquist, and per curve (`raw`, `processed`) the amplitude at most `limit` points from 0 Hz to Nyquist, each the largest of `step` bins, and its peak's frequency, amplitude and dB; what the processed curve went through: `filtersAsked` (the plot's filters in words), `processedWith` (the same when there is a processed curve, else ""), `filterAux`, `filtered` (traces through the filters, those the processed curve is of), `passedBy` (auxiliary traces the filters passed by, the Aux toggle off: in the raw curve only), `filterNote` (what Nyquist cut), `filterProblem` (why the filters did not run), `response` (the filters' own gain, 0 to 1, at the same points, each the smallest of its `step` bins so a notch is kept; null when they have no pass band or notch), and `filterWords`, the window's own line about it) |
| `headers` | A trace: `trace` (its survey-wide id), or `panel` and `position` (0 is the first shown: the leftmost, or the topmost when time runs across), or `file` (an open file's id) and `index` | The trace's keys (stations, coordinates, offset, channel, status) and every field of its headers: block, field, value, byte offset. Read from the file in the background, so the answer may come a few frames later; a file whose drive has not answered for 3 s is answered with an error saying so |
| `screenshot` | `window`: `window` (the whole window, default), `plot` (the Seismic window's picture of the traces alone, as drawn: turned when time runs across), `seismic`, `map` (the Map window), `files`, `records`, `headers` (the Headers window), `messages`, `jobs`, `toolbar`, `statusbar`, `spectrum` (the live Spectrum panel), `fft` (the FFT window opened last), `fft 2` (FFT window 2); `maxSize`, the longest side in pixels (1600; larger pictures are scaled down) | A PNG |
| `wait` | `timeout` in seconds (30; at most 300) | Whether everything is done: no job running or waiting, every panel's picture read, sorted and drawn, what the Headers window has on screen read, and every spectrum window's spectrum computed; else what is still going. Call it after a command that reads data, before `state` or `screenshot` |

### Commands

The `command` tool's arguments are a command, as the window's controls make them. Its
schema (in the tool list) gives every field and value; the most used:

| `kind` | Fields | Does |
|---|---|---|
| `browse` | `paths`, `showFirst` | Lists files and folders in Files (and shows the first) |
| `open` | `paths` | Opens files without showing them |
| `show file` | `path`, `panel` | Shows a file in a panel |
| `go to gather` | `gather` | Shows another record of the file shown |
| `view` | `view` (`traces` and `timeMs`, each `lo` and `hi`) | Zooms and pans, as you would |
| `display` | `display` (`orientation`: `time down` or `time across`; `mode`, `fills`, `overlap`, `gain`, `gainDb`, `agcWindowMs`, `clipPercentile` (the percentile of \|x\| drawn full black, 50 to 100), `colourMap` (density's: `grey`, `red-white-blue`, `viridis`, `red-black`), colours ...) | How the traces are drawn, and which way the plot is turned. A new `clipPercentile` or `colourMap` reads nothing from the file |
| `display preset` | `presetAction` (`apply`, `save`, `rename`, `delete`), `presetName`, `presetNewName` (rename) | Draws the panel as a named display preset says (its orientation kept), keeps the panel's display under a name (replacing one so named), renames or deletes one, as the gear's Display presets section does; for the session only. `state`'s `displayPresets` lists them, and each panel's `displayPreset` names the one it shows |
| `sort` | `order` (`field`, `descending`) | The traces' order; `[]` is the file's |
| `trace filter` | `filter` (`seismic`, `auxiliary`) | Which traces are shown |
| `processing` | `processing` (`dc`: `none`, `mean`, `mean and trend`; `band`: `none`, `low-cut`, `high-cut`, `band-pass`; `f1` .. `f4` in Hz, the low-cut ramp `f1` to `f2` and the high-cut ramp `f3` to `f4`; `notches`, each `on`, `hz`, `widthHz`, `harmonics`; `raw`; `aux`) | The filters the traces go through, as the strip's Filters drop-down sets them: `{"kind": "processing", "processing": {"band": "band-pass", "f1": 4, "f2": 8, "f3": 60, "f4": 80}}`; `raw` shows them unfiltered (`P`), `aux` filters the auxiliary traces too. `state` gives each panel's `processing`, and `processingNote` when the file's Nyquist cut a corner or notch |
| `select` | `traces` (survey-wide ids), `mode` (`replace`, `add`, `toggle`, `range`) | The selection |
| `edit traces` | `edit` (`killed`, `reversed`), `edited`, `on` | Kills or reverses traces, beside the file, for this session (below) |
| `undo edit`, `redo edit` | | Takes back the last change to the edits of the panel's file, or makes it again, as Edit > Undo and Redo; `state`'s panel says what each would do (`undo`, `redo`) |
| `list file memory` | | Reads again what is remembered about files, as File > File memory... does; `state`'s `memory` part gives it |
| `map view` | `mapView` (`centre`: `x`, `y`; `perPixel`: survey units a pixel) | Pans and zooms the map, as you would |
| `map layer` | `mapLayer` (as `state` names it), `shown` | Shows or hides a layer of the map (`shown` defaults to true) |
| `select points` | `points` (`layer`, `role`, `point`), `pointMode` | Selects points on the map, and their traces |
| `hover points`, `show points' record` | `points`; `shotPath` | Lights up the points' traces as the map's pointer does; shows the record of their traces (a source no open file has, its shot from a listed file: the newest, or the file `shotPath` names) |
| `join geometry` | `joinFiles` (each `path`, `kind`: `SPS`, `SEG P1` or `CSV table`, and a table's `role`); `joinFile` (a file's id, as `state` gives it; the plot's file when not given), `joinOptions` (the window's when not given), `joinUnits` | Imports a survey, as File > Import > Survey... does: its SPS and P1 files are put on the map (as `load survey` does; once: one already there is not loaded again) and matched to an open file's traces, in memory; with no file shown and none named, on the map only (no file is written; the kind keeps parseSEG's name for it, a join); `wait`, then `state`'s log and its map part say what it did |
| `select unmatched` | `unmatchedOf` (the id of the file the survey was imported for; the plot's when not given) | Selects the traces the survey did not match |
| `headers shown` | `inspect` (any of `record headers`, `trace headers`, `trace samples`) | Has the Headers window's reader read those parts (of the record the plot shows; of the selected traces, else the trace under the pointer), as the window does for what it has on screen; `wait`, then `state`'s `headers` says what was read. The window says it again when what it shows changes |
| `open spectrum` | `spectrumTraces` (survey-wide ids of the plot's file; the selected traces there when not given), `spectrumShow` (`scale`: `dB` or `linear`; `logFrequency`; `time`: `whole trace` or `visible time`; `raw`, `processed`, `response` (the filters' response drawn), `phase`), `spectrumOf` (the panel, 1) | Opens an FFT window, as "FFT in a new window" does: their amplitude spectrum (averaged), raw and through the plot's filters, killed traces left out; `wait`, then `state`'s `spectra` gives its numbers and `screenshot` `fft` its picture |
| `spectrum panel` | `onScreen` (true when not given) | Shows the live Spectrum panel, brought forward (as Window > Spectrum does), so it follows the plot's view or selection; `false` stops it asking (the window stays as the user left it) |
| `spectrum display` | `spectrum` (the window's id: 0 the live panel), `spectrumShow`, `frozen` | How a spectrum window shows its spectrum, over which time; a new time asks again. Freezes the live panel or lets it follow again; an FFT window frozen keeps the filters it went through, and follows the plot's (and its Aux toggle) again when not |
| `close spectrum` | `spectrum` (an FFT window's id) | Closes it, dropping its work |
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
| `/workspaces/viewSEG/exampleFiles/shot.sgd` | `/home/you/src/viewSEG/exampleFiles/shot.sgd` | `../exampleFiles/shot.sgd` |

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
  it sets are what a new plot starts with until you quit, and the files and folders it opens are
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
  (one trace or all of them), undoes, redoes or clears is shown as if you had done it,
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
  whole (units, readout fields, calibration, theme), importing settings, loading a layout,
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
