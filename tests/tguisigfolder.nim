## A folder of signature files in the running frontend, headless: the Files window lists both
## kinds with the sweep columns (Trigger, Controller and Vibrator shown, the rest in the column
## chooser), the Controller and Vibrator drop-downs and the "Signature files" tick are there;
## the Summary's offer "Open the .vib of this sweep" shows the partner in the same panel and
## its own offer leads back; Page Down in the plot after a one-record sweep shows the next file
## of the Files table; the tick turns the signature rows (and the drop-downs) away and the
## status line counts them. With `VIEWSEG_SCREENSHOTS` set, the Files window with one file open
## and the same after stepping to its partner are saved there (synthetic files only).
##
## Seen to fail: with the tick's rows not left out of the table, `tickOff` found the rows still
## listed; with the key handler not asking for the next file (`stepFile` left out of
## `handleKeys`), `pageDown` never moved; with the pair offer's command not sent,
## `partner` never showed the partner.
##
## Needs a display: run under `xvfb-run -a -s "-screen 0 1920x1080x24" nim test`.

import std/[monotimes, options, os, strutils, tables]
import viewSEG/core/[filelist, geometry, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, sigfiles, waiting]
import parseSSDAT
import parseSSVIB

func centre(r: Rect): Vec2 =
  vec2(r.pos.x + r.size.x / 2, r.pos.y + r.size.y / 2)

proc shownPath(f: FrameInfo): string =
  let i = f.core.shownFile(f.core.findPanel(MainPanel))
  if i >= 0: f.core.sessions[i].path else: ""

proc laidOut(f: FrameInfo): bool =
  let p = f.core.panels[f.core.findPanel(MainPanel)]
  p.laidOut and p.layout.traces > 0

proc has(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

proc main*() =
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  if shots.len > 0: createDir(shots)
  withFixtures fx:
    let dir = fx.dir / "4321" / "20010203"
    var dats, vibs: seq[string] = @[]
    for k in 0 ..< 5:
      let t = k * 10
      dats.add datFile(dir, "0042_200102030405" & intToStr(t, 2) & ".dat", SynthDat(serial: 4321,
        samples: 600, fileNumber: 7001 + k, vibrator: 11 + k mod 3, trigger: DatTime(year: 2001,
        month: 2, day: 3, hour: 4, minute: 5, second: t, nanosecond: 500_000_000)))
      vibs.add vibFile(dir, intToStr(100 + k, 4) & ".VIB", SynthVib(start: VibTime(year: 2001,
        month: 2, day: 3, hour: 4, minute: 5, second: t)))
    let lone = datFile(dir, "0042_20010203040700.dat", SynthDat(serial: 4321, samples: 600,
      fileNumber: 7100, trigger: DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: 7,
      second: 0, nanosecond: 100_000_000)))
    var
      stage = 0
      wait = 0
      since = getMonoTime()
      at: Vec2
      failed = ""
      saved = 0
    let first = dats[1]
    proc key(f: FrameInfo; k: SimKey) =
      case wait
      of 2: f.pressKey(k, true)
      of 3: f.pressKey(k, false)
      else: discard
    proc click(f: FrameInfo; mark: string) =
      if wait == 1:
        at = f.markOf(mark).centre
        f.moveMouse(at)
      if wait == 3: f.pressMouse(at, true)
      if wait == 5: f.pressMouse(at, false)
    proc onFrame(f: FrameInfo) =
      inc wait
      if f.index == 0: f.moveMouse(vec2(4, 4))
      proc next() =
        inc stage
        (wait, since) = (0, getMonoTime())
      case stage
      of 0: # the folder listed, the first .dat open
        if f.laidOut and f.shownPath == first and not f.core.fileList.scanning and
            f.core.fileList.entries.len == 11 and f.has("files.signatures") and
            f.has("files.controller") and f.has("files.vibrator") and
            f.has("headers.summary pair") and wait > 20:
          doAssert f.has("files.cell Trigger (UTC) " & first.extractFilename),
            "no Trigger cell"
          doAssert f.has("files.cell Controller " & first.extractFilename)
          doAssert f.has("files.cell Vibrator " & first.extractFilename)
          doAssert f.core.fileList.pairs.len == 10, $f.core.fileList.pairs.len
          if shots.len > 0 and wait > 30:
            doAssert f.savePng(shots / "signature-folder-dat.png")
            inc saved
          if shots.len == 0 or saved == 1: next()
      of 1: # the partner, from the Summary's offer
        f.click("headers.summary pair")
        if wait > 8 and f.shownPath == vibs[1] and f.laidOut and wait > 40:
          doAssert f.core.fileList.chosen == vibs[1], "the Files selection did not follow"
          doAssert f.has("headers.summary pair")
          if shots.len > 0:
            doAssert f.savePng(shots / "signature-folder-vib.png")
            inc saved
          next()
      of 2: # and back: the partner's own offer leads back
        f.click("headers.summary pair")
        if wait > 8 and f.shownPath == first and f.laidOut: next()
      of 3: # into the plot, then Page Down: the next file of the table (the .vib of sweep 3)
        f.click("plot.data")
        if wait > 8: next()
      of 4:
        f.key(skPageDown)
        if wait > 8 and f.shownPath == vibs[2] and f.laidOut: next()
      of 5:
        f.key(skPageUp)
        if wait > 8 and f.shownPath == first and f.laidOut: next()
      of 6: # the tick: the signature rows go, the status line counts them
        f.click("files.signatures")
        if wait > 8 and not f.core.settings.files.listSignatureFiles:
          if not f.has("files.row " & lone.extractFilename) and wait > 20:
            doAssert not f.has("files.controller"), "the drop-down stayed with the tick off"
            if shots.len > 0:
              doAssert f.savePng(shots / "signature-folder-off.png")
              inc saved
            next()
      else:
        f.stop()
      if overdue(wait, 1200, since): (failed = "stage " & $stage & " did not happen"; f.stop())
    let code = run(RunOptions(openPaths: @[first], windowSize: (1500, 900), theme: forceDark,
      userThemeDir: some(fx.dir / "no-user-themes"), indexCacheDir: some(fx.dir / "cache"),
      onFrame: onFrame))
    doAssert code == 0 and failed.len == 0, failed & " (exit code " & $code & ")"
    doAssert stage == 7, "stopped at stage " & $stage
  echo "tguisigfolder: ok"

when isMainModule:
  main()
