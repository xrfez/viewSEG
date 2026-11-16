## A trace's own frequency filter, kept with the file's edits (`core/edits`,
## `core/filememory`) and run where the plot's filters run (`core/reader`,
## `core/spectrumreader`):
##
## - set, remove, undo and redo on one trace and on a selection, as one step;
## - a document without the field loads as no filters; a field this version
##   does not know is kept and does not refuse the file; a round trip through
##   the file memory and through CSV keeps the filter;
## - the reader's row for a filtered trace equals the same filter run by hand,
##   after the plot's filters and instead of them, and the neighbouring rows
##   are the plot's, bit for bit;
## - a spectrum of the filtered trace shows the filter in the raw curve (the
##   trace with its own filter). Processed and Response are the plot's
##   filters only: an own filter that runs instead leaves them equal, and
##   the window says so.
##
## Seen to fail: with `prepare` not running a trace's own filter (the plot's
## filters only), "trace 2 after the plot's filters is not the filter run by
## hand"; with `fpInstead` still going through the plot's filter, "trace 4
## instead of the plot's filters still has the plot's filter"; with a
## neighbour's row taken from the filtered trace, "trace 3 changed"; with
## `readEditsIn` dropping `(filtered ...)`, "an old document gained a filter"
## and "the filter did not come back"; with `setOwnFilters` making no step,
## "undo did not put the filter back".
##
## Seen to fail: with the live panel's key omitting a trace's own filter,
## "the live panel did not re-ask"; with a filter step not releveled, "a
## trace filter did not relevel". With the pending-edits warning listing
## kills only, "1 filtered" was not in the warning.
##
## Runs on samples/land/shots.sgy.

import std/[os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import viewSEG/core/[edits, filememory, nif, processing, state]
import utils/waiting

const root = currentSourcePath().parentDir.parentDir
let land = root / "samples" / "land" / "shots.sgy"

proc band(lo, hi: float64; place = fpAfter): OwnFilter =
  bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: lo - 2, f2: lo, f3: hi, f4: hi + 4),
    place: place))

block lists:
  var e: FileEdits
  let f = band(10, 60)
  doAssert e.setOwnFilters([4], f) == 1
  doAssert e.hasFilter(4) and e.ownOf(4).filter == f
  doAssert describe(e.nextUndo) == "trace 5 filtered"
  doAssert e.setOwnFilters([4, 6, 4], f) == 1 # 4 already
  doAssert describe(e.nextUndo) == "trace 7 filtered"
  doAssert e.setOwnFilters([1, 2], band(20, 40)) == 2
  doAssert describe(e.nextUndo) == "2 traces filtered"
  doAssert e.undo().kind == skFilter and not e.hasFilter(1) and not e.hasFilter(2)
  doAssert e.hasFilter(4) and e.hasFilter(6)
  doAssert e.redo().kind == skFilter and e.hasFilter(1)
  doAssert e.clearOwnFilters([4, 6, 1, 2]) == 4
  doAssert e.isEmpty and describe(e.nextUndo) == "filters of 4 traces removed"
  doAssert e.undo().kind == skFilter and e.hasFilter(4) and e.hasFilter(2)
  doAssert e.setOwnFilters([4], band(10, 60, fpInstead)) == 1
  doAssert e.ownOf(4).filter.place == fpInstead
  # one step for a selection, and a new change drops what was undone
  discard e.undo()
  doAssert e.canRedo
  doAssert e.setOwnFilters([8], f) == 1 and not e.canRedo
  doAssert e.change(teKilled, [4], true) == 1
  doAssert e.has(teKilled, 4) and e.hasFilter(4) # a kill keeps the filter
  doAssert e.clearAll() and e.isEmpty
  doAssert e.undo().kind == skClear and e.hasFilter(4) and e.has(teKilled, 4)

block memory:
  var rec = FileRecord(name: "shots.sgy", path: land)
  rec.edits.lists[teKilled] = @[2]
  rec.edits.filters = @[FilterEntry(trace: 4, filter: band(10, 60))]
  let doc = memoryDocument(rec)
  var problems: seq[string]
  let back = readMemory(parseNif(doc, "t.nif"), "t.nif", problems)
  doAssert problems.len == 0, $problems
  doAssert back.edits.filters == rec.edits.filters, "the filter did not come back"
  doAssert back.edits.lists[teKilled] == @[2]
  # an older document, no filtered field
  let old = doc.replace("(filtered", "(filteredLater")
  problems.setLen 0
  let aged = readMemory(parseNif(old, "old.nif"), "old.nif", problems)
  doAssert aged.edits.filters.len == 0, "an old document gained a filter"
  doAssert aged.later.len > 0 # the unknown node is kept, not a refusal
  # a newer sibling does not refuse the file, and is written back
  let newer = doc.replace("(fileMemory", "(fileMemory (futureNote \"x\")")
  problems.setLen 0
  let ahead = readMemory(parseNif(newer, "new.nif"), "new.nif", problems)
  doAssert ahead.edits.filters.len == 1 and ahead.later.len >= 1, $ahead.later.len
  doAssert "futureNote" in memoryDocument(ahead)
  # CSV round trip
  let csv = editsCsv(rec.edits, [1.0, 1.0], [3.0, 5.0], "shots.sgy")
  problems.setLen 0
  let fromCsv = readEditsCsv(csv, "a.csv", problems)
  doAssert problems.len == 0, $problems
  doAssert fromCsv.filters.len == 1 and fromCsv.filters[0].filter.place == fpAfter
  doAssert fromCsv.filters[0].filter.spec.band == pbBandPass
  doAssert fromCsv.lists[teKilled] == @[2]
  doAssert "1 filtered" in keptWords(rec.edits)

proc byHand(samples: seq[float32]; dtMs: float64; steps: openArray[Processing]): seq[float32] =
  ## `samples` through `steps`, each as the plot's filter pipeline runs it.
  result = samples
  if result.len == 0: return
  var keys = @[initTraceKeys()]
  keys[0].status = tsLive
  var lengths = @[result.len]
  let rows = rowsOf(keys, lengths)
  var ws = initWorkspace()
  for p in steps:
    var q = p
    q.raw = false
    let pipe = q.filterPipeline(dtMs)
    if pipe.len > 0:
      let plan = pipe.compile(float32, dtMs, result.len, recordSamples = result.len)
      ws.reserve(plan)
      plan.apply(rowBlock(result, 1, result.len), initChunkMeta(rows, dtMs), ws)

proc rowOf(t: Tile; trace: int): seq[float32] =
  let r = t.traces.find(trace)
  doAssert r >= 0, "trace " & $(trace + 1) & " is not in the tile"
  t.data[r * t.columns ..< (r + 1) * t.columns]

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and p.pending.gen == p.requestGen and st.tiles(0).len > 0 and
    st.tiles(0)[^1].request == p.pending

doAssert fileExists(land), "samples/land/shots.sgy is not here"
block reader:
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  var d = st.panel(MainPanel).layers[0].display
  d.gain = dgNone
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  let lay = st.panel(MainPanel).layout
  var view = fitAll(lay, 800, 2 * lay.samples)
  view.traces = Span(lo: -0.5, hi: 7.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: view)
  doAssert st.settle(st.answered)
  let raw = st.tiles(0)[^1]
  doAssert raw.request.stride == 1 and raw.request.decimation == 1, $raw.request
  let plot = Processing(band: pbHighCut, f3: 40, f4: 50)
  st.apply Command(kind: ckProcessing, panel: MainPanel, processing: plot)
  doAssert st.settle(st.answered)
  let plotted = st.tiles(0)[^1]
  let base = st.sessions[0].base
  let after = band(12, 40)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 1], on: true,
    processing: after.spec, filterPlace: fpAfter)
  doAssert st.settle(st.answered)
  let t = st.tiles(0)[^1]
  let dt = lay.dtMs
  let handAfter = byHand(raw.rowOf(1), dt, [plot, after.spec])
  doAssert t.rowOf(1) == handAfter, "trace 2 after the plot's filters is not the filter run by hand"
  for k in [0, 2, 3]:
    doAssert t.rowOf(k) == plotted.rowOf(k), "trace " & $(k + 1) & " changed"
  let instead = band(15, 35, fpInstead)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 3], on: true,
    processing: instead.spec, filterPlace: fpInstead)
  doAssert st.settle(st.answered)
  let u = st.tiles(0)[^1]
  let handInstead = byHand(raw.rowOf(3), dt, [instead.spec])
  doAssert u.rowOf(3) == handInstead,
    "trace 4 instead of the plot's filters still has the plot's filter"
  doAssert u.rowOf(1) == handAfter, "trace 2 lost its filter"
  doAssert u.rowOf(2) == plotted.rowOf(2), "trace 3 changed"
  # one trace, instead: the plot's filters do not apply, so processed equals
  # the raw curve (the trace with its own filter), and the window says so
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[base + 3])
  doAssert st.settle(st.spectra[^1].spectrum.raw.len > 0 and
    st.spectra[^1].spectrum.processed.len > 0)
  doAssert st.spectra[^1].spectrum.filters == "high-cut 40-50 Hz", st.spectra[^1].spectrum.filters
  doAssert st.spectra[^1].spectrum.processed == st.spectra[^1].spectrum.raw,
    "instead: the processed curve is not the raw curve"
  doAssert "this trace uses its own filter instead of the plot's" in st.spectra[^1].filterText,
    st.spectra[^1].filterText
  doAssert "Trace 4: own filter, band-pass 15-35 Hz" in st.spectra[^1].filterText,
    st.spectra[^1].filterText
  st.apply Command(kind: ckCloseSpectrum, spectrum: st.spectra[^1].id)
  # undo removes the instead filter; the row is the plot's again
  st.apply Command(kind: ckUndoEdit, panel: MainPanel)
  doAssert st.settle(st.answered)
  doAssert st.tiles(0)[^1].rowOf(3) == plotted.rowOf(3), "undo did not put the filter back"
  # a spectrum of the filtered trace: the own filter is in the raw curve.
  # The response is the plot's filters only.
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[base + 1])
  doAssert st.settle(st.spectra.len > 1 and not st.spectra[^1].waiting and
    st.spectra[^1].spectrum.processed.len > 0)
  let sp = st.spectra[^1].spectrum
  doAssert sp.raw.len == sp.processed.len and sp.raw.len > 8
  doAssert sp.filters == "high-cut 40-50 Hz", sp.filters
  doAssert "Trace 2: own filter, band-pass 12-40 Hz" in st.spectra[^1].filterText,
    st.spectra[^1].filterText
  let plotOnly = appliedResponse(plot.filterPipeline(dt), dt, lay.samples, sp.responseHz)
  doAssert sp.response == plotOnly, "the response is not the plot's filters alone"
  # several traces with their own filters: the count, and the plot's response
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 3], on: true,
    processing: instead.spec, filterPlace: fpInstead)
  doAssert st.settle(st.answered)
  st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[base + 1, base + 3])
  doAssert st.settle(st.spectra[^1].spectrum.processed.len > 0)
  let both = st.spectra[^1].spectrum
  doAssert "2 traces have their own filter" in st.spectra[^1].filterText, st.spectra[^1].filterText
  doAssert "2 traces have their own filter" notin both.filters, both.filters
  let plotResp = appliedResponse(plot.filterPipeline(dt), dt, lay.samples, both.responseHz)
  doAssert both.response == plotResp, "a mixed window did not keep the plot's response"
  st.shutdown()

block relevel:
  # Normalized over the whole record: a trace-filter step releveled, as a
  # plot-filter change does. Seen to fail with resample not releveled on a
  # filter step: "a trace filter did not relevel".
  var st = initAppState()
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  var d = st.panel(MainPanel).layers[0].display
  d.gain = dgNormalized
  d.normScope = perPanel
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 800, 2 * lay.samples))
  doAssert st.settle(st.answered)
  st.apply Command(kind: ckProcessing, panel: MainPanel,
    processing: Processing(band: pbHighCut, f3: 40, f4: 50))
  doAssert st.settle(st.answered and not st.panel(MainPanel).relevel)
  let before = st.panel(MainPanel).level.clip
  let base = st.sessions[0].base
  var ids: seq[int]
  for t in 0 ..< st.sessions[0].len: ids.add base + t
  let narrow = band(5, 8, fpInstead)
  st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: ids, on: true,
    processing: narrow.spec, filterPlace: fpInstead)
  doAssert st.panel(MainPanel).relevel, "a trace filter did not relevel"
  doAssert st.settle(st.answered and not st.panel(MainPanel).relevel)
  doAssert abs(st.panel(MainPanel).level.clip - before) > 1e-6, "the level stayed " & $before
  st.shutdown()

block changedBeforeIdentity:
  # A pending document of filters, the file changed since: the warning lists
  # them, as it lists kills. Seen to fail with the list omitting filters:
  # the warning ended "They were: ."
  let config = root / ".scratch" / "ownfilter-pending"
  createDir(config)
  if dirExists(config / StoreFolder):
    for kind, p in walkDir(config / StoreFolder):
      if kind == pcFile: removeFile(p)
  var st = initAppState()
  st.rememberFilesIn(config)
  createDir(config / StoreFolder)
  writeFile(config / StoreFolder / pendingName(land), memoryDocument(FileRecord(
    identity: FileIdentity(size: getFileSize(land) + 1), name: "shots.sgy", path: land,
    opened: getTime(), modified: getLastModificationTime(land),
    edits: EditLists(filters: @[FilterEntry(trace: 2, filter: band(10, 60))]))))
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
  proc warning(st: AppState): string =
    for e in st.log:
      if e.severity == sevWarning: result = e.text
  doAssert st.settle("1 filtered" in warning(st)), warning(st)
  doAssert not st.ownAt(land, 2).has, "the dropped filter was applied"
  st.shutdown()

block words:
  doAssert filterWords(OwnFilter(place: fpInstead)) ==
    "No filter: the plot's filters are not applied"
  let plot = Processing(band: pbHighCut, f3: 40, f4: 50)
  doAssert ownShownWords(11, [band(10, 60)]) == "Trace 12: own filter, band-pass 10-60 Hz"
  doAssert ownShownWords(0, [band(8, 20), band(40, 80, fpInstead)]) ==
    "2 traces have their own filter"
  doAssert insteadWords(1, 1) == "this trace uses its own filter instead of the plot's"

echo "townfilter: ok"
