## Station position overrides (`core/stationmoves`): which move applies before,
## at and after each `fromTime`; two moves of one station; an undated move;
## replace; remove; a trace with no time; `applyMoves` changing only the
## receiver position; a move found as the join finds a station; station-key
## rounding equal to the join's; the project
## document written and read back, and an old project reading as no moves.
##
## Seen to fail: with the dated move taken only when `fromTime` is strictly
## before the trace (the `<=` in `movedPosition` written as `<`), "at the
## fromTime the move applies" (the trace at 1000 kept its old position); with
## `stationMoves` left out of `projectDocument`, "the project document writes
## the moves" (the written document had no `(stationMoves`); with `readMove`
## adding a finite line that `stationKey` turns non-finite and not calling
## `r.problem`, "and a problem is reported" (problems stayed empty); with `add`
## storing a non-finite x, "a non-finite x, y or elevation is not stored"
## (`projectDocument` then died in `nifFloat`'s assert); with lookup by exact
## index only, "a trace with index 0 takes the move stored at index 1" (the
## move at index 1 was not applied).

import std/[math, options, strutils]
import parseSEG
import viewSEG/core/[project, projectnif, stationmoves]

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
    doAssert not applyMoves(moves, other), "index 2 does not take a move stored at index 1"
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

  block project_round_trip:
    var moves = StationMoves()
    moves.add moveAt(100.004, 199.996, 1, some(1_000.5), 1.2345678901234567,
      -2.5, some(3.25), "moved after \"flooding\"")
    moves.add moveAt(10, 20, 0, none(float64), 8, 9, note = "survey")
    var d = ProjectDoc(name: "Land 2026")
    d.stationMoves = moves
    let text = projectDocument(d)
    doAssert "(stationMoves" in text and "fromTime" in text, "the project document writes the moves"
    doAssert "1.2345678901234567" in text, text
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.stationMoves.len == 2
    doAssert back.stationMoves[0].station == stationKey(10, 20, 0)
    doAssert back.stationMoves[0].fromTime.isNone
    doAssert back.stationMoves[0].note == "survey"
    doAssert back.stationMoves[1].station == stationKey(100.004, 199.996, 1)
    doAssert back.stationMoves[1].fromTime == some(1000.5)
    doAssert back.stationMoves[1].x == 1.2345678901234567
    doAssert back.stationMoves[1].y == -2.5 and back.stationMoves[1].elev == some(3.25)
    doAssert back.stationMoves[1].note == "moved after \"flooding\""
    let again = projectDocument(back)
    doAssert again == text, "written again as read"

  block old_project:
    var problems: seq[string]
    let old = readProject("(.nif27)\n(project (version 1) (name \"old\"))\n", "project.nif",
      problems)
    doAssert problems.len == 0, $problems
    doAssert old.stationMoves.len == 0, "an old project reads as no moves"
    doAssert "stationMoves" notin projectDocument(old)

  block unknown_kept:
    var moves = StationMoves()
    moves.add moveAt(1, 2, 1, some(10.0), 3, 4)
    var d = ProjectDoc(name: "Land 2026")
    d.stationMoves = moves
    let withExtra = projectDocument(d).replace("(version 1)", "(version 1)\n (picks (file \"x\"))")
    var problems: seq[string]
    let back = readProject(withExtra, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert back.later.len == 1 and back.later[0].tag == "picks"
    doAssert back.stationMoves.len == 1 and back.stationMoves[0].x == 3
    var again: seq[string]
    let kept = readProject(projectDocument(back), "project.nif", again)
    doAssert kept.later.len == 1 and kept.later[0].tag == "picks",
      "a later version's part is kept"

  block bad_move:
    let text = """(.nif27)
(project (version 1) (name "Land")
 (stationMoves
  (move (line 1.0) (point 2.0) (index 1) (y 4.0))
  (move (line 1.0) (point 2.0) (index 1) (fromTime noon) (x 3.0) (y 4.0))
  (move (line 5.0) (point 6.0) (x 7.0) (y 8.0) (elev "high") (note "kept") (sensor 1))))
"""
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert back.stationMoves.len == 1, "a bad move is left out; a bad fromTime is not undated"
    doAssert back.stationMoves[0].station == stationKey(5, 6, 0), "a missing index is 0"
    doAssert back.stationMoves[0].elev.isNone and back.stationMoves[0].note == "kept"
    doAssert back.later.len == 0, "a field inside a move is not a later version's part"
    doAssert problems.len > 0

  block key_not_storable:
    let text = """(.nif27)
(project (version 1) (name "Land")
 (stationMoves
  (move (line 1e308) (point 2.0) (x 3.0) (y 4.0))
  (move (line 2.0) (point 1e308) (x 5.0) (y 6.0))
  (move (line 1.0) (point 2.0) (x 3.0) (y 4.0))))
"""
    var problems: seq[string]
    let back = readProject(text, "project.nif", problems)
    doAssert back.stationMoves.len == 1, "a line or point stationKey cannot store is left out"
    doAssert back.stationMoves[0].station == stationKey(1.0, 2.0, 0)
    doAssert back.stationMoves[0].x == 3.0 and back.stationMoves[0].y == 4.0
    doAssert problems.len > 0, "and a problem is reported"

  block nonfinite_position_refused:
    var moves = StationMoves()
    moves.add moveAt(1, 2, 1, some(10.0), NaN, 4.0)
    moves.add moveAt(1, 2, 1, some(10.0), Inf, 4.0)
    moves.add moveAt(1, 2, 1, some(10.0), -Inf, 4.0)
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, NaN)
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, Inf)
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, 4.0, some(NaN))
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, 4.0, some(Inf))
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, 4.0, some(-Inf))
    doAssert moves.len == 0, "a non-finite x, y or elevation is not stored"
    var d = ProjectDoc(name: "Land")
    d.stationMoves = moves
    doAssert "stationMoves" notin projectDocument(d), "save writes no move and does not die"
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, 4.0, some(5.0))
    moves.add moveAt(1, 2, 1, some(10.0), NaN, 9.0)
    moves.add moveAt(1, 2, 1, some(10.0), 3.0, 4.0, some(NaN))
    doAssert moves.len == 1 and moves[0].x == 3.0 and moves[0].y == 4.0
    doAssert moves[0].elev == some(5.0), "a refused move does not replace a stored one"
    d.stationMoves = moves
    let text = projectDocument(d)
    doAssert "(x 3.0)" in text and "(y 4.0)" in text and "(elev 5.0)" in text

  block index_as_the_join:
    var exact = StationMoves()
    exact.add moveAt(10, 20, 1, some(1000.0), 30, 40)
    var at2 = filled(10, 20, 2, 1000.0)
    doAssert not applyMoves(exact, at2), "index 2 is not the move stored at index 1"
    doAssert at2.rcvX == 8
    var at0 = filled(10, 20, 0, 1000.0)
    doAssert applyMoves(exact, at0), "a trace with index 0 takes the move stored at index 1"
    doAssert at0.rcvX == 30 and at0.rcvY == 40
    let at0pos = movedPosition(exact, StationKey(line: 10, point: 20, index: 0), 1000.0)
    doAssert at0pos.isSome and xy(at0pos.get) == (30.0, 40.0)

    var anyIndex = StationMoves()
    anyIndex.add moveAt(10, 20, 0, some(1000.0), 7, 8)
    var at5 = filled(10, 20, 5, 1000.0)
    doAssert applyMoves(anyIndex, at5), "a move stored with index 0 applies to any index"
    doAssert at5.rcvX == 7 and at5.rcvY == 8
    var at0any = filled(10, 20, 0, 1000.0)
    doAssert applyMoves(anyIndex, at0any) and at0any.rcvX == 7

    var both = StationMoves()
    both.add moveAt(10, 20, 0, some(1000.0), 1, 1)
    both.add moveAt(10, 20, 3, some(1000.0), 9, 9)
    var at3 = filled(10, 20, 3, 1000.0)
    doAssert applyMoves(both, at3) and at3.rcvX == 9 and at3.rcvY == 9,
      "the exact index wins over index 0"
    var at4 = filled(10, 20, 4, 1000.0)
    doAssert applyMoves(both, at4) and at4.rcvX == 1 and at4.rcvY == 1

    var later = StationMoves()
    later.add moveAt(10, 20, 0, none(float64), 1, 1)
    later.add moveAt(10, 20, 3, some(2000.0), 9, 9)
    var early = filled(10, 20, 3, 1000.0)
    doAssert not applyMoves(later, early),
      "an exact move that does not apply yet is not replaced by index 0"

  echo "tstationmoves: done"

when isMainModule:
  main()
