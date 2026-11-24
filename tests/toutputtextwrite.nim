## A project's chosen text header template is the text header of every SEG-Y
## file the Output writes (one file and a batch; the like path, which copies
## the source's headers, and the keys path, built from header keys): the
## template rendered for that file, in the template's character set (the
## source's own on the like path). Cards 39 and 40 stay the library's. With
## no template the header is what it was; a template that cannot be filled in
## for a file leaves that file with that header and the result line says why,
## and the batch goes on.
##
## Seen to fail: with `fullText` not passed on the like path, the header was
## the source's ("C 1 {stem}" was not written); not passed on the keys path,
## it was "WRITTEN BY parseSEG"; with the keys path's `textEncoding` left
## EBCDIC, the ASCII template's file was EBCDIC; with `firstLast` not filled,
## `{record}` of a file of records 5 and 9 failed instead of reading `5-9`;
## with a failed render still written, the file with record 0 held "{record}".
##
## Runs on a copy of samples/land/shots.sgy and samples/land/shots.sgd and on
## small files written here.

import std/[options, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[edits, jobs, outputbatch, outputjobs, outputtext, state]
import utils/waiting

const root = currentSourcePath().parentDir.parentDir

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc tpl(encoding: TextEncoding; lines: varargs[string]): Option[OutputText] =
  some(OutputText(name: "Survey", encoding: encoding, lines: @lines))

proc runOne(source, dest: string; opts: OutputOptions): OutputResult =
  var file = openSeismic(source, keys = true)
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(addr file, source, dest, opts, FileEdits(), @[source], sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the write did not finish"
  doAssert jobs.state(id) == jsDone, jobs.info(id).get.error & " / " & sink.result.reason
  file.close()
  sink.result

proc cardsOf(path: string): seq[string] =
  var f = openSeismic(path, keys = false)
  result = f.textHeader.split('\n')
  f.close()

proc padded(line: string): string = line & repeat(' ', 80 - line.len)

proc encodingOf(path: string): TextEncoding =
  var f = openSeismic(path, keys = false)
  result = f.index.segy.text.encoding
  f.close()

proc writeSmall(path: string; encoding: TextEncoding; records: openArray[float64]) =
  ## Two samples a trace, one trace a record number.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1,
    textEncoding: encoding, text: @["SMALL SOURCE"]))
  for i, r in records:
    var k = initTraceKeys()
    k.record = r
    k.srcPoint = 103.0
    k.channel = float64(i + 1)
    k.intervalUs = 2000.0
    k.traceCode = 1
    k.status = tsLive
    w.writeTrace(k, @[float32(i), 1.0'f32])
  doAssert w.close().len == 0

proc main*() =
  let land = root / "samples" / "land"
  let base = getTempDir() / ("viewseg-otw-" & $getCurrentProcessId())
  let inDir = base / "in"
  let dir = base / "out" ## every output; sources are in `inDir`
  createDir(inDir)
  createDir(dir)
  let segy = inDir / "shots.sgy"
  let segd = inDir / "shots.sgd"
  copyFile(land / "shots.sgy", segy)
  copyFile(land / "shots.sgd", segd)
  let ebcdic = tpl(teEbcdic, "C 1 FROM {stem}", "C 2 FILE {file}", "", "C 4 \xc3\xa9t\xc3\xa9",
    "C 5 WRITTEN {date}")
  let wantLines = @["C 1 FROM shots", "C 2 FILE shots.sgy", "", "C 4 \xc3\xa9t\xc3\xa9"]

  proc check(cards: seq[string]; stem, file: string) =
    doAssert cards.len == 40
    doAssert cards[0] == padded("C 1 FROM " & stem), cards[0]
    doAssert cards[1] == padded("C 2 FILE " & file), cards[1]
    doAssert cards[2] == padded(""), "a blank line was not blank"
    doAssert cards[3] == padded("C 4 \xe9t\xe9"), "Latin-1 bytes: " & cards[3]
    doAssert cards[4].startsWith("C 5 WRITTEN 20") and cards[4].len == 80, cards[4]
    for i in 5 ..< 38: doAssert cards[i] == padded(""), "card " & $(i + 1)
    doAssert cards[38].startsWith("C39"), "card 39 is the library's: " & cards[38]
    doAssert "END TEXTUAL HEADER" in cards[39], "card 40 is the library's: " & cards[39]

  block likeEbcdic:
    let dest = dir / "like-ebcdic.sgy"
    let r = runOne(segy, dest, OutputOptions(format: ofSegy, textHeader: ebcdic))
    doAssert r.ok
    doAssert "Text header: template 'Survey'." in r.lines, $r.lines
    check(cardsOf(dest), "shots", "shots.sgy")
    doAssert encodingOf(dest) == teEbcdic

  block keysEbcdic:
    let dest = dir / "keys-ebcdic.sgy"
    let r = runOne(segd, dest, OutputOptions(format: ofSegy, textHeader: ebcdic))
    doAssert r.ok
    doAssert "Text header: template 'Survey'." in r.lines, $r.lines
    let cards = cardsOf(dest)
    doAssert cards[0] == padded("C 1 FROM shots") and cards[1] == padded("C 2 FILE shots.sgd"),
      cards[0] & "|" & cards[1]
    doAssert cards[38].startsWith("C39") and "END TEXTUAL HEADER" in cards[39]
    doAssert encodingOf(dest) == teEbcdic

  block keysAscii:
    let dest = dir / "keys-ascii.sgy"
    let t = tpl(teAscii, "C 1 {stem}", "C 2 ABC {record:2}")
    let r = runOne(segd, dest, OutputOptions(format: ofSegy, textHeader: t))
    doAssert r.ok and "Text header: template 'Survey'." in r.lines, $r.lines
    doAssert encodingOf(dest) == teAscii, "the ASCII template was written as EBCDIC"
    let cards = cardsOf(dest)
    doAssert cards[0] == padded("C 1 shots") and cards[1] == padded("C 2 ABC 01-06"), cards[1]

  block likeAscii:
    let small = inDir / "small-ascii.sgy"
    writeSmall(small, teAscii, [5.0, 5.0])
    let t = tpl(teAscii, "C 1 {stem} R{record:3}")
    let dest = dir / "like-ascii.sgy"
    let r = runOne(small, dest, OutputOptions(format: ofSegy, textHeader: t))
    doAssert r.ok and "Text header: template 'Survey'." in r.lines, $r.lines
    doAssert encodingOf(dest) == teAscii
    doAssert cardsOf(dest)[0] == padded("C 1 small-ascii R005"), cardsOf(dest)[0]
    # An EBCDIC template on an ASCII source takes the source's character set.
    let dest2 = dir / "like-recoded.sgy"
    let r2 = runOne(small, dest2, OutputOptions(format: ofSegy,
      textHeader: tpl(teEbcdic, "C 1 {stem}")))
    doAssert r2.ok
    doAssert encodingOf(dest2) == teAscii
    doAssert cardsOf(dest2)[0] == padded("C 1 small-ascii")
    var said = false
    for l in r2.lines:
      if "own character set (ASCII)" in l: said = true
    doAssert said, $r2.lines

  block noTemplateUnchanged:
    for source in [segy, segd]:
      let plain = dir / "plain-" & source.extractFilename & ".sgy"
      let templated = dir / "templated-" & source.extractFilename & ".sgy"
      let a = runOne(source, plain, OutputOptions(format: ofSegy))
      doAssert a.ok
      for l in a.lines: doAssert not l.startsWith("Text header"), l
      let b = runOne(source, templated, OutputOptions(format: ofSegy,
        textHeader: tpl(teEbcdic, "C 1 CHANGED")))
      doAssert b.ok
      let x = readFile(plain)
      let y = readFile(templated)
      doAssert x.len == y.len
      doAssert x[0 ..< 3200] != y[0 ..< 3200], "the template did not change the header"
      doAssert x[3200 .. ^1] == y[3200 .. ^1], "more than the text header changed"
    # The header with no template is the source's own on the like path.
    doAssert readFile(dir / "plain-shots.sgy.sgy")[0 ..< 3200] == readFile(segy)[0 ..< 3200]

  block firstLastRecords:
    let small = inDir / "two-records.sgy"
    writeSmall(small, teEbcdic, [5.0, 5.0, 9.0])
    for (name, source) in [("like", small)]:
      let dest = dir / "firstlast-" & name & ".sgy"
      let r = runOne(source, dest, OutputOptions(format: ofSegy,
        textHeader: tpl(teEbcdic, "C 1 RECORD {record}")))
      doAssert r.ok, r.reason
      doAssert cardsOf(dest)[0] == padded("C 1 RECORD 5-9"), cardsOf(dest)[0]

  block renderFails:
    let dest = dir / "failed.sgy"
    let plain = dir / "failed-plain.sgy"
    doAssert runOne(segy, plain, OutputOptions(format: ofSegy)).ok
    let r = runOne(segy, dest, OutputOptions(format: ofSegy,
      textHeader: tpl(teEbcdic, "C 1 {vibrator}")))
    doAssert r.ok, r.reason
    doAssert r.written > 0
    var said = ""
    for l in r.lines:
      if l.startsWith("Text header:"): said = l
    doAssert said == "Text header: template 'Survey' was not used for this file: Line 1: " &
      "{vibrator} is not in this file. The header it would have had was written.", said
    doAssert readFile(dest) == readFile(plain), "a failed template changed the file"

  block batchPerFile:
    let src = inDir / "batch"
    let outDir = base / "batch-out"
    createDir(src)
    createDir(outDir)
    createDir(base / "mem")
    writeSmall(src / "one.sgy", teEbcdic, [5.0, 5.0])
    writeSmall(src / "zero.sgy", teEbcdic, [0.0, 0.0])
    writeSmall(src / "three.sgy", teEbcdic, [7.0, 7.0])
    let items = @[BatchItem(source: src / "one.sgy", relative: "one.sgy"),
      BatchItem(source: src / "zero.sgy", relative: "zero.sgy"),
      BatchItem(source: src / "three.sgy", relative: "three.sgy")]
    let ask = BatchAsk(root: src, items: items, destRoot: outDir,
      options: OutputOptions(format: ofSegy,
        textHeader: tpl(teEbcdic, "C 1 {stem} REC {record}")))
    let jobs = initJobs()
    let sink = BatchSink()
    let id = jobs.submit(outputBatchSpec(ask),
      outputBatchWork(ask, Store(home: base / "mem"), @[], sink))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the batch did not end"
    doAssert jobs.state(id) == jsDone, jobs.info(id).get.error
    let got = sink.result
    doAssert got.written == 3 and got.failed == 0, $got.written & "/" & $got.failed
    doAssert cardsOf(outDir / "one.sgy")[0] == padded("C 1 one REC 5")
    doAssert cardsOf(outDir / "three.sgy")[0] == padded("C 1 three REC 7")
    doAssert cardsOf(outDir / "zero.sgy")[0] == padded("C 1 SMALL SOURCE"),
      "the file the template cannot fill kept its header"
    var said: seq[string] = @[]
    for it in got.items:
      for l in it.lines:
        if l.startsWith("Text header:"): said.add it.relative & ": " & l
    doAssert said.len == 3, $said
    doAssert "one.sgy: Text header: template 'Survey'." in said, $said
    doAssert said[1].startsWith("zero.sgy: Text header: template 'Survey' was not used"), said[1]

  block lowestHighest:
    let small = inDir / "unordered.sgy"
    writeSmall(small, teEbcdic, [5.0, 9.0, 3.0])
    let dest = dir / "unordered-out.sgy"
    let r = runOne(small, dest, OutputOptions(format: ofSegy,
      textHeader: tpl(teEbcdic, "C 1 RECORD {record}")))
    doAssert r.ok, r.reason
    doAssert cardsOf(dest)[0] == padded("C 1 RECORD 3-9"), cardsOf(dest)[0]

  block refusedAtOpenKeepsCharset:
    # The library refuses an ASCII header that reads as a tape label; the
    # file is then the one a write with no template makes, EBCDIC bytes too.
    let t = tpl(teAscii, "0001SYTEST", repeat(' ', 48) & "CX")
    let plain = dir / "label-plain.sgy"
    doAssert runOne(segd, plain, OutputOptions(format: ofSegy)).ok
    let dest = dir / "label.sgy"
    let r = runOne(segd, dest, OutputOptions(format: ofSegy, textHeader: t))
    doAssert r.ok, r.reason
    var said = false
    for l in r.lines:
      if l.startsWith("Text header: template 'Survey' was not used for this file:"): said = true
      doAssert l != "Text header: template 'Survey'.", "said it was used"
    doAssert said, $r.lines
    doAssert readFile(dest) == readFile(plain), "the header is not the one with no template"

  block ownPositionsKept:
    # A join changed the keys; with the session's positions off the headers
    # keep the file's own, and so does the template.
    let small = inDir / "joined.sgy"
    writeSmall(small, teEbcdic, [5.0, 5.0])
    let dest = dir / "joined-out.sgy"
    var open = openSeismic(small, keys = true)
    for t in 0 ..< open.len: open.mindex.keys[t].srcPoint = 999.0
    open.mindex.joined = true
    let jobs = initJobs()
    let sink = OutputSink()
    let opts = OutputOptions(format: ofSegy, writeSessionPositions: false,
      textHeader: tpl(teEbcdic, "C 1 POINT {srcPoint}"))
    let id = jobs.submit(outputSpec(small, dest),
      outputWork(addr open, small, dest, opts, FileEdits(), @[small], sink))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "no end"
    doAssert jobs.state(id) == jsDone, jobs.info(id).get.error & sink.result.reason
    open.close()
    doAssert cardsOf(dest)[0] == padded("C 1 POINT 103"), cardsOf(dest)[0]

  block charsetWords:
    let small = inDir / "ascii-words.sgy"
    writeSmall(small, teAscii, [5.0])
    let dest = dir / "ascii-words-out.sgy"
    let plain = dir / "ascii-words-plain.sgy"
    doAssert runOne(small, plain, OutputOptions(format: ofSegy)).ok
    let r = runOne(small, dest, OutputOptions(format: ofSegy,
      textHeader: tpl(teEbcdic, "C 1 \xc3\xa9t\xc3\xa9")))
    doAssert r.ok, r.reason
    doAssert "Text header: template 'Survey' was not used for this file: this file keeps " &
      "its own character set (ASCII), and line 1 column 5 holds a character ASCII cannot " &
      "hold. The header it would have had was written." in r.lines, $r.lines
    for l in r.lines: doAssert "own character set (ASCII)." notin l, l
    doAssert readFile(dest) == readFile(plain)

  removeDir(base)
  echo "toutputtextwrite: ok"

when isMainModule:
  main()
