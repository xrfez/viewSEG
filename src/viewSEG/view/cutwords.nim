## Words for Project > Slice by shot log (internal names keep "cut"). The sentences a finished slice logs
## live in `core/cutgatherjobs`; the refusals in `core/state`. The sentences
## that refuse a file that is not a continuous recording are `cutRefusal` in
## `core/cutgather` (the slice job says them too), exported here.

import std/[math, strutils]
import ../core/[cutgather, shotlog]
export cutRefusal, standardExt, defaultName
import processSEG/continuous/slice

const
  CutWindowTitle* = "Slice by shot log###cutgather"
  CutMenuTip* = "Slice the recording the Seismic window shows into one record per shot of a " &
    "loaded shot log, and write them to a new file"
  Intro* = "Slices a continuous recording at the times of a shot log: one record per shot, " &
    "holding the recording's components, written to a new file. The recording is not changed."
  AlignNearest* = "Nearest sample"
  AlignLinear* = "Linear"
  AlignCubic* = "Cubic"
  AlignSinc* = "Sinc"
  FormatSegd* = "SEG-D Rev 3"
  FormatSegdKeep* = "SEG-D (the source's revision)"
  FormatSegy* = "SEG-Y"
  NoCarry* = "This recording's headers cannot be carried into the output (it has more than " &
    "one record, or is in Rev 3 extended recording mode): they are built from the options, " &
    "as Rev 3."
  ChooseFileTip* = "Open the recording to slice; it is shown in the Seismic window"
  NeedSource* = "No recording is shown: choose the file to slice. It opens in the Seismic " &
    "window."
  NeedFolder* = "Choose the folder the file is written to."
  NeedName* = "Give the file a name."
  DestChecking* = "Checking the destination..."
  DestExists* = "A file or folder of this name is already in the folder: choose another " &
    "name or folder."
  NameHasFolder* = "The name is a file name: choose the folder with the button."
  HeadersNotRead* = "The recording's headers are still being read."
  RecordingBeingRead* = "The recording is being read to see whether the slice can use it."
  OpenCut* = "Open the sliced file"
  ChooseFolderTip* = "Choose a folder: every recording in it is sliced in one run, each to a " &
    "file of its own in the destination folder"
  NeedSourceFolder* = "Choose the folder whose recordings are sliced."
  FolderBeingRead* = "Reading the folder..."

func alignWords*(a: SliceAlign): string =
  ## The drop-down's words for an alignment.
  case a
  of saNearest: AlignNearest
  of saLinear: AlignLinear
  of saCubic: AlignCubic
  of saSinc: AlignSinc

func alignTip*(a: SliceAlign): string =
  ## One plain sentence for each alignment.
  case a
  of saNearest: "Each record starts at the sample nearest the shot; nothing is interpolated."
  of saLinear: "The sub-sample part of the start is shifted out by linear interpolation."
  of saCubic: "The sub-sample part of the start is shifted out by cubic interpolation."
  of saSinc: "Sinc is the most exact and the slowest."

func orderWords*(o: CutOrder): string =
  ## The drop-down's words for the order of a record's traces.
  case o
  of coAsSource: "As in the recording"
  of coByFlag: "By flag (a station's components together)"
  of coByComponent: "By component (each component's stations together)"

func orderTip*(o: CutOrder): string =
  ## One plain sentence for each order.
  case o
  of coAsSource:
    "The traces of a record keep the recording's order: by station, then channel."
  of coByFlag:
    "All the components of one station together (vertical, inline, crossline, hydrophone), " &
      "then the next station."
  of coByComponent:
    "All the vertical traces, then all the inline, the crossline and the hydrophone, each " &
      "in station order."

const
  OptCorrelated* = "Correlated with the project's reference##cut"
  CorrelatedTip* = "Correlate each record with the project's stored sweep as it is cut and " &
    "write the listen time only: the samples are those of slicing without this, then " &
    "writing the sliced file from Output with Correlated, in one step and one file."
  CorrelatedPilotWhy* = "A recording has no pilot for each shot: choose a stored sweep in " &
    "References."
  CorrelatedNoCarry* = "The recording's own SEG-D headers are not carried: correlated " &
    "records are not the length of the recording's, so the headers are built from the options."
  UseTextTip* = "The SEG-Y text header is the project's template, filled in for this file; " &
    "the note that the file was sliced by this program follows its last line, in the cards " &
    "it leaves free. Clear the box for the header a slice writes without one."
  UseBinaryTip* = "The fields of the project's set are written into the SEG-Y binary file " &
    "header; the rest of it is the slice's own. Clear the box to write none of them."
  OrderOneComponent* = "The recording's headers code fewer than two components, so there " &
    "is nothing to group."
  OrderKeepsHeaders* = "A SEG-D slice that keeps the recording's headers cannot reorder " &
    "its traces: it is written in the recording's order."

func standardWords*(s: CutStandard; sourceSegd = false): string =
  ## The words for a file format. A SEG-D source cut into SEG-D keeps its own
  ## revision (the headers are its own); any other source gives Rev 3.
  if s == csSegy: FormatSegy
  elif sourceSegd: FormatSegdKeep
  else: FormatSegd

func sizeWords*(bytes: int64): string =
  ## "about 1.5 GB" style, decimal units.
  let b = float64(bytes)
  if b >= 1e9: formatFloat(b / 1e9, ffDecimal, 1) & " GB"
  elif b >= 1e6: formatFloat(b / 1e6, ffDecimal, 1) & " MB"
  else: formatFloat(max(b / 1e3, 0.1), ffDecimal, 1) & " kB"

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func summaryWords*(shots: CutShots; components, samples: int; opts: CutOptions;
    carryHeaderBytes: int64 = 0): string =
  ## "N shots (M rows have no time and are left out), C components, about X GB to write."
  var anyStation, anySourceXY = false
  for s in shots.shots:
    if not (s.srcLine.isNaN or s.srcPoint.isNaN): anyStation = true
    if not (s.srcX.isNaN or s.srcY.isNaN): anySourceXY = true
  let bytes =
    if opts.standard == csSegdRev3 and carryHeaderBytes > 0:
      # headers carried from the source: its own bytes, then float32 samples
      int64(shots.shots.len) * (carryHeaderBytes + int64(components) * int64(samples) * 4)
    else:
      estimateBytes(opts, shots.shots.len, components, samples, anyStation, anySourceXY, false)
  result = plural(shots.shots.len, "shot", "shots")
  if shots.dropped > 0:
    result.add " (" & plural(shots.dropped, "row has", "rows have") &
      " no time and " & (if shots.dropped == 1: "is" else: "are") & " left out)"
  result.add ", " & plural(components, "component", "components") & ", about " &
    sizeWords(bytes) & " to write."

func numberingWords*(shots: CutShots): string =
  ## What the records are numbered by, when it is not the log's file numbers.
  if shots.shots.len > 0 and not recordNumbers(shots).fromFileNumber:
    "Records are numbered 1 to " & $shots.shots.len &
      ": the log's file numbers do not rise in time order."
  else: ""
