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
##   file's identity, and said lost at a quit before it came;
## - a document that cannot be read is said and never written over;
## - a document with a part that cannot be read keeps the time its file was
##   opened beside it, and File memory lists that time;
## - a user's edit while the hash is under way, on a file taken at once for
##   one remembered, is not left in that file's document when the hash says
##   it was another;
## - a file's hash under way holds no background job (a lane of its own);
## - a file rewritten in the middle while its hash runs is not confirmed;
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
## identity is not said" and "the lost edits are not said at the quit";
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
## background job waits behind a file's hash".

import std/[atomics, os, strutils, times]
import viewSEG/core/[jobs, state]
import utils/[faultyfs, fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond)) # as a frame does

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
    let docBefore = readFile(docs(config)[0])
    st = start(config)
    holdStep("reading every byte") # a large file: its hash comes later
    st.showFile(c2)
    doAssert st.settle(st.remembering(c2).known)
    doAssert st.editsOf(0).has(teKilled, 3), "a file of the same size, ends and time is " &
      "taken for the file at once"
    st.edit(teKilled, 9) # the user's, while the hash is under way: written a second later
    st.flushFiles()
    doAssert "changed-same-time" in readFile(docs(config)[0])
    releaseStep("reading every byte")
    doAssert st.settle(st.remembering(c2).confirmed and not st.remembering(c2).looking)
    doAssert st.editsOf(0).isEmpty and not st.panel(MainPanel).layers[0].reversed,
      "the changed copy shows the edits of the file it was copied from"
    doAssert "its content differs" in st.lastWarning, st.lastWarning
    doAssert st.quiet, "the jobs of what is remembered were said to end"
    st.shutdown()
    doAssert docs(config).len == 1, "the copies made documents of their own: " & $docs(config)
    doAssert readFile(docs(config)[0]) == docBefore, "the other file's document keeps what " &
      "was written of the changed copy: " & readFile(docs(config)[0])
  block clearedAndBack:
    var st = start(config)
    st.showFile(b)
    doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3))
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
    doAssert "once viewSEG has read its first and last bytes" in st.lastWarning,
      "an edit that waits for the file's identity is not said: " & st.lastWarning
    st.shutdown(wait = initDuration(milliseconds = 200))
    doAssert "are not remembered" in st.lastWarning, "the lost edits are not said at the quit"
    release(b)
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
      opened: months, modified: t, edits: EditLists(lists: [@[], @[2]]))).replace(
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
  doAssert (readFile(b), getLastModificationTime(b)) == kept, "the data file changed"
echo "tmemory: ok"
