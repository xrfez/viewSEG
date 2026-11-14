## The command line: files to open, the options that print and exit, `--`
## for a file named like an option, and a bad option refused.
##
## Seen to fail: with `--` not ending the options, `dashDash` refused
## "-odd.sgy" as an unknown argument.

import viewSEG

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
