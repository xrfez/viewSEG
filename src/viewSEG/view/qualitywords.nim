## Words for the Trace quality window and the Reports menu. Drawing lives in
## the frontend; this module holds the sentences.

import std/strutils
import ../core/[missingreport, qualityreport]
from missingwords import ReceiversOption, SourcesOption, UntoldLabel, UntoldTip, UntoldNames,
  stationNoun
export ReceiversOption, SourcesOption, UntoldLabel, UntoldTip, UntoldNames, stationNoun

const
  QualityTip* = "Traces that are dead, all zero, constant, clipped, spiky, offset or not " &
    "finite, and stations that lack a component: the open file, or the files of a folder " &
    "you choose. A killed trace is counted as killed, not as bad."
  NeedFile* = "Open a file first."
  NeedFolder* = "Choose a folder, then press Run."
  Ready* = "Ready."
  Scanning* = "Scanning."
  Stopped* = "The scan was stopped."
  ScanFailed* = "The scan failed."
  CappedNote* = "The list stopped at the file limit; later files were not scanned."
  ExportButton* = "Export CSV..."
  StopButton* = "Stop"
  RunButton* = "Run"
  FolderButton* = "Folder..."
  FileTab* = "File"
  FolderTab* = "Folder"
  SubfoldersBox* = "Include subfolders"
  SubfoldersTip* = "Also measure the files of the folders inside the chosen folder."
  NoFolderChosen* = "No folder chosen."
  UnreadFiles* = "Unread"
  WithStats* = "statistics in a second file"
  StatsTip* = "Also write a file beside the one you save, with -statistics before the " &
    "extension."
  SuggestedName* = "trace-quality.csv"
  Written* = "Wrote the CSV."
  ExportFailed* = "The CSV could not be written."
  NoRows* = "Nothing to show."
  ExportIsData* = "The CSV was not written: that file is one the scan read, or one that is " &
    "open in viewSEG."
  SignatureNote* = "A vibrator signature file is not measured here: use Vibrator QC."
  NoStations* = "No trace of the file has a station."
  NoneUnread* = "No file was unread."
  ColLine* = "Line"
  ColPoint* = "Point"
  ColLacking* = "Lacks component"
  ColLackFiles* = "Files lacking"
  ColSeen* = "Traces"
  ColKilled* = "Killed"
  ColBad* = "Bad"
  ColHeaderDead* = "Dead"
  ColAllZero* = "All zero"
  ColConstant* = "Constant"
  ColClipped* = "Clipped"
  ColSpiky* = "Spiky"
  ColDcOffset* = "DC offset"
  ColNonFinite* = "Not finite"
  ColNoisyTested* = "Tested (noisy)"
  ColNoisy* = "Noisy"
  ColWeakTested* = "Tested (weak)"
  ColWeak* = "Weak"
  LineTip* = "The line of the station: the receiver of a shot gather's traces, the source " &
    "of a receiver gather's."
  PointTip* = "The point of the station."
  LackingTip* = "The components a file has at other stations that this station has no " &
    "trace of there, while it has a trace of another component; those of any file. Empty " &
    "when it lacked none."
  LackFilesTip* = "In how many files the station lacked a component: the file has it at " &
    "other stations, this station has none of it there."
  SeenTip* = "Traces read, killed ones included, of all the components of the station."
  DeadTip* = "Traces the header marks dead. A dead trace is not also counted as all zero."
  ZeroTip* = "Traces whose every finite sample is zero."
  ConstantTip* = "Traces whose samples are all the same value."
  ClippedTip* = "Traces with runs of samples stuck at their maximum."
  SpikyTip* = "Traces with samples far above their neighbours."
  DcTip* = "Traces whose mean is large against their spread, so they sit away from zero."
  NonFiniteTip* = "Traces with a sample that is not a finite number."
  ScanJudgesTip = "The scan judges the samples as recorded, with your kills and noise " &
    "settings, but without the per-trace filters, reversals, shifts or template-only " &
    "restriction the map applies to the record shown."
  NoisyTestedTip* = "Traces the noisy test judged: those outside the area around the " &
    "source, in a record that could be judged. Killed, dead and auxiliary traces are not."
  NoisyTip* = "Of the traces tested for noisy, those much louder than the others of their " &
    "record. Not counted as bad. Empty when no trace was tested for noisy. " & ScanJudgesTip
  WeakTestedTip* = "Traces the weak test judged: as for noisy, and those inside the area " &
    "around the source too."
  WeakTip* = "Of the traces tested for weak, those much quieter than the others of their " &
    "record. Not counted as bad. Empty when no trace was tested for weak. " & ScanJudgesTip
  KilledTip* = "Traces an edit killed. They are counted as killed, not as bad, and are not " &
    "measured."
  BadTip* = "Traces with a finding. A killed trace is not among them."
  FiguresTip* = "Each station (line and point) counts once, over all its components and " &
    "files. A trace with several findings is one bad trace."
  FilterStations* = "Filter by line, point or component"
  FilterStationsTip* = "Show only the stations whose line, point or lacking components " &
    "hold every word typed here."

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func percentOf(n, whole: int): string =
  ## `n` of `whole` as a percentage, 0 for an empty whole.
  percentText(if whole <= 0: 0.0 else: 100.0 * float64(n) / float64(whole))

func countsLine*(t: Totals; folder: bool): string =
  ## What was read: files (for a folder) and traces.
  let traces = plural(t.traces, "trace", "traces")
  if folder: plural(t.files, "file", "files") & ", " & traces else: traces

func unknownWords(why: TemplateUnknown; side: StationSide): string =
  ## Why records of `side` were measured whole, after their count.
  let shots = side == ssReceivers
  case why
  of tuNoStation:
    if shots: "with no source station: load the relation file or a survey that places the source"
    else: "with no receiver station"
  of tuNoSources: "whose traces name no source station"
  of tuNoRecord: (if shots: "whose X record is not found" else: "whose O records are not found")
  of tuByChannel: "matched to their X record by channel, not by station"

func noStationLine*(t: Totals): string =
  ## How many traces of records whose template is known were left out because no station
  ## holds them; "" for none.
  if t.noStation == 0: ""
  else: plural(t.noStation, "trace", "traces") &
    " at no station (not placed by the headers or the survey): left out"

func wholeLine*(t: Totals; side: StationSide): string =
  ## How many records (of `ssSources`: receiver gathers) were measured whole although a
  ## relation file is loaded, because their template is not known, and why; "" for none.
  var whole = 0
  var why: seq[string] = @[]
  for w in TemplateUnknown:
    if t.unknown[w] > 0:
      whole += t.unknown[w]
      why.add $t.unknown[w] & " " & unknownWords(w, side)
  let (one, many) = if side == ssSources: ("receiver gather", "receiver gathers")
                    else: ("record", "records")
  if whole == 0: ""
  elif whole == 1: "1 " & one & " was measured whole: its template is not known (" & why[0] &
    ")"
  else: $whole & " " & many & " were measured whole: their template is not known (" &
    why.join(", ") & ")"

func statisticLines*(t: Totals; side: StationSide; folder: bool): seq[string] =
  ## One line for each figure, worded for what is counted, in the words of the column
  ## headers. Counts are traces except the stations. Killed is not bad. The noisy and weak
  ## lines only when some trace was tested for them, the component line only when the data
  ## has more than one component, the lines of the traces left out at no station and of the
  ## records measured whole only when there are some (`noStationLine`, `wholeLine`).
  let noun = side.stationNoun
  let where = if folder: "the files" else: "the file"
  let measured = t.traces - t.killed
  result.add noun & " stations in " & where & ": " & $t.stations
  result.add "Traces: " & $t.traces & ", " & $t.killed & " killed, " & $measured & " measured"
  result.add "Bad traces: " & $t.bad & " (" & percentOf(t.bad, measured) & "% of the measured)"
  result.add noun & " stations with a bad trace: " & $t.badStations & " of " & $t.stations &
    " (" & percentOf(t.badStations, t.stations) & "%)"
  result.add "Dead: " & $t.counts[qfHeaderDead] & ", all zero: " & $t.counts[qfAllZero] &
    ", constant: " & $t.counts[qfConstant] & ", clipped: " & $t.counts[qfClipped] &
    ", spiky: " & $t.counts[qfSpiky] & ", DC offset: " & $t.counts[qfDcOffset] &
    ", not finite: " & $t.counts[qfNonFinite]
  if t.outside > 0:
    result.add "Left out as outside the template: " & plural(t.outside, "trace", "traces") &
      " (not counted above)"
  let unplaced = noStationLine(t)
  if unplaced.len > 0: result.add unplaced
  let whole = wholeLine(t, side)
  if whole.len > 0: result.add whole
  if t.noisyTested > 0:
    result.add "Noisy: " & $t.noisy & " of " & $t.noisyTested & " tested (" &
      percentOf(t.noisy, t.noisyTested) & "%)"
  if t.weakTested > 0:
    result.add "Weak: " & $t.weak & " of " & $t.weakTested & " tested (" &
      percentOf(t.weak, t.weakTested) & "%)"
  if t.components > 1:
    result.add $t.lacking & " " & noun.toLowerAscii & " " &
      (if t.lacking == 1: "station lacks" else: "stations lack") & " a component" &
      (if folder: " in at least one file" else: "") & " (of " &
      $t.components & " components)"

func headerTip*(name: string): string =
  ## The tooltip of column title `name`, or "" when the title says enough.
  case name
  of ColLine: LineTip
  of ColPoint: PointTip
  of ColLacking: LackingTip
  of ColLackFiles: LackFilesTip
  of ColSeen: SeenTip
  of ColClipped: ClippedTip
  of ColSpiky: SpikyTip
  of ColKilled: KilledTip
  of ColBad: BadTip
  of ColHeaderDead: DeadTip
  of ColAllZero: ZeroTip
  of ColConstant: ConstantTip
  of ColDcOffset: DcTip
  of ColNonFinite: NonFiniteTip
  of ColNoisyTested: NoisyTestedTip
  of ColNoisy: NoisyTip
  of ColWeakTested: WeakTestedTip
  of ColWeak: WeakTip
  else: ""

func unreadNote*(rows: openArray[tuple[path, why: string]]): string =
  ## One line when a file or a trace could not be read, or "" when none could not.
  ## A reason that starts with "trace " is one trace; any other reason is one file.
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

func notCheckedNote*(rows: openArray[tuple[path, why: string]]): string =
  ## One line for the files left out because they are not gathers of one side (a continuous
  ## receiver recording) or their kind is not told; "" for none.
  if rows.len == 0: return ""
  if rows.len == 1: return "1 file was not measured: " & rows[0].why & "."
  $rows.len & " files were not measured: " & rows[0].why & " (the first of them)."

func countLabel*(what: string; n: int): string =
  ## A button label with its count.
  what & " (" & $n & ")"
