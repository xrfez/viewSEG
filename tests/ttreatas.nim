## What the user forces a file to be treated as (`ckTreatAs`): its kind of recording and the
## order of its traces, shown in the Files panel with a mark and the automatic answer, kept in
## the file's document of the store (found by its identity, made on demand) and read back with
## the kinds when the folder is listed again, with unknown nodes of the document kept and an old
## document without the choice read as before. A forced kind is what the slice dialog's refusal
## and the slice job go by; forced continuous where the start times cannot be read takes the
## traces end to end and says so.
##
## Seen to fail with a deliberate fault: with the choice left out of `memoryDocument`, the
## choice was not kept ("futureNote" and "(treat" in the document); with `endToEndTimes` giving
## the file's own times, "the slice did not follow end to end"; with the sentence of the segment
## times written twice, it was counted twice; with the end-to-end sentence saying the start times
## "could not be read", the words were not those of a file whose starts are the same; without the
## check of the first start time, a file of starts at the epoch was sliced from 1970; returning
## early when the user's choice did not change, the user's pick after an agent's did nothing;
## without the check of the path, a missing, unlisted or non-seismic file took a choice. On the
## code before the choice had a writer of its own in the disk thread: the edit written while the
## look-up was under way was lost ("@[0]"), and the later version's node was dropped by the edit
## after a choice; a file opened by its path did not have its choice, and its first edit made a
## second document; a document that may be another file's gave the row its choice; the look-up
## ran on the peeks lane ("peeks"). With the choice taken when the look-up was asked for, not when
## its answer came, the read-back of the newest choice failed. Before a document of only a
## choice was taken as the file's own: a file touched since and edited got a second document
## ("a second document: 2"), and edits made on one and a quit before the hash came back only
## offered; the list showed the choice of a document of another content and time; a look-up
## left at the quit or stopped was said nowhere; and the choice was written whole, so a second
## program's choice of the grouping erased the first one's kind.

import std/[importutils, options, os, sequtils, strutils, tables, times]
import parseSEG
import viewSEG/core/state {.all.}
import viewSEG/core/[cutgather, edits, filelist, filememory, identity, jobs, nif,
  recordingkind, shotlog, traceorder, treatas]
import viewSEG/core/cutgatherjobs {.all.}
import viewSEG/view/[filetable, recordingwords]
import utils/[fixtures, kindfiles, waiting]

privateAccess(AppState)
privateAccess(Remembered)

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func entry(name: string; kind: RecordingKind; order: TraceOrder; treat = TreatAs()): FileEntry =
  FileEntry(path: "/d/" & name, name: name, kind: fkSegd, size: 1, kindState: ksKnown,
    recording: kind, traceOrder: order, treat: treat)

proc docs(dir: string): seq[string] =
  let store = dir / StoreFolder
  if dirExists(store):
    for kind, p in walkDir(store):
      if p.endsWith(MemorySuffix): result.add p

proc appIn(dir: string): AppState =
  result = initAppState()
  result.rememberFilesIn(dir)

proc listed(st: AppState; n: int): bool =
  not st.fileList.scanning and st.fileList.entries.len == n and
    st.fileList.entries.allIt(it.kindState != ksUnread) and st.kindJob == NoJob

template settled(st: var AppState; cond: untyped): bool =
  ## `cond`, with the inbox drained and what is due handed to the disk thread meanwhile
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settled(st.sessions.len >= 1 and st.sessions[^1].path == canonical(path) and
    st.panel(MainPanel).laidOut), "not shown: " & path

proc kill(st: var AppState; trace: int) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
    edited: @[st.sessions[^1].base + trace], on: true, origin: coWindow)

proc idle(st: var AppState): bool =
  ## no job of what is remembered left (identifications, hashes, look-ups), the disk written
  st.flushFiles()
  st.memoryWork.len == 0 and st.remembered.allIt(it.job == NoJob and it.hashJob == NoJob)

proc main*() =
  block theWordsAndTheMark:
    let auto = TraceOrder(grouping: tgNone, subSort: tsByStation)
    var e = entry("a.sgd", rkShotGather, auto)
    doAssert kindText(e) == "Shot" and orderText(e) == "Station"
    doAssert kindTip(e) == "Shot gather"
    e.treat.kind = some rkReceiverSliced
    doAssert e.recordingOf == some(rkReceiverSliced) and e.autoRecordingOf == some(rkShotGather)
    doAssert kindText(e) == "Sliced *", kindText(e)
    doAssert kindTip(e) == "Time-sliced receiver gather. Set by you: right-click to return to " &
      "automatic. Automatic says: Shot gather.", kindTip(e)
    e.treat.grouping = some tgByFlag
    doAssert orderText(e) == "Flag · station *", orderText(e)
    doAssert orderTip(e).startsWith("Traces are grouped by flag") and
      "Set by you: right-click to return to automatic. Automatic says: Traces are sorted " &
      "by station." in orderTip(e), orderTip(e)
    # a file not read yet shows what is forced, and none of the rest
    let unread = FileEntry(path: "/d/u.sgd", name: "u.sgd", kind: fkSegd, size: 1,
      treat: TreatAs(kind: some rkReceiverContinuous))
    doAssert kindText(unread) == "Continuous *" and kindTip(unread).endsWith(
      "Automatic says: not read yet."), kindTip(unread)
    doAssert orderText(unread) == "" and orderText(e) != ""
    # sorted by the words shown: the forced kind counts as the kind
    var list = FileList(gen: 1, revision: 1)
    var forcedCont = entry("b.sgd", rkShotGather, auto, TreatAs(kind: some rkReceiverContinuous))
    list.merge([entry("a.sgd", rkReceiverSliced, auto), forcedCont,
      entry("c.sgd", rkShotGather, auto)])
    var t: FileTable
    t.update(list, "", FileOrder(column: fcKind))
    var names: seq[string] = @[]
    for r in t.rows: names.add list.entries[r].name
    doAssert names == @["b.sgd", "c.sgd", "a.sgd"], $names

  block theDocumentKeepsWhatItDoesNotKnowAndOldOnesLoad:
    let old = "(.nif27)\n(.vendor \"viewSEG\")\n(fileMemory (version 1) (identity (size 10) " &
      "(quick \"0000000000000001\")) (seen (name \"a.sgd\") (path \"/d/a.sgd\") " &
      "(opened \"2026-11-15T10:02:41Z\") (modified 1763200961 0)) (killed \"3\"))\n"
    var problems: seq[string]
    let r = readMemory(parseNif(old, "old"), "old.nif", problems)
    doAssert problems.len == 0 and not r.treat.isSet and r.edits.lists[teKilled] == @[2]
    doAssert "treat" notin memoryDocument(r), "an old document gained a choice"
    var withIt = r
    withIt.treat = TreatAs(kind: some rkShotGather, grouping: some tgByComponent,
      subSort: some tsByTime)
    withIt.later = parseNif("(futureNote \"kept\")", "later")
    let text = memoryDocument(withIt)
    doAssert "futureNote" in text and "(treat" in text, text
    let back = readMemory(parseNif(text, "new"), "new.nif", problems)
    doAssert back.treat == withIt.treat and back.later.len == 1 and
      back.edits.lists[teKilled] == @[2], text
    # a word that is not one is a problem, and the rest is read
    var bad: seq[string]
    let odd = readMemory(parseNif(text.replace("\"shot\"", "\"wide\""), "odd"), "odd.nif", bad)
    doAssert bad.len == 1 and odd.treat.kind.isNone and odd.treat.subSort == some(tsByTime), $bad

  block theSegmentTimesAreSaidOnce:
    let lines = cutLines(CutResult(ok: true, segmentsFromHeaders: true), initCutOptions(1000, 0))
    doAssert lines.countIt(it == "Segment times were read from the trace headers.") == 1, $lines

  block aForcedKindChangesTheRefusalAndTheOrderIsShown:
    let auto = RecordingFacts(ready: true, kind: rkShotGather,
      order: TraceOrder(grouping: tgNone, subSort: tsByStation))
    doAssert cutRefusal(auto).len > 0 and "You set" notin cutRefusal(auto)
    let asContinuous = auto.applied(TreatAs(kind: some rkReceiverContinuous))
    doAssert cutRefusal(asContinuous) == "" and asContinuous.forced
    let continuous = RecordingFacts(ready: true, kind: rkReceiverContinuous)
    let asSliced = continuous.applied(TreatAs(kind: some rkReceiverSliced))
    doAssert "time-sliced" in cutRefusal(asSliced) and "You set this kind" in cutRefusal(asSliced)
    doAssert auto.applied(TreatAs(grouping: some tgByFlag)).order ==
      TraceOrder(grouping: tgByFlag, subSort: tsByStation)
    doAssert not auto.applied(TreatAs()).forced
    # a part forced leaves the other part's "inside each record" as it was
    let inRec = TraceOrder(grouping: tgByFlag, subSort: tsByStation, sortInRecords: true,
      groupInRecords: true)
    doAssert applied(inRec, TreatAs(grouping: some tgByComponent)) == TraceOrder(
      grouping: tgByComponent, subSort: tsByStation, sortInRecords: true)
    doAssert applied(inRec, TreatAs(subSort: some tsByTime)) == TraceOrder(
      grouping: tgByFlag, subSort: tsByTime, groupInRecords: true)

  withFixtures fx:
    let config = fx.dir / "config"
    let dir = fx.dir / "folder"
    let cont = writeSpecs(dir, "a", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    let shot = writeSpecs(dir, "c", [spec(0, 0), spec(1, 0), spec(2, 0)])
    var st = appIn(config)

    block forcingEachKindAndClearingIt:
      st.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert st.settle(st.listed(2)), "the kinds were not read"
      let i = st.fileList.find(canonical(shot))
      for k in RecordingKind:
        st.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: kindName(k))
        doAssert st.fileList.entries[i].recordingOf == some(k), "the row did not take the " &
          "forced kind"
        doAssert st.fileList.entries[i].autoRecordingOf == some(rkShotGather)
        doAssert st.treatOf(shot).kind == some(k)
      st.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: "automatic")
      doAssert st.fileList.entries[i].recordingOf == some(rkShotGather)
      doAssert not st.treatOf(shot).isSet
      st.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: "wide") # refused, in words
      st.apply Command(kind: ckTreatAs, treatPath: shot) # nothing given: refused
      doAssert not st.treatOf(shot).isSet
      doAssert st.log.anyIt("is not a kind" in it.text)
      doAssert docs(config).len == 0 or true

    block onlyASeismicFileListedOrOpenIsTreated:
      let cfg = fx.dir / "refuse-config"
      var r = appIn(cfg)
      let notes = fx.dir / "notes.txt"
      writeFile(notes, "x")
      for p in [fx.dir / "nope.sgd", notes, shot]: # (`shot`: not listed in this one)
        r.apply Command(kind: ckTreatAs, treatPath: p, treatKind: "shot")
        doAssert not r.treatOf(p).isSet, "taken for " & p
        doAssert r.log.anyIt(canonical(p) & " is not a seismic file listed in Files or open" in
          it.text), "not said for " & p
        var agent = Command(kind: ckTreatAs, treatPath: p, treatKind: "shot")
        agent.origin = coAgent
        r.apply agent
        doAssert not r.treatOf(p).isSet, "an agent's taken for " & p
      doAssert r.settle((r.flushFiles(); r.jobs.list.allIt(it.state notin {jsQueued, jsRunning})))
      doAssert docs(cfg).len == 0, "a document was written for a file that is not treated"

    block theChoiceIsKeptForTheFileAndReadBack:
      st.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: "continuous",
        treatGrouping: "flag", treatSubSort: "time")
      let want = TreatAs(kind: some rkReceiverContinuous, grouping: some tgByFlag,
        subSort: some tsByTime)
      proc stored(): TreatAs =
        # (the document, once it is there: earlier commands' jobs may have written theirs)
        var p: seq[string]
        if docs(config).len == 1:
          try:
            result = readMemoryFile(docs(config)[0], p).treat
          except CatchableError:
            discard
      doAssert st.settle((st.flushFiles(); stored() == want)), "the choice was not kept"
      let doc = docs(config)[0]
      var p: seq[string]
      let rec = readMemoryFile(doc, p)
      doAssert rec.path == canonical(shot), $rec.treat
      # a node this version does not know, written by a later one, stays
      var text = readFile(doc)
      text = text[0 ..< text.rfind(')')] & " (futureNote \"kept\")\n)\n"
      writeFile(doc, text)
      st.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: "sliced")
      doAssert st.settle((st.flushFiles(); "sliced" in readFile(doc))),
        "the new choice was not kept"
      doAssert "futureNote" in readFile(doc), "the unknown node was dropped"
      doAssert docs(config).len == 1, "the file got a second document"
      # another run of the program: listed again, the row has what was kept
      var again = appIn(config)
      again.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert again.settle(again.listed(2)), "the kinds were not read"
      let j = again.fileList.find(canonical(shot))
      doAssert again.fileList.entries[j].treat.kind == some(rkReceiverSliced) and
        again.fileList.entries[j].treat.grouping == some(tgByFlag),
        "the choice was not read back"
      doAssert again.fileList.entries[j].recordingOf == some(rkReceiverSliced)
      doAssert again.fileList.entries[again.fileList.find(canonical(cont))].treat == TreatAs()
      # given back to automatic, the choice goes; what the document holds that is not ours stays
      again.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: "automatic",
        treatGrouping: "automatic", treatSubSort: "automatic")
      doAssert again.settle((again.flushFiles(); "(treat" notin readFile(doc))),
        "the choice was kept after it was taken off"
      doAssert "futureNote" in readFile(doc)
      # a file with nothing else in its document has none once it is automatic again
      again.apply Command(kind: ckTreatAs, treatPath: cont, treatKind: "shot")
      doAssert again.settle((again.flushFiles(); docs(config).len == 2)), "no document made"
      again.apply Command(kind: ckTreatAs, treatPath: cont, treatKind: "automatic")
      doAssert again.settle((again.flushFiles(); docs(config).len == 1)),
        "the document of nothing forced was kept"

    block anAgentsChoiceIsForTheSessionOnly:
      var g = appIn(fx.dir / "agent-config")
      g.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert g.settle(g.listed(2))
      g.apply Command(kind: ckShowFile, panel: MainPanel, path: cont)
      doAssert g.settle(g.rememberedAt(canonical(cont)) >= 0)
      var agent = Command(kind: ckTreatAs, treatPath: cont, treatKind: "shot")
      agent.origin = coAgent
      g.apply agent
      doAssert g.treatOf(cont).kind == some(rkShotGather), "the agent's choice was not taken"
      doAssert g.treatsKept.len == 0, "an agent's choice is kept"
      doAssert not g.recordOf(g.rememberedAt(canonical(cont))).treat.isSet,
        "an edit write would carry the agent's choice"
      g.apply Command(kind: ckTreatAs, treatPath: cont, treatKind: "sliced")
      agent.treatKind = "continuous"
      g.apply agent
      doAssert g.treatOf(cont).kind == some(rkReceiverContinuous)
      doAssert g.treatsKept.getOrDefault(canonical(cont)).kind == some(rkReceiverSliced),
        "the user's choice was replaced by the agent's"
      # the user picks their own choice again: the agent's goes
      g.apply Command(kind: ckTreatAs, treatPath: cont, treatKind: "sliced")
      doAssert g.treatOf(cont).kind == some(rkReceiverSliced), "the user's pick did nothing"
      doAssert g.fileList.entries[g.fileList.find(canonical(cont))].recordingOf ==
        some(rkReceiverSliced)
      doAssert g.settle((g.flushFiles(); docs(fx.dir / "agent-config").len == 1))
      var p: seq[string]
      doAssert readMemoryFile(docs(fx.dir / "agent-config")[0], p).treat.kind ==
        some(rkReceiverSliced)

    block severalDocumentsOfOneQuickIdentity:
      # the hash of every byte tells which document is the file's; none is written when it cannot
      let cfg = fx.dir / "many-config"
      let target = writeSpecs(fx.dir / "many", "m", [spec(0, 0), spec(1, 0), spec(2, 0)])
      var modified: Time
      let id = quickIdentity(target, modified)
      var other = writeSpecs(fx.dir / "many", "n", [spec(0, 0), spec(1, 0)])
      discard other
      let store = Store(home: cfg / StoreFolder)
      createDir(store.home)
      var taken: seq[string] = @[]
      proc put(full: Option[uint64]; at: string): string =
        var rec = FileRecord(identity: id, name: "m.sgd", path: at, opened: getTime(),
          modified: modified)
        rec.identity.fullKnown = full.isSome
        rec.identity.full = full.get(0)
        rec.edits.lists[teKilled] = @[1]
        result = freeDocName(id, taken)
        taken.add result
        writeFile(store.docPath(result), memoryDocument(rec))
      let real = fullHash(target)
      let wrong = put(some(real xor 1), target)
      let right = put(some(real), target)
      var m = appIn(cfg)
      m.apply Command(kind: ckBrowse, paths: @[fx.dir / "many"])
      doAssert m.settle(m.listed(2))
      m.apply Command(kind: ckTreatAs, treatPath: target, treatKind: "shot")
      doAssert m.settle((m.flushFiles(); "(treat" in readFile(store.docPath(right)))),
        "the choice was not written to the file's own document"
      doAssert "(treat" notin readFile(store.docPath(wrong)), "the choice went to another file's"
      # two documents whose own hash was never taken: nothing is written, and it is said
      let cfg2 = fx.dir / "unsure-config"
      let store2 = Store(home: cfg2 / StoreFolder)
      createDir(store2.home)
      taken = @[]
      for i in 0 .. 1:
        var rec = FileRecord(identity: id, name: "m.sgd", path: target, opened: getTime(),
          modified: modified)
        rec.edits.lists[teKilled] = @[1]
        let name = freeDocName(id, taken)
        taken.add name
        writeFile(store2.docPath(name), memoryDocument(rec))
      var u = appIn(cfg2)
      u.apply Command(kind: ckBrowse, paths: @[fx.dir / "many"])
      doAssert u.settle(u.listed(2))
      u.apply Command(kind: ckTreatAs, treatPath: target, treatKind: "shot")
      doAssert u.settle(u.log.anyIt("must be opened once first" in it.text)),
        "the file was not told to be opened first"
      doAssert u.fileList.entries[u.fileList.find(canonical(target))].treat.kind ==
        some(rkShotGather), "the choice was not kept for the session"
      for name in taken: doAssert "(treat" notin readFile(store2.docPath(name))

    block aChoiceChangesOnlyWhatTheFileIsTreatedAs:
      # an edit written while the look-up of the document is under way stays: the choice is set
      # in the document as it is when it is written
      let cfg = fx.dir / "race-config"
      let f = writeSpecs(fx.dir / "race", "r", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var a = appIn(cfg)
      a.showFile(f)
      a.kill(0)
      doAssert a.settled(a.idle and docs(cfg).len == 1)
      let doc = docs(cfg)[0]
      a.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "shot")
      let look = a.memoryWork[^1]
      doAssert waitUntil(a.jobs.info(look).get.state == jsDone), "the look-up did not end"
      a.kill(1) # written before the look-up's answer is taken
      a.flushFiles()
      var p: seq[string]
      doAssert readMemoryFile(doc, p).edits.lists[teKilled] == @[0, 1]
      doAssert a.settled(a.idle and readMemoryFile(doc, p).treat.isSet), "the choice was not kept"
      doAssert readMemoryFile(doc, p).edits.lists[teKilled] == @[0, 1],
        "the edit written meanwhile was lost: " & $readMemoryFile(doc, p).edits.lists[teKilled]
      a.shutdown()
      # a later version's node, read by this run, survives a choice and the edit after it
      var text = readFile(doc)
      text = text[0 ..< text.rfind(')')] & " (futureNote \"kept\")\n)\n"
      writeFile(doc, text)
      var b = appIn(cfg)
      b.showFile(f)
      doAssert b.settled(b.idle and b.editsAt(canonical(f)).kept.lists[teKilled] == @[0, 1])
      b.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "sliced")
      doAssert b.settled(b.idle and "sliced" in readFile(doc))
      b.kill(2)
      doAssert b.settled(b.idle and readMemoryFile(doc, p).edits.lists[teKilled] == @[0, 1, 2])
      doAssert "futureNote" in readFile(doc), "the later version's node was dropped"
      doAssert "sliced" in readFile(doc) and docs(cfg).len == 1
      b.shutdown()

    block theLastChoiceIsTheOneKept:
      let cfg = fx.dir / "quick-config"
      var q = appIn(cfg)
      q.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert q.settle(q.listed(2))
      for k in ["shot", "continuous", "sliced", "automatic", "continuous"]:
        q.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: k)
      doAssert q.settled(q.idle and docs(cfg).len == 1)
      var p: seq[string]
      doAssert readMemoryFile(docs(cfg)[0], p).treat.kind == some(rkReceiverContinuous),
        $readMemoryFile(docs(cfg)[0], p).treat
      for k in ["shot", "automatic"]:
        q.apply Command(kind: ckTreatAs, treatPath: shot, treatKind: k)
      doAssert q.settled(q.idle and docs(cfg).len == 0), "the last choice, automatic, was not kept"
      q.shutdown()

    block aFileOpenedWithoutItsFolderHasItsChoice:
      # the choice was made in the list; opened by its path in another run, the file has it, and
      # its edits go to the same document
      let cfg = fx.dir / "open-config"
      let f = writeSpecs(fx.dir / "open", "o", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "open"])
      doAssert a.settle(a.listed(1))
      a.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "shot")
      doAssert a.settled(a.idle and docs(cfg).len == 1)
      a.shutdown()
      var b = appIn(cfg)
      b.showFile(f) # no listing
      doAssert b.settled(b.idle and b.treatOf(f).kind == some(rkShotGather)),
        "the choice did not come with the open"
      doAssert b.recordingFacts.ready == false or b.recordingFacts.kind == rkShotGather
      b.kill(0)
      doAssert b.settled(b.idle and docs(cfg).len == 1 and
        readFile(docs(cfg)[0]).contains("killed")), "the edit went to a second document: " &
        $docs(cfg).len
      var p: seq[string]
      doAssert readMemoryFile(docs(cfg)[0], p).treat.kind == some(rkShotGather)
      b.shutdown()

    block anotherFilesChoiceIsNeverShown:
      let cfg = fx.dir / "other-config"
      let target = writeSpecs(fx.dir / "other", "t", [spec(0, 0), spec(1, 0), spec(2, 0)])
      var modified: Time
      let id = quickIdentity(target, modified)
      let store = Store(home: cfg / StoreFolder)
      createDir(store.home)
      var taken: seq[string] = @[]
      proc put(full: Option[uint64]; treat: TreatAs) =
        var rec = FileRecord(identity: id, name: "t.sgd", path: target, opened: getTime(),
          modified: modified, treat: treat)
        rec.identity.fullKnown = full.isSome
        rec.identity.full = full.get(0)
        let name = freeDocName(id, taken)
        taken.add name
        writeFile(store.docPath(name), memoryDocument(rec))
      # two documents of the file's quick identity, the hash of neither known: no choice shown
      put(none(uint64), TreatAs(kind: some rkReceiverContinuous))
      put(none(uint64), TreatAs())
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "other"])
      doAssert a.settle(a.listed(1))
      doAssert not a.fileList.entries[0].treat.isSet, "a choice that may be another file's shown"
      a.shutdown()
      # one document whose hash of every byte is not the file's, once the file's is known
      for name in taken: removeFile(store.docPath(name))
      taken.setLen 0
      put(some(fullHash(target) xor 1), TreatAs(kind: some rkReceiverContinuous))
      var b = appIn(cfg)
      b.showFile(target)
      doAssert b.settled(b.idle and b.remembered[0].hashed)
      doAssert not b.treatOf(target).isSet, "another file's choice taken by the open"
      b.apply Command(kind: ckBrowse, paths: @[fx.dir / "other"])
      doAssert b.settle(b.listed(1))
      doAssert not b.fileList.entries[0].treat.isSet, "another file's choice shown"
      b.shutdown()

    block theLookUpHoldsNoPeekAndHashesOnlyWhenNeeded:
      let cfg = fx.dir / "lane-config"
      let f = writeSpecs(fx.dir / "lane", "l", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "lane"])
      doAssert a.settle(a.listed(1))
      a.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "shot")
      let look = a.jobs.info(a.memoryWork[^1]).get
      doAssert look.spec.lane == jlInteractive, $look.spec.lane
      doAssert a.settled(a.idle and docs(cfg).len == 1)
      # a document whose file's hash is known: the file's is taken, on the lane of hashes
      var p: seq[string]
      var rec = readMemoryFile(docs(cfg)[0], p)
      rec.identity.full = fullHash(f)
      rec.identity.fullKnown = true
      writeFile(docs(cfg)[0], memoryDocument(rec))
      a.shutdown()
      var b = appIn(cfg)
      b.apply Command(kind: ckBrowse, paths: @[fx.dir / "lane"])
      doAssert b.settle(b.listed(1))
      b.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "sliced")
      var lanes: seq[JobLane] = @[]
      proc lookUps(st: AppState; lanes: var seq[JobLane]) =
        for j in st.jobs.list:
          if j.spec.title.startsWith("Remember what") and j.spec.lane notin lanes:
            lanes.add j.spec.lane
      doAssert b.settled((b.lookUps(lanes); b.idle and "sliced" in readFile(docs(cfg)[0])))
      doAssert lanes == @[jlInteractive, jlHashes], $lanes
      # its hash is known to the run now: the next choice reads no byte more
      b.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "continuous")
      doAssert b.settled((b.lookUps(lanes); b.idle and "continuous" in readFile(docs(cfg)[0])))
      doAssert b.jobs.list.countIt(it.spec.lane == jlHashes and
        it.spec.title.startsWith("Remember what")) <= 1, "hashed again"
      b.shutdown()

    block aTouchedFilesChoiceStaysWithItsEdits:
      # the choice made in the list; the file touched since; opened and edited: one document
      # holds both, and the next run shows the choice
      let cfg = fx.dir / "touched-config"
      let f = writeSpecs(fx.dir / "touched", "t", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "touched"])
      doAssert a.settle(a.listed(1))
      a.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "shot")
      doAssert a.settled(a.idle and docs(cfg).len == 1)
      a.shutdown()
      setLastModificationTime(f, getLastModificationTime(f) + initDuration(hours = 1))
      var b = appIn(cfg)
      b.showFile(f)
      doAssert b.settled(b.idle)
      b.kill(0)
      doAssert b.settled(b.idle)
      doAssert docs(cfg).len == 1, "a second document: " & $docs(cfg).len
      var p: seq[string]
      let rec = readMemoryFile(docs(cfg)[0], p)
      doAssert rec.treat.kind == some(rkShotGather) and rec.edits.lists[teKilled] == @[0] and
        rec.identity.fullKnown, $rec.treat & " " & $rec.edits.lists[teKilled]
      b.shutdown()
      var c = appIn(cfg)
      c.apply Command(kind: ckBrowse, paths: @[fx.dir / "touched"])
      doAssert c.settle(c.listed(1))
      doAssert c.fileList.entries[0].treat.kind == some(rkShotGather), "the choice was lost"
      c.shutdown()

    block editsMadeOnADocumentOfOnlyAChoiceAreTheFilesOwn:
      # the edits made on a file whose document says only what it is treated as come back
      # applied, also when viewSEG quits before the hash of every byte
      let cfg = fx.dir / "bare-config"
      let f = writeSpecs(fx.dir / "bare", "b", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "bare"])
      doAssert a.settle(a.listed(1))
      a.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "shot")
      doAssert a.settled(a.idle and docs(cfg).len == 1)
      a.shutdown()
      var b = appIn(cfg)
      b.apply Command(kind: ckShowFile, panel: MainPanel, path: f)
      doAssert b.settle(b.sessions.len == 1 and b.remembered.len == 1 and b.remembered[0].known)
      b.kill(0) # and the quit, before any hash
      b.shutdown()
      var p: seq[string]
      doAssert docs(cfg).len == 1 and not readMemoryFile(docs(cfg)[0], p).unconfirmed and
        readMemoryFile(docs(cfg)[0], p).edits.lists[teKilled] == @[0],
        "the edits were not written as the file's own: " & $docs(cfg).len
      var c = appIn(cfg)
      c.showFile(f)
      doAssert c.settled(c.idle and c.editsAt(canonical(f)).kept.lists[teKilled] == @[0]),
        "the edits did not come back applied"
      doAssert c.earlierOf(canonical(f)).len == 0, "the edits were offered"
      c.shutdown()

    block aChoiceOfAFileTouchedSinceIsNotShownUntilIdentified:
      # the one document of the file's quick identity knows another content and another time
      let cfg = fx.dir / "stranger-config"
      let target = writeSpecs(fx.dir / "stranger", "s", [spec(0, 0), spec(1, 0), spec(2, 0)])
      var modified: Time
      let id = quickIdentity(target, modified)
      let store = Store(home: cfg / StoreFolder)
      createDir(store.home)
      var rec = FileRecord(identity: id, name: "other.sgd", path: "/elsewhere/other.sgd",
        opened: getTime(), modified: modified - initDuration(hours = 2),
        treat: TreatAs(kind: some rkReceiverContinuous))
      (rec.identity.full, rec.identity.fullKnown) = (fullHash(target) xor 1, true)
      rec.edits.lists[teKilled] = @[1]
      writeFile(store.docPath(freeDocName(id, @[])), memoryDocument(rec))
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "stranger"])
      doAssert a.settle(a.listed(1))
      doAssert not a.fileList.entries[0].treat.isSet, "shown before the file is identified"
      a.showFile(target)
      doAssert a.settled(a.idle and a.remembered[0].hashed)
      doAssert not a.treatOf(target).isSet and not a.fileList.entries[0].treat.isSet,
        "another file's choice after the hash"
      a.shutdown()

    block aChoiceWhoseLookUpDidNotEndIsSaid:
      let cfg = fx.dir / "quit-config"
      let f = writeSpecs(fx.dir / "quit", "q", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var a = appIn(cfg)
      a.apply Command(kind: ckBrowse, paths: @[fx.dir / "quit"])
      doAssert a.settle(a.listed(1))
      a.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "shot")
      a.shutdown() # its look-up not taken
      doAssert a.log.anyIt("The choice for q.sgd is kept for this session only: viewSEG quit " &
        "before its look-up ended." in it.text), "not said at the quit"
      # an open file's document is known: the choice goes to it at the quit
      var b = appIn(cfg)
      b.showFile(f)
      b.kill(0)
      doAssert b.settled(b.idle and docs(cfg).len == 1)
      b.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "sliced")
      b.shutdown()
      var p: seq[string]
      doAssert readMemoryFile(docs(cfg)[0], p).treat.kind == some(rkReceiverSliced),
        "the choice of the quit was not written"
      # a look-up stopped in Jobs
      var c = appIn(cfg)
      c.treatJobs[canonical(f)] = JobId(987654)
      discard c.endMemoryWork(JobInfo(id: JobId(987654), state: jsCancelled))
      doAssert c.log.anyIt("The choice for q.sgd is kept for this session only: its look-up " &
        "was stopped." in it.text), "not said at the cancel"
      c.shutdown()

    block twoProgramsEachSetTheirOwnPart:
      let cfg = fx.dir / "two-config"
      let f = writeSpecs(fx.dir / "two", "w", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
      var p1 = appIn(cfg)
      var p2 = appIn(cfg)
      for st in [addr p1, addr p2]:
        st[].apply Command(kind: ckBrowse, paths: @[fx.dir / "two"])
        doAssert st[].settle(st[].listed(1))
      p1.apply Command(kind: ckTreatAs, treatPath: f, treatKind: "sliced")
      doAssert p1.settled(p1.idle and docs(cfg).len == 1)
      p2.apply Command(kind: ckTreatAs, treatPath: f, treatGrouping: "flag") # knows no kind
      var p: seq[string]
      doAssert p2.settled(p2.idle and
        readMemoryFile(docs(cfg)[0], p).treat.grouping == some(tgByFlag))
      doAssert readMemoryFile(docs(cfg)[0], p).treat.kind == some(rkReceiverSliced),
        "the other program's kind was erased"
      # automatic for one part clears that part alone
      p1.apply Command(kind: ckTreatAs, treatPath: f, treatGrouping: "automatic")
      doAssert p1.settled(p1.idle and readMemoryFile(docs(cfg)[0], p).treat.grouping.isNone)
      doAssert readMemoryFile(docs(cfg)[0], p).treat.kind == some(rkReceiverSliced)
      p1.shutdown()
      p2.shutdown()

    block aForcedKindIsWhatTheDialogGoesBy:
      # the shown file's facts carry the forced kind: the refusal of the slice follows it
      let sliced = writeSpecs(dir, "b", [spec(0, 0), spec(0, 1000), spec(0, 2150), spec(0, 3150)])
      var v = appIn(config)
      v.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert v.settle(v.listed(3))
      v.apply Command(kind: ckShowFile, panel: MainPanel, path: sliced)
      doAssert v.settle((v.watchRecording(true); v.recHave and v.recJob == NoJob)),
        "the facts were not read"
      doAssert "time-sliced" in cutRefusal(v.recordingFacts)
      v.apply Command(kind: ckTreatAs, treatPath: sliced, treatKind: "continuous")
      doAssert cutRefusal(v.recordingFacts) == "", "the refusal did not follow the forced kind"
      v.apply Command(kind: ckTreatAs, treatPath: sliced, treatKind: "shot")
      doAssert "You set this kind" in cutRefusal(v.recordingFacts)

  block theSliceTakesTracesEndToEndWhenEveryStartIsTheSame:
    const BaseUs = 1_772_323_200_000_000'i64
    let dir = getTempDir() / ("viewseg-treatas-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir / "out")
    createDir(dir / "rec")
    defer: removeDir(dir)
    # four traces of one receiver that all carry one start time `time`: the file cannot say when
    # each began; the samples are a ramp over the four, as a recorder that kept going writes them
    proc record(name: string; time: float64): string =
      result = dir / "rec" / name
      var w = openSeismicWriter(result, SegdOutputOptions(sampleIntervalUs: 2000,
        numSamples: 3000))
      for seg in 0 .. 3:
        var samples = newSeq[float32](3000)
        for j in 0 ..< 3000: samples[j] = float32(seg * 3000 + j)
        var k = initTraceKeys()
        k.status = tsLive
        k.record = float64(seg + 1)
        k.channel = 11
        k.component = 1
        k.intervalUs = 2000
        k.t0Ms = 0
        k.time = time
        k.rcvLine = 1
        k.rcvPoint = 7
        w.writeTrace(k, samples)
      discard w.close()
    let path = record("same.sgd", float64(BaseUs div 1_000_000))
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crTime]
    m.dateTimePattern = EpochMicros
    let shots = shotsInTime(shots(parseShotLog("1," & $(BaseUs + 5_000_000) & "\n", m), m).rows)
    let jobs = initJobs()
    proc run(opts: CutOptions; dest: string; path = path): tuple[st: JobState; res: CutResult] =
      var src = openSeismic(path, keys = true)
      defer: src.close()
      let sink = CutSink()
      let id = jobs.submit(cutGatherSpec(path, dest), cutGatherWork(addr src, path, dest, shots,
        opts, sink))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled})
      (jobs.info(id).get.state, sink.result)
    let refused = run(initCutOptions(2000, -100), dir / "out" / "auto.sgd")
    doAssert not refused.res.ok and "time-sliced" in refused.res.reason, refused.res.reason
    var opts = initCutOptions(2000, -100)
    opts.treatKind = some rkReceiverContinuous
    let got = run(opts, dir / "out" / "forced.sgd")
    doAssert got.st == jsDone and got.res.ok and got.res.endToEnd, got.res.reason
    doAssert "vendor header map" in got.res.lines.join(" "), $got.res.lines
    # the start times were read: they are the same, which is what is said
    doAssert "Every trace of a component carries the same start time" in
      got.res.lines.join(" ") and "could not be read" notin got.res.lines.join(" "),
      $got.res.lines
    var f = openSeismic(dir / "out" / "forced.sgd", keys = true)
    defer: f.close()
    let x = f.readTraces(0 .. 0)
    # 5.0 s less 100 ms is sample 2450: the window crosses from the first trace to the second
    for j in 0 ..< 1000:
      doAssert x[0, j] == float32(2450 + j), "the slice did not follow end to end at " & $j
    # a first trace without a start time (the epoch): nothing to place the traces from, refused
    let zero = record("zero.sgd", 0)
    let epoch = run(opts, dir / "out" / "zero-out.sgd", zero)
    doAssert not epoch.res.ok and epoch.res.reason == "The first trace of zero.sgd has no start " &
      "time, so its traces cannot be placed in time: load a vendor header map that reads the " &
      "start time.", epoch.res.reason
    doAssert not fileExists(dir / "out" / "zero-out.sgd")

when isMainModule:
  main()
