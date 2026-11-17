## SEG-Y trace identification codes in words, for the readout and the headers
## window, and the four vibrator codes the vibrator signature takes its roles
## from.
##
## The names are the SEG-Y rev 1 list (codes 1 to 22). A code outside it is
## shown as it is, "not in the standard": what a manufacturer's own code
## means is not guessed.

const
  VibReactionMassCode* = 18'i16 ## vibrator reaction mass
  VibBaseplateCode* = 19'i16    ## vibrator baseplate
  VibGroundForceCode* = 20'i16  ## vibrator estimated ground force
  VibReferenceCode* = 21'i16    ## vibrator reference

  StandardIdNames = ["seismic data", "dead", "dummy", "time break", "uphole", "sweep",
    "timing", "water break", "near-field gun signature", "far-field gun signature",
    "seismic pressure sensor", "multicomponent seismic sensor, vertical",
    "multicomponent seismic sensor, cross-line", "multicomponent seismic sensor, in-line",
    "rotated multicomponent sensor, vertical", "rotated multicomponent sensor, transverse",
    "rotated multicomponent sensor, radial", "vibrator reaction mass", "vibrator baseplate",
    "vibrator estimated ground force", "vibrator reference", "time-velocity pairs"]
    ## Code 1 first.

const Rev2IdNames = ["time-depth pairs", "depth-velocity pairs", "depth domain seismic data",
  "gravity potential", "electric field, vertical", "electric field, cross-line",
  "electric field, in-line", "rotated electric field, vertical",
  "rotated electric field, transverse", "rotated electric field, radial",
  "magnetic field, vertical", "magnetic field, cross-line", "magnetic field, in-line",
  "rotated magnetic field, vertical", "rotated magnetic field, transverse",
  "rotated magnetic field, radial", "rotational sensor, pitch", "rotational sensor, roll",
  "rotational sensor, yaw"]
  ## Codes 23 to 41 of SEG-Y rev 2 (parseSEG docs/spec/segy_rev2_1.md, section 4.5).

func traceIdName*(code: int; rev2 = false): string =
  ## The standard's name of trace identification code `code` ("vibrator baseplate" for 19):
  ## codes 1 to 22 in every revision, 23 to 41 in rev 2 and later (`rev2`), -1 "other";
  ## "" for 0 (not set) and for any other code.
  if code == -1: "other"
  elif code in 1 .. StandardIdNames.len: StandardIdNames[code - 1]
  elif rev2 and code in 23 .. 41: Rev2IdNames[code - 23]
  else: ""

func traceIdText*(code: int; rev2 = false): string =
  ## What the user is told of a trace's identification code: "vibrator baseplate (19)",
  ## "code 29 (not in the standard)"; "" when it is not set (0, as every SEG-D and SEG-2
  ## trace has). `rev2`: the file is SEG-Y rev 2 or later, whose codes 23 to 41 have names
  ## and whose 256 to 16383 are optional use, and whose +16384 marks an interpolated trace
  ## ("interpolated vertical sensor (16396)").
  if code == 0: return ""
  if rev2 and code >= 16384 and code <= 32767:
    let base = traceIdName(code and 0x3FFF, true)
    return (if base.len > 0: "interpolated " & base else: "interpolated code " &
      $(code and 0x3FFF)) & " (" & $code & ")"
  let name = traceIdName(code, rev2)
  if name.len > 0: name & " (" & $code & ")"
  elif rev2 and code in 256 .. 16383: "code " & $code & " (optional use)"
  else: "code " & $code & " (not in the standard)"
