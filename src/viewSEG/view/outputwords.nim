## Words for the Output window and File > Output.... Drawing lives in the
## frontend; this module holds the sentences.

const
  OutputTip* = "Write the seismic files of the folder open in the file list, " &
    "including the folders under it, as SEG-Y or SEG-D."
  OutputNeedFolder* = "Open a folder first."
  NeedFolder* = "Open a folder first."
  Listing* = "Listing the folder."
  CannotList* = "The folder could not be listed."
  CappedNote* = "The list stopped at the file limit; later files were not listed."
  NoSeismic* = "No seismic file in this folder."
  Ready* = "Ready."
  Checking* = "Checking the destination."
  Writing* = "Writing."
  Stopped* = "The write was stopped."
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
  ColFile* = "File"
  ColOutcome* = "Outcome"
  ColWritten* = "Written"
  ColDropped* = "Dropped"
  GainTip* = "Display-only gain is not written."
  ProcessingTip* = "The Seismic window's filters. Display-only gain is not written."
  SortTip* = "Write traces in the plot's sort. A SEG-D file is sorted within each record."
  MirrorTip* = "On: a file in a sub folder is written in that sub folder. Off: every " &
    "file is written in the destination folder."
  FilterTip* = "Show only the files whose names hold this text. A folder stays when a " &
    "file under it matches. All and None still cover every listed file."
  ShownTip* = "Tick the file the Seismic window shows, and no other."
  RunTip* = "Write every ticked seismic file. A file already open is written as it " &
    "stands, including edits not yet saved."
  CopyTip* = "Copy the results table to the clipboard."
  OpenTip* = "Open the destination folder."

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

func resultsText*(lines: openArray[string]; written, failed, skipped: int): string =
  ## The results table, as text, for the clipboard.
  result = ColFile & "\t" & ColOutcome & "\t" & ColWritten & "\t" & ColDropped & "\n"
  for line in lines:
    result.add line
    result.add '\n'
  result.add summaryLine(written, failed, skipped)
  result.add '\n'
