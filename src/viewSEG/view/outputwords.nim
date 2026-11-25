## Words for the Output window and File > Output.... Drawing lives in the
## frontend; this module holds the sentences.

const
  OutputTip* = "Write the seismic files of the folder open in the file list, " &
    "including the folders under it, as SEG-Y or SEG-D."
  OutputNeedFolder* = "Open a folder first."
  NeedFolder* = "Open a folder first."
  Listing* = "Listing the folder..."
  CannotList* = "The folder could not be listed."
  CappedNote* = "The list stopped at the file limit; later files were not listed."
  NoSeismic* = "No seismic file in this folder."
  Ready* = "Ready."
  Checking* = "Checking the destination."
  Writing* = "Writing."
  Stopped* = "Stopped."
  WriteFailed* = "The write failed."
  ListTitle* = "List files to write"
  CheckTitle* = "Check the destination"
  ChangeSource* = "Change source..."
  ChangeDest* = "Change destination..."
  AllButton* = "All"
  NoneButton* = "None"
  ShownButton* = "Only the shown file"
  RunButton* = "Run"
  StopButton* = "Stop"
  CopyButton* = "Copy results"
  OpenButton* = "Open destination"
  ExportLogButton* = "Export log..."
  ExportLogTip* = "Save the run's log as a text file: when it ran, the options, the totals, " &
    "and every file's row with all its notes. Available once a run has ended."
  ExportTitle* = "Export the output log"
  ExportPhase* = "writing the log"
  ExportFailed* = ExportTitle & " failed"
  FilterHint* = "Filter by file name"
  SourceLabel* = "Source"
  DestLabel* = "Destination"
  FormatLabel* = "Format"
  RevisionLabel* = "Revision"
  RevisionSegyTip* = "Same as the source: a SEG-Y file keeps its own revision and headers; " &
    "a SEG-D or SEG-2 file is written as Rev 2.1. A revision named here rewrites the " &
    "headers as that revision; the notes list what it could not keep."
  RevisionSegdTip* = "Same as the source: a SEG-D file keeps its own revision, which " &
    "is the only choice for it; a SEG-Y or SEG-2 file is written as Rev 3.0. Rev 3.1 " &
    "is offered when no ticked file is SEG-D."
  RevisionMixedNote* = "A mix of standards: each file of the standard written keeps its " &
    "own revision, the others are written as Rev 2.1 (SEG-Y) or Rev 3.0 (SEG-D)."
  KeepFolders* = "Keep the sub folders"
  OptReversals* = "Polarity reversals"
  OptKilled* = "Drop killed traces"
  OptFilters* = "Own filters"
  OptProcessing* = "Processing"
  OptShifts* = "Time shifts"
  OptCorrelated* = "Correlated"
  CorrelatedTip* = "Correlate each trace with the project's reference while writing. " &
    "Samples are written as 32-bit float."
  CorrelatedNeedRef* = "Choose a reference sweep in the project to write correlated data."
  CorrelatedNeedArchive* = "The reference archive is still being read."
  CorrelatedPilotTip* = "Correlate each trace with the pilot, a trace of each record, " &
    "taken from the record being written. A record without that trace fails. " &
    "Samples are written as 32-bit float."
  OptSort* = "Sort"
  KeepOwnPositions* = "Keep the file's own positions"
  ColFile* = "File"
  ColOutcome* = "Outcome"
  ColWritten* = "Written"
  ColDropped* = "Dropped"
  ColNotes* = "Notes"
  TickNone* = "Tick at least one file."
  NeedDest* = "Choose a destination folder."
  GainTip* = "Display-only gain is not written."
  ProcessingTip* = "The Seismic window's filters. Display-only gain is not written."
  SortTip* = "Write traces in the plot's sort. A SEG-D file is sorted within each record."
  KeepOwnTip* = "Off: a survey join or a station move is written into the headers, " &
    "including when they are built from the trace keys. On: the file's own positions " &
    "are written from its header keys. The notes say what was stored."
  MirrorTip* = "On: a file in a sub folder is written in that sub folder. Off: every " &
    "file is written in the destination folder."
  FilterTip* = "Show only the files whose names hold this text. A folder stays when a " &
    "file under it matches. All and None still cover every listed file."
  ShownTip* = "Tick the file the Seismic window shows, and no other."
  RunTip* = "Write every ticked seismic file. A file already open is written as it " &
    "stands, including edits not yet saved."
  CopyTip* = "Copy the results table to the clipboard."
  OpenTip* = "Open the destination folder."
  FileNamesLabel* = "File names"
  AsSourceFile* = "As the source file"
  EditNames* = "Edit..."
  LeastDigits* = "Least digits"
  VendorPartTip* = "The name of a vendor field, as the display lines list it (a bare name, " &
    "or block.name when two fields share it). Its value over the file's traces is written; " &
    "a file where the traces differ, or lack it, is not written."
  WidthTip* = "Shorter numbers get leading zeros. Longer numbers are never cut."
  AddPart* = "Add part"
  SavePattern* = "Save"
  DeletePattern* = "Delete"
  UpPart* = "Up"
  DownPart* = "Down"
  RemovePart* = "Remove"
  SeparatorLabel* = "Separator"
  ExampleLabel* = "Example:"
  PatternNameHint* = "Name of this pattern"

func separatorChoice*(ch: string): string =
  ## `"." dot`: the separator character in quotes, then its word.
  let word = case ch
    of ".": "dot"
    of "_": "underscore"
    of "-": "hyphen"
    else: ch
  "\"" & ch & "\" " & word

func summaryLine*(written, failed, skipped: int; correlatedWith = ""): string =
  ## One sentence for the totals under the results. A correlated run adds
  ## "correlated with <reference name>".
  result = $written & " written, " & $failed & " failed, " & $skipped & " skipped"
  if correlatedWith.len > 0:
    result.add ", correlated with "
    result.add correlatedWith
  result.add "."

func sortTip*(keys: string): string =
  ## The sort checkbox's tooltip, naming the plot's keys when there are any.
  result = SortTip
  if keys.len > 0:
    result.add " Now: "
    result.add keys
    result.add "."

func runWhy*(ticked: int; dest: string): string =
  ## Why Run stays inactive, or "" when a file is ticked and a destination is set.
  let none = ticked <= 0
  let noDest = dest.len == 0
  if none and noDest: TickNone & " " & NeedDest
  elif none: TickNone
  elif noDest: NeedDest
  else: ""

func tickedLine*(files: int; size: string; pattern = ""): string =
  ## "3 files ticked, 6.4 MB", under the tree. A chosen pattern adds
  ## "named by <label>".
  let word = if files == 1: "file" else: "files"
  result = $files & " " & word & " ticked, " & size
  if pattern.len > 0:
    result.add ", named by "
    result.add pattern

func folderCount*(name: string; on, total: int): string =
  ## "sub (1 of 1)": how many of a folder's files are ticked.
  name & " (" & $on & " of " & $total & ")"

func resultsText*(lines: openArray[string]; written, failed, skipped: int;
    correlatedWith = ""): string =
  ## The results table, as text, for the clipboard.
  result = ColFile & "\t" & ColOutcome & "\t" & ColWritten & "\t" & ColDropped &
    "\t" & ColNotes & "\n"
  for line in lines:
    result.add line
    result.add '\n'
  result.add summaryLine(written, failed, skipped, correlatedWith)
  result.add '\n'
