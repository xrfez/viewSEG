## The trace-quality scan on the item pool: the report is the same, field for field and in
## both CSVs, whether the files are measured on one thread or on several; a cancel leaves the
## sink empty; a file that cannot be read, or that fails after some of its records were
## measured, is listed unread once and counts nothing, as in a serial scan; the item types
## hold plain data.
##
## The scenarios (`utils/qualityfolders`) are shot gathers (killed traces, a path twice, a text
## file, a file cut short), receiver gathers, receiver gathers beside a continuous recording,
## one-component and three-component files (the component rule), files whose kind cannot be told
## (taken like the folder, only these, chosen), and shot and receiver gathers together. Their
## figures were taken from the serial scan before it ran on the pool.
##
## Seen to fail: with the item for file `i` measuring file `i xor 1`, `the_figures_are_the_
## serial_scans` saw 27 traces where the folder's untold files give 22. With the build of a file
## that failed part-way kept (and its failure not listed), `a_file_that_fails_part_way_*` saw no
## unread file. With a cancel raised neither by `take`, nor after the batch, nor before the
## report, `a_cancel_while_files_are_in_hand_*` found the job done.

import std/[atomics, locks, os, sequtils, strutils, tables, times]
import viewSEG/core/[itempool, jobs, noisearea, qualityjobs, qualityreport, recordingkind, reportside]
import utils/[faultyfs, fixtures, qualityfolders, waiting]

const Expected = [
  "receivers 9 52 4 48 7 7 0 1; sources 0 0 0 0 0 0 0 0; unread 2, not checked 0, sides 9/0/0",
  "receivers 0 0 0 0 0 0 0 0; sources 6 30 2 28 13 12 0 1; unread 0, not checked 0, sides 0/6/0",
  "receivers 1 4 0 4 4 4 0 1; sources 3 15 0 15 8 8 0 1; unread 0, not checked 0, sides 0/3/0",
  "receivers 8 52 1 51 7 7 3 3; sources 0 0 0 0 0 0 0 0; unread 0, not checked 0, sides 8/0/0",
  "receivers 7 22 0 22 11 11 0 1; sources 0 0 0 0 0 0 0 0; unread 0, not checked 0, sides 7/0/0",
  "receivers 0 0 0 0 0 0 0 0; sources 0 0 0 0 0 0 0 0; unread 0, not checked 4, sides 0/0/4",
  "receivers 0 0 0 0 0 0 0 0; sources 0 0 0 0 0 0 0 0; unread 0, not checked 1, sides 0/0/1",
  "receivers 0 0 0 0 0 0 0 0; sources 0 0 0 0 0 0 0 0; unread 0, not checked 0, sides 3/4/0",
  "receivers 4 4 1 3 4 3 0 0; sources 0 0 0 0 0 0 0 0; unread 0, not checked 0, sides 4/0/0",
  "receivers 0 0 0 0 0 0 0 0; sources 0 0 0 0 0 0 0 0; unread 1, not checked 0, sides 5/2/0"]

var mappedCalls, failAt: Atomic[int]
var failing: string

var readLock: Lock
var readCounts: Table[string, int]
initLock readLock

proc readHook(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  ## Notes each file whose samples are read.
  {.cast(gcsafe).}:
    if op == foMapped:
      withLock readLock:
        readCounts.mgetOrPut(path, 0) += 1

proc countingHook(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  ## Counts the mapped reads of `failing`; the `failAt`th is an I/O error.
  {.cast(gcsafe).}:
    if op == foMapped and path == failing and mappedCalls.fetchAdd(1) + 1 == failAt.load:
      raise newException(OSError, "Input/output error (planted)")

proc main*() =
  block plain:
    static:
      doAssert plainData(QualityBuild)

  withFixtures fx:
    let all = scenarios(fx.dir / "folder")
    doAssert all.len == Expected.len

    block the_figures_are_the_serial_scans:
      for i, sc in all:
        let got = sc.scan(1)
        doAssert got.st == jsDone, sc.name & ": " & $got.st
        doAssert got.result.figures == Expected[i], sc.name & ":\n" & got.result.figures
      let untold = all[4].scan(1).result
      doAssert untold.taken.contains("taken as shot gathers, like the others"), untold.taken
      let chosen = all[7].scan(1).result
      doAssert chosen.taken.contains("as chosen") and chosen.mixed.len > 0, chosen.taken
      let shots = all[0].scan(1).result
      doAssert shots.unread.len == 2 and shots.unread[0].why.contains("not a SEG") and
        shots.unread[1].why.contains("cut short"), $shots.unread
      doAssert shots.paths.len == 9, "a path given twice is read once: " & $shots.paths.len

    block the_report_is_the_same_on_any_number_of_threads:
      for sc in all:
        let serial = sc.scan(1)
        let want = serial.result.digest
        for threads in [2, 4, 8]:
          let got = sc.scan(threads)
          doAssert got.st == jsDone, sc.name & " on " & $threads & " threads: " & $got.st
          doAssert got.result.digest == want,
            sc.name & " differs on " & $threads & " threads:\n" & got.result.digest & "\n" & want

    block a_budget_no_file_fits_runs_one_file_at_a_time:
      let saved = itemBudget
      itemBudget = 1
      defer: itemBudget = saved
      for sc in all:
        let got = sc.scan(4)
        doAssert got.st == jsDone
        doAssert got.result.digest == sc.scan(1).result.digest, sc.name

    block a_cancel_leaves_the_sink_empty:
      for sc in [all[0], all[4]]:
        let jobs = initJobs()
        jobs.setItemThreads(4)
        let sink = QualitySink()
        # the cancel is asked from outside before any file is taken
        let id = jobs.submit(qualitySpec(sc.paths), scanQuality(sc.paths, sc.edits, sink, "",
          NoiseSettings(), sc.forced, sc.untold, sc.folderRun))
        discard jobs.cancel(id)
        doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
          "the cancelled job did not finish"
        doAssert jobs.info(id).get.state in {jsCancelled, jsDone}
        if jobs.info(id).get.state == jsCancelled:
          doAssert not sink.result.ok and sink.result.unread.len == 0 and
            sink.result.receivers.totals.traces == 0

    block a_cancel_while_files_are_in_hand_leaves_the_sink_empty:
      install()
      defer: setFsHook(nil)
      let sc = all[0]
      fault(fx.dir / "folder", fkDelay, delay = initDuration(milliseconds = 25))
      let jobs = initJobs()
      jobs.setItemThreads(4)
      let sink = QualitySink()
      let id = jobs.submit(qualitySpec(sc.paths), scanQuality(sc.paths, sc.edits, sink, "",
        NoiseSettings(), sc.forced, sc.untold, sc.folderRun))
      sleep 120
      discard jobs.cancel(id)
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the cancelled job did not finish"
      fault(fx.dir / "folder", fkNone)
      doAssert jobs.info(id).get.state == jsCancelled, $jobs.info(id).get.state
      doAssert not sink.result.ok and sink.result.unread.len == 0 and
        sink.result.receivers.totals.traces == 0

    block a_file_that_cannot_be_opened_is_unread_and_the_others_are_measured:
      install()
      defer: setFsHook(nil)
      let sc = all[0]
      let victim = sc.paths[3]
      fault(victim, fkFail)
      defer: fault(victim, fkNone)
      let serial = sc.scan(1)
      let pooled = sc.scan(4)
      for got in [serial, pooled]:
        doAssert got.st == jsDone
        var named = 0
        for u in got.result.unread:
          if u.path == victim: inc named
        doAssert named == 1, $got.result.unread
        doAssert got.result.receivers.totals.files == 8, $got.result.receivers.totals
      doAssert pooled.result.digest == serial.result.digest

    block a_file_that_fails_part_way_counts_nothing_and_is_unread_once:
      let whole = fx.dir / "whole.sgd"
      let broken = fx.dir / "broken.sgd"
      shotsFile(whole)
      twoRecords(broken)
      failing = broken
      setFsHook(countingHook)
      defer: setFsHook(nil)
      let sc = Scenario(name: "broken", paths: @[whole, broken],
        forced: forcedKinds([whole, broken], rkShotGather))
      # a run that fails nowhere counts the file's mapped reads; the last is in the second
      # record, after the first was measured
      mappedCalls.store(0)
      failAt.store(0)
      let clean = sc.scan(1).result
      doAssert clean.unread.len == 0 and clean.receivers.totals.traces == 6 + 1200, $clean.unread
      let last = mappedCalls.load
      for threads in [1, 4]:
        mappedCalls.store(0)
        failAt.store(last)
        let got = sc.scan(threads).result
        var named = 0
        for u in got.unread:
          if u.path == broken: inc named
        doAssert named == 1 and got.unread.len == 1, $got.unread
        doAssert got.receivers.totals.traces == 6 and got.receivers.totals.files == 1,
          "the unread file is counted: " & $got.receivers.totals

    block a_mix_stops_the_measuring_of_the_files_after_it:
      let dir = fx.dir / "mix"
      createDir dir
      var paths: seq[string] = @[]
      for k in 1 .. 30:
        let p = dir / ("m" & $k & ".sgd")
        if k == 3: receiverFile(p) else: shotsFile(p)
        paths.add p
      var kinds = forcedKinds(paths, rkShotGather)
      kinds[forcedPath(paths[2])] = rkReceiverSliced
      let sc = Scenario(name: "mix", paths: paths, forced: kinds)
      let cache = fx.dir / "mixcache"
      let serial = sc.scan(1, cache)
      doAssert serial.result.mixed.len > 0 and serial.result.receivers.totals.traces == 0
      setFsHook(readHook)
      defer: setFsHook(nil)
      # the cache holds the keys of every file: what is read now is the measuring
      # a folder with no mix: every file is opened and measured, the reads of one file `full`
      readCounts.clear()
      let plain = Scenario(name: "no mix", paths: paths[3 .. ^1], forced: kinds).scan(4, cache)
      doAssert plain.result.receivers.totals.files == 27
      var full = 0
      withLock readLock:
        for _, n in readCounts: full = max(full, n)
      readCounts.clear()
      let got = sc.scan(4, cache)
      doAssert got.result.digest == serial.result.digest
      var measured = 0
      withLock readLock:
        for _, n in readCounts:
          if n >= full: inc measured
      # the files taken before the mix, and as many as the pool holds beyond them
      doAssert measured <= 2 + 2 * 4, $measured & " of 30 files measured"

  echo "tqualitypool: ok"

when isMainModule:
  main()
