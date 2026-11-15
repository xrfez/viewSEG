## The map's filters in `core`, without a window (`core/recordqc`,
## `filterHits`), on `mapSps`'s spread with its X file and the SEG-D shot of
## source 1003 of line 1 with every `MapDefect` planted:
##
## - nothing is read while no filter that needs the record is on;
## - each filter marks what was planted, and only that: the trace marked
##   dead, the clipped and the noisy ones (processSEG's amplitude flags with
##   their default thresholds), the time break as auxiliary, the receiver
##   not recorded and the one renamed as missing from the template (with
##   processSEG's `recordCompleteness`'s count), the stations past the ten a
##   line the X record plans as not in it, the station recorded twice, the
##   trace no survey file places as without a position; traces killed and
##   reversed by the user; the shots whose X record agrees with their
##   template far less than the survey's typically do (processSEG's
##   `compareRelations`, as the test makes it too);
## - another record shown: read again (computing meanwhile); no filter on:
##   what was found goes;
## - a receiver gather whose headers name no receiver station: the
##   template's filters say they are not checked, and why;
## - the record read is as it was (bytes and time).
##
## Seen to fail: with the record's statistics left out (`recordAmplitude`),
## "noisy" found none; with the duplicate's first trace left out, "recorded
## twice" found 1 trace, not 2.

import std/[algorithm, os, sets, strutils]
import parseSEG
import processSEG/survey/patch
import viewSEG/core/state
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc receiverOf(st: AppState; trace: int): (int, int) =
  ## The receiver line (0-based) and receiver (0-based along it) of
  ## survey-wide trace `trace`, from its file's own headers.
  let i = st.findTrace(trace)
  let own = st.survey.findTraces(st.sessions[i].id)
  let s = st.survey.layers[own].stationOf(prReceiver, trace - st.sessions[i].base)
  (MapRcvLines.find(s.line), int(s.point) - 101)

proc receivers(st: AppState; h: FilterHits): seq[(int, int)] =
  for t in h.traces: result.add st.receiverOf(t)
  result.sort()

proc on(st: var AppState; filters: set[MapFilter]) =
  var s = st.settings
  s.map.filters = filters
  st.apply Command(kind: ckSettings, settings: s)

func done(st: AppState): bool =
  st.recordQc.job == NoJob and st.recordQc.hits[mfDead].state == fsDone

withFixtures fx:
  let sps = fx.mapSps()
  let shot = fx.mapShotSegd(0, 2, {MapDefect.low .. MapDefect.high})
  let bytes = readFile(shot)
  let time = getLastModificationTime(shot)
  var st = initAppState()
  st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r, fx.mapXps])
  doAssert st.settle(st.survey.layers.len == 3 and st.jobs.active.len == 0)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: shot)
  doAssert st.settle(st.sessions.len == 1 and st.survey.findTraces(st.sessions[0].id) >= 0 and
    st.jobs.active.len == 0)
  doAssert st.recordQc.job == NoJob and st.recordQc.key.file == NoSession, "read with no filter"
  let base = st.sessions[0].base

  block everyFilter:
    st.on({MapFilter.low .. MapFilter.high})
    doAssert st.recordQc.job != NoJob and st.recordQc.hits[mfNoisy].state == fsComputing
    doAssert st.settle(st.done and st.spreads.job == NoJob)
    let h = st.filterHits
    let at = MapDefectAt
    doAssert st.receivers(h[mfDead]) == @[at[mdDead]], $st.receivers(h[mfDead])
    doAssert at[mdClipped] in st.receivers(h[mfClipped]), $st.receivers(h[mfClipped])
    doAssert st.receivers(h[mfNoisy]) == @[at[mdNoisy]], "noisy: " & $st.receivers(h[mfNoisy])
    doAssert h[mfUndecodable].traces.len == 0 and h[mfNotANumber].traces.len == 0
    doAssert h[mfAuxiliary].traces == @[base], $h[mfAuxiliary].traces
    for f in [mfNoisy, mfClipped, mfSpiky, mfConstant, mfWeak, mfDcOffset, mfAllZero,
        mfNotANumber]:
      doAssert base notin h[f].traces, "the time break flagged " & $f
    # missing: the receiver not recorded, and the one whose trace names another station
    var missing: seq[(int, int)]
    for s in h[mfMissing].stations: missing.add (MapRcvLines.find(s.line), int(s.point) - 101)
    missing.sort()
    doAssert missing == @[at[mdUnplaced], at[mdMissing]].sorted, $missing
    doAssert h[mfMissing].count == 2 and "30" in h[mfMissing].note, h[mfMissing].note
    # not in the template: the 11 receivers past the ten planned on each line, and 199
    doAssert h[mfUnlisted].count == 34, $h[mfUnlisted].count
    doAssert h[mfUnlisted].traces.len == 34
    for t in h[mfUnlisted].traces:
      let (_, k) = st.receiverOf(t)
      doAssert k >= MapPlanned or k == MapUnplacedPoint - 101, $k
    doAssert st.receivers(h[mfDuplicate]) == @[at[mdDuplicate], at[mdDuplicate]],
      "recorded twice: " & $st.receivers(h[mfDuplicate]).len & " traces"
    doAssert h[mfDuplicate].count == 1
    doAssert h[mfNoPosition].traces.len == 1 and st.receiverOf(h[mfNoPosition].traces[0]) ==
      (at[mdUnplaced].line, MapUnplacedPoint - 101), $h[mfNoPosition].traces
    doAssert h[mfKilled].count == 0 and h[mfReversed].count == 0
    # the shots whose X record is not their template's, as processSEG says
    var g = initSurveyGeometry()
    for p in [sps.s, sps.r, fx.mapXps]: g.addSps(p)
    let d = g.describePatches()
    var shots: seq[PatchShot]
    for r in g.records:
      for run in g.relationRuns(r):
        if shots.len == 0 or shots[^1].record != r: shots.add PatchShot(record: r,
          source: run.fixed)
    var gen = initSurveyGeometry()
    gen.addSps(SpsFile(relations: g.generateRelations(d.layout, shots,
      initPatchTemplate(d.templateLines, d.templateChannels))))
    # far less in agreement than the survey's records typically are: under the
    # median Jaccard index less 3 robust deviations (the median when they agree)
    var agreements: seq[RecordAgreement]
    var j: seq[float]
    for a in compareRelations(g, gen):
      if a.listed > 0:
        agreements.add a
        j.add a.jaccard
    var v = j
    v.sort()
    let median = v[v.high div 2]
    var dev: seq[float]
    for x in v: dev.add abs(x - median)
    dev.sort()
    let mad = dev[dev.high div 2]
    let below = if mad > 0: median - 3 * 1.4826 * mad else: median
    var differ: HashSet[StationKey]
    for a in agreements:
      if a.jaccard < below and a.jaccard < 1:
        for s in shots:
          if s.record == a.record: differ.incl s.source
    doAssert h[mfSpreadDiffers].state == fsDone and h[mfSpreadDiffers].count == differ.len and
      differ.len > 0, $h[mfSpreadDiffers].count & " of " & $differ.len
    for s in h[mfSpreadDiffers].sources: doAssert s in differ
    doAssert stationKey(MapSrcLines[MapOddSpread.line], float64(1001 + MapOddSpread.k), 1) in
      differ, "the odd spread"
    # killed and reversed by the user
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 3,
      base + 5], on: true)
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[base + 7],
      on: true)
    let e = st.filterHits
    doAssert e[mfKilled].traces == @[base + 3, base + 5] and e[mfKilled].count == 2
    doAssert e[mfReversed].traces == @[base + 7]

  block anotherRecord:
    let other = fx.mapShotSegd(1, 4)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
    doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path.endsWith(
      other.extractFilename) and st.selection.activeGather.file == st.sessions[^1].id)
    doAssert st.settle(st.done and st.recordQc.key.file == st.sessions[^1].id)
    let h = st.filterHits
    # (its amplitudes are the data's: a synthetic record's few traces where two
    # arrivals meet stand out from a median nothing else departs from)
    doAssert h[mfDead].count == 0 and h[mfClipped].count == 0 and h[mfMissing].count == 0 and
      h[mfDuplicate].count == 0, "a clean record"
    doAssert h[mfUnlisted].count == 33
    st.on({})
    doAssert st.recordQc.key.file == NoSession and st.filterHits[mfDead].state == fsOff

  block receiverGather:
    st.on({mfMissing, mfDead})
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.mapReceiverSegy(1, 4))
    doAssert st.settle(st.shownDomain == rdReceiver and st.done)
    let h = st.filterHits
    doAssert h[mfMissing].state == fsNotChecked and "receiver station" in h[mfMissing].note,
      h[mfMissing].note
    st.shutdown()
  doAssert readFile(shot) == bytes and getLastModificationTime(shot) == time, "the record changed"

echo "tfilters: ok"
