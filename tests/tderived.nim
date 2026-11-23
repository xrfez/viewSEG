## A derived session is shown and closed without the file system seeing its key.
##
## The raw file is opened, then an in-memory copy is bound with `asDerived`
## and shown in its place. The reader lays the panel out, the watch looks at
## the open files, and stepping to another file closes the derived view and
## the raw file.
##
## Seen to fail: with the watch or a reader handed the virtual key, "fs was
## asked about the virtual path".

import std/[locks, monotimes, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[filesystem, state]
import utils/[fixtures, waiting]

var
  guard: Lock
  armed = false
  forbidden = ""
  seen: seq[string]

proc note(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if not armed: return
  {.cast(gcsafe).}:
    withLock guard:
      if forbidden.len > 0 and (path == forbidden or '\0' in path):
        seen.add $op & " " & path

proc bytesOf(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc main*() =
  initLock guard
  withFixtures fx:
    let raw = fx.oneTraceSegy()
    let other = fx.surveySegy()
    forbidden = correlatedPath(raw)
    var st = initAppState(watchEvery = initDuration(milliseconds = 20))
    var settings = st.settings
    settings.files.prepareNext = false
    st.apply Command(kind: ckSettings, settings: settings)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
    doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == raw and
      st.panel(MainPanel).laidOut), "the raw file was not shown"
    setFsHook(note)
    armed = true
    var copy = openSeismicBytes(bytesOf(raw), "correlated copy", keys = true)
    doAssert copy.inMemory
    let derived = newSession(raw, copy)
    derived.asDerived()
    doAssert derived.path == forbidden
    doAssert derived.diskPath == raw
    st.adoptDerived(derived)
    let shown = st.shownFile(st.findPanel(MainPanel))
    doAssert shown >= 0 and st.sessions[shown].derived, "the derived view was not shown"
    doAssert st.sessions.anyIt(not it.derived and it.path == raw), "the raw file was closed"
    doAssert st.fileList.chosen == raw, "the chosen file is not the file on disk"
    doAssert forbidden notin st.settings.recentFiles, "the virtual key was remembered"
    let since = getMonoTime()
    doAssert st.settle(st.panel(MainPanel).laidOut and st.jobs.active.len == 0 and
      getMonoTime() - since > initDuration(milliseconds = 80)),
      "the derived view was not laid out"
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == other and
      st.jobs.active.len == 0 and not st.sessions.anyIt(it.derived)),
      "the derived view was still open"
    discard st.shutdown()
    doAssert seen.len == 0, "fs was asked about the virtual path: " & seen.join("; ")
  setFsHook(nil)
  armed = false
  echo "tderived: ok"

when isMainModule: main()
