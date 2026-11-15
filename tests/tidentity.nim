## A file's identity (`core/identity`): XXH64 as published (its test
## vectors, and the same hash however the bytes are fed), and the quick
## identity and the full hash of files: the same for a renamed copy, the
## quick identity the same but the full hash not for a copy with one byte
## changed in the middle, both different for one changed in its first or
## last 64 KiB; a file shorter than 64 KiB, and an empty one; reading
## leaves the file's bytes and modification time as they were.
##
## Seen to fail: with the second lane's prime swapped for the first's in
## `initHasher` (`v2: P1`), the vector of 39 bytes is "7dab3ce2071fc62f",
## not "fbcea83c8a378bf1"; with the tail of a large file left out of `quickIdentity`, "a
## change in the last 64 KiB changes the quick identity".

import std/[os, times]
import viewSEG/core/[identity, filesystem]

block vectors:
  doAssert hex(xxh64("")) == "ef46db3751d8e999", hex(xxh64(""))
  doAssert hex(xxh64("a")) == "d24ec4f1a98c6e5b", hex(xxh64("a"))
  doAssert hex(xxh64("abc")) == "44bc2cf5ad770999", hex(xxh64("abc"))
  let long = "Nobody inspects the spammish repetition"
  doAssert hex(xxh64(long)) == "fbcea83c8a378bf1", hex(xxh64(long))

block pieces:
  var data = newString(10_000)
  for i, c in data.mpairs: c = char((i * 7919 + i div 13) and 255)
  let whole = xxh64(data)
  for piece in [1, 3, 7, 31, 32, 33, 64, 1000]:
    var h = initHasher()
    var i = 0
    while i < data.len:
      let n = min(piece, data.len - i)
      h.update(data.toOpenArrayByte(i, i + n - 1))
      i += n
    doAssert h.digest == whole, "fed " & $piece & " bytes at a time"

let dir = getTempDir() / "viewSEG-tidentity-" & $getCurrentProcessId()
createDir(dir)
try:
  proc make(name: string; size: int; change = -1): string =
    result = dir / name
    var s = newString(size)
    for i, c in s.mpairs: c = char((i * 31 + i shr 9) and 255)
    if change >= 0: s[change] = char(ord(s[change]) xor 1)
    writeFile(result, s)

  proc quick(path: string): FileIdentity =
    var t: Time
    quickIdentity(path, t)

  const size = 1_000_000
  let a = make("a.sgy", size)
  let before = (readFile(a), getLastModificationTime(a))
  let ida = quick(a)
  doAssert ida.size == size and not ida.fullKnown
  let fa = fullHash(a)
  doAssert (readFile(a), getLastModificationTime(a)) == before, "the file changed"
  block renamed:
    let b = dir / "renamed.sgy"
    copyFile(a, b)
    doAssert quick(b) == ida and fullHash(b) == fa
  block middle:
    let c = make("middle.sgy", size, change = size div 2)
    doAssert quick(c) == ida, "a change in the middle is not in the quick identity"
    doAssert fullHash(c) != fa, "a change in the middle changes the full hash"
  block ends:
    doAssert quick(make("first.sgy", size, change = 100)) != ida,
      "a change in the first 64 KiB changes the quick identity"
    doAssert quick(make("last.sgy", size, change = size - 100)) != ida,
      "a change in the last 64 KiB changes the quick identity"
  block small:
    let s = make("small.sgy", 1000)
    let ids = quick(s)
    doAssert ids.size == 1000 and ids.quick == xxh64(readFile(s))
    doAssert fullHash(s) == xxh64(readFile(s))
    let mid = make("mid.sgy", 100_000) # between one and two spans: each byte once
    doAssert quick(mid).quick == xxh64(readFile(mid))
    let empty = make("empty.sgy", 0)
    doAssert quick(empty).size == 0 and fullHash(empty) == xxh64("")
  block key:
    doAssert FileIdentity(size: 0x2000f, quick: 0xab).key == "2000f-00000000000000ab"
    doAssert FileIdentity(size: 0, quick: 1).key == "0-0000000000000001"
  block stops:
    var calls = 0
    doAssertRaises IOError:
      discard fullHash(a, proc (done, total: int64): bool =
        inc calls
        false)
    doAssert calls == 1
  block missing:
    doAssertRaises OSError: discard quick(dir / "not there.sgy")
finally:
  removeDir(dir)
echo "tidentity: ok"
