## Where a Shot log grid's layout (column order, widths, hidden columns, sort) is kept.
## With a project open it is stored with the log and comes back after a close and an
## open, by column name; a log read again with the same headers gets the layout of
## the last one that had them from the settings, which also keep it for a log that is
## not stored; the settings file writes and reads it back; a column the layout does
## not know is shown at the end, one that is gone is dropped; a read-only project does
## not write it. The layout never changes the log's rows.
##
## Seen to fail: with the project's copy of the layout left unwritten, `projectReopen`
## read the default layout; with the settings not told, `sessionOnly` found the
## layout gone after the same log was imported again; with the settings writer
## leaving the layouts out, `sessionOnly` found none kept.

import std/[os, strutils]
import viewSEG/core/[filesystem, project, settings, settingsnif, shotlayout, shotlog, state]
import utils/[fixtures, waiting]

const Sample = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shotlog.csv"

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc eligibleAll(n: int): seq[bool] =
  result = newSeq[bool](n)
  for i in 0 ..< n: result[i] = true

proc layoutOf(): ShotLayout =
  ShotLayout(columns: @[ShotColumnLayout(name: "shot point", width: 12.5),
    ShotColumnLayout(name: "sequence", hidden: true)],
    sort: @[(name: "shot point", descending: true)])

proc main*() =
  withFixtures fx:
    let root = fx.dir

    block sessionOnly:
      var st = start(root / "config-a")
      st.apply Command(kind: ckImportShotLog, logPath: Sample)
      doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
      doAssert st.shotLayout(0).isDefault
      st.apply Command(kind: ckShotLayout, slogIndex: 0, slogLayout: layoutOf())
      doAssert st.shotLayout(0) == layoutOf()
      doAssert st.settings.shotLayouts.len == 1
      let rows = st.shotView(0).rows.len
      st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
      st.apply Command(kind: ckImportShotLog, logPath: Sample)
      doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
      doAssert st.shotLayout(0) == layoutOf(), "the log read again lost its layout"
      doAssert st.shotView(0).rows.len == rows
      let keys = st.shotLogKeys(0)
      let p = st.shotLayout(0).places(keys, eligibleAll(keys.len))
      doAssert p[0].col == 3 and p[0].width == 12.5'f32 and p[1].hidden
      doAssert p.len == keys.len and p[2].col == 1, "the others follow in the file's order"
      st.apply Command(kind: ckShotLayout, slogIndex: 7, slogLayout: layoutOf())
      doAssert st.shotLayout(7).isDefault
      discard st.shutdown()

    block projectReopen:
      let job = root / "JobLayout"
      var st = start(root / "config-b")
      st.apply Command(kind: ckNewProject, projectPath: job)
      doAssert st.settle(st.inProject and st.jobs.active.len == 0)
      st.apply Command(kind: ckImportShotLog, logPath: Sample)
      doAssert st.settle(st.shotLogCount == 1 and st.jobs.active.len == 0)
      st.apply Command(kind: ckShotLayout, slogIndex: 0, slogLayout: layoutOf())
      st.flushFiles()
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject and st.jobs.active.len == 0)
      # another settings folder: the project alone brings the layout back
      discard st.shutdown()
      var other = start(root / "config-c")
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject and other.shotLogCount == 1 and
        other.jobs.active.len == 0)
      doAssert other.shotLayout(0) == layoutOf(), $other.shotLayout(0)
      doAssert other.settings.shotLayouts.len == 0
      discard other.shutdown()

    block settingsFile:
      var s = Settings()
      s.shotLayouts.remember("a\x1fb", layoutOf())
      s.shotLayouts.remember("c", ShotLayout(sort: @[(name: "c", descending: false)]))
      var problems: seq[string]
      let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
      doAssert problems.len == 0, $problems
      doAssert back.shotLayouts.len == 2 and back.shotLayouts == s.shotLayouts
      doAssert back.shotLayouts.layoutFor("a\x1fb") == layoutOf()

  echo "tshotlayout: ok"

when isMainModule:
  main()
