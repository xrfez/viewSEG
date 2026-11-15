## Windows and the screens they are on: the geometry behind the Window
## menu's "Bring all windows onto this screen" and "Reset the windows", and
## behind the corrections made at start when a saved place is off every
## screen (a monitor unplugged, a laptop away from its desk) or is larger
## than any screen.
##
## Rectangles are in the desktop's coordinates, as the windowing system gives
## them: a screen is its usable area (without task bars and docks); a window
## is its own area, without the frame the desktop draws around it. Nothing
## here asks the system: the frontend gives the screens, so the rules are
## tested on made-up ones.

import geometry

const
  GripWidth* = 100'f32 ## the width of a window's top edge that must be on a screen to be reached
  GripHeight* = 20'f32 ## how far down from the top that is looked at

type
  StartPlace* = enum
    ## What becomes of a saved place for the main window at start.
    spKept = "kept"            ## on a screen and of a size one holds: as it was
    spShrunk = "shrunk"        ## larger than any screen: made to fit the one it is on
    spOffScreen = "off screen" ## no screen holds its top edge: the default place instead

func rect*(x, y, w, h: int): Rect =
  ## The rectangle at (`x`, `y`), `w` wide and `h` high.
  Rect(pos: vec2(float32(x), float32(y)), size: vec2(float32(w), float32(h)))

func right(r: Rect): float32 {.inline.} = r.pos.x + r.size.x
func bottom(r: Rect): float32 {.inline.} = r.pos.y + r.size.y

func overlap*(a, b: Rect): float32 =
  ## The area `a` and `b` share; 0 when they do not touch.
  let w = min(a.right, b.right) - max(a.pos.x, b.pos.x)
  let h = min(a.bottom, b.bottom) - max(a.pos.y, b.pos.y)
  if w <= 0 or h <= 0: 0'f32 else: w * h

func inside*(r, screen: Rect): bool =
  ## Whether all of `r` lies on `screen`.
  r.pos.x >= screen.pos.x and r.pos.y >= screen.pos.y and r.right <= screen.right and
    r.bottom <= screen.bottom

func screenOf*(r: Rect; screens: openArray[Rect]): int =
  ## The screen that holds the most of `r` (the first of those that hold
  ## as much); -1 when none holds any of it.
  result = -1
  var best = 0'f32
  for i, s in screens:
    let a = overlap(r, s)
    if a > best:
      best = a
      result = i

func reachable*(r: Rect; screens: openArray[Rect]): bool =
  ## Whether some screen holds at least `GripWidth` × `GripHeight` of the
  ## top of `r` (or all of a narrower top), so the window can be seen and
  ## dragged by it.
  let top = Rect(pos: r.pos, size: vec2(r.size.x, min(r.size.y, GripHeight)))
  let need = min(GripWidth, r.size.x) * top.size.y
  result = false
  if need > 0:
    for s in screens:
      if overlap(top, s) >= need: return true

func fits*(r: Rect; screen: Rect): bool =
  ## Whether `screen` is as wide and as high as `r`.
  r.size.x <= screen.size.x and r.size.y <= screen.size.y

func fitsSome*(r: Rect; screens: openArray[Rect]): bool =
  ## Whether some screen is as wide and as high as `r`.
  result = false
  for s in screens:
    if r.fits(s): return true

func fitOnto*(r: Rect; screen: Rect): Rect =
  ## `r` moved as little as it takes to lie wholly on `screen`, first made
  ## no larger than the screen; `r` itself when it lies on it already.
  result = r
  result.size.x = min(r.size.x, screen.size.x)
  result.size.y = min(r.size.y, screen.size.y)
  result.pos.x = clamp(r.pos.x, screen.pos.x, screen.right - result.size.x)
  result.pos.y = clamp(r.pos.y, screen.pos.y, screen.bottom - result.size.y)

func centredOn*(size: Vec2; screen: Rect): Rect =
  ## A rectangle of `size` (no larger than `screen`) in the middle of `screen`.
  let s = vec2(min(size.x, screen.size.x), min(size.y, screen.size.y))
  Rect(pos: vec2(screen.pos.x + float32(int((screen.size.x - s.x) / 2)),
    screen.pos.y + float32(int((screen.size.y - s.y) / 2))), size: s)

func homeScreen*(r: Rect; screens: openArray[Rect]; primary: int): int =
  ## The screen a window at `r` is on: the one holding the most of it, else
  ## `primary`; -1 when there are no screens.
  result = screenOf(r, screens)
  if result < 0 and screens.len > 0:
    result = if primary in 0 ..< screens.len: primary else: 0

func mainWindowAtStart*(saved: Rect; screens: openArray[Rect]): (Rect, StartPlace) =
  ## Where the main window opens when it was last at `saved`: there, when a
  ## screen holds its top edge and some screen is as large as it
  ## (`spKept`); made to fit the screen it is on, when none is that large
  ## (`spShrunk`); nowhere (an empty rectangle: the caller opens it at its
  ## default place) when no screen holds its top edge (`spOffScreen`).
  ## With no screens known, as it was.
  if screens.len == 0: (saved, spKept)
  elif not saved.reachable(screens): (Rect(), spOffScreen)
  elif saved.fitsSome(screens): (saved, spKept)
  else: (saved.fitOnto(screens[saved.screenOf(screens)]), spShrunk)
