## Which auxiliary traces a correlation correlates: only those whose position is marked,
## each after its own shift. A mark belongs to a file (its edits, remembered with it) or to
## the project; the file's entry wins, then the project's, else the trace is not marked.
##
## (a) with no mark no auxiliary trace is correlated, the reference-coded one included:
## it is cut to the listen time, raw, on every path.
## (b) a file mark with shift 0 and with 500 ms: peak position, peak amplitude, written delay.
## (c) a project mark holds for two files; a file's "not marked" and a file's own shift win.
## (d) a file of auxiliary traces only takes its length and interval from the marked ones,
## SEG-Y and SEG-D, and refuses with the sentence when none is marked.
## (e) the correlated view (in memory, and on demand by its readers) equals the written file.
## (f) marks survive the file's memory document, the project document, and the commands.
## (g) a marked position a record lacks is skipped, said once.
## (h) the per-record pilot rule with a marked pilot, and with an unmarked one.
##
## Seen to fail: with the reference-coded traces marked whatever the marks, (a) found a
## marked trace where none was given (`picked.marked.len == 0`); with every shift
## taken as 500 ms, (b) found the shift-0 peak at 250; with the project's marks left
## out of the resolution, (c) found trace 3 of the first file raw; with the shape taken
## from seismic traces only, (d) refused a file whose auxiliary trace was marked; with
## the view's shifts left out, (e) differed from the file at trace 3 (1.0 against 0.0);
## with `auxMarks` left out of the memory document, (f) read back none; with a position
## a record lacks given the record's last auxiliary trace, (g) listed trace 6 twice; with
## each record's pilot trace marked whatever the marks, (h) found the unmarked pilot
## trace correlated.

import std/[math, options, os, sequtils, strutils, times]
import parseSEG
import processSEG
import viewSEG/core/[correlatejobs, correlateread, edits, filememory, jobs, nif, outputjobs,
  processing, project, projectnif, references, session]
import viewSEG/core/state {.all.}
import utils/[fixtures, waiting]

const
  DtMs = 2.0
  Record = 1000
  SweepLen = 200
  Listen = 800
  Delays = [40, 100, 200]
  AuxDelayMs = 20.0 ## the delay the first auxiliary trace is recorded with
  NoMarkSentence =
    "the file has no seismic traces and no auxiliary trace is marked for correlation."

type RecordSpec = object
  sweep: seq[float32]
  seismic, aux: int ## live traces, then auxiliary ones: the first holds the sweep

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc delayedSweep(sweep: openArray[float32]; samples, delay: int): seq[float32] =
  result = newSeq[float32](samples)
  for i in 0 ..< samples:
    let j = i - delay
    if j >= 0 and j < sweep.len: result[i] = sweep[j]

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc peakAt(x: openArray[float32]): int =
  var best = -1.0
  for i, v in x:
    if abs(float64(v)) > best:
      best = abs(float64(v))
      result = i

proc writeRecords(path: string; recs: openArray[RecordSpec]; segd = false) =
  ## One record for each of `recs` (numbered 7, 8, ...): live traces at 40, 100 and 200
  ## samples, then the auxiliary traces. The first holds the sweep at 0 and is recorded
  ## with a delay of `AuxDelayMs`; the others are ramps.
  var w =
    if segd:
      openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: DtMs * 1000.0,
        numSamples: Record, time: 1_700_000_000.0))
    else:
      openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
        text: @["C01 marked auxiliary traces"]))
  for r, rec in recs:
    for i in 0 ..< rec.seismic + rec.aux:
      var buf: seq[float32]
      var k = initTraceKeys()
      if i < rec.seismic:
        buf = delayedSweep(rec.sweep, Record, Delays[i mod Delays.len])
        (k.traceCode, k.status) = (1'i16, tsLive)
      elif i == rec.seismic:
        buf = delayedSweep(rec.sweep, Record, 0)
        (k.traceCode, k.status) = (5'i16, tsAuxiliary)
        k.t0Ms = AuxDelayMs
      else:
        buf = newSeq[float32](Record)
        for j in 0 ..< Record: buf[j] = float32(j + 1)
        (k.traceCode, k.status) = (6'i16, tsAuxiliary)
        if segd: k.t0Ms = AuxDelayMs # a SEG-D channel set has one start time
      k.record = float64(7 + r)
      k.channel = float64(i + 1)
      k.intervalUs = DtMs * 1000.0
      k.time = 1_700_000_000.0
      if segd:
        w.writeTrace(k, buf, channelType = (if k.status == tsAuxiliary: sctOther
          else: sctSeismic))
      else:
        w.writeTrace(k, buf)
  doAssert w.close().len == 0, "the file did not close"

proc spec(path: string): JobSpec =
  JobSpec(title: "Correlate " & path.extractFilename, lane: jlBackground,
    reads: @[path], cancellable: true)

proc correlated(file: var SeismicFile; path: string; sweep: seq[float32];
    fileMarks, projectMarks: seq[AuxMarkEntry]): CorrelateResult =
  ## The correlation job on what the marks pick, finished (`result.ok` says whether it did).
  let picked = markedAuxiliaries(addr file, fileMarks, projectMarks)
  var jobs = initJobs()
  result.opened = nil
  result.lines = @[]
  try:
    let id = jobs.submit(spec(path), correlateWork(CorrelateAsk(
      file: addr file, path: path, reference: sweep, referenceDtMs: DtMs,
      marked: picked.marked, markNotes: picked.notes), addr result))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
      "the correlation did not finish"
  finally:
    jobs.stop()

proc written(file: var SeismicFile; source, dest: string; sweep: seq[float32];
    edits: FileEdits; projectMarks: seq[AuxMarkEntry]; pilot = none(PilotRule);
    format = ofSegy): tuple[ok: bool; reason: string; lines: seq[string]] =
  ## Output with the correlated option on, as the Output window runs it.
  let jobs = initJobs()
  let sink = OutputSink()
  let opts = OutputOptions(format: format, correlation: some(OutputCorrelation(
    reference: sweep, referenceDtMs: DtMs, projectMarks: projectMarks, pilot: pilot)))
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, edits, @[source], sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not finish"
  (jobs.state(id) == jsDone, sink.result.reason, sink.result.lines)

func mark(position: int; ms: float64): AuxMarkEntry =
  AuxMarkEntry(position: position, marked: true, ms: ms)

proc edited(entries: varargs[AuxMarkEntry]): FileEdits =
  for e in entries:
    doAssert result.setAuxMark(e.position, (if e.marked: amMarked else: amNotMarked),
      e.ms) == 1, "the mark was refused"

proc sameSamples(a, b: openArray[float32]; what: string) =
  doAssert a.len == b.len, what & ": " & $a.len & " samples, not " & $b.len
  for j in 0 ..< a.len:
    doAssert a[j] == b[j], what & " sample " & $j & ": " & $a[j] & " vs " & $b[j]

proc raw(f: SeismicFile; trace: int): seq[float32] =
  ## The recorded trace cut to the listen time.
  samplesOf(f, trace)[0 ..< Listen]

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc main*() =
  let base = getTempDir() / ("tauxcorrelate-" & $getCurrentProcessId())
  let dir = base / "src"
  let outDir = base / "out"
  createDir(dir)
  createDir(outDir)
  defer: removeDir(base)
  let sweep = linearSweep(8.0, 80.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  let other = linearSweep(20.0, 60.0, float64(SweepLen) * DtMs, DtMs).sweepSamples(float32)
  let one = [RecordSpec(sweep: sweep, seismic: 3, aux: 2)]
  let path = dir / "raw.sgy"
  writeRecords(path, one)
  var file = openSeismic(path, keys = true)
  defer: file.close()
  doAssert file.len == 5 and file.traceKeys(3).status == tsAuxiliary, "the layout is wrong"

  block noMarkNoCorrelation:
    ## (a) the reference-coded trace 3 and the ramp 4 are cut, raw; the seismic traces peak
    ## at their arrivals.
    let picked = markedAuxiliaries(addr file, [], [])
    doAssert picked.marked.len == 0 and picked.notes.len == 0
    let made = correlated(file, path, sweep, @[], @[])
    doAssert made.ok, made.failure
    let f = made.opened.filePtr
    defer: discard made.opened.close()
    for t in 3 .. 4:
      sameSamples(samplesOf(f[], t), raw(file, t), "unmarked trace " & $t & " was correlated")
    for t in 0 .. 2: doAssert peakAt(samplesOf(f[], t)) == Delays[t], "seismic trace " & $t
    doAssert made.lines[1] == "sweep 400 ms.", $made.lines
    let dest = outDir / "a-out.sgy"
    let got = written(file, path, dest, sweep, FileEdits(), @[])
    doAssert got.ok, got.reason
    var out1 = openSeismic(dest, keys = true)
    for t in 0 ..< 5: sameSamples(samplesOf(out1, t), samplesOf(f[], t), "output trace " & $t)
    doAssert out1.traceKeys(3).t0Ms == AuxDelayMs, "the delay was changed: " &
      $out1.traceKeys(3).t0Ms
    out1.close()

  block fileMarkShifts:
    ## (b) shift 0: the peak stays at sample 0 and keeps its height, the delay is the
    ## file's own. Shift 500: the peak is 250 samples on, and the delay is its own less 500.
    for ms in [0.0, 500.0]:
      let marks = edited(mark(1, ms)).auxMarks
      let picked = markedAuxiliaries(addr file, marks, [])
      doAssert picked.marked == @[AuxMark(trace: 3, shiftMs: ms)], $picked.marked
      let made = correlated(file, path, sweep, marks, @[])
      doAssert made.ok, made.failure
      let f = made.opened.filePtr
      let at = peakAt(samplesOf(f[], 3))
      doAssert at == int(ms / DtMs), "the peak is at " & $at & " with " & $ms & " ms"
      doAssert abs(abs(samplesOf(f[], 3)[at]) - 1.0) < 1e-3, "the peak is " &
        $samplesOf(f[], 3)[at]
      sameSamples(samplesOf(f[], 4), raw(file, 4), "ramp trace 4")
      doAssert (ms == 0.0) == ("sweep 400 ms." == made.lines[1]), $made.lines
      doAssert ms == 0.0 or made.lines[1] == "sweep 400 ms. 1 reference trace delayed by " &
        "500 ms.", $made.lines
      let dest = outDir / ("b-" & $int(ms) & ".sgy")
      let got = written(file, path, dest, sweep, edited(mark(1, ms)), @[])
      doAssert got.ok, got.reason
      var out1 = openSeismic(dest, keys = true)
      sameSamples(samplesOf(out1, 3), samplesOf(f[], 3), "output trace 3")
      doAssert out1.traceKeys(3).t0Ms == AuxDelayMs - ms, "delay " & $out1.traceKeys(3).t0Ms
      doAssert out1.traceKeys(4).t0Ms == 0.0, "the ramp's delay was changed"
      out1.close()
      discard made.opened.close()
    let negative = correlated(file, path, sweep, edited(mark(1, -100.0)).auxMarks, @[])
    doAssert negative.ok and negative.lines[1] ==
      "sweep 400 ms. 1 reference trace advanced by 100 ms.", "an earlier shift: " &
      $negative.lines
    doAssert samplesOf(negative.opened.filePtr[], 3) != raw(file, 3), "an earlier shift left it raw"
    discard negative.opened.close()

  block projectAndFile:
    ## (c) the project's mark holds in two files; a file's "not marked" and a file's own
    ## shift win over it.
    let pathB = dir / "second.sgy"
    writeRecords(pathB, one)
    var fileB = openSeismic(pathB, keys = true)
    defer: fileB.close()
    let project = @[mark(1, 500.0)]
    for (name, source, f) in [("a", path, addr file), ("b", pathB, addr fileB)]:
      let made = correlated(f[], source, sweep, @[], project)
      doAssert made.ok, made.failure
      doAssert peakAt(samplesOf(made.opened.filePtr[], 3)) == 250, "file " & name
      discard made.opened.close()
    let off = edited(AuxMarkEntry(position: 1, marked: false))
    doAssert markedAuxiliaries(addr file, off.auxMarks, project).marked.len == 0
    let notMarked = correlated(file, path, sweep, off.auxMarks, project)
    doAssert notMarked.ok, notMarked.failure
    sameSamples(samplesOf(notMarked.opened.filePtr[], 3), raw(file, 3),
      "a file's not-marked left trace 3 correlated")
    discard notMarked.opened.close()
    let own = correlated(fileB, pathB, sweep, edited(mark(1, 0.0)).auxMarks, project)
    doAssert own.ok and peakAt(samplesOf(own.opened.filePtr[], 3)) == 0,
      "a file's own shift did not win"
    discard own.opened.close()
    # the Output window's path: the project's marks, then the file's edits
    let outA = written(file, path, outDir / "c-a.sgy", sweep, off, project)
    let outB = written(fileB, pathB, outDir / "c-b.sgy", sweep, FileEdits(), project)
    doAssert outA.ok and outB.ok, outA.reason & outB.reason
    var a = openSeismic(outDir / "c-a.sgy", keys = true)
    var b = openSeismic(outDir / "c-b.sgy", keys = true)
    sameSamples(samplesOf(a, 3), raw(file, 3), "output of the file that is not marked")
    doAssert peakAt(samplesOf(b, 3)) == 250, "output of the project's mark"
    a.close()
    b.close()

  block auxiliaryOnly:
    ## (d) the length and interval come from the marked traces; with none marked the
    ## file is refused in words, by the job, the view and Output.
    for segd in [false, true]:
      let name = dir / (if segd: "aux.sgd" else: "aux.sgy")
      writeRecords(name, [RecordSpec(sweep: sweep, seismic: 0, aux: 2)], segd)
      var f = openSeismic(name, keys = true)
      defer: f.close()
      doAssert f.len == 2 and f.traceKeys(0).status == tsAuxiliary
      let refused = correlated(f, name, sweep, @[], @[])
      doAssert not refused.ok and refused.failure == NoMarkSentence, refused.failure
      let view = initCorrelateView(addr f, sweep, DtMs, @[])
      doAssert view.refusal == NoMarkSentence, view.refusal
      let got = written(f, name, outDir / "d-refused", sweep, FileEdits(), @[])
      doAssert not got.ok and got.reason == NoMarkSentence, got.reason
      doAssert not fileExists(outDir / "d-refused"), "a refused write left a file"
      let marks = @[mark(1, 500.0)]
      let made = correlated(f, name, sweep, marks, @[])
      doAssert made.ok, made.failure
      let c = made.opened.filePtr
      doAssert c[].len == 2 and int(c[].traceEntry(0).numSamples) == Listen
      doAssert peakAt(samplesOf(c[], 0)) == 250, "the marked trace's peak"
      sameSamples(samplesOf(c[], 1), raw(f, 1), "the unmarked ramp")
      let built = initCorrelateView(addr f, sweep, DtMs, markedAuxiliaries(addr f, marks,
        []).marked)
      doAssert built.refusal.len == 0, built.refusal
      doAssert built.view.listenSamples == Listen and built.view.t0Ms == AuxDelayMs
      let dest = outDir / (if segd: "d-out.sgd" else: "d-out.sgy")
      let wrote = written(f, name, dest, sweep, FileEdits(), marks,
        format = (if segd: ofSegd else: ofSegy))
      doAssert wrote.ok, wrote.reason
      var o = openSeismic(dest, keys = true)
      sameSamples(samplesOf(o, 0), samplesOf(c[], 0), "output trace 0")
      sameSamples(samplesOf(o, 1), samplesOf(c[], 1), "output trace 1")
      o.close()
      discard made.opened.close()

  block viewEqualsFile:
    ## (e) the on-demand view, row by row and in blocks, is the written file.
    let marks = @[mark(1, 500.0), mark(2, 100.0)]
    let picked = markedAuxiliaries(addr file, marks, []).marked
    doAssert picked == @[AuxMark(trace: 3, shiftMs: 500.0), AuxMark(trace: 4, shiftMs: 100.0)]
    let made = correlated(file, path, sweep, marks, @[])
    doAssert made.ok, made.failure
    let f = made.opened.filePtr
    let built = initCorrelateView(addr file, sweep, DtMs, picked)
    doAssert built.refusal.len == 0, built.refusal
    var ws = newWorkspace(built.view)
    var rows = newSeq[float32](5 * Listen)
    readListenTraces(built.view, addr file, [0, 1, 2, 3, 4], rows, ws)
    doAssert ws.failed.len == 0
    for t in 0 ..< 5:
      sameSamples(rows[t * Listen ..< (t + 1) * Listen], samplesOf(f[], t),
        "the view's trace " & $t)
    var pool = newProcessPool(2)
    var blockRows = newSeq[float32](5 * Listen)
    correlateBlock(built.view, addr file, [0, 1, 2, 3, 4], 0, Listen, blockRows, ws, pool)
    sameSamples(blockRows, rows, "the view's block")
    let dest = outDir / "e-out.sgy"
    let got = written(file, path, dest, sweep, FileEdits(), marks)
    doAssert got.ok, got.reason
    var o = openSeismic(dest, keys = true)
    for t in 0 ..< 5: sameSamples(samplesOf(o, t), samplesOf(f[], t), "written trace " & $t)
    o.close()
    discard made.opened.close()

  block persistence:
    ## (f) the file's marks in its memory document, the project's in the project document.
    var rec = FileRecord(name: "x.sgy", path: "/x.sgy")
    rec.edits.auxMarks = @[AuxMarkEntry(position: 1, marked: true, ms: 500.5),
      AuxMarkEntry(position: 2, marked: false), AuxMarkEntry(position: 7, marked: true,
      ms: -30.0)]
    var problems: seq[string] = @[]
    let back = readMemory(parseNif(memoryDocument(rec), "x"), "x", problems)
    doAssert problems.len == 0 and back.edits.auxMarks == rec.edits.auxMarks,
      $problems & " " & $back.edits.auxMarks
    doAssert not back.edits.isEmpty and back.edits.count == 3
    var e = FileEdits()
    doAssert e.setAuxMark(1, amMarked, 250.0) == 1
    doAssert e.setAuxMark(1, amMarked, 250.0) == 0, "no change made a step"
    doAssert e.setAuxMark(2, amNotMarked) == 1
    doAssert e.setAuxMark(3, amMarked, Inf) == 0 and e.setAuxMark(0, amMarked, 1.0) == 0
    doAssert e.auxMarks.len == 2 and e.keptAuxMarks == e.auxMarks
    doAssert e.undoText == "auxiliary trace 2 marked not for correlation", e.undoText
    discard e.undo()
    doAssert e.auxMarks == @[mark(1, 250.0)]
    discard e.redo()
    doAssert e.setAuxMark(2, amForget) == 1 and e.auxMarks == @[mark(1, 250.0)]
    doAssert e.clearAll() and e.auxMarks.len == 0
    discard e.undo()
    doAssert e.auxMarks == @[mark(1, 250.0)], "undo of clear left the marks off"
    var agent = FileEdits()
    doAssert agent.setAuxMark(1, amMarked, 5.0, keep = false) == 1
    doAssert agent.auxMarks.len == 1 and agent.keptAuxMarks.len == 0
    # a document a later version wrote, and one with a bad entry
    var bad: seq[string] = @[]
    let odd = readMemory(parseNif("(fileMemory (version 1) (identity (size 1) " &
      "(quick \"0000000000000001\")) (auxMarks (aux 1 (marked true) (ms 5.0)) (aux 0 " &
      "(marked true) (ms 1.0)) (aux 2 (marked true)) (aux 3 (marked maybe)) (aux 4 " &
      "(marked false)) (later)))", "x"), "x", bad)
    doAssert odd.edits.auxMarks == @[mark(1, 5.0), AuxMarkEntry(position: 4)], $odd.edits
    doAssert bad.len == 3, $bad
    var doc = ProjectDoc(version: 1, name: "p")
    doc.auxMarks = @[mark(1, 500.0), mark(3, 0.0)]
    var pp: seq[string] = @[]
    let again = readProject(projectDocument(doc), "p", pp)
    doAssert pp.len == 0 and again.auxMarks == doc.auxMarks, $pp & $again.auxMarks
    var p2: seq[string] = @[]
    let dirty = readProject("(project (version 1) (auxMarks (aux 2 (ms 5.0)) (aux 2 " &
      "(ms 6.0)) (aux 0 (ms 1.0)) (aux 3 (ms \"x\")) (newer)))", "p", p2)
    doAssert dirty.auxMarks == @[mark(2, 5.0)] and dirty.auxMarksLater.len == 1, $dirty.auxMarks
    doAssert p2.len == 3, $p2
    doAssert "(newer)" in projectDocument(dirty)
    let none = readProject("(project (version 1))", "p", p2)
    doAssert none.auxMarks.len == 0

  block missingPosition:
    ## (g) record 7 has two auxiliary traces, record 8 one: position 2 is skipped in
    ## record 8 and said once; the file is not failed.
    let twoPath = dir / "two.sgy"
    writeRecords(twoPath, [RecordSpec(sweep: sweep, seismic: 2, aux: 2),
      RecordSpec(sweep: other, seismic: 2, aux: 1)])
    var f = openSeismic(twoPath, keys = true)
    defer: f.close()
    let marks = @[mark(1, 500.0), mark(2, 0.0)]
    let picked = markedAuxiliaries(addr f, marks, [])
    doAssert picked.marked.mapIt(it.trace) == @[2, 3, 6], $picked.marked
    doAssert picked.notes == @["Auxiliary trace 2 is marked for correlation but 1 record has " &
      "no such trace (the first is FFID 8): it is skipped there."], $picked.notes
    let made = correlated(f, twoPath, sweep, marks, @[])
    doAssert made.ok, made.failure
    doAssert made.lines.count(picked.notes[0]) == 1, $made.lines
    doAssert peakAt(samplesOf(made.opened.filePtr[], 2)) == 250, "record 7's first auxiliary"
    doAssert samplesOf(made.opened.filePtr[], 6) != raw(f, 6), "record 8's was left raw"
    doAssert samplesOf(made.opened.filePtr[], 3) != raw(f, 3), "record 7's second was left raw"
    discard made.opened.close()
    let got = written(f, twoPath, outDir / "g-out.sgy", sweep, FileEdits(), marks)
    doAssert got.ok, got.reason
    doAssert got.lines.count(picked.notes[0]) == 1, $got.lines

  block pilotRule:
    ## (h) each record's pilot is its first auxiliary trace. Marked, the pilot's own trace
    ## is correlated too (a peak at the shift); unmarked, it is written raw.
    let twoPath = dir / "pilots.sgy"
    writeRecords(twoPath, [RecordSpec(sweep: sweep, seismic: 2, aux: 1),
      RecordSpec(sweep: other, seismic: 2, aux: 1)])
    var f = openSeismic(twoPath, keys = true)
    defer: f.close()
    let rule = PilotRule(aux: true, trace: 1, startMs: 0.0,
      spanMs: float64(SweepLen) * DtMs)
    for marked in [false, true]:
      let dest = outDir / ("h-" & $marked & ".sgy")
      let got = written(f, twoPath, dest, @[], FileEdits(),
        (if marked: @[mark(1, 500.0)] else: @[]), pilot = some(rule))
      doAssert got.ok, got.reason
      var o = openSeismic(dest, keys = true)
      for t in [2, 5]:
        if marked: doAssert peakAt(samplesOf(o, t)) == 250, "marked pilot trace " & $t
        else: sameSamples(samplesOf(o, t), raw(f, t), "unmarked pilot trace " & $t)
      for t in [0, 1, 3, 4]:
        doAssert peakAt(samplesOf(o, t)) == Delays[t mod 3], "seismic trace " & $t
      o.close()

  withFixtures fx:
    ## The commands, and a view asked for again when a mark in force changes.
    let src = fx.dir / "cmd.sgy"
    writeRecords(src, one)
    var st = initAppState(watchEvery = initDuration(hours = 1))
    var settings = st.settings
    settings.files.prepareNext = false
    st.apply Command(kind: ckSettings, settings: settings)
    st.rememberFilesIn(fx.dir / "config")
    st.apply Command(kind: ckFileAuxMark, auxFile: src, auxPosition: 1, auxMarked: amMarked)
    doAssert st.said("is not open"), "a mark of a file that is not open was taken"
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: src)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    doAssert st.settle(st.referencesLoaded), "the archive was not read"
    let first = st.sessions[0].base
    st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "short",
      trace: first, fromMs: 0, toMs: 100))
    doAssert st.settle(st.references.entries.anyIt(it.name == "short")),
      "the sweep was not stored"
    for e in st.references.entries:
      if e.name == "short": st.apply Command(kind: ckSelectReference, refId: e.id)
    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
    proc derivedTrace(st: AppState; t: int): seq[float32] =
      for i in countdown(st.sessions.high, 0): # the newest view is the one shown
        if st.sessions[i].derived: return samplesOf(st.sessions[i].filePtr[], t)
    doAssert st.settle(st.sessions.anyIt(it.derived) and st.jobs.active.len == 0),
      "the correlated record was not shown"
    let unmarked = st.derivedTrace(3)
    sameSamples(unmarked, samplesOf(st.sessions.filterIt(not it.derived)[0].filePtr[], 3)[
      0 ..< unmarked.len], "no mark: trace 3 raw")
    st.apply Command(kind: ckFileAuxMark, auxFile: src, auxPosition: 1, auxMarked: amMarked,
      auxShiftMs: 500.0)
    doAssert st.settle(not st.correlating and st.derivedTrace(3) != unmarked),
      "the correlated view was not asked for again"
    let edits = st.editsAt(src)
    doAssert edits.auxMarks == @[mark(1, 500.0)] and edits.keptAuxMarks == edits.auxMarks
    let marked = st.derivedTrace(3)
    st.apply Command(kind: ckFileAuxMark, auxFile: src, auxPosition: 1, auxMarked: amMarked,
      auxShiftMs: 500.0)
    doAssert st.log.len > 0 and st.derivedTrace(3) == marked
    # an agent's mark is for the session: shown, not kept
    st.apply Command(kind: ckFileAuxMark, origin: coAgent, auxFile: src, auxPosition: 2,
      auxMarked: amMarked, auxShiftMs: 10.0)
    doAssert st.editsAt(src).auxMarks.len == 2 and st.editsAt(src).keptAuxMarks.len == 1
    st.apply Command(kind: ckFileAuxMark, auxFile: src, auxPosition: 0, auxMarked: amMarked)
    st.apply Command(kind: ckFileAuxMark, auxFile: src, auxPosition: 1, auxMarked: amMarked,
      auxShiftMs: Inf)
    doAssert st.editsAt(src).auxMarks.len == 2, "a refused mark changed the file"
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.editsAt(src).auxMarks.len == 1, "undo did not take the agent's mark back"
    st.apply Command(kind: ckFileAuxMark, auxFile: src, auxPosition: 1, auxMarked: amForget)
    doAssert st.settle(not st.correlating and st.derivedTrace(3) == unmarked),
      "forgetting the mark did not give the raw trace back"
    # the project's mark: refused with no project, then kept in the project
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 1, auxMarked: amMarked,
      auxShiftMs: 500.0)
    doAssert st.said(NeedProjectAuxMarks)
    discard st.shutdown()

  withFixtures fy:
    var st = initAppState()
    st.rememberFilesIn(fy.dir / "config")
    let field = fy.dir / "field"
    createDir(field)
    st.apply Command(kind: ckNewProject, projectPath: fy.dir / "job", dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0 and
      not st.project.readOnly), "the project was not made"
    let opened = st.project.revision
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 2, auxMarked: amMarked,
      auxShiftMs: 40.0)
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 1, auxMarked: amMarked,
      auxShiftMs: 500.0)
    doAssert st.project.doc.auxMarks == @[mark(1, 500.0), mark(2, 40.0)]
    doAssert st.project.revision > opened, "the project was not marked changed"
    doAssert st.projectAuxMarks == st.project.doc.auxMarks
    let was = st.project.revision
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 1, auxMarked: amMarked,
      auxShiftMs: 500.0)
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 5, auxMarked: amNotMarked)
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 0, auxMarked: amMarked)
    doAssert st.project.revision == was, "a change of nothing changed the project"
    st.apply Command(kind: ckProjectAuxMark, auxPosition: 2, auxMarked: amForget)
    doAssert st.project.doc.auxMarks == @[mark(1, 500.0)]
    var problems: seq[string] = @[]
    doAssert readProject(projectDocument(st.project.doc), "p", problems).auxMarks ==
      @[mark(1, 500.0)]
    discard st.shutdown()
  echo "tauxcorrelate: ok"

when isMainModule:
  main()
