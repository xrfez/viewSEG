## The folder's shots on the map, in the running frontend, headless, with
## real clicks: `mapSps`'s S and R files and a folder of five shot records
## of its spread, listed (its first file shown).
##
## - The five sources with a file in the folder are ringed in the outline
##   colour; a source without one is not.
## - The point under the pointer names the file that holds its record.
## - A click on a source whose file is listed but not open shows that file
##   in the plot, at its record, and the file list marks it.
## - The Layers popover says how many of the survey's sources have a file.
##
## Seen to fail: with the marked points left out of the map's image, "the
## sources with a file ringed" found no ring round source 0/1.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves map-shots-*.png there.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))

proc centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func same(a, b: Rgba): bool = a.r == b.r and a.g == b.g and a.b == b.b

proc ring(f: FrameInfo; at: Vec2; c: Rgba): int =
  ## The pixels of colour `c` between 3 and 8 pixels from `at`.
  for dy in -8 .. 8:
    for dx in -8 .. 8:
      let d = hypot(float(dx), float(dy))
      if d >= 3 and d <= 8 and same(f.readPixel(int(round(at.x)) + dx,
          int(round(at.y)) + dy), c): inc result

const Shot = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 5)]

proc main() =
  withFixtures fx:
    let sps = fx.mapSps()
    let folder = fx.dir / "shots"
    createDir(folder)
    for (line, k) in Shot:
      discard fx.mapShotSegy(line, k, name = "shots" / "shot-" & $mapRecord(line, k) & ".sgy")
    let target = folder / "shot-" & $mapRecord(1, 5) & ".sgy"
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var ink: MapInk
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc point(f: FrameInfo; line, k: int): Vec2 =
      let (x, y) = mapSrc(line, k)
      let p = f.screen(x, y)
      vec2(round(p.x), round(p.y))

    step("listed and read", noop, proc (f: FrameInfo): bool =
      result = f.core.survey.layers.len >= 3 and f.core.shots.shotFiles == 5 and
        f.core.shots.pending.len == 0 and f.core.shots.job == NoJob and
        f.mapWindow.mapShown.isSet and wait > 8 and f.core.sessions.len == 1
      if result: ink = mapInk(f.theme, pcPaper))
    step("the sources with a file ringed", noop, proc (f: FrameInfo): bool =
      result = wait > 3
      if result:
        doAssert f.core.shots.pointRefs.len == 5
        for (line, k) in Shot[1 .. ^1]:
          doAssert f.ring(f.point(line, k), ink.outline) >= 6, "no ring round source " &
            $line & "/" & $k & ": " & $f.ring(f.point(line, k), ink.outline)
        doAssert f.ring(f.point(1, 1), ink.outline) == 0, "a ring round a source with no file"
        f.shot("map-shots-ringed.png"))
    step("the pointer on one names its file", proc (f: FrameInfo) =
      f.moveMouse(f.point(1, 5)), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0
      if result:
        let t = f.mapWindow.pointTexts
        var named = false
        for line in t:
          if line == "Shot in the folder: " & target.extractFilename & " (FFID " &
              $(MapFfid + mapRecord(1, 5)) & ")": named = true
        doAssert named, $t
        f.shot("map-shots-hovered.png"))
    step("the map focused", proc (f: FrameInfo) =
      # The click that brings the window forward does nothing else.
      let (x, y) = mapRcv(1, 2)
      let p = f.screen(x, y + MapLineGap / 2)
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false), proc (f: FrameInfo): bool = wait > 4)
    step("back on the source", proc (f: FrameInfo) =
      f.moveMouse(f.point(1, 5)), proc (f: FrameInfo): bool =
      wait > 4 and f.mapWindow.hoveredPoints.len > 0)
    step("a click shows its file", proc (f: FrameInfo) =
      let p = f.point(1, 5)
      f.pressMouse(p, true)
      f.pressMouse(p, false), proc (f: FrameInfo): bool =
      result = f.core.fileList.chosen == target and f.core.sessions.len >= 1 and
        f.core.sessions[^1].path == target and
        f.core.selection.activeGather.file == f.core.sessions[^1].id and wait > 4
      if result: f.shot("map-shots-clicked.png"))
    step("the Layers popover counts them", proc (f: FrameInfo) =
      let p = f.markOf("map.layers").centre
      f.moveMouse(p)
      f.pressMouse(p, true)
      f.pressMouse(p, false), proc (f: FrameInfo): bool =
      result = wait > 3 and f.markOf("map.shots").size.x > 0)

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
        elif overdue(wait, 900, since):
          failed = steps[at].name & " did not happen"
          f.stop()
    let code = run(RunOptions(openPaths: @[sps.s, sps.r, folder],
      windowSize: (1400, 900), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

main()
