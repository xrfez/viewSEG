## Words for the Shot log window. Drawing lives in the frontend.

import std/[strutils, times]
import ../core/[shotfollow, shotfollowtarget, shotlog]

const
  WindowTip* = "A shot log: one row per shot, with a time in UTC and the problems the reader found."
  ImportTip* = "A shot log (a CSV or text table of shots). With a project open it is kept with " &
    "the project; otherwise it lasts for this run only."
  SessionOnly* = "session only"
  NoLog* = "No shot log is loaded."
  Reading* = "Reading..."
  ColumnsButton* = "Columns..."
  ApplyButton* = "Apply"
  CancelButton* = "Cancel"
  GuessButton* = "Guess again"
  ProblemsOnly* = "Problems only"
  AllowEditing* = "Allow editing"
  AllowEditingTip* = "Change cells here. A log corrected outside the program is better " &
    "imported again."
  FollowPlot* = "Follow the plot"
  FollowPlotTip* = "Show the row of the trace under the pointer, of a selected vibrator " &
    "signature, or of the selected file, matched by time."
  PointerRow = "Trace under the pointer: row "
  SignatureRow = "Selected signature: row "
  FileRow = "Selected file: row "
  ByTime = ", by time"
  ByTimeAndNumbers = ", by time and numbers"
  WithinSecond = ", within the second"
  ByNumbers = ", by numbers only"
  RowsAtTime = " rows at this time"
  NoRowAtTime = "No row at this time"
  HiddenByFilter = ", hidden by the filter"
  FilterHint* = "Filter"
  GridTab* = "Grid"
  ProblemsTab* = "Problems"
  TimeHeader* = "Time (UTC)"
  StatusHeader* = " "
  EmptyProblems* = "No problems."
  CappedNote* = "The list shows the first problems only."
  DuplicateTail* = " is chosen more than once"
  RevertCell* = "Revert to the file's value"
  UndoCellTip* = "Undo the last cell edit"
  RedoCellTip* = "Redo the cell edit undone last"

proc utcMicrosText*(us: int64): string =
  ## UTC microseconds since 1970 as a date and time, to the microsecond.
  var sec = us div 1_000_000
  var frac = us mod 1_000_000
  if frac < 0:
    frac += 1_000_000
    dec sec
  fromUnix(sec).utc.format("yyyy-MM-dd HH:mm:ss") & "." & align($frac, 6, '0')

func followStatus*(a: ShotFollowAnswer; hidden: bool): string =
  ## The follow line, or "" when there is nothing to follow. `hidden` adds
  ## that the one row is left out by the filter.
  if a.source == sfNone: return ""
  if a.match.count > 1: return $a.match.count & RowsAtTime
  if a.match.row < 0: return NoRowAtTime
  let who = case a.source
    of sfPointer: PointerRow
    of sfSignature: SignatureRow
    of sfFile: FileRow
    of sfNone: ""
  let how = case a.match.rule
    of mrTime: ByTime
    of mrTimeAndNumbers: ByTimeAndNumbers
    of mrSecond: WithinSecond
    of mrNumbers: ByNumbers
    of mrNone: ""
  result = who & $(a.match.row + 1) & how
  if hidden: result.add HiddenByFilter

func shotLogSummary*(file: string; rows, columns, problems: int; where: string): string =
  ## The window's top line.
  file & " · " & $rows & " rows · " & $columns & " columns · " & $problems &
    " problems · " & where

func roleUnique*(role: ColumnRole): bool =
  ## A meaning that should belong to one column only.
  case role
  of crIgnored, crText, crStatus, crSourceType, crSourceId, crGunArray: false
  else: true

func duplicateRoles*(roles: openArray[ColumnRole]): seq[ColumnRole] =
  ## Unique roles chosen more than once, in the order they repeat.
  var seen = newSeq[bool](ColumnRole.high.ord + 1)
  var flagged = newSeq[bool](ColumnRole.high.ord + 1)
  for r in roles:
    if not roleUnique(r): continue
    let i = r.ord
    if seen[i] and not flagged[i]:
      flagged[i] = true
      result.add r
    seen[i] = true

func duplicateSentence*(role: ColumnRole): string =
  label(role) & DuplicateTail

func delimChar*(d: Delimiter): char =
  case d
  of dlComma: ','
  of dlTab: '\t'
  of dlSemicolon: ';'
  of dlSpaces: ' '

func quoteCell*(s: string; d: char): string =
  ## `s` quoted when it holds the delimiter, a quote or a new line.
  if d in s or '"' in s or '\n' in s or '\r' in s:
    result = "\""
    for c in s:
      if c == '"': result.add '"'
      result.add c
    result.add '"'
  else:
    result = s

func joinRow*(cells: openArray[string]; d: char): string =
  ## One delimited row, cells quoted where they need it.
  result = ""
  for i, c in cells:
    if i > 0: result.add d
    result.add quoteCell(c, d)

func splitSentinels*(text: string): seq[string] =
  ## Non-empty lines of the sentinel box.
  for line in text.splitLines:
    let s = line.strip
    if s.len > 0: result.add s

func sentinelsText*(items: openArray[string]): string =
  items.join("\n")
