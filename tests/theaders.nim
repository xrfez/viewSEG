## The Headers window's models in `core` and `view`, filled from each
## fixture: the Summary tab's lines (what the file is, the record shown and
## its counts, a SEG-D record's channel sets), read when the file is opened
## (`Session.facts`, on the open job's thread), for SEG-Y, SEG-D and SEG-2.
##
## Seen to fail: with the summary's record taken from the first gather
## whatever is shown (`s.records[0]`), `summaryOfASegyFile` found no FFID
## 12 for the second record.

import std/[os, strutils]
import parseSEG
import viewSEG/core/[fielddocs, state]
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
