## What is remembered about a file, with large lists: a million traces
## killed one in two (a document of about 7.5 MB) is handed to the disk
## thread without its document being made on the caller's thread, and reads
## back whole from the store; a file's list of a million rows as CSV (about
## 25 MB) is imported, read and taken apart off the UI thread, so no frame
## that takes it in is held; the traces past the file's last are said and
## left out.
##
## Seen to fail: with the document made by the caller (`memoryDocument` in
## `replace`, as `writeMemoryDoc` did before), "handing the document over
## took 300 ms" (a debug build; 72 ms in a release build); with the store's
## documents and the lists imported read within NIF's 4 MB
## (`MaxMemoryBytes`), "200000000-000000000000feed-1.nif is larger than 4
## MB". (The CSV of a million rows took 505 ms to take apart in a release
## build, on the UI thread before: `takeImported`.)
##
## Runs alone: it bounds the time a call and a frame take (20 and 25 ms).

import std/[monotimes, os, strutils, times]
import viewSEG/core/[diskio, inbox, state]
import utils/[fixtures, owntime, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc main*() =

  let tmp = getTempDir() / ("viewseg_tmemorylarge_" & $getCurrentProcessId())
  removeDir(tmp)
  createDir(tmp)

  block millionScattered:
    let box = initInbox()
    var d = newDiskIo(box.poster)
    let id = FileIdentity(size: 1 shl 33, quick: 0xfeed'u64, full: 7, fullKnown: true)
    var r = FileRecord(identity: id, name: "big.sgy", path: tmp / "big.sgy", doc: docName(id, 1))
    for i in 0 ..< 1_000_000: r.edits.lists[teKilled].add 2 * i
    let want = r.edits
    let store = Store(home: tmp / StoreFolder)
    let t0 = ownTime()
    d.replace(store.docPath(r.doc), r, "what is remembered about big.sgy")
    let took = ownTime() - t0
    doAssert took < initDuration(milliseconds = 20),
      "handing the document over took " & $took.inMilliseconds & " ms"
    d.flush()
    doAssert getFileSize(store.docPath(r.doc)) > 4 shl 20, "not a large document"
    var problems: seq[string]
    let back = readMemoryFile(store.docPath(r.doc), problems)
    doAssert problems.len == 0, $problems
    doAssert back.edits == want, "the large document did not read back whole"

  block millionRowsImported:
    withFixtures fx:
      let a = fx.surveySegy()
      var st = initAppState()
      st.rememberFilesIn(fx.dir / "config")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      let n = st.sessions[0].len
      var csv = CsvHeader & "\n"
      for i in 0 ..< 1_000_000: csv.add $(2 * i + 1) & ",1234,567,killed,big.sgy\n"
      let list = fx.dir / "big.csv"
      writeFile(list, csv)
      st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: list)
      var longest = Duration()
      proc logText(st: AppState): string =
        for e in st.log: result.add e.text & "\n"
      doAssert waitUntil((
        let t0 = ownTime()
        discard st.drainInbox()
        longest = max(longest, ownTime() - t0)
        not st.editsOf(0).isEmpty or "Cannot import" in st.logText), initDuration(seconds = 60))
      let said = st.logText
      doAssert not st.editsOf(0).isEmpty, said
      doAssert st.editsOf(0).len(teKilled) == (n + 1) div 2, $st.editsOf(0).len(teKilled)
      doAssert "past the last trace" in said, said
      doAssert longest < initDuration(milliseconds = 25),
        "taking in the import held a frame " & $longest.inMilliseconds & " ms"
      st.shutdown()

  removeDir(tmp)
  echo "tmemorylarge: ok"

when isMainModule:
  main()
