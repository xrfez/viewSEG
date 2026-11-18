## Moving the pointer through a context menu never dims the application, headless: with
## a survey loaded and a file whose traces are all auxiliary shown, the Seismic plot's menu
## is opened and the pointer is moved over every item, the "New plot" submenu's too, and in
## every frame Dear ImGui draws no dim layer (`dimmedBy`: no modal popup, no window list).
##
## Not seen to fail: the dim the user saw was not reproduced here (a new project, a survey
## and an all-auxiliary file shown, every item hovered for a second); this is a guard.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/plotink
import viewSEG/ui/imgui/app
import utils/[fixtures, vibfiles, waiting]

proc main*() =
  withFixtures fx:
    let path = fx.vibFourSegy()
    let sps = fx.mapSpsIn("dim-survey", "Metres", "1")
    let xps = fx.mapXps()
    var stage = 0
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var visited: seq[string]
    var at = 0
    var dwell = getMonoTime()
    var seen = 0
    # Pixels of the window far from the menu and from anything that changes with the
    # pointer: the menu bar's and toolbar's empty parts, the Files panel's empty part.
    const probes = [(700, 12), (700, 46), (150, 420)]
    var still: seq[Rgba]
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc onFrame(f: FrameInfo) =
      inc wait
      template next() = (stage, wait, since) = (stage + 1, 0, getMonoTime())
      if stage >= 2 and stage < 3 and failed.len == 0:
        let what = "stage " & $stage & ", item " & (if at < visited.len: visited[at] else: "-")
        if f.modalOpen: failed = what & ": a modal popup is open"
        elif stage >= 2:
          for i, p in probes:
            let now = f.readPixel(p[0], p[1])
            if now != still[i]:
              failed = what & ": the pixel " & $p & " went from " & $still[i] & " to " & $now &
                " (the application is dimmed)"
      case stage
      of 0:
        if wait == 1:
          f.apply Command(kind: ckNewProject, projectPath: fx.dir / "dim-project",
            projectName: "dim", dataFolders: @[fx.dir])
        if wait == 5: f.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, xps])
        if wait > 30 and f.panel.laidOut and f.markOf("plot.data").size.x > 0 and
            f.core.survey.layers.len >= 3 and f.core.jobs.active.len == 0:
          next()
      of 1:
        let d = f.markOf("plot.data")
        let q = vec2(d.pos.x + d.size.x / 2, d.pos.y + d.size.y / 2)
        if wait == 1:
          for p in probes: still.add f.readPixel(p[0], p[1]) # nothing open: the plain colours
        if wait == 2: f.moveMouse(q)
        if wait == 5:
          f.pressMouse(q, true, 3)
          f.pressMouse(q, false, 3)
        if wait > 8 and f.markOf("plot.menu").size.x > 0: next()
      of 2: # the pointer over each item in turn, a second on each (the tooltips and the
            # submenu open after a delay), every item drawn so far, the submenu's too
        if wait == 1 or (getMonoTime() - dwell).inMilliseconds > 1000:
          var next = ""
          for n in f.markNames("plot.menu."):
            if n notin visited and "item " notin n and n != "plot.menu.target" and
                f.markOf(n).size.x > 0:
              next = n
              break
          if next.len == 0: stage = 3
          else:
            visited.add next
            at = visited.len - 1
            let r = f.markOf(next)
            f.moveMouse(vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2))
            dwell = getMonoTime()
            inc seen
      else: f.stop()
      if overdue(f.index, 6000, since): (failed = "timed out in stage " & $stage & ": laidOut " &
        $f.panel.laidOut & ", plot " &
        $f.markOf("plot.data").size.x & ", layers " & $f.core.survey.layers.len & ", jobs " &
        $f.core.jobs.active.len; f.stop())
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert seen > 12, "the pointer visited " & $seen & " items"
    echo "tguimenudim: no dim over ", seen, " items"

when isMainModule:
  main()
