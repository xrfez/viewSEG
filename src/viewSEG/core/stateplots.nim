## The analysis windows (New plot) in `AppState`: opened from a plot's
## traces, asked of their reader (`core/analysisreader`), following the
## plot they came from, closed. Included in `core/state`, after the
## spectrum windows, whose helpers it shares.

const MaxVibratorTraces* = 16
  ## traces a vibrator signature is opened on at most: those its roles
  ## choose from

const MaxPlotTraces* = 256
  ## traces a spectrogram averages at most (more chosen are taken evenly);
  ## a curve view draws the first `MaxAnalysisCurves`

func plots*(state: AppState): lent seq[AnalysisWindow] {.inline.} =
  ## The analysis windows, in the order opened.
  state.plots

func findPlot*(state: AppState; id: int): int =
  ## The index in `plots` of window `id`; -1 when there is none.
  for i, w in state.plots:
    if w.id == id: return i
  -1

func selectedIn*(state: AppState; i: int): int =
  ## How many of the selected traces are of open file `sessions[i]`; 0 for
  ## none, or no such file.
  result = 0
  if i in 0 ..< state.sessions.len:
    let s = state.sessions[i]
    for t in state.selection.selected:
      if t in s: inc result

proc traceNames*(state: AppState; w: AnalysisWindow): seq[string] =
  ## Window `w`'s traces as the curves call them ("trace 12": its place in
  ## its file), in its order; "trace ?" for one whose file is not open.
  for t in w.traces:
    let i = state.findTrace(t)
    result.add(if i >= 0: "trace " & $(t - state.sessions[i].base + 1) else: "trace ?")

func plotsWaiting*(state: AppState): seq[string] =
  ## The windows whose numbers are on their way, by title.
  for w in state.plots:
    if w.waiting: result.add w.title

func plotsUse(state: AppState; file: SessionId): bool =
  ## Whether an analysis window is of traces of open file `file`, or
  ## correlates against one of its traces: then showing another file in
  ## the plot keeps it open.
  let i = state.findSession(file)
  if i < 0: return false
  let s = state.sessions[i]
  for w in state.plots:
    if (w.traces.len > 0 and w.traces[0] in s) or
        (w.view == avCorrelation and w.params.reference >= 0 and w.params.reference in s):
      return true
  false

proc analysisReaderFor(state: var AppState; path: string): lent AnalysisReader =
  ## The analysis reader, started when first needed; one stuck in a drive
  ## that does not answer is left to end on its own when `path` is another
  ## file.
  if not state.analysisReader.isNil and state.analysisReader.silentFor >= StallAfter and
      state.analysisReader.readingPath != path:
    state.analysisReader.leave()
    state.leftAnalysisReaders.add move state.analysisReader
  if state.analysisReader.isNil:
    state.analysisReader = newAnalysisReader(state.inbox.poster, state.jobs.holdRelease)
  state.analysisReader

const SweepTraceCode = 6'i16 ## SEG-Y's trace identification code of a sweep: a pilot

func firstAux(s: Session; trace: int): int =
  ## The first auxiliary trace (index in the file) of the record `trace`
  ## is in: its pilot, for a correlation; -1 for none.
  result = -1
  let g = s.gatherOf(trace)
  if g >= 0 and g < s.gathers.len:
    let f = s.filePtr
    for t in s.gathers[g].traces:
      if t in 0 ..< f[].len and not isSeismic(f[].index, t): return t

proc askPlot(state: var AppState; w: int): bool =
  ## Asks the reader for window `plots[w]`'s numbers of its traces, with
  ## the filters it has; false when its file is not open any more or cannot
  ## be held now (asked again once it can).
  template pw: untyped = state.plots[w]
  let i = state.findTrace(if pw.traces.len > 0: pw.traces[0] else: -1)
  if i < 0: return false
  let s = state.sessions[i]
  var traces: seq[int] = @[]
  var labels: seq[string] = @[]
  for t in pw.traces:
    if t in s:
      traces.add t - s.base
      labels.add "trace " & $(t - s.base + 1)
  var a = AnalysisAsk(id: pw.id, view: pw.view, params: pw.params, file: s.filePtr,
    path: s.path, size: s.size, traces: traces, names: labels,
    processing: pw.processing)
  # the unit of the file's distances: as imported, else what its headers say
  let joined = state.joinedOf(s.id)
  let imported = joined >= 0 and state.joins[joined].units.file != suNotGiven
  a.unit = if imported: state.joins[joined].units.file else: headerUnitOf(s.crs)
  # the offsets' unit: the import's when joined, else the header's measurement system
  a.offsetUnit = if imported: state.joins[joined].units.file else: offsetUnitOf(s.crs)
  if pw.view == avCorrelation:
    let r = pw.params.reference
    let j = state.findTrace(r)
    if j >= 0:
      let rs = state.sessions[j]
      (a.refTrace, a.refName) = (r - rs.base, "trace " & $(r - rs.base + 1) &
        (if j != i: " of " & rs.name else: ""))
      if j != i:
        if not state.jobs.hold(rs.path): return false
        (a.refFile, a.refPath, a.refSize) = (rs.filePtr, rs.path, rs.size)
    else:
      let aux = s.firstAux(traces[0])
      if aux >= 0:
        # a sweep (SEG-Y trace code 6) is a pilot; any other auxiliary trace (a
        # time break on a dynamite record) is only the first one
        let sweep = s.filePtr[].traceKeys(aux).traceCode == SweepTraceCode
        (a.refTrace, a.refName) = (aux, (if sweep: "the pilot, trace "
          else: "the first auxiliary trace, trace ") & $(aux + 1))
    pw.reference = a.refName
  if not state.jobs.hold(s.path):
    if a.refFile != nil: discard state.jobs.holdRelease.release(a.refPath)
    return false
  # frozen: the kills it was frozen with; else the plot's now
  var killed = if pw.frozen: pw.killed else: killedOf(state.editsAt(s.path), traces)
  killed.sort()
  a.killed = killed
  inc state.plotGen
  a.gen = state.plotGen
  pw.asked = state.plotGen
  pw.waiting = true
  pw.killed = killed
  pw.editsSeen = state.editsAt(s.path).revision
  inc pw.asks
  inc pw.revision
  state.analysisReaderFor(s.path).ask a
  true

proc openPlot(state: var AppState; cmd: Command) =
  ## `ckOpenPlot`: a new analysis window of `cmd.plotTraces` (else the
  ## selected traces of the panel's file, else the trace under the
  ## pointer), asked for at once; an envelope or a phase spectrum is of the
  ## first of them; a vibrator signature opened on one trace takes it and
  ## the record's next three (Ref, GF, M, B, as wireline records have them);
  ## an f-k opened on fewer than `MinFkTraces` is of the seismic traces of
  ## the whole record, and of the first `MaxPlotTraces` (side by side) of
  ## more.
  let k = state.findPanel(if cmd.plotOf == NoPanel: MainPanel else: cmd.plotOf)
  let i = if k >= 0: state.shownFile(k) else: -1
  if k < 0:
    state.ignore(cmd, $cmd.plotOf & " does not exist")
    return
  if i < 0:
    state.ignore(cmd, "the panel shows no file")
    return
  if state.plots.len >= MaxAnalysisWindows:
    state.ignore(cmd, $MaxAnalysisWindows & " plot windows are open; close one first")
    return
  let problem = settingProblem(cmd.plotParams, cmd.plotView)
  if problem.len > 0:
    state.ignore(cmd, problem)
    return
  let s = state.sessions[i]
  var ids = cmd.plotTraces
  if ids.len == 0:
    for t in state.selection.selected:
      if t in s: ids.add t
    ids.sort()
  if ids.len == 0 and state.selection.hover >= 0 and state.selection.hover in s:
    ids.add state.selection.hover
  var traces: seq[int] = @[]
  var outside = 0
  for t in ids:
    if t in s: traces.add t - s.base
    else: inc outside
  traces = deduplicate(traces)
  if traces.len == 0:
    state.ignore(cmd, if ids.len == 0: "no trace is selected or under the pointer in " & s.name
                      else: "none of the traces is in " & s.name)
    return
  if cmd.plotView in {avEnvelope, avPhase} and traces.len > 1:
    traces.setLen 1 # a view of one trace: the first chosen
  if cmd.plotView == avVibrator:
    if traces.len == 1:
      # one trace: it and the record's next channels, as Ref, GF, M, B
      let g = s.gatherOf(traces[0])
      if g in 0 ..< s.gathers.len:
        let record = s.gathers[g].traces # (a run of the file's traces)
        if traces[0] in record:
          for t in traces[0] + 1 .. min(traces[0] + 3, record.b): traces.add t
    if traces.len > MaxVibratorTraces: traces.setLen MaxVibratorTraces
  if cmd.plotView == avFk:
    if traces.len < MinFkTraces:
      # too few for an f-k: the seismic traces of the first one's record
      let g = s.gatherOf(traces[0])
      if g in 0 ..< s.gathers.len:
        var record: seq[int] = @[]
        for t in s.gathers[g].traces:
          if isSeismic(s.filePtr[].index, t): record.add t
        if record.len >= MinFkTraces: traces = record
    if traces.len > MaxPlotTraces:
      # the first ones, side by side: taken evenly, their spacing would not be
      state.log.add(sevInfo, s.name, "An f-k of the first " & $MaxPlotTraces & " of the " &
        $traces.len & " traces.")
      traces.setLen MaxPlotTraces
  if traces.len > MaxPlotTraces:
    var kept: seq[int] = @[]
    for j in evenly(traces.len, MaxPlotTraces): kept.add traces[j]
    traces = kept
  if cmd.plotParams.reference >= 0 and state.findTrace(cmd.plotParams.reference) < 0:
    state.ignore(cmd, "the reference trace " & $cmd.plotParams.reference &
      " is in no open file")
    return
  template p: untyped = state.panels[k]
  var w = AnalysisWindow(id: freePlotId(state.plots), view: cmd.plotView,
    params: cmd.plotParams, panel: p.id, file: s.name, record: s.recordText(traces[0]),
    traces: traces.mapIt(it + s.base), first: traces[0], processing: spectrumFilters(p),
    since: state.plotGen + 1)
  w.filters = filtersText(w.processing)
  state.plots.add w
  if not state.askPlot(state.plots.high):
    state.plots.delete state.plots.high
    state.ignore(cmd, s.name & " is busy (a job needs it to itself)")
    return
  if outside > 0:
    state.log.add(sevWarning, s.name, $outside & " of the traces given are not in " & s.name &
      ": left out of the plot.")

proc showPlot(state: var AppState; cmd: Command) =
  ## `ckPlotDisplay`: an analysis window's settings, and whether it is
  ## frozen; asked again when a setting changed (from the samples, once
  ## read: nothing else follows a frozen window).
  let w = state.findPlot(cmd.plot)
  if w < 0:
    state.ignore(cmd, "there is no plot window " & $cmd.plot)
    return
  template pw: untyped = state.plots[w]
  let problem = settingProblem(cmd.plotParams, pw.view)
  if problem.len > 0:
    state.ignore(cmd, problem)
    return
  if cmd.plotParams.reference >= 0 and state.findTrace(cmd.plotParams.reference) < 0:
    state.ignore(cmd, "the reference trace " & $cmd.plotParams.reference &
      " is in no open file")
    return
  let changed = cmd.plotParams != pw.params
  pw.params = cmd.plotParams
  pw.frozen = cmd.plotFrozen # unfrozen, `followPlots` asks again if the plot changed
  inc pw.revision
  if changed and not state.askPlot(w):
    state.log.add(sevWarning, "New plot", "The file of " & pw.title & " is not open any " &
      "more, or busy: it shows what it had.")

proc holdPlotCursor(state: var AppState; cmd: Command) =
  ## `ckPlotCursor`: where an analysis window's cursor is held (by its
  ## keys, or an agent); let go (`held` false), it follows the pointer.
  let w = state.findPlot(cmd.plot)
  if w < 0:
    state.ignore(cmd, "there is no plot window " & $cmd.plot)
    return
  state.plots[w].cursor = cmd.plotCursor
  state.plots[w].cursorOn = cmd.plotCursorOn
  inc state.plots[w].revision

proc closePlot(state: var AppState; cmd: Command) =
  ## `ckClosePlot`: the window goes, its work with it.
  let w = state.findPlot(cmd.plot)
  if w < 0:
    state.ignore(cmd, "there is no plot window " & $cmd.plot)
    return
  if not state.analysisReader.isNil: state.analysisReader.cancel(cmd.plot)
  var files: seq[SessionId] = @[]
  for t in [state.plots[w].traces[0], state.plots[w].params.reference]:
    let i = state.findTrace(t)
    if i >= 0: files.add state.sessions[i].id
  state.plots.delete w
  # a file kept open for it alone, which no plot shows, goes with it
  for f in files:
    if not state.panels.anyIt(it.layers.anyIt(it.shows(f))) and not state.plotsUse(f):
      let i = state.findSession(f)
      if i >= 0: state.closeSession(i, quiet = true)

proc takeAnalysis(state: var AppState; m: sink Msg) =
  ## Numbers for a window still open, newer than those it shows.
  let w = state.findPlot(m.analysis.id)
  if w >= 0 and m.analysis.gen >= state.plots[w].since and
      m.analysis.gen <= state.plots[w].asked and m.analysis.gen > state.plots[w].result.gen:
    template pw: untyped = state.plots[w]
    pw.waiting = m.analysis.gen < pw.asked
    pw.result = move m.analysis
    inc pw.revision

proc followPlots(state: var AppState) =
  ## After every change: each window not frozen follows the filters of the
  ## plot it was opened from (and its Aux toggle; shown raw or not alike),
  ## and the kills of its traces, asked again when either changed. Its
  ## traces stay those it was opened on.
  for w in 0 ..< state.plots.len:
    template pw: untyped = state.plots[w]
    if not pw.frozen:
      let k = state.findPanel(pw.panel)
      let i = state.findTrace(if pw.traces.len > 0: pw.traces[0] else: -1)
      if k >= 0 and i >= 0 and state.panels[k].layers.len > 0:
        let pr = spectrumFilters(state.panels[k])
        let s = state.sessions[i]
        let e = state.editsAt(s.path)
        var killsMoved = false
        if e.revision != pw.editsSeen:
          var traces: seq[int] = @[]
          for t in pw.traces:
            if t in s: traces.add t - s.base
          var killed = killedOf(e, traces)
          killed.sort()
          killsMoved = killed != pw.killed
          if not killsMoved: pw.editsSeen = e.revision # other traces' edits: nothing to ask
        if pr != pw.processing or killsMoved:
          let was = pw.processing
          pw.processing = pr
          if state.askPlot(w): pw.filters = filtersText(pr)
          else: pw.processing = was # asked again once it can be
