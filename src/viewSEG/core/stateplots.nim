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
  ## Whether an analysis window is of traces of open file `file`: then
  ## showing another file in the plot keeps it open.
  let i = state.findSession(file)
  if i < 0: return false
  let s = state.sessions[i]
  for w in state.plots:
    if w.traces.len > 0 and w.traces[0] in s: return true
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

proc traceDtMs(s: Session; index: int): float64 =
  ## The sample interval of trace `index`, in ms; 0 when it has none.
  if s.filePtr == nil or index notin 0 ..< s.filePtr[].len: return 0
  let k = s.filePtr[].traceKeys(index)
  let us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
           else: s.filePtr[].sampleIntervalUs(index)
  if us > 0 and us < Inf: us / 1000 else: 0

proc keptIntervalMs(s: Session; traces, killed: openArray[int]): float64 =
  ## The sample interval, in ms, of the first trace the analysis reader
  ## would keep: not killed, not dead, with an interval. 0 when it would
  ## keep none. The interval gate uses this, not `traces[0]`.
  if s.filePtr == nil: return 0
  let f = s.filePtr
  for t in traces:
    if t in 0 ..< f[].len and t notin killed and f[].traceKeys(t).status != tsDead:
      let dt = traceDtMs(s, t)
      if dt > 0: return dt
  0.0

const
  MaxCodeScan = 64 ## traces of a record whose identification codes are read on the UI thread
  FileReferenceName* = "This file's reference trace"
  NoFileReference* = "This record has no trace with trace identification code 21 " &
    "(the vibrator reference)."

proc fileReferencePlace(s: Session; g: int): int =
  ## The place, among the auxiliary traces of gather `g`, of its trace with the
  ## vibrator reference code (counted from 1); 0 when it has none.
  if g notin 0 ..< s.gathers.len or s.filePtr == nil: return 0
  var aux = 0
  let span = s.gathers[g].traces
  for t in span.a .. min(span.b, span.a + MaxCodeScan - 1): # the first traces only
    if t in 0 ..< s.filePtr[].len and not isSeismic(s.filePtr[].index, t):
      inc aux
      if s.filePtr[].traceKeys(t).traceCode == VibReferenceCode: return aux

proc fileReferenceRule(s: Session; g: int): PilotRule =
  ## The rule that takes the record's vibrator reference trace whole; `trace` 0 when
  ## the record has none.
  PilotRule(name: FileReferenceName, aux: true, trace: fileReferencePlace(s, g),
    startMs: 0, spanMs: 1e9)

proc hasFileReference*(state: AppState; w: int): bool =
  ## Whether window `plots[w]`'s record has a trace with the vibrator reference code (found
  ## when the window last asked, not at every frame).
  state.plots[w].fileRef

proc vibReferencePlace*(state: AppState; w: int): int =
  ## The place, among window `plots[w]`'s traces, of the one with the vibrator
  ## reference code; -1 when none has it.
  template pw: untyped = state.plots[w]
  result = -1
  if pw.traces.len == 0: return
  let i = state.findTrace(pw.traces[0])
  if i < 0 or state.sessions[i].filePtr == nil: return
  let s = state.sessions[i]
  for n, t in pw.traces:
    let local = t - s.base
    if result < 0 and local in 0 ..< s.filePtr[].len and
        s.filePtr[].traceKeys(local).traceCode == VibReferenceCode: result = n

proc pilotFollowKey(state: AppState; w: int): string =
  ## "" unless window `plots[w]` is a correlation (or an envelope) against the chosen
  ## pilot of the record; else its trace and what changes it: a reversal, a kill, its
  ## own filter.
  template pw: untyped = state.plots[w]
  if pw.view notin {avCorrelation, avEnvelope} or pw.traces.len == 0: return ""
  var rule = PilotRule()
  if pw.params.fileReference: rule.trace = -1 # the record's own
  else:
    if state.chosenRef.len == 0 or not state.refsLoaded: return ""
    let at = state.refs.findId(state.chosenRef)
    if at < 0 or not state.refs.entries[at].isPilot: return ""
    rule = pilotRuleOf(state.refs.entries[at])
  let i = state.findTrace(pw.traces[0])
  if i < 0: return ""
  let s = state.sessions[i]
  let e = state.editsAt(s.path)
  let g = s.gatherOf(pw.traces[0] - s.base)
  if pw.params.fileReference: rule = fileReferenceRule(s, g)
  if rule.trace < 1: return "none|" & NoFileReference
  let (rt, _, problem) = s.pilotOfRecord(g, rule, e)
  if rt < 0: return "none|" & problem
  $rt & "|" & pilotKeyOf(e, rt)

proc showCorrelationProblem(state: var AppState; w: int; problem, name: string) =
  ## The correlation window says `problem` and draws nothing. A later answer
  ## cannot put the old curves back.
  template pw: untyped = state.plots[w]
  if not state.analysisReader.isNil: state.analysisReader.cancel(pw.id)
  inc state.plotGen
  pw.asked = state.plotGen
  pw.waiting = false
  pw.result = AnalysisResult(view: avCorrelation, gen: state.plotGen, id: pw.id,
    problem: problem)
  pw.reference = name
  pw.archiveSeen = state.chosenRef
  pw.archiveRev = state.refsRev
  pw.pilotKey = state.pilotFollowKey(w)
  pw.since = state.plotGen
  if "no longer in the archive" in problem: pw.goneNote = problem
  else: pw.goneNote = ""
  inc pw.revision

proc correlationBlock(state: AppState; dtMs: float64): tuple[problem, name: string] =
  ## Why a correlation cannot use the chosen reference, and that reference's
  ## name when it has one. `problem` "" : it can, and `name` is it.
  if state.chosenRef.len == 0:
    return (NoReferenceChosen, "")
  if not state.refsLoaded:
    return ("the reference archive is still being read", state.chosenRef)
  let at = state.refs.findId(state.chosenRef)
  if at < 0:
    return (referenceGone(state.chosenRef), state.chosenRef)
  let e = state.refs.entries[at]
  if e.missing or e.blocked:
    return (referenceGone(e.name), e.name)
  if dtMs > 0 and e.intervalUs > 0:
    let rdt = e.intervalUs / 1000
    if abs(rdt - dtMs) > 1e-9 * max(rdt, dtMs):
      return (intervalRefusal(rdt, dtMs), e.name)
  ("", e.name)

proc chosenReferenceFor(state: var AppState; w: int; s: Session; dtMs: float64;
    edits: FileEdits; a: var AnalysisAsk): tuple[problem, name: string] =
  ## Window `plots[w]`'s chosen reference, for a correlation and an envelope
  ## alike: `a` is told which (a trace of the record by the rule, or an archive
  ## file) and the window's `reference` is its name; else the `problem` that
  ## it cannot be used (none chosen, gone, another interval, a record with no
  ## such trace) and the name it has.
  template pw: untyped = state.plots[w]
  if pw.params.fileReference:
    # the record's own reference trace, by the rule: no archive involved
    let local = pw.traces[0] - s.base
    let g = s.gatherOf(local)
    let rule = fileReferenceRule(s, g)
    if rule.trace < 1: return (NoFileReference, FileReferenceName)
    var records: seq[int] = @[]
    for t in pw.traces:
      if t in s:
        let gt = s.gatherOf(t - s.base)
        if gt notin records: records.add gt
    if records.len > 1:
      return ("These traces come from " & $records.len &
        " records; a record's reference trace needs traces of one record.", FileReferenceName)
    let (rt, record, problem) = s.pilotOfRecord(g, rule, edits)
    if problem.len > 0: return (problem, FileReferenceName)
    a.pilotTrace = rt
    a.pilotRule = rule
    a.pilotRecord = record
    a.pilotReversed = edits.has(teReversed, rt)
    a.pilotShiftMs = edits.shiftOf(rt)
    a.archiveName = FileReferenceName
    pw.reference = FileReferenceName
    return ("", FileReferenceName)
  let blocked = state.correlationBlock(dtMs)
  if blocked.problem.len > 0: return blocked
  let e = state.refs.entries[state.refs.findId(state.chosenRef)]
  if e.isPilot:
    # a trace of the record this window is of, by the rule: each record has
    # its own pilot, found from the keys already held
    let rule = pilotRuleOf(e)
    let local = pw.traces[0] - s.base
    var records: seq[int] = @[]
    for t in pw.traces:
      if t in s:
        let g = s.gatherOf(t - s.base)
        if g notin records: records.add g
    if records.len > 1:
      return ("These traces come from " & $records.len &
        " records; a record's pilot needs traces of one record.", e.name)
    let (rt, record, problem) = s.pilotOfRecord(s.gatherOf(local), rule, edits)
    if problem.len > 0: return (problem, e.name)
    a.pilotTrace = rt
    a.pilotRule = rule
    a.pilotRecord = record
    a.pilotReversed = edits.has(teReversed, rt)
    a.pilotShiftMs = edits.shiftOf(rt)
    a.archiveName = e.name
  else:
    a.archivePath = state.refsHome / e.file
    a.archiveName = e.name
    a.archiveIntervalUs = e.intervalUs
  pw.reference = e.name
  ("", e.name)

proc recordCodes(s: Session; g: int): seq[int16] =
  ## The identification codes of the traces of gather `g`, in order.
  if g notin 0 ..< s.gathers.len or s.filePtr == nil: return
  let span = s.gathers[g].traces
  for t in span.a .. min(span.b, span.a + MaxCodeScan - 1):
    result.add(if t in 0 ..< s.filePtr[].len: s.filePtr[].traceKeys(t).traceCode else: 0'i16)


func vibTopKey*(state: AppState; pw: AnalysisWindow): string =
  ## What the top frequency typed in vibrator window `pw` is kept under: the project
  ## reference's id when the window is measured against a stored one (a trace of each
  ## record, a pilot, is the recorded trace), else `RecordedKey` and the file layout (the
  ## key the roles use: the record's trace count and codes), so a file of another kind
  ## never takes a top typed for this one.
  result = RecordedKey
  if pw.traces.len > 0:
    let i = state.findTrace(pw.traces[0])
    if i >= 0:
      let s = state.sessions[i]
      let g = s.gatherOf(pw.traces[0] - s.base)
      if g in 0 ..< s.gathers.len:
        result = RecordedKey & " " & layoutKey(s.recordCodes(g), s.gathers[g].traces.len)
  if pw.params.projectReference and state.chosenRef.len > 0 and
      state.refsLoaded:
    let at = state.refs.findId(state.chosenRef)
    if at >= 0 and not state.refs.entries[at].isPilot: result = state.chosenRef

func vibTyped*(state: AppState; pw: AnalysisWindow): float64 =
  ## The top frequency typed for window `pw`'s reference: the window's own, else the one
  ## kept in the open project; NaN when none is.
  let key = state.vibTopKey(pw)
  result = pw.params.tops.topOf(key)
  if result.isNaN and state.inProject:
    result = topsOf(state.project.doc.vibTops).topOf(key)

proc vibProfileOf*(state: AppState; w: AnalysisWindow): VibQcProfile =
  ## Vibrator window `w`'s settings as a profile: the limits, window, harmonics, set, the
  ## force scale in force, a typed 100 % force and drive level, the chosen reference's
  ## archive id and the top typed for it. Nothing read from the file but its name.
  let p = w.params
  let refId = if p.projectReference and state.chosenReference.len > 0:
      state.chosenReference
    else: ""
  let key = state.vibTopKey(w)
  var top = p.tops.topOf(key)
  if top.isNaN and state.inProject: top = topsOf(state.project.doc.vibTops).topOf(key)
  profileOf(p.qc, p.qcWindowMs, p.harmonics, p.accelSet, state.settings.forceScale,
    p.forceHundredPct, p.targetPct, refId, top, p.forceHundredUnit, p.forceHundredSet,
    w.file, p.roles.judge, p.reactionMassKg, p.baseplateMassKg, p.forceHundredWeighted)

proc signatureAsk(state: AppState; s: Session; p: AnalysisParams): SignatureAsk =
  ## What a signature file adds to the Vibrator window's ask: the user's force scale (the
  ## ground force in newtons, display and verdict only), the 100 % force the file itself
  ## gives, and the controller's QC record (a `.vib`'s through its pair).
  let f = s.signature
  result = SignatureAsk(given: true, isDat: f.kind == sgDat,
    setA: f.kind == sgVib and p.accelSet == asA)
  let scale = state.settings.forceScale
  # (a drive level nobody typed is NaN: the default 100 gives no 100 % force)
  result.applyFileScale(f.kind, scale.datCountsPerLbf, scale.vibAccMvPerCount,
    f.info.weights, p.accelSet == asA, f.qc.valid, f.qc.targetForceLbf, p.targetPct)
  case f.kind
  of sgDat:
    if f.qc.valid:
      result.ctlFrom = "this file"
      result.ctl = f.qc.brief
      result.ctl.valid = true
      result.correlationStored = f.qc.correlationStored
      result.correlationLagZero = f.qc.correlationLagZero
  of sgVib:
    if f.pair.len > 0 and f.pairQc.valid:
      result.ctlFrom = "the .dat of this sweep"
      result.ctl = f.pairQc
  of sgNone: discard

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
      labels.add(if s.isSignature and t - s.base in 0 ..< s.signature.traces.len:
        s.signature.traces[t - s.base].name else: "trace " & $(t - s.base + 1))
  if pw.view in {avCorrelation, avEnvelope}:
    pw.fileRef = fileReferencePlace(s, s.gatherOf(pw.traces[0] - s.base)) > 0
  var a = AnalysisAsk(id: pw.id, view: pw.view, params: pw.params, file: s.filePtr,
    correlated: s.correlatedView, path: s.path, size: s.size, traces: traces, names: labels,
    processing: pw.processing)
  pw.sweep = identityOf(s.signature)
  if s.isSignature:
    a.forceNote = signatureForceNote(s.signature)
    a.sig = state.signatureAsk(s, pw.params)
  # the unit of the file's distances: as imported, else what its headers say
  let joined = state.joinedOf(s.id)
  let imported = joined >= 0 and state.joins[joined].units.file != suNotGiven
  a.unit = if imported: state.joins[joined].units.file else: headerUnitOf(s.crs)
  # the offsets' unit: the import's when joined, else the header's measurement system
  a.offsetUnit = if imported: state.joins[joined].units.file else: offsetUnitOf(s.crs)
  let edits = state.editsAt(s.path)
  var killed = if pw.frozen: pw.killed else: killedOf(edits, traces)
  if pw.view in {avCorrelation, avEnvelope}:
    # the chosen reference only: none, gone, or another interval is said (a
    # correlation then draws nothing, no auxiliary trace, no first trace; an
    # envelope draws the trace's own phase). The interval is the first trace
    # the reader would keep, not a killed or dead traces[0].
    let dtMs = keptIntervalMs(s, traces, killed)
    var blocked: tuple[problem, name: string] = ("", "")
    if pw.view == avCorrelation or state.chosenRef.len > 0 or pw.params.fileReference:
      blocked = state.chosenReferenceFor(w, s, dtMs, edits, a)
    if pw.view == avCorrelation and blocked.problem.len > 0:
      state.showCorrelationProblem(w, blocked.problem, blocked.name)
      return true
    if pw.view == avEnvelope:
      a.notUsed = blocked.problem
      pw.reference = if blocked.problem.len > 0: "" else: blocked.name
  elif pw.view == avVibrator and not (pw.params.projectReference and state.chosenRef.len > 0):
    # the Ref role's recorded trace is the reference, and the window says why
    a.vibWhy = if state.chosenRef.len == 0: "no project reference is chosen"
               else: "the project reference is not used"
  elif pw.view == avVibrator and state.chosenRef.len > 0 and
      state.refsLoaded and state.refs.findId(state.chosenRef) >= 0 and
      state.refs.entries[state.refs.findId(state.chosenRef)].isPilot:
    a.extraNote = "Reference: " & state.refs.entries[state.refs.findId(state.chosenRef)].name &
      " is a trace of each record; the file's own pilot is used."
  elif pw.view == avVibrator and state.chosenRef.len > 0:
    # an archive reference stands in for the file's pilot
    if not state.refsLoaded:
      a.archiveGone = "the reference archive is still being read"
      a.archiveName = state.chosenRef
    else:
      let at = state.refs.findId(state.chosenRef)
      if at < 0:
        a.archiveGone = "the reference \"" & state.chosenRef &
          "\" is no longer in the archive"
        a.archiveName = state.chosenRef
      elif state.refs.entries[at].missing:
        a.archiveGone = "the reference \"" & state.refs.entries[at].name &
          "\" is no longer in the archive (its file is missing)"
        a.archiveName = state.refs.entries[at].name
      else:
        let e = state.refs.entries[at]
        a.archivePath = state.refsHome / e.file
        a.archiveName = e.name
        a.archiveIntervalUs = e.intervalUs
        a.archiveStartMs = e.timeStart
        if e.origin.generated: a.exactTopHz = max(e.origin.f1Hz, e.origin.f2Hz)
    a.refName = a.archiveName & " (archive)"
    pw.reference = a.refName
  if pw.view == avVibrator:
    a.topHz = state.vibTyped(pw)
  if pw.view == avVibrator and pw.params.roles.source == rsCodes:
    a.extraNote = (if a.extraNote.len > 0: a.extraNote & "; " else: "") &
      "roles taken from the trace identification codes"
  if not state.jobs.hold(s.path): return false
  # frozen: the kills it was frozen with; else the plot's now
  killed.sort()
  a.killed = killed
  if not pw.frozen:
    pw.own = ownOfTraces(edits, traces)
    pw.shifts = shiftsOfTraces(edits, traces)
    pw.reversed = reversedOf(edits, traces)
    pw.allReversed = edits.allReversed
    pw.ownKey = ownKeyOf(edits, traces)
  a.own = pw.own
  a.shifts = pw.shifts
  a.reversed = pw.reversed
  a.allReversed = pw.allReversed
  inc state.plotGen
  a.gen = state.plotGen
  pw.asked = state.plotGen
  pw.waiting = true
  pw.killed = killed
  pw.editsSeen = edits.revision
  inc pw.asks
  inc pw.revision
  state.analysisReaderFor(s.path).ask a
  if pw.view in {avCorrelation, avEnvelope, avVibrator}:
    pw.archiveSeen = state.chosenRef
    pw.archiveRev = state.refsRev
  pw.pilotKey = state.pilotFollowKey(w)
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

proc codeRolesIn(s: Session; fileTraces: openArray[int]; roles: VibRoles;
    accelSet = asB): (bool, VibRoles) =
  ## `roles` with the places the identification codes of `fileTraces` (indices in `s`'s
  ## file, the window's order) give, and whether they gave any. For a `.vib` judged on set A
  ## its codes (258, 257, 267) stand for the reaction mass, baseplate and ground force, and
  ## set B's own codes are not looked at.
  var codes: seq[int16] = @[]
  for t in fileTraces:
    codes.add(if t in 0 ..< s.filePtr[].len: s.filePtr[].traceKeys(t).traceCode else: 0'i16)
  if accelSet == asA and s.signature.kind == sgVib:
    for c in codes.mitems:
      c = case c
        of VibSetAMassCode: VibReactionMassCode
        of VibSetABaseplateCode: VibBaseplateCode
        of VibSetAGroundForceCode: VibGroundForceCode
        of VibReactionMassCode, VibBaseplateCode, VibGroundForceCode: 0'i16
        else: c
  var plain = roles
  (plain.source, plain.handFile) = (rsPosition, "")
  let r = plain.withCodeRoles(codes, "")
  (r.source == rsCodes, r)

proc shapeOpened(state: AppState; view: AnalysisView; i: int; traces: var seq[int];
    order: openArray[int] = []) =
  ## The traces a new window of `view` is opened on, from the ones chosen:
  ## an envelope or a phase spectrum keeps the first; a vibrator signature
  ## opened on one takes the record's next three; an f-k opened on fewer
  ## than `MinFkTraces` takes the record's seismic traces; more than
  ## `MaxPlotTraces` are cut down (an f-k: the first, side by side; another
  ## view: spread evenly). `order`, when given, is the plot's order of the record
  ## (`gatherOrder`): the record an f-k takes is in it, not in the file's.
  if traces.len == 0 or i < 0: return
  let s = state.sessions[i]
  if view in {avEnvelope, avPhase} and traces.len > 1: traces.setLen 1
  if view == avVibrator:
    if traces.len == 1:
      let g = s.gatherOf(traces[0])
      if g in 0 ..< s.gathers.len:
        let record = s.gathers[g].traces
        if traces[0] in record:
          # A record with the vibrator's codes (in its first traces) opens the window on its
          # coded traces, whichever trace was chosen, then the traces after the first of
          # them up to the cap, so any trace of the group can be picked for a role; else the
          # chosen trace and the next three.
          var coded: seq[int] = @[]
          for t in record.a .. min(record.b, record.a + MaxCodeScan - 1):
            let c = s.filePtr[].traceKeys(t).traceCode
            if c in VibReactionMassCode .. VibReferenceCode and coded.len < MaxVibratorTraces:
              coded.add t
          let (isCoded, _) = s.codeRolesIn(coded, VibRoles())
          if isCoded:
            var t = coded[0]
            # (a signature file's window holds its four coded traces: the rest are other
            # channels, not candidates for a role)
            while not s.isSignature and coded.len < MaxVibratorTraces and t <= record.b:
              if t notin coded: coded.add t
              inc t
            coded.sort()
            traces = coded
          else:
            for t in traces[0] + 1 .. min(traces[0] + 3, record.b): traces.add t
    if traces.len > MaxVibratorTraces: traces.setLen MaxVibratorTraces
  if view == avFk:
    if traces.len < MinFkTraces:
      let g = s.gatherOf(traces[0])
      if g in 0 ..< s.gathers.len:
        var record: seq[int] = @[]
        var src = @order
        if src.len == 0:
          for t in s.gathers[g].traces: src.add t
        for t in src:
          if isSeismic(s.filePtr[].index, t): record.add t
        if record.len >= MinFkTraces: traces = record
    if traces.len > MaxPlotTraces: traces.setLen MaxPlotTraces
  if traces.len > MaxPlotTraces:
    var kept: seq[int] = @[]
    for j in evenly(traces.len, MaxPlotTraces): kept.add traces[j]
    traces = kept

proc accelSetTraces(s: Session; traces: seq[int]; accelSet: AccelSet): seq[int] =
  ## The traces (indices in `s`'s file) of a `.vib`'s Vibrator window judging `accelSet`: for
  ## set B what it holds already; for set A the reference and the three traces of set A of the
  ## same record, in the file's order. Unchanged when a trace of the set is missing.
  result = traces
  if accelSet == asB or s.signature.kind != sgVib or traces.len == 0: return
  let g = s.gatherOf(traces[0])
  if g notin 0 ..< s.gathers.len: return
  let record = s.gathers[g].traces
  var found: seq[int] = @[]
  for t in record.a .. min(record.b, record.a + MaxCodeScan - 1):
    if s.filePtr[].traceKeys(t).traceCode in [VibReferenceCode, VibSetAMassCode,
        VibSetABaseplateCode, VibSetAGroundForceCode]: found.add t
  if found.len == 4: result = found

proc rolesOf(state: AppState; s: Session; fileTraces: openArray[int]; roles: VibRoles;
    file: string; accelSet = asB): VibRoles =
  ## `roles` of a vibrator signature on `fileTraces` (indices in `s`'s file, the
  ## window's order) of `file`. A choice made by hand on this file stays. Else a choice
  ## remembered for this file layout (the record's trace count and codes) applies; else
  ## the identification codes give them when they are the vibrator's; else the roles are
  ## as they were (the window's order at first).
  result = roles
  if s.isSignature:
    # The channels are named by the file: the codes decide, never a remembered layout or a
    # hand-made choice (the polarity the user chose stays).
    let (found, byCodes) = s.codeRolesIn(fileTraces, roles, accelSet)
    if found: result = byCodes
    # the polarity the user chose for this file layout comes back (the places are the codes');
    # Automatic is never offered here, and M and B have no polarity of their own
    result.massPolarity = poAsRecorded
    result.judge = joRecorded # (what the kind does unless the switch was set for this layout)
    if fileTraces.len > 0:
      let g = s.gatherOf(fileTraces[0])
      var places: array[4, int]
      var polarity = Recorded
      if g in 0 ..< s.gathers.len and state.vibLayouts.choiceFor(
          layoutKey(s.recordCodes(g), s.gathers[g].traces.len), places, polarity):
        result.groundForcePolarity = polarity.gf
        result.judge = polarity.judge
    if result.groundForcePolarity == poAutomatic: result.groundForcePolarity = poAsRecorded
    return
  if fileTraces.len == 0 or roles.source == rsHand and roles.handFile == file: return
  let g = s.gatherOf(fileTraces[0])
  if g notin 0 ..< s.gathers.len: return
  let key = layoutKey(s.recordCodes(g), s.gathers[g].traces.len)
  var places: array[4, int]
  var polarity = Recorded
  if state.vibLayouts.choiceFor(key, places, polarity):
    let first = s.gathers[g].traces.a
    var mapped: array[4, int]
    var reachable = true
    for i in 0 ..< 4:
      mapped[i] = if places[i] < 0: -1 else: fileTraces.find(first + places[i])
      if places[i] >= 0 and mapped[i] < 0: reachable = false
    if reachable: # a remembered choice is used only when the window holds all its traces
      (result.reference, result.groundForce, result.mass, result.baseplate) =
        (mapped[0], mapped[1], mapped[2], mapped[3])
      (result.source, result.handFile) = (rsRemembered, "")
      # the polarity chosen with them comes back too (a choice kept before polarities
      # were, or left as recorded, is as recorded)
      (result.groundForcePolarity, result.massPolarity, result.judge) = (polarity.gf,
        polarity.mb, polarity.judge)
      return
  let (found, byCodes) = s.codeRolesIn(fileTraces, roles)
  if found: result = byCodes
  elif roles.source in {rsRemembered, rsCodes}:
    # what another file's codes or another layout's choice gave does not carry over
    (result.reference, result.groundForce, result.mass, result.baseplate) = (0, 1, 2, 3)
    result.source = rsPosition

proc vibWindowFile(state: AppState; w: int): int =
  ## The index of the open file window `plots[w]` is of; -1 when none.
  if state.plots[w].traces.len == 0: -1 else: state.findTrace(state.plots[w].traces[0])

proc codeRoles*(state: AppState; w: int): VibRoles =
  ## Window `plots[w]`'s roles as its traces' identification codes give them: with
  ## `source` `rsCodes` when they do, else the window's roles unchanged.
  result = state.plots[w].params.roles
  let i = state.vibWindowFile(w)
  if i < 0: return
  let s = state.sessions[i]
  var local: seq[int] = @[]
  for t in state.plots[w].traces: local.add t - s.base
  let (found, r) = s.codeRolesIn(local, result, state.plots[w].params.accelSet)
  if found: result = r

proc projectChanged(state: var AppState)

proc persistVibLayouts(state: var AppState; origin: CommandOrigin) =
  ## `vibLayouts` kept in the project when one is open, else in the settings, when the
  ## user made the change (`keeps`).
  if state.inProject:
    if keeps(origin) and not state.project.readOnly:
      state.project.doc.vibRoles = state.vibLayouts
      state.projectChanged()
    elif keeps(origin) and state.project.readOnly:
      state.log.add(sevWarning, "vibrator signature", "The project is read-only: the roles " &
        "chosen are remembered for this run only.")
  else:
    let kept = state.vibLayouts
    state.change(origin, st): st.vibRoles = kept

proc rememberRoles(state: var AppState; w: int; roles: VibRoles; origin: CommandOrigin) =
  ## The roles of window `plots[w]`, chosen by hand, are remembered for the layout of its
  ## record: in the project, else the settings, for every later file of that layout.
  let i = state.vibWindowFile(w)
  if i < 0: return
  let s = state.sessions[i]
  let g = s.gatherOf(state.plots[w].traces[0] - s.base)
  if g notin 0 ..< s.gathers.len: return
  let first = s.gathers[g].traces.a
  var places: array[4, int]
  for n, p in [roles.reference, roles.groundForce, roles.mass, roles.baseplate]:
    places[n] = if p in 0 ..< state.plots[w].traces.len:
                  state.plots[w].traces[p] - s.base - first
                else: -1
  state.vibLayouts = state.vibLayouts.withChoice(layoutKey(s.recordCodes(g), s.gathers[
      g].traces.len), places, ChosenPolarity(gf: roles.groundForcePolarity,
        mb: roles.massPolarity, judge: roles.judge))
  state.persistVibLayouts(origin)

proc rememberSigPolarity(state: var AppState; w: int; polarity: Polarity; judge: JudgeOn;
    origin: CommandOrigin) =
  ## The ground force's polarity and the ground force switch chosen on a signature file's
  ## window are remembered for its layout (in the project, else the settings): the places are the codes' own, so the
  ## record's trace of Ref, GF, M and B is the one with code 21, 20, 18 and 19.
  let i = state.vibWindowFile(w)
  if i < 0: return
  let s = state.sessions[i]
  let g = s.gatherOf(state.plots[w].traces[0] - s.base)
  if g notin 0 ..< s.gathers.len: return
  let record = s.gathers[g].traces
  var places = [-1, -1, -1, -1]
  for t in record.a .. min(record.b, record.a + MaxCodeScan - 1):
    case s.filePtr[].traceKeys(t).traceCode
    of VibReferenceCode: (if places[0] < 0: places[0] = t - record.a)
    of VibGroundForceCode: (if places[1] < 0: places[1] = t - record.a)
    of VibReactionMassCode: (if places[2] < 0: places[2] = t - record.a)
    of VibBaseplateCode: (if places[3] < 0: places[3] = t - record.a)
    else: discard
  state.vibLayouts = state.vibLayouts.withChoice(layoutKey(s.recordCodes(g), record.len),
    places, ChosenPolarity(gf: polarity, judge: judge))
  state.persistVibLayouts(origin)

proc forgetRoles(state: var AppState; w: int; origin: CommandOrigin) =
  ## The choice remembered for window `plots[w]`'s layout goes ("Roles from the codes").
  let i = state.vibWindowFile(w)
  if i < 0: return
  let s = state.sessions[i]
  let g = s.gatherOf(state.plots[w].traces[0] - s.base)
  if g notin 0 ..< s.gathers.len: return
  let before = state.vibLayouts.len
  state.vibLayouts = state.vibLayouts.withoutChoice(layoutKey(s.recordCodes(g), s.gathers[g].traces.len))
  if state.vibLayouts.len != before: state.persistVibLayouts(origin)

proc codeWordsOf(state: AppState; w: AnalysisWindow; n: int): string =
  ## The identification code in words of window `w`'s trace number `n` ("vibrator
  ## baseplate (19)"); "" when it has none.
  let i = state.findTrace(w.traces[n])
  if i >= 0 and state.sessions[i].filePtr != nil:
    let local = w.traces[n] - state.sessions[i].base
    if local in 0 ..< state.sessions[i].filePtr[].len:
      result = traceIdText(int(state.sessions[i].filePtr[].traceKeys(local).traceCode))

proc vibConverter*(state: AppState; w: AnalysisWindow): bool =
  ## Whether window `w`'s traces are laid out as the external converter's SEG-Y from a
  ## signature file lays them out (`isConverterLayout`).
  var codes: seq[int16] = @[]
  for n in 0 ..< min(w.traces.len, 4):
    let i = state.findTrace(w.traces[n])
    let local = if i >= 0: w.traces[n] - state.sessions[i].base else: -1
    if i >= 0 and state.sessions[i].filePtr != nil and
        local in 0 ..< state.sessions[i].filePtr[].len:
      codes.add state.sessions[i].filePtr[].traceKeys(local).traceCode
  isConverterLayout(codes)

proc vibTraceNames*(state: AppState; w: AnalysisWindow): seq[string] =
  ## The window's traces as the vibrator signature's pickers list them: "trace 7 · code
  ## 30 (not in the standard)", "trace 1 · vibrator reference (21)"; the number alone
  ## for a trace without a code.
  result = state.traceNames(w)
  for n in 0 ..< w.traces.len:
    let said = state.codeWordsOf(w, n)
    if said.len > 0: result[n] = result[n] & " · " & said

proc rememberedNotUsed(state: AppState; w: AnalysisWindow): bool =
  ## Whether a choice is remembered for the layout of `w`'s record that the window does not
  ## use (it does not hold all the traces the choice names).
  if w.traces.len == 0: return false
  let i = state.findTrace(w.traces[0])
  if i < 0: return false
  let s = state.sessions[i]
  let g = s.gatherOf(w.traces[0] - s.base)
  if g notin 0 ..< s.gathers.len: return false
  var places: array[4, int]
  state.vibLayouts.choiceFor(layoutKey(s.recordCodes(g), s.gathers[g].traces.len), places)

proc vibForceNote*(state: AppState; w: int): string =
  ## For a vibrator window of a signature file (plot `w`): what its ground force and masses
  ## are, in words ("M and B are forces already ..."); "" for any other file.
  if w < 0 or w >= state.plots.len: return
  let i = state.vibWindowFile(w)
  if i >= 0 and state.sessions[i].isSignature:
    result = signatureForceNote(state.sessions[i].signature)

proc vibSignature*(state: AppState; w: int): SignatureKind =
  ## Which signature file plot `w` (a Vibrator window) is of; `sgNone` for any other file.
  if w < 0 or w >= state.plots.len: return sgNone
  let i = state.vibWindowFile(w)
  if i >= 0: state.sessions[i].signature.kind else: sgNone

proc vibWeights*(state: AppState; w: int): VibWeights =
  ## The header's weights and sensitivities of the `.vib` plot `w` is of (NaN for any other
  ## file).
  if state.vibSignature(w) == sgVib: state.sessions[state.vibWindowFile(w)].signature.info.weights
  else: VibWeights()

proc vibWeightFindings*(state: AppState): FleetWeights =
  ## The `.vib` header weights of the listed folder, per vibrator (the `.dat` of the sweep tells
  ## which, when it is listed): a vibrator whose sweeps state different weights, or whose weights
  ## differ from those the others state, is flagged (`vibratorWords`). Nothing is corrected.
  var sweeps: seq[tuple[vibrator: int; weights: VibWeights]] = @[]
  for e in state.files.entries:
    if e.kind == fkVib and e.sweep.problem.len == 0:
      var v = 0
      let partner = state.files.pairs.getOrDefault(e.path)
      if partner.len > 0:
        let d = state.files.find(partner)
        if d >= 0 and state.files.entries[d].kind == fkDat:
          v = state.files.entries[d].sweep.vibrator
      sweeps.add (v, e.sweep.weights)
  perVibrator(sweeps)

proc vibChoiceNotes*(state: AppState; w: AnalysisWindow): string =
  ## What the user chose on a signature file's window, in words ("; accelerometer set A, by your
  ## choice; GF reversed for the analysis: your choice"); "" for none, and for any other file.
  let at = if w.traces.len > 0: state.findTrace(w.traces[0]) else: -1
  if at < 0 or not state.sessions[at].isSignature: return
  if state.sessions[at].signature.kind == sgVib and w.params.accelSet == asA:
    result.add "; accelerometer set A, by your choice"
  if w.params.roles.groundForcePolarity == poReversed:
    result.add "; GF reversed for the analysis: your choice"

proc vibRolesLine*(state: AppState; w: AnalysisWindow; long = true): string =
  ## Where each role of a vibrator signature comes from, in one line. `long`: "Reference:
  ## trace 1 (vibrator reference, 21) · Ground force: trace 4 (...) · Mass: ... ·
  ## Baseplate: ... — from the trace identification codes"; else the short form "Ref
  ## trace 1 · GF trace 4 · M trace 3 · B trace 2 — from the trace identification codes".
  let names = state.traceNames(w)
  for (role, short, place) in [("Reference", "Ref", w.params.roles.reference),
      ("Ground force", "GF", w.params.roles.groundForce), ("Mass", "M", w.params.roles.mass),
      ("Baseplate", "B", w.params.roles.baseplate)]:
    if result.len > 0: result.add " · "
    result.add(if long: role & ": " else: short & " ")
    if place in 0 ..< names.len:
      result.add names[place]
      let said = state.codeWordsOf(w, place)
      if long and said.len > 0: result.add " (" & said & ")"
    else: result.add "none"
  result.add " — " & (case w.params.roles.source
    of rsPosition: "in the window's order"
    of rsCodes: "from the trace identification codes"
    of rsHand: "chosen by hand"
    of rsRemembered: "remembered for this file layout")
  let sigAt = if w.traces.len > 0: state.findTrace(w.traces[0]) else: -1
  if long: result.add state.vibChoiceNotes(w)
  if w.params.roles.source in {rsPosition, rsCodes} and state.rememberedNotUsed(w) and
      not (sigAt >= 0 and state.sessions[sigAt].isSignature):
    result.add "; the choice remembered for this file layout is not used: some of its " &
      "traces are not in the window"

func plotsCanOpen*(state: AppState; panel: PanelId): bool =
  ## Whether the analysis windows (FFT, New plot) can be opened on `panel`: it
  ## shows a file. Nothing else is needed: with no trace selected they open
  ## and say what to click.
  let k = state.findPanel(panel)
  k >= 0 and state.shownFile(k) >= 0

proc blockPlot(state: var AppState; w, i: int; problem: string; awaiting = false)

proc openEmptyPlot(state: var AppState; cmd: Command; k, i: int) =
  ## A new analysis window with no trace to show (none is selected or under the
  ## pointer): it opens and says what to click, and follows the plot, so a
  ## selection fills it without reopening it.
  template p: untyped = state.panels[k]
  let params = if cmd.plotParams == AnalysisParams():
                 state.settings.plotOptions.applied(cmd.plotView, cmd.plotParams)
               else: cmd.plotParams
  state.plots.add AnalysisWindow(id: freePlotId(state.plots), view: cmd.plotView,
    params: params, panel: p.id, file: state.sessions[i].name, processing: spectrumFilters(p),
    since: state.plotGen + 1)
  state.plots[^1].filters = filtersText(state.plots[^1].processing)
  state.blockPlot(state.plots.high, i, awaitingWords(cmd.plotView), awaiting = true)
  state.stampPick(state.plots.high, k, i)

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
  let problem = settingProblem(cmd.plotParams, cmd.plotView, state.sessions[i].isSignature)
  if problem.len > 0:
    state.ignore(cmd, problem)
    return
  let s = state.sessions[i]
  var ids = cmd.plotTraces
  if ids.len == 0 and cmd.plotView == avOrientation:
    # the traces the plot shows, in its order, whatever is selected
    for t in state.gatherOrder(k, i): ids.add t + s.base
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
  if traces.len == 0 and ids.len == 0:
    state.openEmptyPlot(cmd, k, i)
    return
  if traces.len == 0:
    state.ignore(cmd, "none of the traces is in " & s.name)
    return
  if cmd.plotView == avFk and traces.len >= MinFkTraces and traces.len > MaxPlotTraces:
    # the first ones, side by side: taken evenly, their spacing would not be
    state.log.add(sevInfo, s.name, "An f-k of the first " & $MaxPlotTraces & " of the " &
      $traces.len & " traces.")
  let order = state.gatherOrder(k, i)
  if cmd.plotView == avFk:
    # the rows go in the order the plot shows, whatever chose them, so the sign
    # of a dip does not depend on how the window was opened
    var rank = initTable[int, int]()
    for j, t in order: rank[t] = j
    traces = traces.sortedByIt(rank.getOrDefault(it, order.len))
  state.shapeOpened(cmd.plotView, i, traces, order)
  if cmd.plotView == avVibrator and s.isSignature:
    traces = s.accelSetTraces(traces, cmd.plotParams.accelSet)
  template p: untyped = state.panels[k]
  # Settings not given (the built-in ones) open with the options last used for the kind
  let params = if cmd.plotParams == AnalysisParams():
                 state.settings.plotOptions.applied(cmd.plotView, cmd.plotParams)
               else: cmd.plotParams
  var w = AnalysisWindow(id: freePlotId(state.plots), view: cmd.plotView,
    params: params, panel: p.id, file: s.name, record: s.recordText(traces[0]),
    traces: traces.mapIt(it + s.base), first: traces[0], processing: spectrumFilters(p),
    since: state.plotGen + 1)
  w.filters = filtersText(w.processing)
  if w.view == avVibrator:
    if s.signature.kind != sgVib: w.params.accelSet = asB
    if s.isSignature and cmd.plotParams.forceHundredPct.isNaN:
      # a typed 100 % force is its window's: the file's own 100 % is never hidden by a
      # remembered number
      (w.params.forceHundredPct, w.params.forceHundredUnit) = (NaN, "")
    if s.isSignature and cmd.plotParams.targetPct == AnalysisParams().targetPct:
      # so is the drive level: a signature file's window opens with none typed (the box
      # empty), unless the command gives one other than the built-in 100
      w.params.targetPct = NaN
    w.params.forceHundredSet = w.params.accelSet
    if s.isSignature and state.inProject and state.project.doc.hasVibProfile and
        cmd.plotParams == AnalysisParams():
      # a window opened on a file starts from the project's vibrator QC profile, so two
      # windows agree and one cannot wipe what the other set
      let p = state.project.doc.vibProfile
      w.params.qc = p.limits
      (w.params.qcWindowMs, w.params.harmonics) = (p.qcWindowMs, p.harmonics)
      if s.signature.kind == sgVib: w.params.accelSet = p.accelSet
      (w.params.forceHundredPct, w.params.forceHundredUnit) = (p.forceHundredPct,
        p.forceHundredUnit)
      w.params.forceHundredSet = if p.forceHundredSetKnown: p.forceHundredSet
        else: w.params.accelSet
      w.params.targetPct = p.targetPct
    if samePlaces(cmd.plotParams.roles, VibRoles()):
      w.params.roles = state.rolesOf(s, traces, w.params.roles, s.name, w.params.accelSet)
    else: # the command names the places: that is a choice made on this file
      w.params.roles.source = rsHand
      w.params.roles.handFile = s.name
    if state.inProject:
      # the top frequencies typed in this project come with the window
      for t in topsOf(state.project.doc.vibTops):
        w.params.tops = w.params.tops.withTop(t.reference, t.hz)
  state.plots.add w
  if not state.askPlot(state.plots.high):
    state.plots.delete state.plots.high
    state.ignore(cmd, s.name & " is busy (a job needs it to itself)")
    return
  state.stampPick(state.plots.high, k, i)
  if outside > 0:
    state.log.add(sevWarning, s.name, $outside & " of the traces given are not in " & s.name &
      ": left out of the plot.")

proc keepVibProfile(state: var AppState; had, now: VibQcProfile) =
  ## Writes into the project's vibrator QC profile the settings that differ between
  ## `had` and `now` (one window's before and after a change); with no profile yet,
  ## `now` is the profile. The change is said in Messages once it has settled.
  let hasOne = state.project.doc.hasVibProfile
  let stored = state.project.doc.vibProfile
  let next = if hasOne: merged(stored, had, now) else: now
  if hasOne and next == stored: return
  if state.profileNoteAt == MonoTime(): state.profileNoteBase = stored
  state.profileNoteAt = getMonoTime()
  state.profileNoteFile = now.fromFile
  state.project.doc.vibProfile = next
  state.project.doc.vibProfile.later = stored.later
  state.project.doc.hasVibProfile = true
  state.projectChanged()

proc showPlot(state: var AppState; cmd: Command) =
  ## `ckPlotDisplay`: an analysis window's settings, and whether it is
  ## frozen; asked again when a setting changed (from the samples, once
  ## read: nothing else follows a frozen window).
  let w = state.findPlot(cmd.plot)
  if w < 0:
    state.ignore(cmd, "there is no plot window " & $cmd.plot)
    return
  template pw: untyped = state.plots[w]
  let sigFile = if pw.view == avVibrator: state.vibWindowFile(w) else: -1
  let signature = sigFile >= 0 and state.sessions[sigFile].isSignature
  let problem = settingProblem(cmd.plotParams, pw.view, signature)
  if problem.len > 0:
    state.ignore(cmd, problem)
    return
  var params = cmd.plotParams
  if signature:
    # a signature file's window: the codes decide the places (the user picks no trace), the
    # accelerometer set is the window's own choice, and the ground force's polarity is as
    # recorded unless the user reverses it, which is remembered for the file layout
    let s = state.sessions[sigFile]
    let had = pw.params.roles
    if s.signature.kind != sgVib: params.accelSet = asB
    if params.accelSet != pw.params.accelSet:
      var local: seq[int] = @[]
      for t in pw.traces: local.add t - s.base
      if params.accelSet == asB:
        # back to set B: the record's coded traces, as a window opens on them
        var seed = @[local[0]]
        state.shapeOpened(avVibrator, sigFile, seed)
        local = seed
      else:
        let before = local
        local = s.accelSetTraces(local, asA)
        if local == before:
          params.accelSet = asB
          state.log.add(sevWarning, s.name, "This record has no accelerometer set A: the " &
            "window keeps set B.")
      if params.accelSet != pw.params.accelSet:
        pw.traces = local.mapIt(it + s.base)
        pw.first = local[0]
        pw.record = s.recordText(local[0])
    var pol = params.roles.groundForcePolarity
    if pol == poAutomatic:
      pol = poAsRecorded
      state.log.add(sevWarning, s.name, "Automatic polarity is not offered for a signature " &
        "file: the ground force stays as recorded unless you reverse it.")
    var local: seq[int] = @[]
    for t in pw.traces: local.add t - s.base
    let (found, byCodes) = s.codeRolesIn(local, had, params.accelSet)
    let judge = params.roles.judge # (the places are the codes'; the switch is the window's)
    params.roles = if found: byCodes else: had
    params.roles.judge = judge
    params.roles.groundForcePolarity = pol
    params.roles.massPolarity = poAsRecorded
    if pol != had.groundForcePolarity or params.roles.judge != had.judge:
      state.rememberSigPolarity(w, pol, params.roles.judge, cmd.origin)
    if not (params.forceHundredPct == pw.params.forceHundredPct or
        (params.forceHundredPct.isNaN and pw.params.forceHundredPct.isNaN)) or
        params.forceHundredUnit != pw.params.forceHundredUnit:
      # a 100 % force typed now: in pound-counts, those of the set judged now (on the other
      # set it is another force, and is not applied)
      params.forceHundredSet = params.accelSet
    else: params.forceHundredSet = pw.params.forceHundredSet
  elif pw.view == avVibrator:
    # where the roles came from is the window's to say: "Roles from the codes" puts the
    # code-given places back (and forgets the layout's remembered choice); a role given
    # another trace is a choice made on this window's file and remembered for its layout;
    # else they stay as they were
    let had = pw.params.roles
    (params.roles.source, params.roles.handFile) = (had.source, had.handFile)
    let byCodes = state.codeRoles(w)
    if cmd.plotParams.roles.source == rsCodes and byCodes.source == rsCodes and
        samePlaces(cmd.plotParams.roles, byCodes) and had.source != rsCodes:
      (params.roles.source, params.roles.handFile) = (rsCodes, "")
      state.forgetRoles(w, cmd.origin)
    elif not samePlaces(params.roles, had):
      (params.roles.source, params.roles.handFile) = (rsHand, pw.file)
      state.rememberRoles(w, params.roles, cmd.origin)
    elif params.roles.groundForcePolarity != had.groundForcePolarity or
        params.roles.massPolarity != had.massPolarity or params.roles.judge != had.judge:
      # a polarity chosen on the window is remembered with the roles, for the layout
      state.rememberRoles(w, params.roles, cmd.origin)
  let profileHad = if signature: state.vibProfileOf(pw) else: VibQcProfile()
  if pw.view == avVibrator and params.tops != pw.params.tops and state.inProject and
      keeps(cmd.origin) and not state.project.readOnly:
    # a top frequency typed on the window is kept with its reference in the project
    var kept = topsOf(state.project.doc.vibTops)
    for t in params.tops: kept = kept.withTop(t.reference, t.hz)
    for t in pw.params.tops:
      if params.tops.topOf(t.reference).isNaN: kept = kept.withTop(t.reference, NaN)
    state.project.doc.vibTops = kept.topTexts
    state.projectChanged()
  # (unfolding the roles, the note or the set-up is no reason to measure again)
  var measured = params
  (measured.rolesOpen, measured.noteOpen) = (pw.params.rolesOpen, pw.params.noteOpen)
  (measured.setupOpen, measured.setupSet) = (pw.params.setupOpen, pw.params.setupSet)
  let changed = measured != pw.params
  pw.params = params
  if signature and state.inProject and keeps(cmd.origin) and not state.project.readOnly:
    # what the user sets on a signature window is the project's vibrator QC profile: one
    # configuration, which a QC run reads (no separate button). Only the settings this
    # change touched are written; the rest of the stored profile stays as it is
    let now = state.vibProfileOf(pw)
    if now != profileHad: state.keepVibProfile(profileHad, now)
  # what the user set becomes what a new window of the kind opens with
  # (a signature file's typed 100 % force belongs to its window: never remembered for the kind)
  # (nor its drive level: a new window of a signature file opens with none typed)
  var remembered = cmd.plotParams
  if signature:
    remembered.forceHundredPct = state.settings.plotOptions.vibrator.forceHundredPct
    remembered.targetPct = state.settings.plotOptions.vibrator.targetPct
  if pw.view.hasOptions and
      state.settings.plotOptions.applied(pw.view, remembered) != remembered:
    state.change(cmd.origin, x):
      x.plotOptions.remember(pw.view, remembered)
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
    if pw.result.warning.len > 0 and pw.result.problem.len == 0 and pw.traces.len > 0:
      # said in Messages once for the file, not at every redraw of the window
      let i = state.findTrace(pw.traces[0])
      if i >= 0:
        let key = state.sessions[i].path & "\n" & pw.result.warning
        if key notin state.unmatched:
          state.unmatched.incl key
          state.log.add(sevWarning, state.sessions[i].name,
            state.sessions[i].name & ": " & pw.result.warning.replace("\n", "; ") & ".")

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
  of avSpectrogram, avCorrelation, avOrientation:
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

proc blockPlot(state: var AppState; w, i: int; problem: string; awaiting = false) =
  ## The window stays open and says `problem`; nothing is asked. `awaiting`:
  ## it has no trace yet and `problem` says what to click (an empty state).
  template pw: untyped = state.plots[w]
  if not state.analysisReader.isNil: state.analysisReader.cancel(pw.id)
  let name = if i >= 0: state.sessions[i].name else: ""
  if pw.result.problem == problem and pw.result.awaiting == awaiting and pw.traces.len == 0 and
      not pw.waiting and pw.file == name:
    return
  pw.waiting = false
  pw.traces.setLen 0
  pw.file = name
  pw.record = ""
  pw.result = AnalysisResult(view: pw.view, problem: problem, awaiting: awaiting)
  pw.since = state.plotGen + 1
  inc pw.revision

proc followFilters(state: var AppState; w, k: int) =
  ## Window `plots[w]`, not frozen, follows the plot's filters and the kills
  ## of the traces it already shows, and a reversal of one of them or
  ## reverse-all. `sameFollow` is the spectrum windows' comparison. A
  ## correlation's reference is the chosen one, followed in `followPlots`.
  template pw: untyped = state.plots[w]
  let i = state.findTrace(if pw.traces.len > 0: pw.traces[0] else: -1)
  if i < 0 or state.panels[k].layers.len == 0: return
  if pw.view in {avCorrelation, avEnvelope} and state.pilotFollowKey(w) != pw.pilotKey:
    # the pilot of the record was reversed, killed or given a filter of its own
    if state.askPlot(w): return
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
  var seed = if view == avOrientation: newSeq[int]() else: state.selectedHere(i, order)
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
  if view == avVibrator:
    # a `.vib` window judging set A keeps to it as it follows; any other file is set B's
    if s.signature.kind != sgVib: state.plots[w].params.accelSet = asB
    seed = s.accelSetTraces(seed, state.plots[w].params.accelSet)
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
  let oldRoles = pw.params.roles
  let oldTyped = (pw.params.targetPct, pw.params.forceHundredPct, pw.params.forceHundredUnit)
  let oldAt = if oldTraces.len > 0: state.findTrace(oldTraces[0]) else: -1
  let wasSignature = oldAt >= 0 and state.sessions[oldAt].isSignature
  pw.file = s.name
  pw.record = s.recordText(seed[0])
  pw.traces = ids
  if view == avVibrator:
    pw.params.roles = state.rolesOf(s, seed, oldRoles, s.name, pw.params.accelSet)
    if s.isSignature != wasSignature:
      # from another kind of file to a signature file, or back: the drive level and the 100 %
      # force are those a window of the new kind opens with (a signature file's: none typed)
      let kind = state.settings.plotOptions.vibrator
      pw.params.forceHundredPct = if s.isSignature: NaN else: kind.forceHundredPct
      pw.params.forceHundredUnit = ""
      pw.params.targetPct = if s.isSignature: NaN else: kind.targetPct
  pw.first = seed[0]
  pw.processing = pr
  if state.askPlot(w):
    pw.filters = filtersText(pr)
    state.stampPick(w, k, i)
    if oldRoles.source == rsHand and oldRoles.handFile != s.name and
        pw.params.roles.source == rsCodes:
      state.log.add(sevInfo, s.name, "The vibrator signature's roles are taken from this " &
        "file's trace identification codes; the roles chosen on " & oldRoles.handFile &
        " do not apply here.")
    return true
  pw.processing = kept
  pw.traces = oldTraces
  pw.first = oldFirst
  pw.file = oldFile
  pw.record = oldRecord
  pw.params.roles = oldRoles
  (pw.params.targetPct, pw.params.forceHundredPct, pw.params.forceHundredUnit) = oldTyped
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
  if state.panels[k].layers.len == 0 or sw.traces.len == 0: return
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
    sw.axisT0Ms = state.axisT0Of(k)
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
  let oldAxis = sw.axisT0Ms
  if not window[0].isNaN:
    sw.visibleMs = Span(lo: window[0], hi: window[1])
    sw.axisT0Ms = state.axisT0Of(k)
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
  sw.axisT0Ms = oldAxis
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
    if pw.view in {avCorrelation, avEnvelope, avVibrator} and
        (pw.archiveSeen != state.chosenRef or pw.archiveRev != state.refsRev):
      # The file may already be closed: `askPlot` then cannot replace the
      # picture, and the old curves must not remain.
      if not state.askPlot(w) and pw.view == avCorrelation and not pw.result.awaiting and
          state.findTrace(if pw.traces.len > 0: pw.traces[0] else: -1) < 0:
        let blocked = state.correlationBlock(0.0)
        state.showCorrelationProblem(w, blocked.problem, blocked.name)
    let k = state.findPanel(pw.panel)
    if k < 0 or state.panels[k].layers.len == 0: continue
    let i = state.shownFile(k)
    if i < 0: continue
    if state.pickChanged(w, k, i):
      if not state.repick(w, k, i): state.followFilters(w, k)
    else:
      state.followFilters(w, k)
