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

func traceIdName*(code: int): string =
  ## The standard's name of trace identification code `code` ("vibrator
  ## baseplate" for 19); "" for 0 (not set) and for a code outside 1 to 22.
  if code in 1 .. StandardIdNames.len: StandardIdNames[code - 1] else: ""

func traceIdText*(code: int): string =
  ## What the user is told of a trace's identification code: "vibrator
  ## baseplate (19)", "code 29 (not in the standard)"; "" when it is not set
  ## (0, as every SEG-D and SEG-2 trace has).
  if code == 0: ""
  elif traceIdName(code).len > 0: traceIdName(code) & " (" & $code & ")"
  else: "code " & $code & " (not in the standard)"
