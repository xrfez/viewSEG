## The Correlate toggle holds the correlated copy in memory when it fits, and shows a
## correlated view of the raw file when it would be larger than the state's limit.
##
## A refusal adopts nothing under either limit, and a sweep of one sample is refused by the
## view's build in the words the copy's job gives.
##
## Seen to fail: with the limit ignored, "a view was not adopted with a small limit"; with
## a view for every copy, "the copy that fits was adopted as a view"; with the sentence
## not said, "the on-demand sentence was logged 0 times".

import std/[os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[correlatejobs, correlateread, jobs, references, session, threads]
import viewSEG/core/state {.all.}
import utils/[fixtures, waiting]

const OnDemand = "Correlated on demand: the correlated copy would be"

proc said(st: AppState; text: string): int =
  for e in st.log:
    if text in e.text: inc result

proc shownSession(st: AppState): Session =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i] else: nil

proc correlating(st: var AppState; raw: string; toMs: float64; limit: int64) =
  ## Shows `raw`, stores a sweep of `toMs` from its trace, and turns Correlate on.
  let name = "sweep" & $int(toMs)
  var settings = st.settings
  settings.files.prepareNext = false
  st.apply Command(kind: ckSettings, settings: settings)
  st.rememberFilesIn(raw.parentDir / "switch-config")
  st.setCorrelateLimit(limit)
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
    "the raw file was not shown"
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: name,
    trace: st.sessions[0].base, fromMs: 0, toMs: toMs))
  doAssert st.settle(st.references.entries.anyIt(it.name == name)),
    "the sweep was not stored"
  for e in st.references.entries:
    if e.name == name: st.apply Command(kind: ckSelectReference, refId: e.id)
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)

proc listenOf(s: Session): seq[float32] =
  ## Trace 0 of `s` in listen time, whichever way `s` holds it.
  if s.isCorrelatedView:
    var ws = newWorkspace(s.correlatedView[])
    markWorkerThread() # the read is a worker's
    let x = readListenChunk(s.correlatedView[], s.filePtr, 0 .. 0, ws)
    markUiThread()
    for j in 0 ..< x.shape[1]: result.add x[0, j]
  else:
    let x = s.filePtr[].readTraces(0 .. 0)
    for j in 0 ..< x.shape[1]: result.add x[0, j]

proc refusedBy(raw: string; limit: int64): CorrelateResult =
  ## The job on a pilot of one sample, finished: `limit` picks the copy or the view.
  var file = openSeismic(raw, keys = true)
  var jobs = initJobs()
  try:
    let ask = CorrelateAsk(file: addr file, path: raw, marked: @[])
    let load = CorrelateLoad(pilotTrace: 0, record: "the record",
      pilot: PilotRule(name: "one", trace: 1, startMs: 0, spanMs: DtMs))
    let spec = JobSpec(title: "Correlate", lane: jlBackground, reads: @[raw],
      cancellable: true)
    let id = jobs.submit(spec, correlateOrView(ask, load, limit, addr result))
    doAssert waitUntil(jobs.list.anyIt(it.id == id and
      it.state in {jsDone, jsFailed, jsCancelled})),
      "the job did not finish"
  finally:
    jobs.stop()
  file.close()

proc main*() =
  withFixtures fx:
    let raw = fx.oneTraceSegy()
    var inMemory: seq[float32] = @[]

    block fits:
      var st = initAppState(watchEvery = initDuration(hours = 1))
      st.correlating(raw, 100, MaxPrepareBytes)
      doAssert st.settle(st.shownSession != nil and st.shownSession.derived and
        st.jobs.active.len == 0), "the correlated record was not shown"
      doAssert not st.shownSession.isCorrelatedView,
        "the copy that fits was adopted as a view"
      doAssert st.said(OnDemand) == 0, "the on-demand sentence was said for a copy that fits"
      inMemory = listenOf(st.shownSession)
      discard st.shutdown()

    block tooLarge:
      var st = initAppState(watchEvery = initDuration(hours = 1))
      st.correlating(raw, 100, 1)
      doAssert st.settle(st.shownSession != nil and st.shownSession.derived and
        st.jobs.active.len == 0), "the correlated record was not shown"
      block checks:
        # in a block of its own: no reference to the view is left to hold the raw file
        let view = st.shownSession
        doAssert view.isCorrelatedView, "a view was not adopted with a small limit"
        doAssert inMemory.len > 0 and listenOf(view) == inMemory,
          "the view's samples differ from the in-memory copy's"
      doAssert st.said(OnDemand) == 1,
        "the on-demand sentence was logged " & $st.said(OnDemand) & " times"
      doAssert st.said("listen time") >= 1, "the job's report lines were not logged"
      st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
      doAssert st.said(OnDemand) == 1, "the on-demand sentence was logged again"
      let rawSession = st.sessions[st.originIndex(raw)]
      st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: false)
      doAssert st.settle(not st.correlateOn and not st.sessions.anyIt(it.derived) and
        st.shownSession != nil and not st.shownSession.derived), "the raw record was not shown"
      doAssert st.settle(close(rawSession)), "a view still holds the raw file"
      discard st.shutdown()

    for limit in [MaxPrepareBytes, 1'i64]:
      # a sweep as long as the record: refused the same way under either limit
      var st = initAppState(watchEvery = initDuration(hours = 1))
      st.correlating(raw, -1, limit)
      doAssert st.settle(not st.correlateOn and st.jobs.active.len == 0),
        "the toggle stayed on after a refusal: " & st.log.mapIt(it.text).join(" / ")
      doAssert not st.sessions.anyIt(it.derived), "a refused correlation adopted a session"
      doAssert st.said("there is no listen time") == 1, "the refusal was not logged once"
      discard st.shutdown()
    # a sweep of one sample fits the estimate and is refused by the view's own build
    let copy = refusedBy(raw, MaxPrepareBytes)
    let view = refusedBy(raw, 1)
    doAssert not copy.ok and copy.opened.isNil and "at least two samples" in copy.failure,
      "the copy's refusal was " & copy.failure
    doAssert not view.ok and view.opened.isNil and not view.onDemand and
      view.failure == copy.failure, "the view's refusal was " & view.failure
  echo "tcorrswitch: ok"

when isMainModule: main()
