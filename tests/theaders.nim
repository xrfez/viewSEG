## The Headers window's models in `core` and `view`, filled from each
## fixture: the Summary tab's lines (what the file is, the record shown and
## its counts, a SEG-D record's channel sets), read when the file is opened
## (`Session.facts`, on the open job's thread), for SEG-Y, SEG-D and SEG-2.
##
## The File headers tab's: a SEG-Y file's binary header fields and textual
## header, a SEG-D record's general headers, channel sets side by side (the
## fields that differ marked), and its extended and external headers as
## bytes, read by the Headers window's reader (`core/inspector`) off the UI
## thread when the tab is on screen (`ckInspect`).
##
## Seen to fail: with the summary's record taken from the first gather
## whatever is shown (`s.records[0]`), `summaryOfASegyFile` found no FFID
## 12 for the second record; with the inspector keeping its holds,
## `inspectorReadsTheRecordShown` found "the inspector's hold did not end".

import std/[intsets, os, strutils]
import parseSEG
import viewSEG/core/[fielddocs, inspector, state]
import viewSEG/view/headerviews
import utils/[fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func valueOf(lines: openArray[SummaryLine]; label: string; nth = 0): string =
  ## The value of the `nth` line labelled `label`; "" when there is none.
  var k = 0
  for l in lines:
    if not l.heading and l.label == label:
      if k == nth: return l.value
      inc k
  ""

func hasHeading(lines: openArray[SummaryLine]; start: string): bool =
  for l in lines:
    if l.heading and l.label.startsWith(start): return true
  false

proc shown(st: var AppState; path: string): Session =
  ## Opens `path` in the main panel and waits until it is shown.
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path
  st.sessions[0]

block summaryOfASegyFile:
  withFixtures fx:
    var st = initAppState()
    let s = st.shown(fx.surveySegy())
    let facts = s.facts
    doAssert facts.problems.len == 0, $facts.problems
    doAssert facts.summary.standard == skSegy and $facts.summary.revision == "2.1"
    doAssert facts.textEncoding in ["EBCDIC", "ASCII"]
    doAssert facts.text.len == 40 and facts.text[0].startsWith("C 1 C01 viewSEG test fixture") and
      facts.text[0].len == 80,
      $facts.text[0 .. 2]
    let lines = summaryLines(s, 1)
    doAssert lines.valueOf("Name") == "survey-clean.sgy"
    doAssert lines.valueOf("Standard") == "SEG-Y revision 2.1", lines.valueOf("Standard")
    doAssert lines.valueOf("Sample format") == "5: IEEE float, 4 bytes"
    doAssert lines.valueOf("Samples decodable") == "yes"
    doAssert lines.valueOf("Traces") == $SurveyTraces
    doAssert lines.valueOf("Records") == $Shots
    doAssert lines.valueOf("Field records (FFID)") == $FirstRecord & " to " &
      $(FirstRecord + Shots - 1)
    doAssert lines.valueOf("Samples per trace") == $Samples
    doAssert lines.valueOf("Sample interval") == "2 ms"
    doAssert lines.valueOf("Record length") == $(float64(Samples - 1) * DtMs).int & " ms"
    doAssert lines.valueOf("Units") == "metres", lines.valueOf("Units")
    # the record shown (the second): what tells it apart and its counts
    doAssert lines.hasHeading("The record shown: 2 of 3")
    doAssert lines.valueOf("Kind") == "shot record"
    doAssert lines.valueOf("FFID") == $(FirstRecord + 1)
    doAssert lines.valueOf("Source") == $(int(FirstSrcPoint) + 1), # no source line in it
      lines.valueOf("Source")
    doAssert lines.valueOf("Traces", 1) == $Channels & " (from trace " & $(Channels + 1) & ")"
    doAssert lines.valueOf("Seismic") == $Channels and lines.valueOf("Auxiliary") == "0"
    doAssert lines.valueOf("Dead") == "0"
    doAssert not lines.hasHeading("Channel sets")
    # copied as text: a value after its label and a tab
    doAssert "Sample interval\t2 ms\n" in summaryText(lines)
    st.shutdown()

block summaryOfARecordShortOfTraces:
  withFixtures fx:
    var st = initAppState()
    let s = st.shown(fx.patchySegy())
    let short = summaryLines(s, PatchyShort)
    doAssert short.valueOf("Missing") == "5 of the " & $Channels &
      " seismic traces the file declares", short.valueOf("Missing")
    let dead = summaryLines(s, 1)
    doAssert dead.valueOf("Dead") == $PatchyDead.len, dead.valueOf("Dead")
    st.shutdown()

block summaryOfASegdRecord:
  withFixtures fx:
    var st = initAppState()
    let s = st.shown(fx.twoSetSegd())
    doAssert s.facts.problems.len == 0, $s.facts.problems
    doAssert s.facts.text.len == 0 and s.facts.textEncoding == ""
    let lines = summaryLines(s, 0)
    doAssert lines.valueOf("Standard") == "SEG-D revision 3.0", lines.valueOf("Standard")
    doAssert lines.valueOf("Sample format") == "8058: IEEE float, 4 bytes, demultiplexed"
    doAssert lines.valueOf("Byte order") == "" # always big-endian: not said
    doAssert lines.valueOf("File numbers") == $SegdRecordNo
    doAssert lines.hasHeading("Channel sets of the record shown (SEG-D record 1)")
    doAssert lines.valueOf("Set 1").startsWith("time break, 1 trace, " & $SegdSamples &
      " samples at 2 ms"), lines.valueOf("Set 1")
    doAssert lines.valueOf("Set 3") == "seismic, " & $SegdChannels & " traces, " &
      $SegdSamples & " samples at 2 ms, 0 to " & $(float64(SegdSamples - 1) * DtMs).int &
      " ms", lines.valueOf("Set 3")
    doAssert lines.valueOf("Set 5") == ""
    doAssert lines.valueOf("Auxiliary") == "2", lines.valueOf("Auxiliary")
    doAssert lines.valueOf("Seismic") == $(2 * SegdChannels)
    st.shutdown()

block summaryOfTheDemoFiles:
  # A post-stack SEG-Y line with extended textual headers, a SEG-D shot, a
  # SEG-D record of Rev 2 and a SEG-2 line: every one says what it is.
  withFixtures fx:
    for name in demoFileNames:
      var st = initAppState()
      let s = st.shown(fx.demoFile(name))
      doAssert s.facts.problems.len == 0, name & ": " & $s.facts.problems
      let lines = summaryLines(s, 0)
      doAssert lines.valueOf("Name") == name
      doAssert lines.valueOf("Traces") == $s.len, name
      doAssert lines.valueOf("Samples decodable") == "yes", name
      case s.file.kind
      of skSegy:
        doAssert s.facts.extendedText.len > 0, name
        doAssert lines.valueOf("Extended textual headers") == $s.facts.extendedText.len
        doAssert lines.valueOf("Sample format") == "1: IBM float, 4 bytes", name
      of skSegd:
        doAssert lines.hasHeading("Channel sets of the record shown"), name
      of skSeg2:
        doAssert lines.valueOf("Standard").startsWith("SEG-2 revision"), name
        doAssert lines.valueOf("Byte order") == "little-endian", name
      of skUnknown: doAssert false, name
      st.shutdown()

func rowOf(rows: openArray[FieldRow]; blockName, field: string): FieldRow =
  for r in rows:
    if r.blockName == blockName and r.field == field: return r
  raise newException(KeyError, "no " & blockName & "." & field)

block fileHeadersOfASegyFile:
  # The binary header's fields with their bytes in the block, the textual
  # header's 40 lines; a table of them with the block's title first.
  withFixtures fx:
    var st = initAppState()
    let s = st.shown(fx.surveySegy())
    let format = s.facts.rows.rowOf("binary", "formatCode")
    doAssert format.value == "5" and format.number == 5, $format
    doAssert (format.first, format.last) == (25, 26), $format # bytes 3225-3226
    doAssert format.offset == 3224 and format.blockOffset == 3200 and format.blockSize == 400
    doAssert format.description == "Data sample format code"
    let table = fieldTable([s.facts.rows], ["Value"], skSegy)
    doAssert table.rows[0].title.startsWith("Textual header (text, 3200 bytes at 0)"),
      table.rows[0].title
    var found = false
    for row in table.rows:
      if row.name == "binary.formatCode":
        doAssert row.bytes == "25-26" and row.values == @["5"] and not row.differs, $row
        found = true
    doAssert found
    doAssert "Data sample format code\t5\n" in tableText(table)
    st.shutdown()

block recordHeadersOfASegdRecord:
  # A SEG-D record's general headers, channel sets, extended and external
  # headers (their bytes), read as the inspector reads them.
  withFixtures fx:
    var f = openSeismic(fx.areasSegd(), keys = true)
    doAssert not f.log.hasErrors, $f.log.len
    let r = readRecordHeaders(f, 0)
    doAssert r.problem.len == 0, r.problem
    doAssert r.rows.rowOf("gh1", "formatCode").value == "8058"
    doAssert r.rows.rowOf("gh1", "formatCode").description == "Data sample format code"
    var sets: seq[seq[FieldRow]]
    for x in r.rows:
      if x.blockName.startsWith("st") and "cs" in x.blockName:
        if sets.len == 0 or sets[^1][0].blockName != x.blockName: sets.add @[]
        sets[^1].add x
    doAssert sets.len == 4
    let table = fieldTable(sets, ["1", "2", "3", "4"], skSegd, byBlock = false)
    for row in table.rows:
      if row.name.endsWith(".channelType"):
        doAssert row.values == @["32", "152", "16", "16"] and row.differs, $row
      if row.name.endsWith(".scanTypeNumber"):
        doAssert row.values == @["1", "1", "1", "1"] and not row.differs, $row
    var areas: seq[RawBlock] # (the record's untyped general header block is raw too)
    for b in r.raw:
      if b.blockName in ["extended", "external"]: areas.add b
    doAssert areas.len == 2, $r.raw.len
    doAssert areas[0].blockName == "extended" and areas[0].size == 32
    doAssert areas[1].blockName == "external" and areas[1].size == 64
    var text = ""
    for b in areas[1].bytes: text.add char(b)
    doAssert text.startsWith(SegdExternalText), text
    doAssert dumpLines(areas[1].bytes) == 4
    let line = dumpLine(areas[1].bytes, areas[1].offset, 0)
    doAssert line.startsWith(toHex(areas[1].offset, 8) & "  76 69 65 77") and
      line.endsWith(SegdExternalText[0 .. 15]), line
    doAssert readRecordHeaders(openSeismic(fx.surveySegy()), 0).rows.len == 0 # not SEG-D
    f.close()

block inspectorReadsTheRecordShown:
  # The File headers tab on screen (`ckInspect`): the record's headers are
  # read off the UI thread and come with the next drained answer; the
  # inspector's hold on the file ends; off screen, nothing is kept.
  withFixtures fx:
    var st = initAppState()
    let path = fx.areasSegd()
    discard st.shown(path)
    let reader = st.jobs.held(path) # the panel's reader's
    st.apply Command(kind: ckInspect, inspect: {ipRecord})
    doAssert st.inspection.answer.recordPath == "", "read on the UI thread"
    doAssert st.settle(st.inspection.answer.recordPath == path)
    let r = st.inspection.answer.record
    doAssert r.record == 0 and r.rows.len > 0 and r.raw.len == 3, r.problem
    doAssert not st.inspection.waiting
    doAssert waitUntil(st.jobs.held(path) == reader), "the inspector's hold did not end"
    st.apply Command(kind: ckInspect, inspect: {})
    doAssert st.inspection.answer.recordPath == "" and st.inspection.answer.traces.len == 0
    st.shutdown()

block whichTracesTheTraceTabShows:
  # The selection; else the trace under the plot's pointer; else the traces
  # of the receiver under the map's pointer; else those pointed at last
  # (while "Follow the pointer" is on); the first 32, by id.
  var sel = Selection()
  doAssert chosenTraces(sel, true).by == cbNone
  sel.hover = 7
  doAssert chosenTraces(sel, true) == Chosen(by: cbPlotPointer, traces: @[7], total: 1)
  doAssert chosenTraces(sel, false).by == cbNone
  sel.hover = -1
  sel.hoverTraces = toIntSet([5, 3])
  doAssert chosenTraces(sel, true) == Chosen(by: cbMapPointer, traces: @[3, 5], total: 2)
  sel.hoverTraces = initIntSet()
  let last = Chosen(by: cbPlotPointer, traces: @[7], total: 1)
  doAssert chosenTraces(sel, true, last) == last, "the trace pointed at last went"
  doAssert chosenTraces(sel, false, last).by == cbNone
  doAssert chosenTraces(sel, true, Chosen(by: cbSelection, traces: @[2], total: 1)).by == cbNone
  for t in countdown(139, 100): sel.selected.incl t
  let many = chosenTraces(sel, true, last)
  doAssert many.by == cbSelection and many.total == 40 and many.traces.len == MaxInspected
  doAssert many.traces[0] == 100 and many.traces[^1] == 100 + MaxInspected - 1

block inspectorReadsTraces:
  # The Trace tab on screen: the chosen traces' header fields and samples,
  # read off the UI thread; as recorded, then as displayed (a kill blanks a
  # trace, a reversal negates it, the display gain processes them).
  withFixtures fx:
    var st = initAppState()
    let path = fx.surveySegy()
    let s = st.shown(path)
    let reader = st.jobs.held(path)
    st.apply Command(kind: ckSelect, traces: @[s.base + 3, s.base + 7], mode: smReplace)
    st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders, ipTraceSamples})
    doAssert st.inspection.chosen.by == cbSelection
    doAssert st.inspection.answer.traces.len == 0, "read on the UI thread"
    doAssert st.settle(st.inspection.answer.traces.len == 2)
    for (k, channel) in [(0, 4), (1, 8)]:
      let d = st.inspection.answer.traces[k]
      doAssert d.problem.len == 0, d.problem
      doAssert d.id == s.base + channel - 1 and d.trace == channel - 1 and d.file == s.name
      doAssert d.rows.rowOf("trace", "fieldRecord").value == $FirstRecord
      doAssert d.rows.rowOf("trace", "fieldRecord").description ==
        fieldDescription(hbSegyTrace, "fieldRecord")
      doAssert d.samples.len == Samples and not d.displayed and d.dtMs == DtMs
      for i in 0 ..< Samples:
        doAssert d.samples[i] == surveySample(0, channel, i), $i
    let traces = st.inspection.answer.traces
    let table = fieldTable([traces[0].rows, traces[1].rows], ["4", "8"], skSegy)
    for row in table.rows:
      if row.name == "trace.fieldRecord": doAssert not row.differs, $row
      if row.name == "trace.groupX": doAssert row.differs, $row
    doAssert "Trace 4" in traceLabel(traces[0], false)
    doAssert dataText(traces).startsWith("0\t0\t" & sampleText(surveySample(0, 4, 0)) & '\t')
    doAssert waitUntil(st.jobs.held(path) == reader), "the inspector's hold did not end"
    # As displayed, with no gain: the killed trace blank, the reversed one negated.
    var d = st.panel(MainPanel).layers[0].display
    d.gain = dgNone
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s.base + 3],
      on: true)
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teReversed, edited: @[s.base + 7],
      on: true)
    var settings = st.settings
    settings.headers.asDisplayed = true
    st.apply Command(kind: ckSettings, settings: settings)
    doAssert st.settle(st.inspection.answer.traces.len == 2 and
      st.inspection.answer.traces[0].displayed and not st.inspection.waiting)
    let shown = st.inspection.answer.traces
    for i in 0 ..< Samples:
      doAssert shown[0].samples[i] == 0, "the killed trace's sample " & $i
      doAssert shown[1].samples[i] == -surveySample(0, 8, i), "the reversed trace's sample " & $i
    # AGC: processed, so other values than recorded, all finite.
    d.gain = dgAgc
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    let before = st.inspection.answer.gen
    doAssert st.settle(st.inspection.answer.gen > before and not st.inspection.waiting)
    let agc = st.inspection.answer.traces[1]
    var other = false
    for i in 0 ..< Samples:
      doAssert abs(agc.samples[i]) < Inf
      if agc.samples[i] != -surveySample(0, 8, i): other = true
    doAssert other, "AGC changed nothing"
    # Off screen: nothing is kept, nothing is read.
    st.apply Command(kind: ckInspect, inspect: {})
    doAssert st.inspection.answer.traces.len == 0
    st.shutdown()

block everyFieldDescribed:
  # Every field parseSEG names has words of its own, short enough for a
  # table's column.
  for k in HeaderBlock:
    for n in fieldNames(k):
      let d = fieldDescription(k, n)
      doAssert d.len > 0 and d.len <= 70, $k & "." & n & ": " & d
  doAssert fieldDescription(hbSegyTrace, "sourceX").startsWith("Source X coordinate")
  doAssert fieldDescription(hbSegyBinary, "formatCode") == "Data sample format code"
  doAssert fieldDescription(hbSeg2Trace, "SAMPLE_INTERVAL") == "Sample interval"
  doAssert wordsOf("receiverLineNumber") == "Receiver line number"
  doAssert wordsOf("tuple1Coord1") == "Tuple 1 coord 1" and wordsOf("") == ""

block wordsOfHeaderBlocks:
  doAssert blockTitle("trace", skSegy) == "Trace header"
  doAssert blockTitle("ext1", skSegd) == "Trace header extension 1"
  doAssert blockTitle("gh12", skSegd) == "General header 12"
  doAssert blockTitle("st1cs3", skSegd) == "Channel set 3 (scan type 1)"
  doAssert blockTitle("st2skew", skSegd) == "Skew (scan type 2)"
  doAssert blockTitle("extended", skSegd) == "Extended header"
  doAssert blockTitle("extended", skSegy) == "Extended textual headers"
  doAssert blockTitle("label", skSegd) == "Storage unit label"
  doAssert blockTitle("file", skSeg2) == "File descriptor block"
  doAssert grouped(1234567) == "1 234 567" and grouped(-1000) == "-1 000" and grouped(12) == "12"
  doAssert bytesText(1) == "1 byte" and bytesText(2048) == "2 048 bytes (2.0 KiB)"
  doAssert latin1("caf\xE9\x01") == "café."
  doAssert exactText(2.0) == "2" and exactText(0.1) == "0.1"
