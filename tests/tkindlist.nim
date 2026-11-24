## The kind of recording of each listed file, read in the background (`startKinds`): a folder
## listed gets each file's kind (`FileEntry.recording`) without anything being opened; a file the
## watch reports as changed is read again; an answer for a file that changed since it was read,
## or for a listing replaced since, is not kept.
##
## Seen to fail with a deliberate fault: with the entry marked unread by the watch taken out
## (`if not same: e.kindState = ksUnread`), "a changed file is not asked again"; with the size
## and time of an answer not compared in `takeKinds`, "an answer for a changed file was kept".

import std/[options, os, sequtils, times]
import viewSEG/core/state {.all.}
import viewSEG/core/[filelist, filekinds, inbox, jobs, recordingkind]
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
      st.mailbox.post Msg(kind: mkKinds, kindsGen: st.fileList.gen, kinds: @[KindAnswer(
        path: canonical(shot), size: st.fileList.entries[i].size + 1,
        modified: st.fileList.entries[i].modified, kind: some(rkReceiverContinuous))])
      discard st.drainInbox()
      doAssert st.kindOf(shot) == some(rkShotGather), "an answer for a changed file was kept"

    block anAnswerForAnotherListingIsNotKept:
      let i = st.fileList.find(canonical(shot))
      st.mailbox.post Msg(kind: mkKinds, kindsGen: st.fileList.gen + 7, kinds: @[KindAnswer(
        path: canonical(shot), size: st.fileList.entries[i].size,
        modified: st.fileList.entries[i].modified, kind: some(rkReceiverContinuous))])
      discard st.drainInbox()
      doAssert st.kindOf(shot) == some(rkShotGather), "an answer for another listing was kept"

    block aNewListingStopsTheReading:
      let other = fx.dir / "other"
      let o = writeSpecs(other, "z", [spec(0, 0), spec(1, 0)])
      st.apply Command(kind: ckBrowse, paths: @[other])
      doAssert st.settle(st.listed(1) and st.jobs.list.allIt(it.state notin {jsQueued,
          jsRunning}) and st.kindOf(o).isSome)
      doAssert st.fileList.find(canonical(cont)) < 0
      doAssert st.kindOf(o) == some(rkShotGather)
    st.shutdown()

when isMainModule:
  main()
