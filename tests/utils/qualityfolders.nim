## Small synthetic folders for the trace-quality scan, one `Scenario` each: shot gathers,
## receiver gathers, receiver gathers beside a continuous recording, one-component and
## three-component files, files whose kind cannot be told, shot and receiver gathers together,
## and files that cannot be read. Killed traces are in the edits table. `scan` runs one on a
## number of item threads and `digest` writes everything the report holds (every total, every
## station row, the unread and not-checked lists, the notes, both CSVs) as one string, so two
## runs are the same when their digests are.

import std/[options, os, strutils, tables]
import parseSEG
import viewSEG/core/[edits, jobs, noisearea, qualityjobs, qualityreport, recordingkind,
  reportside, settings]
import waiting

type
  Scenario* = object
    name*: string
    paths*: seq[string]
    edits*: Table[string, FileEdits]
    forced*: Table[string, RecordingKind]
    untold*: UntoldKind
    folderRun*: bool

  Tr = tuple[rcvLine, rcvPoint, srcLine, srcPoint: float64; component: uint8;
    status: TraceStatus; samples: seq[float32]]

proc quiet(n = 40): seq[float32] =
  result = newSeq[float32](n)
  for i in 0 ..< n: result[i] = if i mod 2 == 0: 1 else: -1

proc clipped(): seq[float32] =
  result = quiet(32)
  for i in 4 .. 6: result[i] = 1000
  for i in 8 .. 10: result[i] = -1000
  for i in 20 .. 22: result[i] = 1000
  for i in 24 .. 26: result[i] = -1000

proc writeSeis(path: string; record: int; traces: openArray[Tr]; samples = 40;
    recordPerTrace = false) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: samples, time: 1_700_000_000.0))
  for i, t in traces:
    var k = initTraceKeys()
    k.record = float64(if recordPerTrace: i + 1 else: record)
    k.channel = float64(i + 1)
    k.srcLine = t.srcLine
    k.srcPoint = t.srcPoint
    k.srcIndex = 1
    k.rcvLine = t.rcvLine
    k.rcvPoint = t.rcvPoint
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.component = t.component
    k.sensorType = t.component
    k.status = t.status
    w.writeTrace(k, t.samples)
  doAssert w.close().len == 0, "file was not written: " & path

proc fill(samples: seq[float32]; n: int): seq[float32] =
  result = samples
  result.setLen n

proc shotAt(path: string; shot: int; points: openArray[int]; comps = 1; bad = -1) =
  ## One shot received at `points` of line 10, `comps` components each; the trace at index
  ## `bad` is dead (all zero).
  var traces: seq[Tr] = @[]
  for p in points:
    for c in 1 .. comps:
      let dead = traces.len == bad
      traces.add (rcvLine: 10.0, rcvPoint: float64(p), srcLine: 1.0, srcPoint: float64(shot),
        component: uint8(c), status: tsLive,
        samples: if dead: newSeq[float32](40) elif p mod 5 == 0: clipped().fill(40) else: quiet())
  writeSeis(path, shot, traces)

proc receiverAt(path: string; point: int; sources: openArray[int]) =
  ## One receiver (line 20) recording the sources `sources` of line 5.
  var traces: seq[Tr] = @[]
  for s in sources:
    traces.add (rcvLine: 20.0, rcvPoint: float64(point), srcLine: 5.0, srcPoint: float64(s),
      component: 1'u8, status: tsLive, samples: if s mod 4 == 0: clipped().fill(40) else: quiet())
  writeSeis(path, point, traces, recordPerTrace = true)

proc shotsFile*(path: string) =
  ## One shot at six stations.
  shotAt(path, 99, [1, 2, 3, 4, 5, 9])

proc receiverFile*(path: string) =
  ## One receiver recording five sources.
  receiverAt(path, 90, [1, 2, 3, 4, 5])

proc partial(path: string; shot: int; two: openArray[int]) =
  ## One shot at the points 1 .. 4 of line 10, each with component 1 and those in `two` also
  ## with component 2: component 2 counts for the file when at least two of its stations, and
  ## half of them, have it.
  var traces: seq[Tr] = @[]
  for p in 1 .. 4:
    for c in 1 .. (if p in two: 2 else: 1):
      traces.add (rcvLine: 10.0, rcvPoint: float64(p), srcLine: 1.0, srcPoint: float64(shot),
        component: uint8(c), status: tsLive, samples: quiet())
  writeSeis(path, shot, traces)

proc lone(path: string; n: int) =
  ## A file of one receiver and one source: its kind cannot be told.
  writeSeis(path, n, [(rcvLine: float64(50 + n), rcvPoint: 5.0, srcLine: 1.0, srcPoint: 1.0,
    component: 1'u8, status: tsLive, samples: quiet())])

proc killing(paths: openArray[string]; traces: openArray[int]): Table[string, FileEdits] =
  for p in paths:
    var e = FileEdits()
    discard e.change(teKilled, traces, true)
    result[p] = e

proc forcedKinds*(paths: openArray[string]; kind: RecordingKind): Table[string, RecordingKind] =
  ## `kind` set for each of `paths`, as the Files window keys it.
  for p in paths: result[forcedPath(p)] = kind

func cut(data: string): string =
  ## The first three quarters of `data`: a file whose last trace is cut short.
  data[0 ..< data.len * 3 div 4]

proc scenarios*(dir: string): seq[Scenario] =
  ## The scenarios, their files written into `dir`.
  createDir dir
  template at(name: string): string = dir / name
  # shot gathers: overlapping stations, dead and clipped traces, killed traces for two files,
  # a path listed twice, a text file, a file cut short
  var shots: seq[string] = @[]
  for k in 1 .. 8:
    let p = at("shot" & $k & ".sgd")
    shotAt(p, k, [1 + k mod 3, 2 + k mod 3, 3 + k mod 3, 4, 5 + k mod 2, 9], bad = k mod 4)
    shots.add p
  let text = at("notes.sgd")
  writeFile(text, "not a seismic file")
  let cut = at("cut.sgd")
  writeFile(cut, readFile(shots[0]).cut)
  var shotPaths = shots & @[shots[2], text, cut]
  var sc = Scenario(name: "shot gathers", paths: shotPaths,
    edits: killing([shots[1], shots[5]], [0, 3]), forced: forcedKinds(shotPaths, rkShotGather))
  result.add sc
  # receiver gathers
  var recvs: seq[string] = @[]
  for k in 1 .. 6:
    let p = at("recv" & $k & ".sgd")
    receiverAt(p, k, [1, 2 + k, 4, 8, 9 + k])
    recvs.add p
  result.add Scenario(name: "receiver gathers", paths: recvs,
    edits: killing([recvs[2]], [1, 2]), forced: forcedKinds(recvs, rkReceiverSliced))
  # receiver gathers and a continuous recording: both sides are filled
  let cont = at("continuous.sgd")
  shotAt(cont, 77, [1, 2, 3, 4])
  var both = recvs[0 .. 2] & @[cont]
  var bothKinds = forcedKinds(recvs[0 .. 2], rkReceiverSliced)
  bothKinds[forcedPath(cont)] = rkReceiverContinuous
  result.add Scenario(name: "receiver gathers and a continuous recording", paths: both,
    forced: bothKinds)
  # one-component and three-component files: the component rule
  var comps: seq[string] = @[]
  for (name, points, c) in [("c3a", @[1, 2, 3, 4], 3), ("c1a", @[1, 2, 3, 4, 5], 1),
      ("c3b", @[2, 3], 3), ("c3c", @[7], 3), ("c2d", @[1, 2, 3, 6], 2)]:
    let p = at(name & ".sgd")
    shotAt(p, comps.len + 30, points, comps = c)
    comps.add p
  for (name, two) in [("p3", @[1, 2, 3]), ("p1", @[1]), ("p2", @[2, 4])]:
    let p = at(name & ".sgd")
    partial(p, comps.len + 30, two)
    comps.add p
  result.add Scenario(name: "one and three components", paths: comps,
    edits: killing([comps[0]], [1]), forced: forcedKinds(comps, rkShotGather))
  # files that cannot be told, next to files that are told as shots by their stations
  var untold: seq[string] = @[]
  for n in 1 .. 4:
    let p = at("untold" & $n & ".sgd")
    lone(p, n)
    untold.add p
  let told = shots[0 .. 2]
  result.add Scenario(name: "untold, taken like the folder", paths: told & untold,
    folderRun: true)
  result.add Scenario(name: "untold only", paths: untold, folderRun: true)
  result.add Scenario(name: "untold, one file", paths: untold[0 .. 0])
  result.add Scenario(name: "untold, chosen as receivers", paths: told & untold,
    untold: ukReceiver)
  result.add Scenario(name: "untold, chosen as shots", paths: untold, untold: ukShot,
    edits: killing([untold[1]], [0]))
  # shot and receiver gathers together: not reported
  var mixed = shots[0 .. 2] & recvs[0 .. 1] & @[text] & shots[3 .. 4]
  var mixedKinds = forcedKinds(shots[0 .. 2] & shots[3 .. 4], rkShotGather)
  for p in recvs[0 .. 1]: mixedKinds[forcedPath(p)] = rkReceiverSliced
  result.add Scenario(name: "shots and receivers", paths: mixed, forced: mixedKinds)

proc scan*(sc: Scenario; threads: int; cacheDir = ""): tuple[st: JobState;
    result: QualityJobResult] =
  ## Runs `sc` as a job on `threads` item threads.
  let jobs = initJobs()
  jobs.setItemThreads(threads)
  let sink = QualitySink()
  let id = jobs.submit(qualitySpec(sc.paths), scanQuality(sc.paths, sc.edits, sink, cacheDir,
    NoiseSettings(), sc.forced, sc.untold, sc.folderRun))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the scan did not finish"
  (jobs.info(id).get.state, sink.result)

proc digest*(r: QualityJobResult): string =
  ## Everything the result holds, as text.
  result = $r & "\n" & stationsCsv(r.receivers.stations) & totalsCsv(r.receivers.totals) &
    stationsCsv(r.sources.stations) & totalsCsv(r.sources.totals)

proc figures*(r: QualityJobResult): string =
  ## The totals of both sides and the sizes of the lists, in one line.
  for (name, t) in [("receivers", r.receivers.totals), ("sources", r.sources.totals)]:
    result.add name & " " & $t.files & " " & $t.traces & " " & $t.killed & " " & $t.bad & " " &
      $t.stations & " " & $t.badStations & " " & $t.lacking & " " & $t.components & "; "
  result.add "unread " & $r.unread.len & ", not checked " & $r.notChecked.len & ", sides " &
    $r.sides.shots & "/" & $r.sides.receivers & "/" & $r.sides.untold

proc twoRecords*(path: string) =
  ## Two records of 600 traces: more than one chunk of traces, and a record that ends in the
  ## second chunk, so that a read fails after the first record was measured.
  var traces: seq[Tr] = @[]
  for shot in 1 .. 2:
    for i in 1 .. 600:
      traces.add (rcvLine: 10.0, rcvPoint: float64(i), srcLine: 1.0, srcPoint: float64(shot),
        component: 1'u8, status: tsLive, samples: quiet())
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 40, time: 1_700_000_000.0))
  for i, t in traces:
    var k = initTraceKeys()
    k.record = float64(1 + i div 600)
    k.channel = float64(1 + i mod 600)
    k.srcLine = t.srcLine
    k.srcPoint = t.srcPoint
    k.srcIndex = 1
    k.rcvLine = t.rcvLine
    k.rcvPoint = t.rcvPoint
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.component = t.component
    k.sensorType = t.component
    k.status = t.status
    w.writeTrace(k, t.samples)
  doAssert w.close().len == 0, "file was not written: " & path
