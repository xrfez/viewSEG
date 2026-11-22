## The first-break overlay's given velocity model (`core/breakmodel`, `FirstBreaks.withModel`):
## a model held fixed across records instead of one fitted to each record's own picks.
##
## - the given model at the shot's true velocity (2500 m/s, 20 ms) puts the model bars on the
##   picks: few traces off, the median near 0, the picks and the fit untouched;
## - the same shot with its offsets wrong by a constant (a source named or placed wrongly:
##   the traces are 400 m further out than they are) shows with the given model a median of
##   about -160 ms and most traces off, while the fitted model follows the picks and hides it;
## - "Use this record's fit" copies the fitted velocity, intercept, second velocity and
##   crossover, and switches to given; a record that has no fit gives no model;
## - two segments are continuous at the crossover, a trace with no offset (or killed) has
##   no model time, a velocity of 0 is not a given model, the numbers are bounded;
## - the model is remembered: in the settings file with the display, in the project document;
## - the key's words and the tooltip's: "model (given: 2500 m/s)", the numbers and the
##   record's own median.
##
## Seen to fail: with the given model's times left as the fit's, "the given model is off by";
## with the offsets shifted not used (given flagged by the fit's suspect flag), "most traces
## off"; with the fit's second velocity left out of the copy, "the fit's second velocity was
## not copied"; with the second segment not continuous (no `crossover / v1` term), "not
## continuous"; with a missing offset given 0, "a trace without an offset has a model time";
## with the key's word left "model", "key word"; with the project document not writing the
## model, "project document".

import std/[math, strutils]
import parseSEG
import viewSEG/core/[breakmodel, firstbreakjobs, firstbreaks, join, project, projectnif,
  settingsnif, settings, panels]
import utils/[breakfiles, fixtures]

const Truth = BreakModel(source: bmGiven, v1: 2500, interceptMs: 20)

proc moved(i: int; k: var TraceKeys): float64 =
  ## A source named wrongly: the headers' offsets are 400 m too long.
  k.offset = offsetOf(i) + 400
  arrivalMs(offsetOf(i))

proc breaksOf(path: string): FirstBreaks =
  var f = openSeismic(path, keys = true)
  result = breaksOfRecord(addr f, path, 0 ..< f.len, [])
  f.close()

proc main*() =

  block givenModelAtTheTrueVelocitySitsOnThePicks:
    withFixtures fx:
      let b = breaksOf(fx.shotSegy("true.sgy", gHeaderOffset))
      let g = b.withModel(Truth)
      doAssert g.isGiven and g.hasModel and g.modelled == Traces
      var worst = 0.0
      for i in 0 ..< Traces:
        if i != PlantedTrace: worst = max(worst, abs(g.modelOf(i) - arrivalMs(offsetOf(i))))
      doAssert worst < 1e-6, "the given model is off by " & $worst
      doAssert g.compared > 40 and g.offModel <= 2, $g.compared & " compared, " & $g.offModel &
        " off"
      doAssert abs(g.medianDiffMs) < 6, "median " & $g.medianDiffMs
      doAssert g.pickMs == b.pickMs and g.fit.v1 == b.fit.v1 and g.fit.modelMs == b.fit.modelMs,
        "the picks and the fit are unchanged"
      doAssert g.mismatched(PlantedTrace) and not g.mismatched(3), "the 12 ms limit"
      doAssert not b.withModel(BreakModel()).isGiven and
        b.withModel(BreakModel()).modelMs == b.modelMs, "the fitted source changes nothing"
      doAssert not b.withModel(BreakModel(source: bmGiven)).isGiven, "no velocity changes nothing"

  block aMovedSourceShowsWithTheGivenModelNotTheFitted:
    withFixtures fx:
      let b = breaksOf(fx.customShot("moved.sgy", Traces, moved))
      var fittedOff = 0
      for i in 0 ..< Traces:
        if b.mismatched(i): inc fittedOff
      doAssert fittedOff <= 3, "the fit follows the record: " & $fittedOff & " flagged"
      let g = b.withModel(Truth)
      doAssert g.medianDiffMs < -100 and g.medianDiffMs > -200, "median " & $g.medianDiffMs
      doAssert g.offModel * 10 > g.compared * 9, "most traces off: " & $g.offModel & " of " &
        $g.compared
      var flagged = 0
      for i in 0 ..< Traces:
        if g.mismatched(i): inc flagged
      doAssert flagged * 10 > Traces * 9, "most traces off: " & $flagged & " flagged"
      doAssert "median -1" in g.statusWords and " off" in g.statusWords, g.statusWords
      doAssert "median pick less model -1" in g.givenWords and "off by more than 12 ms" in
        g.givenWords, g.givenWords

  block useThisRecordsFit:
    withFixtures fx:
      var b = breaksOf(fx.shotSegy("fit.sgy", gHeaderOffset))
      var m = b.fitAsModel
      doAssert m.source == bmGiven and m.v1 == b.fit.v1 and m.interceptMs == b.fit.interceptMs
      b.fit.v1 = 2000
      b.fit.v2 = 4500
      b.fit.crossover = 900
      b.fit.interceptMs = 7
      m = b.fitAsModel
      doAssert m == BreakModel(source: bmGiven, v1: 2000, interceptMs: 7, v2: 4500,
        crossover: 900), "the fit's second velocity was not copied: " & $m
      b.fit.v2 = NaN
      b.fit.crossover = Inf
      doAssert b.fitAsModel.segments == 1
      b.hasFit = false
      doAssert b.fitAsModel == BreakModel(), "no fit, no model"

  block theModelsShape:
    let m = BreakModel(source: bmGiven, v1: 2000, interceptMs: 10, v2: 4000, crossover: 1000)
    doAssert m.segments == 2
    doAssert abs(m.modelMs(1000) - 510) < 1e-9, $m.modelMs(1000)
    let step = m.modelMs(1000.001) - m.modelMs(1000)
    doAssert abs(step - 0.00025) < 1e-6, "not continuous at the crossover: " & $step
    doAssert abs(m.modelMs(3000) - (10 + 500 + 500)) < 1e-9
    doAssert m.modelMs(-3000) == m.modelMs(3000), "either side of the source"
    doAssert BreakModel(v1: 2500).modelMs(1250) == 500.0
    doAssert BreakModel(v1: 0).modelMs(100).isNaN and Truth.modelMs(NaN).isNaN
    let bad = BreakModel(source: bmGiven, v1: NaN, interceptMs: Inf, v2: 3000, crossover: 0)
    doAssert bad.bounded == BreakModel(source: bmGiven), $bad.bounded
    doAssert not BreakModel(source: bmGiven, v1: 0).given

  block aTraceWithoutAnOffsetHasNoModel:
    withFixtures fx:
      var b = breaksOf(fx.shotSegy("nooff.sgy", gHeaderOffset))
      b.offsetAbs[3] = NaN
      let g = b.withModel(Truth)
      doAssert g.modelOf(3).isNaN, "a trace without an offset has a model time"
      doAssert not g.modelOf(4).isNaN and g.modelled == Traces - 1
      doAssert not g.pickOf(3).isNaN and not g.mismatched(3)

  block rememberedInSettingsAndProject:
    let m = BreakModel(source: bmGiven, v1: 2400, interceptMs: 12.5, v2: 3800, crossover: 900)
    var s = Settings()
    s.plot.display.breakModel = m
    let text = settingsDocument(s)
    doAssert "(breakModel" in text, text
    var problems: seq[string]
    let back = readSettings(text, "settings.nif", Settings(), problems)
    doAssert back.plot.display.breakModel == m, $back.plot.display.breakModel
    var d = ProjectDoc(name: "P")
    d.breakModel = m
    d.hasBreakModel = true
    let doc = projectDocument(d)
    doAssert "(breakModel" in doc, "project document: " & doc
    let pb = readProject(doc, "project.nif", problems)
    doAssert pb.hasBreakModel and pb.breakModel == m, $pb.breakModel
    doAssert not readProject(projectDocument(ProjectDoc(name: "P")), "x", problems).hasBreakModel
    doAssert asPreset(DisplaySettings(breakModel: m)).breakModel == BreakModel(),
      "a preset keeps no model"

  block theKeysWords:
    withFixtures fx:
      let b = breaksOf(fx.shotSegy("words.sgy", gHeaderOffset))
      doAssert b.keyWord(suMetres) == "model"
      let g = b.withModel(Truth)
      doAssert g.keyWord(suMetres) == "model (given: 2500 m/s)", "key word: " & g.keyWord(suMetres)
      doAssert g.keyWord(suFeet) == "model (given: 2500 ft/s)"
      let w = g.modelWords(suMetres)
      doAssert "the one you gave" in w and "not fitted to the picks" in w, w
      doAssert "Velocity: 2500 m/s" in w and "Intercept: 20.0 ms" in w, w
      doAssert "Given model: median pick less model" in w and "Offsets from the file" in w, w
      let two = b.withModel(BreakModel(source: bmGiven, v1: 2500, v2: 4000, crossover: 1500))
      doAssert "Beyond 1500 m offset: 4000 m/s" in two.modelWords(suMetres),
        two.modelWords(suMetres)

  echo "tbreakmodel: ok"

when isMainModule:
  main()
