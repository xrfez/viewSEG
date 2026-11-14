## The font loader on a real ImGui context (no window or GL needed): the
## bundled faces load, hold every icon the shell uses, and bad files fall back
## to the built-in font with a message instead of an ImGui assertion.

import std/[os, strutils]
import imguin/cimgui
import viewSEG/view/theme
import viewSEG/ui/imgui/[fonts, icons, messages]

const fontDir = currentSourcePath().parentDir.parentDir / "assets" / "fonts"

block fontChecks:
  let real = readFile(fontDir / DefaultFonts[frUi])
  doAssert looksLikeFont(real)
  doAssert not looksLikeFont("")
  doAssert not looksLikeFont("not a font at all, really")
  doAssert not looksLikeFont(real[0 ..< 2048]) # its tables lie beyond the end
  doAssert findFont(DefaultFonts[frMono], ["/nowhere", fontDir]) == fontDir / DefaultFonts[frMono]
  doAssert findFont(fontDir / DefaultFonts[frMono], []) == fontDir / DefaultFonts[frMono]
  doAssert findFont("missing.ttf", [fontDir]) == ""

block bundledFaces:
  let ctx = igCreateContext(nil)
  defer: igDestroyContext(ctx)
  var f: Fonts
  var log: Messages
  f.load(EverforestDark, [fontDir], log)
  doAssert log.items.len == 0, $log.items
  for role in FontRole:
    doAssert f.files[role] == fontDir / DefaultFonts[role], $role
    doAssert not f.faces[role].isNil
  doAssert f.faces[frUi] != f.faces[frMono] and f.faces[frUi] != f.faces[frHeading]
  doAssert igGetIO_Nil().FontDefault == f.faces[frUi]
  for icon in AllIcons:
    doAssert ImFont_IsGlyphInFont(f.faces[frUi], ImWchar(codepoint(icon))),
      "icon U+" & $codepoint(icon) & " is not in the UI font"
  # Loading the same theme again reuses the faces.
  let before = f.faces
  f.load(EverforestLight, [fontDir], log)
  doAssert f.faces == before and log.items.len == 0

block badFacesFallBack:
  let ctx = igCreateContext(nil)
  defer: igDestroyContext(ctx)
  let dir = getTempDir() / ("viewseg_tfonts_" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  writeFile(dir / "garbage.ttf", "garbage")
  var t = EverforestDark
  t.fonts = ["garbage.ttf", "missing.ttf", DefaultFonts[frHeading]]
  t.iconFont = "garbage.ttf"
  var f: Fonts
  var log: Messages
  f.load(t, [dir, fontDir], log)
  doAssert log.items.len == 1 and log.items[0].level == mlWarning, $log.items
  doAssert "garbage.ttf is not a TrueType" in log.items[0].text, log.items[0].text
  doAssert "`missing.ttf` not found" in log.items[0].text
  doAssert f.files[frUi] == "" and f.files[frMono] == ""   # the built-in font
  doAssert f.faces[frUi] == f.faces[frMono] and not f.faces[frUi].isNil
  doAssert f.files[frHeading] == fontDir / DefaultFonts[frHeading]
