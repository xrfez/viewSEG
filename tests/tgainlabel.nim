## The gain bar's label and the drop-down's "now:" line (`core/gainlabel`).
## Automatic is a rule that picks a type, not a label of its own: the bar
## says "Gain: auto (AGC 200 ms)" or "Gain: auto (none)" when viewSEG chose,
## and "Gain: AGC 200 ms" when the user did. "now:" names the type the rule
## picks for this record.
##
## Seen to fail: with the bar still saying "automatic (auto)" for a shot,
## "auto AGC"; with stacked data's "now:" line saying "now: none" and not
## "stacked data".

import viewSEG/core/[gainlabel, panels]

proc shot(window = 200.0; gain = dgAuto): DisplaySettings =
  DisplaySettings(gain: gain, agcWindowMs: window)

block autoShot:
  let d = shot()
  doAssert gainBarLabel(d, gkShot) == "Gain: auto (AGC 200 ms)", "auto AGC"
  doAssert gainNow(d, gkShot) == "now: AGC 200 ms"
  doAssert gainBarLabel(d, gkReceiver) == "Gain: auto (AGC 200 ms)"
  doAssert gainNow(d, gkOffset) == "now: AGC 200 ms"

block autoStacked:
  let d = shot()
  doAssert gainBarLabel(d, gkCmp) == "Gain: auto (none)", "auto none"
  doAssert gainNow(d, gkCmp) == "now: none, stacked data"
  doAssert gainBarLabel(d, gkUnknown) == "Gain: auto (none)"
  doAssert gainNow(d, gkUnknown) == "now: none"

block chosen:
  doAssert gainBarLabel(shot(gain = dgAgc), gkShot) == "Gain: AGC 200 ms"
  doAssert gainBarLabel(shot(gain = dgNone), gkCmp) == "Gain: none"
  doAssert gainBarLabel(shot(gain = dgFixed), gkShot) == "Gain: fixed"
  doAssert gainBarLabel(shot(gain = dgFloat), gkShot) == "Gain: float"
  # the rule's pick is still said, beside the box, after the user picks
  doAssert gainNow(shot(gain = dgFixed), gkShot) == "now: AGC 200 ms"
  doAssert gainNow(shot(gain = dgAgc), gkCmp) == "now: none, stacked data"
  var n = shot(gain = dgNormalized)
  n.normScope = perPanel
  doAssert gainBarLabel(n, gkShot) == "Gain: normalized, record"
  var e = shot(gain = dgExponential)
  e.dbPerS = 6
  e.untilMs = 2000
  doAssert gainBarLabel(e, gkShot) == "Gain: exponential, 6 dB/s to 2000 ms"

echo "tgainlabel: ok"
