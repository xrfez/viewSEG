## The project's text header template and binary header set in a SEG-Y slice built from
## header keys. The recording is built here (SEG-D, two stations of two traces, one segment
## of 100 samples at 2 ms); the slice is made at one shot, to SEG-Y or SEG-D.
##
## With a template, the header holds its rendered cards (the slice's name, record, receiver
## points) and the two lines the slice writes about itself in the first free cards after
## its last non-empty line; with no free card the notes are left out and a result line says
## so; a template that cannot be rendered (a token with no value) or that the library refuses
## leaves the header the slice writes without one, with a line saying why. A set writes its
## fields into the binary header. Neither chosen, an empty set, or SEG-D output: the file is
## the one written without.
##
## Seen failing: the template not passed to the writer ("cards[0]"); the notes written over
## the template's cards ("a card of the template was overwritten"); the notes written with no
## room ("no free card"); a render problem ignored ("not used"); the set not passed ("jobId").

import std/[assertions, options, os, sequtils, strutils]
import parseSEG
import parseSEG/model/traceindex
import processSEG/continuous/slice
import viewSEG/core/[cutgather, cutgatherjobs, cutheaders, jobs, outputbinary, outputnames,
  outputtext, recordingkind, shotlog]
import utils/waiting

const BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC

proc makeRecording(path: string; records = 1) =
  ## SEG-D, stations 7 and 8 on line 1, two traces each, in `records` records a second apart.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 100))
  for rec in 1 .. records:
    for pi in 0 .. 1:
      for ci in 0 .. 1:
        var k = initTraceKeys()
        k.status = tsLive
        k.record = float64(rec)
        k.channel = float64(pi * 2 + ci + 1)
        k.component = uint8(ci + 11)
        k.intervalUs = 2000
        k.time = float64(BaseUs div 1_000_000 + rec - 1)
        k.rcvLine = 1
        k.rcvPoint = 7.0 + float64(pi)
        var samples = newSeq[float32](100)
        for j in 0 ..< 100: samples[j] = float32(j)
        w.writeTrace(k, samples)
  discard w.close()

proc runCut(jobs: Jobs; f: var SeismicFile; source, dest: string; opts: CutOptions;
    two = false): tuple[ok: bool; res: CutResult] =
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crUtcMicros]
  let view = shots(parseShotLog("101," & $(BaseUs + 20_000) & "\n" &
    (if two: "102," & $(BaseUs + 1_020_000) & "\n" else: ""), m), m)
  let sink = CutSink()
  let id = jobs.submit(cutGatherSpec(source, dest),
    cutGatherWork(addr f, source, dest, shotsInTime(view.rows), opts, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the slice did not finish"
  (jobs.info(id).get.state == jsDone, sink.result)

proc cardsOf(path: string): seq[string] =
  var f = openSeismic(path, keys = false)
  result = f.textHeader.split('\n')
  f.close()

proc fieldOf(path, name: string): float64 =
  var f = openSeismic(path, keys = false)
  result = f.fileField("binary." & name).toFloat
  f.close()

proc padded(line: string): string = line & repeat(' ', 80 - line.len)

proc one(name: string; entries: varargs[(string, string)]): OutputBinary =
  result = OutputBinary(name: name)
  for (f, v) in entries: result.entries.add BinaryEntry(field: f, value: v)

proc main*() =
  let dir = getTempDir() / ("viewseg-cutheaders-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir / "rec")
  defer: removeDir(dir)
  let jobs = initJobs()
  let src = dir / "rec" / "r.sgd"
  makeRecording(src)
  var f = openSeismic(src, keys = true)
  defer: f.close()
  var base = initCutOptions(100.0, 0.0, standard = csSegy)
  base.treatKind = some rkReceiverContinuous
  let plainPath = dir / "plain.sgy"
  let plain = runCut(jobs, f, src, plainPath, base)
  doAssert plain.ok and plain.res.headerNotes.len == 0, plain.res.reason
  let plainBytes = readFile(plainPath)

  block nothing_chosen_or_empty:
    # no template, an empty set, boxes off (the options not set): the file written without
    var o = base
    o.headerBinary = some(OutputBinary(name: "Empty"))
    let r = runCut(jobs, f, src, dir / "empty.sgy", o)
    doAssert r.ok and "Binary header: set 'Empty' (0 fields)." in r.res.lines, $r.res.lines
    doAssert readFile(dir / "empty.sgy") == plainBytes, "bytes differ"

  block template_and_notes:
    var o = base
    o.headerText = some(OutputText(name: "T", encoding: teAscii,
      lines: @["SLICE OF {stem}", "", "REC {record} POINTS {rcvPoint}", "", ""]))
    let r = runCut(jobs, f, src, dir / "tpl.sgy", o)
    doAssert r.ok, r.res.reason
    let cards = cardsOf(dir / "tpl.sgy")
    doAssert cards.len == 40
    doAssert cards[0] == padded("SLICE OF tpl"), "cards[0]: " & cards[0]
    doAssert cards[1] == padded(""), cards[1]
    doAssert cards[2] == padded("REC 101 POINTS 7-8"), cards[2]
    # the notes follow the last non-empty line (card 3), not the blank cards after it
    doAssert cards[3].startsWith("C 4 SLICED BY viewSEG") and cards[3].len == 80, cards[3]
    doAssert cards[4].startsWith("C 5 SHOT LOG") or cards[4].startsWith("C 5   "), cards[4]
    doAssert cards[38].startsWith("C39") and "END TEXTUAL HEADER" in cards[39]
    doAssert "Text header: template 'T'." in r.res.lines, $r.res.lines
    doAssert r.res.provenanceIn == "the textual header"
    doAssert r.res.lines.anyIt("says the file was sliced" in it), $r.res.lines

  block no_free_card:
    var lines: seq[string] = @[]
    for i in 1 .. 38: lines.add "LINE " & $i
    var o = base
    o.headerText = some(OutputText(name: "Full", encoding: teAscii, lines: lines))
    let r = runCut(jobs, f, src, dir / "full.sgy", o)
    doAssert r.ok, r.res.reason
    let cards = cardsOf(dir / "full.sgy")
    for i in 0 ..< 38:
      doAssert cards[i] == padded("LINE " & $(i + 1)), "a card of the template was overwritten"
    doAssert r.res.provenanceIn == "", "the notes were written with no free card"
    doAssert r.res.lines.anyIt("is not written" in it and "'Full'" in it), $r.res.lines
    doAssert not r.res.lines.anyIt("says the file was sliced" in it)

  block render_problem:
    var o = base
    o.headerText = some(OutputText(name: "Src", encoding: teAscii,
      lines: @["SOURCE LINE {srcLine}"]))
    let r = runCut(jobs, f, src, dir / "prob.sgy", o)
    doAssert r.ok, r.res.reason
    doAssert r.res.lines.anyIt(it.startsWith("Text header: template 'Src' was not used for " &
      "this file: ")), $r.res.lines
    doAssert not ("Text header: template 'Src'." in r.res.lines)
    doAssert readFile(dir / "prob.sgy") == plainBytes, "the header is not the one with none"

  block binary_set:
    var o = base
    o.headerBinary = some(one("Job", ("jobId", "9071"), ("lineNumber", "-3")))
    let r = runCut(jobs, f, src, dir / "bin.sgy", o)
    doAssert r.ok, r.res.reason
    doAssert fieldOf(dir / "bin.sgy", "jobId") == 9071 and
      fieldOf(dir / "bin.sgy", "lineNumber") == -3, "jobId"
    doAssert "Binary header: set 'Job' (2 fields)." in r.res.lines, $r.res.lines
    doAssert cardsOf(dir / "bin.sgy") == cardsOf(plainPath), "the text header changed"

  block refusal_falls_back:
    # an ASCII header that reads as a tape label is refused by the library: the header is the
    # one written without a template, and the set is still written
    let label = OutputText(name: "L", encoding: teAscii,
      lines: @["0001SYTEST", repeat(' ', 48) & "CX"])
    var o = base
    o.headerBinary = some(one("Job", ("jobId", "12")))
    let withSet = runCut(jobs, f, src, dir / "set.sgy", o)
    o.headerText = some(label)
    let r = runCut(jobs, f, src, dir / "label.sgy", o)
    doAssert withSet.ok and r.ok, r.res.reason
    doAssert r.res.lines.anyIt(it.startsWith("Text header: template 'L' was not used")),
      $r.res.lines
    doAssert "Binary header: set 'Job' (1 field)." in r.res.lines
    doAssert readFile(dir / "label.sgy") == readFile(dir / "set.sgy"),
      "the header is not the one with the set alone"

  block segd_output_is_not_touched:
    # a two-record source, so the SEG-D output is built from keys, not carried
    let twoSrc = dir / "rec" / "two.sgd"
    makeRecording(twoSrc, records = 2)
    var g = openSeismic(twoSrc, keys = true)
    defer: g.close()
    var o = initCutOptions(100.0)
    o.treatKind = some rkReceiverContinuous
    let a = runCut(jobs, g, twoSrc, dir / "a.sgd", o, two = true)
    doAssert a.ok and not a.res.carried, a.res.reason
    o.headerText = some(OutputText(name: "T", encoding: teAscii, lines: @["X"]))
    o.headerBinary = some(one("Job", ("jobId", "12")))
    let b = runCut(jobs, g, twoSrc, dir / "b.sgd", o, two = true)
    doAssert b.ok and not b.res.carried and b.res.headerNotes.len == 0, $b.res.lines
    doAssert readFile(dir / "a.sgd") == readFile(dir / "b.sgd"), "bytes differ"

  block missing_values_are_ignored:
    # a receiver with no point does not make the points "mixed": the others agree, one value
    var rk: seq[TraceKeys] = @[]
    for p in [7.0, NaN]:
      var k = initTraceKeys()
      k.rcvPoint = p
      rk.add k
    let v = sliceTextValues("o.sgy", [101], [initSliceShot(1.0, 101.0)], rk, 0)
    doAssert v.values[npRcvPoint].state == nvNumber and v.values[npRcvPoint].number == 7.0,
      "one station with aux traces is not one value"
    doAssert v.values[npSrcLine].state == nvMissing
    rk[1].rcvPoint = 9.0
    let w = sliceTextValues("o.sgy", [101], [initSliceShot(1.0, 101.0)], rk, 0)
    doAssert w.values[npRcvPoint].state == nvMixed and w.firstLast[npRcvPoint].last.number == 9.0

when isMainModule:
  main()
