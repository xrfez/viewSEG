## The Shot log window in the running frontend, headless: Project > Import shot
## log... reads the sample; the top line, row 0's time, a cell and a role line
## match; Columns changes a role and flags a duplicated X; a filter and
## Problems only narrow the rows; removing the log leaves the window up.
## A generated log of 100 000 rows is then scrolled, and those frames stay
## under the budget the other GUI tests use.
##
## Seen to fail: with the row 0 time left unmarked, "row 0 time was @[]".
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[algorithm, math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
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
    let gridShot = root / ".scratch" / "shotlog-grid.png"
    let columnsShot = root / ".scratch" / "shotlog-columns.png"
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
          let point = roleCol(f, "shot point")
          if "shotlog.csv" in line and "200 rows" in line:
            doAssert f.markNames("shotlog.time 0 2024-03-01 00:00:00.000000").len > 0,
              "row 0 time was " & $f.markNames("shotlog.time 0 ")
          result = "shotlog.csv" in line and "200 rows" in line and "22 columns" in line and
            line.endsWith("session only") and point >= 0 and
            ("shotlog.cell 0 " & $point & " 1000") in f.markNames("shotlog.cell 0 ") and
            f.markNames("shotlog.time 0 2024-03-01 00:00:00.000000").len > 0
          if result:
            pointCol = point
            doAssert asked == @[dkShotLog], "asked for " & $asked
            doAssert f.savePng(gridShot), "the grid screenshot was not written"
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
            line.endsWith("session only")
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

when isMainModule:
  main()
