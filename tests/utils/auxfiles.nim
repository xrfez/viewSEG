## A small SEG-Y file for the Aux window's tests (`tauxwin`, `tguiauxwin`): written with
## parseSEG's writer into a folder the caller owns.

import std/os
import parseSEG

proc twoRecordsSegy*(dir: string): string =
  ## Record 1: three seismic traces and two auxiliary ones (the pilot loud, a monitor quiet);
  ## record 2: three seismic traces and none auxiliary. 100 samples at 2 ms.
  result = dir / "aux-window.sgy"
  var w = openSeismicWriter(result, SegyOutputOptions(traceSorting: 1,
    text: @["C01 viewSEG test fixture: an Aux window"]))
  var buf = newSeq[float32](100)
  for shot in 1 .. 2:
    for c in 1 .. 5:
      if shot == 2 and c > 3: break
      var k = initTraceKeys()
      (k.record, k.channel, k.intervalUs) = (float64(shot), float64(c), 2000.0)
      let aux = c > 3
      if aux: (k.traceCode, k.status) = (6'i16, tsAuxiliary)
      else: k.status = tsLive
      for i in 0 ..< buf.len:
        buf[i] = (if aux: 1000.0 * float32(c - 3) else: 1.0) * float32((i mod 7) - 3)
      w.writeTrace(k, buf)
  doAssert w.close().len == 0
