## What kind of recording a file on disk is, asked of the file alone (`kindOfFile`), so the
## Files panel can say it for every file. It never shows a guess.
##
## The kind follows from every trace of the file: a receiver or a component that first appears
## late in the file can change it, so no start of a file is enough. A file up to
## `ProbeWholeBytes` is opened whole, through the same read-only mapped open the program uses to
## show a file: only the header blocks are touched, no sample is read, and the answer is exactly
## that of `describeRecording`. A larger file is not opened (`poNotKnown`): the Files panel says
## the kind is known once the file is opened. Before that, the first `ProbeHeadBytes` say what
## the file is: not seismic (`poNone`), or multiplexed SEG-D (`poMultiplexed`), which the open
## demultiplexes into a temporary copy of the whole file, too much to do for a list.

import parseSEG
import parseSEG/io/memsource
import ./[correlatejobs, filesystem, jobs, recordingkind]

const
  ProbeHeadBytes* = 256 * 1024 ## the first read: what the file is
  ProbeWholeBytes* = 256'i64 * 1024 * 1024
    ## a file up to this size is opened whole (headers only) for its kind

type
  ProbeOutcome* = enum
    poNone        ## not a seismic file, cannot be read, or has no live trace with a sample interval
    poKnown       ## `KindProbe.kind` is the answer
    poNotKnown    ## a seismic file larger than the whole-open limit: it must be opened
    poMultiplexed ## multiplexed SEG-D: not opened for its kind, it must be opened

  KindProbe* = object
    outcome*: ProbeOutcome
    kind*: RecordingKind ## when `outcome` is `poKnown`
    order*: TraceOrder   ## when `outcome` is `poKnown`: how the traces are written

func known(facts: RecordingFacts): KindProbe =
  KindProbe(outcome: poKnown, kind: facts.kind, order: facts.order)

proc readHead(f: File; path: string; count: int): seq[byte] {.raises: [IOError].} =
  ## The first `count` bytes of `f` (fewer when the file ends sooner).
  result = newSeq[byte](count)
  var got = 0
  while got < result.len:
    let n = fs.readBuffer(f, path, addr result[got], result.len - got)
    if n <= 0: break
    got += n
  result.setLen got

proc multiplexedSegd(head: sink seq[byte]; path: string): bool =
  ## Whether the first record of the SEG-D file whose start is `head` is multiplexed. False
  ## when its headers do not fit in `head`: the open then says what the file is.
  try:
    var r = openSegd(openMemorySource(head, path), headersOnly = true)
    result = r.nextRecord() and r.record.multiplexed
  except CatchableError:
    result = false

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
    let dtMs = seismicDtMs(addr f)
    if f.len > 0 and not dtMs.isNaN and dtMs > 0:
      let facts = describeRecording(planRecording(addr f, path, dtMs, vendors, check))
      if facts.ready: result = known(facts)
  finally:
    f.close()

proc kindOfFile*(path: string; vendors: VendorRegistry;
    check: proc () {.gcsafe.} = nil; wholeBytes = ProbeWholeBytes): KindProbe =
  ## The kind of the seismic file `path` (see the module's comment); a file up to `wholeBytes`
  ## is opened whole. `poNone` for a file that is not seismic, cannot be read (the failure is
  ## not reported: the file is only without a kind) or has no live trace with a sample
  ## interval. `check` may raise to stop. Worker-only: it reads the file.
  result = KindProbe(outcome: poNone)
  try:
    let size = fs.getFileSize(path)
    var file: File
    if size <= 0 or not fs.open(file, path): return
    var head: seq[byte] = @[]
    try:
      if check != nil: check()
      head = readHead(file, path, int(min(ProbeHeadBytes.int64, size)))
    finally:
      close(file)
    let kind = detectKind(head)
    if kind == skUnknown: discard
    elif kind == skSegd and multiplexedSegd(move head, path):
      result = KindProbe(outcome: poMultiplexed)
    elif size > wholeBytes: result = KindProbe(outcome: poNotKnown)
    else: result = wholeKind(path, vendors, check)
  except JobCancelledError:
    raise
  except CatchableError:
    # unreadable or damaged: no kind
    result = KindProbe(outcome: poNone)
