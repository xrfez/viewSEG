## What the shots of the folder listed are made of (`core/shots`): each
## listed seismic file's records by FFID and source station (`FileShots`),
## and how they are kept beside the index cache (`cacheText`, `parseCache`).
## A module of its own so that the inbox can carry them.

import std/[strutils, times]
import parseSEG

export StationKey

const
  ShotCacheExt* = ".shots" ## the extension of a shot cache file
  ShotCacheHeader = "viewSEG shots 1"

type
  ShotOf* = object
    ## One record of a listed file: what tells its shot apart.
    gather*: int        ## its gather, as an open of the file numbers them
    record*: float64    ## its FFID; NaN when not known
    source*: StationKey ## its source station (`hasStation`)
    hasStation*: bool
    x*, y*: float64     ## its source's coordinates in the headers; NaN when none

  FileShots* = object
    ## The shots of one listed file.
    path*: string
    size*: int64
    modified*: Time
    shots*: seq[ShotOf]
    problem*: string ## why it could not be read; "" when it was

func num(x: float64): string =
  if x.isNaN: "nan" else: $x

func parseNum(s: string): float64 =
  if s == "nan": NaN else: parseFloat(s)

func cacheText*(f: FileShots): string =
  ## `f` as its shot cache file holds it: a header line, the file's size and
  ## time, then a line per record.
  result = ShotCacheHeader & "\n" & $f.size & " " & $f.modified.toUnix & " " &
    $f.modified.nanosecond & "\n"
  for s in f.shots:
    result.add $s.gather & " " & num(s.record) & " " & (if s.hasStation: num(s.source.line) &
      " " & num(s.source.point) & " " & $s.source.index else: "nan nan 0") & " " & num(s.x) &
      " " & num(s.y) & "\n"

func parseCache*(text, path: string): (bool, FileShots) =
  ## The shots a shot cache file's `text` holds for `path`; false when it is
  ## not one (another version, damaged).
  result[1] = FileShots(path: path)
  var lines = text.splitLines
  if lines.len < 2 or lines[0] != ShotCacheHeader: return
  try:
    let head = lines[1].splitWhitespace
    if head.len != 3: return
    result[1].size = parseBiggestInt(head[0])
    result[1].modified = initTime(parseBiggestInt(head[1]), parseInt(head[2]))
    for line in lines[2 .. ^1]:
      let p = line.splitWhitespace
      if p.len == 7:
        let (l, pt) = (parseNum(p[2]), parseNum(p[3]))
        var s = ShotOf(gather: parseInt(p[0]), record: parseNum(p[1]), x: parseNum(p[5]),
          y: parseNum(p[6]))
        if not (l.isNaN or pt.isNaN):
          (s.source, s.hasStation) = (stationKey(l, pt, int16(parseInt(p[4]))), true)
        result[1].shots.add s
      elif line.len > 0: return
    result[0] = true
  except ValueError:
    discard
