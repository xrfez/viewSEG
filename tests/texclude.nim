## A trace excluded from the plot's filters (the "Exclude from plot filters" edit,
## mark "E"): the edit lists, their memory with the file, the menu's lines and
## tooltip, and the readers: a plot filter changes an unmarked trace and leaves an
## excluded one as the file has it, bit for bit, an auxiliary trace too when
## "Filter the Aux traces too" is on; a filter of the trace's own still runs.
##
## Seen to fail: with the readers given the stored own filters (`plotFiltersIn`
## replaced by `filtersIn` in the request), "the excluded trace was filtered";
## with the exclusion left out of `isEmpty`, "an exclusion alone is not an edit";
## with "excluded" left out of the memory document, "the exclusion was not
## remembered"; with the list left out of `markEntries`, "no line takes the
## exclusion away".

import std/[os, strutils]
import parseSEG
import viewSEG/core/[editmarks, edits, filememory, identity, nif, processing, spectra, state]
import utils/[fixtures, waiting]

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending

proc showAll(st: var AppState) =
  var d = st.panel(MainPanel).layers[0].display
  (d.gain, d.mode) = (dgNone, dmDensity)
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
  let lay = st.panel(MainPanel).layout
  st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
  doAssert st.settle(st.answered)

proc rowOf(t: Tile; trace: int): seq[float32] =
  let r = t.traces.find(trace)
  doAssert r >= 0, "trace " & $(trace + 1) & " is not in the tile"
  t.data[r * t.columns ..< (r + 1) * t.columns]

proc main*() =

  block lists:
    var e: FileEdits
    doAssert e.change(teExcluded, [3, 5, 3], true) == 2
    doAssert e.has(teExcluded, 3) and e.len(teExcluded) == 2 and e.editsOf(5) == {teExcluded}
    doAssert not e.isEmpty, "an exclusion alone is not an edit"
    doAssert describe(e.nextUndo) == "2 traces excluded from the plot's filters"
    doAssert e.undo().traces == @[3, 5] and not e.has(teExcluded, 3)
    doAssert e.redo().traces == @[3, 5] and e.has(teExcluded, 5)
    doAssert e.change(teExcluded, [5], false) == 1 and e.listIn(teExcluded, 0 .. 10) == @[3]
    doAssert describe(e.nextUndo) == "trace 6 given the plot's filters again"
    doAssert e.nextUndo.touches(teExcluded) and not e.nextUndo.touches(teKilled)
    # the plot's readers get the exclusion as an own filter that runs instead
    let band = OwnFilter(spec: Processing(band: pbBandPass, f1: 4, f2: 8, f3: 12, f4: 16),
      place: fpAfter)
    doAssert e.setOwnFilters([3, 4], band, true) == 2
    let own = e.plotFiltersIn(0 .. 10)
    doAssert own.len == 2 and own[0].trace == 3 and own[1].trace == 4, $own
    doAssert own[0].filter.place == fpInstead and own[0].filter.spec == band.spec,
      "an excluded trace keeps its own filter, run instead of the plot's"
    doAssert own[1].filter.place == fpAfter
    doAssert e.change(teExcluded, [1], true) == 1
    doAssert e.plotFiltersIn(0 .. 10)[0].trace == 1 and
      e.plotFiltersIn(0 .. 10)[0].filter.place == fpInstead and
      not e.plotFiltersIn(0 .. 10)[0].filter.spec.hasFilters
    doAssert e.clearAll() and e.isEmpty

  block memory:
    var l = EditLists()
    l.lists[teExcluded] = @[2, 3, 9]
    l.lists[teKilled] = @[4]
    let id = FileIdentity(size: 99, quick: 7, full: 1, fullKnown: true)
    let rec = FileRecord(identity: id, name: "x.sgy", path: "/x.sgy", edits: l,
      doc: docName(id, 1))
    let text = memoryDocument(rec)
    doAssert "(excluded \"3-4 10\")" in text, "the exclusion was not remembered: " & text
    var problems: seq[string]
    let back = readMemory(parseNif(text, "x"), rec.doc, problems)
    doAssert problems.len == 0 and back.edits == l, $problems
    doAssert keptWords(l) == "1 killed, 3 excluded"
    let csv = editsCsv(l, [], [], "x.sgy")
    doAssert ",excluded," in csv, csv
    var bad: seq[string]
    doAssert readEditsCsv(csv, "x.csv", bad) == l and bad.len == 0, $bad
    # the list read is not also kept as a later version's node (it came back after a removal);
    # the store's merge reads documents through `readMemoryFile`, the same reader
    doAssert back.later.len == 0, "an excluded node is kept as a later version's"
    var cleared = back
    cleared.edits.lists[teExcluded] = @[]
    let text2 = memoryDocument(cleared)
    doAssert "(excluded" notin text2, "the removed exclusion is written again: " & text2
    var p2: seq[string]
    let again = readMemory(parseNif(text2, "x"), rec.doc, p2)
    doAssert again.edits.lists[teExcluded].len == 0 and again.later.len == 0, "it came back"
    let dir = getTempDir() / "viewSEG-texclude-" & $getCurrentProcessId()
    createDir(dir)
    writeFile(dir / "doc.nif", text)
    var p3: seq[string]
    let viaFile = readMemoryFile(dir / "doc.nif", p3)
    removeDir(dir)
    doAssert viaFile.later.len == 0 and viaFile.edits.lists[teExcluded] == @[2, 3, 9]

  block menu:
    let rows = [TraceEditView(trace: 4, edits: {teExcluded})]
    let hit = MarkHit(traces: @[4])
    let entries = markEntries(hit, rows, [])
    doAssert entries.len == 1 and entries[0].item == miRemoveExclude,
      "no line takes the exclusion away"
    doAssert entryText(entries[0], false).startsWith("Remove the exclusion")
    let tip = markTip(hit, [EditMark(trace: 4, edits: {teExcluded})])
    doAssert "Excluded from the plot's filters" in tip, tip

  block tiles:
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[path])
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.showAll()
      let raw = st.tiles(0)[^1]
      let base = st.sessions[0].base
      let spec = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 60, f4: 80, dc: dcMean)
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: spec)
      doAssert st.settle(st.answered)
      let both = st.tiles(0)[^1]
      doAssert both.rowOf(4) != raw.rowOf(4), "the plot's filter did not change trace 5"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teExcluded, edited: @[base + 4],
        on: true)
      doAssert st.settle(st.answered and st.traceEdits(base + 4) == {teExcluded})
      doAssert st.settle(st.tiles(0)[^1].rowOf(4) == raw.rowOf(4)),
        "the excluded trace was filtered"
      let t = st.tiles(0)[^1]
      doAssert t.rowOf(5) == both.rowOf(5), "an unmarked trace is filtered as before"
      doAssert t.rowOf(5) != raw.rowOf(5)
      # a spectrum window: the plot's filter does not touch the excluded trace (processed ==
      # raw) and does touch an unmarked one
      proc spectrumOf(st: var AppState; trace: int): Spectrum =
        st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[trace],
          spectrumShow: SpectrumDisplay())
        let w = st.spectra.high
        doAssert st.settle(not st.spectra[w].waiting and st.spectra[w].spectrum.raw.len > 0 and
          st.spectra[w].spectrum.processed.len > 0), "no spectrum"
        st.spectra[w].spectrum
      let ex = st.spectrumOf(base + 4)
      doAssert ex.processed == ex.raw, "the plot's filter touched the excluded trace's spectrum"
      let other = st.spectrumOf(base + 5)
      doAssert other.processed != other.raw, "the plot's filter did not touch an unmarked trace"
      # its own filter is a separate choice and still runs
      st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 4], on: true,
        processing: Processing(band: pbLowCut, f1: 20, f2: 30), filterPlace: fpAfter)
      doAssert st.settle(st.tiles(0)[^1].rowOf(4) != raw.rowOf(4)),
        "an excluded trace's own filter did not run"
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.tiles(0)[^1].rowOf(4) == raw.rowOf(4))
      st.apply Command(kind: ckUndoEdit, panel: MainPanel)
      doAssert st.settle(st.tiles(0)[^1].rowOf(4) == both.rowOf(4)),
        "undo did not give the plot's filters back"
      st.shutdown()

  block aux_with_filter_aux_on:
    withFixtures fx:
      let segd = fx.threeComponentSegd() # a time break, then seismic traces
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[segd])
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: true,
        auxiliary: true))
      doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).layout.traces == 37)
      st.showAll()
      let base = st.sessions[0].base
      let raw = st.tiles(0)[^1]
      var p = Processing(band: pbLowCut, f1: 2, f2: 6, aux: true)
      st.apply Command(kind: ckProcessing, panel: MainPanel, processing: p)
      doAssert st.settle(st.answered)
      doAssert st.tiles(0)[^1].rowOf(0) != raw.rowOf(0), "Aux on did not filter the time break"
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teExcluded, edited: @[base],
        on: true)
      doAssert st.settle(st.tiles(0)[^1].rowOf(0) == raw.rowOf(0)),
        "the excluded time break was filtered with Aux on"
      st.shutdown()
when isMainModule:
  main()
