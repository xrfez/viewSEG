## A per-trace time shift, kept with the file's edits (`core/edits`,
## `core/filememory`) and run where the plot's filters run (`core/reader`,
## `core/analysisreader`):
##
## - set, remove, undo and redo on one trace and on a selection, as one step;
##   the stored milliseconds are the snapped whole-sample shift;
## - a document without the field loads as no shifts; a field this version
##   does not know is kept and does not refuse the file; a round trip through
##   the file memory and through CSV keeps the shift, and a CSV with no shift
##   has no `ms` column;
## - the reader's row for a shifted trace equals the library's `timeShift`
##   of the same samples (positive later, so the count is negated), after a
##   snap, at zero, and when the shift is longer than the trace (all zeros);
##   a zoomed window matches the whole trace shifted, not the window alone;
##   the own filter runs after the shift, equal to the library then the
##   filter by hand; a neighbour is unchanged; an auxiliary trace is not
##   shifted;
## - a trace with no shift allocates no shift list (`shiftsIn` returns before
##   `newSeqOfCap`) and the reader does not walk a shift (`req.shifts.len == 0`
##   skips the rows). `applyStoredShift` returns before `timeShift` when the
##   milliseconds are 0.
##
## Seen to fail: with `setTimeShifts` storing the asked milliseconds, "stored
## 3.0, not the snapped 4 ms". With `prepare` not applying the shift, "trace 2
## is not the snapped shift". With the seismic guard off, "an auxiliary trace
## was shifted". With `shiftNeedsWhole` false, "a shift did not read the whole
## trace: (gen: 5, first: 0, count: 20, stride: 1, firstSample: 138, samples: 165,
## decimation: 1, margin: 0, envelope: false)".
##
## Runs on samples/land/shots.sgy and a synthetic file with an auxiliary trace.

import std/[os, strutils, times]
import parseSEG
import processSEG/core/timeshift
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import viewSEG/core/[analysisreader, editmarks, edits, filememory, nif, processing, state]
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

proc band(lo, hi: float64): OwnFilter =
  bounded(OwnFilter(spec: Processing(band: pbBandPass, f1: lo - 2, f2: lo, f3: hi, f4: hi + 4)))

proc moved(samples: seq[float32]; ms, dtMs: float64): seq[float32] =
  ## `samples` shifted as the plot does: the library, positive later.
  result = samples
  if result.len == 0: return
  let n = wholeSamples(ms, dtMs)
  if n != 0: timeShift(result, -n)

proc byHand(samples: seq[float32]; dtMs: float64; steps: openArray[Processing]): seq[float32] =
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

proc show(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
  var d = st.panel(MainPanel).layers[0].display
  d.gain = dgNone
  st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)

proc fit(st: var AppState; columns, rows: int) =
  let lay = st.panel(MainPanel).layout
  var view = fitAll(lay, columns, rows)
  view.traces = Span(lo: -0.5, hi: float64(min(lay.traces, 8)) - 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: view)
  doAssert st.settle(st.answered)
  doAssert st.tiles(0)[^1].request.decimation == 1, $st.tiles(0)[^1].request

proc main*() =
  block lists:
    var e: FileEdits
    let dt = 2.0
    doAssert e.setTimeShifts([4], 3.0, dt) == 1
    doAssert e.shiftOf(4) == 4.0, "stored " & $e.shiftOf(4) & ", not the snapped 4 ms"
    doAssert e.hasShift(4)
    doAssert describe(e.nextUndo) == "trace 5 shifted"
    doAssert e.setTimeShifts([4, 6, 4], 4.0, dt) == 1 # 4 already at 4 ms
    doAssert describe(e.nextUndo) == "trace 7 shifted"
    doAssert e.setTimeShifts([1, 2], -3.0, dt) == 2
    doAssert e.shiftOf(1) == -4.0 and e.shiftOf(2) == -4.0
    doAssert describe(e.nextUndo) == "2 traces shifted"
    doAssert e.undo().kind == skTimeShift and not e.hasShift(1) and not e.hasShift(2)
    doAssert e.hasShift(4) and e.shiftOf(6) == 4.0
    doAssert e.redo().kind == skTimeShift and e.shiftOf(1) == -4.0
    doAssert e.clearTimeShifts([4, 6, 1, 2]) == 4
    doAssert e.isEmpty and describe(e.nextUndo) == "shifts of 4 traces removed"
    doAssert e.undo().kind == skTimeShift and e.hasShift(4) and e.hasShift(2)
    doAssert e.setTimeShifts([4], 0.0, dt) == 1 # a snap of no sample takes it away
    doAssert not e.hasShift(4)
    discard e.undo()
    doAssert e.canRedo
    doAssert e.setTimeShifts([8], 4.0, dt) == 1 and not e.canRedo
    doAssert e.change(teKilled, [4], true) == 1
    doAssert e.has(teKilled, 4) and e.hasShift(4) # a kill keeps the shift
    doAssert e.setTimeShifts([0], 4.0, 0.0) == 0 # no interval: nothing stored
    doAssert not e.hasShift(0)
    doAssert e.shiftsIn(20 .. 30).len == 0
    doAssert e.clearAll() and e.isEmpty
    doAssert e.undo().kind == skClear and e.hasShift(4) and e.has(teKilled, 4)
    doAssert shiftWords(500.0) == "shifted +500 ms"
    doAssert shiftWords(-4.0) == "shifted -4 ms"
    doAssert "shifted +500 ms" in markTip(MarkHit(traces: @[3]),
      @[EditMark(trace: 3, shiftNote: shiftWords(500.0))])

  block memory:
    var rec = FileRecord(name: "shots.sgy", path: "shots.sgy")
    rec.edits.lists[teKilled] = @[2]
    rec.edits.shifts = @[ShiftEntry(trace: 4, ms: 4.0), ShiftEntry(trace: 6, ms: -2.0)]
    let doc = memoryDocument(rec)
    doAssert "(shifted" in doc
    var problems: seq[string]
    let back = readMemory(parseNif(doc, "t.nif"), "t.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.edits.shifts == rec.edits.shifts, "the shift did not come back"
    doAssert back.edits.lists[teKilled] == @[2]
    let old = doc.replace("(shifted", "(shiftedLater")
    problems.setLen 0
    let aged = readMemory(parseNif(old, "old.nif"), "old.nif", problems)
    doAssert aged.edits.shifts.len == 0, "an old document gained a shift"
    doAssert aged.later.len > 0
    let plain = "trace,record,channel,edit,file\n3,,,killed,shots.sgy\n"
    problems.setLen 0
    let fromOld = readEditsCsv(plain, "old.csv", problems)
    doAssert problems.len == 0 and fromOld.shifts.len == 0, $problems
    doAssert not ("," & "ms" in editsCsv(fromOld, [], [], "shots.sgy").splitLines[0])
    let csv = editsCsv(rec.edits, [1.0, 1.0, 1.0], [3.0, 5.0, 7.0], "shots.sgy")
    doAssert csv.splitLines[0].endsWith(",ms")
    problems.setLen 0
    let fromCsv = readEditsCsv(csv, "a.csv", problems)
    doAssert problems.len == 0, $problems
    doAssert fromCsv.shifts == rec.edits.shifts, $fromCsv.shifts
    doAssert fromCsv.lists[teKilled] == @[2]
    doAssert "2 shifted" in keptWords(rec.edits)

  let land = root / "samples" / "land" / "shots.sgy"
  doAssert fileExists(land), "samples/land/shots.sgy is not here"
  block reader:
    var st = initAppState()
    st.show land
    st.fit(800, 2 * st.panel(MainPanel).layout.samples)
    let raw = st.tiles(0)[^1]
    let dt = st.panel(MainPanel).layout.dtMs
    let base = st.sessions[0].base
    let asked = dt * 1.5 # ties away from zero: two samples
    doAssert wholeSamples(asked, dt) == 2
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 1], on: true,
      shiftMs: asked)
    doAssert st.settle(st.answered)
    let snapped = st.tiles(0)[^1]
    doAssert snapped.rowOf(1) == moved(raw.rowOf(1), asked, dt),
      "trace 2 is not the snapped shift"
    doAssert snapped.rowOf(0) == raw.rowOf(0), "trace 1 changed"
    doAssert snapped.rowOf(1) != raw.rowOf(1), "a snap of two samples left the trace"
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 1], on: true,
      shiftMs: -dt)
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].rowOf(1) == moved(raw.rowOf(1), -dt, dt),
      "trace 2 moved the wrong way"
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 1], on: false)
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].rowOf(1) == raw.rowOf(1), "clearing the shift left it on"
    let huge = dt * float64(raw.rowOf(1).len + 5)
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 1], on: true,
      shiftMs: huge)
    doAssert st.settle(st.answered)
    let wiped = st.tiles(0)[^1].rowOf(1)
    for v in wiped: doAssert v == 0, "a shift longer than the trace left a sample"
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].rowOf(1) == raw.rowOf(1), "undo did not put the trace back"
    st.apply Command(kind: ckRedoEdit, panel: MainPanel)
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].rowOf(1) == wiped, "redo did not shift the trace again"
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    let plot = Processing(band: pbHighCut, f3: 40, f4: 50)
    st.apply Command(kind: ckProcessing, panel: MainPanel, processing: plot)
    doAssert st.settle(st.answered)
    let plotted = st.tiles(0)[^1]
    let own = band(12, 40)
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 1], on: true,
      shiftMs: 4 * dt)
    st.apply Command(kind: ckOwnFilter, panel: MainPanel, edited: @[base + 1], on: true,
      processing: own.spec, filterPlace: fpAfter)
    doAssert st.settle(st.answered)
    let both = st.tiles(0)[^1]
    let hand = byHand(moved(raw.rowOf(1), 4 * dt, dt), dt, [plot, own.spec])
    doAssert both.rowOf(1) == hand, "shift then filter is not the library, then the filter"
    doAssert both.rowOf(2) == plotted.rowOf(2), "trace 3 changed"
    st.shutdown()

  block wholeTrace:
    # A late window, shift only: the read starts at sample 0 and the row is
    # the whole trace shifted. Seen to fail with `shiftNeedsWhole` false.
    var st = initAppState()
    st.show land
    st.fit(800, 2 * st.panel(MainPanel).layout.samples)
    let raw = st.tiles(0)[^1]
    let dt = st.panel(MainPanel).layout.dtMs
    let base = st.sessions[0].base
    var view = fitAll(st.panel(MainPanel).layout, 200, 80)
    let start = st.panel(MainPanel).layout.t0Ms + 200 * dt
    view.timeMs = Span(lo: start, hi: start + 40 * dt)
    view.traces = Span(lo: -0.5, hi: 7.5)
    st.apply Command(kind: ckView, panel: MainPanel, view: view)
    st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 1], on: true,
      shiftMs: 4 * dt)
    doAssert st.settle(st.answered)
    let zoomed = st.tiles(0)[^1]
    doAssert zoomed.request.margin >= st.panel(MainPanel).layout.samples,
      "a shift did not read the whole trace: " & $zoomed.request
    let full = moved(raw.rowOf(1), 4 * dt, dt)
    let a = zoomed.request.firstSample
    doAssert zoomed.rowOf(1) == full[a ..< a + zoomed.columns],
      "the late window is not the whole trace shifted"
    st.shutdown()

  block auxiliary:
    withFixtures fx:
      let path = fx.spectrumAuxSegy()
      var st = initAppState()
      st.show path
      st.apply Command(kind: ckFilter, panel: MainPanel,
        filter: TraceFilter(seismic: true, auxiliary: true))
      doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).layout.traces == 5)
      st.fit(200, st.panel(MainPanel).layout.samples)
      let raw = st.tiles(0)[^1]
      let dt = st.panel(MainPanel).layout.dtMs
      let base = st.sessions[0].base
      st.apply Command(kind: ckTimeShift, panel: MainPanel, edited: @[base + 0, base + 4],
        on: true, shiftMs: 4 * dt)
      doAssert st.settle(st.answered)
      let t = st.tiles(0)[^1]
      doAssert t.rowOf(0) == moved(raw.rowOf(0), 4 * dt, dt), "the seismic trace was not shifted"
      doAssert t.rowOf(4) == raw.rowOf(4), "an auxiliary trace was shifted"
      st.shutdown()

  echo "ttimeshift: ok"

when isMainModule:
  main()
