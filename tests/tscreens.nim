## Windows and screens on made-up desktops (`core/screens`): which screen a
## window is on, whether it can be reached by its top edge, how it is put
## wholly on a screen, and where the main window opens when its saved place
## is on a monitor that is gone, hangs off the desktop's edge, or is larger
## than any screen. The frontend under a test has one screen and no window
## manager, so these rules are tested here, on screens that are not there:
## two monitors side by side (the second left of the primary, at negative
## coordinates), a third above, and a laptop's screen alone.
##
## Seen to fail: with `reachable` looking at the whole window instead of its
## top edge, "a window whose top is above the screens" was reachable; with
## `fitOnto` moving before it shrinks, the window larger than the laptop
## ended 640 pixels past its right edge; with `mainWindowAtStart` keeping a
## window larger than every screen, "shrunk" was "kept".

import viewSEG/core/[geometry, screens]

let
  primary = rect(0, 0, 1920, 1040)     # its task bar below
  left = rect(-2560, -200, 2560, 1440) # a larger monitor left of it, higher
  above = rect(0, -1080, 1920, 1080)
  desk = [primary, left, above]
  laptop = [rect(0, 0, 1366, 728)]

block whichScreen:
  doAssert rect(100, 100, 800, 600).screenOf(desk) == 0
  doAssert rect(-1000, 100, 800, 600).screenOf(desk) == 1
  doAssert rect(-300, 100, 800, 600).screenOf(desk) == 0, "most of it is on the primary"
  doAssert rect(-500, 100, 800, 600).screenOf(desk) == 1, "most of it is on the left"
  doAssert rect(100, -900, 800, 600).screenOf(desk) == 2
  doAssert rect(5000, 5000, 800, 600).screenOf(desk) == -1, "on no screen"
  doAssert rect(5000, 5000, 800, 600).homeScreen(desk, 0) == 0, "the primary, when on none"
  doAssert rect(-1000, 100, 800, 600).homeScreen(laptop, 0) == 0
  doAssert rect(0, 0, 10, 10).homeScreen([], 0) == -1

block reachable:
  doAssert rect(100, 100, 800, 600).reachable(desk)
  doAssert rect(-1000, 100, 800, 600).reachable(desk), "on the left monitor"
  doAssert not rect(-1000, 100, 800, 600).reachable(laptop), "its monitor is gone"
  doAssert not rect(5000, 5000, 800, 600).reachable(desk)
  # 50 pixels of its top edge on the primary's right: too little to drag it by
  doAssert not rect(1870, 100, 800, 600).reachable(desk)
  doAssert rect(1800, 100, 800, 600).reachable(desk), "120 pixels of its top are on it"
  # its top above the screens of the laptop, its lower part on it: the title
  # bar cannot be reached
  doAssert not rect(100, -400, 800, 600).reachable(laptop),
    "a window whose top is above the screens was reachable"
  doAssert rect(100, -10, 800, 600).reachable(laptop), "10 of its top 20 rows are on it"
  doAssert rect(100, 100, 60, 300).reachable(laptop), "a narrow window, all on the screen"
  doAssert not rect(100, 100, 0, 0).reachable(desk), "nothing to reach"

block fitOnto:
  let s = laptop[0]
  doAssert rect(100, 100, 800, 600).fitOnto(s) == rect(100, 100, 800, 600), "already on it"
  doAssert rect(1000, 100, 800, 600).fitOnto(s) == rect(566, 100, 800, 600), "moved left"
  doAssert rect(-1000, -500, 800, 600).fitOnto(s) == rect(0, 0, 800, 600), "moved in"
  doAssert rect(3000, 3000, 800, 600).fitOnto(s) == rect(566, 128, 800, 600)
  let big = rect(200, 50, 2000, 900).fitOnto(s)
  doAssert big == rect(0, 0, 1366, 728), "larger than the laptop: " & $big
  doAssert big.inside(s)
  for r in [rect(-2560, -200, 3000, 2000), rect(1919, 1039, 5, 5), rect(0, -1080, 1920, 1080)]:
    doAssert r.fitOnto(primary).inside(primary), $r
  doAssert rect(1000, 100, 800, 600).fitOnto(left) == rect(-800, 100, 800, 600)

block centred:
  doAssert vec2(1280, 800).centredOn(primary) == rect(320, 120, 1280, 800)
  doAssert vec2(3000, 800).centredOn(laptop[0]) == rect(0, 0, 1366, 728), "no larger than it"
  doAssert vec2(1280, 800).centredOn(left) == rect(-1920, 120, 1280, 800)

block mainWindowAtStart:
  # where it was, on any monitor that is still there
  doAssert mainWindowAtStart(rect(100, 100, 1280, 800), desk) == (rect(100, 100, 1280, 800),
    spKept)
  doAssert mainWindowAtStart(rect(-2000, 0, 1280, 800), desk)[1] == spKept
  # hanging over the edge, but reachable: left as the user put it
  doAssert mainWindowAtStart(rect(1500, 100, 1280, 800), desk)[1] == spKept
  # on the left monitor, which is gone
  doAssert mainWindowAtStart(rect(-2000, 0, 1280, 800), laptop) == (Rect(), spOffScreen)
  # far off every screen (a settings file from another machine)
  doAssert mainWindowAtStart(rect(9000, 9000, 1280, 800), desk)[1] == spOffScreen
  # larger than any screen: made to fit the one it is on
  let (r, how) = mainWindowAtStart(rect(100, 100, 3000, 2000), laptop)
  doAssert how == spShrunk, "shrunk was " & $how
  doAssert r == rect(0, 0, 1366, 728), $r
  # spanning the primary and the one above: the left monitor is high enough
  doAssert mainWindowAtStart(rect(0, -600, 1800, 1400), desk)[1] == spKept
  doAssert mainWindowAtStart(rect(0, -600, 1800, 1500), desk) ==
    (rect(0, -600, 1800, 1500).fitOnto(primary), spShrunk)
  # no screens known (the system gave none): as it was
  doAssert mainWindowAtStart(rect(9000, 9000, 1280, 800), [])[1] == spKept

echo "tscreens: ok"
