## The plot's time axis: how the cursor's time is written beside its
## labels.
##
## **The cursor's time** (`cursorTimeText`) is written to the record's
## sample interval: whole milliseconds at 1 ms and coarser, one decimal at
## 0.5 ms, two at 0.25 ms.

import std/[math, strutils]

func decimalsOf*(step: float64): int =
  ## The decimals that multiples of `step` need, at most 6.
  result = 0
  var s = step
  while result < 6 and abs(s - round(s)) > 1e-9 * max(1.0, abs(s)):
    s *= 10
    inc result

func cursorTimeText*(tMs, dtMs: float64): string =
  ## The time `tMs` as the cursor's time line shows it at the axis: to the
  ## sample interval `dtMs` (whole ms at 1 ms or coarser); "" for a time that
  ## is not a number.
  if tMs.classify in {fcNan, fcInf, fcNegInf}: return ""
  let d = if dtMs > 0 and dtMs < Inf: min(decimalsOf(dtMs), 3) else: 0
  result = formatFloat(tMs, ffDecimal, d)
  if result.endsWith('.'): result.setLen(result.len - 1) # Nim writes "702." with no decimals
  if result.startsWith("-") and result.strip(chars = {'-', '0', '.'}).len == 0:
    result = result[1 .. ^1] # "-0" from a time just before 0
