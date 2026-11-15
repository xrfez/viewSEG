## Pictures for agent control (`remote/tools`, the `screenshot` tool): a
## part of the frame just drawn, read back from the GL back buffer on the UI
## thread, and the PNG encoder (SDL's, in memory) agent control's server
## thread runs on it. Nothing is written to a file.

import sdl3_nim
import imguin/glad/gl
import ../../core/geometry

proc readRegion*(frameHeight: int; x, y, w, h: int): seq[Rgba] =
  ## The pixels of the rectangle at (`x`, `y`) (from the top-left corner),
  ## `w` by `h`, of the frame being drawn, row by row from the top, opaque.
  ## The caller keeps the rectangle inside the frame.
  var raw = newSeq[uint8](w * h * 4)
  if raw.len == 0: return
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(x.GLint, GLint(frameHeight - y - h), w.GLint, h.GLint, GL_RGBA,
    GL_UNSIGNED_BYTE, addr raw[0])
  result = newSeq[Rgba](w * h)
  for row in 0 ..< h:
    let src = (h - 1 - row) * w * 4 # GL rows start at the bottom
    for col in 0 ..< w:
      let i = src + 4 * col
      result[row * w + col] = Rgba(r: raw[i], g: raw[i + 1], b: raw[i + 2], a: 255)

proc encodePng*(pixels: openArray[Rgba]; w, h: int): (string, string) {.nimcall, gcsafe.} =
  ## `pixels` (`w` by `h`, rows from the top) as PNG bytes, in memory; or ""
  ## and why not. Any thread may call it (SDL: "can be called on different
  ## threads with different surfaces"); the surface only reads `pixels`.
  result = ("", "")
  if w <= 0 or h <= 0 or pixels.len != w * h:
    return ("", "the picture is empty")
  let surface = SDL_CreateSurfaceFrom(w.cint, h.cint, SDL_PIXELFORMAT_RGBA32,
    addr pixels[0], cint(w * 4))
  if surface.isNil: return ("", "SDL cannot make a surface: " & $SDL_GetError())
  let io = SDL_IOFromDynamicMem()
  if io.isNil:
    SDL_DestroySurface(surface)
    return ("", "SDL cannot make a memory stream: " & $SDL_GetError())
  if SDL_SavePNG_IO(surface, io, false):
    let size = int(SDL_TellIO(io))
    let mem = SDL_GetPointerProperty(SDL_GetIOProperties(io),
      SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER.cstring, nil)
    if mem != nil and size > 0:
      result[0] = newString(size)
      copyMem(addr result[0][0], mem, size)
    else:
      result[1] = "SDL wrote no PNG"
  else:
    result[1] = "SDL cannot encode the PNG: " & $SDL_GetError()
  discard SDL_CloseIO(io)
  SDL_DestroySurface(surface)
