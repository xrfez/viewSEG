## The noisy-trace test's settings and words (`core/noisearea`) and the
## exclusion area's geometry (`view/areabands`), without a window or a file:
##
## - the settings map onto the library's parameters (automatic by default; a
##   fixed time, a radius, a count of stations with its default of 8; "every
##   line"), a number out of range is bounded, never the library's trend;
## - the choice is saved in the settings file and read back, bounded;
## - the words say which rule set the area and why not another, in plain words
##   with no library name; the not-judged words name the unknown sensors;
## - the bands cover the runs of traces inside the area as the plot shows them,
##   in a sorted plot too, and none without an area.
##
## Seen to fail: with the radius choice mapped to a fixed time, "radius: fixed time"; with the
## choice left out of the settings file, "the choice did not come back"; with the origin left out
## of the words, "header coordinates" was missing; with the bands taken in file order, "the
## sorted plot's band covers positions 10 .. 12".

import std/[math, strutils]
import processSEG/qc/exclusion
import viewSEG/core/[geometry, noisearea, orientation, settings, settingsnif, viewport]
import viewSEG/view/areabands

proc summary(rule: AreaRule; reasons: set[AreaReason] = {}): NoiseSummary =
  NoiseSummary(ready: true, rule: rule, reasons: reasons, edgeMs: NaN, radius: NaN,
    origin: ooUnknown)

proc main*() =

  block settingsMapOntoTheLibrary:
    doAssert NoiseSettings().paramsOf(ooUnknown).choice == acAuto
    doAssert NoiseSettings().steps == 8
    let t = NoiseSettings(choice: ncTime, edgeMs: 150).paramsOf(ooHeaders)
    doAssert t.choice == acFixedTime and t.edgeMs == 150 and t.offsetOrigin == ooHeaders
    let r = NoiseSettings(choice: ncRadius, radius: 640).paramsOf(ooSurvey)
    doAssert r.choice == acFixedRadius, "radius: " & $r.choice
    doAssert r.radius == 640
    let s = NoiseSettings(choice: ncSteps, steps: 3, allLines: true).paramsOf(ooUnknown)
    doAssert s.choice == acSteps and s.steps == 3 and s.stepsOnAllLines
    for c in NoiseChoice:
      doAssert NoiseSettings(choice: c).paramsOf(ooUnknown).choice != acTrend
    let bad = NoiseSettings(edgeMs: NaN, radius: -4, steps: 99999).bounded
    doAssert bad.edgeMs == 100 and bad.radius == 500 and bad.steps == MaxStations
    doAssert NoiseSettings(steps: -3).bounded.steps == 0

  block theChoiceIsSaved:
    var s = Settings()
    s.noise = NoiseSettings(choice: ncSteps, edgeMs: 75, radius: 320, steps: 5, allLines: true)
    var problems: seq[string]
    let back = readSettings(settingsDocument(s), "settings.nif", Settings(), problems)
    doAssert back.noise == s.noise, "the choice did not come back: " & $back.noise
    doAssert problems.len == 0, $problems
    doAssert readSettings("(settings (version 1))", "s.nif", Settings(), problems).noise ==
      NoiseSettings(), "a file without the choice is automatic"
    s.noise.steps = 7
    doAssert Settings().noise.choice == ncAuto

  block theWordsSayWhichRuleAndWhy:
    var n = summary(arModel)
    n.edgeMs = 187.0
    doAssert n.areaWords == "Area set by the first-break model (edge at 187 ms)", n.areaWords
    n = summary(arRadius, {rnNoPicks})
    n.origin = ooHeaders
    n.radius = 640
    doAssert "header" in n.areaWords and "radius 640" in n.areaWords, "header coordinates: " &
      n.areaWords
    doAssert "no first breaks" in n.areaWords, n.areaWords
    n.origin = ooSurvey
    doAssert "survey" in n.areaWords
    n = summary(arSteps, {rnNoOffsets})
    n.steps = 8
    n.lines = 4
    n.linesReached = 1
    doAssert n.areaWords.startsWith("Area set by 8 stations either side of the source"), n.areaWords
    doAssert "1 of 4 lines" in n.areaWords, n.areaWords
    n.domain = gdCommonReceiver
    doAssert "8 shots either side of the receiver" in n.areaWords, n.areaWords
    n = summary(arNone, {rnNoOffsets, rnNoPosition})
    doAssert n.areaWords == "No area: every trace judged (no offsets, coordinates or " &
      "station numbers)", n.areaWords
    n = summary(arNone, {rnOverrideNeedsModel})
    doAssert "needs the first-break model" in n.areaWords, n.areaWords
    n = summary(arFixedTime)
    n.edgeMs = 90
    doAssert "you chose" in n.areaWords and "90 ms" in n.areaWords, n.areaWords
    doAssert summary(arNone).areaWords.startsWith("No area")
    doAssert NoiseSummary().areaWords == "", "words before there is a result"
    # no library name reaches the user
    for r in AreaRule:
      for w in [summary(r).areaWords, summary(r, {rnNoPicks, rnBadModel}).areaWords]:
        for name in ["arModel", "acAuto", "AreaRule", "noiseQc", "exclusion", "trend"]:
          doAssert name notin w, "the library's name " & name & " in: " & w
    n = summary(arModel, {rnUnknownSensors, rnAllInside})
    doAssert "sensors are not named" in n.notesWords and "whole group" in n.notesWords,
      n.notesWords

  block theTracesNotJudgedAreCountedAndNamed:
    var n = summary(arModel)
    (n.inArea, n.unknown, n.incomplete, n.unusable) = (12, 3, 2, 5)
    doAssert n.notJudged == 17, "no-samples traces are not counted here: " & $n.notJudged
    let w = n.notJudgedWords
    doAssert "12 inside the area" in w and "3 with the sensor or station unknown" in w and
      "2 traces of an incomplete node" in w, w
    doAssert summary(arNone).notJudgedWords == "none"

  block bandsFollowThePlot:
    const n = 20
    var s = summary(arModel)
    s.first = 100
    s.inArea = 6
    s.inside = newSeq[bool](n)
    for i in 0 .. 2: s.inside[i] = true
    for i in 10 .. 12: s.inside[i] = true
    let plot = Rect(pos: vec2(0, 0), size: vec2(200, 100))
    let layout = PanelLayout(traces: n, samples: 500, dtMs: 2, t0Ms: 0)
    let view = Viewport(traces: Span(lo: -0.5, hi: n.float64 - 0.5),
      timeMs: Span(lo: 0, hi: 1000), columns: 200, rows: 100)
    var shown = newSeq[int](n)
    for i in 0 ..< n: shown[i] = 100 + i
    let bands = areaBands(s, shown, layout, view, TimeDown, plot)
    doAssert bands.len == 2, "bands: " & $bands.len
    doAssert bands[0].first == 0 and bands[0].last == 2 and bands[1].first == 10 and
      bands[1].last == 12
    doAssert abs(bands[0].a.x - 0) < 0.5 and abs(bands[0].b.x - 30) < 0.5, $bands[0]
    doAssert bands[0].a.y == 0 and bands[0].b.y == 100, "the band runs the whole time axis"
    # a sorted plot: the traces reversed, so the area is at the other end
    var rev = shown
    for i in 0 ..< n: rev[i] = shown[n - 1 - i]
    let sorted = areaBands(s, rev, layout, view, TimeDown, plot)
    doAssert sorted.len == 2 and sorted[1].first == 17 and sorted[1].last == 19,
      "the sorted plot's band covers positions " & $sorted[1].first & " .. " & $sorted[1].last
    # no area, no band; not ready, none either
    s.inArea = 0
    doAssert areaBands(s, shown, layout, view, TimeDown, plot).len == 0
    doAssert areaBands(NoiseSummary(), shown, layout, view, TimeDown, plot).len == 0

  echo "tnoisearea: ok"

when isMainModule:
  main()
