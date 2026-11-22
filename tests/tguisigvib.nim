## The Vibrator window on a signature file in the running program, headless, on synthetic
## sweeps:
##
## - a `.dat` whose ground force is opposite to the reference: the polarity line is drawn under
##   the verdict with the button "Reverse the ground force for the analysis"; pressing it puts
##   the choice in the window ("As recorded" is then the button) and the roles line says so;
##   the controller's table is drawn; the force scale box is in the set-up, and once a scale is
##   set the 100 % force says where it comes from;
## - a `.vib` with its `.dat`: the accelerometer set choice (pressing A makes it the window's
##   set), the weights line and the sentence that the scaled reference depends on the
##   hold-down weight, the controller's table "from the .dat of this sweep";
## - a folder of `.vib` files of three vibrators, one of them with other weights: the weights
##   per vibrator open by themselves and say the difference in words.
##
## With `VIEWSEG_SCREENSHOTS` set, a picture of each step is saved there (synthetic files only).
##
## Seen to fail: with the polarity line not drawn, "no polarity line"; with the button's click
## not reaching the window ("Reverse" drawn without a command), "the choice was not made".

import std/[math, monotimes, options, os, strutils, times]
import parseSSDAT
import parseSSVIB
import viewSEG/core/[analysis, filelist, geometry, settings, state]
import viewSEG/ui/imgui/app
import utils/[fixtures, sigfiles, waiting]

func centre(r: Rect): Vec2 = vec2(round(r.pos.x + r.size.x / 2), round(r.pos.y + r.size.y / 2))

proc shown(f: FrameInfo; mark: string): bool = f.markOf(mark).size.x > 0

proc click(f: FrameInfo; mark: string) =
  let c = f.markOf(mark).centre
  f.moveMouse(c)
  f.pressMouse(c, true)
  f.pressMouse(c, false)

type Step = object
  name: string
  act: proc (f: FrameInfo)
  done: proc (f: FrameInfo): bool

template step(list: var seq[Step]; stepName: string; actBody, doneBody: untyped) =
  ## One step: `actBody` runs once (`f` is the frame), `doneBody` is true when it is done.
  list.add Step(name: stepName,
    act: proc (f {.inject.}: FrameInfo) = actBody,
    done: proc (f {.inject.}: FrameInfo): bool = doneBody)

proc steps(file: string; tmp: string; list: seq[Step]; browse = "") =
  ## Runs `list` in order, each acting once when it is reached and done when its condition
  ## holds for a few frames; `file` is shown first (after `browse`, a folder, is listed).
  var at = 0
  var acted = false
  var wait = 0
  var browsed = browse.len == 0
  var shownFile = false
  let since = getMonoTime()
  var failed = ""
  proc onFrame(f: FrameInfo) =
    inc wait
    if f.index == 0: f.moveMouse(vec2(4, 4))
    if not browsed:
      f.apply Command(kind: ckBrowse, paths: @[browse])
      f.apply Command(kind: ckSubfolders, subfolders: true)
      browsed = true
    elif not shownFile:
      if browse.len == 0 or (not f.core.fileList.scanning and f.core.fileList.entries.len > 1):
        f.apply Command(kind: ckShowFile, panel: MainPanel, path: file)
        shownFile = true
    elif at < list.len:
      let s = list[at]
      if f.core.sessions.len > 0 and wait > 5:
        if not acted:
          if s.act != nil: s.act(f)
          (acted, wait) = (true, 0)
        elif wait > 10 and s.done(f):
          (at, acted, wait) = (at + 1, false, 0)
    else:
      f.stop()
    if overdue(f.index, 4000, since):
      failed = (if at < list.len: "step \"" & list[at].name & "\" did not finish" else: "end")
      f.stop()
  let code = run(RunOptions(windowSize: (1500, 1000), theme: forceDark,
    userThemeDir: some(tmp / "no-user-themes"), indexCacheDir: some(tmp / "cache"),
    openPaths: (if browse.len == 0: @[file] else: @[]), onFrame: onFrame))
  doAssert code == 0 and failed.len == 0, failed

proc main*() =
  let shots = getEnv("VIEWSEG_SCREENSHOTS")
  if shots.len > 0: createDir(shots)
  proc shoot(f: FrameInfo; name: string) =
    if shots.len > 0: doAssert f.savePng(shots / name), name
  const W = "new plot 1"
  withFixtures fx:
    block dat:
      var d = SynthDat(samples: 12000)
      let ref0 = parseDat(synthDat(SynthDat(samples: 12000))).data[dcReference]
      d.data[dcReference] = ref0
      for (c, k) in [(dcMass, -0.25), (dcBaseplate, -0.125)]:
        d.data[c] = newSeq[int32](ref0.len)
        for i, v in ref0: d.data[c][i] = int32(round(k * float64(v)))
      let path = datFile(fx.dir / "dat", "0042_20010203T040506.789000000Z.dat", d)
      var list: seq[Step] = @[]
      list.step "the window opened":
        f.apply Command(kind: ckOpenPlot, plotView: avVibrator,
          plotTraces: @[f.core.sessions[0].base])
      do:
        f.shown(W & ".polarity") and f.shown(W & ".reverse") and f.shown(W & ".controller") and
          f.shown(W & ".force scale") and f.shown(W & ".verdict")
      list.step "the polarity line":
        doAssert f.core.plots[0].result.polarity.kind == pkOpposite,
          f.core.plots[0].result.polarity.line
        f.shoot("sigvib-dat.png")
      do: true
      list.step "reversed by the button":
        f.click(W & ".reverse")
      do:
        f.core.plots[0].params.roles.groundForcePolarity == poReversed and
          f.core.plots[0].result.polarity.reversed and f.shown(W & ".reverse")
      list.step "the choice is said":
        doAssert "as you chose" in f.core.plots[0].result.polarity.line,
          f.core.plots[0].result.polarity.line
        f.shoot("sigvib-dat-reversed.png")
      do: true
      list.step "a scale is set":
        var s = f.core.settings
        s.forceScale.datCountsPerLbf = 8
        f.apply Command(kind: ckSettings, settings: s)
      do:
        f.shown(W & ".hundred words") and f.core.plots[0].result.hundredWords.len > 0
      list.step "the 100 % force says where it comes from":
        f.shoot("sigvib-dat-scale.png")
      do: true
      steps(path, fx.dir / "a", list)
    block vib:
      let dir = fx.dir / "pair"
      var s = SynthVib()
      s.header.sensitivity1 = 20
      s.header.sensitivity2 = 25
      let ref0 = synthRef(s)
      s.data[vcReference] = ref0
      for c in [vcBaseplateA, vcMassA, vcBaseplateB, vcMassB]:
        s.data[c] = newSeq[int16](ref0.len)
        for i, v in ref0: s.data[c][i] = int16(round(-0.3 * float64(v)))
      discard datFile(dir, "4321_0.dat", SynthDat(samples: 12000))
      let path = vibFile(dir, "0007.VIB", s)
      var list: seq[Step] = @[]
      list.step "the window opened":
        f.apply Command(kind: ckOpenPlot, plotView: avVibrator,
          plotTraces: @[f.core.sessions[0].base])
      do:
        f.shown(W & ".polarity") and f.shown(W & ".weights") and f.shown(W & ".set A") and
          f.shown(W & ".controller")
      list.step "set B":
        doAssert f.core.plots[0].params.accelSet == asB
        doAssert "the .dat of this sweep" in f.core.plots[0].result.controllerNote
        f.shoot("sigvib-vib-pair.png")
      do: true
      list.step "set A pressed":
        f.click(W & ".set A")
      do:
        f.core.plots[0].params.accelSet == asA and not f.core.plots[0].waiting and
          f.core.plots[0].result.plots.len > 0
      list.step "set A shown":
        f.shoot("sigvib-vib-setA.png")
      do: true
      list.step "a scale is set":
        var st = f.core.settings
        st.forceScale.vibAccMvPerCount = 12.5
        f.apply Command(kind: ckSettings, settings: st)
      do:
        f.shown(W & ".hundred words") and f.core.plots[0].result.hundredWords.len > 0
      list.step "the scale":
        f.shoot("sigvib-vib-scale.png")
      do: true
      steps(path, fx.dir / "b", list, browse = dir)
    block fleet:
      let dir = fx.dir / "fleet"
      var other = SynthVib()
      other.header.holdDownLb = 25000
      other.header.baseplateLb = 5000
      var k = 0
      var first = ""
      for (vibrator, header) in [(11, SynthVib().header), (11, SynthVib().header),
          (12, SynthVib().header), (12, SynthVib().header), (13, other.header),
          (13, other.header)]:
        inc k
        let secs = 10 * k
        var dat = SynthDat(samples: 600, vibrator: vibrator, serial: 4321)
        dat.trigger = DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5 + secs div 60,
          second: secs mod 60, nanosecond: 500_000_000)
        discard datFile(dir, "d" & $k & ".dat", dat)
        var v = SynthVib()
        v.header = header
        v.start = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5 + secs div 60,
          second: secs mod 60)
        let p = vibFile(dir, intToStr(k, 4) & ".VIB", v)
        if first.len == 0: first = p
      var list: seq[Step] = @[]
      list.step "the window opened":
        f.apply Command(kind: ckOpenPlot, plotView: avVibrator,
          plotTraces: @[f.core.sessions[0].base])
      do:
        f.shown(W & ".fleet header") and f.shown(W & ".fleet")
      list.step "the difference is said":
        let found = f.core.vibWeightFindings()
        doAssert found.len == 3 and found[2].unlike, $found.len
        f.shoot("sigvib-fleet.png")
      do: true
      steps(first, fx.dir / "c", list, browse = dir)
  echo "tguisigvib: ok"

when isMainModule:
  main()
