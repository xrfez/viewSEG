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
bar shows **agents: on**, and **agent connected** (in the warning colour) while an agent
is connected; hover over it for the socket's path and the agents' names. Messages says when
it was turned on, which agent connected, each of its calls with its arguments, and what was
refused.

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

`--mcp-call=<socket>` names the socket. The exit code is 0 when the call succeeded, 1 when
it was refused or failed, 2 when no viewSEG listens.

## The tools

| Tool | Arguments | Answers with |
|---|---|---|
| `command` | One command: its `kind` and the fields that kind takes (below) | What the program said while carrying it out; an error when the command was refused, or did not fit the state (a gather out of range) |
| `state` | `parts` (any of `program`, `fileList`, `files`, `panels`, `selection`, `map`, `jobs`, `messages`, `survey`; all when not given), `messages` (how many of the newest, 20), `since` (a message serial), `limit` (the longest list, 200) | The program's own folder and working folder (`program`: see "Paths" below), the file list, the open files (each with `firstTrace`, the survey-wide id of its first trace), the panels (file, record, layout, view, display and gain, display header, order, trace filter, polarity, `positions`: the trace index in its file at each position in the order shown, the killed and reversed traces, and whether the picture is `complete`), the selection, the map (its view, each layer with its points and whether it is shown, the points selected and hovered with where they are and their stations), the jobs, the newest messages, the survey's layers |
| `headers` | A trace: `trace` (its survey-wide id), or `panel` and `position` (0 is the leftmost), or `file` (an open file's id) and `index` | The trace's keys (stations, coordinates, offset, channel, status) and every field of its headers: block, field, value, byte offset |
| `screenshot` | `window`: `window` (the whole window, default), `plot` (the Seismic window's picture of the traces alone), `seismic`, `map` (the Map window), `files`, `records`, `messages`, `jobs`, `toolbar`, `statusbar`; `maxSize`, the longest side in pixels (1600; larger pictures are scaled down) | A PNG |
| `wait` | `timeout` in seconds (30; at most 300) | Whether everything is done: no job running or waiting and every panel's picture read, sorted and drawn; else what is still going. Call it after a command that reads data, before `state` or `screenshot` |

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
| `display` | `display` (`mode`, `fills`, `overlap`, `gain`, `gainDb`, `agcWindowMs`, colours ...) | How the traces are drawn |
| `sort` | `order` (`field`, `descending`) | The traces' order; `[]` is the file's |
| `trace filter` | `filter` (`seismic`, `auxiliary`) | Which traces are shown |
| `select` | `traces` (survey-wide ids), `mode` (`replace`, `add`, `toggle`, `range`) | The selection |
| `edit traces` | `edit` (`killed`, `reversed`), `edited`, `on` | Kills or reverses traces, beside the file |
| `map view` | `mapView` (`centre`: `x`, `y`; `perPixel`: survey units a pixel) | Pans and zooms the map, as you would |
| `map layer` | `mapLayer` (as `state` names it), `shown` | Shows or hides a layer of the map (`shown` defaults to true) |
| `select points` | `points` (`layer`, `role`, `point`), `pointMode` | Selects points on the map, and their traces |
| `hover points`, `show points' record` | `points` | Lights up the points' traces as the map's pointer does; shows the record of their traces |
| `undo edit`, `clear edits`, `reverse all`, `back`, `map back`, `hover`, `clear selection`, `close`, `load survey`, `unload survey`, `cancel job`, ... | | As in the windows |

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

## What an agent cannot do

- **Write a file.** Exporting the settings, a layout or the messages, saving or importing a
  layout and resetting the settings (which keeps a backup) are refused. Killing and
  reversing traces never changes the file: the edits are kept beside it, as when you make
  them.
- **Change your preferences** or the windows' arrangement: the settings as a whole,
  importing settings, loading a layout.
- **Reach anything but this viewSEG.** The socket is a file only you can use (mode 0600);
  on Linux a client must run as your user. Nothing listens on the network.

Limits: four agents at once, a message of 1 MiB at most, sixteen calls waiting per agent; a
call is answered within a minute or refused (a `wait`, within its own time). Bad input is
answered with an error and never stops the program.

## When it does not connect

- *viewSEG is not running with agent control on at ...*: no viewSEG listens there. Start
  it with `--mcp`, or turn on File > Agent control, with the same socket on both sides
  (`viewSEG --paths` shows the default).
- *another program listens on ...*: another viewSEG has agent control on with that socket;
  give this one `--mcp=<another socket>`.
- *the socket path ... is longer than the 107 bytes*: give a shorter `--mcp=<socket>`.
- *... is not a socket*: a file of that name is in the way; viewSEG leaves it alone.

**Windows:** not available yet; the options say so.
