## A cursor on a plot of samples, held by the keys: the spectrum windows'
## (a frequency bin along the plot, and the curve it reads), and later an
## f-k plot's (a frequency and a wavenumber), so both step it alike.
##
## The cursor follows the pointer while it is over the plot; a key that
## moves it (Left / Right a sample along the first axis, Home / End to its
## ends, Up / Down along the second) holds it where the key put it, and it
## stays there when the pointer leaves, until the pointer moves over the
## plot again or Esc lets it go. Held, it is the window's (`core`, so an
## agent can move it too); following the pointer, it is the frontend's
## alone.

import std/math

type
  CursorMove* = enum
    ## A key's move of a cursor.
    cmNone = "none"
    cmPrevious = "previous" ## one sample back along the first axis (Left)
    cmNext = "next"         ## one sample on (Right)
    cmFirst = "first"       ## the first sample (Home)
    cmLast = "last"         ## the last sample (End)
    cmUp = "up"             ## one back along the second axis (Up)
    cmDown = "down"         ## one on along the second axis (Down)

  PlotCursor* = object
    ## Where a plot's cursor is held.
    held*: bool
      ## held by the keys or an agent: drawn there whatever the pointer
      ## does, until let go; false: it follows the pointer
    x*: int ## the sample it is at along the plot's first axis (a frequency bin)
    y*: int
      ## and along its second (a curve plot's curve, 0 the first in its
      ## legend; an f-k plot's wavenumber)

func clamped*(c: PlotCursor; counts: array[2, int]): PlotCursor =
  ## `c` within `counts` samples along each axis (at 0 for an axis of none).
  result = c
  result.x = clamp(c.x, 0, max(counts[0] - 1, 0))
  result.y = clamp(c.y, 0, max(counts[1] - 1, 0))

func moved*(c: PlotCursor; m: CursorMove; counts: array[2, int]): PlotCursor =
  ## `c` moved by `m` within `counts` samples along each axis, and held.
  result = c
  result.held = true
  case m
  of cmNone: discard
  of cmPrevious: dec result.x
  of cmNext: inc result.x
  of cmFirst: result.x = 0
  of cmLast: result.x = counts[0] - 1
  of cmUp: dec result.y
  of cmDown: inc result.y
  result = result.clamped(counts)

func nearestSample*(at, step: float64; count: int; first = 0): int =
  ## The sample nearest `at` on an axis of `count` samples `step` apart
  ## from 0 (a spectrum's bins: `at` a frequency, `step` their spacing),
  ## within `first` ..< `count`: so a cursor held at a value stays there
  ## when the samples change (finer bins), at its nearest. 0 when there
  ## are none; `first` when `at` is not a number or `step` not positive.
  if count <= 0: return 0
  let lo = clamp(first, 0, count - 1)
  if at.isNaN or not (step > 0) or step == Inf: return lo
  let k = at / step
  if k <= float64(lo): lo
  elif k >= float64(count - 1): count - 1
  else: clamp(int(round(k)), lo, count - 1)
