## Slicing every recording of a folder: the job lists the folder, says for each file
## whether it can be sliced and what it spans, gives each shot to the file that holds
## its record, and writes one file for each recording that holds a shot, with the
## routine that slices one file. Four recordings of 12 s (two components) and a text
## file; the shots are in the first, in the second, in the third (whose output has the
## second's name) and in none. The sources are never changed.
##
## Each was seen to fail with a deliberate fault: the span of a file ignored when
## the shots are given out ("shots of one.sgy 4"); the shots no file holds not counted
## (`r.unplaced == 1`); the name clash not looked for (the third recording's skip
## sentence did not name the second's slice).

import std/[assertions, os, sequtils, strutils]
import parseSEG
import viewSEG/core/[cutfolderjobs, cutgather, jobs, shotlog]
import viewSEG/view/cutfolderwords
import utils/waiting

const
  BaseUs = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC
  SegLen = 3000
  DtUs = 2000'i64

func ramp(comp, k: int): float32 =
  float32(100_000 * comp + k)

proc makeRecording(path: string; offsetS: int) =
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
      k.time = float64(BaseUs div 1_000_000 + offsetS) + float64(seg * SegLen) * 0.002
      k.rcvLine = 1
      k.rcvPoint = 7
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
    doAssert outcomeLines(r).len == 3, $outcomeLines(r) # two files and the unplaced shots

  block a_second_run_replaces_nothing:
    let written = readFile(outDir / "one_slice.sgd")
    let got = run(jobs, plan)
    doAssert got.st == jsDone, got.error
    doAssert got.res.countWritten == 0 and got.res.countSliceable == 0
    doAssert "already in the destination folder" in fileOf(got.res, "one.sgy").skip,
      fileOf(got.res, "one.sgy").skip
    doAssert readFile(outDir / "one_slice.sgd") == written, "an output was replaced"

  block a_folder_that_cannot_be_listed_fails:
    var bad = plan
    bad.folder = dir / "nothing"
    let got = run(jobs, bad)
    doAssert got.st == jsFailed and "could not be listed" in got.error, got.error

  echo "tcutfolderjob ok"

when isMainModule:
  main()
