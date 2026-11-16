## What the Headers window's hex pane says of a field's bytes: the field's
## place in its block's dump (`dumpColumn`), and the bytes read every way a
## header could hold them (`byteReadings`): whole numbers big- and
## little-endian, signed and not, IEEE and IBM floats, BCD digits and text,
## through parseSEG's codecs, so that a value read wrongly (the wrong byte
## order, a format the file does not say) shows what it would be.

import std/[math, strutils]
import parseSEG
import parseSEG/codecs

type
  Reading* = tuple[label, value: string]
    ## A way to read the bytes, and what it reads.

func dumpColumn*(byteInLine: int): int =
  ## The character a byte starts at in a line of `dumpLine` (its offset's
  ## eight digits, two blanks, then three characters a byte and one more
  ## blank after the eighth).
  10 + 3 * byteInLine + (if byteInLine >= 8: 1 else: 0)

func number(x: float64): string =
  if x.isNaN: "NaN"
  elif x == round(x) and abs(x) < 1e15: $int64(x)
  else: $x

func textOf(b: openArray[byte]): string =
  for x in b: result.add (if x in 0x20'u8 .. 0x7E'u8: char(x) else: '.')

func nibbleOf(b: openArray[byte]; n: int): int =
  ## Nibble `n` of `b` (0: the high nibble of its first byte).
  int(if n mod 2 == 0: b[n div 2] shr 4 else: b[n div 2] and 0x0F)

func covers*(nibbleStart, nibbles, byteInField, half: int): bool =
  ## Whether the field that takes `nibbles` nibbles from nibble `nibbleStart`
  ## of its bytes (`nibbles` 0: whole bytes) takes nibble `half` (0 high, 1
  ## low) of its byte number `byteInField`.
  nibbles == 0 or 2 * byteInField + half in nibbleStart ..< nibbleStart + nibbles

proc nibbleReadings(b: openArray[byte]; start, count: int): seq[Reading] =
  ## What a field of `count` nibbles from nibble `start` of `b` reads, and
  ## only those nibbles: as hexadecimal, as BCD digits and as a number.
  result = @[]
  if count <= 0 or start < 0 or start + count > 2 * b.len: return
  var hex = ""
  var number = 0'u64
  for n in start ..< start + count:
    hex.add "0123456789ABCDEF"[nibbleOf(b, n)]
    if count <= 16: number = number shl 4 or uint64(nibbleOf(b, n))
  result.add ("Nibbles", hex & " (" & $count & (if count == 1: " nibble)" else: " nibbles)"))
  try:
    result.add ("BCD", $bcd(b, start, count))
  except CatchableError:
    result.add ("BCD", "not BCD (a nibble past 9)")
  if count <= 16: result.add ("Unsigned, binary", $number)
  result.add ("Bytes it touches", (block:
    var s = ""
    for x in b: s.add toHex(x) & ' '
    s.strip))
  result.add ("This machine", (if hostOrder == boLittle: "little-endian" else: "big-endian"))

proc byteReadings*(b: openArray[byte]; nibbleStart = 0; nibbles = 0): seq[Reading] =
  ## `b` (a field's 1 to 8 bytes) read each way that fits its size; none for
  ## another size. A field that takes some of its bytes' nibbles only
  ## (`nibbles` not 0, from nibble `nibbleStart`) is read as those nibbles,
  ## never the whole bytes. This machine's byte order is named last.
  result = @[]
  if nibbles > 0: return nibbleReadings(b, nibbleStart, nibbles)
  case b.len
  of 1:
    result.add ("Unsigned", $beU8(b, 0))
    result.add ("Signed", $beI8(b, 0))
  of 2:
    result.add ("Integer, big-endian", $beI16(b, 0))
    result.add ("Unsigned, big-endian", $beU16(b, 0))
    result.add ("Integer, little-endian", $cast[int16](swapBytes(beU16(b, 0))))
    result.add ("Unsigned, little-endian", $getNum[uint16](b, 0, boLittle))
  of 3:
    result.add ("Integer, big-endian", $beI24(b, 0))
    result.add ("Unsigned, big-endian", $beU24(b, 0))
    let p: ByteBuf = byteBuf(b)
    result.add ("Integer, little-endian", $(int(loadU24(p, 0, boLittle)) -
      (if (b[2] and 0x80) != 0: 1 shl 24 else: 0)))
    result.add ("Unsigned, little-endian", $loadU24(p, 0, boLittle))
  of 4:
    result.add ("Integer, big-endian", $beI32(b, 0))
    result.add ("Unsigned, big-endian", $beU32(b, 0))
    result.add ("Integer, little-endian", $getNum[int32](b, 0, boLittle))
    result.add ("IEEE float, big-endian", number(float64(beF32(b, 0))))
    result.add ("IEEE float, little-endian", number(float64(getNum[float32](b, 0, boLittle))))
    result.add ("IBM float", number(ibmToFloat64(beU32(b, 0))))
  of 8:
    result.add ("Integer, big-endian", $beI64(b, 0))
    result.add ("Unsigned, big-endian", $beU64(b, 0))
    result.add ("Integer, little-endian", $loadNum[int64](byteBuf(b), 0, boLittle))
    result.add ("IEEE float, big-endian", number(beF64(b, 0)))
    result.add ("IEEE float, little-endian", number(cast[float64](swapBytes(beU64(b, 0)))))
  else: return
  try:
    result.add ("BCD", $bcd(b, 0, 2 * b.len))
  except CatchableError:
    result.add ("BCD", "not BCD (a nibble past 9)")
  result.add ("Text", textOf(b))
  result.add ("Bytes", (block:
    var s = ""
    for x in b: s.add toHex(x) & ' '
    s.strip))
  result.add ("This machine", (if hostOrder == boLittle: "little-endian" else: "big-endian"))
