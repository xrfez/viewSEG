## The pre-plot fold job (`core/foldjobs`) on `samples/land`, without a window.
##
## - The counts the job returns equal a direct `surveyGrid` + `preplotFold` call on
##   a geometry read from the same files, and the grid's origin, azimuth and
##   bin sizes place every bin where the library's `location` does.
## - A cancel leaves the sink untouched.
## - A survey with no X records gives the reason, and no job.
## - A bin size of 0.01 gives the budget sentence, not a crash.
## - The follower keeps results by survey and bin size (a bin size chosen again
##   starts no job), and drops them when a survey is loaded or cleared.
##
## Seen to fail: with the grid's origin taken from the library's `location(1)` instead of
## `location(0)`, "bins are placed where the library puts them" failed; with the cache
## key leaving the bin sizes out, "a bin size chosen again" found the first size's map
## for the second.

import std/[math, os, strutils]
import parseSEG
import processSEG/qc/fold
import processSEG/stack/binning
import viewSEG/core/[foldjobs, jobs, state]
import utils/waiting

const Land = "samples/land/land"

proc loaded(st: var AppState; paths: varargs[string]): bool =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)
  st.settle(st.jobs.active.len == 0 and st.survey.layers.len >= paths.len)

proc finish(t: var FoldTracker; st: var AppState; on: bool; along = NaN; across = NaN): bool =
  ## Follows until the tracker is ready or has said why not.
  t.follow(st.jobs, st.survey, on, along, across)
  waitUntil((t.follow(st.jobs, st.survey, on, along, across);
    t.status != fsComputing))

proc main*() =
  block counts:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    doAssert st.survey.foldReason == ""
    var t: FoldTracker
    doAssert t.finish(st, true) and t.status == fsReady, t.reason
    let r = t.shown
    doAssert not r.isNil and r.ok and r.kind == fkPreplot
    var g = initSurveyGeometry()
    for ext in [".s", ".r", ".x"]: g.addSps(Land & ext)
    let grid = surveyGrid(g)
    var direct = g.preplotFold(grid)
    doAssert r.inlines == grid.inlines and r.crosslines == grid.crosslines
    doAssert r.counts == direct.fold.toFlatSeq, "counts differ from a direct call"
    doAssert r.maxFold == max(direct.fold.toFlatSeq)
    doAssert r.binned == direct.binned and r.outside == direct.outside and
      r.noCoordinates == direct.noCoordinates
    doAssert r.maxFold > 0 and r.binned > 0
    # bins are placed where the library puts them
    let (u, v) = (sin(degToRad(r.azimuthDeg)), cos(degToRad(r.azimuthDeg)))
    for bin in [0, r.crosslines - 1, (r.inlines - 1) * r.crosslines, r.inlines * r.crosslines - 1]:
      let loc = grid.location(bin)
      let (i, j) = (float64(bin div r.crosslines), float64(bin mod r.crosslines))
      let x = r.x0 + j * r.binAlong * u + i * r.binAcross * v
      let y = r.y0 + j * r.binAlong * v - i * r.binAcross * u
      doAssert abs(x - loc.x) < 1e-6 * max(1.0, abs(x)) and abs(y - loc.y) < 1e-6 * max(1.0, abs(y)),
        "bins are placed where the library puts them: " & $(x, y) & " vs " & $(loc.x, loc.y)

  block cancel:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    let inp = foldInputs(st.survey, NaN, NaN)
    let sink = FoldSink()
    let id = st.jobs.submit(foldSpec(), foldWork(inp, sink))
    discard st.jobs.cancel(id)
    doAssert waitUntil(st.jobs.active.len == 0)
    doAssert sink.result.counts.len == 0 and not sink.result.ok, "a cancel leaves nothing"

  block noRelations:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r")
    doAssert st.survey.foldReason == NoRelations
    var t: FoldTracker
    t.follow(st.jobs, st.survey, true, NaN, NaN)
    doAssert t.status == fsImpossible and t.reason == NoRelations and t.shown.isNil
    doAssert st.jobs.active.len == 0

  block budget:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true, 0.01, 0.01)
    doAssert t.status == fsFailed and "too many bins" in t.reason, t.reason
    doAssert t.shown.isNil

  block cache:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true)
    let first = t.shown
    doAssert t.finish(st, true, 50.0, 50.0) and t.status == fsReady
    let second = t.shown
    doAssert second != first and second.binAlong != first.binAlong,
      "a bin size chosen again found the first size's map for the second"
    let rev = t.revision
    t.follow(st.jobs, st.survey, true, NaN, NaN) # back to the natural bin: from the cache
    doAssert t.status == fsReady and t.shown == first and st.jobs.active.len == 0,
      "a bin size chosen again starts no job"
    doAssert t.revision > rev
    # off: nothing drawn, the results kept
    t.follow(st.jobs, st.survey, false, NaN, NaN)
    doAssert t.status == fsOff and t.shown.isNil
    t.follow(st.jobs, st.survey, true, NaN, NaN)
    doAssert t.shown == first, "turned on again: the kept map"
    # a new import drops them
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    st.apply Command(kind: ckClearSurvey)
    doAssert st.settle(st.survey.layers.len == 0 and st.jobs.active.len == 0)
    t.follow(st.jobs, st.survey, true, NaN, NaN)
    doAssert t.shown.isNil and t.status == fsImpossible,
      "dropped when the survey is cleared"
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    doAssert t.finish(st, true) and t.shown != first and t.shown != nil,
      "a new import counts again"

  echo "tfoldjobs: ok"

when isMainModule:
  main()
