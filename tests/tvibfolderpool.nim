## The folder QC on the item pool: the table is the same, row for row and in the CSV, whether
## the files are judged on one thread or on several; a cancel lists the files not judged as
## skipped, as a serial run does; a file the drive fails on is that row's problem and the
## others are judged; the item types hold plain data.
##
## Seen to fail: with the item for file `i` judging file `i xor 1`, `sameOnAnyThreads` names the
## first row that differs. With the outcome of a failed item not turned into a problem row (the
## failure dropped), `oneFileFails` finds no problem row. With the files a cancel from outside
## left untaken not listed as skipped, `cancelWhileRunning` finds the job done, not cancelled.

import std/[os, strutils, times]
import viewSEG/core/[analysis, itempool, jobs, project, signatures, sigjudge, sweepinfo,
  vibfolderjobs, vibfolderqc, vibjudge, vibprofile,
  settings, sigtypes, threads, units]
import viewSEG/view/vibfolderwords
import utils/[faultyfs, fixtures, sigfiles, waiting]
import parseSSDAT, parseSSVIB

const
  Samples = 6000
  Files = 14

proc listed(path: string): FolderListed =
  var head: seq[byte] = @[]
  let size = readHead(path, head)
  let kind = if size >= 0: signatureKindOf(head) else: sgNone
  FolderListed(path: path, info: readSweepInfo(path, kind, size))

proc askOf(): VibQcAsk =
  var profile = profileOf(QcLimits(), 500.0, 5, asB, ForceScale(), NaN, NaN, "", NaN)
  applied(profile, [])

proc runOn(threads: int; files: seq[FolderListed]; ask: VibQcAsk): tuple[
    st: JobState; table: FolderTable] =
  let jobs = initJobs()
  jobs.setItemThreads(threads)
  let sink = FolderQcSink()
  let id = jobs.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the folder job did not finish"
  (jobs.info(id).get.state, sink.result)

var lane: Jobs

proc stopAtThird(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if back or not phase.startsWith("file 3 of"): return
  discard lane.cancel(id)

proc main*() =
  withFixtures fx:
    let dir = fx.dir / "folder"
    var files: seq[FolderListed] = @[]
    for k in 0 ..< Files:
      let second = k mod 60
      if k mod 4 == 3:
        files.add listed(vibFile(dir, "s" & $k & ".vib", SynthVib(start: VibTime(year: 2001,
          month: 2, day: 3, hour: 4, minute: 0, second: second), afterTrigger: 3000)))
      else:
        files.add listed(datFile(dir, "s" & $k & ".dat", SynthDat(samples: Samples,
          fileNumber: 7000 + k, trigger: DatTime(year: 2001, month: 2, day: 3, hour: 4,
          minute: 0, second: second, nanosecond: 0))))
    let notOne = dir / "z-notes.dat"
    writeFile(notOne, "not a signature file")
    files.add listed(notOne)
    let ask = askOf()

    block plain:
      static:
        doAssert plainData(FolderRow) and plainData(FolderListed) and plainData(VibQcAsk)
        doAssert plainData(SignatureChoice) and plainData(SweepInfo)

    block sameOnAnyThreads:
      let serial = runOn(1, files, ask)
      doAssert serial.st == jsDone
      doAssert serial.table.rows.len == files.len
      doAssert serial.table.totals.passed + serial.table.totals.failed > 0
      for threads in [2, 4, 8]:
        let got = runOn(threads, files, ask)
        doAssert got.st == jsDone
        doAssert got.table.rows.len == serial.table.rows.len
        for i, row in got.table.rows:
          doAssert $row == $serial.table.rows[i],
            "row " & $i & " differs on " & $threads & " threads:\n" & $row & "\n" &
            $serial.table.rows[i]
          doAssert row.path == files[i].path, "row " & $i & " is not file " & $i
        doAssert $got.table == $serial.table, "the table differs on " & $threads & " threads"
        doAssert resultsCsv(got.table) == resultsCsv(serial.table),
          "the CSV differs on " & $threads & " threads"

    block budgetInForce:
      ## a budget no file fits: one file at a time, every file still judged, the same table
      let serial = runOn(1, files, ask)
      let saved = itemBudget
      itemBudget = 1
      let got = runOn(4, files, ask)
      itemBudget = saved
      doAssert got.st == jsDone
      doAssert got.table.rows.len == files.len
      doAssert $got.table == $serial.table, "the table differs under a budget"

    block cancelStops:
      lane = initJobs()
      lane.setItemThreads(4)
      setJobHook(stopAtThird)
      let sink = FolderQcSink()
      let id = lane.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
      doAssert waitUntil(lane.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the cancelled job did not finish"
      setJobHook(nil)
      doAssert lane.info(id).get.state == jsCancelled
      let table = sink.result
      doAssert table.cancelled
      doAssert table.rows.len == files.len, $table.rows.len
      for i, row in table.rows:
        doAssert row.path == files[i].path
        doAssert (row.outcome == foSkipped) == (i >= 2),
          "row " & $i & " is " & $row.outcome
      doAssert table.totals.skipped == files.len - 2

    block cancelWhileRunning:
      ## a cancel from outside while several files are in hand: the rows judged come first,
      ## every other file is skipped, and none is lost
      install()
      fault(dir, fkDelay, {foOpen}, initDuration(milliseconds = 60))
      let jobs = initJobs()
      jobs.setItemThreads(4)
      let sink = FolderQcSink()
      let id = jobs.submit(folderQcSpec(files), folderQcWork(ask, VibJobWeights(), files, sink))
      sleep 150
      discard jobs.cancel(id)
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the cancelled job did not finish"
      fault(dir, fkNone)
      setFsHook(nil)
      doAssert jobs.info(id).get.state == jsCancelled
      let table = sink.result
      doAssert table.cancelled
      doAssert table.rows.len == files.len, $table.rows.len
      var skipped = false
      for i, row in table.rows:
        doAssert row.path == files[i].path
        if row.outcome == foSkipped: skipped = true
        else: doAssert not skipped, "row " & $i & " judged after a skipped one"
      doAssert skipped, "nothing was cancelled"

    block oneFileFails:
      install()
      let victim = files[5].path
      fault(victim, fkFail)
      let serial = runOn(1, files, ask)
      let pooled = runOn(4, files, ask)
      fault(victim, fkNone)
      setFsHook(nil)
      for got in [serial, pooled]:
        doAssert got.st == jsDone
        doAssert got.table.rows.len == files.len
        for i, row in got.table.rows:
          if i == 5:
            doAssert row.outcome == foProblem and "cannot be read" in row.problem, row.problem
          elif i < files.high:
            doAssert row.outcome == foJudged, $i & ": " & row.problem
      doAssert $pooled.table == $serial.table

  echo "tvibfolderpool: ok"

when isMainModule:
  main()
