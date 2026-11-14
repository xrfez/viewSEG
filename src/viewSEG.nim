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
## Options that print and exit without opening a window:
## - `--version`: the version of viewSEG and parseSEG;
## - `--paths` (or `--where`): the directories in use, one `name: path` per line.

import std/[os, strutils]
import parseSEG
import viewSEG/platform/[paths, winres] # winres: Windows manifest, icon, version, subsystem

const frontend {.strdefine.} = "imgui"

proc nimbleVersion(): string {.compileTime.} =
  result = "0.0.0"
  for line in staticRead("../viewSEG.nimble").splitLines:
    if line.startsWith("version"):
      result = line.split('=', 1)[1].strip.strip(chars = {'"'})

const
  ViewSEGVersion* = nimbleVersion() ## from viewSEG.nimble
  Usage = "usage: viewSEG [--version] [--paths | --where] [--help] [--] [file ...]"

when frontend == "imgui":
  import viewSEG/ui/imgui/app
else:
  {.error: "unknown -d:frontend=" & frontend & " (known: imgui)".}

type
  CommandAction* = enum
    caRun = "run"         ## open the window (and `files`)
    caVersion = "version" ## print the versions and exit
    caPaths = "paths"     ## print the directories and exit
    caHelp = "help"       ## print the usage and exit
    caError = "error"     ## a bad argument: print `error` and the usage, exit 1

  CommandLine* = object
    ## What the command line asks for.
    action*: CommandAction
    files*: seq[string] ## seismic files to open, as given
    error*: string

func parseCommandLine*(args: openArray[string]): CommandLine =
  ## Reads the program's arguments: options first wins (`--version`,
  ## `--paths`, `--help`); anything else not starting with `-` names a file;
  ## after `--` every argument names a file.
  result = CommandLine(action: caRun)
  var options = true
  for arg in args:
    if options and arg == "--":
      options = false
    elif options and arg.startsWith("-") and arg != "-":
      case arg
      of "--version", "-v": return CommandLine(action: caVersion)
      of "--paths", "--where": return CommandLine(action: caPaths)
      of "--help", "-h": return CommandLine(action: caHelp)
      else: return CommandLine(action: caError, error: "unknown argument " & arg)
    elif arg.len > 0:
      result.files.add arg

proc versionLine(): string =
  "viewSEG " & ViewSEGVersion & " (parseSEG " & parseSEG.PackageVersion & ")"

proc pathsReport*(c: PathContext): string =
  ## The directories `c` resolves to, one `name: path` line each; the search lists
  ## (assets, vendormaps) give one line per directory, in search order, or
  ## `(none)`. Nothing is created.
  result = "app: " & c.appDir & "\n" &
    "portable: " & (if c.isPortable: "yes" else: "no") & "\n" &
    "config: " & c.configDir & "\n" &
    "logs: " & c.logDir & "\n" &
    "cache: " & c.cacheDir & "\n"
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
    echo versionLine(), "\n", Usage
  of caError:
    stderr.writeLine "viewSEG: ", cmd.error, "\n", Usage
    quit QuitFailure
  of caRun:
    echo versionLine()
    quit run(RunOptions(openPaths: cmd.files, persist: true,
      version: ViewSEGVersion & " (parseSEG " & parseSEG.PackageVersion & ")"))
