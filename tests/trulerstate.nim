## The map's one ruler (`MapRuler`): on or off, and a line only while it is
## on. A measure turns it on and sets the two points. Clicking it while on
## turns it off and clears the points, so the next line starts fresh.
## Clicking it while off turns measure mode on, with no line. Escape ends
## the line and leaves the mode on.
##
## Seen to fail: with `placeRuler` leaving `on` false (a Ctrl measure drew
## the line and did not light the button), "a measure turns the ruler on"
## found it off; with `clickRuler` only flipping `on` and keeping the
## points, "clicking the lit ruler clears the line" found the points still
## set.

import viewSEG/core/mapview
import viewSEG/view/maplayers

proc fresh(): MapRuler =
  result.placeRuler(mapPoint(0, 0), mapPoint(200, 0))

block a_measure_turns_the_ruler_on:
  var r = MapRuler()
  doAssert not r.on and not r.shown
  r.placeRuler(mapPoint(10, 20), mapPoint(30, 80))
  doAssert r.on, "a measure turns the ruler on"
  doAssert r.shown
  doAssert r.a == mapPoint(10, 20) and r.b == mapPoint(30, 80)
  # whichever way it was started: a second measure, already on, keeps it on
  r.placeRuler(mapPoint(1, 1), mapPoint(2, 2))
  doAssert r.on and r.shown
  doAssert r.a == mapPoint(1, 1) and r.b == mapPoint(2, 2), "the new line replaced the old"

block clicking_the_lit_ruler_clears_the_line:
  var r = fresh()
  r.clickRuler()
  doAssert not r.on, "clicking the lit ruler turns it off"
  doAssert not r.shown, "clicking the lit ruler clears the line"
  doAssert r.a == mapPoint(0, 0) and r.b == mapPoint(0, 0), "the points stayed"
  r.placeRuler(mapPoint(5, 5), mapPoint(9, 1))
  doAssert r.on and r.shown and r.a == mapPoint(5, 5), "the next ruler did not start fresh"

block clicking_while_off_turns_mode_on:
  var r = MapRuler()
  r.clickRuler()
  doAssert r.on and not r.shown, "clicking while off should arm measure mode, not draw"
  doAssert r.a == mapPoint(0, 0) and r.b == mapPoint(0, 0)

block escape_ends_the_line_and_leaves_the_mode:
  var r = fresh()
  r.endRulerLine()
  doAssert r.on, "Escape turned the ruler off"
  doAssert not r.shown, "Escape left the line"
  doAssert r.a == mapPoint(0, 0) and r.b == mapPoint(0, 0)
  # a line is never drawn with the button off, and the button is never lit
  # with the mode off: `on` is the mode the button shows
  doAssert not (r.shown and not r.on)

block off_never_shows_a_line:
  var r = fresh()
  r.clickRuler()
  doAssert not r.shown and not r.on
  r.endRulerLine()
  doAssert not r.on and not r.shown, "ending a line that is already gone turned the mode on"

echo "trulerstate: ok"
