## A project's parts on their own (`core/project`, `core/projectnif`,
## `core/surveystore`), without a window:
##
## - the project document read back as written (its data folders, its
##   survey's copies with their originals, the import's options and units,
##   `survey.bin`'s size and hash, the plot's filters, the display presets,
##   the output name patterns and which one is chosen),
##   a later version's parts kept and written back, a newer version said, a
##   document that is not one refused;
## - paths kept relative to the project folder and absolute, looked for in
##   that order and then beside the project (a project handed over with its
##   data beside it), and a folder re-pointed when its drive moved;
## - the survey kept in `survey.bin`: an SPS survey's points and relations,
##   a P1 file's shotpoints and a CSV table read back as parseSEG read them
##   from the files; a byte changed or the file cut short is refused before
##   anything is handed over. The column map used last is written and read
##   with a stored log's map, and a hostile node is left out.
##
## Seen to fail: with `candidates` looking at the absolute place first, "a
## project copied with its data finds its own copy first" (it found the old
## folder); with the store's hash left out of `readStore`'s check, "a
## changed byte is refused" (the points came back with a wrong easting);
## with `later` not written back, "a later version's part is kept"; with a
## device name accepted, a hostile `(file "CON")` was stored; with a hostile
## `(lastShotMap)` stored anyway, `lastShotMap` kept `(role "not a role")`; with
## `decimalComma` left out of the map writer, "decimalComma did not come back";
## with a bad role in `(lastShotMap)` saying the log is left out,
## "a remembered map said a log was left out";
## with a part
## kind written as `$kind`, `(part "srcLine"` was missing (the file said
## `npSrcLine`); with the patterns node always written, an old document held
## `(outputPatterns`; with an unknown part word kept, the bad pattern was
## stored beside "Good"; with a repeated label kept, both "Line" and "line"
## were stored; with no cap, 33 patterns were kept; with the part cap and
## `patternProblem` both skipped, a 17-part pattern was kept; with the chosen
## label not checked, "Nope" stayed chosen; with a pattern's unknown child
## dropped, it was not written back; with an empty choice written,
## `(outputPattern ` was in the document. With an unknown child of a part
## dropped, `(futurePart 1)` was not written back inside the part; with an
## extra child of pad, text or the chosen label taken as a missing value, the
## pattern or the choice was left out; with an extra child of a separator
## taken as a bad separator, the pattern was left out. With a refusal that
## did not name the pattern, a bad separator on "Line" said nothing of "Line";
## with the control-character sentence left as "holds no", a tab in a label
## said the opposite; with "32th", the limit sentence was wrong; with a long
## choice said missing, its first 20 characters were not quoted. With
## `patternProblem` not applied, a stored text part holding the pattern's own
## separator was kept. With the texts node always written, an old document held
## `(outputTexts`; with an unknown child of a template dropped, `(kept` was not
## written back; with an encoding other than the two taken as EBCDIC, a template
## of `utf8` was kept; with the text choice not checked, "Nope" stayed chosen.

import std/[options, os, strutils, times]
import parseSEG
import viewSEG/core/[jobs, join, nif, outputnames, outputtext, processing, project, projectnif, shotlog,
  surveystore]
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
    d.store = StoreInfo(format: 1, splitKnown: true, bytes: 31457280, hash: 0x51f3'u64,
      sources: 1200,
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
    m.roles = @[crFileNumber, crShotPoint, crTime]
    m.clock = tcGps
    m.dateTimePattern = "yyyy-mm-dd hh:mm:ss"
    m.sentinels = @["-999.25"]
    m.lengthUnit = luFeet
    m.decimalComma = true
    d.shotLogs = @[StoredShotLog(name: "morning", file: "morning.csv", map: m)]
    let text = projectDocument(d)
    doAssert "(decimalComma true)" in text, "decimalComma was not written: " & text
    doAssert "(shotLogs" in text and "(file \"morning.csv\")" in text, text
    doAssert "shotlogs/" notin text, "the copy's folder is not written into the document: " & text
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.shotLogs.len == 1, $back.shotLogs.len
    doAssert back.shotLogs[0].name == "morning" and back.shotLogs[0].file == "morning.csv"
    doAssert back.shotLogs[0].map == m, "the map did not come back"
    doAssert back.shotLogs[0].map.decimalComma, "decimalComma did not come back"
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

  block oldShotLogRoles:
    # A project saved before the system columns were named holds the older
    # role words. They are read as the same columns, and the same shots.
    var m = initShotLogMap()
    m.hasHeader = false
    m.roles = @[crFileNumber, crSequence, crStatus, crX, crY, crZ, crSourceDepth, crIgnored]
    var d = ProjectDoc(name: "Land 2026")
    d.shotLogs = @[StoredShotLog(name: "morning", file: "morning.csv", map: m)]
    d.lastShotMap = some(LastShotMap(map: m, headers: @["a", "b", "c", "d", "e", "f", "g",
      "h"]))
    let current = projectDocument(d)
    doAssert "(role \"FFID\")" in current and "(role \"Ignore\")" in current, current
    var old = current
    for (now, was) in [("FFID", "file number"), ("SEQ", "year"), ("Status", "day of year"),
        ("X", "hour"), ("Y", "minute"), ("Z", "second"), ("Depth", "gun array"),
        ("Ignore", "ignored")]:
      old = old.replace("(role \"" & now & "\")", "(role \"" & was & "\")")
    doAssert "FFID" notin old and "(role \"gun array\")" in old
    var problems: seq[string]
    let back = readProject(old, "project.nif", problems)
    doAssert problems.len == 0, $problems
    let got = back.shotLogs[0].map
    doAssert got.roles == @[crFileNumber, crTime, crTime, crTime, crTime, crTime, crText,
      crIgnored], $got.roles
    doAssert got.dateTimePattern == "yyyy ddd hh mi ss.ffffff", got.dateTimePattern
    doAssert got.names == @["", "", "", "", "", "", "gun array", ""], $got.names
    doAssert back.lastShotMap.get.map.roles == got.roles
    let text = "7,2024,61,0,0,59.5,12.5,x\n"
    let view = shots(parseShotLog(text, got), got)
    doAssert view.problems.count == 0
    doAssert view.rows[0].fileNumber == some(7'i64)
    doAssert view.rows[0].timeUtcUs == some(1_709_251_259_500_000'i64)
    doAssert view.rows[0].texts == @["12.5"]
    # what is written now reads back to itself, names included
    var named = m
    named.roles = @[crText, crTime, crTime]
    named.names = @["Note", "", ""]
    named.dateTimePattern = "yyyy-mm-dd hh:mi:ss"
    d.shotLogs = @[StoredShotLog(name: "morning", file: "morning.csv", map: named)]
    problems.setLen 0
    doAssert readProject(projectDocument(d), "project.nif", problems).shotLogs[0].map == named
    doAssert problems.len == 0
    let bad = current.replace("(role \"FFID\")", "(role \"no such role\")")
    problems.setLen 0
    doAssert readProject(bad, "project.nif", problems).shotLogs.len == 0
    doAssert problems.len > 0 and "no such role" in problems[0]

  block lastShotMap:
    # The column map used last is kept beside a stored log, and comes back
    # with its header names. The text of the log is still not a node.
    var d = ProjectDoc(name: "Land 2026")
    var m = initShotLogMap()
    m.delimiter = dlSemicolon
    m.skipLines = 1
    m.hasHeader = true
    m.roles = @[crText, crSequence, crText]
    m.clock = tcGps
    m.dateTimePattern = "yyyy-mm-dd hh:mm:ss"
    m.sentinels = @["-999.25"]
    m.lengthUnit = luFeet
    m.decimalComma = true
    d.shotLogs = @[StoredShotLog(name: "morning", file: "morning.csv", map: m)]
    d.lastShotMap = some(LastShotMap(map: m, headers: @["File", "Shot", "Note"]))
    let text = projectDocument(d)
    doAssert "(decimalComma true)" in text, "decimalComma was not written: " & text
    doAssert "(lastShotMap" in text and "(headerName \"File\")" in text, text
    doAssert "(shotLogs" in text, "a stored log was dropped beside the remembered map"
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.shotLogs.len == 1 and back.shotLogs[0].map == m
    doAssert back.lastShotMap.isSome, "the remembered map did not come back"
    doAssert back.lastShotMap.get.map == m, "the remembered map did not come back"
    doAssert back.lastShotMap.get.map.decimalComma, "decimalComma did not come back"
    doAssert back.shotLogs[0].map.decimalComma, "a stored log lost decimalComma"
    doAssert back.lastShotMap.get.headers == @["File", "Shot", "Note"]
    var plain = m
    plain.decimalComma = false
    let quiet = projectDocument(ProjectDoc(name: "plain",
      shotLogs: @[StoredShotLog(name: "morning", file: "morning.csv", map: plain)],
      lastShotMap: some(LastShotMap(map: plain, headers: @["File"]))))
    doAssert "decimalComma" notin quiet, "a false decimalComma was written: " & quiet
    let old = projectDocument(ProjectDoc(name: "old"))
    doAssert "(lastShotMap" notin old, old
    problems.setLen 0
    doAssert readProject(old, "project.nif", problems).lastShotMap.isNone and problems.len == 0
    let extra = text.replace("(headerName \"Note\")",
      "(headerName \"Note\") (kept (n 1))")
    let kept = readProject(extra, "project.nif", problems)
    doAssert kept.lastShotMap.isSome and kept.lastShotMap.get.later.len == 1
    doAssert "(kept" in projectDocument(kept), "a later field beside the map is kept"
    let extraMap = text.replace("(pattern \"yyyy-mm-dd hh:mm:ss\")",
      "(pattern \"yyyy-mm-dd hh:mm:ss\") (keptInMap (n 1))")
    let keptMap = readProject(extraMap, "project.nif", problems)
    doAssert keptMap.lastShotMap.isSome and keptMap.lastShotMap.get.mapLater.len == 1
    doAssert "(keptInMap" in projectDocument(keptMap), "a later field of the map is kept"
    proc hostileMap(body, words: string) =
      problems.setLen 0
      let doc = "(project (version 1) (name \"h\") (lastShotMap " & body & "))"
      let got = readProject(doc, "project.nif", problems)
      doAssert got.lastShotMap.isNone, "a hostile map was stored: " & body
      doAssert got.name == "h"
      var said = false
      for p in problems:
        if words in p: said = true
      doAssert said, "not said (" & words & "): " & $problems
    hostileMap("(map (role \"not a role\"))", "the remembered column map is left out")
    hostileMap("(map (role))", "the remembered column map is left out")
    problems.setLen 0
    discard readProject("(project (version 1) (name \"h\") (lastShotMap " &
      "(map (role \"not a role\"))))", "project.nif", problems)
    for p in problems:
      doAssert "the log is left out" notin p, "a remembered map said a log was left out: " & p
    hostileMap("(headerName \"file\")", "left out")
    hostileMap("(map (role \"text\")) (headerName 1)", "left out")
    hostileMap("(map (role \"text\")) (headerName \"" & "x".repeat(200) & "\")", "left out")
    var roles = ""
    for i in 1 .. 300: roles.add " (role \"text\")"
    hostileMap("(map" & roles & ")", "left out")
    var names = ""
    for i in 1 .. 300: names.add " (headerName \"c\")"
    hostileMap("(map (role \"text\"))" & names, "left out")

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
        info.receivers == Channels and info.relations == Shots and info.receiverRelations == 0, $info
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

  block outputNames:
    # Two patterns, each separator, a width, a quoted label and non-ASCII text.
    # A quote cannot sit in a text part: patternProblem refuses it as a file name.
    var d = ProjectDoc(name: "Land 2026", hasOutputPatterns: true, outputPattern: "a\"b")
    d.outputPatterns = @[
      OutputPattern(name: "a\"b", separator: nsUnderscore, parts: @[
        NamePart(kind: npSrcLine, pad: 5),
        NamePart(kind: npText, text: "café")]),
      OutputPattern(name: "Point", separator: nsHyphen, parts: @[
        NamePart(kind: npSrcPoint), NamePart(kind: npRecord)])]
    let text = projectDocument(d)
    doAssert "(separator \"_\")" in text and "(separator \"-\")" in text, text
    doAssert text.count("(pad ") == 1 and "(pad 5)" in text, text
    doAssert "(part \"srcLine\"" in text and "npSrcLine" notin text, text
    doAssert "(outputPattern \"a\\22b\")" in text and "café" in text, text
    var problems: seq[string] = @[]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.hasOutputPatterns and back.outputPattern == "a\"b"
    doAssert back.outputPatterns == d.outputPatterns, $back.outputPatterns
    # The sensor serial part is stored as its own word; an old file still reads.
    var sensor = ProjectDoc(name: "s", hasOutputPatterns: true)
    sensor.outputPatterns = @[OutputPattern(name: "Unit", separator: nsDot, parts: @[
      NamePart(kind: npStem), NamePart(kind: npSensorSerial)])]
    let sensorText = projectDocument(sensor)
    doAssert "(part \"sensorSerial\"" in sensorText, sensorText
    problems.setLen 0
    let sensorBack = readProject(sensorText, "project.nif", problems)
    doAssert problems.len == 0 and sensorBack.outputPatterns == sensor.outputPatterns,
      $problems
    # A vendor field part is stored with its name as `(text ...)`.
    var vendor = ProjectDoc(name: "v", hasOutputPatterns: true)
    vendor.outputPatterns = @[OutputPattern(name: "Batch", separator: nsUnderscore, parts: @[
      NamePart(kind: npStem), NamePart(kind: npVendor, text: "unitInfo.serial")])]
    let vendorText = projectDocument(vendor)
    doAssert "(part \"vendor\" (text \"unitInfo.serial\")" in vendorText, vendorText
    problems.setLen 0
    let vendorBack = readProject(vendorText, "project.nif", problems)
    doAssert problems.len == 0 and vendorBack.outputPatterns == vendor.outputPatterns, $problems
    # A dot is not written, and a width of 0 is not written.
    var dot = ProjectDoc(name: "d", hasOutputPatterns: true)
    dot.outputPatterns = @[OutputPattern(name: "Dot", separator: nsDot, parts: @[
      NamePart(kind: npStem)])]
    let dotText = projectDocument(dot)
    doAssert "(separator" notin dotText and "(pad " notin dotText, dotText
    problems.setLen 0
    let dotBack = readProject(dotText, "project.nif", problems)
    doAssert problems.len == 0 and dotBack.outputPatterns.len == 1
    doAssert dotBack.outputPatterns[0].separator == nsDot
    doAssert dotBack.outputPatterns[0].parts[0].pad == 0
    # An older document has neither node: none, and no problem.
    let old = projectDocument(ProjectDoc(name: "old"))
    doAssert "(outputPatterns" notin old and "(outputPattern" notin old, old
    problems.setLen 0
    let oldBack = readProject(old, "project.nif", problems)
    doAssert not oldBack.hasOutputPatterns and oldBack.outputPatterns.len == 0
    doAssert oldBack.outputPattern.len == 0 and problems.len == 0, $problems
    # A bad part word is left out; a good pattern beside it is kept.
    proc readDoc(body: string): ProjectDoc =
      problems.setLen 0
      readProject("(project (version 1) (name \"h\") " & body & ")", "project.nif", problems)
    let bad = readDoc("(outputPatterns (pattern \"Bad\" (part \"notAPart\")) " &
      "(pattern \"Good\" (part \"srcLine\")))")
    doAssert bad.name == "h" and bad.outputPatterns.len == 1
    doAssert bad.outputPatterns[0].name == "Good"
    doAssert problems.len == 1 and "notAPart" in problems[0], $problems
    # A label given twice, without regard to case: the first counts.
    let dup = readDoc("(outputPatterns (pattern \"Line\" (part \"srcLine\")) " &
      "(pattern \"line\" (part \"srcPoint\")))")
    doAssert dup.outputPatterns.len == 1 and dup.outputPatterns[0].name == "Line"
    doAssert problems.len == 1 and "twice" in problems[0], $problems
    # 33 patterns: the first 32 are kept, the rest said.
    var many = "(outputPatterns"
    for i in 1 .. MaxOutputPatterns + 1:
      many.add " (pattern \"p" & $i & "\" (part \"record\"))"
    many.add ")"
    let got33 = readDoc(many)
    doAssert got33.outputPatterns.len == MaxOutputPatterns, $got33.outputPatterns.len
    doAssert got33.outputPatterns[0].name == "p1"
    doAssert got33.outputPatterns[^1].name == "p" & $MaxOutputPatterns
    doAssert problems.len == 1 and "left out" in problems[0], $problems
    # 17 parts: that pattern is left out; a sibling is kept.
    var parts = ""
    for i in 1 .. MaxPatternParts + 1: parts.add " (part \"record\")"
    let got17 = readDoc("(outputPatterns (pattern \"TooMany\"" & parts &
      ") (pattern \"Good\" (part \"srcLine\")))")
    doAssert got17.outputPatterns.len == 1 and got17.outputPatterns[0].name == "Good"
    doAssert got17.name == "h" and problems.len == 1 and "left out" in problems[0], $problems
    # A chosen label that names no pattern reads as none, with a sentence.
    # The choice is written before the patterns, so order does not matter.
    let miss = readDoc("(outputPattern \"Nope\") " &
      "(outputPatterns (pattern \"Line\" (part \"srcLine\")))")
    doAssert miss.outputPattern.len == 0 and miss.outputPatterns.len == 1 and miss.name == "h"
    doAssert problems.len == 1 and "Nope" in problems[0], $problems
    # A text part longer than 120 bytes is left out.
    let long = readDoc("(outputPatterns (pattern \"T\" (part \"text\" (text \"" &
      repeat('a', 121) & "\"))))")
    doAssert long.outputPatterns.len == 0 and long.name == "h" and problems.len == 1, $problems
    # A child this version does not know is kept and written back inside the pattern.
    problems.setLen 0
    let extra = "(project (version 1) (name \"h\") (outputPatterns " &
      "(pattern \"Line\" (part \"srcLine\") (kept (n 1)))))"
    let kept = readProject(extra, "project.nif", problems)
    doAssert problems.len == 0 and kept.outputPatterns.len == 1, $problems
    doAssert kept.outputPatternLater.len == 1 and kept.outputPatternLater[0].len == 1
    doAssert kept.outputPatternLater[0][0].tag == "kept"
    let again = projectDocument(kept)
    doAssert "(kept" in again and "(n 1)" in again, again
    doAssert again.find("(pattern ") < again.find("(kept"), again
    # An empty choice is not written.
    var emptyChoice = ProjectDoc(name: "e", hasOutputPatterns: true)
    emptyChoice.outputPatterns = @[
      OutputPattern(name: "Line", parts: @[NamePart(kind: npSrcLine)])]
    let emptyText = projectDocument(emptyChoice)
    doAssert "(outputPatterns" in emptyText and "(outputPattern " notin emptyText, emptyText

  block outputTexts:
    # Text header templates: written beside the name patterns, read back as
    # written, an old document with none, a bad one left out and said, an
    # unknown child kept.
    var d = ProjectDoc(name: "Land 2026", hasOutputTexts: true, outputText: "Ascii \"one\"")
    d.outputTexts = @[
      OutputText(name: "Ebcdic", encoding: teEbcdic, lines: @["C 1 {stem}", "", "caf\xc3\xa9"]),
      OutputText(name: "Ascii \"one\"", encoding: teAscii, lines: @["{{x}} {record:5}"])]
    let text = projectDocument(d)
    doAssert "(outputTexts" in text and "(text \"Ebcdic\"" in text, text
    doAssert text.count("(encoding ") == 1 and "(encoding \"ascii\")" in text, text
    doAssert "(line \"\")" in text and "(outputText \"Ascii \\22one\\22\")" in text, text
    var problems: seq[string] = @[]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.hasOutputTexts and back.outputTexts == d.outputTexts, $back.outputTexts
    doAssert back.outputText == d.outputText
    let old = projectDocument(ProjectDoc(name: "old"))
    doAssert "(outputTexts" notin old and "(outputText " notin old, old
    let oldBack = readProject(old, "project.nif", problems)
    doAssert not oldBack.hasOutputTexts and oldBack.outputTexts.len == 0 and
      oldBack.outputText.len == 0 and problems.len == 0, $problems
    proc readDoc(body: string): ProjectDoc =
      problems.setLen 0
      readProject("(project (version 1) (name \"h\") " & body & ")", "project.nif", problems)
    let bad = readDoc("(outputTexts (text \"Bad\" (line \"{nope}\")) " &
      "(text \"Enc\" (encoding \"utf8\")) (text \"Good\" (line \"C 1\")))")
    doAssert bad.outputTexts.len == 1 and bad.outputTexts[0].name == "Good", $bad.outputTexts
    doAssert problems.len == 2 and "{nope}" in problems[0] and "utf8" in problems[1],
      $problems
    let dup = readDoc("(outputTexts (text \"A\" (line \"1\")) (text \"a\" (line \"2\")))")
    doAssert dup.outputTexts.len == 1 and dup.outputTexts[0].lines == @["1"] and
      problems.len == 1 and "twice" in problems[0], $problems
    var thirty9 = "(outputTexts (text \"Long\""
    for i in 1 .. 39: thirty9.add " (line \"x\")"
    thirty9.add ")"
    let long = readDoc(thirty9 & ")")
    doAssert long.outputTexts.len == 0 and problems.len == 1, $problems
    let miss = readDoc("(outputText \"Nope\") (outputTexts (text \"A\" (line \"1\")))")
    doAssert miss.outputText.len == 0 and miss.outputTexts.len == 1 and problems.len == 1 and
      "Nope" in problems[0], $problems
    let chosen = readDoc("(outputText \"a\") (outputTexts (text \"A\" (line \"1\")))")
    doAssert chosen.outputText == "A" and problems.len == 0, $problems
    var many = "(outputTexts"
    for i in 1 .. MaxOutputTexts + 1: many.add " (text \"t" & $i & "\" (line \"x\"))"
    let capped = readDoc(many & ")")
    doAssert capped.outputTexts.len == MaxOutputTexts and problems.len == 1, $problems
    # An unknown child of a template and of the node is kept and written back.
    let extra = readDoc("(outputTexts (text \"A\" (line \"1\") (kept (n 1))) (future 2))")
    doAssert problems.len == 0 and extra.outputTexts.len == 1, $problems
    doAssert extra.outputTextLater.len == 1 and extra.outputTextLater[0][0].tag == "kept"
    doAssert extra.outputTextsLater.len == 1 and extra.outputTextsLater[0].tag == "future"
    let again = projectDocument(extra)
    doAssert "(kept (n 1))" in again and "(future 2)" in again, again
    doAssert again.find("(line \"1\")") < again.find("(kept"), again
    # The name patterns beside them are not disturbed.
    let both = readDoc("(outputPatterns (pattern \"Line\" (part \"srcLine\"))) " &
      "(outputPattern \"Line\") (outputTexts (text \"A\" (line \"1\"))) (outputText \"A\")")
    doAssert both.outputPattern == "Line" and both.outputText == "A" and problems.len == 0

  block unknownChildren:
    # An unknown child of a part is kept and written back inside that part.
    # An extra child of a scalar (pad, text, separator, the chosen label) does
    # not drop the value, and is not written back.
    var problems: seq[string] = @[]
    proc readDoc(body: string): ProjectDoc =
      problems.setLen 0
      readProject("(project (version 1) (name \"h\") " & body & ")", "project.nif", problems)
    let partUnk = readDoc("(outputPatterns (pattern \"Line\" (part \"srcLine\" (pad 5) " &
      "(futurePart 1))))")
    doAssert problems.len == 0 and partUnk.outputPatterns.len == 1, $problems
    doAssert partUnk.outputPatterns[0].parts[0].pad == 5
    let partText = projectDocument(partUnk)
    doAssert "(part \"srcLine\" (pad 5) (futurePart 1))" in partText, partText
    # A separator's extra child is not written back; the separator is kept.
    let sep = readDoc("(outputPatterns (pattern \"Line\" (separator \"_\" (futureSep 1)) " &
      "(part \"srcLine\")))")
    doAssert problems.len == 0 and sep.outputPatterns.len == 1, $problems
    doAssert sep.outputPatterns[0].separator == nsUnderscore
    let sepText = projectDocument(sep)
    doAssert "(separator \"_\")" in sepText and "futureSep" notin sepText, sepText
    # An extra child of pad does not drop the width or the choice.
    let padX = readDoc("(outputPatterns (pattern \"Line\" (part \"srcLine\" " &
      "(pad 5 (futurePad 1))))) (outputPattern \"Line\")")
    doAssert problems.len == 0 and padX.outputPatterns.len == 1, $problems
    doAssert padX.outputPatterns[0].parts[0].pad == 5 and padX.outputPattern == "Line"
    let padText = projectDocument(padX)
    doAssert "(pad 5)" in padText and "futurePad" notin padText, padText
    doAssert "(outputPattern \"Line\")" in padText, padText
    # An extra child of text does not drop the string.
    let textX = readDoc("(outputPatterns (pattern \"Line\" (part \"text\" " &
      "(text \"abc\" (futureText 1)))))")
    doAssert problems.len == 0 and textX.outputPatterns.len == 1, $problems
    doAssert textX.outputPatterns[0].parts[0].text == "abc"
    let textBack = projectDocument(textX)
    doAssert "(text \"abc\")" in textBack and "futureText" notin textBack, textBack
    # An extra child of the chosen label does not clear the choice.
    let ch = readDoc("(outputPatterns (pattern \"Line\" (part \"srcLine\"))) " &
      "(outputPattern \"Line\" (futureChoice 1))")
    doAssert problems.len == 0 and ch.outputPattern == "Line" and ch.outputPatterns.len == 1, $problems
    let chText = projectDocument(ch)
    doAssert "(outputPattern \"Line\")" in chText and "futureChoice" notin chText, chText

  block refusalSentences:
    var problems: seq[string] = @[]
    proc readDoc(body: string): ProjectDoc =
      problems.setLen 0
      readProject("(project (version 1) (name \"h\") " & body & ")", "project.nif", problems)
    proc said(text: string) =
      doAssert problems.len == 1 and problems[0] == "project.nif line 1: " & text, $problems
    let sep = readDoc("(outputPatterns (pattern \"Line\" (separator \"x\") (part \"srcLine\")))")
    doAssert sep.outputPatterns.len == 0
    said("the name pattern \"Line\": a name pattern's separator is \".\", \"_\" or \"-\"; " &
      "it is left out")
    let wide = readDoc("(outputPatterns (pattern \"Line\" (part \"srcLine\" (pad 13))))")
    doAssert wide.outputPatterns.len == 0
    said("the name pattern \"Line\": Source line's width is from 0 to 12; it is left out.")
    let tabbed = readDoc("(outputPatterns (pattern \"Li\\tne\" (part \"srcLine\")))")
    doAssert tabbed.outputPatterns.len == 0
    said("the name pattern \"Li\tne\": the label has a control character; it is left out")
    let unnamed = readDoc("(outputPatterns (pattern (part \"srcLine\")))")
    doAssert unnamed.outputPatterns.len == 0
    said("A name pattern needs a name; it is left out.")
    var many = "(outputPatterns"
    for i in 1 .. MaxOutputPatterns + 1:
      many.add " (pattern \"p" & $i & "\" (part \"record\"))"
    many.add ")"
    let got33 = readDoc(many)
    doAssert got33.outputPatterns.len == MaxOutputPatterns
    said("At most " & $MaxOutputPatterns & " name patterns are kept; the 1 after the first " &
      $MaxOutputPatterns & " are left out.")
    let head = repeat('A', 20)
    let longChoice = readDoc("(outputPattern \"" & repeat('A', 65) & "\") " &
      "(outputPatterns (pattern \"Line\" (part \"srcLine\")))")
    doAssert longChoice.outputPattern.len == 0 and longChoice.outputPatterns.len == 1
    said("the chosen name pattern \"" & head & "\" is too long; today's naming is used")
    let huge = readDoc("(outputPattern \"" & repeat('B', MaxPatternName * 4 + 65) & "\")")
    doAssert huge.outputPattern.len == 0
    said("the chosen name pattern \"" & repeat('B', 20) & "\" is too long; today's naming is used")

  block separatorInText:
    # Text that holds this pattern's separator cannot be a file-name piece, so
    # the stored pattern is left out and the sentence names the label. The same
    # text with another separator is a piece, and is kept.
    var problems: seq[string] = @[]
    proc readDoc(body: string): ProjectDoc =
      problems.setLen 0
      readProject("(project (version 1) (name \"h\") " & body & ")", "project.nif", problems)
    let held = readDoc("(outputPatterns (pattern \"Line\" (separator \"_\") " &
      "(part \"text\" (text \"a_b\"))))")
    doAssert held.outputPatterns.len == 0 and problems.len == 1, $problems
    doAssert problems[0] == "project.nif line 1: the name pattern \"Line\": " &
      "Text has the separator _ in it; it is left out.", $problems
    let other = readDoc("(outputPatterns (pattern \"Line\" (separator \"-\") " &
      "(part \"text\" (text \"a_b\"))))")
    doAssert problems.len == 0 and other.outputPatterns.len == 1, $problems
    doAssert other.outputPatterns[0].separator == nsHyphen
    doAssert other.outputPatterns[0].parts[0].text == "a_b"

  echo "tproject: done"

when isMainModule:
  main()
