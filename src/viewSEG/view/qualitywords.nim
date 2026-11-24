## Words for the Trace quality window and the Reports menu. Drawing lives in
## the frontend; this module holds the sentences.

import ../core/qualityreport

const
  QualityTip* = "Traces in the open folder that are dead, all zero, constant, " &
    "clipped, spiky, offset or not finite. A killed trace is counted as killed, not as bad."
  NeedFolder* = "Open a folder first."
  Ready* = "Ready."
  Scanning* = "Scanning the folder."
  Stopped* = "The scan was stopped."
  ScanFailed* = "The scan failed."
  Listing* = "Listing the folder."
  CannotList* = "The folder could not be listed."
  CappedNote* = "The list stopped at the file limit; later files were not scanned."
  ExportButton* = "Export CSV..."
  RescanButton* = "Rescan"
  CancelButton* = "Cancel"
  UnreadFiles* = "Unread"
  StationsTab* = "Stations"
  RecordsTab* = "Records"
  WithTotals* = "totals in a second file"
  TotalsTip* = "Also write a file beside the one you save, with -totals before the extension."
  SuggestedName* = "trace-quality.csv"
  Written* = "Wrote the CSV."
  ExportFailed* = "The CSV could not be written."
  NoRows* = "Nothing to show."
  NoneUnread* = "No file was unread."
  ColLine* = "Line"
  ColPoint* = "Point"
  ColIndex* = "Index"
  ColComponent* = "Component"
  ColSeen* = "Seen"
  ColKilled* = "Killed"
  ColBad* = "Bad"
  ColHeaderDead* = "Header-dead"
  ColAllZero* = "All-zero"
  ColConstant* = "Constant"
  ColClipped* = "Clipped"
  ColSpiky* = "Spiky"
  ColDcOffset* = "DC offset"
  ColNonFinite* = "Non-finite"
  ColBadRecords* = "Bad records"
  ColFile* = "File"
  ColRecord* = "Record"
  KilledTip* = "A trace an edit killed. It is counted as killed, not as bad, and it is not " &
    "measured."
  BadTip* = "Traces with a finding. A killed trace is not among them."
  FilterStations* = "Filter by line, point, index or component"
  FilterRecords* = "Filter by file name or record"
  FilterStationsTip* = "Show only the stations whose line, point, index, component or " &
    "bad-record text holds every word typed here."
  FilterRecordsTip* = "Show only the records whose file name or record number holds every " &
    "word typed here."

func qualityReady*(hasFolder: bool): bool =
  ## Whether Reports > Trace quality can start a scan. A relation file is not needed.
  hasFolder

func qualityWhy*(hasFolder: bool): string =
  ## One sentence naming what is missing, or "" when a scan can start.
  if not hasFolder: NeedFolder else: ""

func totalsLine*(t: Totals): string =
  ## The totals strip: counts, then each finding. Killed is not bad.
  $t.files & " files, " & $t.records & " records, " & $t.traces & " traces, " &
    $t.killed & " killed, " & $t.bad & " bad, " & $t.stations & " stations, " &
    $t.counts[qfHeaderDead] & " header-dead, " & $t.counts[qfAllZero] & " all-zero, " &
    $t.counts[qfConstant] & " constant, " & $t.counts[qfClipped] & " clipped, " &
    $t.counts[qfSpiky] & " spiky, " & $t.counts[qfDcOffset] & " dc offset, " &
    $t.counts[qfNonFinite] & " non-finite"

func countLabel*(what: string; n: int): string =
  ## A button label with its count.
  what & " (" & $n & ")"
