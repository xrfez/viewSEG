## A background job that judges each vibrator signature file of a folder the
## way one Vibrator window would, and fills a table (`core/vibfolderqc`).
## Up to the item pool's threads of files are open at once, and the rows are taken in file
## order. One file that cannot be read does not stop
## the rest. A cancel stops before the first file, between files and inside
## a file, and every file not judged is listed as skipped. The sink is set
## before the job returns, fails or is cancelled.
##
## Polarity is reported, and never changed from what a file says: a ground force is reversed
## for the analysis only where the user chose so for the file's layout in a Vibrator window,
## as that window does, and the row's polarity line says so. Job weights are never applied as
## masses: a header that disagrees is words only.

import std/[math, os, sets, strutils, tables]
import parseSEG
import parseSEG/common/diagnostics
import processSEG/core/shift
import analysis, filejobs, filekinds, filesystem, jobs, project, references, session, settings,
  signatures, sigjudge, sweepinfo, sweeppairs, threads, traceids, vibalign, vibanalysis,
  vibfolderqc, vibjudge, vibprofile
import sigtypes except QcLimit

var itemBudget* = 256'i64 shl 20
  ## Most bytes of files in hand at once. The pool lets the first file not yet taken run
  ## whatever its size, so a file over the budget runs alone and never waits for ever. Set only by tests.

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
    recorded: bool
    exactTopHz: float64 ## a generated reference's end frequency; NaN: not generated

func filePhase(i, n: int; path: string): string =
  "file " & $(i + 1) & " of " & $n & ": " & path.extractFilename

func sameDt(a, b: float64): bool {.inline.} =
  a > 0 and b > 0 and abs(a - b) <= 1e-9 * max(a, b)

func typedForce(x: float64): bool {.inline.} = x > 0 and x < Inf

const OwnLimitsNote* = "Judged with the project's QC profile limits; a window on this file " &
  "opens with its own remembered limits"
  ## said on a converter's SEG-Y row whose window would open with other limits, statistics
  ## window or harmonics than the profile's (`VibQcAsk.segyLimits`)

func sameNumber(a, b: float64): bool {.inline.} = a == b or (a.isNaN and b.isNaN)

func opensOtherwise(ask: VibQcAsk): bool =
  ## Whether a Vibrator window on a SEG-Y file opens with other limits, statistics window or
  ## harmonics than the profile's; false when they are not known.
  if ask.segyQcWindowMs.isNaN: return false
  result = not sameNumber(ask.segyQcWindowMs, ask.options.qcWindowMs) or
    ask.segyHarmonics != ask.options.harmonics
  for mine, theirs in fields(ask.options.qc, ask.segyLimits):
    if not sameNumber(mine, theirs): result = true

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
    if c.folder.len > 0 and not fs.dirExists(c.folder):
      raise newException(ValueError, CannotListFolder)
    var capped = false
    var paths: seq[string] = @[]
    try:
      paths = listedNames(choicePaths(c), c.subfolders, capped,
        proc (found: int): bool {.gcsafe, raises: [].} =
        ctx.progress(int64(found), 0))
    except OSError:
      raise newException(ValueError, CannotListFolder)
    ctx.checkCancelled()
    var chosen = initHashSet[string]()
    for f in c.files: chosen.incl f.normalizedPath
    var files: seq[FolderListed] = @[]
    for i, path in paths:
      ctx.checkCancelled()
      discard ctx.progress(int64(i), int64(paths.len))
      let kind = sniff(path)
      if kind == fkSegy and convertedSegy(path):
        # the external converter's SEG-Y from a signature file: judged with the signature files
        files.add FolderListed(path: path, info: SweepInfo(), converted: true)
        continue
      if kind notin SignatureFileKinds:
        if path in chosen:
          # a file the user chose is listed with its problem, never dropped
          let why = if fs.fileExists(path): path.extractFilename &
              " is not a signature file." else: path.extractFilename & " cannot be read."
          files.add FolderListed(path: path, info: SweepInfo(problem: why))
        continue
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

func chosenRoles*(roles: VibRoles; layouts: openArray[string]; codes: openArray[int16];
    count, first: int; signature = false): VibRoles =
  ## `roles` with the choice remembered for the layout of a record of `count` traces from
  ## trace `first` whose codes are `codes` (`layoutKey`), as a Vibrator window on that record
  ## takes it: for a `signature` file the ground force's polarity and the ground force switch
  ## (its places are its codes'; M and B stay as recorded), else the places (Swap mass and
  ## baseplate among them) with the polarities and the switch chosen with them. Unchanged when
  ## none is remembered for the layout, or a place is not in the record: `roles.judge` is then
  ## the one judged.
  result = roles
  var places: array[4, int]
  var polarity = Recorded
  if layouts.choiceFor(layoutKey(codes, count), places, polarity):
    if signature:
      # (Automatic is never offered for a signature file)
      result.groundForcePolarity = if polarity.gf == poAutomatic: poAsRecorded else: polarity.gf
      result.judge = polarity.judge
      return
    for p in places:
      if p >= count: return
    for p in places.mitems:
      if p >= 0: p += first
    (result.reference, result.groundForce, result.mass, result.baseplate) =
      (places[0], places[1], places[2], places[3])
    (result.source, result.handFile) = (rsRemembered, "")
    (result.groundForcePolarity, result.massPolarity, result.judge) = (polarity.gf, polarity.mb,
      polarity.judge)

proc folderParams*(ask: VibQcAsk; roles: VibRoles; kind: SignatureKind): AnalysisParams =
  ## The ask a Vibrator window would use, on `roles` as given (the ground force judged among
  ## them: the one chosen for the file's layout, `chosenRoles`), with the profile's masses and
  ## the made signal's 100 % force whatever is judged (none when the profile has none). A 100 %
  ## force the profile did not type stays unset. Its unit, and the accelerometer set
  ## a pound-counts force was typed on, are the ones the profile stored, never
  ## the set now judged and never guessed from the scale. A set an older
  ## project did not store stays unknown.
  AnalysisParams(roles: roles, harmonics: ask.options.harmonics,
    accelSet: ask.accelSet, qcWindowMs: ask.options.qcWindowMs, qc: ask.options.qc,
    forceHundredPct: ask.options.forceHundredPct,
    forceHundredUnit: ask.forceHundredUnit, forceHundredSet: ask.forceHundredSet,
    forceHundredSetKnown: ask.forceHundredSetKnown,
    targetPct: ask.options.targetPct, phaseShow: ask.options.phaseShow,
    reactionMassKg: ask.options.reactionMassKg, baseplateMassKg: ask.options.baseplateMassKg,
    forceHundredWeighted: ask.options.forceHundredWeighted, projectReference: false)

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
  if table.totals.forceNotJudged > 0 and ForceNotJudged notin table.problems:
    table.problems.add ForceNotJudged
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

proc readAll(ctx: ItemContext; path: string; size: int64): seq[byte] =
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
    discard ctx.progress(int64(got), size)

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
  result.held.recorded = reference.recorded
  result.held.exactTopHz = reference.exactTopHz
  if reference.path.len == 0: return
  try:
    let read = readReferenceFile(reference.path)
    result.held.samples = read.samples
    result.held.dtMs = if read.intervalUs > 0: read.intervalUs / 1000.0 else: NaN
    if result.held.name.len == 0:
      result.held.name = reference.path.extractFilename
  except CatchableError as e:
    result.problem = e.msg

func forceWhyNot(facts: SignatureFacts; ask: VibQcAsk; params: AnalysisParams;
    measures: seq[FolderMeasure]; hundredProblem: string; ownHundred: bool): string =
  ## Why this file's force limits were not judged, in words; "" when they were (or
  ## are off). The missing piece is named from what the file and the settings it was judged
  ## with (`params`) hold.
  var notJudged = false
  for m in measures:
    if m.limit in {qlAvgForce, qlPeakForce} and m.status == qsNotJudged and
        not m.bound.isNaN:
      notJudged = true
  if not notJudged: return
  result = "the force limits are not judged: "
  if hundredProblem.len > 0:
    result.add "the typed 100 % force does not apply (" & hundredProblem & ")"
  elif params.roles.judge == joWeighted and facts.kind == sgNone and
      typedForce(params.reactionMassKg) and typedForce(params.baseplateMassKg):
    # (a converter's file whose ground force is made: its own 100 % force is the one that counts)
    result.add(if typedForce(params.forceHundredWeighted):
        "no force was measured in the judged part"
      else: "no 100 % force is set for the ground force made from mass and baseplate")
  elif ownHundred:
    result.add "no force was measured in the judged part"
  elif ask.hundredConflict.len > 0 and facts.kind != sgNone:
    result.add "no 100 % force is set (" & ask.hundredConflict & ")"
  else:
    case facts.kind
    of sgDat:
      if not typedForce(ask.forceScale.datCountsPerLbf):
        result.add "no counts-per-pound scale is set"
      elif not facts.qc.valid or facts.qc.targetForceLbf <= 0:
        result.add "this file holds no target force"
      else:
        result.add "no drive level is set"
    of sgVib:
      if not typedForce(ask.forceScale.vibAccMvPerCount):
        result.add "no accelerometer constant is set"
      else:
        result.add "the header gives no hold-down weight"
    of sgNone:
      result.add "no 100 % force is typed for a SEG-Y file's recorded ground force (the " &
        "project's 100 % force is a signature file's, in another unit)"

proc judgeFile(ctx: ItemContext; item: FolderListed; pairPath: string; pairInfo: SweepInfo;
    ask: VibQcAsk; choice: SignatureChoice; held: HeldRef): FolderRow =
  let path = item.path
  let name = path.extractFilename
  var size: int64
  try:
    size = fs.getFileSize(path)
  except OSError as e:
    raise newException(IOError, name & " cannot be read (" & e.msg & ").")
  let modified = fs.getLastModificationTime(path)
  let bytes = if item.converted: newSeq[byte]() else: readAll(ctx, path, size)
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
  s = if item.converted: openSession(path)
    else: decodeToSession(bytes, path, modified, choice, log, pair)
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
  # the first record, as a window on it holds it: the layout its remembered roles are kept for
  var (first, count) = (0, n)
  if s.gathers.len > 0:
    (first, count) = (s.gathers[0].traces.a, s.gathers[0].traces.len)
  s = nil
  clearCycleRoots()
  if held.samples.len > 0 and not sameDt(held.dtMs, dtMs):
    let why = if not (held.dtMs > 0 and held.dtMs < Inf):
        "the reference trace is at another interval: it has no sample interval"
      else: intervalRefusal(held.dtMs, dtMs)
    return FolderRow(path: path, kind: facts.kind, pair: pairPath, outcome: foProblem,
      problem: why)
  var roles = folderRoles(codes, facts.kind, ask.accelSet)
  roles.judge = ask.judge # (the profile's, for a layout with no choice of its own)
  var topHz = ask.topHz
  if first in 0 ..< codes.len and first + count <= codes.len:
    template record: untyped = codes.toOpenArray(first, first + count - 1)
    # the roles the Vibrator window takes for the file's layout: a SEG-Y file's choice made by
    # hand there (Swap mass and baseplate), with its polarities; a signature file's places are
    # its codes', and the ground force's polarity chosen for the layout comes back
    roles = roles.chosenRoles(ask.layouts, record, count, first,
      signature = facts.kind != sgNone)
    if held.samples.len == 0:
      # measured against the recorded reference: the top typed for this file's layout, as
      # the window keeps it (a file of another layout never takes it)
      topHz = topsOf(ask.tops).topOf(recordedTopKey(record, count))
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
  var params = folderParams(ask, roles, facts.kind)
  # the project's one 100 % force, for every vibrator, in the unit and set it was given in
  # (`folderParams` takes them from the ask). A converter's SEG-Y is no signature file: its
  # recorded ground force is in its own unit, so it takes what a Vibrator window on it opens
  # with, the 100 % force and drive level typed for a SEG-Y window (none: not judged), never
  # the signature files' value read raw
  if item.converted:
    (params.forceHundredPct, params.forceHundredUnit) = (ask.segyHundredPct, "")
    params.targetPct = ask.segyTargetPct
  let sig = if item.converted: SignatureAsk()
    else: folderSignature(facts, ask.forceScale, ask.accelSet, pair, ask.options.targetPct)
  # (the window's check of the converter's order: said when the other order fits clearly better)
  let exactTopHz = if held.samples.len > 0: held.exactTopHz else: NaN
  var answer = vibratorOf(rows, names, at, dtMs, params, recorded, topHz, exactTopHz, note, sig,
    converterOrder = facts.kind == sgNone and isConverterLayout(codes))
  if answer.problem.len == 0:
    if held.samples.len > 0:
      let label = if held.name.len > 0: held.name else: "reference"
      answer.against = "Measured against the project reference " & label
    elif at[vsReference] >= 0 and at[vsReference] < names.len:
      # the window's sentence when no project reference is chosen
      let why = if held.recorded:
          "the project reference " & held.name & " is a trace of the record"
        else: "no project reference is chosen"
      answer.against = "Measured against the recorded reference, " &
        names[at[vsReference]] & " (" & why & ")"
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
  if item.converted and ask.opensOtherwise: addLine(warnings, OwnLimitsNote)
  if answer.problem.len > 0:
    return FolderRow(path: path, kind: facts.kind, pair: pairPath, outcome: foProblem,
      problem: answer.problem, polarity: answer.polarity.line, warnings: warnings)
  let measures = measuresOf(answer.qc.rows)
  let forceWhy = forceWhyNot(facts, ask, params, measures, answer.hundredProblem,
    typedForce(params.forceHundredPct))
  if forceWhy.len > 0:
    addLine(warnings, forceWhy.capitalizeAscii)
  FolderRow(path: path, kind: facts.kind, pair: pairPath, outcome: foJudged,
    verdict: answer.qc.verdict, sentence: answer.qc.line, forceWhy: forceWhy,
    measures: measures, polarity: answer.polarity.line,
    warnings: warnings, controllers: controllersOf(answer.controller))

type
  FolderItems = object
    ## What every item of the batch reads, never writes: the files, each one's partner
    ## (path and facts), and the one ask. No `ref` is inside it.
    files: seq[FolderListed]
    partners: seq[string]
    partnerInfos: seq[SweepInfo]
    ask: VibQcAsk
    choice: SignatureChoice
    choices: seq[SignatureChoice] ## each file's, when given (`folderQcWork`)
    held: HeldRef
    gone: string

static:
  doAssert plainData(FolderItems) and plainData(FolderRow)

proc judgeItem(it: ItemContext; a: ptr FolderItems; i: int): FolderRow {.nimcall, gcsafe.} =
  ## The row of file `i` before the job's own words are added: raises when the file cannot
  ## be judged.
  let item = a.files[i]
  let partner = a.partners[i]
  if a.gone.len > 0:
    FolderRow(path: item.path, kind: item.info.kind, pair: partner,
      outcome: foProblem, problem: a.gone)
  elif item.info.problem.len > 0:
    FolderRow(path: item.path, kind: item.info.kind, pair: partner,
      outcome: foProblem, problem: item.info.problem)
  elif item.info.kind notin {sgDat, sgVib} and not item.converted:
    FolderRow(path: item.path, kind: item.info.kind, pair: partner,
      outcome: foProblem, problem: item.path.extractFilename & " is not a signature file.")
  else:
    let choice = if i < a.choices.len: a.choices[i] else: a.choice
    judgeFile(it, item, partner, a.partnerInfos[i], a.ask, choice, a.held)

proc runFolder(ctx: JobContext; ask: VibQcAsk; weights: VibJobWeights;
    files: seq[FolderListed]; target: FolderQcSink; choice: SignatureChoice;
    choices: seq[SignatureChoice]; reference: FolderReference) =
  var table = FolderTable(problems: ask.problems, rows: @[])
  var keys: seq[PairKey] = @[]
  for f in files: keys.add pairKeyOf(f.path, f.info)
  let paired = pairSweeps(keys)
  table.weightWords = fleetWords(sweepsOf(files, paired.pairs))
  let count = files.len
  if count == 0:
    finish(target, table)
    return
  if ctx.cancelled:
    skipFrom(table.rows, files, paired.pairs, 0)
    stopJob(target, table)
  var held = HeldRef(exactTopHz: NaN)
  var gone = ""
  held.recorded = reference.recorded
  held.name = reference.name
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
  var args = FolderItems(files: files, ask: ask, choice: choice, choices: choices, held: held,
    gone: gone,
    partners: newSeq[string](count), partnerInfos: newSeq[SweepInfo](count))
  for i, item in files:
    args.partners[i] = paired.pairs.getOrDefault(item.path)
    args.partnerInfos[i] = infoOf(files, args.partners[i])
  proc take(i: int; outcome: sink ItemOutcome[FolderRow]) {.closure, gcsafe.} =
    let item = files[i]
    ctx.setPhase(filePhase(i, count, item.path))
    if ctx.cancelled:
      skipFrom(table.rows, files, paired.pairs, i)
      stopJob(target, table)
    let partner = args.partners[i]
    let partnerInfo = args.partnerInfos[i]
    let note = paired.notes.getOrDefault(item.path)
    if outcome.ok:
      var row = outcome.value
      row.weightWords = weightFindings(item.info.weights, weights.holdDownKg,
        weights.baseplateMassKg, weights.reactionMassKg)
      if note.len > 0: row.warnings.add note
      table.rows.add stamped(row, item.info, partnerInfo, partner)
    elif outcome.failure.cancelled or ctx.cancelled:
      table.rows.add stamped(FolderRow(path: item.path, kind: item.info.kind,
        pair: partner, outcome: foSkipped, problem: "Cancelled."), item.info,
        partnerInfo, partner)
      skipFrom(table.rows, files, paired.pairs, i + 1)
      stopJob(target, table)
    else:
      let e = outcome.failure
      let why = if e.msg.len > 0: e.msg else: e.name
      table.rows.add stamped(FolderRow(path: item.path, kind: item.info.kind,
        pair: partner, outcome: foProblem, problem: why,
        weightWords: weightFindings(item.info.weights, weights.holdDownKg,
        weights.baseplateMassKg, weights.reactionMassKg)), item.info, partnerInfo, partner)
  var sizes = newSeq[int64](count)
  for i, item in files:
    try:
      sizes[i] = max(0'i64, fs.getFileSize(item.path))
    except OSError:
      sizes[i] = 0 # the item says why it cannot be read
  ctx.setPhase("judging " & $count & (if count == 1: " file" else: " files"))
  let ran = ctx.parallelItems(count, addr args, judgeItem, take,
    ItemOptions(scale: FolderScale, cost: sizes, budget: itemBudget))
  if ran.taken < count:
    # a cancel the batch saw between files: the rest is skipped, as in a file
    skipFrom(table.rows, files, paired.pairs, ran.taken)
    stopJob(target, table)
  finish(target, table)

proc folderQcWork*(ask: VibQcAsk; weights: VibJobWeights; files: seq[FolderListed];
    sink: FolderQcSink; choice = SignatureChoice();
    reference = FolderReference(); choices: seq[SignatureChoice] = @[]): JobWork =
  ## Judges each of `files` in order, on a job thread (`folderQcSpec`).
  ## `weights` are compared with a `.vib` header and never applied. `choice`
  ## is the open choice; the default is the file's own. `choices`, when given, are each
  ## file's (`files[i]` is decoded with `choices[i]`, as a window opens it). `reference.path`,
  ## when set, is read once and used instead of the recorded pilot when the
  ## sample interval agrees. A reference that cannot be read, or that has no
  ## samples, is a problem on every row and no file is judged. Up to the item
  ## pool's threads of files are open at once, and the rows are taken in file
  ## order; the files in hand hold at most 256 MiB together (a file
  ## larger than that runs alone). The sink is set before this returns.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      runFolder(ctx, ask, weights, files, sink, choice, choices, reference)
