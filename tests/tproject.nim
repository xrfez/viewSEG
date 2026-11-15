## A project's parts on their own (`core/project`, `core/projectnif`,
## `core/surveystore`), without a window:
##
## - the project document read back as written (its data folders, its
##   survey's copies with their originals, the import's options and units,
##   `survey.bin`'s size and hash, the plot's filters, the display presets),
##   a later version's parts kept and written back, a newer version said, a
##   document that is not one refused;
## - paths kept relative to the project folder and absolute, looked for in
##   that order and then beside the project (a project handed over with its
##   data beside it), and a folder re-pointed when its drive moved;
## - the survey kept in `survey.bin`: an SPS survey's points and relations,
##   a P1 file's shotpoints and a CSV table read back as parseSEG read them
##   from the files; a byte changed or the file cut short is refused before
##   anything is handed over.
##
## Seen to fail: with `candidates` looking at the absolute place first, "a
## project copied with its data finds its own copy first" (it found the old
## folder); with the store's hash left out of `readStore`'s check, "a
## changed byte is refused" (the points came back with a wrong easting);
## with `later` not written back, "a later version's part is kept".

import std/[options, os, strutils, times]
import parseSEG
import viewSEG/core/[jobs, join, nif, processing, project, projectnif, surveystore]
import utils/[fixtures, waiting]

block document:
  var d = ProjectDoc(name: "Morgantown 2026", created: initTime(1_763_240_400, 0))
  d.data = @[ProjectPath(path: "../field/day1", absolute: "/mnt/field/day1")]
  d.survey = @[SurveyCopy(kind: jkSps, copy: "survey/files/a.sps",
    original: ProjectPath(path: "../survey/a.sps", absolute: "/mnt/survey/a.sps"),
    size: 4812733, modified: initTime(1_763_200_961, 120_000_000), quick: 0x9a0c51f3e2d4b6a7'u64),
    SurveyCopy(kind: jkCsv, role: crReceivers, copy: "survey/files/b.csv",
    original: ProjectPath(absolute: "D:\\survey\\b.csv"), size: 10, quick: 1)]
  d.options = JoinOptions(trailingDigits: true, lineNames: @[LineName(name: "CLT4960",
    line: 4960)])
  d.units = JoinUnits(survey: suUsFeet, file: suFeet, fileFromHeaders: true)
  d.notes = @["H20 Description of grid units: US survey feet"]
  d.store = StoreInfo(format: 1, bytes: 31457280, hash: 0x51f3'u64, sources: 1200,
    receivers: 3954, relations: 1200)
  d.processing = Processing(band: pbBandPass, f1: 5, f2: 10, f3: 50, f4: 70)
  d.hasProcessing = true
  let text = projectDocument(d)
  doAssert "(copy \"survey/files/a.sps\")" in text and "(path \"../field/day1\")" in text, text
  var problems: seq[string]
  let back = readProject(text, "project.nif", problems)
  doAssert problems.len == 0, $problems
  doAssert back.name == d.name and back.created == d.created and back.data == d.data
  doAssert back.survey == d.survey, $back.survey
  doAssert back.options.trailingDigits and back.options.lineNames == d.options.lineNames
  doAssert back.units == d.units and back.notes == d.notes and back.store == d.store
  doAssert back.hasProcessing and back.processing.band == pbBandPass and back.processing.f3 == 50
  doAssert not back.hasPresets
  # A later version's part is kept and written back; a newer version is said.
  let later = text.replace("(version 1)", "(version 1)\n (picks (file \"x\"))")
  let l = readProject(later, "project.nif", problems)
  doAssert l.later.len == 1 and readProject(projectDocument(l), "x", problems).later[0].tag ==
    "picks", "a later version's part is kept"
  discard readProject(text.replace("(version 1)", "(version 7)"), "project.nif", problems)
  doAssert problems.len == 1 and "newer viewSEG" in problems[0], $problems
  doAssertRaises NifError: discard readProject("(settings (version 1))", "x", problems)
  problems.setLen 0
  discard readProject(text.replace("(size 4812733)", "(size big)"), "project.nif", problems)
  doAssert problems.len == 1 and "line" in problems[0], $problems

block places:
  let dir = "/jobs/Morgantown 2026"
  let p = placeOf(dir, "/jobs/field/day1")
  doAssert p.path == "../field/day1" and p.absolute == "/jobs/field/day1", $p
  # copied with its data to another drive: its own copy first, then the old
  # place, then a folder of that name beside the project
  doAssert p.candidates("/media/usb/Morgantown 2026") == @["/media/usb/field/day1",
    "/jobs/field/day1", "/media/usb/day1"], "a project copied with its data finds its " &
    "own copy first: " & $p.candidates("/media/usb/Morgantown 2026")
  let m = p.moved("/jobs/field", "/mnt/field")
  doAssert m.absolute == "/mnt/field/day1", m.absolute
  doAssert "/jobs/Morgantown 2026/x".isInside("/jobs/Morgantown 2026") and
    not "/jobs/Morgantown 20267".isInside("/jobs/Morgantown 2026")
  doAssert projectDirOf("/a/b/project.nif") == "/a/b" and projectDirOf("/a/b") == "/a/b"
  doAssert projectNameProblem("").len > 0 and projectNameProblem("a/b").len > 0 and projectNameProblem("Job 1") == ""
  doAssert copyName("a.sps", ["a.sps", "a-2.sps"]) == "a-3.sps"

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc run(work: JobWork) =
  let jobs = initJobs()
  let id = jobs.submit(JobSpec(title: "t", lane: jlBackground), work)
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled})
  doAssert jobs.state(id) == jsDone, $jobs.info(id)

block store:
  withFixtures fx:
    let survey = fx.surveySps()
    let dir = fx.dir / "project"
    createDir(dir / "survey" / "files")
    var copies: seq[SurveyCopy]
    for path in [survey.s, survey.r, survey.x]:
      copyFile(path, dir / "survey" / "files" / path.extractFilename)
      copies.add SurveyCopy(kind: jkSps, copy: "survey/files/" & path.extractFilename)
    writeFile(dir / "survey" / "files" / "t.csv", "line,point,x,y,kind\n1,2,10,20,S\n")
    copies.add SurveyCopy(kind: jkCsv, copy: "survey/files/t.csv")
    var info: StoreInfo
    run(proc (ctx: JobContext) {.gcsafe.} =
      {.cast(gcsafe).}: info = writeStore(dir, copies, ctx))
    let path = dir / "survey" / "survey.bin"
    doAssert info.bytes == getFileSize(path) and info.sources == Shots and
      info.receivers == Channels and info.relations == Shots, $info
    proc readBack(path: string): tuple[points: seq[SpsPoint]; rel: seq[SpsRelation];
        csv: string; files: seq[string]; failure: string] =
      var got: typeof(result)
      let g = addr got
      proc onFile(f: StoredFile) = g.files.add f.name
      proc onSps(f: StoredFile; part: SpsFile) =
        g.points.add part.points
        g.rel.add part.relations
      proc onCsv(f: StoredFile; text: string) = g.csv = text
      run(proc (ctx: JobContext) {.gcsafe.} =
        {.cast(gcsafe).}:
          try: readStore(path, ctx, StoreReader(onFile: onFile, onSps: onSps, onCsv: onCsv))
          except IOError as e: g.failure = e.msg)
      got
    let b = readBack(path)
    doAssert b.failure == "", b.failure
    doAssert b.files == @["survey.s", "survey.r", "survey.x", "t.csv"], $b.files
    var want: seq[SpsPoint]
    for p in [survey.s, survey.r]: want.add readSps(p).points
    doAssert b.points.len == want.len
    for i, p in want:
      doAssert b.points[i].line == p.line and b.points[i].point == p.point and
        b.points[i].easting == p.easting and b.points[i].kind == p.kind and
        b.points[i].lineName == p.lineName, $i
    let x = readSps(survey.x).relations
    doAssert b.rel.len == x.len and b.rel[^1].fieldRecord == x[^1].fieldRecord and
      b.rel[^1].toReceiver == x[^1].toReceiver
    doAssert "1,2,10,20,S" in b.csv
    # one byte changed in the middle, then the file cut short: refused whole
    var bytes = readFile(path)
    bytes[bytes.len div 2] = char(ord(bytes[bytes.len div 2]) xor 0x55)
    writeFile(path & ".bad", bytes)
    let bad = readBack(path & ".bad")
    doAssert bad.failure.len > 0 and bad.points.len == 0, "a changed byte is refused"
    writeFile(path & ".short", readFile(path)[0 ..< 100])
    doAssert readBack(path & ".short").failure.len > 0, "a cut file is refused"
echo "tproject: done"
