## Clear survey in the running frontend, headless, driven by SDL events as the
## user's mouse sends them, on a synthetic SEG-D record and SPS survey:
##
## - Project > Clear survey is there under Import survey..., and with no
##   survey imported a click on it does nothing (no confirmation opens);
## - after the survey is imported, the item works: the confirmation opens in
##   the middle of the window; Cancel changes nothing (the file is still
##   joined, the survey files still on the map);
## - the confirmation's Clear survey takes the survey away: no file joined,
##   no survey file on the map, the file's own coordinates in its keys;
## - the Import survey window's Clear survey button asks the same question
##   (and is disabled while no survey is imported).
##
## Seen to fail: with the item always enabled, "a click with no survey opened
## the confirmation"; with Cancel sending the command, "Cancel changed
## something"; with the confirmation's button sending nothing, "the survey was
## not cleared".
##
## Needs a display: run under the tester, which gives each file its own.
## `VIEWSEG_SCREENSHOTS=<dir>` saves clear-survey-*.png there.

import std/[math, monotimes, options, os, strutils]
import parseSEG
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

let shots = getEnv("VIEWSEG_SCREENSHOTS")

proc shot(f: FrameInfo; name: string) =
  if shots.len > 0:
    createDir(shots)
    discard f.savePng(shots / name)

proc drive(steps: seq[Step]; paths: seq[string]; dir: string) =
  var at = 0
  var started = false
  var wait = 0
  var since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      started = true
      wait = 0
      since = getMonoTime()
    else:
      inc wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 600, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(RunOptions(openPaths: paths, windowSize: (1400, 1000),
    theme: forceDark, userThemeDir: some(dir / "no-user-themes"),
    indexCacheDir: some(dir / "cache"), onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc surveyFiles(f: FrameInfo): int =
  for l in f.core.survey.layers:
    if l.origin == loSurveyFile: inc result

proc main*() =
  withFixtures fx:
    let path = fx.stationsSegd()
    let sps = fx.surveySps()
    var steps: seq[Step]
    var own: TraceKeys
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    proc openImport(f: FrameInfo): bool =
      ## Opens the Project menu by a click; true once the Clear survey item is drawn.
      if f.markOf("menu.Clear survey").size.x > 0: return true
      if f.index mod 10 == 0: f.click(f.markOf("menu.Project").centre)
    step("the record is shown", noop, proc (f: FrameInfo): bool =
      result = f.core.panels[f.core.findPanel(MainPanel)].laidOut and
        f.core.survey.findTraces(f.core.sessions[0].id) >= 0
      if result: own = f.core.sessions[0].file.index.keys[1])
    step("Project: Clear survey is listed", proc (f: FrameInfo) = discard openImport(f),
      openImport)
    step("with no survey, a click does nothing", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Clear survey").centre), proc (f: FrameInfo): bool =
      doAssert f.markOf("survey.clear").size.x == 0, "a click with no survey opened the " &
        "confirmation"
      true)
    step("the menu is closed", proc (f: FrameInfo) =
      f.pressKey(skEscape, true), proc (f: FrameInfo): bool =
      f.pressKey(skEscape, false)
      f.markOf("menu.Clear survey").size.x == 0 or f.index mod 7 == 0)
    proc importIt(f: FrameInfo) =
      f.apply Command(kind: ckJoin, joinFile: f.core.sessions[0].id, joinFiles: @[
        JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
        JoinFile(path: sps.x, kind: jkSps)], joinUnits: JoinUnits(survey: suMetres))
    step("the survey is imported", importIt, proc (f: FrameInfo): bool =
      f.core.joinReport.serial > 0 and not f.core.importing and f.core.joins.len == 1 and
        f.core.sessions[0].file.index.keys[1].rcvX != own.rcvX)
    step("Project again", proc (f: FrameInfo) =
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false), openImport)
    step("the item opens the confirmation", proc (f: FrameInfo) =
      f.shot("clear-survey-menu.png")
      f.click(f.markOf("menu.Clear survey").centre), proc (f: FrameInfo): bool =
      let w = f.markOf("survey.clear")
      result = w.size.x > 0 and f.markOf("survey.clear.confirm").size.x > 0
      if result: doAssert f.markOf("survey.clear.cancel").size.x > 0)
    step("the confirmation is drawn", noop, proc (f: FrameInfo): bool =
      f.shot("clear-survey-confirm.png")
      true)
    step("Cancel changes nothing", proc (f: FrameInfo) =
      f.click(f.markOf("survey.clear.cancel").centre), proc (f: FrameInfo): bool =
      result = f.markOf("survey.clear").size.x == 0
      if result:
        doAssert f.core.joins.len == 1 and f.surveyFiles == 3 and f.core.surveyInEffect,
          "Cancel changed something"
        doAssert f.core.sessions[0].file.index.keys[1].rcvX != own.rcvX)
    step("the window's button asks the same", proc (f: FrameInfo) =
      f.click(f.markOf("menu.Project").centre), proc (f: FrameInfo): bool =
      let item = f.markOf("menu.Import survey...")
      if item.size.x > 0: f.click(item.centre)
      f.markOf("join.clear").size.x > 0)
    step("Clear survey in the window", proc (f: FrameInfo) =
      f.click(f.markOf("join.clear").centre), proc (f: FrameInfo): bool =
      f.markOf("survey.clear.confirm").size.x > 0)
    step("Confirm clears it", proc (f: FrameInfo) =
      f.click(f.markOf("survey.clear.confirm").centre), proc (f: FrameInfo): bool =
      result = not f.core.surveyInEffect and f.core.joins.len == 1 - 1 and
        f.markOf("survey.clear").size.x == 0 and f.core.sessions.len == 1 and
        f.core.panels[f.core.findPanel(MainPanel)].laidOut
      if result:
        doAssert f.surveyFiles == 0, "the survey files are on the map"
        doAssert f.core.sessions[0].file.index.keys[1].rcvX == own.rcvX,
          "the survey was not cleared")
    step("the button is disabled now", noop, proc (f: FrameInfo): bool =
      result = f.markOf("join.clear").size.x > 0
      if result:
        f.click(f.markOf("join.clear").centre)
        doAssert f.markOf("survey.clear").size.x == 0, "the button asked with no survey")
    drive(steps, @[path], fx.dir)
    echo "tguiclearsurvey: ", steps.len, " steps"

when isMainModule:
  main()
