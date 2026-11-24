## Words for a folder vibrator QC table: column labels, one text line per
## file, and the same columns as CSV. Drawing lives in the frontend.

import std/[math, os, strutils]
import ../core/[settings, units, vibfolderqc, vibjudge, vibprofile]

const
  ColFile* = "File"
  ColKind* = "Kind"
  ColPair* = "Pair"
  ColVerdict* = "Verdict"
  ColSentence* = "Sentence"
  ColPolarity* = "Polarity"
  ColWarnings* = "Warnings"
  ColProblem* = "Problem"

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
  result = @[ColFile, ColKind, ColPair, ColVerdict, ColSentence]
  for l in QcLimit: result.add measureHead(l)
  result.add ColPolarity
  result.add ColWarnings
  result.add ColProblem

func summaryLine*(t: FolderTotals): string =
  ## One line for the counts under the table.
  result = $t.files & " files, " & $t.passed & " pass, " & $t.failed &
    " fail, " & $t.notJudged & " not judged, " & $t.problems & " problems, " &
    $t.skipped & " skipped."

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

func warningsCell(row: FolderRow): string =
  result = joinWords(row.warnings)
  if row.extraWarnings.len > 0:
    if result.len > 0: result.add "; "
    result.add "From the pair: "
    result.add joinWords(row.extraWarnings)
  if row.weightWords.len > 0:
    if result.len > 0: result.add "; "
    result.add joinWords(row.weightWords)

func cells(row: FolderRow): seq[string] =
  result = @[row.path.extractFilename, $row.kind, row.pair.extractFilename,
    verdictCell(row), row.sentence]
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

func resultsText*(table: FolderTable): string =
  ## The table as text: the profile's problems, a header, one row per line,
  ## the counts, then the fleet's weight words.
  for p in table.problems:
    result.add p
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
    result.add csvField(p)
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
  NoProfile* = "No profile yet: open a signature file, set the Vibrator " &
    "window as you want it, and choose Use as profile"
  ProfileStored* = "Stored as the project's vibrator QC profile."
  FolderTip* = "Judge each vibrator signature file in the open folder, " &
    "including the folders under it, with the project's profile."
  NeedFolder = "Open a folder first."
  Ready* = "Ready."
  Listing* = "Listing the folder."
  Judging* = "Judging the signature files."
  Stopped* = "The run was stopped."
  RunFailed* = "The run failed."
  CannotList* = "The folder could not be listed."
  NoFiles* = "No signature files in this folder."
  NoTicked* = "Tick at least one file."
  NoRows* = "No results yet. Tick the files and choose Run."
  RunButton* = "Run"
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

func rowCells*(row: FolderRow): seq[string] =
  ## The cells of one row, in `headers` order.
  cells(row)

func folderReady*(hasFolder: bool): bool =
  ## Whether Reports > Vibrator QC of a folder can open. A profile is not
  ## needed to open the window.
  hasFolder

func folderWhy*(hasFolder: bool): string =
  ## One sentence naming what is missing, or "" when the item can open.
  if not hasFolder: NeedFolder else: ""

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

proc sortColumn*(name: string; col: var FolderColumn): bool =
  ## The sort key `name` is, when that header sorts. False for Warnings.
  if name == ColFile: col = fcPath
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
