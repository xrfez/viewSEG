## The Store-as-reference dialog says what it takes, headless: on a trace of 12 000 samples
## at 1 ms the boxes read 0 and 11999 (the first and last sample's times) and the line under
## them says "0 to 11 999 ms: 12 000 samples at 1 ms = 12 000 ms (12 s)"; a "To" typed past
## the last sample is brought back to 11999 and the dialog says so. The Messages line after
## Store, and the archive's Length column, give the same 12 000 ms.
## `VIEWSEG_SCREENSHOTS=<dir>` saves storewords.png there (a generated file) and stops
## after the words.
##
## Seen to fail: with the dialog's boxes alone (no "store.taken" line) "no line says what
## the window takes"; with "To" not clamped, "no clamp is said" and the box kept 20000;
## with the length taken as (N - 1)·dt, "11 999 ms" in the line; with the From and To boxes
## not live (Dear ImGui 1.92.9 writes a typed number back only when the box is left:
## `ImGui_ItemFlags_LiveEditOnInputScalar` off), "no clamp is said" when the machine is busy
## (one CPU shared with busy loops).
##
## Needs a display: run under the tester, which gives each file its own.

import std/[math, monotimes, options, os, strutils]
import viewSEG/core/[geometry, references, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

func centre(r: Rect): Vec2 =
  vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc nameWith(f: FrameInfo; prefix: string): string =
  for n in f.markNames(prefix): return n

proc main*() =
  withFixtures fx:
    let path = fx.longTraceSegy(12_000)
    let config = fx.dir / "config"
    createDir(config)
    var stage = 0
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    template panel(f: FrameInfo): untyped = f.core.panels[f.core.findPanel(MainPanel)]
    proc click(f: FrameInfo; q: Vec2; button = 1) =
      f.moveMouse(q)
      f.pressMouse(q, true, button)
      f.pressMouse(q, false, button)
    proc onFrame(f: FrameInfo) =
      inc wait
      template next() = (stage, wait, since) = (stage + 1, 0, getMonoTime())
      let plot = f.markOf("plot.data")
      case stage
      of 0:
        if wait == 1 and getEnv("VIEWSEG_SCREENSHOTS").len > 0: f.keepInMainWindow
        if wait > 10 and f.panel.laidOut and plot.size.x > 0 and f.core.referencesLoaded:
          next()
      of 1: # the menu, then the dialog
        if f.markOf("store").size.x > 0: next()
        elif f.markOf("plot.menu.store").size.x > 0:
          if wait mod 6 == 3: f.click(f.markOf("plot.menu.store").centre)
        elif wait mod 10 == 2: f.click(plot.centre, 3)
      of 2:
        let taken = f.nameWith("store.taken:")
        if wait > 10 and taken.len > 0: # a few frames on: the picture lags the marks
          if "0 to 11 999 ms: 12 000 samples at 1 ms = 12 000 ms (12 s)" notin taken:
            failed = "the line says " & taken
          let dir = getEnv("VIEWSEG_SCREENSHOTS")
          if dir.len > 0:
            createDir(dir)
            discard f.savePng(dir / "storewords.png")
            stage = 99 # a picture only: with the windows kept inside the main one the keys differ
            return
          next()
        elif wait > 60: failed = "no line says what the window takes"
      of 3: # type a To past the end
        let box = f.markOf("store.to")
        if not f.typing:
          if wait mod 8 == 3: f.click(box.centre)
        elif wait mod 8 == 5 and f.nameWith("store.clamped:").len == 0:
          # (the box selects its text when it takes the keyboard, so no select-all key is
          # needed; a held Ctrl makes a box ignore text, and a key pressed and released in
          # one frame reaches Dear ImGui over several)
          f.typeText("20000")
        if f.nameWith("store.clamped:").len > 0:
          let said = f.nameWith("store.clamped:")
          if "11999" notin said: failed = "the clamp says " & said
          if "11 999 ms" notin f.nameWith("store.taken:"):
            failed = "after the clamp: " & f.nameWith("store.taken:")
          f.pressKey(skEnter, true)
          f.pressKey(skEnter, false)
          next()
        elif wait > 80: failed = "no clamp is said"
      of 4: # store it, then the message and the archive
        if f.markOf("store").size.x > 0:
          if wait mod 6 == 3: f.click(f.markOf("store.ok").centre)
        else:
          var said = false
          for e in f.core.log:
            if "Stored the reference" in e.text and
                "12 000 samples at 1 ms = 12 000 ms (12 s)" in e.text: said = true
          if said and f.core.references.entries.len == 1:
            let e = f.core.references.entries[0]
            if lengthText(e) != "12000 ms (12000)": failed = "the column says " & lengthText(e)
            next()
          elif wait > 400: failed = "no Stored message with the length"
      else: f.stop()
      if failed.len > 0 or overdue(f.index, 6000, since):
        if failed.len == 0: failed = "timed out in stage " & $stage
        f.stop()
    let code = run(RunOptions(openPaths: @[path], windowSize: (1400, 900),
      theme: forceDark, persist: true, configDir: some(config),
      logDir: some(fx.dir / "logs"), userThemeDir: some(fx.dir / "no-user-themes"),
      indexCacheDir: some(fx.dir / "cache"), onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    echo "tguistorewords: the dialog says what it takes"

when isMainModule:
  main()
