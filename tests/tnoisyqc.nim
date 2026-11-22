## The record QC's noisy-trace test on a synthetic shot (`core/recordqc` with
## processSEG's `noiseQc`), without a window: 64 traces, offsets 100 m to
## 1675 m, a first break on a 2500 m/s half space, the traces near the source
## far louder (as the ground there is), one far trace planted noisy and one
## planted louder than its neighbours only.
##
## - the loud traces near the source are not noisy: they are inside the area,
##   counted as not judged (`mfNotJudged`), and the rule that set the area is
##   the first-break model, in words;
## - the planted noisy trace is found outside the area, the near traces are not;
## - a fixed time, a radius and a count of stations each set the area their way,
##   live: a new key reads the record again; the count never leaves a receiver
##   line (two lines, counted each on its own);
## - one pick serves the record QC and the first-break overlay: whichever asks
##   first, the other takes the result; a record is picked once;
## - a record whose traces carry no offset, coordinate or station number has no
##   area, and says so: every trace judged.
##
## Seen to fail: with the area switched off in the job (every trace judged), "n.rule == arModel:
## none"; with the not-judged filter left empty, the count was 0 against the area's traces; with
## the settings left out of the job's key, "a new choice did not read again"; with the overlay
## asking for its job while the check was picking, "picked twice: 1 + 1"; with the check's own
## first breaks not marked as shared once posted, "the check ran 2 times"; with the nodes' roles
## made one group, "weak components of unrotated nodes: 21". Not mutated: the count of stations
## never leaving a line (the library's guarantee: the test asserts it, nothing here enforces it).

import std/[atomics, os, strutils]
import parseSEG
import processSEG/qc/exclusion
import viewSEG/core/[firstbreaks, noisearea, recordqc]
import viewSEG/core/state
import utils/[fixtures, noisefiles, waiting]

proc setFilters(st: var AppState; filters: set[MapFilter]; noise = NoiseSettings()) =
  var s = st.settings
  s.map.filters = filters
  s.noise = noise
  st.apply Command(kind: ckSettings, settings: s)

func done(st: AppState): bool =
  st.recordQc.job == NoJob and st.recordQc.noise.ready and
    st.recordQc.hits[mfNoisy].state == fsDone

proc open(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)

const Noise = {mfNoisy, mfWeak, mfLouder, mfNotJudged}

var picksByCheck, picksByOverlay, checks: Atomic[int]

proc countHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  ## Counts the jobs that pick a record's first breaks, by who asked.
  discard id
  if back: return
  if phase == "judging the noisy traces": checks.atomicInc
  elif phase == "picking the first breaks": picksByCheck.atomicInc
  elif phase == "picking and fitting the first breaks": picksByOverlay.atomicInc

proc asNow(st: var AppState; noise: NoiseSettings) =
  st.setFilters(Noise, noise)

func sorted(h: FilterHits; base: int): seq[int] =
  for t in h.traces: result.add t - base

proc main*() =

  block theNearTracesAreNotJudgedAndTheRuleIsSaid:
    withFixtures fx:
      var st = initAppState()
      st.open(fx.noisyShot("shot.sgy"))
      doAssert st.recordQc.job == NoJob and not st.recordQc.noise.ready, "read with no filter"
      st.setFilters(Noise)
      doAssert st.settle(st.done)
      let n = st.recordQc.noise
      let h = st.filterHits
      let base = st.sessions[0].base
      doAssert n.rule == arModel, $n.rule & " " & n.areaWords
      doAssert n.areaWords.startsWith("Area set by the first-break model"), n.areaWords
      doAssert n.inArea > 0 and n.inArea < NoisyTraces div 2, "not judged: " & $n.inArea
      doAssert h[mfNotJudged].count == n.notJudged and h[mfNotJudged].traces.len == n.notJudged
      for t in 0 ..< 3:
        doAssert base + t in h[mfNotJudged].traces, "a near trace is judged: " & $t
        doAssert base + t notin h[mfNoisy].traces, "near traces flagged noisy: " & $t
      doAssert base + 63 notin h[mfNotJudged].traces
      doAssert base + PlantedNoisy in h[mfNoisy].traces, $h[mfNoisy].traces
      doAssert base + PlantedLouder in h[mfLouder].traces or
        base + PlantedNoisy in h[mfLouder].traces, "louder: " & $h[mfLouder].traces
      doAssert h[mfNotJudged].note.contains("inside the area"), h[mfNotJudged].note
      doAssert n.notJudgedWords.len > 0
      st.shutdown()

  block theOverridesSetTheAreaLive:
    withFixtures fx:
      var st = initAppState()
      st.open(fx.noisyShot("over.sgy"))
      let base = st.sessions[0].base
      st.setFilters(Noise)
      doAssert st.settle(st.done)
      let auto = st.recordQc.noise.inArea
      # a fixed time: the model's arrival 20 + 0.4 x; 120 ms is x = 250: rows 0 .. 5
      st.asNow(NoiseSettings(choice: ncTime, edgeMs: 120))
      doAssert st.recordQc.hits[mfNoisy].state == fsComputing, "a new choice did not read again"
      doAssert st.settle(st.done and st.recordQc.noise.asked.choice == ncTime)
      var n = st.recordQc.noise
      doAssert n.rule == arFixedTime and "you chose" in n.areaWords, n.areaWords
      doAssert n.inArea in 4 .. 7, "a fixed time left " & $n.inArea & " inside"
      # a radius
      st.asNow(NoiseSettings(choice: ncRadius, radius: 600))
      doAssert st.settle(st.done and st.recordQc.noise.asked.choice == ncRadius)
      n = st.recordQc.noise
      doAssert n.rule == arFixedRadius and n.inArea == 20, "radius: " & $n.rule & " " & $n.inArea
      doAssert "radius you chose" in n.areaWords, n.areaWords
      # the radius changed: read again (a number typed is live)
      st.asNow(NoiseSettings(choice: ncRadius, radius: 300))
      doAssert st.recordQc.hits[mfNoisy].state == fsComputing,
        "a new radius did not read the record again"
      doAssert st.settle(st.done and st.recordQc.noise.asked.radius == 300)
      doAssert st.recordQc.noise.inArea == 8, "radius 300: " & $st.recordQc.noise.inArea
      # a count of stations: 3 either side of the source on the one line: 4 traces
      st.asNow(NoiseSettings(choice: ncSteps, steps: 3, allLines: true))
      doAssert st.settle(st.done and st.recordQc.noise.asked.choice == ncSteps)
      n = st.recordQc.noise
      doAssert n.rule == arSteps and n.steps == 3 and n.inArea == 4,
        $n.rule & " " & $n.steps & " " & $n.inArea
      doAssert "3 stations either side of the source" in n.areaWords, n.areaWords
      doAssert st.filterHits[mfNotJudged].sorted(base) == @[0, 1, 2, 3]
      doAssert auto > 0
      st.shutdown()

  block aCountOfStationsNeverLeavesItsLine:
    withFixtures fx:
      var st = initAppState()
      st.open(fx.noisyShot("lines.sgy", lines = 2))
      let base = st.sessions[0].base
      # two lines of 32: the source is nearest the first station of each line (offsets
      # 100 and 900), counted on each line on its own
      st.setFilters(Noise, NoiseSettings(choice: ncSteps, steps: 3, allLines: true))
      doAssert st.settle(st.done)
      doAssert st.filterHits[mfNotJudged].sorted(base) == @[0, 1, 2, 3, 32, 33, 34, 35],
        $st.filterHits[mfNotJudged].sorted(base)
      doAssert st.recordQc.noise.lines == 2
      # only the lines the shot reaches: the loud one, not the quiet far line
      st.setFilters(Noise, NoiseSettings(choice: ncSteps, steps: 3, allLines: false))
      doAssert st.settle(st.done and not st.recordQc.noise.asked.allLines)
      doAssert st.filterHits[mfNotJudged].sorted(base) == @[0, 1, 2, 3],
        $st.filterHits[mfNotJudged].sorted(base)
      doAssert st.recordQc.noise.linesReached == 1
      st.shutdown()

  block oneResultServesTheCheckAndTheOverlay:
    withFixtures fx:
      let path = fx.noisyShot("share.sgy")
      # the check first: it picks, the overlay takes its result
      var st = initAppState()
      st.open(path)
      picksByCheck.store 0
      picksByOverlay.store 0
      checks.store 0
      setJobHook(countHook)
      st.setFilters(Noise)
      doAssert st.settle(st.done and st.jobs.active.len == 0)
      doAssert checks.load == 1, "the check ran " & $checks.load & " times"
      doAssert picksByCheck.load == 1 and st.firstBreaks.len == 1 and
        st.firstBreaks[0].state == bkDone, "the check did not post its first breaks"
      var d = st.panel(MainPanel).layers[0].display
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.jobs.active.len == 0)
      doAssert picksByOverlay.load == 0 and picksByCheck.load == 1,
        "picked twice: " & $picksByCheck.load & " + " & $picksByOverlay.load
      doAssert st.breaksIndex(0) >= 0 and st.firstBreaks[st.breaksIndex(0)].hasModel
      st.shutdown()
      # the overlay first: the check takes its result
      st = initAppState()
      st.open(path)
      picksByCheck.store 0
      picksByOverlay.store 0
      d = st.panel(MainPanel).layers[0].display
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.firstBreaks.len == 1 and st.firstBreaks[0].state == bkDone and
        st.jobs.active.len == 0)
      st.setFilters(Noise)
      doAssert st.settle(st.done)
      doAssert picksByOverlay.load == 1 and picksByCheck.load == 0,
        "picked twice: " & $picksByCheck.load & " + " & $picksByOverlay.load
      doAssert st.recordQc.noise.rule == arModel
      # both asked in one go: still one pick
      st.shutdown()
      st = initAppState()
      st.open(path)
      picksByCheck.store 0
      picksByOverlay.store 0
      st.setFilters(Noise)
      d = st.panel(MainPanel).layers[0].display
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.done and st.firstBreaks.len == 1 and
        st.firstBreaks[0].state == bkDone and st.jobs.active.len == 0)
      doAssert picksByCheck.load + picksByOverlay.load == 1,
        "picked twice: " & $picksByCheck.load & " + " & $picksByOverlay.load
      setJobHook(nil)
      st.shutdown()

  block noAreaWhenNothingGivesOne:
    withFixtures fx:
      var st = initAppState()
      st.open(fx.noisyShot("bare.sgy", stations = false, offsets = false))
      st.setFilters(Noise)
      doAssert st.settle(st.done)
      let n = st.recordQc.noise
      doAssert n.rule == arNone and n.inArea == 0, $n.rule & " " & $n.inArea
      doAssert n.areaWords == "No area: every trace judged (no offsets, coordinates or " &
        "station numbers)", n.areaWords
      doAssert st.filterHits[mfNotJudged].count == 0
      # a fixed time needs the model: said, every trace judged
      st.setFilters(Noise, NoiseSettings(choice: ncTime, edgeMs: 100))
      doAssert st.settle(st.done and st.recordQc.noise.asked.choice == ncTime)
      doAssert "needs the first-break model" in st.recordQc.noise.areaWords,
        st.recordQc.noise.areaWords
      st.shutdown()

  block unrotatedComponentsAreNotComparedAcrossNodes:
    # the second component of every node is 50 times weaker, whichever way the node lies:
    # compared one by one (or all together) they would be called weak; the library judges
    # a node on all its components, and the viewer does not undo that
    withFixtures fx:
      var st = initAppState()
      st.open(fx.noisyShot("nodes.sgy", comps = 3))
      st.setFilters(Noise)
      doAssert st.settle(st.done)
      doAssert st.filterHits[mfWeak].count == 0,
        "weak components of unrotated nodes: " & $st.filterHits[mfWeak].count
      doAssert st.filterHits[mfNoisy].count == 0, "noisy: " & $st.filterHits[mfNoisy].count
      st.shutdown()

  echo "tnoisyqc: ok"

when isMainModule:
  main()
