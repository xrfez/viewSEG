## What was under the pointer at a right click stays highlighted, and its
## read-outs stay as they were, while the right-click menu is open, in the
## running frontend, headless, with real clicks: the survey's seismic file
## and its SPS files (the plot and the map, linked).
##
## - The map: the pointer on a receiver (drawn in the hover colour, its
##   trace lit up in the plot, its description beside the pointer, its
##   coordinates in the status bar); a right click opens the menu; with the
##   pointer moved over the menu, for several frames, the receiver is still
##   the hover, drawn in the hover colour, its trace still lit up in the
##   plot, the description the same (beside the menu, not under it) and the
##   status bar's coordinates those of the right click. A click away closes
##   the menu: the hover follows the pointer again (nothing under it, its
##   coordinates in the status bar).
## - The plot: the pointer on a trace (the hover, drawn in the hover
##   colour, its receiver lit up on the map, the status bar's read-out, the
##   cursor's time line); a right click opens the plot's menu; with the
##   pointer over the menu, all of it stays as it was at the right click.
##   Esc closes the menu: the hover and the read-out follow the pointer
##   again.
## - A table of the Headers window (the binary header): a value right
##   clicked stays highlighted while its menu is open, with the pointer over
##   the menu; Esc closes it, and the value is drawn as the others.
##
## Seen to fail: with the map's held points left out (`under` from the
## pointer while the menu is open, as it was), "the map's menu holds what
## was under the pointer" found no point hovered; with the plot's held pick
## left out, "the plot's menu holds what was under the pointer" found the
## hover -1; with the value's selectable not drawn as chosen while its menu
## is open, "the value not highlighted while its menu was open".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves held-*.png there.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, pick, state]
import viewSEG/ui/imgui/app
import viewSEG/view/[maplayers, plotink]
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func same(a, b: Rgba): bool = a.r == b.r and a.g == b.g and a.b == b.b

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc screen(f: FrameInfo; x, y: float64): Vec2 =
  ## Where survey point (`x`, `y`) is drawn now, framebuffer pixels, rounded
  ## to where SDL puts the pointer.
  let p = f.mapWindow.mapShown.screenAt(f.mapWindow.mapPlot, mapPoint(x, y))
  vec2(round(p.x), round(p.y))

proc pixel(f: FrameInfo; at: Vec2): Rgba = f.readPixel(int(floor(at.x)), int(floor(at.y)))

proc inked(f: FrameInfo; c: Rgba): int =
  ## The plot image's pixels of colour `c`.
  let (img, _, _) = f.tracePanel.plotImage
  for p in img:
    if distance(p, c) <= 12: inc result

func leftHalf(r: Rect): Rect =
  ## (where the menu, opened at the middle, does not cover it)
  Rect(pos: r.pos, size: vec2(r.size.x / 2 - 2, r.size.y))

proc commonest(f: FrameInfo; r: Rect): Rgba =
  ## The colour most of the pixels of `r` have (an item's background, not
  ## its text's).
  let img = f.readFrame()
  var counts: seq[(Rgba, int)]
  for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
    for x in int(r.pos.x) ..< int(r.pos.x + r.size.x):
      let c = img[y * f.width + x]
      var k = 0
      while k < counts.len and not same(counts[k][0], c): inc k
      if k == counts.len: counts.add (c, 0)
      inc counts[k][1]
  var best = 0
  for k in 1 ..< counts.len:
    if counts[k][1] > counts[best][1]: best = k
  counts[best][0]

proc main() =
  withFixtures fx:
    let sps = fx.surveySps()
    let segy = fx.surveySegy()
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var steps: seq[Step]
    var at = 0
    var started = false
    var wait = 0 # frames since the step began, at `since`
    var since = getMonoTime()
    var failed = ""
    var ink: MapInk
    var p: Vec2 # where the pointer was at the right click
    var points: seq[PointRef] # what the read-outs said then:
    var texts: seq[string]
    var cursor: string
    var hover = -1
    var picked: Pick
    var line: Rect
    var lit: int
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc hoverInk(f: FrameInfo): Rgba =
      let k = f.core.findPanel(MainPanel)
      plotInk(f.theme, f.core.panels[k].layers[0].display).wiggle.hover
    proc rightClick(f: FrameInfo; at: Vec2) =
      if wait == 3: f.pressMouse(at, true, button = 3)
      if wait == 5: f.pressMouse(at, false, button = 3)

    step("loaded", proc (f: FrameInfo) =
      var s = f.core.settings
      s.cursorLine = true # (off by default)
      f.apply(Command(kind: ckSettings, settings: s)), proc (f: FrameInfo): bool =
      let k = f.core.findPanel(MainPanel)
      result = f.core.survey.layers.len == 3 and f.core.panels[k].laidOut and
        f.core.tiles(k).len > 0 and f.mapWindow.mapShown.isSet and
        f.markOf("plot.data").size.x > 0 and f.markOf("map.data").size.x > 0 and wait > 10
      if result: ink = mapInk(f.theme, pcPaper))

    # ------------------------------------------------------------- the map --
    step("the pointer on a receiver", proc (f: FrameInfo) =
      # (the last: far from the sources)
      p = f.screen(rcvX(Channels), OriginY)
      f.moveMouse(p), proc (f: FrameInfo): bool =
      result = wait > 4 and f.mapWindow.hoveredPoints.len > 0 and
        f.core.selection.hoverTraces.len > 0 and f.mapCursor.len > 0 and
        same(f.pixel(p), ink.hover) and f.inked(f.hoverInk) > 0
      if result:
        points = f.mapWindow.hoveredPoints
        texts = f.mapWindow.pointTexts
        cursor = f.mapCursor
        lit = f.inked(f.hoverInk)
        doAssert texts.len > 0 and f.markOf("map.info").size.x > 0, $texts)
    step("a right click opens the map's menu", noop, proc (f: FrameInfo): bool =
      f.rightClick(p)
      result = wait > 6 and f.markOf("map menu.select").size.x > 0)
    var frames = 0
    step("the map's menu holds what was under the pointer", proc (f: FrameInfo) =
      frames = 0
      f.moveMouse(f.markOf("map menu.select").centre), proc (f: FrameInfo): bool =
      if wait > 3:
        # every frame from here: as at the right click
        doAssert f.markOf("map menu.select").size.x > 0, "the menu closed"
        doAssert f.mapWindow.hoveredPoints == points,
          "the hover: " & $f.mapWindow.hoveredPoints.len & " points"
        doAssert f.core.selection.hoverPoints == points, "the hover sent to the plot"
        doAssert f.core.selection.hoverTraces.len > 0, "no trace lit up in the plot"
        doAssert f.mapWindow.pointTexts == texts, $f.mapWindow.pointTexts
        doAssert f.mapCursor == cursor, "the status bar: " & f.mapCursor & ", was " & cursor
        doAssert same(f.pixel(p), ink.hover), "the receiver not in the hover colour: " &
          $f.pixel(p)
        doAssert f.inked(f.hoverInk) == lit, "the plot's lit trace: " & $f.inked(f.hoverInk) &
          " pixels, was " & $lit
        let box = f.markOf("map.info")
        let menu = f.markOf("map menu")
        doAssert box.size.x > 0, "no description"
        doAssert box.pos.x + box.size.x <= menu.pos.x or box.pos.y >= menu.pos.y + menu.size.y or
          box.pos.y + box.size.y <= menu.pos.y or box.pos.x >= menu.pos.x + menu.size.x,
          "the description under the menu: " & $box & " " & $menu
        inc frames
      result = frames >= 8
      if result: f.shot("held-map.png"))
    var away: Vec2
    step("a click away closes it: the hover follows the pointer", proc (f: FrameInfo) =
      # an empty spot of the map, above the line
      let d = f.markOf("map.data")
      away = vec2(round(d.pos.x + d.size.x / 2), round(d.pos.y + d.size.y * 0.2))
      f.moveMouse(away), proc (f: FrameInfo): bool =
      if wait == 3: f.pressMouse(away, true)
      if wait == 5: f.pressMouse(away, false)
      result = wait > 8 and f.markOf("map menu").size.x == 0 and
        f.mapWindow.hoveredPoints.len == 0 and f.mapCursor.len > 0 and f.mapCursor != cursor
      if result:
        doAssert f.core.selection.hoverPoints.len == 0
        doAssert not same(f.pixel(p), ink.hover), "the receiver still in the hover colour")

    # ------------------------------------------------------------ the plot --
    step("the pointer on a trace", proc (f: FrameInfo) =
      let d = f.markOf("plot.data")
      p = vec2(round(d.pos.x + d.size.x * 0.3), round(d.pos.y + d.size.y * 0.4))
      f.moveMouse(p), proc (f: FrameInfo): bool =
      result = wait > 4 and f.core.selection.hover >= 0 and f.pick.found and
        f.markOf("plot.cursor line").size.x > 0 and f.core.selection.hoverAt.len > 0
      if result:
        hover = f.core.selection.hover
        picked = f.pick
        line = f.markOf("plot.cursor line")
        lit = f.inked(f.hoverInk)
        doAssert lit > 0, "the hovered trace is not drawn in the hover colour")
    step("a right click opens the plot's menu", noop, proc (f: FrameInfo): bool =
      f.rightClick(p)
      result = wait > 6 and f.markOf("plot.menu.kill").size.x > 0)
    step("the plot's menu holds what was under the pointer", proc (f: FrameInfo) =
      frames = 0
      f.moveMouse(f.markOf("plot.menu.kill").centre), proc (f: FrameInfo): bool =
      if wait > 3:
        doAssert f.markOf("plot.menu.kill").size.x > 0, "the menu closed"
        doAssert f.core.selection.hover == hover, "the hover: " & $f.core.selection.hover &
          ", was " & $hover
        let now = f.pick
        doAssert now.found and now.position == picked.position and now.trace == picked.trace and
          now.at == picked.at and now.sample == picked.sample,
          "the read-out: " & $now.position & " at " & $now.at & ", was " & $picked.position &
          " at " & $picked.at
        doAssert f.markOf("plot.cursor line") == line, "the cursor's time line: " &
          $f.markOf("plot.cursor line") & ", was " & $line
        doAssert f.inked(f.hoverInk) == lit, "the hovered trace's pixels: " &
          $f.inked(f.hoverInk) & ", were " & $lit
        doAssert f.core.selection.hoverAt.len > 0, "its points not lit up on the map"
        inc frames
      result = frames >= 8
      if result: f.shot("held-plot.png"))
    step("Esc closes it: the hover follows the pointer", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
      result = wait > 4 and f.markOf("plot.menu.kill").size.x == 0 and f.pick.inside and
        f.pick.at != picked.at and f.markOf("plot.cursor line") != line)
    step("off the plot: no hover", proc (f: FrameInfo) =
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      wait > 4 and f.core.selection.hover < 0 and not f.pick.inside)

    # ------------------------------------------- a table of the Headers window --
    const cell = "headers.binary binary.jobId 0"
    proc click(f: FrameInfo; mark: string): bool =
      ## Two clicks on `mark` over frames 2 to 9 of a step (the first only
      ## brings the window forward); true after.
      let c = f.markOf(mark).centre
      if wait == 2: f.moveMouse(c)
      if wait in [3, 7]: f.pressMouse(c, true)
      if wait in [5, 9]: f.pressMouse(c, false)
      wait > 12
    step("the Headers window's File headers", noop, proc (f: FrameInfo): bool =
      f.click("headers.tab file"))
    step("its binary header", noop, proc (f: FrameInfo): bool =
      f.click("headers.file tab Binary") and f.markOf(cell).size.x > 0)
    step("a right click on a value opens its menu", proc (f: FrameInfo) =
      p = f.markOf(cell).centre
      f.moveMouse(p), proc (f: FrameInfo): bool =
      f.rightClick(p)
      result = wait > 6 and f.markOf("headers.value menu").size.x > 0)
    var heldInk: Rgba
    step("its menu keeps the value highlighted", proc (f: FrameInfo) =
      f.moveMouse(f.markOf("headers.value menu").centre), proc (f: FrameInfo): bool =
      result = wait > 6 and f.markOf("headers.value menu").size.x > 0
      if result:
        heldInk = f.commonest(f.markOf(cell).leftHalf)
        f.shot("held-headers.png"))
    step("Esc closes it: the value as the others", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
      f.moveMouse(vec2(4, 4)), proc (f: FrameInfo): bool =
      result = wait > 6 and f.markOf("headers.value menu").size.x == 0
      if result:
        let plain = f.commonest(f.markOf(cell).leftHalf)
        doAssert distance(heldInk, plain) > 12, "the value not highlighted while its menu " &
          "was open: " & $heldInk & ", as the others " & $plain)

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
        if wait >= 2 and steps[at].done(f):
          inc at
          started = false
        elif overdue(wait, 400, since):
          failed = steps[at].name & " did not happen"
          f.stop()

    let code = run(RunOptions(openPaths: @[segy, sps.s, sps.r],
      windowSize: (1600, 1000), theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name
    echo "tguiheld: ", steps.len, " steps: the map's and the plot's menus hold what was " &
      "under the pointer"

main()
