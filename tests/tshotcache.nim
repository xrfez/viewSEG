## The shot cache file kept beside the index cache (`core/shotfiles`): what
## `cacheText` writes `parseCache` reads back; a damaged file (a number out
## of its range, a line cut short, another version) is said not to be one,
## so the file is read again, and never ends the program.
##
## Seen to fail: with the station index and the nanoseconds taken without a
## range check, a point index of 99999 and a nanosecond of 2e9 each raised a
## RangeDefect, which `readShots`'s worker does not catch.

import std/times
import viewSEG/core/shotfiles

let f = FileShots(path: "/data/shot.sgd", size: 1234, modified: initTime(1_700_000_000, 5),
  shots: @[ShotOf(gather: 0, record: 151, source: StationKey(line: 129, point: 113, index: 1),
    hasStation: true, x: 1833476.1, y: 417000.8),
    ShotOf(gather: 1, record: NaN, x: NaN, y: NaN)])
let text = f.cacheText
block roundTrip:
  let (ok, back) = parseCache(text, f.path)
  doAssert ok and back.size == f.size and back.modified == f.modified and back.shots.len == 2
  doAssert back.shots[0].hasStation and back.shots[0].source.index == 1 and
    back.shots[0].record == 151 and not back.shots[1].hasStation

block damaged:
  let bad = [
    "viewSEG shots 1\n1234 1700000000 5\n0 151 129 113 99999 1.0 2.0\n", # index past int16
    "viewSEG shots 1\n1234 1700000000 2000000000\n",                      # nanoseconds
    "viewSEG shots 1\n1234 1700000000 -1\n",
    "viewSEG shots 1\n1234 1700000000 5\n0 151 129 113 1 1.0\n",           # cut short
    "viewSEG shots 1\n1234 x 5\n",
    "viewSEG shots 0\n1234 1700000000 5\n"]
  for t in bad:
    let (ok, _) = parseCache(t, f.path)
    doAssert not ok, "taken: " & t

echo "tshotcache: ok"
