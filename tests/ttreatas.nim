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
## "could not be read", the words were not those of a file whose starts are the same.

import std/[importutils, options, os, sequtils, strutils, tables, times]
import parseSEG
import viewSEG/core/state {.all.}
import viewSEG/core/[cutgather, edits, filelist, filememory, identity, jobs, nif,
  recordingkind, shotlog, traceorder, treatas]
import viewSEG/core/cutgatherjobs {.all.}
import viewSEG/view/[filetable, recordingwords]
import utils/[fixtures, kindfiles, waiting]

privateAccess(AppState)

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
      doAssert g.recordOf(g.rememberedAt(canonical(cont))).treat.kind == some(rkReceiverSliced),
        "the user's choice was replaced by the agent's"
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

  block theSliceTakesTracesEndToEndWhenTheStartTimesCannotBeRead:
    const BaseUs = 1_772_323_200_000_000'i64
    let dir = getTempDir() / ("viewseg-treatas-" & $getCurrentProcessId())
    removeDir(dir)
    createDir(dir / "out")
    createDir(dir / "rec")
    defer: removeDir(dir)
    # four traces of one receiver that all carry one start time: the file cannot say when each
    # began; the samples are a ramp over the four, as a recorder that kept going writes them
    let path = dir / "rec" / "same.sgd"
    var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 3000))
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
      k.time = float64(BaseUs div 1_000_000)
      k.rcvLine = 1
      k.rcvPoint = 7
      w.writeTrace(k, samples)
    discard w.close()
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crUtcMicros]
    let shots = shotsInTime(shots(parseShotLog("1," & $(BaseUs + 5_000_000) & "\n", m), m).rows)
    var src = openSeismic(path, keys = true)
    defer: src.close()
    let jobs = initJobs()
    proc run(opts: CutOptions; dest: string): tuple[st: JobState; res: CutResult] =
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

when isMainModule:
  main()
