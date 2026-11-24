## What kind of recording a file on disk is, asked cheaply of the file alone
## (`kindOfFile`), so the Files panel can say it for every file. It never shows a guess.
##
## The open of a whole file walks every trace header. For a file up to `ProbeWholeBytes` that
## is what is done, through the same read-only mapped open the program uses to show a file:
## only the header blocks are touched, no sample is read, and the answer is exactly that of
## `describeRecording`. A larger file is read by its start only: 256 KiB at first, four times
## more (the bytes already read are kept) each time the traces seen do not yet give every
## receiver seen `KindStarts` start times, up to `ProbeMaxBytes` or `ProbeTraces` traces. At
## that cap, without those starts, the kind is not known (`poNotKnown`): more of the file
## could change it, and the Files panel says so rather than guess. A file that was read whole
## to its end, or whose every receiver has its starts, has its answer.

import parseSEG
import ./[correlatejobs, filesystem, jobs, recordingkind]

const
  ProbeFirstBytes* = 256 * 1024     ## the first prefix read
  ProbeMaxBytes* = 16 * 1024 * 1024 ## the most bytes read of the start of a larger file
  ProbeTraces* = 4096               ## the prefix stops growing once it holds this many traces
  ProbeWholeBytes* = 256'i64 * 1024 * 1024
    ## a file up to this size is opened whole (headers only) for its kind
  ProbeGrowth = 4                   ## each prefix is this many times the one before

type
  ProbeOutcome* = enum
    poNone     ## not a seismic file, cannot be read, or has no live trace with a sample interval
    poKnown    ## `KindProbe.kind` is the answer
    poNotKnown ## a seismic file whose start does not tell its kind: it must be opened

  KindProbe* = object
    outcome*: ProbeOutcome
    kind*: RecordingKind ## when `outcome` is `poKnown`

func known(kind: RecordingKind): KindProbe = KindProbe(outcome: poKnown, kind: kind)

proc readMore(f: File; path: string; bytes: var seq[byte]; count: int64) {.raises: [IOError].} =
  ## Reads `f` on until `bytes` holds `count` bytes (fewer when the file ends sooner).
  var got = bytes.len
  bytes.setLen count
  while got < bytes.len:
    let n = fs.readBuffer(f, path, addr bytes[got], bytes.len - got)
    if n <= 0: break
    got += n
  bytes.setLen got

proc factsOf(f: var SeismicFile; path: string; vendors: VendorRegistry;
    check: proc () {.gcsafe.}): RecordingFacts =
  ## The facts of the open file `f`, not ready without a live trace and a sample interval.
  result = RecordingFacts()
  let dtMs = seismicDtMs(addr f)
  if f.len > 0 and not dtMs.isNaN and dtMs > 0:
    result = describeRecording(planRecording(addr f, path, dtMs, vendors, check))

proc cancelledBy(check: proc () {.gcsafe.}): Progress =
  ## A progress callback for the open that stops it when `check` raises.
  result = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try:
      if check != nil:
        {.cast(raises: [CatchableError]).}:
          check()
      true
    except CatchableError:
      false

proc wholeKind(path: string; vendors: VendorRegistry; check: proc () {.gcsafe.}): KindProbe =
  ## The kind of `path` opened whole, as the program opens a file to show it.
  result = KindProbe(outcome: poNone)
  fs.mappedRead(path, headers = true) # (the seam: a drive that stops answering holds here)
  var f: SeismicFile
  try:
    f = openSeismic(path, keys = true, progress = cancelledBy(check),
      opts = OpenOptions(vendors: vendors))
  except SegCancelledError:
    if check != nil: check() # raises the cancel
    return
  try:
    let facts = factsOf(f, path, vendors, check)
    if facts.ready: result = known(facts.kind)
  finally:
    f.close()

proc kindOfFile*(path: string; vendors: VendorRegistry;
    check: proc () {.gcsafe.} = nil; wholeBytes = ProbeWholeBytes): KindProbe =
  ## The kind of the seismic file `path` (see the module's comment); a file up to `wholeBytes`
  ## is opened whole. `poNone` for a file that
  ## is not seismic, cannot be read (the failure is not reported: the file is only without a
  ## kind) or has no live trace with a sample interval. `check` may raise to stop. Worker-only:
  ## it reads the file.
  result = KindProbe(outcome: poNone)
  var size = 0'i64
  try:
    size = fs.getFileSize(path)
  except OSError:
    return
  var file: File
  if size <= 0 or not fs.open(file, path): return
  try:
    var bytes: seq[byte] = @[]
    var window = ProbeFirstBytes.int64
    while true:
      if check != nil: check()
      let count = min(window, size)
      let whole = count >= size
      readMore(file, path, bytes, count)
      fs.mappedRead(path, headers = true)
      var f = openSeismicBytes(bytes, path, keys = true, opts = OpenOptions(vendors: vendors))
      var more = false
      try:
        let capped = f.len >= ProbeTraces or window >= ProbeMaxBytes
        if f.kind == skUnknown:
          return
        elif not whole and size <= wholeBytes:
          # a file in the prefix's format that is not multiplexed: open it whole
          result = wholeKind(path, vendors, check)
          return
        let facts = factsOf(f, path, vendors, check)
        if whole:
          if facts.ready: result = known(facts.kind)
          return
        elif facts.ready and facts.fewestStarts >= KindStarts:
          result = known(facts.kind)
          return
        elif capped:
          result = KindProbe(outcome: poNotKnown)
          return
        else:
          more = true
      finally:
        f.close()
      if more: window *= ProbeGrowth
  except JobCancelledError:
    raise
  except CatchableError:
    # unreadable, damaged, or a file memory cannot hold (multiplexed SEG-D): no kind
    result = KindProbe(outcome: poNone)
  finally:
    close(file)
