## Survey files and positions through the application state: SPS and P1
## files are told apart by their first bytes (also when the first 4 KiB
## hold header records only, as the land survey files do) and listed as
## what they are; `ckLoadSurvey` loads them on a job with progress into the
## survey, with what is wrong in them said in the log; File > Open, a drop
## and a click in the file list send a survey file to the survey and leave
## the plot as it is, and stepping through the list passes survey files by;
## an open file's positions are read on a job and leave with the file;
## hostile survey files (cut short, a huge line, binary junk, a junk tail,
## empty, a named pipe, a binary card among cards) are refused or read as
## far as they go, and nothing raises or hangs; a file of several chunks
## loads whole; a cancel stops a load; the files are never changed; a P1
## file's text line names ("CLT4960") are the import's numbers on the map
## (the trailing digits, a line name mapped), also for a file the import
## finds loaded with other options.
## With the private land survey present, its S, R and X files load, and its
## record's traces find their receivers there by station.
##
## Seen to fail: with `surveyKind` judging only data records (no word from
## a name), `kindsOfHeads` found the headers-only file unknown; with the open
## job opening every file as seismic (`openWork` for `openFileWork`),
## `openAndDropSurveyFiles` found no layer for the file opened; with the
## junk check never stopping a read, `hostileFiles` found no word of where
## the junk tail's read stopped; with a chunk cut where the buffer ends
## instead of after its last line end, `bigFileInChunks` lost the records
## across the cuts; with `closeSession` keeping the traces layer,
## `positionsOfOpenFiles` found it after the close, and with the hint said for
## every file, it found it for the second file of a folder; with binary
## cards blanked as one line (the whole chunk), `fixedCardsWithABinaryCard`
## found no receiver; with a P1 line name read as a number only
## (`parseFloat`, as before), `textLineNames` found @[nan, nan, nan], not 4960.
##
## Runs alone: it measures the time the land survey takes to load, and
## bounds the frame that takes in an opened file (20 ms).

import std/[monotimes, os, strutils, times]
import parseSEG
import viewSEG/core/[filejobs, state, surveyjobs]
import viewSEG/view/filetable
import privatefiles
import utils/[fixtures, owntime, waiting]
when not defined(windows):
  from std/posix import nil

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

func said(log: MessageLog; part: string): bool =
  for e in log:
    if part in e.text: return true
  false

proc lastLines(log: MessageLog): string =
  for e in log: result.add $e.severity & ": " & e.text & "\n"

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

template fileLayer(st: AppState; path: string): SurveyLayer =
  st.survey.layers[st.survey.findFile(path)]

proc idle(st: var AppState): bool =
  st.settle(st.jobs.active.len == 0)

proc load(st: var AppState; paths: varargs[string]) =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)

func bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc main*() =

  block kindsOfHeads:
    withFixtures fx:
      let sps = fx.surveySps()
      for (path, want) in [(sps.s, fkSpsSource), (sps.r, fkSpsReceiver), (sps.x, fkSpsRelation),
          (fx.surveyP1(), fkP1), (fx.surveySegy(), fkSegy), (fx.twoSetSegd(), fkSegd),
          (fx.hostileSurvey(hsNoLineEnds), fkSpsReceiver),
          (fx.hostileSurvey(hsHeadersOnly), fkSpsReceiver),
          (fx.hostileSurvey(hsBinary), fkUnknown), (fx.hostileSurvey(hsEmpty), fkUnknown)]:
        doAssert sniff(path) == want, path.extractFilename & ": " & $sniff(path)
      # Header records only in the first 4 KiB: the H00 record, and the name.
      var head = ""
      for i in 0 ..< 60:
        head.add alignLeft(if i == 0: "H00 SPS format version num.     SPS 2.1;"
          else: "H" & align($i, 2, '0') & " Some header", 80) & "\r\n"
      let bytes = bytesOf(head[0 ..< SniffBytes])
      for (name, want) in [("a.sps", fkSpsSource), ("a.RPS", fkSpsReceiver),
          ("a.xps", fkSpsRelation), ("a.s01", fkSps), ("a.ops", fkSpsRelation)]:
        doAssert fileKindOf(bytes, name, whole = false) == want, name
      # Without H00 naming SPS, the name must say SPS.
      let plain = bytesOf(head.replace("H00 SPS format version num.     SPS 2.1;",
        "H00 Format version             2.1;     ")[0 ..< SniffBytes])
      doAssert fileKindOf(plain, "a.txt", false) == fkUnknown
      doAssert fileKindOf(plain, "a.r", false) == fkSpsReceiver
      # Comments first, as a SEG-Y textual header starts: still SPS.
      let commented = "C This survey\nC was shot in 2026\n" & readFile(sps.r)
      doAssert fileKindOf(bytesOf(commented), "c.txt", whole = true) == fkSpsReceiver
      # A text file, and one with a NUL in it.
      doAssert fileKindOf(bytesOf("Notes on line 7\nall fine\n"), "n.txt", true) == fkUnknown
      var nul = readFile(sps.r)
      nul[100] = '\0'
      doAssert fileKindOf(bytesOf(nul), "survey.r", true) == fkUnknown

  block listedAsWhatTheyAre:
    withFixtures fx:
      let dir = fx.dir / "line 7"
      createDir(dir)
      let sps = fx.plantedSps()
      for p in [sps.s, sps.r, sps.x, fx.surveyP1(), fx.surveySegy()]:
        copyFile(p, dir / p.extractFilename)
      writeFile(dir / "notes.txt", "nothing to see\n")
      var st = initAppState()
      st.apply Command(kind: ckBrowse, paths: @[dir], showFirst: true)
      doAssert st.settle(not st.fileList.scanning and st.shownPath == dir / "survey-clean.sgy")
      var kinds: seq[string]
      for e in st.fileList.entries: kinds.add e.name & " " & $e.kind
      doAssert kinds == @["planted.r SPS R", "planted.s SPS S", "planted.x SPS X",
        "survey-clean.sgy SEG-Y", "survey.p1 P1"], $kinds
      doAssert st.fileList.others == 1
      # A folder's survey files are listed, not loaded.
      doAssert st.survey.findFile(dir / "planted.r") < 0
      # Stepping passes them by, both ways.
      var t: FileTable
      t.update(st.fileList, "", FileOrder())
      let shown = dir / "survey-clean.sgy"
      doAssert t.stepped(st.fileList, shown, 1) == shown and
        t.stepped(st.fileList, shown, -1) == shown
      doAssert t.stepped(st.fileList, "", 1) == shown and t.stepped(st.fileList, "", -1) == shown
      # A click on one loads it, and the plot stays.
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: dir / "planted.r")
      doAssert st.settle(st.survey.findFile(dir / "planted.r") >= 0)
      doAssert st.shownPath == shown and st.fileList.chosen == shown
      # Clicked again, unchanged: loaded already.
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: dir / "planted.r")
      doAssert st.log.has("planted.r is loaded already, as it is now.")
      st.shutdown()

  block loadsWithProgress:
    withFixtures fx:
      let sps = fx.plantedSps()
      let p1 = fx.surveyP1()
      let before = [snapshot(sps.s), snapshot(sps.r), snapshot(sps.x), snapshot(p1)]
      var st = initAppState()
      st.load(sps.s, sps.r, sps.x)
      st.load(sps.r)
      doAssert st.log.has("planted.r is already being loaded.")
      doAssert st.surveyLoading(sps.r)
      doAssert st.settle(st.survey.layers.len == 3 and st.jobs.active.len == 0), st.log.lastLines
      for j in st.jobs.list:
        doAssert j.spec.title.startsWith("Load ") and j.state == jsDone, $j
        doAssert j.progress.done == j.progress.total and j.progress.total > 0, $j.progress
      let r = st.fileLayer(sps.r)
      doAssert r.kind == fkSpsReceiver and r.points[prReceiver].len == Channels
      doAssert r.counts[prReceiver].moved == 1 and r.counts[prReceiver].zero == 1
      doAssert r.size == getFileSize(sps.r) and r.modified == getLastModificationTime(sps.r)
      doAssert st.log.has("Loaded planted.r (SPS R): " & $Channels & " receiver points. 1 record " &
        "without receiver coordinates; 1 record with the receiver at (0, 0); 2 receiver stations " &
        "given again (1 at other coordinates: the last is kept).", sevWarning), st.log.lastLines
      doAssert st.log.has("Loaded planted.x (SPS X): " & $Shots & " X records for " &
        $Shots & " field records.")
      # parseSEG's own word on the record without coordinates, by line.
      doAssert st.log.said("line "), st.log.lastLines
      doAssert st.fileLayer(sps.x).relationRuns == Shots
      # Not listed: loaded again on request, in place of the layer before.
      st.load(sps.r)
      doAssert st.settle(st.log.has("Loaded planted.r (SPS R) again", sevWarning))
      doAssert st.survey.layers.len == 3
      # A P1 file holds sources, as the S file does: one source file is loaded at a time.
      st.load(p1)
      doAssert st.settle(st.survey.findFile(p1) >= 0 and st.jobs.active.len == 0)
      doAssert st.log.has("Loaded survey.p1 (P1): " & $(P1Shots + 1) & " source points. 1 " &
        "record with the source at (0, 0). It replaces planted.s: one S file is loaded at a " &
        "time.", sevWarning), st.log.lastLines
      doAssert st.survey.findFile(sps.s) < 0 and st.survey.layers.len == 3
      # Taken out again.
      st.apply Command(kind: ckUnloadSurvey, layer: st.fileLayer(p1).id)
      doAssert st.log.has("survey.p1 was taken out of the survey.") and
        st.survey.layers.len == 2
      st.apply Command(kind: ckUnloadSurvey, layer: SurveyLayerId(999))
      doAssert st.log.has("Ignored \"unload survey\": survey layer 999 is not loaded.",
        sevWarning)
      st.shutdown()
      doAssert [snapshot(sps.s), snapshot(sps.r), snapshot(sps.x), snapshot(p1)] == before,
        "loading changed a survey file"

  block aCheckHoldsNoFrame:
    # With a relation file of 200 000 X records loaded, a file opened (as each
    # step through a folder opens one) is checked against it on a job that
    # reads the relations where they are: the frame that takes the file in
    # holds no copy of them. Seen to fail: with `checkWork` given the layer's
    # relations by value (a copy on this thread), "the open's frame took 470
    # ms" (debug). And the layer can be unloaded while a check reads it.
    withFixtures fx:
      let xp = fx.dir / "big.x"
      let header = SpsHeader(code: "00", description: "SPS format version num.",
        data: "SPS 2.1;")
      var x = SpsFile(headers: @[header])
      for i in 0 ..< 200_000:
        x.relations.add SpsRelation(fieldRecord: 1 + i, recordIncrement: 1, instrumentCode: '1',
          srcLine: float(100 + i div 1000), srcPoint: float(1000 + i mod 1000), srcIndex: 1,
          fromChannel: 1, toChannel: 240, channelIncrement: 1, rcvLine: 200, fromReceiver: 1000,
          toReceiver: 1239, rcvIndex: 1)
      doAssert writeSps(x, xp).len == 0
      var st = initAppState()
      st.load(xp)
      doAssert st.settle(st.survey.layers.len == 1 and st.jobs.active.len == 0), st.log.lastLines
      doAssert st.fileLayer(xp).relationRuns == 200_000
      var longest = Duration()
      for name in ["one.sgy", "two.sgy"]:
        copyFile(fx.surveySegy(), fx.dir / name)
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.dir / name)
        doAssert waitUntil((
          let t0 = ownTime()
          discard st.drainInbox()
          longest = max(longest, ownTime() - t0)
          st.sessions.len == 1 and st.sessions[0].name == name and st.jobs.active.len == 0))
      doAssert longest < initDuration(milliseconds = 20), "the open's frame took " &
        $longest.inMilliseconds & " ms"
      # unloaded while a check of the next file is under way: it ends, and says nothing
      copyFile(fx.surveySegy(), fx.dir / "three.sgy")
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.dir / "three.sgy")
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].name == "three.sgy")
      st.apply Command(kind: ckUnloadSurvey, layer: st.fileLayer(xp).id)
      doAssert st.settle(st.jobs.active.len == 0)
      for e in st.log: doAssert e.severity != sevError, st.log.lastLines
      st.shutdown()

  block openAndDropSurveyFiles:
    withFixtures fx:
      let sps = fx.surveySps()
      let segy = fx.surveySegy()
      var st = initAppState()
      # File > Open of a seismic file, then of a survey file: the plot stays.
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy, listFolder: true)
      doAssert st.settle(st.shownPath == segy)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: sps.r)
      doAssert st.settle(st.survey.findFile(sps.r) >= 0), st.log.lastLines
      doAssert st.idle()
      discard st.drainInbox()
      doAssert st.shownPath == segy and st.fileList.chosen == segy and st.sessions.len == 1
      doAssert not st.log.said("not a SEG-Y"), st.log.lastLines
      # Opened (the command line): into the survey too.
      st.apply Command(kind: ckOpen, paths: @[sps.s])
      doAssert st.settle(st.survey.findFile(sps.s) >= 0) and st.sessions.len == 1
      # Dropped together with a seismic file: the survey files are loaded
      # and the seismic file is shown.
      var dropped = initAppState()
      dropped.apply Command(kind: ckBrowse, paths: @[sps.x, sps.s, fx.twoSetSegd(), sps.r],
        showFirst: true)
      doAssert dropped.settle(dropped.survey.layers.len >= 4 and
        dropped.shownPath == fx.twoSetSegd() and dropped.idle()), dropped.log.lastLines
      for p in [sps.s, sps.r, sps.x]: doAssert dropped.survey.findFile(p) >= 0, p
      # One survey file dropped alone: loaded once, its folder listed.
      var alone = initAppState()
      alone.apply Command(kind: ckBrowse, paths: @[sps.r], showFirst: true)
      doAssert alone.settle(alone.survey.findFile(sps.r) >= 0 and not alone.fileList.scanning and
        alone.idle()), alone.log.lastLines
      discard alone.drainInbox()
      var loads = 0
      for j in alone.jobs.list:
        if j.spec.title in ["Load survey.r", "Open survey.r"]: inc loads
      doAssert loads == 1, $loads & " loads"
      doAssert alone.fileList.chosen == "" or alone.fileList.chosen.endsWith(".sgy") or
        alone.fileList.chosen.endsWith(".sgd"), alone.fileList.chosen
      for s in [st.addr, dropped.addr, alone.addr]: s[].shutdown()

  block positionsOfOpenFiles:
    withFixtures fx:
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[fx.surveySegy()])
      doAssert st.settle(st.sessions.len == 1 and st.survey.findTraces(st.sessions[0].id) >= 0)
      let s = st.sessions[0]
      let l = st.survey.layers[st.survey.findTraces(s.id)]
      doAssert l.origin == loTraces and l.base == s.base and l.traces == SurveyTraces
      doAssert l.points[prSource].len == Shots and l.points[prReceiver].len == Channels
      doAssert l.kind == fkSegy and l.keysRevision == s.file.keysRevision
      doAssert st.log.count(sevWarning) == 0, st.log.lastLines
      var job: JobInfo
      for j in st.jobs.list:
        if j.spec.title == "Read the positions in survey-clean.sgy": job = j
      doAssert job.state == jsDone and job.progress.phase == "preparing the map" and
        job.progress.done == job.progress.total and job.spec.reads == @[s.path], $job
      st.apply Command(kind: ckClose, file: s.id)
      doAssert st.survey.findTraces(s.id) < 0 and st.survey.layers.len == 0
      # A file with sources at (0, 0) says so, once.
      st.apply Command(kind: ckOpen, paths: @[fx.surveySegy(pdZeroCoordinates)])
      doAssert st.settle(st.sessions.len == 1 and st.survey.layers.len == 1)
      doAssert st.log.has($Channels & " traces without source coordinates"), st.log.lastLines
      # A record without coordinates (stations only) says how to place it.
      st.apply Command(kind: ckOpen, paths: @[fx.demoFile("record.sgd")])
      doAssert st.settle(st.sessions.len == 2 and st.survey.layers.len == 2), st.log.lastLines
      doAssert st.log.said("record.sgd carries no source or receiver coordinates"),
        st.log.lastLines
      # Said once a folder: another such file there says nothing.
      let other = fx.demoFile("record.sgd").parentDir / "record2.sgd"
      copyFile(fx.demoFile("record.sgd"), other)
      st.apply Command(kind: ckOpen, paths: @[other])
      doAssert st.settle(st.sessions.len == 3 and st.survey.layers.len == 3), st.log.lastLines
      doAssert not st.log.said("record2.sgd carries no source"), st.log.lastLines
      st.shutdown()

  block hostileFiles:
    withFixtures fx:
      var st = initAppState()
      var paths: seq[string]
      for h in HostileSurvey: paths.add fx.hostileSurvey(h)
      when not defined(windows):
        let pipe = fx.dir / "hostile" / "pipe.sps"
        doAssert posix.mkfifo(pipe.cstring, 0o600) == 0
        paths.add pipe
      # one at a time: of the files that hold receivers only the last loaded stays
      template layerOf(h: HostileSurvey): untyped =
        st.load(fx.hostileSurvey(h))
        doAssert st.idle(), "a hostile survey file hung its load"
        discard st.drainInbox()
        st.fileLayer(fx.hostileSurvey(h))
      # The last record lost its coordinates: read, and counted without them.
      let truncated = layerOf(hsTruncated)
      doAssert truncated.points[prReceiver].len == Channels - 1 and
        truncated.counts[prReceiver].missing == 1
      doAssert layerOf(hsHugeLine).points[prReceiver].len == Channels
      doAssert st.log.said("longer than 65536 bytes"), st.log.lastLines
      doAssert layerOf(hsJunkTail).points[prReceiver].len == JunkTailReceivers
      doAssert st.log.has("junk-tail.rps turns into other data (16 MiB with no SPS records), " &
        "so it was read up to byte 1677", sevWarning), st.log.lastLines # (16 MiB, to its last line)
      doAssert st.log.has("lines of junk-tail.rps hold binary data", sevWarning)
      # Binary bytes and no line end: read no further than the junk tail, either.
      # Seen to fail with the junk counted in lines (each chunk one line, but 64
      # records to parseSEG): read to its end, no word of where the read stopped.
      doAssert layerOf(hsBinaryTail).points[prReceiver].len == JunkTailReceivers
      doAssert st.log.said("binary-tail.rps turns into other data (16 MiB with no SPS " &
        "records), so it was read up to byte"), st.log.lastLines
      doAssert layerOf(hsNoLineEnds).points[prReceiver].len == Channels
      doAssert layerOf(hsHeadersOnly).points[prReceiver].len == 0
      var refused = @[fx.hostileSurvey(hsBinary), fx.hostileSurvey(hsEmpty)]
      when not defined(windows): refused.add paths[^1]
      st.load(refused)
      doAssert st.idle(), "a hostile survey file hung its load"
      for h in [hsBinary, hsEmpty]:
        let p = fx.hostileSurvey(h)
        doAssert st.survey.findFile(p) < 0
        doAssert st.log.has("Cannot load " & p & ": it is not an SPS or SEG P1 file.", sevError), p
      when not defined(windows):
        doAssert st.log.has("Cannot load " & paths[^1] & ": it is not a regular file (a named " &
          "pipe, a device).", sevError), st.log.lastLines
      # The log stays readable: a file's problems are capped.
      var hugeLines = 0
      for e in st.log:
        if e.source == "huge-line.rps": inc hugeLines
      doAssert hugeLines <= MaxProblems + 2, $hugeLines # and "N more", and "Loaded"
      st.shutdown()

  block fixedCardsWithABinaryCard:
    # 80-byte cards without line ends: a card of binary data among them is
    # passed by alone.
    withFixtures fx:
      var f = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
        data: "SPS 2.1;")])
      for line in 0 ..< 4:
        for channel in 1 .. Channels:
          f.points.add SpsPoint(kind: pkReceiver, line: RcvLine + float64(line),
            point: FirstRcvPoint + float64(channel - 1), index: 1, code: "G1",
            easting: rcvX(channel), northing: OriginY + 50 * float64(line), elevation: Elevation,
            dayOfYear: -1, hour: -1, minute: -1, second: -1)
      var cards: seq[string]
      for line in spsText(f).text.splitLines:
        if line.len > 0: cards.add alignLeft(line, 80)
      var binary = newString(80)
      for i in 0 ..< 80: binary[i] = char(i * 7 mod 32) # control bytes
      let path = fx.dir / "cards.rps"
      writeFile(path, cards[0 .. 72].join("") & binary & cards[73 .. ^1].join(""))
      var st = initAppState()
      st.load(path)
      doAssert st.settle(st.survey.findFile(path) >= 0), st.log.lastLines
      doAssert st.fileLayer(path).points[prReceiver].len == 4 * Channels
      doAssert st.log.has("1 line of cards.rps holds binary data", sevWarning), st.log.lastLines
      st.shutdown()

  block bigFileInChunks:
    # An R file of several chunks: every record is read across the cuts, and
    # a cancel stops a load between chunks.
    withFixtures fx:
      let path = fx.dir / "big.rps"
      var text = "H00 SPS format version num.     SPS 2.1;\n"
      const n = 160_000 # about 13 MB: 3 to 4 chunks
      for i in 0 ..< n:
        let p = SpsPoint(kind: pkReceiver, line: float64(1 + i div 1000),
          point: float64(1 + i mod 1000), index: 1, code: "G1", easting: 500_000 + float64(i),
          northing: 6_000_000, elevation: 10, staticCorrection: NaN, pointDepth: NaN,
          seismicDatum: NaN, upholeTime: NaN, waterDepth: NaN, dayOfYear: -1, hour: -1,
          minute: -1, second: -1)
        text.add encodeSps(p, sps21) & "\r\n"
      writeFile(path, text)
      doAssert text.len > 3 * SurveyChunk
      var st = initAppState()
      st.load(path)
      doAssert st.settle(st.survey.findFile(path) >= 0), st.log.lastLines
      let l = st.fileLayer(path) # a copy: the layer goes with the unload below
      doAssert l.points[prReceiver].len == n and l.counts[prReceiver].given == n
      doAssert st.log.count(sevWarning) == 0, st.log.lastLines
      let at = l.stationPoint(prReceiver, Station(line: 80, point: 500, index: 1))
      doAssert at >= 0 and l.points[prReceiver].index.x(at) == 500_000 + 79_499
      st.apply Command(kind: ckUnloadSurvey, layer: l.id)
      st.load(path)
      for j in st.jobs.list:
        if j.state in {jsQueued, jsRunning}: st.apply Command(kind: ckCancelJob, job: j.id)
      doAssert st.settle(st.log.has("Loading big.rps was cancelled.") or
        st.survey.findFile(path) >= 0)
      doAssert st.survey.findFile(path) < 0, "the cancel did not stop the load"
      st.shutdown()

  block textLineNames:
    withFixtures fx:
      let path = fx.dir / "text-lines.p1"
      var lf = PLogicalFile(format: pfP1, header: @["H SEG P1 viewSEG test fixture: line CLT4960",
        " PROJECTION UTM 30N, GRID UNITS METRES"])
      for point in 1 .. 3:
        var r = initP1Record()
        (r.lineName, r.pointName, r.point) = ("CLT4960", $point, float64(point))
        (r.latitude, r.longitude) = (55.0 + float64(point) / 1000, -2.0)
        (r.easting, r.northing, r.depthOrElevation) = (p1X(float64(point)), P1Y, 12.0)
        lf.records.add r
      doAssert writeP1(P1File(files: @[lf]), path).len == 0
      func lines(l: SurveyLayer): seq[float64] =
        for s in l.points[prSource].station: result.add s.line
      var st = initAppState()
      st.load(path)
      doAssert st.idle and st.survey.findFile(path) >= 0, st.log.lastLines
      for line in st.fileLayer(path).lines: doAssert line.isNaN, "no rule: no line"
      # The import's trailing digits: loaded again by the import, line 4960.
      var opts = st.settings.join
      opts.trailingDigits = true
      st.apply Command(kind: ckJoin, joinFiles: @[JoinFile(path: path, kind: jkP1)],
        joinOptions: opts)
      doAssert st.idle
      doAssert st.fileLayer(path).lines == @[4960.0, 4960.0, 4960.0], $st.fileLayer(path).lines
      # A line name mapped (the import's options, kept in the settings) wins.
      var s = st.settings
      s.join.lineNames = @[LineName(name: "CLT4960", line: 12)]
      st.apply Command(kind: ckSettings, settings: s)
      st.load(path)
      doAssert st.idle
      doAssert st.fileLayer(path).lines == @[12.0, 12.0, 12.0], $st.fileLayer(path).lines
      st.shutdown()

  block landSurvey:
    # Local only: the private land survey, named in exampleFiles/names.cfg.
    let survey = privateFiles("landSps", "landRps", "landXps")
    if survey.len == 3:
      var st = initAppState()
      let start = epochTime()
      st.load(survey[0], survey[1], survey[2])
      doAssert st.settle(st.survey.layers.len == 3 and st.idle()), st.log.lastLines
      let seconds = epochTime() - start
      let s = st.fileLayer(survey[0])
      let r = st.fileLayer(survey[1])
      let x = st.fileLayer(survey[2])
      doAssert r.kind == fkSpsReceiver and s.kind == fkSpsSource and x.kind == fkSpsRelation
      doAssert r.points[prReceiver].len > 1000 and s.points[prSource].len > 1000
      doAssert x.relationRuns > 100_000
      doAssert r.gridUnit.measurementSystem == 2, "the land survey is in US survey feet"
      echo "  land survey: ", r.points[prReceiver].len, " receivers, ", s.points[prSource].len,
        " sources, ", x.relationRuns, " relation records of ", x.relationRecords,
        " records; loaded in ", formatFloat(seconds, ffDecimal, 2), " s"
      let record = privateFile("landSegd")
      if record.len > 0:
        st.apply Command(kind: ckOpen, paths: @[record])
        doAssert st.settle(st.sessions.len == 1 and st.survey.layers.len == 4), st.log.lastLines
        let f = st.sessions[0]
        var found = 0
        for t in 0 ..< f.len:
          let k = f.file.traceKeys(t)
          if k.isSeismic:
            for p in st.survey.tracePoints(f.base + t, k):
              if p.layer == r.id and p.role == prReceiver: inc found
        echo "  land survey record: ", found, " of ", f.len, " traces find their receiver"
        doAssert found > f.len div 2
      st.shutdown()

when isMainModule:
  main()
