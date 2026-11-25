## The map's fold layer: the bins of a rotated grid drawn as filled quads
## with OpenGL 3.3, under the survey's points (`gpu/mappoints` calls it).
##
## The colour of each block of bins (`core/foldgrid`: the grid itself, or a
## coarser level when the bins are small on the screen) goes to the GPU once
## per level (`setCells`) as an RGBA texture, one texel a block. A frame draws
## a few instanced triangle strips, one quad for each block of a rectangle of
## blocks (`setSpans` groups the runs of blocks the view touches, a row each,
## into at most `Chunks` such rectangles, so a rotated grid draws about its
## diagonal and a frame costs a few draw calls, not one a row): the vertex
## shader reads its block's colour with `texelFetch`, lays the block's four
## corners on the rotated grid (a block's corners are the same numbers its
## neighbour's are, so quads meet without gaps), and moves a block of no fold
## (alpha 0) out of the view. Positions are relative to the view's centre, so
## a survey far from the origin keeps its precision. A pan or zoom changes
## the uniforms and the rectangles only: no allocation, no upload.

import std/math
import ../core/[foldgrid, spatial]
import gl, textures

const Chunks = 12 ## draw calls a frame at most

type
  FoldUniform = enum
    fuOffset = "offset", fuScale = "scale", fuU = "uAxis", fuV = "vAxis", fuBins = "bins",
    fuFirstCol = "firstCol", fuFactor = "factor", fuAlong = "nAlong", fuAcross = "nAcross",
    fuFirst = "firstRow", fuWidth = "width", fuCells = "cells"

  FoldDraw* = object
    ## What the layer draws in one image.
    on*: bool
    key*: int                  ## names the cells `setCells` was given
    x0*, y0*: float64          ## the centre of bin (0, 0)
    azimuthDeg*: float64
    binAlong*, binAcross*: float64
    crosslines*, inlines*: int ## in bins
    factor*, cols*, rows*: int ## blocks of `factor` bins: their columns and rows
    spans*, spansSum*: int
      ## how many runs of blocks `setSpans` was given, and a sum naming them (the
      ## image is drawn again when they change)

  Rectangle = tuple[row, first, rows, width: int]

  FoldGpu* = object
    program: GLuint
    loc: array[FoldUniform, GLint]
    vao, tex: GLuint
    key*: int
    texCols, texRows: int
    rects: seq[Rectangle] ## what `setSpans` made of the runs of blocks
    drawn*: int           ## blocks of the last draw (for tests)

const
  vertexShader = """
#version 330 core
uniform sampler2D cells; // one texel a block
uniform vec2 offset;  // the grid's first centre less the view's centre
uniform vec2 scale;   // ndc per map unit
uniform vec2 uAxis, vAxis; // unit vectors along the crosslines and along the inlines
uniform vec2 bins;    // bin size along u, along v
uniform int firstCol, firstRow, width, factor, nAlong, nAcross;
out vec4 shade;
void main() {
  int col = firstCol + gl_InstanceID % width;
  int row = firstRow + gl_InstanceID / width;
  shade = texelFetch(cells, ivec2(col, row), 0);
  if (shade.a == 0.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
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
  ## The program and vertex array, with a GL context current: "" or why not.
  var g = FoldGpu()
  if glDrawArraysInstanced.isNil:
    return (g, "OpenGL instancing missing")
  let (program, err) = buildProgram(vertexShader, fragmentShader, "map fold")
  if program == 0: return (g, err)
  g.program = program
  for u in FoldUniform:
    g.loc[u] = glGetUniformLocation(program, cstring($u))
  glGenVertexArrays(1, addr g.vao)
  (g, "")

proc setCells*(g: var FoldGpu; key, cols, rows: int; colours: openArray[uint32]) =
  ## Gives the GPU the block colours (packed r, g, b, a bytes, `cols` x `rows`
  ## row-major) named `key`. The texture bound before is bound again.
  if g.vao == 0 or colours.len == 0 or colours.len != cols * rows: return
  var lastTex, lastUnit: GLint
  glGetIntegerv(GL_ACTIVE_TEXTURE, addr lastUnit)
  glActiveTexture(GL_TEXTURE0)
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr lastTex)
  if g.tex == 0: glGenTextures(1, addr g.tex)
  glBindTexture(GL_TEXTURE_2D, g.tex)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA8), GLsizei(cols), GLsizei(rows), 0, GL_RGBA,
    GL_UNSIGNED_BYTE, unsafeAddr colours[0])
  glBindTexture(GL_TEXTURE_2D, GLuint(lastTex))
  glActiveTexture(GLenum(lastUnit))
  (g.key, g.texCols, g.texRows) = (key, cols, rows)

proc setSpans*(g: var FoldGpu; spans: openArray[FoldSpan]): tuple[count, sum: int] =
  ## The runs of blocks the next draws are of, grouped (in room kept from the
  ## frame before) into at most `Chunks` rectangles of rows; a count and a sum
  ## that tell one set from another.
  g.rects.setLen 0
  let per = max(1, (spans.len + Chunks - 1) div Chunks)
  var k = 0
  while k < spans.len:
    var (lo, hi) = (spans[k].first, spans[k].last)
    let last = min(spans.len - 1, k + per - 1)
    for q in k .. last:
      lo = min(lo, spans[q].first)
      hi = max(hi, spans[q].last)
    g.rects.add (spans[k].row, lo, spans[last].row - spans[k].row + 1, hi - lo + 1)
    k = last + 1
  for sp in spans:
    result.sum = (result.sum * 31 + sp.row * 7 + sp.first * 3 + sp.last) mod 1_000_003
  result.count = spans.len

proc draw*(g: var FoldGpu; d: FoldDraw; area: Bounds) =
  ## Draws the rectangles of blocks into the framebuffer bound, for map area
  ## `area`. The caller has the blending set; its program and vertex array are
  ## bound again by it.
  g.drawn = 0
  if g.program == 0 or not d.on or d.key != g.key or g.rects.len == 0:
    return
  let (s, c) = (sin(degToRad(d.azimuthDeg)), cos(degToRad(d.azimuthDeg)))
  var lastTex, lastUnit: GLint
  glGetIntegerv(GL_ACTIVE_TEXTURE, addr lastUnit)
  glActiveTexture(GL_TEXTURE0)
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr lastTex)
  glBindTexture(GL_TEXTURE_2D, g.tex)
  glUseProgram(g.program)
  glUniform1i(g.loc[fuCells], 0)
  glUniform2f(g.loc[fuOffset], float32(d.x0 - (area.minX + area.maxX) / 2),
    float32(d.y0 - (area.minY + area.maxY) / 2))
  glUniform2f(g.loc[fuScale], float32(2 / area.width), float32(2 / area.height))
  glUniform2f(g.loc[fuU], float32(s), float32(c))
  glUniform2f(g.loc[fuV], float32(c), float32(-s))
  glUniform2f(g.loc[fuBins], float32(d.binAlong), float32(d.binAcross))
  glUniform1i(g.loc[fuFactor], GLint(d.factor))
  glUniform1i(g.loc[fuAlong], GLint(d.crosslines))
  glUniform1i(g.loc[fuAcross], GLint(d.inlines))
  glBindVertexArray(g.vao)
  for r in g.rects:
    if r.row + r.rows <= g.texRows and r.first + r.width <= g.texCols:
      glUniform1i(g.loc[fuFirst], GLint(r.row))
      glUniform1i(g.loc[fuFirstCol], GLint(r.first))
      glUniform1i(g.loc[fuWidth], GLint(r.width))
      glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, GLsizei(r.rows * r.width))
      g.drawn += r.rows * r.width
  glBindTexture(GL_TEXTURE_2D, GLuint(lastTex))
  glActiveTexture(GLenum(lastUnit))

proc free*(g: var FoldGpu) =
  if g.tex != 0: glDeleteTextures(1, addr g.tex)
  if g.vao != 0: glDeleteVertexArrays(1, addr g.vao)
  if g.program != 0: glDeleteProgram(g.program)
  g = FoldGpu()
