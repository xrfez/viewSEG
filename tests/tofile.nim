## The O file made from the imported survey's X records (`core/ofile`,
## `ckGenerateOFile`): the O records equal parseSEG's `receiverRelations`,
## written in the X file's revision with its H records, and read back they
## give the pairs of source and receiver stations the X records gave, none
## lost and none made up (samples/land, samples/obn, samples/vibroseis, with
## and without several channels per station). The job: a cancel leaves no
## file, a folder that cannot be made fails with the reason, an existing file
## is replaced whole, a survey file or an open file is refused. A receiver
## gather is checked by Missing traces the same against the O file as
## against the X records it was made from.
##
## Seen to fail: with the last O record left out of the file, "not the library's"
## (land, by the record count); with the H records left out, "H records differ"; with a cancel not
## checked before the write, "a cancelled job wrote the file"; with the
## refusal left out, "the X file was overwritten".

import std/[os, sequtils, sets, strutils]
import parseSEG
import viewSEG/core/[jobs, missingjobs, missingreport, ofile, state]
import utils/waiting

const
  root = currentSourcePath().parentDir.parentDir
  Surveys = [
    root / "samples" / "land" / "land.x",
    root / "samples" / "obn" / "obn.x",
    root / "samples" / "vibroseis" / "survey" / "vibroseis.x"]

proc key(s: StationKey): string =
  $s.line & ":" & $s.point & ":" & $s.index

proc xPairs(g: SurveyGeometry): HashSet[string] =
  for rec in g.records(rdSource):
    for (_, rel) in g.relations(rec, rdSource):
      if rel.component <= 1: result.incl key(rel.source) & ">" & key(rel.receiver)

proc oPairs(g: SurveyGeometry): HashSet[string] =
  for rec in g.records(rdReceiver):
    for (_, rel) in g.relations(rec, rdReceiver):
      if rel.component <= 1: result.incl key(rel.source) & ">" & key(rel.receiver)

proc geometryOf(path: string; multi: bool): SurveyGeometry =
  result = initSurveyGeometry()
  result.multiComponent = multi
  result.addSps(path)

proc headLines(text: string): seq[string] =
  for l in text.splitLines:
    if l.startsWith("H"): result.add l.strip(leading = false)

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

var lane: Jobs

proc cancelAtWrite(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if not back and phase == "Writing": discard lane.cancel(id)

proc runOFile(g: ref SurveyGeometry; source, dest: string):
    tuple[st: JobState; sink: OFileSink] =
  lane = initJobs()
  let sink = OFileSink(source: source, dest: dest)
  let id = lane.submit(oFileSpec(dest), oFileWork(g, sink))
  doAssert waitUntil(lane.state(id) in {jsDone, jsFailed, jsCancelled}),
    "the job did not finish: " & $lane.state(id)
  (lane.state(id), sink)

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
  false

proc put(line: var string; at: int; text: string) =
  for j, c in text: line[at - 1 + j] = c

proc xRec(record: int; srcPoint: int; fromCh, toCh, fromR, toR: int): string =
  result = "X" & repeat(' ', 79)
  result.put(2, "T1")
  result.put(8, align($record, 8))
  result.put(16, "11")
  result.put(18, align("1.00", 10))
  result.put(28, align($srcPoint & ".00", 10))
  result.put(38, "1")
  result.put(39, align($fromCh, 5))
  result.put(44, align($toCh, 5))
  result.put(49, "1")
  result.put(50, align("10.00", 10))
  result.put(60, align($fromR & ".00", 10))
  result.put(70, align($toR & ".00", 10))
  result.put(80, "1")

proc receiverFile(path: string; record: int; receiver: float64; sources: openArray[float64]) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0, receiverGather: true))
  let samples = @[0'f32]
  for i, src in sources:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(i + 1)
    k.srcLine = 1
    k.srcPoint = src
    k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = receiver
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, samples)
  doAssert w.close().len == 0, "receiver file was not written: " & path

proc main*() =
  let dir = getTempDir() / ("viewseg-ofile-" & $getCurrentProcessId())
  removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  block derived_equals_the_library_and_loses_nothing:
    for path in Surveys:
      doAssert fileExists(path), "missing " & path
      let head = readFile(path)
      for multi in [false, true]:
        let g = geometryOf(path, multi)
        let made = deriveOFile(g, parseSps(head, path))
        let expected = g.receiverRelations(1, 'O')
        doAssert made.file.relations.len == expected.len and expected.len > 0, path
        for i, r in made.file.relations:
          doAssert r.recordType == 'O' and r.fieldRecord == expected[i].fieldRecord and
            r.fromChannel == expected[i].fromChannel and r.toChannel == expected[i].toChannel and
            r.fromReceiver == expected[i].fromReceiver and r.toReceiver == expected[i].toReceiver,
            "record " & $i & " of " & path & " is not the library's"
        let t = spsText(made.file)
        doAssert not t.log.hasErrors, path
        # Read back with the library, as the import would.
        var back = initSurveyGeometry()
        back.multiComponent = multi
        back.addSps(parseSps(t.text, "x.ops"))
        doAssert back.relationCount(rdReceiver) == expected.len, path
        doAssert back.relationCount(rdSource) == 0
        let was = g.xPairs
        let now = back.oPairs
        doAssert was.len > 0 and was == now, "pairs differ in " & path & ": " & $was.len &
          " against " & $now.len
        doAssert made.summary.pairs >= was.len, $made.summary
        doAssert made.summary.records == expected.len
        doAssert made.summary.receivers == int(expected[^1].fieldRecord)
        # The layout: the X file's H records, then 80-column O records.
        doAssert headLines(t.text) == headLines(head), "H records differ in " & path
        for l in t.text.splitLines:
          if l.len > 0 and l[0] != 'H':
            doAssert l[0] == 'O' and l.len == 80, "not an O record of 80 columns: " & l

  block several_channels_per_station:
    let g = geometryOf(root / "samples" / "obn" / "obn.x", true)
    let made = deriveOFile(g, SpsFile())
    var channels, stations = 0
    for rec in g.records(rdSource):
      for run in g.relationRuns(rec, rdSource):
        channels += run.stations * run.components
        stations += run.stations
    doAssert channels > stations, "obn.x has no component runs here"
    doAssert made.summary.components == channels - stations, $made.summary
    doAssert made.summary.pairs == stations, $made.summary
    let said = oFileSentences(made.summary, "obn.ops", "obn.x")
    doAssert "have no component" in said or "no component" in said, said

  block file_written_beside_and_atomically:
    let source = dir / "land.x"
    copyFile(Surveys[0], source)
    let before = readFile(source)
    let g = new SurveyGeometry
    g[] = geometryOf(source, false)
    let dest = dir / "out" / "land.ops"
    let got = runOFile(g, source, dest)
    doAssert got.st == jsDone and got.sink.summary.error.len == 0, got.sink.summary.error
    doAssert got.sink.summary.file == dest and fileExists(dest)
    doAssert readFile(source) == before, "the X file was opened for writing"
    doAssert toSeq(walkFiles(dir / "out" / "*")) == @[dest], "a temporary file was left"
    var back = initSurveyGeometry()
    back.addSps(dest)
    doAssert back.oPairs == g[].xPairs
    # An existing file is replaced whole.
    writeFile(dest, "old\n")
    let again = runOFile(g, source, dest)
    doAssert again.sink.summary.error.len == 0 and readFile(dest).startsWith("H00")

  block cancel_leaves_no_file:
    let source = dir / "land.x"
    let g = new SurveyGeometry
    g[] = geometryOf(source, false)
    let dest = dir / "cancelled.ops"
    setJobHook(cancelAtWrite)
    defer: setJobHook(nil)
    let got = runOFile(g, source, dest)
    doAssert got.st == jsCancelled, $got.st
    doAssert not fileExists(dest), "a cancelled job wrote the file"
    doAssert toSeq(walkFiles(dir / "cancelled*")).len == 0, "a temporary file was left"

  block unwritable_folder_fails_with_the_reason:
    let source = dir / "land.x"
    let g = new SurveyGeometry
    g[] = geometryOf(source, false)
    let dest = source / "inside.ops" # a file where the folder should be
    let got = runOFile(g, source, dest)
    doAssert got.sink.summary.error.len > 0, "no failure for a folder that cannot be made"
    doAssert got.sink.summary.file.len == 0
    doAssert fileExists(source) and not dirExists(source)
    let missing = runOFile(g, dir / "gone.x", dir / "gone.ops")
    doAssert "cannot read" in missing.sink.summary.error and not fileExists(dir / "gone.ops"),
      missing.sink.summary.error

  block refused_targets:
    doAssert refusedTarget("/a/x.ops", ["/a/x.ops"]).len > 0
    doAssert refusedTarget("/a/y.ops", ["/a/x.ops"]).len == 0
    doAssert refusedTarget("", ["/a/x.ops"]).len > 0

  block the_command:
    let source = dir / "cmd.x"
    copyFile(Surveys[0], source)
    let bytes = readFile(source)
    var st = initAppState()
    # No relation file: nothing to take O records from.
    st.apply Command(kind: ckGenerateOFile, oDest: dir / "none.ops")
    doAssert not st.oFileRunning and st.said("no X records"), "no refusal without X records"
    st.apply Command(kind: ckLoadSurvey, paths: @[source])
    doAssert st.settle(st.relationLayer >= 0), "the X file was not loaded"
    st.apply Command(kind: ckGenerateOFile, oDest: "")
    doAssert not st.oFileRunning and st.said("no file name")
    st.apply Command(kind: ckGenerateOFile, oDest: source)
    doAssert not st.oFileRunning and readFile(source) == bytes and
      st.oFileOutcome.startsWith("The O file was not written") and
      "own files" in st.oFileOutcome, "the X file was overwritten: " & st.oFileOutcome
    let dest = dir / "cmd.ops"
    st.apply Command(kind: ckGenerateOFile, oDest: dest)
    doAssert st.settle(not st.oFileRunning and st.oFileWritten == canonical(dest)),
      "no file: " & st.oFileOutcome
    doAssert fileExists(dest) and readFile(source) == bytes
    doAssert st.said("Wrote ") and st.said("O records to cmd.ops") and st.said("not imported"),
      st.oFileOutcome
    doAssert "receivers" in st.oFileOutcome and "source points" in st.oFileOutcome

  block missing_traces_the_same_from_x_and_from_o:
    # Three shots recorded by three receivers on line 10.
    var lines = @["H00 SPS format version number   SPS 2.1;",
      xRec(1, 1, 1, 3, 1, 3), xRec(2, 2, 1, 3, 1, 3),
      xRec(3, 3, 1, 3, 1, 3)]
    let xs = parseSps(lines.join("\n"), "m.x")
    var gx = initSurveyGeometry()
    gx.addSps(xs)
    let made = deriveOFile(gx, xs)
    var go = initSurveyGeometry()
    go.addSps(parseSps(spsText(made.file).text, "m.ops"))
    doAssert go.relationCount(rdSource) == 0 and go.relationCount(rdReceiver) == 3
    let folder = dir / "gathers"
    createDir(folder)
    # Receiver 2's gather has sources 1 and 3: source 2 is missing from it.
    let file = folder / "node2.sgd"
    receiverFile(file, 9, 2.0, [1.0, 3.0])
    var totals: seq[string]
    for rels in [gx, go]:
      let relations = new SurveyGeometry
      relations[] = rels
      let jobs = initJobs()
      let sink = MissingSink()
      let id = jobs.submit(missingSpec(folder, @[file]),
        scanMissing(folder, @[file], relations, sink, ""))
      doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled}),
        "the scan did not finish"
      doAssert jobs.state(id) == jsDone, jobs.info(id).get.error
      let t = sink.result.report.totals
      doAssert t.expected == 3 and t.present == 2 and t.missing == 1, $t
      # (the numbers of the gathers without data differ: the derived ones follow the X
      # records' numbers, the file's own start at 1)
      totals.add [t.files, t.records, t.expected, t.present, t.missing, t.alsoIn, t.never,
        t.duplicates, t.extras, t.xpsWithoutData.len].join(",") & $sink.result.unmatched
    doAssert totals[0] == totals[1], "Missing traces differs: " & totals[0] & " / " & totals[1]

when isMainModule:
  main()
