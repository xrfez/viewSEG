## The scale boxes: traces per inch and ms per inch read from a view, and a
## view made from a typed value, both ways, at two pixel densities (96 and
## 144 pixels per inch) and per cm and as inches per second; the pixels per
## inch assumed and calibrated (from a monitor's diagonal, from a ruler),
## per monitor; and values beyond the limits.
##
## Seen to fail: with `traceScale` using the view's rows instead of its
## columns, `readsTheView` did not read 12 traces per inch; with
## `withTimeScale` keeping the bottom edge, `typedScalesKeepTheTopLeft` found
## the top moved; with `calibrate` keeping a monitor's earlier value,
## `perMonitorCalibration` found it twice.

import std/math
import viewSEG/core/[settings, viewport, zoom]

const layout = PanelLayout(traces: 2000, samples: 3001, dtMs: 2, t0Ms: 0)

func near(a, b: float64; eps = 1e-9): bool = abs(a - b) <= eps * max(1.0, abs(b))

func plot(traces, ms: float64; columns = 960; rows = 720): Viewport =
  Viewport(traces: Span(lo: 99.5, hi: 99.5 + traces), timeMs: Span(lo: 500, hi: 500 + ms),
    columns: columns, rows: rows)

proc main*() =

  let lim = limitsOf(layout)

  let perInch = ScaleUnits()
  let perCm = ScaleUnits(length: luCm)
  let speed = ScaleUnits(speed: true)

  block readsTheView:
    # 960 x 720 pixels at 96 per inch: 10 x 7.5 inches
    let v = plot(120, 1500)
    doAssert near(traceScale(v, 96, perInch), 12) and near(timeScale(v, 96, perInch), 200)
    # at 144 per inch the same pixels are 6.667 x 5 inches
    doAssert near(traceScale(v, 144, perInch), 18) and near(timeScale(v, 144, perInch), 300)
    doAssert near(traceScale(v, 96, perCm), 12 / 2.54) and
      near(timeScale(v, 96, perCm), 200 / 2.54)
    # 7.5 inches for 1.5 s: 5 inches per second
    doAssert near(timeScale(v, 96, speed), 5) and near(timeScale(v, 144, speed), 5 * 96 / 144)
    doAssert traceScale(plot(120, 1500, columns = 0), 96, perInch).isNaN
    doAssert timeScale(plot(120, 1500, rows = 0), 96, perInch).isNaN
    doAssert traceScale(v, 0, perInch).isNaN and timeScale(v, NaN, perInch).isNaN
    doAssert traceLabel(perInch) == "traces/in" and timeLabel(perInch) == "ms/in"
    doAssert traceLabel(perCm) == "traces/cm" and timeLabel(perCm) == "ms/cm"
    doAssert timeLabel(speed) == "in/s" and timeLabel(ScaleUnits(length: luCm, speed: true)) ==
      "cm/s"

  block bothWays:
    for ppi in [96.0, 144.0]:
      for u in [perInch, perCm, speed, ScaleUnits(length: luCm, speed: true)]:
        for tr in [2.5, 12.0, 40.0]:
          let v = withTraceScale(plot(120, 1500), tr, ppi, u, lim)
          doAssert near(traceScale(v, ppi, u), tr), $ppi & " " & $u & ": " & $tr & " set, " &
            $traceScale(v, ppi, u) & " read"
          doAssert v.timeMs == plot(120, 1500).timeMs, "a trace scale moved the time axis"
        # values inside the limits (16 ms to 6.6 s on screen) for each unit
        let times = if u.speed: @[4.0, 10.0, 40.0] else: @[4.5, 50.0, 250.0]
        for tm in times:
          let v = withTimeScale(plot(120, 1500), tm, ppi, u, lim)
          let want = timeScale(v, ppi, u)
          doAssert near(want, tm), $ppi & " " & $u & ": " & $tm & " set, " & $want & " read"
          doAssert v.traces == plot(120, 1500).traces, "a time scale moved the traces"
        # and from the view: what is read sets the same view again
        let v = plot(333, 2222)
        let back = withTimeScale(withTraceScale(v, traceScale(v, ppi, u), ppi, u, lim),
          timeScale(v, ppi, u), ppi, u, lim)
        doAssert near(back.traces.hi, v.traces.hi) and near(back.timeMs.hi, v.timeMs.hi)

  block typedScalesKeepTheTopLeft:
    let v = plot(120, 1500)
    let w = withTimeScale(withTraceScale(v, 6, 96, perInch, lim), 100, 96, perInch, lim)
    doAssert w.traces.lo == v.traces.lo and w.timeMs.lo == v.timeMs.lo
    doAssert near(w.traces.width, 60) and near(w.timeMs.width, 750), $w

  block beyondTheLimits:
    # wider than the data allows: the widest view, which reads back as less
    let v = plot(120, 1500)
    let wide = withTraceScale(v, 1e6, 96, perInch, lim)
    doAssert wide.traces.width == lim[axTraces].most
    doAssert traceScale(wide, 96, perInch) < 1e6
    let short = withTimeScale(v, 1e-6, 96, perInch, lim)
    doAssert short.timeMs.width == lim[axTime].least
    # nothing usable typed: the view as it was
    for bad in [0.0, -3.0, NaN, Inf]:
      doAssert withTraceScale(v, bad, 96, perInch, lim) == v
      doAssert withTimeScale(v, bad, 96, perInch, lim) == v
    # past the end: kept inside the bounds
    let late = withTimeScale(Viewport(traces: v.traces, timeMs: Span(lo: 5900, hi: 6000),
      columns: 960, rows: 720), 500, 96, perInch, lim)
    doAssert late.timeMs.hi == lim[axTime].bounds.hi and near(late.timeMs.width, 3750), $late

  block pixelsPerInch:
    doAssert defaultPpi(1) == 96 and defaultPpi(1.5) == 144 and defaultPpi(2) == 192
    doAssert defaultPpi(0) == 96 and defaultPpi(NaN) == 96
    # a 27-inch 4K monitor: 163.2 pixels per inch
    doAssert near(ppiFromDiagonal(3840, 2160, 27), hypot(3840.0, 2160.0) / 27)
    doAssert abs(ppiFromDiagonal(3840, 2160, 27) - 163.18) < 0.01
    doAssert near(ppiFromRuler(378, 10, luCm), 378 / (10 / 2.54))
    doAssert near(ppiFromRuler(192, 2, luInch), 96)
    doAssertRaises ValueError: discard ppiFromDiagonal(0, 1080, 24)
    doAssertRaises ValueError: discard ppiFromDiagonal(1920, 1080, 0)
    doAssertRaises ValueError: discard ppiFromRuler(-5, 10, luCm)
    doAssertRaises ValueError: discard ppiFromRuler(100, NaN, luInch)

  block perMonitorCalibration:
    var s = Settings()
    doAssert s.ppiFor("DP-1 3840x2160", 1.5) == 144
    doAssert s.calibration("DP-1 3840x2160").isNaN
    s.calibrate("DP-1 3840x2160", 163.2)
    s.calibrate("HDMI-1 1920x1080", 92)
    doAssert s.ppiFor("DP-1 3840x2160", 1.5) == 163.2
    doAssert s.ppiFor("HDMI-1 1920x1080", 1) == 92
    doAssert s.ppiFor("eDP-1 2560x1600", 1.25) == 120
    s.calibrate("DP-1 3840x2160", 160)
    doAssert s.ppiFor("DP-1 3840x2160", 1.5) == 160 and s.calibrations.len == 2
    s.calibrate("DP-1 3840x2160", NaN) # forgets it
    doAssert s.ppiFor("DP-1 3840x2160", 1.5) == 144 and s.calibrations.len == 1
    doAssertRaises ValueError: s.calibrate("x", 0)
    doAssertRaises ValueError: s.calibrate("x", Inf)

  block cleanedSettings:
    let given = Settings(calibrations: @[Calibration(monitor: "a", ppi: 100),
      Calibration(monitor: "b", ppi: -1), Calibration(monitor: "a", ppi: 110),
      Calibration(monitor: "c", ppi: NaN)], readout: @[rfTime, rfAmplitude, rfTime])
    let (s, dropped) = cleaned(given)
    doAssert s.calibrations == @[Calibration(monitor: "a", ppi: 110)], $s.calibrations
    doAssert s.readout == @[rfTime, rfAmplitude] and dropped == 4, $dropped
    doAssert Settings().readout == @DefaultReadout and cleaned(Settings())[1] == 0

when isMainModule:
  main()
