## Station position overrides (`core/stationmoves`): which move applies before,
## at and after each `fromTime`; two moves of one station; an undated move;
## replace; remove; a trace with no time; `applyMoves` changing only the
## receiver position; station-key rounding equal to the join's.
##
## Seen to fail: with the dated move taken only when `fromTime` is strictly
## before the trace (the `<=` in `movedPosition` written as `<`), "at the
## fromTime the move applies" (the trace at 1000 kept its old position).

import std/[math, options]
import parseSEG
import viewSEG/core/stationmoves

proc moveAt(line, point: float64; index: int16; fromTime: Option[float64]; x, y: float64;
    elev: Option[float64] = none(float64); note = ""): StationMove =
  StationMove(station: StationKey(line: line, point: point, index: index), fromTime: fromTime,
    x: x, y: y, elev: elev, note: note)

proc filled(line, point: float64; index: int16; time: float64): TraceKeys =
  result = initTraceKeys()
  result.record = 1
  result.ensemble = 2
  result.offset = 3
  result.srcLine = 4
  result.srcPoint = 5
  result.srcX = 6
  result.srcY = 7
  result.rcvLine = line
  result.rcvPoint = point
  result.rcvX = 8
  result.rcvY = 9
  result.srcZ = 11
  result.rcvZ = 12
  result.cmpX = 13
  result.cmpY = 14
  result.srcIndex = 1
  result.rcvIndex = index
  result.depthIndex = 1
  result.reshootIndex = 1
  result.sensorType = 1
  result.component = 1
  result.traceCode = 1
  result.status = tsLive
  result.traceCodeRev = tcrRev1
  result.channel = 15
  result.time = time
  result.t0Ms = 16
  result.intervalUs = 17
  result.inline = 18
  result.crossline = 19

proc xy(pos: MovedPosition): tuple[x, y: float64] = (pos.x, pos.y)

proc main*() =
  block before_at_after:
    var moves = StationMoves()
    moves.add moveAt(10, 20, 1, some(1000.0), 1, 2, note = "first")
    moves.add moveAt(10, 20, 1, some(2000.0), 3, 4, note = "second")
    let station = StationKey(line: 10, point: 20, index: 1)
    doAssert movedPosition(moves, station, 999.0).isNone, "before every fromTime keeps its position"
    let atFirst = movedPosition(moves, station, 1000.0)
    doAssert atFirst.isSome and xy(atFirst.get) == (1.0, 2.0), "at the fromTime the move applies"
    let between = movedPosition(moves, station, 1500.0)
    doAssert between.isSome and xy(between.get) == (1.0, 2.0), "after the first, before the second"
    let atSecond = movedPosition(moves, station, 2000.0)
    doAssert atSecond.isSome and xy(atSecond.get) == (3.0, 4.0),
      "at the later fromTime that move applies"
    let after = movedPosition(moves, station, 2500.0)
    doAssert after.isSome and xy(after.get) == (3.0, 4.0), "after both, the latest applies"

  block two_moves_sorted:
    var moves = StationMoves()
    moves.add moveAt(2, 1, 1, some(5.0), 9, 9)
    moves.add moveAt(1, 2, 1, some(3.0), 8, 8)
    moves.add moveAt(1, 1, 2, some(1.0), 7, 7)
    moves.add moveAt(1, 1, 1, some(4.0), 6, 6)
    moves.add moveAt(1, 1, 1, none(float64), 5, 5)
    doAssert moves.len == 5
    doAssert moves[0].station == stationKey(1, 1, 1) and moves[0].fromTime.isNone
    doAssert moves[1].fromTime == some(4.0)
    doAssert moves[2].station.index == 2
    doAssert moves[3].station == stationKey(1, 2, 1)
    doAssert moves[4].station == stationKey(2, 1, 1)

  block undated:
    var moves = StationMoves()
    moves.add moveAt(10, 20, 1, none(float64), 1, 2, note = "survey")
    moves.add moveAt(10, 20, 1, some(1000.0), 3, 4, note = "moved after flooding")
    let station = StationKey(line: 10, point: 20, index: 1)
    let before = movedPosition(moves, station, 500.0)
    doAssert before.isSome and xy(before.get) == (1.0, 2.0), "undated holds before every fromTime"
    let after = movedPosition(moves, station, 1000.0)
    doAssert after.isSome and xy(after.get) == (3.0, 4.0), "dated replaces undated from its time"
    let notime = movedPosition(moves, station, NaN)
    doAssert notime.isSome and xy(notime.get) == (1.0, 2.0),
      "a trace with no time takes the undated move"
    doAssert movedPosition(moves, station, Inf).isNone == false
    doAssert xy(movedPosition(moves, station, Inf).get) == (1.0, 2.0)

  block undated_absent_no_time:
    var moves = StationMoves()
    moves.add moveAt(10, 20, 1, some(1000.0), 3, 4)
    doAssert movedPosition(moves, StationKey(line: 10, point: 20, index: 1), NaN).isNone,
      "a trace with no time takes only an undated move"

  block replace:
    var moves = StationMoves()
    moves.add moveAt(10, 20, 1, some(1000.0), 1, 2, note = "first note")
    moves.add moveAt(10, 20, 1, some(1000.0), 9, 8, some(4.5), "moved after flooding")
    doAssert moves.len == 1, "the same station and fromTime replaces"
    doAssert moves[0].x == 9 and moves[0].y == 8 and moves[0].elev == some(4.5)
    doAssert moves[0].note == "moved after flooding"

  block remove_move:
    var moves = StationMoves()
    moves.add moveAt(10, 20, 1, some(1000.0), 1, 2)
    moves.add moveAt(10, 20, 1, some(2000.0), 3, 4)
    moves.add moveAt(11, 20, 1, some(1000.0), 5, 6)
    doAssert moves.remove(StationKey(line: 10, point: 20, index: 1), some(1000.0))
    doAssert moves.len == 2
    doAssert movedPosition(moves, StationKey(line: 10, point: 20, index: 1), 1000.0).isNone
    let later = movedPosition(moves, StationKey(line: 10, point: 20, index: 1), 2000.0)
    doAssert later.isSome and xy(later.get) == (3.0, 4.0), "remove leaves the other move"
    doAssert not moves.remove(StationKey(line: 10, point: 20, index: 1), some(1000.0))
    let other = movedPosition(moves, StationKey(line: 11, point: 20, index: 1), 1000.0)
    doAssert other.isSome and xy(other.get) == (5.0, 6.0)

  block apply_only_receiver:
    var moves = StationMoves()
    moves.add moveAt(10, 20, 1, some(1000.0), 30, 40, some(50.0))
    var keys = filled(10, 20, 1, 1000.0)
    let before = keys
    doAssert applyMoves(moves, keys), "the move applies"
    doAssert keys.rcvX == 30 and keys.rcvY == 40 and keys.rcvZ == 50
    var back = keys
    back.rcvX = before.rcvX
    back.rcvY = before.rcvY
    back.rcvZ = before.rcvZ
    doAssert back == before, "applyMoves changes only rcvX, rcvY and rcvZ"
    var plain = filled(10, 20, 1, 1000.0)
    var noElev = StationMoves()
    noElev.add moveAt(10, 20, 1, some(1000.0), 30, 40)
    doAssert applyMoves(noElev, plain)
    doAssert plain.rcvX == 30 and plain.rcvY == 40 and plain.rcvZ == 12,
      "elevation is left when the move gives none"
    doAssert plain.offset == 3 and plain.cmpX == 13 and plain.cmpY == 14
    var other = filled(10, 20, 2, 1000.0)
    doAssert not applyMoves(moves, other), "a different index is a different station"
    doAssert other.rcvX == 8 and other.rcvY == 9
    var early = filled(10, 20, 1, 999.0)
    doAssert not applyMoves(moves, early)
    doAssert early.rcvX == 8
    var notime = filled(10, 20, 1, NaN)
    doAssert not applyMoves(moves, notime), "no time, and no undated move"
    doAssert notime.rcvX == 8

  block rounding:
    doAssert stationKey(100.0, 200.0, 1) == stationKey(100.004, 199.996, 1),
      "a 1/100 difference matches"
    doAssert stationKey(100.0, 200.0, 1) != stationKey(100.01, 200.0, 1)
    var moves = StationMoves()
    moves.add moveAt(100.004, 199.996, 1, some(10.0), 1.5, 2.5)
    doAssert moves[0].station == stationKey(100.004, 199.996, 1), "stored as the join rounds"
    let got = movedPosition(moves, StationKey(line: 100.0, point: 200.0, index: 1), 10.0)
    doAssert got.isSome and xy(got.get) == (1.5, 2.5), "lookup rounds as the join does"
    var keys = filled(100.001, 200.004, 1, 10.0)
    doAssert applyMoves(moves, keys)
    doAssert keys.rcvX == 1.5 and keys.rcvY == 2.5

  echo "tstationmoves: done"

when isMainModule:
  main()
