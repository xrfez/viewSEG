## The map's units, without a window: the unit of the survey's coordinates
## as the data say it, never guessed (`surveyUnit`, `unitsOf`), and the unit
## and factor its lengths are shown in (`shownLengths`):
##
## - SPS grid units: metres ("m"), international feet ("ft", 0.3048 m a
##   unit), US survey feet ("ftUS": H20 `feet` with H201 0.3048006096, as
##   a land survey says them), and nothing said, or words without a
##   factor that name no unit known: not given (the scale bar says "units");
## - the units confirmed with a join come first;
## - a seismic file's own coordinate units when no survey file says;
## - lengths in another unit, converted exactly (1 ft = 0.3048 m, 1 ftUS =
##   1200/3937 m), and a scale bar's length and pixels in it; nothing
##   converted from a unit not known.
##
## - H201's factor rounded as files write it (0.3048006, 0.304801): the
##   foot it is nearest, US survey or international.
## - files that name different units: said once in the messages and by
##   `unitsDisagree` (the Layers list), the map keeping the first.
##
## Seen to fail: with "US ft" as the abbreviation of US survey feet, the
## US survey feet case failed; with lengths converted by 0.3048 for US
## survey feet too, "metres from US survey feet" failed; with the factor
## matched to 1e-9 (as it was), `factorsAsWritten` took 0.3048006 for
## international feet; with the disagreement not followed (`followUnits`
## left out), "said in the messages" found none.

import std/[math, strutils]
import parseSEG/survey/sps
import viewSEG/core/[mapview, state]
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

proc loaded(fx: Fixtures; name, gridUnits, factor: string): AppState =
  let sps = fx.mapSpsIn(name, gridUnits, factor)
  result = initAppState()
  result.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
  doAssert result.settle(result.survey.layers.len == 2), name

proc lengthsIn(st: var AppState; m: MapLengths) =
  var s = st.settings
  s.map.lengths = m
  st.apply Command(kind: ckSettings, settings: s)

withFixtures fx:
  block gridUnits:
    for (name, words, factor, unit, text) in [("metres", "Metres", "1.0", suMetres, "m"),
        ("feet", "Feet", "0.3048", suFeet, "ft"),
        ("usfeet", "feet", "0.3048006096", suUsFeet, "ftUS"),
        ("usfeet-words", "US survey feet", "", suUsFeet, "ftUS"),
        ("none", "", "", suNotGiven, ""), ("yards", "yards", "", suNotGiven, "")]:
      var st = fx.loaded(name, words, factor)
      doAssert st.surveyUnit == unit, name & ": " & $st.surveyUnit
      doAssert st.unitsOf == text, name & ": " & st.unitsOf
      doAssert st.shownLengths == (unit, 1.0), name
      doAssert lengthText(500, st.unitsOf) == (if text.len > 0: "500 " & text else: "500 units")

  block factorsAsWritten:
    # H201's factor as survey files write it, rounded: the foot it is nearest
    # (the two differ by 2 parts in a million). A factor that is neither
    # leaves the words to say.
    for (factor, words, unit) in [(0.3048006096, "feet", suUsFeet), (0.3048006, "feet", suUsFeet),
        (0.304801, "feet", suUsFeet), (0.30480061, "Metres", suUsFeet),
        (0.3048, "feet", suFeet), (0.30480, "US survey feet", suFeet),
        (0.304800, "", suFeet), (1.0, "feet", suMetres), (0.9999999, "", suMetres),
        (0.3047, "feet", suFeet), (0.3047, "", suNotGiven), (NaN, "US ft", suUsFeet)]:
      let got = unitOf(GridUnit(name: words, metres: factor))
      doAssert got == unit, $factor & " " & words & ": " & $got

  block conversions:
    doAssert metresPerUnit(suUsFeet) == 1200 / 3937 and metresPerUnit(suFeet) == 0.3048
    doAssert metresPerUnit(suMetres) == 1 and metresPerUnit(suDegrees).isNaN
    var st = fx.loaded("usfeet", "feet", "0.3048006096")
    st.lengthsIn(dlMetres)
    doAssert st.shownLengths == (suMetres, 1200 / 3937), "metres from US survey feet: " &
      $st.shownLengths
    st.lengthsIn(dlFeet)
    doAssert st.shownLengths.unit == suFeet and
      abs(st.shownLengths.factor - 1200 / 3937 / 0.3048) < 1e-15
    st.lengthsIn(dlUsFeet)
    doAssert st.shownLengths == (suUsFeet, 1.0)
    # A scale bar at 10 ftUS a pixel, 150 pixels at most, in metres: 3.048006 m
    # a pixel, so 200 m, drawn 200 / 3.048006 pixels long.
    st.lengthsIn(dlMetres)
    let bar = scaleBar(10 * st.shownLengths.factor, 150)
    doAssert bar.length == 200 and abs(bar.pixels - 200 / (10 * 1200 / 3937)) < 1e-9, $bar
    var none = fx.loaded("none", "", "")
    none.lengthsIn(dlMetres)
    doAssert none.shownLengths == (suNotGiven, 1.0), "nothing converted from a unit not known"

  block joinedUnitsFirst:
    var st = fx.loaded("feet", "Feet", "0.3048")
    let segy = fx.surveySegy()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: segy)
    doAssert st.settle(st.sessions.len == 1)
    let sps = fx.surveySps()
    st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
      JoinFile(path: sps.s, kind: jkSps), JoinFile(path: sps.r, kind: jkSps),
      JoinFile(path: sps.x, kind: jkSps)],
      joinUnits: JoinUnits(survey: suMetres))
    doAssert st.settle(st.joinReport.serial > 0 and st.joinUnderWay.job == NoJob)
    doAssert st.joinedOf(st.sessions[0].id) >= 0, $st.joinReport.words
    doAssert st.unitsOf == "m", "the units confirmed with the join: " & st.unitsOf

  block seismicFileUnits:
    # No survey file: the open file's own headers say (the survey SEG-Y's
    # binary header gives metres, or nothing).
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
    doAssert st.settle(st.sessions.len == 1)
    doAssert st.surveyUnit == unitOf(st.sessions[0].crs.units)
    echo "tmapunits: the survey SEG-Y's headers say ", st.sessions[0].crs.units

  block mixedUnits:
    # A survey file in feet, another in metres: said, once; the map keeps feet.
    var st = fx.loaded("feet2", "Feet", "0.3048")
    doAssert st.unitsDisagree == ""
    let m = fx.mapSpsIn("metres2", "Metres", "1.0")
    st.apply Command(kind: ckLoadSurvey, paths: @[m.s])
    doAssert st.settle(st.survey.layers.len == 3)
    let words = st.unitsDisagree
    doAssert "feet" in words and "metres" in words and "the map uses feet" in words, words
    doAssert st.surveyUnit == suFeet
    var said = 0
    for e in st.log:
      if e.severity == sevWarning and "units disagree" in e.text: inc said
    doAssert said == 1, "said in the messages: " & $said
    st.apply Command(kind: ckLoadSurvey, paths: @[m.s]) # nothing new: not said again
    discard st.settle(st.jobs.active.len == 0)
    said = 0
    for e in st.log:
      if e.severity == sevWarning and "units disagree" in e.text: inc said
    doAssert said == 1, "said again: " & $said

echo "tmapunits: done"
