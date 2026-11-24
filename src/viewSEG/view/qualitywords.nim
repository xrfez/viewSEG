## Words for the Trace quality window and the Reports menu. Drawing lives in
## the frontend; this module holds the sentences.

import std/strutils
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
  ColHeaderDead* = "Dead"
  ColAllZero* = "Zero"
  ColConstant* = "Flat"
  ColClipped* = "Clipped"
  ColSpiky* = "Spiky"
  ColDcOffset* = "DC"
  ColNonFinite* = "Not finite"
  ColNoisy* = "Noisy"
  ColWeak* = "Weak"
  ColBadRecords* = "Bad records"
  DeadTip* = "A trace the header marks dead. It is not also counted as all-zero."
  ZeroTip* = "Every finite sample is zero."
  FlatTip* = "The samples are constant."
  DcTip* = "The samples have a DC offset."
  NonFiniteTip* = "A sample is not a finite number."
  NoisyTip* = "Traces much louder than the others of their record, outside the area around " &
    "the source. Not counted as bad. Empty when the record could not be judged."
  WeakTip* = "Traces much quieter than the others of their record. Not counted as bad. " &
    "Empty when the record could not be judged."
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

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func totalsLine*(t: Totals): string =
  ## The totals strip: counts, then each finding, then the noisy and weak traces when any
  ## trace was tested. Killed is not bad.
  plural(t.files, "file", "files") & ", " & plural(t.records, "record", "records") & ", " &
    plural(t.traces, "trace", "traces") & ", " & $t.killed & " killed, " & $t.bad & " bad, " &
    $t.stations & " stations, " & $t.counts[qfHeaderDead] & " header-dead, " &
    $t.counts[qfAllZero] & " all-zero, " & $t.counts[qfConstant] & " constant, " &
    $t.counts[qfClipped] & " clipped, " & $t.counts[qfSpiky] & " spiky, " &
    $t.counts[qfDcOffset] & " dc offset, " & $t.counts[qfNonFinite] & " non-finite" &
    (if t.tested > 0: ", " & $t.noisy & " noisy, " & $t.weak & " weak" else: "")

func headerTip*(name: string): string =
  ## The tooltip of column title `name`, or "" when the title says enough.
  case name
  of ColKilled: KilledTip
  of ColBad: BadTip
  of ColHeaderDead: DeadTip
  of ColAllZero: ZeroTip
  of ColConstant: FlatTip
  of ColDcOffset: DcTip
  of ColNonFinite: NonFiniteTip
  of ColNoisy: NoisyTip
  of ColWeak: WeakTip
  else: ""

func unreadNote*(rows: openArray[tuple[path, why: string]]): string =
  ## One line under the totals when a file or a trace could not be read, or ""
  ## when none could not. A reason that starts with "trace " is one trace; any
  ## other reason is one file.
  if rows.len == 0: return ""
  var files, traces = 0
  for row in rows:
    if row.why.startsWith("trace "): inc traces
    else: inc files
  let filePart = if files > 0: plural(files, "file", "files") else: ""
  let tracePart = if traces > 0: plural(traces, "trace", "traces") else: ""
  if files > 0 and traces > 0: filePart & " and " & tracePart & " could not be read."
  elif files > 0: filePart & " could not be read."
  else: tracePart & " could not be read."

func countLabel*(what: string; n: int): string =
  ## A button label with its count.
  what & " (" & $n & ")"
