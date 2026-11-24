## Words for Project > Slice by shot log (internal names keep "cut"). The sentences a finished slice logs
## live in `core/cutgatherjobs`; the refusals in `core/state`. The sentences
## that refuse a file that is not a continuous recording are `cutRefusal` in
## `core/cutgather` (the slice job says them too), exported here.

import std/[math, strutils]
import ../core/[cutgather, shotlog]
export cutRefusal
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
  NeedFolder* = "Choose the folder the file is written to."
  NeedName* = "Give the file a name."
  DestChecking* = "Checking the destination..."
  DestExists* = "A file or folder of this name is already in the folder: choose another " &
    "name or folder."
  NameHasFolder* = "The name is a file name: choose the folder with the button."
  HeadersNotRead* = "The recording's headers are still being read."
  RecordingBeingRead* = "The recording is being read to see whether the slice can use it."
  OpenCut* = "Open the sliced file"

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

func standardWords*(s: CutStandard; sourceSegd = false): string =
  ## The words for a file format. A SEG-D source cut into SEG-D keeps its own
  ## revision (the headers are its own); any other source gives Rev 3.
  if s == csSegy: FormatSegy
  elif sourceSegd: FormatSegdKeep
  else: FormatSegd

func standardExt*(s: CutStandard): string =
  ## The extension of a file of that format.
  if s == csSegy: ".sgy" else: ".sgd"

func defaultName*(source: string; s: CutStandard): string =
  ## The source's stem, "_slice", and the format's extension.
  var stem = source
  let dot = stem.rfind('.')
  if dot > 0: stem.setLen dot
  stem & "_slice" & standardExt(s)

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
