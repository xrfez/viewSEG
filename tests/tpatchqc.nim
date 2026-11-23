## The noisy-trace test inside the template (`core/recordqc`, `NoiseSettings.templateOnly`)
## and the first-break key's words (`firstbreaks.modelWords`).
##
## A shot of 63 receivers on a land spread with a relation file that plans 30 of them
## (the patch): a trace 100 times louder outside the patch is not judged and not flagged,
## and is counted "outside the template"; the traces inside are judged as they were without
## it (twenty loud traces outside the patch must not change which inside traces are flagged);
## with the tick off, every trace is judged again; with no relation file there is no
## template and the record is judged whole, as before. The model's words say what it is:
## its velocity (2500 m/s on the synthetic shot), unit, intercept, picks and the source of
## the offsets.
##
## Seen to fail: with the outside traces not left out of the call, "outside traces were
## flagged" and "the outside traces changed the inside flags"; with the tick ignored,
## "tick off: outside trace not judged"; with the template used without a relation file
## (every trace outside), "no template: traces were left out"; with the count not kept,
## "outside the template: 0"; with the velocity shown from the intercept,
## "velocity words"; with the offsets' source left out of the words, "offsets source".

import std/[os, strutils]
import parseSEG
import viewSEG/core/[firstbreaks, firstbreakjobs, join, noisearea]
import viewSEG/core/state
import utils/[breakfiles, fixtures, waiting]

const
  Filters = {mfNoisy, mfWeak, mfLouder, mfNotJudged, mfUnlisted}
  ManyLoud = [(0, 12), (0, 13), (0, 14), (0, 15), (0, 16), (0, 17), (0, 18), (0, 19),
    (1, 12), (1, 13), (1, 14), (1, 15), (1, 16), (1, 17), (1, 18), (1, 19),
    (2, 12), (2, 13), (2, 14), (2, 15)] ## receivers past the ten planned on each line
  OneLoud = [(1, 15)]

proc withFilters(st: var AppState; templateOnly: bool) =
  var s = st.settings
  s.map.filters = Filters
  s.noise.templateOnly = templateOnly
  st.apply Command(kind: ckSettings, settings: s)

func done(st: AppState): bool =
  st.recordQc.job == NoJob and st.recordQc.noise.ready and
    st.recordQc.hits[mfNoisy].state == fsDone and st.recordQc.hits[mfUnlisted].state != fsComputing

proc openShot(st: var AppState; path: string; survey: seq[string]) =
  if survey.len > 0:
    st.apply Command(kind: ckLoadSurvey, paths: survey)
    doAssert st.settle(st.survey.layers.len == survey.len and st.jobs.active.len == 0)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)

func inside(h: array[MapFilter, FilterHits]; m: MapFilter): seq[int] =
  ## The traces of filter `m` that the template plans (not among the unlisted).
  for t in h[m].traces:
    if t notin h[mfUnlisted].traces: result.add t

proc main*() =

  block outsideTheTemplateIsNotJudged:
    withFixtures fx:
      let sps = fx.mapSps()
      let survey = @[sps.s, sps.r, fx.mapXps]
      let plain = fx.mapShotSegd(0, 2, {mdNoisy}, "plain.sgd")
      let loud = fx.mapShotSegd(0, 2, {mdNoisy}, "loud.sgd", ManyLoud)
      let one = fx.mapShotSegd(0, 2, {mdNoisy}, "one.sgd", OneLoud)
      var plainInside, plainNoisy, plainWeak, plainLouder: seq[int]
      block baseline:
        var st = initAppState()
        st.openShot(plain, survey)
        st.withFilters(true)
        doAssert st.settle(st.done)
        let h = st.filterHits
        plainInside = h.inside(mfNoisy)
        (plainNoisy, plainWeak, plainLouder) = (h[mfNoisy].traces, h[mfWeak].traces,
          h[mfLouder].traces)
        doAssert plainInside.len == 1 and h[mfUnlisted].count == 33, $h[mfUnlisted].count
        doAssert st.recordQc.noise.outsideCount == 33,
          "outside the template: " & $st.recordQc.noise.outsideCount
        doAssert "33 outside the template" in st.recordQc.noise.notJudgedWords,
          st.recordQc.noise.notJudgedWords
        st.shutdown()
      block oneLoudOutside:
        var st = initAppState()
        st.openShot(one, survey)
        st.withFilters(true)
        doAssert st.settle(st.done)
        let h = st.filterHits
        let n = st.recordQc.noise
        doAssert h[mfNoisy].traces == plainNoisy, "outside traces were flagged: " &
          $h[mfNoisy].traces
        doAssert h[mfLouder].traces == plainLouder and h[mfWeak].traces == plainWeak,
          "louder or weak outside the template"
        for t in h[mfUnlisted].traces: doAssert t in h[mfNotJudged].traces
        doAssert n.outsideCount == 33 and h[mfNotJudged].count >= 33, $n.outsideCount
        doAssert "outside the template" in h[mfNotJudged].note, h[mfNotJudged].note
        doAssert n.outsideAt(h[mfUnlisted].traces[0]) # the state says it per trace
        # the tick off: every trace is judged again
        st.withFilters(false)
        doAssert st.settle(st.done and not st.recordQc.noise.asked.templateOnly)
        let all = st.filterHits
        doAssert st.recordQc.noise.outsideCount == 0, "tick off: outside trace not judged"
        doAssert all[mfNoisy].traces.len > plainNoisy.len, "tick off: " & $all[mfNoisy].traces
        st.shutdown()
      block statistics:
        var st = initAppState()
        st.openShot(loud, survey)
        st.withFilters(true)
        doAssert st.settle(st.done)
        var h = st.filterHits
        doAssert h[mfNoisy].traces == plainNoisy,
          "the outside traces changed the inside flags: " & $h[mfNoisy].traces & " against " &
          $plainNoisy
        doAssert h[mfWeak].traces == plainWeak and h[mfLouder].traces == plainLouder,
          "the outside traces changed the inside flags: weak " & $h[mfWeak].traces &
          ", louder " & $h[mfLouder].traces
        st.withFilters(false)
        doAssert st.settle(st.done and not st.recordQc.noise.asked.templateOnly)
        h = st.filterHits
        doAssert h.inside(mfNoisy) != plainInside or h[mfWeak].traces != plainWeak or
            h[mfLouder].traces != plainLouder,
          "tick off: the loud outside traces did not change the statistics"
        st.shutdown()
      block noTemplate:
        var st = initAppState()
        st.openShot(one, @[])
        st.withFilters(true)
        doAssert st.settle(st.done)
        doAssert st.recordQc.noise.outsideCount == 0 and st.recordQc.noise.outside.len == 0,
          "no template: traces were left out"
        doAssert st.filterHits[mfNoisy].traces.len >= 2, "no template: judged whole"
        st.shutdown()

  block theModelsWords:
    withFixtures fx:
      var f = openSeismic(fx.shotSegy("model.sgy", gHeaderOffset), keys = true)
      let b = breaksOfRecord(addr f, fx.dir / "model.sgy", 0 ..< f.len, [])
      f.close()
      doAssert b.segments in 1 .. 2 and b.hasModel
      doAssert abs(b.fit.v1 - 2500) < 150, "fitted velocity " & $b.fit.v1
      doAssert abs(b.fit.interceptMs - 20) < 8, "intercept " & $b.fit.interceptMs
      let w = b.modelWords(suMetres)
      doAssert "straight-line refraction fit to this record's own picks" in w, w
      doAssert "No velocity is typed in" in w, w
      let near = "Velocit" & (if b.segments == 1: "y: " else: "ies: ") & $int(round(b.fit.v1)) &
        " m/s"
      doAssert near in w, "velocity words: " & w
      doAssert "Intercept: " in w and " ms" in w, w
      doAssert "Fitted to " & $b.used & " confident picks" in w, w
      doAssert "Offsets from the file's own headers" in w, "offsets source: " & w
      doAssert "ft/s" in b.modelWords(suFeet), b.modelWords(suFeet)
      doAssert "offset units per second" in b.modelWords(suNotGiven)
      var two = b
      two.fit.v2 = 4000
      two.fit.crossover = 1200
      let w2 = two.modelWords(suMetres)
      doAssert two.segments == 2 and "beyond 1200 m offset" in w2 and "4000 m/s" in w2, w2
      var none = b
      none.modelled = 0
      doAssert none.modelWords(suMetres) == "" and none.segments == 0
      var survey = b
      survey.source = bsSurvey
      (survey.withOffset, survey.fromPositions) = (b.modelled, b.modelled)
      doAssert "Offsets from the imported survey" in survey.modelWords(suMetres)

  echo "tpatchqc: ok"

when isMainModule:
  main()
