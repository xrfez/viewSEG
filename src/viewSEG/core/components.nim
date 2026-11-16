## Components of a multi-component record, apart from drawing them.
##
## A trace's component is parseSEG's `TraceKeys.component`: the value the
## By Component sort uses (SEG-D sensor type, or the group index when that
## is set; a SEG-Y trace identification code when it names a component).
## 0 means the headers do not say. A record is multi-component when those
## traces, before any component filter, carry more than one distinct
## non-zero component.
##
## Named components, in the order their buttons are drawn: hydrophone,
## vertical, inline, crossline. SEG-D sensor types 1..4 and the SEG-Y codes
## that name the same sensors (11..17) share a name, a letter and a colour.
## Any other code keeps the normal ink and is labelled with its number.
##
## `TraceFilter.components` is the components to show; empty shows all
## (including a trace whose component is 0, which no button names). The
## last component still on cannot be turned off.

import std/algorithm
import geometry

type
  ComponentKind* = enum
    ckOther = "other"
    ckHydrophone = "hydrophone"
    ckVertical = "vertical"
    ckInline = "inline"
    ckCrossline = "crossline"

  ComponentTally* = object
    ## One component present in a record, and how many of its traces.
    code*: uint8
    count*: int

const
  ComponentShift* = 3
    ## Bits of a tile mark that hold `colourSlot` (0 other, 1..4 named).
  DefaultComponentColours* = [
    Rgba(r: 0x2E, g: 0x6B, b: 0xB0, a: 255), ## hydrophone, blue
    Rgba(r: 0x1E, g: 0x8A, b: 0x45, a: 255), ## vertical, green
    Rgba(r: 0xB0, g: 0x86, b: 0x0B, a: 255), ## inline, yellow (dark gold)
    Rgba(r: 0x0E, g: 0x8A, b: 0x86, a: 255)] ## crossline, teal
                                             ## Readable on white paper and on a dark plot (relative luminance about
                                             ## 0.15..0.25). The plot still darkens or lightens a chosen colour that
                                             ## would not show on the background it is drawn on.

func kindOf*(code: uint8): ComponentKind =
  ## The named kind of component code `code`, or other.
  case code
  of 1, 11: ckHydrophone
  of 2, 12, 15: ckVertical
  of 3, 14, 17: ckInline
  of 4, 13, 16: ckCrossline
  else: ckOther

func colourSlot*(code: uint8): int =
  ## 0 for the normal ink, else 1..4 into `DefaultComponentColours`.
  case kindOf(code)
  of ckOther: 0
  of ckHydrophone: 1
  of ckVertical: 2
  of ckInline: 3
  of ckCrossline: 4

func componentMark*(code: uint8): uint8 =
  ## The mark bits of `code` (`ComponentShift`).
  uint8(colourSlot(code) shl ComponentShift)

func letterOf*(code: uint8): string =
  ## The button's letter, or the number when the component is not named.
  case kindOf(code)
  of ckHydrophone: "H"
  of ckVertical: "Z"
  of ckInline: "X"
  of ckCrossline: "Y"
  of ckOther: $code

func nameOf*(code: uint8): string =
  ## The component's name, for a tooltip.
  case kindOf(code)
  of ckOther: "component " & $code
  of ckHydrophone: "hydrophone"
  of ckVertical: "vertical"
  of ckInline: "inline"
  of ckCrossline: "crossline"

func rankOf(code: uint8): int =
  ## Button order: hydrophone, vertical, inline, crossline, then others.
  case kindOf(code)
  of ckHydrophone: 0
  of ckVertical: 1
  of ckInline: 2
  of ckCrossline: 3
  of ckOther: 4

func tallyCounts*(counts: array[256, int]): seq[ComponentTally] =
  ## The non-zero counts, in button order (others by code).
  var found: seq[uint8] = @[]
  for code in 1'u8 .. 255'u8:
    if counts[code] > 0: found.add code
  found.sort(proc (a, b: uint8): int =
    result = rankOf(a) - rankOf(b)
    if result == 0: result = int(a) - int(b))
  for code in found:
    result.add ComponentTally(code: code, count: counts[code])

func tally*(codes: openArray[uint8]): seq[ComponentTally] =
  ## The distinct non-zero components of `codes`, and how often each occurs.
  var counts: array[256, int]
  for c in codes:
    if c != 0: inc counts[c]
  tallyCounts(counts)

func multiComponent*(codes: openArray[uint8]): bool =
  ## More than one distinct non-zero component.
  tally(codes).len > 1

func passesComponent*(code: uint8; filter: set[uint8]): bool =
  ## Whether a trace of component `code` is shown. Empty shows all; a trace
  ## with no component (0) is never one of the buttons, so it stays.
  code == 0 or filter.card == 0 or code in filter

func keptIndices*(codes: openArray[uint8]; filter: set[uint8]): seq[int] =
  ## The indices of `codes` the component filter keeps.
  for i, c in codes:
    if passesComponent(c, filter): result.add i

func componentShown*(filter: set[uint8]; code: uint8): bool =
  ## Whether `code`'s button is on. Empty shows every component.
  filter.card == 0 or code in filter

func keepsOne*(present: openArray[uint8]; filter: set[uint8]): bool =
  ## Whether `filter` still shows a component of `present` (empty shows all).
  ## `present` empty: nothing to refuse yet.
  if filter.card == 0 or present.len == 0: return true
  for c in present:
    if c in filter: return true
  false

func toggled*(present: openArray[uint8]; filter: set[uint8]; code: uint8): set[uint8] =
  ## The filter after clicking `code`. The last of `present` still on stays
  ## on. All of them on is the empty set, so a component a later record adds
  ## is shown until it is turned off.
  var on: set[uint8] = {}
  if filter.card == 0:
    for c in present: on.incl c
  else:
    on = filter
  if code in on:
    var n = 0
    for c in present:
      if c in on: inc n
    if n <= 1: return filter
    on.excl code
    result = on
  else:
    on.incl code
    var all = true
    for c in present:
      if c notin on: all = false
    if all: result = {}
    else: result = on
