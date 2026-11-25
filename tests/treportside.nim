## The side of a file for the missing-traces and trace-quality reports: from the kind of
## recording the file is treated as (set in the Files window, else told from the file),
## and only from its stations when the kind is not told. A mix of shot and receiver
## gathers is counted, not calculated.
##
## Seen to fail: with a continuous recording mapped to the shot side,
## `kinds_map_to_sides` rejected rsShot for rsNotGather; with a file of one receiver and
## one source taken as a shot without being set, `a_forced_kind_wins` rejected rsShot for
## rsCannotTell.

import std/[options, strutils]
import parseSEG
import viewSEG/core/[recordingkind, relationside, reportside]

proc stationsOf(traces: openArray[tuple[rcv, src: float64]]): Stations =
  result = initStations()
  for (r, s) in traces:
    var k = initTraceKeys()
    k.rcvLine = 10
    k.rcvPoint = r
    k.srcLine = 1
    k.srcPoint = s
    k.status = tsLive
    result.note k

proc main*() =
  let shot = stationsOf([(1.0, 1.0), (2.0, 1.0), (3.0, 1.0)])
  let receiver = stationsOf([(7.0, 1.0), (7.0, 2.0), (7.0, 3.0)])
  let slice = stationsOf([(7.0, 1.0)])
  let both = stationsOf([(1.0, 1.0), (2.0, 1.0), (1.0, 2.0), (2.0, 2.0)])

  block kinds_map_to_sides:
    doAssert reportSide(some(rkShotGather), false, shot).side == rsShot
    doAssert reportSide(some(rkReceiverSliced), false, receiver).side == rsReceiver
    # the kind decides, not the station count, when it is told
    doAssert reportSide(some(rkReceiverSliced), false, both).side == rsReceiver
    doAssert reportSide(some(rkShotGather), false, both).side == rsShot
    let c = reportSide(some(rkReceiverContinuous), false, receiver)
    doAssert c.side == rsNotGather and c.why == ContinuousWhy

  block a_forced_kind_wins:
    # one receiver and one source cannot be told; set, it is what the user said
    let unset = reportSide(none(RecordingKind), false, slice)
    doAssert unset.side == rsCannotTell and unset.why.contains("Files window"), unset.why
    doAssert reportSide(some(rkShotGather), false, slice).side == rsCannotTell
    doAssert reportSide(some(rkShotGather), true, slice).side == rsShot
    doAssert reportSide(some(rkReceiverSliced), true, slice).side == rsReceiver
    doAssert reportSide(some(rkReceiverContinuous), true, shot).side == rsNotGather

  block not_told_takes_the_stations:
    doAssert reportSide(none(RecordingKind), false, shot).side == rsShot
    doAssert reportSide(none(RecordingKind), false, receiver).side == rsReceiver
    let neither = reportSide(none(RecordingKind), false, both)
    doAssert neither.side == rsCannotTell and neither.why.contains("Files window"),
      neither.why

  block a_mix_is_counted:
    var c: SideCounts
    for side in [rsShot, rsShot, rsNotGather, rsCannotTell]: c.note side
    doAssert not c.isMixed and c.shots == 2 and c.untold == 1 and c.receivers == 0
    c.note rsReceiver
    doAssert c.isMixed
    let words = mixedNote(c)
    doAssert "2 are shot gathers" in words and "1 is a receiver gather" in words and
      "1 could not be told" in words and "Files window" in words, words
    doAssert "nothing is calculated" in words, words

  echo "treportside: ok"

when isMainModule:
  main()
