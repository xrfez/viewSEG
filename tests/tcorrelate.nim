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
## With an import aimed at the derived key, "the imported kill is not on
## the raw file". With a sweep stored from the correlated view, "the stored
## sweep is not the raw trace". With a file whose header already says
## correlated, "the raw record was not shown". With the derived view left
## up when the held reopen fails, "the correlated view stayed after the
## reopen failed".

import std/[os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[jobs, references]
import viewSEG/core/state {.all.}
import utils/[faultyfs, fixtures, steps, waiting]

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if text in e.text: return true
  false

proc importWhileCorrelated(raw, list: string) =
  ## Imports a kill while the derived view is shown, and turns the toggle
  ## off before the list is read: the kill must be on the raw file.
  var st = initAppState(watchEvery = initDuration(hours = 1))
  var settings = st.settings
  settings.files.prepareNext = false
  st.apply Command(kind: ckSettings, settings: settings)
  st.rememberFilesIn(raw.parentDir / "import-config")
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  let trace = st.sessions[0].base
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "import",
    trace: trace, fromMs: 0, toMs: 100))
  doAssert st.settle(st.references.entries.anyIt(it.name == "import")),
    "the sweep was not stored"
  var id = ""
  for e in st.references.entries:
    if e.name == "import": id = e.id
  st.apply Command(kind: ckSelectReference, refId: id)
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
  doAssert st.settle(st.sessions.anyIt(it.derived) and
    st.shownFile(st.findPanel(MainPanel)) >= 0 and
    st.sessions[st.shownFile(st.findPanel(MainPanel))].derived),
    "the correlated record was not shown"
  holdStep("reading the list")
  st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: list)
  doAssert st.settle(inStep("reading the list").len == 1), "the import was not held"
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: false)
  doAssert st.settle(not st.correlateOn and not st.sessions.anyIt(it.derived)),
    "the raw record was not shown"
  releaseStep("reading the list")
  let k = st.findPanel(MainPanel)
  doAssert st.settle(st.editsOf(k).has(teKilled, 0)),
    "the imported kill is not on the raw file"
  discard st.shutdown()

proc traceSamples(path: string; trace: int): seq[float32] =
  var f = openSeismic(path, keys = true)
  let x = f.readTraces(trace .. trace)
  f.close()
  result.setLen x.shape[1]
  for j in 0 ..< result.len: result[j] = x[0, j]

proc storeWhileCorrelated(raw: string) =
  ## Stores a sweep from the trace the correlated view shows. It must be the
  ## raw recorded samples, not the correlated ones.
  var st = initAppState(watchEvery = initDuration(hours = 1))
  var settings = st.settings
  settings.files.prepareNext = false
  st.apply Command(kind: ckSettings, settings: settings)
  st.rememberFilesIn(raw.parentDir / "store-config")
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  let trace = st.sessions[0].base
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "short",
    trace: trace, fromMs: 0, toMs: 100))
  doAssert st.settle(st.references.entries.anyIt(it.name == "short")),
    "the sweep was not stored"
  var id = ""
  for e in st.references.entries:
    if e.name == "short": id = e.id
  st.apply Command(kind: ckSelectReference, refId: id)
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
  doAssert st.settle(st.sessions.anyIt(it.derived) and
    st.shownFile(st.findPanel(MainPanel)) >= 0 and
    st.sessions[st.shownFile(st.findPanel(MainPanel))].derived and
    st.jobs.active.len == 0), "the correlated record was not shown"
  let shown = st.shownFile(st.findPanel(MainPanel))
  let shownTrace = st.sessions[shown].base
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "fromview",
    trace: shownTrace, fromMs: 0, toMs: -1))
  doAssert st.settle(st.references.entries.anyIt(it.name == "fromview")),
    "the sweep from the correlated view was not stored: " &
    (if st.log.len > 0: st.log[st.log.len - 1].text else: "")
  var file = ""
  for e in st.references.entries:
    if e.name == "fromview": file = e.file
  let got = traceSamples(st.referencesHome / file, 0)
  let rawSamples = traceSamples(raw, 0)
  doAssert got == rawSamples, "the stored sweep is not the raw trace (" & $got.len &
    " samples, the raw trace has " & $rawSamples.len & ")"
  discard st.shutdown()

proc alreadyCorrelatedFile(fx: Fixtures; raw: string): string =
  ## A copy of `raw` whose SEG-Y flags say the data are already correlated.
  result = fx.dir / "already.sgy"
  copyFile(raw, result)
  var ed = openEditor(result)
  doAssert ed.setFileField("binary.correlated", 2), "binary.correlated was refused"
  doAssert ed.setTraceField(0, "trace.correlated", 2), "trace.correlated was refused"
  ed.close()

proc refuseAlreadyCorrelated(path: string) =
  ## A file whose header says correlated is shown raw, and the toggle stays on.
  var st = initAppState(watchEvery = initDuration(hours = 1))
  var settings = st.settings
  settings.files.prepareNext = false
  st.apply Command(kind: ckSettings, settings: settings)
  st.rememberFilesIn(path.parentDir / "already-config")
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  let trace = st.sessions[0].base
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "flagged",
    trace: trace, fromMs: 0, toMs: 100))
  doAssert st.settle(st.references.entries.anyIt(it.name == "flagged")),
    "the sweep was not stored"
  var id = ""
  for e in st.references.entries:
    if e.name == "flagged": id = e.id
  st.apply Command(kind: ckSelectReference, refId: id)
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
  doAssert st.settle(st.jobs.active.len == 0), "the correlation did not finish"
  doAssert st.correlateOn, "the toggle turned off"
  let shown = st.shownFile(st.findPanel(MainPanel))
  doAssert shown >= 0 and not st.sessions[shown].derived, "the raw record was not shown"
  doAssert not st.sessions.anyIt(it.derived), "a correlated view was made"
  doAssert st.said("is already correlated (its header says so)"), "the header was not said"
  discard st.shutdown()

proc heldReopenFailed(raw: string) =
  ## The file changes while the derived view is shown, and the reopen of the
  ## raw file fails: the correlated picture must go, as a failed reopen of a
  ## shown file does, and the log must say why.
  var st = initAppState(watchEvery = initDuration(hours = 1))
  var settings = st.settings
  settings.files.prepareNext = false
  st.apply Command(kind: ckSettings, settings: settings)
  st.rememberFilesIn(raw.parentDir / "held-config")
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: raw)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  let trace = st.sessions[0].base
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "heldopen",
    trace: trace, fromMs: 0, toMs: 100))
  doAssert st.settle(st.references.entries.anyIt(it.name == "heldopen")),
    "the sweep was not stored"
  var id = ""
  for e in st.references.entries:
    if e.name == "heldopen": id = e.id
  st.apply Command(kind: ckSelectReference, refId: id)
  st.apply Command(kind: ckCorrelate, panel: MainPanel, correlate: true)
  doAssert st.settle(st.sessions.anyIt(it.derived) and
    st.shownFile(st.findPanel(MainPanel)) >= 0 and
    st.sessions[st.shownFile(st.findPanel(MainPanel))].derived and
    st.sessions.anyIt(not it.derived)), "the correlated record was not shown"
  var path = ""
  for s in st.sessions:
    if not s.derived: path = s.diskPath
  let whole = readFile(path)
  writeFile(path, whole & "x")
  install()
  fault(path, fkFail, {foMapped})
  st.mailbox.post Msg(kind: mkWatched, watched: @[WatchedFile(path: path, exists: true,
    size: getFileSize(path), modified: getLastModificationTime(path), changing: false)])
  doAssert st.settle(st.jobs.active.len == 0), "the reopen did not end"
  releaseAll()
  setFsHook(nil)
  setIoHook(nil)
  doAssert not st.sessions.anyIt(it.derived) and
    st.shownFile(st.findPanel(MainPanel)) < 0,
    "the correlated view stayed after the reopen failed"
  doAssert path in st.fileList.failed, "the failed reopen was not marked"
  doAssert st.fileList.chosen == "", "a failed reopen leaves the choice on what is shown"
  doAssert st.said("Cannot open"), "the failure was not logged"
  doAssert st.said("correlated view was closed because the file changed"),
    "the close was not said"
  discard st.shutdown()

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

    storeWhileCorrelated(raw)
    refuseAlreadyCorrelated(alreadyCorrelatedFile(fx, raw))
    heldReopenFailed(raw)
    installSteps()
    let list = fx.dir / "kills.csv"
    writeFile(list, CsvHeader & "\n1,,,killed," & raw.extractFilename & "\n")
    importWhileCorrelated(raw, list)
    let held = quitWhileCorrelating(raw)
    releaseStep("correlating")
    doAssert waitUntil(cameBack(held)), "the correlation did not come back"
    setJobHook(nil)
  echo "tcorrelate: ok"

when isMainModule: main()
