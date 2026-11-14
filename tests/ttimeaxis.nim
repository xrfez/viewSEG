## The time axis's helpers (`view/timeaxis`): the cursor's time is written
## to the sample interval, never as "-0" nor with a bare point; and the
## widest tick label of a record covers every label Dear ImPlot's axis can
## write for it, at every zoom, so the axis never grows.
##
## Seen to fail: with Nim's `formatFloat` taken as it is, 702.34 ms at 2 ms
## read "702." and -0.2 ms "0."; with the finest step's decimals left out of
## `timeLabelChars`, "dt 0.125, 8 samples from 0.0 ms: "0.5" is longer
## than 1".

import std/math
import viewSEG/core/[viewport, zoom]
import viewSEG/view/timeaxis

block cursorTime:
  doAssert cursorTimeText(702.34, 2) == "702"
  doAssert cursorTimeText(702.34, 1) == "702"
  doAssert cursorTimeText(702.34, 0.5) == "702.3"
  doAssert cursorTimeText(702.34, 0.25) == "702.34"
  doAssert cursorTimeText(702.3456, 0.125) == "702.346"
  doAssert cursorTimeText(-0.2, 2) == "0", cursorTimeText(-0.2, 2)
  doAssert cursorTimeText(-12.6, 2) == "-13"
  doAssert cursorTimeText(NaN, 2) == "" and cursorTimeText(5, NaN) == "5"
  doAssert decimalsOf(2) == 0 and decimalsOf(0.5) == 1 and decimalsOf(0.05) == 2

proc snprintf(buf: cstring; n: csize_t; fmt: cstring): cint {.importc, header: "<stdio.h>",
  varargs.}

proc printed(v: float64): string =
  ## `v` as ImPlot's default formatter writes a tick label: `%g`.
  var buf: array[64, char]
  discard snprintf(cast[cstring](addr buf[0]), csize_t(buf.len), "%g", v)
  $cast[cstring](addr buf[0])

func niceNum(x: float64; round: bool): float64 =
  let e = floor(log10(x))
  let f = x / pow(10.0, e)
  let nf = if round: (if f < 1.5: 1.0 elif f < 3: 2.0 elif f < 7: 5.0 else: 10.0)
           else: (if f <= 1: 1.0 elif f <= 2: 2.0 elif f <= 5: 5.0 else: 10.0)
  nf * pow(10.0, e)

proc labels(lo, hi: float64; pixels: int): seq[string] =
  ## The major tick labels ImPlot's `Locator_Default` puts on an axis from
  ## `lo` to `hi` that is `pixels` tall, as it computes them.
  let nMajor = max(2, int(round(float64(pixels) / 300)))
  let interval = niceNum(niceNum((hi - lo) * 0.99, false) / float64(nMajor - 1), true)
  var major = floor(lo / interval) * interval
  let graphMax = ceil(hi / interval) * interval
  while major < graphMax + 0.5 * interval:
    if major - interval < 0 and major + interval > 0: major = 0
    if major >= lo and major <= hi: result.add printed(major)
    major += interval

block widestLabel:
  # every view of each record, from the shortest the zoom allows to the
  # whole record, at its start, middle and end, on plots 60 to 6000 pixels
  # tall: no label is longer than `timeLabelChars`
  var checked = 0
  for dt in [0.125, 0.25, 0.5, 1.0, 2.0, 4.0]:
    for samples in [8, 100, 500, 1001, 3000, 30_000]:
      for t0 in [0.0, -100.0, 2000.0]:
        let layout = PanelLayout(traces: 10, samples: samples, dtMs: dt, t0Ms: t0)
        let lim = limitsOf(layout)[axTime]
        let most = timeLabelChars(layout)
        var span = lim.least
        while span <= lim.most * 1.0001:
          for at in [0.0, 0.5, 1.0]:
            let lo = lim.bounds.lo + at * (lim.bounds.width - span)
            for pixels in [60, 300, 900, 2000, 6000]:
              for label in labels(lo, lo + span, pixels):
                doAssert label.len <= most, "dt " & $dt & ", " & $samples & " samples from " &
                  $t0 & " ms: \"" & label & "\" is longer than " & $most
                inc checked
          span *= 1.7
  doAssert checked > 10_000, $checked
  doAssert timeLabelChars(PanelLayout(traces: 24, samples: 500, dtMs: 2)) == 3
  doAssert timeLabelChars(PanelLayout(traces: 24, samples: 3000, dtMs: 2)) == 4
  doAssert timeLabelChars(PanelLayout(traces: 24, samples: 3000, dtMs: 0.5, t0Ms: -100)) == 6
