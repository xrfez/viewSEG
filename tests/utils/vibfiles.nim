## Synthetic SEG-Y files of the shapes a vibrator's electronics write, for the
## tests of trace identification codes, roles taken from them and damaged
## files. Each call writes one file into the fixtures' folder (once) and
## returns its path. Every sample is a function of the trace and its index.
##
## - `vibFourSegy()`: SEG-Y rev 1, IEEE float, four traces of one record with
##   trace identification codes 21, 19, 18, 20 (reference, baseplate, reaction
##   mass, ground force); the last is `VibLoud` times larger.
## - `vibThirteenSegy()`: thirteen traces with codes 21, 19, 18, 20, 29, 28, 30,
##   33, 34, 35, 36, 1, 1; every field record number 0; the binary header claims
##   `VibClaimed` traces per ensemble.
## - `vibPlainSegy()`: four auxiliary traces with code 6 (sweep): no vibrator
##   codes.
## - `zeroBinarySegy()`: `vibPlainSegy`'s traces with the binary header's samples per
##   trace set to 0 (the trace headers give the length).
## - `variableSegy()`: rev 1, two traces of different lengths.
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
    claimed = 0) =
  var w = openSeismicWriter(path, SegyOutputOptions(revision: SegyRevision(major: 1, minor: 0),
    traceSorting: 1, measurementSystem: 1, text: @["C01 viewSEG test fixture: vibrator codes"]))
  var buf = newSeq[float32](VibSamples)
  for n, code in codes:
    for i in 0 ..< VibSamples: buf[i] = vibSample(n, i)
    if loud and n == codes.high:
      for i in 0 ..< VibSamples: buf[i] *= VibLoud
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (record, float64(n + 1), 0.0, VibDtMs * 1000)
    k.traceCode = code
    # the writer keeps a code only when the status agrees with it
    k.status = if code == 1: tsLive elif code in 18'i16 .. 21'i16 or code == 6: tsAuxiliary
               else: tsUnknown
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
  if not fileExists(result): writeVib(result, VibFourCodes, 1, true)

proc vibThirteenSegy*(fx: Fixtures): string =
  result = fx.dir / "vib-thirteen.sgy"
  if not fileExists(result): writeVib(result, VibThirteenCodes, 0, false, VibClaimed)

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
