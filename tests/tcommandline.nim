## The command line: files to open, the options that print and exit, `--`
## for a file named like an option, and a bad option refused; agent
## control's options (`--mcp`, `--mcp-stdio`, `--mcp-call` with its tool,
## arguments and `--png`) and the socket `--paths` reports; `--reset-windows`,
## and what `--help` says of it.
##
## Seen to fail: with `--` not ending the options, `dashDash` refused
## "-odd.sgy" as an unknown argument; with `--mcp-call`'s arguments read as
## files, `agentOptions` saw "unknown argument --png=shot.png"; before
## `--reset-windows` was known, `resetWindows` saw "unknown argument
## --reset-windows".

import std/strutils
import viewSEG
import viewSEG/platform/paths

block files:
  let c = parseCommandLine(["shot.sgd", "../data/survey.sgy"])
  doAssert c.action == caRun and c.files == @["shot.sgd", "../data/survey.sgy"], $c
  doAssert parseCommandLine([]).action == caRun and parseCommandLine([]).files.len == 0
  doAssert parseCommandLine(["", "a.sgy"]).files == @["a.sgy"], "an empty argument was kept"

block printAndExit:
  doAssert parseCommandLine(["--version"]).action == caVersion
  doAssert parseCommandLine(["-v"]).action == caVersion
  doAssert parseCommandLine(["a.sgy", "--paths"]).action == caPaths
  doAssert parseCommandLine(["--where"]).action == caPaths
  doAssert parseCommandLine(["-h"]).action == caHelp

block dashDash:
  let c = parseCommandLine(["a.sgy", "--", "-odd.sgy", "--version"])
  doAssert c.action == caRun and c.files == @["a.sgy", "-odd.sgy", "--version"], $c

block badOption:
  let c = parseCommandLine(["--open", "a.sgy"])
  doAssert c.action == caError and c.error == "unknown argument --open", $c

block agentOptions:
  let on = parseCommandLine(["--mcp", "a.sgy"])
  doAssert on.action == caRun and on.agent and on.socket == "" and on.files == @["a.sgy"], $on
  let at = parseCommandLine(["a.sgy", "--mcp=/run/v.sock"])
  doAssert at.action == caRun and at.agent and at.socket == "/run/v.sock", $at
  doAssert not parseCommandLine(["a.sgy"]).agent, "agent control is off by default"
  doAssert parseCommandLine(["--mcp="]).action == caError
  doAssert parseCommandLine(["--mcpx"]).action == caError
  doAssert parseCommandLine(["--", "--mcp"]).files == @["--mcp"]
  let bridge = parseCommandLine(["--mcp-stdio"])
  doAssert bridge.action == caMcpStdio and bridge.socket == ""
  doAssert parseCommandLine(["--mcp-stdio=/s.sock", "x"]).socket == "/s.sock"
  let call = parseCommandLine(["--mcp-call=/s.sock", "state", """{"parts":["jobs"]}""",
    "--png=shot.png"])
  doAssert call.action == caMcpCall and call.socket == "/s.sock" and call.tool == "state" and
    call.arguments == """{"parts":["jobs"]}""" and call.png == "shot.png", $call
  doAssert parseCommandLine(["--mcp-call", "wait"]).arguments == ""
  for bad in [@["--mcp-call"], @["--mcp-call", "a", "{}", "c"], @["--mcp-call", "a", "--x"]]:
    doAssert parseCommandLine(bad).action == caError, $bad

block resetWindows:
  let c = parseCommandLine(["--reset-windows", "a.sgy"])
  doAssert c.action == caRun and c.resetWindows and c.files == @["a.sgy"], $c
  doAssert not parseCommandLine(["a.sgy"]).resetWindows, "off by default"
  doAssert parseCommandLine(["a.sgy", "--reset-windows", "--mcp"]).resetWindows
  let after = parseCommandLine(["--", "--reset-windows"])
  doAssert not after.resetWindows and after.files == @["--reset-windows"], $after
  doAssert "--reset-windows" in Help and "primary screen" in Help and
    "Window > Reset the windows" in Help, Help

block pathsReportsTheSocket:
  let report = pathsReport(currentContext())
  doAssert "\nagent socket: " in report and "viewSEG.sock\n" in report, report
