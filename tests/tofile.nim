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
## refusal left out, "the X file was overwritten"; with only the names compared, "the file
## behind a link is not refused".

import std/[os, sequtils, sets, strutils]
when defined(linux):
  import std/posix
  const RlimitFsize = 1.cint # RLIMIT_FSIZE on Linux
import parseSEG
import viewSEG/core/[jobs, missingjobs, missingreport, ofile, shotlogsps, state]
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
  let sink = OFileSink(sources: @[source], dest: dest)
  let id = lane.submit(oFileSpec(dest), oFileWork(@[g], sink))
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
    let said = oFileSentences(made.summary, "obn.ops", ["obn.x"])
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

  block symlinked_survey_file_is_refused:
    when defined(posix):
      let real = dir / "real"
      createDir(real)
      let target = real / "land.x"
      copyFile(Surveys[0], target)
      let bytes = readFile(target)
      createSymlink(target, dir / "link.x")
      doAssert refusedTarget(target, [dir / "link.x"]).len > 0,
        "the file behind a link is not refused"
      doAssert refusedTarget(dir / "link.x", [target]).len > 0, "a link to the X file is not refused"
      doAssert refusedTarget(real / "other.ops", [dir / "link.x"]).len == 0
      doAssert refusedTarget(target, [dir / "gone.x"]).len == 0, "a missing source refused a target"
      var st = initAppState()
      st.apply Command(kind: ckLoadSurvey, paths: @[dir / "link.x"])
      doAssert st.settle(st.relationLayer >= 0), "the linked X file was not loaded"
      st.apply Command(kind: ckGenerateOFile, oDest: target)
      doAssert not st.oFileRunning and readFile(target) == bytes,
        "the X file was overwritten through a link"
      doAssert "own files" in st.oFileOutcome, st.oFileOutcome

  block full_disk_is_an_error:
    when defined(linux):
      # A file size limit stands for a full disk: the write comes up short.
      let dest = dir / "full.ops"
      writeFile(dest, "OLD")
      var old: RLimit
      doAssert getrlimit(RlimitFsize, old) == 0
      var small = old
      small.rlim_cur = 1000
      let was = signal(SIGXFSZ, SIG_IGN)
      doAssert setrlimit(RlimitFsize, small) == 0
      let err = writeBeside(dest, repeat('O', 3000), replace = true)
      doAssert setrlimit(RlimitFsize, old) == 0
      discard signal(SIGXFSZ, was)
      doAssert err.len > 0, "a truncated file was reported as written: '" & err & "'"
      doAssert readFile(dest) == "OLD", "the target was touched"
      doAssert toSeq(walkFiles(dir / "full.ops*")) == @[dest], "a temporary file was left"

  block every_x_file_is_used:
    # Two files give receivers 1 to 3 the sources (1, 2) and (2, 3): source 2 is in both.
    const H00 = "H00 SPS format version number   SPS 2.1;"
    let one = dir / "one.x"
    let two = dir / "two.x"
    writeFile(one, [H00, xRec(1, 1, 1, 3, 1, 3), xRec(2, 2, 1, 3, 1, 3)].join("\n") & "\n")
    writeFile(two, [H00, xRec(1, 2, 1, 3, 1, 3), xRec(2, 3, 1, 3, 1, 3)].join("\n") & "\n")
    var union = initHashSet[string]()
    var each: seq[ref SurveyGeometry]
    for p in [one, two]:
      let g = new SurveyGeometry
      g[] = geometryOf(p, false)
      each.add g
      union.incl g[].xPairs
    doAssert union.len == 9
    let made = deriveOFile(each, parseSps(readFile(one), one))
    doAssert made.summary.shared == 3, $made.summary
    doAssert made.summary.sources == 3 and made.summary.receivers == 3, $made.summary
    var back = initSurveyGeometry()
    back.addSps(parseSps(spsText(made.file).text, "both.ops"))
    doAssert back.oPairs == union, "pairs differ: " & $back.oPairs.len & " against " & $union.len
    doAssert made.summary.pairs == 9
    var st = initAppState()
    st.apply Command(kind: ckLoadSurvey, paths: @[one, two])
    doAssert st.settle(st.survey.layers.len == 2 and st.relationLayer >= 0), "no two X files"
    let dest = dir / "both.ops"
    st.apply Command(kind: ckGenerateOFile, oDest: dest)
    doAssert st.settle(not st.oFileRunning and st.oFileWritten.len > 0), st.oFileOutcome
    doAssert "one.x, two.x" in st.oFileOutcome and "written once" in st.oFileOutcome,
      st.oFileOutcome
    var file = initSurveyGeometry()
    file.addSps(dest)
    doAssert file.oPairs == union

  proc pairsOfRelations(rels: seq[SpsRelation]): HashSet[string] =
    var g = initSurveyGeometry()
    g.addSps(SpsFile(relations: rels), rdSource)
    g.xPairs

  proc relation(rec: int; srcPoint: float64; fromCh, toCh: int; rcvLine, fromR, toR: float64):
      SpsRelation =
    result = initSpsRelation()
    result.fieldRecord = rec
    (result.srcLine, result.srcPoint) = (1.0, srcPoint)
    (result.fromChannel, result.toChannel) = (int64(fromCh), int64(toCh))
    (result.rcvLine, result.fromReceiver, result.toReceiver) = (rcvLine, fromR, toR)

  block revision_1_0_that_does_not_fit_is_written_as_2_1:
    # 10 005 receivers on one line: more gathers than SPS 1.0's four digits number.
    var g = initSurveyGeometry()
    g.addSps(SpsFile(relations: @[relation(1, 1, 1, 10_005, 10, 1, 10_005)]), rdSource)
    var head = SpsFile(revision: sps10, revisionDeclared: true)
    head.headers = @[SpsHeader(code: "00", description: "SPS format version num.",
      data: "SPS001;")]
    var made = deriveOFile(g, head)
    doAssert made.summary.revision == sps10
    let text = renderOFile(made.file, made.summary)
    doAssert made.summary.error.len == 0 and made.summary.widened and
      made.summary.revision == sps21, $made.summary
    doAssert "SPS 2.1" in text.splitLines[0], text.splitLines[0]
    var back = initSurveyGeometry()
    back.addSps(parseSps(text, "w.ops"))
    doAssert back.oPairs == g.xPairs and back.oPairs.len == 10_005
    doAssert "written as SPS 2.1" in oFileSentences(made.summary, "w.ops", ["w.x"])
    # One that fits stays SPS 1.0.
    var small = initSurveyGeometry()
    small.addSps(SpsFile(relations: @[relation(1, 1, 1, 5, 10, 1, 5)]), rdSource)
    var m2 = deriveOFile(small, head)
    let t2 = renderOFile(m2.file, m2.summary)
    doAssert not m2.summary.widened and m2.summary.revision == sps10 and
      "SPS001" in t2.splitLines[0], t2.splitLines[0]

  block receiver_with_more_traces_than_the_columns_hold:
    # 100 005 sources recorded by one receiver: SPS 2.1 counts to 99 999 traces.
    var g = initSurveyGeometry()
    var rels: seq[SpsRelation]
    for i in 1 .. 100_005: rels.add relation(i, float64(i), 1, 1, 10, 1, 1)
    g.addSps(SpsFile(relations: rels), rdSource)
    var made = deriveOFile(g, SpsFile())
    let text = renderOFile(made.file, made.summary)
    doAssert made.summary.error.len == 0 and made.summary.extraGathers == 1 and
      made.summary.records == 2, $made.summary
    var back = initSurveyGeometry()
    back.addSps(parseSps(text, "b.ops"))
    doAssert back.oPairs == g.xPairs and back.oPairs.len == 100_005,
      "pairs differ: " & $back.oPairs.len
    doAssert "gather was added" in oFileSentences(made.summary, "b.ops", ["b.x"])

  block what_does_not_fit_names_the_o_record:
    var g = initSurveyGeometry()
    g.addSps(SpsFile(relations: @[relation(1, 1, 1, 1, 12_345_678_901.0, 1, 1)]), rdSource)
    var made = deriveOFile(g, SpsFile())
    let text = renderOFile(made.file, made.summary)
    doAssert text.len == 0 and made.summary.error.len > 0
    doAssert "O record" in made.summary.error and "X." notin made.summary.error,
      made.summary.error

  block head_is_read_to_the_first_record:
    # 4 000 H26 records (over 300 KB), then 60 000 X records (5 MB): all the H
    # records are copied, the X records are not read.
    var text = "H00 SPS format version num.     SPS 2.1;\n"
    for i in 0 ..< 4000: text.add "H26 " & align($i, 70) & "\n"
    let hp = dir / "bighead.x"
    var body = newStringOfCap(17_000_000)
    body.add text
    for i in 1 .. 60_000: body.add xRec(i, i, 1, 3, 1, 3) & "\n"
    writeFile(hp, body)
    let head = readHead(hp)
    doAssert head.headers.len == 4001, "H records: " & $head.headers.len
    doAssert head.revision == sps21 and head.relations.len < 20_000,
      "the file was read past its head: " & $head.relations.len
    doAssert headLines(spsText(SpsFile(headers: head.headers)).text).len == 4001
    var asked = ""
    try:
      discard readHead(hp, limit = 100_000)
    except IOError as e:
      asked = e.msg
    doAssert "bighead.x" in asked and "run past" in asked, asked
    let through = new SurveyGeometry
    through[] = geometryOf(hp, false)
    let made = runOFile(through, hp, dir / "bighead.ops")
    doAssert made.sink.summary.error.len == 0 and made.sink.summary.headers == 4001,
      $made.sink.summary
    # A file of records only has no head, and a short one with no end of line is read.
    writeFile(dir / "nohead.x", xRec(1, 1, 1, 3, 1, 3))
    doAssert readHead(dir / "nohead.x").headers.len == 0
    doAssert readHead(dir / "nohead.x").relations.len == 1

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
