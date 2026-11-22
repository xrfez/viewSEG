## `unixNs` and `timeText` (the civil-date arithmetic of the signature facts) agree with
## `std/times` over leap days, year ends and the years 2026, 2038 and 2100, and keep their
## nanoseconds; a leap second counts as the second after the 59th.
##
## Seen to fail: with the century term of `daysFromCivil` dropped, 1970-01-01 differed from
## `std/times`.

import std/[strutils, times]
import viewSEG/core/sigtypes

proc main*() =
  var checked = 0
  for (y, m, d) in [(1970, 1, 1), (1999, 12, 31), (2000, 2, 28), (2000, 2, 29), (2000, 3, 1),
      (2001, 2, 3), (2024, 2, 29), (2024, 12, 31), (2025, 1, 1), (2026, 11, 22), (2026, 12, 31),
      (2038, 1, 19), (2038, 1, 20), (2099, 12, 31), (2100, 1, 1), (2100, 2, 28), (2100, 3, 1),
      (2262, 4, 10)]:
    for (h, mi, sec, ns) in [(0, 0, 0, 0), (4, 5, 6, 789_012_345), (23, 59, 59, 999_999_999)]:
      let t = dateTime(y, Month(m), d, h, mi, sec, 0, utc())
      let want = int64(t.toTime.toUnix) * 1_000_000_000 + ns
      let got = unixNs(y, m, d, h, mi, sec, ns)
      doAssert got == want, $(y, m, d, h, mi, sec, ns) & ": " & $got & " != " & $want
      let text = timeText(got)
      doAssert text == t.format("yyyy-MM-dd HH:mm:ss") & "." & intToStr(ns, 9), text
      doAssert timeText(got, 0) == t.format("yyyy-MM-dd HH:mm:ss"), text
      inc checked
  doAssert unixNs(2016, 12, 31, 23, 59, 60, 0) == unixNs(2017, 1, 1, 0, 0, 0, 0)
  doAssert checked == 54
  # past the year 2262 nanoseconds do not fit 64 bits: the largest value, not an overflow
  doAssert unixNs(2400, 2, 29, 0, 0, 0, 0) == high(int64)
  doAssert unixNs(9999, 12, 31, 23, 59, 59, 999_999_999) == high(int64)
  echo "tsigtime: ok"

when isMainModule:
  main()
