## What is remembered about a file, through `core/state` with a store
## (`rememberFilesIn`), run after run (each run an `AppState` of its own,
## shut down as at a quit):
##
## - a trace killed, one reversed and the polarity of all traces reversed
##   by the user, and one killed by an agent; the program quits; the file is
##   renamed; the next run opens it under its new name: the user's three
##   edits are back at once (the file's size, first and last 64 KiB and
##   modification time are those remembered), the agent's is not, the plot
##   is reversed as a whole, the history is empty (it is the session's), and
##   the hash of every byte confirms it; the document names the new name;
## - a copy with one byte changed in the middle of a trace is another file:
##   nothing is brought back, also when its modification time is made the
##   same (then what came at once is taken away again when the hash says
##   it is another file, with a warning);
## - edits taken away to nothing remove the document; Ctrl+Z writes it
##   again;
## - a file's list exported as CSV (trace, record, channel, edit) and as
##   NIF, never over the data file, and each imported again as one step; a
##   table without a trace column refused;
## - a file whose drive does not answer when its identity is read: the plot
##   opens and draws, and the edits come once the drive answers;
## - a copy (a time of its own) edited before the hash of every byte comes
##   gets what is remembered of the file all the same, in one document;
## - edits made while the drive does not answer are said to wait for the
##   file's identity, kept by the file's path at a quit before it came; the
##   next run does not apply them by themselves (the path says nothing of the
##   content): they are offered as an unconfirmed record, applied only by the
##   user's click (one step, Undo takes it back); kept so for a file that
##   changed since, they are said and not applied;
## - a document that cannot be read is said and never written over;
## - a document with a part that cannot be read keeps the time its file was
##   opened beside it, and File memory lists that time;
## - a user's edit while the hash is under way, on a file taken at once for
##   one remembered, is kept apart in a record of its own (unconfirmed) and
##   never written into that file's document; when the hash says it was
##   another file, the brought-back edits are taken off and the user's own
##   stay as this file's; edits made after the hash agrees (also by two
##   programs, or under two paths) join the record and its one document;
## - a document with a part that cannot be read is not written again when
##   its hash agrees either;
## - a file's hash under way holds no background job (a lane of its own);
## - File memory lists past an entry whose drive does not answer, which is
##   "not answering" and never gone;
## - a file rewritten in the middle while its hash runs is not confirmed;
## - an export leaves out an agent's kill (for the session only), and says so;
## - two programs writing one file's document: neither drops the other's
##   edits, and each shows the other's;
## - one file opened under three paths (itself, a symbolic link, a copy)
##   has one set of edits, the kills made under each kept, in one document;
## - a kill taken back in the second before a silent drive answers stays
##   taken back (this run's pending document is older than what it shows);
##   an earlier run's pending document, its drive silent in this run too,
##   is kept beside this run's edits, never written over;
## - what is remembered forgotten (File memory), then the same trace killed
##   again: the new kill is kept and shown;
## - another program in the middle of its write of the document (it holds
##   the store's lock): this one's write waits for it, then merges;
## - the data file's bytes and modification time are as they were through
##   all of it, what is remembered of it forgotten (File memory) included.
##
## Seen to fail: with `applyRecord` not called for a document whose time
## matches (only after the hash), "the edits came at once" (they came only
## with the hash); with the kept lists written from what is shown,
## "the agent's kill was remembered"; with `takeHashed` not looking at the
## full hash of what it brought back, "the changed copy shows the edits
## of the file it was copied from"; with `takeHashed` not writing back
## the other file's document as it was brought, "the other file's document
## keeps what was written of the changed copy"; with no word of edits that
## wait for the file's identity, "an edit that waits for the file's
## identity is not said"; with no pending document written (as before),
## "the edits kept by the path are not said at the quit"; with it not read
## at the next identification, "the edits made before the identity was known are
## not offered"; with `takePending` making the record confirmed (`unconfirmed:
## false`), the same block ("the edits made before the identity was known are
## not offered"); with `writeMemoryDoc` not routing a check to
## `writeProvisional`, "the user's own edit is not kept in a record of its
## own"; with `takeHashed` rewriting a document with parts it cannot read when
## its hash agrees (no `damaged` check), "the damaged document was written";
## with the names of documents that could not be read left out of those
## taken (`Remembered.taken`), "the document that could not be read was
## written over"; with no side file for a damaged document, "a file opened
## in the run before is listed as opened months ago"; with the hash of every
## byte writing its document again (for the hash), "the damaged document was
## written"; with `takeHashed` looking at what waited only when the
## file had no document yet, "what is remembered for the file did not come
## to its copy edited before the hash"; with the hash's after-check on the
## size and the ends only, "a file changed in the middle while it was
## hashed was confirmed"; with the hash on the background lane, "a
## background job waits behind a file's hash"; with the files looked at in
## the listing's job, "the listing waits for a drive that does not answer";
## with the edits shown exported, "the export holds the agent's kill"; with
## the edits kept by path (`keyOf` the path itself), "the link does not share
## the edits"; with `link` merging what a path only brought back from the
## document, "a kill taken back came back with the link"; with the disk
## thread writing over another program's change (no `mergeOthers`), "a write
## dropped the other's edit"; with `takePending` taking in a pending
## document this run wrote, "the kill taken back came back from the pending
## document"; with the pending document written over (not merged), "the
## earlier run's pending edit is not shown beside this run's"; with a plain
## removal leaving the disk thread's stamp of the document (`written`), "the
## kill made after the forgetting is gone"; with no lock between programs
## (`lockStore`), "this program wrote while the other held the lock".

import std/[atomics, os, sequtils, strutils, times]
import viewSEG/core/[diskio, filesystem, jobs, state]
import utils/[faultyfs, fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond)) # as a frame does

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and not p.pending.isEmpty and st.tiles(0).len > 0 and
    st.tiles(0)[^1].request == p.pending

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path
  st.apply Command(kind: ckView, panel: MainPanel,
    view: fitAll(st.panel(MainPanel).layout, 640, 480))
  doAssert st.settle(st.answered), "not drawn: " & path

proc base(st: AppState): int = st.sessions[^1].base

proc edit(st: var AppState; edit: TraceEdit; trace: int; by = coWindow) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: edit, edited: @[st.base + trace],
    on: true, origin: by)

proc docs(config: string): seq[string] =
  if dirExists(config / StoreFolder):
    for kind, p in walkDir(config / StoreFolder):
      if kind == pcFile: result.add p

proc lastWarning(st: AppState): string =
  for e in st.log:
    if e.severity == sevWarning: result = e.text

proc lastError(st: AppState): string =
  for e in st.log:
    if e.severity == sevError: result = e.text

proc quiet(st: AppState): bool =
  ## Nothing said of the identity's and the hash's jobs ending.
  for e in st.log:
    if e.source == "jobs": return false
  true
var locking, unlocking: Gate

proc holdStoreLock(path: string) {.thread.} =
  ## Another program in the middle of a write: it holds the store's lock
  ## until `unlocking` opens.
  var l = fs.lockFile(path, initDuration(seconds = 1))
  doAssert l.locked
  locking.open()
  doAssert waitUntil(unlocking.isOpen)
  fs.unlock(l)

proc main*() =

  var backgroundRan: Atomic[bool]

  install()
  installSteps()
  withFixtures fx:
    let config = fx.dir / "config"
    let a = fx.surveySegy()
    # a whole second, so that a copy can be given exactly its time (`utimes`)
    setLastModificationTime(a, initTime(getLastModificationTime(a).toUnix - 60, 0))
    let kept = (readFile(a), getLastModificationTime(a))
    block firstRun:
      var st = start(config)
      st.showFile(a)
      doAssert st.settle(st.remembering(a).known)
      doAssert st.remembering(a).doc == "" and st.editsOf(0).isEmpty
      st.edit(teKilled, 3)
      st.edit(teReversed, 5)
      st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
      st.edit(teKilled, 7, by = coAgent)
      doAssert st.panel(MainPanel).layers[0].reversed and st.editsOf(0).has(teKilled, 7)
      doAssert st.settle(st.remembering(a).confirmed)
      st.shutdown()
      let d = docs(config)
      doAssert d.len == 1, $d
      let text = readFile(d[0])
      doAssert "(killed \"4\")" in text, "the agent's kill was remembered: " & text
      doAssert "(reversed \"6\")" in text and "(allReversed true)" in text and "full" in text, text
    let b = fx.dir / "renamed.sgy"
    moveFile(a, b)
    block renamed:
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known)
      doAssert st.editsOf(0).has(teKilled, 3) and st.editsOf(0).has(teReversed, 5),
        "the edits came at once"
      doAssert not st.editsOf(0).has(teKilled, 7), "the agent's kill came back"
      doAssert st.editsOf(0).allReversed and st.panel(MainPanel).layers[0].reversed
      doAssert not st.editsOf(0).canUndo, "the history is the session's"
      doAssert st.settle(st.answered)
      let t = st.tiles(0)[^1]
      doAssert t.isKilled(t.traces.find(3)), "the tile does not draw the kill"
      doAssert st.settle(st.remembering(b).confirmed and not st.remembering(b).looking)
      doAssert st.editsOf(0).has(teKilled, 3), "the hash took the edits away"
      st.shutdown()
      let text = readFile(docs(config)[0])
      doAssert "renamed.sgy" in text and "survey-" notin text, text
    doAssert (readFile(b), getLastModificationTime(b)) == kept, "the data file changed"
    block changedCopy:
      var bytes = readFile(b)
      let at = bytes.len div 2
      bytes[at] = char(ord(bytes[at]) xor 0x10)
      let c = fx.dir / "changed.sgy"
      writeFile(c, bytes)
      var st = start(config)
      st.showFile(c)
      doAssert st.settle(st.remembering(c).confirmed and not st.remembering(c).looking)
      doAssert st.editsOf(0).isEmpty, "the changed copy shows the edits of the file it was " &
        "copied from"
      st.shutdown()
      # the same, with the time of the file it was copied from: at once, then taken away
      let c2 = fx.dir / "changed-same-time.sgy"
      writeFile(c2, bytes)
      setLastModificationTime(c2, kept[1])
      let docBeforePath = docs(config)[0]
      let docBefore = readFile(docBeforePath)
      st = start(config)
      holdStep("reading every byte") # a large file: its hash comes later
      st.showFile(c2)
      doAssert st.settle(st.remembering(c2).known)
      doAssert st.editsOf(0).has(teKilled, 3), "a file of the same size, ends and time is " &
        "taken for the file at once"
      st.edit(teKilled, 9) # the user's, while the hash is under way: kept apart
      st.flushFiles()
      doAssert docs(config).len == 2, "the user's own edit is not kept in a record of its own"
      doAssert readFile(docBeforePath) == docBefore,
        "the brought-back document holds the edit made on the other file"
      doAssert docs(config).anyIt("changed-same-time" in readFile(it) and "unconfirmed" in readFile(it)),
        "the own record is not marked unconfirmed"
      releaseStep("reading every byte")
      doAssert st.settle(st.remembering(c2).confirmed and not st.remembering(c2).looking)
      doAssert st.editsOf(0).has(teKilled, 9) and not st.editsOf(0).has(teKilled, 3) and
        not st.panel(MainPanel).layers[0].reversed,
        "the brought-back edits stay, or the user's own were taken away, when the content differs"
      doAssert "its content differs" in st.lastWarning, st.lastWarning
      doAssert st.quiet, "the jobs of what is remembered were said to end"
      st.shutdown()
      doAssert docs(config).len == 2, "the changed copy has its own record only: " & $docs(config)
      doAssert readFile(docBeforePath) == docBefore, "the other file's document keeps what " &
        "was written of the changed copy: " & readFile(docBeforePath)
      for f in docs(config): # the copy's own record is the file's now: not for later blocks
        if f != docBeforePath: removeFile(f)
    block clearedAndBack:
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3))
      # while the hash is under way, what is taken off is the user's own state,
      # kept apart as an unconfirmed record: the brought-back document stands
      doAssert st.settle(st.remembering(b).confirmed and not st.remembering(b).looking)
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      st.flushFiles()
      doAssert docs(config).len == 0, "a document that keeps nothing is removed"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      st.flushFiles()
      doAssert docs(config).len == 1, "the undo did not write it again"
      st.shutdown()
    block exportAndImport:
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3))
      let csv = fx.dir / "list.csv"
      let nif = fx.dir / "list.nif"
      st.apply Command(kind: ckExportEdits, panel: MainPanel, listPath: csv)
      st.apply Command(kind: ckExportEdits, panel: MainPanel, listPath: nif)
      st.apply Command(kind: ckExportEdits, panel: MainPanel, listPath: b)
      doAssert "never writes over" in st.lastWarning, st.lastWarning
      doAssert st.settle(fileExists(csv) and fileExists(nif))
      let text = readFile(csv)
      doAssert text.startsWith(CsvHeader & "\nall,,,reversed,renamed.sgy\n" &
        "4,11,4,killed,renamed.sgy\n6,11,6,reversed,renamed.sgy\n"), text
      doAssert "(killed \"4\")" in readFile(nif) and "renamed.sgy" in readFile(nif)
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      for list in [csv, nif]:
        st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: list)
        doAssert st.settle(st.editsOf(0).has(teKilled, 3)), "not imported: " & list
        doAssert st.editsOf(0).has(teReversed, 5) and st.editsOf(0).allReversed and
          st.panel(MainPanel).layers[0].reversed
        doAssert "3 edits imported from " & list.extractFilename in describe(st.editsOf(0).nextUndo)
        st.apply Command(kind: ckUndoEdit, panel: MainPanel)
        doAssert st.editsOf(0).isEmpty, "the import is not one step"
      writeFile(fx.dir / "bad.csv", "station,edit\n1,kill\n")
      st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: fx.dir / "bad.csv")
      doAssert st.settle("Cannot import" in st.lastError), st.lastError
      st.apply Command(kind: ckUndoEdit, panel: MainPanel) # the clear: as before
      doAssert st.editsOf(0).has(teKilled, 3)
      st.shutdown()
    block driveDoesNotAnswer:
      var st = start(config)
      holdStep("reading its first and last bytes")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: b)
      doAssert waitUntil((discard st.drainInbox(); inStep("reading its first and last bytes").len == 1))
      doAssert st.settle(st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckView, panel: MainPanel,
        view: fitAll(st.panel(MainPanel).layout, 640, 480))
      fault(b, fkHang, {foOpen, foRead})
      releaseStep("reading its first and last bytes")
      doAssert waitUntil(hung() == 1), "the identity's read does not hang"
      doAssert st.settle(st.answered and st.tiles(0).len > 0), "the plot waits for the identity"
      doAssert not st.remembering(b).known and st.editsOf(0).isEmpty
      release(b)
      doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3)),
        "the edits did not come once the drive answered"
      st.shutdown()
    block copyEditedBeforeHash:
      # a copy of the file (a time of its own, so what is remembered waits for
      # the hash of every byte), edited before that hash comes: the edits
      # remembered for the file come all the same, beside the new one, in one
      # document
      let c = fx.dir / "copy.sgy"
      writeFile(c, readFile(b))
      var st = start(config)
      holdStep("reading every byte")
      st.showFile(c)
      doAssert st.settle(st.remembering(c).known)
      doAssert st.editsOf(0).isEmpty, "a copy with a time of its own waits for the hash"
      st.edit(teKilled, 9)
      st.flushFiles()
      doAssert docs(config).len == 2 # the edit's own, for now
      releaseStep("reading every byte")
      doAssert st.settle(st.remembering(c).confirmed and not st.remembering(c).looking)
      doAssert st.editsOf(0).has(teKilled, 9) and st.editsOf(0).has(teKilled, 3),
        "what is remembered for the file did not come to its copy edited before the hash"
      st.flushFiles()
      let d = docs(config)
      doAssert d.len == 1, "two documents for one file: " & $d
      doAssert "(killed \"4 10\")" in readFile(d[0]), readFile(d[0])
      st.apply Command(kind: ckUndoEdit, panel: MainPanel) # as it was for the next blocks
      st.shutdown()
      removeFile(c)
    block editedBeforeKnown:
      # edits made while the drive does not give the file's first and last
      # bytes are said to wait for them, and said lost at a quit before
      var st = start(config)
      holdStep("reading its first and last bytes")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: b)
      doAssert waitUntil((discard st.drainInbox(); inStep("reading its first and last bytes").len == 1))
      doAssert st.settle(st.panel(MainPanel).laidOut)
      fault(b, fkHang, {foOpen, foRead})
      releaseStep("reading its first and last bytes")
      doAssert waitUntil(hung() == 1)
      st.edit(teKilled, 1)
      proc lastInfo(st: AppState): string =
        for e in st.log:
          if e.severity == sevInfo: result = e.text
      doAssert "kept by its path until viewSEG has read its first and last bytes" in st.lastInfo,
        "an edit that waits for the file's identity is not said: " & st.lastInfo
      st.shutdown(wait = initDuration(milliseconds = 200))
      doAssert "kept by its path: viewSEG could not read" in st.lastInfo,
        "the edits kept by the path are not said at the quit: " & st.lastInfo
      doAssert fileExists(config / StoreFolder / pendingName(b)), "no pending document"
      release(b)
      # the next run, the file unchanged and its drive answering: the edits
      # kept by the path are not applied by themselves (the path says nothing
      # of the content): an unconfirmed record of the file's identity, offered
      # with the earlier outputs, the pending document gone
      st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known and
        st.earlierOf(b).anyIt(it.unconfirmed and 1 in it.edits.lists[teKilled])),
        "the edits made before the identity was known are not offered"
      doAssert st.settle(st.remembering(b).confirmed and not st.remembering(b).looking)
      doAssert not st.editsOf(0).has(teKilled, 1), "the edits kept by the path were applied alone"
      doAssert st.editsOf(0).has(teKilled, 3), "what was remembered of it before did not come"
      st.flushFiles()
      doAssert not fileExists(config / StoreFolder / pendingName(b)), "the pending document stays"
      # Apply (one step) makes them the file's: the user's click only
      let offered = st.earlierOf(b)[0]
      st.apply Command(kind: ckImportEdits, panel: MainPanel,
        listPath: st.store.docPath(offered.doc), replaceEdits: true)
      doAssert st.settle(st.editsOf(0).has(teKilled, 1)), "Apply did not apply them"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel) # as it was for the next blocks
      doAssert st.settle(st.editsOf(0).has(teKilled, 3) and not st.editsOf(0).has(teKilled, 1))
      st.shutdown()
      for f in docs(config): # the offered record: not for the next blocks
        if "unconfirmed" in readFile(f): removeFile(f)
      # a pending document of a file that changed since: not applied, said
      # with its edits, removed
      writeFile(config / StoreFolder / pendingName(b), memoryDocument(FileRecord(
        identity: FileIdentity(size: getFileSize(b) + 1), name: "renamed.sgy", path: b,
        opened: getTime(), modified: kept[1], edits: EditLists(lists: [@[], @[4, 5, 6], @[]]))))
      st = start(config)
      st.showFile(b)
      doAssert st.settle("are not applied: it changed since" in st.lastWarning), st.lastWarning
      doAssert "killed 5-7" in st.lastWarning and not st.editsOf(0).has(teKilled, 4)
      st.flushFiles()
      doAssert not fileExists(config / StoreFolder / pendingName(b))
      st.shutdown()
    block damagedNotWrittenOver:
      # a document of the file's quick identity that cannot be read is said,
      # and a new one is written beside it, never over it
      var bytes = readFile(b)
      bytes[0] = char(ord(bytes[0]) xor 1)
      let d = fx.dir / "other-header.sgy"
      writeFile(d, bytes)
      var t: Time
      let id = quickIdentity(d, t)
      let damaged = config / StoreFolder / docName(id, 1)
      writeFile(damaged, "(fileMemory (version 1) (killed \"2 3")
      var st = start(config)
      st.showFile(d)
      doAssert st.settle(st.remembering(d).known)
      doAssert docName(id, 1) in st.lastWarning, st.lastWarning
      st.edit(teKilled, 2)
      st.flushFiles()
      doAssert readFile(damaged) == "(fileMemory (version 1) (killed \"2 3",
        "the document that could not be read was written over"
      doAssert fileExists(config / StoreFolder / docName(id, 2))
      st.shutdown()
    block damagedKeepsItsTime:
      # a document with a part that cannot be read (edited by hand) is not
      # written again when its file is opened, so as not to drop that part:
      # when it was opened is kept beside it, and File memory lists it as
      # opened now, in this run and the next, never as months ago
      var bytes = readFile(b)
      bytes[1] = char(ord(bytes[1]) xor 1)
      let d = fx.dir / "hand-edited.sgy"
      writeFile(d, bytes)
      var t: Time
      let id = quickIdentity(d, t)
      let months = getTime() - initDuration(days = 200)
      let doc = docName(id, 1)
      let text = memoryDocument(FileRecord(identity: id, name: "hand-edited.sgy", path: d,
        opened: months, modified: t, edits: EditLists(lists: [@[], @[2], @[]]))).replace(
        "(killed \"3\")", "(killed \"3 x\")")
      writeFile(config / StoreFolder / doc, text)
      proc listedOpened(st: var AppState): Time =
        st.apply Command(kind: ckFileMemory)
        doAssert st.settle(st.memoryList.listed and not st.memoryList.listing)
        for r in st.memoryList.records:
          if r.doc == doc: result = r.opened
      block opened:
        var st = start(config)
        st.showFile(d)
        doAssert st.settle(st.remembering(d).known and st.editsOf(0).has(teKilled, 2))
        doAssert st.settle(st.remembering(d).confirmed and not st.remembering(d).looking)
        st.flushFiles()
        doAssert readFile(config / StoreFolder / doc) == text,
          "the damaged document was written: " & readFile(config / StoreFolder / doc)
        doAssert getTime() - st.listedOpened < initDuration(minutes = 5),
          "a file opened now is listed as opened months ago"
        st.shutdown()
      block nextRun: # not opened: the time comes from beside the document
        var st = start(config)
        doAssert getTime() - st.listedOpened < initDuration(minutes = 5),
          "a file opened in the run before is listed as opened months ago"
        st.shutdown()
      var st = start(config) # once its edits change, the document is whole again
      st.showFile(d)
      doAssert st.settle(st.remembering(d).known)
      # the user's edit during the check is kept apart; once the hash agrees
      # the edit joins the record, which is then whole again
      doAssert st.settle(st.remembering(d).confirmed and not st.remembering(d).looking)
      st.edit(teKilled, 5)
      st.flushFiles()
      doAssert "x" notin readFile(config / StoreFolder / doc).split("(killed")[1].split(")")[0]
      doAssert not fileExists(config / StoreFolder / doc.seenName), "the side file stays"
      st.apply Command(kind: ckForgetFiles, forget: @[doc])
      st.shutdown()
    block pruned:
      # what is remembered of the file forgotten: the data file still as it was
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3))
      let doc = st.remembering(b).doc
      st.apply Command(kind: ckForgetFiles, forget: @[doc])
      doAssert st.editsOf(0).isEmpty
      st.flushFiles()
      doAssert not fileExists(config / StoreFolder / doc)
      st.shutdown()
    block hashBesideBackground:
      # a file's hash under way (a large file, or one on a share) holds no
      # background work: a QC check queued after it runs at once
      var st = start(config)
      holdStep("reading every byte")
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known)
      st.edit(teKilled, 2) # the user's: the file is hashed whole
      doAssert waitUntil((discard st.drainInbox(); inStep("reading every byte").len == 1))
      backgroundRan.store(false)
      discard st.jobs.submit(JobSpec(title: "Check the records", lane: jlBackground),
        proc (ctx: JobContext) {.gcsafe.} = backgroundRan.store(true))
      doAssert waitUntil(backgroundRan.load, initDuration(seconds = 2)),
        "a background job waits behind a file's hash"
      releaseStep("reading every byte")
      doAssert st.settle(st.remembering(b).confirmed)
      st.shutdown()
    block changedWhileHashed:
      # a file rewritten in place while its hash runs, a byte in the middle
      # (its size and its ends as they were): nothing is confirmed
      let c = fx.dir / "rewritten.sgy"
      writeFile(c, readFile(b))
      var st = start(config)
      holdStep("reading every byte")
      st.showFile(c)
      doAssert st.settle(st.remembering(c).known)
      st.edit(teKilled, 2) # the user's: the file is hashed whole
      doAssert waitUntil(inStep("reading every byte").len == 1)
      var f = open(c, fmReadWriteExisting)
      f.setFilePos(getFileSize(c) div 2)
      f.write "x"
      f.close()
      releaseStep("reading every byte")
      proc said(st: AppState; text: string): bool =
        for e in st.log:
          if text in e.text: return true
      doAssert st.settle(st.said("it changed while it was read")),
        "a file changed in the middle while it was hashed was confirmed"
      st.shutdown()
      removeFile(c)
    block exportLeavesOutTheAgents:
      # an export is handed on and outlives the session: an agent's kill
      # (shown for the session only) is left out of it, and said
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known)
      st.edit(teKilled, 3)
      st.edit(teKilled, 6, by = coAgent)
      let csv = fx.dir / "agent.csv"
      st.apply Command(kind: ckExportEdits, panel: MainPanel, listPath: csv)
      doAssert st.settle(fileExists(csv))
      let text = readFile(csv)
      doAssert "\n4,11,4,killed," in text and "\n7," notin text,
        "the export holds the agent's kill: " & text
      var said = false
      for e in st.log:
        if "leaves out 1 edit shown for this session only" in e.text: said = true
      doAssert said, "the edit left out is not said"
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      st.shutdown()
    block listedPastAHungDrive:
      # File memory with an entry on a drive that does not answer: the
      # listing comes at once, the entries elsewhere are looked at, the one
      # held is "not answering" (never gone), and its answer, once the drive
      # gives it, is still taken
      let hungDir = fx.dir / "a-hung-share"
      let placeDir = fx.dir / "place"
      createDir(hungDir)
      createDir(placeDir)
      writeFile(hungDir / "far.sgy", newString(300))
      writeFile(placeDir / "here.sgy", newString(400))
      var docs: seq[string]
      for (name, path, size) in [("far.sgy", hungDir / "far.sgy", 300'i64),
          ("here.sgy", placeDir / "here.sgy", 400'i64), ("gone.sgy", placeDir / "gone.sgy", 500'i64)]:
        var r = FileRecord(identity: FileIdentity(size: size, quick: uint64(size)), name: name,
          path: path, opened: getTime())
        r.edits.lists[teKilled] = @[0]
        r.doc = docName(r.identity, 1)
        writeFile(config / StoreFolder / r.doc, memoryDocument(r))
        docs.add r.doc
      proc rec(st: AppState; name: string): FileRecord =
        for r in st.memoryList.records:
          if r.name == name: return r
      var st = start(config)
      fault(hungDir, fkHang, {foStat})
      st.apply Command(kind: ckFileMemory)
      doAssert waitUntil((discard st.drainInbox(); st.memoryList.listed and
        not st.memoryList.listing), initDuration(seconds = 2)),
        "the listing waits for a drive that does not answer"
      doAssert st.settle(st.rec("gone.sgy").gone and not st.rec("here.sgy").looking and
        st.rec("far.sgy").silent), "the entries after the one held were not looked at"
      doAssert not st.rec("here.sgy").gone and not st.rec("far.sgy").gone
      release(hungDir)
      doAssert st.settle(not st.rec("far.sgy").silent and not st.rec("far.sgy").looking),
        "the late answer was not taken"
      doAssert not st.rec("far.sgy").gone
      st.apply Command(kind: ckForgetFiles, forget: docs)
      st.shutdown()
    when not defined(windows):
      # A file opened by its symbolic link reads as empty on Windows: parseSEG sizes it with
      # `std/os.getFileSize`, which there answers the link's own size (0).
      block onePathAndAnother:
        # one file opened under two paths (a symbolic link: at once; a copy
        # with a time of its own: once both are hashed whole): one set of
        # edits, every path's kept, in one document, back under any path
        let l = fx.dir / "link.sgy"
        createSymlink(b, l)
        let c = fx.dir / "same-copy.sgy"
        writeFile(c, readFile(b))
        var st = start(config)
        st.showFile(b)
        doAssert st.settle(st.remembering(b).known)
        # paths of one content are linked only once the edits brought back are
        # confirmed: the edits come after the hash
        doAssert st.settle(st.remembering(b).confirmed and not st.remembering(b).looking)
        st.edit(teKilled, 4)
        st.edit(teKilled, 12)
        st.flushFiles() # the document has 12 killed ...
        st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[st.base + 12],
          on: false) # ... and the user takes it back, not written yet
        st.showFile(l)
        doAssert st.settle(st.remembering(l).known)
        # the link's edits, brought back from the document, are checked first:
        # the two paths join once both hashes agree
        doAssert st.settle(st.remembering(l).confirmed and not st.remembering(l).looking)
        doAssert st.editsOf(0).has(teKilled, 4), "the link does not share the edits"
        doAssert not st.editsOf(0).has(teKilled, 12), "a kill taken back came back with the link"
        st.edit(teKilled, 8)
        st.showFile(b)
        doAssert st.editsOf(0).has(teKilled, 8), "the file does not share its link's edit"
        st.showFile(c)
        doAssert st.settle(st.remembering(c).confirmed and st.remembering(b).confirmed and
          not st.remembering(c).looking and st.editsOf(0).has(teKilled, 4)),
          "the copy does not share the edits once hashed"
        st.edit(teKilled, 6)
        st.flushFiles()
        var t: Time
        let key = quickIdentity(b, t).key
        var d: seq[string]
        for x in docs(config): # (the rewritten copy's, of the same ends, is another file's)
          if x.extractFilename.startsWith(key) and "rewritten.sgy" notin readFile(x): d.add x
        var texts = ""
        for x in d: texts.add readFile(x) & "\n"
        doAssert d.len == 1, "one file, documents: " & texts
        doAssert "(killed \"5 7 9\")" in readFile(d[0]), readFile(d[0])
        st.showFile(b)
        doAssert st.editsOf(0).has(teKilled, 6), "the file does not share its copy's edit"
        # a file of the same size, ends and time but another content: taken at
        # once for the same file, and apart again when its hash says so
        var bytes = readFile(b)
        bytes[bytes.len div 2] = char(ord(bytes[bytes.len div 2]) xor 0x20)
        let x = fx.dir / "same-ends.sgy"
        writeFile(x, bytes)
        setLastModificationTime(x, getLastModificationTime(b))
        holdStep("reading every byte")
        st.showFile(x)
        doAssert st.settle(st.remembering(x).known and st.editsOf(0).has(teKilled, 4))
        releaseStep("reading every byte")
        doAssert st.settle(st.remembering(x).confirmed and not st.remembering(x).looking)
        doAssert st.editsOf(0).isEmpty, "a file of another content keeps the edits of the other"
        doAssert "its content differs" in st.lastWarning, st.lastWarning
        st.showFile(b)
        doAssert st.editsOf(0).has(teKilled, 4) and st.editsOf(0).has(teKilled, 6) and
          st.editsOf(0).has(teKilled, 8), "the file lost its edits to the other"
        st.shutdown()
        removeFile(x)
        st = start(config)
        st.showFile(l)
        doAssert st.settle(st.remembering(l).known and st.editsOf(0).has(teKilled, 6) and
          st.editsOf(0).has(teKilled, 4) and st.editsOf(0).has(teKilled, 8)),
          "the edits of the three paths did not all come back"
        # cleared once the hash agrees: during the check a clearing is the user's
        # own state, kept apart as an unconfirmed record
        doAssert st.settle(st.remembering(l).confirmed and not st.remembering(l).looking)
        st.apply Command(kind: ckClearEdits, panel: MainPanel)
        st.shutdown()
        removeFile(l)
        removeFile(c)
    block twoPrograms:
      # two viewSEG at once (two states on one store), the same file open in
      # both: neither write drops the other's edits; each shows the other's
      # once it writes; a clearing in one stays cleared, what the other adds
      # after it is kept
      var one = start(config)
      var two = start(config)
      one.showFile(b)
      two.showFile(b)
      doAssert one.settle(one.remembering(b).known) and two.settle(two.remembering(b).known)
      # the edits brought back are checked first; what each makes after is the
      # record's, written to the one document
      doAssert one.settle(one.remembering(b).confirmed and not one.remembering(b).looking) and
        two.settle(two.remembering(b).confirmed and not two.remembering(b).looking)
      one.edit(teKilled, 2)
      one.flushFiles()
      two.edit(teKilled, 5)
      two.flushFiles()
      var t: Time
      let doc = config / StoreFolder / docName(quickIdentity(b, t), 1)
      doAssert "(killed \"3 6\")" in readFile(doc), "a write dropped the other's edit: " &
        readFile(doc)
      doAssert two.settle(two.editsOf(0).has(teKilled, 2)), "the other's edit is not shown"
      var told = false
      for e in two.log:
        if "Another viewSEG changed the edits" in e.text: told = true
      doAssert told, "the other's change is not said"
      one.edit(teKilled, 7)
      one.flushFiles()
      doAssert "(killed \"3 6 8\")" in readFile(doc), readFile(doc)
      doAssert one.settle(one.editsOf(0).has(teKilled, 5))
      one.apply Command(kind: ckClearEdits, panel: MainPanel)
      one.flushFiles()
      doAssert not fileExists(doc), "the clearing did not remove the document"
      two.edit(teKilled, 9)
      two.flushFiles()
      doAssert "(killed \"10\")" in readFile(doc), "the clearing in the other came back, or " &
        "the new edit is lost: " & readFile(doc)
      doAssert two.settle(not two.editsOf(0).has(teKilled, 2) and two.editsOf(0).has(teKilled, 9))
      two.apply Command(kind: ckClearEdits, panel: MainPanel)
      one.shutdown()
      two.shutdown()
      doAssert not fileExists(doc)
    block pendingOfThisRunAndAnEarlier:
      # a store of its own: the pending documents of the file's path
      let config = fx.dir / "config-pending"
      proc hungShow(st: var AppState; path: string) =
        holdStep("reading its first and last bytes")
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
        doAssert waitUntil((discard st.drainInbox(); inStep(
            "reading its first and last bytes").len == 1))
        doAssert st.settle(st.panel(MainPanel).laidOut)
        fault(path, fkHang, {foOpen, foRead})
        releaseStep("reading its first and last bytes")
        doAssert waitUntil(hung() == 1)
      proc kill(st: var AppState; trace: int; on = true) =
        st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[st.base + trace],
          on: on)
      # this run's own pending document is older than what it shows: a kill
      # taken back in the second before the drive answers stays taken back
      var st = start(config)
      st.hungShow(b)
      st.kill(1)
      st.flushFiles() # the pending document has it
      st.kill(1, on = false) # not written yet when the drive answers
      release(b)
      doAssert waitUntil((discard st.drainInbox(); st.remembering(b).known))
      doAssert not st.editsOf(0).has(teKilled, 1), "the kill taken back came back from the " &
        "pending document"
      st.shutdown()
      doAssert docs(config).len == 0, $docs(config)
      # an earlier run's pending document, the drive not answering in this run
      # either: kept beside this run's edits, not written over
      st = start(config)
      st.hungShow(b)
      st.kill(3)
      st.shutdown(wait = initDuration(milliseconds = 200))
      release(b)
      doAssert waitUntil(hung() == 0)
      st = start(config)
      st.hungShow(b)
      st.kill(5)
      st.flushFiles()
      doAssert st.settle(st.editsOf(0).has(teKilled, 3)), "the earlier run's pending edit is " &
        "not shown beside this run's"
      release(b)
      doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 5))
      doAssert st.editsOf(0).has(teKilled, 3), "the earlier run's pending document was written over"
      st.flushFiles()
      doAssert not fileExists(config / StoreFolder / pendingName(b))
      doAssert "(killed \"4 6\")" in readFile(config / StoreFolder / st.remembering(b).doc)
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      st.shutdown()
    block forgottenThenKilledAgain:
      # what is remembered forgotten (File memory), then the same trace killed
      # again: the new kill is kept and shown
      let config = fx.dir / "config-forget"
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known)
      st.edit(teKilled, 3)
      st.flushFiles()
      st.apply Command(kind: ckForgetFiles, forget: @[st.remembering(b).doc])
      st.flushFiles()
      st.edit(teKilled, 3)
      st.flushFiles()
      doAssert st.settle(true)
      doAssert st.editsOf(0).has(teKilled, 3), "the kill made after the forgetting is gone"
      doAssert docs(config).len == 1 and "(killed \"4\")" in readFile(docs(config)[0]),
        "the kill made after the forgetting is not remembered"
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      st.shutdown()
    block anotherProgramMidWrite:
      # another viewSEG in the middle of its write of the document (it holds
      # the store's lock: between its look at the document and its rename):
      # this one's write waits for it, then merges, and loses neither kill
      let config = fx.dir / "config-lock"
      var st = start(config)
      st.showFile(b)
      doAssert st.settle(st.remembering(b).known)
      st.edit(teKilled, 2)
      st.flushFiles()
      let doc = config / StoreFolder / st.remembering(b).doc
      locking.close()
      unlocking.close()
      var other: Thread[string]
      createThread(other, holdStoreLock, config / StoreFolder & StoreLockSuffix)
      doAssert waitUntil(locking.isOpen), "the lock was not taken"
      st.edit(teKilled, 4)
      st.persist() # the change seen ...
      sleep 1100
      st.persist() # ... and handed to the disk thread a second later
      sleep 300
      # the other program's rename, with a kill of its own
      let text = readFile(doc).replace("(killed \"3\")", "(killed \"3 8\")")
      doAssert "3 8" in text, "this program wrote while the other held the lock: " & readFile(doc)
      writeFile(doc & ".other.tmp", text)
      moveFile(doc & ".other.tmp", doc)
      unlocking.open()
      joinThread(other)
      st.flushFiles()
      doAssert st.settle(st.editsOf(0).has(teKilled, 7)), "the other's kill is not shown"
      doAssert "(killed \"3 5 8\")" in readFile(doc), "a write in the other's lost a kill: " &
        readFile(doc)
      st.apply Command(kind: ckClearEdits, panel: MainPanel)
      st.shutdown()
    doAssert (readFile(b), getLastModificationTime(b)) == kept, "the data file changed"
  echo "tmemory: ok"

when isMainModule:
  main()
