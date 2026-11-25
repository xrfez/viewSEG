## Words for the Missing traces window and the Reports menu. Drawing lives in
## the frontend; this module holds the sentences.

import ../core/[missingjobs, missingreport]

const
  MenuTip* = "Stations the survey's relation records call for that a file does not hold: " &
    "the open file, or the files of a folder you choose."
  NeedFile* = "Open a file first."
  Ready* = "Ready."
  Scanning* = "Scanning."
  Stopped* = "The scan was stopped."
  ScanFailed* = "The scan failed."
  CappedNote* = "The list stopped at the file limit; later files were not scanned."
  NeedFolder* = "Choose a folder, then press Run."
  NoTemplate* = "No relation records (X records) are imported, so there is nothing to " &
    "check against: import a survey with an X or O relation file."
  Continuous* = "This file is a continuous receiver recording; it is not checked."
  NoTemplateRecord* = "No record of the file has a record in the relation records."
  NothingMissing* = "Every station the template calls for is in the data."
  ExportButton* = "Export CSV..."
  StopButton* = "Stop"
  RunButton* = "Run"
  FolderButton* = "Folder..."
  FileTab* = "File"
  FolderTab* = "Folder"
  SubfoldersBox* = "Include subfolders"
  SubfoldersTip* = "Also check the files of the folders inside the chosen folder."
  NoFolderChosen* = "No folder chosen."
  WithStats* = "statistics in a second file"
  StatsTip* = "Also write a file beside the one you save, with -statistics before the " &
    "extension."
  SuggestedName* = "missing-traces.csv"
  Written* = "Wrote the CSV."
  ExportFailed* = "The CSV could not be written."
  NoRows* = "Nothing to show."
  NoneSkipped* = "No file was skipped."
  NoneUnmatched* = "No record was left unmatched."
  SkippedFiles* = "Skipped"
  UnmatchedRecords* = "Unmatched"
  NotChecked* = "Not checked"
  NoneNotChecked* = "Every file was checked."
  ColLine* = "Line"
  ColPoint* = "Point"
  ColMissing* = "Missing"
  MissingTip* = "The records (of the files) whose relation record calls for this station and " &
    "that do not have it."
  FilterStations* = "Filter by line or point"
  FilterStationsTip* = "Show only the stations whose line or point holds every word typed here."
  ReceiversOption* = "Receiver stations (shot gathers)"
  SourcesOption* = "Source stations (receiver gathers)"

func stationNoun*(side: StationSide): string =
  ## "Receiver" for a shot gather's stations, "Source" for a receiver gather's.
  if side == ssReceivers: "Receiver" else: "Source"

func templateName*(s: MissingStats): string =
  ## The relation records the side is checked against.
  if s.side == ssReceivers: "X records"
  elif s.derived: "O records derived from the X records"
  else: "O records"

func statisticLines*(s: MissingStats; folder: bool): seq[string] =
  ## One line for each figure, worded for what is counted; the counts per
  ## record only when there is more than one record.
  let noun = s.side.stationNoun
  let where = if folder: "the files" else: "the file"
  result.add noun & " stations expected by the " & s.templateName & "."
  result.add noun & " stations in the template: " & $s.inTemplate
  result.add noun & " stations found in " & where & ": " & $s.found
  result.add noun & " stations missing: " & $s.missing
  result.add "Percent of the template missing: " & percentText(s.percentMissing) & "%"
  if s.records > 1:
    result.add "Counted per record, each station once for each record that calls for it: " &
      $s.expectedInRecords & " expected, " & $s.presentInRecords & " present, " &
      $s.missingInRecords & " missing, " & percentText(s.percentMissingInRecords) & "% missing"

func countsLine*(s: MissingStats; folder: bool): string =
  ## What was read: files (for a folder) and records.
  let records = $s.records & (if s.records == 1: " record" else: " records")
  if folder: $s.files & (if s.files == 1: " file, " else: " files, ") & records
  else: records

func countLabel*(what: string; n: int): string =
  ## A button label with its count.
  what & " (" & $n & ")"
