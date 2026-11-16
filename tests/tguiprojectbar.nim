## The main toolbar's right end shows the project, where the light / dark
## button was. Headless, driven by real clicks, a project made in a
## temporary folder:
##
## - with none open, dim text "No project"; its tooltip says to open or
##   create one; a click opens the Project menu's items (New, Open, Recent);
## - a project made there shows its name; the tooltip is its folder and, in
##   one line, how many survey files and data folders the state knows;
## - a very long name is shortened in the middle with an ellipsis, and the
##   button does not overlap or move the other toolbar buttons; at a narrow
##   window the name gives way and the icon remains;
## - the light / dark button is gone from the bar; View > Light / dark still
##   changes the theme, and View > Theme still lists the themes.
##
## Checked at 1152 x 720 and 125 % (SDL_VIDEO_X11_SCALING_FACTOR), the size
## a small laptop opens at.
##
## Seen to fail: with the theme button still drawn at the right of the bar
## and no project label, "no project shows No project" did not happen.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

const
  LabelPrefix = "tool.project.label:"
  TipPrefix = "tool.project.tip:"
  LongName = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" &
    "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWEND"

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

func overlaps(a, b: Rect): bool =
  a.size.x > 0 and b.size.x > 0 and
    a.pos.x < b.pos.x + b.size.x - 0.5 and b.pos.x < a.pos.x + a.size.x - 0.5 and
    a.pos.y < b.pos.y + b.size.y - 0.5 and b.pos.y < a.pos.y + a.size.y - 0.5

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

func labelOf(f: FrameInfo): string =
  for n in f.markNames(LabelPrefix):
    return n[LabelPrefix.len .. ^1]

func tipOf(f: FrameInfo): string =
  for n in f.markNames(TipPrefix):
    return n[TipPrefix.len .. ^1]

proc hasInk(f: FrameInfo; r: Rect): bool =
  ## Text was drawn in `r`: several pixels are not the bar colour.
  let bar = f.theme.roles[rlBar]
  let y = int(r.pos.y + r.size.y / 2)
  var n = 0
  var x = int(r.pos.x) + 1
  while x < int(r.pos.x + r.size.x) - 1:
    if distance(f.readPixel(x, y), bar) > 40: inc n
    x += 2
  n >= 3

proc clearOfOthers(f: FrameInfo) =
  ## The project button is on the bar and covers no other toolbar button.
  let btn = f.markOf("tool.project")
  doAssert btn.size.x > 0 and btn.size.y > 0, "no project button on the bar"
  let bar = f.markOf("toolbar")
  doAssert btn.pos.x + btn.size.x <= bar.pos.x + bar.size.x + 1, "the project leaves the bar"
  for n in f.markNames("tool."):
    if n == "tool.project" or n.startsWith("tool.project."): continue
    doAssert not overlaps(btn, f.markOf(n)), n & " overlaps the project button"
  doAssert f.markOf("tool.Light / dark theme").size.x == 0,
    "the light / dark button is still on the bar"

var wait = 0
var since = getMonoTime()
var jobsX = -1'f32

proc runSteps(steps: seq[Step]; opts: RunOptions) =
  var at = 0
  var started = false
  var failed = ""
  var o = opts
  o.onFrame = proc (f: FrameInfo) =
    if at >= steps.len or failed.len > 0:
      f.stop()
      return
    if not started:
      steps[at].act(f)
      started = true
      (wait, since) = (0, getMonoTime())
    else:
      inc wait
      if wait >= 3 and steps[at].done(f):
        inc at
        started = false
      elif overdue(wait, 600, since):
        failed = steps[at].name & " did not happen"
        echo "  label ", f.labelOf, " tip ", f.tipOf, " title ", f.windowTitle,
          " project ", f.core.inProject, " theme ", f.theme.name, " ", f.width, "x",
          f.height, " scale ", f.scale
        let shots = getEnv("VIEWSEG_SCREENSHOTS")
        if shots.len > 0: discard f.savePng(shots / "bar-failed.png")
        f.stop()
  let code = run(o)
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

if getEnv("SDL_VIDEO_DRIVER") notin ["", "x11"]:
  echo "tguiprojectbar: skipped (SDL_VIDEO_DRIVER=", getEnv("SDL_VIDEO_DRIVER"), ")"
  quit 0

withFixtures fx:
  let places = fx.dir / "projects"
  createDir(places)
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  if shots.len > 0: createDir(shots)
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard

  step("no project shows No project", noop, proc (f: FrameInfo): bool =
    result = f.labelOf == "No project" and f.markOf("tool.project").size.x > 0 and
      abs(f.scale - 1.25) < 0.01 and f.width >= 1140 and f.width <= 1160
    if result:
      f.clearOfOthers()
      doAssert f.markOf("tool.project.name").size.x > 0, "No project is not drawn"
      doAssert f.hasInk(f.markOf("tool.project.name")), "No project left no ink"
      doAssert f.windowTitle == "viewSEG", "the title is " & f.windowTitle
      jobsX = f.markOf("tool.Jobs").pos.x
      if shots.len > 0: discard f.savePng(shots / "bar-none.png")
      echo "tguiprojectbar: ", f.width, "x", f.height, " at ", f.scale)

  step("its tooltip offers to open or create one", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("tool.project").centre), proc (f: FrameInfo): bool =
    f.tipOf == "Open or create a project")

  step("a click opens the Project menu's items", proc (f: FrameInfo) =
    f.click(f.markOf("tool.project").centre), proc (f: FrameInfo): bool =
    let item = f.markOf("menu.New project...")
    if item.size.x == 0 and wait mod 6 == 3: f.click(f.markOf("tool.project").centre)
    result = item.size.x > 0 and f.markOf("menu.Open project...").size.x > 0 and
      f.markOf("menu.Recent projects").size.x > 0 and f.markOf("menu.Project...").size.x > 0
    if result and shots.len > 0: discard f.savePng(shots / "bar-menu.png"))

  step("Escape closes that menu", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    f.markOf("menu.New project...").size.x == 0)

  step("View > Theme still lists the themes", proc (f: FrameInfo) =
    f.click(f.markOf("menu.View").centre), proc (f: FrameInfo): bool =
    let theme = f.markOf("menu.Theme")
    if theme.size.x > 0: f.moveMouse(theme.centre)
    elif wait mod 6 == 3: f.click(f.markOf("menu.View").centre)
    f.markOf("menu.theme.follow").size.x > 0 and
      f.markOf("menu.theme.everforest-light").size.x > 0)

  step("View > Light / dark still changes the theme", proc (f: FrameInfo) =
    f.click(f.markOf("menu.View").centre), proc (f: FrameInfo): bool =
    let item = f.markOf("menu.Light / dark")
    if item.size.x > 0 and wait mod 5 == 0: f.click(item.centre)
    elif item.size.x == 0 and wait mod 6 == 3: f.click(f.markOf("menu.View").centre)
    f.theme.mode == tmLight)

  step("a project in a temporary folder shows its name", proc (f: FrameInfo) =
    f.apply(Command(kind: ckNewProject, projectPath: places / "field",
      projectName: "field")), proc (f: FrameInfo): bool =
      result = f.core.inProject and f.labelOf == "field" and
        f.windowTitle == "viewSEG - field"
      if result:
        f.clearOfOthers()
        doAssert f.markOf("tool.project.name").size.x > 0, "the name is not drawn"
        doAssert f.hasInk(f.markOf("tool.project.name")), "the name left no ink"
        doAssert abs(f.markOf("tool.Jobs").pos.x - jobsX) < 1, "Jobs moved"
        if shots.len > 0: discard f.savePng(shots / "bar-named.png"))

  step("the tooltip is the folder and what it holds", proc (f: FrameInfo) =
    f.moveMouse(f.markOf("tool.project").centre), proc (f: FrameInfo): bool =
    let tip = f.tipOf
    tip.len > 0 and f.core.project.dir in tip and "\n" in tip and
      "0 survey files" in tip and "0 data folders" in tip)

  step("a very long name is shortened and nothing overlaps", proc (f: FrameInfo) =
    f.apply(Command(kind: ckNewProject, projectPath: places / "long",
      projectName: LongName)), proc (f: FrameInfo): bool =
      let label = f.labelOf
      result = f.core.project.doc.name == LongName and label.len > 0 and label != LongName and
        "…" in label and label.startsWith("W") and label.endsWith("D")
      if result:
        f.clearOfOthers()
        doAssert label.len < LongName.len, "not shortened"
        doAssert abs(f.markOf("tool.Jobs").pos.x - jobsX) < 1, "a long name moved Jobs"
        doAssert f.markOf("tool.project").pos.x >= f.markOf("tool.Jobs").pos.x +
          f.markOf("tool.Jobs").size.x - 1, "the name sits on Jobs"
        if shots.len > 0: discard f.savePng(shots / "bar-long.png")
        echo "tguiprojectbar: long name shown as ", label.len, " characters")

  step("a narrow window keeps the icon and drops the name", proc (f: FrameInfo) =
    let jobs = f.markOf("tool.Jobs")
    f.resizeWindow(int(jobs.pos.x + jobs.size.x + jobs.size.y + 28), f.height),
      proc (f: FrameInfo): bool =
      let btn = f.markOf("tool.project")
      result = btn.size.x > 0 and f.markOf("tool.project.name").size.x == 0 and
        not overlaps(btn, f.markOf("tool.Jobs")) and f.labelOf.len == 0
      if result:
        f.clearOfOthers()
        if shots.len > 0: discard f.savePng(shots / "bar-narrow.png"))

  putEnv("SDL_VIDEO_X11_SCALING_FACTOR", "1.25")
  let opts = RunOptions(windowSize: (922, 576), theme: forceDark,
    configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
    indexCacheDir: some(fx.dir / "cache"), userThemeDir: some(fx.dir / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]))
  runSteps(steps, opts)
  delEnv("SDL_VIDEO_X11_SCALING_FACTOR")
echo "tguiprojectbar: done"
