## What a list knows of a signature file without decoding a sample: a `.dat`'s header,
## position record and trailer (its first two blocks and its last, 1.5 KiB read), a `.vib`'s
## 47-byte header. Read through `fs`, so a drive that fails is the list's problem and not the
## UI thread's. A file the library refuses gives `SweepInfo.problem` in words.

import filesystem, sigdat, sigtypes, sigvib

const DatBlock = 512

proc readAt(f: File; path: string; at: int64; n: int; into: var seq[byte]) =
  ## `n` bytes of `f` from `at` (fewer at the end of the file) into `into`.
  into.setLen n
  if n > 0:
    f.setFilePos(at)
    into.setLen fs.readBuffer(f, path, addr into[0], n)

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
