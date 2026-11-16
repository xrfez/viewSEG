## Neutral names for the private sample files: a missing folder, mapping or
## file is "", and a key absent from an existing mapping is an error that
## names the key. No private name is compiled in.
##
## Seen to fail: with a missing key returned as "" (`privateFile` skipping
## it), `missingKey` did not raise, and the message did not name "absent".

import std/[os, strutils]
import privatefiles

proc writeCfg(dir, text: string) =
  createDir(dir)
  writeFile(dir / "names.cfg", text)

block missingFolder:
  doAssert privateFile("landSegd", getTempDir() / "viewseg-no-such-private") == ""

block missingMapping:
  let dir = getTempDir() / ("viewseg-nomap-" & $getCurrentProcessId())
  createDir(dir)
  doAssert privateFile("landSegd", dir) == ""
  removeDir(dir)

block missingFile:
  let dir = getTempDir() / ("viewseg-nofile-" & $getCurrentProcessId())
  writeCfg(dir, "# a comment\n\nlandSegd = samples/land-record.sgd\n")
  doAssert privateFile("landSegd", dir) == "", "a mapped file that is not there skips"
  doAssert privateFile("landSegd", dir) == "" # the mapping is read once
  removeDir(dir)

block present:
  let dir = getTempDir() / ("viewseg-hasfile-" & $getCurrentProcessId())
  writeCfg(dir, "smallSegd = shot.sgd\n")
  writeFile(dir / "shot.sgd", "x")
  doAssert privateFile("smallSegd", dir) == dir / "shot.sgd"
  removeDir(dir)

block missingKey:
  let dir = getTempDir() / ("viewseg-nokey-" & $getCurrentProcessId())
  writeCfg(dir, "landSegd = samples/land-record.sgd\n")
  var named = ""
  try:
    discard privateFile("absent", dir)
  except ValueError as e:
    named = e.msg
  doAssert "absent" in named, "a missing key is an error that names it, not a skip: " & named
  removeDir(dir)

block badLine:
  let dir = getTempDir() / ("viewseg-badline-" & $getCurrentProcessId())
  writeCfg(dir, "not a mapping\n")
  doAssertRaises ValueError:
    discard privateFile("landSegd", dir)
  removeDir(dir)

block listed:
  let dir = getTempDir() / ("viewseg-listed-" & $getCurrentProcessId())
  writeCfg(dir, "# note\nlandSps = survey/line.sps\n")
  let names = listedNames(dir)
  doAssert names == @["survey/line.sps", "line.sps"], $names
  doAssert listedNames(getTempDir() / "viewseg-no-such-private").len == 0
  removeDir(dir)
