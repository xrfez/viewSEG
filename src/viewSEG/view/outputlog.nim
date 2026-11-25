## The text of an Output run's log, for the file Export log... writes: when the
## run was, the source and destination, the options in force, the totals, and
## for every file its row and all its notes, in file order. No toolkit; the
## window holds the run's record and the job writes the text.

import std/[os, sequtils, strutils, times]
import ../core/[outputbatch, outputjobs, outputrevision]
import filetable, outputbinaryedit, outputtextedit, outputwords

type
  RunRecord* = object
    ## What the run was asked, as the window had it when Run was clicked.
    startedAt*: string                 ## local time, "2026-11-25 14:03:59"
    source*, dest*: string
    format*: OutputFormat
    revision*: OutputRevision
    reversals*, dropKilled*, ownFilters*, processing*, shifts*, sortOn*: bool
    keepOwnPositions*, correlated*, mirror*: bool
    processingSentence*: string        ## what the Processing tick wrote, when it was on
    reference*: string                 ## the reference when Correlated
    sort*: string                      ## the plot's keys when the Sort tick was on
    pattern*: string                   ## the file names' pattern, "" for the source's names
    textHeader*, binaryHeader*: string ## the templates in use, "" for none

func logName*(t: DateTime): string =
  ## "viewSEG-output-20261125-140359.txt": the name offered for the file.
  "viewSEG-output-" & t.format("yyyyMMdd-HHmmss") & ".txt"

func nowText*(t: DateTime): string =
  t.format("yyyy-MM-dd HH:mm:ss")

func onOff(b: bool): string =
  if b: "on" else: "off"

func oneLine(s: string): string =
  ## `s` with a line end or a tab written as `\n`, `\r` or `\t`, so one item stays on
  ## its lines (a Linux file name may hold them).
  if s.anyIt(it in {'\n', '\r', '\t'}):
    for c in s:
      case c
      of '\n': result.add "\\n"
      of '\r': result.add "\\r"
      of '\t': result.add "\\t"
      else: result.add c
  else:
    result = s

func slashed(path: string): string =
  ## A Windows path with `/`; on Linux a backslash is a character of the name.
  oneLine(if DirSep == '\\': path.replace('\\', '/') else: path)

func logText*(rec: RunRecord; r: BatchResult; sizes: openArray[int64]): string =
  ## `sizes[i]`: the bytes of the file written for `r.items[i]`, -1 when not known
  ## or not written.
  var lines: seq[string] = @[]
  lines.add "viewSEG output log"
  lines.add "Run: " & rec.startedAt
  lines.add "Source: " & oneLine(rec.source)
  lines.add "Destination: " & oneLine(rec.dest)
  lines.add "Format: " & $rec.format
  lines.add "Revision: " & rec.revision.revisionLabel
  lines.add OptReversals & ": " & onOff(rec.reversals)
  lines.add OptKilled & ": " & onOff(rec.dropKilled)
  lines.add OptFilters & ": " & onOff(rec.ownFilters)
  lines.add OptProcessing & ": " & onOff(rec.processing) &
    (if rec.processing and rec.processingSentence.len > 0: " (" & rec.processingSentence & ")"
      else: "")
  lines.add OptShifts & ": " & onOff(rec.shifts)
  lines.add OptSort & ": " & (if rec.sortOn and rec.sort.len > 0: rec.sort
    else: onOff(rec.sortOn))
  lines.add KeepOwnPositions & ": " & onOff(rec.keepOwnPositions)
  lines.add OptCorrelated & ": " & (if rec.correlated: rec.reference else: "off")
  lines.add KeepFolders & ": " & onOff(rec.mirror)
  lines.add FileNamesLabel & ": " & (if rec.pattern.len > 0: rec.pattern else: AsSourceFile)
  if rec.format == ofSegy:
    lines.add TextRowLabel & ": " & (if rec.textHeader.len > 0: rec.textHeader
      else: TextAsSource)
    lines.add BinaryRowLabel & ": " & (if rec.binaryHeader.len > 0: rec.binaryHeader
      else: BinaryAsSource)
  lines.add summaryLine(r.written, r.failed, r.skipped, r.correlatedWith)
  if r.cancelled: lines.add "The run was stopped before every file was written."
  if r.reason.len > 0: lines.add oneLine(r.reason)
  for i, item in r.items:
    lines.add ""
    lines.add "File: " & slashed(item.relative)
    lines.add "  Written as: " & (if item.outcome == boWritten and item.destination.len > 0:
      oneLine(item.destination) else: "-")
    var outcome = $item.outcome
    if item.outcome == boFailed and item.why.len > 0: outcome.add ": " & oneLine(item.why)
    lines.add "  Result: " & outcome
    lines.add "  Size: " & (if i < sizes.len and sizes[i] >= 0: sizeText(sizes[i]) & " (" &
      $sizes[i] & " bytes)" else: "-")
    lines.add "  Traces: " & $item.writtenTraces & " written, " & $item.droppedTraces &
      " dropped"
    if item.lines.len == 0: lines.add "  Notes: none"
    else:
      lines.add "  Notes:"
      for note in item.lines: lines.add "    - " & oneLine(note)
  lines.join("\n") & "\n"
