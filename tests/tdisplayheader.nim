## The display header over a trace panel: labels are thinned to steps of 1,
## 2 or 5 × 10^k positions (times the panel's stride) so that they never
## overlap, they fall on multiples of the step, and values are written as
## a geophysicist reads them.
##
## Seen to fail: with `headerStep` ignoring the stride, `stepsKeepLabelsApart`
## got a step that is no multiple of 4 at stride 4 (positions without
## values); with `labelled` starting at the first visible position,
## `labelsOnMultiples` labelled 3, 8, 13 ...

import viewSEG/view/displayheader

proc main*() =

  block stepsKeepLabelsApart:
    doAssert headerStep(1, 40, 30) == 1 # room for every label
    doAssert headerStep(1, 10, 30) == 5 # 1 and 2 are too close
    doAssert headerStep(1, 1, 30) == 50
    doAssert headerStep(1, 0.01, 30) == 5000
    doAssert headerStep(4, 2, 30) == 20 # a multiple of the stride
    doAssert headerStep(4, 10, 30) == 4
    doAssert headerStep(2, 0, 30) == 2 and headerStep(1, 5, 0) == 1
    for stride in [1, 2, 4, 16]:
      for px in [0.05, 0.3, 1.0, 7.0, 64.0]:
        let step = headerStep(stride, px, 42)
        doAssert step mod stride == 0, $(stride, px, step)
        doAssert float64(step) * px >= 42 or step == stride, $(stride, px, step)

  block labelsOnMultiples:
    var got: seq[int]
    for p in labelled(3 .. 27, 5): got.add p
    doAssert got == @[5, 10, 15, 20, 25], $got
    got.setLen 0
    for p in labelled(0 .. 4, 1): got.add p
    doAssert got == @[0, 1, 2, 3, 4]
    got.setLen 0
    for p in labelled(6 .. 9, 10): got.add p
    doAssert got.len == 0
    for p in labelled(5 .. 4, 1): doAssert false, "an empty range has no labels"

  block valuesAsRead:
    doAssert headerText(101) == "101" and headerText(-3) == "-3"
    doAssert headerText(1001001) == "1001001"
    doAssert headerText(99.5) == "99.5" and headerText(12.25) == "12.25"
    doAssert headerText(0.1 + 0.2) == "0.3"
    doAssert headerText(NaN) == "" and headerText(Inf) == ""

when isMainModule:
  main()
