## viewSEG: a high-performance SEG-Y / SEG-D viewer built on parseSEG and processSEG.
##
## The entry point reads the command line and picks the frontend; see
## docs/architecture.md for the layers. `-d:frontend=imgui` (the default) is the
## Dear ImGui frontend in `viewSEG/ui/imgui`.
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
  Usage = "usage: viewSEG [--version] [--paths | --where] [--help]"

when frontend == "imgui":
  import viewSEG/ui/imgui/app
else:
  {.error: "unknown -d:frontend=" & frontend & " (known: imgui)".}

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
  for arg in commandLineParams():
    case arg
    of "--version", "-v":
      echo versionLine()
      quit QuitSuccess
    of "--paths", "--where":
      stdout.write pathsReport(currentContext())
      quit QuitSuccess
    of "--help", "-h":
      echo versionLine(), "\n", Usage
      quit QuitSuccess
    else:
      stderr.writeLine "viewSEG: unknown argument ", arg, "\n", Usage
      quit QuitFailure
  echo versionLine()
  quit run()
