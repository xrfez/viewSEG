## A file's identity: what it holds, not where it is, so that what the
## viewer remembers about a file (its trace edits, `core/filememory`) finds
## it again when it is renamed or moved, and never on another file.
##
## - **Quick** (`quickIdentity`, at open, a few milliseconds): the file's
##   size and a hash of its first and last `QuickSpan` bytes (64 KiB each).
##   The first 64 KiB hold the file's header blocks (SEG-Y's text and binary
##   headers with the first extended text headers, SEG-D's general headers,
##   SEG-2's descriptor), so two files with one quick identity are almost
##   always the same data; a change in the middle of a trace does not show
##   in it.
## - **Full** (`fullHash`, on the background lane): a hash of every byte,
##   which confirms the quick identity or tells the files apart. Read in
##   1 MiB pieces with progress and a cancel between them.
##
## The hash is XXH64 (seed 0), written here so that it never changes with
## the compiler's own `hash`: an identity is kept on disk between versions.
## Every read goes through `fs` (`core/filesystem`), so a drive that does
## not answer holds the job's thread, never the UI's; nothing is written,
## and the file's bytes and modification time are left as they are.

import std/[strutils, times]
import filesystem

const
  QuickSpan* = 64 * 1024     ## bytes hashed at each end for the quick identity
  FullPiece = 1024 * 1024    ## bytes read at a time for the full hash
  P1 = 11400714785074694791'u64
  P2 = 14029467366897019727'u64
  P3 = 1609587929392839161'u64
  P4 = 9650029242287828579'u64
  P5 = 2870177450012600261'u64

type
  Hasher* = object
    ## XXH64, fed in pieces of any length (`update`), read with `digest`.
    v1, v2, v3, v4: uint64
    total: uint64
    buf: array[32, byte]
    used: int

  FileIdentity* = object
    ## What a file holds, by its size and hashes of its bytes.
    size*: int64        ## its size in bytes
    quick*: uint64      ## its first and last `QuickSpan` bytes' hash
    full*: uint64       ## every byte's hash, once `fullKnown`
    fullKnown*: bool

func rotl(x: uint64; r: int): uint64 {.inline.} = (x shl r) or (x shr (64 - r))

func round(acc, input: uint64): uint64 {.inline.} =
  rotl(acc + input * P2, 31) * P1

func merge(acc, v: uint64): uint64 {.inline.} =
  (acc xor round(0, v)) * P1 + P4

func word64(b: openArray[byte]; at: int): uint64 {.inline.} =
  for i in countdown(7, 0): result = (result shl 8) or uint64(b[at + i])

func word32(b: openArray[byte]; at: int): uint64 {.inline.} =
  for i in countdown(3, 0): result = (result shl 8) or uint64(b[at + i])

func initHasher*(): Hasher =
  ## A hasher with nothing fed yet (seed 0).
  Hasher(v1: P1 + P2, v2: P2, v3: 0, v4: 0'u64 - P1)

proc stripe(h: var Hasher; b: openArray[byte]; at: int) {.inline.} =
  h.v1 = round(h.v1, word64(b, at))
  h.v2 = round(h.v2, word64(b, at + 8))
  h.v3 = round(h.v3, word64(b, at + 16))
  h.v4 = round(h.v4, word64(b, at + 24))

proc update*(h: var Hasher; data: openArray[byte]) =
  ## Feeds `data`.
  h.total += uint64(data.len)
  var i = 0
  if h.used > 0:
    while h.used < 32 and i < data.len:
      h.buf[h.used] = data[i]
      inc h.used
      inc i
    if h.used < 32: return
    h.stripe(h.buf, 0)
    h.used = 0
  while i + 32 <= data.len:
    h.stripe(data, i)
    i += 32
  while i < data.len:
    h.buf[h.used] = data[i]
    inc h.used
    inc i

proc update*(h: var Hasher; data: string) =
  ## Feeds the bytes of `data`.
  h.update(data.toOpenArrayByte(0, data.high))

func digest*(h: Hasher): uint64 =
  ## The hash of everything fed so far.
  result = if h.total >= 32:
      var acc = rotl(h.v1, 1) + rotl(h.v2, 7) + rotl(h.v3, 12) + rotl(h.v4, 18)
      acc = acc.merge(h.v1)
      acc = acc.merge(h.v2)
      acc = acc.merge(h.v3)
      acc.merge(h.v4)
    else: h.v3 + P5
  result += h.total
  var i = 0
  while i + 8 <= h.used:
    result = rotl(result xor round(0, word64(h.buf, i)), 27) * P1 + P4
    i += 8
  if i + 4 <= h.used:
    result = rotl(result xor (word32(h.buf, i) * P1), 23) * P2 + P3
    i += 4
  while i < h.used:
    result = rotl(result xor (uint64(h.buf[i]) * P5), 11) * P1
    inc i
  result = (result xor (result shr 33)) * P2
  result = (result xor (result shr 29)) * P3
  result = result xor (result shr 32)

func xxh64*(data: openArray[byte]): uint64 =
  ## XXH64 of `data`, seed 0.
  var h = initHasher()
  h.update(data)
  h.digest

func xxh64*(data: string): uint64 =
  ## XXH64 of the bytes of `data`, seed 0.
  xxh64(data.toOpenArrayByte(0, data.high))

func hex*(x: uint64): string {.inline.} = toHex(x, 16).toLowerAscii
  ## `x` as 16 hexadecimal digits, lower case.

func key*(id: FileIdentity): string =
  ## The quick identity as a name: the size and the quick hash, in
  ## hexadecimal (`2000f-1a2b...`); the name of the file's documents starts
  ## with it.
  var size = toHex(id.size).toLowerAscii.strip(trailing = false, chars = {'0'})
  if size.len == 0: size = "0"
  size & "-" & hex(id.quick)

func sameData*(a, b: FileIdentity): bool =
  ## Whether `a` and `b` are the same data: the same quick identity, and
  ## the same full hash when both know it.
  a.size == b.size and a.quick == b.quick and
    (not a.fullKnown or not b.fullKnown or a.full == b.full)

proc readAt(f: File; path: string; at: int64; buf: var seq[byte]): int =
  f.setFilePos(at)
  if buf.len == 0: 0 else: fs.readBuffer(f, path, addr buf[0], buf.len)

proc quickIdentity*(path: string; modified: var Time): FileIdentity =
  ## The quick identity of the file at `path` (see the module's
  ## documentation), with its modification time as it was read. Raises
  ## `IOError` when it cannot be opened or read, `OSError` when it cannot
  ## be looked at.
  let info = fs.getFileInfo(path)
  modified = info.lastWriteTime
  result = FileIdentity(size: info.size)
  var f: File
  if not fs.open(f, path):
    raise newException(IOError, "it cannot be opened")
  try:
    var h = initHasher()
    var buf = newSeq[byte](int(min(info.size, QuickSpan)))
    let n = readAt(f, path, 0, buf)
    h.update(buf.toOpenArray(0, n - 1))
    if info.size > QuickSpan:
      let tail = min(info.size - QuickSpan, QuickSpan)
      buf.setLen int(tail)
      let m = readAt(f, path, info.size - tail, buf)
      h.update(buf.toOpenArray(0, m - 1))
    result.quick = h.digest
  finally:
    f.close()

proc fullHash*(path: string; progress: proc (done, total: int64): bool {.gcsafe.} = nil): uint64 =
  ## The hash of every byte of the file at `path`, read in 1 MiB pieces;
  ## `progress` is called after each piece, and a false from it stops the
  ## read with `IOError` ("stopped"). Raises `IOError` when the file cannot
  ## be opened or read.
  var f: File
  if not fs.open(f, path):
    raise newException(IOError, "it cannot be opened")
  try:
    var h = initHasher()
    var buf = newSeq[byte](FullPiece)
    var done = 0'i64
    let total = try: fs.getFileSize(path) except OSError: 0'i64
    while true:
      let n = fs.readBuffer(f, path, addr buf[0], buf.len)
      if n <= 0: break
      h.update(buf.toOpenArray(0, n - 1))
      done += n
      if progress != nil and not progress(done, total):
        raise newException(IOError, "stopped")
    result = h.digest
  finally:
    f.close()
