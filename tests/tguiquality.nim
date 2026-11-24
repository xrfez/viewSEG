## Reports > Trace quality in the running frontend, headless: the item is
## inactive until a folder is open; the window is closed at the start, then a
## tab beside the Seismic window; the scan matches an independent scan; the
## totals, the all-zero station, a sort, a filter, a CSV export and a
## double-click are what the window shows.
##
## Seen to fail: with the Reports item left enabled when no folder is open
## (no disabled mark), "Reports is inactive without a folder did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils, tables]
import parseSEG
import viewSEG/core/[filejobs, geometry, jobs, qualityjobs, qualityreport, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc writeTraceAt(w: var SeismicWriter; record, channel: int; line, point: float64;
    component: uint8; status: TraceStatus; samples: openArray[float32]) =
  var k = initTraceKeys()
  k.record = float64(record)
  k.channel = float64(channel)
  k.srcLine = 1
  k.srcPoint = 1
  k.srcIndex = 1
  k.rcvLine = line
  k.rcvPoint = point
  k.rcvIndex = 1
  k.intervalUs = 2000
  k.component = component
  k.sensorType = component
  k.status = status
  w.writeTrace(k, samples)

proc seismicFile(path: string; record: int; traces: openArray[tuple[line, point: float64;
    component: uint8; status: TraceStatus; samples: seq[float32]]]) =
  let n = if traces.len == 0: 1 else: traces[0].samples.len
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: n, time: 1_700_000_000.0))
  for i, t in traces:
    writeTraceAt(w, record, i + 1, t.line, t.point, t.component, t.status, t.samples)
  doAssert w.close().len == 0, "file was not written: " & path

proc zeros(n: int): seq[float32] = newSeq[float32](n)

proc wave(): seq[float32] =
  result = newSeq[float32](32)
  for i in 0 ..< 32:
    result[i] = sin(float32(i) * 0.4'f32) * 20

proc stationBad(f: FrameInfo; line: string): tuple[seen: bool; bad, allZero: int] =
  for name in f.markNames("quality.station " & line & " "):
    let parts = name.split(' ')
    if parts.len >= 9:
      return (true, parseInt(parts[7]), parseInt(parts[8]))

proc main*() =
  var wait = 0
  var since = getMonoTime()

  withFixtures fx:
    let folder = fx.dir / "line"
    createDir(folder)
    seismicFile(folder / "one.sgd", 7, @[
      (line: 40.0, point: 1.0, component: 1'u8, status: tsLive, samples: zeros(32)),
      (line: 90.0, point: 1.0, component: 1'u8, status: tsLive, samples: wave())])
    writeFile(folder / "notes.txt", "not seismic\n")
    let outCsv = fx.dir / "out" / "trace-quality.csv"
    createDir(fx.dir / "out")
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let shot = currentSourcePath().parentDir.parentDir / ".scratch" / "quality-window.png"
    createDir(shot.parentDir)

    var asked: seq[DialogKind]
    var answer: seq[string]
    var expectedTotals = ""
    var expectedCsv = ""
    var scanned = false
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      answer

    proc scanOnce(f: FrameInfo) =
      if scanned: return
      let listed = $(f.core.fileList.folder)
      let cache = $(f.core.indexCache)
      var capped = false
      let paths = listedNames(@[listed], true, capped)
      let snap = f.core.editsSnapshot
      var edits = initTable[string, FileEdits]()
      for path in paths:
        var key = ""
        if path in snap.alias: key = snap.alias[path]
        elif path in snap.byKey: key = path
        if key.len > 0 and key in snap.byKey: edits[path] = snap.byKey[key]
      let jobs = initJobs()
      let sink = QualitySink()
      let id = jobs.submit(qualitySpec(paths), scanQuality(paths, edits, sink, cache))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the independent scan did not finish"
      let info = jobs.info(id).get
      doAssert info.state == jsDone, info.error
      let t = sink.result.report.totals
      expectedTotals = "quality.totals " & $t.files & " " & $t.records & " " & $t.traces &
        " " & $t.killed & " " & $t.bad & " " & $t.stations & " " & $t.counts[qfAllZero]
      expectedCsv = stationsCsv(sink.result.report.stations)
      doAssert t.files == 1, "independent scan saw " & $t.files & " files"
      doAssert t.bad >= 1, "the all-zero trace was not bad"
      doAssert t.counts[qfAllZero] >= 1, "no all-zero count"
      var unreadNotes = false
      for row in sink.result.unread:
        if "notes.txt" in row.path: unreadNotes = true
      doAssert unreadNotes, "notes.txt was not unread: " & $sink.result.unread
      scanned = true

    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    step("closed at the start", noop, proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert awQuality in f.hiddenWindows, $f.hiddenWindows
        doAssert not f.windowPlace("quality").inSight)

    proc inactive(f: FrameInfo) = f.click(f.markOf("menu.Reports").centre)
    proc inactiveDone(f: FrameInfo): bool =
      f.markOf("menu.Trace quality").size.x > 0 and
        f.markOf("menu.Trace quality.disabled").size.x > 0
    step("Reports is inactive without a folder", inactive, inactiveDone)

    proc listFolder(f: FrameInfo) =
      f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
    proc folderListed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("the folder is listed", listFolder, folderListed)

    var opened = false
    proc openReport(f: FrameInfo) =
      if f.markOf("menu.Trace quality").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc reportReady(f: FrameInfo): bool =
      if not opened:
        let it = f.markOf("menu.Trace quality")
        if it.size.x > 0 and f.markOf("menu.Trace quality.disabled").size.x == 0:
          f.click(it.centre)
          opened = true
      result = f.markOf("quality.ready").size.x > 0 and
        f.markOf("quality.tab Stations").size.x > 0
      if result:
        let (m, p) = (f.windowPlace("quality"), f.windowPlace("plot"))
        doAssert m.inSight and m.docked and not m.apart, "not in the centre dock: " & $m
        doAssert abs(m.rect.pos.x - p.rect.pos.x) <= 2 and abs(m.rect.pos.y - p.rect.pos.y) <= 2,
          "not a tab beside the Seismic window: " & $m.rect & " plot " & $p.rect
    step("Reports > Trace quality", openReport, reportReady)

    proc totalsMatch(f: FrameInfo): bool =
      scanOnce(f)
      f.markOf(expectedTotals).size.x > 0
    step("the totals match an independent scan", noop, totalsMatch)

    var exportClicked = false
    proc exportCsv(f: FrameInfo) =
      asked.setLen 0
      answer = @[outCsv]
      f.click(f.markOf("quality.export").centre)
      exportClicked = true
    proc exported(f: FrameInfo): bool =
      if not exportClicked: return false
      if not fileExists(outCsv): return false
      let got = readFile(outCsv)
      doAssert got == expectedCsv, "csv differs, asked " & $asked & "\n" &
        got[0 ..< min(240, got.len)]
      doAssert asked == @[dkExportQuality], "asked for " & $asked
      true
    step("Export CSV... writes the stations", exportCsv, exported)

    proc sortBad(f: FrameInfo) = f.click(f.markOf("quality.header Bad").centre)
    proc sortedBad(f: FrameInfo): bool = f.markOf("quality.sort Bad").size.x > 0
    step("a click on Bad sorts by Bad", sortBad, sortedBad)

    var filterAt = vec2(0, 0)
    proc startFilter(f: FrameInfo) =
      filterAt = f.markOf("quality.filter").centre
      f.moveMouse(filterAt)
    proc filtered(f: FrameInfo): bool =
      if wait == 3: f.pressMouse(filterAt, true)
      if wait == 5: f.pressMouse(filterAt, false)
      if wait == 7: f.typeText("40")
      if wait < 14: return false
      let bad = f.stationBad("40")
      let other = f.stationBad("90")
      result = bad.seen and bad.bad >= 1 and bad.allZero >= 1 and not other.seen
      if result:
        doAssert f.savePng(shot), "the screenshot was not written"
    step("the filter shows the all-zero station", startFilter, filtered)

    proc recordsTab(f: FrameInfo) = f.click(f.markOf("quality.tab Records").centre)
    proc recordsShown(f: FrameInfo): bool =
      if f.markOf("quality.record 0").size.x == 0 and wait mod 8 == 0:
        f.click(f.markOf("quality.tab Records").centre)
      f.markOf("quality.file one.sgd").size.x > 0
    step("the Records tab", recordsTab, recordsShown)

    proc openedFile(f: FrameInfo): bool =
      var saw = false
      for s in f.core.sessions:
        if "one.sgd" in s.path: saw = true
      if not saw:
        let row = f.markOf("quality.record 0")
        let q = vec2(row.pos.x + 12, round(row.pos.y + row.size.y / 2))
        case wait mod 12
        of 2: f.moveMouse(q)
        of 4: f.pressMouse(q, true)
        of 5: f.pressMouse(q, false)
        of 6: f.pressMouse(q, true)
        of 7: f.pressMouse(q, false)
        else: discard
      saw
    step("a double click opens the file", noop, openedFile)

    proc openUnread(f: FrameInfo) = f.click(f.markOf("quality.unread").centre)
    proc unreadNames(f: FrameInfo): bool =
      for name in f.markNames("quality.unreadline "):
        if "notes.txt" in name: return true
    step("Unread names notes.txt", openUnread, unreadNames)

    var at = 0
    var started = false
    var failed = ""
    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if at >= steps.len or failed.len > 0:
        f.stop()
        return
      if not started:
        steps[at].act(f)
        started = true
        wait = 0
        since = getMonoTime()
      else:
        inc wait
        if wait >= 3 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      dialogs: hook, onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiquality: ", steps.len, " steps"

when isMainModule:
  main()
