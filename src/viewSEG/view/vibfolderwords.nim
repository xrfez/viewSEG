## Words for a folder vibrator QC table: column labels, one text line per
## file, and the same columns as CSV. Drawing lives in the frontend.

import std/[os, strutils]
import ../core/[vibfolderqc, vibjudge]

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
  if t.contributed > 0:
    result.add " "
    result.add $t.contributed
    result.add " contributed."

func verdictCell(row: FolderRow): string =
  case row.outcome
  of foJudged: $row.verdict
  of foContributed: "contributed"
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
