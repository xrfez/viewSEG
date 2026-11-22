## The display header over a trace panel: rows of header values (receiver
## line and point by default) labelling the traces, thinned so labels never
## overlap.
##
## Labels go on positions that are multiples of a step: the panel's stride
## times 1, 2 or 5 × 10^k, the smallest that leaves room for the widest
## label. Steps of that kind keep labels on round positions, and since they
## are multiples of the stride, a zoomed-out tile has a value for each.

import std/math
from ../core/readout import numberText
from ../core/panels import HeaderField, hfChannelSet, hfTraceId
from ../core/traceids import traceIdText
from ../core/sigtypes import headerName

func headerStep*(stride: int; pixelsPerPosition, labelPixels: float64): int =
  ## The step between labelled positions: `stride` times the smallest of 1,
  ## 2, 5, 10, 20, 50 ... that keeps labels `labelPixels` apart when
  ## positions are `pixelsPerPosition` apart.
  let s = max(stride, 1)
  if not (pixelsPerPosition > 0) or not (labelPixels > 0): return s
  var m = 1
  while float64(s * m) * pixelsPerPosition < labelPixels and m < high(int) div 10:
    let d = m div (10 ^ (int(log10(float64(m)))))
    m = if d == 1: m * 2 elif d == 2: m div 2 * 5 else: m * 2
  s * m

iterator labelled*(visible: Slice[int]; step: int): int =
  ## The positions of `visible` that get a label: the multiples of `step`.
  if step > 0 and visible.len > 0:
    var p = (visible.a + step - 1) div step * step
    while p <= visible.b:
      yield p
      p += step

func headerText*(v: float64): string =
  ## A header value as the header shows it: whole numbers without decimals,
  ## others with up to two; "" when unknown (as the status bar shows them).
  numberText(v)

func headerLabel*(f: HeaderField; v: float64; channelSet: string): string =
  ## What the header shows for value `v` of field `f`: `headerText`, except
  ## for the channel set (`channelSet`, its number and type in words, when the
  ## tile has it) and the trace ID code (the code in words).
  case f
  of hfChannelSet: (if channelSet.len > 0: headerName(channelSet) else: headerText(v))
  of hfTraceId:
    (if v.isNaN: "" elif channelSet.len > 0: headerName(channelSet) # (a signature file's own names)
      else: traceIdText(int(v)))
  else: headerText(v)
