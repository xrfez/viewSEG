## Choosing a shot on the map, in the running frontend, headless, with real clicks. A
## time-sliced receiver gather of five traces is open and a shot log of 120 rows is
## imported through Project > Import shot log...; its rows 40 and 100 are one shot taken
## twice (the same line, point and position), and the file's traces are the shots of rows
## 2, 40, 70, 100 and 110.
##
## - A click on the twice-taken shot's point chooses rows 40 and 100 (the grid marks them,
##   the status of the choice is the program's `shotRowsChosen`), selects traces 1 and 3 of
##   the file (rows 40 and 100's shot) and shows their record.
## - With Follow the pointer on (the Headers window's option), the grid scrolls to row 40;
##   with it off, a click on another shot (row 5) chooses it but the grid stays where it
##   was (row 5 is not among the rows drawn).
## - Only selected lists just the chosen rows ("2 of 120 rows"); with the filter box typed
##   into as well, only the chosen rows the filter leaves in; the choice itself is not
##   changed by either, and with nothing chosen the grid says "No rows are selected.".
## - With no row chosen, the grid follows the pointer over a shot on the map (marks its rows,
##   scrolls to them) while Follow the pointer is on, and does not with it off.
## - A click on a row of the grid chooses it, and its point is the one selected on the map.
##
## Seen to fail: with the click choosing the clicked point's own row alone, "the twice-taken
## shot chose rows [40]"; with the grid scrolling whatever the option, "the grid scrolled
## with Follow the pointer off"; with Only selected ignoring the filter, "the filter did not
## narrow the selected rows: shotlog.listed 2".
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves shotselect-*.png there.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, shotlog, state, survey]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const
  BaseS = 1_772_323_200'i64     # 2026-03-01T00:00:00 UTC
  Rows = 120
  Twice = (first: 40, again: 100)
  Taken = [5, 40, 70, 100, 110] ## the rows whose shots the file's traces are

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc writeSliced(path: string) =
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for i, row in Taken:
    var k = initTraceKeys()
    k.status = tsLive
    k.record = float64(i + 1)
    k.channel = 1
    k.intervalUs = 2000
    k.t0Ms = 0
    k.time = float64(BaseS + int64(row) * 10)
    k.rcvLine = 1
    k.rcvPoint = 7
    var samples = newSeq[float32](20)
    for j in 0 ..< 20: samples[j] = float32(i * 100 + j)
    w.writeTrace(k, samples)
  discard w.close()

func rowX(row: int): float64 =
  ## Where a shot is: the repeat is where the first was.
  1000.0 + 10.0 * float64(if row == Twice.again: Twice.first else: row)

proc writeLog(path: string) =
  var text = "line,point,x,y,time\n"
  for i in 0 ..< Rows:
    let shot = if i == Twice.again: Twice.first else: i
    text.add "10," & $(100 + shot) & "," & $rowX(i) & ",2000," &
      $((BaseS + int64(i) * 10) * 1_000_000) & "\n"
  writeFile(path, text)

proc runMain() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let sliced = fx.dir / "sliced.sgy"
    let logPath = fx.dir / "shots.csv"
    writeSliced(sliced)
    writeLog(logPath)
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkShotLog: @[logPath] else: @[]
    proc pointOf(f: FrameInfo; row: int): Vec2 =
      f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(rowX(row), 2000.0))
    proc has(f: FrameInfo; prefix: string): bool = f.markNames(prefix).len > 0
    proc setFollow(f: FrameInfo; on: bool) =
      var s = f.core.settings
      s.headers.followPointer = on
      f.apply Command(kind: ckSettings, settings: s)

    step("the bar", proc (f: FrameInfo) =
      f.resizeWindow(1920, 1080)
      f.keepInMainWindow(), proc (f: FrameInfo): bool =
      f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080) and
        f.core.sessions.len == 1)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
    step("import", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Import shot log...").centre), proc (f: FrameInfo): bool =
      f.core.shotLogCount == 1 and f.core.jobs.active.len == 0 and wait > 8)
    proc remap(f: FrameInfo) =
      var m = initShotLogMap()
      m.hasHeader = true
      m.roles = @[crSourceLine, crShotPoint, crX, crY, crTime]
      m.dateTimePattern = EpochMicros
      f.apply Command(kind: ckRemapShotLog, logIndex: 0, logMap: m)
    step("the columns as they are", remap, proc (f: FrameInfo): bool =
      result = f.core.survey.findShotLog(f.core.shotLogId(0)) >= 0 and wait > 8 and
        f.markNames("shotlog.time 0 2026").len > 0)
    proc dragged(f: FrameInfo; a, b: Vec2): bool =
      ## Called each frame of a step from its third: presses at `a`, moves to `b`, lets go.
      case wait
      of 3: f.moveMouse(a)
      of 4: f.pressMouse(a, true)
      of 5: f.moveMouse(vec2((a.x + b.x) / 2, (a.y + b.y) / 2))
      of 6: f.moveMouse(b)
      of 7: f.pressMouse(b, false)
      else: discard
      wait > 10
    step("every control in reach at the default width", noop, proc (f: FrameInfo): bool =
      result = wait > 6
      if result:
        let win = f.markOf("shotlog")
        for name in ["shotlog.filter", "shotlog.problemsbox", "shotlog.onlybox",
            "shotlog.allowbox", "shotlog.followbox", "shotlog.pointerbox", "shotlog.columns",
            "shotlog.exportsps"]:
          let r = f.markOf(name)
          doAssert r.size.x > 0 and r.pos.x + r.size.x <= win.pos.x + win.size.x and
            r.pos.y + r.size.y <= win.pos.y + win.size.y, name & " is cut off at the default width"
        f.shot("shotselect-default.png"))
    # the grid is made narrower, to leave the map (at the right) in sight
    step("the grid narrower", noop, proc (f: FrameInfo): bool =
      f.dragged(vec2(1509, 907), vec2(1090, 1000)))
    step("every control in reach at a narrow width", noop, proc (f: FrameInfo): bool =
      result = wait > 6
      if result:
        let win = f.markOf("shotlog")
        for name in ["shotlog.filter", "shotlog.problemsbox", "shotlog.onlybox",
            "shotlog.allowbox", "shotlog.followbox", "shotlog.pointerbox", "shotlog.columns",
            "shotlog.exportsps"]:
          let r = f.markOf(name)
          doAssert r.size.x > 0 and r.pos.x + r.size.x <= win.pos.x + win.size.x and
            r.pos.y + r.size.y <= win.pos.y + win.size.y, name & " is cut off at the narrow width"
        f.shot("shotselect-narrow.png"))
    step("fit", proc (f: FrameInfo) = f.click(f.markOf("map.fit").centre),
      proc (f: FrameInfo): bool =
      result = wait > 12 and f.mapWindow.mapShown.isSet
      if result: f.shot("shotselect-layout.png"))

    step("the pointer over a shot, nothing chosen: the grid follows it", proc (f: FrameInfo) =
      f.moveMouse(f.pointOf(Twice.first)), proc (f: FrameInfo): bool =
      result = f.has("shotlog.chosen pointer " & $Twice.first) and wait > 4
      if result:
        doAssert f.core.shotRowsChosen.rows.len == 0, "hovering chose rows"
        f.shot("shotselect-hover.png"))
    step("with Follow the pointer off it does not", proc (f: FrameInfo) =
      f.setFollow(false)
      f.moveMouse(f.pointOf(70)), proc (f: FrameInfo): bool =
      result = wait > 8
      if result:
        doAssert f.has("shotlog.marked none 0"),
          "the grid marked the pointer's rows with Follow the pointer off: " &
            $f.markNames("shotlog.marked")
        f.setFollow(true))
    step("a click on the twice-taken shot", proc (f: FrameInfo) =
      f.click(f.pointOf(Twice.first)), proc (f: FrameInfo): bool =
      result = f.core.shotRowsChosen.rows.len > 0 and wait > 6
      if result:
        doAssert f.core.shotRowsChosen.rows == @[Twice.first, Twice.again],
          "the twice-taken shot chose rows " & $f.core.shotRowsChosen.rows
        let base = f.core.sessions[0].base
        doAssert base + 1 in f.core.selection.selected and base + 3 in f.core.selection.selected and
          f.core.selection.selected.len == 2, "the traces of both shots were not selected"
        doAssert f.core.selection.points.len == 2, "both rows' points are selected on the map"
        doAssert f.has("shotlog.chosen selection " & $Twice.first),
          "the grid did not scroll to the chosen row: " & $f.markNames("shotlog.edge")
        f.shot("shotselect-twice.png"))

    step("follow off, a click on another shot", proc (f: FrameInfo) =
      f.setFollow(false)
      f.click(f.pointOf(5)), proc (f: FrameInfo): bool =
      result = f.core.shotRowsChosen.rows == @[5] and wait > 8
      if result:
        doAssert not f.has("shotlog.chosen selection 5"),
          "the grid scrolled with Follow the pointer off"
        doAssert f.core.selection.selected.len == 1)

    step("follow on again: the next change scrolls", proc (f: FrameInfo) =
      f.setFollow(true)
      f.click(f.pointOf(Twice.again)), proc (f: FrameInfo): bool =
      result = f.core.shotRowsChosen.rows.len == 2 and wait > 8
      if result:
        doAssert f.has("shotlog.chosen selection " & $Twice.first),
          "the grid did not scroll with Follow the pointer on")

    proc focusGrid(f: FrameInfo) =
      ## A click on the window's summary line: it takes the focus (a click elsewhere left it).
      f.click(f.markOf("shotlog.summary").centre)
    step("only selected", focusGrid, proc (f: FrameInfo): bool =
      if wait == 4: f.click(f.markOf("shotlog.onlybox").centre)
      result = f.has("shotlog.onlyon") and wait > 6
      if result:
        doAssert f.has("shotlog.only 2 of " & $Rows & " rows"), $f.markNames("shotlog.only")
        doAssert f.markNames("shotlog.listed ") == @["shotlog.listed 2"],
          $f.markNames("shotlog.listed ")
        doAssert f.core.shotRowsChosen.rows == @[Twice.first, Twice.again]
        f.shot("shotselect-only.png"))

    var typed = false
    step("the filter narrows the selected rows", proc (f: FrameInfo) =
      f.click(f.markOf("shotlog.filter").centre)
      typed = false, proc (f: FrameInfo): bool =
      if wait == 5 and not typed:
        f.typeText($((BaseS + int64(Twice.again) * 10) * 1_000_000))
        typed = true
      result = wait > 10 and f.has("shotlog.only 1 of")
      if result:
        doAssert f.markNames("shotlog.listed ") == @["shotlog.listed 1"],
          "the filter did not narrow the selected rows: " & $f.markNames("shotlog.listed ")
        doAssert f.core.shotRowsChosen.rows == @[Twice.first, Twice.again],
          "filtering changed the selection")

    proc clearRows(f: FrameInfo) =
      f.apply Command(kind: ckSelectShotRows, shotLogId: f.core.shotLogId(0), shotRows: @[])
    step("nothing chosen", clearRows, proc (f: FrameInfo): bool =
      result = wait > 6 and f.has("shotlog.only No rows are selected.")
      if result: f.shot("shotselect-empty.png"))

    step("Only selected off", focusGrid, proc (f: FrameInfo): bool =
      if wait == 4: f.click(f.markOf("shotlog.onlybox").centre)
      wait > 6 and not f.has("shotlog.onlyon"))
    var rowShown = -1
    step("a click on a row of the grid", proc (f: FrameInfo) =
      let name = f.markNames("shotlog.row ")[0] # the first row drawn
      rowShown = parseInt(name.split(' ')[^1])
      f.click(f.markOf(name).centre), proc (f: FrameInfo): bool =
      result = f.core.shotRowsChosen.rows == @[rowShown] and wait > 4
      if result:
        doAssert f.core.selection.points.len == 1,
          "the clicked row's point is not selected on the map"
        f.shot("shotselect-row.png"))

    proc onFrame(f: FrameInfo) =
      if f.index == 0: f.moveMouse(vec2(4, 4))
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
        elif overdue(wait, 600, since):
          failed = steps[at].name & " did not happen (shot logs " & $f.core.shotLogCount &
            ", layers " & $f.core.survey.layers.len & ", map marks " & $f.markNames("map") & ")"
          f.shot("shotselect-failed.png")
          f.stop()
    let code = run(RunOptions(openPaths: @[sliced], windowSize: (1920, 1080),
      theme: forceDark, persist: true, configDir: some(fx.dir / "config"),
      logDir: some(fx.dir / "logs"), indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
      dialogs: hook, onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc main*() =
  runMain()

when isMainModule:
  main()
