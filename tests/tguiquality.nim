## Reports > Trace quality in the running frontend, headless: the menu item is always
## active; the window is closed at the start and then a tab beside the Seismic window;
## opening it computes nothing, not even on a listed folder; the File tab measures the
## file shown only, with the statistics lines on top and a table of one row per station
## (Line, Point, Lacks component, the counts: no Index, Component, File or Record column,
## no record number anywhere); a station with a component the data has but it has not is
## listed and counted; the Folder tab starts nothing until Run, takes the folder from the
## dialog, reads its subfolders only when the box says so (off by default; changing it
## drops the answer), counts a station over the files, exports the list, and the window
## closes by its tab's button and returns from the View menu.
##
## Seen to fail: with the Folder tab's job started as soon as a folder is chosen,
## "Folder... chooses the folder" found a folder job before Run; with the subfolders tick
## ignored by the walk, "Run: the folder without its subfolders" did not happen (2 files,
## not 1); with the station counts of the second file not added to the first's, "Run with
## subfolders" saw a row of 1 trace; with the menu item disabled without a folder,
## "Reports > Trace quality" found a disabled mark.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, jobs, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[qualitywords, theme]
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

proc main*() =
  var wait = 0
  var since = getMonoTime()

  withFixtures fx:
    let folder = fx.dir / "line"
    createDir(folder / "sub")
    seismicFile(folder / "one.sgd", 7, @[
      (line: 40.0, point: 1.0, component: 1'u8, status: tsLive, samples: zeros(32)),
      (line: 90.0, point: 1.0, component: 1'u8, status: tsLive, samples: wave()),
      (line: 90.0, point: 1.0, component: 2'u8, status: tsLive, samples: wave()),
      (line: 91.0, point: 1.0, component: 1'u8, status: tsLive, samples: wave()),
      (line: 91.0, point: 1.0, component: 2'u8, status: tsLive, samples: wave())])
    seismicFile(folder / "sub" / "two.sgd", 8, @[
      (line: 40.0, point: 1.0, component: 1'u8, status: tsLive, samples: zeros(32)),
      (line: 100.0, point: 1.0, component: 1'u8, status: tsLive, samples: wave()),
      (line: 100.0, point: 1.0, component: 2'u8, status: tsLive, samples: wave()),
      (line: 101.0, point: 1.0, component: 1'u8, status: tsLive, samples: wave()),
      (line: 101.0, point: 1.0, component: 2'u8, status: tsLive, samples: wave())])
    writeFile(folder / "notes.txt", "not seismic\n")
    let outCsv = fx.dir / "out" / "trace-quality.csv"
    createDir(fx.dir / "out")
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let shots = currentSourcePath().parentDir.parentDir / ".scratch" / "shots"
    createDir(shots)

    var asked: seq[DialogKind]
    var answer: seq[string]
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      answer

    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc has(f: FrameInfo; name: string): bool = f.markOf(name).size.x > 0
    proc jobTitles(f: FrameInfo): seq[string] =
      for j in f.core.jobs.list(): result.add j.spec.title
    proc said(f: FrameInfo; text: string): bool =
      for e in f.core.log:
        if text in e.text: return true
    proc qualityJobs(f: FrameInfo): seq[string] =
      for t in f.jobTitles:
        if t.startsWith("Trace quality"): result.add t

    step("closed at the start", noop, proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert awQuality in f.hiddenWindows, $f.hiddenWindows
        doAssert not f.windowPlace("quality").inSight)

    proc listFolder(f: FrameInfo) =
      f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
    proc folderListed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("the folder is listed", listFolder, folderListed)

    var opened = false
    proc openReport(f: FrameInfo) =
      if f.markOf("menu.Trace quality").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc noFile(f: FrameInfo): bool =
      if not opened:
        let it = f.markOf("menu.Trace quality")
        if it.size.x > 0:
          doAssert not f.has("menu.Trace quality.disabled"), "the menu item is inactive"
          f.click(it.centre)
          opened = true
      result = f.has("quality.tab File") and f.has("quality.message " & NeedFile)
      if result:
        let (m, p) = (f.windowPlace("quality"), f.windowPlace("plot"))
        doAssert m.inSight and m.docked and not m.apart, "not in the centre dock: " & $m
        doAssert abs(m.rect.pos.x - p.rect.pos.x) <= 2 and abs(m.rect.pos.y - p.rect.pos.y) <= 2,
          "not a tab beside the Seismic window: " & $m.rect & " plot " & $p.rect
        doAssert f.qualityJobs.len == 0, "opening the window computed something: " &
          $f.qualityJobs
        doAssert f.markNames("quality.station ").len == 0
    step("Reports > Trace quality opens the window and computes nothing", openReport, noFile)

    proc showFile(f: FrameInfo) =
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "one.sgd",
        listFolder: false)
    proc fileStats(f: FrameInfo): bool =
      result = f.has("quality.ready") and f.has("quality.header Line")
      if result:
        for line in ["Receiver stations in the file: 3", "Traces: 5, 0 killed, 5 measured",
            "Bad traces: 1 (20% of the measured)",
            "Receiver stations with a bad trace: 1 of 3 (33.33%)",
            "Dead: 0, all zero: 1, constant: 0, clipped: 0, spiky: 0, DC offset: 0, " &
            "not finite: 0", "1 receiver station lacks a component (of 2 components)"]:
          doAssert f.has("quality.stat " & line), "no line " & line & " in " &
            $f.markNames("quality.stat ")
        doAssert f.has("quality.counts 5 traces"), $f.markNames("quality.counts ")
        doAssert not f.said("Trace quality in one.sgd is done"),
          "the File tab announced its own end"
        doAssert f.has("quality.station 40 1 1 0 1 1 2 1"), $f.markNames("quality.station ")
        doAssert f.has("quality.station 90 1 2 0 0 0 - 0"), $f.markNames("quality.station ")
        var headers: seq[string] = @[]
        for n in f.markNames("quality.header "): headers.add n[len("quality.header ") .. ^1]
        for h in ["Line", "Point", "Lacks component", "Traces", "Killed", "Bad", "Dead",
            "All zero"]:
          doAssert h in headers, h & " missing from " & $headers
        for h in ["Index", "Component", "File", "Record", "Bad records"]:
          doAssert h notin headers, "a duplicated or record column: " & h
        doAssert not f.has("quality.tab Records") and not f.has("quality.tab Stations")
        doAssert f.qualityJobs == @["Trace quality in one.sgd"], $f.qualityJobs
        doAssert f.has("quality.statsbox")
        doAssert f.savePng(shots / "quality-file.png"), "file shot was not written"
    step("the File tab: statistics and one row per station", showFile, fileStats)

    proc folderTab(f: FrameInfo) = f.click(f.markOf("quality.tab Folder").centre)
    proc folderIdle(f: FrameInfo): bool =
      if not f.has("quality.folderbutton") and wait mod 8 == 4:
        f.click(f.markOf("quality.tab Folder").centre)
      result = f.has("quality.message folder") and f.has("quality.folderbutton")
      if result:
        doAssert not f.has("quality.scanning") and not f.has("quality.ready")
        for t in f.qualityJobs:
          doAssert t != "Trace quality in line", "a folder job before Run"
    step("the Folder tab starts nothing", folderTab, folderIdle)

    proc chooseFolder(f: FrameInfo) =
      asked.setLen 0
      answer = @[folder]
      f.click(f.markOf("quality.folderbutton").centre)
    proc folderChosen(f: FrameInfo): bool =
      result = f.has("quality.folderpath " & folder)
      if result:
        doAssert asked == @[dkQualityFolder], $asked
        doAssert f.core.settings.quality.folder == folder
        doAssert not f.core.settings.quality.subfolders, "subfolders is on by default"
        doAssert not f.has("quality.subfolderson")
        for t in f.qualityJobs:
          doAssert t != "Trace quality in line", "a folder job before Run"
    step("Folder... chooses the folder", chooseFolder, folderChosen)

    proc run(f: FrameInfo) = f.click(f.markOf("quality.run").centre)
    proc folderOff(f: FrameInfo): bool =
      result = f.has("quality.ready") and f.has("quality.counts 1 file, 5 traces")
      if result:
        doAssert f.said("Trace quality in line is done"), "the Folder run is announced"
        doAssert f.has("quality.stat Receiver stations in the files: 3"),
          $f.markNames("quality.stat ")
        doAssert f.has("quality.station 40 1 1 0 1 1 2 1"), $f.markNames("quality.station ")
        doAssert f.markNames("quality.station 100 ").len == 0, "the subfolder was read"
        doAssert f.savePng(shots / "quality-folder.png"), "folder shot was not written"
    step("Run: the folder without its subfolders", run, folderOff)

    proc tick(f: FrameInfo) = f.click(f.markOf("quality.subfolders").centre)
    proc dropped(f: FrameInfo): bool =
      result = f.core.settings.quality.subfolders and not f.has("quality.ready") and
        f.has("quality.message folder")
    step("Include subfolders drops the answer", tick, dropped)

    proc withSub(f: FrameInfo): bool =
      result = f.has("quality.ready") and f.has("quality.counts 2 files, 10 traces")
      if result:
        # station 40:1 is in both files: one row with the counts of both
        doAssert f.has("quality.station 40 1 2 0 2 2 2 2"), $f.markNames("quality.station ")
        doAssert f.has("quality.station 100 1 2 0 0 0 - 0"), $f.markNames("quality.station ")
        doAssert f.has("quality.stat Receiver stations in the files: 5"),
          $f.markNames("quality.stat ")
        doAssert f.has("quality.stat 1 receiver station lacks a component in at least one file " &
          "(of 2 components)"),
          $f.markNames("quality.stat ")
    step("Run with subfolders: a station counts over the files", run, withSub)

    var exportClicked = false
    proc exportCsv(f: FrameInfo) =
      asked.setLen 0
      answer = @[outCsv]
    proc exported(f: FrameInfo): bool =
      if not exportClicked and wait >= 2:
        f.click(f.markOf("quality.export").centre)
        exportClicked = true
      if not fileExists(outCsv): return false
      let rows = readFile(outCsv).splitLines
      doAssert rows[0] == "# Receiver stations", rows[0]
      doAssert rows[1].startsWith("line,point,lacking components,files lacking,seen,killed,bad,"),
          rows[0]
      doAssert rows[2].startsWith("40,1,2,2,2,0,2,"), rows[2]
      doAssert rows[3].startsWith("90,1,,0,2,0,0,"), rows[3]
      doAssert rows.len == 8 and rows[7] == "", $rows
      doAssert asked == @[dkExportQuality], "asked for " & $asked
      true
    step("Export CSV... writes the stations", exportCsv, exported)

    var refused = false
    let dataSize = getFileSize(folder / "one.sgd")
    proc exportOnData(f: FrameInfo) =
      asked.setLen 0
      answer = @[folder / "one.sgd"]
      f.click(f.markOf("quality.export").centre)
    proc exportRefused(f: FrameInfo): bool =
      result = f.has("quality.exported " & ExportIsData)
      if result: doAssert getFileSize(folder / "one.sgd") == dataSize, "a data file was written"
    step("Export CSV... refuses a file of the scan", exportOnData, exportRefused)

    proc sortBad(f: FrameInfo) = f.click(f.markOf("quality.header Bad").centre)
    proc sortedBad(f: FrameInfo): bool = f.has("quality.sort Bad")
    step("a click on Bad sorts by Bad", sortBad, sortedBad)

    var filterAt = vec2(0, 0)
    proc startFilter(f: FrameInfo) =
      filterAt = f.markOf("quality.filter").centre
      f.moveMouse(filterAt)
    proc filtered(f: FrameInfo): bool =
      if wait == 3: f.pressMouse(filterAt, true)
      if wait == 5: f.pressMouse(filterAt, false)
      if wait == 7: f.typeText("100")
      if wait < 14: return false
      result = f.has("quality.station 100 1 2 0 0 0 - 0") and
        not f.has("quality.station 90 1 2 0 0 0 - 0")
    step("the filter shows one station", startFilter, filtered)

    proc fileTab(f: FrameInfo) =
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "sub" / "two.sgd",
        listFolder: false)
    proc followsFile(f: FrameInfo): bool =
      if not f.has("quality.stat Traces: 5, 0 killed, 5 measured") and wait mod 8 == 4:
        f.click(f.markOf("quality.tab File").centre)
      result = f.has("quality.ready") and f.has("quality.stat Traces: 5, 0 killed, 5 measured")
      if result:
        # (the Folder tab's filter box says 100; this tab's box is its own, empty)
        doAssert f.has("quality.station 100 1 2 0 0 0 - 0") and
          f.has("quality.station 40 1 1 0 1 1 2 1") and
          not f.has("quality.station 90 1 2 0 0 0 - 0"), $f.markNames("quality.station ")
        doAssert f.has("quality.counts 5 traces")
    step("the File tab follows the file shown", fileTab, followsFile)

    proc unreadButton(f: FrameInfo): bool = f.has("quality.unread")
    step("the Unread button is there", noop, unreadButton)

    var closed = false
    proc closeIt(f: FrameInfo) = discard
    proc closedDone(f: FrameInfo): bool =
      if not closed and wait >= 3:
        let at = f.tabCloseAt("quality")
        doAssert at.x > 0, "no tab close button"
        f.click(at)
        closed = true
      result = closed and awQuality in f.hiddenWindows and not f.windowPlace("quality").inSight
    step("the window's close button hides it", closeIt, closedDone)

    var jobsBefore = 0
    proc showOther(f: FrameInfo) =
      jobsBefore = f.qualityJobs.len
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "one.sgd",
        listFolder: false)
    proc hiddenIdle(f: FrameInfo): bool =
      result = wait >= 15
      if result:
        doAssert f.qualityJobs.len == jobsBefore, "a job started for the file shown while the " &
          "window was hidden: " & $f.qualityJobs
    step("hidden: no job starts for the file shown", showOther, hiddenIdle)

    var shownAgain = false
    proc showAgain(f: FrameInfo) =
      f.click(f.markOf("menu.View").centre)
    proc returned(f: FrameInfo): bool =
      let item = f.markOf("menu.window.quality")
      if not shownAgain:
        if item.size.x > 0:
          f.click(item.centre)
          shownAgain = true
        elif wait mod 12 == 0:
          f.click(f.markOf("menu.View").centre)
      result = shownAgain and f.windowPlace("quality").inSight and f.has("quality.tab File")
    step("the View menu brings it back", showAgain, returned)

    proc measuresOnReturn(f: FrameInfo): bool =
      result = f.qualityJobs.len > jobsBefore and f.has("quality.ready")
    step("back in sight it measures the file then shown", noop, measuresOnReturn)

    proc backToFolder(f: FrameInfo) = f.click(f.markOf("quality.tab Folder").centre)
    proc folderKept(f: FrameInfo): bool =
      if not f.has("quality.counts 2 files, 10 traces") and wait mod 8 == 4:
        f.click(f.markOf("quality.tab Folder").centre)
      result = f.has("quality.counts 2 files, 10 traces")
    step("hiding kept the Folder answer", backToFolder, folderKept)

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
