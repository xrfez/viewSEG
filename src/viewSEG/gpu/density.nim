## Variable-density drawing of trace tiles with OpenGL 3.3: one program,
## used by `gpu/plotimage` for each block of a tile.
##
## A block is one quad, its corners placed through the plot's `Turn`
## (`core/orientation`'s `ndcOf`), so a plot turned time across draws the
## same texels transposed; the texture coordinates do not change.
##
## The shader takes the nearest trace and interpolates linearly in time
## between column centres, scales by the display gain (a uniform) and looks
## the colour up in a 256-entry colour map: what `amplitudeAt` and
## `densityColour` do on the CPU, which is what the tests compare it with.
## A hovered or selected trace's column is tinted towards its colour
## (`densityTint` on the CPU). A killed trace's column is the plot's
## background (`solidColour`), tinted as well. Drawn `solid`, the quad is
## painted in one colour instead: the paper under a tile's wiggles.

import ../core/[geometry, orientation, tiles, viewport]
import gl, textures

type
  DensityProgram* = object
    ## The density shader and the buffer for its quads.
    program, vao, vbo: GLuint
    locAmps, locLut, locMarks, locScale, locSolid, locSolidColour, locHover, locTint,
      locHoverColour, locSelectedColour, locBandPx, locBandEdge, locImageSize,
      locCompColour: GLint

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
  # held at the ends. As `amplitudeAt` and `lutIndex`; the tint as
  # `densityTint`.
  fragmentShader = """
#version 330 core
in vec2 texel;
uniform sampler2D amps;
uniform sampler2D lut;
uniform sampler2D marks;
uniform float scale;
uniform int solid;
uniform vec4 solidColour;
uniform int hoverRow;
uniform float tint;
uniform vec4 hoverColour;
uniform vec4 selectedColour;
uniform int bandPx;          // 0: no component band
uniform int bandEdge;        // 0 top of the image, 1 its left edge
uniform vec2 imageSize;
uniform vec4 compColour[4];  // hydrophone, vertical, inline, crossline
out vec4 colour;
void main() {
  if (solid == 1) {
    colour = solidColour;
    return;
  }
  ivec2 size = textureSize(amps, 0);
  int row = clamp(int(floor(texel.x)), 0, size.y - 1);
  float j = floor(texel.y);
  int j0 = clamp(int(j), 0, size.x - 1);
  int j1 = clamp(int(j) + 1, 0, size.x - 1);
  float f = clamp(texel.y - j, 0.0, 1.0);
  int m = int(texelFetch(marks, ivec2(row, 0), 0).r * 255.0 + 0.5);
  if ((m & 2) != 0) colour = solidColour; // killed: blank
  else {
    float a0 = texelFetch(amps, ivec2(j0, row), 0).r;
    float a1 = texelFetch(amps, ivec2(j1, row), 0).r;
    float a = a0 * (1.0 - f) + a1 * f;
    float u = clamp(a * scale, -1.0, 1.0);
    int i = int(floor((u + 1.0) * 127.5 + 0.5));
    colour = texelFetch(lut, ivec2(i, 0), 0);
  }
  if (tint > 0.0) {
    if (row == hoverRow || (m & 4) != 0) colour = mix(colour, hoverColour, tint);
    else if ((m & 1) != 0) colour = mix(colour, selectedColour, tint);
  }
  if (bandPx > 0 && (m & 2) == 0) {
    int kind = (m >> 3) & 7;
    bool edge = bandEdge == 0 ? gl_FragCoord.y >= imageSize.y - float(bandPx)
                              : gl_FragCoord.x < float(bandPx);
    if (edge && kind >= 1 && kind <= 4) colour = compColour[kind - 1];
  }
}
"""

func vec4(c: Rgba): array[4, float32] =
  [c.r.float32 / 255, c.g.float32 / 255, c.b.float32 / 255, c.a.float32 / 255]

proc uniform4*(loc: GLint; c: Rgba) =
  ## Sets a `vec4` uniform to colour `c`.
  let v = vec4(c)
  glUniform4f(loc, v[0], v[1], v[2], v[3])

proc initDensityProgram*(): (DensityProgram, string) =
  ## The program, and "" or why the driver rejects it.
  var d = DensityProgram()
  let (program, err) = buildProgram(vertexShader, fragmentShader, "density")
  if program == 0: return (d, err)
  d.program = program
  for (loc, name) in [(addr d.locAmps, "amps"), (addr d.locLut, "lut"), (addr d.locMarks, "marks"),
      (addr d.locScale, "scale"), (addr d.locSolid, "solid"),
      (addr d.locSolidColour, "solidColour"), (addr d.locHover, "hoverRow"),
      (addr d.locTint, "tint"), (addr d.locHoverColour, "hoverColour"),
      (addr d.locSelectedColour, "selectedColour"), (addr d.locBandPx, "bandPx"),
      (addr d.locBandEdge, "bandEdge"), (addr d.locImageSize, "imageSize"),
      (addr d.locCompColour, "compColour[0]")]:
    loc[] = glGetUniformLocation(program, name.cstring)
  var lastVao, lastBuf: GLint
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  glGenVertexArrays(1, addr d.vao)
  glGenBuffers(1, addr d.vbo)
  glBindVertexArray(d.vao)
  glBindBuffer(GL_ARRAY_BUFFER, d.vbo)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, GL_FLOAT, 0, 4 * sizeof(float32), nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 2, GL_FLOAT, 0, 4 * sizeof(float32),
    cast[pointer](2 * sizeof(float32)))
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))
  (d, "")

type DensityLook* = object
  ## How density is drawn: the scale, or one solid colour; the tint of
  ## marked traces.
  scale*: float32
  solid*: bool
  solidColour*: Rgba
  tint*: float32
  hover*, selected*: Rgba
  bandPx*: int ## 0: no component band along the top of each trace column
  bandEdge*: int ## 0 the top of the image, 1 its left edge (time across)
  imageW*, imageH*: int
  componentColours*: array[4, Rgba]

proc use*(d: DensityProgram; look: DensityLook) =
  ## Makes the program current with `look`: the values on texture unit 0,
  ## the colour map on 1, the marks on 2.
  glUseProgram(d.program)
  glUniform1i(d.locAmps, 0)
  glUniform1i(d.locLut, 1)
  glUniform1i(d.locMarks, 2)
  glUniform1f(d.locScale, look.scale)
  glUniform1i(d.locSolid, GLint(look.solid))
  uniform4(d.locSolidColour, look.solidColour)
  glUniform1f(d.locTint, look.tint)
  uniform4(d.locHoverColour, look.hover)
  uniform4(d.locSelectedColour, look.selected)
  glUniform1i(d.locBandPx, GLint(look.bandPx))
  glUniform1i(d.locBandEdge, GLint(look.bandEdge))
  glUniform2f(d.locImageSize, float32(look.imageW), float32(look.imageH))
  for i, c in look.componentColours:
    uniform4(d.locCompColour + GLint(i), c)
  glBindVertexArray(d.vao)
  glBindBuffer(GL_ARRAY_BUFFER, d.vbo)

proc draw*(d: DensityProgram; view: Viewport; m: Turn; t: Tile; tt: TileTextures;
    hoverRow: int) =
  ## Draws the blocks of tile `t` (its GPU copy `tt`) as they fall in
  ## `view` on a plot turned as `m` says, after `use`; `hoverRow` is the
  ## tile's hovered row, -1 for none.
  var v: array[24, float32]
  for k, b in tt.blocks:
    let q = t.quad(b)
    # the corners: first position and earliest time, then round the block
    let a = view.ndcOf(m, DataPoint(x: q.x0, tMs: q.t0))
    let c = view.ndcOf(m, DataPoint(x: q.x1, tMs: q.t0))
    let e = view.ndcOf(m, DataPoint(x: q.x1, tMs: q.t1))
    let g = view.ndcOf(m, DataPoint(x: q.x0, tMs: q.t1))
    let (u0, u1, v0, v1) = (float32(q.u0), float32(q.u1), float32(q.v0), float32(q.v1))
    v = [a[0], a[1], u0, v0, c[0], c[1], u1, v0, e[0], e[1], u1, v1,
         a[0], a[1], u0, v0, e[0], e[1], u1, v1, g[0], g[1], u0, v1]
    glBufferData(GL_ARRAY_BUFFER, sizeof(v), addr v[0], GL_STREAM_DRAW)
    glUniform1i(d.locHover, GLint(if hoverRow >= b.row and hoverRow < b.row + b.rows:
      hoverRow - b.row else: -1))
    glActiveTexture(GL_TEXTURE0 + 2)
    glBindTexture(GL_TEXTURE_2D, tt.marks[k])
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, tt.data[k])
    glDrawArrays(GL_TRIANGLES, 0, 6)

proc free*(d: var DensityProgram) =
  ## Deletes its GL objects.
  if d.vbo != 0: glDeleteBuffers(1, addr d.vbo)
  if d.vao != 0: glDeleteVertexArrays(1, addr d.vao)
  if d.program != 0: glDeleteProgram(d.program)
  d = DensityProgram()
