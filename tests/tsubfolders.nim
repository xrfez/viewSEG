## A folder with only subfolders lists no files, and the Files panel says why:
## "No seismic files here; 2 subfolders" (1 subfolder), instead of an empty list. A
## folder with seismic files says nothing of the kind, and hidden folders are not
## counted.
##
## Seen to fail: with the subfolders not counted by the scan, `onlyFolders` read "".

import std/os
import viewSEG/core/[filelist, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main*() =
  withFixtures fx:
    let top = fx.dir / "top"
    createDir(top / "day1")
    createDir(top / "day2")
    createDir(top / ".hidden")
    var st = initAppState()
    st.apply Command(kind: ckBrowse, paths: @[top])
    doAssert st.settle(st.fileList.title == top and not st.fileList.scanning)
    doAssert st.fileList.entries.len == 0
    doAssert st.fileList.subfolders == 2, $st.fileList.subfolders
    doAssert st.fileList.subfoldersNote == "No seismic files here; 2 subfolders",
      st.fileList.subfoldersNote
    removeDir(top / "day2")
    st.apply Command(kind: ckBrowse, paths: @[top])
    doAssert st.settle(st.fileList.title == top and not st.fileList.scanning and
      st.fileList.subfolders == 1)
    doAssert st.fileList.subfoldersNote == "No seismic files here; 1 subfolder"
    copyFile(fx.vibPlainSegy(), top / "a.sgy")
    st.apply Command(kind: ckBrowse, paths: @[top])
    doAssert st.settle(st.fileList.title == top and not st.fileList.scanning and
      st.fileList.entries.len == 1)
    doAssert st.fileList.subfoldersNote == ""
    discard st.shutdown()
  echo "tsubfolders: ok"

when isMainModule:
  main()
