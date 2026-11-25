## The map's fold layer: the bins of a rotated grid drawn as filled quads
## with OpenGL 3.3, under the survey's points (`gpu/mappoints` calls it).
##
## The colour of each block of bins (`core/foldgrid`: the grid itself, or a
## coarser level when the bins are small on the screen) goes to the GPU once
## per level (`setCells`), four bytes a block. A frame draws one instanced
## triangle strip for each block of the block rows the view can touch
## (`FoldDraw.firstRow`, `rowCount`): the vertex shader finds the block from
## `gl_InstanceID`, lays its four corners on the rotated grid (a block's
## corners are the same numbers its neighbour's are, so quads meet without
## gaps), and moves a block of no fold (alpha 0) out of the view. Positions
## are relative to the view's centre, so a survey far from the origin keeps
## its precision. A pan or zoom changes the uniforms and the instance range
## only: no allocation, no upload.

import std/math
import ../core/spatial
import gl, textures

type
  FoldUniform = enum
    fuOffset = "offset", fuScale = "scale", fuU = "uAxis", fuV = "vAxis", fuBins = "bins",
    fuCols = "cols", fuFactor = "factor", fuAlong = "nAlong", fuAcross = "nAcross",
    fuFirst = "firstRow"

  FoldDraw* = object
    ## What the layer draws in one image.
    on*: bool
    key*: int                  ## names the cells `setCells` was given
    x0*, y0*: float64          ## the centre of bin (0, 0)
    azimuthDeg*: float64
    binAlong*, binAcross*: float64
    crosslines*, inlines*: int ## in bins
    factor*, cols*, rows*: int ## blocks of `factor` bins: their columns and rows
    firstRow*, rowCount*: int  ## the block rows drawn

  FoldGpu* = object
    program: GLuint
    loc: array[FoldUniform, GLint]
    vao, vbo: GLuint
    key*: int
    cells: int
    drawn*: int ## blocks of the last draw (for tests)

const
  vertexShader = """
#version 330 core
layout(location = 0) in vec4 cellColour;
uniform vec2 offset;  // the grid's first centre less the view's centre
uniform vec2 scale;   // ndc per map unit
uniform vec2 uAxis, vAxis; // unit vectors along the crosslines and along the inlines
uniform vec2 bins;    // bin size along u, along v
uniform int cols, factor, nAlong, nAcross, firstRow;
out vec4 shade;
void main() {
  shade = cellColour;
  if (cellColour.a == 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
  int col = gl_InstanceID % cols;
  int row = firstRow + gl_InstanceID / cols;
  float j0 = float(col * factor) - 0.5;
  float j1 = float(min((col + 1) * factor, nAlong)) - 0.5;
  float i0 = float(row * factor) - 0.5;
  float i1 = float(min((row + 1) * factor, nAcross)) - 0.5;
  float a = ((gl_VertexID & 1) == 0 ? j0 : j1) * bins.x;
  float b = ((gl_VertexID >> 1) == 0 ? i0 : i1) * bins.y;
  gl_Position = vec4((offset + a * uAxis + b * vAxis) * scale, 0.0, 1.0);
}
"""
  fragmentShader = """
#version 330 core
in vec4 shade;
out vec4 colour;
void main() { colour = vec4(shade.rgb, 1.0); }
"""

proc initFoldGpu*(): (FoldGpu, string) =
  ## The program and buffers, with a GL context current: "" or why not.
  var g = FoldGpu()
  if glVertexAttribDivisor.isNil or glDrawArraysInstanced.isNil:
    return (g, "OpenGL instancing missing")
  let (program, err) = buildProgram(vertexShader, fragmentShader, "map fold")
  if program == 0: return (g, err)
  g.program = program
  for u in FoldUniform:
    g.loc[u] = glGetUniformLocation(program, cstring($u))
  glGenVertexArrays(1, addr g.vao)
  glGenBuffers(1, addr g.vbo)
  (g, "")

proc setCells*(g: var FoldGpu; key: int; colours: openArray[uint32]) =
  ## Gives the GPU the block colours (packed r, g, b, a bytes) named `key`.
  ## The vertex array and buffer bound before are bound again.
  if g.vao == 0 or colours.len == 0: return
  var lastVao, lastBuf: GLint
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING, addr lastVao)
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING, addr lastBuf)
  glBindVertexArray(g.vao)
  glBindBuffer(GL_ARRAY_BUFFER, g.vbo)
  glBufferData(GL_ARRAY_BUFFER, GLsizeiptr(colours.len * 4), unsafeAddr colours[0],
    GL_STATIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 4, GL_UNSIGNED_BYTE, 1, 4, nil)
  glVertexAttribDivisor(0, 1)
  g.key = key
  g.cells = colours.len
  glBindVertexArray(GLuint(lastVao))
  glBindBuffer(GL_ARRAY_BUFFER, GLuint(lastBuf))

proc draw*(g: var FoldGpu; d: FoldDraw; area: Bounds) =
  ## Draws the blocks into the framebuffer bound, for map area `area`. The
  ## caller has the blending set; its program and vertex array are bound again by it.
  g.drawn = 0
  if g.program == 0 or not d.on or d.key != g.key or d.rowCount <= 0 or d.cols <= 0 or
      (d.firstRow + d.rowCount) * d.cols > g.cells:
    return
  let (s, c) = (sin(degToRad(d.azimuthDeg)), cos(degToRad(d.azimuthDeg)))
  glUseProgram(g.program)
  glUniform2f(g.loc[fuOffset], float32(d.x0 - (area.minX + area.maxX) / 2),
    float32(d.y0 - (area.minY + area.maxY) / 2))
  glUniform2f(g.loc[fuScale], float32(2 / area.width), float32(2 / area.height))
  glUniform2f(g.loc[fuU], float32(s), float32(c))
  glUniform2f(g.loc[fuV], float32(c), float32(-s))
  glUniform2f(g.loc[fuBins], float32(d.binAlong), float32(d.binAcross))
  glUniform1i(g.loc[fuCols], GLint(d.cols))
  glUniform1i(g.loc[fuFactor], GLint(d.factor))
  glUniform1i(g.loc[fuAlong], GLint(d.crosslines))
  glUniform1i(g.loc[fuAcross], GLint(d.inlines))
  glUniform1i(g.loc[fuFirst], GLint(d.firstRow))
  glBindVertexArray(g.vao)
  glBindBuffer(GL_ARRAY_BUFFER, g.vbo)
  # the instance range starts at the first row: the attribute's pointer moves there
  glVertexAttribPointer(0, 4, GL_UNSIGNED_BYTE, 1, 4, cast[pointer](d.firstRow * d.cols * 4))
  g.drawn = d.rowCount * d.cols
  glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, GLsizei(g.drawn))

proc free*(g: var FoldGpu) =
  if g.vbo != 0: glDeleteBuffers(1, addr g.vbo)
  if g.vao != 0: glDeleteVertexArrays(1, addr g.vao)
  if g.program != 0: glDeleteProgram(g.program)
  g = FoldGpu()
