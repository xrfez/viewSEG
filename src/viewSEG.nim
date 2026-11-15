## viewSEG: a high-performance SEG-Y / SEG-D viewer built on parseSEG and processSEG.
##
## The entry point reads the command line and picks the frontend; see
## docs/architecture.md for the layers. `-d:frontend=imgui` (the default) is the
## Dear ImGui frontend in `viewSEG/ui/imgui`.
##
## `viewSEG [file ...]` opens the window and the seismic files named, each in
## the background, as File > Open file does. `--` ends the options, for a file
## whose name starts with `-`.
##
## `--mcp` turns agent control on for the run (docs/agent-control.md): an
## MCP client can operate the program through a socket, `--mcp=<socket>` or
## the one `--paths` names.
##
## `--reset-windows` starts with the windows as at a first start, for when
## they are arranged so that the menus cannot be reached: the default layout
## (every window shown and docked in the main window) and the main window on
## the primary screen at its default size; every other setting is as saved.
##
## Options that print and exit without opening a window:
## - `--version`: the versions of viewSEG, parseSEG and processSEG;
## - `--paths` (or `--where`): the directories in use, one `name: path` per line.
##
## Options that talk to a running viewSEG's agent control, without a window:
## - `--mcp-stdio[=<socket>]`: the MCP server an MCP client starts (stdio);
## - `--mcp-call[=<socket>] <tool> [<arguments>] [--png=<file>]`: one tool
##   call, its answer printed (an image written to `--png`'s file).

import std/[os, strutils]
import viewSEG/core/versions
import viewSEG/platform/[paths, winres] # winres: Windows manifest, icon, version, subsystem
import viewSEG/remote/client

const frontend {.strdefine.} = "imgui"

const
  Usage = "usage: viewSEG [--version] [--paths | --where] [--help] [--reset-windows] " &
    "[--mcp[=<socket>]] [--] [file ...]\n" &
    "       viewSEG --mcp-stdio[=<socket>]\n" &
    "       viewSEG --mcp-call[=<socket>] <tool> [<arguments as JSON>] [--png=<file>]"
  Help* = """
Opens the window, and the seismic and survey files and folders named.

Options:
  --reset-windows     Start with the windows as at a first start: every window
                      shown and docked in the main window, and the main window on
                      the primary screen at its default size. For when the
                      windows are arranged so that the menus cannot be reached;
                      Window > Reset the windows (Ctrl+Shift+R) does the same in
                      a running viewSEG. Every other setting stays as saved.
  --mcp[=<socket>]    Turn agent control on for this run: an MCP client can
                      operate viewSEG through the socket (--paths names the
                      default one).
  --version, -v       Print the versions of viewSEG, parseSEG and processSEG.
  --paths, --where    Print the folders in use (settings, logs, cache, assets).
  --help, -h          Print this.
  --                  End the options: what follows names files.
  --mcp-stdio         Serve an MCP client on stdio, through a running viewSEG's
                      socket.
  --mcp-call          Make one call to a running viewSEG's agent control and
                      print its answer."""

when frontend == "imgui":
  import viewSEG/ui/imgui/app
else:
  {.error: "unknown -d:frontend=" & frontend & " (known: imgui)".}

type
  CommandAction* = enum
    caRun = "run"            ## open the window (and `files`)
    caVersion = "version"    ## print the versions and exit
    caPaths = "paths"        ## print the directories and exit
    caHelp = "help"          ## print the usage and exit
    caError = "error"        ## a bad argument: print `error` and the usage, exit 1
    caMcpStdio = "mcp-stdio" ## serve an MCP client on stdio, through the socket
    caMcpCall = "mcp-call"   ## make one tool call through the socket

  CommandLine* = object
    ## What the command line asks for.
    action*: CommandAction
    files*: seq[string]       ## seismic files to open, as given
    error*: string
    agent*: bool              ## caRun: agent control on (`--mcp`)
    resetWindows*: bool       ## caRun: the windows as at a first start (`--reset-windows`)
    socket*: string           ## agent control's socket, as given; "" for the default
    tool*, arguments*: string ## caMcpCall: the tool and its arguments (JSON text)
    png*: string              ## caMcpCall: where an image the answer holds goes; "" for nowhere

func socketOption(arg, name: string; socket: var string): bool =
  ## Whether `arg` is option `name`, alone or as `name=<socket>`.
  result = arg == name or arg.startsWith(name & "=")
  if result and arg.len > name.len: socket = arg.substr(name.len + 1)

func parseMcpCall(args: openArray[string]; socket: string): CommandLine =
  ## `--mcp-call`'s own arguments: the tool, its arguments, `--png=<file>`.
  result = CommandLine(action: caMcpCall, socket: socket)
  for arg in args:
    if arg.startsWith("--png="): result.png = arg.substr("--png=".len)
    elif arg.startsWith("-") and arg != "-": return CommandLine(action: caError,
      error: "unknown argument " & arg & " after --mcp-call")
    elif result.tool.len == 0: result.tool = arg
    elif result.arguments.len == 0: result.arguments = arg
    else: return CommandLine(action: caError, error: "--mcp-call takes a tool and its " &
      "arguments as one JSON object")
  if result.tool.len == 0:
    result = CommandLine(action: caError, error: "--mcp-call needs a tool to call")

func parseCommandLine*(args: openArray[string]): CommandLine =
  ## Reads the program's arguments: options first wins (`--version`,
  ## `--paths`, `--help`, `--mcp-stdio`, `--mcp-call` and what follows it);
  ## `--mcp` turns agent control on and `--reset-windows` starts with the
  ## windows as at a first start; anything else not starting with `-` names
  ## a file; after `--` every argument names a file.
  result = CommandLine(action: caRun)
  var options = true
  for i, arg in args:
    var socket = ""
    if options and arg == "--":
      options = false
    elif options and arg.socketOption("--mcp-stdio", socket):
      return CommandLine(action: caMcpStdio, socket: socket)
    elif options and arg.socketOption("--mcp-call", socket):
      return parseMcpCall(args.toOpenArray(i + 1, args.high), socket)
    elif options and arg.socketOption("--mcp", socket):
      result.agent = true
      if socket.len > 0: result.socket = socket
    elif options and arg.startsWith("-") and arg != "-":
      case arg
      of "--reset-windows": result.resetWindows = true
      of "--version", "-v": return CommandLine(action: caVersion)
      of "--paths", "--where": return CommandLine(action: caPaths)
      of "--help", "-h": return CommandLine(action: caHelp)
      else: return CommandLine(action: caError, error: "unknown argument " & arg)
    elif arg.len > 0:
      result.files.add arg
  if result.agent and result.socket.len == 0 and "--mcp=" in args:
    result = CommandLine(action: caError, error: "--mcp= needs a socket path")

proc versionLine(): string =
  "viewSEG " & ViewSEGVersion & " (parseSEG " & ParseSEGVersion & ", processSEG " &
    ProcessSEGVersion & ")"

proc pathsReport*(c: PathContext): string =
  ## The directories `c` resolves to, one `name: path` line each; the search lists
  ## (assets, vendormaps) give one line per directory, in search order, or
  ## `(none)`. Nothing is created.
  result = "app: " & c.appDir & "\n" &
    "portable: " & (if c.isPortable: "yes" else: "no") & "\n" &
    "config: " & c.configDir & "\n" &
    "logs: " & c.logDir & "\n" &
    "cache: " & c.cacheDir & "\n" &
    "agent socket: " & c.agentSocket & "\n"
  for (name, dirs) in [("assets", c.assetDirs), ("vendormaps", c.vendorMapDirs)]:
    if dirs.len == 0:
      result.add name & ": (none)\n"
    for d in dirs:
      result.add name & ": " & d & "\n"

when isMainModule:
  let cmd = parseCommandLine(commandLineParams())
  case cmd.action
  of caVersion:
    echo versionLine()
  of caPaths:
    stdout.write pathsReport(currentContext())
  of caHelp:
    echo versionLine(), "\n", Usage, "\n\n", Help
  of caError:
    stderr.writeLine "viewSEG: ", cmd.error, "\n", Usage
    quit QuitFailure
  of caMcpStdio:
    quit bridge(if cmd.socket.len > 0: absolutePath(cmd.socket) else: agentSocket(),
      ViewSEGVersion)
  of caMcpCall:
    quit callOnce(if cmd.socket.len > 0: absolutePath(cmd.socket) else: agentSocket(),
      cmd.tool, cmd.arguments, cmd.png)
  of caRun:
    echo versionLine()
    quit run(RunOptions(openPaths: cmd.files, persist: true,
      version: ViewSEGVersion & " (parseSEG " & ParseSEGVersion & ", processSEG " &
        ProcessSEGVersion & ")",
      agent: cmd.agent, agentSocket: if cmd.socket.len > 0: absolutePath(cmd.socket) else: "",
      resetWindows: cmd.resetWindows, tray: true))
