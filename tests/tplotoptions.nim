## The options of the New plot windows are remembered per kind (`Settings.plotOptions`,
## `core/plotoptions`), without a window, on a record of nine traces:
##
## - a window of a kind that is changed (ckPlotDisplay) makes its options the
##   kind's; a new window of that kind opens with them, a window already open
##   keeps its own, and a window of another kind is not touched;
## - the envelope and the node orientation have no options; the vibrator's
##   roles and the f-k's time box are not options and are not remembered;
## - they are saved with the settings and read again at the next start, a
##   mass not set staying unset; a settings document of an older version, with
##   none, loads the built-in ones; one that gives a value out of range or of
##   the wrong kind keeps the built-in one and says so;
## - Reset (the built-in options sent as a display) is what a new window then
##   opens with, and saved; a window opened with settings given keeps them;
## - an agent's change is remembered for the session only.
##
## Seen to fail: with `showPlot` not remembering, "a new spectrogram did not open with
## 64 ms"; with the writer leaving `plotOptions` out, "the restart forgot the options";
## with `applied` taking the f-k's time box too, "the f-k's box was remembered".

import std/[math, os, strutils]
import viewSEG/core/[analysis, colourmaps, log, persist, phasepicture, plotoptions, settingsnif, state]
import utils/[fixtures, waiting]

proc lastText(log: MessageLog): string = log[log.len - 1].text

proc appIn(dir: string): AppState =
  result = initAppState()
  result.keepSettingsIn(dir, loadSettings(dir / SettingsFileName))
  result.rememberFilesIn(dir)

proc main*() =

  block pureFunctions:
    var p = AnalysisParams(windowMs: 32, overlap: 10, floorDb: -30, colourMap: cmGrey,
      maxLagMs: 40, harmonics: 3, fkRaw: true, fkFromMs: 5, fkToMs: 50)
    p.roles.reference = 2
    var o = PlotOptions()
    o.remember(avSpectrogram, p)
    doAssert o.spectrogram.windowMs == 32 and o.spectrogram.colourMap == cmGrey
    doAssert o.correlation == CorrelationOptions(), "only the kind's options are taken"
    o.remember(avFk, p)
    doAssert o.fk == FkOptions(floorDb: -30, colourMap: cmGrey, raw: true)
    o.remember(avEnvelope, p)
    doAssert o == (block: (var x = PlotOptions(); x.remember(avSpectrogram, p);
      x.remember(avFk, p); x)), "the envelope has none to remember"
    let q = o.applied(avFk, AnalysisParams(fkFromMs: 7, roles: p.roles))
    doAssert q.fkRaw and q.floorDb == -30 and q.fkFromMs == 7 and q.roles == p.roles,
      "the f-k's box and the roles are not options"
    doAssert builtin(avSpectrogram, p).windowMs == AnalysisParams().windowMs
    doAssert builtin(avSpectrogram, p).maxLagMs == 40, "another kind's options stay"
    doAssert not avEnvelope.hasOptions and not avOrientation.hasOptions
    for v in AnalysisView:
      doAssert PlotOptions().applied(v, AnalysisParams()) == AnalysisParams(),
        "the built-in options agree: " & $v
      doAssert AnalysisParams().optionsOf(v) == PlotOptions(), "agree the other way: " & $v

  block documents:
    var problems: seq[string]
    let old = readSettings("(settings (version 1) (theme \"x\"))", "settings.nif",
      Settings(), problems)
    doAssert problems.len == 0 and old.plotOptions == PlotOptions(), "an older document"
    let bad = readSettings("""(settings (version 1) (plotOptions
 (spectrogram (windowMs -5.0) (overlap 50.0) (colourMap neon))
 (vibrator (harmonics 40) (reactionMassKg 0.0) (limits (phaseDeg 9.0) (colour 3)))
 (sonar (range 3))))""", "settings.nif", Settings(), problems)
    doAssert bad.plotOptions.spectrogram.windowMs == 128 and
      bad.plotOptions.spectrogram.overlap == 50 and
      bad.plotOptions.spectrogram.colourMap == cmViridis, "out of range keeps the built-in"
    doAssert bad.plotOptions.vibrator.harmonics == 5 and
      bad.plotOptions.vibrator.reactionMassKg.isNaN and
      bad.plotOptions.vibrator.limits.phaseDeg == 9, $bad.plotOptions.vibrator
    doAssert problems.len >= 5, $problems
    let kinds = problems.join("\n")
    for word in ["windowMs", "colourMap", "harmonics", "reactionMassKg", "colour", "sonar"]:
      doAssert word in kinds, word & " was not said: " & kinds

  withFixtures fx:
    let dir = fx.dir / "config"
    createDir(dir)
    var st = appIn(dir)
    st.apply Command(kind: ckOpen, paths: @[fx.spectrumSegy()])
    doAssert st.settle(st.sessions.len == 1)
    let base = st.sessions[0].base
    proc open(st: var AppState; v: AnalysisView; params = AnalysisParams()): int =
      let before = st.plots.len
      st.apply Command(kind: ckOpenPlot, plotView: v, plotTraces: @[base, base + 1, base + 2,
        base + 3, base + 4], plotParams: params)
      doAssert st.plots.len == before + 1, st.log.lastText
      st.plots[^1].id
    proc show(st: var AppState; id: int; p: AnalysisParams) =
      st.apply Command(kind: ckPlotDisplay, plot: id, plotParams: p)
    proc paramsOf(st: AppState; id: int): AnalysisParams =
      for w in st.plots:
        if w.id == id: return w.params

    let first = st.open(avSpectrogram)
    let second = st.open(avSpectrogram)
    doAssert st.paramsOf(second) == AnalysisParams(), "the built-in options at first"
    var changed = AnalysisParams(windowMs: 64, overlap: 50, floorDb: -80, colourMap: cmGrey)
    st.show(first, changed)
    doAssert st.paramsOf(second) == AnalysisParams(), "an open window is not changed by another"
    let third = st.open(avSpectrogram)
    doAssert st.paramsOf(third) == changed, "a new spectrogram did not open with 64 ms: " &
      $st.paramsOf(third)
    let phase = st.open(avPhase)
    doAssert st.paramsOf(phase) == AnalysisParams(), "another kind is not touched"
    # not an option: the f-k's box
    var fk = AnalysisParams(floorDb: -90, fkRaw: true, fkFromMs: 10, fkToMs: 90)
    let k = st.open(avFk)
    st.show(k, fk)
    let k2 = st.open(avFk)
    doAssert st.paramsOf(k2).fkRaw and st.paramsOf(k2).floorDb == -90 and
      st.paramsOf(k2).fkFromMs.isNaN, "the f-k's box was remembered"
    # the vibrator's masses and limits, a mass left empty
    var vib = AnalysisParams(reactionMassKg: 3000, harmonics: 8, limitsOn: true)
    vib.limits.phaseDeg = 7
    let v = st.open(avVibrator)
    st.show(v, vib)
    let v2 = st.open(avVibrator)
    doAssert st.paramsOf(v2).reactionMassKg == 3000 and st.paramsOf(v2).harmonics == 8 and
      st.paramsOf(v2).limits.phaseDeg == 7 and st.paramsOf(v2).baseplateMassKg.isNaN
    # the envelope has none
    let e = st.open(avEnvelope)
    doAssert st.paramsOf(e) == AnalysisParams()
    # a window opened with its settings given keeps them
    let given = st.open(avSpectrogram, AnalysisParams(windowMs: 16))
    doAssert st.paramsOf(given).windowMs == 16 and st.paramsOf(given).overlap == 75

    # saved, and read again at the next start
    st.flushFiles()
    st.shutdown()
    var again = appIn(dir)
    doAssert again.settings.plotOptions.spectrogram.windowMs == 64, "the restart forgot the options"
    doAssert again.settings.plotOptions.fk.raw and
      again.settings.plotOptions.vibrator.reactionMassKg == 3000 and
      again.settings.plotOptions.vibrator.baseplateMassKg.isNaN and
      again.settings.plotOptions.phase == PhaseOptions()
    again.apply Command(kind: ckOpen, paths: @[fx.spectrumSegy()])
    doAssert again.settle(again.sessions.len == 1)
    let after = again.open(avSpectrogram)
    doAssert again.paramsOf(after) == changed, "a window after the restart"

    # Reset: the built-in options, which become the remembered ones
    again.show(after, builtin(avSpectrogram, again.paramsOf(after)))
    let reset = again.open(avSpectrogram)
    doAssert again.paramsOf(reset) == AnalysisParams(), "reset did not take"
    again.flushFiles()
    again.shutdown()
    var third2 = appIn(dir)
    doAssert third2.settings.plotOptions.spectrogram == SpectrogramOptions(),
      "the reset was not saved"
    third2.shutdown()

    # an agent's change is for the session
    var agent = appIn(dir)
    agent.apply Command(kind: ckOpen, paths: @[fx.spectrumSegy()])
    doAssert agent.settle(agent.sessions.len == 1)
    let a = agent.open(avSpectrogram)
    agent.apply Command(kind: ckPlotDisplay, plot: a, origin: coAgent,
      plotParams: AnalysisParams(windowMs: 33))
    doAssert agent.settings.plotOptions.spectrogram.windowMs == 33 and
      agent.keptSettings.plotOptions.spectrogram.windowMs == 128
    agent.shutdown()
    echo "tplotoptions: ok"

when isMainModule: main()
