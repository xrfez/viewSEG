## Tests of the pure part of cutting a continuous gather by a shot log.
## Each was seen to fail with a deliberate fault: the UTC time passed
## through `initSliceShotGps` (shifted by the leap seconds), the id copied
## from the wrong field, the NaN replaced by 0, untimed rows kept, an
## unstable sort, `increasing` always true, a size term left out, and the
## checks removed.

import std/[assertions, math, options]
import processSEG/continuous/slice
import viewSEG/core/[cutgather, shotlog]

func shotAt(us: int64, file = -1'i64): Shot =
  result = Shot(timeUtcUs: some(us), sourceLine: NaN, shotPoint: NaN, x: NaN, y: NaN,
    z: NaN)
  if file >= 0: result.fileNumber = some(file)

func untimed(file: int64): Shot =
  Shot(fileNumber: some(file), sourceLine: NaN, shotPoint: NaN, x: NaN, y: NaN, z: NaN)

const T0 = 1_772_323_200_000_000'i64 # 2026-03-01T00:00:00 UTC

proc main*() =
  block utc_not_shifted:
    let s = sliceShotOf(shotAt(T0 + 250_000))
    doAssert s.timeUsKnown
    doAssert s.timeUs == T0 + 250_000
    doAssert s.time == 1_772_323_200.25, "POSIX seconds by hand"

  block field_mapping:
    var sh = shotAt(T0, 77)
    sh.sourceLine = 12.0
    sh.shotPoint = 345.0
    sh.pointIndex = some(3'i64)
    sh.x = 1.5
    sh.y = 2.5
    sh.z = -3.5
    let s = sliceShotOf(sh)
    doAssert s.id == 77.0
    doAssert s.srcLine == 12.0 and s.srcPoint == 345.0 and s.srcIndex == 3
    doAssert s.srcX == 1.5 and s.srcY == 2.5 and s.srcZ == -3.5

  block nan_kept:
    let s = sliceShotOf(shotAt(T0))
    doAssert s.id.isNaN
    doAssert s.srcLine.isNaN and s.srcPoint.isNaN
    doAssert s.srcX.isNaN and s.srcY.isNaN and s.srcZ.isNaN
    doAssert s.srcIndex == 0

  block untimed_dropped:
    let c = shotsInTime([shotAt(T0 + 2_000_000, 2), untimed(9), shotAt(T0, 1)])
    doAssert c.dropped == 1
    doAssert c.shots.len == 2
    doAssert c.rows == @[2, 0]
    doAssert c.shots[0].timeUs == T0

  block equal_times_stable:
    let c = shotsInTime([shotAt(T0, 5), shotAt(T0, 6), shotAt(T0 - 1, 4)])
    doAssert c.rows == @[2, 0, 1]
    doAssert c.duplicateTimes == 1

  block numbers_from_file:
    let c = shotsInTime([shotAt(T0 + 2, 20), shotAt(T0, 10), shotAt(T0 + 1, 15)])
    doAssert c.increasing
    let r = recordNumbers(c)
    doAssert r.fromFileNumber
    doAssert r.numbers == @[10, 15, 20]

  block numbers_sequence:
    let c = shotsInTime([shotAt(T0 + 2, 10), shotAt(T0, 20), shotAt(T0 + 1, 15)])
    doAssert not c.increasing
    let r = recordNumbers(c)
    doAssert not r.fromFileNumber
    doAssert r.numbers == @[1, 2, 3]
    # a missing or fractional number also falls back
    doAssert not recordNumbers(shotsInTime([shotAt(T0, 1), shotAt(T0 + 1)])).fromFileNumber
    doAssert not recordNumbers(shotsInTime([shotAt(T0, 1), shotAt(T0 + 1,
        0x1000000)])).fromFileNumber

  block size_formulas:
    var o = initCutOptions(1000.0)
    # 2 shots, 3 traces, 250 samples: record 192; trace 20 + 64 + 1000 = 1084
    doAssert estimateBytes(o, 2, 3, 250, false, false, false) == 2 * 192 + 6 * 1084
    # source station +32, source XY +96 per record; receiver XY: 5 extensions
    doAssert estimateBytes(o, 2, 3, 250, true, true, true) ==
      2 * (192 + 32 + 96) + 6 * (20 + 160 + 1000)
    o.standard = csSegy
    doAssert estimateBytes(o, 2, 3, 250, true, true, true) == 3600 + 6 * (240 + 1000)
    doAssert estimateBytes(o, 3_000_000, 4, 500_000, false, false, false) >
      int64(high(int32)), "int64 throughout"

  block check_options:
    doAssert checkOptions(initCutOptions(1000.0), 2.0) == ""
    doAssert checkOptions(initCutOptions(1001.0), 2.0).len > 0, "not whole"
    doAssert checkOptions(initCutOptions(0.0), 2.0).len > 0, "zero"
    doAssert checkOptions(initCutOptions(-4.0), 2.0).len > 0, "negative"
    doAssert checkOptions(initCutOptions(3_000_000.0), 2.0).len > 0, "too long"
    doAssert checkOptions(initCutOptions(1000.0, startMs = 2_147_000.0), 2.0).len > 0
    doAssert checkOptions(initCutOptions(1000.0), 0.0).len > 0

  echo "tcutgather ok"

when isMainModule:
  main()
