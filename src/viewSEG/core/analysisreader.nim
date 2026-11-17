## The analysis windows' reader (New plot): the thread that reads the
## traces an analysis window is of, puts them through the plot's filters
## and works its view out (`core/analysis`), so that the UI thread never
## does either.
##
## - **One request per window, newest wins.** A request replaces the one of
##   the same window that waits; one being served is given up between
##   traces when a newer one of its window comes, or its window closes
##   (`cancel`). Windows' requests are served in turn.
## - **What is read.** The traces asked about, whole, less those killed, those
##   the file marks dead and those that cannot be decoded (the answer counts
##   them, `leftOut`), at the first one's sample interval (a trace sampled at
##   another interval, or with none, is left out and counted, `atOtherInterval`,
##   as the spectrum reader does); a correlation's reference is the chosen
##   archive reference, read raw (no plot filter, no own filter).
## - **Filters.** An effectively reversed trace is multiplied by -1 first (own
##   reversal or reverse-all, not both; a sign flip, before anything else; no
##   box turns it off). The plot's filters first
##   after that (`Processing`, shown raw or not alike; an f-k asked raw
##   leaves them out), made for the traces' interval, run on whole traces;
##   an auxiliary trace goes through them only when the Aux toggle says so,
##   as in the plot. Each trace's own filter runs after them, always, and
##   instead of them when it says so.
## - **Holds.** The caller holds the files (`Jobs.hold`) before it asks; the
##   reader ends the holds (`HoldRelease`) once it has served the request or
##   given it up, and `ask` and `cancel` end those of the requests they drop.
## - **A file cut short, or that cannot be looked at,** is not read: the
##   answer says why. Each read is marked through the seam (`fs.mappedRead`).

import std/[algorithm, locks, math, monotimes, options, os, strutils, times]
import parseSEG
import processSEG/pipeline
import processSEG/core/[rows, types, workspace]
import analysis, cutfile, filesystem, fkanalysis, inbox, jobs, join, log, processing, references,
  threads, vibanalysis

type
  AnalysisAsk* = object
    ## What an analysis window asks the reader for.
    id*: int                    ## the window's
    gen*: uint64
    view*: AnalysisView
    params*: AnalysisParams
    file*: ptr SeismicFile      ## held by the caller
    path*: string
    size*: int64                ## its size when it was opened; -1 when not known
    traces*: seq[int]           ## indices in the file, in the order drawn
    unit*: SurveyUnit           ## the unit of the file's distances (coordinates)
    offsetUnit*: SurveyUnit     ## the unit of the file's trace offsets
    names*: seq[string]         ## per trace, what the curves call it: "trace 12"
    killed*: seq[int]           ## those of `traces` killed, ascending: left out
    reversed*: seq[int]         ## those of `traces` effectively reversed, ascending: samples times -1 first
    allReversed*: bool          ## reverse-all was on for this file
    own*: seq[FilterEntry]      ## traces that carry a filter of their own, ascending
    processing*: Processing     ## the plot's filters and its Aux toggle
    refName*: string
    archivePath*: string        ## a reference from the archive, instead of a trace
    archiveName*: string
    archiveIntervalUs*: float64
    archiveGone*: string        ## selected, but not usable: said, and nothing is drawn
    pilotTrace*: int = -1
      ## a chosen pilot of the record: this record's trace (an index in the file) it
      ## takes by the rule `pilotRule`; -1 for none
    pilotRule*: PilotRule
    pilotRecord*: string ## which record that is, for the sentences
    pilotReversed*: bool ## that trace is effectively reversed: turned over first
    pilotOwn*: seq[FilterEntry] ## its own filter, when it has one
    extraNote*: string ## said under the numbers, for what the choice of a reference changed
    notUsed*: string
      ## an envelope's chosen reference that cannot be used, and why (the trace's own
      ## phase is drawn, and the window says so)

  ReaderObj = object
    lock: Lock
    changed: Cond
    queue: seq[AnalysisAsk]
    quit: bool
    serving: int     ## the window whose request is served; -1 for none
    dropServed: bool ## that request is given up
    poster: Poster
    holds: HoldRelease
    started, busy, ended, abandoned: bool
    beat: MonoTime
    reading: string
    thread: Thread[ptr ReaderObj]

  AnalysisReader* = object
    ## The analysis windows' reader thread. Move-only; destroying it stops
    ## the thread.
    p: ptr ReaderObj

proc `=destroy`*(x: AnalysisReader)
proc `=wasMoved`*(x: var AnalysisReader) = x.p = nil
proc `=copy`*(dest: var AnalysisReader; src: AnalysisReader) {.error.}
proc `=dup`*(src: AnalysisReader): AnalysisReader {.error.}

func isNil*(x: AnalysisReader): bool {.inline.} =
  ## Whether `x` was never started.
  x.p == nil

# ------------------------------------------------------------ the thread --

proc interrupted(p: ptr ReaderObj; id: int): bool =
  ## Whether the request of window `id` being served is to be given up: a
  ## newer one of its window waits, it closed, or the reader stops. A sign
  ## of life too.
  let now = fs.now()
  withLock p.lock:
    p.beat = now
    result = p.quit or p.dropServed
    for a in p.queue:
      if a.id == id: result = true

proc beat(p: ptr ReaderObj; reading: string) =
  let now = fs.now()
  withLock p.lock:
    p.beat = now
    p.reading = reading

func sameDt(a, b: float64): bool {.inline.} = abs(a - b) <= 1e-9 * max(a, b)

func recordSentenceOf(a: AnalysisAsk): string =
  if a.pilotRecord.len == 0: "The record" else: capitalizeAscii(a.pilotRecord)

proc readRows(p: ptr ReaderObj; f: ptr SeismicFile; path: string; list: seq[int];
    id: int; rows: var seq[seq[float32]]; failed: var seq[bool]): bool =
  ## Traces `list` of `f`, whole, into `rows` (in its order; a trace that
  ## cannot be decoded is empty and `failed`); false when a newer request
  ## came first.
  result = true
  rows = newSeq[seq[float32]](list.len)
  failed = newSeq[bool](list.len)
  if list.len == 0: return
  p.beat(path)
  var pf = newPrefetcher[float32](f[], list, chunkTraces = 16, workers = 2, uniform = true)
  var c: PrefetchChunk[float32]
  while pf.nextInto(c):
    fs.mappedRead(path)
    let b = rowBlock(c.samples)
    for r in c.failedRows: failed[c.first + r] = true
    for k in 0 ..< c.count:
      let n = min(c.rows.numSamples(k), b.cols)
      var s = newSeq[float32](max(n, 0))
      if n > 0: copyMem(addr s[0], b.rowPtr(k), n * sizeof(float32))
      for v in s.mitems:
        if not (abs(v) < Inf): v = 0 # a sample that is not a number: as the plot draws it
      rows[c.first + k] = move s
    if c.first + c.count < list.len and p.interrupted(id):
      result = false
      break
    p.beat(path)
  discard pf.close()
  clearCycleRoots()

func unionAsc(a, b: openArray[int]): seq[int] =
  result = newSeqOfCap[int](a.len + b.len)
  var i, j = 0
  while i < a.len or j < b.len:
    let x = if j >= b.len or (i < a.len and a[i] <= b[j]): a[i] else: b[j]
    if result.len == 0 or result[^1] != x: result.add x
    if i < a.len and a[i] == x: inc i
    if j < b.len and b[j] == x: inc j

proc negateListed(rows: var seq[seq[float32]]; list, reversed: openArray[int]) =
  ## Multiplies each listed trace that is reversed by -1, before the plot's
  ## filters and each trace's own filter. A sign flip, not a filter.
  if reversed.len == 0 or rows.len == 0: return
  for i, t in list:
    if i < rows.len and reversed.binarySearch(t) >= 0:
      for v in rows[i].mitems: v = -v

proc applyRowsOwn(b: RowBlock[float32]; live: TraceRows; dtMs: float64;
    list: openArray[int]; own: openArray[FilterEntry]; ws: var Workspace) =
  ## Each listed trace's own frequency filter, on the rows of `b`.
  var seen: seq[int]
  for k, t in list:
    let at = entryAt(own, t)
    if at >= 0 and own[at].filter.spec.hasFilters and k notin seen:
      let f = own[at].filter
      var group = @[k]
      seen.add k
      for j in k + 1 ..< list.len:
        let aj = entryAt(own, list[j])
        if aj >= 0 and own[aj].filter == f:
          group.add j
          seen.add j
      var skip = newSeqOfCap[int](b.len - group.len)
      var g = 0
      for row in 0 ..< b.len:
        if g < group.len and group[g] == row: inc g
        else: skip.add row
      let pipe = f.ownPipeline(dtMs)
      if pipe.len > 0:
        let plan = pipe.compile(float32, dtMs, b.cols, recordSamples = b.cols)
        ws.reserve(plan)
        plan.apply(b, initChunkMeta(live, dtMs, 0, skip), ws)

proc filtered*(rows: var seq[seq[float32]]; f: ptr SeismicFile; list: seq[int];
    pr: Processing; own: openArray[FilterEntry]; reversed: openArray[int];
    dtMs: float64; passed: var int; plotOn = true): string =
  ## `rows` (traces `list` of `f`) with each reversed trace multiplied by -1
  ## first (`reversed`), then through the plot's filters `pr` at `dtMs` when
  ## `plotOn` (an f-k asked raw leaves them out), then through each trace's
  ## own filter (`own`), always. An own filter that runs instead leaves the
  ## plot's filters off that trace. An auxiliary trace goes through the
  ## plot's filters only when `pr.aux` (the others, `passed` of them, are
  ## passed by); its own filter runs either way. What the plot's filters
  ## are, in words, or why they did not run; "" when they were not applied.
  negateListed(rows, list, reversed)
  passed = 0
  var q = pr
  q.raw = false
  var instead: seq[int]
  var anyOwn = false
  for k, t in list:
    let at = entryAt(own, t)
    if at >= 0:
      if own[at].filter.place == fpInstead: instead.add k
      if own[at].filter.spec.hasFilters: anyOwn = true
  let applyPlot = plotOn and q.hasFilters
  if (not applyPlot and not anyOwn) or rows.len == 0: return ""
  let filters = if applyPlot: q.filterPipeline(dtMs) else: initPipeline()
  if applyPlot and filters.len == 0 and not anyOwn:
    return "the filters (none of them below Nyquist) did not run"
  var cols = 0
  for r in rows: cols = max(cols, r.len)
  if cols == 0: return ""
  var work = newSeq[float32](rows.len * cols)
  for i, r in rows:
    if r.len > 0: copyMem(addr work[i * cols], addr r[0], r.len * sizeof(float32))
  let b = rowBlock(work, rows.len, cols)
  try:
    var ws = initWorkspace()
    let traceRows = f[].rowsOf(list)
    if applyPlot and filters.len > 0:
      let plan = filters.compile(float32, dtMs, cols, recordSamples = cols)
      ws.reserve(plan)
      if q.aux and traceRows.hasAuxiliary:
        var keys: seq[TraceKeys] = @[]
        var lengths: seq[int] = @[]
        let skip = if instead.len == 0: newSeq[int]() else: instead
        plan.apply(b, initChunkMeta(traceRows.auxLiveRows(keys, lengths), dtMs, 0, skip), ws)
      elif instead.len == 0:
        plan.apply(b, initChunkMeta(traceRows, dtMs), ws)
      else:
        plan.apply(b, initChunkMeta(traceRows, dtMs, 0, instead), ws)
    if anyOwn:
      var keys: seq[TraceKeys] = @[]
      var lengths: seq[int] = @[]
      applyRowsOwn(b, traceRows.auxLiveRows(keys, lengths), dtMs, list, own, ws)
  except ValueError as e:
    return "the filters could not run: " & e.msg
  for i in 0 ..< rows.len:
    if rows[i].len > 0: copyMem(addr rows[i][0], addr work[i * cols], rows[i].len * 4)
    if applyPlot and not q.aux and f[].traceKeys(list[i]).status == tsAuxiliary:
      inc passed
  if applyPlot and filters.len > 0:
    result = "through " & q.describe
    if instead.len > 0: result.add ". " & insteadWords(instead.len, list.len)
  elif applyPlot: result = "the filters (none of them below Nyquist) did not run"

proc orientationAnswer(p: ptr ReaderObj; a: AnalysisAsk): AnalysisResult =
  ## A node orientation plot: the three angles of each trace's header, in
  ## degrees (NaN for a trace without one); no samples are read.
  let f = a.file
  var angles: seq[array[3, float64]] = @[]
  try:
    p.beat(a.path)
    for t in a.traces:
      var row = [NaN, NaN, NaN]
      if t in 0 ..< f[].len:
        fs.mappedRead(a.path)
        let o = f[].traceOrientation(t)
        if o.isSome:
          let v = o.get
          row = [radToDeg(float64(v.rotationX)), radToDeg(float64(v.rotationY)),
            radToDeg(float64(v.rotationZ))]
      angles.add row
      if angles.len mod 256 == 0: p.beat(a.path)
    result = orientationOf(angles)
  except CatchableError as e:
    result.problem = "it cannot be read now: " & e.msg

type ReferenceRead = object
  ## What reading a window's reference gave.
  samples: seq[float32]
  name: string    ## in words, for the window's notes
  problem: string ## why it cannot be used; "" when it can
  cancelled: bool ## a newer request came first

func hasReference(a: AnalysisAsk): bool {.inline.} =
  ## Whether the window was given a reference: an archive file, a trace of the
  ## record by a rule, or a stored one that is gone (said, not used).
  a.archiveGone.len > 0 or a.archivePath.len > 0 or a.pilotTrace >= 0

proc readReference(p: ptr ReaderObj; a: AnalysisAsk; f: ptr SeismicFile; dtMs: float64;
    through: var string; passed: var int): ReferenceRead =
  ## The chosen reference of window `a`, as a correlation and an envelope take
  ## it: an archive file read raw, else the record's trace by the rule, put
  ## through what the plot puts a trace through (reversal, filters, its own
  ## filter) and cut to the rule's window; refused when its interval is not
  ## `dtMs`. `through` and `passed` say what the filters did to the pilot.
  if a.archiveGone.len > 0:
    result.problem = a.archiveGone
  elif a.archivePath.len > 0:
    var refSamples: seq[float32] = @[]
    var rus = a.archiveIntervalUs
    try:
      var read: tuple[samples: seq[float32]; intervalUs: float64]
      {.cast(gcsafe).}:
        read = readReferenceFile(a.archivePath)
      refSamples = read.samples
      if read.intervalUs > 0: rus = read.intervalUs
    except CatchableError as e:
      result.problem = "the reference \"" & a.archiveName &
        "\" is no longer in the archive (" & e.msg & ")"
    if result.problem.len == 0:
      let rdt = rus / 1000
      if not (rus > 0 and rus < Inf):
        result.problem = "the reference trace is at another interval: it has " &
          "no sample interval"
      elif not sameDt(rdt, dtMs):
        result.problem = intervalRefusal(rdt, dtMs)
      elif refSamples.len == 0:
        result.problem = "the reference trace could not be read"
      else:
        result.name = a.archiveName & " (archive)"
        result.samples = refSamples
  elif a.pilotTrace >= 0:
    let rt = a.pilotTrace
    if rt notin 0 ..< f[].len:
      result.problem = recordSentenceOf(a) & " has no such trace."
      return
    var refRows: seq[seq[float32]] = @[]
    var refFailed: seq[bool] = @[]
    if not p.readRows(f, a.path, @[rt], a.id, refRows, refFailed):
      result.cancelled = true
      return
    let rk = f[].traceKeys(rt)
    let rus = if rk.intervalUs > 0 and rk.intervalUs < Inf: rk.intervalUs
              else: f[].sampleIntervalUs(rt)
    let rdt = rus / 1000
    if refFailed[0] or refRows[0].len == 0:
      result.problem = "the pilot trace could not be read"
    elif not (rus > 0 and rus < Inf):
      result.problem = "the pilot trace has no sample interval"
    elif not sameDt(rdt, dtMs):
      result.problem = intervalRefusal(rdt, dtMs)
    else:
      var refPassed = 0
      let refRev = if a.pilotReversed: @[rt] else: newSeq[int]()
      let refThrough = filtered(refRows, f, @[rt], a.processing, a.pilotOwn,
        refRev, dtMs, refPassed)
      if refPassed > 0 and refThrough.startsWith("through "):
        inc passed
        let words = "the pilot is not filtered: " & AuxFilterOff
        through = if through.len > 0: through & "; " & words else: words
      let (cut, why) = cutPilot(refRows[0], dtMs, a.pilotRule, a.pilotRecord)
      if why.len > 0:
        result.problem = why
      else:
        result.name = a.archiveName & " (" & a.pilotRecord & ", " &
          pilotWords(a.pilotRule.aux, a.pilotRule.trace) & ")"
        result.samples = cut

proc serve(p: ptr ReaderObj; a: AnalysisAsk): bool =
  ## Reads, works out and posts what `a` asks for; false when a newer
  ## request came first (nothing is posted).
  var answer = AnalysisResult(gen: a.gen, id: a.id, view: a.view)
  let f = a.file
  var why = cutWhy(f[])
  if why.len > 0:
    answer.problem = why
  elif a.view == avOrientation:
    answer = p.orientationAnswer(a)
  else:
    # the traces to read: live, not killed, at the first one's interval
    var list: seq[int] = @[]
    var names: seq[string] = @[]
    var dtMs = NaN
    var t0Ms = 0.0
    var notDrawn = 0
    for i, t in a.traces:
      if t notin 0 ..< f[].len or a.killed.binarySearch(t) >= 0 or
          f[].traceKeys(t).status == tsDead:
        inc answer.leftOut
      else:
        let k = f[].traceKeys(t)
        # the interval as the spectrum reader resolves it: the trace's, else the file's
        let us = if k.intervalUs > 0 and k.intervalUs < Inf: k.intervalUs
                 else: f[].sampleIntervalUs(t)
        if not (us > 0 and us < Inf):
          inc answer.atOtherInterval
        else:
          let dt = us / 1000
          if dtMs.isNaN:
            dtMs = dt
            if abs(k.t0Ms) < Inf: t0Ms = k.t0Ms
          if not sameDt(dt, dtMs): inc answer.atOtherInterval
          elif a.view == avCorrelation and list.len >= MaxAnalysisCurves:
            inc notDrawn # drawn no more than that many: the rest are not even read
          else:
            list.add t
            names.add (if i < a.names.len: a.names[i] else: "trace " & $(t + 1))
    answer.dtMs = dtMs
    if list.len == 0:
      answer.problem = "no trace to work it out on (" &
        (if a.traces.len == 0: "none asked about" else: "every one left out: killed, " &
        "marked dead, or at another interval") & ")"
    else:
      try:
        var rows: seq[seq[float32]] = @[]
        var failed: seq[bool] = @[]
        if not p.readRows(f, a.path, list, a.id, rows, failed): return false
        var kept: seq[seq[float32]] = @[]
        var keptNames: seq[string] = @[]
        var keptList: seq[int] = @[]
        for i in 0 ..< rows.len:
          if failed[i] or rows[i].len == 0: inc answer.leftOut
          else:
            kept.add move rows[i]
            keptNames.add names[i]
            keptList.add list[i]
        let stop = proc (): bool = p.interrupted(a.id)
        let plotOn = not (a.view == avFk and a.params.fkRaw) # f-k raw: the plot's filters only
        var passed = 0
        var through = if kept.len > 0: filtered(kept, f, keptList, a.processing,
          a.own, a.reversed, dtMs, passed, plotOn) else: ""
        if passed > 0 and through.startsWith("through "):
          # the filters did not touch these: the words must not say they did
          if passed == kept.len:
            through = passedWords(passed) & " (the plot's filters: " &
              through["through ".len .. ^1] & ")"
          else:
            through.add " (" & passedWords(passed) & ")"
        if kept.len == 0:
          answer.problem = "none of the traces could be read"
        else:
          case a.view
          of avSpectrogram:
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = spectrogramOf(kept, dtMs, t0Ms, a.params, stop)
            (answer.leftOut, answer.atOtherInterval) = n
          of avEnvelope:
            # against the chosen reference when there is one that can be used:
            # the same reader of it as a correlation's; else the trace's own phase
            var reference: seq[float32] = @[]
            var refName = ""
            var notUsed = a.notUsed
            if a.hasReference and a.params.phaseAgainst == paReference:
              let got = p.readReference(a, f, dtMs, through, passed)
              if got.cancelled: return false
              if got.problem.len > 0: notUsed = got.problem
              else: (reference, refName) = (got.samples, got.name)
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = envelopeOf(kept[0], keptNames[0], dtMs, t0Ms, a.params, reference, refName,
              notUsed)
            (answer.leftOut, answer.atOtherInterval) = n
            let rule = if reference.len > 0: lengthRule(reference.len, kept[0].len) else: ""
            if rule.len > 0 and answer.problem.len == 0:
              answer.note = capitalizeAscii(rule) & ". " & answer.note
          of avPhase:
            let n = (answer.leftOut, answer.atOtherInterval)
            answer = phaseOf(kept[0], keptNames[0], dtMs, a.params)
            (answer.leftOut, answer.atOtherInterval) = n
          of avCorrelation:
            # the chosen reference only, read raw (an archive file) or cut from
            # the record's own trace; none is said and nothing is drawn
            if not a.hasReference:
              answer.problem = NoReferenceChosen
            else:
              let got = p.readReference(a, f, dtMs, through, passed)
              if got.cancelled: return false
              if got.problem.len > 0: answer.problem = got.problem
              else:
                var signals: seq[(string, seq[float32])] = @[]
                for i in 0 ..< min(kept.len, MaxAnalysisCurves):
                  signals.add (keptNames[i], kept[i])
                let n = (answer.leftOut, answer.atOtherInterval)
                answer = correlationOf(signals, got.samples, got.name, dtMs, a.params, stop)
                (answer.leftOut, answer.atOtherInterval) = n
                let rule = if kept.len > 0: lengthRule(got.samples.len, kept[0].len) else: ""
                if rule.len > 0 and answer.problem.len == 0:
                  answer.note = "Reference: " & got.name & ". " & rule &
                    (if answer.note.len > 0: ". " & answer.note else: "")
                elif answer.problem.len == 0:
                  answer.note = "Reference: " & got.name &
                    (if answer.note.len > 0: ". " & answer.note else: "")
          of avFk:
            # the trace spacing, from the keys of the traces read
            var offsets, xs, ys: seq[float64] = @[]
            for t in keptList:
              let k = f[].traceKeys(t)
              offsets.add k.offset
              xs.add k.rcvX
              ys.add k.rcvY
            let (spacing, source) = spacingOf(offsets, xs, ys)
            let n = (answer.leftOut, answer.atOtherInterval)
            # the offsets' unit when the spacing is from them, else the coordinates'
            let unit = if source == "offsets": a.offsetUnit else: a.unit
            answer = fkOf(kept, spacing, source, unit, dtMs, t0Ms, a.params, stop)
            (answer.leftOut, answer.atOtherInterval) = n
          of avOrientation: discard # answered above, before any sample is read
          of avVibrator:
            # each role's trace: its place among those asked about, then
            # among those read (one left out has no role). An archive
            # reference replaces the reference role's samples.
            if a.archiveGone.len > 0:
              answer.problem = a.archiveGone
            else:
              var rows = kept
              var names = keptNames
              var archiveSamples: seq[float32] = @[]
              var refused = false
              if a.archivePath.len > 0:
                try:
                  var read: tuple[samples: seq[float32]; intervalUs: float64]
                  {.cast(gcsafe).}:
                    read = readReferenceFile(a.archivePath)
                  let rus = if read.intervalUs > 0: read.intervalUs else: a.archiveIntervalUs
                  let rdt = rus / 1000
                  if not (rus > 0 and rus < Inf):
                    answer.problem = "the reference trace is at another interval: it has " &
                      "no sample interval"
                    refused = true
                  elif not sameDt(rdt, dtMs):
                    answer.problem = intervalRefusal(rdt, dtMs)
                    refused = true
                  else:
                    archiveSamples = read.samples
                except CatchableError as e:
                  answer.problem = "the reference \"" & a.archiveName &
                    "\" is no longer in the archive (" & e.msg & ")"
                  refused = true
              if not refused:
                let places = [vsReference: a.params.roles.reference,
                  vsGroundForce: a.params.roles.groundForce, vsMass: a.params.roles.mass,
                  vsBaseplate: a.params.roles.baseplate]
                var at: array[VibRole, int]
                var missing: seq[string] = @[]
                for role in VibRole:
                  let q = places[role]
                  at[role] = if q in 0 ..< a.traces.len: keptList.find(a.traces[q]) else: -1
                  if q in 0 ..< a.traces.len and at[role] < 0 and a.archivePath.len == 0:
                    missing.add $role
                if archiveSamples.len > 0:
                  let refName = a.archiveName & " (archive)"
                  if at[vsReference] >= 0:
                    rows[at[vsReference]] = archiveSamples
                    names[at[vsReference]] = refName
                  else:
                    rows.add archiveSamples
                    names.add refName
                    at[vsReference] = rows.high
                let n = (answer.leftOut, answer.atOtherInterval)
                answer = vibratorOf(rows, names, at, dtMs, a.params)
                (answer.leftOut, answer.atOtherInterval) = n
                if archiveSamples.len > 0 and answer.problem.len == 0:
                  let refName = a.archiveName & " (archive)"
                  let rule = if kept.len > 0: lengthRule(archiveSamples.len, kept[0].len) else: ""
                  let line = "Reference: " & refName &
                    (if rule.len > 0: ". " & rule else: "")
                  answer.note = line & (if answer.note.len > 0: ". " & answer.note else: "")
                if missing.len > 0:
                  let words = missing.join(", ") & " left out (killed, dead or unreadable)"
                  if answer.problem.len > 0: answer.problem.add "; " & words
                  else: answer.note.add "; " & words
          if answer.cancelled: return false # its window closed or asked again: nothing to say
          answer.gen = a.gen
          answer.id = a.id
          answer.passedBy = passed
          answer.notDrawn = notDrawn
          if through.len > 0 and answer.problem.len == 0:
            answer.note = (if answer.note.len > 0: answer.note & "; " else: "") & through
          if a.extraNote.len > 0 and answer.problem.len == 0:
            answer.note = (if answer.note.len > 0: answer.note & "; " else: "") & a.extraNote
      except ValueError as e:
        answer.problem = e.msg
      except CatchableError as e: # a cut file, a drive that failed
        answer.problem = readProblem(e)
  answer.gen = a.gen
  answer.id = a.id
  answer.view = a.view
  clearCycleRoots() # the UI thread frees what was made here
  p.poster.post Msg(job: NoJob, kind: mkAnalysis, analysis: answer)
  true

proc release(p: ptr ReaderObj; a: AnalysisAsk) =
  discard p.holds.release(a.path)

proc run(p: ptr ReaderObj) {.thread.} =
  markWorkerThread()
  while true:
    var a: AnalysisAsk
    var got, quit = false
    withLock p.lock:
      while not (p.quit or p.queue.len > 0):
        wait(p.changed, p.lock)
      quit = p.quit
      got = p.queue.len > 0 and not quit
      if got:
        a = move p.queue[0]
        p.queue.delete 0
        p.serving = a.id
        p.dropServed = false
      p.busy = got
      p.beat = fs.now()
    if got:
      try:
        discard p.serve(a)
      except CatchableError as e:
        p.poster.post Msg(job: NoJob, kind: mkLog, entry: LogEntry(time: getTime(),
          severity: sevWarning, source: "New plot", text: "A plot could not be worked " &
          "out: " & e.msg))
      clearCycleRoots()
      p.release(a)
    withLock p.lock:
      p.busy = false
      p.serving = -1
      p.reading = ""
    if quit: break
  clearCycleRoots()
  withLock p.lock:
    p.busy = false
    p.ended = true

# --------------------------------------------------------------- the UI side --

const AnalysisStopWait* = initDuration(milliseconds = 800)

proc stop*(x: AnalysisReader; deadline = getMonoTime() + AnalysisStopWait): bool {.
  discardable, raises: [].}

proc `=destroy`*(x: AnalysisReader) =
  if x.p != nil:
    var abandoned = false
    withLock x.p.lock:
      abandoned = x.p.abandoned
    if not abandoned: discard x.stop()
    if not x.p.started:
      for a in x.p.queue:
        discard x.p.holds.release(a.path)
      deinitCond(x.p.changed)
      deinitLock(x.p.lock)
      `=destroy`(x.p[])
      deallocShared(x.p)

proc newAnalysisReader*(poster: sink Poster; holds: HoldRelease): AnalysisReader =
  ## Starts the reader, which posts through `poster` and ends its holds
  ## through `holds`.
  let p = cast[ptr ReaderObj](allocShared0(sizeof(ReaderObj)))
  initLock p.lock
  initCond p.changed
  p.poster = poster
  p.holds = holds
  p.serving = -1
  result = AnalysisReader(p: p)
  createThread(p.thread, run, p)
  p.started = true

proc dropOf(x: AnalysisReader; id: int): seq[AnalysisAsk] =
  ## Window `id`'s requests waiting, taken out of the queue (under the lock).
  var i = 0
  while i < x.p.queue.len:
    if x.p.queue[i].id == id:
      result.add move x.p.queue[i]
      x.p.queue.delete i
    else: inc i

proc ask*(x: AnalysisReader; a: sink AnalysisAsk) =
  ## Asks for `a`, whose files the caller holds; replaces a request of the
  ## same window not yet taken (ending its holds), and has one being served
  ## given up.
  assert x.p != nil
  var dropped: seq[AnalysisAsk] = @[]
  withLock x.p.lock:
    dropped = x.dropOf(a.id)
    x.p.queue.add a
    signal(x.p.changed)
  for d in dropped: x.p.release(d)

proc cancel*(x: AnalysisReader; id: int) =
  ## Drops window `id`'s requests: one waiting (its holds ended), and one
  ## being served is given up.
  if x.p == nil: return
  var dropped: seq[AnalysisAsk] = @[]
  withLock x.p.lock:
    dropped = x.dropOf(id)
    if x.p.serving == id: x.p.dropServed = true
  for d in dropped: x.p.release(d)

proc askStop*(x: AnalysisReader) =
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      signal(x.p.changed)

proc stop*(x: AnalysisReader; deadline = getMonoTime() + AnalysisStopWait): bool {.
    discardable, raises: [].} =
  ## Stops the thread and waits for it until `deadline`: true when it has
  ## ended; false when it is stuck, and it is then left to end on its own.
  if x.p == nil or not x.p.started: return true
  x.askStop()
  var ended = false
  while true:
    withLock x.p.lock:
      ended = x.p.ended
    if ended or getMonoTime() >= deadline: break
    sleep 1
  if ended:
    joinThread(x.p.thread)
    x.p.started = false
  else:
    withLock x.p.lock:
      x.p.abandoned = true
  ended

proc leave*(x: AnalysisReader) =
  ## Leaves the thread to end on its own (stuck in a drive that does not
  ## answer); its holds stay until it ends.
  if x.p != nil:
    withLock x.p.lock:
      x.p.quit = true
      x.p.abandoned = true
      signal(x.p.changed)

proc silentFor*(x: AnalysisReader; now = fs.now()): Duration =
  ## How long the reader has been busy without a sign of life; zero when
  ## idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = now - x.p.beat

proc readingPath*(x: AnalysisReader): string =
  ## The file the reader reads now; "" when it is idle or none.
  if x.p != nil:
    withLock x.p.lock:
      if x.p.busy: result = x.p.reading

func queued*(x: AnalysisReader): int =
  ## Requests waiting, not the one being served. A later ask of the same
  ## window has already replaced the ones before it.
  if x.p == nil: return 0
  withLock x.p.lock:
    result = x.p.queue.len
