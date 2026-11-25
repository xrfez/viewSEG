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
## - A survey file read again is counted again (the cache keys on the layer), a count whose
##   record was dropped from the job history does not stay "computing", bin sizes as typed are
##   kept and shown to six digits, a grid of one bin says so, the zoom levels come with the
##   result, and bin sizes changed in quick succession end with the last one's map.
## - A survey rotated by 33 degrees (made here from the sample): its corner and inner bins are
##   where the library's `location` puts them, and `binAt` finds them again.
##
## Seen to fail: with the layer's id left out of the cache key, "a file read again" kept the old
## map; with a forgotten job's record left unhandled the follower stayed "computing" (the test
## timed out); with the typed sizes measured from `location` again, "typed sizes" found
## 12.300000000046566; with every size 1, the rotated survey's bins were far from `location`;
## with `binAt` along the unturned axes, "binAt does not find bin 47". Earlier: with the grid's
## origin taken from the library's `location(1)` instead of
## `location(0)`, "bins are placed where the library puts them" failed; with the cache
## key leaving the bin sizes out, "a bin size chosen again" found the first size's map
## for the second.

import std/[math, os, strformat, strutils]
import parseSEG
import processSEG/qc/fold
import processSEG/stack/binning
import viewSEG/core/[colourmaps, foldgrid, foldjobs, jobs, state]
import utils/[fixtures, waiting]

const Land = "samples/land/land"

proc loaded(st: var AppState; paths: varargs[string]): bool =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)
  st.settle(st.jobs.active.len == 0 and st.survey.layers.len >= paths.len)

proc finish(t: var FoldTracker; st: var AppState; on: bool; along = NaN; across = NaN): bool =
  ## Follows until the tracker is ready or has said why not.
  t.follow(st.jobs, st.survey, on, along, across)
  waitUntil((t.follow(st.jobs, st.survey, on, along, across);
    t.status != fmComputing))

proc rotatedCopy(src, dest: string; degrees: float64) =
  ## `src`, an SPS S or R file, with its coordinates turned `degrees` about the middle of
  ## `samples/land` (easting in columns 47 to 55, northing in 56 to 65).
  let (cx, cy) = (2_001_000.0, 500_000.0)
  let (s, c) = (sin(degToRad(degrees)), cos(degToRad(degrees)))
  var text = ""
  for line in readFile(src).splitLines:
    var l = line
    if l.len >= 65 and l[0] in {'S', 'R'}:
      let (dx, dy) = (parseFloat(l[46 .. 54].strip) - cx, parseFloat(l[55 .. 64].strip) - cy)
      l = l[0 .. 45] & &"{cx + dx * c - dy * s:>9.1f}" & &"{cy + dx * s + dy * c:>10.1f}" &
        l[65 .. ^1]
    text.add l & "\n"
  writeFile(dest, text)

proc checkPlaced(r: FoldResult; grid: Binning; bins: openArray[int]) =
  ## Each bin of `bins` is where `grid.location` puts it, and `binAt` finds it there.
  let (u, v) = (sin(degToRad(r.azimuthDeg)), cos(degToRad(r.azimuthDeg)))
  for bin in bins:
    let loc = grid.location(bin)
    let (i, j) = (float64(bin div r.crosslines), float64(bin mod r.crosslines))
    let x = r.x0 + j * r.binAlong * u + i * r.binAcross * v
    let y = r.y0 + j * r.binAlong * v - i * r.binAcross * u
    doAssert abs(x - loc.x) < 1e-6 * max(1.0, abs(x)) and abs(y - loc.y) < 1e-6 * max(1.0, abs(y)),
      "rotated survey: bin " & $bin & " is not where the library puts it: " & $(x, y) &
      " vs " & $(loc.x, loc.y)
    doAssert r.binAt(loc.x, loc.y) == bin, "binAt does not find bin " & $bin

proc main*() =
  block counts:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    doAssert st.survey.foldReason == ""
    var t: FoldTracker
    doAssert t.finish(st, true) and t.status == fmReady, t.reason
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
    doAssert t.status == fmImpossible and t.reason == NoRelations and t.shown.isNil
    doAssert st.jobs.active.len == 0

  block budget:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true, 0.01, 0.01)
    doAssert t.status == fmFailed and "too many bins" in t.reason, t.reason
    doAssert t.shown.isNil

  block cache:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true)
    let first = t.shown
    doAssert t.finish(st, true, 50.0, 50.0) and t.status == fmReady
    let second = t.shown
    doAssert second != first and second.binAlong != first.binAlong,
      "a bin size chosen again found the first size's map for the second"
    let rev = t.revision
    t.follow(st.jobs, st.survey, true, NaN, NaN) # back to the natural bin: from the cache
    doAssert t.status == fmReady and t.shown == first and st.jobs.active.len == 0,
      "a bin size chosen again starts no job"
    doAssert t.revision > rev
    # off: nothing drawn, the results kept
    t.follow(st.jobs, st.survey, false, NaN, NaN)
    doAssert t.status == fmOff and t.shown.isNil
    t.follow(st.jobs, st.survey, true, NaN, NaN)
    doAssert t.shown == first, "turned on again: the kept map"
    # a new import drops them
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    st.apply Command(kind: ckClearSurvey)
    doAssert st.settle(st.survey.layers.len == 0 and st.jobs.active.len == 0)
    t.follow(st.jobs, st.survey, true, NaN, NaN)
    doAssert t.shown.isNil and t.status == fmImpossible,
      "dropped when the survey is cleared"
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    doAssert t.finish(st, true) and t.shown != first and t.shown != nil,
      "a new import counts again"

  block reread:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true)
    let first = t.shown
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x") # the same files, a new load
    doAssert t.finish(st, true) and t.status == fmReady
    doAssert t.shown != first and t.shown[].counts == first[].counts,
      "a file read again is counted again (the old map was kept)"

  block pruned:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    t.follow(st.jobs, st.survey, true, NaN, NaN)
    doAssert t.status == fmComputing
    doAssert waitUntil(st.jobs.active.len == 0) # nobody follows meanwhile
    for k in 0 ..< 150: # so many jobs after it that its record is forgotten
      discard st.jobs.submit(JobSpec(title: "other", lane: jlBackground, auto: true),
        proc (ctx: JobContext) {.gcsafe.} = discard)
    doAssert waitUntil(st.jobs.active.len == 0)
    doAssert t.finish(st, true) and t.status == fmReady and not t.shown.isNil,
      "pruned job: still " & $t.status

  block typedSizes:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true, 12.3, 12.3) and t.status == fmReady, t.reason
    let r = t.shown
    doAssert r.binAlong == 12.3 and r.binAcross == 12.3,
      "typed sizes are kept as typed: " & $(r.binAlong, r.binAcross)
    doAssert "12.3 x 12.3 m." in r[].totalsText("m"), r[].totalsText("m")
    doAssert sizeText(7.299999999902738) == "7.3" and sizeText(1e7) == "1e+07"

  block oneBin:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true, 1e7, 1e7) and t.status == fmReady, t.reason
    let r = t.shown
    doAssert r.inlines == 1 and r.crosslines == 1 and r.counts.len == 1
    doAssert r.binAlong == 1e7 and r.binAcross == 1e7, "one bin: sizes " & $(r.binAlong, r.binAcross)
    doAssert r[].totalsText("m").startsWith("One bin holds " & $r.binned)
    doAssert r.levels.len == 1 and r.levels[0].cols == 1

  block levels:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    doAssert t.finish(st, true) and t.status == fmReady
    let r = t.shown
    doAssert r.levels.len > 1 and r.levels[0].factor == 1
    doAssert r.levels[^1].cols == 1 and r.levels[^1].rows == 1
    let top = r.levels[^1].colours[0]
    doAssert top == foldColour(lutOf(cmViridis), r.maxFold, r.maxFold),
      "the one block of the last level holds the highest fold"
    for k, l in r.levels:
      doAssert l.factor == 0 or (l.factor == 1 shl k and l.colours.len == l.cols * l.rows)
    doAssert initFoldGrid(r).level(1).colours.len == r.counts.len

  block quickChanges:
    var st = initAppState()
    doAssert st.loaded(Land & ".s", Land & ".r", Land & ".x")
    var t: FoldTracker
    for size in [20.0, 25.0, 30.0, 35.0, 40.0]: # each frame asks for another: none may pile up
      t.follow(st.jobs, st.survey, true, size, size)
    doAssert waitUntil((t.follow(st.jobs, st.survey, true, 40.0, 40.0); t.status != fmComputing))
    doAssert t.status == fmReady and t.shown.binAlong == 40.0, "the last size's map"

  block rotated:
    withFixtures fx:
      let (sFile, rFile) = (fx.dir / "turn.s", fx.dir / "turn.r")
      rotatedCopy(Land & ".s", sFile, 33)
      rotatedCopy(Land & ".r", rFile, 33)
      let xFile = absolutePath(Land & ".x")
      var st = initAppState()
      doAssert st.loaded(sFile, rFile, xFile)
      var t: FoldTracker
      doAssert t.finish(st, true) and t.status == fmReady, t.reason
      let r = t.shown
      var g = initSurveyGeometry()
      for f in [sFile, rFile, xFile]: g.addSps(f)
      let grid = surveyGrid(g)
      var direct = g.preplotFold(grid)
      doAssert r.counts == direct.fold.toFlatSeq
      let n = r.inlines * r.crosslines
      doAssert r.inlines > 3 and r.crosslines > 3
      r[].checkPlaced(grid, [0, r.crosslines - 1, n - r.crosslines, n - 1,
        r.crosslines + 1, n div 2, n div 3 + 1])
      let straight = block:
        var gs = initSurveyGeometry()
        for ext in [".s", ".r", ".x"]: gs.addSps(Land & ext)
        let gr = surveyGrid(gs)
        gr.location(1).y != gr.location(0).y
      doAssert straight or abs(r.azimuthDeg - 90.0 * round(r.azimuthDeg / 90.0)) > 5,
        "the fixture's grid is turned: " & $r.azimuthDeg

  echo "tfoldjobs: ok"

when isMainModule:
  main()
