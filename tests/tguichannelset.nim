## The Channel set header row in the running frontend, headless, on
## samples/vib/vib_signature.sgd (24 auxiliary traces, channel sets 1 to 4
## cycling): the file's automatic rows do not include it; once the user chooses
## it, the row's band is drawn above the plot, the tile holds each trace's
## channel set in words and the panel knows the field. `HANDTEST_SHOTS=<dir>`
## saves handtest-chanset.png there.
##
## Seen to fail: with the row's band not drawn for the field (`drawHeader` not
## given the field), "the Channel set row is not drawn".
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
    var wait = 0
    var since = getMonoTime()
    var failed = ""
    var chosen = 0
    var settle = 0
    var seen = false
    proc onFrame(f: FrameInfo) =
      inc wait
      let k = f.core.findPanel(MainPanel)
      if k >= 0 and f.core.panels[k].laidOut and f.core.panels[k].shown.len > 0:
        if chosen == 0:
          doAssert hfChannelSet notin f.core.panels[k].shownFields,
            "the row is on without being chosen"
          doAssert hfChannelSet in f.core.panels[k].known, "the panel does not know the field"
          f.apply Command(kind: ckHeader, panel: MainPanel,
            header: HeaderChoice(auto: false, fields: @[hfChannelSet]))
          chosen = wait
        elif wait > chosen + 6:
          let tiles = f.core.tiles(k)
          if tiles.len > 0 and tiles[^1].fields == @[hfChannelSet] and
              f.markOf("plot.header.channel set").size.x > 0:
            seen = true
            doAssert tiles[^1].sets.len > 3 and tiles[^1].sets[0].startsWith(
                "1 · ") and
              tiles[^1].sets[3].startsWith("4 · "), $tiles[^1].sets
            inc settle
            if settle == 10:
              if shots.len > 0:
                createDir(shots)
                discard f.savePng(shots / "handtest-chanset.png")
              f.stop()
      if overdue(wait, 600, since):
        failed = if chosen == 0: "the window shows no trace"
                 else: "the Channel set row is not drawn"
        f.stop()
    let code = run(RunOptions(openPaths: @[sample], windowSize: (1500, 900),
        theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(
          fx.dir / "cache"),
      persist: true, configDir: some(fx.dir / "config"), logDir: some(fx.dir /
          "logs"),
      onFrame: onFrame))
    doAssert code == 0, "run() exit code " & $code
    doAssert failed.len == 0, failed
    doAssert seen
    echo "tguichannelset: ok"

when isMainModule: main()
