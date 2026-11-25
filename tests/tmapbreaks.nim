## The map's first-break filters ("first break off the model", "first break off its
## neighbours") in `core`, without a window: they are the first-break overlay's flags of the
## record shown, from its one result.
##
## On `breakfiles`' shot (48 traces, the coordinates in the headers, trace 20's data 80 ms
## late: its station is wrong):
## - ticked with the overlay off: "computing" (never a count of 0) while one picking job runs,
##   the overlay stays off; then the counts, and trace 20 off the model;
## - the overlay turned on: no second job, and its flags are the filters' traces: off the model
##   (with far off) and off its neighbours, each set, and together every trace it joins with a
##   line; so too with the picking on the samples as recorded instead of smoothed, chosen in
##   the overlay's settings while it is off;
## - with the noisy filter on too, the record is picked once for both, whatever the overlay
##   (off) is set to pick on;
## - a record with no offsets and no coordinates: not checked, with the overlay's reason;
## - the traces with no break found and beyond the offsets where breaks are seen are said in a
##   line, not judged.
##
## Seen to fail: with the filters taking no result (no key wanted while the overlay is off),
## "computing" never ended; with the far-off traces left out of "off the model", trace 20 was
## in neither filter while the overlay joined it; with the panel's pick choice not in the
## filters' key, the picks on the samples as recorded gave other traces than the overlay's; with
## `breakKeyFor` keeping to panels with the overlay on, the noise check picked the record a second
## time.

import std/[algorithm, atomics, strutils]
import parseSEG
import viewSEG/core/[firstbreaks, jobs, state]
import viewSEG/view/maplayers
import utils/[breakfiles, fixtures, waiting]

var picked: Atomic[int] ## picking passes begun (a first-break job's, or a record check's)

proc countPicks(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  discard id
  if not back and phase in ["picking and fitting the first breaks", "picking the first breaks"]:
    picked.atomicInc

proc on(st: var AppState; filters: set[MapFilter]) =
  var s = st.settings
  s.map.filters = filters
  st.apply Command(kind: ckSettings, settings: s)

proc shown(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)

func sorted(xs: seq[int]): seq[int] =
  result = xs
  result.sort()

proc overlaySets(b: FirstBreaks; base: int): tuple[model, neighbours, joined: seq[int]] =
  ## The overlay's flags of `b`, as survey-wide trace ids: off the model or far off it, off its
  ## neighbours, and every trace it joins with a line (`mismatched`).
  for i in 0 ..< b.pickMs.len:
    let t = b.first + i
    if b.rule.offModel[i] or b.rule.farOff[i]: result.model.add base + t
    if b.rule.offNeighbours[i]: result.neighbours.add base + t
    if b.mismatched(t): result.joined.add base + t

proc main*() =
  setJobHook(countPicks)

  block theOverlaysFlags:
    for basis in [pbSmoothed, pbAsRecorded]:
      withFixtures fx:
        var st = initAppState()
        st.shown fx.shotSegy("shot.sgy", gCoordinates)
        let base = st.sessions[0].base
        var d = st.panel(MainPanel).layers[0].display
        if basis != pbSmoothed:
          d.breakPickOn = basis # (the overlay's settings, while it is off)
          st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
          doAssert st.settle(st.jobs.active.len == 0)
        doAssert st.firstBreaks.len == 0, "work done with nothing asking"
        picked.store 0
        st.on({mfBreakOffModel, mfBreakOffNeighbours})
        # asked for: computing, one job, and the overlay still off
        var h = st.filterHits
        for f in BreakFilters:
          doAssert h[f].state == fsComputing and filterLabel(f, h[f]).endsWith("(computing...)"),
            $f & ": " & $h[f]
        doAssert st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkComputing and
          st.firstBreaks[0].key.pick == basis, "no job for the filters"
        doAssert st.settle(st.jobs.active.len == 0 and
          st.filterHits[mfBreakOffModel].state != fsComputing)
        doAssert not st.panel(MainPanel).layers[0].display.firstBreaks, "the overlay came on"
        doAssert picked.load == 1, "picked " & $picked.load & " times"
        h = st.filterHits
        for f in BreakFilters:
          doAssert h[f].state == fsDone and h[f].count == h[f].traces.len, $f & ": " & $h[f]
        doAssert base + PlantedTrace in h[mfBreakOffModel].traces, $h[mfBreakOffModel]
        doAssert "ms from the model" in h[mfBreakOffModel].note, h[mfBreakOffModel].note
        # the overlay on: the same result, no new job, and its flags are the filters'
        d = st.panel(MainPanel).layers[0].display
        d.firstBreaks = true
        st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
        doAssert st.jobs.active.len == 0 and st.firstBreaks.len == 1, "a second job"
        doAssert st.settle(st.jobs.active.len == 0)
        doAssert picked.load == 1, "picked again for the overlay"
        let k = st.findPanel(MainPanel)
        let b = st.shownBreaks(k)
        doAssert b.state == bkDone and b.hasModel and b.key.pick == basis
        let (model, neighbours, joined) = b.overlaySets(base)
        h = st.filterHits
        doAssert h[mfBreakOffModel].traces.sorted == model, $basis & ": " &
          $h[mfBreakOffModel].traces & " / " & $model
        doAssert h[mfBreakOffNeighbours].traces.sorted == neighbours, $basis & ": " &
          $h[mfBreakOffNeighbours].traces & " / " & $neighbours
        var both = h[mfBreakOffModel].traces & h[mfBreakOffNeighbours].traces
        both.sort()
        var union: seq[int] = @[]
        for t in both:
          if union.len == 0 or union[^1] != t: union.add t
        doAssert union == joined, $union & " / " & $joined
        st.shutdown()

  block withTheNoiseTest:
    # the noisy filter's check and the first-break filters share one picking of the record,
    # also when the overlay (off) is set to pick on the samples as recorded
    withFixtures fx:
      var st = initAppState()
      st.shown fx.shotSegy("noise.sgy", gCoordinates)
      var d = st.panel(MainPanel).layers[0].display
      d.breakPickOn = pbAsRecorded
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.jobs.active.len == 0)
      picked.store 0
      st.on({mfNoisy, mfBreakOffModel})
      doAssert st.settle(st.jobs.active.len == 0 and st.recordQc.job == NoJob and
        st.filterHits[mfBreakOffModel].state == fsDone and
        st.filterHits[mfNoisy].state == fsDone), $st.filterHits[mfBreakOffModel]
      doAssert picked.load == 1, "picked " & $picked.load & " times"
      doAssert st.sessions[0].base + PlantedTrace in st.filterHits[mfBreakOffModel].traces
      st.shutdown()

  block noOffsets:
    withFixtures fx:
      var st = initAppState()
      st.shown fx.shotSegy("bare.sgy", gNothing)
      st.on({mfBreakOffModel, mfBreakOffNeighbours})
      doAssert st.settle(st.jobs.active.len == 0 and
        st.filterHits[mfBreakOffModel].state != fsComputing)
      let h = st.filterHits
      for f in BreakFilters:
        doAssert h[f].state == fsNotChecked and
          "the model needs source-receiver offsets" in h[f].note, $f & ": " & $h[f]
      doAssert st.breakFilterWords == ""
      st.shutdown()

  block notJudgedWords:
    # the traces with no break, and those beyond the offsets where breaks are seen
    var b = FirstBreaks(state: bkDone, modelled: 4, pickMs: @[1.0, 2, 3, 4],
      rule: BreakRule(offModel: @[false, true, false, false], farOff: @[false, false, true,
        false], offNeighbours: @[false, false, false, true], nNoBreak: 2, nBeyond: 1,
        limitMs: 14.0, stationLimitMs: 20.0, guideWindowMs: 20.0))
    b.first = 10
    let h = b.filterHitsOf(100)
    doAssert h.offModel.traces == @[111, 112] and h.offNeighbours.traces == @[113], $h
    doAssert h.notJudged == "First breaks: 2 traces with no break found; 1 beyond the offsets " &
      "where breaks are seen: not judged.", h.notJudged
    b.rule.nNoBreak = 0
    doAssert b.filterHitsOf(0).notJudged == "First breaks: 1 trace beyond the offsets where " &
      "breaks are seen: not judged.", b.filterHitsOf(0).notJudged
    b.state = bkComputing
    doAssert b.filterHitsOf(0).offModel.state == fsComputing

  setJobHook(nil)
  echo "tmapbreaks: ok"

when isMainModule:
  main()
