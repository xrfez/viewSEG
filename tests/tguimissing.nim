## Reports > Missing traces... in the running frontend, headless: the window is
## closed at the start and then a tab beside the Seismic window; with no
## relation records it says what to import and shows no table; with a file
## shown it computes only the File tab (no job lists a folder), and the tab
## has the statistics lines and the table of Line, Point, Missing (no record
## column); the Folder tab starts nothing until Run, takes the folder from the
## dialog, honours Include subfolders (off by default; changing it drops the
## answer), exports the list, the File tab follows the file shown, and the
## window closes by its tab's button and returns from the View menu.
##
## Seen to fail: with the Folder tab's job started as soon as a folder is chosen,
## "Folder... chooses the folder" found a folder job before Run; with the
## subfolders tick ignored by the walk, "Run: the folder without its subfolders"
## did not happen (3 files, not 2).
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, jobs, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[missingwords, theme]
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

proc put(line: var string; at: int; text: string) =
  let i = at - 1
  for j, c in text:
    if i + j < line.len: line[i + j] = c

proc xRec(record: int; srcPoint: string; toCh, fromR, toR: int): string =
  result = repeat(' ', 80)
  result[0] = 'X'
  put(result, 2, "T1")
  put(result, 8, align($record, 8))
  put(result, 16, "11")
  put(result, 18, align("1.00", 10))
  put(result, 28, align(srcPoint, 10))
  put(result, 38, "1")
  put(result, 39, align("1", 5))
  put(result, 44, align($toCh, 5))
  put(result, 49, "1")
  put(result, 50, align("10.00", 10))
  put(result, 60, align($fromR & ".00", 10))
  put(result, 70, align($toR & ".00", 10))
  put(result, 80, "1")

proc shotFile(path: string; receivers: Slice[int]) =
  ## One shot record (field record 1, source 1.00 / 1.00) with a trace at each receiver.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000,
    numSamples: 1, time: 1_700_000_000.0))
  var ch = 1
  for point in receivers:
    var k = initTraceKeys()
    k.record = 1
    k.channel = float64(ch)
    k.srcLine = 1
    k.srcPoint = 1
    k.srcIndex = 1
    k.rcvLine = 10
    k.rcvPoint = float64(point)
    k.rcvIndex = 1
    k.intervalUs = 2000
    k.status = tsLive
    w.writeTrace(k, @[0'f32])
    inc ch
  doAssert w.close().len == 0, "shot file was not written: " & path

proc main*() =
  var wait = 0
  var since = getMonoTime()

  withFixtures fx:
    let folder = fx.dir / "line"
    createDir(folder / "sub")
    shotFile(folder / "one.sgd", 1 .. 2)
    shotFile(folder / "two.sgd", 1 .. 3)
    shotFile(folder / "sub" / "three.sgd", 1 .. 4)
    writeFile(folder / "notes.txt", "not seismic\n")
    let plan = fx.dir / "plan.x"
    writeFile(plan, "H00 SPS format version number   SPS 2.1;\n" & xRec(1, "1.00", 4, 1, 4) & "\n")
    let outCsv = fx.dir / "out" / "missing.csv"
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

    step("closed at the start", noop, proc (f: FrameInfo): bool =
      result = wait > 4
      if result:
        doAssert awMissing in f.hiddenWindows, $f.hiddenWindows
        doAssert not f.windowPlace("missing").inSight)

    var opened = false
    proc openReport(f: FrameInfo) =
      if f.markOf("menu.Missing traces...").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc noTemplate(f: FrameInfo): bool =
      if not opened:
        let it = f.markOf("menu.Missing traces...")
        if it.size.x > 0:
          doAssert not f.has("menu.Missing traces.disabled"), "the menu item is inactive"
          f.click(it.centre)
          opened = true
      result = f.has("missing.tab File") and f.has("missing.message " & NoTemplate)
      if result:
        let (m, p) = (f.windowPlace("missing"), f.windowPlace("plot"))
        doAssert m.inSight and m.docked and not m.apart, "not in the centre dock: " & $m
        doAssert abs(m.rect.pos.x - p.rect.pos.x) <= 2 and abs(m.rect.pos.y - p.rect.pos.y) <= 2,
          "not a tab beside the Seismic window: " & $m.rect & " plot " & $p.rect
        doAssert f.markNames("missing.row ").len == 0 and not f.has("missing.header Line"),
          "a table without relation records"
    step("no relation records: one sentence and no table", openReport, noTemplate)

    proc showFile(f: FrameInfo) =
      f.apply Command(kind: ckLoadSurvey, paths: @[plan])
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "one.sgd",
        listFolder: true)
    proc fileStats(f: FrameInfo): bool =
      result = f.has("missing.ready") and f.has("missing.header Missing")
      if result:
        for line in ["Receiver stations expected by the X records.",
            "Receiver stations in the template: 4", "Receiver stations found in the file: 2",
            "Receiver stations missing: 2", "Percent of the template missing: 50%"]:
          doAssert f.has("missing.stat " & line), "no line " & line & " in " &
            $f.markNames("missing.stat ")
        doAssert f.markNames("missing.stat Counted per record").len == 0,
          "per record figures for one record"
        doAssert f.has("missing.counts 1 record")
        doAssert f.has("missing.row 10 3 1") and f.has("missing.row 10 4 1"),
          $f.markNames("missing.row ")
        var headers: seq[string] = @[]
        for n in f.markNames("missing.header "): headers.add n
        doAssert headers.len == 3 and "missing.header Line" in headers and
          "missing.header Point" in headers and "missing.header Missing" in headers,
          "columns: " & $headers
        for t in f.jobTitles:
          doAssert t != "Missing traces in line",
            "the window computes the file only, a job for the folder: " & t
        doAssert f.has("missing.statsbox")
        doAssert f.savePng(shots / "missing-file.png"), "file shot was not written"
    step("the File tab: statistics and Line, Point, Missing", showFile, fileStats)

    proc folderTab(f: FrameInfo) = f.click(f.markOf("missing.tab Folder").centre)
    proc folderIdle(f: FrameInfo): bool =
      if not f.has("missing.folderbutton") and wait mod 8 == 4:
        f.click(f.markOf("missing.tab Folder").centre)
      result = f.has("missing.message folder") and f.has("missing.folderbutton")
      if result:
        doAssert not f.has("missing.scanning") and not f.has("missing.ready")
        for t in f.jobTitles:
          doAssert t != "Missing traces in line", "a folder job before Run"
    step("the Folder tab starts nothing", folderTab, folderIdle)

    proc chooseFolder(f: FrameInfo) =
      asked.setLen 0
      answer = @[folder]
      f.click(f.markOf("missing.folderbutton").centre)
    proc folderChosen(f: FrameInfo): bool =
      result = f.has("missing.folderpath " & folder)
      if result:
        doAssert asked == @[dkMissingFolder], $asked
        doAssert f.core.settings.missing.folder == folder
        doAssert not f.core.settings.missing.subfolders, "subfolders is on by default"
        doAssert not f.has("missing.subfolderson")
        for t in f.jobTitles:
          doAssert t != "Missing traces in line", "a folder job before Run"
    step("Folder... chooses the folder", chooseFolder, folderChosen)

    proc run(f: FrameInfo) = f.click(f.markOf("missing.run").centre)
    proc folderOff(f: FrameInfo): bool =
      result = f.has("missing.ready") and f.has("missing.counts 2 files, 2 records")
      if result:
        for line in ["Receiver stations in the template: 4",
            "Receiver stations found in the files: 3",
            "Receiver stations missing: 2",
            "Counted per record, each station once for each record that calls for it: " &
            "8 expected, 5 present, 3 missing, 37.50% missing"]:
          doAssert f.has("missing.stat " & line), "no line " & line & " in " &
            $f.markNames("missing.stat ")
        doAssert f.has("missing.row 10 3 1") and f.has("missing.row 10 4 2"),
          $f.markNames("missing.row ")
        doAssert f.savePng(shots / "missing-folder.png"), "folder shot was not written"
    step("Run: the folder without its subfolders", run, folderOff)

    proc tick(f: FrameInfo) = f.click(f.markOf("missing.subfolders").centre)
    proc dropped(f: FrameInfo): bool =
      result = f.core.settings.missing.subfolders and not f.has("missing.ready") and
        f.has("missing.message folder")
    step("Include subfolders drops the answer", tick, dropped)

    proc withSub(f: FrameInfo): bool =
      result = f.has("missing.ready") and f.has("missing.counts 3 files, 3 records")
      if result:
        doAssert f.has("missing.stat Counted per record, each station once for each " &
          "record that calls for it: 12 expected, 9 present, 3 missing, 25% missing"),
          $f.markNames("missing.stat ")
    step("Run with subfolders", run, withSub)

    var exportClicked = false
    proc exportCsv(f: FrameInfo) =
      asked.setLen 0
      answer = @[outCsv]
    proc exported(f: FrameInfo): bool =
      if not exportClicked and wait >= 2:
        f.click(f.markOf("missing.export").centre)
        exportClicked = true
      if not fileExists(outCsv): return false
      let got = readFile(outCsv)
      doAssert got == "line,point,missing\n10,3,1\n10,4,2\n", got
      doAssert asked == @[dkExportMissing], "asked for " & $asked
      true
    step("Export CSV... writes Line, Point, Missing", exportCsv, exported)

    proc fileTab(f: FrameInfo) =
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: folder / "two.sgd",
        listFolder: false)
    proc followsFile(f: FrameInfo): bool =
      if not f.has("missing.row 10 4 1") and wait mod 8 == 4:
        f.click(f.markOf("missing.tab File").centre)
      result = f.has("missing.ready") and f.has("missing.stat Receiver stations found in the file: 3")
      if result:
        doAssert f.has("missing.stat Receiver stations missing: 1")
        doAssert f.has("missing.row 10 4 1") and not f.has("missing.row 10 3 1"),
          $f.markNames("missing.row ")
    step("the File tab follows the file shown", fileTab, followsFile)

    var closed = false
    proc closeIt(f: FrameInfo) = discard
    proc closedDone(f: FrameInfo): bool =
      if not closed and wait >= 3:
        let at = f.tabCloseAt("missing")
        doAssert at.x > 0, "no tab close button"
        f.click(at)
        closed = true
      result = closed and awMissing in f.hiddenWindows and not f.windowPlace("missing").inSight
    step("the window's close button hides it", closeIt, closedDone)

    var shownAgain = false
    proc showAgain(f: FrameInfo) =
      f.click(f.markOf("menu.View").centre)
    proc returned(f: FrameInfo): bool =
      let item = f.markOf("menu.window.missing")
      if not shownAgain:
        if item.size.x > 0:
          f.click(item.centre)
          shownAgain = true
        elif wait mod 12 == 0:
          f.click(f.markOf("menu.View").centre)
      result = shownAgain and f.windowPlace("missing").inSight and f.has("missing.tab File")
    step("the View menu brings it back", showAgain, returned)

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
    echo "tguimissing: ", steps.len, " steps"

when isMainModule:
  main()
