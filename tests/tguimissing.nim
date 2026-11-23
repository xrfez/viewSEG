## Reports > Missing traces... in the running frontend, headless: the item is
## inactive until a folder is open and a relation file is loaded; the scan of
## that folder (subfolders included) matches an independent scan of the same
## files; the totals, the skipped file, a header sort, a CSV export and a
## double-click are what the window shows.
##
## Seen to fail: with the Reports item left enabled when no folder is open
## (no disabled mark), "Reports is inactive without a folder did not happen".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[filejobs, geometry, jobs, missingjobs, missingreport, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
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

proc filesOf(f: FrameInfo): int =
  ## The file count in the totals mark, or -1 when that mark is not drawn.
  result = -1
  for name in f.markNames("missing.totals "):
    let parts = name.split(' ')
    if parts.len > 1: return parseInt(parts[1])

proc main*() =
  var wait = 0
  var since = getMonoTime()

  withFixtures fx:
    let folder = fx.dir / "line"
    createDir(folder / "sub")
    copyFile(fx.stationsSegd(), folder / "one.sgd")
    copyFile(fx.stationsSegd(), folder / "two.sgd")
    copyFile(fx.stationsSegd(), folder / "sub" / "one.sgd")
    writeFile(folder / "notes.txt", "not seismic\n")
    let sps = fx.surveySps()
    let outCsv = fx.dir / "out" / "missing.csv"
    createDir(fx.dir / "out")
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let shots = currentSourcePath().parentDir.parentDir / ".scratch" / "shots"
    createDir(shots)

    var asked: seq[DialogKind]
    var answer: seq[string]
    var expected = ""
    var expectedCsv = ""
    var scanned = false
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      asked.add kind
      answer

    proc scanOnce(f: FrameInfo) =
      if scanned: return
      let layer = f.core.relationLayer
      doAssert layer >= 0, "no relation file"
      let relations = f.core.survey.layers[layer].relations
      let listed = $(f.core.fileList.folder)
      let cache = $(f.core.indexCache)
      var capped = false
      let paths = listedNames(@[listed], true, capped)
      let jobs = initJobs()
      let sink = MissingSink()
      let id = jobs.submit(missingSpec(listed, @[listed]),
        scanMissing(listed, paths, relations, sink, cache))
      doAssert waitUntil(jobs.info(id).get.state in {jsDone, jsFailed, jsCancelled}),
        "the independent scan did not finish"
      let info = jobs.info(id).get
      doAssert info.state == jsDone, info.error
      let t = sink.result.report.totals
      expected = "missing.totals " & $t.files & " " & $t.records & " " & $t.expected &
        " " & $t.present & " " & $t.missing & " " & $t.never & " " & $t.duplicates &
        " " & $t.extras & " " & $t.xpsWithoutData.len
      expectedCsv = pointsCsv(sink.result.report.points)
      doAssert t.files == 3, "independent scan saw " & $t.files & " files"
      doAssert sink.result.report.points.len > 0, "nothing missing to sort"
      doAssert sink.result.report.records.len > 0, "no record row to open"
      var skippedNotes = false
      for row in sink.result.skipped:
        if row.path == "notes.txt": skippedNotes = true
      doAssert skippedNotes, "notes.txt was not skipped: " & $sink.result.skipped
      scanned = true

    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard

    proc inactive(f: FrameInfo) = f.click(f.markOf("menu.Reports").centre)
    proc inactiveDone(f: FrameInfo): bool =
      f.markOf("menu.Missing traces...").size.x > 0 and
        f.markOf("menu.Missing traces.disabled").size.x > 0
    step("Reports is inactive without a folder", inactive, inactiveDone)

    proc listFolder(f: FrameInfo) =
      f.apply Command(kind: ckBrowse, paths: @[folder], showFirst: false)
    proc folderListed(f: FrameInfo): bool =
      not f.core.fileList.scanning and f.core.fileList.folder.len > 0
    step("the folder is listed", listFolder, folderListed)

    proc stillInactive(f: FrameInfo) =
      if f.markOf("menu.Missing traces...").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc stillInactiveDone(f: FrameInfo): bool =
      f.markOf("menu.Missing traces.disabled").size.x > 0
    step("still inactive without a relation file", stillInactive, stillInactiveDone)

    proc loadSurvey(f: FrameInfo) =
      f.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, sps.x])
    proc surveyLoaded(f: FrameInfo): bool = f.core.relationLayer >= 0
    step("the relation file is loaded", loadSurvey, surveyLoaded)

    var opened = false
    proc openReport(f: FrameInfo) =
      if f.markOf("menu.Missing traces...").size.x == 0:
        f.click(f.markOf("menu.Reports").centre)
    proc reportReady(f: FrameInfo): bool =
      if not opened:
        let it = f.markOf("menu.Missing traces...")
        if it.size.x > 0 and f.markOf("menu.Missing traces.disabled").size.x == 0:
          f.click(it.centre)
          opened = true
      f.markOf("missing.ready").size.x > 0 and f.markOf("missing.tab Folder").size.x > 0
    step("Reports > Missing traces...", openReport, reportReady)

    proc totalsMatch(f: FrameInfo): bool =
      scanOnce(f)
      result = f.markOf(expected).size.x > 0
      if result:
        doAssert f.savePng(shots / "missing-folder.png"), "folder shot was not written"
    step("the totals match an independent scan", noop, totalsMatch)

    proc openSkipped(f: FrameInfo) = f.click(f.markOf("missing.skipped").centre)
    proc skippedNames(f: FrameInfo): bool =
      for name in f.markNames("missing.skippedline "):
        if "notes.txt" in name: return true
    step("Skipped names notes.txt", openSkipped, skippedNames)

    var exportClicked = false
    proc exportCsv(f: FrameInfo) =
      asked.setLen 0
      answer = @[outCsv]
      f.click(vec2(8, 8)) # the skipped list is open; a click elsewhere closes it
    proc exported(f: FrameInfo): bool =
      if not exportClicked and wait >= 4:
        let b = f.markOf("missing.export")
        doAssert b.size.x > 0, "Export CSV... is not shown"
        f.click(b.centre)
        exportClicked = true
      if not fileExists(outCsv): return false
      let got = readFile(outCsv)
      doAssert got == expectedCsv, "csv differs, asked " & $asked & "\n" &
        got[0 ..< min(240, got.len)]
      doAssert asked == @[dkExportMissing], "asked for " & $asked
      true
    step("Export CSV... writes the points", exportCsv, exported)

    proc sortLine(f: FrameInfo) = f.click(f.markOf("missing.header Line").centre)
    proc sortedLine(f: FrameInfo): bool = f.markOf("missing.sort Line").size.x > 0
    step("a click on Line sorts by Line", sortLine, sortedLine)

    proc reverseLine(f: FrameInfo) = f.click(f.markOf("missing.header Line").centre)
    proc reversedLine(f: FrameInfo): bool = f.markOf("missing.sort Line-").size.x > 0
    step("a second click reverses Line", reverseLine, reversedLine)

    proc shiftPoint(f: FrameInfo) =
      f.pressKey(skShift, true, {smShift})
      f.click(f.markOf("missing.header Point").centre)
    proc shiftedPoint(f: FrameInfo): bool =
      result = f.markOf("missing.sort Line-,Point").size.x > 0
      if result: f.pressKey(skShift, false)
    step("Shift-click adds Point", shiftPoint, shiftedPoint)

    proc recordsTab(f: FrameInfo) = f.click(f.markOf("missing.tab Records").centre)
    proc recordsShown(f: FrameInfo): bool =
      if f.markOf("missing.record 0").size.x == 0 and wait mod 8 == 0:
        f.click(f.markOf("missing.tab Records").centre)
      result = f.markOf("missing.record 0").size.x > 0
      if result:
        doAssert f.savePng(shots / "missing-records.png"), "records shot was not written"
      elif wait > 20:
        var seen = ""
        for n in f.markNames("missing."): seen.add n & "; "
        let t = f.markOf("missing.tab Records")
        doAssert false, "tab " & $t.pos & " " & $t.size & " marks [" & seen & "]"
    step("the Records tab", recordsTab, recordsShown)

    proc openedFile(f: FrameInfo): bool =
      if f.core.sessions.len == 0:
        let row = f.markOf("missing.record 0")
        let q = vec2(row.pos.x + 12, round(row.pos.y + row.size.y / 2))
        case wait mod 12
        of 2: f.moveMouse(q)
        of 4: f.pressMouse(q, true)
        of 5: f.pressMouse(q, false)
        of 6: f.pressMouse(q, true)
        of 7: f.pressMouse(q, false)
        else: discard
      f.core.sessions.len > 0
    step("a double click opens the file", noop, openedFile)

    proc rescan(f: FrameInfo) =
      removeFile(folder / "two.sgd")
      f.click(f.markOf("missing.rescan").centre)
    proc rescanned(f: FrameInfo): bool =
      f.markOf("missing.ready").size.x > 0 and filesOf(f) == 2
    step("Rescan after a file is removed", rescan, rescanned)

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
    let code = run(RunOptions(windowSize: (1600, 1000), theme: forceDark, persist: true,
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
