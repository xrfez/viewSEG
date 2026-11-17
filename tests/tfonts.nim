## The font loader on a real ImGui context (no window or GL needed): the
## bundled faces load, hold every icon the shell uses, and bad files fall back
## to the built-in font with a message instead of an ImGui assertion.

import std/[os, strutils]
import imguin/cimgui
import viewSEG/view/theme
import viewSEG/ui/imgui/[fonts, icons, messages]

const fontDir = currentSourcePath().parentDir.parentDir / "assets" / "fonts"

proc main*() =

  block fontChecks:
    let real = readFile(fontDir / DefaultFonts[frUi])
    doAssert looksLikeFont(real)
    doAssert not looksLikeFont("")
    doAssert not looksLikeFont("not a font at all, really")
    doAssert not looksLikeFont(real[0 ..< 2048]) # its tables lie beyond the end
    # A font collection: its first font's directory must hold up too.
    func be32(n: int): string =
      result = newString(4)
      for i in 0 .. 3: result[i] = char(n shr (8 * (3 - i)) and 0xff)
    let ttc = "ttcf\x00\x01\x00\x00" & be32(1)
    doAssert looksLikeFont(ttc & be32(16) & real)
    doAssert not looksLikeFont(ttc & be32(0x7ffffff0) & newString(400)) # beyond the end
    doAssert not looksLikeFont(ttc & be32(16) & newString(400)) # no directory there
    doAssert not looksLikeFont("ttcf\x00\x01\x00\x00" & be32(0) & be32(16) & real) # no fonts
    doAssert not looksLikeFont(real[0 ..< 100]) # ImGui asserts on 100 bytes or fewer
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
    # a collection header whose first font lies far beyond the end of the file:
    # ImGui would read out of bounds (it crashed before the collection check)
    writeFile(dir / "forged.ttc", "ttcf\x00\x01\x00\x00\x00\x00\x00\x01\x7f\xff\xff\xf0" &
      newString(400))
    var forged = EverforestDark
    forged.fonts[frHeading] = "forged.ttc"
    var ff: Fonts
    var flog: Messages
    ff.load(forged, [dir, fontDir], flog)
    doAssert flog.items.len == 1 and "forged.ttc is not a TrueType" in flog.items[0].text,
      $flog.items
    doAssert ff.files[frHeading] == "" and ff.files[frUi] == fontDir / DefaultFonts[frUi]
    var t = EverforestDark
    t.fonts = ["garbage.ttf", "missing.ttf", DefaultFonts[frHeading]]
    t.iconFont = "garbage.ttf"
    var f: Fonts
    var log: Messages
    f.load(t, [dir, fontDir], log)
    doAssert log.items.len == 1 and log.items[0].level == mlWarning, $log.items
    doAssert "garbage.ttf is not a TrueType" in log.items[0].text, log.items[0].text
    doAssert "`missing.ttf` not found" in log.items[0].text
    doAssert f.files[frUi] == "" and f.files[frMono] == "" # the built-in font
    doAssert f.faces[frUi] == f.faces[frMono] and not f.faces[frUi].isNil
    doAssert f.files[frHeading] == fontDir / DefaultFonts[frHeading]

when isMainModule:
  main()
