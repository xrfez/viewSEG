## The right-click menu of a seismic file's row in Files: "Treat as" lists Automatic and the
## three kinds, "Trace order" the grouping and the sort; a choice becomes the file's command,
## its cell shows the word with a mark, and a tick stands at the choice in the menu.
## `VIEWSEG_SCREENSHOTS=<dir>` saves treat-as.png there, the menu open.
##
## Seen to fail with a deliberate fault: with the popup not opened on the row ("the menu did
## not open"); with the menu items' commands not sent ("the kind was not forced").

import std/[math, monotimes, options, os, sequtils, times]
import viewSEG/core/[filelist, geometry, state, treatas]
import viewSEG/view/[filetable, theme]
import viewSEG/ui/imgui/app
import utils/[fixtures, kindfiles]
import viewSEG/core/recordingkind

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc main*() =
  withFixtures fx:
    let dir = fx.dir / "treat"
    discard writeSpecs(dir, "a continuous", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    discard writeSpecs(dir, "b shot", [spec(0, 0), spec(1, 0), spec(2, 0)])
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var
      stage = 0
      wait = 0
      at: Vec2
      since = getMonoTime()
      failed = ""
    proc next() =
      inc stage
      wait = 0
    proc row(f: FrameInfo): int = f.core.fileList.find(f.core.fileList.entries[1].path)
    proc onFrame(f: FrameInfo) =
      inc wait
      if f.index == 0:
        f.keepInMainWindow()
        f.moveMouse(vec2(4, 4))
      if getMonoTime() - since > initDuration(seconds = 40) and failed.len == 0:
        failed = "stopped at stage " & $stage
        f.stop()
      let entries = f.core.fileList.entries
      case stage
      of 0: # listed and read
        if not f.core.fileList.scanning and entries.len == 2 and
            entries.allIt(it.kindState != ksUnread): next()
      of 1: # point at the second row
        let r = f.markOf("files.row b shot.sgd")
        if r.size.x > 0:
          at = vec2(r.pos.x + 20, r.pos.y + r.size.y / 2)
          f.moveMouse(at)
          if wait > 3: next()
      of 2: # right click
        if wait == 1:
          f.pressMouse(at, true, 3)
          f.pressMouse(at, false, 3)
        if f.markOf("files.menu b shot.sgd").size.x > 0: next()
        elif wait > 30: failed = "the menu did not open"
      of 3: # point at "Treat as": the submenu opens
        let r = f.markOf("files.menu.treat")
        if r.size.x > 0:
          f.moveMouse(r.centre)
          if wait > 3 and f.markOf("files.menu.item Time-sliced receiver gather").size.x > 0:
            next()
      of 4: # the picture, then the second kind
        if wait > 3:
          if shots.len > 0:
            createDir(shots)
            doAssert f.savePng(shots / "treat-as.png"), "cannot save the Files panel"
          at = f.markOf("files.menu.item Continuous receiver gather").centre
          f.moveMouse(at)
          next()
      of 5: # click it
        if wait == 3:
          f.pressMouse(at, true)
          f.pressMouse(at, false)
        if entries[1].treat.kind == some(rkReceiverContinuous): next()
        elif wait > 30: failed = "the kind was not forced"
      of 6:
        if wait > 3:
          doAssert kindText(entries[1]) == "Continuous *", kindText(entries[1])
          f.stop()
      else: discard
      if failed.len > 0: f.stop()
    let code = run(RunOptions(openPaths: @[dir], windowSize: (1280, 800),
      indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert stage == 6, "stopped at stage " & $stage

when isMainModule:
  main()
