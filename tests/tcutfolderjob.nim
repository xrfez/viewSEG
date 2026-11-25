## Slicing every recording of a folder: the job lists the folder, says for each file
## whether it can be sliced and what it spans, gives each file every shot whose record
## starts inside it, and writes one file for each recording that takes a shot, with the
## routine that slices one file. Cases: files of different times, nodes of one time (every
## file takes every shot), a start half a sample before the first sample and a record
## past the end (zero-padded), day files, names that clash (also by case), a destination
## inside the source folder, the kind the user set, the facts kept for an unchanged file, a
## file whose read fails. The sources are never changed.
##
## Each was seen to fail with a deliberate fault: a shot given to the first file only
## ("Sliced 1 file." for two nodes); the user's kind ignored (the forced file refused); a
## read of the recording reported as a write failure; the span of a file ignored when the
## shots are given out ("shots of one.sgy 4"); the shots no file takes not counted
## (`r.unplaced == 1`); the name clash not looked for.

import std/[algorithm, assertions, atomics, os, sequtils, strutils, tables, times]
import parseSEG
import viewSEG/core/[cutfolderjobs, cutgather, filesystem, jobs, recordingkind, shotlog]
import viewSEG/view/cutfolderwords
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  SegLen = 3000
  DtUs = 2000'i64

func ramp(comp, k: int): float32 =
  float32(100_000 * comp + k)

proc makeRecording(path: string; offsetS: int; point = 7; every = 1) =
  ## Two components, two adjacent source traces each of 3000 samples at 2 ms, from
  ## `offsetS` seconds after BaseUs.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for seg in 0 .. 1:
    for comp in 0 .. 1:
      var samples = newSeq[float32](SegLen)
      for j in 0 ..< SegLen: samples[j] = ramp(comp, seg * SegLen + j)
      var k = initTraceKeys()
      k.status = tsLive
      k.record = float64(seg + 1)
      k.channel = float64(comp + 11)
      k.intervalUs = 2000
      k.t0Ms = 0
      k.time = float64(BaseUs div 1_000_000 + offsetS) + float64(seg * every * SegLen) * 0.002
      k.rcvLine = 1
      k.rcvPoint = float64(point)
      w.writeTrace(k, samples)
  discard w.close()

proc logOf(files: openArray[int]; offsetsUs: openArray[int64]): ShotView =
  var text = ""
  for i in 0 ..< files.len:
    text.add $files[i] & "," & $(BaseUs + offsetsUs[i]) & "\n"
  var m = initShotLogMap()
  m.hasHeader = false
  m.roles = @[crFileNumber, crTime]
  m.dateTimePattern = EpochMicros
  shots(parseShotLog(text, m), m)

proc run(jobs: Jobs; plan: FolderPlan): tuple[st: JobState; res: FolderResult; error: string] =
  let sink = FolderSink()
  let id = jobs.submit(cutFolderSpec(plan.folder, plan.write), cutFolderWork(plan, sink))
  doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
    "the job did not finish"
  let info = jobs.info(id).get
  (info.state, sink.result, info.error)

proc fileOf(r: FolderResult; name: string): FolderFile =
  for f in r.files:
    if f.path.extractFilename == name: return f
  doAssert false, "no entry for " & name

var
  failName, failOut: string
  armed: Atomic[bool]

proc failingHook(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  ## The read of `failName` fails once its slice's part file exists in `failOut`.
  {.cast(gcsafe).}:
    if armed.load and op == foMapped and path.extractFilename == failName:
      for k, q in walkDir(failOut):
        if q.extractFilename.startsWith("b_slice.sgd.part-"):
          raise newException(OSError, "Input/output error")

proc samplesOf(f: SeismicFile; trace: int): seq[float32] =
  let x = f.readTraces(trace .. trace)
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc main*() =
  let dir = getTempDir() / ("viewseg-cutfolder-" & $getCurrentProcessId())
  removeDir(dir)
  let src = dir / "in"
  let outDir = dir / "out"
  createDir(src)
  createDir(outDir)
  defer: removeDir(dir)
  makeRecording(src / "one.sgy", 0)
  makeRecording(src / "two.segy", 100)
  makeRecording(src / "two.sgy", 300)
  writeFile(src / "notes.txt", "not a recording\n")
  # Shots (seconds after BaseUs): in one.sgy, in two.segy, in two.sgy, in no file (50 s)
  let secs = [2, 103, 302, 50]
  let view = logOf([1, 2, 3, 4], secs.mapIt(int64(it) * 1_000_000))
  var before: seq[string] = @[]
  for p in ["one.sgy", "two.segy", "two.sgy", "notes.txt"]: before.add readFile(src / p)
  let jobs = initJobs()
  var plan = FolderPlan(folder: src, destFolder: outDir, rows: view.rows,
    opts: initCutOptions(1000.0), cacheDir: dir / "cache")

  block a_check_says_what_would_be_written_and_writes_nothing:
    let got = run(jobs, plan)
    doAssert got.st == jsDone, got.error
    let r = got.res
    doAssert r.listed and r.finished and r.files.len == 4, $r.files.len
    doAssert fileOf(r, "one.sgy").sliceable and fileOf(r, "one.sgy").shots == 1,
      "shots of one.sgy " & $fileOf(r, "one.sgy").shots
    doAssert fileOf(r, "two.segy").sliceable and fileOf(r, "two.segy").shots == 1
    doAssert fileOf(r, "notes.txt").skip == NotRecording, "the text file was not skipped"
    let clash = fileOf(r, "two.sgy")
    doAssert not clash.sliceable and "two_slice.sgd" in clash.skip and
      "two.segy" in clash.skip, clash.skip
    doAssert r.unplaced == 1 # the clashing file still holds its shot
    doAssert r.countSliceable == 2
    doAssert walkFiles(outDir / "*").toSeq.len == 0, "the check wrote a file"
    doAssert checkWords(r).startsWith("2 recordings of 4 files can be sliced"), checkWords(r)

  block shots_with_no_file_are_counted_once:
    let got = run(jobs, plan)
    doAssert got.res.unplaced == 1, "unplaced " & $got.res.unplaced
    doAssert got.res.unplacedNamed == @["file 4"], $got.res.unplacedNamed
    doAssert "1 shot is in no file" in unplacedWords(got.res)

  plan.write = true
  block a_run_writes_one_file_for_each_recording_that_holds_a_shot:
    let got = run(jobs, plan)
    doAssert got.st == jsDone, got.error
    let r = got.res
    doAssert r.finished and r.countWritten == 2 and r.countFailed == 0, outcomeWords(r)
    doAssert fileExists(outDir / "one_slice.sgd") and fileExists(outDir / "two_slice.sgd")
    doAssert not fileExists(outDir / "notes_slice.sgd")
    doAssert walkFiles(outDir / "*").toSeq.len == 2, "other files were written"
    for (name, offsetS, shotS) in [("one_slice.sgd", 0, 2), ("two_slice.sgd", 100, 103)]:
      var f = openSeismic(outDir / name, keys = true)
      defer: f.close()
      doAssert f.len == 2, name & " has " & $f.len & " traces"
      let first = int((int64(shotS - offsetS) * 1_000_000) div DtUs)
      for comp in 0 .. 1:
        let s = samplesOf(f, comp)
        doAssert s.len == 500 and s[0] == ramp(comp, first) and s[499] == ramp(comp, first + 499),
          name & " comp " & $comp & ": " & $s[0]
    var after: seq[string] = @[]
    for p in ["one.sgy", "two.segy", "two.sgy", "notes.txt"]: after.add readFile(src / p)
    doAssert after == before, "a source changed"
    # two files, the file whose name is taken (with its shot) and the unplaced shot
    doAssert outcomeLines(r).len == 4, $outcomeLines(r)
    doAssert fileOf(r, "two.sgy").shots == 1 and "(1 shot not sliced)" in skipLines(r)[1],
      $skipLines(r)

  block a_second_run_replaces_nothing:
    let written = readFile(outDir / "one_slice.sgd")
    let got = run(jobs, plan)
    doAssert got.st == jsDone, got.error
    doAssert got.res.countWritten == 0 and got.res.countSliceable == 0
    doAssert "already in the destination folder" in fileOf(got.res, "one.sgy").skip,
      fileOf(got.res, "one.sgy").skip
    doAssert readFile(outDir / "one_slice.sgd") == written, "an output was replaced"

  block every_node_file_takes_every_shot_it_holds:
    # two nodes recorded the same 12 s: each file is sliced at both shots
    let a = dir / "nodes"
    createDir(a / "in")
    createDir(a / "out")
    makeRecording(a / "in" / "node007.sgy", 0, 7)
    makeRecording(a / "in" / "node008.sgy", 0, 8)
    let v = logOf([1, 2], [2_000_000'i64, 5_000_000])
    let got = run(jobs, FolderPlan(folder: a / "in", destFolder: a / "out", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache", write: true))
    doAssert got.st == jsDone, got.error
    doAssert got.res.countWritten == 2 and got.res.unplaced == 0, outcomeWords(got.res)
    for name in ["node007_slice.sgd", "node008_slice.sgd"]:
      var f = openSeismic(a / "out" / name, keys = true)
      defer: f.close()
      doAssert f.len == 4, name & " has " & $f.len & " traces (two records of two)"
      doAssert samplesOf(f, 0)[0] == ramp(0, 1000) and samplesOf(f, 2)[0] == ramp(0, 2500), name

  block a_start_is_placed_as_the_single_slice_places_it:
    # one file from 0 to 12 s, 2 ms samples, the nearest sample: a start 0.45 of a sample
    # before the first sample is the first sample; 0.55 of a sample before is not in the file
    let b = dir / "edge"
    createDir(b / "in")
    createDir(b / "out")
    makeRecording(b / "in" / "e.sgy", 0)
    let v = logOf([1, 2, 3], [-900'i64, -1100, 11_500_000])
    let plan = FolderPlan(folder: b / "in", destFolder: b / "out", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache", write: true)
    let got = run(jobs, plan)
    doAssert got.st == jsDone, got.error
    doAssert fileOf(got.res, "e.sgy").shots == 2, $fileOf(got.res, "e.sgy").shots
    doAssert got.res.unplaced == 1 and got.res.unplacedNamed == @["file 2"], $got.res.unplacedNamed
    var f = openSeismic(b / "out" / "e_slice.sgd", keys = true)
    defer: f.close()
    doAssert f.len == 4
    doAssert samplesOf(f, 0)[0] == ramp(0, 0), "the start before the first sample is not sample 0"
    # the window that runs past the end is written, zero-padded
    let late = samplesOf(f, 2)
    doAssert late.len == 500 and late[0] == ramp(0, 5750) and late[249] == ramp(0, 5999) and
      late[250] == 0 and late[499] == 0, $late[245 .. 255]
    doAssert got.res.files[0].line.len > 0

  block the_day_files_of_one_node_take_each_shot_once:
    let c = dir / "days"
    createDir(c / "in")
    createDir(c / "out")
    makeRecording(c / "in" / "day1.sgy", 0)
    makeRecording(c / "in" / "day2.sgy", 12)
    # inside the first, at its end (the window runs on), at the start of the second, inside it
    let v = logOf([1, 2, 3, 4], [5_000_000'i64, 11_500_000, 12_000_000, 20_000_000])
    let got = run(jobs, FolderPlan(folder: c / "in", destFolder: c / "out", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache"))
    doAssert fileOf(got.res, "day1.sgy").shots == 2 and fileOf(got.res, "day2.sgy").shots == 2,
      $(fileOf(got.res, "day1.sgy").shots, fileOf(got.res, "day2.sgy").shots)
    doAssert got.res.unplaced == 0

  block a_name_that_differs_by_case_is_a_clash:
    let d = dir / "case"
    createDir(d / "in")
    createDir(d / "out")
    makeRecording(d / "in" / "A.sgy", 0)
    makeRecording(d / "in" / "a.segy", 0, 8)
    let v = logOf([1], [2_000_000'i64])
    let got = run(jobs, FolderPlan(folder: d / "in", destFolder: d / "out", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache"))
    doAssert got.res.countSliceable == 1, $skipLines(got.res)
    doAssert skipLines(got.res).anyIt("its slice would be named" in it), $skipLines(got.res)

  block a_destination_inside_the_source_folder_is_refused_once:
    let e = dir / "inside"
    createDir(e / "in")
    makeRecording(e / "in" / "a.sgy", 0)
    makeRecording(e / "in" / "b.sgy", 0, 8)
    let v = logOf([1], [2_000_000'i64])
    let got = run(jobs, FolderPlan(folder: e / "in", destFolder: e / "in" / "sub", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache", write: true))
    doAssert got.res.refused == InsideSource, got.res.refused
    doAssert got.res.countWritten == 0 and not dirExists(e / "in" / "sub")
    doAssert not skipLines(got.res).anyIt("open file" in it), $skipLines(got.res)

  block the_kind_the_user_set_is_used:
    let g = dir / "treat"
    createDir(g / "in")
    createDir(g / "out")
    makeRecording(g / "in" / "gaps.sgy", 0, 7, 2) # no trace follows directly on another
    makeRecording(g / "in" / "whole.sgy", 0, 8)
    let v = logOf([1], [2_000_000'i64])
    var p = FolderPlan(folder: g / "in", destFolder: g / "out", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache", write: true)
    var check = p
    check.write = false
    let plain = run(jobs, check)
    doAssert not fileOf(plain.res, "gaps.sgy").sliceable and
      fileOf(plain.res, "whole.sgy").sliceable, fileOf(plain.res, "gaps.sgy").skip
    p.treats[absolutePath(g / "in" / "gaps.sgy").normalizedPath] = rkReceiverContinuous
    p.treats[absolutePath(g / "in" / "whole.sgy").normalizedPath] = rkShotGather
    let forced = run(jobs, p)
    doAssert fileOf(forced.res, "gaps.sgy").sliceable, fileOf(forced.res, "gaps.sgy").skip
    doAssert "You set this kind" in fileOf(forced.res, "whole.sgy").skip,
      fileOf(forced.res, "whole.sgy").skip
    doAssert fileExists(g / "out" / "gaps_slice.sgd"), "the file of the kind set was not sliced"
    doAssert not fileExists(g / "out" / "whole_slice.sgd")

  block the_facts_of_a_file_that_has_not_changed_are_kept:
    let h = dir / "known"
    createDir(h / "in")
    makeRecording(h / "in" / "k.sgy", 0)
    makeRecording(h / "in" / "m.sgy", 0, 8)
    let v = logOf([1], [2_000_000'i64])
    var p = FolderPlan(folder: h / "in", destFolder: dir / "knownout", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache")
    let first = run(jobs, p)
    p.known = first.res.facts
    p.known[0].skip = "kept from before"
    p.known[1].skip = "kept from before"
    setLastModificationTime(h / "in" / "m.sgy", getLastModificationTime(h / "in" / "m.sgy") +
      initDuration(seconds = 5))
    let second = run(jobs, p)
    doAssert fileOf(second.res, "k.sgy").skip == "kept from before", "the facts were not reused"
    doAssert fileOf(second.res, "m.sgy").sliceable, "a changed file was not read again"

  block a_file_that_fails_does_not_stop_the_others:
    let w = dir / "fail"
    createDir(w / "in")
    createDir(w / "out")
    makeRecording(w / "in" / "a.sgy", 0)
    makeRecording(w / "in" / "b.sgy", 0, 8)
    makeRecording(w / "in" / "c.sgy", 0, 9)
    let v = logOf([1], [2_000_000'i64])
    failName = "b.sgy"
    failOut = w / "out"
    setFsHook(failingHook)
    armed.store true
    let got = run(jobs, FolderPlan(folder: w / "in", destFolder: w / "out", rows: v.rows,
      opts: initCutOptions(1000.0), cacheDir: dir / "cache", write: true))
    armed.store false
    setFsHook(nil)
    doAssert got.st == jsDone, got.error
    doAssert outcomeWords(got.res) == "Sliced 2 files; 1 file failed.", outcomeWords(got.res)
    doAssert "Reading the recording failed" in fileOf(got.res, "b.sgy").reason,
      fileOf(got.res, "b.sgy").reason
    var left: seq[string] = @[]
    for q in walkFiles(w / "out" / "*"): left.add q.extractFilename
    left.sort()
    doAssert left == @["a_slice.sgd", "c_slice.sgd"], $left

  block a_folder_that_cannot_be_listed_fails:
    var bad = plan
    bad.folder = dir / "nothing"
    let got = run(jobs, bad)
    doAssert got.st == jsFailed and "could not be listed" in got.error, got.error

  echo "tcutfolderjob ok"

when isMainModule:
  main()
