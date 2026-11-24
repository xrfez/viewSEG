## The kind of recording of each listed file, read in the background (`startKinds`): a folder
## listed gets each file's kind (`FileEntry.recording`) without anything being opened; a file the
## watch reports as changed is read again; an answer for a file that changed since it was read,
## or for a listing replaced since, is not kept; a file whose kind is not known takes it once it
## is shown.
##
## A change of the vendor maps (a new load, or the project's choice) sends every row back to unread
## and reads again.
##
## Seen to fail with a deliberate fault: with the entry marked unread by the watch taken out
## (`if not same: e.kindState = ksUnread`), "a changed file is not asked again"; with the size
## and time of an answer not compared in `takeKinds`, "an answer for a changed file was kept";
## with `rereadKinds` taken out of `takeVendor`, "the kind did not follow the map"; out of
## `setVendorChoice`, "the kind kept the map left off"; with the kinds job on the background
## lane, "the kinds are not read on the peeks lane"; with the shown file not asked for its facts
## (`rowAsks`), "the file shown did not give its row the kind".

import std/[options, os, sequtils, times]
import viewSEG/core/state {.all.}
import viewSEG/core/[filelist, filekinds, inbox, jobs, recordingkind, vendormaps]
import utils/[fixtures, kindfiles, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc kindOf(st: AppState; path: string): Option[RecordingKind] =
  let i = st.fileList.find(canonical(path))
  doAssert i >= 0, path & " is not listed"
  st.fileList.entries[i].recordingOf

proc listed(st: AppState; n: int): bool =
  not st.fileList.scanning and st.fileList.entries.len == n

proc main*() =
  withFixtures fx:
    let dir = fx.dir / "folder"
    let cont = writeSpecs(dir, "a", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    let sliced = writeSpecs(dir, "b", [spec(0, 0), spec(0, 1000), spec(0, 2150), spec(0, 3150)])
    let shot = writeSpecs(dir, "c", [spec(0, 0), spec(1, 0), spec(2, 0)])
    var st = initAppState()

    block listedFilesGetTheirKinds:
      st.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert st.settle(st.listed(3) and st.jobs.list.allIt(it.state notin {jsQueued,
          jsRunning}) and
        st.fileList.entries.allIt(it.kindState != ksUnread)), "the kinds were not read"
      doAssert st.kindOf(cont) == some(rkReceiverContinuous)
      doAssert st.kindOf(sliced) == some(rkReceiverSliced)
      doAssert st.kindOf(shot) == some(rkShotGather)
      doAssert st.sessions.len == 0, "reading the kinds opened a file"
      let reading = st.jobs.list.filterIt(it.spec.title == "Read what the files are")
      doAssert reading.len > 0 and reading.allIt(it.spec.lane == jlPeeks),
        "the kinds are not read on the peeks lane: " & $reading.mapIt(it.spec.lane)

    block aChangedFileIsReadAgain:
      # the continuous file is written again with a late start: time sliced
      discard writeSpecs(dir, "a", [spec(0, 0), spec(0, 1000), spec(0, 2150), spec(0, 3150),
        spec(0, 4150)])
      let info = getFileInfo(cont)
      st.mailbox.post Msg(kind: mkWatched, watchGen: st.fileList.gen, watched: @[WatchedFile(
        path: canonical(cont), exists: true, kind: fkSegd, size: info.size,
        modified: info.lastWriteTime + initDuration(seconds = 5), listed: true)])
      discard st.drainInbox()
      doAssert st.kindOf(cont).isNone, "a changed file is not asked again"
      doAssert st.settle(st.kindOf(cont) == some(rkReceiverSliced)),
        "the changed file kept its old kind"

    block anAnswerForAChangedFileIsNotKept:
      let i = st.fileList.find(canonical(shot))
      st.mailbox.post Msg(kind: mkKinds, kindsGen: st.fileList.gen,
        kindsVendors: st.vendorGen, kinds: @[KindAnswer(
        path: canonical(shot), size: st.fileList.entries[i].size + 1,
        modified: st.fileList.entries[i].modified, state: ksKnown,
        kind: rkReceiverContinuous)])
      discard st.drainInbox()
      doAssert st.kindOf(shot) == some(rkShotGather), "an answer for a changed file was kept"

    block anAnswerForAnotherListingIsNotKept:
      let i = st.fileList.find(canonical(shot))
      st.mailbox.post Msg(kind: mkKinds, kindsGen: st.fileList.gen + 7,
        kindsVendors: st.vendorGen, kinds: @[KindAnswer(
        path: canonical(shot), size: st.fileList.entries[i].size,
        modified: st.fileList.entries[i].modified, state: ksKnown,
        kind: rkReceiverContinuous)])
      discard st.drainInbox()
      doAssert st.kindOf(shot) == some(rkShotGather), "an answer for another listing was kept"

    block aFileNotKnownTakesItsKindWhenItIsShown:
      # a file whose start did not tell its kind (posted so: the probe's cap is 16 MiB): once the
      # file is open and shown, its row takes the kind of the facts of the whole file
      let i = st.fileList.find(canonical(sliced))
      st.mailbox.post Msg(kind: mkKinds, kindsGen: st.fileList.gen,
        kindsVendors: st.vendorGen, kinds: @[KindAnswer(
        path: canonical(sliced), size: st.fileList.entries[i].size,
        modified: st.fileList.entries[i].modified, state: ksNotKnown)])
      discard st.drainInbox()
      doAssert st.fileList.entries[i].kindState == ksNotKnown and st.kindOf(sliced).isNone
      st.apply Command(kind: ckOpen, paths: @[sliced])
      doAssert st.settle((st.watchRecording(false); st.kindOf(sliced).isSome)),
        "the file shown did not give its row the kind"
      doAssert st.kindOf(sliced) == some(rkReceiverSliced)

    block aNewListingStopsTheReading:
      let other = fx.dir / "other"
      let o = writeSpecs(other, "z", [spec(0, 0), spec(1, 0)])
      st.apply Command(kind: ckBrowse, paths: @[other])
      doAssert st.settle(st.listed(1) and st.jobs.list.allIt(it.state notin {jsQueued,
          jsRunning}) and st.kindOf(o).isSome)
      doAssert st.fileList.find(canonical(cont)) < 0
      doAssert st.kindOf(o) == some(rkShotGather)
    st.shutdown()

    block aVendorMapChangesWhatTheKindsAre:
      # the start times of this file live in a vendor block: without the map every trace is
      # its own receiver and the file is no continuous recording; with it, it is one
      let folder = fx.dir / "clocked"
      var raw: seq[int64] = @[]
      for i in 0 ..< ClockSegments: raw.add clockStart(i)
      createDir(folder)
      let path = folder / "clock.sgd"
      writeClockRecording(path, raw)
      discard clockRegistry(fx.dir / "clockmaps") # writes the map
      var v = initAppState()
      v.setVendorFolders(@[])
      doAssert v.settle(v.vendorGen == 1)
      v.apply Command(kind: ckBrowse, paths: @[folder])
      doAssert v.settle(v.listed(1) and v.kindOf(path).isSome), "the kind was not read"
      doAssert v.kindOf(path) != some(rkReceiverContinuous), $v.kindOf(path)
      v.setVendorFolders(@[VendorFolder(dir: fx.dir / "clockmaps", origin: voUser)])
      discard v.drainInbox()
      doAssert v.settle(v.vendorGen == 2 and v.kindOf(path) == some(rkReceiverContinuous)),
        "the kind did not follow the map: " & $v.kindOf(path)
      # the other way: a map taken away
      v.setVendorFolders(@[])
      doAssert v.settle(v.vendorGen == 3 and v.kindOf(path).isSome and
        v.kindOf(path) != some(rkReceiverContinuous)), "the kind kept the map taken away"
      v.shutdown()

    block theProjectsVendorChoiceChangesWhatTheKindsAre:
      let folder = fx.dir / "clocked"
      var v = initAppState()
      v.rememberFilesIn(fx.dir / "config")
      v.setVendorFolders(@[VendorFolder(dir: fx.dir / "clockmaps", origin: voUser)])
      doAssert v.settle(v.vendorGen == 1)
      v.apply Command(kind: ckNewProject, projectPath: fx.dir / "kindjob", dataFolders: @[])
      doAssert v.settle(v.inProject and v.projectOpening.len == 0)
      v.apply Command(kind: ckBrowse, paths: @[folder])
      let path = folder / "clock.sgd"
      doAssert v.settle(v.listed(1) and v.kindOf(path) == some(rkReceiverContinuous))
      let gen = v.vendorGen
      v.apply Command(kind: ckVendorMap, vendorMap: "none")
      doAssert v.settle(v.vendorGen > gen and v.kindOf(path).isSome and
        v.kindOf(path) != some(rkReceiverContinuous)), "the kind kept the map left off"
      v.apply Command(kind: ckVendorMap, vendorMap: "automatic")
      doAssert v.settle(v.kindOf(path) == some(rkReceiverContinuous)),
        "the kind did not return with the map"
      v.flushFiles()
      v.shutdown()

when isMainModule:
  main()
