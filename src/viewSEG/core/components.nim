## Components of a multi-component record, apart from drawing them.
##
## A trace's component is parseSEG's `TraceKeys.component`: the value the
## By Component sort uses, and what tells traces of one station apart.
## SEG-D Rev 3 stores the group index there when that is set, else the
## sensor type; a SEG-Y trace stores an identification code when it names
## a component. 0 means the headers do not say. A record is multi-component
## when those traces, before any component filter, carry more than one
## distinct non-zero component. One button per distinct value.
##
## The button's name, letter and colour come from what the trace says it
## is, not from the group index. SEG-D `TraceKeys.sensorType` when it is a
## named sensor: 1 hydrophone; 2, 3, 4 vertical, inline and crossline
## geophone; 6, 7, 8 the same three as an accelerometer (the same letters
## and colours, the tooltip says accelerometer). A SEG-Y trace leaves
## `sensorType` 0 and puts the identification code in `component`, so the
## same rule uses that code (11..17). Several components with the same
## sensor, or with no named sensor, are labelled with the component number
## and take the four configured colours in order, green first; further ones
## keep the normal ink. The tooltip says whatever is known.
##
## `TraceFilter.components` is the components switched off, not the ones
## left on, so a component first seen on a later record is shown. Empty
## shows all (including a trace whose component is 0, which no button
## names). The last component still on cannot be turned off. A record that
## would be left with no trace, because every component present is off,
## is shown whole again.

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

  ComponentFace* = object
    ## How one component's button is drawn, and how its traces are coloured.
    code*: uint8
    count*: int
    sensor*: uint8  ## the sensor type when every trace of `code` agrees; else 0
    letter*: string ## H, Z, X, Y, or the component number
    name*: string   ## the tooltip, without the trace count
    slot*: int      ## 0 the normal ink, else 1..4 into the configured colours

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
  ## The named kind of a sensor type or a SEG-Y identification code, or
  ## other. Not a group index: codes 1..4 here are sensor types.
  case code
  of 1, 11: ckHydrophone
  of 2, 6, 12, 15: ckVertical
  of 3, 7, 14, 17: ckInline
  of 4, 8, 13, 16: ckCrossline
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

func rankOfKind(kind: ComponentKind): int =
  case kind
  of ckHydrophone: 0
  of ckVertical: 1
  of ckInline: 2
  of ckCrossline: 3
  of ckOther: 4

func letterOfKind(kind: ComponentKind): string =
  case kind
  of ckHydrophone: "H"
  of ckVertical: "Z"
  of ckInline: "X"
  of ckCrossline: "Y"
  of ckOther: ""

func slotOfKind(kind: ComponentKind): int =
  case kind
  of ckOther: 0
  of ckHydrophone: 1
  of ckVertical: 2
  of ckInline: 3
  of ckCrossline: 4

func rankOf(code: uint8): int =
  ## Button order of a sensor or SEG-Y code: hydrophone, vertical, inline,
  ## crossline, then others.
  rankOfKind(kindOf(code))

func sensorWords(sensor: uint8): string =
  ## What a SEG-D sensor type is called; "" when it names no sensor.
  case sensor
  of 1: "hydrophone"
  of 2: "vertical geophone"
  of 3: "inline geophone"
  of 4: "crossline geophone"
  of 6: "vertical accelerometer"
  of 7: "inline accelerometer"
  of 8: "crossline accelerometer"
  else: ""

func identityOf(sensor, code: uint8): tuple[kind: ComponentKind, words: string] =
  ## What a trace says it is. A named sensor type wins; otherwise a SEG-Y
  ## identification code in `code` (a SEG-Y trace's sensor type is 0).
  let words = sensorWords(sensor)
  if words.len > 0: (kindOf(sensor), words)
  elif kindOf(code) != ckOther and code in 11'u8 .. 17'u8: (kindOf(code), nameOf(code))
  else: (ckOther, "")

const numberedSlots = [2, 3, 4, 1]
  ## Colour slots for components that share a sensor, or have none: green,
  ## yellow, teal, blue. Further ones keep the normal ink.

func buttonFaces*(codes, sensors: openArray[uint8]; counts: openArray[int]): seq[ComponentFace] =
  ## One face per component, in button order. `sensors[i]` is the sensor
  ## type of every trace of `codes[i]`, or 0 when they disagree or the
  ## headers do not say. A component whose sensor is named, and named for
  ## no other component here, takes that sensor's letter and colour.
  ## Several with the same sensor, or with none, take the component number
  ## and the next of `numberedSlots`.
  let n = min(codes.len, sensors.len)
  var code = newSeq[uint8](n)
  var sensor = newSeq[uint8](n)
  for i in 0 ..< n:
    code[i] = codes[i]
    sensor[i] = sensors[i]
  var kind: seq[ComponentKind] = @[]
  var words: seq[string] = @[]
  var used: array[ComponentKind, int]
  for i in 0 ..< n:
    let id = identityOf(sensor[i], code[i])
    kind.add id.kind
    words.add id.words
    if id.kind != ckOther: inc used[id.kind]
  var lettered, numbered: seq[int] = @[]
  for i in 0 ..< n:
    if kind[i] != ckOther and used[kind[i]] == 1: lettered.add i
    else: numbered.add i
  lettered.sort(proc (a, b: int): int =
    result = rankOfKind(kind[a]) - rankOfKind(kind[b])
    if result == 0: result = int(code[a]) - int(code[b]))
  numbered.sort(proc (a, b: int): int = int(code[a]) - int(code[b]))
  for i in lettered:
    result.add ComponentFace(code: code[i], count: if i < counts.len: counts[i] else: 0,
      sensor: sensor[i], letter: letterOfKind(kind[i]), name: words[i], slot: slotOfKind(kind[i]))
  for k, i in numbered:
    let slot = if k < numberedSlots.len: numberedSlots[k] else: 0
    let known = words[i]
    let name = "component " & $code[i] & (if known.len > 0: " (" & known & ")" else: "")
    result.add ComponentFace(code: code[i], count: if i < counts.len: counts[i] else: 0,
      sensor: sensor[i], letter: $code[i], name: name, slot: slot)

func componentSlots*(faces: openArray[ComponentFace]): array[256, uint8] =
  ## Colour slot of each component code in `faces` (0: the normal ink).
  for f in faces: result[f.code] = uint8(f.slot)

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

const ComponentsRestored* =
  "Every component of this record was switched off: all are shown again."

func passesComponent*(code: uint8; off: set[uint8]): bool =
  ## Whether a trace of component `code` is shown. `off` is the components
  ## switched off; empty shows all. A trace with no component (0) is never
  ## one of the buttons, so it stays.
  code == 0 or code notin off

func keptIndices*(codes: openArray[uint8]; filter: set[uint8]): seq[int] =
  ## The indices of `codes` the component filter keeps.
  for i, c in codes:
    if passesComponent(c, filter): result.add i

func componentShown*(off: set[uint8]; code: uint8): bool =
  ## Whether `code`'s button is on. Empty shows every component.
  code notin off

func keepsOne*(present: openArray[uint8]; off: set[uint8]): bool =
  ## Whether `off` still shows a component of `present`. `present` empty:
  ## nothing to refuse yet.
  if present.len == 0: return true
  for c in present:
    if c notin off: return true
  false

func toggled*(present: openArray[uint8]; off: set[uint8]; code: uint8): set[uint8] =
  ## The components switched off after clicking `code`. The last of
  ## `present` still on stays on. A component a later record adds is not
  ## in `off`, so it is shown until it is turned off.
  if code notin off:
    var n = 0
    for c in present:
      if c notin off: inc n
    if n <= 1: return off
    result = off
    result.incl code
  else:
    result = off
    result.excl code
