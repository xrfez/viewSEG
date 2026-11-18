## A folder with only subfolders lists no files, and the Files panel says why:
## "No seismic files here; 2 subfolders" (1 subfolder), instead of an empty list. A
## folder with seismic files says nothing of the kind, and hidden folders are not
## counted.
##
## "Include subfolders" (`ckSubfolders`): off by default, the list holds the top folder's
## files only; on, the seismic files of a tree three levels deep, each with the path
## below the folder listed (`folder`, "/" between), the name filter matching it; a
## symbolic link back up the tree is not followed (the listing ends); a tree over the
## cap lists up to it and says so (`treeNames`); a file that appears in a subfolder is
## listed and followed; the choice is kept in the project and survives its reopen, and
## in the settings without one.
##
## Seen to fail: with the subfolders not counted by the scan, `onlyFolders` read "";
## with `listedNames` not entering folders, "the tree listed 1 files"; with
## `treeNames` entering symbolic links to folders, the loop block never ended (watchdog).

import std/[os, strutils, times]
import viewSEG/core/[filejobs, filelist, settings, state]
import utils/[fixtures, vibfiles, waiting]

proc tree(fx: Fixtures; name: string): string =
  ## top/a.sgy, top/one/b.sgy, top/one/two/c.sgy, top/one/two/three/d.sgy, a hidden folder
  ## with a file, and a text file.
  result = fx.dir / name
  createDir(result / "one" / "two" / "three")
  createDir(result / ".hidden")
  copyFile(fx.vibPlainSegy(), result / "a.sgy")
  copyFile(fx.vibPlainSegy(), result / "one" / "b.sgy")
  copyFile(fx.vibPlainSegy(), result / "one" / "two" / "c.sgy")
  copyFile(fx.vibPlainSegy(), result / "one" / "two" / "three" / "d.sgy")
  copyFile(fx.vibPlainSegy(), result / ".hidden" / "e.sgy")
  writeFile(result / "note.txt", "not seismic")

proc names(st: AppState): seq[string] =
  for e in st.fileList.entries: result.add (if e.folder.len > 0: e.folder & "/" else: "") & e.name

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
    block offThenOn:
      let top = fx.tree("tree")
      var st = initAppState(indexCache = fx.dir / "cache")
      st.apply Command(kind: ckBrowse, paths: @[top])
      doAssert st.settle(st.fileList.title == top and not st.fileList.scanning)
      doAssert not st.includesSubfolders and st.names == @["a.sgy"], $st.names
      st.apply Command(kind: ckSubfolders, subfolders: true)
      # as the scan ends, before the watch's first look could add any
      doAssert st.settle(st.fileList.recursive and not st.fileList.scanning)
      doAssert st.fileList.entries.len == 4, "the tree listed " & $st.names
      doAssert st.names == @["a.sgy", "one/b.sgy", "one/two/c.sgy", "one/two/three/d.sgy"],
        $st.names
      doAssert st.fileList.subfoldersNote == ""
      doAssert st.fileList.entries[3].matches("three") and not st.fileList.entries[2].matches("three")
      doAssert st.fileList.entries[2].matches("c.sgy two")
      # a file that appears three levels down is listed, marked new, and followed
      var s = st.settings
      s.files.followLatest = true
      st.apply Command(kind: ckSettings, settings: s)
      createDir(top / "one" / "two" / "later")
      let late = top / "one" / "two" / "later" / "f.sgy"
      copyFile(fx.vibPlainSegy(), late)
      setLastModificationTime(late, getTime() + initDuration(seconds = 30))
      doAssert st.settle(st.fileList.find(late) >= 0 and
        st.fileList.entries[st.fileList.find(late)].folder == "one/two/later")
      doAssert st.settle(st.fileList.chosen == late), "followed " & st.fileList.chosen
      st.apply Command(kind: ckSubfolders, subfolders: false)
      doAssert st.settle(not st.fileList.recursive and not st.fileList.scanning and
        st.names == @["a.sgy"]), $st.names
      discard st.shutdown()

    block aLinkBackUp:
      let top = fx.tree("loop")
      createSymlink(top, top / "one" / "two" / "back")
      var st = initAppState()
      st.apply Command(kind: ckSubfolders, subfolders: true)
      st.apply Command(kind: ckBrowse, paths: @[top])
      doAssert st.settle(st.fileList.recursive and not st.fileList.scanning)
      doAssert st.fileList.entries.len == 4, "listed " & $st.names
      var capped = false
      let all = treeNames(top, 10, capped, proc (n: int): bool {.gcsafe, raises: [].} = true)
      doAssert not capped and all.len == 5, $all # the four, and the text file
      discard treeNames(top, 3, capped, proc (n: int): bool {.gcsafe, raises: [].} = true)
      doAssert capped
      discard st.shutdown()

    block keptInTheProject:
      let top = fx.tree("job data")
      let dir = fx.dir / "config"
      createDir(dir)
      let proj = fx.dir / "job"
      block first:
        var st = initAppState()
        st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
        st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job",
          dataFolders: @[top])
        doAssert st.settle(st.inProject)
        st.apply Command(kind: ckBrowse, paths: @[top])
        doAssert st.settle(st.fileList.folder == top and not st.fileList.scanning)
        st.apply Command(kind: ckSubfolders, subfolders: true)
        doAssert st.settle(st.fileList.recursive and not st.fileList.scanning and
          st.fileList.entries.len == 4)
        st.apply Command(kind: ckCloseProject)
        doAssert st.settle(not st.inProject)
        doAssert not st.includesSubfolders, "the project's choice went to the settings"
        discard st.shutdown()
      block reopened:
        var st = initAppState()
        st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
        st.apply Command(kind: ckOpenProject, projectPath: proj)
        doAssert st.settle(st.inProject and st.fileList.recursive and
          not st.fileList.scanning and st.fileList.entries.len == 4),
          "reopened with " & $st.names
        discard st.shutdown()

    block keptInTheSettings:
      let dir = fx.dir / "config2"
      createDir(dir)
      block first:
        var st = initAppState()
        st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
        st.apply Command(kind: ckSubfolders, subfolders: true)
        discard st.shutdown()
      doAssert loadSettings(dir / "settings.nif").settings.files.subfolders
  echo "tsubfolders: ok"

when isMainModule:
  main()
