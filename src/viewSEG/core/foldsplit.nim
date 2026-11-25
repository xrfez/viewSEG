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
    spNone    ## no restriction
    spOffset  ## offset classes
    spAzimuth ## azimuth sectors

  FoldSplit* = object
    ## The restriction the fold layers are counted with.
    kind*: SplitKind
    edges*: seq[float64] ## `spOffset`: ascending class edges, `classes + 1` of them
    sectors*: int        ## `spAzimuth`: how many; sector 0 starts at north
    pick*: int           ## the class or sector drawn; -1: all of them

func finite(x: float64): bool {.inline.} = x.classify notin {fcNan, fcInf, fcNegInf}

func classes*(s: FoldSplit): int =
  ## How many classes or sectors the restriction has.
  case s.kind
  of spNone: 0
  of spOffset: max(0, s.edges.len - 1)
  of spAzimuth: s.sectors

func active*(s: FoldSplit): bool {.inline.} =
  ## Whether the parts are counted per class or sector.
  s.classes > 0

func drawn*(s: FoldSplit): bool {.inline.} =
  ## Whether one class or sector is drawn (rather than all of them).
  s.active and s.pick in 0 ..< s.classes

func number*(v: float64): string =
  ## `v` to at most six significant digits, no trailing zeros.
  result = formatFloat(v, ffDefault, 6)
  result.trimZeros()

func edgesText*(edges: openArray[float64]): string =
  ## The edges as the box shows them: "0, 1000, 2000".
  for i, e in edges:
    if i > 0: result.add ", "
    result.add number(e)

func specId*(s: FoldSplit): string =
  ## Names what the parts are counted for: the kind and the edges or the sectors.
  case s.kind
  of spNone: ""
  of spOffset: "o:" & edgesText(s.edges)
  of spAzimuth: "a:" & $s.sectors

func pickId*(s: FoldSplit): string =
  ## Names `specId` and the class or sector drawn.
  if s.active: s.specId & "@" & $(if s.drawn: s.pick else: -1) else: ""

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
  ## sector + 1). A class drawn wins over a sector drawn; with neither, the edges stand before
  ## the sectors.
  let edges = parseEdges(offsets)
  let byOffset = edges.error.len == 0 and edges.edges.len >= 2
  let bySector = sectors in MinSectors .. MaxSectors
  let offsetPick = if byOffset and offsetClass in 1 .. edges.edges.len - 1: offsetClass - 1 else: -1
  let sectorPick = if bySector and sector in 1 .. sectors: sector - 1 else: -1
  if byOffset and (offsetPick >= 0 or sectorPick < 0):
    FoldSplit(kind: spOffset, edges: edges.edges, pick: offsetPick)
  elif bySector:
    FoldSplit(kind: spAzimuth, sectors: sectors, pick: sectorPick)
  else: FoldSplit(pick: -1)

func classOf*(s: FoldSplit; k: TraceKeys): int =
  ## The class or sector of trace `k`, -1 for none (processSEG's rule, see the module).
  let coords = finite(k.srcX) and finite(k.srcY) and finite(k.rcvX) and finite(k.rcvY)
  case s.kind
  of spNone: -1
  of spOffset:
    let offset = if coords: hypot(k.rcvX - k.srcX, k.rcvY - k.srcY) else: abs(k.offset)
    if offset >= s.edges[0] and offset < s.edges[^1]: upperBound(s.edges, offset) - 1
    else: -1
  of spAzimuth:
    let bearing = if coords: radToDeg(arctan2(k.rcvX - k.srcX, k.rcvY - k.srcY)) else: NaN
    if bearing.isNaN: -1
    else: min(s.sectors - 1, int(floorMod(bearing - 0.0, 360.0) * float64(s.sectors) / 360.0))

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
  if s.kind == spAzimuth: "no azimuth sector" else: "no offset class"
