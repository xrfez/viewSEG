## One survey file of each kind is loaded at a time: R (receiver points), S (source points),
## X (shot to receivers) and O (receiver to shots). A file loaded takes the place of every
## loaded file that holds a kind it holds, whole (also what else that holds), and the log says
## which went; the same file loaded again replaces itself silently. Files loaded in one
## action load all when their kinds differ; of two of one kind the later in the list stays
## (whichever is read first). A project document naming several files of one kind opens
## with the last. What a load replaced is put back as it was (`putBack`).
##
## Seen to fail: with `Survey.add` taking the place of the same file only (the old rule),
## `twoX` found two layers; with `clashes` comparing the kinds of a layer whole (not the
## overlap), `halfRemoved` found the S points of the file left beside the new R file; with a
## load that was asked earlier replacing one asked later, `oneAction` kept the first file
## listed in some runs (the reversed list found the other); with `putBack` placing only one
## layer, `putBack` found the second one lost.

import std/[os, strutils, times]
import parseSEG
import viewSEG/core/[filekinds, jobs, survey, state]
import utils/[fixtures, waiting]

proc header(): SpsHeader =
  SpsHeader(code: "00", description: "SPS format version num.", data: "SPS 2.1;")

proc point(kind: SpsPointKind; pt: float64): SpsPoint =
  SpsPoint(kind: kind, line: 10, point: pt, index: 1, code: "G1", easting: 100 + pt,
    northing: 200, elevation: 5, dayOfYear: -1, hour: -1, minute: -1, second: -1)

proc relation(kind: char; record: int; src: float64): SpsRelation =
  SpsRelation(recordType: kind, fieldRecord: record, recordIncrement: 1, instrumentCode: '1',
    srcLine: 1, srcPoint: src, srcIndex: 1, fromChannel: 1, toChannel: 3, channelIncrement: 1,
    rcvLine: 10, fromReceiver: 1, toReceiver: 3, rcvIndex: 1)

proc write(path: string; points: seq[SpsPoint] = @[]; relations: seq[SpsRelation] = @[]) =
  let f = SpsFile(headers: @[header()], points: points, relations: relations)
  doAssert writeSps(f, path).len == 0

proc said(st: AppState; part: string): bool =
  for e in st.log:
    if part in e.text: return true

proc load(st: var AppState; paths: varargs[string]) =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)

template keepSettled(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc surveyFiles(st: AppState): seq[string] =
  for l in st.survey.layers:
    if l.origin == loSurveyFile: result.add l.name

proc idle(st: var AppState): bool = st.settle(st.jobs.active.len == 0)

var gate: Gate

proc layerOf(path: string; kinds: set[PointRole]): SurveyLayer =
  var b = initSurveyFileBuilder(path, fkSps, 1, fromUnix(0))
  for r in kinds: b.addPoint(r, 10, 1, 1, 100, 200, 5)
  b.finish()

proc main*() =
  let dir = getTempDir() / ("viewseg-oneeach-" & $getCurrentProcessId())
  createDir(dir)
  let (ax, bx, rf, sf, of1, both) = (dir / "a.x", dir / "b.x", dir / "c.r", dir / "d.s",
    dir / "e.o", dir / "both.sps")
  write(ax, relations = @[relation('X', 1, 5)])
  write(bx, relations = @[relation('X', 2, 6), relation('X', 3, 7)])
  write(rf, points = @[point(pkReceiver, 1), point(pkReceiver, 2)])
  write(sf, points = @[point(pkSource, 5), point(pkSource, 6)])
  write(of1, relations = @[relation('O', 1, 1)])
  write(both, points = @[point(pkReceiver, 1), point(pkSource, 5)])

  block twoX:
    var st = initAppState()
    st.load ax
    doAssert st.idle
    st.load bx
    doAssert st.settle(st.said("Loaded b.x") and st.jobs.active.len == 0)
    doAssert st.surveyFiles == @["b.x"], $st.surveyFiles
    doAssert st.said("It replaces a.x: one X file is loaded at a time."), $st.log.len
    doAssert st.relationLayer >= 0 and st.survey.layers[st.relationLayer].name == "b.x"
    # the same file again: replaced, said as before, nothing more
    st.load ax
    doAssert st.settle(st.said("Loaded a.x") and st.jobs.active.len == 0)
    st.load ax
    doAssert st.idle
    st.shutdown()

  block fourKinds:
    var st = initAppState()
    for p in [rf, sf, ax, of1]:
      st.load p
      doAssert st.idle
    doAssert st.surveyFiles.len == 4, $st.surveyFiles
    for l in st.survey.layers:
      if l.origin == loSurveyFile: doAssert not st.said("It replaces"), l.name
    st.shutdown()

  block sameFile:
    var st = initAppState()
    st.load rf
    doAssert st.idle
    sleep 20
    write(rf, points = @[point(pkReceiver, 1), point(pkReceiver, 2), point(pkReceiver, 3)])
    st.load rf
    doAssert st.settle(st.said("Loaded c.r (SPS R) again") and st.jobs.active.len == 0)
    doAssert st.surveyFiles == @["c.r"] and not st.said("It replaces")
    write(rf, points = @[point(pkReceiver, 1), point(pkReceiver, 2)])
    st.shutdown()

  block halfRemoved:
    # a file with R and S points, then an R file: the first goes whole, and the log says so
    var st = initAppState()
    st.load both
    doAssert st.idle
    st.load sf
    doAssert st.idle
    doAssert st.surveyFiles == @["d.s"], $st.surveyFiles # S alone replaced it as well
    doAssert st.said("It replaces both.sps: one S file"), "no S"
    doAssert st.said("both.sps held R and S: its R points went with it, and no R file is " &
      "loaded now."), "no word of the lost R points"
    st.load both
    doAssert st.idle
    doAssert st.surveyFiles == @["both.sps"], $st.surveyFiles
    st.load rf
    doAssert st.idle
    doAssert st.surveyFiles == @["c.r"], $st.surveyFiles
    doAssert st.said("It replaces both.sps: one R file"), "no R"
    doAssert st.said("its S points went with it, and no S file is loaded now."), "no S word"
    st.shutdown()

  block oneAction:
    # two X files and an R file in one action: the R file and the later X file stay
    for (first, second) in [(ax, bx), (bx, ax)]:
      var st = initAppState()
      st.load(first, rf, second)
      doAssert st.settle(st.surveyFiles.len == 2 and st.jobs.active.len == 0), $st.surveyFiles
      doAssert second.extractFilename in st.surveyFiles and first.extractFilename notin
        st.surveyFiles, $st.surveyFiles
      doAssert st.said(first.extractFilename & " is not kept") or
        st.said("It replaces " & first.extractFilename), "nothing said of " & first
      st.shutdown()

  block putBack:
    # what a layer replaced is put back as it was, in its place
    var s: Survey
    var a = layerOf("a", {prReceiver, prSource})
    let ida = s.add(a)
    a.id = ida
    let idc = s.add(layerOf("c", {}))
    var replaced: seq[SurveyLayer] = @[]
    var b = layerOf("b", {prReceiver})
    b.order = 2
    let idb = s.add(b, replaced)
    doAssert replaced.len == 1 and replaced[0].path == "a", $replaced.len
    doAssert s.find(ida) < 0 and s.find(idb) == 0 and s.find(idc) == 1
    let late = layerOf("a", {prSource})
    doAssert s.supersededBy(late) < 0 # asked at the same time (0): none is later
    var early = layerOf("z", {prReceiver})
    early.order = 1
    doAssert s.supersededBy(early) == s.find(idb)
    doAssert s.putBack(idb, move replaced).len == 0
    doAssert s.find(ida) == 0 and s.find(idb) < 0 and s.layers.len == 2

  block oldProject:
    # an import naming two X files the file list does not know: the later is loaded and kept
    # in the project, the earlier is left out of both and Messages says so
    let config = dir / "config"
    let job = dir & "-project" / "Old project"
    createDir(config)
    var st = initAppState()
    st.rememberFilesIn(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[dir])
    doAssert st.keepSettled(st.inProject and st.projectOpening.len == 0)
    st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
      JoinFile(path: ax, kind: jkSps), JoinFile(path: rf, kind: jkSps),
      JoinFile(path: bx, kind: jkSps)])
    doAssert st.keepSettled(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport), "not imported: " & st.project.surveyNote
    doAssert st.surveyFiles.len == 2, $st.surveyFiles
    doAssert st.said("a.x is not kept in the project"), "the left-out file is not said"
    st.flushFiles()
    doAssert "a.x" notin readFile(job / "project.nif"), "the project names the left-out file"
    st.shutdown()
    var again = initAppState()
    again.rememberFilesIn(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.keepSettled(again.inProject and again.project.survey == srLoaded and
      again.surveyFiles.len == 2), $again.surveyFiles
    doAssert again.project.doc.survey.len == 2, "the project names " &
      $again.project.doc.survey.len & " files"
    doAssert "b.x" in again.surveyFiles and "a.x" notin again.surveyFiles, $again.surveyFiles
    again.shutdown()

  block laterAskWins:
    # an import's layer arrives, then a file asked after the import began: the later ask
    # stays, and cancelling the import leaves it (l.x, which the import replaced, is not put
    # back over it, and Messages says so)
    withFixtures fx:
      let sv = fx.surveySps()
      let seg = fx.stationsSegd()
      let big = fx.dir / "e.x"
      var g = SpsFile(headers: @[header()])
      for k in 0 ..< 300_000: g.relations.add relation('X', k + 1, float64(k))
      doAssert writeSps(g, big).len == 0
      let small = fx.dir / "l.x"
      write(small, relations = @[relation('X', 1, 5)])
      for withSmall in [false, true]:
        var st = initAppState()
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: seg)
        doAssert st.settle(st.sessions.len == 1 and
          st.survey.findTraces(st.sessions[0].id) >= 0)
        if withSmall:
          st.load small
          doAssert st.settle(st.jobs.active.len == 0 and "l.x" in st.surveyFiles)
        gate.close()
        discard st.jobs.submit(JobSpec(title: "Hold it", lane: jlBackground, reads: @[seg]),
          proc (ctx: JobContext) {.gcsafe.} = gate.waitAt(ctx))
        st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
          JoinFile(path: sv.s, kind: jkSps), JoinFile(path: sv.r, kind: jkSps),
          JoinFile(path: sv.x, kind: jkSps)])
        doAssert st.settle("survey.x" in st.surveyFiles)
        st.load big
        doAssert st.settle("e.x" in st.surveyFiles and st.surveyFiles.len == 3 or
          st.said("e.x is not kept")), $st.surveyFiles
        doAssert "e.x" in st.surveyFiles and "survey.x" notin st.surveyFiles, "e.x was " &
          "asked later: " & $st.surveyFiles
        doAssert not st.said("e.x is not kept")
        st.apply Command(kind: ckCancelJob, job: st.joinUnderWay.job)
        doAssert st.settle(st.joinUnderWay.job == NoJob)
        gate.open()
        discard st.settle(st.jobs.active.len == 0)
        var xs = 0
        for n in st.surveyFiles:
          if n.endsWith(".x"): inc xs
        doAssert xs == 1 and "e.x" in st.surveyFiles, "after the cancel: " & $st.surveyFiles
        if withSmall:
          doAssert st.said("l.x is not put back: e.x, loaded since, holds its X records"),
            "l.x was put back beside e.x"
        st.shutdown()

  block askedAfterTheImportArrivesBefore:
    # the import is asked, then a file of its kind straight after: the import's layers are
    # posted when it has read its files, after the ask of the file but asked before it: the
    # file asked last stays, and is not said to be asked before
    withFixtures fx:
      let sv = fx.surveySps()
      let seg = fx.stationsSegd()
      let small = fx.dir / "l.x"
      write(small, relations = @[relation('X', 1, 5)])
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: seg)
      doAssert st.settle(st.sessions.len == 1 and st.survey.findTraces(st.sessions[0].id) >= 0)
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: sv.s, kind: jkSps), JoinFile(path: sv.r, kind: jkSps),
        JoinFile(path: sv.x, kind: jkSps)])
      st.load small
      doAssert st.settle(st.jobs.active.len == 0 and st.joinUnderWay.job == NoJob)
      doAssert "l.x" in st.surveyFiles and "survey.x" notin st.surveyFiles,
        "the file asked last was not kept: " & $st.surveyFiles
      doAssert not st.said("l.x is not kept")
      st.shutdown()

  block earlierAskKeptOut:
    # a file asked before the import began and read after its layer came is kept out, and
    # put back when the import is cancelled
    withFixtures fx:
      let sv = fx.surveySps()
      let seg = fx.stationsSegd()
      let big = fx.dir / "e.x"
      var g = SpsFile(headers: @[header()])
      for k in 0 ..< 300_000: g.relations.add relation('X', k + 1, float64(k))
      doAssert writeSps(g, big).len == 0
      var st = initAppState()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: seg)
      doAssert st.settle(st.sessions.len == 1 and st.survey.findTraces(st.sessions[0].id) >= 0)
      gate.close()
      discard st.jobs.submit(JobSpec(title: "Hold it", lane: jlBackground, reads: @[seg]),
        proc (ctx: JobContext) {.gcsafe.} = gate.waitAt(ctx))
      st.load big
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: sv.s, kind: jkSps), JoinFile(path: sv.r, kind: jkSps),
        JoinFile(path: sv.x, kind: jkSps)])
      doAssert st.settle("survey.x" in st.surveyFiles and not st.surveyLoading(big))
      doAssert st.said("e.x is not kept: survey.x, asked after it") or
        st.said("It replaces e.x"), "nothing said of e.x"
      st.apply Command(kind: ckCancelJob, job: st.joinUnderWay.job)
      doAssert st.settle(st.joinUnderWay.job == NoJob)
      gate.open()
      discard st.settle(st.jobs.active.len == 0)
      doAssert "e.x" in st.surveyFiles and "survey.x" notin st.surveyFiles, $st.surveyFiles
      st.shutdown()

  block importLeavesOutEarlier:
    # an import naming two X files uses the later, and keeps only that one in the project
    let config = dir / "config2"
    createDir(config)
    let job = dir & "-project" / "Import two"
    var st = initAppState()
    st.rememberFilesIn(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[dir])
    doAssert st.keepSettled(st.inProject and st.projectOpening.len == 0)
    st.apply Command(kind: ckBrowse, paths: @[dir])
    doAssert st.keepSettled(not st.fileList.scanning and st.fileList.entries.len > 0)
    st.apply Command(kind: ckJoin, joinFile: NoSession, joinFiles: @[
      JoinFile(path: ax, kind: jkSps), JoinFile(path: bx, kind: jkSps)])
    doAssert st.keepSettled(st.project.survey == srLoaded and st.project.doc.hasStore and
      not st.project.doc.hasImport), "not imported: " & st.project.surveyNote
    doAssert st.surveyFiles == @["b.x"], $st.surveyFiles
    doAssert st.project.doc.survey.len == 1, "the project keeps " &
      $st.project.doc.survey.len & " files"
    doAssert st.said("a.x is left out of the import"), "left-out file not said"
    st.shutdown()

  removeDir(dir)
  removeDir(dir & "-project")
  echo "toneeach: ok"

when isMainModule:
  main()
