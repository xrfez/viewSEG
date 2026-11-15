## The plot's image: a panel's tiles drawn with OpenGL 3.3, as density,
## wiggles or wiggles over density, into an RGBA image the size of the
## plot, which the frontend shows in its plot. The plot's `Turn`
## (`core/orientation`) places everything: time down, or time across (the
## image the other way round, its wiggles swung the other way); the tiles
## and their textures are the same either way.
##
## Tiles are drawn oldest first, each over the ones before it: its area
## first (density, or the plot's background under wiggles alone), then its
## wiggles (`gpu/wiggle`), then its hovered and selected traces once more,
## on top. Under density alone, a hovered or selected trace's column is
## tinted (`gpu/density`). A tile that a newer one covers in view is not
## drawn (`hidden`): it would be painted over.
##
## Drawing is skipped when nothing it depends on changed since the last
## image (`PlotFrame`, the tiles and their marks): an idle plot costs the
## GPU nothing. **A hover** (the pointer moved to another trace) changes
## only the pixels of the trace it leaves and of the one it reaches: those
## two stripes (columns, or rows when time is across) are drawn again, as the whole image is (cleared, every tile
## in its order), with the rest of the image kept, so the image is the one a
## whole drawing makes, at the cost of two traces' columns instead of the
## plot's (on software OpenGL, a whole Morgantown record in wiggles took
## about 30 ms a hover).
##
## Everything here runs on the UI thread with the frontend's GL context
## current. Objects are freed explicitly (`free`), never by a destructor.

import std/[algorithm, math, strutils]
import ../core/[geometry, orientation, panels, tiles, viewport, wiggle]
import density, gl, textures, wiggle as gpuwiggle

export GetProcAddress, GLuint

type
  PlotFrame* = object
    ## What one image shows, and how.
    view*: Viewport        ## the data shown, and the plot's pixels along each axis
    turn*: Turn = TimeDown ## which way the plot is turned: the image is `screenSize`
    background*: Rgba
    density*: bool         ## greyscale density under everything
    wiggles*: bool
    scale*: float32        ## the display gain (`displayScale`)
    style*: WiggleStyle
    ink*: WiggleInk
    tint*: float32         ## density alone: how far a marked trace's column is tinted
    marks*: int            ## bumped by the caller whenever a tile's marks change

  PlotRenderer* = object
    ## The two programs, the colour map, and the image the plot shows.
    density: DensityProgram
    wiggle: WiggleProgram
    lut, fbo, target: GLuint
    width, height: int
    maxSize: int    ## the largest texture side used
    ready: bool
    last: PlotFrame ## what the image shows now
    lastTiles: seq[uint64]
    lastHover: seq[int]
    drawn: int      ## images drawn, for tests
    columns: int
      ## pixels along the traces the last drawing drew (all, or a hover's
      ## stripes)

var missing: seq[string]
var loaded = false

proc initGpu*(getProc: GetProcAddress): string =
  ## Loads the GL functions; "" when all are there, else what is missing.
  ## Call once, with a context current.
  missing = loadGl(getProc)
  loaded = missing.len == 0
  missing.join(", ")

proc maxTextureSize*(): int =
  ## The GPU's largest texture side.
  var v: GLint
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, addr v)
  int(v)

proc setLut*(r: PlotRenderer; lut: Lut) =
  ## Replaces the density colour map.
  var last: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr last)
  glBindTexture(GL_TEXTURE_2D, r.lut)
  var data = lut
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), 256, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE,
    addr data[0])
  glBindTexture(GL_TEXTURE_2D, GLuint(last))

proc warmUp(r: var PlotRenderer) {.gcsafe.}

proc newPlotRenderer*(lut: Lut; maxSize = 0): (PlotRenderer, string) =
  ## The renderer, with density colour map `lut`, and "" or why it cannot
  ## draw (a shader the driver rejects). Textures are at most `maxSize` on a
  ## side (0: the GPU's limit). Needs `initGpu` first.
  var r = PlotRenderer()
  if not loaded:
    return (r, "OpenGL functions missing: " & missing.join(", "))
  r.maxSize = if maxSize > 0: min(maxSize, maxTextureSize()) else: maxTextureSize()
  let (d, e1) = initDensityProgram()
  if e1.len > 0: return (r, e1)
  r.density = d
  let (w, e2) = initWiggleProgram()
  if e2.len > 0:
    r.density.free()
    return (PlotRenderer(), e2)
  r.wiggle = w
  var lastTex: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr lastTex)
  r.lut = newTexture()
  glBindTexture(GL_TEXTURE_2D, GLuint(lastTex))
  r.setLut(lut)
  glGenFramebuffers(1, addr r.fbo)
  r.ready = true
  r.warmUp()
  (r, "")

func ready*(r: PlotRenderer): bool {.inline.} = r.ready
  ## Whether it can draw.

func maxSize*(r: PlotRenderer): int {.inline.} = r.maxSize
  ## The largest texture side it uses.

func imagesDrawn*(r: PlotRenderer): int {.inline.} = r.drawn
  ## How many images it has drawn (an unchanged frame draws none).

func columnsDrawn*(r: PlotRenderer): int {.inline.} = r.columns
  ## How many of the image's pixels along the traces (its columns, or its
  ## rows when time is across) the last drawing drew: all of them, or the
  ## stripes of the traces a hover left and reached (for tests).

proc upload*(r: PlotRenderer; t: Tile): TileTextures =
  ## The GPU's copy of `t`.
  if r.ready: upload(t, r.maxSize) else: TileTextures(id: t.id, hoverRow: -1)

proc resize(r: var PlotRenderer; width, height: int) =
  if r.target != 0 and width == r.width and height == r.height: return
  if r.target != 0: glDeleteTextures(1, addr r.target)
  r.target = newTexture()
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glBindFramebuffer(GL_FRAMEBUFFER, r.fbo)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r.target, 0)
  (r.width, r.height) = (width, height)

proc unchanged(r: PlotRenderer; f: PlotFrame; textures: openArray[TileTextures]): bool =
  ## Whether the image already shows `f` with `textures`.
  if r.target == 0 or f != r.last or textures.len != r.lastTiles.len: return false
  for i, tt in textures:
    if tt.id != r.lastTiles[i] or tt.hoverRow != r.lastHover[i]: return false
  true

const StripeRoom = 2 ## pixels a hover's stripe reaches past its trace's quad

proc hoverStripes(r: PlotRenderer; f: PlotFrame; tiles: openArray[Tile];
    textures: openArray[TileTextures]): seq[Slice[int]] =
  ## When the image shows `f` and `textures` but for the hovered rows: the
  ## pixels along the traces (from the view's first position) that the
  ## rows a hover left and reached draw on (each row's quad: its column
  ## under density, its wiggle's reach), merged and in order. None when more
  ## than that changed, or when they would cover half the image (a whole
  ## drawing is as cheap).
  if r.target == 0 or f != r.last or textures.len != r.lastTiles.len or
      tiles.len < textures.len:
    return
  let v = f.view
  let perPos = float64(v.columns) / v.traces.width # pixels a position
  var spans: seq[Slice[int]]
  for i, tt in textures:
    if tt.id != r.lastTiles[i]: return @[]
    if tt.hoverRow != r.lastHover[i]:
      let q = tiles[i].request
      let half = (if f.wiggles: max(f.style.reach, 0.5) else: 0.5) * float64(q.stride) +
        float64(q.stride)
      for row in [tt.hoverRow, r.lastHover[i]]:
        if row >= 0:
          let x = (float64(q.position(row)) - v.traces.lo) * perPos
          let a = max(0, int(floor(x - half * perPos)) - StripeRoom)
          let b = min(v.columns - 1, int(ceil(x + half * perPos)) + StripeRoom)
          if a <= b: spans.add a .. b
  if spans.len == 0: return
  spans.sort(proc (a, b: Slice[int]): int = cmp(a.a, b.a))
  var width = 0
  for s in spans:
    if result.len > 0 and s.a <= result[^1].b + 1: result[^1].b = max(result[^1].b, s.b)
    else: result.add s
  for s in result: width += s.len
  if 2 * width > v.columns: result.setLen 0

proc render*(r: var PlotRenderer; f: PlotFrame; tiles: openArray[Tile];
    textures: openArray[TileTextures]): GLuint =
  ## Draws `tiles` (with their GPU copies `textures`, in the same order;
  ## later ones over earlier ones) as `f` says, into an image the size of
  ## the plot (`screenSize` of its view and turn), and returns that image's
  ## texture: its first row is the plot's bottom edge. The GL state the
  ## frontend had is restored. 0 when it cannot draw.
  let (width, height) = f.view.screenSize(f.turn)
  if not r.ready or width <= 0 or height <= 0 or not (f.view.traces.width > 0) or
      not (f.view.timeMs.width > 0):
    return 0
  if r.unchanged(f, textures): return r.target
  let stripes = r.hoverStripes(f, tiles, textures)
  var lastFbo, lastRead, lastProgram, lastVao, lastActive, lastBuf: GLint
  var lastTex: array[3, GLint]
  var lastViewport, lastScissor: array[4, GLint]
  var lastClear: array[4, float32]
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, addr lastFbo)
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, addr lastRead)
  glGetIntegerv(GL_CURRENT_PROGRAM, addr lastProgram)
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  glGetIntegerv(GL_ACTIVE_TEXTURE, addr lastActive)
  glGetIntegerv(GL_VIEWPORT, addr lastViewport[0])
  glGetIntegerv(GL_SCISSOR_BOX, addr lastScissor[0])
  glGetFloatv(GL_COLOR_CLEAR_VALUE, addr lastClear[0])
  for unit in 0 .. 2:
    glActiveTexture(GL_TEXTURE0 + GLenum(unit))
    glGetIntegerv(GL_TEXTURE_BINDING_2D, addr lastTex[unit])
  const caps = [GL_BLEND, GL_SCISSOR_TEST, GL_DEPTH_TEST, GL_CULL_FACE, GL_STENCIL_TEST]
  var enabled: array[caps.len, bool]
  for i, c in caps:
    enabled[i] = glIsEnabled(c) != 0
    glDisable(c)

  r.resize(width, height)
  glBindFramebuffer(GL_FRAMEBUFFER, r.fbo)
  glViewport(0, 0, GLsizei(width), GLsizei(height))
  let bg = f.background
  glClearColor(bg.r.float32 / 255, bg.g.float32 / 255, bg.b.float32 / 255, 1)
  glActiveTexture(GL_TEXTURE0 + 1)
  glBindTexture(GL_TEXTURE_2D, r.lut)
  glActiveTexture(GL_TEXTURE0)
  let look = DensityLook(scale: f.scale, solid: not f.density, solidColour: bg,
    tint: (if f.wiggles: 0'f32 else: f.tint), hover: f.ink.hover, selected: f.ink.selected)
  let n = min(tiles.len, textures.len)
  template drawAll() =
    glClear(GL_COLOR_BUFFER_BIT)
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA) # premultiplied
    for i in 0 ..< n:
      if not tiles.toOpenArray(0, n - 1).hidden(i, f.view):
        let tt = textures[i]
        glDisable(GL_BLEND)
        r.density.use(look)
        r.density.draw(f.view, f.turn, tiles[i], tt, tt.hoverRow)
        if f.wiggles:
          glEnable(GL_BLEND)
          r.wiggle.use(f.view, f.turn, f.style, f.ink)
          r.wiggle.draw(f.view, tiles[i], tt, tt.hoverRow, markedOnly = false)
          r.wiggle.draw(f.view, tiles[i], tt, tt.hoverRow, markedOnly = true)
  if stripes.len > 0:
    # Only the hover changed: its stripes drawn again as the whole image is.
    glEnable(GL_SCISSOR_TEST)
    r.columns = 0
    for s in stripes:
      let box = f.view.screenRect(f.turn, s) # from the top-left; GL counts from the bottom
      glScissor(GLint(box.pos.x), GLint(float32(height) - box.pos.y - box.size.y),
        GLsizei(box.size.x), GLsizei(box.size.y))
      drawAll()
      r.columns += s.len
    glDisable(GL_SCISSOR_TEST)
  else:
    drawAll()
    r.columns = f.view.columns
  r.last = f
  r.lastTiles.setLen 0
  r.lastHover.setLen 0
  for tt in textures:
    r.lastTiles.add tt.id
    r.lastHover.add tt.hoverRow
  inc r.drawn

  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(lastFbo))
  glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(lastRead))
  glUseProgram(GLuint(lastProgram))
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))
  for unit in 0 .. 2:
    glActiveTexture(GL_TEXTURE0 + GLenum(unit))
    glBindTexture(GL_TEXTURE_2D, GLuint(lastTex[unit]))
  glActiveTexture(GLenum(lastActive))
  glViewport(lastViewport[0], lastViewport[1], lastViewport[2], lastViewport[3])
  glScissor(lastScissor[0], lastScissor[1], lastScissor[2], lastScissor[3])
  glClearColor(lastClear[0], lastClear[1], lastClear[2], lastClear[3])
  for i, c in caps:
    if enabled[i]: glEnable(c)
    else: glDisable(c)
  r.target

proc warmUp(r: var PlotRenderer) =
  ## Draws one value once in every mode, so that a driver that compiles
  ## shaders on first use (Mesa's llvmpipe takes tens of ms) does it now,
  ## not in a frame.
  let t = Tile(id: 0, request: ReadRequest(count: 1, stride: 1, samples: 1, decimation: 1),
    dtMs: 1, columns: 1, data: @[0'f32], traces: @[0])
  var tt = r.upload(t)
  let view = Viewport(traces: Span(lo: -0.5, hi: 0.5), timeMs: Span(lo: -0.5, hi: 0.5),
    columns: 1, rows: 1)
  for (density, wiggles) in [(true, false), (false, true)]:
    discard r.render(PlotFrame(view: view, density: density, wiggles: wiggles, scale: 1,
      style: WiggleStyle(scale: 1, overlap: 1, pixelsPerTrace: 1, msPerPixel: 1,
      lineWidth: 1, markedWidth: 2, fills: {wfPositive})), [t], [tt])
  tt.free()
  r.last = PlotFrame()
  r.lastTiles.setLen 0
  r.drawn = 0

proc readImage*(r: PlotRenderer): seq[Rgba] =
  ## The last image `render` drew, row by row from the top. For tests.
  if r.target == 0: return
  var raw = newSeq[uint8](r.width * r.height * 4)
  var lastRead: GLint
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, addr lastRead)
  glBindFramebuffer(GL_READ_FRAMEBUFFER, r.fbo)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(0, 0, GLsizei(r.width), GLsizei(r.height), GL_RGBA, GL_UNSIGNED_BYTE,
    addr raw[0])
  glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(lastRead))
  result = newSeq[Rgba](r.width * r.height)
  for y in 0 ..< r.height:
    let src = (r.height - 1 - y) * r.width * 4
    for x in 0 ..< r.width:
      let i = src + 4 * x
      result[y * r.width + x] = Rgba(r: raw[i], g: raw[i + 1], b: raw[i + 2], a: raw[i + 3])

func imageSize*(r: PlotRenderer): (int, int) {.inline.} = (r.width, r.height)
  ## The size of the last image drawn.

proc free*(r: var PlotRenderer) =
  ## Deletes its GL objects.
  if r.target != 0: glDeleteTextures(1, addr r.target)
  if r.lut != 0: glDeleteTextures(1, addr r.lut)
  if r.fbo != 0: glDeleteFramebuffers(1, addr r.fbo)
  r.density.free()
  r.wiggle.free()
  r = PlotRenderer()
