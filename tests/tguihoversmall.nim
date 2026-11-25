## The map's hover box in a small window, headless, on `samples/land`: with the map
## docked at the right of an 800 x 600 and a 1024 x 768 window, the box that names
## the point under the pointer (and, with the fold layer on, the bin's fold) at a
## station near the map's right edge, one near its bottom edge and one in the
## middle, is inside the window and does not cover the pointer (over the map's
## neighbour when the map is too narrow for it).
##
## Seen to fail before the box was wrapped and moved: at 800 x 600 the box of the
## station at the map's right edge was 286 wide in a map 168 wide, its right part
## past the window's edge and cut.
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 800x600x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves hover-<size>-<case>.png there.

import std/[math, monotimes, options, os, strformat]
import viewSEG/core/[geometry, spatial, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const Land = "samples/land/land"

type Spot = tuple[name: string, p: Vec2]

proc inside(r, outer: Rect): bool =
  r.pos.x >= outer.pos.x and r.pos.y >= outer.pos.y and
    r.pos.x + r.size.x <= outer.pos.x + outer.size.x and
    r.pos.y + r.size.y <= outer.pos.y + outer.size.y

proc stations(f: FrameInfo): seq[Spot] =
  ## The right-most, bottom-most and middle-most points shown by the map.
  let (view, plot) = (f.mapWindow.mapShown, f.mapWindow.mapPlot)
  let mid = vec2(plot.pos.x + plot.size.x / 2, plot.pos.y + plot.size.y / 2)
  var all: seq[Vec2]
  for l in f.core.survey.layers:
    for role in [prSource, prReceiver]:
      let ix = l.points[role].index
      for q in 0 ..< ix.len:
        let p = view.screenAt(plot, mapPoint(ix.x(q), ix.y(q)))
        let p2 = vec2(round(p.x), round(p.y))
        if p2.x > plot.pos.x + 4 and p2.x < plot.pos.x + plot.size.x - 4 and
            p2.y > plot.pos.y + 4 and p2.y < plot.pos.y + plot.size.y - 4:
          all.add p2
  doAssert all.len > 0, "no point on the map"
  var (r, b, m) = (all[0], all[0], all[0])
  for p in all:
    if p.x > r.x: r = p
    if p.y > b.y: b = p
    if (p.x - mid.x) ^ 2 + (p.y - mid.y) ^ 2 < (m.x - mid.x) ^ 2 + (m.y - mid.y) ^ 2: m = p
  result = @[("right", r), ("bottom", b), ("middle", m)]

proc runSize(fx: Fixtures; size: (int, int); shots: string) =
  let tag = $size[0] & "x" & $size[1]
  var spots: seq[Spot]
  var stage, wait, caseAt = 0 # 0 loading, 1 hovering fold off, 2 turning fold on, 3 fold on
  var failed = ""
  let start = getMonoTime()
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if overdue(f.index, 6000, start) and failed.len == 0:
      failed = "stage " & $stage & " case " & $caseAt & " did not happen"
    if failed.len > 0:
      f.stop()
      return
    case stage
    of 0:
      if f.core.survey.layers.len == 3 and f.mapWindow.mapShown.isSet and
          f.core.jobs.active.len == 0 and wait > 20:
        spots = f.stations()
        (stage, wait, caseAt) = (1, 0, 0)
        f.moveMouse(spots[0].p)
    of 1, 3:
      let s = spots[caseAt]
      if wait > 6 and f.mapWindow.hoveredPoints.len > 0 and f.markOf("map.info").size.x > 0:
        let info = f.markOf("map.info")
        let display = Rect(pos: vec2(0, 0), size: vec2(float64(f.width), float64(f.height)))
        let layer = if stage == 1: "off" else: "on"
        echo &"tguihoversmall: {tag} {s.name} fold {layer}: box {info}, pointer {s.p}, ",
          f.mapWindow.pointTexts.len, " lines"
        discard f.savePng(shots / &"hover-{tag}-{s.name}-fold-{layer}.png")
        doAssert info.inside(display), &"{tag} {s.name} fold {layer}: the box {info} is not in " &
          &"the window {f.width} x {f.height}"
        doAssert s.p notin info,
          &"{tag} {s.name} fold {layer}: the box {info} covers the pointer {s.p}"
        wait = 0
        inc caseAt
        if caseAt < spots.len:
          f.moveMouse(spots[caseAt].p)
        elif stage == 1:
          (stage, caseAt) = (2, 0)
          f.moveMouse(vec2(4, 4))
          var st = f.core.settings
          st.map.foldLayer = true
          f.apply Command(kind: ckSettings, settings: st)
        else:
          f.stop()
          stage = 4
      elif wait > 600:
        failed = &"{tag} {s.name} stage {stage}: no box ({f.mapWindow.pointTexts})"
    of 2:
      if wait > 10 and f.mapWindow.foldBlocksDrawn > 0 and f.mapWindow.foldResult != nil:
        (stage, wait) = (3, 0)
        f.moveMouse(spots[0].p)
    else: discard
  let code = run(RunOptions(openPaths: @[Land & ".s", Land & ".r", Land & ".x"],
    windowSize: size, theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
    indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert stage == 4, "stopped at stage " & $stage

proc main*() =
  withFixtures fx:
    var shots = getEnv("VIEWSEG_SCREENSHOTS")
    if shots.len == 0: shots = fx.dir / "shots"
    createDir(shots)
    for size in [(800, 600), (1024, 768)]:
      runSize(fx, size, shots)
    echo "tguihoversmall: ok"

when isMainModule:
  main()
