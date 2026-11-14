## The GPU's copy of each trace tile, and the helpers the plot's two
## programs (`gpu/density`, `gpu/wiggle`) share.
##
## A `Tile` (`core/tiles`) is uploaded once, as blocks that fit the GPU's
## texture size limit (`splitBlocks`), each with up to three textures:
##
## - its values, `R32F`, one texture row per trace (density, and wiggles
##   when the samples are not decimated);
## - with the tile's envelope (`core/wiggle`), each column's extremes, two
##   texels a column, what zoomed-out wiggles are drawn through;
## - its marks, `R8`, one texel per trace: whether the trace is selected
##   (`SelectedMark`) and whether it was killed when the tile was made
##   (`KilledMark`: drawn blank), replaced (`setMarks`) when the selection
##   changes, so a click never uploads samples again.
##
## Everything here runs on the UI thread with the frontend's GL context
## current. Objects are freed explicitly (`free`), never by a destructor.

import std/strutils
import ../core/[tiles, viewport, wiggle]
import gl

const
  SelectedMark* = 1'u8 ## a mark's bit: the trace is selected
  KilledMark* = 2'u8   ## a mark's bit: the trace is killed (drawn blank)

type
  TileTextures* = object
    ## The GPU's copy of one tile.
    id*: uint64             ## the tile's id
    blocks*: seq[TileBlock]
    data*: seq[GLuint]      ## per block: the values
    envelope*: seq[GLuint]  ## per block: the columns' extremes; empty when the tile has none
    marks*: seq[GLuint]     ## per block: each trace's `SelectedMark` and `KilledMark` bits
    bytes*: int             ## GPU memory they take
    selectionRevision*: int ## the selection the marks show; -1 for none yet
    hoverRevision*: int     ## the selection `hoverRow` was found for; -1 for none yet
    hoverRow*: int          ## the tile's row of the hovered trace; -1 for none

proc newTexture*(): GLuint =
  ## A new 2D texture, bound, sampled nearest and clamped.
  glGenTextures(1, addr result)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GLint(GL_NEAREST))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GLint(GL_CLAMP_TO_EDGE))
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GLint(GL_CLAMP_TO_EDGE))

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

proc buildProgram*(vertex, fragment, what: string): (GLuint, string) =
  ## The program of shaders `vertex` and `fragment`, and "", or 0 and why
  ## the driver rejects it (naming it `what`).
  let (vs, e1) = compile(GL_VERTEX_SHADER, vertex)
  if vs == 0: return (0'u32, "the " & what & " vertex shader: " & e1)
  let (fs, e2) = compile(GL_FRAGMENT_SHADER, fragment)
  if fs == 0:
    glDeleteShader(vs)
    return (0'u32, "the " & what & " fragment shader: " & e2)
  let program = glCreateProgram()
  glAttachShader(program, vs)
  glAttachShader(program, fs)
  glLinkProgram(program)
  glDeleteShader(vs)
  glDeleteShader(fs)
  var ok: GLint
  glGetProgramiv(program, GL_LINK_STATUS, addr ok)
  if ok == 0:
    var log = newString(1024)
    glGetProgramInfoLog(program, GLsizei(log.len), nil, log.cstring)
    glDeleteProgram(program)
    return (0'u32, "the " & what & " shader: " & log.strip(chars = {'\0', ' ', '\n'}))
  (program, "")

func marksOf(t: Tile; b: TileBlock; selected: openArray[bool]): seq[uint8] =
  ## The marks of block `b`'s rows: selected (`selected[row]`; a row past
  ## its end is not), drawn blank (killed, or dead in the file).
  result = newSeq[uint8](b.rows)
  for i in 0 ..< b.rows:
    let row = b.row + i
    if row < selected.len and selected[row]: result[i] = result[i] or SelectedMark
    if t.isBlank(row): result[i] = result[i] or KilledMark

proc upload*(t: Tile; maxSize: int): TileTextures =
  ## The GPU's copy of `t`, in blocks of at most `maxSize` texels a side
  ## (half that in time when the tile has an envelope, which takes two
  ## texels a column). Nothing is selected; its blank traces (killed, dead)
  ## are marked.
  result = TileTextures(id: t.id, selectionRevision: -1, hoverRevision: -1, hoverRow: -1)
  if t.request.count == 0 or t.columns == 0: return
  let envelope = t.hasEnvelope
  var last: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr last)
  for b in splitBlocks(t.request.count, t.columns, if envelope: maxSize div 2 else: maxSize):
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
    glPixelStorei(GL_UNPACK_ROW_LENGTH, GLint(t.columns))
    result.data.add newTexture()
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_R32F), GLsizei(b.cols), GLsizei(b.rows), 0,
      GL_RED, GL_FLOAT, unsafeAddr t.data[b.row * t.columns + b.col])
    result.bytes += b.rows * b.cols * sizeof(float32)
    if envelope:
      glPixelStorei(GL_UNPACK_ROW_LENGTH, GLint(2 * t.columns))
      result.envelope.add newTexture()
      glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_R32F), GLsizei(2 * b.cols), GLsizei(b.rows), 0,
        GL_RED, GL_FLOAT, unsafeAddr t.envelope[2 * (b.row * t.columns + b.col)])
      result.bytes += 2 * b.rows * b.cols * sizeof(float32)
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0)
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
    var marks = t.marksOf(b, [])
    result.marks.add newTexture()
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_R8), GLsizei(b.rows), 1, 0, GL_RED,
      GL_UNSIGNED_BYTE, addr marks[0])
    result.bytes += b.rows
    result.blocks.add b
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  glBindTexture(GL_TEXTURE_2D, GLuint(last))

proc setMarks*(tt: TileTextures; t: Tile; selected: openArray[bool]) =
  ## Marks the rows of tile `t` (whose GPU copy `tt` is) that are selected
  ## (`selected[row]`; a row past its end is not), and those killed.
  var last: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, addr last)
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
  for k, b in tt.blocks:
    var marks = t.marksOf(b, selected)
    glBindTexture(GL_TEXTURE_2D, tt.marks[k])
    glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_R8), GLsizei(b.rows), 1, 0, GL_RED,
      GL_UNSIGNED_BYTE, addr marks[0])
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4)
  glBindTexture(GL_TEXTURE_2D, GLuint(last))

proc free*(tt: var TileTextures) =
  ## Deletes the textures.
  for list in [addr tt.data, addr tt.envelope, addr tt.marks]:
    if list[].len > 0:
      glDeleteTextures(GLsizei(list[].len), addr list[][0])
    list[].setLen 0
  tt.blocks.setLen 0
  tt.bytes = 0
