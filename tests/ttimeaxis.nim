## The time axis's helpers (`view/timeaxis`): the cursor's time is written
## to the sample interval, never as "-0" nor with a bare point.
##
## Seen to fail: with Nim's `formatFloat` taken as it is, 702.34 ms at 2 ms
## read "702." and -0.2 ms "0.".

import viewSEG/view/timeaxis

block cursorTime:
  doAssert cursorTimeText(702.34, 2) == "702"
  doAssert cursorTimeText(702.34, 1) == "702"
  doAssert cursorTimeText(702.34, 0.5) == "702.3"
  doAssert cursorTimeText(702.34, 0.25) == "702.34"
  doAssert cursorTimeText(702.3456, 0.125) == "702.346"
  doAssert cursorTimeText(-0.2, 2) == "0", cursorTimeText(-0.2, 2)
  doAssert cursorTimeText(-12.6, 2) == "-13"
  doAssert cursorTimeText(NaN, 2) == "" and cursorTimeText(5, NaN) == "5"
  doAssert decimalsOf(2) == 0 and decimalsOf(0.5) == 1 and decimalsOf(0.05) == 2
