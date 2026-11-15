## The quit on a disk slow to write the settings, in the running frontend,
## headless: a setting changed just before the quit, and every file opened
## in the settings' folder taking 1.5 s (`tests/utils/faultyfs`). The quit
## waits for the write, and meanwhile the window goes on drawing frames
## that say what it waits for ("saving"), its events taken; once `run`
## returns, the setting is in the settings file.
##
## Seen to fail: with the window left as it was during the wait (no `tick`
## given to `shutdown`), "no frame said it was saving".
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils, times]
import viewSEG/core/[geometry, persist, state]
import viewSEG/ui/imgui/app
import utils/[faultyfs, fixtures, waiting]

install()

withFixtures fx:
  let config = fx.dir / "config"
  createDir(config)
  var saving = 0 # frames that said so
  var stopping = false
  var stoppedAt: MonoTime
  let since = getMonoTime()
  proc onFrame(f: FrameInfo) =
    if stopping:
      if f.markOf("saving").size.x > 0: inc saving
    elif f.index >= 10 and f.core.panels[f.core.findPanel(MainPanel)].laidOut:
      fault(config, fkDelay, {foOpen}, delay = initDuration(milliseconds = 1500))
      var s = f.core.settings
      s.theme = "nord" # a theme there is: one that is not falls back to "" at once
      f.apply Command(kind: ckSettings, settings: s)
      stopping = true
      stoppedAt = getMonoTime()
      f.stop()
    elif overdue(f.index, 600, since):
      f.stop()
  let code = run(RunOptions(persist: true, configDir: some(config),
    logDir: some(config / "logs"), openPaths: @[fx.surveySegy()], windowSize: (1280, 800),
    theme: forceDark, userThemeDir: some(config / "no-user-themes"),
    assetDirs: some(@[currentSourcePath().parentDir.parentDir / "assets"]),
    indexCacheDir: some(config / "cache"), onFrame: onFrame))
  let took = getMonoTime() - stoppedAt
  fault(config, fkNone)
  doAssert code == 0, "run() exit code " & $code
  doAssert stopping, "the setting was never changed"
  doAssert "(theme \"nord\")" in readFile(config / SettingsFileName),
    "the setting is not in the settings file"
  doAssert saving > 0, "no frame said it was saving (the quit took " &
    $took.inMilliseconds & " ms)"
  doAssert uiCalls().len == 0, "the UI thread called the file system:\n" &
    uiCalls().join("\n")
  echo "tguiquit: the quit waited ", took.inMilliseconds, " ms for the settings, ", saving,
    " frames saying so"
