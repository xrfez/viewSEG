## The receiver gather (`ckReceiverGather`, `core/receivergather`): one receiver station's
## trace from every seismic file the Files window lists, collected in memory, read-only.
##
## Synthetic files only: shots of the map fixture's survey (an X file places channel 5 of
## each record at receiver 100/105), written here one file each.
##
## - Every gathered trace equals the source trace bit for bit, in record-time order (the
##   files' order is the reverse), and the session names the file of each trace; the traces
##   keep their own source stations.
## - A file with no trace at the station is counted and said, a file of another sample
##   interval is skipped and named, a longer trace is cut and a shorter one padded with
##   zeros, and the sentence says each.
## - The traces' limit stops the gather and says so; no listed file holding the station gives
##   no session and a sentence.
## - Every edit command is refused with a sentence, no edits are kept for the gather, and its
##   edit key is no file's.
## - A cancelled gather leaves no session; stepping the main panel to another listed file
##   while the job runs does not cancel it.
## - A trace whose start differs by whole samples is shifted onto the gather's axis, one by a
##   part of a sample is left out and named; a file whose interval is not given sets nothing.
## - The survey is the map's, with or without a project, and a survey still loading refuses
##   the command. A file listed twice is read once; a killed trace is left out; "any
##   component" takes every component.
## - A full gather opens no later file; a single trace over the byte limit is refused.
## - The gather's key reaches no file system call, a reopen is refused, a station move leaves
##   its keys alone, and replacing it says it was closed.
##
## - A project survey being updated while one is loaded refuses the command with its own
##   sentence; a survey that failed to load gets the same note as one never loaded.
##
## Seen to fail: with the project-survey update not told apart, "surveyUpdating" found the loading sentence; with the refusal on `projectSurveyLoading` back, a cancelled project survey load
## refused the gather for good; with the window test taken out, "b-far.sgy" came as a trace of zeros; with the
## refusal in `editTraces` taken out, "an edit is refused" failed on
## the first edit; with the sort by record time left out, trace 0 was the first file's, not
## the earliest shot's; with the listed files back in the job's reads, "stepAway" ended with
## a cancelled gather; with the shift taken out, "a later start was not shifted"; with no
## survey given, no trace was found; with the look for files listed twice taken out, 3
## traces came, not 2; with the reopen refusal taken out, "a reopen was not refused"; with
## the join queues' skip of a gather taken out, "a move changed the gather"; with every
## interval accepted, the first file's interval set the gather's and the run overflowed;
## with the stop flag not set, 150 files were touched; with the single-trace check taken out,
## no file said "over the memory limit"; with the kills ignored, 5 traces came; with the
## "closed" line taken out, none was said; with the exact component only, "any component"
## found none; with the loading check taken out, the gather ran with the survey loading.

import std/[atomics, locks, os, sequtils, sets, strutils]
import parseSEG
import viewSEG/core/[edits, filesystem, jobs, receivergather, session, state, stationmoves]
import utils/[fixtures, waiting]

const
  Samples = 16
  Time0 = 1_700_000_000.0
  Station = (line: 100.0, point: 105.0) ## channel 5 of a record the X file lists

var gate: Gate
var reached: Atomic[bool]
var keyTouched: Atomic[bool] ## a file system call named a gather's key
var touchLock: Lock
var touched: HashSet[string] ## files the job's threads touched
var mainThread: int

proc holdOpen(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    if op in {foOpen, foMapped} and path.endsWith("b-shot2.sgy") and
        getThreadId() != mainThread:
      reached.store(true)
      var waited = 0
      while not gate.isOpen and waited < 60_000:
        sleep 1
        inc waited

proc holdSurvey(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    if op == foOpen and path.endsWith("survey.bin") and getThreadId() != mainThread:
      reached.store(true)
      var waited = 0
      while not gate.isOpen and waited < 60_000:
        sleep 1
        inc waited

proc watchKeys(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if "gathered" in path or '\0' in path: keyTouched.store(true)

proc countOpens(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  if op in {foOpen, foMapped} and getThreadId() != mainThread and path.endsWith(".sgy"):
    {.cast(gcsafe).}:
      withLock touchLock:
        touched.incl path

proc shotFile(path: string; record: int64; time: float64; intervalUs = 2000.0;
    samples = Samples; t0Ms = 0.0; rev1 = false) =
  ## A record of 30 channels; the sample `i` of channel `ch` is its own number.
  var opts = SegyOutputOptions(traceSorting: 1, measurementSystem: 1)
  if rev1: opts.revision = SegyRevision(major: 1, minor: 0)
  var w = openSeismicWriter(path, opts)
  for ch in 1 .. 30:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    k.srcPoint = 1000.0 + float64(record) # the X record's source
    k.time = time
    k.t0Ms = t0Ms
    (k.intervalUs, k.status) = (intervalUs, tsLive)
    var buf = newSeq[float32](samples)
    for i in 0 ..< samples: buf[i] = float32(int(record) * 1000 + ch * 10) + float32(i) * 0.37'f32
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "shot file was not written: " & path

proc componentFile(path: string; component: int) =
  ## A SEG-D file of one trace: receiver 100/105, record 99, the given component.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: Samples))
  var k = initTraceKeys()
  k.status = tsLive
  (k.record, k.channel, k.component) = (99.0, 1.0, uint8(component))
  (k.rcvLine, k.rcvPoint, k.intervalUs, k.time) = (100.0, 105.0, 2000.0, Time0 + 600)
  (k.srcLine, k.srcPoint) = (1.0, 1099.0)
  var buf = newSeq[float32](Samples)
  for i in 0 ..< Samples: buf[i] = 9000'f32 + float32(i)
  w.writeTrace(k, buf)
  doAssert w.close().len == 0, "component file was not written: " & path

proc zeroInterval(path: string) =
  ## Writes 0 into the file's sample interval fields (the writer refuses to), binary header
  ## and every trace header: a file whose interval is not given.
  var bytes = readFile(path)
  bytes[3216] = '\0'
  bytes[3217] = '\0'
  var at = 3600
  while at + 240 <= bytes.len:
    bytes[at + 116] = '\0'
    bytes[at + 117] = '\0'
    at += 240 + Samples * 4
  writeFile(path, bytes)

proc sourceTrace(path: string; index: int): seq[float32] =
  ## Trace `index` of the file at `path`, as the viewer reads it.
  var f = openSeismic(path, keys = true)
  var log: DiagLog
  let n = int(f.index.entries[index].numSamples)
  let block1 = f.readTraces([index], 0 ..< n, log)
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = block1[0, i]
  f.close()

proc fitted(x: seq[float32]; n: int): seq[float32] =
  result = x
  result.setLen n

proc gatherSamples(s: Session; trace: int): seq[float32] =
  var log: DiagLog
  let block1 = s.filePtr[].readTraces([trace], 0 ..< Samples, log)
  result = newSeq[float32](Samples)
  for i in 0 ..< Samples: result[i] = block1[0, i]

proc sayings(st: AppState; word: string): int =
  for e in st.log:
    if e.text.contains(word): inc result

proc lastSaid(st: AppState): string =
  ## The newest sentence about a gather.
  for i in countdown(st.log.len - 1, 0):
    let t = st.log[i].text
    if t.startsWith("Gathered") or t.startsWith("No listed file") or "gather" in t:
      return t

proc ask(st: var AppState; line = Station.line; point = Station.point; component = 0) =
  st.apply Command(kind: ckReceiverGather, gatherLine: line, gatherPoint: point,
    gatherComponent: component)

proc main*() =
  mainThread = getThreadId()
  initLock touchLock
  withFixtures fx:
    let (sps, _) = (fx.mapSps, 0)
    let xps = fx.mapXps
    let dir = fx.dir / "shots"
    createDir(dir)
    let names = ["a-shot1.sgy", "b-shot2.sgy", "c-shot3.sgy", "d-other.sgy", "e-fast.sgy",
      "f-long.sgy", "g-short.sgy"]
    let paths = names.mapIt(dir / it)
    shotFile(paths[0], 1, Time0 + 300)
    shotFile(paths[1], 2, Time0 + 200)
    shotFile(paths[2], 3, Time0 + 100)
    shotFile(paths[3], 900, Time0 + 50) # a record the X file does not list: no stations
    shotFile(paths[4], 4, Time0 + 60, intervalUs = 1000.0)
    shotFile(paths[5], 5, Time0 + 400, samples = 24)
    shotFile(paths[6], 6, Time0 + 500, samples = 8)
    var st = initAppState()
    st.rememberFilesIn(fx.dir / "config")
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckNewProject, projectPath: fx.dir / "Job 1", dataFolders: @[dir])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0)
    let before = st.joinReport.serial
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
      JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
      JoinFile(path: xps, kind: jkSps)])
    doAssert st.settle(st.joinReport.serial > before and not st.importing)
    doAssert st.settle(st.project.survey == srLoaded and st.project.doc.hasStore)
    st.apply Command(kind: ckBrowse, paths: @[dir])
    doAssert st.settle(not st.fileList.scanning and st.fileList.folder == dir)

    block gathered:
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), "no gather came: " & st.lastSaid
      let s = st.sessions[0]
      let said = st.lastSaid
      doAssert s.name == "Receiver gather 100/105", s.name
      doAssert s.path notin paths and s.diskPath notin paths
      # time order c, b, a (the files' order reversed), then the late f and g
      let order = [2, 1, 0, 5, 6]
      let records = [1, 2, 3, 900, 4, 5, 6]
      doAssert s.len == order.len, $s.len & ": " & said
      for i, f in order:
        doAssert s.gatherSource(i) == paths[f], "trace " & $i & " is from " & s.gatherSource(i)
        let want = sourceTrace(paths[f], 4).fitted(Samples)
        doAssert gatherSamples(s, i) == want, "samples of trace " & $i & " differ"
        let k = s.file.index.keys[i]
        doAssert k.srcPoint == 1000.0 + float64(records[f]) and k.rcvPoint == 105.0 and
          k.rcvLine == 100.0, "keys of trace " & $i & ": " & $k.srcPoint
      doAssert s.gatherSource(order.len).len == 0 and s.gatherSources.len == 5
      doAssert "Gathered 5 traces" in said and "from 5 files of the 7 listed" in said, said
      doAssert "d-other.sgy" notin said and "1 file has no trace at the station" in said, said
      doAssert "e-fast.sgy (sample interval 1 ms, the gather's is 2 ms)" in said, said
      doAssert "1 shorter trace padded with zeros" in said and "1 longer trace cut" in said,
        said
      doAssert s.gathers.len == 1 and s.gathers[0].traces.len == order.len
      # the zeros the padding added
      doAssert gatherSamples(s, 4)[Samples - 1] == 0'f32

      block editKeyIsNoFiles:
        let own = st.editKeyOf(s.path)
        for p in paths: doAssert own != st.editKeyOf(p) and own != p, "the edit key is a file's"

      block editsRefused:
        let id = s.base
        let commands = [Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[id],
          on: true), Command(kind: ckReverseAll, panel: MainPanel, reverse: true),
          Command(kind: ckUndoEdit, panel: MainPanel), Command(kind: ckRedoEdit, panel: MainPanel),
          Command(kind: ckClearEdits, panel: MainPanel),
          Command(kind: ckTimeShift, panel: MainPanel, edited: @[id], on: true, ms: 4.0),
          Command(kind: ckOwnFilter, panel: MainPanel, edited: @[id], on: true)]
        for c in commands:
          let n = st.sayings("read-only")
          st.apply c
          doAssert st.sayings("read-only") == n + 1, "an edit is refused: " & $c.kind
          doAssert st.editsAt(s.path).isEmpty, "an edit was kept: " & $c.kind
    # closing frees it
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.sessions.len == 0)

    block cap:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      gatherTraces = 2
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      gatherTraces = 20_000
      doAssert st.sessions[0].len == 2, $st.sessions[0].len
      doAssert "Stopped at the limit of 2 traces" in st.lastSaid, st.lastSaid
      gatherBytes = 2 * Samples * 4
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered)
      gatherBytes = 512'i64 shl 20
      doAssert st.sessions[0].len == 2 and "memory limit" in st.lastSaid, st.lastSaid

    block zeroMatches:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      let id = st.sessions[0].id
      st.ask(point = 999.0)
      doAssert st.settle(st.jobs.active.len == 0 and
        "No listed file holds receiver station 100/999" in st.lastSaid), st.lastSaid
      doAssert st.sessions.len == 1 and st.sessions[0].id == id, "a session was made"

    block cancel:
      gate.close()
      reached.store(false)
      setFsHook(holdOpen)
      st.ask()
      doAssert waitUntil(reached.load), "the job did not reach its file"
      doAssert st.jobs.active.len == 1
      let job = st.jobs.active[0].id
      st.apply Command(kind: ckCancelJob, job: job)
      gate.open
      doAssert st.settle(st.jobs.active.len == 0)
      setFsHook(nil)
      doAssert st.settle(st.jobs.info(job).get.state == jsCancelled)
      doAssert st.sessions.len == 1 and not st.sessions[0].gathered, "a cancel left a session"
      doAssert "was cancelled" in st.lastSaid, st.lastSaid

    block stepAway:
      # stepping the main panel to another listed file while the job is held closes the file
      # it showed: the gather goes on (no listed file is in the job's reads)
      gate.close()
      reached.store(false)
      setFsHook(holdOpen)
      st.ask()
      doAssert waitUntil(reached.load), "the job did not reach its file"
      let job = st.jobs.active[0].id
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[2])
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].diskPath == paths[2])
      doAssert st.jobs.info(job).get.state in {jsQueued, jsRunning}, "the gather was cancelled"
      gate.open
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      setFsHook(nil)
      doAssert st.sessions[0].len == 5

    block keyIsNoFile:
      let s = st.sessions[0]
      let keys = s.file.index.keys.mapIt($it)
      keyTouched.store(false)
      setFsHook(watchKeys)
      let said = st.sayings("no options to reopen")
      st.apply Command(kind: ckReopen, reopenPath: s.path)
      doAssert st.sayings("no options to reopen") == said + 1, "a reopen was not refused"
      doAssert st.sessions.len == 1 and st.sessions[0].gathered and not keyTouched.load,
        "the gather's key reached the file system"
      # a station move and a survey update leave the gather's keys as they were
      var moves = StationMoves()
      moves.add StationMove(station: stationKey(100, 105, 1), x: 1.0, y: 2.0)
      st.setStationMoves(moves)
      for _ in 1 .. 3:
        doAssert st.settle(st.jobs.active.len == 0)
        sleep 100
      doAssert st.sessions[0].file.index.keys.mapIt($it) == keys, "a move changed the gather"
      doAssert not keyTouched.load, "the gather's key reached the file system"
      doAssert st.sayings("Matched Receiver gather") == 0
      setFsHook(nil)
      st.setStationMoves(StationMoves())
      doAssert st.settle(st.jobs.active.len == 0)

    block replacedSaid:
      let said = st.sayings("The receiver gather 100/105 was closed.")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      doAssert st.sayings("The receiver gather 100/105 was closed.") == said + 1

    block limits:
      # a full gather opens no more files; a trace bigger than the memory limit is refused
      let many = fx.dir / "many"
      createDir(many)
      for i in 1 .. 150: shotFile(many / ("f" & align($i, 3, '0') & ".sgy"), 1, Time0 + float64(i))
      st.apply Command(kind: ckBrowse, paths: @[many])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == many)
      doAssert st.settle(st.jobs.active.len == 0) # (the kinds of the files are read)
      gatherTraces = 1
      touched.clear()
      setFsHook(countOpens)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      setFsHook(nil)
      gatherTraces = 20_000
      doAssert st.sessions[0].len == 1 and "Stopped at the limit of 1 trace" in st.lastSaid,
        st.lastSaid
      doAssert touched.len < 150, "every file was opened: " & $touched.len
      doAssert "later files" in st.lastSaid, st.lastSaid
      st.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == dir)
      gatherBytes = 8
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and
        "over the memory limit" in st.lastSaid), st.lastSaid
      gatherBytes = 512'i64 shl 20
      doAssert not st.sessions[0].gathered

    block times:
      # start times: a whole number of samples is shifted, a part of a sample is left out; an
      # interval that is not given sets nothing; the components; a file listed twice
      let d2 = fx.dir / "times"
      createDir(d2)
      shotFile(d2 / "0-nointerval.sgy", 7, Time0 + 700, rev1 = true)
      zeroInterval(d2 / "0-nointerval.sgy")
      shotFile(d2 / "a.sgy", 1, Time0 + 300)
      shotFile(d2 / "b-late.sgy", 2, Time0 + 200, t0Ms = 4.0)
      shotFile(d2 / "c-frac.sgy", 3, Time0 + 100, t0Ms = 1.0)
      shotFile(d2 / "d-early.sgy", 4, Time0 + 400, t0Ms = -4.0)
      componentFile(d2 / "e-comp.sgd", 2)
      st.apply Command(kind: ckBrowse, paths: @[d2])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == d2)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      let s = st.sessions[0]
      let said = st.lastSaid
      doAssert s.len == 3, $s.len & ": " & said
      let late = sourceTrace(d2 / "b-late.sgy", 4)
      let early = sourceTrace(d2 / "d-early.sgy", 4)
      let a = sourceTrace(d2 / "a.sgy", 4)
      # record time order: b (200), a (300), d (400)
      doAssert s.gatherSource(0) == d2 / "b-late.sgy" and s.gatherSource(1) == d2 / "a.sgy"
      var want = newSeq[float32](Samples)
      for j in 2 ..< Samples: want[j] = late[j - 2]
      doAssert gatherSamples(s, 0) == want, "a later start was not shifted"
      doAssert gatherSamples(s, 1) == a
      for j in 0 ..< Samples - 2: want[j] = early[j + 2]
      want[Samples - 2] = 0
      want[Samples - 1] = 0
      doAssert gatherSamples(s, 2) == want, "an earlier start was not shifted"
      for i in 0 ..< s.len: doAssert s.file.index.keys[i].t0Ms == 0.0, "t0 of trace " & $i
      doAssert "2 traces start at another time and were shifted to the gather's" in said, said
      doAssert "c-frac.sgy (starts 1 ms from the gather's start, not a whole number of " &
        "samples)" in said, said
      doAssert "0-nointerval.sgy (sample interval not given)" in said and
        "e-comp.sgd" notin said, said
      # any component takes e-comp's trace too, in file order
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: d2 / "a.sgy")
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      st.ask(component = AnyComponent)
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      doAssert st.sessions[0].len == 4 and "(any component)" in st.lastSaid, st.lastSaid
      doAssert d2 / "e-comp.sgd" in st.sessions[0].gatherSources
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: d2 / "a.sgy")
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      st.ask(component = 7)
      doAssert st.settle(st.jobs.active.len == 0 and
        "No listed file holds receiver station 100/105 (component 7)" in st.lastSaid), st.lastSaid

    block outsideWindow:
      # a trace that starts so far away that none of its samples is in the gather's window is
      # left out and named; one that overlaps partly is shifted and counted as having lost
      # samples
      let d3 = fx.dir / "window"
      createDir(d3)
      shotFile(d3 / "a-first.sgy", 1, Time0 + 100)
      shotFile(d3 / "b-far.sgy", 2, Time0 + 200, t0Ms = 100.0)
      shotFile(d3 / "c-near.sgy", 3, Time0 + 300, t0Ms = -2.0)
      st.apply Command(kind: ckBrowse, paths: @[d3])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == d3)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      let said = st.lastSaid
      doAssert st.sessions[0].len == 2, $st.sessions[0].len & ": " & said
      doAssert "b-far.sgy (starts outside the gather's time window)" in said, said
      doAssert "1 trace starts at another time and was shifted to the gather's; " &
        "1 of them lost samples at an end" in said, said
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: d3 / "a-first.sgy")
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)

    block windowBoundary:
      # the 16 sample window at 2 ms is 32 ms long: a start at 32.0 ms is outside it and is
      # named; one at 30.0 ms keeps its first sample as the window's last
      let d4 = fx.dir / "boundary"
      createDir(d4)
      shotFile(d4 / "a-first.sgy", 1, Time0 + 100)
      shotFile(d4 / "b-edge.sgy", 2, Time0 + 200, t0Ms = 32.0)
      shotFile(d4 / "c-inside.sgy", 3, Time0 + 300, t0Ms = 30.0)
      st.apply Command(kind: ckBrowse, paths: @[d4])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == d4)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      let said = st.lastSaid
      doAssert st.sessions[0].len == 2, $st.sessions[0].len & ": " & said
      doAssert "b-edge.sgy (starts outside the gather's time window)" in said, said
      doAssert "c-inside.sgy" notin said, said
      let kept = gatherSamples(st.sessions[0], 1)
      doAssert kept[15] == 3050'f32, $kept
      for j in 0 ..< 15: doAssert kept[j] == 0'f32, $kept
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: d4 / "a-first.sgy")
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)

    block listedTwice:
      let top = fx.dir / "top"
      createDir top / "sub"
      for r in 1 .. 2: shotFile(top / "sub" / ("shot" & $r & ".sgy"), r, Time0 + float64(r))
      createSymlink(top / "sub" / "shot1.sgy", top / "link1.sgy")
      st.apply Command(kind: ckBrowse, paths: @[top])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == top)
      st.apply Command(kind: ckSubfolders, subfolders: true)
      doAssert st.settle(not st.fileList.scanning and st.fileList.recursive)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      doAssert st.sessions[0].len == 2 and "1 file listed twice was read once" in st.lastSaid,
        $st.sessions[0].len & ": " & st.lastSaid

    block killed:
      st.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert st.settle(not st.fileList.scanning and st.fileList.folder == dir)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert st.settle(st.sessions.len == 1 and not st.sessions[0].gathered)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
        edited: @[st.sessions[0].base + 4], on: true)
      st.ask()
      doAssert st.settle(st.jobs.active.len == 0 and st.sessions.len == 1 and
        st.sessions[0].gathered), st.lastSaid
      doAssert st.sessions[0].len == 4 and paths[0] notin st.sessions[0].gatherSources and
        "1 killed trace left out" in st.lastSaid, st.lastSaid

    block noProject:
      # the map's survey files place the traces with no project open; a survey still being
      # loaded is no reason to gather with none
      var lone = initAppState()
      lone.rememberFilesIn(fx.dir / "config2")
      lone.apply Command(kind: ckShowFile, panel: MainPanel, path: paths[0])
      doAssert lone.settle(lone.sessions.len == 1 and lone.panel(MainPanel).laidOut)
      lone.apply Command(kind: ckJoin, joinFile: lone.sessions[0].id, joinFiles: @[
        JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
        JoinFile(path: xps, kind: jkSps)])
      lone.ask()
      doAssert lone.sayings("still loading") == 1, "a gather ran with the survey loading"
      doAssert lone.settle(not lone.importing and lone.survey.layers.len >= 3)
      lone.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert lone.settle(not lone.fileList.scanning and lone.fileList.folder == dir)
      lone.ask()
      doAssert lone.settle(lone.jobs.active.len == 0 and lone.sessions.len == 1 and
        lone.sessions[0].gathered), lone.lastSaid
      doAssert lone.sessions[0].len == 5, $lone.sessions[0].len & ": " & lone.lastSaid
      lone.shutdown()

    block surveyCancelled:
      # the project's survey load is cancelled: the document still has a survey, which is
      # not loaded, and that is no reason to refuse: the gather runs and says so
      st.flushFiles()
      st.shutdown()
      var re = initAppState()
      re.rememberFilesIn(fx.dir / "config3")
      gate.close()
      reached.store(false)
      setFsHook(holdSurvey)
      re.apply Command(kind: ckOpenProject, projectPath: fx.dir / "Job 1")
      doAssert re.settle(reached.load), "the survey load did not start"
      doAssert re.settle(re.jobs.active.anyIt(it.spec.title == "Load the project's survey"))
      let load = re.jobs.active.filterIt(it.spec.title == "Load the project's survey")[0].id
      re.apply Command(kind: ckCancelJob, job: load)
      gate.open
      doAssert re.settle(re.jobs.info(load).get.state == jsCancelled)
      setFsHook(nil)
      doAssert re.project.survey == srNone and re.project.doc.hasSurvey and
        re.projectSurveyLoading, "the survey is not left cancelled"
      re.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert re.settle(not re.fileList.scanning and re.fileList.folder == dir)
      re.ask()
      # (no survey file is on the map, so no station is found: the gather ran and said so)
      doAssert re.settle(re.jobs.active.len == 0 and
        "No listed file holds receiver station 100/105" in re.lastSaid),
        "refused: " & re.lastSaid
      doAssert re.sayings("still loading") == 0
      doAssert "The project's survey is not loaded: stations come from the headers and " &
        "the survey files on the map." in re.lastSaid, re.lastSaid
      re.shutdown()

    block surveyUpdating:
      # "Update survey" with the survey loaded: the gather is refused with its own sentence
      sleep 20 # a later modification time than the copy's
      let original = open(sps.s, fmAppend)
      original.write "\n"
      original.close()
      var up = initAppState()
      up.rememberFilesIn(fx.dir / "config4")
      up.apply Command(kind: ckOpenProject, projectPath: fx.dir / "Job 1")
      doAssert up.settle(up.inProject and up.project.survey == srLoaded and up.project.offer),
        "the project did not open with a changed original"
      up.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert up.settle(not up.fileList.scanning and up.fileList.folder == dir)
      up.apply Command(kind: ckUpdateSurvey)
      doAssert up.project.survey == srKeeping, "the update did not start"
      up.ask()
      doAssert up.sayings("is being copied into the project") == 1, "refused with another sentence"
      doAssert up.sayings("still loading") == 0
      doAssert up.settle(up.jobs.active.len == 0 and up.project.survey in {srLoaded, srFailed})
      up.flushFiles()
      up.shutdown()

    block surveyFailed:
      # a survey that failed to load is not loaded: the gather runs and says so
      # (survey.bin and the project's copies of the survey files are gone: it cannot be made)
      removeDir(fx.dir / "Job 1" / "survey")
      var bad = initAppState()
      bad.rememberFilesIn(fx.dir / "config5")
      bad.apply Command(kind: ckOpenProject, projectPath: fx.dir / "Job 1")
      doAssert bad.settle(bad.inProject and bad.project.survey == srFailed),
        "the survey did not fail: " & $bad.project.survey
      bad.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert bad.settle(not bad.fileList.scanning and bad.fileList.folder == dir)
      bad.ask()
      doAssert bad.settle(bad.jobs.active.len == 0 and
        "No listed file holds receiver station 100/105" in bad.lastSaid), bad.lastSaid
      doAssert "The project's survey is not loaded" in bad.lastSaid, bad.lastSaid
      bad.shutdown()
  echo "treceivergather: done"

when isMainModule:
  main()
