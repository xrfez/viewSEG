## Words for a folder vibrator QC table: column labels, one text line per
## file, and the same columns as CSV. Drawing lives in the frontend.

import std/[math, os, strutils]
from ../core/sigtypes import SignatureKind, sgDat, sgNone, sgVib, timeText
import ../core/[project, settings, units, vibfolderconf, vibfolderqc, vibjudge, vibprofile]

const
  ColFile* = "File"
  ColController* = "Electronics number"
  ColVibrator* = "Vibrator number"
  ColTime* = "Time"
  ColFfid* = "FFID"
  ColSourceLine* = "Source line"
  ColSourcePoint* = "Source point"
  ColKind* = "Kind"
  ColPair* = "Pair"
  ColVerdict* = "Verdict"
  ColSentence* = "Sentence"
  ColPolarity* = "Polarity"
  ColWarnings* = "Warnings"
  ColProblem* = "Problem"
  DatKindLabel* = ".dat signature file"
  VibKindLabel* = ".vib file"
  ArchiveMissing* = "The reference is not in the archive."
  RecordedReference* = "Measured against each file's recorded reference."

func measureHead(l: QcLimit): string =
  case l
  of qlAvgPhase: "Average phase (°)"
  of qlPeakPhase: "Peak phase (°)"
  of qlAvgDistortion: "Average distortion (%)"
  of qlPeakDistortion: "Peak distortion (%)"
  of qlAvgForce: "Average force (%)"
  of qlPeakForce: "Peak force (%)"

func headers*(): seq[string] =
  ## The column labels, in order.
  result = @[ColFile, ColController, ColVibrator, ColTime, ColFfid, ColSourceLine,
    ColSourcePoint, ColKind, ColPair, ColVerdict, ColSentence]
  for l in QcLimit: result.add measureHead(l)
  result.add ColPolarity
  result.add ColWarnings
  result.add ColProblem

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func summaryLine*(t: FolderTotals): string =
  ## One line for the counts under the table. One of a kind is singular.
  plural(t.files, "file", "files") & ", " & plural(t.passed, "pass", "passes") & ", " &
    plural(t.failed, "fail", "fails") & ", " & $t.notJudged & " not judged, " &
    plural(t.problems, "problem", "problems") & ", " &
    plural(t.skipped, "skipped", "skipped") & "."

func kindLabel*(kind: SignatureKind): string =
  ## What the Kind column shows. The two signature files do not share a prefix,
  ## so a narrow column cannot show the same word for both.
  case kind
  of sgDat: DatKindLabel
  of sgVib: VibKindLabel
  of sgNone: ""

func sentenceOf*(row: FolderRow): string =
  ## The sentence column. A file that was not judged has its reason here, not
  ## only in the problem column.
  if row.sentence.len > 0: row.sentence else: row.problem

func verdictCell(row: FolderRow): string =
  case row.outcome
  of foJudged: $row.verdict
  of foProblem: "problem"
  of foSkipped: "skipped"

func measureCell(row: FolderRow; limit: QcLimit): string =
  for m in row.measures:
    if m.limit == limit:
      return measuredText(QcRow(limit: m.limit, measured: m.measured, bound: m.bound,
        atMs: m.atMs, status: m.status, why: m.why))
  "-"

func joinWords(parts: seq[string]): string =
  var kept: seq[string] = @[]
  for p in parts:
    if p.len > 0: kept.add p
  kept.join("; ")

func polarityCell(row: FolderRow): string =
  result = row.polarity
  if row.extraPolarity.len > 0:
    if result.len > 0: result.add "; "
    result.add "From the pair: "
    result.add row.extraPolarity

func tickedCount*(on, total: int): string =
  ## "3 of 3": how many of the listed files are ticked.
  $on & " of " & $total

func warningsCell*(row: FolderRow): string =
  ## Warnings for the row, including a pair's and the weight comparison.
  result = joinWords(row.warnings)
  if row.extraWarnings.len > 0:
    if result.len > 0: result.add "; "
    result.add "From the pair: "
    result.add joinWords(row.extraWarnings)
  if row.weightWords.len > 0:
    if result.len > 0: result.add "; "
    result.add joinWords(row.weightWords)

func numberCell(n: int64): string =
  if n > 0: $n else: ""

func timeCell*(row: FolderRow): string =
  ## The sweep's trigger time as the file list shows it: to the millisecond;
  ## a lone `.vib` states only the second its recording began.
  if row.triggerNs == 0: ""
  elif row.timeIsStart: "began " & timeText(row.triggerNs, 0)[11 .. ^1]
  else: timeText(row.triggerNs, 3)

func cells(row: FolderRow): seq[string] =
  result = @[row.path.extractFilename, numberCell(row.controller),
    numberCell(row.vibrator), timeCell(row), row.shot.ffid, row.shot.line, row.shot.point,
    kindLabel(row.kind), row.pair.extractFilename, verdictCell(row), sentenceOf(row)]
  for l in QcLimit: result.add measureCell(row, l)
  result.add polarityCell(row)
  result.add warningsCell(row)
  result.add row.problem

func flat(s: string): string =
  ## Tabs and line breaks become spaces, so one row stays one line.
  result = newStringOfCap(s.len)
  for c in s:
    if c in {'\t', '\n', '\r'}: result.add ' '
    else: result.add c

func csvField(s: string): string =
  if ',' in s or '"' in s or '\n' in s or '\r' in s:
    result = "\""
    for c in s:
      if c == '"': result.add "\"\""
      else: result.add c
    result.add '"'
  else: result = s

func shownProblem*(text: string): string =
  ## What the window says for a profile problem. An empty reference id is each
  ## file's recorded reference, not a missing archive entry. A named reference
  ## that is missing keeps the archive sentence.
  if text == ArchiveMissing: RecordedReference else: text

func resultsText*(table: FolderTable): string =
  ## The table as text: the profile's problems, a header, one row per line,
  ## the counts, then the fleet's weight words.
  for p in table.problems:
    result.add shownProblem(p)
    result.add '\n'
  var head: seq[string] = @[]
  for h in headers(): head.add flat(h)
  result.add head.join("\t")
  result.add '\n'
  for row in table.rows:
    var line: seq[string] = @[]
    for c in cells(row): line.add flat(c)
    result.add line.join("\t")
    result.add '\n'
  result.add summaryLine(totalsOf(table.rows))
  result.add '\n'
  for w in table.weightWords:
    result.add w
    result.add '\n'

func resultsCsv*(table: FolderTable): string =
  ## The same columns as CSV. A field with a comma, a quote or a line break
  ## is quoted, and a quote in it is doubled.
  for p in table.problems:
    result.add csvField(shownProblem(p))
    result.add '\n'
  var head: seq[string] = @[]
  for h in headers(): head.add csvField(h)
  result.add head.join(",")
  result.add '\n'
  for row in table.rows:
    var line: seq[string] = @[]
    for c in cells(row): line.add csvField(c)
    result.add line.join(",")
    result.add '\n'
  result.add csvField(summaryLine(totalsOf(table.rows)))
  result.add '\n'
  for w in table.weightWords:
    result.add csvField(w)
    result.add '\n'

const
  ProfileStored* = "Stored as the project's vibrator QC profile."
  FolderTip* = "Judge the vibrator signature files you choose, with the project's " &
    "vibrator QC configuration."
  NoShotLog* = "No shot log is loaded: FFID and source point are not shown."
  NothingChosen* = "Choose a folder or files."
  FolderButton* = "Folder..."
  FilesButton* = "Files..."
  SubfoldersLabel* = "Include subfolders"
  SubfoldersTip* = "Also run the files in the folders under the chosen folder. Off: " &
    "only the files in the folder itself."
  ChosenFolder* = "Folder: "
  ChosenFiles* = "Files: "
  Ready* = "Ready."
  Listing* = ListingPhase
  Judging* = "Judging the signature files."
  Stopped* = "The run was stopped."
  RunFailed* = "The run failed."
  CannotList* = CannotListFolder
  NoFiles* = "No signature files in this folder."
  NoTicked* = "Tick at least one file."
  NoRows* = "No results yet. Choose a folder or files, tick them and choose Run."
  RunButton* = "Run"
  AllButton* = "All"
  NoneButton* = "None"
  CancelButton* = "Cancel"
  CopyButton* = "Copy"
  ExportButton* = "Export CSV..."
  Written* = "The CSV was written."
  ExportFailed* = "The CSV was not written."
  FilesTab* = "Files"
  ResultsTab* = "Results"
  FilterHint* = "Filter the rows"
  CappedNote* = "The list stopped at the file limit; later files were not listed."
  SuggestedName* = "vibrator-qc.csv"
  HoldDownLabel* = "Hold-down"
  BaseplateLabel* = "Baseplate"
  ReactionLabel* = "Reaction mass"
  WeightsHint* = "Job weights, kilograms. Compared with each file's header and never " &
    "applied. Empty: not set."
  NeedProjectWeights* = "A project is needed to store the job weights."

func rowCells*(row: FolderRow): seq[string] =
  ## The cells of one row, in `headers` order.
  cells(row)


func offOr(x: float64; suffix: string): string =
  if x.isNaN: "off" else: sensible(x) & suffix

func scaleBit(s: ForceScale): string =
  if not s.datCountsPerLbf.isNaN:
    result = ".dat " & sensible(s.datCountsPerLbf) & " counts/lbf"
  if not s.vibAccMvPerCount.isNaN:
    if result.len > 0: result.add ", "
    result.add ".vib " & sensible(s.vibAccMvPerCount) & " mV/count"

func profileLines*(p: VibQcProfile): seq[string] =
  ## One or two plain lines naming the settings a folder QC run will use.
  var line = "Window " & sensible(p.qcWindowMs) & " ms, " & $p.harmonics &
    " harmonics, set " & $p.accelSet & "."
  let scale = scaleBit(p.forceScale)
  if scale.len > 0:
    line.add " Force scale "
    line.add scale
    line.add "."
  if not p.forceHundredPct.isNaN:
    line.add " 100% force " & sensible(p.forceHundredPct)
    if p.forceHundredUnit.len > 0:
      line.add " "
      line.add p.forceHundredUnit
    line.add "."
  if not p.targetPct.isNaN:
    line.add " Drive " & sensible(p.targetPct) & "%."
  if not p.topHz.isNaN:
    line.add " Top " & sensible(p.topHz) & " Hz."
  if p.referenceId.len > 0:
    line.add " Reference " & p.referenceId & "."
  result = @[line]
  let lim = p.limits
  result.add "Average phase " & offOr(lim.avgPhaseDeg, "°") &
    ", peak phase " & offOr(lim.peakPhaseDeg, "°") &
    ", average distortion " & offOr(lim.avgDistortionPct, "%") &
    ", peak distortion " & offOr(lim.peakDistortionPct, "%") &
    ", average force " & offOr(lim.avgForcePct, "%") &
    ", peak force " & offOr(lim.peakForcePct, "%") & "."

func configLines*(c: VibQcConfig): seq[string] =
  ## The configuration a run uses, as read-only lines: the reference measured
  ## against, the file it was set from when known, the settings, then the job's
  ## weights when any is set.
  let against = if c.profile.referenceId.len == 0:
      "each file's recorded reference"
    elif c.referenceName.len > 0: c.referenceName
    else: c.profile.referenceId
  var head = "Reference: " & against & "."
  if c.profile.fromFile.len > 0:
    head.add " Configured from " & c.profile.fromFile & "."
  result = @[head]
  result.add profileLines(c.profile)
  var kg: seq[string] = @[]
  if not c.weights.holdDownKg.isNaN: kg.add "hold-down " & sensible(c.weights.holdDownKg) & " kg"
  if not c.weights.baseplateMassKg.isNaN:
    kg.add "baseplate " & sensible(c.weights.baseplateMassKg) & " kg"
  if not c.weights.reactionMassKg.isNaN:
    kg.add "reaction mass " & sensible(c.weights.reactionMassKg) & " kg"
  if kg.len > 0: result.add "Job weights: " & kg.join(", ") & "."

proc sortColumn*(name: string; col: var FolderColumn): bool =
  ## The sort key `name` is, when that header sorts. False for Warnings.
  if name == ColFile: col = fcPath
  elif name == ColController: col = fcController
  elif name == ColVibrator: col = fcVibrator
  elif name == ColTime: col = fcTime
  elif name == ColKind: col = fcKind
  elif name == ColPair: col = fcPair
  elif name == ColVerdict: col = fcVerdict
  elif name == ColSentence: col = fcSentence
  elif name == measureHead(qlAvgPhase): col = fcAvgPhase
  elif name == measureHead(qlPeakPhase): col = fcPeakPhase
  elif name == measureHead(qlAvgDistortion): col = fcAvgDistortion
  elif name == measureHead(qlPeakDistortion): col = fcPeakDistortion
  elif name == measureHead(qlAvgForce): col = fcAvgForce
  elif name == measureHead(qlPeakForce): col = fcPeakForce
  elif name == ColPolarity: col = fcPolarity
  elif name == ColProblem: col = fcProblem
  else: return false
  true

func columnLabel*(col: FolderColumn): string =
  ## The header `col` sorts, in `headers` order. `fcOutcome` is not a column
  ## the table draws.
  case col
  of fcPath: ColFile
  of fcKind: ColKind
  of fcController: ColController
  of fcVibrator: ColVibrator
  of fcTime: ColTime
  of fcPair: ColPair
  of fcOutcome: "Outcome"
  of fcVerdict: ColVerdict
  of fcSentence: ColSentence
  of fcAvgPhase: measureHead(qlAvgPhase)
  of fcPeakPhase: measureHead(qlPeakPhase)
  of fcAvgDistortion: measureHead(qlAvgDistortion)
  of fcPeakDistortion: measureHead(qlPeakDistortion)
  of fcAvgForce: measureHead(qlAvgForce)
  of fcPeakForce: measureHead(qlPeakForce)
  of fcPolarity: ColPolarity
  of fcProblem: ColProblem
