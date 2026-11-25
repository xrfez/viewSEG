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
  KilledNote* = "Killed traces count as present: the file is checked as it is on disk."
  SingleSliceNote* = "This file holds one shot slice of one receiver: the other shots of " &
    "this receiver are in other files. Run the folder to check the receiver as a whole."
  SignatureNote* = "A vibrator signature file is not checked: it holds no survey stations."
  Continuous* = "This file is a continuous receiver recording; it is not checked."
  NoTemplateRecord* = "No record of the file has a record in the relation records."
  NothingMissing* = "Every station the template calls for is in the data."
  FiguresTip* = "In the template, found and missing: each station (line and point) counts " &
    "once, over all the records. In the line counted per record, a station counts once for " &
    "each record that calls for it, so found and missing can add up to more than the " &
    "template: a station found in one record and missing from another is in both."
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
    let each = if s.side == ssSources: "receiver" else: "record"
    result.add "Counted per " & each & ", each station once for each " & each &
      " that calls for it: " &
      $s.expectedInRecords & " expected, " & $s.presentInRecords & " present, " &
      $s.missingInRecords & " missing, " & percentText(s.percentMissingInRecords) & "% missing"

func countsLine*(s: MissingStats; folder: bool): string =
  ## What was read: files (for a folder) and records; for a receiver side, the
  ## receivers checked (a receiver cut into slices is one check).
  let noun = if s.side == ssSources: "receiver" else: "record"
  let records = $s.records & " " & noun & (if s.records == 1: "" else: "s")
  if folder: $s.files & (if s.files == 1: " file, " else: " files, ") & records
  else: records

func countLabel*(what: string; n: int): string =
  ## A button label with its count.
  what & " (" & $n & ")"
