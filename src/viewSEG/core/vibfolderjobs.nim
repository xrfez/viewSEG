## A background job that judges each vibrator signature file of a folder the
## way one Vibrator window would, and fills a table (`core/vibfolderqc`).
## One file is open at a time. One file that cannot be read does not stop
## the rest. A cancel stops before the first file, between files and inside
## a file, and every file not judged is listed as skipped. The sink is set
## before the job returns, fails or is cancelled.
##
## Polarity is reported and never changed. Job weights are never applied as
## masses: a header that disagrees is words only.

import std/[math, os, strutils, tables]
import parseSEG
import parseSEG/common/diagnostics
import processSEG/core/shift
import analysis, filejobs, filekinds, filesystem, jobs, project, references, session, settings,
  signatures, sigjudge, sweepinfo, sweeppairs, threads, traceids, vibalign, vibanalysis,
  vibfolderqc, vibjudge, vibprofile
import sigtypes except QcLimit

const FolderScale* = 1000
  ## Files of progress in one file. A job's `done div FolderScale` is files finished.

type
  FolderChoice* = object
    ## What the user picked to run: a folder (its subfolders only when
    ## `subfolders`) and/or single files. Nothing else is listed.
    folder*: string
    files*: seq[string]
    subfolders*: bool

  FolderListSink* = ref object
    ## Filled on the job thread before the list job returns.
    files*: seq[FolderListed]
    capped*: bool

  FolderQcSink* = ref object
    ## Filled on the job thread before the job returns. Read it after the job ends.
    result*: FolderTable

  HeldRef = object
    samples: seq[float32]
    dtMs: float64
    name: string
    startMs: float64

func shareOf(done, total: int64): int64 =
  if total <= 0 or done <= 0: return 0
  if done >= total: return FolderScale - 1
  let scaled = int64(float64(done) / float64(total) * float64(FolderScale))
  if scaled >= FolderScale: FolderScale - 1 else: scaled

func filePhase(i, n: int; path: string): string =
  "file " & $(i + 1) & " of " & $n & ": " & path.extractFilename

func sameDt(a, b: float64): bool {.inline.} =
  a > 0 and b > 0 and abs(a - b) <= 1e-9 * max(a, b)

func typedForce(x: float64): bool {.inline.} = x > 0 and x < Inf

func hasChoice*(c: FolderChoice): bool =
  ## Whether a folder or a file was picked.
  c.folder.len > 0 or c.files.len > 0

func choicePaths(c: FolderChoice): seq[string] =
  result = @[]
  if c.folder.len > 0: result.add c.folder
  for f in c.files: result.add f

proc folderListSpec*(c: FolderChoice): JobSpec =
  ## The job that lists the signature files `c` names: background, reading
  ## the chosen folder and files.
  JobSpec(title: "List vibrator files", lane: jlBackground, reads: choicePaths(c))

proc folderListWork*(c: FolderChoice; sink: FolderListSink): JobWork =
  ## Lists the signature files `c` names, each with the header facts read
  ## (never a sample), in natural order of file name. `c.subfolders` is
  ## honoured and nothing outside the choice is looked at. The sink is set
  ## before the job returns. A folder that cannot be read fails the job.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase(ListingPhase)
    var capped = false
    var paths: seq[string] = @[]
    try:
      paths = listedNames(choicePaths(c), c.subfolders, capped,
        proc (found: int): bool {.gcsafe, raises: [].} =
        ctx.progress(int64(found), 0))
    except OSError:
      raise newException(ValueError, CannotListFolder)
    ctx.checkCancelled()
    var files: seq[FolderListed] = @[]
    for i, path in paths:
      ctx.checkCancelled()
      discard ctx.progress(int64(i), int64(paths.len))
      let kind = sniff(path)
      if kind notin SignatureFileKinds: continue
      var info = SweepInfo(kind: kind.sweepKindOf)
      try:
        info = readSweepInfo(path, kind.sweepKindOf, fs.getFileSize(path))
      except OSError as e:
        info.problem = if e.msg.len > 0: e.msg else: "it cannot be read"
      files.add FolderListed(path: path, info: info)
    if sink != nil:
      sink.capped = capped
      sink.files = files

proc folderQcSpec*(files: openArray[FolderListed]; reference = ""): JobSpec =
  ## The job that judges `files`: background, reading each file, and the
  ## reference when one was given. Does not touch the file system.
  var reads: seq[string] = @[]
  for f in files:
    if f.path.len > 0: reads.add f.path
  if reference.len > 0: reads.add reference
  JobSpec(title: "Vibrator QC", lane: jlBackground, reads: reads)

proc folderRoles*(codes: openArray[int16]; kind: SignatureKind;
    accelSet: AccelSet): VibRoles =
  ## The roles the trace codes give, polarity as recorded. A `.vib` judged
  ## on set A uses that set's codes and not set B's.
  var mapped = newSeq[int16](codes.len)
  for i, c in codes: mapped[i] = c
  if accelSet == asA and kind == sgVib:
    for c in mapped.mitems:
      c = case c
        of VibSetAMassCode: VibReactionMassCode
        of VibSetABaseplateCode: VibBaseplateCode
        of VibSetAGroundForceCode: VibGroundForceCode
        of VibReactionMassCode, VibBaseplateCode, VibGroundForceCode: 0'i16
        else: c
  result = VibRoles().withCodeRoles(mapped, "")
  result.groundForcePolarity = poAsRecorded
  result.massPolarity = poAsRecorded
  result.judge = joRecorded

proc folderParams*(ask: VibQcAsk; roles: VibRoles; kind: SignatureKind): AnalysisParams =
  ## The ask a Vibrator window would use, with no typed masses. A 100 % force
  ## the profile did not type stays unset. Its unit, and the accelerometer set
  ## a pound-counts force was typed on, are the ones the profile stored, never
  ## the set now judged and never guessed from the scale. A set an older
  ## project did not store stays unknown.
  AnalysisParams(roles: roles, harmonics: ask.options.harmonics,
    accelSet: ask.accelSet, qcWindowMs: ask.options.qcWindowMs, qc: ask.options.qc,
    forceHundredPct: ask.options.forceHundredPct,
    forceHundredUnit: ask.forceHundredUnit, forceHundredSet: ask.forceHundredSet,
    forceHundredSetKnown: ask.forceHundredSetKnown,
    targetPct: ask.options.targetPct, phaseShow: ask.options.phaseShow,
    reactionMassKg: NaN, baseplateMassKg: NaN, projectReference: false)

proc folderSignature*(facts: SignatureFacts; scale: ForceScale; accelSet: AccelSet;
    pair = SignaturePair(); targetPct = NaN): SignatureAsk =
  ## What the file adds. `given` so polarity is reported and never changed,
  ## and Automatic is not honoured. The force scale and the file's own 100 %
  ## force are what the Vibrator window sets (`applyFileScale`).
  result = SignatureAsk(given: true, isDat: facts.kind == sgDat,
    setA: facts.kind == sgVib and accelSet == asA)
  result.applyFileScale(facts.kind, scale.datCountsPerLbf, scale.vibAccMvPerCount,
    facts.info.weights, accelSet == asA, facts.qc.valid, facts.qc.targetForceLbf,
    targetPct)
  case facts.kind
  of sgDat:
    if facts.qc.valid:
      result.ctlFrom = "this file"
      result.ctl = facts.qc.brief
      result.ctl.valid = true
      result.correlationStored = facts.qc.correlationStored
      result.correlationLagZero = facts.qc.correlationLagZero
  of sgVib:
    if pair.path.len > 0 and pair.qc.valid:
      result.ctlFrom = "the .dat of this sweep"
      result.ctl = pair.qc
  of sgNone: discard

proc finish(sink: FolderQcSink; table: var FolderTable) =
  attachPairs(table.rows)
  table.totals = totalsOf(table.rows)
  if sink != nil: sink.result = table

proc stopJob(sink: FolderQcSink; table: var FolderTable) =
  table.cancelled = true
  finish(sink, table)
  raise newException(JobCancelledError, "Cancelled.")

func infoOf(files: seq[FolderListed]; path: string): SweepInfo =
  for f in files:
    if f.path == path: return f.info

proc skipFrom(rows: var seq[FolderRow]; files: seq[FolderListed];
    pairs: Table[string, string]; frm: int) =
  for j in frm ..< files.len:
    let item = files[j]
    let partner = pairs.getOrDefault(item.path)
    rows.add stamped(FolderRow(path: item.path, kind: item.info.kind,
      pair: partner, outcome: foSkipped, problem: "Cancelled."), item.info,
      infoOf(files, partner), partner)

func sweepsOf(files: seq[FolderListed]; pairs: Table[string, string]): seq[
    tuple[vibrator: int; weights: VibWeights]] =
  var at = initTable[string, int]()
  for i, f in files: at[f.path] = i
  for f in files:
    if f.info.kind == sgVib:
      var vib = f.info.vibrator
      let partner = pairs.getOrDefault(f.path)
      if vib <= 0 and partner.len > 0 and partner in at:
        vib = files[at[partner]].info.vibrator
      result.add (vib, f.info.weights)

proc readAll(ctx: JobContext; path: string; size: int64; fileNo, count: int): seq[byte] =
  let name = path.extractFilename
  if size < 0:
    raise newException(IOError, name & " cannot be read.")
  if size == 0:
    raise newException(SignatureError, name & " is empty: not opened.")
  if size > MaxSignatureBytes:
    raise newException(SignatureError, name & " is larger than any signature file (" &
      $(MaxSignatureBytes shr 20) & " MiB): not opened")
  var f: File
  if not fs.open(f, path):
    raise newException(IOError, name & " cannot be read.")
  defer: close(f)
  result = newSeq[byte](int(size))
  var got = 0
  while got < int(size):
    if ctx.cancelled: raise newException(JobCancelledError, "Cancelled.")
    let n = min(1 shl 20, int(size) - got)
    let read = fs.readBuffer(f, path, addr result[got], n)
    if read <= 0:
      raise newException(IOError, name & " cannot be read.")
    got += read
    discard ctx.progress(int64(fileNo) * FolderScale + shareOf(int64(got), size),
      int64(count) * FolderScale)

proc addLine(into: var seq[string]; line: string) =
  if line.len > 0 and line notin into: into.add line

proc addLines(into: var seq[string]; text: string) =
  for line in text.splitLines: addLine(into, line)

proc fitLines(f: SignatureFacts): seq[string] =
  if f.kind != sgVib: return
  let t = f.trigger
  if t.source != trEstimated and t.why.len > 0:
    result.add "Sweep fit: " & t.why
  elif t.crossings > 0 and (t.crossings < 200 or t.residualCycles > 0.05):
    result.add "Sweep fit: " & $t.crossings & " zero crossings, residual " &
      formatFloat(t.residualCycles, ffDecimal, 3) & " cycles"
  if f.endsInSweep: result.add "Recording ends inside the sweep."

proc measuresOf(rows: seq[QcRow]): seq[FolderMeasure] =
  for row in rows:
    result.add FolderMeasure(limit: row.limit, measured: row.measured, bound: row.bound,
      atMs: row.atMs, status: row.status, why: row.why)

proc controllersOf(rows: seq[ControllerRow]): seq[FolderController] =
  for r in rows:
    result.add FolderController(label: r.label, viewseg: r.viewseg,
      controller: r.controller, tip: r.tip)

proc loadReference(reference: FolderReference): tuple[held: HeldRef; problem: string] =
  result.held.startMs = reference.startMs
  result.held.name = reference.name
  if reference.path.len == 0: return
  try:
    let read = readReferenceFile(reference.path)
    result.held.samples = read.samples
    result.held.dtMs = if read.intervalUs > 0: read.intervalUs / 1000.0 else: NaN
    if result.held.name.len == 0:
      result.held.name = reference.path.extractFilename
  except CatchableError as e:
    result.problem = e.msg

proc judgeFile(ctx: JobContext; item: FolderListed; pairPath: string; pairInfo: SweepInfo;
    ask: VibQcAsk; choice: SignatureChoice; held: HeldRef; fileNo, count: int): FolderRow =
  let path = item.path
  let name = path.extractFilename
  var size: int64
  try:
    size = fs.getFileSize(path)
  except OSError as e:
    raise newException(IOError, name & " cannot be read (" & e.msg & ").")
  let modified = fs.getLastModificationTime(path)
  let bytes = readAll(ctx, path, size, fileNo, count)
  if ctx.cancelled: raise newException(JobCancelledError, "Cancelled.")
  var pair = SignaturePair()
  if item.info.kind == sgVib and pairPath.len > 0:
    pair = SignaturePair(path: pairPath, triggerNs: pairInfo.triggerNs,
      controller: pairInfo.controller, vibrator: pairInfo.vibrator,
      fileNumber: pairInfo.fileNumber, qc: pairInfo.qc)
  var log: DiagLog
  var s: Session = nil
  defer:
    s = nil
    clearCycleRoots()
  s = decodeToSession(bytes, path, modified, choice, log, pair)
  if ctx.cancelled: raise newException(JobCancelledError, "Cancelled.")
  let n = s.len
  if n == 0:
    raise newException(SignatureError, name & " has no trace.")
  let dtMs = s.filePtr[].traceKeys(0).intervalUs / 1000.0
  var rows: seq[seq[float32]] = @[]
  var names: seq[string] = @[]
  var codes: seq[int16] = @[]
  for t in 0 ..< n:
    if ctx.cancelled: raise newException(JobCancelledError, "Cancelled.")
    rows.add readRawTrace(s.filePtr, path, t)
    codes.add s.filePtr[].traceKeys(t).traceCode
    if t < s.signature.traces.len: names.add s.signature.traces[t].name
    else: names.add "trace " & $(t + 1)
  let facts = s.signature
  let note = signatureForceNote(facts)
  s = nil
  clearCycleRoots()
  if held.samples.len > 0 and not sameDt(held.dtMs, dtMs):
    let why = if not (held.dtMs > 0 and held.dtMs < Inf):
        "the reference trace is at another interval: it has no sample interval"
      else: intervalRefusal(held.dtMs, dtMs)
    return FolderRow(path: path, kind: facts.kind, pair: pairPath, outcome: foProblem,
      problem: why)
  let roles = folderRoles(codes, facts.kind, ask.accelSet)
  var at: array[VibRole, int]
  at[vsReference] = roles.reference
  at[vsGroundForce] = roles.groundForce
  at[vsMass] = roles.mass
  at[vsBaseplate] = roles.baseplate
  var recorded = -1
  var aligned = ""
  if held.samples.len > 0:
    var stored = held.samples
    if roles.reference >= 0 and roles.reference < rows.len:
      let al = alignStored(rows[roles.reference], held.samples, dtMs)
      aligned = al.words
      if al.found: stored = placedSinc(held.samples, al.shiftMs, dtMs)
      recorded = roles.reference
    else:
      stored = startedAt(held.samples, held.startMs, dtMs)
    rows.add stored
    let label = if held.name.len > 0: held.name else: "reference"
    names.add label & " (archive)"
    at[vsReference] = rows.high
  let params = folderParams(ask, roles, facts.kind)
  let sig = folderSignature(facts, ask.forceScale, ask.accelSet, pair,
    ask.options.targetPct)
  var answer = vibratorOf(rows, names, at, dtMs, params, recorded, ask.topHz, NaN, note, sig)
  if answer.problem.len == 0:
    if held.samples.len > 0:
      let label = if held.name.len > 0: held.name else: "reference"
      answer.against = "Measured against the project reference " & label
    elif at[vsReference] >= 0 and at[vsReference] < names.len:
      # the window's sentence when no project reference is chosen
      answer.against = "Measured against the recorded reference, " &
        names[at[vsReference]] & " (no project reference is chosen)"
  var warnings: seq[string] = @[]
  for w in facts.warnings: addLine(warnings, w)
  for w in fitLines(facts): addLine(warnings, w)
  addLine(warnings, aligned)
  addLines(warnings, answer.warning)
  addLine(warnings, answer.band.warning)
  addLine(warnings, answer.hundredProblem)
  addLine(warnings, answer.judgeWarning)
  addLine(warnings, answer.controllerNote)
  addLine(warnings, answer.against)
  if answer.problem.len > 0:
    return FolderRow(path: path, kind: facts.kind, pair: pairPath, outcome: foProblem,
      problem: answer.problem, polarity: answer.polarity.line, warnings: warnings)
  FolderRow(path: path, kind: facts.kind, pair: pairPath, outcome: foJudged,
    verdict: answer.qc.verdict, sentence: answer.qc.line,
    measures: measuresOf(answer.qc.rows), polarity: answer.polarity.line,
    warnings: warnings, controllers: controllersOf(answer.controller))

proc runFolder(ctx: JobContext; ask: VibQcAsk; weights: VibJobWeights;
    files: seq[FolderListed]; sink: FolderQcSink; choice: SignatureChoice;
    reference: FolderReference) =
  var table = FolderTable(problems: ask.problems, rows: @[])
  if not typedForce(ask.options.forceHundredPct) and
      not filesGiveForce(ask.options.targetPct, ask.forceScale) and
      ForceNotJudged notin table.problems:
    table.problems.add ForceNotJudged
  var keys: seq[PairKey] = @[]
  for f in files: keys.add pairKeyOf(f.path, f.info)
  let paired = pairSweeps(keys)
  table.weightWords = fleetWords(sweepsOf(files, paired.pairs))
  let count = files.len
  if count == 0:
    finish(sink, table)
    return
  if ctx.cancelled:
    skipFrom(table.rows, files, paired.pairs, 0)
    stopJob(sink, table)
  var held: HeldRef
  var gone = ""
  if reference.path.len > 0:
    let loaded = loadReference(reference)
    held = loaded.held
    if loaded.problem.len > 0 or held.samples.len == 0:
      let name = if held.name.len > 0: held.name
                 elif reference.name.len > 0: reference.name
                 else: reference.path.extractFilename
      let why = if loaded.problem.len > 0: loaded.problem
                else: "the reference file is missing"
      gone = "the reference \"" & name &
        "\" is no longer in the archive (" & why & ")"
  var done = 0
  for i, item in files:
    ctx.setPhase(filePhase(i, count, item.path))
    if ctx.cancelled:
      skipFrom(table.rows, files, paired.pairs, i)
      stopJob(sink, table)
    discard ctx.progress(int64(done) * FolderScale, int64(count) * FolderScale)
    let partner = paired.pairs.getOrDefault(item.path)
    let note = paired.notes.getOrDefault(item.path)
    try:
      var row: FolderRow
      if gone.len > 0:
        row = FolderRow(path: item.path, kind: item.info.kind, pair: partner,
          outcome: foProblem, problem: gone)
      elif item.info.problem.len > 0:
        row = FolderRow(path: item.path, kind: item.info.kind, pair: partner,
          outcome: foProblem, problem: item.info.problem)
      elif item.info.kind notin {sgDat, sgVib}:
        row = FolderRow(path: item.path, kind: item.info.kind, pair: partner,
          outcome: foProblem, problem: item.path.extractFilename &
          " is not a signature file.")
      else:
        row = judgeFile(ctx, item, partner, infoOf(files, partner), ask, choice, held, i, count)
      row.weightWords = weightFindings(item.info.weights, weights.holdDownKg,
        weights.baseplateMassKg, weights.reactionMassKg)
      if note.len > 0: row.warnings.add note
      table.rows.add stamped(row, item.info, infoOf(files, partner), partner)
    except JobCancelledError:
      table.rows.add stamped(FolderRow(path: item.path, kind: item.info.kind,
        pair: partner, outcome: foSkipped, problem: "Cancelled."), item.info,
        infoOf(files, partner), partner)
      skipFrom(table.rows, files, paired.pairs, i + 1)
      stopJob(sink, table)
    except CatchableError as e:
      if ctx.cancelled:
        table.rows.add stamped(FolderRow(path: item.path, kind: item.info.kind,
          pair: partner, outcome: foSkipped, problem: "Cancelled."), item.info,
          infoOf(files, partner), partner)
        skipFrom(table.rows, files, paired.pairs, i + 1)
        stopJob(sink, table)
      let why = if e.msg.len > 0: e.msg else: $e.name
      table.rows.add stamped(FolderRow(path: item.path, kind: item.info.kind,
        pair: partner, outcome: foProblem, problem: why,
        weightWords: weightFindings(item.info.weights, weights.holdDownKg,
        weights.baseplateMassKg, weights.reactionMassKg)), item.info,
        infoOf(files, partner), partner)
    inc done
    discard ctx.progress(int64(done) * FolderScale, int64(count) * FolderScale)
  finish(sink, table)

proc folderQcWork*(ask: VibQcAsk; weights: VibJobWeights; files: seq[FolderListed];
    sink: FolderQcSink; choice = SignatureChoice();
    reference = FolderReference()): JobWork =
  ## Judges each of `files` in order, on a job thread (`folderQcSpec`).
  ## `weights` are compared with a `.vib` header and never applied. `choice`
  ## is the open choice; the default is the file's own. `reference.path`,
  ## when set, is read once and used instead of the recorded pilot when the
  ## sample interval agrees. A reference that cannot be read, or that has no
  ## samples, is a problem on every row and no file is judged. One file is
  ## open at a time. The sink is set before this returns.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      runFolder(ctx, ask, weights, files, sink, choice, reference)
