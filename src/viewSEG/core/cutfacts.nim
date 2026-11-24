## What a recording says about a cut by shot log before it is cut: its
## sample interval and how many components (receivers) each record would hold.
## Read from the trace keys the file already has in memory; no sample is read.

import std/math
import parseSEG
import processSEG
import processSEG/continuous/slice
import correlatejobs

type CutFacts* = object
  ready*: bool ## the keys were there, and the recording has a sample interval
  dtMs*: float64
  components*: int

proc cutFacts*(file: ptr SeismicFile): CutFacts =
  ## The facts of `file` from its keys; not `ready` while they are not read or
  ## the file has no live trace.
  result = CutFacts(dtMs: NaN)
  if file == nil or not file[].isOpen or file[].len == 0 or not file[].hasKeys: return
  let dtMs = seismicDtMs(file)
  if dtMs.isNaN or dtMs <= 0: return
  let streams = initSliceStreams(chunkMeta(file[], 0 ..< file[].len, dtMs = dtMs))
  result.dtMs = dtMs
  result.components = streams.receiverCount
  result.ready = result.components > 0
