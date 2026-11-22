## The record QC job never restarts for a key it has answered (it did, without end, on a record whose
## first breaks could not be picked: the key said "shared" only for a finished pick, a failed one
## left it at 0 and the next frame started the job again). Counted in frames, not waited for:
## the starts must stop growing.
##
## - a signature `.dat` and `.vib` (no receivers) with the noise and template filters on: no job
##   starts at all, and each of those filters says "does not apply to a signature file", done, 0;
## - a seismic record with no offsets and no survey: one check, never a second;
## - a check or an overlay job cancelled stays cancelled while its key holds.
##
## Seen to fail: with the signature test out of `followRecordQc`, the `.dat` started a
## job; with the notes out of `filterHits`, "no note"; with the key test out of `followRecordQc`
## (a job for every frame), the seismic record never settled. Not tested: the failed pick of the first breaks
## (`bkFailed`, counted as an answer in `followRecordQc`'s key): no fixture makes the picker fail
## (a SEG-Y without a sample interval cannot be written, and one patched by hand still read one);
## the `.dat` of the report hit it, and the signature exemption now keeps it out of reach.

import std/[atomics, os]
import parseSEG
import viewSEG/core/[firstbreaks, mapkinds, state]
import utils/[fixtures, noisefiles, sigfiles, waiting]

var starts: Atomic[int]

proc countHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  discard id
  if not back and phase in ["judging the noisy traces", "picking the first breaks",
      "picking and fitting the first breaks", "reading the record"]: starts.atomicInc

const Filters = {mfNoisy, mfWeak, mfLouder, mfNotJudged, mfMissing}

proc setFilters(st: var AppState; filters: set[MapFilter]) =
  var s = st.settings
  s.map.filters = filters
  st.apply Command(kind: ckSettings, settings: s)

proc open(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
    st.jobs.active.len == 0)

proc frames(st: var AppState; n: int) =
  for i in 0 ..< n:
    discard st.drainInbox()
    sleep 2

proc queued(st: AppState): int =
  for j in st.jobs.list:
    if j.spec.title == "Check the record shown for the map's filters": inc result

proc main*() =
  for kind in ["dat", "vib"]:
    withFixtures fx:
      let path = if kind == "dat": datFile(fx.dir, "0042_x.dat") else: vibFile(fx.dir, "0042_x.vib")
      var st = initAppState()
      st.open(path)
      starts.store 0
      setJobHook(countHook)
      st.setFilters(Filters)
      st.frames 200
      doAssert st.recordQc.job == NoJob and starts.load == 0 and st.queued == 0,
        kind & ": a job ran for a signature file: " & $starts.load & " " & $st.queued
      let h = st.filterHits
      for f in Filters:
        doAssert h[f].state == fsDone and h[f].count == 0 and
          h[f].note == "does not apply to a signature file",
          kind & ": no note for " & $f & ": " & $h[f].state & " '" & h[f].note & "'"
      setJobHook(nil)
      st.shutdown()

  block seismicWithoutOffsets:
    withFixtures fx:
      var st = initAppState(indexCache = fx.dir / "cache")
      st.open(fx.noisyShot("bare.sgy", stations = false, offsets = false))
      starts.store 0
      setJobHook(countHook)
      st.setFilters(Filters - {mfMissing})
      doAssert st.settle(st.recordQc.job == NoJob and st.recordQc.hits[mfNoisy].state == fsDone)
      let first = st.queued
      st.frames 50
      doAssert st.queued == first and st.recordQc.job == NoJob, "restarted: " & $first
      st.frames 200
      doAssert st.queued == first and st.recordQc.job == NoJob,
        "restarted: " & $first & " -> " & $st.queued
      setJobHook(nil)
      st.shutdown()

  block cancelledStaysCancelled:
    withFixtures fx:
      var st = initAppState()
      st.open(fx.noisyShot("cancel.sgy", stations = false, offsets = false))
      st.setFilters(Filters - {mfMissing})
      let q = st.recordQc.job
      doAssert q != NoJob
      discard st.jobs.cancel(q)
      st.frames 50
      let n = st.queued
      st.frames 200
      doAssert st.queued == n and st.recordQc.job == NoJob, "restarted after the cancel"
      st.shutdown()

  echo "tqcloop: ok"

when isMainModule:
  main()
