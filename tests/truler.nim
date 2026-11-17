## The ruler's reading (`rulerReading`), one case per unit of the survey:
## metres, international feet, US survey feet, and a unit not known. For each
## of the gear's four Lengths choices the number is in that unit, with that
## unit's short name (`m`, `ft`, `ftUS`). An unknown unit keeps the survey's
## number and names no unit.
##
## Seen to fail: with the reading made by `lengthText`, a survey in metres
## at 1 500 read "1.50 km" ("metres"), and a unit not known read "2.50 units"
## ("not known").

import std/[math, strutils]
import viewSEG/core/[mapview, state]
import viewSEG/view/maplayers
import utils/[fixtures, waiting]

proc expect(n: float64; unit: string): string =
  let num = if n == round(n) and abs(n) < 1e15: $int64(n)
            else: formatFloat(n, ffDecimal, (if abs(n) >= 10: 1 else: 2))
  if unit.len == 0: num else: num & " " & unit

proc lengthsIn(st: var AppState; m: MapLengths) =
  var s = st.settings
  s.map.lengths = m
  st.apply Command(kind: ckSettings, settings: s)

proc check(st: var AppState; distance: float64; name, short: string) =
  for m in MapLengths:
    st.lengthsIn(m)
    let (u, f) = st.shownLengths
    let got = rulerReading(distance, (u, f))
    let want = expect(distance * f, u.abbreviation)
    doAssert got == want, name & " " & $m & ": " & got & " not " & want
    doAssert "units" notin got, name & " invents a unit: " & got
    if short.len == 0:
      doAssert ' ' notin got, name & " names a unit: " & got
    elif m == dlSurvey or u.abbreviation == short:
      doAssert got.endsWith(" " & u.abbreviation), name & " " & $m & ": " & got

proc loaded(fx: Fixtures; name, words, factor: string): AppState =
  let sps = fx.mapSpsIn(name, words, factor)
  result = initAppState()
  result.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
  doAssert result.settle(result.survey.layers.len == 2), name

proc main*() =

  withFixtures fx:
    block metres:
      var st = fx.loaded("metres", "Metres", "1.0")
      st.check(1500, "metres", "m")
      doAssert rulerReading(1500, (suMetres, 1.0)) == "1500 m", "metres"

    block feet:
      var st = fx.loaded("feet", "Feet", "0.3048")
      st.check(1000, "feet", "ft")
      st.lengthsIn(dlMetres)
      doAssert st.shownLengths.unit == suMetres
      doAssert rulerReading(1, st.shownLengths) == expect(0.3048, "m")

    block usFeet:
      var st = fx.loaded("usfeet", "feet", "0.3048006096")
      st.check(1200, "US survey feet", "ftUS")
      st.lengthsIn(dlFeet)
      doAssert st.shownLengths.unit == suFeet
      let n = 1200 * (1200 / 3937) / 0.3048
      doAssert rulerReading(1200, st.shownLengths) == expect(n, "ft"), "US survey feet"

    block notKnown:
      var st = fx.loaded("none", "", "")
      st.check(2.5, "not known", "")
      doAssert rulerReading(2.5, (suNotGiven, 1.0)) == "2.50", "not known"
      st.lengthsIn(dlMetres)
      doAssert rulerReading(2.5, st.shownLengths) == "2.50", "nothing converted"

  echo "truler: ok"

when isMainModule:
  main()
