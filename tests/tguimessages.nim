## The Messages window in the running frontend, headless, with real pointer
## events: the errors toggle hides the error lines and shows them again, and
## is kept in the settings; the Auto-scroll toggle too; clicking a line that
## names a trace shows that trace's gather in the plot, the trace selected;
## Clear empties the window, and a new message shows; Export (the save
## dialog's answer) writes every message to a text file.
##
## Seen to fail: with the toggles drawn but `update` ignoring `hidden`, "the
## errors toggle hid nothing"; with the line's click not passed on
## (`showPath` left empty), "the click on the message did not show trace
## 30"; with Clear not moving `cleared`, "Clear left lines".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves messages.png there.
##
## Runs alone: it counts and clicks the lines of the Messages window, where
##   a debug build also warns of a frame over its 50-ms budget.

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, log]
import viewSEG/core/state {.all.}
import viewSEG/ui/imgui/[app, shell]
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func has(lines: seq[Message]; part: string): bool =
  for m in lines:
    if part in m.text: return true
  false

proc main*() =

  withFixtures fx:
    let survey = fx.surveySegy()
    let exported = fx.dir / "out" / "messages.log"
    createDir(exported.parentDir)
    var
      stage = 0
      wait = 0 # frames since the stage began, at `since`
      since = getMonoTime()
      at: Vec2
      reached: seq[string]
      before, hiddenErrors, shownAgain = -1
      kept, scrollOff, jumped, cleared, newShown, wrote = false
      lines: seq[Message]
      stuck = ""
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
      proc next(name: string) =
        reached.add name
        inc stage
        wait = 0
        since = getMonoTime()
      let k = f.core.findPanel(MainPanel)
      case stage
      of 0:
        if f.core.shownFile(k) >= 0 and f.core.panels[k].laidOut:
          let post = f.core.mailbox
          post.post Msg(kind: mkLog, entry: LogEntry(time: getTime(), severity: sevError,
            source: "test", text: "Planted error, nothing to show"))
          post.post Msg(kind: mkLog, entry: LogEntry(time: getTime(), severity: sevWarning,
            source: "test", text: "Planted warning about trace 30",
            loc: Location(file: survey, trace: 30)))
          next "file shown"
      of 1:
        if f.messages.has("Planted warning") and wait > 3:
          before = f.shownMessages
          next "posted"
      of 2:
        if f.click("messages.errors"):
          hiddenErrors = f.shownMessages
          kept = f.core.settings.messages.hidden == {sevError}
          next "hide errors"
      of 3:
        if f.click("messages.errors"):
          shownAgain = f.shownMessages
          next "show errors"
      of 4:
        if f.click("messages.autoscroll"):
          scrollOff = not f.core.settings.messages.autoScroll
          next "auto-scroll"
      of 5:
        if f.click("messages.last"):
          # the gather is read by a job: waited for, not given a number of frames
          let i = f.core.shownFile(k)
          var sel: seq[int]
          for t in f.core.selection.selected: sel.add t
          let there = i >= 0 and f.core.panels[k].layers[0].source.gather == 1 and
            sel == @[f.core.sessions[i].base + 30]
          if wait > 12 and (there or overdue(wait, 400, since)):
            jumped = there
            if getEnv("VIEWSEG_SCREENSHOTS").len > 0:
              createDir(getEnv("VIEWSEG_SCREENSHOTS"))
              discard f.savePng(getEnv("VIEWSEG_SCREENSHOTS") / "messages.png")
            next "jump"
      of 6:
        if f.click("messages.clear"):
          cleared = f.shownMessages == 0
          f.core.mailbox.post Msg(kind: mkLog, entry: LogEntry(time: getTime(),
            severity: sevInfo, source: "test", text: "After the clear"))
          next "clear"
      of 7:
        if wait > 3:
          newShown = f.shownMessages == 1
          postShellEvent ShellEvent(kind: sePathsChosen, dialog: dkExportLog, paths: @[exported])
          next "new line"
      of 8:
        if fileExists(exported) and "After the clear" in readFile(exported) and
            f.messages.has("Messages exported to " & exported):
          wrote = "Planted warning about trace 30" in readFile(exported)
          lines = f.messages
          next "export"
          f.stop()
      else: discard
      if stage <= 8 and overdue(wait, 3000, since):
        stuck = "nothing came at stage " & $stage & ", after " & $reached
        lines = f.messages
        f.stop()

    let code = run(RunOptions(openPaths: @[survey], windowSize: (1600, 1000),
      indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert stuck.len == 0, stuck
    doAssert before > 2, "too few lines to start with: " & $before
    doAssert hiddenErrors == before - 1, "the errors toggle hid nothing: " & $hiddenErrors &
      " of " & $before
    doAssert kept, "the toggle is not in the settings"
    doAssert shownAgain == before
    doAssert scrollOff, "Auto-scroll did not switch off"
    doAssert jumped, "the click on the message did not show trace 30"
    doAssert cleared, "Clear left lines"
    doAssert newShown, "a message after Clear is not shown"
    doAssert wrote, "the export did not write the messages: " & $reached
    doAssert lines.has("Messages exported to " & exported)
    echo "tguimessages: ", reached.join(", ")

when isMainModule:
  main()
