## The Correlate toggle shows a derived session of the open file.
##
## With no reference chosen the toggle stays on, the raw record stays shown,
## and the none sentence is logged once. A short stored sweep is shown as a
## derived view, and turning the toggle off shows the raw record again. A
## sweep as long as the record fails, turns the toggle off, and logs why.
##
## Seen to fail: with the toggle cleared on that failure, "the toggle stayed
## on after the sweep had no listen time". With the derived view closed on
## the way to the next file, "the raw record was not shown". With the
## correlation's hold not kept at the quit, AddressSanitizer reports a
## heap-use-after-free in the job's write of the result after shutdown.

import std/[os, sequtils, strutils, times]
import viewSEG/core/[jobs, references, state]
import utils/[fixtures, steps, waiting]

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
  false

proc quitWhileCorrelating(raw: string): JobId =
  ## Quits while a correlation is held in its phase; the caller lets it go
  ## on after this state is gone.
  var st = initAppState(watchEvery = initDuration(hours = 1))
  var settings = st.settings
  settings.files.prepareNext = false
  st.apply Command(kind: ckSettings, settings: settings)
  st.rememberFilesIn(raw.parentDir / "quit-config")
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  let trace = st.sessions[0].base
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "held",
    trace: trace, fromMs: 0, toMs: 100))
  doAssert st.settle(st.references.entries.anyIt(it.name == "held")),
    "the sweep was not stored"
  var id = ""
  for e in st.references.entries:
    if e.name == "held": id = e.id
  st.apply Command(kind: ckSelectReference, refId: id)
  holdStep("correlating")
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
  doAssert st.settle(inStep("correlating").len == 1), "the correlation was not held"
  result = inStep("correlating")[0]
  doAssert not st.shutdown(wait = initDuration(milliseconds = 50),
    diskLimit = initDuration(milliseconds = 50)), "the quit waited for the correlation"

proc main*() =
  withFixtures fx:
    let raw = fx.oneTraceSegy()
    var st = initAppState(watchEvery = initDuration(hours = 1))
    var settings = st.settings
    settings.files.prepareNext = false
    st.apply Command(kind: ckSettings, settings: settings)
    st.rememberFilesIn(fx.dir / "config")
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut),
      "the raw file was not shown"

    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
    doAssert st.correlateOn, "no reference turned the toggle off"
    let shown = st.shownFile(st.findPanel(MainPanel))
    doAssert shown >= 0 and not st.sessions[shown].derived, "the raw record was not shown"
    doAssert st.said(NoReferenceChosen), "the none sentence was not logged"
    let saidOnce = st.log.len
    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
    doAssert st.log.len == saidOnce, "the none sentence was logged again"

    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: false)
    doAssert not st.correlateOn, "the toggle did not turn off"
    doAssert st.settle(st.referencesLoaded), "the archive was not read"
    let trace = st.sessions[0].base
    st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "short",
      trace: trace, fromMs: 0, toMs: 100))
    doAssert st.settle(st.references.entries.len > 0), "the short sweep was not stored: " &
      st.log[st.log.len - 1].text
    var shortId = ""
    for e in st.references.entries:
      if e.name == "short": shortId = e.id
    doAssert shortId.len > 0, "the short sweep was not listed"
    st.apply Command(kind: ckSelectReference, refId: shortId)
    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
    doAssert st.settle(st.sessions.anyIt(it.derived) and
      st.shownFile(st.findPanel(MainPanel)) >= 0 and
      st.sessions[st.shownFile(st.findPanel(MainPanel))].derived and
      st.jobs.active.len == 0), "the correlated record was not shown: " &
      (if st.log.len > 0: st.log[st.log.len - 1].text else: "")
    doAssert st.correlateOn, "a successful correlation turned the toggle off"
    doAssert st.sessions.anyIt(not it.derived and it.diskPath == raw),
      "the raw file was closed"
    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: false)
    doAssert st.settle(not st.correlateOn and not st.sessions.anyIt(it.derived) and
      st.shownFile(st.findPanel(MainPanel)) >= 0 and
      not st.sessions[st.shownFile(st.findPanel(MainPanel))].derived),
      "the raw record was not shown"

    st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "full",
      trace: trace, fromMs: 0, toMs: -1))
    doAssert st.settle(st.references.entries.anyIt(it.name == "full")),
      "the full sweep was not stored"
    var fullId = ""
    for e in st.references.entries:
      if e.name == "full": fullId = e.id
    st.apply Command(kind: ckSelectReference, refId: fullId)
    st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
    doAssert st.settle(not st.correlateOn and st.jobs.active.len == 0),
      "the toggle stayed on after the sweep had no listen time"
    doAssert st.said("there is no listen time"), "the failure was not logged"
    let rawShown = st.shownFile(st.findPanel(MainPanel))
    doAssert rawShown >= 0 and not st.sessions[rawShown].derived, "the raw record was not shown"
    discard st.shutdown()

    installSteps()
    let held = quitWhileCorrelating(raw)
    releaseStep("correlating")
    doAssert waitUntil(cameBack(held)), "the correlation did not come back"
    setJobHook(nil)
  echo "tcorrelate: ok"

when isMainModule: main()
