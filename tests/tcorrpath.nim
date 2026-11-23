## A derived session's path is a virtual key, not a file on disk.
##
## Seen to fail: with the key's trailing NUL omitted, "the virtual key can end
## a file name" (a file system allows that ending). With only a trailing NUL,
## "a C string of the key names the file on disk". With `asDerived` stating
## the key (`fs.fileExists`), "fs was asked to stat the virtual path".

import std/[os, strutils]
import parseSEG
import viewSEG/core/[filesystem, session]
import utils/fixtures

var
  forbidden = ""
  hits = 0
  seen: seq[string] = @[]

proc note(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    inc hits
    if forbidden.len > 0 and (path == forbidden or '\0' in path):
      seen.add $op & " " & path

proc main*() =
  block key_cannot_be_a_file:
    let raw = "/tmp/raw-record.segy"
    let key = correlatedPath(raw)
    doAssert key != raw
    doAssert correlatedPath(raw) == key, "the key is not stable for the file"
    doAssert key[^1] == '\0', "the virtual key can end a file name"
    doAssert $cstring(key) != raw, "a C string of the key names the file on disk"
    doAssert '\0' notin ($cstring(key))

  block derived_session_keeps_the_disk_path:
    setFsHook(note)
    withFixtures fx:
      let raw = fx.oneTraceSegy()
      forbidden = correlatedPath(raw)
      var file = openSeismic(raw, keys = true)
      let s = newSession(raw, file)
      doAssert not s.derived
      doAssert s.origin.len == 0
      doAssert s.diskPath == raw
      doAssert s.path == raw
      s.asDerived()
      doAssert s.derived
      doAssert s.origin == raw
      doAssert s.diskPath == raw
      doAssert s.path == forbidden
      doAssert s.path != raw
      doAssert s.name == raw.extractFilename, "the name carries the virtual key: " & s.name
      doAssert '\0' notin s.name
      s.asDerived()
      doAssert s.origin == raw, "a second bind replaced the origin"
      doAssert s.path == forbidden, "a second bind changed the key"
    doAssert hits > 0, "the file-system hook saw no call"
    doAssert seen.len == 0, "fs was asked to stat the virtual path: " & strutils.join(seen, "; ")
    setFsHook(nil)

  echo "tcorrpath: ok"

when isMainModule: main()
