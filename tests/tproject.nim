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
## with `later` not written back, "a later version's part is kept"; with a
## device name accepted, a hostile `(file "CON")` was stored.

import std/[options, os, strutils, times]
import parseSEG
import viewSEG/core/[jobs, join, nif, processing, project, projectnif, shotlog, surveystore]
import utils/[fixtures, waiting]

func h(path: string): string =
  ## A POSIX-style absolute path as the host writes it: on Windows on drive C.
  when defined(windows): "C:" & path.replace('/', '\\') else: path

proc state(jobs: Jobs; id: JobId): JobState = jobs.info(id).get.state

proc run(work: JobWork) =
  let jobs = initJobs()
  let id = jobs.submit(JobSpec(title: "t", lane: jlBackground), work)
  doAssert waitUntil(jobs.state(id) in {jsDone, jsFailed, jsCancelled})
  doAssert jobs.state(id) == jsDone, $jobs.info(id)

proc main*() =

  block document:
    var d = ProjectDoc(name: "Land 2026", created: initTime(1_763_240_400, 0))
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

  block shotLogs:
    # A log's map is kept with the project; the text itself is not in the document.
    var d = ProjectDoc(name: "Land 2026")
    var m = initShotLogMap()
    m.delimiter = dlSemicolon
    m.skipLines = 2
    m.hasHeader = false
    m.roles = @[crFileNumber, crShotPoint, crDateTime]
    m.clock = tcGps
    m.dateTimePattern = "yyyy-mm-dd hh:mm:ss"
    m.sentinels = @["-999.25"]
    m.lengthUnit = luFeet
    d.shotLogs = @[StoredShotLog(name: "morning", file: "morning.csv", map: m)]
    let text = projectDocument(d)
    doAssert "(shotLogs" in text and "(file \"morning.csv\")" in text, text
    doAssert "shotlogs/" notin text, "the copy's folder is not written into the document: " & text
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.shotLogs.len == 1, $back.shotLogs.len
    doAssert back.shotLogs[0].name == "morning" and back.shotLogs[0].file == "morning.csv"
    doAssert back.shotLogs[0].map == m, "the map did not come back"
    # An older document has no node: none, and writing it does not add one.
    let old = projectDocument(ProjectDoc(name: "old"))
    doAssert "(shotLogs" notin old, old
    problems.setLen 0
    doAssert readProject(old, "project.nif", problems).shotLogs.len == 0 and problems.len == 0
    # A field this version does not know is kept and written back.
    let extra = text.replace("(file \"morning.csv\")",
      "(file \"morning.csv\") (kept (n 1))")
    let kept = readProject(extra, "project.nif", problems)
    doAssert kept.shotLogs.len == 1 and kept.shotLogs[0].later.len == 1
    doAssert "(kept" in projectDocument(kept), "a later version's part of a shot log is kept"
    # Hostile: wrong arity, an unknown role, and a huge column count are said
    # and left out. The rest of the document still reads.
    proc hostile(body, words: string) =
      problems.setLen 0
      let doc = "(project (version 1) (name \"h\") (shotLogs " & body & "))"
      let got = readProject(doc, "project.nif", problems)
      doAssert got.shotLogs.len == 0, "a hostile shot log was stored: " & body
      doAssert got.name == "h"
      var said = false
      for p in problems:
        if words in p: said = true
      doAssert said, "not said (" & words & "): " & $problems
    hostile("(log)", "left out")
    hostile("(log (name \"a\" \"b\") (file \"a.csv\"))", "string")
    hostile("(log (name \"a\") (file \"a.csv\") (map (role \"not a role\")))", "not a column role")
    var roles = ""
    for i in 1 .. 10_000: roles.add " (role \"text\")"
    hostile("(log (name \"a\") (file \"a.csv\") (map" & roles & "))", "left out")
    # A copy that is not a plain file name is left out.
    hostile("(log (name \"a\") (file \"shotlogs/../a.csv\"))", "left out")
    # A Windows device name, or a trailing dot or space, is not a file name.
    hostile("(log (name \"a\") (file \"CON\"))", "left out")
    hostile("(log (name \"a\") (file \"nul.txt\"))", "left out")
    hostile("(log (name \"a\") (file \"COM1.csv\"))", "left out")
    hostile("(log (name \"a\") (file \"lpt9\"))", "left out")
    hostile("(log (name \"a\") (file \"end.\"))", "left out")
    hostile("(log (name \"a\") (file \"end \"))", "left out")

  block places:
    let dir = h"/jobs/Land 2026"
    let p = placeOf(dir, h"/jobs/field/day1")
    doAssert p.path == "../field/day1" and p.absolute == h"/jobs/field/day1", $p
    # copied with its data to another drive: its own copy first, then the old
    # place, then a folder of that name beside the project
    doAssert p.candidates(h"/media/usb/Land 2026") == @[h"/media/usb/field/day1",
      h"/jobs/field/day1", h"/media/usb/day1"], "a project copied with its data finds its " &
      "own copy first: " & $p.candidates(h"/media/usb/Land 2026")
    let m = p.moved(h"/jobs/field", h"/mnt/field")
    doAssert m.absolute == h"/mnt/field/day1", m.absolute
    doAssert h"/jobs/Land 2026/x".isInside(h"/jobs/Land 2026") and
      not h"/jobs/Land 20267".isInside(h"/jobs/Land 2026")
    doAssert projectDirOf(h"/a/b/project.nif") == h"/a/b" and projectDirOf(h"/a/b") == h"/a/b"
    doAssert projectNameProblem("").len > 0 and projectNameProblem("a/b").len > 0 and
        projectNameProblem("Job 1") == ""
    doAssert copyName("a.sps", ["a.sps", "a-2.sps"]) == "a-3.sps"
    doAssert not "CON".isShotLogFile and not "nul.txt".isShotLogFile
    doAssert not "COM1.csv".isShotLogFile and not "lpt9".isShotLogFile
    doAssert not "end.".isShotLogFile and not "end ".isShotLogFile
    doAssert "shotlog.csv".isShotLogFile
    doAssert copyName("CON", []) == "CON-2"
    doAssert copyName("nul.txt", []) == "nul-2.txt"
    doAssert copyName("COM1.csv", []) == "COM1-2.csv"
    doAssert copyName("lpt9", []) == "lpt9-2"
    doAssert copyName("end.", []) == "end" and copyName("end ", []) == "end"

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

when isMainModule:
  main()
