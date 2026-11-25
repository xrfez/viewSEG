## The restriction of the map's fold layers to one offset class or one azimuth sector: what the
## user types (the class edges, the number of sectors), what is drawn, and the rule that puts
## a recorded trace in a class or a sector.
##
## The rule is processSEG's (`FoldOptions` of `qc/fold`, its `addTrace`): a trace's offset is
## the distance from source to receiver when all four coordinates are finite, else the absolute
## value of the header's offset; class `k` of the edges `b` holds `b[k] <= offset < b[k + 1]`
## (the last edge is not in the last class), and an offset outside every class, or one that is
## not a number, is in none. The bearing is that of the source to the receiver, degrees
## clockwise from north, and only when all four coordinates are finite (else it is none); sector
## `k` of `n` holds bearings from `k * 360 / n` up to but not including the next, the last
## sector taking the rest. `tests/tfoldactual.nim` holds the rule equal to the library's.
##
## Only one restriction applies at a time: a class of offsets or a sector of bearings. The
## class edges and the sector count the parts are counted for (`specId`) are told apart from
## which class is drawn (`pick`), so another class drawn reads no file again.

import std/[algorithm, math, strutils]
import parseSEG

const
  MaxClasses* = 16 ## the most offset classes
  MaxSectors* = 36 ## the most azimuth sectors
  MinSectors* = 2

type
  SplitKind* = enum
    spNone    ## every class and sector
    spOffset  ## an offset class
    spAzimuth ## an azimuth sector

  FoldSplit* = object
    ## The restriction the fold layers are counted with. Offset classes and azimuth sectors
    ## can both be defined (a file's part holds both); one class or sector is drawn.
    kind*: SplitKind ## what is drawn: an offset class, an azimuth sector, or all (`spNone`)
    edges*: seq[float64] ## ascending class edges, `classes + 1` of them; none: no classes
    sectors*: int ## how many azimuth sectors (none: 0); sector 0 starts at north
    pick*: int ## the class or sector drawn; -1: all of them

func finite(x: float64): bool {.inline.} = x.classify notin {fcNan, fcInf, fcNegInf}

func offsetClasses*(s: FoldSplit): int {.inline.} = max(0, s.edges.len - 1)

func classes*(s: FoldSplit): int {.inline.} =
  ## How many places a part keeps a list for: the offset classes, then the sectors.
  s.offsetClasses + (if s.sectors >= 2: s.sectors else: 0)

func active*(s: FoldSplit): bool {.inline.} =
  ## Whether the parts are counted per class or sector.
  s.classes > 0

func drawn*(s: FoldSplit): bool {.inline.} =
  ## Whether one class or sector is drawn (rather than all of them).
  case s.kind
  of spNone: false
  of spOffset: s.pick in 0 ..< s.offsetClasses
  of spAzimuth: s.sectors >= 2 and s.pick in 0 ..< s.sectors

func slot*(s: FoldSplit): int {.inline.} =
  ## Where the class or sector drawn is among the places of a part (offset classes first).
  if s.kind == spAzimuth: s.offsetClasses + s.pick else: s.pick

func shownKind*(s: FoldSplit): SplitKind =
  ## The kind the totals speak of: what is drawn, else the offsets when they are defined.
  if s.kind != spNone: s.kind
  elif s.offsetClasses > 0: spOffset
  elif s.sectors >= 2: spAzimuth
  else: spNone

func number*(v: float64): string =
  ## `v` to at most six significant digits, no trailing zeros (for words, not for keeping).
  result = formatFloat(v, ffDefault, 6)
  result.trimZeros()

func exactNumber*(v: float64): string =
  ## The shortest text without an exponent that reads back as `v`, no trailing ".0".
  for places in 0 .. 20:
    result = formatFloat(v, ffDecimal, places)
    if parseFloat(result) == v: break
  result.trimZeros()

func edgesText*(edges: openArray[float64]): string =
  ## The edges as the box keeps them, exactly: "0, 1000, 2000.5".
  for i, e in edges:
    if i > 0: result.add ", "
    result.add exactNumber(e)

func specId*(s: FoldSplit): string =
  ## Names what the parts are counted for: the edges and the sectors, whichever is defined.
  if s.offsetClasses > 0: result = "o:" & edgesText(s.edges)
  if s.sectors >= 2: result.add "|a:" & $s.sectors

func pickId*(s: FoldSplit): string =
  ## Names `specId` and the class or sector drawn.
  if s.active: s.specId & "@" & (if s.drawn: $ord(s.kind) & ":" & $s.pick else: "-1")
  else: ""

func parseEdges*(text: string): tuple[edges: seq[float64], error: string] =
  ## The offset class edges typed in `text` (separated by commas, semicolons or spaces); none
  ## for empty text. `error` is a sentence when they cannot be used.
  var edges: seq[float64] = @[]
  for tok in text.split({',', ';', ' ', '\t'}):
    if tok.len > 0:
      var v = NaN
      try: v = parseFloat(tok)
      except ValueError: discard
      if not v.finite:
        return (@[], "\"" & tok & "\" is not a number: give the offsets as numbers such as " &
          "0, 1000, 2000.")
      if v < 0:
        return (@[], "An offset is not negative: " & tok & ".")
      if v == 0: v = 0.0 # not "-0"
      if edges.len > 0 and v <= edges[^1]:
        return (@[], "The edges must go up, each larger than the one before: " & tok &
          " follows " & number(edges[^1]) & ".")
      edges.add v
  if edges.len == 1: return (@[], "Give at least two edges (a class is between two).")
  if edges.len > MaxClasses + 1:
    return (@[], "At most " & $MaxClasses & " classes (" & $(MaxClasses + 1) & " edges).")
  (edges, "")

func parseSectors*(text: string): tuple[sectors: int, error: string] =
  ## The number of azimuth sectors typed in `text`: 0 (or empty) for none, else
  ## `MinSectors .. MaxSectors`.
  let t = text.strip
  if t.len == 0: return (0, "")
  var n = -1
  try: n = parseInt(t)
  except ValueError: discard
  if n == 0 or n in MinSectors .. MaxSectors: (n, "")
  else: (0, "Give the sectors as a whole number from " & $MinSectors & " to " & $MaxSectors &
    ", or 0 for all bearings.")

func splitOf*(offsets: string; offsetClass: int; sectors, sector: int): FoldSplit =
  ## The restriction the settings ask for: `offsets` (the edges as `edgesText` gives them) and
  ## `offsetClass` (0: all, else the class + 1), `sectors` and `sector` (0: all, else the
  ## sector + 1). A class drawn wins over a sector drawn.
  result = FoldSplit(pick: -1)
  let edges = parseEdges(offsets)
  if edges.error.len == 0 and edges.edges.len >= 2: result.edges = edges.edges
  if sectors in MinSectors .. MaxSectors: result.sectors = sectors
  if offsetClass in 1 .. result.offsetClasses: (result.kind, result.pick) = (spOffset, offsetClass - 1)
  elif sector in 1 .. result.sectors: (result.kind, result.pick) = (spAzimuth, sector - 1)

func offsetClassOf*(s: FoldSplit; k: TraceKeys): int =
  ## The offset class of trace `k`, -1 for none (processSEG's rule, see the module).
  if s.offsetClasses == 0: return -1
  let coords = finite(k.srcX) and finite(k.srcY) and finite(k.rcvX) and finite(k.rcvY)
  let offset = if coords: hypot(k.rcvX - k.srcX, k.rcvY - k.srcY) else: abs(k.offset)
  if offset >= s.edges[0] and offset < s.edges[^1]: upperBound(s.edges, offset) - 1 else: -1

func sectorOf*(s: FoldSplit; k: TraceKeys): int =
  ## The azimuth sector of trace `k`, -1 for none.
  if s.sectors < 2: return -1
  let coords = finite(k.srcX) and finite(k.srcY) and finite(k.rcvX) and finite(k.rcvY)
  let bearing = if coords: radToDeg(arctan2(k.rcvX - k.srcX, k.rcvY - k.srcY)) else: NaN
  if bearing.isNaN: -1
  else: min(s.sectors - 1, int(floorMod(bearing - 0.0, 360.0) * float64(s.sectors) / 360.0))

func classOf*(s: FoldSplit; k: TraceKeys): int =
  ## The class or sector of trace `k` of the kind the totals speak of, -1 for none.
  case s.shownKind
  of spOffset: s.offsetClassOf(k)
  of spAzimuth: s.sectorOf(k)
  of spNone: -1

func classLabel*(s: FoldSplit; k: int; unit: string): string =
  ## Class or sector `k` in words: "1000–2000 ft", "45–90°".
  case s.kind
  of spOffset:
    number(s.edges[k]) & "–" & number(s.edges[k + 1]) & (if unit.len > 0: " " & unit else: "")
  of spAzimuth:
    number(float64(k) * 360 / float64(s.sectors)) & "–" &
      number(float64(k + 1) * 360 / float64(s.sectors)) & "°"
  of spNone: ""

func drawnLabel*(s: FoldSplit; unit: string): string =
  ## What is drawn, for the legend and the hover: "offsets 1000–2000 ft", "azimuth 45–90°";
  ## empty when every class is.
  if not s.drawn: ""
  else: (if s.kind == spOffset: "offsets " else: "azimuth ") & s.classLabel(s.pick, unit)

func noneWord*(s: FoldSplit): string =
  ## What a trace in no class is said to be in: "no offset class", "no azimuth sector".
  if s.shownKind == spAzimuth: "no azimuth sector" else: "no offset class"
