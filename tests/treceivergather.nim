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
## - A cancelled gather leaves no session.
##
## Seen to fail: with the refusal in `editTraces` taken out, "an edit is refused" failed on
## the first edit; with the sort by record time left out, trace 0 was the first file's, not
## the earliest shot's.

import std/[atomics, os, sequtils, strutils]
import parseSEG
import viewSEG/core/[edits, filesystem, jobs, receivergather, session, state]
import utils/[fixtures, waiting]

const
  Samples = 16
  Time0 = 1_700_000_000.0
  Station = (line: 100.0, point: 105.0) ## channel 5 of a record the X file lists

var gate: Gate
var reached: Atomic[bool]
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

proc shotFile(path: string; record: int64; time: float64; intervalUs = 2000.0;
    samples = Samples) =
  ## A record of 30 channels; the sample `i` of channel `ch` is its own number.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for ch in 1 .. 30:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    k.srcPoint = 1000.0 + float64(record) # the X record's source
    k.time = time
    (k.intervalUs, k.status) = (intervalUs, tsLive)
    var buf = newSeq[float32](samples)
    for i in 0 ..< samples: buf[i] = float32(int(record) * 1000 + ch * 10) + float32(i) * 0.37'f32
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "shot file was not written: " & path

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
        st.sessions[0].gathered)
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
    st.shutdown()
  echo "treceivergather: done"

when isMainModule:
  main()
