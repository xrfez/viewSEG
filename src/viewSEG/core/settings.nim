## The user's settings that the views read: how scales are stated, each
## monitor's calibration, and the status bar's fields. Changed only through
## a `ckSettings` command; kept for the session (saving them to disk is
## still to come).

import std/math
import readout, scales

export readout, scales

type
  Calibration* = object
    ## A monitor's measured pixel size.
    monitor*: string ## the monitor, as the frontend names it (its name and size in pixels)
    ppi*: float64    ## framebuffer pixels per inch

  Settings* = object
    scale*: ScaleUnits                            ## per inch or cm; time as ms per length or speed
    calibrations*: seq[Calibration]               ## one per calibrated monitor
    readout*: seq[ReadoutField] = @DefaultReadout ## the status bar's fields, in order

func calibration*(s: Settings; monitor: string): float64 =
  ## The calibrated pixels per inch of `monitor`; NaN when it is not
  ## calibrated.
  for c in s.calibrations:
    if c.monitor == monitor: return c.ppi
  NaN

func ppiFor*(s: Settings; monitor: string; displayScale: float64): float64 =
  ## The pixels per inch of `monitor`: its calibration, else
  ## `defaultPpi(displayScale)`.
  let c = s.calibration(monitor)
  if c.isNaN: defaultPpi(displayScale) else: c

proc calibrate*(s: var Settings; monitor: string; ppi: float64) =
  ## Sets `monitor`'s pixels per inch; NaN removes its calibration. Raises
  ## `ValueError` for a value that is neither NaN nor positive and finite.
  if not ppi.isNaN and not (ppi > 0 and ppi < Inf):
    raise newException(ValueError, "pixels per inch must be positive, got " & $ppi)
  var kept: seq[Calibration]
  for c in s.calibrations:
    if c.monitor != monitor: kept.add c
  if not ppi.isNaN: kept.add Calibration(monitor: monitor, ppi: ppi)
  s.calibrations = kept

func cleaned*(s: Settings): (Settings, int) =
  ## `s` without what cannot be used (a calibration that is not positive
  ## and finite, a monitor calibrated twice: the last one counts, a field
  ## listed twice), and how many entries were dropped.
  var r = s
  r.calibrations.setLen 0
  for i in countdown(s.calibrations.high, 0):
    let c = s.calibrations[i]
    var seen = false
    for d in r.calibrations:
      if d.monitor == c.monitor: seen = true
    if c.ppi > 0 and c.ppi < Inf and not seen: r.calibrations.insert(c, 0)
  r.readout = cleaned(s.readout)
  (r, s.calibrations.len - r.calibrations.len + s.readout.len - r.readout.len)
