## Physical scales, as seismic plots are stated: traces per inch and ms per
## inch (or per cm, or time as inches per second), and the pixels per inch
## they rest on.
##
## A view's scale depends on its pixels (`Viewport.columns` and `rows`,
## framebuffer pixels) and on how many of those make an inch on the monitor.
## Systems do not report that reliably, so the default is `DefaultDpi` (96)
## times the display scale the system sets (`defaultPpi`), and a monitor can
## be calibrated: from its diagonal (`ppiFromDiagonal`), or by making a bar
## on the screen as long as a ruler says (`ppiFromRuler`).
##
## Setting a scale moves one edge of the view: traces per inch keep the left
## edge, time scales keep the top, so a plot grows from where it starts, as
## on paper. The view is then kept within its limits (`core/zoom`), so the
## scale shown afterwards may differ from the one typed.

import std/math
import viewport, zoom

const
  DefaultDpi* = 96.0 ## pixels per inch at a display scale of 1
  CmPerInch* = 2.54

type
  LengthUnit* = enum
    luInch = "in"
    luCm = "cm"

  ScaleUnits* = object
    ## How the scale boxes state a view.
    length*: LengthUnit = luInch ## traces per inch or per cm, ms per inch or per cm
    speed*: bool                 ## time as inches (or cm) per second instead of ms per inch (or cm)

func inches(length: float64; unit: LengthUnit): float64 {.inline.} =
  if unit == luInch: length else: length / CmPerInch

func usable(x: float64): bool {.inline.} = x > 0 and x < Inf

func defaultPpi*(displayScale: float64): float64 =
  ## The pixels per inch assumed for a monitor that is not calibrated:
  ## `DefaultDpi` times its display scale (1 when that is not usable).
  DefaultDpi * (if usable(displayScale): displayScale else: 1.0)

func ppiFromDiagonal*(widthPx, heightPx: int; diagonalInches: float64): float64 =
  ## The pixels per inch of a monitor of `widthPx` × `heightPx` pixels whose
  ## picture measures `diagonalInches` corner to corner. Raises `ValueError`
  ## for a size or diagonal that is not positive.
  if widthPx <= 0 or heightPx <= 0 or not usable(diagonalInches):
    raise newException(ValueError, "a monitor of " & $widthPx & " x " & $heightPx &
      " pixels with a diagonal of " & $diagonalInches & " inches has no pixel size")
  hypot(float64(widthPx), float64(heightPx)) / diagonalInches

func ppiFromRuler*(pixels, length: float64; unit: LengthUnit): float64 =
  ## The pixels per inch when a bar `pixels` long measures `length` in
  ## `unit` on a ruler held to the screen. Raises `ValueError` for a bar or
  ## length that is not positive.
  if not usable(pixels) or not usable(length):
    raise newException(ValueError, "a bar of " & $pixels & " pixels measuring " & $length &
      " " & $unit & " has no pixel size")
  pixels / inches(length, unit)

func traceLabel*(u: ScaleUnits): string =
  ## The trace scale's unit as the box shows it.
  "traces/" & $u.length

func timeLabel*(u: ScaleUnits): string =
  ## The time scale's unit as the box shows it.
  if u.speed: $u.length & "/s" else: "ms/" & $u.length

func traceScale*(v: Viewport; ppi: float64; u: ScaleUnits): float64 =
  ## Traces (positions) per inch or cm of `v` at `ppi` pixels per inch; NaN
  ## when the view has no pixels.
  if v.columns <= 0 or not usable(ppi): return NaN
  let along = float64(v.columns) / ppi # inches
  v.traces.width / (if u.length == luInch: along else: along * CmPerInch)

func timeScale*(v: Viewport; ppi: float64; u: ScaleUnits): float64 =
  ## Ms per inch or cm of `v` at `ppi` pixels per inch, or inches or cm per
  ## second with `u.speed`; NaN when the view has no pixels or no time.
  if v.rows <= 0 or not usable(ppi) or not (v.timeMs.width > 0): return NaN
  let down = float64(v.rows) / ppi # inches
  let length = if u.length == luInch: down else: down * CmPerInch
  if u.speed: length / (v.timeMs.width / 1000) else: v.timeMs.width / length

func withTraceScale*(v: Viewport; value, ppi: float64; u: ScaleUnits;
    lim: ViewLimits): Viewport =
  ## `v` at `value` traces per inch (or cm), its left edge kept, within the
  ## limits. `v` as it is (within its limits) when `value` or `ppi` is not
  ## usable or the view has no pixels.
  result = kept(v, lim)
  if usable(value) and usable(ppi) and v.columns > 0:
    let along = float64(v.columns) / ppi
    let w = value * (if u.length == luInch: along else: along * CmPerInch)
    result.traces = keptFrom(v.traces.lo, w, lim[axTraces])

func withTimeScale*(v: Viewport; value, ppi: float64; u: ScaleUnits;
    lim: ViewLimits): Viewport =
  ## `v` at `value` ms per inch (or cm; with `u.speed`, inches or cm per
  ## second), its top edge kept, within the limits. `v` as it is (within its
  ## limits) when `value` or `ppi` is not usable or the view has no pixels.
  result = kept(v, lim)
  if usable(value) and usable(ppi) and v.rows > 0:
    let down = float64(v.rows) / ppi
    let length = if u.length == luInch: down else: down * CmPerInch
    let w = if u.speed: length / value * 1000 else: value * length
    result.timeMs = keptFrom(v.timeMs.lo, w, lim[axTime])
