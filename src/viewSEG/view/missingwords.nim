## Words for the Missing traces window and the Reports menu. Drawing lives in
## the frontend; this module holds the sentences.

import std/[math, strutils]
import ../core/missingjobs

const
  MenuTip* = "Stations the relation file expected that this folder's files did not record, " &
    "and records short of their spread."
  NeedFolder* = "Open a folder first."
  Ready* = "Ready."
  Scanning* = "Scanning the folder."
  Stopped* = "The scan was stopped."
  ScanFailed* = "The scan failed."
  Listing* = "Listing the folder."
  CannotList* = "The folder could not be listed."
  CappedNote* = "The list stopped at the file limit; later files were not scanned."
  NotSortable* = "This column is not sorted."
  ExportButton* = "Export CSV..."
  RescanButton* = "Rescan"
  StopButton* = "Stop"
  FolderTab* = "Folder"
  RecordsTab* = "Records"
  WithPoints* = "with missing points"
  WithTotals* = "totals in a second file"
  PointsTip* = "On the Records tab, write one row per missing station instead of one row " &
    "per record."
  TotalsTip* = "Also write a file beside the one you save, with -totals before the extension."
  SuggestedName* = "missing-traces.csv"
  Written* = "Wrote the CSV."
  ExportFailed* = "The CSV could not be written."
  NoRows* = "Nothing to show."
  NoneSkipped* = "No file was skipped."
  NoneUnmatched* = "No record was left unmatched."
  SkippedFiles* = "Skipped"
  UnmatchedRecords* = "Unmatched"
  ColLine* = "Line"
  ColPoint* = "Point"
  ColIndex* = "Index"
  ColExpectedIn* = "Expected in"
  ColMissingIn* = "Missing in"
  ColNever* = "Never"
  ColUnknown* = "Unknown"
  ColFirstFile* = "First file"
  ColFirstRecord* = "First record"
  ColLastFile* = "Last file"
  ColLastRecord* = "Last record"
  ColFile* = "File"
  ColRecord* = "Record"
  ColExpected* = "Expected"
  ColPresent* = "Present"
  ColMissing* = "Missing"
  ColDuplicates* = "Duplicates"
  ColExtras* = "Extras"
  ColAlsoIn* = "Also in"
  ColMissingPoints* = "Missing points"
  FigFiles* = "files"
  FigRecords* = "records"
  FigExpected* = "expected"
  FigPresent* = "present"
  FigMissing* = "missing"
  FigNever* = "never recorded"
  FigDuplicates* = "duplicates"
  FigExtras* = "extras"
  FigNoData* = "survey records with no data"
  NeverTip* = "Missing from every record the relation file expected this station in."
  UnknownTip* = "Missing, and those records have no spread, so this is not evidence " &
    "the station was expected."
  FilterFolder* = "Filter by line or point"
  FilterRecords* = "Filter by file name"
  FilterFolderTip* = "Show only the stations whose line or point holds every word typed here."
  FilterRecordsTip* = "Show only the records whose file name holds every word typed here."

func missingReady*(hasFolder, hasSurvey: bool): bool =
  ## Whether Reports > Missing traces can start a scan.
  hasFolder and hasSurvey

func missingWhy*(hasFolder, hasSurvey: bool): string =
  ## One sentence naming what is missing, or "" when a scan can start.
  ## A missing folder is named first.
  if not hasFolder: NeedFolder
  elif not hasSurvey: NoSurvey
  else: ""

func percentText*(x: float64): string =
  ## `x` with no fraction when it is a whole number, otherwise two places.
  if x == round(x) and abs(x) < 1e15: $int64(x) else: formatFloat(x, ffDecimal, 2)

func totalsLine*(files, records, expected, present, missing, never, duplicates, extras,
    noData: int; percent: float64): string =
  ## The totals strip: counts, then the missing share.
  $files & " files, " & $records & " records, " & $expected & " expected, " &
    $present & " present, " & $missing & " missing (" & percentText(percent) & "%), " &
    $never & " never, " & $duplicates & " duplicates, " & $extras & " extras, " &
    $noData & " survey records with no data"

func countLabel*(what: string; n: int): string =
  ## A button label with its count.
  what & " (" & $n & ")"
