## The Messages window's Auto-scroll button, in the running frontend, headless, with real
## pointer events and several hundred lines:
##
## - on, with the view at the end: lines that arrive keep the last line in view;
## - the user scrolls up, the button is switched off and on again: the last line is in view;
## - off: lines that arrive leave the view where the user left it;
## - on, the severity chips toggled: the last line of what is shown is in view.
##
## Seen to fail: with the list followed only while it was already at the end (the old rule),
## "switching it on again left the end out of view"; with the scroll after a new line left
## out, "new lines left the end out of view".
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, log]
import viewSEG/core/state {.all.}
import viewSEG/ui/imgui/[app, shell]
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc lastInView(f: FrameInfo): bool =
  ## Whether the last line of the window is drawn inside the window.
  let (line, win) = (f.markOf("messages.last"), f.markOf("messages"))
  line.size.y > 0 and win.size.y > 0 and line.pos.y + line.size.y <= win.pos.y + win.size.y + 1

proc main*() =
  withFixtures fx:
    var
      stage = 0
      wait = 0
      since = getMonoTime()
      at: Vec2
      stuck = ""
      problems: seq[string]
      held = 0.0'f32
      posted = 0
    proc onFrame(f: FrameInfo) =
      inc wait
      if f.index == 0: f.moveMouse(vec2(4, 4))
      proc click(f: FrameInfo; mark: string): bool =
        if wait == 1:
          at = f.markOf(mark).centre
          f.moveMouse(at)
        if wait == 3: f.pressMouse(at, true)
        if wait == 5: f.pressMouse(at, false)
        wait > 7
      proc next() =
        inc stage
        wait = 0
        since = getMonoTime()
      proc post(n: int; severity = sevInfo) =
        for i in 0 ..< n:
          inc posted
          f.core.mailbox.post Msg(kind: mkLog, entry: LogEntry(time: getTime(),
            severity: severity, source: "test", text: "Line " & $posted))
      proc scrollUp(): bool =
        ## Moves the pointer onto the lines, turns the wheel; true some frames later.
        if wait == 1: f.moveMouse(f.markOf("messages").centre)
        if wait == 4: f.scrollWheel(f.markOf("messages").centre, 400)
        wait > 10
      let scrolled = f.messageScroll
      case stage
      of 0:
        if f.index > 10 and f.markOf("messages").size.y > 0:
          post 400
          next()
      of 1: # on, at the end: more lines
        if wait > 10:
          if not f.lastInView: problems.add "400 lines left the end out of view"
          post 60
          next()
      of 2:
        if wait > 10:
          if not f.lastInView: problems.add "new lines left the end out of view"
          next()
      of 3: # the user scrolled up, then switches it off and on
        if scrollUp():
          if f.lastInView: problems.add "the wheel did not scroll up"
          next()
      of 4:
        if f.click("messages.autoscroll"): next() # off
      of 5:
        if f.click("messages.autoscroll"): next() # on again
      of 6:
        if wait > 8:
          if not f.lastInView: problems.add "switching it on again left the end out of view"
          next()
      of 7: # off: the view stays
        if f.click("messages.autoscroll"): next()
      of 8:
        if scrollUp():
          held = scrolled
          post 60
          next()
      of 9:
        if wait > 10:
          if abs(scrolled - held) > 0.5: problems.add "off: the view moved"
          if f.lastInView: problems.add "off: the end came into view"
          next()
      of 10: # on again, then the chips
        if f.click("messages.autoscroll"): next()
      of 11:
        if wait > 8:
          if not f.lastInView: problems.add "on: the end is out of view before the chips"
          post 20, sevWarning
          next()
      of 12:
        if f.click("messages.warnings"): next() # hide the warnings
      of 13:
        if wait > 8:
          if not f.lastInView: problems.add "chip off: the end is out of view"
          post 30
          next()
      of 14:
        if wait > 8:
          if not f.lastInView: problems.add "chip off, new lines: the end is out of view"
          next()
      of 15:
        if f.click("messages.warnings"): next() # show them
      of 16:
        if wait > 8:
          if not f.lastInView: problems.add "chip on: the end is out of view"
          next()
          f.stop()
      else: discard
      if stage <= 16 and overdue(wait, 3000, since):
        stuck = "nothing came at stage " & $stage
        f.stop()
    let code = run(RunOptions(openPaths: @[], windowSize: (1600, 1000),
      indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert stuck.len == 0, stuck
    doAssert problems.len == 0, problems.join("; ")
    echo "tguimessagescroll: ok"

when isMainModule: main()
