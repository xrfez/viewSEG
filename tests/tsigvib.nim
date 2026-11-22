## The Vibrator window on a vibrator controller's signature file (a `.dat` or a `.vib`), headless,
## on made-up sweeps whose ground force is opposite to, or in phase with, the reference:
##
## - the ground force against the reference is reported in words ("opposite", mean phase near
##   180 degrees; "in phase"; "unclear" for a weak or absent drive) and the data is unchanged;
## - the explicit choice "Reverse the ground force for the analysis" is remembered for the file
##   layout (in the project when one is open, else in the settings), is said in the roles line
##   and the polarity line, and "As recorded" takes it back; Automatic is not honoured;
## - a `.vib` judged on set A takes traces 5 to 7 of its record, and the choice is the
##   window's own: the next window, and the settings, do not hold it;
## - the user's force scale (a `.dat`: counts per lbf; a `.vib`: the accelerometer constant)
##   turns the ground force into newtons for the display and the verdict, as the library's
##   `scaleOf` gives it for a `.vib`; the 100 % force comes from the controller's target force
##   (`.dat`) or the header's hold-down weight (`.vib`) when none is typed;
## - the controller's QC numbers are beside this window's (a `.vib`'s from its pair);
## - the header's weights and sensitivities of a `.vib`, and per vibrator across a folder, where
##   a vibrator whose weights differ is a finding in words and nothing is rescaled;
## - the four field recordings in samples/vib/field open as SEG-Y: roles from the codes and a
##   polarity line in words (the words are checked, not numbers).
##
## Seen to fail, each with the behaviour off: the ground force's phase not turned back by half a
## turn when reversed (`reversedAsRecorded` found "in phase as recorded"); the report always
## "opposite" (`inPhase`); Automatic let through in `showPlot` (`automatic` found the polarity
## changed); set A's traces not taken (`setA`); the force scale ignored (`scale`); the hold-down
## weight not used for 100 % (`hundred`); the controller's rows left out (`controller`); no weak
## limit on the phase consistency (`weak` found the noise sweep not unclear); the weights grouped
## by file instead of by vibrator (`fleet`); the reversed choice not remembered (`reversedAsRecorded`
## found no choice in the settings) and not read back for the next window (the same test).
## Not mutated: that an agent's polarity is never saved (it is the existing `keeps` rule); the
## words of the three kinds of polarity beyond "opposite", "in phase" and "unclear".

import std/[json, math, os, strutils, times]
import parseSEG
import parseSSDAT
import parseSSVIB
import viewSEG/core/[analysis, persist, settings, signatures, state, units, vendormaps]
import utils/[fixtures, sigfiles, waiting]

proc settleIt(st: var AppState; w: int): bool =
  st.settle(st.plots[w].result.gen > 0 and not st.plots[w].waiting and
    (st.plots[w].result.plots.len > 0 or st.plots[w].result.problem.len > 0))

proc started(dir: string): AppState =
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))

proc shown(st: var AppState; path: string): int =
  ## Opens `path` in the main panel; the index of its session.
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  var at = -1
  doAssert st.settle((at = -1; (for i, s in st.sessions: (if s.path == path: at = i)); at >= 0) and
    st.panel(MainPanel).laidOut and st.shownFile(st.findPanel(MainPanel)) == at), path
  at

proc window(st: var AppState; path: string; params = AnalysisParams()): int =
  ## Opens `path` and a Vibrator window on its first trace; the window's index.
  let i = st.shown(path)
  st.apply Command(kind: ckOpenPlot, plotView: avVibrator,
    plotTraces: @[st.sessions[i].base], plotParams: params)
  result = st.plots.high
  doAssert st.settleIt(result), st.plots[result].result.problem
  doAssert st.plots[result].result.problem.len == 0, st.plots[result].result.problem

proc change(st: var AppState; w: int; p: AnalysisParams; origin = coWindow) =
  let before = st.plots[w].result.gen
  st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p, origin: origin)
  doAssert st.settle(st.plots[w].result.gen > before and not st.plots[w].waiting and
    (st.plots[w].result.plots.len > 0 or st.plots[w].result.problem.len > 0)),
    "the window was not worked out again"

proc setScale(st: var AppState; dat, vib: float64) =
  var s = st.settings
  s.forceScale = ForceScale(datCountsPerLbf: dat, vibAccMvPerCount: vib)
  st.apply Command(kind: ckSettings, settings: s)

func cell(r: AnalysisResult; signal, column: string): string =
  ## The table's cell of the row of `signal` under `column`.
  var at = -1
  for i, c in r.table[0]:
    if c == column: at = i
  for row in r.table[1 .. ^1]:
    if row[0] == signal and at >= 0: return row[at]
  doAssert false, signal & " / " & column & " is not in the table"

const NoWords = ["real", "true", "measured", "simulated"]

proc plainWords(text: string) =
  ## The user's rule: no ground force or accelerometer set is called real, true, measured or
  ## simulated.
  for w in text.toLowerAscii.split({' ', '\n', '\t', ',', '.', ';', ':', '(', ')'}):
    for bad in NoWords:
      doAssert w != bad, "\"" & bad & "\" in: " & text

proc sweepOf(sign, gain: float64): SynthVib =
  ## A `.vib` whose accelerations are the reference times `sign` times `gain` (set B twice set
  ## A's, so the two sets differ): the ground force is the weights times them, in phase when
  ## `sign` is 1 and opposite when it is -1. A zero `sign` has no drive.
  result = SynthVib()
  result.header.sensitivity1 = 20.0
  result.header.sensitivity2 = 25.0
  let ref0 = synthRef(result)
  result.data[vcReference] = ref0
  for c in [vcBaseplateA, vcMassA]:
    result.data[c] = newSeq[int16](ref0.len)
    for i, v in ref0: result.data[c][i] = int16(round(sign * gain * float64(v)))
  for c in [vcBaseplateB, vcMassB]:
    result.data[c] = newSeq[int16](ref0.len)
    for i, v in ref0: result.data[c][i] = int16(round(2 * sign * gain * float64(v)))

proc datOf(sign: float64; more = SynthDat(samples: 12000)): SynthDat =
  ## A `.dat` whose force channels are the reference times `sign` (a sweep).
  result = more
  let ref0 = parseDat(synthDat(SynthDat(samples: more.samples))).data[dcReference]
  result.data[dcReference] = ref0
  for (c, k) in [(dcMass, 0.25), (dcBaseplate, 0.125)]:
    result.data[c] = newSeq[int32](ref0.len)
    for i, v in ref0: result.data[c][i] = int32(round(sign * k * float64(v)))

proc main*() =
  block oppositeVib:
    block:
      withFixtures fx:
        var st = initAppState()
        let path = vibFile(fx.dir, "0007.VIB", sweepOf(-1, 0.3))
        let w = st.window(path)
        let r = st.plots[w].result
        doAssert r.polarity.kind == pkOpposite and abs(r.polarity.meanPhaseDeg) > 160,
          r.polarity.line & " " & $r.polarity.meanPhaseDeg
        doAssert r.polarity.line.startsWith("Ground force against the reference: opposite (mean phase "),
          r.polarity.line
        doAssert "°)" in r.polarity.line and r.polarity.consistency > 0.9
        doAssert "mean phase -" notin r.polarity.line and "\u2212" notin r.polarity.line,
          "an opposite ground force is told by its size: " & r.polarity.line
        doAssert st.plots[w].params.roles.groundForcePolarity == poAsRecorded
        doAssert r.cell("GF", "Polarity") == "as recorded"
        # the data is unchanged: trace 4 is the library's ground force of set B, sign as recorded
        let shot = parseVib(cast[seq[byte]](readFile(path)))
        let gf = groundForce(shot, vsB)
        let s = st.sessions[0]
        let x = s.filePtr[].readTraces(3 .. 3)
        for i in countup(0, gf.len - 1, 97):
          doAssert x[0, i] == gf[i], "sample " & $i
        plainWords(r.polarity.line)
        st.shutdown()

  block oppositeDat:
    block:
      withFixtures fx:
        var st = initAppState()
        let w = st.window(datFile(fx.dir, "a.dat", datOf(-1)))
        let r = st.plots[w].result
        doAssert r.polarity.kind == pkOpposite and abs(r.polarity.meanPhaseDeg) > 160,
          r.polarity.line
        doAssert st.plots[w].params.roles.groundForcePolarity == poAsRecorded
        st.shutdown()

  block inPhase:
    block:
      withFixtures fx:
        var st = initAppState()
        let w = st.window(vibFile(fx.dir, "0007.VIB", sweepOf(1, 0.3)))
        let r = st.plots[w].result
        doAssert r.polarity.kind == pkInPhase and abs(r.polarity.meanPhaseDeg) < 20, r.polarity.line
        doAssert r.polarity.line.startsWith("Ground force against the reference: in phase ("),
          r.polarity.line
        let d = st.window(datFile(fx.dir, "a.dat", datOf(1)))
        doAssert st.plots[d].result.polarity.kind == pkInPhase, st.plots[d].result.polarity.line
        st.shutdown()

  block weak:
    block:
      withFixtures fx:
        var st = initAppState()
        # no drive at all, and a drive that is noise: unclear, never "opposite"
        let w = st.window(vibFile(fx.dir, "0007.VIB", sweepOf(0, 0.3)))
        let r = st.plots[w].result
        doAssert r.polarity.kind == pkUnclear and "unclear" in r.polarity.line, r.polarity.line
        plainWords(r.polarity.line)
        var noisy = sweepOf(1, 0.3)
        var seed = 12345'u32
        for c in [vcBaseplateA, vcMassA, vcBaseplateB, vcMassB]:
          for i in 0 ..< noisy.data[c].len:
            seed = seed * 1664525'u32 + 1013904223'u32
            noisy.data[c][i] = int16(int(seed shr 16) mod 2001 - 1000)
        let n = st.window(vibFile(fx.dir, "0008.VIB", noisy))
        doAssert st.plots[n].result.polarity.kind == pkUnclear and
          "follows the reference weakly" in st.plots[n].result.polarity.line,
          st.plots[n].result.polarity.line
        st.shutdown()

  block reversedAsRecorded:
    block:
      withFixtures fx:
        let dir = fx.dir / "config"
        createDir(dir)
        var st = started(dir)
        let w = st.window(vibFile(fx.dir, "0007.VIB", sweepOf(-1, 0.3)))
        var p = st.plots[w].params
        p.roles.groundForcePolarity = poReversed
        st.change(w, p)
        let r = st.plots[w].result
        # the phase is told as recorded (still opposite), and the choice is said
        doAssert r.polarity.kind == pkOpposite and abs(r.polarity.meanPhaseDeg) > 160,
          r.polarity.line
        doAssert r.polarity.reversed and
          "reversed for the analysis, as you chose" in r.polarity.line, r.polarity.line
        doAssert r.cell("GF", "Polarity") == "reversed"
        doAssert r.cell("GF", "Mean |phase| (°)").parseFloat < 20,
          "the analysis did not turn the ground force over"
        let roles = st.vibRolesLine(st.plots[w], long = true)
        doAssert "GF reversed for the analysis: your choice" in roles, roles
        doAssert st.settings.vibRoles.len == 1 and st.settings.vibRoles[0].endsWith(" r.a"),
          $st.settings.vibRoles
        # a later window of that layout opens with it
        let v = st.window(vibFile(fx.dir, "0008.VIB", sweepOf(-1, 0.3)))
        doAssert st.plots[v].params.roles.groundForcePolarity == poReversed
        doAssert "GF reversed for the analysis: your choice" in
          st.vibRolesLine(st.plots[v], long = true)
        # "As recorded" takes it back, and the memory with it
        var q = st.plots[v].params
        q.roles.groundForcePolarity = poAsRecorded
        st.change(v, q)
        doAssert not st.plots[v].result.polarity.reversed
        doAssert "reversed" notin st.plots[v].result.polarity.line
        doAssert st.settings.vibRoles.len == 1 and not st.settings.vibRoles[0].contains(" r"),
          $st.settings.vibRoles
        doAssert "GF reversed" notin st.vibRolesLine(st.plots[v], long = true)
        discard st.shutdown()
        var back = started(dir)
        let u = back.window(vibFile(fx.dir, "0009.VIB", sweepOf(-1, 0.3)))
        doAssert back.plots[u].params.roles.groundForcePolarity == poAsRecorded
        discard back.shutdown()

  block remembered:
    # in a project, and in the settings of a restart
    block:
      withFixtures fx:
        let dir = fx.dir / "config-a"
        createDir(dir)
        let proj = fx.dir / "job"
        var st = started(dir)
        st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job")
        doAssert st.settle(st.inProject)
        let w = st.window(datFile(fx.dir, "a.dat", datOf(-1)))
        var p = st.plots[w].params
        p.roles.groundForcePolarity = poReversed
        st.change(w, p)
        doAssert st.project.doc.vibRoles.len == 1 and st.settings.vibRoles.len == 0,
          $(st.project.doc.vibRoles, st.settings.vibRoles)
        st.apply Command(kind: ckCloseProject)
        doAssert st.settle(not st.inProject)
        discard st.shutdown()
        var back = started(dir)
        back.apply Command(kind: ckOpenProject, projectPath: proj)
        doAssert back.settle(back.inProject)
        let v = back.window(datFile(fx.dir, "b.dat", datOf(-1)))
        doAssert back.plots[v].params.roles.groundForcePolarity == poReversed,
          "the polarity did not come back in the project"
        back.apply Command(kind: ckCloseProject)
        discard back.shutdown()
        # a polarity an agent sets is for the run: nothing is kept
        let dir2 = fx.dir / "config-b"
        createDir(dir2)
        var agent = started(dir2)
        let a = agent.window(datFile(fx.dir, "c.dat", datOf(-1)))
        var q = agent.plots[a].params
        q.roles.groundForcePolarity = poReversed
        agent.change(a, q, coAgent)
        doAssert agent.plots[a].params.roles.groundForcePolarity == poReversed
        discard agent.shutdown()
        doAssert loadSettings(dir2 / "settings.nif").settings.vibRoles.len == 0,
          "an agent's polarity was kept"

  block automatic:
    block:
      withFixtures fx:
        var st = initAppState()
        let w = st.window(datFile(fx.dir, "a.dat", datOf(-1)))
        var p = st.plots[w].params
        p.roles.groundForcePolarity = poAutomatic
        st.apply Command(kind: ckPlotDisplay, plot: st.plots[w].id, plotParams: p)
        doAssert st.settle(not st.plots[w].waiting)
        doAssert st.plots[w].params.roles.groundForcePolarity == poAsRecorded,
          "Automatic was honoured for a signature file"
        doAssert not st.plots[w].result.polarity.reversed
        var found = false
        for e in st.log:
          if "Automatic polarity is not offered" in e.text: found = true
        doAssert found, "the refusal was not said"
        st.shutdown()

  block setA:
    block:
      withFixtures fx:
        let dir = fx.dir / "config"
        createDir(dir)
        var st = started(dir)
        let path = vibFile(fx.dir, "0007.VIB", sweepOf(-1, 0.3))
        let w = st.window(path)
        doAssert st.plots[w].traces.len == 4 and st.plots[w].params.accelSet == asB
        let peakB = st.plots[w].result.cell("GF", "Max peak").parseFloat
        let before = st.settings.vibRoles
        var p = st.plots[w].params
        p.accelSet = asA
        st.change(w, p)
        let base = st.sessions[0].base
        doAssert st.plots[w].params.accelSet == asA
        doAssert st.plots[w].traces == @[base, base + 4, base + 5, base + 6], $st.plots[w].traces
        let r = st.plots[w].result
        doAssert "set A" in r.cell("GF", "Trace") and "set A" in r.cell("M", "Trace") and
          "set A" in r.cell("B", "Trace"), $r.table
        doAssert "set B" notin r.cell("GF", "Trace")
        doAssert r.polarity.kind == pkOpposite
        let peakA = r.cell("GF", "Max peak").parseFloat
        doAssert abs(peakB / peakA - 2.0) < 0.05, "set A is half set B here: " & $(peakA, peakB)
        doAssert "accelerometer set A, by your choice" in st.vibRolesLine(st.plots[w], long = true)
        doAssert "following" notin r.controllerNote
        # not remembered: neither the settings nor the next window hold it
        doAssert st.settings.vibRoles == before, $st.settings.vibRoles
        let v = st.window(path)
        doAssert st.plots[v].params.accelSet == asB and st.plots[v].traces.len == 4 and
          st.plots[v].traces[1] == base + 1, $st.plots[v].traces
        # back to set B
        var q = st.plots[w].params
        q.accelSet = asB
        st.change(w, q)
        doAssert st.plots[w].traces == @[base, base + 1, base + 2, base + 3]
        doAssert abs(st.plots[w].result.cell("GF", "Max peak").parseFloat - peakB) < 1e-6 * peakB
        discard st.shutdown()

  block scale:
    block:
      withFixtures fx:
        var st = initAppState()
        # a .dat: 8 counts per lbf
        let w = st.window(datFile(fx.dir, "a.dat", datOf(1)))
        doAssert st.plots[w].result.forceUnits.len > 0
        let counts = st.plots[w].result.cell("GF", "Max peak").parseFloat
        let unitBefore = st.plots[w].result.forceUnits[1]
        doAssert unitBefore == "counts", unitBefore
        st.setScale(8.0, NaN)
        doAssert st.settle(st.plots[w].result.forceUnits[1] == "N" and not st.plots[w].waiting)
        let r = st.plots[w].result
        let lbf = shownTable(r.table, r.forceUnits, usImperial)
        var at = -1
        for i, c in lbf[0]: (if c.startsWith("Max peak"): at = i)
        var got = NaN
        for row in lbf[1 .. ^1]:
          if row[0] == "GF": got = row[at].split(' ')[0].parseFloat
        doAssert abs(got - counts / 8) < 0.002 * (counts / 8) + 0.001,
          "the force does not read in lbf: " & $(got, counts / 8)
        doAssert "8 counts per lbf" in r.scaleWords and "8 counts per lbf" in r.note
        # the samples stay raw counts
        let raw = parseDat(cast[seq[byte]](readFile(fx.dir / "a.dat")))
        let x = st.sessions[0].filePtr[].readTraces(0 .. 0)
        doAssert x[0, 100] == float32(raw.data[dcReference][100])
        plainWords(r.scaleWords)
        st.shutdown()
    block:
      withFixtures fx:
        # a .vib: the accelerometer constant, with the header's sensitivity of the set judged
        var st = initAppState()
        let path = vibFile(fx.dir, "0007.VIB", sweepOf(1, 0.3))
        let w = st.window(path)
        let pounds = st.plots[w].result.cell("GF", "Max peak").parseFloat
        doAssert st.plots[w].result.forceUnits[1] == "pound-counts", st.plots[w].result.forceUnits[1]
        st.setScale(NaN, 12.5)
        doAssert st.settle(st.plots[w].result.forceUnits[1] == "N" and not st.plots[w].waiting)
        let shot = parseVib(cast[seq[byte]](readFile(path)))
        let k = VibScale(accMvPerCount: 12.5)
        let factorB = scaleOf(shot, vcBaseplateB, k, force = false) # (set B: the second sensitivity)
        let scaledB = st.plots[w].result.cell("GF", "Max peak").parseFloat
        doAssert abs(scaledB / pounds - factorB * NPerLbf) < 1e-4 * factorB * NPerLbf,
          $(scaledB / pounds, factorB * NPerLbf)
        # set A takes the first sensitivity
        var p = st.plots[w].params
        p.accelSet = asA
        st.change(w, p)
        let factorA = scaleOf(shot, vcBaseplateA, k, force = false)
        doAssert factorA != factorB
        let ratio = st.plots[w].result.cell("GF", "Max peak").parseFloat / (scaledB / 2.0)
        doAssert abs(ratio - factorA / factorB) < 0.05 * factorA / factorB, $(ratio, factorA / factorB)
        st.shutdown()

  block hundred:
    block:
      withFixtures fx:
        var st = initAppState()
        let w = st.window(datFile(fx.dir, "a.dat", datOf(1)))
        doAssert st.plots[w].result.qc.hundredPct.isNaN, "no scale: no 100 % force"
        st.setScale(8.0, NaN)
        # no drive level typed: the default 100 gives no 100 % force, and the words say what to type
        doAssert st.settle(st.plots[w].result.scaleWords.len > 0 and not st.plots[w].waiting)
        doAssert st.plots[w].result.qc.hundredPct.isNaN and st.plots[w].result.hundredWords == "",
          "a drive level nobody typed gave a 100 % force"
        doAssert "type the drive level" in st.plots[w].result.hundredHint,
          st.plots[w].result.hundredHint
        let target = float64(parseDat(cast[seq[byte]](readFile(fx.dir /
            "a.dat"))).qc.targetForceLbf)
        doAssert target > 0
        # the drive level typed (even 100): 100 % is the controller's target force at that level
        var p = st.plots[w].params
        (p.targetPct, p.targetTyped) = (100.0, true)
        st.change(w, p)
        let r = st.plots[w].result
        doAssert abs(r.qc.hundredPct - target * NPerLbf) < 1e-9 * target, $r.qc.hundredPct
        doAssert "controller's target force" in r.hundredWords and r.hundredHint == "",
          r.hundredWords
        p.targetPct = 60
        st.change(w, p)
        doAssert abs(st.plots[w].result.qc.hundredPct - target * 100 / 60 * NPerLbf) <
          1e-9 * target, $st.plots[w].result.qc.hundredPct
        # a 100 % force typed wins, and the words are gone
        (p.forceHundredPct, p.forceHundredUnit) = (1000.0, "N")
        st.change(w, p)
        doAssert st.plots[w].result.qc.hundredPct == 1000 and st.plots[w].result.hundredWords == ""
        st.shutdown()
    block:
      withFixtures fx:
        var st = initAppState()
        let w = st.window(vibFile(fx.dir, "0007.VIB", sweepOf(1, 0.3)))
        doAssert st.plots[w].result.hundredWords == ""
        st.setScale(NaN, 12.5)
        doAssert st.settle(st.plots[w].result.qc.hundredPct > 0 and not st.plots[w].waiting)
        let hold = float64(SynthVib().header.holdDownLb)
        doAssert abs(st.plots[w].result.qc.hundredPct - hold * NPerLbf) < 1e-9 * hold
        doAssert "hold-down weight" in st.plots[w].result.hundredWords
        st.shutdown()

  block typedHundred:
    # a typed 100 % force keeps its unit: it survives a scale given and taken away without
    # changing meaning, is not applied (and says so) when it cannot be converted, and is not
    # carried into the next window
    withFixtures fx:
      let dir = fx.dir / "config"
      createDir(dir)
      var st = started(dir)
      let path = datFile(fx.dir, "a.dat", datOf(1))
      let w = st.window(path)
      var p = st.plots[w].params
      (p.forceHundredPct, p.forceHundredUnit) = (1000.0, "counts")
      st.change(w, p)
      doAssert st.plots[w].result.qc.hundredPct == 1000
      st.setScale(8.0, NaN)
      doAssert st.settle(st.plots[w].result.scaleWords.len > 0 and not st.plots[w].waiting)
      doAssert abs(st.plots[w].result.qc.hundredPct - 1000 * NPerLbf / 8) < 1e-9 and
        st.plots[w].result.hundredProblem == "", $st.plots[w].result.qc.hundredPct
      st.setScale(NaN, NaN)
      doAssert st.settle(st.plots[w].result.scaleWords.len == 0 and not st.plots[w].waiting)
      doAssert st.plots[w].result.qc.hundredPct == 1000 and st.plots[w].result.hundredProblem == "",
        "the typed value changed meaning"
      # typed in newtons, the scale taken away: not applied, and said
      st.setScale(8.0, NaN)
      doAssert st.settle(st.plots[w].result.scaleWords.len > 0 and not st.plots[w].waiting)
      p = st.plots[w].params
      (p.forceHundredPct, p.forceHundredUnit) = (5000.0, "N")
      st.change(w, p)
      doAssert st.plots[w].result.qc.hundredPct == 5000
      st.setScale(NaN, NaN)
      doAssert st.settle(st.plots[w].result.scaleWords.len == 0 and not st.plots[w].waiting)
      doAssert st.plots[w].result.qc.hundredPct.isNaN and
        "typed in N" in st.plots[w].result.hundredProblem and
        "type it again" in st.plots[w].result.hundredProblem, st.plots[w].result.hundredProblem
      # not carried into a new window of the kind, nor remembered for it
      doAssert st.settings.plotOptions.vibrator.forceHundredPct.isNaN
      let v = st.window(datFile(fx.dir, "b.dat", datOf(1)))
      doAssert st.plots[v].params.forceHundredPct.isNaN
      discard st.shutdown()

  block fleetCases:
    # the weights per vibrator, on the pure function: two that differ, a sensitivity-only
    # difference, vibrators not known, and the wording
    let base = VibWeights(holdDownLb: 40000, baseplateLb: 6000, massLb: 4000,
      sensitivity1: 20, sensitivity2: 20)
    var big = base
    big.holdDownLb = 60000
    var sens = base
    sens.sensitivity1 = 21
    sens.sensitivity2 = 21
    let two = perVibrator([(11, base), (11, base), (12, big)])
    doAssert two.twoDiffer and two.flagged and not two.vibrators[0].unlike and
      not two.vibrators[1].unlike
    let said = twoDifferWords(two)
    doAssert "two vibrators state different weights" in said and "do not say which" in said, said
    doAssert "wrong vibrator type" notin vibratorWords(two.vibrators[1])
    let onlySens = perVibrator([(11, base), (12, base), (13, sens)])
    doAssert onlySens.vibrators[2].sensUnlike and not onlySens.vibrators[2].unlike and
      not onlySens.twoDiffer and onlySens.flagged
    let words = vibratorWords(onlySens.vibrators[2])
    doAssert "sensitivities differ" in words and "wrong vibrator type" notin words, words
    let aloneSens = perVibrator([(11, base), (11, sens)])
    doAssert aloneSens.vibrators[0].sensDiffers and not aloneSens.vibrators[0].differs and
      "wrong vibrator type" notin vibratorWords(aloneSens.vibrators[0])
    # vibrators not known are listed, never grouped or compared
    let unknown = perVibrator([(0, base), (0, big), (11, base), (12, base)])
    doAssert unknown.unknown == 2 and unknown.vibrators.len == 2 and not unknown.flagged
    doAssert "not known" in unknownWords(unknown.unknown) and "not compared" in
      unknownWords(unknown.unknown)
    # the count wording
    var small = base
    small.holdDownLb = 30000
    let one = perVibrator([(11, base), (11, base), (11, small), (12, base), (13, base)])
    let l = vibratorWords(one.vibrators[0])
    doAssert "2 sweeps state one set, 1 sweep states the other" in l and "1 of one" notin l, l

  block targetSeventy:
    # the controller's force numbers and this window's are on one base (% of the 100 % force):
    # a sweep driven at 70 % of the full scale, the drive level typed as 70, agrees in both
    withFixtures fx:
      var st = initAppState()
      var d = datOf(1)
      (d.forceMax, d.forceMin, d.forceAvg) = (70, 70, 70)
      let w = st.window(datFile(fx.dir, "a.dat", d))
      let target = float64(parseDat(cast[seq[byte]](readFile(fx.dir /
          "a.dat"))).qc.targetForceLbf)
      let peak = st.plots[w].result.cell("GF", "Max peak").parseFloat # counts
                                                                      # a scale that makes the sweep's peak the target force: 100 % is then target / 0.7
      st.setScale(peak / target, NaN)
      doAssert st.settle(st.plots[w].result.scaleWords.len > 0 and not st.plots[w].waiting)
      var p = st.plots[w].params
      (p.targetPct, p.targetTyped) = (70.0, true)
      st.change(w, p)
      let rows = st.plots[w].result.controller
      doAssert rows[0].label.contains("% of hold-down") and rows[0].controller == "70 %"
      let mx = rows[0].viewseg.replace(" %", "").parseFloat
      let av = rows[2].viewseg.replace(" %", "").parseFloat
      doAssert abs(mx - 70) < 3, "max " & rows[0].viewseg
      doAssert abs(av - 70) < 10, "average " & rows[2].viewseg & " (on the target's base: " & $(av /
          0.7) & ")"
      doAssert "hold-down weight" in rows[0].tip
      st.shutdown()

  block neither:
    # a ground force a quarter turn from the reference is neither in phase nor opposite
    withFixtures fx:
      var st = initAppState()
      var s = SynthVib()
      let ref0 = synthRef(s)
      s.data[vcReference] = ref0
      let n = ref0.len
      for c in [vcBaseplateA, vcMassA, vcBaseplateB, vcMassB]: s.data[c] = newSeq[int16](n)
      for i in 0 ..< n:
        let tf = float64(i) - s.preTrigger
        var v = 0.0
        if tf > 0:
          let t = tf * s.intervalUs / 1e6
          let ph = s.startHz * t + 0.5 * s.rateHzPerS * t * t
          let e = min(1.0, tf / float64(s.taperFrames)) *
            min(1.0, max(0.0, (float64(s.afterTrigger) - tf) / float64(s.taperFrames)))
          v = 0.3 * float64(s.amplitude) * e * sin(2 * PI * ph + PI / 2)
        for c in [vcBaseplateA, vcMassA, vcBaseplateB, vcMassB]: s.data[c][i] = int16(round(v))
      let w = st.window(vibFile(fx.dir, "0007.VIB", s))
      let r = st.plots[w].result
      doAssert r.polarity.kind == pkOther and abs(abs(r.polarity.meanPhaseDeg) - 90) < 15,
        r.polarity.line
      doAssert "neither in phase nor opposite (mean phase " in r.polarity.line, r.polarity.line
      st.shutdown()

  block controller:
    block:
      withFixtures fx:
        var st = initAppState()
        var d = datOf(1)
        d.corr = newSeq[int8](128)
        d.corr[64] = -117
        let w = st.window(datFile(fx.dir, "a.dat", d))
        var r = st.plots[w].result
        doAssert r.controller.len == 7, $r.controller.len
        doAssert r.controller[0].label.startsWith("Force, max") and r.controller[0].controller == "61 %"
        doAssert r.controller[1].controller == "58 %" and r.controller[2].controller == "59 %"
        doAssert r.controller[3].controller == "9 %" and r.controller[4].controller == "4 %"
        # force compares only once 100 % is the controller's target force
        doAssert r.controller[0].viewseg == "—" and "target force" in r.controller[0].tip
        doAssert "THD" in r.controller[3].label and "defined differently" in r.controller[3].tip
        doAssert "this file" in r.controllerNote
        st.setScale(8.0, NaN)
        doAssert st.settle(st.plots[w].result.scaleWords.len > 0 and not st.plots[w].waiting)
        # a scale alone is not enough for a .dat: the drive level must be typed
        doAssert st.plots[w].result.controller[0].viewseg == "—"
        doAssert "type the drive level" in st.plots[w].result.controller[0].tip
        var q = st.plots[w].params
        (q.targetPct, q.targetTyped) = (100.0, true)
        st.change(w, q)
        r = st.plots[w].result
        doAssert r.controller[0].viewseg.endsWith(" %") and "hold-down" in r.controller[0].tip
        # the controller's own correlation, for an in-phase sweep: said without a claim
        doAssert "peak at lag 0 negative (−117)" in r.polarity.line, r.polarity.line
        plainWords(r.controllerNote)
        st.shutdown()
    block:
      withFixtures fx:
        # opposite, with the controller's negative lag 0: it records the same relation
        var st = initAppState()
        var d = datOf(-1)
        d.corr = newSeq[int8](128)
        d.corr[64] = -117
        let w = st.window(datFile(fx.dir, "a.dat", d))
        doAssert "it records the same relation and counts it as in phase" in
          st.plots[w].result.polarity.line, st.plots[w].result.polarity.line
        st.shutdown()
    block:
      withFixtures fx:
        # a .vib has none of its own: its pair's, said so; set B notes which set the report follows
        let dir = fx.dir / "pair"
        discard datFile(dir, "4321_0.dat", datOf(1, SynthDat(samples: 12000)))
        let vibPath = vibFile(dir, "0007.VIB", sweepOf(1, 0.3))
        var st = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
        st.apply Command(kind: ckBrowse, paths: @[dir])
        doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 2)
        let i = st.shown(vibPath)
        doAssert st.sessions[i].signature.pair.endsWith("4321_0.dat"), "no pair"
        st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[st.sessions[i].base])
        doAssert st.settleIt(0)
        let r = st.plots[0].result
        doAssert r.controller.len == 7 and r.controller[0].controller == "61 %", $r.controller.len
        doAssert "the .dat of this sweep" in r.controllerNote and
          "follows set A (probable)" in r.controllerNote, r.controllerNote
        # the shot block of the .vib in memory holds its pair's file number
        let maps = currentSourcePath.parentDir.parentDir / "vendormaps"
        let load = loadVendorFolders([VendorFolder(dir: maps, origin: voProgram)])
        let blocks = vendorBlocks(st.sessions[i].filePtr[], -1, load.registry)
        doAssert blocks.blocks.len == 1 and blocks.blocks[0].name == "parseSSVIBShot"
        var datNumber = ""
        for f in blocks.blocks[0].fields:
          if f.name == "datFileNumber": datNumber = f.value
        doAssert datNumber == "7001", "the shot block's .dat file number: " & datNumber
        var p = st.plots[0].params
        p.accelSet = asA
        st.change(0, p)
        doAssert "follows set A" notin st.plots[0].result.controllerNote
        doAssert "the .dat of this sweep" in st.plots[0].result.controllerNote
        st.shutdown()
    block:
      withFixtures fx:
        # a .vib with no pair has no controller numbers
        var st = initAppState()
        let w = st.window(vibFile(fx.dir, "0007.VIB", sweepOf(1, 0.3)))
        doAssert st.plots[w].result.controller.len == 0 and st.plots[w].result.controllerNote == ""
        st.shutdown()

  block weights:
    block:
      withFixtures fx:
        var st = initAppState()
        let w = st.window(vibFile(fx.dir, "0007.VIB", sweepOf(1, 0.3)))
        let wt = st.vibWeights(w)
        doAssert wt.holdDownLb == 40000 and wt.baseplateLb == 6000 and wt.massLb == 4000 and
          wt.sensitivity1 == 20 and wt.sensitivity2 == 25, $wt
        let words = weightsText(wt)
        for part in ["Hold-down 40 000 lb", "baseplate 6 000 lb", "reaction mass 4 000 lb",
            "sensitivities 20.000 and 25.000"]:
          doAssert part in words, part & " is not in: " & words
        doAssert "depends on the hold-down weight" in WeightsDepend and
          "Nothing is corrected or rescaled" in WeightsDepend
        plainWords(words & WeightsDepend)
        st.shutdown()

  block fleet:
    block:
      withFixtures fx:
        # three vibrators: 11 and 12 state one set of weights, 13 another; vibrator 11's second
        # sweep states a third: its controller changed between sweeps
        let dir = fx.dir / "fleet"
        var small = SynthVib()
        small.header.holdDownLb = 30000
        var other = SynthVib()
        other.header.holdDownLb = 25000
        other.header.baseplateLb = 5000
        var k = 0
        let usual = SynthVib().header
        let headers = [(11, usual), (11, small.header), (12, usual), (12, usual),
          (13, other.header), (13, other.header)]
        for (vibrator, header) in headers:
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
          discard vibFile(dir, intToStr(k, 4) & ".VIB", v)
        var st = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
        st.apply Command(kind: ckBrowse, paths: @[dir])
        doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 12)
        let found = st.vibWeightFindings().vibrators
        doAssert found.len == 3, $found.len
        doAssert found[0].vibrator == 11 and found[0].differs and found[0].kinds.len == 2
        doAssert found[1].vibrator == 12 and not found[1].differs and not found[1].unlike
        doAssert found[2].vibrator == 13 and found[2].unlike and not found[2].differs,
          "vibrator 13's weights differ from the others': " & $found[2]
        let l11 = vibratorWords(found[0])
        doAssert "different sets of weights" in l11 and "changed between sweeps" in l11, l11
        let l13 = vibratorWords(found[2])
        doAssert "may be set up for the wrong vibrator type" in l13, l13
        doAssert "may be set up" notin vibratorWords(found[1])
        plainWords(l11 & l13)
        # a finding is words only: the sweep of vibrator 13 judges as it did
        st.shutdown()

  block fieldRecordings:
    # the four recordings are ordinary SEG-Y files: roles come from the codes, and the
    # polarity line gives words (not numbers: they are the field's)
    for name in ["signature_4trace_a.sgy", "signature_13trace_a.sgy"]:
      withFixtures fx:
        var st = initAppState()
        let path = currentSourcePath.parentDir.parentDir / "samples" / "vib" / "field" / name
        let w = st.window(path)
        let roles = st.plots[w].params.roles
        doAssert roles.source == rsCodes, name & ": " & $roles
        let line = st.plots[w].result.polarity.line
        doAssert line.startsWith("Ground force against the reference: "), name & ": " & line
        var said = false
        for part in ["in phase", "opposite", "unclear", "neither in phase nor opposite"]:
          if part in line: said = true
        doAssert said, name & ": " & line
        plainWords(line)
        st.shutdown()

  echo "tsigvib: ok"

when isMainModule:
  main()
