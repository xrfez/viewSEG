## Dear ImGui's internal checks (`IM_ASSERT`) in release builds.
##
## Debug builds keep ImGui's own `assert`, which stops the program at the
## mistake. A release build must not abort over a check in the toolkit: it
## force-includes `imassert.h` into every C++ file, which routes `IM_ASSERT` to
## `viewsegImAssert` below. Each failed check is recorded once (with a repeat
## count), and the frame loop shows new ones in the Messages window. ImGui's
## recoverable errors (`IM_ASSERT_USER_ERROR`) end up here too.

import std/os

const RoutedChecks* = defined(release) or defined(danger)
  ## true when failed ImGui checks are recorded instead of aborting

when RoutedChecks:
  import std/strutils # only to find imassert.h beside this file
  # Joined with "/" by hand: cross-compiling for Windows, `/` and `parentDir`
  # use the target's `\`, which a Linux shell drops.
  const
    here = currentSourcePath().replace('\\', '/')
    header = here[0 .. here.rfind('/')] & "imassert.h"
  when defined(vcc):
    {.passC: "/FI" & quoteShell(header).}
  else:
    {.passC: "-include " & quoteShell(header).}

type
  ImguiCheck* = object
    ## A Dear ImGui check that failed.
    expr*: string ## the condition, as written in ImGui's source
    file*: string ## the source file's name, without its directory
    line*: int
    count*: int   ## how often it has failed so far

const maxChecks = 64 ## distinct checks kept; later new ones are not recorded

var
  checks: seq[ImguiCheck] # Dear ImGui runs on the UI thread only, and so does this
  reported = 0

proc viewsegImAssert(expr, file: cstring; line: cint) {.exportc, cdecl, raises: [].} =
  ## Called by `IM_ASSERT` (imassert.h) when its condition is false.
  let name = extractFilename($file)
  var known = false
  for c in checks.mitems:
    if c.line == line and c.file == name:
      inc c.count
      known = true
  if not known and checks.len < maxChecks:
    checks.add ImguiCheck(expr: $expr, file: name, line: line, count: 1)

proc newImguiChecks*(): seq[ImguiCheck] =
  ## The checks that failed for the first time since the last call.
  result = checks[reported .. ^1]
  reported = checks.len

func describe*(c: ImguiCheck): string =
  ## `c` in plain words, for the log.
  "Internal display error: Dear ImGui's check `" & c.expr & "` failed (" & c.file & ":" &
    $c.line & "). viewSEG carries on; please report this message."

proc checkCount*(): int =
  ## How many distinct checks have failed since the program started.
  checks.len

proc checkReport*(): string =
  ## Every failed check, in words; "" when none has failed.
  for c in checks: result.add c.describe & "\n"
