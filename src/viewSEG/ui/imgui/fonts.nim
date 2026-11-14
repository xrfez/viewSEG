## The theme's fonts, through Dear ImGui 1.92's dynamic font atlas: a face is
## added once, with no size and no glyph ranges, and ImGui bakes each glyph on
## demand at whatever size it is drawn (the theme's size times the viewport's
## DPI scale), so text stays sharp on every monitor and nothing is rebuilt.
##
## Font files are looked up in each assets `fonts/` directory (or used as given
## when absolute). A face that is missing or unreadable falls back to ImGui's
## built-in font and says so in the Messages window: the program always starts.

import std/[os, strutils]
import imguin/cimgui
import ../../view/theme
import messages

type
  Fonts* = object
    ## The faces in use, by role; each is a loaded font or ImGui's built-in one.
    faces*: array[FontRole, ptr ImFont]
    files*: array[FontRole, string] ## the file of each face, "" for the built-in
    cache: seq[(string, ptr ImFont)] ## every face added to the atlas, by file
    builtin: ptr ImFont

func be16(s: string; at: int): int = s[at].int shl 8 or s[at + 1].int

func be32(s: string; at: int): int = be16(s, at) shl 16 or be16(s, at + 2)

func looksLikeFont*(data: string): bool =
  ## A TrueType / OpenType file whose table directory fits in `data` and has
  ## the tables a font needs; a font collection only needs its header. Checked
  ## before ImGui sees the bytes, whose own checks assert.
  result = false
  if data.len >= 12:
    let tag = data[0 ..< 4]
    if tag == "ttcf":
      result = data.len >= 16
    elif tag in ["\x00\x01\x00\x00", "true", "OTTO"]:
      let tables = be16(data, 4)
      if tables > 0 and 12 + 16 * tables <= data.len:
        var found = 0
        result = true
        for i in 0 ..< tables:
          let at = 12 + 16 * i
          let (name, offset, length) = (data[at ..< at + 4], be32(data, at + 8),
            be32(data, at + 12))
          if offset < 0 or length < 0 or offset + length > data.len:
            result = false
          if name in ["cmap", "head", "hhea", "hmtx"]:
            inc found
        result = result and found == 4

proc findFont*(name: string; fontDirs: openArray[string]): string =
  ## The path of font file `name`: itself when absolute, else the first
  ## `<dir>/<name>` that exists; "" when none does.
  result = ""
  if name.isAbsolute:
    if fileExists(name): result = name
  else:
    for d in fontDirs:
      if result.len == 0 and fileExists(d / name):
        result = d / name

proc addFace(atlas: ptr ImFontAtlas; data: string; mergeInto: ptr ImFont): ptr ImFont =
  ## Adds `data` (a checked font file) to the atlas, as a new face or merged
  ## into `mergeInto`; nil if ImGui rejects it. ImGui owns the copy it is given.
  let buf = igMemAlloc(data.len.csize_t)
  copyMem(buf, unsafeAddr data[0], data.len)
  let cfg = ImFontConfig_ImFontConfig()
  cfg.FontDataOwnedByAtlas = true
  cfg.MergeMode = not mergeInto.isNil
  cfg.DstFont = mergeInto
  let io = igGetIO_Nil()
  let asserts = io.ConfigErrorRecoveryEnableAssert
  io.ConfigErrorRecoveryEnableAssert = false # a bad font is logged, not fatal
  result = ImFontAtlas_AddFontFromMemoryTTF(atlas, buf, data.len.cint, 0, cfg, nil)
  io.ConfigErrorRecoveryEnableAssert = asserts
  ImFontConfig_destroy(cfg)

proc builtinFont(f: var Fonts): ptr ImFont =
  if f.builtin.isNil:
    f.builtin = ImFontAtlas_AddFontDefault(igGetIO_Nil().Fonts, nil)
  f.builtin

proc face(f: var Fonts; key: string): ptr ImFont =
  result = nil
  for (k, font) in f.cache:
    if k == key: result = font

proc loadFace(f: var Fonts; name, icons: string; fontDirs: openArray[string];
    problems: var seq[string]): (ptr ImFont, string) =
  ## The face for file `name` (with `icons` merged in when not ""), from the
  ## cache or the disk; the built-in font and a problem when it cannot be had.
  let path = findFont(name, fontDirs)
  let iconPath = if icons.len == 0: "" else: findFont(icons, fontDirs)
  let key = path & (if iconPath.len > 0: "+" & iconPath else: "")
  result = (f.face(key), path)
  if path.len == 0:
    problems.add "`" & name & "` not found"
    result = (f.builtinFont, "")
  elif result[0].isNil:
    var data = ""
    try:
      data = readFile(path)
    except IOError, OSError:
      problems.add path & " cannot be read (" & getCurrentExceptionMsg() & ")"
    if not looksLikeFont(data):
      if problems.len == 0 or path notin problems[^1]: # not already "cannot be read"
        problems.add path & " is not a TrueType or OpenType font"
      data = ""
    let atlas = igGetIO_Nil().Fonts
    let font = if data.len > 0: addFace(atlas, data, nil) else: nil
    if font.isNil:
      if data.len > 0:
        problems.add path & " was rejected by the font loader"
      result = (f.builtinFont, "")
    else:
      if icons.len > 0:
        var iconData = ""
        try:
          if iconPath.len > 0: iconData = readFile(iconPath)
        except IOError, OSError:
          discard
        if iconData.len == 0 or not looksLikeFont(iconData) or
            addFace(atlas, iconData, font).isNil:
          problems.add "icon font `" & icons & "` could not be merged"
      f.cache.add (key, font)
      result = (font, path)

proc load*(f: var Fonts; t: Theme; fontDirs: openArray[string]; log: var Messages) =
  ## Makes `t`'s fonts current, loading the ones not loaded yet, and sets the
  ## UI face as ImGui's default. Call between frames. Problems go to `log` as
  ## one warning; each missing face is replaced by the built-in font.
  var problems: seq[string]
  for role in FontRole:
    let icons = if role == frUi: t.iconFont else: ""
    (f.faces[role], f.files[role]) = f.loadFace(t.fonts[role], icons, fontDirs, problems)
  igGetIO_Nil().FontDefault = f.faces[frUi]
  if problems.len > 0:
    log.add "Fonts: " & problems.join("; ") & ". Using the built-in font instead" &
      (if fontDirs.len == 0: " (no assets folder found)."
       else: " (searched " & fontDirs.join(", ") & ")."), mlWarning

proc push*(f: Fonts; role: FontRole; size = 0'f32) =
  ## Draws with the `role` face from here to `pop`; `size` 0 keeps the current
  ## size (before the DPI scale).
  igPushFont(f.faces[role], size)

proc pop*(f: Fonts) =
  igPopFont()

template withFont*(f: Fonts; role: FontRole; size: float32; body: untyped) =
  f.push(role, size)
  try:
    body
  finally:
    f.pop()
