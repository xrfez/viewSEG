## The files the viewer lets go of are closed, on the closer's thread
## (`core/closer`): stepping through a folder's files, each file stepped
## away from is unmapped and its descriptor closed once its close job has
## run, so the files open stay one however many are stepped through; the
## quit closes the last.
##
## Seen to fail: with the closer's thread taking each file in place under
## its lock (`s = move files[0]` inside `withLock`, then `s = nil`), which
## Nim 2.4 compiles as a plain store, no file was ever closed: "step0.sgy is
## still mapped" after its close, and every file stepped through stayed
## mapped and open to the end of the run.
##
## Linux only: it reads the process's maps and descriptors in /proc.

import std/[os, strutils]
import viewSEG/core/state
import utils/[fixtures, waiting]

when not defined(linux):
  echo "tcloser: skipped (reads /proc/self)"
else:
  template settle(st: var AppState; cond: untyped): bool =
    waitUntil((discard st.drainInbox(); cond))

  proc mapped(path: string): bool =
    ## Whether the process maps `path` now.
    for line in readFile("/proc/self/maps").splitLines:
      if line.endsWith(path): return true
    false

  proc descriptors(dir: string): int =
    ## How many descriptors the process has open on files in `dir`.
    for kind, fd in walkDir("/proc/self/fd"):
      try:
        if expandSymlink(fd).startsWith(dir): inc result
      except OSError:
        discard # closed meanwhile

  withFixtures fx:
    let dir = fx.dir / "folder"
    createDir(dir)
    const Files = 6
    for i in 0 ..< Files:
      copyFile(fx.surveySegy, dir / ("step" & $i & ".sgy"))
    var st = initAppState()
    var s = st.settings
    s.files.prepareNext = false # only the file shown is open
    st.apply Command(kind: ckSettings, settings: s)
    for i in 0 ..< Files:
      let path = dir / ("step" & $i & ".sgy")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == path and
        st.panel(MainPanel).laidOut), "step" & $i & ".sgy shown"
      doAssert mapped(path)
      if i > 0:
        let before = dir / ("step" & $(i - 1) & ".sgy")
        doAssert st.settle(not mapped(before)), before.extractFilename &
          " is still mapped after its close"
      doAssert st.settle(descriptors(dir) <= 1), "descriptors open on the folder's files: " &
        $descriptors(dir)
    discard st.shutdown()
    doAssert not mapped(dir / ("step" & $(Files - 1) & ".sgy")), "the quit closes the last file"
    echo "tcloser: ", Files, " files stepped through, one open at a time"
