## The words of the gain bar and of the drop-down's "now:" line. The stored
## setting stays `dgAuto` or one of the six types; only what is drawn changes.
## `dgAuto` is a rule that picks a type, not a type of its own.

import std/math
import panels, readout

func pickedGain*(kind: GatherKind): DisplayGain =
  ## The type Automatic picks for a gather of `kind`: AGC on a shot,
  ## receiver, offset or other record, none on stacked data (`gkCmp`) and
  ## on a record whose kind is not known.
  if kind in {gkShot, gkReceiver, gkOffset, gkOther}: dgAgc else: dgNone

func gainSetting*(d: DisplaySettings; g: DisplayGain): string =
  ## `g` with its main setting, as the bar writes it: "AGC 200 ms", "none",
  ## "exponential, 6 dB/s to 2000 ms".
  case g
  of dgAgc: "AGC " & $int(round(d.agcWindowMs)) & " ms"
  of dgNone: "none"
  of dgFixed: "fixed"
  of dgNormalized:
    "normalized, " & (if d.normScope == perTrace: "each trace" else: "record")
  of dgExponential:
    let shape = if d.timeGain == tgDbPerSecond: significant(d.dbPerS, 3) & " dB/s"
                else: "t^" & significant(d.power, 3)
    "exponential, " & shape & " to " & $int(round(d.untilMs)) & " ms"
  of dgFloat: "float"
  of dgAuto: "automatic"

func gainBarLabel*(d: DisplaySettings; kind: GatherKind): string =
  ## The gain control's label: "Gain: AGC 200 ms" when the user chose it,
  ## "Gain: auto (AGC 200 ms)" or "Gain: auto (none)" when viewSEG chose.
  let g = if d.gain == dgAuto: d.effectiveGain(kind) else: d.gain
  if d.gain == dgAuto: "Gain: auto (" & gainSetting(d, g) & ")"
  else: "Gain: " & gainSetting(d, g)

func gainNow*(d: DisplaySettings; kind: GatherKind): string =
  ## What Automatic picks for this record, with its main setting: "now: AGC
  ## 200 ms", "now: none, stacked data".
  let g = pickedGain(kind)
  if g == dgNone and kind == gkCmp: "now: none, stacked data"
  elif g == dgNone: "now: none"
  else: "now: " & gainSetting(d, g)
