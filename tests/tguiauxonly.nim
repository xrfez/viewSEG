## A record whose traces are ALL auxiliary opens with Aux switched on, in the running
## frontend, headless, on samples/vib/vib_signature.sgd (24 auxiliary traces and none
## seismic): the Seismic window shows them (not an empty panel), and Messages says once, in
## a plain sentence, why. `HANDTEST_SHOTS=<dir>` saves handtest-aux.png there.
##
## Seen to fail: with the rule left out, "the window shows no trace" (the panel is empty).
##
## Needs a display: run under the tester, which gives each file its own.

import std/[monotimes, options, os, strutils]
import viewSEG/core/[geometry, panels, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, waiting]

const sample = currentSourcePath().parentDir.parentDir / "samples" / "vib" / "vib_signature.sgd"

proc main*() =
  withFixtures fx:
    doAssert fileExists(sample), sample
    let shots = getEnv("HANDTEST_SHOTS")
    var at = 0
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var settle = 0
    proc onFrame(f: FrameInfo) =
      inc wait
      let k = f.core.findPanel(MainPanel)
      if k >= 0 and f.core.panels[k].laidOut and f.core.panels[k].shown.len > 0:
        inc settle
        if settle == 1:
          doAssert f.core.panels[k].layers[0].filter.auxiliary, "Aux is not on"
          var said = 0
          for e in f.core.log:
            if "is auxiliary" in e.text and "Aux is switched on" in e.text: inc said
          doAssert said == 1, "Messages says it " & $said & " times, not once"
        if settle == 20:
          if shots.len > 0:
            createDir(shots)
            discard f.savePng(shots / "handtest-aux.png")
          f.stop()
          at = 1
      elif overdue(wait, 600, since):
        failed = "the window shows no trace"
        f.stop()
    let code = run(RunOptions(openPaths: @[sample], windowSize: (1500, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir / "logs"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert at == 1, "the file did not show"
    echo "tguiauxonly: ok"

when isMainModule: main()
