## The survey as imported into a project (`survey/survey.bin`): what parseSEG
## read from each survey file, kept so that the survey files are read once in
## the project's life. Opening the project reads this file instead of the
## text: the map's layers and the joins' geometry are made from it.
##
## What is kept is what the files say, not what the import's options made of
## it: the line and point fields as text beside their numbers, so the line
## names and trailing digits can change without a new read. Per file:
##
## - SPS: its header records (H), its point records (R, S), its relation
##   records (X, O), in parts of at most `PartRecords` records;
## - SEG P1: its logical files' shotpoint records;
## - a CSV table: its text.
##
## **The format** (`StoreFormat` 1), little-endian: a 16-byte magic, the
## format as a 32-bit number, then blocks, each a kind (1 byte), a count
## (32 bits) and its payload's size (64 bits) before the payload; the last
## block is `bkEnd`, followed by an XXH64 hash of every byte before the hash.
## A string is its size (32 bits) and its bytes. A file whose hash does not
## match, or that ends early, is never used: `readStore` raises before it
## hands anything over.
##
## **Writing** goes to `survey.bin.<process id>.tmp` beside it, flushed, then
## renamed over it, so a crash leaves the old file or the new one. Everything
## here runs on a job; every file call goes through `fs`.

import std/[os, strutils, times]
when defined(posix):
  from std/posix import fsync
import parseSEG
import filejobs, filekinds, filesystem, identity, jobs, join, project

const
  StoreMagic* = "viewSEG survey\0\0"
  StoreFormat* = 1
  PartRecords* = 65_536 ## records of one kind in a block, at most
  SpsChunk = 4 * 1024 * 1024
  MaxStoreString = 64 * 1024 * 1024
  MaxBlockBytes = 1024'i64 * 1024 * 1024
  # The least a record takes in format 1 (its fields as the writer puts them,
  # a name as its length word and text): a count read from a block is
  # checked against them before anything is sized by it.
  PointMinBytes = 1 + 4 + 4 + 8 + 8 + 4 + 8 + 8 + 8
  RelationMinBytes = 1 + 4 + 8 + 4 + 1 + 4 + 4 + 8 + 8 + 4 + 8 + 8 + 4 + 4 + 4 + 4 + 8 + 8 + 8 + 4
  P1MinBytes = 4 + 4 + 8 + 1 + 8 + 8 + 8

static: doAssert cpuEndian == littleEndian, "survey.bin is written little-endian"

type
  BlockKind = enum
    bkNone = 0, bkFile = 1, bkHeaders = 2, bkPoints = 3, bkRelations = 4, bkP1 = 5,
    bkCsv = 6, bkEnd = 255

  StoredFile* = object
    ## One survey file as the store keeps it.
    copy*: string       ## the copy's path, relative to the project folder
    name*: string       ## its file name
    kind*: JoinFileKind
    fileKind*: FileKind ## as told from its first bytes
    role*: CsvRole
    size*: int64        ## the copy's size and modification time when read
    modified*: Time

  StoreReader* = object
    ## What `readStore` hands over, file by file (each callback may be nil).
    onFile*: proc (f: StoredFile) {.closure.}
    onSps*: proc (f: StoredFile; part: SpsFile) {.closure.}
      ## a part of an SPS file: its headers with every part, its records in order
    onP1*: proc (f: StoredFile; p1: P1File) {.closure.}
    onCsv*: proc (f: StoredFile; text: string) {.closure.}
    onEnd*: proc (f: StoredFile) {.closure.}

  Writer = object
    f: File
    path: string
    h: Hasher
    bytes: int64
    buf: string

# ----------------------------------------------------------------- writing --

proc raw[T](s: var string; x: T) {.inline.} =
  let at = s.len
  s.setLen at + sizeof(T)
  copyMem(addr s[at], addr x, sizeof(T))

proc str(s: var string; x: string) =
  s.raw uint32(x.len)
  s.add x

proc emit(w: var Writer; data: string) =
  if data.len == 0: return
  w.h.update data
  w.bytes += data.len
  if fs.writeBuffer(w.f, w.path, unsafeAddr data[0], data.len) != data.len:
    raise newException(IOError, "the disk did not take " & w.path.extractFilename &
      " (is it full?)")

proc flushBlock(w: var Writer; kind: BlockKind; count: int) =
  var head = newStringOfCap(13)
  head.raw uint8(ord(kind))
  head.raw uint32(count)
  head.raw int64(w.buf.len)
  w.emit head
  w.emit w.buf
  w.buf.setLen 0

proc fileBlock(w: var Writer; f: StoredFile; domain: RelationDomain; revision: SpsRevision) =
  w.buf.str f.copy
  w.buf.str f.name
  w.buf.raw uint8(ord(f.kind))
  w.buf.raw uint8(ord(f.fileKind))
  w.buf.raw uint8(ord(f.role))
  w.buf.raw uint8(ord(domain))
  w.buf.raw uint8(ord(revision))
  w.buf.raw f.size
  w.buf.raw f.modified.toUnix
  w.buf.raw int32(f.modified.nanosecond)
  w.flushBlock(bkFile, 1)

proc headersBlock(w: var Writer; headers: openArray[SpsHeader]) =
  for h in headers:
    w.buf.str h.code
    w.buf.str h.description
    w.buf.str h.data
  w.flushBlock(bkHeaders, headers.len)

proc pointsBlock(w: var Writer; points: openArray[SpsPoint]) =
  for p in points:
    w.buf.raw uint8(ord(p.kind))
    w.buf.str p.lineName
    w.buf.str p.pointName
    w.buf.raw p.line
    w.buf.raw p.point
    w.buf.raw int32(p.index)
    w.buf.raw p.easting
    w.buf.raw p.northing
    w.buf.raw p.elevation
  w.flushBlock(bkPoints, points.len)

proc relationsBlock(w: var Writer; rel: openArray[SpsRelation]) =
  for r in rel:
    w.buf.raw r.recordType
    w.buf.str r.fieldTape
    w.buf.raw r.fieldRecord
    w.buf.raw int32(r.recordIncrement)
    w.buf.raw r.instrumentCode
    w.buf.str r.srcLineName
    w.buf.str r.srcPointName
    w.buf.raw r.srcLine
    w.buf.raw r.srcPoint
    w.buf.raw int32(r.srcIndex)
    w.buf.raw r.fromChannel
    w.buf.raw r.toChannel
    w.buf.raw int32(r.channelIncrement)
    w.buf.str r.rcvLineName
    w.buf.str r.fromReceiverName
    w.buf.str r.toReceiverName
    w.buf.raw r.rcvLine
    w.buf.raw r.fromReceiver
    w.buf.raw r.toReceiver
    w.buf.raw int32(r.rcvIndex)
  w.flushBlock(bkRelations, rel.len)

proc p1Block(w: var Writer; lf: PLogicalFile) =
  w.buf.raw uint8(ord(lf.format))
  var n = 0
  for r in lf.records:
    if r.lineName.len > 0 or not r.point.isNaN: inc n
  w.buf.raw uint32(n)
  for r in lf.records:
    if r.lineName.len > 0 or not r.point.isNaN:
      w.buf.str r.lineName
      w.buf.str r.pointName
      w.buf.raw r.point
      w.buf.raw r.reshoot
      w.buf.raw r.easting
      w.buf.raw r.northing
      w.buf.raw r.depthOrElevation
  w.flushBlock(bkP1, n)

func cutAt(text: string; layout: TextLayout): int =
  ## Where a chunk of an SPS file is cut: after its last line end (a whole
  ## number of 80-byte cards for fixed cards).
  if layout in {tlFixed80, tlEbcdic80}: return text.len - text.len mod 80
  result = text.rfind('\n')
  if result < 0: result = text.rfind('\r')
  result = if result < 0: text.len else: result + 1

proc eachSpsChunk*(path: string; ctx: JobContext; done: var int64; total: int64;
    onPart: proc (part: SpsFile)) =
  ## Reads the SPS file `path` a chunk at a time with parseSEG's `parseSps`
  ## (the first chunk's revision and layout kept for the rest), handing each
  ## chunk's records to `onPart`; `done` of `total` bytes for the job's
  ## progress, which can cancel between chunks (`JobCancelledError`).
  var f: File
  if not fs.open(f, path): raise newException(IOError, "cannot open " & path)
  try:
    var opts = SpsOptions(keepRaw: false, skipBinary: true)
    var buf = newString(SpsChunk)
    var carry = ""
    var layout = tlLines
    var first = true
    while true:
      let got = fs.readBuffer(f, path, addr buf[0], SpsChunk)
      done += got
      let eof = got < SpsChunk
      var text = move carry
      if got > 0:
        let at = text.len
        text.setLen at + got
        copyMem(addr text[at], addr buf[0], got)
      if first and text.len > 0: layout = detectLayout(text.toOpenArray(0, min(text.high, 4095)))
      let cut = if eof: text.len else: cutAt(text, layout)
      carry = text[cut .. ^1]
      text.setLen cut
      if text.len > 0:
        let part = parseSps(text, path, opts)
        if first:
          (opts.revision, opts.forceLayout, opts.layout) = (part.revision, true, part.layout)
          first = false
        onPart(part)
      if not ctx.progress(done, max(total, done)):
        raise newException(JobCancelledError, "cancelled")
      if eof: break
  finally:
    close(f)

proc readText(path: string; most: int64): string =
  let size = fs.getFileSize(path)
  if size > most:
    raise newException(IOError, path.extractFilename & " is larger than " &
      $(most div (1024 * 1024)) & " MiB")
  fs.readFile(path)

proc c_fflush(f: File): cint {.importc: "fflush", header: "<stdio.h>".}

proc syncFile(f: File; name: string) =
  ## Puts what was written to `f` on the disk: the stream's buffer flushed
  ## (its result checked: a full disk shows here) and, on POSIX, `fsync`ed,
  ## so that the rename that follows never puts a cut-short file in place.
  ## Raises `IOError`.
  if c_fflush(f) != 0: raise newException(IOError, "the disk did not take " & name)
  when defined(posix):
    if fsync(getFileHandle(f)) != 0: raise newException(IOError, "the disk did not keep " & name)

proc writeStore*(dir: string; files: openArray[SurveyCopy]; ctx: JobContext): StoreInfo =
  ## Reads the copies `files` of the project in `dir` and writes what they
  ## hold to its `survey.bin` (the module's documentation); the counts of
  ## stations and relations it holds, its size and hash. Raises `IOError`
  ## when a copy cannot be read or the store not written,
  ## `JobCancelledError` at a cancel. Worker-only.
  let path = dir.partOf(SurveyStoreName)
  let tmp = path & "." & $getCurrentProcessId() & ".tmp"
  fs.createDir(path.parentDir)
  var w = Writer(path: tmp, h: initHasher())
  if not fs.open(w.f, tmp, fmWrite): raise newException(IOError, "cannot write " & tmp)
  var ok = false
  result = StoreInfo(format: StoreFormat)
  try:
    var head = StoreMagic
    head.raw uint32(StoreFormat)
    w.emit head
    var total = 0'i64
    for c in files:
      try: total += fs.getFileSize(dir.partOf(c.copy))
      except OSError: discard
    var done = 0'i64
    for c in files:
      let src = dir.partOf(c.copy)
      var info: FileInfo
      try: info = fs.getFileInfo(src)
      except OSError: raise newException(IOError, "the copy " & c.copy & " is not there")
      let fk = if c.kind == jkCsv: fkUnknown else: sniff(src)
      var sf = StoredFile(copy: c.copy, name: src.extractFilename, kind: c.kind, fileKind: fk,
        role: c.role, size: info.size, modified: info.lastWriteTime)
      ctx.setPhase "keeping " & sf.name
      case c.kind
      of jkSps:
        var started = false
        var pw = addr w
        let domain = relationDomainOf(src)
        var res = addr result
        eachSpsChunk(src, ctx, done, total, proc (part: SpsFile) =
          if not started:
            started = true
            pw[].fileBlock(sf, domain, part.revision)
            pw[].headersBlock(part.headers)
          var i = 0
          while i < part.points.len:
            let j = min(i + PartRecords, part.points.len)
            pw[].pointsBlock(part.points.toOpenArray(i, j - 1))
            i = j
          i = 0
          while i < part.relations.len:
            let j = min(i + PartRecords, part.relations.len)
            pw[].relationsBlock(part.relations.toOpenArray(i, j - 1))
            i = j
          for p in part.points:
            if p.kind == pkSource: inc res.sources else: inc res.receivers
          res.relations += part.relations.len)
        if not started:
          w.fileBlock(sf, domain, sps21)
      of jkP1:
        let text = readText(src, 64 * 1024 * 1024)
        done += text.len
        let pf = parseP1(text, src)
        w.fileBlock(sf, rdSource, sps21)
        for lf in pf.files:
          w.p1Block(lf)
          if lf.format == pfP1: result.sources += lf.records.len
      of jkCsv:
        let text = readText(src, 64 * 1024 * 1024)
        done += text.len
        w.fileBlock(sf, rdSource, sps21)
        w.buf.str text
        w.flushBlock(bkCsv, 1)
      if not ctx.progress(done, max(total, done)):
        raise newException(JobCancelledError, "cancelled")
    w.flushBlock(bkEnd, 0)
    var tail = ""
    let digest = w.h.digest
    tail.raw digest
    if fs.writeBuffer(w.f, w.path, addr tail[0], tail.len) != tail.len:
      raise newException(IOError, "the disk did not take " & tmp.extractFilename)
    w.bytes += tail.len
    syncFile(w.f, tmp.extractFilename)
    result.hash = digest
    result.bytes = w.bytes
    ok = true
  finally:
    close(w.f)
    if not ok: discard fs.tryRemoveFile(tmp)
  fs.moveFile(tmp, path)

# ----------------------------------------------------------------- reading --

type Cursor = object
  s: string
  at: int

proc need(c: var Cursor; n: int) {.inline.} =
  if n < 0 or c.at + n > c.s.len: raise newException(IOError, "survey.bin is damaged")

proc needRecords(c: var Cursor; count: uint32; minBytes: int) =
  ## Fails when `count` records of at least `minBytes` each cannot be in the
  ## bytes left in the block.
  if int64(count) * int64(minBytes) > int64(c.s.len - c.at):
    raise newException(IOError, "survey.bin is damaged")

proc get[T](c: var Cursor; x: var T) {.inline.} =
  c.need sizeof(T)
  copyMem(addr x, addr c.s[c.at], sizeof(T))
  c.at += sizeof(T)

proc getStr(c: var Cursor): string =
  var n = 0'u32
  c.get n
  if n > MaxStoreString: raise newException(IOError, "survey.bin is damaged")
  c.need int(n)
  result = c.s[c.at ..< c.at + int(n)]
  c.at += int(n)

proc read8[T: enum](c: var Cursor; lo, hi: T): T =
  var b = 0'u8
  c.get b
  if int(b) < ord(lo) or int(b) > ord(hi): raise newException(IOError, "survey.bin is damaged")
  T(b)

proc readExact(f: File; path: string; buf: var string; n: int; h: var Hasher) =
  buf.setLen n
  if n > 0:
    if fs.readBuffer(f, path, addr buf[0], n) != n:
      raise newException(IOError, "survey.bin ends early")
    h.update buf

proc storeHash*(path: string; ctx: JobContext): uint64 =
  ## The XXH64 hash of the store file at `path` but its last 8 bytes, as
  ## written into those bytes. Worker-only.
  var f: File
  if not fs.open(f, path): raise newException(IOError, "cannot open " & path)
  try:
    let size = fs.getFileSize(path)
    var h = initHasher()
    var buf = newString(1024 * 1024)
    var left = size - 8
    while left > 0:
      let n = int(min(left, buf.len.int64))
      if fs.readBuffer(f, path, addr buf[0], n) != n:
        raise newException(IOError, "survey.bin ends early")
      h.update buf.toOpenArrayByte(0, n - 1)
      left -= n
      if not ctx.progress(size - left, size):
        raise newException(JobCancelledError, "cancelled")
    result = h.digest
  finally:
    close(f)

proc readStore*(path: string; ctx: JobContext; r: StoreReader) =
  ## Reads the store file at `path` (written by `writeStore`) and hands what
  ## it holds to `r`, file by file, in order. The whole file's hash is
  ## checked first, so nothing is handed over from a damaged one. Raises
  ## `IOError` for a file that is not one, damaged or cut short,
  ## `JobCancelledError` at a cancel. Worker-only.
  let expected = block:
    var f: File
    if not fs.open(f, path): raise newException(IOError, "cannot open " & path)
    try:
      let size = fs.getFileSize(path)
      if size < StoreMagic.len + 4 + 13 + 8: raise newException(IOError, "survey.bin ends early")
      var tail = newString(8)
      f.setFilePos(size - 8)
      if fs.readBuffer(f, path, addr tail[0], 8) != 8:
        raise newException(IOError, "survey.bin ends early")
      var d = 0'u64
      copyMem(addr d, addr tail[0], 8)
      d
    finally:
      close(f)
  if storeHash(path, ctx) != expected: raise newException(IOError, "survey.bin is damaged")
  var f: File
  if not fs.open(f, path): raise newException(IOError, "cannot open " & path)
  try:
    var h = initHasher()
    var buf = ""
    readExact(f, path, buf, StoreMagic.len + 4, h)
    if buf[0 ..< StoreMagic.len] != StoreMagic:
      raise newException(IOError, "it is not a survey kept by viewSEG")
    var format = 0'u32
    copyMem(addr format, addr buf[StoreMagic.len], 4)
    if format != StoreFormat:
      raise newException(IOError, "it is kept in format " & $format & "; this viewSEG reads " &
        $StoreFormat)
    var current = StoredFile()
    var headers: seq[SpsHeader] = @[]
    var revision = sps21
    var domain = rdSource
    var open = false
    let size = fs.getFileSize(path)
    while true:
      readExact(f, path, buf, 13, h)
      var c = Cursor(s: move buf)
      let kind = c.read8(bkNone, bkEnd)
      var count = 0'u32
      c.get count
      var bytes = 0'i64
      c.get bytes
      if bytes < 0 or bytes > MaxBlockBytes: raise newException(IOError, "survey.bin is damaged")
      buf = move c.s
      readExact(f, path, buf, int(bytes), h)
      c = Cursor(s: move buf)
      case kind
      of bkFile:
        if open and not r.onEnd.isNil: r.onEnd(current)
        current = StoredFile(copy: c.getStr, name: c.getStr)
        current.kind = c.read8(jkSps, jkCsv)
        current.fileKind = c.read8(low(FileKind), high(FileKind))
        current.role = c.read8(low(CsvRole), high(CsvRole))
        domain = c.read8(rdSource, rdReceiver)
        revision = c.read8(low(SpsRevision), high(SpsRevision))
        c.get current.size
        var secs = 0'i64
        var ns = 0'i32
        c.get secs
        c.get ns
        current.modified = initTime(secs, clamp(ns, 0, 999_999_999))
        headers = @[]
        open = true
        if not r.onFile.isNil: r.onFile(current)
      of bkHeaders:
        for i in 0 ..< int(count):
          headers.add SpsHeader(code: c.getStr, description: c.getStr, data: c.getStr)
      of bkPoints:
        var part = SpsFile(name: current.copy.extractFilename, revision: revision,
          headers: headers)
        c.needRecords(count, PointMinBytes)
        part.points = newSeqOfCap[SpsPoint](int(count))
        for i in 0 ..< int(count):
          var p = SpsPoint()
          p.kind = c.read8(pkReceiver, pkSource)
          p.lineName = c.getStr
          p.pointName = c.getStr
          c.get p.line
          c.get p.point
          var idx = 0'i32
          c.get idx
          p.index = idx
          c.get p.easting
          c.get p.northing
          c.get p.elevation
          part.points.add p
        if not r.onSps.isNil: r.onSps(current, part)
      of bkRelations:
        var part = SpsFile(name: current.copy.extractFilename, revision: revision,
          headers: headers)
        c.needRecords(count, RelationMinBytes)
        part.relations = newSeqOfCap[SpsRelation](int(count))
        for i in 0 ..< int(count):
          var x = SpsRelation()
          c.get x.recordType
          x.fieldTape = c.getStr
          c.get x.fieldRecord
          var v = 0'i32
          c.get v
          x.recordIncrement = v
          c.get x.instrumentCode
          x.srcLineName = c.getStr
          x.srcPointName = c.getStr
          c.get x.srcLine
          c.get x.srcPoint
          c.get v
          x.srcIndex = v
          c.get x.fromChannel
          c.get x.toChannel
          c.get v
          x.channelIncrement = v
          x.rcvLineName = c.getStr
          x.fromReceiverName = c.getStr
          x.toReceiverName = c.getStr
          c.get x.rcvLine
          c.get x.fromReceiver
          c.get x.toReceiver
          c.get v
          x.rcvIndex = v
          part.relations.add x
        if not r.onSps.isNil: r.onSps(current, part)
      of bkP1:
        var lf = PLogicalFile()
        lf.format = c.read8(low(PFormat), high(PFormat))
        var n = 0'u32
        c.get n
        c.needRecords(n, P1MinBytes)
        lf.records = newSeqOfCap[P1Record](int(n))
        for i in 0 ..< int(n):
          var x = P1Record()
          x.lineName = c.getStr
          x.pointName = c.getStr
          c.get x.point
          c.get x.reshoot
          c.get x.easting
          c.get x.northing
          c.get x.depthOrElevation
          lf.records.add x
        if not r.onP1.isNil: r.onP1(current, P1File(name: current.copy.extractFilename,
          files: @[lf]))
      of bkCsv:
        let text = c.getStr
        if not r.onCsv.isNil: r.onCsv(current, text)
      of bkEnd:
        if open and not r.onEnd.isNil: r.onEnd(current)
        break
      of bkNone: raise newException(IOError, "survey.bin is damaged")
      buf = move c.s
      if not ctx.progress(f.getFilePos, size):
        raise newException(JobCancelledError, "cancelled")
  finally:
    close(f)
