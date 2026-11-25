## A receiver station's position as corrected for the project, never written
## into the seismic file or the survey file.
##
## A station moved during a deployment has one receiver row, and the headers
## are not updated. A `StationMove` names that station and the position that
## holds from a time on. The station is the join's key (line, point, index:
## `StationKey`, rounded by `stationKey` to 1/100). A move is found as the
## join finds a station: the same index, else one stored with index 0 (any
## index), else a trace with index 0 takes a move stored with index 1. The
## move does not name a sensor class or a component.
##
## `fromTime` is the same absolute time as `TraceKeys.time` (UTC POSIX
## seconds). A move with no `fromTime` holds for every trace of the station.
## Several moves of one station are kept. The move that applies to a trace is
## the latest `fromTime` that is not after the trace's time; that move
## replaces an undated one. A trace whose time is before every dated
## `fromTime` keeps the position it has, unless an undated move gives one.
## A trace with no time (not a finite `TraceKeys.time`) takes only an undated
## move.
##
## Adding a move with the same station and the same `fromTime` replaces it.
## The list stays sorted by station (line, point, index) and then by time,
## an undated move before a dated one.
##
## `applyFileMoves` puts the list onto an open file's keys, after the header
## or survey position already there, and recomputes offset and midpoint
## (`deriveGeometry`). It remembers the receiver fields it replaced, so a
## later call with those and an empty list puts them back. It never writes
## the file.

import std/[algorithm, math, options]
import parseSEG
import parseSEG/model/traceindex
import stationindex

const MaxMoveNote* = 256 ## bytes of a move's note

func cleanNote*(note: string): string =
  ## `note` cut to `MaxMoveNote` bytes at a character's edge (a character that ends exactly
  ## there stays), its control characters and line breaks made blanks.
  result = note
  if result.len > MaxMoveNote:
    let edge = (ord(result[MaxMoveNote]) and 0xC0) != 0x80         # a character starts at the cut
    result.setLen MaxMoveNote
    if not edge:
      while result.len > 0 and (ord(result[^1]) and 0xC0) == 0x80: result.setLen result.len - 1
      if result.len > 0 and ord(result[^1]) >= 0xC0: result.setLen result.len - 1
  for c in result.mitems:
    if c < ' ' or c == '\x7f': c = ' '

type OwnPositionKind* = enum
  opReading ## asked for and not yet back, or not asked for
  opNone    ## the header gives no position (NaN or (0, 0))
  opNotRead ## the header was not read: `why` says
  opGiven   ## the header gives a position

func ownPositionTip*(kind: OwnPositionKind; why, station: string): string =
  ## What the "header position" choice says when it offers no position, of `station` (words
  ## naming it): the header gives none, is not read yet, or was not read for `why`.
  case kind
  of opNotRead: "This trace's header was not read: " & why & ". The position can be typed " &
    "with \"Move this station...\"."
  of opNone: "This trace's header gives " & station & " no position to move it to."
  of opReading, opGiven: "This trace's header is still being read."

type
  StationMove* = object
    ## A new position for one receiver station, in the survey's units.
    station*: StationKey   ## line, point, index; stored rounded by `stationKey`
    fromTime*: Option[float64]
      ## when the position starts to hold (`TraceKeys.time`); none: every trace
    x*, y*: float64
    elev*: Option[float64] ## elevation; none when not given
    note*: string          ## why the station was moved

  MovedPosition* = tuple
    x, y: float64
    elev: Option[float64]

  StationMoves* = object
    ## The project's station moves, sorted by station then time.
    list: seq[StationMove]

func finite(x: float64): bool {.inline.} =
  x == x and x != Inf and x != -Inf

func finiteOpt(x: Option[float64]): Option[float64] =
  ## `x` when it holds a finite number; none otherwise.
  if x.isSome and finite(x.get): x else: none(float64)

func cmpFloat(a, b: float64): int =
  if a < b: -1 elif a > b: 1 else: 0

func cmpKey(a, b: StationKey): int =
  result = cmpFloat(a.line, b.line)
  if result == 0: result = cmpFloat(a.point, b.point)
  if result == 0: result = cmp(a.index, b.index)

func cmpTime(a, b: Option[float64]): int =
  ## Undated before dated; dated in time order.
  if a.isNone and b.isNone: 0
  elif a.isNone: -1
  elif b.isNone: 1
  else: cmpFloat(a.get, b.get)

func len*(moves: StationMoves): int {.inline.} =
  ## How many moves `moves` holds.
  moves.list.len

func `[]`*(moves: StationMoves; i: int): lent StationMove {.inline.} =
  ## The move at `i` (sorted order).
  moves.list[i]

iterator items*(moves: StationMoves): lent StationMove =
  ## The moves in sorted order.
  for i in 0 ..< moves.list.len:
    yield moves.list[i]

iterator pairs*(moves: StationMoves): tuple[i: int; move: StationMove] =
  ## The moves in sorted order, with their index.
  for i in 0 ..< moves.list.len:
    yield (i, moves.list[i])

func slot(moves: StationMoves; key: StationKey; fromTime: Option[float64]): int =
  ## Where a move of `key` at `fromTime` sits, or would sit.
  var lo = 0
  var hi = moves.list.len
  while lo < hi:
    let mid = (lo + hi) shr 1
    let byStation = cmpKey(moves.list[mid].station, key)
    let byTime = if byStation == 0: cmpTime(moves.list[mid].fromTime, fromTime) else: byStation
    if byTime < 0: lo = mid + 1
    else: hi = mid
  lo

func sameSlot(moves: StationMoves; i: int; key: StationKey; fromTime: Option[float64]): bool =
  i < moves.list.len and moves.list[i].station == key and
    cmpTime(moves.list[i].fromTime, fromTime) == 0

proc add*(moves: var StationMoves; move: StationMove) =
  ## Puts `move` in, in station then time order. The same station and the
  ## same `fromTime` replaces the move already there. Line and point are
  ## stored as `stationKey` rounds them. A station whose line or point is
  ## not a finite number, whose x or y is not, or whose elevation is given
  ## and not finite, is not added. A `fromTime` that is not finite is stored
  ## as none.
  let key = stationKey(move.station.line, move.station.point, move.station.index)
  if not finite(key.line) or not finite(key.point): return
  if not finite(move.x) or not finite(move.y): return
  if move.elev.isSome and not finite(move.elev.get): return
  var stored = move
  stored.station = key
  stored.fromTime = finiteOpt(move.fromTime)
  stored.elev = move.elev
  let at = slot(moves, key, stored.fromTime)
  if sameSlot(moves, at, key, stored.fromTime): moves.list[at] = stored
  else: moves.list.insert(stored, at)

proc remove*(moves: var StationMoves; station: StationKey; fromTime: Option[float64]): bool =
  ## Takes out the move of `station` at `fromTime` (none: the undated move).
  ## True when one was there. Line and point are rounded as `add` rounds them.
  let key = stationKey(station.line, station.point, station.index)
  if not finite(key.line) or not finite(key.point): return false
  let whenFrom = finiteOpt(fromTime)
  let at = slot(moves, key, whenFrom)
  if not sameSlot(moves, at, key, whenFrom): return false
  moves.list.delete(at)
  true

func movedPosition*(moves: StationMoves; station: StationKey; traceTime: float64):
    Option[MovedPosition] =
  ## The position that applies to `station` at `traceTime`: `(x, y, elev)`.
  ## `elev` is none when that move gives no elevation.
  ##
  ## The station is the one the join would find (`stationIndexTries`): the
  ## same index, else a move stored with index 0 (any index of this line and
  ## point), else, for a trace with index 0, a move stored with index 1. The
  ## first of those that has a move is the station; a later try is not used.
  ## Within it, the latest `fromTime` that is not after `traceTime` wins. An
  ## undated move applies when no dated move does, and is the only move a
  ## trace with no time (not a finite `traceTime`) can take. None when no
  ## move applies: the trace keeps the position it has.
  let probe = stationKey(station.line, station.point, station.index)
  if not finite(probe.line) or not finite(probe.point): return none(MovedPosition)
  let timed = finite(traceTime)
  for indexTry in stationIndexTries(station.index):
    let key = stationKey(station.line, station.point, indexTry)
    var chosen = -1
    var found = false
    var i = slot(moves, key, none(float64))
    while i < moves.list.len and moves.list[i].station == key:
      found = true
      let fromTime = moves.list[i].fromTime
      if fromTime.isNone: chosen = i
      elif timed and fromTime.get <= traceTime: chosen = i
      inc i
    if found:
      if chosen < 0: return none(MovedPosition)
      let move = moves.list[chosen]
      return some((x: move.x, y: move.y, elev: move.elev))
  none(MovedPosition)

proc applyMoves*(moves: StationMoves; keys: var TraceKeys): bool =
  ## Sets `keys.rcvX` and `keys.rcvY` from the move that applies to the
  ## trace's receiver station (`rcvLine`, `rcvPoint`, `rcvIndex`) at
  ## `keys.time`, matched as the join matches that station, and sets
  ## `keys.rcvZ` when that move gives an elevation.
  ## No other key field changes. Returns whether a move applied.
  ##
  ## Offsets derived from positions are not recomputed here. The caller must
  ## recompute them: the source-receiver distance written over `offset`
  ## (`firstbreakjobs.nim:261-263`), `dx` and `dy` (`firstbreakjobs.nim:296`),
  ## the midpoint `cmpX` and `cmpY`, and a copy of `rcvX`/`rcvY` already taken
  ## (`analysisreader.nim:564-565`, spaced along at `fkanalysis.nim:48-58`).
  let station = StationKey(line: keys.rcvLine, point: keys.rcvPoint, index: keys.rcvIndex)
  let pos = movedPosition(moves, station, keys.time)
  if pos.isNone: return false
  keys.rcvX = pos.get.x
  keys.rcvY = pos.get.y
  if pos.get.elev.isSome: keys.rcvZ = pos.get.elev.get
  true

type
  ReceiverBase* = object
    ## A trace's receiver fields, and the join marks on them, before a move
    ## replaced them. Putting them back restores the header or survey position.
    index*: int
    rcvX*, rcvY*, rcvZ*, offset*, cmpX*, cmpY*: float64
    joined*: set[JoinGroup]

func sameNum(x, y: float64): bool {.inline.} =
  x == y or (x.isNaN and y.isNaN)

func snap(file: SeismicFile; t: int): ReceiverBase =
  let k = file.traceKeys(t)
  ReceiverBase(index: t, rcvX: k.rcvX, rcvY: k.rcvY, rcvZ: k.rcvZ, offset: k.offset,
    cmpX: k.cmpX, cmpY: k.cmpY, joined: file.index.joinedGroups(t))

proc putBack(file: var SeismicFile; b: ReceiverBase) =
  let t = b.index
  if t < 0 or t >= file.len: return
  template k: untyped = file.mindex.keys[t]
  k.rcvX = b.rcvX
  k.rcvY = b.rcvY
  k.rcvZ = b.rcvZ
  k.offset = b.offset
  k.cmpX = b.cmpX
  k.cmpY = b.cmpY
  if file.mindex.joinedTraces.len != file.mindex.keys.len:
    file.mindex.joinedTraces.setLen file.mindex.keys.len
  if t < file.mindex.joinedTraces.len: file.mindex.joinedTraces[t] = b.joined

func receiverDiffers(file: SeismicFile; b: ReceiverBase): bool =
  if b.index < 0 or b.index >= file.len: return false
  let k = file.traceKeys(b.index)
  not sameNum(k.rcvX, b.rcvX) or not sameNum(k.rcvY, b.rcvY) or not sameNum(k.rcvZ, b.rcvZ) or
    not sameNum(k.offset, b.offset) or not sameNum(k.cmpX, b.cmpX) or not sameNum(k.cmpY, b.cmpY)

proc findBase(bases: seq[ReceiverBase]; index: int): int =
  ## Index of the base for trace `index` in `bases`, sorted by trace; -1 if none.
  result = -1
  var lo = 0
  var hi = bases.high
  while lo <= hi:
    let mid = (lo + hi) div 2
    if bases[mid].index == index: return mid
    elif bases[mid].index < index: lo = mid + 1
    else: hi = mid - 1

func marksRemain(file: SeismicFile): bool =
  for groups in file.index.joinedTraces:
    if groups.card > 0: return true

proc applyFileMoves*(file: var SeismicFile; moves: StationMoves; bases: var seq[
    ReceiverBase]): int =
  ## Puts `bases` back into `file`'s keys, then applies `moves` over the
  ## receiver positions now there. A trace a move touches is left in `bases`
  ## as it was before that move, so a later call with those bases and an
  ## empty list restores it. Bumps `keysRevision` only when a receiver field
  ## changes, and marks the file joined when a move changed keys, so the
  ## cache is not written as the file's own. Never writes the file. Returns
  ## how many traces changed. A file without keys is left alone, `bases` included.
  if not file.hasKeys: return 0
  var entry: seq[ReceiverBase] = @[]
  for b in bases:
    if b.index >= 0 and b.index < file.len: entry.add snap(file, b.index)
    putBack(file, b)
  entry.sort(proc (a, b: ReceiverBase): int = cmp(a.index, b.index))
  var next: seq[ReceiverBase] = @[]
  var touched: seq[int] = @[]
  for t in 0 ..< file.len:
    let pre = snap(file, t)
    let before = file.traceKeys(t)
    if applyMoves(moves, file.mindex.keys[t]):
      file.mindex.keys[t].deriveGeometry(overwrite = true)
      file.mindex.markJoined(t, changedGroups(before, file.traceKeys(t)))
      next.add pre
      touched.add t
  var changed = 0
  for i, t in touched:
    let at = findBase(entry, t)
    let start = if at >= 0: entry[at] else: next[i]
    if receiverDiffers(file, start): inc changed
  var ti = 0
  for e in entry:
    while ti < touched.len and touched[ti] < e.index: inc ti
    if ti < touched.len and touched[ti] == e.index: continue
    if receiverDiffers(file, e): inc changed
  if changed > 0:
    inc file.mindex.keysRevision
    if moves.len > 0: file.mindex.joined = true
    elif not marksRemain(file): file.mindex.joined = false
  bases = next
  changed
