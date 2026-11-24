## Words for Project > Cut by shot log. The sentences a finished cut logs
## live in `core/cutgatherjobs`; the refusals in `core/state`.

import std/[math, strutils]
import ../core/[cutgather, shotlog]
import processSEG/continuous/slice

const
  CutWindowTitle* = "Cut by shot log###cutgather"
  CutMenuTip* = "Cut the recording the Seismic window shows into one record per shot of a " &
    "loaded shot log, and write them to a new file"
  Intro* = "Cuts a continuous recording at the times of a shot log: one record per shot, " &
    "holding the recording's components, written to a new file. The recording is not changed."
  AlignNearest* = "Nearest sample"
  AlignLinear* = "Linear"
  AlignCubic* = "Cubic"
  AlignSinc* = "Sinc"
  FormatSegd* = "SEG-D"
  FormatSegy* = "SEG-Y"
  NeedFolder* = "Choose the folder the file is written to."
  NeedName* = "Give the file a name."
  NameHasFolder* = "The name is a file name: choose the folder with the button."
  HeadersNotRead* = "The recording's headers are still being read."
  OpenCut* = "Open the cut file"

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

func standardWords*(s: CutStandard): string =
  ## The words for a file format.
  if s == csSegy: FormatSegy else: FormatSegd

func standardExt*(s: CutStandard): string =
  ## The extension of a file of that format.
  if s == csSegy: ".sgy" else: ".sgd"

func defaultName*(source: string; s: CutStandard): string =
  ## The source's stem, "_cut", and the format's extension.
  var stem = source
  let dot = stem.rfind('.')
  if dot > 0: stem.setLen dot
  stem & "_cut" & standardExt(s)

func sizeWords*(bytes: int64): string =
  ## "about 1.5 GB" style, decimal units.
  let b = float64(bytes)
  if b >= 1e9: formatFloat(b / 1e9, ffDecimal, 1) & " GB"
  elif b >= 1e6: formatFloat(b / 1e6, ffDecimal, 1) & " MB"
  else: formatFloat(max(b / 1e3, 0.1), ffDecimal, 1) & " kB"

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func summaryWords*(shots: CutShots; components, samples: int; opts: CutOptions): string =
  ## "N shots (M rows have no time and are left out), C components, about X GB to write."
  var anyStation, anySourceXY = false
  for s in shots.shots:
    if not (s.srcLine.isNaN or s.srcPoint.isNaN): anyStation = true
    if not (s.srcX.isNaN or s.srcY.isNaN): anySourceXY = true
  let bytes = estimateBytes(opts, shots.shots.len, components, samples, anyStation,
    anySourceXY, false)
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
