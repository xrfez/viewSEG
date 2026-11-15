## Wiggle drawing of trace tiles with OpenGL 3.3: one program, used by
## `gpu/plotimage` for each block of a tile.
##
## Each trace of a block is one quad, as wide as its swing can reach
## (`reach`) and as long as the block, drawn instanced (one instance per
## trace) from no vertex data at all. Its fragment shader reads the trace's
## vertices (the values, or the columns' extremes: `core/wiggle`'s
## `Series`) from the block's texture and computes, per pixel, the line's
## and the fills' coverage as `traceInk` does on the CPU, premultiplied, so
## that the quads blend over one another in the traces' order. Everything
## else is a uniform: the gain, the overlap, the colours, the hovered row;
## the selected rows, and those the map's pointer lights up (drawn as the
## hovered row), are the block's marks texture. So a change of any of them
## draws again at once and reads nothing; only the marks are uploaded again.
##
## A second pass draws the hovered and selected traces again, on top: the
## quads of the other traces are collapsed in the vertex shader. A killed
## trace's quad is always collapsed: it is drawn blank.
##
## Positions and times reach the shaders relative to the view's top-left
## corner, taken in float64 here: in float32, position 10 000 000 is a
## whole trace off and 20 000 ms a pixel off when zoomed in, so the
## wiggles of a large gather or a long record would leave their traces.

import ../core/[panels, tiles, viewport, wiggle]
import density, gl, textures

type
  WiggleUniform = enum
    wuSeries = "series", wuMarks = "marks", wuXMap = "xMap", wuTMap = "tMap",
    wuFirstPos = "firstPos", wuStride = "stride", wuReach = "reach", wuTSpan = "tSpan",
    wuHoverRow = "hoverRow", wuMarkedOnly = "markedOnly", wuCount = "count",
    wuFirstMs = "firstMs", wuStepMs = "stepMs", wuScale = "scale", wuOverlap = "overlap",
    wuPxPerPos = "pxPerPos", wuMsPerPx = "msPerPx", wuLineHalf = "lineHalf",
    wuMarkedHalf = "markedHalf", wuFills = "fills", wuLine = "lineColour",
    wuPositive = "positiveColour", wuNegative = "negativeColour", wuHover = "hoverColour",
    wuSelected = "selectedColour"

  WiggleProgram* = object
    ## The wiggle shader and the empty vertex array it draws from.
    program, vao: GLuint
    loc: array[WiggleUniform, GLint]

const
  vertexShader = """
#version 330 core
// Positions and times are relative to the view's left and top edges.
uniform vec2 xMap;       // ndc = position * xMap.x + xMap.y
uniform vec2 tMap;       // ndc = ms * tMap.x + tMap.y
uniform float firstPos;  // the position of the block's first trace
uniform float stride;    // positions between its traces
uniform float reach;     // how far a trace puts ink, in trace spacings
uniform vec2 tSpan;      // the block's time span, ms
uniform int hoverRow;    // the block's hovered row; -1 for none
uniform int markedOnly;  // 1: only the hovered and selected traces
uniform sampler2D marks;
flat out int row;
flat out int marked;     // 0 none, 1 selected, 2 hovered
out float xOff;          // trace spacings from the baseline
out float tMs;
void main() {
  row = gl_InstanceID;
  int m = int(texelFetch(marks, ivec2(row, 0), 0).r * 255.0 + 0.5);
  bool selected = (m & 1) != 0;
  bool killed = (m & 2) != 0;
  bool lit = (m & 4) != 0; // lit up from the map: drawn as the hovered trace
  marked = (row == hoverRow || lit) ? 2 : (selected ? 1 : 0);
  int corner = gl_VertexID;
  xOff = ((corner & 1) == 0 ? -1.0 : 1.0) * reach;
  tMs = (corner & 2) == 0 ? tSpan.x : tSpan.y;
  float x = firstPos + float(row) * stride + xOff;
  vec2 p = vec2(x * xMap.x + xMap.y, tMs * tMap.x + tMap.y);
  if (killed || (markedOnly == 1 && marked == 0)) p = vec2(-2.0, -2.0); // collapsed: nothing drawn
  gl_Position = vec4(p, 0.0, 1.0);
}
"""
  # As `valueAt`, `swing`, `lineExtent`, `covered` and `traceInk`.
  fragmentShader = """
#version 330 core
uniform sampler2D series;
uniform int count;
uniform float firstMs, stepMs; // times relative to the view's top edge, as tMs
uniform float scale, overlap, pxPerPos, msPerPx, lineHalf, markedHalf;
uniform int fills;       // 1 positive, 2 negative
uniform vec4 lineColour, positiveColour, negativeColour, hoverColour, selectedColour;
flat in int row;
flat in int marked;
in float xOff;
in float tMs;
out vec4 colour;

float index(float t) {
  float u = (t - firstMs) / stepMs;
  return u >= -1.0 ? min(u, float(count)) : -1.0;
}
float vertex(int k) { return texelFetch(series, ivec2(k, row), 0).r; }
float valueAt(float t) {
  float u = index(t);
  float j = floor(u);
  int j0 = clamp(int(j), 0, count - 1);
  int j1 = clamp(int(j) + 1, 0, count - 1);
  float f = clamp(u - j, 0.0, 1.0);
  return vertex(j0) * (1.0 - f) + vertex(j1) * f;
}
float swing(float a) { return clamp(a * scale, -1.0, 1.0) * overlap; }
float covered(float lo, float hi, float x0, float x1) {
  return clamp(min(hi, x1) - max(lo, x0), 0.0, 1.0);
}
void main() {
  vec4 line = lineColour, positive = positiveColour, negative = negativeColour;
  float halfWidth = lineHalf;
  if (marked == 2) { line = hoverColour; positive = hoverColour; negative = hoverColour; }
  if (marked == 1) { line = selectedColour; positive = selectedColour; negative = selectedColour; }
  if (marked != 0) halfWidth = markedHalf;
  float x = xOff * pxPerPos;
  float x0 = x - 0.5, x1 = x + 0.5;
  vec4 ink = vec4(0.0);
  if (fills != 0) {
    float d = swing(valueAt(tMs)) * pxPerPos;
    if (d > 0.0 && (fills & 1) != 0) ink = vec4(positive.rgb, 1.0) * covered(0.0, d, x0, x1);
    else if (d < 0.0 && (fills & 2) != 0) ink = vec4(negative.rgb, 1.0) * covered(d, 0.0, x0, x1);
  }
  if (halfWidth > 0.0) {
    float tA = tMs - msPerPx / 2.0, tB = tMs + msPerPx / 2.0;
    float dA = swing(valueAt(tA)), dB = swing(valueAt(tB));
    float lo = min(dA, dB), hi = max(dA, dB);
    int k = max(0, int(floor(index(tA))) + 1);
    int last = min(count - 1, int(ceil(index(tB))) - 1);
    for (int seen = 0; seen < 32 && k <= last; ++seen, ++k) {
      float d = swing(vertex(k));
      lo = min(lo, d);
      hi = max(hi, d);
    }
    float c = covered(lo * pxPerPos - halfWidth, hi * pxPerPos + halfWidth, x0, x1);
    ink = vec4(line.rgb, 1.0) * c + ink * (1.0 - c);
  }
  if (ink.a <= 0.0) discard;
  colour = ink;
}
"""

proc initWiggleProgram*(): (WiggleProgram, string) =
  ## The program, and "" or why the driver rejects it.
  var w = WiggleProgram()
  let (program, err) = buildProgram(vertexShader, fragmentShader, "wiggle")
  if program == 0: return (w, err)
  w.program = program
  for u in WiggleUniform:
    w.loc[u] = glGetUniformLocation(program, cstring($u))
  glGenVertexArrays(1, addr w.vao)
  (w, "")

proc use*(w: WiggleProgram; view: Viewport; st: WiggleStyle; ink: WiggleInk) =
  ## Makes the program current for `view`, drawn in style `st` and colours
  ## `ink`: the series on texture unit 0, the marks on 2.
  glUseProgram(w.program)
  template loc(u: WiggleUniform): GLint = w.loc[u]
  glUniform1i(loc(wuSeries), 0)
  glUniform1i(loc(wuMarks), 2)
  # ndc = (v - lo) / (hi - lo) * 2 - 1, time flipped (down the screen); `draw`
  # passes v - lo
  glUniform2f(loc(wuXMap), float32(2 / view.traces.width), -1)
  glUniform2f(loc(wuTMap), float32(-2 / view.timeMs.width), 1)
  glUniform1f(loc(wuReach), float32(st.reach))
  glUniform1f(loc(wuScale), st.scale)
  glUniform1f(loc(wuOverlap), float32(st.overlap))
  glUniform1f(loc(wuPxPerPos), float32(st.pixelsPerTrace))
  glUniform1f(loc(wuMsPerPx), float32(st.msPerPixel))
  glUniform1f(loc(wuLineHalf), float32(st.lineWidth / 2))
  glUniform1f(loc(wuMarkedHalf), float32(st.markedWidth / 2))
  glUniform1i(loc(wuFills), GLint((if wfPositive in st.fills: 1 else: 0) or
    (if wfNegative in st.fills: 2 else: 0)))
  uniform4(loc(wuLine), ink.line)
  uniform4(loc(wuPositive), ink.positive)
  uniform4(loc(wuNegative), ink.negative)
  uniform4(loc(wuHover), ink.hover)
  uniform4(loc(wuSelected), ink.selected)
  glBindVertexArray(w.vao)

proc draw*(w: WiggleProgram; view: Viewport; t: Tile; tt: TileTextures; hoverRow: int;
    markedOnly: bool) =
  ## Draws the traces of tile `t` (its GPU copy `tt`) as they fall in `view`
  ## (the one given to `use`): every trace, or only the hovered (`hoverRow`,
  ## -1 for none) and selected ones.
  let s = t.series
  let r = t.request
  let (x0, t0) = (view.traces.lo, view.timeMs.lo) # the shaders' origin
  template loc(u: WiggleUniform): GLint = w.loc[u]
  glUniform1i(loc(wuMarkedOnly), GLint(markedOnly))
  glUniform1f(loc(wuStride), float32(r.stride))
  for k, b in tt.blocks:
    let q = t.quad(b)
    glUniform1f(loc(wuFirstPos), float32(float64(r.position(b.row)) - x0))
    glUniform2f(loc(wuTSpan), float32(q.t0 - t0), float32(q.t1 - t0))
    glUniform1i(loc(wuHoverRow), GLint(if hoverRow >= b.row and hoverRow < b.row + b.rows:
      hoverRow - b.row else: -1))
    glUniform1i(loc(wuCount), GLint(b.cols * s.perColumn))
    glUniform1f(loc(wuFirstMs), float32(s.firstMs + float64(b.col * s.perColumn) * s.stepMs -
      t0))
    glUniform1f(loc(wuStepMs), float32(s.stepMs))
    glActiveTexture(GL_TEXTURE0 + 2)
    glBindTexture(GL_TEXTURE_2D, tt.marks[k])
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, if s.perColumn == 2: tt.envelope[k] else: tt.data[k])
    glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, GLsizei(b.rows))

proc free*(w: var WiggleProgram) =
  ## Deletes its GL objects.
  if w.vao != 0: glDeleteVertexArrays(1, addr w.vao)
  if w.program != 0: glDeleteProgram(w.program)
  w = WiggleProgram()
