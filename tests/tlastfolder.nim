## The folder the Files panel listed last is remembered: in the project when one is open
## (listed again when the project opens, not its first data folder), else in the user's
## settings (`recentFolders`, which the program lists again at its start and the open
## dialogs start in: `ui/imgui/app`).
##
## - in a project: browse to a folder several levels down, close the project, a new app
##   state reopens it: the Files panel lists that folder;
## - a choice made by an agent is not kept (`keeps`);
## - in the settings: the folder is the first of `recentFolders` in the saved file.
##
## Seen to fail: with the project's `lastFolder` not set, the reopened project listed its data
## folder, not the one below it.

import std/os
import viewSEG/core/[settings, state]
import utils/[fixtures, vibfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc main*() =
  withFixtures fx:
    let data = fx.dir / "data"
    let deep = data / "2026" / "11" / "day17"
    createDir(deep)
    copyFile(fx.vibPlainSegy(), deep / "a.sgy")
    let dir = fx.dir / "config"
    createDir(dir)
    let proj = fx.dir / "job"
    block inAProject:
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job",
        dataFolders: @[data])
      doAssert st.settle(st.inProject and not st.fileList.scanning)
      st.apply Command(kind: ckBrowse, paths: @[deep])
      doAssert st.settle(st.fileList.folder == deep and not st.fileList.scanning)
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      discard st.shutdown()
    block reopened:
      var st = initAppState()
      st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
      st.apply Command(kind: ckOpenProject, projectPath: proj)
      doAssert st.settle(st.inProject and st.fileList.folder == deep and
        not st.fileList.scanning), "listed " & st.fileList.folder
      doAssert st.fileList.entries.len == 1
      discard st.shutdown()
    block inTheSettings:
      let dir2 = fx.dir / "config2"
      createDir(dir2)
      var st = initAppState()
      st.keepSettingsIn(dir2, loadSettings(dir2 / "settings.nif"))
      st.apply Command(kind: ckBrowse, paths: @[deep])
      doAssert st.settle(st.fileList.folder == deep and not st.fileList.scanning)
      discard st.shutdown()
      let back = loadSettings(dir2 / "settings.nif").settings
      doAssert back.recentFolders.len > 0 and back.recentFolders[0] == deep, $back.recentFolders
  echo "tlastfolder: ok"

when isMainModule:
  main()
