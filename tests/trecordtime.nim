## `timeZeroOfRecord` gives the same instant as the library's
## `recordTimeZeroUs` on every kind of file the tests can write: SEG-D Rev 3
## with a Timestamp block and a delay, SEG-D Rev 3 without a Timestamp block
## (the record's time zero only, also with a late channel set start), SEG-Y
## Rev 1 (whole seconds) and Rev 2 (nanoseconds) with a sub-second time and a
## delay, SEG-Y Rev 2 with a negative delay, and a SEG-Y file without a time.
## The library proc is called here only as the oracle; this goes when that
## proc is removed. The keys-only overload is also checked on keys built by
## hand: a SEG-D channel set with no delay, whose time zero is the header
## clock itself.
##
## Seen to fail: with the delay left out of the subtraction, the delayed files
## differed from the library ("SEG-Y Rev 1, delay 12.5 (keys false) trace 0:
## some(1700000000012500) vs some(1700000000000000)").

import std/[math, options, os]
import parseSEG
import viewSEG/core/recordtime
import utils/fixtures

const
  Base = 1_700_000_000.0
  Frac = 0.123457 ## whole microseconds, not exact in a float64

proc writeSegy(path: string; major: int; delayMs: float64; timed: bool) =
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(
    major: uint8(major), minor: uint8(if major == 2: 1 else: 0)), traceSorting: 1,
        measurementSystem: 1))
  for r in 0 ..< 3:
    for c in 1 .. 2:
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs) = (float64(r + 1), float64(c), delayMs, 2000.0)
      if timed: k.time = Base + float64(r) * 100.0 + Frac
      k.status = tsLive
      w.writeTrace(k, [1.0'f32, 2, 3, 4])
  doAssert w.close().len == 0

proc writeSegd(path: string; delayMs: float64) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4))
  for r in 0 ..< 3:
    for c in 1 .. 2:
      var k = initTraceKeys()
      (k.record, k.channel, k.t0Ms, k.intervalUs) = (float64(r + 1), float64(c), delayMs, 2000.0)
      k.time = Base + float64(r) * 100.0 + Frac
      k.status = tsLive
      w.writeTrace(k, [1.0'f32, 2, 3, 4])
  doAssert w.close().len == 0

proc same(path, what: string; wantSome = true) =
  for keys in [false, true]:
    var f = openSeismic(path, keys = keys)
    defer: f.close()
    doAssert f.len > 0, what
    for t in 0 ..< f.len:
      let got = f.timeZeroOfRecord(t)
      let want = f.recordTimeZeroUs(t)
      doAssert got == want, what & " (keys " & $keys & ") trace " & $t & ": " & $got &
        " vs " & $want
      doAssert got.isSome == wantSome, what & ": " & $got

proc main*() =
  withFixtures fx:
    for delay in [0.0, 12.5, -20.0]:
      let d = $delay
      for major in [1, 2]:
        let p = fx.dir / ("zero-" & $major & "-" & d & ".sgy")
        writeSegy(p, major, delay, true)
        same(p, "SEG-Y Rev " & $major & ", delay " & d)
      let g = fx.dir / ("zero-" & d & ".sgd")
      writeSegd(g, delay)
      same(g, "SEG-D Rev 3, delay " & d)
    let none = fx.dir / "zero-none.sgy"
    writeSegy(none, 2, 0.0, false)
    same(none, "SEG-Y without a time", wantSome = false)
    for p in [fx.twoSetSegd(), fx.lateStartSegd(100), fx.stationsSegd()]:
      same(p, "SEG-D Rev 3 without a Timestamp block: " & p.extractFilename)
    block exact_microseconds:
      # a Rev 2 sub-second is kept to the microsecond
      let p = fx.dir / "zero-2-0.0.sgy"
      var f = openSeismic(p)
      defer: f.close()
      let t = f.timeZeroOfRecord(0)
      doAssert t.isSome and t.get == 1_700_000_000_123_457'i64, $t
    block header_clock_without_delay:
      # a SEG-D channel set the headers do not describe: no delay, so the
      # header clock is the time zero
      var k = initTraceKeys()
      k.time = 1_700_000_007.0
      k.noteRecordedTime(toHeaderSeconds, 1_700_000_007_000_000'i64)
      doAssert k.timeZeroOfRecord(skSegd) == some(1_700_000_007_000_000'i64)
      k.time = 1_700_000_007.654321
      k.noteRecordedTime(toRecordTimeZero, 1_700_000_007_654_321'i64)
      doAssert k.timeZeroOfRecord(skSegd) == some(1_700_000_007_654_321'i64)
      doAssert k.timeZeroOfRecord(skSegy).isNone, "a SEG-Y without a delay has no time zero"
      doAssert k.timeZeroOfRecord(skSeg2).isNone
      doAssert initTraceKeys().timeZeroOfRecord(skSegd).isNone
  echo "trecordtime: ok"

when isMainModule:
  main()
