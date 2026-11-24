## An open vibrator signature file written by the output job.
##
## A `.vib` or `.dat` is a SEG-Y image in memory. Written as SEG-Y and reopened,
## it has the same trace count, sample counts, interval and samples, the same
## text cards, the same header rows, and the library's shot block (the shipped
## maps decode the same named values). Written as SEG-D with no option that
## changes samples or which traces are written, it is written by the library's
## SEG-D writer: the same samples, the shot block's named values, the library's
## channel types, and the clock in the general header (file number, julian day,
## hour, minute, second). With such an option on, headers are built from the
## trace keys, the shot block is not carried, and the result says so.
## The destination name is the one given: a `.sgy` or `.segd` name in another
## folder is written, and the source path is refused, never overwritten. A
## folder of sweeps is one output file per sweep, not one file of every
## record. A sweep that is not already open is decoded and written the same
## way as one that is. A file that cannot be decoded is a failed row with
## the opener's sentence, and the others are still written. Two sweeps whose
## names differ only by `.vib` and `.dat` keep that extension in the output
## name, so they are not written as one file. A SEG-Y file that is only named
## `a.dat`, batched with a signature `a.vib`, is written as `a.sgy` with no
## kept-extension sentence; the signature lands on that same name and fails
## with the clash sentence. The kind, not the extension, decides.
##
## Seen to fail: not by a change in the writer (the SEG-Y write already
## matched). A dropped shot block fails the named-value check; an overwrite
## of the source fails the byte check. With the batch's signature open taken
## out (an unopened sweep opened as a seismic file), the folder that is not
## open fails every row with "no traces", and `a.vib` beside `a.dat` is a
## name clash instead of two files. With the kept extension still decided by
## the name, both files were written (`2 written, 0 failed`). With the kind
## taken from the name instead of the first bytes, `a.vib.sgy` was written.
## With the library path forced off (`if false and signature.isSignature`),
## the SEG-D write said "Headers were built from the trace keys." and the new
## check failed.

import std/[os, strutils, tables]
import parseSEG
import viewSEG/core/[edits, filememory, headers, jobs, outputbatch, outputjobs, sigtypes,
  state, vendormaps]
import utils/[fixtures, sigfiles, waiting]

const maps = currentSourcePath().parentDir.parentDir / "vendormaps"

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc shown(st: AppState): int = st.shownFile(st.findPanel(MainPanel))

proc openIt(st: var AppState; path: string): bool =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  st.settle(st.sessions.len >= 1 and st.panel(MainPanel).laidOut and st.shown >= 0)

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc runWrite(file: ptr SeismicFile; source, dest: string; format: OutputFormat;
    opts = OutputOptions(); edits = FileEdits(); signature = SignatureFacts()):
    tuple[st: JobState; wrote: OutputResult; error: string] =
  var writing = opts
  writing.format = format
  let jobs = initJobs()
  let sink = OutputSink()
  let id = jobs.submit(outputSpec(source, dest),
    outputWork(file, source, dest, writing, edits, @[source], sink, signature))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the write did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc runBatch(ask: BatchAsk; store: Store; openFiles: seq[OpenFile]):
    tuple[st: JobState; wrote: BatchResult; error: string] =
  let jobs = initJobs()
  let sink = BatchSink()
  let id = jobs.submit(outputBatchSpec(ask), outputBatchWork(ask, store, openFiles, sink))
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the batch did not finish: " & $jobs.state(id)
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc namedValues(shown: VendorShown): seq[string] =
  result = @[]
  for b in shown.blocks:
    for f in b.fields:
      result.add f.name & "=" & f.value

proc vendorLines(shown: VendorShown): seq[string] =
  result = @[]
  for b in shown.blocks:
    result.add b.name
    for f in b.fields:
      result.add f.name & "=" & f.value

proc rowLines(rows: seq[FieldRow]): seq[string] =
  result = @[]
  for r in rows:
    result.add r.blockName & " | " & r.field & " = " & r.value

proc pairDiff(title: string; mem, disk: seq[string]): string =
  if mem == disk: return ""
  result = title & ":\n"
  var at: Table[string, int]
  for i, line in mem: at[line] = i
  for line in disk:
    if not at.hasKey(line): result.add "  only on disk: " & line & "\n"
  for line in mem:
    if line notin disk: result.add "  only in memory: " & line & "\n"

proc sampleGap(mem, disk: SeismicFile): string =
  if mem.len != disk.len:
    return "trace count " & $mem.len & " vs " & $disk.len & "\n"
  for t in 0 ..< mem.len:
    let ns = int(mem.traceEntry(t).numSamples)
    let nd = int(disk.traceEntry(t).numSamples)
    if ns != nd:
      result.add "trace " & $t & " sample count " & $ns & " vs " & $nd & "\n"
      continue
    let a = samplesOf(mem, t)
    let b = samplesOf(disk, t)
    for i, x in a:
      if x != b[i]:
        result.add "trace " & $t & " sample " & $i & " differs\n"
        break
    if mem.sampleIntervalUs(t) != disk.sampleIntervalUs(t):
      result.add "trace " & $t & " interval " & $mem.sampleIntervalUs(t) & " vs " &
        $disk.sampleIntervalUs(t) & "\n"

proc segyGap(mem, disk: SeismicFile; memFacts: FileFacts; reg: VendorRegistry): string =
  result = sampleGap(mem, disk)
  let back = fileFacts(disk)
  result.add pairDiff("text cards", memFacts.text, back.text)
  result.add pairDiff("header rows", rowLines(memFacts.rows), rowLines(back.rows))
  var memStanza, diskStanza: seq[string] = @[]
  for s in memFacts.stanzas: memStanza.add $s.kind & " " & s.name & " " & $s.size
  for s in back.stanzas: diskStanza.add $s.kind & " " & s.name & " " & $s.size
  result.add pairDiff("stanzas", memStanza, diskStanza)
  result.add pairDiff("shot block", vendorLines(vendorBlocks(mem, -1, reg)),
    vendorLines(vendorBlocks(disk, -1, reg)))

proc diskGap(left, right: string; reg: VendorRegistry): string =
  var a = openSeismic(left, keys = true)
  var b = openSeismic(right, keys = true)
  result = segyGap(a, b, fileFacts(a), reg)
  a.close()
  b.close()

proc main*() =
  let load = loadVendorFolders([VendorFolder(dir: maps, origin: voProgram)])
  doAssert load.maps.len >= 2, load.foldersText
  let reg = load.registry
  let datSynth = SynthDat(samples: 600)
  let vibSynth = SynthVib(afterTrigger: 400, taperFrames: 40)

  block segy:
    withFixtures fx:
      let src = fx.dir / "src"
      let written = fx.dir / "out"
      createDir(written)
      let vib = vibFile(src, "0007.VIB", vibSynth)
      let dat = datFile(src, "0042_x.dat", datSynth)
      for item in [(vib, "0007.sgy"), (dat, "0042_x.sgy")]:
        let (path, destName) = item
        var st = initAppState()
        doAssert st.openIt(path), "did not open " & path.extractFilename
        let s = st.sessions[st.shown]
        doAssert s.isSignature and s.file.inMemory, path
        let before = readFile(path)
        let dest = written / destName
        let got = runWrite(s.filePtr, path, dest, ofSegy)
        doAssert got.st == jsDone, path.extractFilename & " " & got.wrote.reason &
          " " & got.error
        doAssert readFile(path) == before, path.extractFilename & " was changed"
        doAssert dest.splitFile.ext == ".sgy", dest
        var back = openSeismic(dest, keys = true)
        let gap = segyGap(s.file, back, s.facts, reg)
        back.close()
        doAssert gap.len == 0, path.extractFilename & "\n" & gap
        st.shutdown()

  block segd:
    withFixtures fx:
      let src = fx.dir / "src"
      let written = fx.dir / "out"
      createDir(written)
      let vib = vibFile(src, "0007.VIB", vibSynth)
      let dat = datFile(src, "0042_x.dat", datSynth)
      for item in [(vib, "0007.segd"), (dat, "0042_x.segd")]:
        let (path, destName) = item
        var st = initAppState()
        doAssert st.openIt(path), "did not open " & path.extractFilename
        let s = st.sessions[st.shown]
        let before = readFile(path)
        let dest = written / destName
        let got = runWrite(s.filePtr, path, dest, ofSegd, signature = s.signature)
        doAssert got.st == jsDone, path.extractFilename & " " & got.wrote.reason &
          " " & got.error
        doAssert got.wrote.written == s.len, $got.wrote.written
        doAssert readFile(path) == before, path.extractFilename & " was changed"
        for line in got.wrote.lines:
          doAssert HeaderNotCarried notin line, $got.wrote.lines
          doAssert "Headers were built from the trace keys." notin line, $got.wrote.lines
        var back = openSeismic(dest, keys = true)
        let gap = sampleGap(s.file, back)
        doAssert gap.len == 0, path.extractFilename & "\n" & gap
        doAssert fileFacts(back).text.len == 0, "SEG-D kept text cards"
        let memBlock = vendorBlocks(s.file, -1, reg)
        let diskBlock = vendorBlocks(back, 0, reg)
        doAssert diskBlock.blocks.len > 0, path.extractFilename & " wrote no vendor block"
        let named = pairDiff("named values", namedValues(memBlock), namedValues(diskBlock))
        doAssert named.len == 0, path.extractFilename & "\n" & named
        const datTypes = [0x96'u8, 0x99, 0x95, 0x93]
        const vibTypes = [0x96'u8, 0x99, 0x95, 0x93, 0x97, 0x97, 0x97, 0x97, 0x9B, 0x97,
          0x9A, 0x97, 0x97]
        let expect = if s.signature.kind == sgDat: @datTypes else: @vibTypes
        doAssert back.len == expect.len, $back.len
        for t, want in expect:
          let gotType = back.traceEntry(t).channelType
          doAssert gotType == want, path.extractFilename & " trace " & $t &
            " channel type " & $gotType & " is not " & $want
        for t in 0 ..< s.len:
          let a = s.file.traceKeys(t)
          let b = back.traceKeys(t)
          doAssert b.traceCode == 0, "trace code survived: " & $b.traceCode
          doAssert a.record == b.record and a.channel == b.channel and
            a.intervalUs == b.intervalUs and a.status == b.status,
            "trace " & $t & " keys " & $a.record & "/" & $b.record
        let heads = readRecordHeaders(back, 0)
        var fileNumber, hour, minute, second, day = ""
        for r in heads.rows:
          if r.field == "fileNumber": fileNumber = r.value
          elif r.field == "hour": hour = r.value
          elif r.field == "minute": minute = r.value
          elif r.field == "second": second = r.value
          elif r.field == "julianDay": day = r.value
        doAssert fileNumber.len > 0 and hour == "4" and minute == "5" and
          second == "6" and day == "34",
          path.extractFilename & " " & fileNumber & " " & day & " " & hour
        back.close()
        st.shutdown()

  block reversed:
    withFixtures fx:
      let src = fx.dir / "src"
      let written = fx.dir / "out"
      createDir(written)
      let vib = vibFile(src, "0007.VIB", vibSynth)
      let dat = datFile(src, "0042_x.dat", datSynth)
      for item in [(vib, "0007.segd"), (dat, "0042_x.segd")]:
        let (path, destName) = item
        var st = initAppState()
        doAssert st.openIt(path), "did not open " & path.extractFilename
        let s = st.sessions[st.shown]
        var edits: FileEdits
        doAssert edits.change(teReversed, [0], true) == 1
        let dest = written / destName
        let got = runWrite(s.filePtr, path, dest, ofSegd,
          OutputOptions(applyReversals: true), edits, s.signature)
        doAssert got.st == jsDone, path.extractFilename & " " & got.wrote.reason &
          " " & got.error
        var noted = false
        for line in got.wrote.lines:
          if line == HeaderNotCarried: noted = true
        doAssert noted, $got.wrote.lines
        var back = openSeismic(dest, keys = true)
        doAssert vendorBlocks(back, 0, reg).blocks.len == 0,
          path.extractFilename & " kept a vendor block"
        let a = samplesOf(s.file, 0)
        let b = samplesOf(back, 0)
        var nonzero = false
        for i, x in a:
          if x != 0: nonzero = true
          doAssert b[i] == -x, path.extractFilename & " sample " & $i
        doAssert nonzero, path.extractFilename & " trace 0 is all zero"
        for t in 1 ..< s.len:
          doAssert samplesOf(s.file, t) == samplesOf(back, t),
            path.extractFilename & " trace " & $t
        back.close()
        st.shutdown()

  block destination:
    withFixtures fx:
      let src = fx.dir / "src"
      let written = fx.dir / "out"
      createDir(written)
      let vib = vibFile(src, "0007.VIB", vibSynth)
      var st = initAppState()
      doAssert st.openIt(vib), "did not open the .vib"
      let s = st.sessions[st.shown]
      let before = readFile(vib)
      let over = runWrite(s.filePtr, vib, vib, ofSegy)
      doAssert over.st == jsFailed, "the source path was accepted"
      doAssert "open file" in over.wrote.reason, over.wrote.reason
      doAssert readFile(vib) == before, "the source path was overwritten"
      let beside = runWrite(s.filePtr, vib, src / "0007.sgy", ofSegy)
      doAssert beside.st == jsFailed, "a name in the source folder was accepted"
      doAssert not fileExists(src / "0007.sgy")
      doAssert readFile(vib) == before
      let dest = written / "sweep.sgy"
      let named = runWrite(s.filePtr, vib, dest, ofSegy)
      doAssert named.st == jsDone, named.wrote.reason & " " & named.error
      doAssert dest.splitFile.ext == ".sgy" and fileExists(dest)
      doAssert readFile(vib) == before, "the .sgy write changed the source"
      let segd = written / "sweep.segd"
      let asSegd = runWrite(s.filePtr, vib, segd, ofSegd)
      doAssert asSegd.st == jsDone, asSegd.wrote.reason
      doAssert segd.splitFile.ext == ".segd" and fileExists(segd)
      doAssert readFile(vib) == before
      st.shutdown()

  block folder:
    # Showing the next file closes the one the panel showed, so a folder keeps
    # one open file, not every sweep. Each open file is handed to the folder
    # job on its own.
    withFixtures fx:
      let root = fx.dir / "sweeps"
      createDir(root)
      let a = datFile(root, "0042_a.dat", datSynth)
      let b = datFile(root, "0043_b.dat", datSynth)
      let v = vibFile(root, "0007.VIB", vibSynth)
      let items = @[
        BatchItem(source: a, relative: "0042_a.dat"),
        BatchItem(source: b, relative: "0043_b.dat"),
        BatchItem(source: v, relative: "0007.VIB")]
      let beforeA = readFile(a)
      let beforeB = readFile(b)
      let beforeV = readFile(v)
      let store = Store(home: fx.dir / "mem")
      createDir(store.home)
      let cold = fx.dir / "cold"
      let coldAsk = BatchAsk(root: root, items: items, destRoot: cold,
        options: OutputOptions(format: ofSegy))
      let closed = runBatch(coldAsk, store, @[])
      doAssert closed.st == jsDone, closed.error & " " & closed.wrote.reason
      doAssert closed.wrote.written == 3 and closed.wrote.failed == 0,
        "unopened sweeps written " & $closed.wrote.written & " failed " &
          $closed.wrote.failed
      for it in closed.wrote.items:
        doAssert it.outcome == boWritten, it.relative & " " & it.why
        doAssert it.destination.endsWith(".sgy"), it.destination
        doAssert not it.destination.endsWith(".dat.sgy") and
          not it.destination.endsWith(".VIB.sgy"), it.destination
      doAssert readFile(a) == beforeA and readFile(b) == beforeB and
        readFile(v) == beforeV, "an unopened sweep was changed"
      var da, db, dv: AppState
      da = initAppState()
      db = initAppState()
      dv = initAppState()
      doAssert da.openIt(a) and db.openIt(b) and dv.openIt(v)
      var opens: seq[OpenFile] = @[]
      opens.add (path: a, file: da.sessions[da.shown].filePtr, edits: FileEdits(),
        signature: da.sessions[da.shown].signature)
      opens.add (path: b, file: db.sessions[db.shown].filePtr, edits: FileEdits(),
        signature: db.sessions[db.shown].signature)
      opens.add (path: v, file: dv.sessions[dv.shown].filePtr, edits: FileEdits(),
        signature: dv.sessions[dv.shown].signature)
      let warm = fx.dir / "warm"
      let ask = BatchAsk(root: root, items: items, destRoot: warm,
        options: OutputOptions(format: ofSegy))
      let got = runBatch(ask, store, opens)
      doAssert got.st == jsDone, got.error & " " & got.wrote.reason
      doAssert got.wrote.written == 3 and got.wrote.failed == 0, $got.wrote.failed
      var traces = 0
      for it in got.wrote.items:
        doAssert it.outcome == boWritten, it.relative & " " & it.why
        doAssert it.destination.endsWith(".sgy"), it.destination
        doAssert not it.destination.endsWith(".dat") and not it.destination.endsWith(".VIB")
        var back = openSeismic(it.destination, keys = true)
        doAssert back.len == it.writtenTraces and back.len in {4, 13}, $back.len
        traces += back.len
        back.close()
      doAssert traces == 4 + 4 + 13, "sweeps were combined: " & $traces
      for it in closed.wrote.items:
        let twin = warm / it.destination.extractFilename
        let gap = diskGap(it.destination, twin, reg)
        doAssert gap.len == 0, it.relative & "\n" & gap
      doAssert readFile(a) == beforeA and readFile(b) == beforeB and
        readFile(v) == beforeV, "a sweep was changed"
      da.shutdown()
      db.shutdown()
      dv.shutdown()

  block corrupt:
    withFixtures fx:
      let root = fx.dir / "sweeps"
      createDir(root)
      let good = datFile(root, "0042_a.dat", datSynth)
      let bad = datFile(root, "bad.dat", datSynth)
      let v = vibFile(root, "0007.VIB", vibSynth)
      var raw = readFile(bad)
      doAssert raw.len > 512 * 3, "the synthetic .dat is shorter than three blocks"
      raw[512 * 2 + 40] = char(byte(raw[512 * 2 + 40]) xor 0xFF)
      writeFile(bad, raw)
      let beforeGood = readFile(good)
      let beforeBad = readFile(bad)
      let beforeV = readFile(v)
      let items = @[
        BatchItem(source: good, relative: "0042_a.dat"),
        BatchItem(source: bad, relative: "bad.dat"),
        BatchItem(source: v, relative: "0007.VIB")]
      let store = Store(home: fx.dir / "mem")
      createDir(store.home)
      let dest = fx.dir / "out"
      let got = runBatch(BatchAsk(root: root, items: items, destRoot: dest,
        options: OutputOptions(format: ofSegy)), store, @[])
      doAssert got.st == jsDone, got.error & " " & got.wrote.reason
      doAssert got.wrote.written == 2 and got.wrote.failed == 1,
        $got.wrote.written & " written, " & $got.wrote.failed & " failed"
      for it in got.wrote.items:
        if it.relative == "bad.dat":
          doAssert it.outcome == boFailed, it.why
          doAssert "could not be opened" in it.why, it.why
          doAssert "no traces" notin it.why, it.why
        else:
          doAssert it.outcome == boWritten, it.relative & " " & it.why
          doAssert fileExists(it.destination), it.destination
      doAssert readFile(good) == beforeGood and readFile(bad) == beforeBad and
        readFile(v) == beforeV, "a source was changed"

  block names:
    withFixtures fx:
      let root = fx.dir / "pair"
      createDir(root)
      let d = datFile(root, "a.dat", datSynth)
      let v = vibFile(root, "a.vib", vibSynth)
      let beforeD = readFile(d)
      let beforeV = readFile(v)
      let items = @[
        BatchItem(source: v, relative: "a.vib"),
        BatchItem(source: d, relative: "a.dat")]
      let store = Store(home: fx.dir / "mem")
      createDir(store.home)
      let dest = fx.dir / "out"
      let got = runBatch(BatchAsk(root: root, items: items, destRoot: dest,
        options: OutputOptions(format: ofSegy)), store, @[])
      doAssert got.st == jsDone, got.error & " " & got.wrote.reason
      doAssert got.wrote.written == 2 and got.wrote.failed == 0,
        $got.wrote.failed & " failed"
      doAssert not fileExists(dest / "a.sgy"), "the two sweeps were written as one file"
      for it in got.wrote.items:
        doAssert it.outcome == boWritten, it.relative & " " & it.why
        doAssert it.destination.endsWith(".vib.sgy") or
          it.destination.endsWith(".dat.sgy"), it.destination
        var noted = false
        for line in it.lines:
          if "kept in the name" in line: noted = true
        doAssert noted, it.relative & " did not say the extension was kept"
        var back = openSeismic(it.destination, keys = true)
        if it.destination.endsWith(".vib.sgy"):
          doAssert back.len == 13, $back.len
        else:
          doAssert back.len == 4, $back.len
        back.close()
      doAssert readFile(d) == beforeD and readFile(v) == beforeV,
        "a source was changed"

  block segyNamedDat:
    # A SEG-Y whose name ends `.dat` is not a signature file. Beside one
    # signature `a.vib` it keeps the replaced extension; only the signature
    # would have kept `.vib`, and one signature does not.
    withFixtures fx:
      let root = fx.dir / "mixed"
      createDir(root)
      let segy = root / "a.dat"
      copyFile(fx.oneTraceSegy(), segy)
      let v = vibFile(root, "a.vib", vibSynth)
      let beforeS = readFile(segy)
      let beforeV = readFile(v)
      let items = @[
        BatchItem(source: segy, relative: "a.dat"),
        BatchItem(source: v, relative: "a.vib")]
      let store = Store(home: fx.dir / "mem")
      createDir(store.home)
      let dest = fx.dir / "out"
      let got = runBatch(BatchAsk(root: root, items: items, destRoot: dest,
        options: OutputOptions(format: ofSegy)), store, @[])
      doAssert got.st == jsDone, got.error & " " & got.wrote.reason
      doAssert got.wrote.written == 1 and got.wrote.failed == 1,
        $got.wrote.written & " written, " & $got.wrote.failed & " failed"
      doAssert not fileExists(dest / "a.dat.sgy"), "the SEG-Y kept its extension"
      doAssert not fileExists(dest / "a.vib.sgy"), "the signature kept its extension"
      doAssert fileExists(dest / "a.sgy"), "a.sgy was not written"
      for it in got.wrote.items:
        if it.relative == "a.dat":
          doAssert it.outcome == boWritten, it.why
          doAssert it.destination == dest / "a.sgy", it.destination
          for line in it.lines:
            doAssert "kept in the name" notin line, line
          var back = openSeismic(it.destination, keys = true)
          doAssert back.len == 1, "the written file is not the SEG-Y: " & $back.len
          back.close()
        else:
          doAssert it.outcome == boFailed, it.relative & " " & it.why
          doAssert "already the output" in it.why, it.why
          doAssert it.destination == dest / "a.sgy", it.destination
          doAssert "kept in the name" notin it.why, it.why
      doAssert readFile(segy) == beforeS and readFile(v) == beforeV,
        "a source was changed"

  echo "tsigsave: ok"

when isMainModule:
  main()
