## A folder of vibrator signature files, judged and listed: one row per file,
## totals, a stable sort and a filter. Pure: no file is opened and no sample
## is read. The job that fills a table is `core/vibfolderjobs`; the sentences
## are `view/vibfolderwords`.

import std/[algorithm, math, options, os, strutils, tables]
from sigtypes import SignatureKind, SweepInfo, VibWeights, groupDigits
import shotfollow, shotfollowtarget, shotlog, sigjudge, units, vibjudge

const
  ListingPhase* = "Listing the folder."
  CannotListFolder* = "The folder could not be listed."

type
  FolderOutcome* = enum
    ## What a row is. A paired file keeps its own verdict.
    foJudged = "judged"
    foProblem = "problem"
    foSkipped = "skipped"

  FolderMeasure* = object
    ## One limit, as judged. `measured` is NaN when that limit was not judged.
    limit*: QcLimit
    measured*: float64
    bound*: float64
    atMs*: float64
    status*: QcStatus
    why*: string

  FolderController* = object
    ## One line of the controller's QC beside this window's.
    label*, viewseg*, controller*, tip*: string

  FolderShot* = object
    ## The shot log's row for a sweep, as the log gives it. `found` is false
    ## when no log is loaded or no row fits; the texts are then empty.
    found*: bool
    ffid*, line*, point*: string

  FolderRow* = object
    ## One file. `pair` is the partner's path, or "". A paired file keeps its
    ## own verdict, sentence and measures. `controller`, `vibrator` and
    ## `triggerNs` are what the file list shows (a `.vib` takes its partner's);
    ## 0 is not known. `query` is what a shot log is asked.
    path*: string
    kind*: SignatureKind
    pair*: string
    controller*: int64
    vibrator*: int
    triggerNs*: int64
    timeIsStart*: bool ## `triggerNs` is the second a lone `.vib` began
    query*: ShotQuery
    shot*: FolderShot
    outcome*: FolderOutcome
    verdict*: QcVerdict
    sentence*: string
    measures*: seq[FolderMeasure]
    polarity*: string
    warnings*: seq[string]
    problem*: string
    forceWhy*: string
      ## why this judged file's force limits were not judged, in words; "": they were
      ## (or the file was not judged)
    extraPolarity*: string
    extraWarnings*: seq[string]
    weightWords*: seq[string]
    controllers*: seq[FolderController]

  FolderColumn* = enum
    ## A column a sort key names. Measures sort by the measured number.
    fcPath, fcKind, fcPair, fcOutcome, fcVerdict, fcSentence, fcPolarity, fcProblem
    fcController, fcVibrator, fcTime
    fcAvgPhase, fcPeakPhase, fcAvgDistortion, fcPeakDistortion, fcAvgForce, fcPeakForce

  FolderTotals* = object
    ## Counts of the rows in hand. `passed`, `failed` and `notJudged` are
    ## judged rows only. Every file is counted under its own verdict.
    ## `forceNotJudged` counts judged rows whose force limits were not judged
    ## (also counted under their verdict).
    files*, passed*, failed*, notJudged*, problems*, skipped*, forceNotJudged*: int

  FolderTable* = object
    ## The rows, the profile's problems (said once) and the fleet's weight words.
    rows*: seq[FolderRow]
    problems*: seq[string]
    weightWords*: seq[string]
    cancelled*: bool
    totals*: FolderTotals

  FolderListed* = object
    ## One file the caller chose, with the header facts already read.
    path*: string
    info*: SweepInfo

  FolderReference* = object
    ## An archive reference the run may measure against. Empty `path`: the
    ## recorded pilot. Samples are never kept here.
    path*: string
    name*: string
    startMs*: float64 = NaN
    recorded*: bool
      ## the project's reference is a trace of the record: each file's recorded
      ## reference is used, and `name` is the rule's

func totalsOf*(rows: openArray[FolderRow]): FolderTotals =
  ## Counts of `rows`. `files` is every row.
  result.files = rows.len
  for row in rows:
    case row.outcome
    of foJudged:
      case row.verdict
      of qvPass: inc result.passed
      of qvFail: inc result.failed
      of qvNotJudged: inc result.notJudged
      if row.forceWhy.len > 0: inc result.forceNotJudged
    of foProblem: inc result.problems
    of foSkipped: inc result.skipped

func closeLb(headerLb, jobKg: float64): bool =
  ## Whether a header weight in pounds and a job weight in kilograms are the
  ## same mass, within half a pound or a thousandth, whichever is wider.
  if headerLb.isNaN or jobKg.isNaN: return true
  let jobLb = jobKg / KgPerLb
  let d = abs(headerLb - jobLb)
  d <= 0.5 or d <= 0.001 * max(abs(headerLb), abs(jobLb))

func weightBit(name: string; headerLb, jobKg: float64): string =
  if closeLb(headerLb, jobKg): return ""
  name & " " & groupDigits(int64(round(headerLb))) & " lb, the job's " &
    sensible(jobKg) & " kg"

func weightFindings*(header: VibWeights; holdDownKg, baseplateKg,
    reactionKg: float64): seq[string] =
  ## Where a `.vib` header's weights are not the job's. Words only: nothing
  ## is corrected or rescaled. Empty when the header states none, or the job
  ## set none, or they agree.
  if header.holdDownLb.isNaN and header.baseplateLb.isNaN and header.massLb.isNaN:
    return
  var bits: seq[string] = @[]
  for bit in [weightBit("hold-down", header.holdDownLb, holdDownKg),
      weightBit("baseplate", header.baseplateLb, baseplateKg),
      weightBit("reaction mass", header.massLb, reactionKg)]:
    if bit.len > 0: bits.add bit
  if bits.len == 0: return
  result.add "Header weights differ from the job's (" & bits.join("; ") & "). " &
    WeightsDepend

func fleetWords*(sweeps: openArray[tuple[vibrator: int;
    weights: VibWeights]]): seq[string] =
  ## The fleet's weight findings, one line each. A vibrator of 0 is not known.
  if sweeps.len == 0: return
  let fleet = perVibrator(sweeps)
  result = setsWords(fleet)
  for v in fleet.vibrators:
    if v.differs or v.sensDiffers or v.unlike or v.sensUnlike:
      result.add vibratorWords(v)
  let unknown = unknownWords(fleet.unknown)
  if unknown.len > 0: result.add unknown

proc attachPairs*(rows: var seq[FolderRow]) =
  ## Pairing adds the partner's name, and copies a judged `.vib`'s polarity
  ## and warnings onto its partner, the way a Vibrator window shows them on
  ## a file opened with its pair. Every file keeps its own verdict, sentence
  ## and measures, and is counted under that verdict. A problem or a skipped
  ## file keeps them too. An unpaired file is left as it is.
  var at = initTable[string, int]()
  for i, row in rows:
    at[row.path] = i
  for i in 0 ..< rows.len:
    let row = rows[i]
    if row.kind == sgVib and row.pair.len > 0 and row.outcome == foJudged and
        row.pair in at:
      let j = at[row.pair]
      if rows[j].extraPolarity.len == 0 and row.polarity.len > 0:
        rows[j].extraPolarity = row.polarity
      for w in row.warnings:
        if w notin rows[j].extraWarnings: rows[j].extraWarnings.add w
      for w in row.weightWords:
        if w notin rows[j].weightWords: rows[j].weightWords.add w
  for i in 0 ..< rows.len:
    if rows[i].pair.len == 0: continue
    let named = "Paired with " & rows[i].pair.extractFilename
    if named notin rows[i].warnings: rows[i].warnings.add named

func verdictRank(row: FolderRow): int =
  case row.outcome
  of foJudged:
    case row.verdict
    of qvFail: 0
    of qvNotJudged: 1
    of qvPass: 2
  of foProblem: 3
  of foSkipped: 4

func limitOf(c: FolderColumn): QcLimit =
  case c
  of fcAvgPhase: qlAvgPhase
  of fcPeakPhase: qlPeakPhase
  of fcAvgDistortion: qlAvgDistortion
  of fcPeakDistortion: qlPeakDistortion
  of fcAvgForce: qlAvgForce
  of fcPeakForce: qlPeakForce
  else: qlAvgPhase

func measuredOf(row: FolderRow; limit: QcLimit): float64 =
  result = NaN
  for m in row.measures:
    if m.limit == limit: return m.measured

func cmpFloat(a, b: float64): int =
  let an = a.isNaN
  let bn = b.isNaN
  if an and bn: 0
  elif an: 1
  elif bn: -1
  elif a < b: -1
  elif a > b: 1
  else: 0

func cmpCol(a, b: FolderRow; c: FolderColumn): int =
  case c
  of fcPath: cmp(a.path, b.path)
  of fcKind: cmp(ord(a.kind), ord(b.kind))
  of fcPair: cmp(a.pair, b.pair)
  of fcOutcome: cmp(ord(a.outcome), ord(b.outcome))
  of fcVerdict: cmp(verdictRank(a), verdictRank(b))
  of fcSentence: cmp(a.sentence, b.sentence)
  of fcPolarity: cmp(a.polarity, b.polarity)
  of fcProblem: cmp(a.problem, b.problem)
  of fcController: cmp(a.controller, b.controller)
  of fcVibrator: cmp(a.vibrator, b.vibrator)
  of fcTime: cmp(a.triggerNs, b.triggerNs)
  of fcAvgPhase, fcPeakPhase, fcAvgDistortion, fcPeakDistortion, fcAvgForce, fcPeakForce:
    cmpFloat(measuredOf(a, limitOf(c)), measuredOf(b, limitOf(c)))

proc sortedBy*(table: FolderTable; columns: openArray[FolderColumn]): FolderTable =
  ## `table` with its rows ordered by `columns`, the first the primary key.
  ## Equal keys keep their order. An unmeasured number sorts last.
  result = table
  if columns.len == 0 or result.rows.len < 2: return
  let rows = result.rows
  let keys = @columns
  var order = newSeq[int](rows.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort(proc (i, j: int): int =
    for c in keys:
      let d = cmpCol(rows[i], rows[j], c)
      if d != 0: return d
    cmp(i, j))
  var ordered = newSeq[FolderRow](order.len)
  for k, i in order: ordered[k] = rows[i]
  result.rows = ordered

func haystack(row: FolderRow): string =
  result = row.path & "\n" & $row.kind & "\n" & row.pair & "\n" & row.sentence &
    "\n" & row.polarity & "\n" & row.extraPolarity & "\n" & row.problem & "\n" &
    $row.verdict & "\n" & $row.outcome & "\n" & row.shot.ffid & "\n" & row.shot.line &
    "\n" & row.shot.point & "\n" & row.forceWhy
  if row.controller != 0: result.add "\n" & $row.controller
  if row.vibrator != 0: result.add "\n" & $row.vibrator
  for w in row.warnings: result.add '\n'; result.add w
  for w in row.extraWarnings: result.add '\n'; result.add w
  for w in row.weightWords: result.add '\n'; result.add w

proc filtered*(table: FolderTable; text: string): FolderTable =
  ## The rows whose path, kind, pair, sentence, polarity, problem, warnings
  ## or verdict contain `text`, ignoring case. Totals are of the rows kept.
  ## The profile's problems stay. Empty `text` keeps every row.
  result = table
  if text.len > 0:
    let want = text.toLowerAscii
    var kept: seq[FolderRow] = @[]
    for row in table.rows:
      if want in haystack(row).toLowerAscii: kept.add row
    result.rows = kept
  result.totals = totalsOf(result.rows)

func stamped*(row: FolderRow; info, partner: SweepInfo; pairPath: string): FolderRow =
  ## `row` with the electronics number, vibrator number, trigger time and shot
  ## log query of the sweep `info` (and, for a `.vib`, its partner `partner`
  ## when `pairPath` names one). A `.vib` has neither serial nor vibrator of
  ## its own: the partner's are used.
  result = row
  result.controller = info.controller
  result.vibrator = info.vibrator
  result.triggerNs = info.triggerNs
  result.timeIsStart = info.kind == sgVib and info.timeIsStart
  var pairNs = 0'i64
  var pairFile = -1'i64
  if info.kind == sgVib and pairPath.len > 0:
    if info.controller == 0: result.controller = partner.controller
    if info.vibrator == 0: result.vibrator = partner.vibrator
    pairNs = partner.triggerNs
    pairFile = partner.fileNumber
    if pairNs != 0:
      result.triggerNs = pairNs
      result.timeIsStart = false
  result.query = signatureQuery(info, pairNs, pairFile)

proc shotOf*(q: ShotQuery; ix: ShotIndex; view: ShotView): FolderShot =
  ## The row of `view` that `ix` (built from it) finds for `q`; none found
  ## when no row fits. A row's own numbers are given as the log has them.
  let m = match(ix, q)
  if m.row >= 0 and m.row < view.rows.len:
    let r = view.rows[m.row]
    result.found = true
    if r.fileNumber.isSome: result.ffid = $r.fileNumber.get
    if r.sourceLine == r.sourceLine: result.line = sensible(r.sourceLine)
    if r.shotPoint == r.shotPoint: result.point = sensible(r.shotPoint)
