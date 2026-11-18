## Synthetic SEG-Y files of the shapes a vibrator's electronics write, for the
## tests of trace identification codes, roles taken from them and damaged
## files. Each call writes one file into the fixtures' folder (once) and
## returns its path. Every sample is a function of the trace and its index.
##
## - `vibFourSegy()`: SEG-Y rev 1, IEEE float, four traces of one record with
##   trace identification codes 21, 19, 18, 20 (reference, baseplate, reaction
##   mass, ground force); the last is `VibLoud` times larger. Coordinates on all
##   four, which are auxiliary.
## - `vibFourAgainSegy()`: a second file of that layout; `vibOtherFourSegy()`: four
##   traces with codes 21, 18, 19, 20.
## - `vibLongSegy()`: the four codes, then twenty seismic traces.
## - `vibThirteenSegy()`: thirteen traces with codes 21, 19, 18, 20, 29, 28, 30,
##   33, 34, 35, 36, 1, 1; every field record number 0; the binary header claims
##   `VibClaimed` traces per ensemble. Coordinates on traces 10 to 12 only.
## - `vibZeroTailSegy()`: the four codes, field record 7 on three traces and 0 on the last.
## - `vibPlainSegy()`: four auxiliary traces with code 6 (sweep): no vibrator
##   codes.
## - `zeroBinarySegy()`: `vibPlainSegy`'s traces with the binary header's samples per
##   trace set to 0 (the trace headers give the length).
## - `variableSegy()`: rev 1, two traces of different lengths.
## - `headersOnlySegy()`, `emptyFirstSegy()`, `laterEmptySegy()`: files of 0-sample traces
##   that are not damaged.
## - `damagedSegy()`: binary header with 0 samples, a first trace header with 0
##   samples, then bytes that are not trace headers.

import std/[math, os]
import parseSEG
import fixtures

const
  VibSamples* = 1500 ## samples per trace
  VibDtMs* = 2.0
  VibLoud* = 1e4     ## how much larger the last trace of `vibFourSegy` is
  VibClaimed* = 6    ## traces per ensemble the thirteen-trace file's binary header claims
  VibFourCodes* = [21'i16, 19, 18, 20]
  VibThirteenCodes* = [21'i16, 19, 18, 20, 29, 28, 30, 33, 34, 35, 36, 1, 1]

func vibSample*(trace, i: int): float32 =
  ## A sweep from 10 to 200 Hz, its amplitude and phase set by the trace.
  let t = float64(i) * VibDtMs / 1000
  let sweepS = float64(VibSamples) * VibDtMs / 1000
  let phase = 2 * PI * (10 * t + 0.5 * (190 / sweepS) * t * t)
  float32((1.0 + 0.25 * float64(trace)) * sin(phase + 0.1 * float64(trace)))

proc writeVib(path: string; codes: openArray[int16]; record: float64; loud: bool;
    claimed = 0; located: set[0 .. 15] = {}; zeroFrom = 99; major = 1'u8; shotTime = 0.0) =
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(major: major, minor: 0),
    traceSorting: 1, measurementSystem: 1, text: @["C01 viewSEG test fixture: vibrator codes"]))
  var buf = newSeq[float32](VibSamples)
  for n, code in codes:
    for i in 0 ..< VibSamples: buf[i] = vibSample(n, i)
    if loud and n == codes.high:
      for i in 0 ..< VibSamples: buf[i] *= VibLoud
    var k = initTraceKeys()
    let number = if n >= zeroFrom: 0.0 else: record
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (number, float64(n + 1), 0.0,
      VibDtMs * 1000)
    k.traceCode = code
    if shotTime != 0: k.time = shotTime
    # the writer keeps a code only when the status agrees with it
    k.status = if code == 1 or code in 11'i16 .. 17'i16 or
        (major >= 2 and code in 27'i16 .. 41'i16): tsLive elif code in 18'i16 .. 21'i16 or
        code == 6: tsAuxiliary
               else: tsUnknown
    if n <= 15 and n in located:
      (k.srcX, k.srcY, k.rcvX, k.rcvY) = (500_000.0 + float64(n), 6_000_000.0 + float64(n),
        500_100.0 + float64(n), 6_000_100.0 + float64(n))
    w.writeTrace(k, buf)
  let log = w.close()
  doAssert log.len == 0, $log
  if claimed > 0:
    var f = open(path, fmReadWriteExisting)
    f.setFilePos(3212)
    let declared = [uint8(claimed shr 8), uint8(claimed and 0xff)]
    doAssert f.writeBytes(declared, 0, 2) == 2
    f.close()

proc vibFourSegy*(fx: Fixtures): string =
  result = fx.dir / "vib-four.sgy"
  if not fileExists(result): writeVib(result, VibFourCodes, 1, true, located = {0, 1, 2, 3})

proc vibFourAgainSegy*(fx: Fixtures): string =
  ## Another file of `vibFourSegy`'s layout (four traces, codes 21, 19, 18, 20).
  result = fx.dir / "vib-four-again.sgy"
  if not fileExists(result): writeVib(result, VibFourCodes, 2, true)

proc vibOtherFourSegy*(fx: Fixtures): string =
  ## Four traces with codes 21, 18, 19, 20: a layout of its own.
  result = fx.dir / "vib-other-four.sgy"
  if not fileExists(result): writeVib(result, [21'i16, 18, 19, 20], 3, false)

proc sensorsSegy*(fx: Fixtures): string =
  ## Three traces with the multicomponent sensor codes 12, 13, 14 (vertical, cross-line,
  ## in-line): real components.
  result = fx.dir / "sensors.sgy"
  if not fileExists(result): writeVib(result, [12'i16, 13, 14], 4, false)

proc rev2FieldsSegy*(fx: Fixtures): string =
  ## SEG-Y rev 2: three traces with codes 28, 29, 30 (electric field components there).
  result = fx.dir / "rev2-fields.sgy"
  if not fileExists(result): writeVib(result, [28'i16, 29, 30], 5, false, major = 2)

proc vibLongSegy*(fx: Fixtures): string =
  ## One record: codes 21, 19, 18, 20, then twenty seismic traces (code 1).
  result = fx.dir / "vib-long.sgy"
  if not fileExists(result):
    var codes = @[21'i16, 19, 18, 20]
    for i in 0 ..< 20: codes.add 1
    writeVib(result, codes, 6, false)

proc vibThirteenSegy*(fx: Fixtures): string =
  result = fx.dir / "vib-thirteen.sgy"
  if not fileExists(result): writeVib(result, VibThirteenCodes, 0, false, VibClaimed, located = {9, 10, 11})

proc vibZeroTailSegy*(fx: Fixtures): string =
  ## `vibFourSegy`'s codes, field record number 7 on the first three traces and 0 on
  ## the last (the ground force).
  result = fx.dir / "vib-zero-tail.sgy"
  if not fileExists(result): writeVib(result, VibFourCodes, 7, false, zeroFrom = 3)

proc vibZeroSeismicSegy*(fx: Fixtures): string =
  ## Five seismic traces: record 7 on three, 0 on the last two; no shot time.
  result = fx.dir / "zero-seismic.sgy"
  if not fileExists(result): writeVib(result, [1'i16, 1, 1, 1, 1], 7, false, zeroFrom = 3)

proc vibZeroTimedSegy*(fx: Fixtures): string =
  ## Three auxiliary traces of record 7, then two seismic traces of record 0, all with
  ## the same shot time.
  result = fx.dir / "zero-timed.sgy"
  if not fileExists(result):
    writeVib(result, [21'i16, 19, 18, 1, 1], 7, false, zeroFrom = 3, shotTime = 1_700_000_000.0)

proc vibPlainSegy*(fx: Fixtures): string =
  result = fx.dir / "vib-plain.sgy"
  if not fileExists(result): writeVib(result, [6'i16, 6, 6, 6], 1, false)

proc damagedSegy*(fx: Fixtures): string =
  ## 3600 header bytes with 0 samples (and the format, interval and revision
  ## of a real file), a 240-byte trace header with 0 samples, and 60 000
  ## pseudo-random bytes.
  result = fx.dir / "damaged.sgy"
  if fileExists(result): return
  var bytes = newSeq[byte](3600 + 240 + 60_000)
  for card in 0 ..< 40: # an ASCII textual header
    let text = "C" & (if card < 9: "0" else: "") & $(card + 1) & " viewSEG test fixture: damaged"
    for i, c in text: bytes[card * 80 + i] = byte(c)
    for i in text.len ..< 80: bytes[card * 80 + i] = byte(' ')
  bytes[3224] = 0 # format 5 (bytes 3225-3226)
  bytes[3225] = 5
  bytes[3216] = 0x07 # interval 2000 us (bytes 3217-3218)
  bytes[3217] = 0xD0
  bytes[3500] = 1 # revision 1.0
  var x = 12345'u32
  for i in 3600 + 240 ..< bytes.len:
    x = x * 1664525'u32 + 1013904223'u32
    bytes[i] = byte(x shr 24)
  var f = open(result, fmWrite)
  doAssert f.writeBytes(bytes, 0, bytes.len) == bytes.len
  f.close()

proc zeroBinarySegy*(fx: Fixtures): string =
  result = fx.dir / "zero-binary.sgy"
  if fileExists(result): return
  writeVib(result, [6'i16, 6, 6, 6], 1, false)
  var f = open(result, fmReadWriteExisting)
  f.setFilePos(3220) # bytes 3221-3222, big-endian
  let zero = [0'u8, 0]
  doAssert f.writeBytes(zero, 0, 2) == 2
  f.close()

proc variableSegy*(fx: Fixtures): string =
  result = fx.dir / "variable.sgy"
  if fileExists(result): return
  var w = openSeismicWriter(result, SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0),
    traceSorting: 1, text: @["C01 viewSEG test fixture: variable-length traces"]))
  for n, samples in [100, 150, 120]:
    var buf = newSeq[float32](samples)
    for i in 0 ..< samples: buf[i] = vibSample(n, i)
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs, k.status) = (1.0, float64(n + 1), 0.0,
      VibDtMs * 1000, tsLive)
    w.writeTrace(k, buf)
  discard w.close() # a variable-length file may say so in its log

proc putBe(bytes: var seq[byte]; at, value, width: int) =
  for i in 0 ..< width: bytes[at + i] = byte((value shr (8 * (width - 1 - i))) and 0xff)

proc writeLengths(path: string; lengths: openArray[int]; fixedBinary: int) =
  ## A rev 1 file written by hand: traces of `lengths` samples (IEEE float); the binary header
  ## says `fixedBinary` samples per trace (0: variable). The writer refuses 0-sample traces.
  var total = 3600
  for n in lengths: total += 240 + 4 * n
  var bytes = newSeq[byte](total)
  for card in 0 ..< 40: # an ASCII textual header
    let text = "C" & (if card < 9: "0" else: "") & $(card + 1) & " viewSEG test fixture"
    for i in 0 ..< 80: bytes[card * 80 + i] = if i < text.len: byte(text[i]) else: byte(' ')
  bytes.putBe(3216, 2000, 2) # interval, us
  bytes.putBe(3220, fixedBinary, 2)
  bytes.putBe(3224, 5, 2) # IEEE float
  bytes.putBe(3500, 1, 1) # revision 1.0
  var at = 3600
  for n, samples in lengths:
    bytes.putBe(at, n + 1, 4) # trace sequence number within the line
    bytes.putBe(at + 8, 1, 4) # field record number
    bytes.putBe(at + 114, samples, 2)
    bytes.putBe(at + 116, 2000, 2)
    at += 240 + 4 * samples
  var f = open(path, fmWrite)
  doAssert f.writeBytes(bytes, 0, bytes.len) == bytes.len
  f.close()

proc headersOnlySegy*(fx: Fixtures): string =
  ## Four traces of 0 samples (a geometry export): the binary header says 0 too.
  result = fx.dir / "headers-only.sgy"
  if not fileExists(result): writeLengths(result, [0, 0, 0, 0], 0)

proc emptyFirstSegy*(fx: Fixtures): string =
  ## Variable length: a first trace of 0 samples, then traces of 100 and 120.
  result = fx.dir / "empty-first.sgy"
  if not fileExists(result): writeLengths(result, [0, 100, 120], 0)

proc laterEmptySegy*(fx: Fixtures): string =
  ## Binary header 0: a first trace of 100 samples, then two of 0 (the Headers window says
  ## so, the reader notes it).
  result = fx.dir / "later-empty.sgy"
  if not fileExists(result): writeLengths(result, [100, 0, 0], 0)
