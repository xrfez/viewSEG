## The recorded fold and the fold difference (`core/foldactual`, `core/foldjobs`) on the
## synthetic land survey's six shots, written here one file each, without a window.
##
## - Every recorded trace is counted once: the sum over the bins is the traces read less those
##   left out, and on a complete survey the recorded fold equals the pre-plot in every bin
##   (the difference is 0), with the survey joined to keys that carry no coordinates and with
##   coordinates in the headers; the counts equal the library's `addFold` on the same files.
## - With one shot file out of the folder the difference is exactly that shot's contribution;
##   a killed trace lowers exactly its bin; a trace that is not live is counted as left out.
## - The count is the same on 1, 2, 4 and 8 item threads.
## - A file that gives no positions and that the survey does not place is reported, not
##   dropped; when all of them are, the layer says so and holds no counts; a file that cannot
##   be read is skipped with its reason.
## - The key names the files, their sizes, the edits and the moves: a file added, a kill or
##   a move gives another key; the follower keeps the recorded fold and the difference of one
##   count (switching between them starts no job) and keeps at most three results.
## - A cancel leaves the sink empty.
## - A folder being recorded: a count after a file was added, a file changed in place (within
##   the same second) or a kill reads only that file, and its counts equal a count from nothing;
##   the map counted last stays, updating, meanwhile (also while the folder is listed again); a
##   count of the same grid that the files change under is not cancelled, its map is shown when
##   it ends, and the next one reads only what changed since; past the bytes allowed the parts
##   go and are read again; another survey drops the map at once and every file is read.
## - The survey on the map places files that carry station numbers and no coordinates, also
##   outside a project; in a project whose stored survey is the map's nothing is said, and
##   with another survey loaded on the map the totals say the map's placed the traces.
##
## Seen to fail: with the kill test in the item turned off "a killed trace" found 0 killed
## and 576 binned; with the not-live test turned off the dead trace was counted in a bin;
## with the kills left out of the key "a kill gives another key" failed; with the item for
## file `i` reading file `i xor 1` the single-file counts raised an index error; with the
## project's survey alone joined (none outside a project), "the map's survey places the files"
## found none of the 6 placed; with `otherSurvey` always false, "a survey loaded on the map is
## another" failed. With no part lent, "a file added: only it is read" found all 6 read; with
## the map dropped at every new count, "the last map stays" failed; with the time of the file
## in whole seconds, "a file changed: only it is read" found none read; with a count cancelled
## when the files change, "a count of the same grid is not cancelled" failed.

import std/[algorithm, atomics, locks, math, os, sequtils, strutils, tables]
import parseSEG
import processSEG/adapters
import processSEG/qc/fold
import processSEG/stack/binning
import viewSEG/core/[colourmaps, edits, filesystem, foldactual, foldgrid, foldjobs, jobs, join,
  state, stationmoves]
import utils/[fixtures, waiting]

const Land = "samples/land/land"

type Spot = tuple[x, y: float64]

proc readStations(): tuple[sources, receivers: Table[(int, int), Spot]] =
  ## The coordinates the sample's S and R files give, by line and point.
  for line in lines(Land & ".s"):
    let t = line.splitWhitespace
    if t.len > 8 and t[0] == "S":
      result.sources[(int(parseFloat(t[1])), int(parseFloat(t[2])))] =
        (parseFloat(t[6]), parseFloat(t[7]))
  for line in lines(Land & ".r"):
    let t = line.splitWhitespace
    if t.len > 6 and t[0] == "R":
      result.receivers[(int(parseFloat(t[1])), int(parseFloat(t[2])))] =
        (parseFloat(t[4]), parseFloat(t[5]))

proc shotFile(path: string; shot: int; coordinates: bool; dead = -1; stationless = false) =
  ## Shot `shot` (1 to 6) of the sample: 96 traces, one per receiver, with the station numbers
  ## and, with `coordinates`, the positions in the headers. Trace `dead` (0-based) is marked
  ## dead; `stationless` leaves the stations and coordinates out and gives the record a number
  ## the X records do not list, so the survey cannot place it either.
  let table = readStations()
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 2))
  var ch = 0
  for line in [1001, 1002]:
    for point in 101 .. 148:
      inc ch
      var k = initTraceKeys()
      k.record = float64(if stationless: 9000 + shot else: shot)
      k.channel = float64(ch)
      if not stationless:
        (k.srcLine, k.srcPoint, k.srcIndex) = (2001.0, float64(100 + shot), 1'i16)
        (k.rcvLine, k.rcvPoint, k.rcvIndex) = (float64(line), float64(point), 1'i16)
        if coordinates:
          let (s, r) = (table.sources[(2001, 100 + shot)], table.receivers[(line, point)])
          (k.srcX, k.srcY, k.rcvX, k.rcvY) = (s.x, s.y, r.x, r.y)
      (k.intervalUs, k.status) = (2000.0, if ch - 1 == dead: tsDead else: tsLive)
      w.writeTrace(k, @[0'f32, 0, 0, 0])
  doAssert w.close().len == 0, "shot file was not written: " & path

proc loaded(st: var AppState; paths: varargs[string]): bool =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)
  st.settle(st.jobs.active.len == 0 and st.survey.layers.len >= paths.len)

proc folder(st: var AppState; dir: string): bool =
  st.apply Command(kind: ckBrowse, paths: @[dir])
  st.settle(not st.fileList.scanning and st.fileList.folder == dir)

proc survey(): SurveyGeometry =
  result = initSurveyGeometry()
  for ext in [".s", ".r", ".x"]: result.addSps(Land & ext)

proc sizeOf(path: string): int64 = (if fileExists(path): getFileSize(path) else: 0)

proc inputsOf(paths: seq[string]; kills: Table[string, seq[int]] =
    initTable[string, seq[int]]()): ref ActualInputs =
  result = new ActualInputs
  for p in paths:
    result.files.add ActualFile(path: p, size: sizeOf(p), kills: kills.getOrDefault(p))
    result.key.add p & "|" & $sizeOf(p) & "|" & $kills.getOrDefault(p) & ";"

proc count(st: var AppState; actual: ref ActualInputs; kind = fkActual;
    threads = 0): FoldSink =
  ## Runs the job that counts the files and waits for it.
  if threads > 0: st.jobs.setItemThreads(threads)
  let inp = foldInputs(st.survey, NaN, NaN, kind, actual)
  result = FoldSink()
  discard st.jobs.submit(foldSpec(kind), foldWork(inp, result))
  doAssert waitUntil(st.jobs.active.len == 0)

proc preplotCounts(): seq[int32] =
  var g = survey()
  var m = g.preplotFold(surveyGrid(g))
  m.fold.toFlatSeq

proc libraryCounts(paths: seq[string]): seq[int32] =
  ## What the library's `addFold` makes of the files' own header positions.
  var g = survey()
  var actual = initFoldMap(surveyGrid(g))
  for p in paths:
    var f = openSeismic(p, keys = true)
    var traces: seq[int] = @[]
    for t in 0 ..< f.len: traces.add t
    actual.addFold(chunkMeta(f, traces, dtMs = 2.0))
    f.close()
  actual.fold.toFlatSeq

var
  readsLock: Lock
  reads: seq[string]      ## the files the counts opened, by name
  slowReads: Atomic[bool] ## a read waits while it is set

proc noteRead(path: string) {.nimcall, gcsafe, raises: [IOError].} =
  {.cast(gcsafe).}:
    withLock readsLock: reads.add path.extractFilename
    while slowReads.load: sleep 10

proc readNow(): seq[string] =
  withLock readsLock: result = reads.sorted

proc forgetReads() =
  withLock readsLock: reads.setLen 0

proc main*() =
  initLock readsLock
  withFixtures fx:
    let dir = fx.dir / "shots"
    let dirXy = fx.dir / "shotsxy"
    createDir dir
    createDir dirXy
    var files, filesXy: seq[string] = @[]
    for s in 1 .. 6:
      files.add dir / ("shot" & $s & ".sgy")
      filesXy.add dirXy / ("shot" & $s & ".sgy")
      shotFile(files[^1], s, coordinates = false)
      shotFile(filesXy[^1], s, coordinates = true)
    let planned = preplotCounts()
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")

    block complete:
      for (name, paths) in [("joined by the survey", files), ("header coordinates", filesXy)]:
        let sink = st.count(inputsOf(paths))
        doAssert sink.result.ok, name & ": " & sink.result.reason
        doAssert sink.result.kind == fkActual and sink.other.kind == fkDifference and
          sink.other.ok
        doAssert sink.result.counts == planned, name & ": the recorded fold is not the plan"
        doAssert sink.result.planned == planned
        doAssert sink.other.counts.allIt(it == 0), name & ": the difference is not 0 everywhere"
        doAssert sink.other.maxFold == 0
        let r = sink.result
        doAssert r.files == 6 and r.traces == 576 and r.notLive == 0 and r.killed == 0 and
          r.noCoordinates == 0 and r.outside == 0 and r.unplaced == 0
        doAssert r.binned == 576 and sum(r.counts.mapIt(int(it))) == r.binned,
          "every recorded trace is counted once"
        doAssert r.maxFold > 0 and r.levels.len > 1 and sink.other.levels.len > 1
        # a difference of 0 is the neutral colour (a bin with a plan), a bin with none is clear
        let lut = lutOf(cmRedWhiteBlue)
        let planned0 = planned.find(0)
        let planned1 = planned.find(planned.max)
        doAssert planned0 < 0 or sink.other.levels[0].colours[planned0] == 0,
          "a bin with no plan and no trace is clear"
        doAssert sink.other.levels[0].colours[planned1] ==
          diffColour(lut, 0, 1), "a bin as planned is the neutral colour"
      doAssert libraryCounts(filesXy) == planned, "the library's addFold agrees"

    block oneShotMissing:
      for out0 in 0 ..< files.len:
        let rest = files[0 ..< out0] & files[out0 + 1 .. ^1]
        let sink = st.count(inputsOf(rest))
        let only = st.count(inputsOf(@[files[out0]]))
        doAssert sink.result.ok and only.result.ok
        doAssert sink.other.kind == fkDifference
        let d = sink.result.kind
        doAssert d == fkActual
        doAssert sink.other.counts == only.result.counts,
          "the difference is the contribution of shot " & $(out0 + 1)
        doAssert sink.other.maxFold == only.result.maxFold
        doAssert sink.result.traces == 480 and sink.other.files == 5

    block differenceAsked:
      let sink = st.count(inputsOf(files[1 .. ^1]), fkDifference)
      doAssert sink.result.kind == fkDifference and sink.other.kind == fkActual and
        sink.result.ok and sink.other.ok
      var dsum = 0
      for v in sink.result.counts: dsum += int(v)
      doAssert dsum == 96
      let lut = lutOf(cmRedWhiteBlue)
      doAssert sink.result.levels[0].colours.anyIt(it != 0 and it != diffColour(lut, 0, 1)),
        "a short bin is not neutral"

    block killedAndDead:
      let all = st.count(inputsOf(files))
      var kills = initTable[string, seq[int]]()
      kills[files[2]] = @[10]
      let k = st.count(inputsOf(files, kills))
      doAssert k.result.killed == 1 and k.result.traces == 576 and k.result.binned == 575
      var changed: seq[int] = @[]
      for b in 0 ..< all.result.counts.len:
        if all.result.counts[b] != k.result.counts[b]:
          changed.add b
          doAssert all.result.counts[b] - k.result.counts[b] == 1, "a kill lowers its bin by one"
      doAssert changed.len == 1, "a killed trace lowers exactly its bin"
      doAssert k.other.counts[changed[0]] == 1, "the difference shows it as short by one"
      # a dead trace is not live: left out, not counted in a bin
      let deadFile = fx.dir / "dead.sgy"
      shotFile(deadFile, 1, coordinates = false, dead = 7)
      let d = st.count(inputsOf(@[deadFile]))
      doAssert d.result.notLive == 1 and d.result.binned == 95

    block threads:
      var fingerprints: seq[(seq[int32], seq[int32], int, int)] = @[]
      for n in [1, 2, 4, 8]:
        let sink = st.count(inputsOf(files & @["gone.sgy"]), fkActual, n)
        doAssert sink.result.ok, sink.result.reason
        fingerprints.add (sink.result.counts, sink.other.counts, sink.result.files,
          sink.result.skipped.len)
        doAssert sink.result.skipped.len == 1 and sink.result.skipped[0].path == "gone.sgy",
          "the file that cannot be read is skipped: " & $sink.result.skipped
      for f in fingerprints:
        doAssert f == fingerprints[0], "the count differs with the number of threads"
      st.jobs.setItemThreads(0)

    block noPositions:
      let bare = fx.dir / "bare.sgy"
      shotFile(bare, 1, coordinates = false, stationless = true)
      # no coordinates and no stations: the survey cannot place it, left out, and said
      let mixed = st.count(inputsOf(files & @[bare]))
      doAssert mixed.result.ok and mixed.result.unplaced == 1 and
        mixed.result.noCoordinates == 96, "a file with no positions is reported, not dropped: " &
        $(mixed.result.unplaced, mixed.result.noCoordinates)
      doAssert mixed.result.counts == planned and mixed.result.files == 7
      doAssert "1 file give no source or receiver positions" in
        mixed.result.totalsText("ft"), mixed.result.totalsText("ft")
      let none = st.count(inputsOf(@[bare]))
      doAssert not none.result.ok and "None of the 1 file gives source or receiver positions" in
        none.result.reason, none.result.reason
      let nothing = st.count(inputsOf(@["gone.sgy"]))
      doAssert not nothing.result.ok and "could be read" in nothing.result.reason

    block cancel:
      let inp = foldInputs(st.survey, NaN, NaN, fkActual, inputsOf(files))
      let sink = FoldSink()
      let id = st.jobs.submit(foldSpec(fkActual), foldWork(inp, sink))
      discard st.jobs.cancel(id)
      doAssert waitUntil(st.jobs.active.len == 0)
      doAssert sink.result.counts.len == 0 and not sink.result.ok and not sink.other.ok,
        "a cancel leaves nothing"

    block mapSurveyPlaces:
      # station numbers and no coordinates, no project: the survey on the map places them
      doAssert st.folder(dir) and not st.inProject
      let sink = st.count(actualInputs(st))
      doAssert sink.result.ok, "the map's survey places the files: " & sink.result.reason
      doAssert sink.result.counts == planned and sink.result.unplaced == 0

    block projectSurvey:
      # in a project whose survey is the map's, nothing is said; another survey loaded on the
      # map places the traces and the totals say so
      var p = initAppState()
      p.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
        JoinFile(path: Land & ".s", kind: jkSps), JoinFile(path: Land & ".r", kind: jkSps),
        JoinFile(path: Land & ".x", kind: jkSps)])
      doAssert p.settle(not p.importing and p.survey.layers.len > 0)
      p.apply Command(kind: ckNewProject, projectPath: fx.dir / "Job", useSurvey: true)
      doAssert p.settle(p.inProject and p.project.survey == srLoaded and
        p.jobs.active.len == 0), "the project did not keep the survey"
      doAssert p.folder(dir)
      let own = actualInputs(p)
      doAssert not own.otherSurvey, "the project's own survey is not another"
      let sink = p.count(own)
      doAssert sink.result.ok and sink.result.counts == planned and
        "not the project's" notin sink.result.totalsText("ft")
      let other = fx.dir / "other"
      createDir other
      for ext in [".s", ".r", ".x"]: copyFile(Land & ext, other / ("land" & ext))
      doAssert p.loaded(other / "land.s", other / "land.r", other / "land.x")
      let moved = actualInputs(p)
      doAssert moved.otherSurvey, "a survey loaded on the map is another than the project's"
      let said = p.count(moved)
      doAssert said.result.ok and said.result.counts == planned
      doAssert "The survey on the map, not the project's stored one, placed the traces." in
        said.result.totalsText("ft"), said.result.totalsText("ft")
      discard p.shutdown()

    block keys:
      doAssert st.folder(dir)
      let first = actualInputs(st)
      doAssert first.files.len == 6 and first.key.len > 0
      let stamp = actualStamp(st)
      doAssert actualStamp(st) == stamp and actualInputs(st).key == first.key
      # a kill is another key
      var e = st.editsAt(files[0])
      doAssert e.shown.lists[teKilled].len == 0
      shotFile(dir / "shot7.sgy", 1, coordinates = false)
      doAssert st.folder(dir)
      let added = actualInputs(st)
      doAssert added.files.len == 7 and added.key != first.key, "a file added is another key"
      doAssert actualStamp(st) != stamp
      let sink = st.count(inputsOf(added.files.mapIt(it.path)))
      doAssert sink.result.ok and sink.result.counts != planned and sink.result.files == 7,
        "a file added changes the result"
      removeFile dir / "shot7.sgy"
      doAssert st.folder(dir)
      doAssert actualInputs(st).key == first.key,
        "the folder as it was is the key it was"
      # a file changed in place is another key
      shotFile(files[0], 1, coordinates = false, dead = 3)
      doAssert st.folder(dir)
      doAssert actualInputs(st).key != first.key or getFileSize(files[0]) == first.files[0].size
      doAssert actualReason(st) == ""

    block killedKey:
      var open = initAppState()
      open.apply Command(kind: ckShowFile, panel: MainPanel, path: filesXy[0], listFolder: true)
      doAssert open.settle(open.sessions.len == 1 and open.panel(MainPanel).laidOut and
        not open.fileList.scanning)
      let before = actualInputs(open)
      let stamp = actualStamp(open)
      doAssert before.files.len == 6 and before.files[0].kills.len == 0
      open.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, on: true,
        edited: @[open.sessions[0].base + 10])
      doAssert open.settle(open.editsAt(filesXy[0]).shown.lists[teKilled] == @[10])
      let after = actualInputs(open)
      doAssert after.key != before.key and actualStamp(open) != stamp and
        after.files[0].kills == @[10], "a kill gives another key"
      open.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert open.settle(open.editsAt(filesXy[0]).shown.lists[teKilled].len == 0)
      doAssert actualInputs(open).key != after.key
      discard open.shutdown()

    block noFiles:
      createDir fx.dir / "empty"
      var other = initAppState()
      doAssert other.folder(fx.dir / "empty")
      doAssert actualReason(other) == NoSeismicFiles

    block follower:
      doAssert st.folder(dirXy)
      var t: FoldTracker
      proc want(kind: FoldKind): FoldWant =
        FoldWant(kind: kind, on: true, actual: actualInputs(st), stamp: actualStamp(st))
      proc settleOn(kind: FoldKind): bool =
        t.follow(st.jobs, st.survey, want(kind), NaN, NaN)
        waitUntil((t.follow(st.jobs, st.survey, want(kind), NaN, NaN);
          t.status != fmComputing))
      doAssert settleOn(fkActual) and t.status == fmReady, t.reason
      doAssert t.shown.kind == fkActual
      let actual = t.shown
      t.follow(st.jobs, st.survey, want(fkDifference), NaN, NaN)
      doAssert t.running == NoJob and t.status == fmReady and t.shown.kind == fkDifference,
        "the difference came with the count: no job"
      t.follow(st.jobs, st.survey, want(fkActual), NaN, NaN)
      doAssert t.shown == actual
      # the pre-plot of the same survey is a third result; four layers keep three
      t.follow(st.jobs, st.survey, FoldWant(kind: fkPreplot, on: true), NaN, NaN)
      doAssert waitUntil((t.follow(st.jobs, st.survey,
        FoldWant(kind: fkPreplot, on: true), NaN, NaN); t.status != fmComputing))
      t.follow(st.jobs, st.survey, want(fkActual), NaN, NaN)
      doAssert t.shown == actual, "the recorded fold is still kept beside the pre-plot"
      # a file added is a new count
      shotFile(dirXy / "shot8.sgy", 2, coordinates = true)
      doAssert st.folder(dirXy)
      t.follow(st.jobs, st.survey, want(fkActual), NaN, NaN)
      doAssert t.status == fmComputing, "a file added is counted again"
      doAssert settleOn(fkActual) and t.shown != actual
      # nothing listed: dim with the reason
      var empty = initAppState()
      doAssert empty.loaded(Land & ".s", Land & ".r", Land & ".x")
      var t2: FoldTracker
      t2.follow(empty.jobs, empty.survey, FoldWant(kind: fkActual, on: true,
        why: NoSeismicFiles), NaN, NaN)
      doAssert t2.status == fmImpossible and t2.reason == NoSeismicFiles

    block recounts:
      # a folder being recorded: each count reads only the files that are new or changed (or
      # whose kills changed), and the last map stays until the new one is ready
      let rec = fx.dir / "recording"
      createDir rec
      for s in 1 .. 5: shotFile(rec / ("shot" & $s & ".sgy"), s, coordinates = false)
      var r = initAppState()
      doAssert r.loaded(Land & ".s", Land & ".r", Land & ".x")
      doAssert r.folder(rec)
      var t: FoldTracker
      proc want(): FoldWant =
        FoldWant(kind: fkActual, on: true, actual: actualInputs(r), stamp: actualStamp(r),
          scope: rec)
      proc settled(): bool =
        waitUntil((t.follow(r.jobs, r.survey, want(), NaN, NaN); t.status != fmComputing))
      proc whole(): FoldSink =
        ## The same files counted from nothing.
        r.count(inputsOf(actualInputs(r).files.mapIt(it.path)))
      setIoHook(noteRead)
      forgetReads()
      doAssert settled() and t.status == fmReady, t.reason
      doAssert readNow().len == 5 and t.partsKept == 5
      let five = t.shown
      # a file added: the map stays, marked updating, and only that file is read
      shotFile(rec / "shot6.sgy", 6, coordinates = false)
      t.follow(r.jobs, r.survey, FoldWant(kind: fkActual, on: true, why: Listing, waiting: true,
        stamp: -7, scope: rec), NaN, NaN)
      doAssert t.status == fmComputing and t.shown == five and t.updating and t.showing,
        "the map stays while the folder is listed again"
      doAssert r.folder(rec)
      forgetReads()
      t.follow(r.jobs, r.survey, want(), NaN, NaN)
      doAssert t.updating and t.shown == five, "the last map stays while the new one is counted"
      doAssert settled() and t.status == fmReady and t.shown != five
      doAssert readNow() == @["shot6.sgy"], "a file added: only it is read: " & $readNow()
      forgetReads()
      let all = whole()
      doAssert t.shown.counts == all.result.counts and t.shown.counts == planned and
        t.shown.binned == all.result.binned and t.shown.files == 6, "the same as a whole count"
      # a file changed in place (within the same second): only it is read again
      shotFile(rec / "shot3.sgy", 3, coordinates = false, dead = 5)
      doAssert r.folder(rec)
      forgetReads()
      doAssert settled() and t.status == fmReady
      doAssert readNow() == @["shot3.sgy"], "a file changed: only it is read: " & $readNow()
      forgetReads()
      let changed = whole()
      doAssert t.shown.counts == changed.result.counts and t.shown.notLive == 1 and
        changed.result.notLive == 1
      # a kill: only that file is read again
      r.apply Command(kind: ckShowFile, panel: MainPanel, path: rec / "shot1.sgy",
        listFolder: true)
      doAssert r.settle(r.sessions.len == 1 and r.panel(MainPanel).laidOut and
        not r.fileList.scanning)
      doAssert settled()
      r.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, on: true,
        edited: @[r.sessions[0].base + 10])
      doAssert r.settle(r.editsAt(rec / "shot1.sgy").shown.lists[teKilled] == @[10])
      forgetReads()
      doAssert settled() and t.status == fmReady and t.shown.killed == 1
      doAssert readNow() == @["shot1.sgy"], "a kill: only its file is read: " & $readNow()
      # files that change under a running count of the same grid: it is not cancelled, its
      # map is shown when it ends, and the next count reads only what changed since
      slowReads.store true
      shotFile(rec / "shot7.sgy", 1, coordinates = false)
      doAssert r.folder(rec)
      forgetReads()
      t.follow(r.jobs, r.survey, want(), NaN, NaN)
      let job = t.running
      doAssert job != NoJob and t.updating
      shotFile(rec / "shot8.sgy", 2, coordinates = false)
      doAssert r.folder(rec)
      t.follow(r.jobs, r.survey, want(), NaN, NaN)
      doAssert t.running == job, "a count of the same grid is not cancelled when files change"
      slowReads.store false
      doAssert waitUntil((t.follow(r.jobs, r.survey, want(), NaN, NaN); t.running != job))
      doAssert readNow() == @["shot7.sgy"], "the first count read the file added: " & $readNow()
      doAssert t.shown.files == 7 and t.status == fmComputing and t.updating,
        "the map of the count that ended is shown while the next runs"
      doAssert settled() and t.status == fmReady and t.shown.files == 8
      doAssert readNow() == @["shot7.sgy", "shot8.sgy"], "the next count read only " &
        "the file added since: " & $readNow()
      removeFile rec / "shot7.sgy"
      removeFile rec / "shot8.sgy"
      # past the bytes the parts may take they go (the newest map stays), and are read again
      foldCacheBytes = 1
      shotFile(rec / "shot7.sgy", 1, coordinates = false)
      doAssert r.folder(rec)
      doAssert settled() and t.status == fmReady and t.shown.files == 7
      doAssert t.partsKept == 0, "the parts are kept past the bound: " & $t.partsKept
      foldCacheBytes = 256 shl 20
      removeFile rec / "shot7.sgy"
      doAssert r.folder(rec)
      forgetReads()
      doAssert settled() and t.status == fmReady and t.shown.files == 6
      doAssert readNow().len == 6 and t.partsKept == 6, "the parts dropped are read again"
      # another survey: nothing is kept, the map goes at once and every file is read
      let other = fx.dir / "other2"
      createDir other
      for ext in [".s", ".r", ".x"]: copyFile(Land & ext, other / ("land" & ext))
      forgetReads()
      doAssert r.loaded(other / "land.s", other / "land.r", other / "land.x")
      t.follow(r.jobs, r.survey, want(), NaN, NaN)
      doAssert t.shown.isNil and not t.updating, "another survey's map is not kept"
      doAssert settled() and t.status == fmReady
      doAssert readNow().len == 6, "another survey: every file is read: " & $readNow()
      setIoHook(nil)
      discard r.shutdown()

  echo "tfoldactual: ok"

when isMainModule:
  main()
