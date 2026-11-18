## Hovering the Seismic plot's context menu, in the middle of the window and at its right
## and bottom edge (where the menu and its submenu and tooltips spill out of the window and
## become windows of their own), never makes the main window lose focus, and every such
## window is non-focusable: a compositor that draws inactive windows dimmer would otherwise
## dim the application while the pointer moves from item to item, and brighten it again
## when the extra window goes away.
##
## Under xvfb there is no window manager, so focus events never come; the test asserts on
## what causes them instead: every viewport window created for a menu, popup or tooltip
## (Dear ImGui's NoFocusOnAppearing and NoFocusOnClick flags) must carry
## SDL_WINDOW_NOT_FOCUSABLE. The main window's focus-lost count is printed but not asserted:
## the X server of xvfb has no window manager and moves the focus to whichever window the
## pointer enters, focusable or not, so it counts a loss that a real desktop does not.
##
## Seen to fail: with the `SDL_SetWindowFocusable(window, false)` call in
## `frames.keepFocusOffPopups` removed, the first popup window is reported as focusable.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/plotink
import viewSEG/ui/imgui/app
import viewSEG/ui/imgui/frames
import sdl3_nim
import imguin/cimgui
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
    var pass = 0 # 0: the menu in the middle of the plot, 1: at its right and bottom edge
    var seenAt: array[2, int]
    var openedAt: array[2, int]
    var lostAt: array[2, int]
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc onFrame(f: FrameInfo) =
      inc wait
      template next() = (stage, wait, since) = (stage + 1, 0, getMonoTime())
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
        let q = if pass == 0: vec2(d.pos.x + d.size.x / 2, d.pos.y + d.size.y / 2)
                else: vec2(d.pos.x + d.size.x - 6, d.pos.y + d.size.y - 6)
        if wait == 1:
          visited.setLen 0
          openedAt[pass] = opened.len
          lostAt[pass] = mainFocusLost
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
          if next.len == 0:
            seenAt[pass] = visited.len
            if pass == 0:
              pass = 1
              f.pressKey(skEscape, true)
              f.pressKey(skEscape, false)
              (stage, wait) = (1, 0)
            else: stage = 3
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
    let code = run(RunOptions(openPaths: @[path], windowSize: (1000, 700),
      theme: forceDark, userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    echo "tguimenufocus: items ", seenAt, ", windows opened ", openedAt, ", focus lost ", lostAt
    doAssert seenAt[0] > 12 and seenAt[1] > 12, "the pointer visited " & $seenAt & " items"
    doAssert opened.len > 0, "no menu or tooltip window was opened: the edge pass did not spill"
    let want = ImGui_ViewportFlags_NoFocusOnAppearing.cint or
        ImGui_ViewportFlags_NoFocusOnClick.cint
    for i, w in opened:
      if (w.viewportFlags and want) == want:
        doAssert (w.sdlFlags and SDL_WINDOW_NOT_FOCUSABLE) != 0,
          "popup window " & $i & " (viewport flags " & $w.viewportFlags & ") is focusable"

when isMainModule:
  main()
