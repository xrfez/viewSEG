## View > Theme in the running frontend, headless, driven by real clicks
## and pointer moves (SDL events), with every shipped theme:
##
## - the submenu lists "Follow system" first, then every dark theme, then
##   every light one, each group in the order of the themes' names;
## - each entry has a swatch beside its name: White's shows its white
##   window colour and its black text in the dark menu, Tokyo Night's its
##   window colour;
## - the pointer resting on an entry draws the whole program in that theme
##   (Tokyo Night, then White), and closing the menu without a click goes
##   back to the theme before (Everforest Dark), the settings untouched;
## - a click on an entry keeps it (Catppuccin Latte), in the settings too,
##   and the menu then ticks it;
## - started in a named theme (Nord, as `VIEWSEG_THEME=nord` does) with the
##   settings following the system, a click on "Follow system" after a
##   preview of Tokyo Night draws Everforest Dark, though no setting changes;
## - settings that name a theme no longer shipped (Retro 82) start in the
##   theme Follow system picks, with one plain message, and the settings
##   then follow the system.
##
## Seen to fail: with the preview not reverted when the submenu closes
## (`previewWanted` left as it was), "Escape: back to Everforest Dark did not
## happen"; with a pick that changes no setting left to the settings
## (`previewKept` set, nothing applied), "drawn in Tokyo Night after the menu
## closed"; with a theme the settings name and no file holds left as it was
## (the built-in theme and a warning), "messages about retro-82" held a
## warning and the settings kept retro-82; with the entries in file order, "Catppuccin Latte (light) is
## listed among the dark ones"; with no swatch drawn, "White's swatch: 0
## white pixels".
##
## `VIEWSEG_SCREENSHOTS=<dir>` also saves the menu open (themes-menu.png)
## and previewing Tokyo Night (themes-preview.png) there.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[algorithm, math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, persist, state]
import viewSEG/ui/imgui/app
import viewSEG/view/theme
import utils/[fixtures, waiting]

type
  Step = object
    name: string
    act: proc (f: FrameInfo)
    done: proc (f: FrameInfo): bool

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

let assets = currentSourcePath().parentDir.parentDir / "assets"
let shipped = themeFiles([assets / "themes"])

var wait = 0 ## frames since the step began, at `since`
var since = getMonoTime()

proc drive(steps: seq[Step]; opts: RunOptions) =
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
      elif overdue(wait, 300, since):
        failed = steps[at].name & " did not happen"
        f.stop()
  let code = run(o)
  doAssert code == 0, "run() exit code " & $code
  doAssert failed.len == 0, failed
  doAssert at == steps.len, "stopped at " & steps[min(at, steps.high)].name

proc click(f: FrameInfo; at: Vec2) =
  f.moveMouse(at)
  f.pressMouse(at, true)
  f.pressMouse(at, false)

proc swatchPixels(f: FrameInfo; file: string; c: Rgba): int =
  ## Pixels of colour `c` in the left part of the entry of `file`, where
  ## its swatch is drawn.
  let r = f.markOf("menu.theme." & file)
  result = 0
  for y in int(r.pos.y) ..< int(r.pos.y + r.size.y):
    for x in int(r.pos.x) ..< int(r.pos.x + r.size.y * 3.2):
      if distance(f.readPixel(x, y), c) <= 6: inc result

proc shot(f: FrameInfo; name: string) =
  let dir = getEnv("VIEWSEG_SCREENSHOTS")
  if dir.len > 0:
    createDir(dir)
    doAssert f.savePng(dir / name), name

proc themeOf(file: string): Theme =
  result = builtinTheme(tmDark)
  for t in shipped:
    if t.name == file: result = t.theme

withFixtures fx:
  doAssert shipped.len >= 23, $shipped.len & " themes"
  let opts = RunOptions(windowSize: (1400, 1000), theme: forceDark,
    userThemeDir: some(fx.dir / "no-user-themes"), assetDirs: some(@[assets]),
    indexCacheDir: some(fx.dir / "cache"))
  var steps: seq[Step]
  proc step(name: string; act: proc (f: FrameInfo); done: proc (f: FrameInfo): bool) =
    steps.add Step(name: name, act: act, done: done)
  proc noop(f: FrameInfo) = discard

  proc openThemes(name: string) =
    ## Steps: View clicked, then the pointer on Theme, until its entries show.
    step(name & ": View", proc (f: FrameInfo) = f.click(f.markOf("menu.View").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.Theme").size.x > 0)
    step(name & ": Theme", proc (f: FrameInfo) = f.moveMouse(f.markOf("menu.Theme").centre),
      proc (f: FrameInfo): bool = f.markOf("menu.theme.white").size.x > 0)

  proc rest(file, name: string) =
    ## A step: the pointer rests on `file`'s entry until the program is drawn
    ## in it.
    step("resting on " & name, proc (f: FrameInfo) =
      let r = f.markOf("menu.theme." & file)
      f.moveMouse(vec2(round(r.pos.x + r.size.x * 0.6), round(r.pos.y + r.size.y / 2))),
      proc (f: FrameInfo): bool = f.theme.name == name)

  step("the program starts", noop, proc (f: FrameInfo): bool =
    f.theme.name == "Everforest Dark" and f.markOf("menu.View").size.x > 0)
  openThemes("the menu")
  step("the entries' order", noop, proc (f: FrameInfo): bool =
    result = true
    var dark, light: seq[(float32, string)]
    for t in shipped:
      let r = f.markOf("menu.theme." & t.name)
      doAssert r.size.x > 0, t.name & " is not listed"
      if t.theme.mode == tmDark: dark.add (r.pos.y, t.theme.name)
      else: light.add (r.pos.y, t.theme.name)
    let follow = f.markOf("menu.theme.follow")
    doAssert follow.size.x > 0, "no Follow system"
    for (y, name) in dark & light:
      doAssert y > follow.pos.y, name & " is above Follow system"
    for (y, name) in light:
      for (yd, _) in dark:
        doAssert y > yd, name & " (light) is listed among the dark ones"
    for group in [dark, light]:
      var byPlace = group
      byPlace.sort()
      var names: seq[string]
      for (_, n) in byPlace: names.add n
      doAssert names == names.sorted, "not in order of names: " & $names)
  step("the swatches", noop, proc (f: FrameInfo): bool =
    result = true
    let white = f.swatchPixels("white", Rgba(r: 255, g: 255, b: 255, a: 255))
    doAssert white >= 20, "White's swatch: " & $white & " white pixels"
    let black = f.swatchPixels("white", Rgba(a: 255))
    doAssert black >= 4, "White's swatch: " & $black & " black pixels"
    let tokyo = f.swatchPixels("tokyo-night", themeOf("tokyo-night").roles[rlWindow])
    doAssert tokyo >= 20, "Tokyo Night's swatch: " & $tokyo & " pixels of its window colour"
    f.shot("themes-menu.png"))
  rest("tokyo-night", "Tokyo Night")
  step("Tokyo Night drawn", noop, proc (f: FrameInfo): bool =
    result = true
    let bar = f.markOf("menu.View")
    doAssert distance(f.readPixel(int(bar.pos.x) - 4, int(bar.pos.y) + 2),
      themeOf("tokyo-night").roles[rlBar]) <= 2, "the menu bar is not Tokyo Night's"
    doAssert f.core.settings.theme == "", "a preview changed the settings"
    f.shot("themes-preview.png"))
  rest("white", "White")
  step("Escape: back to Everforest Dark", proc (f: FrameInfo) =
    f.pressKey(skEscape, true)
    f.pressKey(skEscape, false), proc (f: FrameInfo): bool =
    if wait mod 10 == 9 and f.markOf("menu.Theme").size.x > 0: # a level at a time
      f.pressKey(skEscape, true)
      f.pressKey(skEscape, false)
    f.theme.name == "Everforest Dark" and f.markOf("menu.Theme").size.x == 0)
  step("nothing kept", noop, proc (f: FrameInfo): bool =
    doAssert f.core.settings.theme == "", "the settings say " & f.core.settings.theme
    wait > 10 and f.theme.name == "Everforest Dark")
  openThemes("again")
  rest("catppuccin-latte", "Catppuccin Latte")
  step("a click keeps Catppuccin Latte", proc (f: FrameInfo) =
    f.click(f.markOf("menu.theme.catppuccin-latte").centre), proc (f: FrameInfo): bool =
    f.markOf("menu.Theme").size.x == 0 and f.core.settings.theme == "catppuccin-latte")
  step("still Catppuccin Latte", noop, proc (f: FrameInfo): bool =
    wait > 20 and f.theme.name == "Catppuccin Latte")
  openThemes("ticked")
  step("Catppuccin Latte ticked", noop, proc (f: FrameInfo): bool =
    # Dear ImGui draws a menu item's tick at its right end, in the text colour
    let r = f.markOf("menu.theme.catppuccin-latte")
    let other = f.markOf("menu.theme.catppuccin")
    proc ink(q: Rect): int =
      for y in int(q.pos.y) ..< int(q.pos.y + q.size.y):
        for x in int(q.pos.x + q.size.x - q.size.y * 1.5) ..< int(q.pos.x + q.size.x):
          if distance(f.readPixel(x, y), f.theme.roles[rlText]) <= 40: inc result
    doAssert ink(r) > 4 and ink(other) == 0, "the tick: " & $ink(r) & " on Catppuccin Latte, " &
      $ink(other) & " on Catppuccin"
    true)
  drive(steps, opts)
  echo "tguithemes: ", shipped.len, " themes listed, previewed, reverted and picked"

  # Started in a named theme (VIEWSEG_THEME, `themeName`) while the settings
  # follow the system: a click on "Follow system" after resting on another
  # theme changes no setting, and must still leave the preview.
  steps.setLen 0
  var named = opts
  named.themeName = "nord"
  step("started in Nord", noop, proc (f: FrameInfo): bool =
    f.theme.name == "Nord" and f.markOf("menu.View").size.x > 0 and
      f.core.settings.theme == "")
  openThemes("named")
  rest("tokyo-night", "Tokyo Night")
  step("Follow system clicked", proc (f: FrameInfo) =
    f.click(f.markOf("menu.theme.follow").centre), proc (f: FrameInfo): bool =
    f.markOf("menu.Theme").size.x == 0)
  step("drawn in Everforest Dark, not the preview", noop, proc (f: FrameInfo): bool =
    if wait > 30:
      doAssert f.theme.name == "Everforest Dark", "drawn in " & f.theme.name &
        " after the menu closed"
    wait > 30)
  drive(steps, named)
  echo "tguithemes: a named theme, then Follow system"

  # Settings that name a theme viewSEG no longer ships (Retro 82, taken out
  # for its licence): the program starts in the theme Follow system picks,
  # says so once, plainly, and the settings follow the system from then on.
  steps.setLen 0
  let config = fx.dir / "config"
  createDir(config)
  writeFile(config / SettingsFileName, "(.nif27)\n(.vendor \"viewSEG\")\n(settings\n" &
    " (version 1)\n (theme \"retro-82\"))\n")
  var gone = opts
  (gone.theme, gone.persist, gone.configDir) = (followSystem, true, some(config))
  gone.logDir = some(fx.dir / "logs")
  step("started without Retro 82", noop, proc (f: FrameInfo): bool =
    result = f.markOf("menu.View").size.x > 0 and wait > 5
    if result:
      doAssert f.theme.name in ["Everforest Dark", "Everforest Light"], f.theme.name
      var said: seq[string] = @[]
      for m in f.messages:
        if "retro-82" in m.text: said.add m.text
      doAssert said.len == 1, "messages about retro-82: " & $said
      for m in f.messages:
        doAssert m.level == mlInfo or "theme" notin m.text.toLowerAscii, m.text
      doAssert f.core.settings.theme == "", "the settings say " & f.core.settings.theme
      doAssert f.markOf("menu.View").size.x > 0)
  drive(steps, gone)
  echo "tguithemes: a theme no longer shipped falls back to Follow system"
