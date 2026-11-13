## Toolkit-neutral geometry and colour types. `core` and `view` use these, never a
## GUI toolkit's types (docs/architecture.md, rule 1); the frontend converts at its edge.

type
  Vec2* = object
    x*, y*: float32

  Rect* = object
    ## Axis-aligned, `pos` is the top-left corner.
    pos*, size*: Vec2

  Rgba* = object
    r*, g*, b*, a*: uint8

func vec2*(x, y: float32): Vec2 = Vec2(x: x, y: y)

func contains*(r: Rect, p: Vec2): bool =
  p.x >= r.pos.x and p.y >= r.pos.y and p.x < r.pos.x + r.size.x and p.y < r.pos.y + r.size.y
