## The time axis's helpers (`view/timeaxis`): the cursor's time is written
## to the sample interval, never as "-0" nor with a bare point; and the
## widest tick label of a record covers every label Dear ImPlot's axis can
## write for it, at every zoom, so the axis never grows.
##
## The end labels (`timeEnds`): the whole of a 12 000-sample, 1 ms record is
## labelled "11999" at the last sample, "0" at the first, a round tick near
## either gives way, and a zoomed view is labelled at its own ends.
##
## Seen to fail: with `timeEnds` taking the last sample as `samples * dt`,
## "11999" read "12000"; with `givesWay` always false, "11900" was kept
## beside the end label. With Nim's `formatFloat` taken as it is, 702.34 ms at 2 ms
## read "702." and -0.2 ms "0."; with the finest step's decimals left out of
## `timeLabelChars`, "dt 0.125, 8 samples from 0.0 ms: "0.5" is longer
## than 1".

import std/[math, strutils]
import viewSEG/core/[viewport, zoom]
import viewSEG/view/timeaxis

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

proc main*() =

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

  block endLabels:
    let layout = PanelLayout(traces: 10, samples: 12_000, dtMs: 1)
    let bounds = limitsOf(layout)[axTime].bounds
    let chars = timeLabelChars(layout)
    let px = 600.0 # a plot 600 pixels tall, 20 pixels a label
    let whole = timeEnds(bounds, bounds, 1, chars, px / bounds.width, 20)
    doAssert whole.lastText.strip == "11999", whole.lastText
    doAssert whole.firstText.strip == "0" and whole.showFirst
    doAssert whole.last == 11999 and whole.lastText.len == chars
    doAssert whole.givesWay(11999) and whole.givesWay(0)
    doAssert whole.givesWay(11900) and whole.givesWay(300) # within 20 pixels (400 ms)
    doAssert not whole.givesWay(11000) and not whole.givesWay(1000)
    # the round ticks of a full view that are kept never come within a label
    # of the end labels (pixels)
    for k in 0 .. 12:
      let t = float64(k) * 1000
      if not whole.givesWay(t):
        doAssert abs(t - whole.last) * whole.pxPerMs >= 20 and abs(t - whole.first) *
            whole.pxPerMs >= 20
    # zoomed: the view's own last and first time
    let zoom = timeEnds(Span(lo: 2437.4, hi: 3100.6), bounds, 1, chars, px / 663.2, 20)
    doAssert zoom.lastText.strip == "3101" and zoom.firstText.strip == "2437", zoom.lastText
    # a view past the record's ends is cut to them
    let over = timeEnds(Span(lo: -5, hi: 20000), bounds, 1, chars, 0.03, 20)
    doAssert over.lastText.strip == "11999" and over.firstText.strip == "0"
    # sub-ms samples: the decimals of the interval
    let fine = timeEnds(Span(lo: 0, hi: 99.875), Span(lo: 0, hi: 99.875), 0.125, 7, 5, 20)
    doAssert fine.lastText.strip == "99.875", fine.lastText
    # two labels that would touch: the first is dropped, the last stays
    let tiny = timeEnds(Span(lo: 0, hi: 4), Span(lo: 0, hi: 100), 1, chars, 2, 20)
    doAssert not tiny.showFirst and tiny.lastText.strip == "4"

when isMainModule:
  main()
