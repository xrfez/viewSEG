## When a graph's axes are fitted again (`view/axisfit`): an option change
## fits both axes, even over a zoom; new data fits an axis whose limits
## changed unless the user zoomed it; the x axis whose range changed is
## fitted whatever the zoom; a view back on the fit is not a zoom.
##
## Seen to fail: with `plan` ignoring `optionKey`, "an option change fits
## both"; with the zoomed flag never set in `seen`, "a zoomed y is kept";
## with the data's change not compared, "new data fits y".

import viewSEG/view/axisfit

func span(lo, hi: float64): Span = Span(lo: lo, hi: hi)

proc main*() =
  var f: AxisFit
  let x = span(0, 100)
  let y = span(-1, 1)

  block first:
    let p = f.plan("a", x, y)
    doAssert p.x and p.y, "the first frame fits both"
    f.seen(x, y)
    doAssert not f.userZoomed(true) and not f.userZoomed(false)

  block same:
    let p = f.plan("a", x, y)
    doAssert not p.x and not p.y, "same options, same data: nothing"
    f.seen(x, y)

  block newData:
    let p = f.plan("a", x, span(-5, 5))
    doAssert p.y and not p.x, "new data fits y"
    f.seen(x, span(-5, 5))

  block zoom:
    f.seen(span(10, 20), span(-1, 1)) # the user zoomed both
    doAssert f.userZoomed(true) and f.userZoomed(false)
    var p = f.plan("a", x, span(-9, 9))
    doAssert not p.y and not p.x, "a zoomed y is kept"
    f.seen(span(10, 20), span(-1, 1))
    p = f.plan("a", span(0, 200), span(-9, 9))
    doAssert p.x and not p.y, "x whose range changed is fitted, y kept"
    f.seen(span(0, 200), span(-1, 1))
    doAssert not f.userZoomed(true) and f.userZoomed(false)

  block option:
    let p = f.plan("b", span(0, 200), span(-9, 9))
    doAssert p.x and p.y, "an option change fits both"
    f.seen(span(0, 200), span(-9, 9))
    doAssert not f.userZoomed(false)

  block fitGesture:
    f.seen(span(5, 6), span(0, 1))
    doAssert f.userZoomed(true)
    f.seen(span(0, 200), span(-9, 9)) # a double click: back on the fit
    doAssert not f.userZoomed(true) and not f.userZoomed(false)
    let p = f.plan("b", span(0, 200), span(-2, 2))
    doAssert p.y, "no zoom: new data fits"

  block fixedFollow:
    let p = f.plan("b", span(0, 200), span(-3, 3), follow = false)
    doAssert not p.x and not p.y, "follow off: only options fit"
    doAssert f.plan("c", span(0, 200), span(-3, 3), follow = false).y

  block unreadableAxis:
    # an axis showing limits that are not numbers, have no span, or (the user not having
    # zoomed it) hold none of the data is one to fit again; a zoomed one is left alone
    # unless it has no numbers or no span; no finite data, nothing is judged
    # Seen to fail: with `degenerate` false for a view far from the data, "far from the data".
    doAssert degenerate(span(NaN, NaN), span(0, 1), false), "NaN"
    doAssert degenerate(span(NaN, NaN), span(0, 1), true), "NaN, zoomed"
    doAssert degenerate(span(3, 3), span(0, 5), false), "no span"
    doAssert degenerate(span(4, 2), span(0, 5), true), "negative span, zoomed"
    doAssert degenerate(span(10, 20), span(0, 5), false), "far from the data"
    doAssert degenerate(span(-9, -8), span(0, 5), false), "far below the data"
    doAssert not degenerate(span(10, 20), span(0, 5), true), "a zoom away from the data"
    doAssert not degenerate(span(1, 2), span(0, 5), false), "a view inside the data"
    doAssert not degenerate(span(-1, 9), span(0, 5), false), "a view around the data"
    doAssert not degenerate(span(NaN, NaN), span(NaN, NaN), false), "no data"

when isMainModule: main()
