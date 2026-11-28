## Show this receiver across the listed files, in the running frontend, headless, with real
## clicks: three shot files of one folder, each with a trace of one receiver; a right click on
## a trace of the first shows the menu with "Show this receiver across the listed files"
## (enabled, with its tooltip), a click collects the gather. The Seismic window then says
## "read-only", the shown session holds one trace per listed shot, the Headers window's Trace
## table has the Source file column, and killing a trace from the trace menu is refused with
## the read-only sentence in Messages (nothing is killed). On a gather the same menu item is
## dim.
##
## Seen to fail: with the menu item not drawn, "the item is not in the trace menu"; with the
## Source file column left out, "the Source file column is not drawn"; with the refusal of
## `editTraces` taken out, "the read-only sentence did not reach Messages".
##
## Needs a display: run under `env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1920x1080x24"`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves rcvgather-menu.png and rcvgather-shown.png there.

import std/[monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const
  Shots = 3
  ItemMark = "plot.menu.gather"

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc shotFile(path: string; record: int64) =
  ## A record of 30 channels of the map fixture's survey: its X file places them.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
  for ch in 1 .. 30:
    var k = initTraceKeys()
    k.record = float64(record)
    k.channel = float64(ch)
    k.srcPoint = 1000.0 + float64(record)
    k.time = 1_700_000_000.0 + float64(record * 60)
    (k.intervalUs, k.status) = (2000.0, tsLive)
    var buf = newSeq[float32](32)
    for i in 0 ..< buf.len: buf[i] = float32(int(record) * 10 + ch) * float32(i mod 7 - 3)
    w.writeTrace(k, buf)
  doAssert w.close().len == 0, "shot file was not written: " & path

proc main*() =
  withFixtures fx:
    # three shot records in one folder; the survey's S, R and X files, joined, give their
    # traces the receiver stations
    let dir = fx.dir / "shots"
    createDir(dir)
    var names: seq[string] = @[]
    for record in 1 .. Shots:
      shotFile(dir / ("shot" & $record & ".sgy"), record)
      names.add "shot" & $record & ".sgy"
    let (sps, _) = (fx.mapSps, 0)
    let xps = fx.mapXps
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var stage = 0
    var wait = 0
    var since = getMonoTime()
    var at: Vec2
    var problem = ""
    var killedBefore = 0
    proc shot(f: FrameInfo; name: string) =
      if shots.len > 0:
        createDir(shots)
        discard f.savePng(shots / name)
    proc rightClick(f: FrameInfo; p: Vec2) =
      if wait == 3: f.pressMouse(p, true, button = 3)
      if wait == 5: f.pressMouse(p, false, button = 3)
    proc leftClick(f: FrameInfo; p: Vec2) =
      if wait == 2: f.moveMouse(p)
      if wait == 4: f.pressMouse(p, true)
      if wait == 6: f.pressMouse(p, false)
    proc onFrame(f: FrameInfo) =
      inc wait
      template next(n: int) = (stage, wait, since) = (n, 0, getMonoTime())
      if f.index == 0: f.moveMouse(vec2(4, 4))
      let k = f.core.findPanel(MainPanel)
      case stage
      of 0:
        if f.core.panels[k].laidOut and f.core.tiles(k).len > 0 and wait > 5:
          f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: @[
            JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
            JoinFile(path: xps, kind: jkSps)])
          next 10
      of 10:
        if f.core.joinReport.serial > 0 and not f.core.importing and wait > 20:
          f.apply Command(kind: ckBrowse, paths: @[dir])
          next 1
      of 1:
        if not f.core.fileList.scanning and f.core.fileList.folder == dir and wait > 5:
          let d = f.markOf("plot.data")
          at = vec2(round(d.pos.x + d.size.x * 0.3), round(d.pos.y + d.size.y * 0.3))
          f.moveMouse(at)
          next 2
      of 2:
        f.rightClick(at)
        if wait > 8 and f.markOf(ItemMark).size.x > 0:
          doAssert f.markOf(ItemMark).size.x > 0, "the item is not in the trace menu"
          f.moveMouse(f.markOf(ItemMark).centre)
          next 3
      of 3:
        if wait > 6:
          f.shot("rcvgather-menu.png")
          next 4
      of 4:
        f.leftClick(f.markOf(ItemMark).centre)
        if wait > 8 and f.core.sessions.len == 1 and f.core.sessions[0].gathered and
            f.core.jobs.active.len == 0:
          let s = f.core.sessions[0]
          if s.len != Shots:
            problem = "the gather has " & $s.len & " traces, not " & $Shots
          for i in 0 ..< s.len:
            if s.gatherSource(i).extractFilename notin names:
              problem = "trace " & $i & " names no listed file: " & s.gatherSource(i)
          f.moveMouse(vec2(4, 4))
          next 5
      of 5:
        # the Seismic window's title says it is read-only; open the trace table
        f.leftClick(f.markOf("headers.tab table").centre)
        if wait > 12 and f.markOf("table.row 0").size.x > 0:
          if f.markOf("table.header source file").size.x == 0:
            problem = "the Source file column is not drawn"
          if f.markOf("table.source 0").size.x == 0:
            problem = "the Source file column has no cell"
          next 6
      of 6:
        if wait == 3:
          # a trace of the gather, to look at its source in the status bar
          let d = f.markOf("plot.data")
          f.moveMouse(vec2(round(d.pos.x + d.size.x * 0.3), round(d.pos.y + d.size.y * 0.5)))
        if wait > 10:
          if f.markOf("plot.gather title").size.x == 0:
            problem = "the gather's title line is not drawn"
          f.shot("rcvgather-shown.png")
          let d = f.markOf("plot.data")
          at = vec2(round(d.pos.x + d.size.x * 0.3), round(d.pos.y + d.size.y * 0.3))
          f.moveMouse(at)
          next 7
      of 7:
        f.rightClick(at)
        if wait > 8 and f.markOf("plot.menu.kill").size.x > 0:
          killedBefore = f.core.log.len
          f.moveMouse(f.markOf("plot.menu.kill").centre)
          next 8
      of 8:
        f.leftClick(f.markOf("plot.menu.kill").centre)
        if wait > 10:
          var said = false
          for e in f.core.log:
            if "read-only" in e.text: said = true
          if not said: problem = "the read-only sentence did not reach Messages"
          f.stop()
      else: f.stop()
      if overdue(wait, 600, since) and problem.len == 0:
        problem = "stopped at stage " & $stage
        f.shot("rcvgather-debug.png")
      if problem.len > 0: f.stop()
    let code = run(RunOptions(openPaths: @[dir / names[0]], windowSize: (1600, 1000),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert problem.len == 0, problem
    doAssert stage == 8, "stopped at stage " & $stage
    echo "tguireceivergather: done"

when isMainModule:
  main()
