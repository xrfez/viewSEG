## The Files window watching its folder, in the running frontend, headless:
## a file that appears while the window is open is listed with the "new"
## mark, and one that grows with the "being written" mark, while the plot
## stays on the file shown; a click on "Latest" turns "Follow the latest"
## on (a setting) and shows the new file; the growing one is shown once it
## is completely written; a second click turns it off.
##
## Seen to fail: with the marks not drawn (`markOf` returning ""), it
## "stopped before marks"; with the "Latest" button's click not turned into
## the setting, it "stopped before follow".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves files-watch.png there (the new and the
## growing file marked).

import std/[math, monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, state]
import viewSEG/view/theme
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc shownPath(f: FrameInfo): string =
  let i = f.core.shownFile(f.core.findPanel(MainPanel))
  if i >= 0: f.core.sessions[i].path else: ""

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

proc status(f: FrameInfo; path: string): (bool, FileStatus, bool) =
  ## Listed, and its status and new mark.
  let i = f.core.fileList.find(path)
  if i < 0: (false, fsSteady, false)
  else: (true, f.core.fileList.entries[i].status, f.core.fileList.entries[i].isNew)

withFixtures fx:
  let dir = fx.dir / "line 9"
  createDir(dir)
  copyFile(fx.surveySegy(), dir / "shot1.sgy")
  copyFile(fx.twoSetSegd(), dir / "shot2.sgd")
  copyFile(fx.threeComponentSegd(), dir / "shot3.sgd")
  let growing = readFile(fx.longSpreadSegy())
  let fresh = fx.mixedOrderSegd()
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  var
    stage = 0
    wait = 0                # frames since the stage began, at `since`
    since = getMonoTime()
    at: Vec2
    reached: seq[string]
    lines: seq[Message]
    written = 0
    wroteAt = getMonoTime() # when `grow` wrote last
    grower: File
    stayed = true
    saved = false
  proc next(f: FrameInfo; what: string) =
    reached.add what
    inc stage
    (wait, since) = (0, getMonoTime())
  proc grow(upTo: int) =
    ## Another program writing shot5.sgy: 256 bytes at a time, at most 20
    ## times a second (over a minute for the whole file, however fast the
    ## frames), so it changes at every look (a second apart, more on a
    ## loaded machine) until the rest is written at once.
    if written < upTo and getMonoTime() - wroteAt >= initDuration(milliseconds = 50):
      wroteAt = getMonoTime()
      let n = min(256, upTo - written)
      grower.write growing[written ..< written + n]
      grower.flushFile()
      written += n
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    let shown = f.shownPath
    case stage
    of 0: # listed, the first file shown; then a new file, and one being written
      if not f.core.fileList.scanning and shown == dir / "shot1.sgy" and f.laidOut:
        copyFile(fresh, dir / "shot4.sgd")
        grower = open(dir / "shot5.sgy", fmWrite)
        f.next "listed"
    of 1: # both marked; the plot stays on shot1
      grow(growing.len - 1)
      if shown != dir / "shot1.sgy": stayed = false
      let (newListed, newStatus, isNew) = f.status(dir / "shot4.sgd")
      let (grows, growStatus, _) = f.status(dir / "shot5.sgy")
      if newListed and newStatus == fsSteady and isNew and grows and growStatus == fsWriting and
          f.markOf("files.mark shot4.sgd").size.x > 0 and
          f.markOf("files.mark shot5.sgy").size.x > 0:
        if wait > 3:
          if shots.len > 0:
            createDir(shots)
            saved = f.savePng(shots / "files-watch.png")
          at = f.markOf("files.follow").centre
          f.moveMouse(at)
          f.next "marks"
    of 2: # "Latest": the new file is shown
      grow(growing.len - 1) # still being written
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
      if wait > 5 and f.core.settings.files.followLatest and shown == dir / "shot4.sgd" and
          f.laidOut:
        f.next "follow"
    of 3: # the rest of shot5 written: shown once whole
      if grower != nil: grower.write growing[written .. ^1]
      written = growing.len
      if written == growing.len and grower != nil:
        grower.close()
        grower = nil
      if shown == dir / "shot5.sgy" and f.laidOut and
          f.core.sessions[f.core.shownFile(0)].len == LongSpread:
        f.next "followed"
    of 4: # "Latest" again: off
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
      if wait > 5 and not f.core.settings.files.followLatest:
        lines = f.messages
        f.next "off"
        f.stop()
    else: discard
    if overdue(wait, 3000, since): # given up: the checks below say what is missing
      lines = f.messages
      f.stop()

  let code = run(RunOptions(openPaths: @[dir], windowSize: (1600, 1000),
    indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
  if grower != nil: grower.close()
  doAssert code == 0, "run() exit code " & $code
  const order = ["listed", "marks", "follow", "followed", "off"]
  for i, s in order:
    doAssert reached.len > i, "stopped before \"" & s & "\": reached " & $reached &
      "; Messages: " & $lines
  doAssert stayed, "the plot left the file shown before Follow was on"
  if shots.len > 0:
    doAssert saved, "no screenshot"
    echo "tguiwatch: saved ", shots / "files-watch.png"
  echo "tguiwatch: ", reached.len, " steps: ", reached.join(", ")
