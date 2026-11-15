## The "Import survey" window's units in the running frontend, headless,
## driven by SDL events as the user's mouse sends them: the user enters no
## unit when the headers say it.
##
## - Two files open: a SEG-D record whose headers say nothing of their
##   units, and a SEG-Y file whose binary header says feet, shown in the
##   plot. File > Import > Survey...: the SEG-Y file's row reads feet. Add
##   files... (the test's dialog answers) with the survey's S, R and X
##   files, whose headers say "feet" and 0.3048006096 m a unit (H20, H201:
##   US survey feet, as the user's Morgantown survey does): with nothing
##   typed, the survey's row reads US survey feet with "The SPS headers say
##   ..." under it, and the SEG-Y file's US survey feet with "The headers say
##   feet; taken as US survey feet, as the survey says";
## - metres chosen by hand for the survey: the box says so ("yours"), the
##   choice is the state's for those files, and the SEG-Y file's row keeps
##   its headers' feet (a conflict); "As the headers say" takes it back to US
##   survey feet;
## - the record chosen in the window's file box: its row reads US survey
##   feet, with "The headers do not say; taken as US survey feet, as the
##   survey says";
## - Import: the import's units are US survey feet for both, the status bar
##   and the map label their coordinates "ftUS", and nothing says the units
##   disagree; the files imported, now on the map, are listed once (with
##   the loaded files, ticked), no longer also as added.
##
## Seen to fail: with the dropdown's "As the headers say" left out,
## "taken back: as the headers say" did not happen; with the added files'
## headers never asked for
## (`ckSurveyUnits` not sent), "the units read US survey feet" did not
## happen (the survey's row stayed at "not given"); with the seismic file's
## row taken from its headers alone (`fileUnitOf` not following the
## survey), the same; with the added files kept in their list after the
## import, "usft.s is listed twice".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.
## `VIEWSEG_SCREENSHOTS=<dir>` saves joinunits-*.png there.

import std/[math, monotimes, options, os]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/[app, joindialog]
import viewSEG/view/maplayers
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

proc drive(steps: seq[Step]; paths: seq[string]; dir: string; dialogs: DialogHook) =
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
    indexCacheDir: some(dir / "cache"), dialogs: dialogs, onFrame: onFrame))
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc unitsOnce() =
  withFixtures fx:
    let record = fx.stationsSegd()
    let segy = fx.surveySegy(measurementSystem = 2)
    let sps = fx.surveySpsIn("usft", "feet", "0.3048006096")
    let answer = proc (kind: DialogKind; location: string): seq[string] =
      if kind == dkJoinFiles: @[sps.s, sps.r, sps.x] else: @[]
    var steps: seq[Step]
    proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
      steps.add Step(name: name, act: act, done: done)
    proc noop(f: FrameInfo) = discard
    let both = JoinUnits(survey: suUsFeet, file: suUsFeet, surveyFromHeaders: true,
      fileFromHeaders: true)
    step("the record shown", noop, proc (f: FrameInfo): bool =
      f.core.sessions.len == 1 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
    step("the SEG-Y file open too", proc (f: FrameInfo) =
      f.apply(Command(kind: ckOpen, paths: @[segy])), proc (f: FrameInfo): bool =
      f.core.sessions.len == 2)
    step("File > Import > Survey...", proc (f: FrameInfo) =
      f.click(f.markOf("menu.File").centre), proc (f: FrameInfo): bool =
      let item = f.markOf("menu.Import survey...")
      if item.size.x > 0: f.click(item.centre)
      elif f.markOf("menu.Import").size.x > 0 and f.index mod 10 == 0:
        f.click(f.markOf("menu.Import").centre)
      f.markOf("join.add").size.x > 0)
    step("the units before any survey file", noop, proc (f: FrameInfo): bool =
      result = f.markOf("join.file units").size.x > 0
      if result:
        # The plot shows the SEG-Y file, opened last: the window is about it.
        doAssert f.joinWindow.units == JoinUnits(file: suFeet,
          surveyFromHeaders: true, fileFromHeaders: true), "before: " & $f.joinWindow.units
        doAssert f.joinWindow.fileNote == "", f.joinWindow.fileNote
        f.shot("joinunits-1-empty.png"))
    var frames = 0
    step("Add files...", proc (f: FrameInfo) = f.click(f.markOf("join.add").centre),
      proc (f: FrameInfo): bool =
      inc frames
      frames > 8)
    step("the units read US survey feet", noop, proc (f: FrameInfo): bool =
      result = f.joinWindow.units == both and f.markOf("join.survey said").size.x > 0 and
        f.markOf("join.file note").size.x > 0
      if result:
        doAssert f.joinWindow.fileNote == "The headers say feet; taken as US survey feet, as " &
          "the survey says.", f.joinWindow.fileNote
        doAssert f.core.heads.len == 3, $f.core.heads.len
        for h in f.core.heads:
          doAssert h.done and h.head.unit == suUsFeet, $h
        doAssert f.markOf("join.survey disagree").size.x == 0
        doAssert f.markOf("join.file conflict").size.x == 0
        f.shot("joinunits-2-read.png"))
    proc pickIn(f: FrameInfo; combo, item: string): bool =
      ## Opens dropdown `combo` and clicks its `item`; true once it is shut.
      let at = f.markOf(combo & " " & item)
      if at.size.x > 0 and f.index mod 4 == 0: f.click(at.centre)
      elif at.size.x == 0 and f.index mod 8 == 0: f.click(f.markOf(combo).centre)
      at.size.x == 0
    step("metres chosen by hand for the survey", noop, proc (f: FrameInfo): bool =
      discard f.pickIn("join.survey units", $suMetres)
      result = f.joinWindow.units.survey == suMetres and f.markOf("join.survey yours").size.x > 0
      if result:
        doAssert not f.joinWindow.units.surveyFromHeaders
        var unit = suNotGiven
        doAssert f.core.unitChoices.chosenFor([sps.s, sps.r, sps.x], unit) and unit == suMetres
        # The record follows the survey, as nobody chose its unit.
        doAssert f.joinWindow.units.file == suFeet # (its headers' feet: metres conflicts)
        f.shot("joinunits-2b-yours.png"))
    step("taken back: as the headers say", noop, proc (f: FrameInfo): bool =
      discard f.pickIn("join.survey units", "headers")
      result = f.joinWindow.units == both and f.markOf("join.survey yours").size.x == 0
      if result:
        doAssert f.core.unitChoices.surveys.len == 0, $f.core.unitChoices)
    step("the record chosen", proc (f: FrameInfo) =
      f.click(f.markOf("join.file").centre), proc (f: FrameInfo): bool =
      let item = f.markOf("join.file " & record.extractFilename)
      if item.size.x > 0 and f.index mod 4 == 0: f.click(item.centre)
      result = item.size.x == 0 and f.joinWindow.units == both and
        f.joinWindow.fileNote == "The headers do not say; taken as US survey feet, as the " &
          "survey says."
      if result:
        doAssert headerUnitOf(f.core.sessions[0].crs) == suNotGiven
        f.shot("joinunits-3-record.png"))
    step("Import", proc (f: FrameInfo) = f.click(f.markOf("join.run").centre),
      proc (f: FrameInfo): bool =
      result = f.core.joinReport.serial > 0 and not f.core.importing and
        f.markOf("join.report").size.x > 0
      if result:
        doAssert f.core.joinReport.outcome == joJoined, $f.core.joinReport.words
        let j = f.core.joinedOf(f.core.sessions[0].id)
        doAssert j >= 0 and f.core.joins[j].units == both, "the import's units: " &
          (if j >= 0: $f.core.joins[j].units else: "no import")
        doAssert f.core.unitsOf == "ftUS", "the map and the status bar say " & f.core.unitsOf
        doAssert f.core.unitsDisagree == "", f.core.unitsDisagree
        f.shot("joinunits-4-imported.png"))
    step("the files imported listed once", noop, proc (f: FrameInfo): bool =
      for n in ["usft.s", "usft.r", "usft.x"]:
        doAssert f.markOf("join.survey " & n).size.x > 0, n & " is not listed as loaded"
        doAssert f.markOf("join.added " & n).size.x == 0, n & " is listed twice"
      true)
    drive(steps, @[record], fx.dir, answer)
    echo "tguijoinunits: ", steps.len, " steps, no unit typed"

unitsOnce()

# ------------------------------------------------- Morgantown: pictures --
# With `VIEWSEG_SCREENSHOTS=<dir>` and the example files present (local
# only): the user's Morgantown record, its S, R and X files (US survey feet)
# added in the window, the window before Import and after.

const examples = currentSourcePath().parentDir.parentDir / "exampleFiles"

proc morgantown(dir: string) =
  let base = examples / "sps" / "PGI_NNE_West_Morgantown_3D_Post261019_NAD27_SPCS_WV_N_USFeet"
  let record = examples / "00000151_12900_11300.sgd"
  let answer = proc (kind: DialogKind; location: string): seq[string] =
    if kind == dkJoinFiles: @[base & ".sps", base & ".rps", base & ".xps"] else: @[]
  var steps: seq[Step]
  steps.add Step(name: "the record", act: proc (f: FrameInfo) = discard,
    done: proc (f: FrameInfo): bool =
    f.core.sessions.len == 1 and f.core.panels[f.core.findPanel(MainPanel)].laidOut)
  steps.add Step(name: "File > Import > Survey...", act: proc (f: FrameInfo) =
    f.click(f.markOf("menu.File").centre), done: proc (f: FrameInfo): bool =
    let item = f.markOf("menu.Import survey...")
    if item.size.x > 0: f.click(item.centre)
    elif f.markOf("menu.Import").size.x > 0 and f.index mod 10 == 0:
      f.click(f.markOf("menu.Import").centre)
    f.markOf("join.add").size.x > 0)
  var frames = 0
  steps.add Step(name: "Add files...", act: proc (f: FrameInfo) =
    f.click(f.markOf("join.add").centre), done: proc (f: FrameInfo): bool =
    inc frames
    frames > 8)
  steps.add Step(name: "the units read", act: proc (f: FrameInfo) = f.moveMouse(vec2(4, 4)),
    done: proc (f: FrameInfo): bool =
    result = f.joinWindow.units == JoinUnits(survey: suUsFeet, file: suUsFeet,
      surveyFromHeaders: true, fileFromHeaders: true) and
      f.markOf("join.survey said").size.x > 0
    if result:
      echo "tguijoinunits: Morgantown: ", f.joinWindow.fileNote
      discard f.savePng(dir / "joinunits-morgantown-1.png"))
  steps.add Step(name: "Import", act: proc (f: FrameInfo) =
    f.click(f.markOf("join.run").centre), done: proc (f: FrameInfo): bool =
    result = f.core.joinReport.serial > 0 and not f.core.importing and
      f.markOf("join.report").size.x > 0 and f.core.unitsOf == "ftUS"
    if result:
      f.moveMouse(vec2(4, 4))
      discard f.savePng(dir / "joinunits-morgantown-2.png"))
  let tmp = getTempDir() / ("viewseg-joinunits-" & $getCurrentProcessId())
  drive(steps, @[record], tmp, answer)
  removeDir(tmp)
  echo "tguijoinunits: saved ", dir / "joinunits-morgantown-1.png", " and -2.png"

if shots.len > 0 and fileExists(examples / "00000151_12900_11300.sgd"):
  createDir(shots)
  morgantown(shots)
