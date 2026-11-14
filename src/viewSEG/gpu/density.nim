## Variable-density drawing of trace tiles with OpenGL 3.3.
##
## Each `Tile` (`core/tiles`) is uploaded as `R32F` textures, one per block
## that fits the GPU's texture size limit (`splitBlocks`). `render` draws
## the tiles that cover a view into an RGBA image the size of the plot, with
## one shader: the nearest trace, linear interpolation in time between
## column centres, the display gain as a uniform, and a 256-entry colour map
## texture. The frontend then shows that image in its plot. The shader does
## what `amplitudeAt` and `densityColour` do on the CPU, which is what the
## tests compare it with.
##
## Everything here runs on the UI thread with the frontend's GL context
## current. Objects are freed explicitly (`free`), while a context is
## current, never by a destructor.

import std/strutils
import ../core/[geometry, tiles, viewport]
import gl

export GetProcAddress, GLuint

type
  TileTextures* = object
    ## The GPU's copy of one tile.
    id*: uint64           ## the tile's id
    blocks: seq[TileBlock]
    textures: seq[GLuint] ## one per block
    bytes*: int           ## GPU memory they take

  DensityRenderer* = object
    ## The shader, the colour map, and the image the plot shows.
    program, vao, vbo, lut, fbo, target: GLuint
    width, height: int
    locAmps, locLut, locScale: GLint
    maxSize: int ## the largest texture side used
    ready: bool

const
  vertexShader = """
#version 330 core
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
out vec2 texel;
void main() {
  texel = uv;
  gl_Position = vec4(pos, 0.0, 1.0);
}
"""
  # u: the row (trace), nearest; v: the column, linear between centres and
  # held at the ends. As `amplitudeAt` and `lutIndex`.
  fragmentShader = """
#version 330 core
in vec2 texel;
uniform sampler2D amps;
uniform sampler2D lut;
uniform float scale;
out vec4 colour;
void main() {
  ivec2 size = textureSize(amps, 0);
  int row = clamp(int(floor(texel.x)), 0, size.y - 1);
  float j = floor(texel.y);
  int j0 = clamp(int(j), 0, size.x - 1);
  int j1 = clamp(int(j) + 1, 0, size.x - 1);
  float f = clamp(texel.y - j, 0.0, 1.0);
  float a0 = texelFetch(amps, ivec2(j0, row), 0).r;
  float a1 = texelFetch(amps, ivec2(j1, row), 0).r;
  float a = a0 * (1.0 - f) + a1 * f;
  float u = clamp(a * scale, -1.0, 1.0);
  int i = int(floor((u + 1.0) * 127.5 + 0.5));
  colour = texelFetch(lut, ivec2(i, 0), 0);
}
"""

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

proc compile(kind: GLenum; source: string): (GLuint, string) =
  let s = glCreateShader(kind)
  var src = source.cstring
  glShaderSource(s, 1, addr src, nil)
  glCompileShader(s)
  var ok: GLint
  glGetShaderiv(s, GL_COMPILE_STATUS, addr ok)
  if ok == 0:
    var n: GLint
    glGetShaderiv(s, GL_INFO_LOG_LENGTH, addr n)
    var log = newString(max(n, 1))
    glGetShaderInfoLog(s, GLsizei(log.len), nil, log.cstring)
    glDeleteShader(s)
    return (0'u32, log.strip(chars = {'\0', ' ', '\n'}))
  (s, "")

proc texture(): GLuint =
  ## A new 2D texture, bound, sampled nearest and clamped.
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))

proc setLut*(r: DensityRenderer; lut: Lut) =
  ## Replaces the colour map.
  var last: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr last)
  glBindTexture(GL_TEXTURE_2D, r.lut)
  var data = lut
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), 256, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE,
    addr data[0])
  glBindTexture(GL_TEXTURE_2D, GLuint(last))

proc warmUp(r: var DensityRenderer) {.gcsafe.}

proc newDensityRenderer*(lut: Lut; maxSize = 0): (DensityRenderer, string) =
  ## The renderer, with colour map `lut`, and "" or why it cannot draw (a
  ## shader the driver rejects). Textures are at most `maxSize` on a side
  ## (0: the GPU's limit). Needs `initGpu` first.
  var r = DensityRenderer()
  if not loaded:
    return (r, "OpenGL functions missing: " & missing.join(", "))
  r.maxSize = if maxSize > 0: min(maxSize, maxTextureSize()) else: maxTextureSize()
  let (vs, e1) = compile(GL_VERTEX_SHADER, vertexShader)
  if vs == 0: return (r, "the density vertex shader: " & e1)
  let (fs, e2) = compile(GL_FRAGMENT_SHADER, fragmentShader)
  if fs == 0:
    glDeleteShader(vs)
    return (r, "the density fragment shader: " & e2)
  r.program = glCreateProgram()
  glAttachShader(r.program, vs)
  glAttachShader(r.program, fs)
  glLinkProgram(r.program)
  glDeleteShader(vs)
  glDeleteShader(fs)
  var ok: GLint
  glGetProgramiv(r.program, GL_LINK_STATUS, addr ok)
  if ok == 0:
    var log = newString(1024)
    glGetProgramInfoLog(r.program, GLsizei(log.len), nil, log.cstring)
    glDeleteProgram(r.program)
    return (DensityRenderer(), "the density shader: " & log.strip(chars = {'\0', ' ', '\n'}))
  r.locAmps = glGetUniformLocation(r.program, "amps")
  r.locLut = glGetUniformLocation(r.program, "lut")
  r.locScale = glGetUniformLocation(r.program, "scale")
  var lastVao, lastBuf, lastTex: GLint
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr lastTex)
  glGenVertexArrays(1, addr r.vao)
  glGenBuffers(1, addr r.vbo)
  glBindVertexArray(r.vao)
  glBindBuffer(GL_ARRAY_BUFFER, r.vbo)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, GL_FLOAT, 0, 4 * sizeof(float32), nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 2, GL_FLOAT, 0, 4 * sizeof(float32),
    cast[pointer](2 * sizeof(float32)))
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))
  r.lut = texture()
  glBindTexture(GL_TEXTURE_2D, GLuint(lastTex))
  r.setLut(lut)
  glGenFramebuffers(1, addr r.fbo)
  r.ready = true
  r.warmUp()
  (r, "")

func ready*(r: DensityRenderer): bool {.inline.} = r.ready
  ## Whether it can draw.

func maxSize*(r: DensityRenderer): int {.inline.} = r.maxSize
  ## The largest texture side it uses.

proc upload*(r: DensityRenderer; t: Tile): TileTextures =
  ## The GPU's copy of `t`: one `R32F` texture per block, texture rows the
  ## tile's traces.
  result = TileTextures(id: t.id)
  if not r.ready or t.request.count == 0 or t.columns == 0: return
  var last: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr last)
  glPixelStorei(GL_UNPACK_ROW_LENGTH, GLint(t.columns))
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  for b in splitBlocks(t.request.count, t.columns, r.maxSize):
    let tex = texture()
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_R32F), GLsizei(b.cols), GLsizei(b.rows), 0,
      GL_RED, GL_FLOAT, unsafeAddr t.data[b.row * t.columns + b.col])
    result.blocks.add b
    result.textures.add tex
    result.bytes += b.rows * b.cols * sizeof(float32)
  glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)
  glBindTexture(GL_TEXTURE_2D, GLuint(last))

proc free*(tt: var TileTextures) =
  ## Deletes the textures.
  if tt.textures.len > 0:
    glDeleteTextures(GLsizei(tt.textures.len), addr tt.textures[0])
  tt.textures.setLen 0
  tt.blocks.setLen 0
  tt.bytes = 0

proc resize(r: var DensityRenderer; width, height: int) =
  if r.target != 0 and width == r.width and height == r.height: return
  if r.target != 0: glDeleteTextures(1, addr r.target)
  r.target = texture()
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glBindFramebuffer(GL_FRAMEBUFFER, r.fbo)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, r.target, 0)
  (r.width, r.height) = (width, height)

func ndc(s: Span; v: float64; flip: bool): float32 {.inline.} =
  let f = (v - s.lo) / (s.hi - s.lo) * 2 - 1
  float32(if flip: -f else: f)

proc render*(r: var DensityRenderer; view: Viewport; width, height: int; background: Rgba;
    scale: float32; tiles: openArray[Tile]; textures: openArray[TileTextures]): GLuint =
  ## Draws `tiles` (with their GPU copies `textures`, in the same order;
  ## later ones over earlier ones) as they fall in `view`, into an image of
  ## `width` × `height` pixels on `background`, and returns that image's
  ## texture: its first row is the view's bottom edge. The GL state the
  ## frontend had is restored. 0 when it cannot draw.
  if not r.ready or width <= 0 or height <= 0 or not (view.traces.width > 0) or
      not (view.timeMs.width > 0):
    return 0
  var lastFbo, lastRead, lastProgram, lastVao, lastActive, lastBuf: GLint
  var lastTex: array[2, GLint]
  var lastViewport: array[4, GLint]
  var lastClear: array[4, float32]
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, addr lastFbo)
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, addr lastRead)
  glGetIntegerv(GL_CURRENT_PROGRAM, addr lastProgram)
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  glGetIntegerv(GL_ACTIVE_TEXTURE, addr lastActive)
  glGetIntegerv(GL_VIEWPORT, addr lastViewport[0])
  glGetFloatv(GL_COLOR_CLEAR_VALUE, addr lastClear[0])
  for unit in 0 .. 1:
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
  glClearColor(background.r.float32 / 255, background.g.float32 / 255,
    background.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  glUseProgram(r.program)
  glUniform1i(r.locAmps, 0)
  glUniform1i(r.locLut, 1)
  glUniform1f(r.locScale, scale)
  glActiveTexture(GL_TEXTURE0 + 1)
  glBindTexture(GL_TEXTURE_2D, r.lut)
  glActiveTexture(GL_TEXTURE0)
  glBindVertexArray(r.vao)
  glBindBuffer(GL_ARRAY_BUFFER, r.vbo)
  var v: array[24, float32]
  for i in 0 ..< min(tiles.len, textures.len):
    let tt = textures[i]
    for k, b in tt.blocks:
      let q = tiles[i].quad(b)
      let (x0, x1) = (view.traces.ndc(q.x0, false), view.traces.ndc(q.x1, false))
      let (y0, y1) = (view.timeMs.ndc(q.t0, true), view.timeMs.ndc(q.t1, true))
      let (u0, u1, v0, v1) = (float32(q.u0), float32(q.u1), float32(q.v0), float32(q.v1))
      v = [x0, y0, u0, v0, x1, y0, u1, v0, x1, y1, u1, v1,
           x0, y0, u0, v0, x1, y1, u1, v1, x0, y1, u0, v1]
      glBufferData(GL_ARRAY_BUFFER, sizeof(v), addr v[0], GL_STREAM_DRAW)
      glBindTexture(GL_TEXTURE_2D, tt.textures[k])
      glDrawArrays(GL_TRIANGLES, 0, 6)

  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, GLuint(lastFbo))
  glBindFramebuffer(GL_READ_FRAMEBUFFER, GLuint(lastRead))
  glUseProgram(GLuint(lastProgram))
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))
  for unit in 0 .. 1:
    glActiveTexture(GL_TEXTURE0 + GLenum(unit))
    glBindTexture(GL_TEXTURE_2D, GLuint(lastTex[unit]))
  glActiveTexture(GLenum(lastActive))
  glViewport(lastViewport[0], lastViewport[1], lastViewport[2], lastViewport[3])
  glClearColor(lastClear[0], lastClear[1], lastClear[2], lastClear[3])
  for i, c in caps:
    if enabled[i]: glEnable(c)
  r.target

proc warmUp(r: var DensityRenderer) =
  ## Draws one value once, so that a driver that compiles shaders on first
  ## use (Mesa's llvmpipe takes tens of ms) does it now, not in a frame.
  let t = Tile(id: 0, request: ReadRequest(count: 1, stride: 1, samples: 1, decimation: 1),
    dtMs: 1, columns: 1, data: @[0'f32])
  var tt = r.upload(t)
  discard r.render(Viewport(traces: Span(lo: -0.5, hi: 0.5), timeMs: Span(lo: -0.5, hi: 0.5),
    columns: 1, rows: 1), 1, 1, Rgba(), 1, [t], [tt])
  tt.free()

proc readImage*(r: DensityRenderer): seq[Rgba] =
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

func imageSize*(r: DensityRenderer): (int, int) {.inline.} = (r.width, r.height)
  ## The size of the last image drawn.

proc free*(r: var DensityRenderer) =
  ## Deletes its GL objects.
  if r.target != 0: glDeleteTextures(1, addr r.target)
  if r.lut != 0: glDeleteTextures(1, addr r.lut)
  if r.fbo != 0: glDeleteFramebuffers(1, addr r.fbo)
  if r.vbo != 0: glDeleteBuffers(1, addr r.vbo)
  if r.vao != 0: glDeleteVertexArrays(1, addr r.vao)
  if r.program != 0: glDeleteProgram(r.program)
  r = DensityRenderer()
