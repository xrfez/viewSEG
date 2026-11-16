## A reference used by a plot, and a trace stored raw.
##
## The sample pilot (`samples/vib/vib_uncorrelated.sgd`) stored with the
## plot's filters and a trace filter on equals the file's own samples, cut
## to the window asked for. A cross-correlation of that pilot with the
## stored copy equals the one with the file's pilot. A reference at another
## sample interval is refused, and nothing is drawn.
##
## Seen to fail: with the store reading the plot's filtered samples, "stored
## samples are not the file's"; with the archive reference not passed to the
## correlation, "archive correlation is not the file's pilot"; with a
## different interval still drawn, "a different interval was drawn"; with a
## frozen window following the choice, "a frozen correlation asked again"; with
## the follow key holding the pilot's own filter under an archive reference,
## "the pilot's own filter asked again for an archive reference".

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[processing, references, state]
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState; w: int): bool =
  st.plots.len > w and st.plots[w].result.gen > 0 and not st.plots[w].waiting

proc pilotOf(path: string): int =
  result = -1
  var f = openSeismic(path, keys = true)
  for i in 0 ..< f.len:
    if not f.traceKeys(i).isSeismic and f.traceEntry(i).channelSetIndex == 1:
      result = i
      break
  f.close()

proc samplesOf(path: string): seq[float32] =
  ## The first trace, read here: the archive reader refuses the UI thread.
  var f = openSeismic(path, keys = true)
  let rows = f.readTraces(0 .. 0)
  result = newSeq[float32](rows.shape[1])
  for i in 0 ..< result.len: result[i] = rows[0, i]
  f.close()

proc rawOf(path: string; trace: int): seq[float32] =
  var f = openSeismic(path, keys = true)
  let rows = f.readTraces(trace .. trace)
  result = newSeq[float32](rows.shape[1])
  for i in 0 ..< result.len: result[i] = rows[0, i]
  f.close()

withFixtures fx:
  let dir = fx.dir / "config"
  createDir(dir)
  let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"
  let pilot = pilotOf(vib)
  doAssert pilot >= 0, "no pilot trace"
  let raw = rawOf(vib, pilot)

  var st = initAppState()
  st.keepSettingsIn(dir, loadSettings(dir / "settings.nif"))
  st.rememberFilesIn(dir)
  doAssert st.settle(st.referencesLoaded), "the archive was not read"
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  let s = st.sessions[0]
  let id = s.base + pilot
  # filters on: a store that used the plot's samples would not match the file
  st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing(aux: true,
    dc: dcTrend, band: pbBandPass, f1: 8, f2: 12, f3: 40, f4: 60))
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[id], on: true,
    processing: Processing(band: pbBandPass, f1: 10, f2: 14, f3: 50, f4: 70),
    filterPlace: fpInstead)
  let dt = st.sessions[0].filePtr.indexedSpan(pilot).intervalUs
  doAssert dt > 0, "the pilot has no sample interval"
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "the pilot",
    trace: id, fromMs: 0, toMs: -1))
  doAssert st.settle(st.references.entries.len == 1), st.log[st.log.len - 1].text
  let e = st.references.entries[0]
  doAssert e.name == "the pilot" and not e.missing
  let stored = samplesOf(st.referencesHome / e.file)
  doAssert stored == raw, "stored samples are not the file's (" & $stored.len &
    " vs " & $raw.len & ")"
  st.apply Command(kind: ckStoreReference, refStore: StoredReference(name: "a window",
    trace: id, fromMs: 0, toMs: 200))
  doAssert st.settle(st.references.entries.len == 2), st.log[st.log.len - 1].text
  let windowed = samplesOf(st.referencesHome / st.references.entries[1].file)
  doAssert windowed == cutSamples(raw, dt, 0, 200), "the window is not the file's samples"

  block correlation_matches_the_file:
    # filters off: the file's pilot is then the raw trace, as the stored copy is
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: Processing())
    st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[id], on: false)
    var seismic = -1
    var f = openSeismic(vib, keys = true)
    for i in 0 ..< f.len:
      if f.traceKeys(i).isSeismic:
        seismic = i
        break
    f.close()
    doAssert seismic >= 0
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + seismic])
    doAssert st.plots.len >= 1, st.log[st.log.len - 1].text
    let filePlot = st.plots.high
    doAssert st.settle(st.answered(filePlot)), "no correlation of the file's pilot"
    doAssert st.plots[filePlot].result.problem == "", st.plots[filePlot].result.problem
    let fileCurve = st.plots[filePlot].result.plots[0].curves[0].ys
    st.apply Command(kind: ckSelectReference, refId: e.id)
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + seismic])
    let archPlot = st.plots.high
    doAssert st.settle(st.answered(archPlot) and
      "still being read" notin st.plots[archPlot].result.problem),
      st.plots[archPlot].result.problem
    doAssert st.plots[archPlot].result.problem == "", st.plots[archPlot].result.problem
    doAssert "Reference: the pilot (archive)" in st.plots[archPlot].result.note,
      st.plots[archPlot].result.note
    doAssert "(archive)" in st.plots[archPlot].reference, st.plots[archPlot].reference
    doAssert st.plots[archPlot].result.plots[0].curves[0].ys == fileCurve,
      "archive correlation is not the file's pilot"

  block the_choice_is_followed_unless_frozen:
    # another choice asks an unfrozen window again, not a frozen one; the
    # pilot's own filter does not move a window using an archive reference
    st.apply Command(kind: ckSelectReference, refId: "")
    var seismic = -1
    var f = openSeismic(vib, keys = true)
    for i in 0 ..< f.len:
      if f.traceKeys(i).isSeismic:
        seismic = i
        break
    f.close()
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + seismic])
    let free = st.plots.high
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + seismic])
    let held = st.plots.high
    doAssert st.settle(st.answered(free) and st.answered(held)), "no correlations"
    st.apply Command(kind: ckPlotDisplay, plot: st.plots[held].id,
      plotParams: st.plots[held].params, plotFrozen: true)
    doAssert st.settle(not st.plots[held].waiting)
    let (freeAsks, heldAsks) = (st.plots[free].asks, st.plots[held].asks)
    st.apply Command(kind: ckSelectReference, refId: e.id)
    doAssert st.settle(st.plots[free].asks > freeAsks and st.answered(free)),
      "an unfrozen correlation did not ask again for the archive reference"
    doAssert "(archive)" in st.plots[free].reference, st.plots[free].reference
    doAssert st.plots[held].asks == heldAsks, "a frozen correlation asked again"
    doAssert "(archive)" notin st.plots[held].reference, st.plots[held].reference
    let archiveAsks = st.plots[free].asks
    st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[id], on: true,
      processing: Processing(band: pbBandPass, f1: 10, f2: 14, f3: 50, f4: 70),
      filterPlace: fpAfter)
    doAssert st.settle(not st.plots[free].waiting)
    doAssert st.plots[free].asks == archiveAsks,
      "the pilot's own filter asked again for an archive reference"
    doAssert "own filter" notin st.plots[free].result.note, st.plots[free].result.note
    st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[id], on: false)

  block another_interval_is_refused:
    var g = GeneratedReference(name: "other interval", law: rlLinear, f1Hz: 8, f2Hz: 40,
      durationMs: 1000, dtMs: dt / 1000 * 2, taperStartMs: 0, taperEndMs: 0, amplitude: 1)
    if g.dtMs == dt / 1000: g.dtMs = 4
    st.apply Command(kind: ckGenerateReference, refGenerate: g)
    doAssert st.settle(st.references.entries.len == 3), st.log[st.log.len - 1].text
    var other = ""
    for e in st.references.entries:
      if e.name == "other interval": other = e.id
    doAssert other.len > 0, "the generated reference is not in the archive"
    st.apply Command(kind: ckSelectReference, refId: other)
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation, plotTraces: @[s.base + pilot])
    let w = st.plots.high
    doAssert st.settle(st.answered(w)), "no refusal"
    doAssert "the reference is " in st.plots[w].result.problem and
      "this file is " in st.plots[w].result.problem, st.plots[w].result.problem
    doAssert st.plots[w].result.plots.len == 0, "a different interval was drawn"

  block a_deleted_choice_says_the_name:
    # Seen to fail: with the choice left set and the note naming the id,
    # the next plot failed the same way and the note was "r...".
    var windowId = ""
    for entry in st.references.entries:
      if entry.name == "a window": windowId = entry.id
    doAssert windowId.len > 0
    st.apply Command(kind: ckSelectReference, refId: windowId)
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + pilot])
    let usingIt = st.plots.high
    doAssert st.settle(st.answered(usingIt))
    st.apply Command(kind: ckDeleteReference, refId: windowId)
    doAssert st.settle(st.chosenReference.len == 0), "the choice stayed set: " &
      st.chosenReference
    var said = false
    for entry in st.log:
      if "\"a window\"" in entry.text and "no longer in the archive" in entry.text and
          "file's own pilot" in entry.text:
        said = true
    doAssert said, "the name was not said once"
    doAssert "a window" in st.plots[usingIt].goneNote, st.plots[usingIt].goneNote
    st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
      plotTraces: @[s.base + pilot])
    let next = st.plots.high
    doAssert st.settle(st.answered(next) and st.plots[next].result.problem.len == 0),
      "the next plot did not work: " & st.plots[next].result.problem

  block project_switches_the_archive:
    st.apply Command(kind: ckSelectReference, refId: "")
    let proj = fx.dir / "job"
    st.apply Command(kind: ckNewProject, projectPath: proj, projectName: "Job")
    doAssert st.settle(st.inProject and st.referencesLoaded), "the project archive was not read"
    doAssert st.references.entries.len == 0, "a new project started with the main archive"
    doAssert st.mainReferences.entries.len >= 1, "the main archive was dropped"
    doAssert st.chosenReference == "", "the project's choice is not the file's pilot"
    let mainId = st.mainReferences.entries[0].id
    st.apply Command(kind: ckCopyReference, refId: mainId)
    doAssert st.settle(st.references.entries.len == 1), st.log[st.log.len - 1].text
    doAssert st.references.entries[0].name == "the pilot"
    st.apply Command(kind: ckSelectReference, refId: st.references.entries[0].id)
    doAssert st.chosenReference == st.references.entries[0].id
    st.flushFiles()
    st.apply Command(kind: ckCloseProject)
    doAssert not st.inProject
    doAssert st.referencesHome == st.referencesHome # the main folder is back
    doAssert st.references.entries.len >= 1
    doAssert st.chosenReference == "", "closing the project did not restore the file's pilot"
    # the choice kept in the project comes back with it
    st.apply Command(kind: ckOpenProject, projectPath: proj)
    doAssert st.settle(st.inProject and st.referencesLoaded)
    doAssert st.chosenReference.len > 0, "the project's choice was not kept"
    doAssert st.references.entries.len == 1
    # A close queues the document and does not wait. A reopen at once must
    # still see the choice (and every other field of that write).
    # Seen to fail: with the open job reading before that write, the choice
    # was empty.
    st.apply Command(kind: ckSelectReference, refId: "")
    st.apply Command(kind: ckSelectReference, refId: st.references.entries[0].id)
    st.apply Command(kind: ckCloseProject)
    st.apply Command(kind: ckOpenProject, projectPath: proj)
    doAssert st.settle(st.inProject and st.referencesLoaded and st.chosenReference.len > 0),
      "a fast reopen lost the choice"
    st.apply Command(kind: ckCloseProject)

  st.shutdown()

echo "trefplots: ok"
