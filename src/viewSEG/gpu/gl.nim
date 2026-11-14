## The OpenGL 3.3 functions the GPU layer uses, loaded at run time through
## the frontend's own loader (`loadGl`), so that this layer needs no
## windowing library or GL binding package. Only the UI thread calls them,
## with the frontend's GL context current.

when defined(windows):
  {.pragma: glcall, stdcall, gcsafe, raises: [].}
else:
  {.pragma: glcall, cdecl, gcsafe, raises: [].}

type
  GLenum* = uint32
  GLuint* = uint32
  GLint* = int32
  GLsizei* = int32
  GLboolean* = uint8
  GLbitfield* = uint32
  GLsizeiptr* = int

  GetProcAddress* = proc (name: cstring): pointer {.cdecl, gcsafe, raises: [].}
    ## The frontend's GL loader (SDL's `SDL_GL_GetProcAddress`, say).

const
  GL_NO_ERROR* = 0'u32
  GL_TRIANGLES* = 0x0004'u32
  GL_COLOR_BUFFER_BIT* = 0x4000'u32
  GL_CULL_FACE* = 0x0B44'u32
  GL_DEPTH_TEST* = 0x0B71'u32
  GL_STENCIL_TEST* = 0x0B90'u32
  GL_VIEWPORT* = 0x0BA2'u32
  GL_BLEND* = 0x0BE2'u32
  GL_SCISSOR_TEST* = 0x0C11'u32
  GL_COLOR_CLEAR_VALUE* = 0x0C22'u32
  GL_UNPACK_ROW_LENGTH* = 0x0CF2'u32
  GL_UNPACK_ALIGNMENT* = 0x0CF5'u32
  GL_PACK_ALIGNMENT* = 0x0D05'u32
  GL_MAX_TEXTURE_SIZE* = 0x0D33'u32
  GL_TEXTURE_2D* = 0x0DE1'u32
  GL_UNSIGNED_BYTE* = 0x1401'u32
  GL_FLOAT* = 0x1406'u32
  GL_RED* = 0x1903'u32
  GL_RGBA* = 0x1908'u32
  GL_NEAREST* = 0x2600'u32
  GL_TEXTURE_MAG_FILTER* = 0x2800'u32
  GL_TEXTURE_MIN_FILTER* = 0x2801'u32
  GL_TEXTURE_WRAP_S* = 0x2802'u32
  GL_TEXTURE_WRAP_T* = 0x2803'u32
  GL_RGBA8* = 0x8058'u32
  GL_TEXTURE_BINDING_2D* = 0x8069'u32
  GL_CLAMP_TO_EDGE* = 0x812F'u32
  GL_R32F* = 0x822E'u32
  GL_TEXTURE0* = 0x84C0'u32
  GL_ACTIVE_TEXTURE* = 0x84E0'u32
  GL_VERTEX_ARRAY_BINDING* = 0x85B5'u32
  GL_ARRAY_BUFFER* = 0x8892'u32
  GL_ARRAY_BUFFER_BINDING* = 0x8894'u32
  GL_STREAM_DRAW* = 0x88E0'u32
  GL_FRAGMENT_SHADER* = 0x8B30'u32
  GL_VERTEX_SHADER* = 0x8B31'u32
  GL_COMPILE_STATUS* = 0x8B81'u32
  GL_LINK_STATUS* = 0x8B82'u32
  GL_INFO_LOG_LENGTH* = 0x8B84'u32
  GL_CURRENT_PROGRAM* = 0x8B8D'u32
  GL_DRAW_FRAMEBUFFER_BINDING* = 0x8CA6'u32
  GL_READ_FRAMEBUFFER* = 0x8CA8'u32
  GL_DRAW_FRAMEBUFFER* = 0x8CA9'u32
  GL_READ_FRAMEBUFFER_BINDING* = 0x8CAA'u32
  GL_FRAMEBUFFER_COMPLETE* = 0x8CD5'u32
  GL_COLOR_ATTACHMENT0* = 0x8CE0'u32
  GL_FRAMEBUFFER* = 0x8D40'u32

var
  glGetError*: proc (): GLenum {.glcall.}
  glGetIntegerv*: proc (pname: GLenum; data: ptr GLint) {.glcall.}
  glGetFloatv*: proc (pname: GLenum; data: ptr float32) {.glcall.}
  glIsEnabled*: proc (cap: GLenum): GLboolean {.glcall.}
  glEnable*: proc (cap: GLenum) {.glcall.}
  glDisable*: proc (cap: GLenum) {.glcall.}
  glViewport*: proc (x, y: GLint; w, h: GLsizei) {.glcall.}
  glClearColor*: proc (r, g, b, a: float32) {.glcall.}
  glClear*: proc (mask: GLbitfield) {.glcall.}
  glPixelStorei*: proc (pname: GLenum; param: GLint) {.glcall.}
  glReadPixels*: proc (x, y: GLint; w, h: GLsizei; format, kind: GLenum;
    pixels: pointer) {.glcall.}
  glGenTextures*: proc (n: GLsizei; textures: ptr GLuint) {.glcall.}
  glDeleteTextures*: proc (n: GLsizei; textures: ptr GLuint) {.glcall.}
  glBindTexture*: proc (target: GLenum; texture: GLuint) {.glcall.}
  glActiveTexture*: proc (texture: GLenum) {.glcall.}
  glTexParameteri*: proc (target, pname: GLenum; param: GLint) {.glcall.}
  glTexImage2D*: proc (target: GLenum; level, internalFormat: GLint; w, h: GLsizei;
    border: GLint; format, kind: GLenum; pixels: pointer) {.glcall.}
  glGenFramebuffers*: proc (n: GLsizei; ids: ptr GLuint) {.glcall.}
  glDeleteFramebuffers*: proc (n: GLsizei; ids: ptr GLuint) {.glcall.}
  glBindFramebuffer*: proc (target: GLenum; fb: GLuint) {.glcall.}
  glFramebufferTexture2D*: proc (target, attachment, textarget: GLenum; texture: GLuint;
    level: GLint) {.glcall.}
  glCheckFramebufferStatus*: proc (target: GLenum): GLenum {.glcall.}
  glCreateShader*: proc (kind: GLenum): GLuint {.glcall.}
  glShaderSource*: proc (shader: GLuint; count: GLsizei; source: ptr cstring;
    length: ptr GLint) {.glcall.}
  glCompileShader*: proc (shader: GLuint) {.glcall.}
  glGetShaderiv*: proc (shader: GLuint; pname: GLenum; params: ptr GLint) {.glcall.}
  glGetShaderInfoLog*: proc (shader: GLuint; size: GLsizei; length: ptr GLsizei;
    log: cstring) {.glcall.}
  glDeleteShader*: proc (shader: GLuint) {.glcall.}
  glCreateProgram*: proc (): GLuint {.glcall.}
  glAttachShader*: proc (program, shader: GLuint) {.glcall.}
  glLinkProgram*: proc (program: GLuint) {.glcall.}
  glGetProgramiv*: proc (program: GLuint; pname: GLenum; params: ptr GLint) {.glcall.}
  glGetProgramInfoLog*: proc (program: GLuint; size: GLsizei; length: ptr GLsizei;
    log: cstring) {.glcall.}
  glDeleteProgram*: proc (program: GLuint) {.glcall.}
  glUseProgram*: proc (program: GLuint) {.glcall.}
  glGetUniformLocation*: proc (program: GLuint; name: cstring): GLint {.glcall.}
  glUniform1i*: proc (location, v: GLint) {.glcall.}
  glUniform1f*: proc (location: GLint; v: float32) {.glcall.}
  glGenVertexArrays*: proc (n: GLsizei; ids: ptr GLuint) {.glcall.}
  glDeleteVertexArrays*: proc (n: GLsizei; ids: ptr GLuint) {.glcall.}
  glBindVertexArray*: proc (id: GLuint) {.glcall.}
  glGenBuffers*: proc (n: GLsizei; ids: ptr GLuint) {.glcall.}
  glDeleteBuffers*: proc (n: GLsizei; ids: ptr GLuint) {.glcall.}
  glBindBuffer*: proc (target: GLenum; buffer: GLuint) {.glcall.}
  glBufferData*: proc (target: GLenum; size: GLsizeiptr; data: pointer;
    usage: GLenum) {.glcall.}
  glVertexAttribPointer*: proc (index: GLuint; size: GLint; kind: GLenum;
    normalized: GLboolean; stride: GLsizei; offset: pointer) {.glcall.}
  glEnableVertexAttribArray*: proc (index: GLuint) {.glcall.}
  glDrawArrays*: proc (mode: GLenum; first: GLint; count: GLsizei) {.glcall.}

proc loadGl*(getProc: GetProcAddress): seq[string] =
  ## Loads the functions above; returns the names the driver did not give.
  template load(f: untyped) =
    let p = getProc(astToStr(f))
    if p == nil: result.add astToStr(f)
    else: f = cast[typeof(f)](p)
  load glGetError
  load glGetIntegerv
  load glGetFloatv
  load glIsEnabled
  load glEnable
  load glDisable
  load glViewport
  load glClearColor
  load glClear
  load glPixelStorei
  load glReadPixels
  load glGenTextures
  load glDeleteTextures
  load glBindTexture
  load glActiveTexture
  load glTexParameteri
  load glTexImage2D
  load glGenFramebuffers
  load glDeleteFramebuffers
  load glBindFramebuffer
  load glFramebufferTexture2D
  load glCheckFramebufferStatus
  load glCreateShader
  load glShaderSource
  load glCompileShader
  load glGetShaderiv
  load glGetShaderInfoLog
  load glDeleteShader
  load glCreateProgram
  load glAttachShader
  load glLinkProgram
  load glGetProgramiv
  load glGetProgramInfoLog
  load glDeleteProgram
  load glUseProgram
  load glGetUniformLocation
  load glUniform1i
  load glUniform1f
  load glGenVertexArrays
  load glDeleteVertexArrays
  load glBindVertexArray
  load glGenBuffers
  load glDeleteBuffers
  load glBindBuffer
  load glBufferData
  load glVertexAttribPointer
  load glEnableVertexAttribArray
  load glDrawArrays
