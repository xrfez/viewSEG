## The Node orientation plot (New plot) in `core`, without a window, on
## `samples/obn/obn_receiver.sgd` (node 104's record is bumped before its
## fifth shot), on `samples/land/shots.sgy` and on a small SEG-D file in which
## some traces carry no orientation header:
##
## - node 104's roll, pitch and azimuth have one point per trace of its record,
##   steady for the first 16 traces and stepped (roll +4, azimuth +15 degrees)
##   from the 17th; node 103's lines are constant;
## - a component filter shortens the lines to the traces shown (one component
##   of four: eight points);
## - a SEG-Y file says "These traces carry no orientation header." and draws
##   nothing;
## - a trace without the header is a gap (NaN) in the three lines, not a zero;
## - the plot follows the record on show (another record: its own lines) and,
##   frozen, keeps the one it had.
##
## Seen to fail: with the angles left in radians (no `radToDeg`), "roll of
## trace 1"; with a trace's missing header read as zeros instead of NaN, the
## SEG-Y file's "These traces carry no orientation header." (it drew three flat
## zero lines).

import std/[math, options, os]
import parseSEG
import viewSEG/core/[analysis, state]
import utils/[fixtures, waiting]

const root = currentSourcePath().parentDir.parentDir

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc answered(st: AppState; w: int): bool =
  st.plots[w].result.gen > 0 and not st.plots[w].waiting

proc gapRecord(dir: string): string =
  ## Six traces; the third and fourth, a channel set of their own, have no orientation
  ## header (a writer gives a set's traces all one or none). Roll 10 + n.
  result = dir / "gaps.sgd"
  var o = SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 50, format: sd8036,
    units: cuMeters, time: 1_772_413_200.0)
  var w = openSeismicWriter(result, o)
  var buf = newSeq[float32](50)
  for n in 0 ..< 6:
    var k = initTraceKeys()
    (k.record, k.channel, k.t0Ms, k.intervalUs) = (1.0, float64(n + 1), 0.0, 2000.0)
    k.status = tsLive
    let att = initTraceOrientation(float32(degToRad(10.0 + float64(n))), 0'f32,
      float32(degToRad(45.0)), orientationType = 1)
    if n in 2 .. 3: w.writeTrace(k, buf, channelType = sctEm) # a channel set of its own
    else: w.writeTrace(k, buf, orientation = some(att))
  doAssert w.close().len == 0

proc curve(st: AppState; w: int; name: string): seq[float64] =
  for c in st.plots[w].result.plots[0].curves:
    if c.name == name: return c.ys
  doAssert false, "no curve " & name

proc near(a, b: float64): bool = abs(a - b) < 1e-4

proc main*() =
  let obn = root / "samples" / "obn" / "obn_receiver.sgd"
  let land = root / "samples" / "land" / "shots.sgy"
  doAssert fileExists(obn) and fileExists(land)
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: obn)
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)

    block bumpedNode:
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 3)
      doAssert st.settle(st.panel(MainPanel).laidOut and st.panel(MainPanel).shown.len == 32)
      # a selection of two traces does not make the plot of those two
      let b = st.sessions[0].base
      st.apply Command(kind: ckSelect, traces: @[b + 100, b + 101], mode: smReplace)
      st.apply Command(kind: ckOpenPlot, plotView: avOrientation)
      doAssert st.plots.len == 1, "no plot opened"
      doAssert st.plots[0].traces.len == 32, "the plot is of the selection: " &
        $st.plots[0].traces.len
      doAssert st.settle(st.answered(0)), "no answer"
      let r = st.plots[0].result
      doAssert r.problem == "", r.problem
      doAssert r.plots.len == 1 and r.plots[0].xs.len == 32
      let roll = st.curve(0, "roll")
      let pitch = st.curve(0, "pitch")
      let azimuth = st.curve(0, "azimuth")
      for i in 0 ..< 32:
        let moved = i >= 16
        doAssert near(roll[i], if moved: 7.0 else: 3.0), "roll of trace " & $(i + 1) & ": " &
          $roll[i]
        doAssert near(pitch[i], 0.0), "pitch of trace " & $(i + 1) & ": " & $pitch[i]
        doAssert near(azimuth[i], if moved: -5.0 else: -20.0), "azimuth of trace " & $(i + 1) &
          ": " & $azimuth[i]

    block nodeAtRest:
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 2)
      doAssert st.settle(st.answered(0) and st.plots[0].traces.len == 32 and
        st.plots[0].result.plots.len == 1 and
        near(st.curve(0, "azimuth")[0], 90.0)), "the plot did not follow the record"
      for name in ["roll", "pitch", "azimuth"]:
        let ys = st.curve(0, name)
        for y in ys: doAssert y == ys[0], name & " of node 103 is not constant"

    block componentFilter:
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 3)
      doAssert st.settle(st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckFilter, panel: MainPanel, filter: TraceFilter(seismic: true,
        auxiliary: true, components: {1'u8, 2, 3})) # off: three of the four
      doAssert st.settle(st.panel(MainPanel).shown.len == 8 and st.answered(0) and
        st.plots[0].traces.len == 8), "one component of four is eight traces"
      doAssert st.plots[0].result.plots[0].xs.len == 8

    block frozen:
      var p = st.plots[0].params
      let was = st.plots[0].traces
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p,
        plotFrozen: true)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
      doAssert st.settle(st.panel(MainPanel).laidOut)
      doAssert st.plots[0].traces == was, "a frozen plot followed the record"
      st.apply Command(kind: ckClosePlot, plot: st.plots[0].id)

    block segy:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: land)
      doAssert st.settle(st.sessions[^1].path == land and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckOpenPlot, plotView: avOrientation)
      doAssert st.plots.len == 1
      doAssert st.settle(st.answered(0)), "no answer"
      doAssert st.plots[0].result.problem == "These traces carry no orientation header.",
        st.plots[0].result.problem
      doAssert st.plots[0].result.plots.len == 0

    block gaps:
      let path = gapRecord(fx.dir)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.panel(MainPanel).laidOut and st.sessions[^1].path == path)
      doAssert st.settle(st.answered(0) and st.plots[0].file == "gaps.sgd" and
        st.plots[0].result.plots.len == 1), "no answer for the SEG-D file"
      let roll = st.curve(0, "roll")
      doAssert roll.len == 6
      for i in 0 ..< 6:
        if i in 2 .. 3: doAssert roll[i].isNaN, "gap at trace " & $(i + 1) & ": " & $roll[i]
        else: doAssert near(roll[i], 10.0 + float64(i)), "roll of trace " & $(i + 1)
      for name in ["pitch", "azimuth"]:
        doAssert st.curve(0, name)[2].isNaN

  echo "torientation: ok"

when isMainModule:
  main()
