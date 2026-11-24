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
  FilterHint* = "Filter by file name"
  SourceLabel* = "Source"
  DestLabel* = "Destination"
  FormatLabel* = "Format"
  KeepFolders* = "Keep the sub folders"
  OptReversals* = "Polarity reversals"
  OptKilled* = "Drop killed traces"
  OptFilters* = "Own filters"
  OptProcessing* = "Processing"
  OptShifts* = "Time shifts"
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
  WidthTip* = "Shorter numbers get leading zeros. Longer numbers are never cut."
  AddPart* = "Add part"
  SavePattern* = "Save"
  DeletePattern* = "Delete"
  UpPart* = "Up"
  DownPart* = "Down"
  RemovePart* = "Remove"

func summaryLine*(written, failed, skipped: int): string =
  ## One sentence for the totals under the results.
  $written & " written, " & $failed & " failed, " & $skipped & " skipped."

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

func tickedLine*(files: int; size: string): string =
  ## "3 files ticked, 6.4 MB", under the tree.
  let word = if files == 1: "file" else: "files"
  $files & " " & word & " ticked, " & size

func folderCount*(name: string; on, total: int): string =
  ## "sub (1 of 1)": how many of a folder's files are ticked.
  name & " (" & $on & " of " & $total & ")"

func resultsText*(lines: openArray[string]; written, failed, skipped: int): string =
  ## The results table, as text, for the clipboard.
  result = ColFile & "\t" & ColOutcome & "\t" & ColWritten & "\t" & ColDropped &
    "\t" & ColNotes & "\n"
  for line in lines:
    result.add line
    result.add '\n'
  result.add summaryLine(written, failed, skipped)
  result.add '\n'
