## The Shot log window in the running frontend, headless: Project > Import shot
## log... reads the sample; the top line, row 0's time, a cell and a role line
## match; Allow editing starts off, so a double-click opens no box and Ctrl+Z
## does not undo a planted cell edit; ticked, a cell can be edited, escaped, and
## undone; Columns changes a role and
## flags a duplicated X; a filter and
## Problems only narrow the rows; another log clears the tick; removing the log
## leaves the window up.
## A generated log of 100 000 rows is then scrolled, and those frames stay
## under the budget the other GUI tests use.
## Follow the plot starts unticked: a hover (the command the plot sends for the
## trace under the pointer) does not move the grid. Ticked, the grid scrolls to
## the row whose time is that trace's and the status line names it; a hover
## with no match leaves the scroll and says so; two rows at one time say so.
## Allow editing stays off.
##
## Seen to fail: with the row 0 time left unmarked, "row 0 time was @[]".
## With editing left on (no tick), "a double-click opened a box while editing
## was off". With Ctrl+Z still taken while the tick was off, "Ctrl+Z undid a
## shot edit while editing was off".
## With follow applied while the tick was off, "a hover moved the grid while
## follow was off: edge 196 line Trace under the pointer: row 181, by time on 0".
## With the jump not scrolling, "the matched row was not shown: edge 30 line
## [Trace under the pointer: row 181, by time]". With a miss scrolling to row 0,
## "a miss did not leave the grid: edge 30 held 195 line [No row at this time]".
## With two rows scrolling to row 0, "two rows did not leave the grid: edge 30
## held 195 line [2 rows at this time]".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import parseSEG
import viewSEG/core/[geometry, recordtime, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    limit: int
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

func median(xs: seq[float64]): float64 =
  var s = xs
  s.sort()
  if s.len == 0: NaN else: s[s.len div 2]

proc roleCol(f: FrameInfo; label: string): int =
  ## The column whose role line is `label`, or -1.
  result = -1
  const prefix = "shotlog.role "
  for n in f.markNames(prefix):
    let rest = n[prefix.len .. ^1]
    let sp = rest.find(' ')
    if sp > 0 and rest[sp + 1 .. ^1] == label:
      return parseInt(rest[0 ..< sp])

proc edgeRow(f: FrameInfo): int =
  result = -1
  for n in f.markNames("shotlog.edge "):
    return parseInt(n["shotlog.edge ".len .. ^1])

proc summaryLine(f: FrameInfo): string =
  for n in f.markNames("shotlog.summary "):
    return n["shotlog.summary ".len .. ^1]

proc followLineOf(f: FrameInfo): string =
  const prefix = "shotlog.followline "
  for n in f.markNames(prefix):
    return n[prefix.len .. ^1]

proc writeFollowSegd(path: string) =
  ## Three records, one trace each, a hundred seconds apart.
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4))
  var samples = newSeq[float32](4)
  const times = [1_700_000_000.0, 1_700_000_100.0, 1_700_000_200.0]
  for i, t in times:
    var k = initTraceKeys()
    k.record = float64(i + 1)
    k.channel = 1
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = t
    k.status = tsLive
    w.writeTrace(k, samples)
  doAssert w.close().len == 0, "the follow SEG-D was not written"

proc recordTimes(path: string): array[3, int64] =
  ## The UTC microseconds the file actually stores, leap seconds included.
  var f = openSeismic(path)
  doAssert f.len == 3, "the follow SEG-D has " & $f.len & " traces"
  for i in 0 .. 2:
    let t = f.timeZeroOfRecord(i)
    doAssert t.isSome, "trace " & $i & " has no time"
    result[i] = t.get
  f.close()

proc writeFollowLog(path: string; times: array[3, int64]; rows, k: int) =
  ## Row `k` matches trace 2; rows 8 and 9 match trace 1; trace 0 matches none.
  var f = open(path, fmWrite)
  f.writeLine("shot point,UTC microseconds")
  for i in 0 ..< rows:
    var us = times[0] - 86_400_000_000 + int64(i)
    if i == 8 or i == 9: us = times[1]
    elif i == k: us = times[2]
    f.writeLine($(10_000 + i) & "," & $us)
  f.close()

proc writeBig(path: string; n: int) =
  var f = open(path, fmWrite)
  f.writeLine("shot point,X,Y")
  for i in 1 .. n:
    f.writeLine($i & "," & $i & ".5," & $(i + 1))
  f.close()

proc runOpts(fx: Fixtures; hook: DialogHook): RunOptions =
  RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
    configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"),
    userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
    dialogs: hook)

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let root = currentSourcePath().parentDir.parentDir
    let sample = root / "samples" / "land" / "shotlog.csv"
    let bad = fx.dir / "bad-shotlog.csv"
    let big = fx.dir / "big-shotlog.csv"
    writeFile(bad, "shot point,X,Y\n1,10,20\n2,not-a-number,21\n")
    writeBig(big, 100_000)
    let segd = fx.dir / "follow.sgd"
    let followLog = fx.dir / "follow-shotlog.csv"
    const followRows = 220
    const followRow = 180
    writeFollowSegd(segd)
    let times = recordTimes(segd)
    writeFollowLog(followLog, times, followRows, followRow)
    let gridShot = root / ".scratch" / "shotlog-grid.png"
    let dockedShot = root / ".scratch" / "shotlog-docked.png"
    let columnsShot = root / ".scratch" / "shotlog-columns.png"
    let editShot = root / ".scratch" / "shotlog-edit.png"
    let allowShot = root / ".scratch" / "shotlog-allow.png"
    createDir(gridShot.parentDir)

    block sampleLog:
      var nextPath = sample
      var asked: seq[DialogKind]
      let hook = proc (kind: DialogKind; location: string): seq[string] =
        asked.add kind
        if kind == dkShotLog: @[nextPath] else: @[]
      var steps: seq[Step]
      var wait = 0
      var since = getMonoTime()
      var yCol = -1
      var seqCol = -1
      var pointCol = -1
      var filterAt = vec2(0, 0)
      var why = ""
      var problemRow = ""
      proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
          limit = 400) =
        steps.add Step(name: name, limit: limit, act: act, done: done)
      proc noop(f: FrameInfo) = discard
      proc doubleClick(f: FrameInfo; at: Vec2; n: int) =
        if n == 2: f.moveMouse(at)
        if n == 3: f.pressMouse(at, true)
        if n == 4: f.pressMouse(at, false)
        if n == 5: f.pressMouse(at, true)
        if n == 6: f.pressMouse(at, false)

      step("the bar", proc (f: FrameInfo) =
        f.resizeWindow(1920, 1080)
        f.keepInMainWindow(),
        proc (f: FrameInfo): bool =
          f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080))
      step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
        proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
      step("import the sample", proc (f: FrameInfo) =
        f.click(f.markOf("menu.Import shot log...").centre),
        proc (f: FrameInfo): bool =
          let line = f.summaryLine
          result = "shotlog.csv" in line and "200 rows" in line and "22 columns" in line and
            line.endsWith("session only") and f.windowPlace("shotlog").inSight
          if result:
            doAssert asked == @[dkShotLog], "asked for " & $asked
            doAssert f.windowPlace("shotlog").docked, "the Shot log is not docked"
            doAssert f.savePng(dockedShot), "the docked screenshot was not written"
        , 2000)
      step("room for the columns", proc (f: FrameInfo) =
        # a tab beside Headers shows two columns: the window is floated to read the others
        f.arrangeWindows(f.layoutText & "[Window][###shotlog]\nPos=20,80\nSize=1500,850\n" &
          "Collapsed=0\n\n[viewSEG][Windows]\nHidden=aux,missing,quality,vibfolder,output\n\n"),
        proc (f: FrameInfo): bool =
          let point = roleCol(f, "shot point")
          result = f.windowPlace("shotlog").inSight and not f.windowPlace("shotlog").docked and
            point >= 0 and
            ("shotlog.cell 0 " & $point & " 1000") in f.markNames("shotlog.cell 0 ") and
            f.markNames("shotlog.time 0 2024-03-01 00:00:00.000000").len > 0
          if result:
            pointCol = point
            doAssert f.savePng(gridShot), "the grid screenshot was not written"
        , 2000)

      var pointAt = vec2(0, 0)
      var fileCol = -1
      var fileAt = vec2(0, 0)
      var planted = 0.0
      step("double-click edits nothing", proc (f: FrameInfo) =
        pointAt = f.markOf("shotlog.cell 0 " & $pointCol & " 1000").centre
        f.moveMouse(pointAt),
        proc (f: FrameInfo): bool =
          f.doubleClick(pointAt, wait)
          if f.markOf("shotlog.editbox").size.x > 0:
            doAssert false, "a double-click opened a box while editing was off"
          if wait < 12: return false
          f.markOf("shotlog.allowbox").size.x > 0 and
            f.markNames("shotlog.allowon").len == 0 and
            f.markOf("shotlog.undo").size.x == 0 and
            ("shotlog.cell 0 " & $pointCol & " 1000") in f.markNames("shotlog.cell 0 "))
      step("plant a cell edit", proc (f: FrameInfo) =
        planted = f.core.shotView(0).rows[1].shotPoint
        let cmd = Command(kind: ckEditShotCell, logIndex: 0, logRow: 1,
          logCol: pointCol, logCell: "7777")
        f.apply(cmd),
        proc (f: FrameInfo): bool =
          f.core.shotView(0).rows[1].shotPoint == 7777.0)
      step("Ctrl+Z leaves the edit", proc (f: FrameInfo) =
        f.pressKey(skCtrl, true, {smCtrl})
        f.pressKey(skZ, true, {smCtrl}),
        proc (f: FrameInfo): bool =
          if wait == 4:
            f.pressKey(skZ, false, {smCtrl})
            f.pressKey(skCtrl, false)
          if f.core.shotView(0).rows[1].shotPoint != 7777.0:
            doAssert false, "Ctrl+Z undid a shot edit while editing was off"
          if wait < 10: return false
          result = f.core.shotView(0).rows[1].shotPoint == 7777.0 and planted != 7777.0)
      step("Allow editing", proc (f: FrameInfo) =
        f.click(f.markOf("shotlog.allowbox").centre),
        proc (f: FrameInfo): bool =
          if f.markNames("shotlog.allowon").len == 0 and wait mod 8 == 0:
            f.click(f.markOf("shotlog.allowbox").centre)
          f.markNames("shotlog.allowon").len > 0 and f.markOf("shotlog.undo").size.x > 0)
      step("edit a cell", proc (f: FrameInfo) =
        pointAt = f.markOf("shotlog.cell 0 " & $pointCol & " 1000").centre
        f.moveMouse(pointAt),
        proc (f: FrameInfo): bool =
          f.doubleClick(pointAt, wait)
          f.markOf("shotlog.editbox").size.x > 0 and f.typing)
      var typed = false
      step("type and Enter", proc (f: FrameInfo) =
        typed = false,
        proc (f: FrameInfo): bool =
          if not typed and f.typing and
              f.markNames("shotlog.edittext 1000").len > 0:
            f.typeText("4242")
            typed = true
          if typed and f.markNames("shotlog.edittext 4242").len > 0:
            if wait mod 8 == 0: f.pressKey(skEnter, true)
            if wait mod 8 == 1: f.pressKey(skEnter, false)
          why = $f.markNames("shotlog.edittext ")
          if wait < 8: return false
          let cell = "shotlog.cell 0 " & $pointCol & " 4242"
          cell in f.markNames("shotlog.cell 0 ") and
            f.core.shotView(0).rows[0].shotPoint == 4242.0 and
            f.markNames("shotlog.edited 0 " & $pointCol).len > 0
      , 2000)
      step("open another cell", proc (f: FrameInfo) =
        fileCol = roleCol(f, "file number")
        fileAt = f.markOf("shotlog.cell 0 " & $fileCol & " 5000").centre
        f.moveMouse(fileAt),
        proc (f: FrameInfo): bool =
          if fileCol < 0: return false
          f.doubleClick(fileAt, wait)
          if f.markOf("shotlog.editbox").size.x > 0 and
              f.markNames("shotlog.edited 0 " & $pointCol).len > 0 and
              f.markNames("shotlog.allowon").len > 0:
            doAssert f.savePng(editShot), "the edit screenshot was not written"
            doAssert f.savePng(allowShot), "the allow-editing screenshot was not written"
            return true
          false)
      var escaped = false
      step("Escape leaves it", proc (f: FrameInfo) =
        escaped = false,
        proc (f: FrameInfo): bool =
          if not escaped and f.typing and
              f.markNames("shotlog.edittext 5000").len > 0:
            f.typeText("9999")
            escaped = true
          if f.markNames("shotlog.edittext 9999").len > 0:
            if wait mod 8 == 0: f.pressKey(skEscape, true)
            if wait mod 8 == 1: f.pressKey(skEscape, false)
          if wait < 8: return false
          ("shotlog.cell 0 " & $fileCol & " 5000") in f.markNames("shotlog.cell 0 ") and
            f.markOf("shotlog.editbox").size.x == 0)
      step("Ctrl+Z restores", proc (f: FrameInfo) =
        f.pressKey(skCtrl, true, {smCtrl})
        f.pressKey(skZ, true, {smCtrl}),
        proc (f: FrameInfo): bool =
          if wait == 4:
            f.pressKey(skZ, false, {smCtrl})
            f.pressKey(skCtrl, false)
          if wait < 6: return false
          ("shotlog.cell 0 " & $pointCol & " 1000") in f.markNames("shotlog.cell 0 ") and
            f.core.shotView(0).rows[0].shotPoint == 1000.0
      , 2000)

      step("Columns...", proc (f: FrameInfo) = f.click(f.markOf("shotlog.columns").centre),
        proc (f: FrameInfo): bool =
        if f.markOf("shotlog.guess").size.x == 0 and wait mod 8 == 0:
          f.click(f.markOf("shotlog.columns").centre)
        yCol = roleCol(f, "Y")
        pointCol = roleCol(f, "shot point")
        yCol >= 0 and pointCol >= 0 and f.markOf("shotlog.guess").size.x > 0)
      step("shot point becomes X", proc (f: FrameInfo) =
        f.click(f.markOf("shotlog.rolecombo " & $pointCol).centre),
        proc (f: FrameInfo): bool =
          let item = f.markOf("shotlog.roleitem " & $pointCol & " X")
          if item.size.x > 0 and wait == 4: f.click(item.centre)
          if f.markNames("shotlog.duplicate X").len > 0:
            doAssert f.savePng(columnsShot), "the columns screenshot was not written"
            return true
          false)
      step("Cancel", proc (f: FrameInfo) = f.click(f.markOf("shotlog.cancel").centre),
        proc (f: FrameInfo): bool =
        if f.markOf("shotlog.cancel").size.x > 0 and wait mod 8 == 0:
          f.click(f.markOf("shotlog.cancel").centre)
        f.markOf("shotlog.grid").size.x > 0 and roleCol(f, "shot point") == pointCol)

      step("Columns again", proc (f: FrameInfo) = f.click(f.markOf("shotlog.columns").centre),
        proc (f: FrameInfo): bool =
        if f.markOf("shotlog.guess").size.x == 0 and wait mod 8 == 0:
          f.click(f.markOf("shotlog.columns").centre)
        seqCol = roleCol(f, "sequence")
        seqCol >= 0 and f.markOf("shotlog.rolecombo " & $seqCol).size.x > 0)
      step("sequence becomes ignored", proc (f: FrameInfo) =
        f.click(f.markOf("shotlog.rolecombo " & $seqCol).centre),
        proc (f: FrameInfo): bool =
          let item = f.markOf("shotlog.roleitem " & $seqCol & " ignored")
          if item.size.x > 0 and wait == 4: f.click(item.centre)
          roleCol(f, "ignored") == seqCol)
      step("Apply", noop, proc (f: FrameInfo): bool =
        if f.markOf("shotlog.apply").size.x > 0 and wait mod 8 == 0:
          f.click(f.markOf("shotlog.apply").centre)
        f.markOf("shotlog.grid").size.x > 0 and roleCol(f, "ignored") == seqCol
      , 2000)

      step("the filter", proc (f: FrameInfo) =
        filterAt = f.markOf("shotlog.filter").centre
        f.moveMouse(filterAt), proc (f: FrameInfo): bool =
        if wait == 3: f.pressMouse(filterAt, true)
        if wait == 5: f.pressMouse(filterAt, false)
        if wait == 7: f.typeText("5000")
        if wait < 20: return false
        "shotlog.filtered 1" in f.markNames("shotlog.filtered ")
      , 2000)

      step("Project again", proc (f: FrameInfo) =
        nextPath = bad
        f.click(f.markOf("menu.Project").centre),
        proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
      step("import a bad row", proc (f: FrameInfo) =
        f.click(f.markOf("menu.Import shot log...").centre),
        proc (f: FrameInfo): bool =
          let line = f.summaryLine
          "bad-shotlog.csv" in line and "2 rows" in line and not line.endsWith("0 problems") and
            line.endsWith("session only") and f.markNames("shotlog.allowon").len == 0 and
            f.markOf("shotlog.allowbox").size.x > 0
        , 2000)
      step("Problems only", proc (f: FrameInfo) =
        f.click(f.markOf("shotlog.problemsbox").centre),
        proc (f: FrameInfo): bool =
          if f.markNames("shotlog.problemsonly").len == 0 and wait mod 8 == 0:
            f.click(f.markOf("shotlog.problemsbox").centre)
          f.markNames("shotlog.problemsonly").len > 0 and
            "shotlog.listed 1" in f.markNames("shotlog.listed "))
      step("Problems", proc (f: FrameInfo) =
        f.click(f.markOf("shotlog.tab Problems").centre),
        proc (f: FrameInfo): bool =
          if f.markNames("shotlog.problem ").len == 0 and wait mod 8 == 0:
            let tab = f.markOf("shotlog.tab Problems")
            why = "tab " & $tab & " empty " & $f.markNames("shotlog.noproblems").len
            f.click(tab.centre)
          f.markNames("shotlog.problem ").len > 0)
      proc clickProblem(f: FrameInfo) =
        let n = f.markNames("shotlog.problem ")
        if n.len == 0: return
        problemRow = n[0]["shotlog.problem ".len .. ^1]
        f.click(f.markOf(n[0]).centre)
      step("a problem shows its row", clickProblem, proc (f: FrameInfo): bool =
        if problemRow.len == 0: return false
        if f.markNames("shotlog.at " & problemRow).len == 0 and
            f.markNames("shotlog.problem ").len > 0 and wait mod 8 == 0:
          clickProblem(f)
        why = "at " & problemRow & " grid " & $f.markOf("shotlog.grid").size.x
        f.markOf("shotlog.grid").size.x > 0 and
          f.markNames("shotlog.at " & problemRow).len > 0)

      proc removeLogs(f: FrameInfo) =
        while f.core.shotLogCount > 0:
          f.apply Command(kind: ckRemoveShotLog, logIndex: 0)
      step("the log removed", removeLogs, proc (f: FrameInfo): bool =
        f.core.shotLogCount == 0 and f.markOf("shotlog").size.x > 0 and
          f.summaryLine.startsWith("No shot log is loaded.") and
          f.summaryLine.endsWith("session only"))

      var at = 0
      var started = false
      var failed = ""
      proc onFrame(f: FrameInfo) =
        if f.index == 0: f.keepInMainWindow()
        if at >= steps.len or failed.len > 0:
          f.stop()
          return
        if not started:
          steps[at].act(f)
          started = true
          (wait, since) = (0, getMonoTime())
        else:
          inc wait
          if wait >= 3 and steps[at].done(f):
            inc at
            started = false
          elif overdue(wait, steps[at].limit, since):
            failed = steps[at].name & " did not happen: " & f.summaryLine & " " & why
            f.stop()
      var opts = runOpts(fx, hook)
      opts.onFrame = onFrame
      let code = run(opts)
      doAssert code == 0, "run() exit code " & $code
      doAssert failed.len == 0, failed
      doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
      echo "tguishotlog: ", steps.len, " steps"

    block hundredThousand:
      var stage = 0
      var wait = 0
      var since = getMonoTime()
      var last = getMonoTime()
      var idle, scrolling: seq[float64]
      var reached = false
      let hook = proc (kind: DialogKind; location: string): seq[string] =
        if kind == dkShotLog: @[big] else: @[]
      proc onFrame(f: FrameInfo) =
        let now = getMonoTime()
        let ms = float64((now - last).inMicroseconds) / 1000
        last = now
        inc wait
        template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
        if f.index == 0: f.keepInMainWindow()
        case stage
        of 0:
          if f.markOf("menu.Project").size.x > 0 and wait > 3:
            f.click(f.markOf("menu.Project").centre)
            next 1
          doAssert not overdue(wait, 400, since), "the bar was not shown"
        of 1:
          if f.markOf("menu.Import shot log...").size.x > 0:
            f.click(f.markOf("menu.Import shot log...").centre)
            next 2
          doAssert not overdue(wait, 400, since), "Import shot log was not shown"
        of 2:
          let line = f.summaryLine
          if "100000 rows" in line and f.markOf("shotlog.grid").size.x > 0:
            f.moveMouse(f.markOf("shotlog.grid").centre)
            next 3
          doAssert not overdue(wait, 2000, since), "the 100000-row log was not shown: " & line
        of 3:
          if wait > 5: idle.add ms
          if wait == 40: next 4
        of 4:
          if wait > 1: scrolling.add ms
          let grid = f.markOf("shotlog.grid")
          f.scrollWheel(grid.centre, -4000)
          if edgeRow(f) == 99_999: reached = true
          if wait == 80:
            doAssert reached, "the table did not scroll to the last row: edge " & $edgeRow(f)
            f.stop()
        else: discard
      var opts = runOpts(fx, hook)
      opts.onFrame = onFrame
      let code = run(opts)
      doAssert code == 0, "run() exit code " & $code
      doAssert stage == 4, "stopped at stage " & $stage
      let (mi, ms) = (median(idle), median(scrolling))
      echo "tguishotlog: 100000 rows: idle median ", formatFloat(mi, ffDecimal, 1),
        " ms; scrolling median ", formatFloat(ms, ffDecimal, 1), " ms (slowest ",
        formatFloat(scrolling.max, ffDecimal, 1), ")"
      doAssert ms < 33 and ms < mi + 15, "the shot log lags: " & $ms & " ms a frame, idle " & $mi

    block followPlot:
      let followShot = root / ".scratch" / "shotlog-follow.png"
      let want = "Trace under the pointer: row " & $(followRow + 1) & ", by time"
      var stage = 0
      var wait = 0
      var since = getMonoTime()
      var oneId, twoId, noneId = -1
      var matchedEdge = -1
      var lastEdge = -2
      var same = 0
      var why = ""
      let hook = proc (kind: DialogKind; location: string): seq[string] =
        if kind == dkShotLog: @[followLog] else: @[]
      proc onFrame(f: FrameInfo) =
        inc wait
        template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
        if f.index == 0: f.keepInMainWindow()
        case stage
        of 0:
          if f.markOf("menu.Project").size.x > 0 and f.core.sessions.len > 0 and
              f.core.sessions[0].len == 3 and f.markOf("plot.data").size.x > 0 and wait > 3:
            let base = f.core.sessions[0].base
            noneId = base
            twoId = base + 1
            oneId = base + 2
            f.moveMouse(f.markOf("plot.data").centre)
            next 1
          doAssert not overdue(wait, 2000, since), "the follow file was not shown"
        of 1:
          if wait == 2: f.moveMouse(vec2(4, 4))
          if wait == 6:
            f.apply(Command(kind: ckHover, trace: oneId))
            next 2
        of 2:
          if f.markOf("menu.Project").size.x > 0 and wait > 2:
            f.click(f.markOf("menu.Project").centre)
            next 3
          doAssert not overdue(wait, 400, since), "Project was not shown"
        of 3:
          if f.markOf("menu.Import shot log...").size.x > 0:
            f.click(f.markOf("menu.Import shot log...").centre)
            next 4
          doAssert not overdue(wait, 400, since), "Import shot log was not shown"
        of 4:
          let line = f.summaryLine
          if "follow-shotlog.csv" in line and "220 rows" in line and
              f.markOf("shotlog.grid").size.x > 0 and f.markOf("shotlog.followbox").size.x > 0:
            f.apply(Command(kind: ckHover, trace: oneId))
            next 5
          doAssert not overdue(wait, 2000, since), "the follow log was not shown: " & line
        of 5:
          let edge = edgeRow(f)
          why = "edge " & $edge & " line " & followLineOf(f) & " on " &
            $f.markNames("shotlog.followon").len
          if edge >= 0 and edge < followRow and followLineOf(f).len == 0 and
              f.markNames("shotlog.followon").len == 0 and
              f.markNames("shotlog.at " & $followRow).len == 0 and
              f.markNames("shotlog.allowon").len == 0 and wait > 4:
            f.click(f.markOf("shotlog.followbox").centre)
            next 6
          doAssert not overdue(wait, 400, since),
            "a hover moved the grid while follow was off: " & why
        of 6:
          if f.markNames("shotlog.followon").len == 0 and wait mod 8 == 0:
            f.click(f.markOf("shotlog.followbox").centre)
          let edge = edgeRow(f)
          if edge == lastEdge: inc same else: same = 0
          lastEdge = edge
          why = "edge " & $edge & " line [" & followLineOf(f) & "]"
          if edge >= followRow and same >= 3 and followLineOf(f) == want and
              f.markNames("shotlog.at " & $followRow).len > 0 and
              f.markNames("shotlog.allowon").len == 0 and wait > 2:
            matchedEdge = edge
            doAssert f.savePng(followShot), "the follow screenshot was not written"
            f.apply(Command(kind: ckHover, trace: noneId))
            next 7
          doAssert not overdue(wait, 400, since), "the matched row was not shown: " & why
        of 7:
          let edge = edgeRow(f)
          why = "edge " & $edge & " held " & $matchedEdge & " line [" & followLineOf(f) & "]"
          if followLineOf(f) == "No row at this time" and edge == matchedEdge and
              f.markNames("shotlog.allowon").len == 0 and wait > 2:
            f.apply(Command(kind: ckHover, trace: twoId))
            next 8
          doAssert not overdue(wait, 400, since), "a miss did not leave the grid: " & why
        of 8:
          let edge = edgeRow(f)
          why = "edge " & $edge & " held " & $matchedEdge & " line [" & followLineOf(f) & "]"
          if followLineOf(f) == "2 rows at this time" and edge == matchedEdge and
              f.markNames("shotlog.allowon").len == 0 and wait > 2:
            f.stop()
          doAssert not overdue(wait, 400, since), "two rows did not leave the grid: " & why
        else: discard
      var opts = runOpts(fx, hook)
      opts.openPaths = @[segd]
      opts.onFrame = onFrame
      let code = run(opts)
      doAssert code == 0, "run() exit code " & $code
      doAssert stage == 8, "stopped at stage " & $stage & " " & why
      echo "tguishotlog: follow row ", followRow + 1

when isMainModule:
  main()
