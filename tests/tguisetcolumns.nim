## The columns of the Channel sets table keep their places, whatever the number
## of channel sets: Description first, one column per set, then the field's
## Bytes (and Name and Offset, when shown), headless. A record of three
## channel sets is shown, then one of four (and then three again): the
## Bytes column stays after the last set both ways, as it does in the
## General and Trace tabs' tables.
##
## Why the table has its own name per number of columns: Dear ImGui, given a
## table of the same name with another number of columns, carries the old
## columns' state over (by index, then by label: the display order, the
## hidden ones, the widths) and a new column can land in the wrong place; and
## settings it saved for the other count are read back by index. The runs here
## (one run showing three sets, four, three; and three runs one after the
## other on the same settings folder) pass with and without the separate
## names in the headless frames, so they guard the order but were not seen
## to fail.
##
## Needs a display: run under the tester, which gives each file its own.

import std/[algorithm, math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, settings, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc columns(f: FrameInfo): seq[string] =
  ## The labels of the Channel sets table's shown columns, in their places.
  const prefix = "headers.sets column "
  var cols: seq[(int, string)]
  for n in f.markNames(prefix):
    let rest = n[prefix.len .. ^1]
    let gap = rest.find(' ')
    cols.add (parseInt(rest[0 ..< gap]), rest[gap + 1 .. ^1])
  cols.sort()
  for (at, name) in cols: result.add name

type Visit = tuple[path: string, sets: int]

proc visit(plan: openArray[Visit]; config, cache: string) =
  ## Starts on `plan[0]` and shows each file of `plan` in turn in one run; at
  ## each, the Channel sets table's columns must be in their places.
  let plan = @plan
  var at = 0 # the file under test
  var phase = 0 # 0 settings and plot, 1 the tab, 2 show, 3 settle, 4 check
  var wait = 0
  var since = getMonoTime()
  proc click(f: FrameInfo; mark: string) =
    let q = f.markOf(mark).centre
    f.moveMouse(q)
    if wait mod 6 == 3: f.pressMouse(q, true)
    if wait mod 6 == 5: f.pressMouse(q, false)
  proc onFrame(f: FrameInfo) =
    inc wait
    template go(p: int) = (phase, wait, since) = (p, 0, getMonoTime())
    let tab = "headers.file tab Channel sets"
    case phase
    of 0:
      if wait == 1:
        var s = f.core.settings
        s.headers.columns = {hcDescription, hcName, hcBytes, hcOffset}
        f.apply Command(kind: ckSettings, settings: s)
      if f.markOf("plot.data").size.x > 0 and wait > 5: go(1)
    of 1: # the tab, when the window shows another
      if f.columns.len > 0 and wait > 10: go(4)
      elif f.markOf(tab).size.x > 0: f.click(tab)
      elif f.markOf("headers.tab file").size.x > 0: f.click("headers.tab file")
    of 2:
      f.apply Command(kind: ckShowFile, panel: MainPanel, path: plan[at].path)
      go(3)
    of 3:
      let want = "Set " & $plan[at].sets
      if wait > 10 and want in f.columns and "Set " & $(plan[at].sets + 1) notin f.columns:
        go(4)
      elif f.columns.len == 0 and f.markOf(tab).size.x > 0:
        f.click(tab) # (the tab shown may be General again)
    of 4:
      if wait > 10:
        var want = @["Description"]
        for k in 1 .. plan[at].sets: want.add "Set " & $k
        want.add ["Name", "Bytes", "Offset"]
        doAssert f.columns == want, "the columns are in the order " & $f.columns & " for " &
          plan[at].path.extractFilename & " (" & $plan[at].sets & " sets, file " & $at & ")"
        inc at
        go(if at < plan.len: 2 else: 5)
    else: f.stop()
    if overdue(f.index, 3000, since): doAssert false, "timed out in phase " & $phase
  let code = run(RunOptions(openPaths: @[plan[0].path], windowSize: (1600, 1000),
    theme: forceDark, persist: true, configDir: some(config), indexCacheDir: some(cache),
    onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert phase == 5, "stopped in phase " & $phase

proc main*() =
  withFixtures fx:
    let three = (fx.lateStartSegd(1000), 3)
    let four = (fx.twoSetSegd(), 4)
    # in one run, a file of more sets, then of fewer
    visit([three, four, three], fx.dir / "config-run", fx.dir / "cache")
    # a table saved with the settings by one run, a record of another count in the next
    let kept = fx.dir / "config-kept"
    createDir(kept)
    visit([three], kept, fx.dir / "cache")
    visit([four], kept, fx.dir / "cache")
    visit([three], kept, fx.dir / "cache")
    echo "tguisetcolumns: ok"

when isMainModule:
  main()
