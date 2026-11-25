## Survey files in the running frontend, headless: a folder's SPS and P1
## files are listed as what they are beside its seismic file; a click on a
## survey file's row (a real pointer move and button press) loads it into
## the survey and marks the row with a pin, and the plot stays on the
## seismic file; survey files dropped on the window are loaded too; the
## shown file's positions are in the survey. One file of each kind (R, S, X, O) is loaded at
## a time: a second R file loaded takes the first one's place, and of a dropped S file and
## P1 file (both sources) the later stays.
##
## Seen to fail: with a second R file added to the first, "replaced" found both pinned;
## with the pin not drawn (its mark taken out), it "stopped
## before clicked"; with `drop` sending no command for what was dropped, it
## "stopped before dropped".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves files-survey.png there (survey files
## listed and loaded).

import std/[math, monotimes, options, os, sequtils, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc shownPath(f: FrameInfo): string =
  let i = f.core.shownFile(f.core.findPanel(MainPanel))
  if i >= 0: f.core.sessions[i].path else: ""

proc main*() =

  withFixtures fx:
    let dir = fx.dir / "line 3"
    createDir(dir)
    let sps = fx.plantedSps()
    for p in [sps.r, sps.s, fx.surveyP1(), fx.surveySegy()]:
      copyFile(p, dir / p.extractFilename)
    let second = dir / "second.r"
    copyFile(sps.r, second)
    let shown = dir / "survey-clean.sgy"
    let shots = getEnv("VIEWSEG_SCREENSHOTS")
    var
      stage = 0
      wait = 0      # frames since the stage began, at `since`
      since = getMonoTime()
      at: Vec2
      reached: seq[string]
      lines: seq[Message]
      kinds: seq[string]
      stayed = true
      saved = false
      pinned = true # the first R file still pinned when the second is
      once = false
    proc next(f: FrameInfo; what: string) =
      reached.add what
      inc stage
      (wait, since) = (0, getMonoTime())
    proc onFrame(f: FrameInfo) =
      inc wait
      if f.index == 0: f.moveMouse(vec2(4, 4))
      if stage > 0 and f.shownPath != shown: stayed = false
      case stage
      of 0: # listed, the seismic file shown, its positions read
        if not f.core.fileList.scanning and f.shownPath == shown and
            f.core.survey.layers.len == 1 and f.markOf("files.row planted.r").size.x > 0:
          for e in f.core.fileList.entries: kinds.add e.name & " " & $e.kind
          at = f.markOf("files.row planted.r").centre
          f.moveMouse(at)
          f.next "listed"
      of 1: # a click on planted.r: loaded, pinned (the first click brings the
        # Files window forward only)
        if wait == 3: f.pressMouse(at, true)
        if wait == 5: f.pressMouse(at, false)
        if wait == 10: f.pressMouse(at, true)
        if wait == 12: f.pressMouse(at, false)
        if wait > 12 and f.core.survey.findFile(dir / "planted.r") >= 0 and
            f.markOf("files.loaded planted.r").size.x > 0:
          f.next "clicked"
      of 2: # a second R file loaded: it takes the first one's place
        if wait == 1: f.apply Command(kind: ckLoadSurvey, paths: @[second])
        if wait > 1 and f.core.survey.findFile(second) >= 0 and
            f.markOf("files.loaded second.r").size.x > 0:
          pinned = f.markOf("files.loaded planted.r").size.x > 0
          once = f.core.survey.findFile(dir / "planted.r") < 0
          f.next "replaced"
      of 3: # dropped: the other survey files, from where the fixtures are
        if wait == 2:
          if shots.len > 0:
            createDir(shots)
            saved = f.savePng(shots / "files-survey.png")
          f.dropPaths([sps.s, sps.x, fx.surveyP1()])
        # the S file and the P1 file both hold sources: the later of the two stays
        if wait > 2 and f.core.survey.findFile(sps.x) >= 0 and
            f.core.survey.findFile(fx.surveyP1()) >= 0 and
            f.messages.anyIt("planted.s" in it.text):
          lines = f.messages
          f.next "dropped"
          f.stop()
      else: discard
      if overdue(wait, 3000, since): # given up: the checks below say what is missing
        lines = f.messages
        f.stop()

    let code = run(RunOptions(openPaths: @[dir], windowSize: (1600, 1000),
      indexCacheDir: some(fx.dir / "cache"), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    const order = ["listed", "clicked", "replaced", "dropped"]
    for i, s in order:
      doAssert reached.len > i, "stopped before \"" & s & "\": reached " & $reached &
        "; Messages: " & $lines
    doAssert kinds == @["planted.r SPS R", "planted.s SPS S", "second.r SPS R",
      "survey-clean.sgy SEG-Y", "survey.p1 P1"], $kinds
    doAssert once and not pinned, "the first R file stayed with the second: " & $(once, pinned)
    doAssert stayed, "the plot left the seismic file"
    var said = false
    for m in lines:
      if "Loaded planted.r (SPS R)" in m.text: said = true
    doAssert said, $lines
    if shots.len > 0:
      doAssert saved, "no screenshot"
      echo "tguisurvey: saved ", shots / "files-survey.png"
    echo "tguisurvey: ", reached.len, " steps: ", reached.join(", ")

when isMainModule:
  main()
