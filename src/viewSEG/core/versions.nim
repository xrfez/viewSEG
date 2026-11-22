## The versions of viewSEG and of the libraries it is built on, as Help >
## About and agent control give them: read from the packages' nimble files
## at compile time (parseSEG's own `PackageVersion`; processSEG's nimble
## file, found beside one of its modules), with the compiler's version and
## the build's mode. The toolkit's versions (Dear ImGui, SDL, OpenGL) are the
## frontend's to add (`aboutLines`'s `extra`).

import std/[macros, os, strutils]
import parseSEG
import ../authorship
from processSEG/pipeline import Pipeline

export authorship

type
  AboutLine* = tuple[name, version: string]
    ## A part of the program and its version.

proc nimbleVersionIn(dir, name: string): string {.compileTime.} =
  ## The version package `name`'s nimble file gives, found in `dir` or a
  ## folder above it; "unknown" when there is none. The paths are cut and
  ## joined by hand with "/": in a cross-build for Windows this runs on the
  ## build host, where `std/os` would turn them into the target's backslashes
  ## and find nothing.
  var d = dir.replace('\\', '/')
  for _ in 0 ..< 6:
    let path = d & "/" & name & ".nimble"
    if fileExists(path):
      for line in staticRead(path).splitLines:
        let parts = line.split('=', maxsplit = 1)
        if parts.len == 2 and parts[0].strip == "version":
          return parts[1].strip.strip(chars = {'"'})
    let cut = d.rfind('/')
    if cut <= 0:
      break
    d = d[0 ..< cut]
  "unknown"

macro sourceDirOf(sym: typed): string =
  ## The folder of the module that declares `sym`.
  newLit(sym.getImpl.lineInfoObj.filename.parentDir)

const
  ViewSEGVersion* = nimbleVersionIn(currentSourcePath().parentDir, "viewSEG")
    ## viewSEG's version, from viewSEG.nimble
  ParseSEGVersion* =
    if parseSEG.PackageVersion != "unknown": parseSEG.PackageVersion
    else: nimbleVersionIn(sourceDirOf(SeismicFile), "parseSEG")
    ## parseSEG's own `PackageVersion`; its nimble file read here when that cannot
    ## find it (a cross-build for Windows: its search joins paths with the target's `\`)
  ProcessSEGVersion* = nimbleVersionIn(sourceDirOf(Pipeline), "processSEG")
    ## processSEG's version, from its nimble file
  BuildMode* = when defined(danger): "danger" elif defined(release): "release" else: "debug"
    ## how the program was compiled

func aboutLines*(extra: openArray[AboutLine] = []): seq[AboutLine] =
  ## viewSEG, the libraries, `extra` (the frontend's toolkit), the
  ## compiler and the build, in that order.
  result = @[("viewSEG", ViewSEGVersion), ("parseSEG", ParseSEGVersion),
    ("processSEG", ProcessSEGVersion)]
  result.add extra
  result.add ("Nim", NimVersion)
  result.add ("Build", BuildMode & ", " & hostOS & " " & hostCPU)

func aboutText*(lines: openArray[AboutLine]): string =
  ## The lines as text, as Copy puts them on the clipboard.
  for l in lines: result.add l.name & '\t' & l.version & '\n'
