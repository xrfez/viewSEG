## What kind of recording a file on disk is, asked cheaply of the start of the
## file alone (`kindOfFile`), so the Files panel can say it for every file.
##
## The open of a whole file walks every trace header, which takes seconds on a
## large one. Here only a prefix of the file is read, through the file system
## seam, and opened in memory: 256 KiB at first, four times more each time the
## traces seen do not yet give `KindStarts` start times for every receiver, up
## to `ProbeMaxBytes` or `ProbeTraces` traces; then the kind is decided from
## what was seen. A file that fits in the prefix is read whole and gets the
## answer of `describeRecording`. No sample is decoded and no index is built
## past the prefix.

import std/options
import parseSEG
import ./[correlatejobs, filesystem, jobs, recordingkind, vendormaps]

const
  ProbeFirstBytes* = 256 * 1024     ## the first prefix read
  ProbeMaxBytes* = 16 * 1024 * 1024 ## the most bytes read of one file
  ProbeTraces* = 4096               ## the prefix stops growing once it holds this many traces
  ProbeGrowth = 4                   ## each prefix is this many times the one before

proc readPrefix(path: string; count: int64): seq[byte] {.raises: [IOError].} =
  ## The first `count` bytes of `path` (fewer when it ends sooner).
  var f: File
  if not fs.open(f, path):
    raise newException(IOError, "cannot open " & path)
  try:
    result = newSeq[byte](count)
    var got = 0
    while got < result.len:
      let n = fs.readBuffer(f, path, addr result[got], result.len - got)
      if n <= 0: break
      got += n
    result.setLen got
  finally:
    close(f)

func enough(facts: RecordingFacts): bool =
  ## Every receiver seen has `KindStarts` start times: more traces cannot change the answer.
  facts.ready and facts.fewestStarts >= KindStarts

proc kindOfFile*(path: string; vendors: VendorRegistry;
    check: proc () {.gcsafe.} = nil): Option[RecordingKind] =
  ## The kind of the seismic file `path`, read from its first traces; `none` for a file that
  ## is not seismic, cannot be read (the failure is not reported: the file is only without a
  ## kind) or has no live trace with a sample interval. `check` may raise to stop. Worker-only:
  ## it reads the file.
  result = none(RecordingKind)
  var size = 0'i64
  try:
    size = fs.getFileSize(path)
  except OSError:
    return
  var window = ProbeFirstBytes.int64
  while true:
    if check != nil: check()
    let count = min(window, size)
    let whole = count >= size
    var more = false
    try:
      fs.mappedRead(path, headers = true) # (the seam: a drive that stops answering holds here)
      var f = openSeismicBytes(readPrefix(path, count), path, keys = true,
        opts = OpenOptions(vendors: vendors))
      try:
        let dtMs = seismicDtMs(addr f)
        if f.len > 0 and not dtMs.isNaN and dtMs > 0:
          let facts = describeRecording(planRecording(addr f, path, dtMs, vendors, check))
          if facts.ready: result = some(facts.kind)
          more = not (whole or enough(facts) or f.len >= ProbeTraces or
            window >= ProbeMaxBytes)
        else:
          # a recognised file whose first traces do not fit the prefix yet is read further
          more = f.kind != skUnknown and not whole and window < ProbeMaxBytes and
            f.len < ProbeTraces
      finally:
        f.close()
    except IOError, OSError, ValueError:
      # unreadable, or a file memory cannot hold (multiplexed SEG-D): no kind
      return none(RecordingKind)
    if not more: return
    window *= ProbeGrowth
