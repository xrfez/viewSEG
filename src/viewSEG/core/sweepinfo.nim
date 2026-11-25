## What a list knows of a signature file without decoding a sample: a `.dat`'s header,
## position record and trailer (its first two blocks and its last, 1.5 KiB read), a `.vib`'s
## 47-byte header. Read through `fs`, so a drive that fails is the list's problem and not the
## UI thread's. A file the library refuses gives `SweepInfo.problem` in words.

import analysis, filesystem, sigdat, sigtypes, sigvib

const DatBlock = 512

proc readAt(f: File; path: string; at: int64; n: int; into: var seq[byte]) =
  ## `n` bytes of `f` from `at` (fewer at the end of the file) into `into`.
  into.setLen n
  if n > 0:
    f.setFilePos(at)
    into.setLen fs.readBuffer(f, path, addr into[0], n)

proc convertedSegy*(path: string): bool =
  ## Whether the SEG-Y file at `path` is laid out as the external converter writes a signature
  ## file: its first four traces coded 21, 19, 18, 20 (`isConverterLayout`). Reads the binary
  ## header and four trace headers (big-endian files, fixed trace length) and nothing else.
  ## Raises nothing: a file that cannot be read is not one.
  var f: File
  if not fs.open(f, path, fmRead): return false
  try:
    var head: seq[byte] = @[]
    f.readAt(path, 0, 3600, head)
    if head.len < 3600: return false
    func be16(b: openArray[byte]; at: int): int = int(b[at]) shl 8 or int(b[at + 1])
    let samples = be16(head, 3220)
    let bytes = case be16(head, 3224)
      of 1, 2, 4, 5, 10, 11: 4
      of 3: 2
      of 8: 1
      else: 0
    let ext = be16(head, 3504)
    if samples == 0 or bytes == 0 or ext < 0 or ext > 100: return false
    let first = 3600'i64 + 3200'i64 * ext
    let step = 240'i64 + int64(samples) * bytes
    var codes: seq[int16] = @[]
    var h: seq[byte] = @[]
    for k in 0 ..< 4:
      f.readAt(path, first + int64(k) * step, 240, h)
      if h.len < 240: return false
      codes.add int16(be16(h, 28))
    result = isConverterLayout(codes)
  except IOError, OSError:
    result = false
  finally:
    close(f)

proc readSweepInfo*(path: string; kind: SignatureKind; size: int64): SweepInfo =
  ## The `SweepInfo` of the signature file of `kind` at `path`, `size` bytes. Raises nothing:
  ## a file that cannot be read gives `problem`.
  result = SweepInfo(kind: kind)
  var f: File
  if not fs.open(f, path, fmRead):
    result.problem = "it cannot be read"
    return
  try:
    var first, last: seq[byte] = @[]
    case kind
    of sgDat:
      f.readAt(path, 0, int(min(size, 2 * DatBlock)), first)
      let lastAt = max(0'i64, size div DatBlock - 1) * DatBlock
      f.readAt(path, lastAt, int(min(DatBlock, size - lastAt)), last)
      if size >= DatBlock and last.len < DatBlock:
        result.problem = "it cannot be read"
      else:
        result = sigdat.sweepInfo(first, last, size)
    of sgVib:
      f.readAt(path, 0, int(min(size, 47)), first)
      result = sigvib.sweepInfo(first, size, path)
    of sgNone: discard
  except IOError, OSError:
    result.problem = "it cannot be read"
  finally:
    close(f)
