## The guide to writing a vendor header map that every `vendormaps` folder
## holds (`vendormaps/WRITING-A-MAP.md`, written by the program into the
## folders it makes and copied into a release) is parseSEG's own
## (`docs/design/vendor_maps.md`), word for word but for the example map, which
## is written with a made-up vendor here: it fails when parseSEG's guide moves
## on and the copy does not, and when the copy names a manufacturer.
##
## Seen to fail: with a word changed in the copy outside its example,
## "the guide drifted from parseSEG's"; with a manufacturer's name put in the
## copy's example, "the guide names a manufacturer".
import std/[os, strutils]
import viewSEG/core/vendormaps

const
  Marker = "<!-- parseSEG's guide follows -->\n\n"
  Manufacturers = ["inova", "sercel", "geospace", "geo space", "input/output", "wireless seismic",
    "geometrics", "stryde", "seismic instruments", "ion geophysical"]

proc withoutExample(text: string): string =
  ## `text` without its fenced example map (the block that starts with the NIF header).
  let i = text.find("```\n(.nif27)")
  doAssert i >= 0, "no example map"
  let j = text.find("```\n", i + 4)
  doAssert j > i
  text[0 ..< i] & text[j + 4 .. ^1]

proc main*() =
  let library = currentSourcePath().parentDir.parentDir / "deps" / "parseSEG" / "docs" /
    "design" / "vendor_maps.md"
  doAssert fileExists(library), "parseSEG's guide is not there: " & library
  let ours = VendorGuide
  let at = ours.find(Marker)
  doAssert at >= 0, "the copy lacks the line that says where parseSEG's guide begins"
  let copy = ours[at + Marker.len .. ^1]
  # the one place the library's text names a vendor outside its example: a sample text
  let theirs = readFile(library).replace("\"INOVA\"", "\"VENDOR A\"")
  doAssert withoutExample(copy) == withoutExample(theirs),
    "the guide drifted from parseSEG's: copy vendormaps/WRITING-A-MAP.md again from " &
    "deps/parseSEG/docs/design/vendor_maps.md (its example rewritten with a made-up vendor)"
  for name in Manufacturers:
    doAssert name notin ours.toLowerAscii, "the guide names a manufacturer: " & name

when isMainModule:
  main()
