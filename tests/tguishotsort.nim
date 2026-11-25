## The Shot log grid sorted by several columns and rearranged, in the running frontend,
## headless. A click on a header sorts by it; Shift-click adds a further key, and a
## second Shift-click turns that key round; each header says its place and direction and
## the rows come in the sort's order, ties in file order, while the selection, a click
## and the marks still name the log's own rows. The sort is made once, not every frame.
## A header dragged onto another takes its place. The layout (order, sort) is kept in
## the project: closed and opened again, the grid shows it. The header's menu clears the
## sort and resets the columns, which brings back the file's order.
##
## Seen to fail: with the second key replacing the first, `shiftAddsAKey` saw rows in
## the order of the last key alone; with ties listed in the reverse of the file order,
## `twoKeys` listed row 5 before row 1; with the sort built every frame,
## `builtOnce` saw the stamp move; with the dragged header dropped where it was,
## `dragMoves` found the order unchanged; with the layout left out of the project,
## `reopened` found the file's order back.
##
## Needs a display: run under
## `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, shotlayout, state]
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

proc drawnRows(f: FrameInfo): seq[int] =
  for n in f.markNames("shotlog.row "):
    result.add parseInt(n["shotlog.row ".len .. ^1])

proc headerNames(f: FrameInfo): seq[string] =
  for n in f.markNames("shotlog.header "):
    result.add n["shotlog.header ".len .. ^1]

proc stampOf(f: FrameInfo): string =
  for n in f.markNames("shotlog.built "): return n

proc sortLine(f: FrameInfo): string =
  for n in f.markNames("shotlog.sort "): return n["shotlog.sort ".len .. ^1]

proc main*() =
  withFixtures fx:
    createDir(fx.dir / "cache")
    createDir(fx.dir / "config")
    createDir(fx.dir / "logs")
    let root = currentSourcePath().parentDir.parentDir
    let log = fx.dir / "sortlog.csv"
    # two rows tie on line 2 and point 5 (rows 0 and 4), two on line 1 and point 9
    writeFile(log, "line,point,x\n2,5,a\n1,9,b\n2,3,c\n1,7,d\n2,5,e\n1,9,f\n3,1,g\n2,8,h\n")
    let project = fx.dir / "project"
    let shots = root / ".scratch" / "slogtable-shots"
    let sortedShot = shots / "sorted-two-columns.png"
    let movedShot = shots / "rearranged.png"
    createDir(shots)
    var steps: seq[Step]
    var wait = 0
    var since = getMonoTime()
    var why = ""
    var stamp = ""
    var stampFrames = 0
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool;
        limit = 600) =
      steps.add Step(name: name, limit: limit, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shiftClick(f: FrameInfo; name: string) =
      let at = f.markOf("shotlog.header " & name).centre
      f.moveMouse(at)
      f.pressKey(skShift, true, {smShift})
      f.pressMouse(at, true)
      f.pressMouse(at, false)
      f.pressKey(skShift, false)

    step("the bar", proc (f: FrameInfo) =
      f.resizeWindow(1920, 1080)
      f.keepInMainWindow(),
      proc (f: FrameInfo): bool =
        f.markOf("menu.Project").size.x > 0 and f.windowSize == (1920, 1080))
    step("a project", proc (f: FrameInfo) =
      f.apply(Command(kind: ckNewProject, projectPath: project)),
      proc (f: FrameInfo): bool = f.core.inProject)
    step("Project", proc (f: FrameInfo) = f.click(f.markOf("menu.Project").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Import shot log...").size.x > 0)
    step("import the log", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Import shot log...").centre),
      proc (f: FrameInfo): bool =
        why = f.markNames("shotlog.summary ").join("|")
        "sortlog.csv" in why and "8 rows" in why and f.markNames("shotlog.header ").len == 5
      , 2000)
    step("room", proc (f: FrameInfo) =
      f.arrangeWindows(f.layoutText & "[Window][###shotlog]\nPos=20,80\nSize=1500,850\n" &
        "Collapsed=0\n\n[viewSEG][Windows]\nHidden=aux,missing,quality,vibfolder,output\n\n"),
      proc (f: FrameInfo): bool =
        why = $f.windowPlace("shotlog") & " " & $f.markNames("shotlog.header ") & " " &
          $f.markOf("shotlog.header SourcePoint")
        f.windowPlace("shotlog").inSight and not f.windowPlace("shotlog").docked and
          f.markOf("shotlog.header SourcePoint").size.x > 0)
    step("the file's order", noop, proc (f: FrameInfo): bool =
      why = $f.drawnRows
      f.drawnRows == @[0, 1, 2, 3, 4, 5, 6, 7] and f.sortLine == "")
    step("click line", proc (f: FrameInfo) = f.click(f.markOf("shotlog.header line").centre),
      proc (f: FrameInfo): bool =
      why = $f.drawnRows
      f.markNames("shotlog.headersort line 1 up").len > 0 and
        f.drawnRows == @[1, 3, 5, 0, 2, 4, 7, 6])
    step("Shift-click point", proc (f: FrameInfo) = f.shiftClick("SourcePoint"),
      proc (f: FrameInfo): bool =
      why = $f.drawnRows & " " & $f.markNames("shotlog.headersort ")
      # line first, then point; ties (rows 1 and 5, rows 0 and 4) in file order
      result = f.markNames("shotlog.headersort line 1 up").len > 0 and
        f.markNames("shotlog.headersort SourcePoint 2 up").len > 0 and
        f.drawnRows == @[3, 1, 5, 2, 0, 4, 7, 6] and f.sortLine == "line, point"
      if result:
        doAssert f.savePng(sortedShot), "the sorted screenshot was not written")
    step("Shift-click point again", proc (f: FrameInfo) = f.shiftClick("SourcePoint"),
      proc (f: FrameInfo): bool =
      why = $f.drawnRows
      f.markNames("shotlog.headersort SourcePoint 2 down").len > 0 and
        f.drawnRows == @[1, 5, 3, 7, 0, 4, 2, 6])
    step("built once", proc (f: FrameInfo) =
      stamp = f.stampOf
      stampFrames = 0,
      proc (f: FrameInfo): bool =
        if f.stampOf != stamp: why = "the sort was built again: " & stamp & " then " & f.stampOf
        doAssert f.stampOf == stamp, why
        inc stampFrames
        stamp.len > 0 and stampFrames > 30)
    step("a click keeps the log's row", proc (f: FrameInfo) =
      f.click(f.markOf(f.markNames("shotlog.time 0 ")[0]).centre),
      proc (f: FrameInfo): bool =
        let m = f.markNames("shotlog.time 0 ")
        if m.len > 0 and f.markNames("shotlog.at 0").len == 0 and wait mod 8 == 0:
          f.click(f.markOf(m[0]).centre)
        f.markNames("shotlog.at 0").len > 0 and f.core.shotRowsChosen.rows == @[0])
    step("drag x onto line", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("shotlog.header x (file)").centre),
      proc (f: FrameInfo): bool =
        let a = f.markOf("shotlog.header x (file)").centre
        let b = f.markOf("shotlog.header line").centre
        if wait == 3: f.pressMouse(a, true)
        if wait in 5 .. 12: f.moveMouse(vec2(a.x + (b.x - a.x) * float32(wait - 4) / 8, a.y))
        if wait == 16: f.pressMouse(b, false)
        why = $f.headerNames & " " & $f.core.shotLayout(0).columns.len
        wait > 18 and f.headerNames == @["Time (UTC)", "status", "x (file)", "line",
            "SourcePoint"] and
          f.core.shotLayout(0).columns.len == 3 and f.core.shotLayout(0).columns[0].name == "x" and
          f.markNames("shotlog.headersort SourcePoint 2 down").len > 0
      , 600)
    step("the sort kept through the move", noop, proc (f: FrameInfo): bool =
      why = $f.drawnRows
      f.drawnRows == @[1, 5, 3, 7, 0, 4, 2, 6] and f.sortLine == "line, point -")
    step("a shot", noop, proc (f: FrameInfo): bool =
      doAssert f.savePng(movedShot), "the rearranged screenshot was not written"
      true)
    step("close the project", proc (f: FrameInfo) = f.apply(Command(kind: ckCloseProject)),
      proc (f: FrameInfo): bool = not f.core.inProject and f.core.shotLogCount == 0, 2000)
    step("open it again", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpenProject, projectPath: project)),
      proc (f: FrameInfo): bool =
        why = $f.headerNames & " " & f.sortLine & " " & $f.drawnRows
        f.core.inProject and f.core.shotLogCount == 1 and
          f.headerNames == @["Time (UTC)", "status", "x (file)", "line", "SourcePoint"] and
          f.sortLine == "line, point -" and f.drawnRows == @[1, 5, 3, 7, 0, 4, 2, 6], 3000)
    step("the header menu", proc (f: FrameInfo) =
      let at = f.markOf("shotlog.header line").centre
      f.moveMouse(at)
      f.pressMouse(at, true, 3)
      f.pressMouse(at, false, 3),
      proc (f: FrameInfo): bool =
        if f.markOf("shotlog.menu.clearsort").size.x == 0 and wait mod 10 == 0:
          let at = f.markOf("shotlog.header line").centre
          f.moveMouse(at)
          f.pressMouse(at, true, 3)
          f.pressMouse(at, false, 3)
        f.markOf("shotlog.menu.clearsort").size.x > 0 and f.markOf("shotlog.menu.reset").size.x > 0)
    step("Clear sort", proc (f: FrameInfo) = f.click(f.markOf("shotlog.menu.clearsort").centre),
      proc (f: FrameInfo): bool =
      why = f.sortLine & " " & $f.drawnRows
      f.sortLine == "" and f.drawnRows == @[0, 1, 2, 3, 4, 5, 6, 7] and
        f.headerNames == @["Time (UTC)", "status", "x (file)", "line", "SourcePoint"])
    step("the header menu again", proc (f: FrameInfo) =
      let at = f.markOf("shotlog.header line").centre
      f.moveMouse(at)
      f.pressMouse(at, true, 3)
      f.pressMouse(at, false, 3),
      proc (f: FrameInfo): bool =
        if f.markOf("shotlog.menu.reset").size.x == 0 and wait mod 10 == 0:
          let at = f.markOf("shotlog.header line").centre
          f.moveMouse(at)
          f.pressMouse(at, true, 3)
          f.pressMouse(at, false, 3)
        f.markOf("shotlog.menu.reset").size.x > 0)
    step("Reset columns", proc (f: FrameInfo) = f.click(f.markOf("shotlog.menu.reset").centre),
      proc (f: FrameInfo): bool =
      why = $f.headerNames
      f.headerNames == @["Time (UTC)", "status", "line", "SourcePoint", "x (file)"] and
        f.core.shotLayout(0).sort.len == 0)

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
          failed = steps[at].name & " did not happen: " & why
          f.stop()
    let hook = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkShotLog: @[log] else: @[]
    let opts = RunOptions(windowSize: (1920, 1080), theme: forceDark, persist: true,
      configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      indexCacheDir: some(fx.dir / "cache"),
      userThemeDir: some(fx.dir / "no-user-themes"),
      assetDirs: some(@[root / "assets"]), dialogs: hook, onFrame: onFrame)
    let code = run(opts)
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguishotsort: ", steps.len, " steps"

when isMainModule:
  main()
