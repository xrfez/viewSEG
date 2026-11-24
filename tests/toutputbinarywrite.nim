## A project's chosen binary header set is written into the binary file
## header of every SEG-Y file the Output writes (the like path, which copies
## the source's headers, and the keys path, built from header keys), as the
## library's `binaryOverrides`: only the bytes of the fields the set names
## change in bytes 3201 to 3600, and nothing past them. With no set (or one
## with no fields) the file is the one written without. A Rev 2 field is not
## written into a Rev 0 or Rev 1 file and says so; a 16-bit field that an
## extended one, in the set or in the source, hides is left out with a note and
## the rest written (a set the library still refuses at open would leave the
## file a write without it makes, with the line saying why).
## SEG-D is not touched and says nothing.
##
## Seen to fail: with `binaryOverrides` not passed on the like path, then on
## the keys path, "no byte changed" (the set was not written); with the
## revision of a like write taken as 2.1 whatever the source says, a batch
## file of a Rev 1 source got a Rev 2 field written (or the write failed);
## with the source's own binary header not given to `overridesOf`, the library
## refused the set whose 16-bit field the source's extended one hides.
##
## Runs on a copy of samples/land/shots.sgy and samples/land/shots.sgd and on
## small files written here.

import std/[options, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[edits, jobs, outputbatch, outputbinary, outputjobs, outputtext, state]
import utils/waiting

const root = currentSourcePath().parentDir.parentDir

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

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

proc one(name: string; entries: varargs[(string, string)]): OutputBinary =
  result = OutputBinary(name: name)
  for (f, v) in entries: result.entries.add BinaryEntry(field: f, value: v)

proc binaryLines(r: OutputResult): seq[string] =
  for l in r.lines:
    if l.startsWith("Binary header"): result.add l

proc fieldOf(path, name: string): float64 =
  var f = openSeismic(path, keys = false)
  result = f.fileField("binary." & name).toFloat
  f.close()

proc writeSmall(path: string; revision: SegyRevision; extFold = 0; ascii = false) =
  ## Two samples a trace, two traces; `extFold` sets the extended ensemble fold (Rev 2).
  var o = SegyOutputOptions(revision: revision, traceSorting: 1, measurementSystem: 1,
    text: @["SMALL SOURCE"], textEncoding: if ascii: teAscii else: teEbcdic)
  if extFold != 0: o.binaryOverrides = @[headerOverride("binary.extEnsembleFold", extFold)]
  var w = openSeismicWriter(path, o)
  for i in 0 ..< 2:
    var k = initTraceKeys()
    k.record = 5
    k.srcPoint = 103.0
    k.channel = float64(i + 1)
    k.intervalUs = 2000.0
    k.traceCode = 1
    k.status = tsLive
    w.writeTrace(k, @[float32(i), 1.0'f32])
  doAssert w.close().len == 0

proc fieldBytes(name: string): Slice[int] =
  ## The 0-based bytes of the file a field covers.
  let f = fieldInfo(name).get
  (f.firstByte - 1) .. (f.firstByte - 2 + f.bytes)

proc onlyIn(plain, withSet: string; names: openArray[string]) =
  ## `withSet` is `plain` with nothing changed but bytes of the fields `names`
  ## (all in the binary header), and at least one byte is.
  doAssert plain.len == withSet.len, "the length changed"
  var changed = 0
  for i in 0 ..< plain.len:
    if plain[i] != withSet[i]:
      inc changed
      var inside = false
      for n in names:
        if i in fieldBytes(n): inside = true
      doAssert inside, "byte " & $i & " changed, which no field of the set holds"
  doAssert changed > 0, "no byte changed"

proc main*() =
  let land = root / "samples" / "land"
  let base = getTempDir() / ("viewseg-obw-" & $getCurrentProcessId())
  let inDir = base / "in"
  let dir = base / "out"
  createDir(inDir)
  createDir(dir)
  let segy = inDir / "shots.sgy"
  let segd = inDir / "shots.sgd"
  copyFile(land / "shots.sgy", segy)
  copyFile(land / "shots.sgd", segd)
  let revisions = [orSame, orSegy0, orSegy1, orSegy20, orSegy21]
  # Values that no source holds; the extended ones are Rev 2 only.
  let big = one("Survey", ("jobId", "9071"), ("lineNumber", "-3"), ("sweepLength", "10000"),
    ("sweepFreqStart", "8"), ("extSampleIntervalOrig", "4000.5"), ("timeBasisCode", "4"))
  let names = @["jobId", "lineNumber", "sweepLength", "sweepFreqStart", "extSampleIntervalOrig",
    "timeBasisCode"]

  block nothingChosen:
    # Today's file: the like path is the source with nothing changed past
    # the headers it rewrites; a set with no fields, or none, is that file.
    for source in [segy, segd]:
      for rev in revisions:
        let tag = source.extractFilename & "-" & $rev
        let plain = dir / "plain-" & tag & ".sgy"
        let a = runOne(source, plain, OutputOptions(format: ofSegy, revision: rev))
        doAssert a.ok and a.binaryLines.len == 0, $a.lines
        let empty = dir / "empty-" & tag & ".sgy"
        let b = runOne(source, empty, OutputOptions(format: ofSegy, revision: rev,
          headerBinary: some(one("Empty"))))
        doAssert b.ok and b.binaryLines == @["Binary header: set 'Empty' (0 fields)."], $b.lines
        doAssert readFile(plain) == readFile(empty), "an empty set changed the file " & tag
        let again = dir / "again-" & tag & ".sgy"
        doAssert runOne(source, again, OutputOptions(format: ofSegy, revision: rev,
          headerBinary: none(OutputBinary))).ok
        doAssert readFile(plain) == readFile(again)
    let same = readFile(dir / "plain-shots.sgy-same.sgy")
    doAssert same[0 ..< 3200] == readFile(segy)[0 ..< 3200], "the like text header changed"

  block everyRevision:
    for source in [segy, segd]:
      for rev in revisions:
        let tag = source.extractFilename & "-" & $rev
        let dest = dir / "set-" & tag & ".sgy"
        let r = runOne(source, dest, OutputOptions(format: ofSegy, revision: rev,
          headerBinary: some(big)))
        doAssert r.ok, r.reason
        var out2 = openSeismic(dest, keys = false)
        let major = out2.index.segy.revision.major
        out2.close()
        let rev2 = major >= 2
        let wrote = if rev2: names else: names[0 ..< 4]
        doAssert r.binaryLines[0] == "Binary header: set 'Survey' (" & $wrote.len & " fields).",
          $r.binaryLines
        if rev2: doAssert r.binaryLines.len == 1, $r.binaryLines
        else:
          doAssert r.binaryLines.len == 3, $r.binaryLines
          let word = if major == 0: "0" else: "1"
          doAssert r.binaryLines[1] == "Binary header: Extended sample interval original is " &
            "not written in SEG-Y revision " & word & "." and
            r.binaryLines[2] == "Binary header: Time basis code is not written in SEG-Y " &
            "revision " & word & ".", $r.binaryLines
        let plain = readFile(dir / "plain-" & tag & ".sgy")
        let got = readFile(dest)
        plain.onlyIn(got, wrote)
        # Nothing past the binary header changed.
        doAssert plain[3600 .. ^1] == got[3600 .. ^1], "bytes past the binary header changed"
        doAssert plain[0 ..< 3200] == got[0 ..< 3200], "the text header changed"
        doAssert fieldOf(dest, "jobId") == 9071 and fieldOf(dest, "lineNumber") == -3 and
          fieldOf(dest, "sweepLength") == 10000 and fieldOf(dest, "sweepFreqStart") == 8, tag
        if rev2:
          doAssert fieldOf(dest, "extSampleIntervalOrig") == 4000.5 and
            fieldOf(dest, "timeBasisCode") == 4, tag

  block twinHidden:
    # Both of a field and its Rev 2 twin: the twin is written, the small one
    # is said not to be.
    let both = one("Twin", ("ensembleFold", "5"), ("extEnsembleFold", "70000"))
    let dest = dir / "twin.sgy"
    let r = runOne(segd, dest, OutputOptions(format: ofSegy, revision: orSegy21,
      headerBinary: some(both)))
    doAssert r.ok and r.binaryLines == @["Binary header: set 'Twin' (1 field).",
      "Binary header: Ensemble fold is not written in SEG-Y revision 2.1: Extended ensemble " &
      "fold is set and replaces it."], $r.lines
    doAssert fieldOf(dest, "extEnsembleFold") == 70000

  block twinInTheSource:
    # The source has its extended fold set, which hides the 16-bit one: that
    # field is left out with a note, the other fields are written.
    let small = inDir / "twinned.sgy"
    writeSmall(small, SegyRevision(major: 2, minor: 1), extFold = 9)
    let plain = dir / "twinned-plain.sgy"
    doAssert runOne(small, plain, OutputOptions(format: ofSegy)).ok
    let set = one("Fold", ("ensembleFold", "3"), ("jobId", "5"))
    let dest = dir / "twinned.sgy"
    let r = runOne(small, dest, OutputOptions(format: ofSegy, headerBinary: some(set)))
    doAssert r.ok, r.reason
    doAssert r.binaryLines == @["Binary header: set 'Fold' (1 field).",
      "Binary header: Ensemble fold is not written in SEG-Y revision 2.1: Extended ensemble " &
      "fold is set and replaces it."], $r.binaryLines
    plain.readFile.onlyIn(readFile(dest), ["jobId"])
    doAssert fieldOf(dest, "jobId") == 5 and fieldOf(dest, "extEnsembleFold") == 9
    # With a text template too: both are written.
    let tpl = OutputText(name: "T", encoding: teEbcdic, lines: @["C 1 KEPT"])
    let both = dir / "twinned-text.sgy"
    let r2 = runOne(small, both, OutputOptions(format: ofSegy, headerText: some(tpl),
      headerBinary: some(set)))
    doAssert "Text header: template 'T'." in r2.lines and r2.binaryLines.len == 2, $r2.lines
    doAssert readFile(both)[3200 ..< 3600] == readFile(dest)[3200 ..< 3600]
    var back = openSeismic(both, keys = false)
    doAssert back.textHeader.startsWith("C 1 KEPT")
    back.close()
    # The template the library refuses at open (an ASCII tape label) with a set it takes.
    let label = OutputText(name: "L", encoding: teAscii,
      lines: @["0001SYTEST", repeat(' ', 48) & "CX"])
    let good = one("Job", ("jobId", "12"))
    let noText = dir / "label-plain.sgy"
    doAssert runOne(segd, noText, OutputOptions(format: ofSegy, headerBinary: some(good))).ok
    let r3 = runOne(segd, dir / "label-set.sgy", OutputOptions(format: ofSegy,
      headerText: some(label), headerBinary: some(good)))
    doAssert r3.ok and r3.binaryLines == @["Binary header: set 'Job' (1 field)."], $r3.lines
    doAssert "Text header: template 'L' was not used" in r3.lines.join("\n")
    doAssert readFile(dir / "label-set.sgy") == readFile(noText)

  block badSet:
    # A set that holds a problem (the project never keeps one) writes nothing.
    let dest = dir / "bad.sgy"
    let r = runOne(segy, dest, OutputOptions(format: ofSegy,
      headerBinary: some(one("Bad", ("sampleInterval", "1")))))
    doAssert r.ok and r.binaryLines == @["Binary header: set 'Bad' was not used for this file: " &
      "'sampleInterval' is not a binary header field that can be set. The header it would " &
      "have had was written."], $r.lines
    doAssert readFile(dest) == readFile(dir / "plain-shots.sgy-same.sgy")

  block segdUntouched:
    let dest = dir / "out.sgd"
    let plain = dir / "plain.sgd"
    doAssert runOne(segy, plain, OutputOptions(format: ofSegd)).ok
    let r = runOne(segy, dest, OutputOptions(format: ofSegd, headerBinary: some(big)))
    doAssert r.ok and r.binaryLines.len == 0, $r.lines
    doAssert readFile(dest) == readFile(plain)

  block batchPerFile:
    let src = inDir / "batch"
    let outDir = base / "batch-out"
    createDir(src)
    createDir(outDir)
    createDir(base / "mem")
    writeSmall(src / "one.sgy", SegyRevision(major: 2, minor: 1))
    writeSmall(src / "two.sgy", SegyRevision(major: 1, minor: 0))
    let items = @[BatchItem(source: src / "one.sgy", relative: "one.sgy"),
      BatchItem(source: src / "two.sgy", relative: "two.sgy")]
    let ask = BatchAsk(root: src, items: items, destRoot: outDir,
      options: OutputOptions(format: ofSegy, headerBinary: some(big)))
    let jobs = initJobs()
    let sink = BatchSink()
    let id = jobs.submit(outputBatchSpec(ask),
      outputBatchWork(ask, Store(home: base / "mem"), @[], sink))
    doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}), "the batch did not end"
    doAssert jobs.state(id) == jsDone, jobs.info(id).get.error
    doAssert sink.result.written == 2 and sink.result.failed == 0
    doAssert fieldOf(outDir / "one.sgy", "jobId") == 9071 and
      fieldOf(outDir / "two.sgy", "jobId") == 9071
    doAssert fieldOf(outDir / "one.sgy", "timeBasisCode") == 4
    doAssert fieldOf(outDir / "two.sgy", "timeBasisCode") == 0
    var said: seq[string] = @[]
    for it in sink.result.items:
      for l in it.lines:
        if l.startsWith("Binary header: set"): said.add it.relative & ": " & l
    doAssert said == @["one.sgy: Binary header: set 'Survey' (6 fields).",
      "two.sgy: Binary header: set 'Survey' (4 fields)."], $said

  removeDir(base)
  echo "toutputbinarywrite: ok"

when isMainModule:
  main()
