## The map's image: the survey's points drawn with OpenGL 3.3, as discs and
## rings, into an RGBA image the size of the map's plot, which the frontend
## shows in its plot.
##
## Each layer's points go to the GPU once (`MapRenderer.render` uploads a
## layer the first time it is drawn, and frees it once the survey no longer
## has it): every point, then each level of detail (`core/maplod`), as
## `float32` positions relative to the layer's lower-left corner. A frame
## draws, per layer, the coarsest level whose cells are no wider than
## `LodPixels` pixels (every point when zoomed in closer), and only the runs
## of points the view touches (`runs`), one point sprite each: the fragment
## shader makes it a disc or a ring, its edge smoothed over a pixel. The
## highlight (the hovered and selected points) is a small buffer of its own,
## uploaded again when it changes, drawn last, larger and outlined.
##
## Drawing is skipped when nothing it depends on changed since the last
## image (`MapFrame`): an idle map costs the GPU nothing.
##
## Everything here runs on the UI thread with the frontend's GL context
## current. Objects are freed explicitly (`free`), never by a destructor.

import std/math
import ../core/[geometry, mapview, maplod, survey]
import density, gl, textures

const
  LodPixels* = 1.5
    ## the widest cell, in pixels, a level of detail may draw a point for:
    ## its points fall on that pixel and its neighbours anyway

type
  MapUniform = enum
    muOffset = "offset", muScale = "scale", muSize = "size", muEdge = "edgeWidth",
    muHollow = "hollow", muFill = "fill", muEdgeColour = "edge"

  MapShapeKind* = enum
    skDisc ## filled
    skRing ## an outline only

  MapStyle* = object
    ## How one set of points is drawn.
    colour*: Rgba
    edge*: Rgba         ## the outline's colour
    size*: float32      ## the diameter, in pixels
    edgeWidth*: float32 ## the outline's width, in pixels; 0 for none
    shape*: MapShapeKind

  MapDraw* = object
    ## One layer of the map, drawn in `style`.
    layer*: SurveyLayerId
    role*: PointRole
    style*: MapStyle

  MapFrame* = object
    ## What one image shows.
    area*: Bounds
      ## the survey area shown (at equal aspect, but while the plot resizes)
    columns*, rows*: int          ## the image's size in pixels
    background*: Rgba
    draws*: seq[MapDraw]          ## the layers, the first drawn first
    selected*, hovered*: MapStyle ## the highlight's points
    highlight*: int               ## bumped by the caller whenever the highlighted points change
    survey*: int                  ## the survey's revision

  LayerBuffer = object
    key: uint64      ## the layer's id and role
    vbo, vao: GLuint
    starts: seq[int] ## per level, -1 (every point) first: its first vertex
    bytes: int

  MapRenderer* = object
    ## The program, the layers' buffers, and the image the map shows.
    program: GLuint
    loc: array[MapUniform, GLint]
    buffers: seq[LayerBuffer]
    hvbo, hvao: GLuint      ## the highlight: selected points, then hovered ones
    hselected, hhovered: int
    horigin: MapPoint
    fbo, target: GLuint
    width, height: int
    ready: bool
    last: MapFrame
    drawn, pointsDrawn: int ## images drawn, points in the last one (for tests)

const
  vertexShader = """
#version 330 core
layout(location = 0) in vec2 pos; // relative to the layer's origin
uniform vec2 offset; // the origin less the view's centre, in survey units
uniform vec2 scale;  // ndc per survey unit
uniform float size;  // diameter in pixels
void main() {
  gl_Position = vec4((pos + offset) * scale, 0.0, 1.0);
  gl_PointSize = size;
}
"""
  fragmentShader = """
#version 330 core
uniform float size, edgeWidth;
uniform int hollow;
uniform vec4 fill, edge;
out vec4 colour;
void main() {
  float r = length(gl_PointCoord * 2.0 - 1.0) * size / 2.0; // pixels from the centre
  float outer = clamp(size / 2.0 - r + 0.5, 0.0, 1.0);
  if (outer <= 0.0) discard;
  vec4 c = fill;
  if (edgeWidth > 0.0) {
    float inner = clamp(size / 2.0 - edgeWidth - r + 0.5, 0.0, 1.0); // 1 inside the edge
    vec4 body = hollow == 1 ? vec4(0.0) : vec4(fill.rgb, 1.0);
    c = vec4(edge.rgb, 1.0) * (1.0 - inner) + body * inner;
  } else c = vec4(fill.rgb, 1.0);
  colour = c * outer; // premultiplied
  if (colour.a <= 0.0) discard;
}
"""

func keyOf(layer: SurveyLayerId; role: PointRole): uint64 {.inline.} =
  (uint64(int(layer)) shl 1) or uint64(ord(role))

proc newMapRenderer*(): (MapRenderer, string) =
  ## The renderer, and "" or why it cannot draw. Needs the GL functions
  ## loaded (`plotimage.initGpu`) and a context current.
  var r = MapRenderer()
  if glCreateProgram.isNil or glMultiDrawArrays.isNil:
    return (r, "OpenGL functions missing")
  let (program, err) = buildProgram(vertexShader, fragmentShader, "map points")
  if program == 0: return (r, err)
  r.program = program
  for u in MapUniform:
    r.loc[u] = glGetUniformLocation(program, cstring($u))
  glGenFramebuffers(1, addr r.fbo)
  r.ready = true
  (r, "")

func ready*(r: MapRenderer): bool {.inline.} = r.ready
  ## Whether it can draw.

func imagesDrawn*(r: MapRenderer): int {.inline.} = r.drawn
  ## How many images it has drawn (an unchanged frame draws none).

func pointsDrawn*(r: MapRenderer): int {.inline.} = r.pointsDrawn
  ## How many points the last image drew (each level of detail's, not the
  ## layers' own counts).

func gpuBytes*(r: MapRenderer): int =
  ## The GPU memory its layers' buffers take.
  for b in r.buffers: result += b.bytes

proc freeBuffer(b: var LayerBuffer) =
  if b.vbo != 0: glDeleteBuffers(1, addr b.vbo)
  if b.vao != 0: glDeleteVertexArrays(1, addr b.vao)
  b = LayerBuffer()

proc newArray(vbo: var GLuint; vao: var GLuint) =
  glGenVertexArrays(1, addr vao)
  glGenBuffers(1, addr vbo)
  glBindVertexArray(vao)
  glBindBuffer(GL_ARRAY_BUFFER, vbo)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, GL_FLOAT, 0, 8, nil)

proc upload(l: SurveyLayer; role: PointRole): LayerBuffer =
  ## The GPU's copy of the points of role `role` of `l`: every point, then
  ## each level.
  let p = addr l.levels[role]
  result = LayerBuffer(key: keyOf(l.id, role))
  var total = p.xy.len
  for lv in p.levels: total += lv.xy.len
  result.starts.add 0
  var at = p.xy.len div 2
  for lv in p.levels:
    result.starts.add at
    at += lv.xy.len div 2
  newArray(result.vbo, result.vao)
  result.bytes = total * 4
  var data = newSeqOfCap[float32](total)
  data.add p.xy
  for lv in p.levels: data.add lv.xy
  if data.len > 0:
    glBufferData(GL_ARRAY_BUFFER, GLsizeiptr(result.bytes), addr data[0], GL_STATIC_DRAW)

proc sync(r: var MapRenderer; s: Survey; draws: openArray[MapDraw]) =
  ## Uploads the layers to draw that the GPU does not have, and frees those
  ## the survey no longer has.
  var kept: seq[LayerBuffer]
  for b in r.buffers.mitems:
    var live = false
    for l in s.layers:
      for role in PointRole:
        if keyOf(l.id, role) == b.key: live = true
    if live: kept.add move b
    else: b.freeBuffer()
  r.buffers = move kept
  for d in draws:
    let key = keyOf(d.layer, d.role)
    var have = false
    for b in r.buffers:
      if b.key == key: have = true
    let i = s.find(d.layer)
    if not have and i >= 0 and s.layers[i].levels[d.role].xy.len > 0:
      r.buffers.add upload(s.layers[i], d.role)

proc setHighlight*(r: var MapRenderer; origin: MapPoint; selected, hovered: openArray[MapPoint]) =
  ## The highlighted points, relative to `origin` (anywhere near them): the
  ## selected ones, drawn first, then the hovered ones over them. The vertex
  ## array and buffer bound before are bound again.
  var lastVao, lastBuf: GLint
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  if r.hvbo == 0: newArray(r.hvbo, r.hvao)
  var data = newSeqOfCap[float32](2 * (selected.len + hovered.len))
  template add(list: openArray[MapPoint]) =
    for p in list:
      if not (p.x.isNaN or p.y.isNaN):
        data.add float32(p.x - origin.x)
        data.add float32(p.y - origin.y)
  add(selected)
  r.hselected = data.len div 2
  add(hovered)
  r.hhovered = data.len div 2 - r.hselected
  r.horigin = origin
  glBindBuffer(GL_ARRAY_BUFFER, r.hvbo)
  if data.len > 0:
    glBufferData(GL_ARRAY_BUFFER, GLsizeiptr(data.len * 4), addr data[0], GL_STREAM_DRAW)
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))

proc resize(r: var MapRenderer; width, height: int) =
  if r.target != 0 and width == r.width and height == r.height: return
  if r.target != 0: glDeleteTextures(1, addr r.target)
  r.target = newTexture()
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glBindFramebuffer(GL_FRAMEBUFFER, r.fbo)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r.target, 0)
  (r.width, r.height) = (width, height)

proc use(r: MapRenderer; f: MapFrame; origin: MapPoint; st: MapStyle) =
  ## The uniforms for points relative to `origin` drawn in style `st`.
  template loc(u: MapUniform): GLint = r.loc[u]
  let a = f.area
  glUniform2f(loc(muOffset), float32(origin.x - (a.minX + a.maxX) / 2),
    float32(origin.y - (a.minY + a.maxY) / 2))
  glUniform2f(loc(muScale), float32(2 / a.width), float32(2 / a.height))
  glUniform1f(loc(muSize), st.size)
  glUniform1f(loc(muEdge), st.edgeWidth)
  glUniform1i(loc(muHollow), GLint(st.shape == skRing))
  uniform4(loc(muFill), st.colour)
  uniform4(loc(muEdgeColour), st.edge)

proc drawRuns(runs: openArray[Slice[int]]; base: int): int =
  ## Draws `runs` of a buffer's points starting at vertex `base`, runs a
  ## few points apart joined; the points drawn.
  var firsts: seq[GLint]
  var counts: seq[GLsizei]
  for run in runs:
    let a = base + run.a
    if firsts.len > 0 and a - (firsts[^1] + counts[^1]) <= 256:
      counts[^1] = GLsizei(base + run.b + 1 - firsts[^1])
    else:
      firsts.add GLint(a)
      counts.add GLsizei(run.len)
  for c in counts: result += c
  if firsts.len > 0:
    glMultiDrawArrays(GL_POINTS, addr firsts[0], addr counts[0], GLsizei(firsts.len))

proc render*(r: var MapRenderer; f: MapFrame; s: Survey): GLuint =
  ## Draws the layers `f` names (of survey `s`) and the highlight into an
  ## image of `f.columns` × `f.rows` pixels and returns that
  ## image's texture: its first row is the view's bottom (south) edge. The
  ## GL state the frontend had is restored. 0 when it cannot draw.
  let (width, height) = (f.columns, f.rows)
  if not r.ready or width <= 0 or height <= 0 or not (f.area.width > 0) or
      not (f.area.height > 0):
    return 0
  if r.target != 0 and f == r.last: return r.target
  var lastFbo, lastRead, lastProgram, lastVao, lastBuf: GLint
  var lastViewport: array[4, GLint]
  var lastClear: array[4, float32]
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, addr lastFbo)
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, addr lastRead)
  glGetIntegerv(GL_CURRENT_PROGRAM, addr lastProgram)
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  glGetIntegerv(GL_VIEWPORT, addr lastViewport[0])
  glGetFloatv(GL_COLOR_CLEAR_VALUE, addr lastClear[0])
  const caps = [GL_BLEND, GL_SCISSOR_TEST, GL_DEPTH_TEST, GL_CULL_FACE, GL_STENCIL_TEST,
    GL_PROGRAM_POINT_SIZE]
  var enabled: array[caps.len, bool]
  for i, c in caps:
    enabled[i] = glIsEnabled(c) != 0
    glDisable(c)

  r.sync(s, f.draws)
  r.resize(width, height)
  glBindFramebuffer(GL_FRAMEBUFFER, r.fbo)
  glViewport(0, 0, GLsizei(width), GLsizei(height))
  let bg = f.background
  glClearColor(bg.r.float32 / 255, bg.g.float32 / 255, bg.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  glEnable(GL_PROGRAM_POINT_SIZE)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA) # premultiplied
  glUseProgram(r.program)
  r.pointsDrawn = 0
  let view = f.area
  let perPixel = f.area.width / float64(width)
  for d in f.draws:
    let i = s.find(d.layer)
    let key = keyOf(d.layer, d.role)
    var b = -1
    for k, x in r.buffers:
      if x.key == key: b = k
    if i >= 0 and b >= 0:
      template l: untyped = s.layers[i]
      let p = addr l.levels[d.role]
      let reach = float64(d.style.size) * perPixel # a marker's room past the view
      let box = Bounds(minX: view.minX - reach, minY: view.minY - reach,
        maxX: view.maxX + reach, maxY: view.maxY + reach)
      let level = p[].levelFor(perPixel, LodPixels)
      var runs: seq[Slice[int]]
      if level < 0:
        for run in l.points[d.role].index.runs(box): runs.add run
      else:
        for run in p[].runs(level, box): runs.add run
      r.use(f, mapPoint(p.origin.x, p.origin.y), d.style)
      glBindVertexArray(r.buffers[b].vao)
      r.pointsDrawn += drawRuns(runs, r.buffers[b].starts[level + 1])
  if r.hvao != 0 and r.hselected + r.hhovered > 0:
    glBindVertexArray(r.hvao)
    if r.hselected > 0:
      r.use(f, r.horigin, f.selected)
      glDrawArrays(GL_POINTS, 0, GLsizei(r.hselected))
    if r.hhovered > 0:
      r.use(f, r.horigin, f.hovered)
      glDrawArrays(GL_POINTS, GLint(r.hselected), GLsizei(r.hhovered))
    r.pointsDrawn += r.hselected + r.hhovered
  r.last = f
  inc r.drawn

  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(lastFbo))
  glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(lastRead))
  glUseProgram(GLuint(lastProgram))
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))
  glViewport(lastViewport[0], lastViewport[1], lastViewport[2], lastViewport[3])
  glClearColor(lastClear[0], lastClear[1], lastClear[2], lastClear[3])
  for i, c in caps:
    if enabled[i]: glEnable(c)
    else: glDisable(c)
  r.target

proc readImage*(r: MapRenderer): seq[Rgba] =
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

func imageSize*(r: MapRenderer): (int, int) {.inline.} = (r.width, r.height)
  ## The size of the last image drawn.

proc free*(r: var MapRenderer) =
  ## Deletes its GL objects.
  for b in r.buffers.mitems: b.freeBuffer()
  if r.hvbo != 0: glDeleteBuffers(1, addr r.hvbo)
  if r.hvao != 0: glDeleteVertexArrays(1, addr r.hvao)
  if r.target != 0: glDeleteTextures(1, addr r.target)
  if r.fbo != 0: glDeleteFramebuffers(1, addr r.fbo)
  if r.program != 0: glDeleteProgram(r.program)
  r = MapRenderer()
