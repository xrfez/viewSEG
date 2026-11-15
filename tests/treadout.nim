## The status bar's readout: each default field formatted from a pick of a
## known trace, every field blank (not "NaN", not 0) when its keys are not
## known, when no trace is under the cursor and when the cursor is off the
## plot; half-known pairs, zoomed-out amplitudes, the UTC times, and the
## number formats. The raw amplitude, off by default: turned on, the tiles
## carry the file's own samples, before polarity, edits and gain, and the
## readout reads them (`rawAmplitude`).
##
## Seen to fail: with `numberText` printing NaN, `otherFields` showed "nan"
## for an unknown inline number; with `pair` dropping the known half,
## `halfKnownPairs` read "" for a point alone; with the times shown in local
## time (run with TZ=Asia/Tokyo), `defaultFields` read 20:33:20.123; with
## the raw samples cut after `prepare` (the processed ones), `rawAmplitude`
## found "the raw sample of trace 3 at 100 is -3.296956, the file's
## -0.98078525" (after AGC); with no read again when the field is turned on, "no raw
## samples in the tile".

import std/[math, strutils]
import parseSEG
import viewSEG/core/[pick, readout, state, zoom]
import utils/[fixtures, waiting]

proc knownPick(): Pick =
  ## The cursor at 1284 ms over trace 13 (index 12) of shot 11.
  result = noPick()
  result.inside = true
  result.at = DataPoint(x: 12.2, tMs: 1284)
  result.sample = 642
  result.found = true
  result.position = 12
  result.trace = 12
  result.amplitude = 0.041234567
  result.keys.channel = 13
  result.keys.rcvLine = 100
  result.keys.rcvPoint = 113
  result.keys.srcLine = 1
  result.keys.srcPoint = 1001.5
  result.keys.record = 11
  result.keys.offset = 312.5
  result.keys.time = 1478000000.123456 # 2016-11-01 11:33:20.123 UTC
  result.keys.ensemble = 2050
  result.keys.inline = NaN
  result.keys.srcX = 500_137.5
  result.keys.srcY = 6_000_000
  result.keys.rcvZ = 101.25
  result.keys.component = 2
  result.keys.status = tsLive

block numberCharsCountsTheText:
  # `numberChars` (the display header's column widths) is `numberText`'s
  # length, whole numbers counted without making the text.
  for v in [0.0, -0.0, 1, -1, 9, 10, -10, 99, 100, 12345, -98765, 1e14, -1e14 + 1, 999999999999999.0,
      1e15, 2e20, 0.5, -0.5, 0.004, -0.004, 0.005, 3.999, 112.45, -10963.41, 10.1, 1e16 + 0.5,
      NaN, Inf, -Inf]:
    doAssert numberChars(v) == numberText(v).len, $v & ": " & $numberChars(v) & " for " &
      numberText(v).escape

block defaultFields:
  let p = knownPick()
  var shown: seq[string]
  for f in DefaultReadout:
    shown.add caption(f) & " " & p.text(f)
  doAssert shown == @["t 1284.0 ms", "trace 13", "chan 13", "rcv 100 / 113",
    "src 1 / 1001.5", "FFID 11", "offset 312.5", "amp 0.04123",
    "shot 2016-11-01 11:33:20.123"], $shown
  doAssert DefaultReadout == [rfTime, rfTrace, rfChannel, rfReceiver, rfSource, rfRecord,
    rfOffset, rfAmplitude, rfShotTime]

block otherFields:
  let p = knownPick()
  doAssert p.text(rfCursorUtc) == "2016-11-01 11:33:21.407"
  doAssert p.text(rfSample) == "643"
  doAssert p.text(rfEnsemble) == "2050" and p.text(rfInline) == ""
  doAssert p.text(rfSourceXY) == "500137.5, 6000000"
  doAssert p.text(rfReceiverXY) == "" and p.text(rfReceiverZ) == "101.25"
  doAssert p.text(rfComponent) == "2" and p.text(rfStatus) == "live"
  for f in ReadoutField:
    doAssert caption(f).len > 0 and ($f).len > 0

block unknownKeysAreBlank:
  # a trace under the cursor whose headers give nothing
  var p = knownPick()
  p.keys = initTraceKeys()
  for f in ReadoutField:
    let s = p.text(f)
    doAssert "nan" notin s.toLowerAscii and "inf" notin s.toLowerAscii, $f & ": " & s
    if f notin {rfTime, rfSample, rfAmplitude, rfTrace}:
      doAssert s == "", $f & " shows " & s
  doAssert p.text(rfTime) == "1284.0 ms" and p.text(rfTrace) == "13"

block noTraceUnderTheCursor:
  var p = noPick()
  p.inside = true
  p.at = DataPoint(x: 30, tMs: 500)
  p.sample = 250
  for f in ReadoutField:
    if f notin {rfTime, rfSample}:
      doAssert p.text(f) == "", $f & " shows " & p.text(f)
  doAssert p.text(rfTime) == "500.0 ms" and p.text(rfSample) == "251"
  # off the plot: everything blank
  var off = knownPick()
  off.inside = false
  for f in ReadoutField:
    doAssert off.text(f) == "", $f & " shows " & off.text(f)
  # off the record's samples, and a value not held
  var edge = knownPick()
  edge.sample = -1
  edge.amplitude = NaN
  doAssert edge.text(rfSample) == "" and edge.text(rfAmplitude) == ""

block halfKnownPairs:
  var p = knownPick()
  p.keys.rcvLine = NaN
  doAssert p.text(rfReceiver) == "113"
  p.keys.rcvLine = 100
  p.keys.rcvPoint = NaN
  doAssert p.text(rfReceiver) == "100 / ?"
  p.keys.srcLine = NaN
  p.keys.srcPoint = NaN
  doAssert p.text(rfSource) == ""

block zoomedOutAmplitude:
  var p = knownPick()
  p.binned = 4
  doAssert p.text(rfAmplitude) == "0.04123 (peak of 4)"

block numberFormats:
  doAssert numberText(12) == "12" and numberText(-3) == "-3" and numberText(1001.5) == "1001.5"
  doAssert numberText(0.126) == "0.13" and numberText(2.10) == "2.1" and numberText(NaN) == ""
  doAssert numberText(Inf) == "" and numberText(1e20) == "100000000000000000000"
  doAssert significant(0.041234567) == "0.04123" and significant(12345.678) == "1.235e+04"
  doAssert significant(1.0) == "1" and significant(-2.5) == "-2.5" and
    significant(1.5e9) == "1.5e+09" and significant(0) == "0" and significant(NaN) == ""
  doAssert utcText(0) == "1970-01-01 00:00:00.000" and utcText(NaN) == "" and
    utcText(1e300) == ""

block cleanedFields:
  doAssert cleaned([rfTime, rfAmplitude, rfTime, rfShotTime, rfAmplitude]) ==
    @[rfTime, rfAmplitude, rfShotTime]
  doAssert cleaned(newSeq[ReadoutField]()).len == 0

block rawAmplitude:
  doAssert rfRawAmplitude notin DefaultReadout, "the raw amplitude is off by default"
  template settle(st: var AppState; cond: untyped): bool =
    waitUntil((discard st.drainInbox(); cond))
  proc answered(st: AppState): bool =
    let p = st.panel(MainPanel)
    let tiles = st.tiles(st.findPanel(MainPanel))
    tiles.len > 0 and tiles[^1].request == p.pending and p.pending.gen == p.requestGen
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
    doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
    let lay = st.panel(MainPanel).layout
    var d = st.panel(MainPanel).layers[0].display
    d.gain = dgAgc
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
    doAssert st.settle(st.answered)
    doAssert st.tiles(0)[^1].raw.len == 0, "raw samples carried while the field is off"
    var s = st.settings
    s.readout.add rfRawAmplitude
    st.apply Command(kind: ckSettings, settings: s)
    doAssert st.settle(st.answered and st.tiles(0)[^1].raw.len > 0), "no raw samples in the tile"
    proc check(st: AppState; what: string) =
      let t = st.tiles(0)[^1]
      doAssert t.request.decimation == 1 and t.request.stride == 1, what
      for (row, i) in [(2, 100), (7, 250), (20, 400)]:
        let want = surveySample(0, row + 1, t.request.firstSample + i)
        let got = t.raw[row * t.columns + i]
        doAssert got == want, what & ": the raw sample of trace " & $(row + 1) & " at " & $i &
          " is " & $got & ", the file's " & $want
      var at = 300 # a loud sample of trace 8: the flat event
      while abs(surveySample(0, 8, t.request.firstSample + at)) < 0.1: inc at
      var p = pickAt(st.tiles(0), st.panel(MainPanel).layout, DataPoint(x: 7,
        tMs: float64(t.request.firstSample + at) * DtMs))
      p.inside = true
      doAssert p.raw == surveySample(0, 8, t.request.firstSample + at), what & ": " & $p.raw
      doAssert p.text(rfRawAmplitude) == significant(p.raw), what & ": " & p.text(rfRawAmplitude)
      doAssert p.amplitude != p.raw, what & ": the amplitude drawn is the raw one (AGC is on)"
    st.check("as recorded")
    st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
    doAssert st.settle(st.answered and st.tiles(0).len == 1)
    st.check("all reversed")
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[0].base + 7], on: true)
    doAssert st.settle(st.answered and st.tiles(0)[^1].isKilled(7))
    st.check("trace 8 killed")
    s.readout.setLen s.readout.len - 1
    st.apply Command(kind: ckSettings, settings: s)
    doAssert st.settle(st.answered and st.tiles(0)[^1].raw.len == 0)
    st.shutdown()
