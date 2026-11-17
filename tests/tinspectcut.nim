## The Headers window's samples "as displayed" of a trace cut short (more
## samples than are kept at once, `MaxInspectedValues`): the trace is
## filtered and processed whole, as the plot does, then cut, so the samples
## kept are the plot's; and the cut is said.
##
## Seen to fail: with the filters and the display processing run on the
## kept samples alone (as they were), "sample 99 of 100 kept: ... the whole
## trace filtered gives ...".

import std/math
import parseSEG
import processSEG/[adapters, pipeline]
import processSEG/core/[types, workspace]
import viewSEG/core/[edits, headers, processing, viewport]
import viewSEG/core/inspector {.all.}
import utils/fixtures

proc main*() =

  withFixtures fx:
    let path = fx.longTraceSegy(2000)
    var f = openSeismic(path, keys = true)
    let dtMs = f.traceKeys(0).intervalUs / 1000
    let pr = Processing(band: pbBandPass, f1: 4, f2: 8, f3: 30, f4: 45, dc: dcMean)
    let flow = initPipeline([agcOp(windowMs = 200)])
    let req = InspectRequest(samples: true, filters: pr.filterPipeline(dtMs), flow: flow)
    let t = InspectTrace(id: 0, at: 0, trace: 0, displayed: true)
    var d = TraceDetail(keys: f.traceKeys(0), dtMs: dtMs)
    var ws = initWorkspace()
    const Kept = 100
    readSamples(d, addr f, t, req, Kept, ws)
    doAssert d.displayed and d.samples.len == Kept and d.cut == 2000 - Kept, $d.cut
    # the whole trace through the same steps, as the plot's reader runs them
    var log: DiagLog
    var whole = f.readTraces([0], log)
    let n = whole.shape[1]
    for plan in [req.filters.compile(float32, dtMs, n), flow.compile(float32, dtMs, n)]:
      ws.reserve(plan)
      plan.apply(whole, f.chunkMeta([0], dtMs = dtMs), ws)
    for i in 0 ..< Kept:
      doAssert abs(d.samples[i] - whole[0, i]) <= 1e-4 * max(1'f32, abs(whole[0, i])),
        "sample " & $i & " of " & $Kept & " kept: " & $d.samples[i] &
        "; the whole trace filtered gives " & $whole[0, i]
    f.close()
    echo "tinspectcut: ok"

when isMainModule:
  main()
