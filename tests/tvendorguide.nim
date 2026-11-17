## The guide to writing a vendor header map that every `vendormaps` folder
## holds (`vendormaps/WRITING-A-MAP.md`, written by the program into the
## folders it makes and copied into a release) is parseSEG's own
## (`docs/design/vendor_maps.md`), word for word but for the example map, which
## is written with a made-up vendor here: it fails when parseSEG's guide moves
## on and the copy does not.
##
## Seen to fail: with a word changed in the copy outside its example,
## "the guide drifted from parseSEG's".
import std/[os, strutils]
import viewSEG/core/vendormaps

const Marker = "<!-- parseSEG's guide follows -->\n\n"

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
  # the one place the library's text gives a sample text outside its example: the
  # quoted text after "textual header substring, e.g. " is swapped for a made-up one
  var theirs = readFile(library)
  const Sample = "textual header substring, e.g. \""
  let at1 = theirs.find(Sample)
  doAssert at1 >= 0, "the library's text no longer has its sample text"
  let at2 = theirs.find('"', at1 + Sample.len)
  theirs = theirs[0 ..< at1 + Sample.len] & "VENDOR A" & theirs[at2 .. ^1]
  doAssert withoutExample(copy) == withoutExample(theirs),
    "the guide drifted from parseSEG's: copy vendormaps/WRITING-A-MAP.md again from " &
    "deps/parseSEG/docs/design/vendor_maps.md (its example rewritten with a made-up vendor)"

when isMainModule:
  main()
