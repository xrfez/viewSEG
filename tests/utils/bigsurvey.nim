## Surveys at the scale of a real 3D land survey, for benchmarks and for the
## tests that bound how the survey's cost grows: SPS 2.1 S, R and X files
## with the header records a contractor writes (datum, projection, US survey
## feet), and a SEG-Y file whose traces are a few of the survey's shots.
##
## At scale 1 the survey has 200 000 receivers (200 lines of 1000, 400 ft and
## 50 ft apart), 2 000 000 sources (1000 lines of 2000 running north across
## them, 50 ft and 40 ft apart) and, per shot, an X record for each of the
## 10 to 20 receiver lines nearest it (160 channels each, around the shot):
## about 30 million X records, 2.5 GB. A scale `f` keeps the spacing and the
## patch and takes `sqrt(f)` of each count of lines and points, so the
## sources and the X records grow as `f`. The files are written as cards
## directly, about 100 MB a second.
##
## ```nim
## let shape = bigSurveyShape(0.01)
## let files = writeBigSurvey(dir, shape)
## let segy = writeBigSegy(dir, shape, shots = 4)
## ```

import std/[math, os]
import parseSEG

type
  BigSurvey* = object
    ## The shape of a survey `writeBigSurvey` writes.
    scale*: float64
    rLines*, rPoints*: int ## receiver lines and the receivers on each
    sLines*, sPoints*: int ## source lines and the sources on each

  BigSurveyFiles* = tuple[s, r, x: string]

  Card = array[80, char]

const
  OriginX* = 1_800_000.0 ## easting of the first receiver of each line (US survey feet)
  OriginY* = 400_000.0   ## northing of the first receiver line
  RcvDx* = 50.0          ## receivers along a line
  RcvDy* = 400.0         ## receiver lines
  SrcDx* = 50.0          ## source lines
  SrcDy* = 40.0          ## sources along a line
  FirstRcvLine* = 1000   ## receiver lines 1000, 1001 ...
  FirstSrcLine* = 5000   ## source lines 5000, 5001 ...
  PatchChannels* = 160   ## receivers of a line a shot records
  PatchLines* = 10 .. 20 ## receiver lines a shot records
  Samples* = 250         ## samples of a trace of `writeBigSegy`
  Header = [
    "H00 SPS format version num.     SPS 2.1;",
    "H01 Description of survey area  ,Synthetic 3D;",
    "H02 Date of survey              N/A,N/A;",
    "H022Tape/disk identifier        viewSEG synthetic survey;",
    "H26 Date file written           2026-11-15 12:00:00;",
    "H04 Geophysical contractor      Synthetic;",
    "H07 Field computer system(s)    N/A;",
    "H12 Geodetic datum,-spheroid    NAD27 (CONUSClarke 1866  6378206.400 294.9786982",
    "H17 Vertical datum description  N/A;",
    "H18 Projection type             State Plane Coordinate System;",
    "H19 Projection zone             N/A;",
    "H20 Description of grid units   feet;",
    "H201Factor to meters            0.3048006096;",
    "H210Lat. of standard parallel(s)0390000.000N0401500.000N;",
    "H220Long. of central meridian   0793000.000W;",
    "H232Grid coord. at origin       00609601.22E 00000000.00N;",
    "H241Scale factor                1.0000000000;",
    "H400Type,Model,Polarity         1,N/A,N/A,N/A;",
    "H403Number of channels          1,3200;"]

func bigSurveyShape*(scale: float64): BigSurvey =
  ## The survey at `scale` (1: 200 000 receivers, 2 000 000 sources).
  let f = sqrt(scale)
  func count(n: int): int = max(1, int(round(float64(n) * f)))
  BigSurvey(scale: scale, rLines: max(PatchLines.b, count(200)), rPoints: count(1000),
    sLines: count(1000), sPoints: count(2000))

func receivers*(b: BigSurvey): int {.inline.} = b.rLines * b.rPoints
func sources*(b: BigSurvey): int {.inline.} = b.sLines * b.sPoints

func record*(b: BigSurvey; line, k: int): int64 {.inline.} =
  ## The field record of source `k` of source line `line` (both 0-based).
  int64(1 + line * b.sPoints + k)

func mix(z: uint64): uint64 =
  var v = z + 0x9E3779B97F4A7C15'u64
  v = (v xor (v shr 30)) * 0xBF58476D1CE4E5B9'u64
  v = (v xor (v shr 27)) * 0x94D049BB133111EB'u64
  v xor (v shr 31)

type Patch* = object
  ## The receivers a shot records: lines `lines`, on each the points
  ## `points` (0-based), channels numbered from 1 line by line.
  lines*, points*: Slice[int]

func patch*(b: BigSurvey; line, k: int): Patch =
  ## The patch of source `k` of source line `line`: 10 to 20 receiver lines
  ## (as the shot's number mixes) about the nearest one, `PatchChannels`
  ## receivers about the nearest on each, both cut at the survey's edges.
  let n = PatchLines.a + int(mix(uint64(b.record(line, k))) mod
    uint64(PatchLines.b - PatchLines.a + 1))
  let sx = SrcDx * float64(line) + SrcDx / 2
  let sy = SrcDy * float64(k)
  let nearLine = clamp(int(round(sy / RcvDy)), 0, b.rLines - 1)
  let nearPoint = clamp(int(round(sx / RcvDx)), 0, b.rPoints - 1)
  let l0 = clamp(nearLine - n div 2, 0, max(0, b.rLines - n))
  let p0 = clamp(nearPoint - PatchChannels div 2, 0, max(0, b.rPoints - PatchChannels))
  Patch(lines: l0 .. min(l0 + n, b.rLines) - 1,
    points: p0 .. min(p0 + PatchChannels, b.rPoints) - 1)

# ----------------------------------------------------------------- cards --

proc blank(c: var Card) {.inline.} =
  for i in 0 ..< c.len: c[i] = ' '

proc putInt(c: var Card; last: int; v: int64) =
  ## `v` right-aligned to column `last` (1-based).
  var x = abs(v)
  var at = last - 1
  while true:
    c[at] = char(ord('0') + int(x mod 10))
    x = x div 10
    dec at
    if x == 0: break
  if v < 0: c[at] = '-'

proc putFixed(c: var Card; last: int; v: float64; decimals: int) =
  ## `v` with `decimals` decimals, right-aligned to column `last`.
  let scaled = int64(round(abs(v) * float64(10 ^ decimals)))
  var x = scaled
  var at = last - 1
  for d in 0 ..< decimals:
    c[at] = char(ord('0') + int(x mod 10))
    x = x div 10
    dec at
  if decimals > 0:
    c[at] = '.'
    dec at
  while true:
    c[at] = char(ord('0') + int(x mod 10))
    x = x div 10
    dec at
    if x == 0: break
  if v < 0: c[at] = '-'

type CardWriter = object
  f: File
  buf: string

proc initCardWriter(path: string): CardWriter =
  result = CardWriter(f: open(path, fmWrite), buf: newStringOfCap(1 shl 20))
  for h in Header:
    var c: Card
    c.blank()
    for i, ch in h: c[i] = ch
    for ch in c: result.buf.add ch
    result.buf.add '\n'

proc add(w: var CardWriter; c: Card) {.inline.} =
  let at = w.buf.len
  w.buf.setLen at + 81
  copyMem(addr w.buf[at], addr c[0], 80)
  w.buf[at + 80] = '\n'
  if w.buf.len >= (1 shl 20) - 100:
    w.f.write w.buf
    w.buf.setLen 0

proc close(w: var CardWriter) =
  w.f.write w.buf
  w.f.close()

proc pointCard(kind: char; line, point: int; x, y, z: float64): Card =
  ## An SPS 2.1 point record: line (2-11) and point (12-21) as integers,
  ## index 1 (24), code (25-26), easting (47-55), northing (56-65),
  ## elevation (66-71).
  result.blank()
  result[0] = kind
  result.putInt(11, line)
  result.putInt(21, point)
  result[23] = '1'
  (result[24], result[25]) = (if kind == 'R': ('G', '1') else: ('E', '1'))
  result.putFixed(55, x, 1)
  result.putFixed(65, y, 1)
  result.putFixed(71, z, 1)

func elevation(x, y: float64): float64 = 1000 + 80 * sin(x / 7000) + 60 * cos(y / 5000)

func rcvXY*(j, p: int): (float64, float64) =
  ## Receiver `p` of receiver line `j` (0-based).
  (OriginX + RcvDx * float64(p) + 3 * sin(float64(p) / 40),
    OriginY + RcvDy * float64(j) + 2 * cos(float64(p) / 30))

func srcXY*(i, k: int): (float64, float64) =
  ## Source `k` of source line `i` (0-based).
  (OriginX + SrcDx * float64(i) + SrcDx / 2 + 2 * sin(float64(k) / 25),
    OriginY + SrcDy * float64(k))

proc writeBigSurvey*(dir: string; b: BigSurvey): BigSurveyFiles =
  ## Writes the S, R and X files of `b` into `dir` (`big-<scale>.s` ...),
  ## unless they are there.
  let base = dir / ("big-" & $b.scale)
  result = (base & ".s", base & ".r", base & ".x")
  if fileExists(result.x): return
  createDir(dir)
  var r = initCardWriter(result.r)
  for j in 0 ..< b.rLines:
    for p in 0 ..< b.rPoints:
      let (x, y) = rcvXY(j, p)
      r.add pointCard('R', FirstRcvLine + j, 1 + p, x, y, elevation(x, y))
  r.close()
  var s = initCardWriter(result.s)
  for i in 0 ..< b.sLines:
    for k in 0 ..< b.sPoints:
      let (x, y) = srcXY(i, k)
      s.add pointCard('S', FirstSrcLine + i, 1 + k, x, y, elevation(x, y))
  s.close()
  var x = initCardWriter(result.x & ".part")
  for i in 0 ..< b.sLines:
    for k in 0 ..< b.sPoints:
      let pt = b.patch(i, k)
      var channel = 1
      for j in pt.lines:
        # X, record (8-15), its increment (16), instrument (17), source line
        # (18-27), point (28-37) and index (38), channels (39-43, 44-48) and
        # their increment (49), receiver line (50-59), receivers (60-69,
        # 70-79) and index (80)
        var c: Card
        c.blank()
        c[0] = 'X'
        c.putInt(15, b.record(i, k))
        (c[15], c[16]) = ('1', '1')
        c.putInt(27, FirstSrcLine + i)
        c.putInt(37, 1 + k)
        c[37] = '1'
        c.putInt(43, channel)
        c.putInt(48, channel + pt.points.len - 1)
        c[48] = '1'
        c.putInt(59, FirstRcvLine + j)
        c.putInt(69, 1 + pt.points.a)
        c.putInt(79, 1 + pt.points.b)
        c[79] = '1'
        x.add c
        channel += pt.points.len
  x.close()
  moveFile(result.x & ".part", result.x)

func spreadShots*(b: BigSurvey; n: int): seq[(int, int)] =
  ## `n` shots (source line, source) spread over the survey.
  for s in 0 ..< n:
    let at = (s * 2 + 1) * b.sources div (2 * n)
    result.add (at div b.sPoints, at mod b.sPoints)

proc writeBigSegy*(dir: string; b: BigSurvey; shots = 4): string =
  ## A SEG-Y file of `shots` of `b`'s shots (`spreadShots`), a trace per
  ## channel of each, with its field record and channel only (no station,
  ## no coordinates): the join finds them through the X file. Unless it is
  ## there.
  result = dir / ("big-" & $b.scale & "-" & $shots & "shots.sgy")
  if fileExists(result): return
  createDir(dir)
  var w = openSeismicWriter(result & ".part", SegyOutputOptions(traceSorting: 1,
    measurementSystem: 2, text: @["C01 viewSEG synthetic survey: " & $shots & " shots"]))
  var buf = newSeq[float32](Samples)
  for (i, k) in b.spreadShots(shots):
    let pt = b.patch(i, k)
    let channels = pt.lines.len * pt.points.len
    for ch in 1 .. channels:
      var key = initTraceKeys()
      (key.record, key.channel) = (float64(b.record(i, k)), float64(ch))
      (key.t0Ms, key.intervalUs) = (0.0, 2000.0)
      for t in 0 ..< Samples:
        buf[t] = float32(sin(float64(t * ch) / 50) * exp(-float64(t) / 100))
      w.writeTrace(key, buf)
  let log = w.close()
  doAssert log.len == 0, $log
  moveFile(result & ".part", result)
