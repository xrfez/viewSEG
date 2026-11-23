## The first-break overlay's given velocity model (`core/breakmodel`, `FirstBreaks.withModel`):
## a model held fixed across records instead of one fitted to each record's own picks.
##
## - the given model at the shot's true velocity (2500 m/s, 20 ms) puts the model bars on the
##   picks: few traces off, the median near 0, the picks and the fit untouched;
## - the same shot with its offsets wrong by a constant (a source named or placed wrongly:
##   the traces are 100 m further out than they are) shows with the given model a median of
##   about -40 ms and most traces off (a 400 m error, 160 ms, is beyond the 100 ms band in
##   which a pick is compared with the model: no pick is comparable, and the words say the
##   model does not fit the record), while the fitted model follows the picks and hides it;
## - "Use this record's fit" copies the fitted velocity, intercept, second velocity and
##   crossover, and switches to given; a record that has no fit gives no model;
## - two segments are continuous at the crossover, a trace with no offset (or killed) has
##   no model time, a velocity of 0 is not a given model, the numbers are bounded;
## - the model is remembered: in the settings file with the display, in the project document;
## - the key's words and the tooltip's: "model (given: 2500 m/s)", the numbers and the
##   record's own median.
##
## - the counts say what the flagged are: "N flagged (M of K compared off the model, P off their
##   neighbours, F far off)", never "N of K" with N above K.
##
## Seen to fail: with the counts' words as they were ("N of K compared traces flagged"), the
## counts' check; with the given model's times left as the fit's, "the given model is off by";
## with the offsets shifted not used (given flagged by the fit's suspect flag), "most traces
## off"; with the fit's second velocity left out of the copy, "the fit's second velocity was
## not copied"; with the second segment not continuous (no `crossover / v1` term), "not
## continuous"; with a missing offset given 0, "a trace without an offset has a model time";
## with the key's word left "model", "key word"; with the project document not writing the
## model, "project document".

import std/[math, strutils]
import parseSEG
import viewSEG/core/[breakmodel, firstbreakjobs, firstbreaks, join, project, projectnif,
  settingsnif, settings, panels, geometry]
import utils/[breakfiles, fixtures]

const Truth = BreakModel(source: bmGiven, v1: 2500, interceptMs: 20)

proc moved(i: int; k: var TraceKeys): float64 =
  ## A source named wrongly: the headers' offsets are 100 m too long.
  k.offset = offsetOf(i) + 100
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
      doAssert g.medianDiffMs < -30 and g.medianDiffMs > -50, "median " & $g.medianDiffMs
      doAssert g.offModel * 10 > g.compared * 9, "most traces off: " & $g.offModel & " of " &
        $g.compared
      var flagged = 0
      for i in 0 ..< Traces:
        if g.mismatched(i): inc flagged
      doAssert flagged * 10 > Traces * 9, "most traces off: " & $flagged & " flagged"
      # (the counts read "N flagged (M of K compared off the model, ...)": the flagged count
      # holds the far-off traces, which are not among the K compared, so it is never "N of K")
      doAssert "median -4" in g.statusWords and " flagged" in g.statusWords, g.statusWords
      let counts = $g.rule.nFlagged & " flagged (" & $g.rule.nOffModel & " of " & $g.compared &
        " compared off the model, " & $g.rule.nOffNeighbours & " off their neighbours, " &
        $g.rule.nFarOff & " far off)"
      doAssert "median pick less model -4" in g.givenWords and counts in g.givenWords and
        "limit 12.0 ms" in g.givenWords, g.givenWords

  block aSourceFarOffIsFarOffTheModelAndTheModelDoesNotMatch:
    # 400 m too long is 160 ms: beyond the 100 ms band no pick is comparable, but the first pass
    # found every break, far from the model: each trace is flagged (far off the model)
    withFixtures fx:
      let b = breaksOf(fx.customShot("far.sgy", Traces, proc (i: int; k: var TraceKeys): float64 =
        k.offset = offsetOf(i) + 400
        arrivalMs(offsetOf(i))))
      let g = b.withModel(Truth)
      # (the range where breaks are expected ends at the 95th percentile of the offsets whose
      # picks both passes agree on: the outermost traces are beyond it)
      let inRange = Traces - g.rule.nBeyond
      doAssert g.rule.nBeyond <= 3 and g.compared == 0 and g.rule.nFarOff == inRange and
        g.offModel == inRange, $g.compared & " compared, " & $g.rule.nFarOff & " far off, " &
        $g.rule.nBeyond & " beyond"
      for i in 0 ..< inRange: doAssert g.mismatched(i) and not g.faintOf(i)
      doAssert g.rule.mismatch
      doAssert "does not match this record's breaks" in g.modelWords(suMetres),
        g.modelWords(suMetres)
      doAssert "far off the model" in g.modelWords(suMetres)
      doAssert $inRange & " flagged (0 of 0 compared off the model, 0 off their neighbours, " &
        $inRange & " far off)" in g.givenWords, g.givenWords

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
      doAssert b.keyParts == KeyParts() and b.keyNote == "", "a fitted model: a bare key"
      let g = b.withModel(Truth)
      # compact whatever the model: a marker for the given one and a count of those off it;
      # the velocity and the rest are in the tooltip
      doAssert g.keyParts.given and g.keyParts.off == $g.offModel & " off", $g.keyParts
      doAssert g.offModel > 0 and g.keyNote == "", "no long note beside the key: " & g.keyNote
      let aligned = b.withModel(BreakModel(source: bmGiven, v1: b.fit.v1,
        interceptMs: b.fit.interceptMs))
      doAssert aligned.keyParts.given and (aligned.offModel > 0 or aligned.keyParts.off == ""),
        $aligned.keyParts
      doAssert "2500 ft/s" in g.modelWords(suFeet) and "unit is taken from the project's" notin
        g.modelWords(suFeet)
      doAssert "unit is taken from the project's survey: the file names none" in
        g.modelWords(suUsFeet, fromSurvey = true), g.modelWords(suUsFeet, true)
      let w = g.modelWords(suMetres)
      doAssert "the one you gave" in w and "not fitted to the picks" in w, w
      doAssert "Velocity: 2500 m/s" in w and "Intercept: 20.0 ms" in w, w
      doAssert "Given model: median pick less model" in w and "Offsets from the file" in w, w
      let two = b.withModel(BreakModel(source: bmGiven, v1: 2500, v2: 4000, crossover: 1500))
      doAssert "Beyond 1500 m offset: 4000 m/s" in two.modelWords(suMetres),
        two.modelWords(suMetres)

  block lookPersistsAndIsNoPresetsBusiness:
    # Seen to fail: with the pick colour left out of the settings writer, "the pick colour
    # was not kept"; with asPreset keeping the size, "a preset keeps no size".
    var d = DisplaySettings(breakPickColour: Rgba(r: 10, g: 200, b: 30, a: 255),
      breakModelColour: Rgba(r: 250, g: 128, b: 0, a: 255), breakSize: bzLarge)
    var s = Settings()
    s.plot.display = d
    var problems: seq[string]
    let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert back.plot.display.breakPickColour == d.breakPickColour, "the pick colour was not kept"
    doAssert back.plot.display.breakModelColour == d.breakModelColour
    doAssert back.plot.display.breakSize == bzLarge
    # Seen to fail: with the show switches left out of the settings writer, "the picks'
    # switch was not kept".
    d.breakShowPicks = false
    s.plot.display = d
    let hidden = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert not hidden.plot.display.breakShowPicks, "the picks' switch was not kept"
    doAssert hidden.plot.display.breakShowModel, "the model's switch changed"
    doAssert asPreset(d).breakShowPicks, "a preset keeps the switch"
    doAssert not withPreset(d, DisplaySettings()).breakShowPicks
    doAssert DisplaySettings().breakShowPicks and DisplaySettings().breakShowModel
    doAssert settingsDocument(Settings()).count("breakShow") == 0, "defaults are not written"
    d.breakShowPicks = true
    doAssert settingsDocument(Settings()).count("breakPickColour") == 0, "defaults are not written"
    doAssert asPreset(d).breakSize == bzMedium and asPreset(d).breakPickColour.a == 0,
      "a preset keeps no size"
    doAssert withPreset(d, DisplaySettings()).breakSize == bzLarge
    doAssert DisplaySettings().breakSize == bzMedium
    # Seen to fail: with the weak picks' switch or the picking choice left out of the settings
    # writer, "the weak picks' switch was not kept" and "the picking choice was not kept".
    doAssert not DisplaySettings().breakShowWeak and DisplaySettings().breakPickOn == pbSmoothed
    doAssert settingsDocument(Settings()).count("breakShowWeak") == 0 and
      settingsDocument(Settings()).count("breakPickOn") == 0, "defaults are not written"
    d.breakShowWeak = true
    d.breakPickOn = pbAsRecorded
    s.plot.display = d
    let weak = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert problems.len == 0, $problems
    doAssert weak.plot.display.breakShowWeak, "the weak picks' switch was not kept"
    doAssert weak.plot.display.breakPickOn == pbAsRecorded, "the picking choice was not kept"
    doAssert not asPreset(d).breakShowWeak and asPreset(d).breakPickOn == pbSmoothed
    doAssert withPreset(d, DisplaySettings()).breakShowWeak and
      withPreset(d, DisplaySettings()).breakPickOn == pbAsRecorded
    doAssert bounded(DisplaySettings(breakPickColour: Rgba(r: 1, g: 2, b: 3, a: 7))).
      breakPickColour.a == 255

  echo "tbreakmodel: ok"

when isMainModule:
  main()
