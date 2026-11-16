## The analysis windows (New plot) in `AppState`: opened from a plot's
## traces, asked of their reader (`core/analysisreader`), following the
## plot they came from the way the spectrum windows do (`sameFollow`),
## closed. Included in `core/state`, after the spectrum windows, whose
## helpers it shares.

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

func analysisQueued*(state: AppState): int =
  ## Analysis requests waiting to be served (not the one under way). Quick
  ## selection changes must not leave a pile: the latest of a window wins.
  if state.analysisReader.isNil: 0 else: state.analysisReader.queued

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
  let e = state.editsAt(s.path)
  var killed = if pw.frozen: pw.killed else: killedOf(e, traces)
  killed.sort()
  a.killed = killed
  if not pw.frozen:
    pw.own = ownOfTraces(e, traces)
    pw.ownKey = ownKeyOf(e, traces)
  a.own = pw.own
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

proc stampPick(state: var AppState; w, k, i: int) =
  ## Remembers what chose window `plots[w]`'s traces, so a later change of
  ## the selection, the record, the file or the sort asks again.
  template pw: untyped = state.plots[w]
  template p: untyped = state.panels[k]
  pw.pickSession = int(state.sessions[i].id)
  pw.pickGather = if p.layers.len > 0: p.layers[0].source.gather else: -1
  pw.pickSelected = state.selection.selectedRevision
  pw.pickOrder = p.orderGen
  pw.pickSource = p.sourceGen
  pw.pickShown = p.shown.len

func pickChanged(state: AppState; w, k, i: int): bool =
  ## Whether the plot's choice of traces moved on since window `plots[w]`
  ## last followed it.
  template pw: untyped = state.plots[w]
  template p: untyped = state.panels[k]
  let gather = if p.layers.len > 0: p.layers[0].source.gather else: -1
  pw.pickSession != int(state.sessions[i].id) or pw.pickGather != gather or
    pw.pickSelected != state.selection.selectedRevision or pw.pickOrder != p.orderGen or
    pw.pickSource != p.sourceGen or pw.pickShown != p.shown.len

proc shapeOpened(state: AppState; view: AnalysisView; i: int; traces: var seq[int]) =
  ## The traces a new window of `view` is opened on, from the ones chosen:
  ## an envelope or a phase spectrum keeps the first; a vibrator signature
  ## opened on one takes the record's next three; an f-k opened on fewer
  ## than `MinFkTraces` takes the record's seismic traces; more than
  ## `MaxPlotTraces` are cut down (an f-k: the first, side by side; another
  ## view: spread evenly).
  if traces.len == 0 or i < 0: return
  let s = state.sessions[i]
  if view in {avEnvelope, avPhase} and traces.len > 1: traces.setLen 1
  if view == avVibrator:
    if traces.len == 1:
      let g = s.gatherOf(traces[0])
      if g in 0 ..< s.gathers.len:
        let record = s.gathers[g].traces
        if traces[0] in record:
          for t in traces[0] + 1 .. min(traces[0] + 3, record.b): traces.add t
    if traces.len > MaxVibratorTraces: traces.setLen MaxVibratorTraces
  if view == avFk:
    if traces.len < MinFkTraces:
      let g = s.gatherOf(traces[0])
      if g in 0 ..< s.gathers.len:
        var record: seq[int] = @[]
        for t in s.gathers[g].traces:
          if isSeismic(s.filePtr[].index, t): record.add t
        if record.len >= MinFkTraces: traces = record
    if traces.len > MaxPlotTraces: traces.setLen MaxPlotTraces
  if traces.len > MaxPlotTraces:
    var kept: seq[int] = @[]
    for j in evenly(traces.len, MaxPlotTraces): kept.add traces[j]
    traces = kept

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
  if cmd.plotView == avFk and traces.len >= MinFkTraces and traces.len > MaxPlotTraces:
    # the first ones, side by side: taken evenly, their spacing would not be
    state.log.add(sevInfo, s.name, "An f-k of the first " & $MaxPlotTraces & " of the " &
      $traces.len & " traces.")
  state.shapeOpened(cmd.plotView, i, traces)
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
  state.stampPick(state.plots.high, k, i)
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
  var mentioned: seq[int] = @[]
  if state.plots[w].traces.len > 0: mentioned.add state.plots[w].traces[0]
  mentioned.add state.plots[w].params.reference
  for t in mentioned:
    let i = state.findTrace(t)
    if i >= 0: files.add state.sessions[i].id
  state.plots.delete w
  # a file kept open for it alone, which no plot shows, goes with it
  for f in files:
    if not state.panels.anyIt(it.layers.anyIt(it.shows(f))) and not state.plotsUse(f) and
        not state.spectraUse(f):
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

proc gatherOrder(state: AppState; k, i: int): seq[int] =
  ## File indices of the gather `panels[k]` shows, in the order shown once
  ## the reader has said, else the gather's own order.
  result = @[]
  if state.panels[k].layers.len == 0: return
  let s = state.sessions[i]
  let g = state.panels[k].layers[0].source.gather
  if g notin 0 ..< s.gathers.len: return
  if state.panels[k].shown.len > 0: result = state.panels[k].shown
  else:
    for t in s.gathers[g].traces: result.add t

proc gatherFile(state: AppState; k, i: int): seq[int] =
  ## The gather's traces in file order, auxiliary ones included.
  result = @[]
  if state.panels[k].layers.len == 0: return
  let s = state.sessions[i]
  let g = state.panels[k].layers[0].source.gather
  if g in 0 ..< s.gathers.len:
    for t in s.gathers[g].traces: result.add t

func recordHasAux(state: AppState; k, i: int): bool =
  ## Whether the record on show has an auxiliary trace (a pilot, a time break).
  let s = state.sessions[i]
  let f = s.filePtr
  if state.panels[k].layers.len == 0: return false
  let g = state.panels[k].layers[0].source.gather
  if g notin 0 ..< s.gathers.len: return false
  for t in s.gathers[g].traces:
    if t in 0 ..< f[].len and not isSeismic(f[].index, t): return true
  false

proc firstSweep(state: AppState; k, i: int): int =
  ## The record's sweep (trace code 6), else its first auxiliary trace; -1
  ## for none. The keys are the file's, already read.
  result = -1
  let s = state.sessions[i]
  let f = s.filePtr
  if state.panels[k].layers.len == 0: return
  let g = state.panels[k].layers[0].source.gather
  if g notin 0 ..< s.gathers.len: return
  var aux = -1
  for t in s.gathers[g].traces:
    if t in 0 ..< f[].len and not isSeismic(f[].index, t):
      if aux < 0: aux = t
      if f[].traceKeys(t).traceCode == SweepTraceCode: return t
  result = aux

proc selectedHere(state: AppState; i: int; order: openArray[int]): seq[int] =
  ## Selected traces of the record `order` lists, in that order.
  result = @[]
  if not state.selection.anySelected: return
  let base = state.sessions[i].base
  for t in order:
    if base + t in state.selection.selected: result.add t

proc defaultOf(state: AppState; view: AnalysisView; k, i: int; order: seq[int]):
    (seq[int], string) =
  ## What `view` shows of the record with no selection, and why it cannot
  ## when the record has nothing for it.
  case view
  of avEnvelope, avPhase:
    if order.len == 0: return (@[], "the plot shows no trace")
    (@[order[0]], "")
  of avSpectrogram, avCorrelation:
    if order.len == 0: return (@[], "the plot shows no trace")
    var traces = order
    state.shapeOpened(view, i, traces)
    (traces, "")
  of avVibrator:
    let pilot = state.firstSweep(k, i)
    if pilot < 0: return (@[], "this record has no pilot")
    var traces = @[pilot]
    state.shapeOpened(avVibrator, i, traces)
    (traces, "")
  of avFk:
    var seismic: seq[int] = @[]
    let s = state.sessions[i]
    let f = s.filePtr
    let src = if order.len > 0: order else: state.gatherFile(k, i)
    for t in src:
      if t in 0 ..< f[].len and isSeismic(f[].index, t): seismic.add t
    if seismic.len < MinFkTraces:
      return (@[], "an f-k needs " & $MinFkTraces & " traces at least; this record has " &
        $seismic.len)
    if seismic.len > MaxPlotTraces: seismic.setLen MaxPlotTraces
    (seismic, "")

proc blockPlot(state: var AppState; w, i: int; problem: string) =
  ## The window stays open and says `problem`; nothing is asked.
  template pw: untyped = state.plots[w]
  if not state.analysisReader.isNil: state.analysisReader.cancel(pw.id)
  let name = if i >= 0: state.sessions[i].name else: ""
  if pw.result.problem == problem and pw.traces.len == 0 and not pw.waiting and pw.file == name:
    return
  pw.waiting = false
  pw.traces.setLen 0
  pw.file = name
  pw.record = ""
  pw.result = AnalysisResult(view: pw.view, problem: problem)
  pw.since = state.plotGen + 1
  inc pw.revision

proc followFilters(state: var AppState; w, k: int) =
  ## Window `plots[w]`, not frozen, follows the plot's filters and the kills
  ## of the traces it already shows. `sameFollow` is the spectrum windows'
  ## comparison.
  template pw: untyped = state.plots[w]
  let i = state.findTrace(if pw.traces.len > 0: pw.traces[0] else: -1)
  if i < 0 or state.panels[k].layers.len == 0: return
  let pr = spectrumFilters(state.panels[k])
  let s = state.sessions[i]
  var fileTraces: seq[int] = @[]
  for t in pw.traces:
    if t in s: fileTraces.add t - s.base
  let e = state.editsAt(s.path)
  var killed = killedOf(e, fileTraces)
  killed.sort()
  let ownMoved = e.revision != pw.editsSeen and ownKeyOf(e, fileTraces) != pw.ownKey
  let now = LiveKey(session: s.id, traces: fileTraces, processing: pr, killed: killed)
  let was = LiveKey(session: s.id, traces: fileTraces, processing: pw.processing,
    killed: pw.killed)
  if not sameFollow(now, was) or ownMoved:
    let kept = pw.processing
    pw.processing = pr
    if state.askPlot(w): pw.filters = filtersText(pr)
    else: pw.processing = kept
  elif e.revision != pw.editsSeen:
    pw.editsSeen = e.revision

proc repick(state: var AppState; w, k, i: int): bool =
  ## Chooses window `plots[w]`'s traces again from the plot (the selection,
  ## else what the view shows with none) and asks; true when that replaced
  ## the filter follow. A record that cannot feed the view is said, and the
  ## window stays open.
  let view = state.plots[w].view
  let order = state.gatherOrder(k, i)
  var seed = state.selectedHere(i, order)
  var problem = ""
  if seed.len == 0:
    (seed, problem) = state.defaultOf(view, k, i, order)
  else:
    state.shapeOpened(view, i, seed)
    if view == avVibrator and not state.recordHasAux(k, i):
      problem = "this record has no pilot"
    elif view == avFk and seed.len < MinFkTraces:
      problem = "an f-k needs " & $MinFkTraces & " traces at least; this record has " &
        $seed.len
  if problem.len > 0 or seed.len == 0:
    if problem.len == 0: problem = "the plot shows no trace"
    state.stampPick(w, k, i)
    state.blockPlot(w, i, problem)
    return true
  let s = state.sessions[i]
  var ids: seq[int] = @[]
  for t in seed: ids.add t + s.base
  template pw: untyped = state.plots[w]
  let pr = spectrumFilters(state.panels[k])
  if ids == pw.traces and pr == pw.processing:
    state.stampPick(w, k, i)
    return false
  let kept = pw.processing
  let oldTraces = pw.traces
  let oldFirst = pw.first
  let oldFile = pw.file
  let oldRecord = pw.record
  pw.file = s.name
  pw.record = s.recordText(seed[0])
  pw.traces = ids
  pw.first = seed[0]
  pw.processing = pr
  if state.askPlot(w):
    pw.filters = filtersText(pr)
    state.stampPick(w, k, i)
    return true
  pw.processing = kept
  pw.traces = oldTraces
  pw.first = oldFirst
  pw.file = oldFile
  pw.record = oldRecord
  false

proc filesHeldByFollow*(state: AppState): seq[SessionId] =
  ## Files an unfrozen window still shows, taken before it follows, so one
  ## it follows away from can be closed.
  result = @[]
  for w in state.plots:
    if not w.frozen and w.traces.len > 0:
      let i = state.findTrace(w.traces[0])
      if i >= 0: result.add state.sessions[i].id
  for w in state.spectra:
    if not w.frozen and w.traces.len > 0:
      let i = state.findTrace(w.traces[0])
      if i >= 0: result.add state.sessions[i].id

proc releaseFollowed*(state: var AppState; before: seq[SessionId]) =
  ## A file an unfrozen window has followed away from, which no panel shows
  ## and no window still uses, is closed.
  for id in before:
    if state.findSession(id) >= 0 and not state.panels.anyIt(it.layers.anyIt(it.shows(id))) and
        not state.plotsUse(id) and not state.spectraUse(id):
      let i = state.findSession(id)
      if i >= 0: state.closeSession(i, quiet = true)

proc stampSpectrum(state: var AppState; w, k, i: int) =
  ## Remembers what chose FFT window `spectra[w]`'s traces, so a later
  ## change of the selection, the record, the file or the sort asks again.
  template sw: untyped = state.spectra[w]
  template p: untyped = state.panels[k]
  sw.pickSession = int(state.sessions[i].id)
  sw.pickGather = if p.layers.len > 0: p.layers[0].source.gather else: -1
  sw.pickSelected = state.selection.selectedRevision
  sw.pickOrder = p.orderGen
  sw.pickSource = p.sourceGen
  sw.pickShown = p.shown.len

func spectrumMoved(state: AppState; w, k, i: int): bool =
  ## Whether the plot's choice of traces moved on since FFT window
  ## `spectra[w]` last followed it.
  template sw: untyped = state.spectra[w]
  template p: untyped = state.panels[k]
  let gather = if p.layers.len > 0: p.layers[0].source.gather else: -1
  sw.pickSession != int(state.sessions[i].id) or sw.pickGather != gather or
    sw.pickSelected != state.selection.selectedRevision or sw.pickOrder != p.orderGen or
    sw.pickSource != p.sourceGen or sw.pickShown != p.shown.len

proc blockSpectrum(state: var AppState; w, i: int; problem: string) =
  ## The FFT window stays open and says `problem`; nothing is asked.
  template sw: untyped = state.spectra[w]
  if not state.spectrumReader.isNil: state.spectrumReader.cancel(sw.id)
  let name = if i >= 0: state.sessions[i].name else: ""
  if sw.spectrum.problem == problem and sw.traces.len == 0 and not sw.waiting and sw.file == name:
    return
  sw.waiting = false
  sw.traces.setLen 0
  sw.file = name
  sw.record = ""
  sw.chosen = soNothing
  sw.spectrum = Spectrum(problem: problem)
  sw.since = state.spectrumGen + 1
  inc sw.revision

func timeNow(state: AppState; w, k: int): (float64, float64) =
  ## The time window FFT window `spectra[w]` follows, when it shows the
  ## plot's visible time; both NaN for the whole trace.
  template sw: untyped = state.spectra[w]
  let view = state.panels[k].view.timeMs
  if sw.display.time == stVisible and view.hi > view.lo: (view.lo, view.hi)
  else: (NaN, NaN)

proc followSpectrumFilters(state: var AppState; w, k: int) =
  ## FFT window `spectra[w]`, not frozen, follows the plot's filters and the
  ## kills of the traces it already shows, and the plot's visible time when
  ## that is what it shows. `sameFollow` is the comparison.
  template sw: untyped = state.spectra[w]
  if state.panels[k].layers.len == 0: return
  let pr = spectrumFilters(state.panels[k])
  let (_, _, revision) = state.killedNow(sw)
  var ownMoved = false
  var fileTraces: seq[int] = @[]
  var killed: seq[int] = @[]
  let i = state.findTrace(if sw.traces.len > 0: sw.traces[0] else: -1)
  if i >= 0:
    let s = state.sessions[i]
    for t in sw.traces:
      if t in s: fileTraces.add t - s.base
    killed = killedOf(state.editsAt(s.path), fileTraces)
    killed.sort()
    if revision != sw.editsSeen:
      ownMoved = ownKeyOf(state.editsAt(s.path), fileTraces) != sw.ownKey
  else:
    killed = sw.killed
  var timeMoved = false
  let window = state.timeNow(w, k)
  if not window[0].isNaN and (sw.visibleMs.lo != window[0] or sw.visibleMs.hi != window[1]):
    sw.visibleMs = Span(lo: window[0], hi: window[1])
    timeMoved = true
  let now = LiveKey(session: if i >= 0: state.sessions[i].id else: NoSession,
    traces: fileTraces, processing: pr, killed: killed)
  let was = LiveKey(session: now.session, traces: fileTraces, processing: sw.processing,
    killed: sw.killed)
  if not sameFollow(now, was) or ownMoved or timeMoved:
    let kept = sw.processing
    sw.processing = pr
    if not state.askAgain(w): sw.processing = kept # `askSpectrum` says the filters
  elif revision != sw.editsSeen:
    sw.editsSeen = revision

proc repickSpectrum(state: var AppState; w, k, i: int): bool =
  ## Chooses FFT window `spectra[w]`'s traces again from the plot (the
  ## selection in the record, else the traces in view) and asks; true when
  ## that replaced the filter follow. A record with nothing to show is said,
  ## and the window stays open.
  let (fileTraces, chosen, count) = state.liveTraces(k, i)
  if fileTraces.len == 0:
    state.stampSpectrum(w, k, i)
    state.blockSpectrum(w, i, "the plot shows no trace")
    return true
  let s = state.sessions[i]
  var ids = newSeq[int](fileTraces.len)
  for n, t in fileTraces: ids[n] = t + s.base
  template sw: untyped = state.spectra[w]
  let pr = spectrumFilters(state.panels[k])
  let window = state.timeNow(w, k)
  let timeSame = window[0].isNaN or
    (sw.visibleMs.lo == window[0] and sw.visibleMs.hi == window[1])
  if ids == sw.traces and pr == sw.processing and timeSame:
    state.stampSpectrum(w, k, i)
    return false
  let kept = sw.processing
  let oldTraces = sw.traces
  let oldFirst = sw.first
  let oldFile = sw.file
  let oldRecord = sw.record
  let oldChosen = sw.chosen
  let oldCount = sw.chosenCount
  let oldVisible = sw.visibleMs
  sw.file = s.name
  sw.record = s.recordText(fileTraces[0])
  sw.traces = ids
  sw.first = fileTraces[0]
  sw.chosen = chosen
  sw.chosenCount = count
  sw.processing = pr
  if not window[0].isNaN: sw.visibleMs = Span(lo: window[0], hi: window[1])
  if state.askAgain(w):
    state.stampSpectrum(w, k, i)
    return true
  sw.processing = kept
  sw.traces = oldTraces
  sw.first = oldFirst
  sw.file = oldFile
  sw.record = oldRecord
  sw.chosen = oldChosen
  sw.chosenCount = oldCount
  sw.visibleMs = oldVisible
  false

proc followSpectra(state: var AppState) =
  ## After every change: each FFT window not frozen follows the Seismic plot
  ## it was opened from, by the same pick as a New plot window. Opened on
  ## chosen traces, it keeps those until that pick changes. Then the
  ## selection in the record on show wins; with none, the traces in view.
  ## Frozen, it keeps the traces and the file it had.
  for w in 0 ..< state.spectra.len:
    template sw: untyped = state.spectra[w]
    if sw.id == LiveSpectrum or sw.frozen: continue
    let k = state.findPanel(sw.panel)
    if k < 0 or state.panels[k].layers.len == 0: continue
    let i = state.shownFile(k)
    if i < 0:
      state.blockSpectrum(w, -1, "the plot shows no file")
      continue
    if sw.heldOpen and not state.spectrumMoved(w, k, i):
      state.followSpectrumFilters(w, k)
    else:
      sw.heldOpen = false
      if not state.repickSpectrum(w, k, i): state.followSpectrumFilters(w, k)

proc followPlots(state: var AppState) =
  ## After every change: each New plot window not frozen follows the Seismic
  ## plot it was opened from, by the spectrum windows' follow (`sameFollow`),
  ## and each FFT window does the same (`followSpectra`). The selection in
  ## the record on show wins; with none, the view's own traces of that
  ## record. A new file is followed. Frozen, a window keeps the traces and
  ## the file it had. Filters and kills of the traces it shows are followed
  ## too, unless a repick already asked. A file followed away from is closed
  ## by the caller (`releaseFollowed`), once both have followed.
  state.followSpectra()
  for w in 0 ..< state.plots.len:
    template pw: untyped = state.plots[w]
    if pw.frozen: continue
    let k = state.findPanel(pw.panel)
    if k < 0 or state.panels[k].layers.len == 0: continue
    let i = state.shownFile(k)
    if i < 0: continue
    if state.pickChanged(w, k, i):
      if not state.repick(w, k, i): state.followFilters(w, k)
    else:
      state.followFilters(w, k)
