## The text of an Output run's log (`view/outputlog`), without a window: the
## options in force, the totals, and for every file its row and all its notes
## in file order; a stopped run keeps the files it skipped; a correlated run
## names its reference; the file name offered carries the date and time.
##
## Seen to fail: with the notes cut to the first, "a note is missing"; with the
## skipped rows left out, "a skipped file is not in the log".

import std/[strutils, times]
import viewSEG/core/[outputbatch, outputjobs, outputrevision]
import viewSEG/view/outputlog

proc main*() =
  block name:
    let t = dateTime(2026, mNov, 25, 14, 3, 9, zone = utc())
    doAssert logName(t) == "viewSEG-output-20261125-140309.txt", logName(t)
    doAssert nowText(t) == "2026-11-25 14:03:09"

  var rec = RunRecord(startedAt: "2026-11-25 14:03:09", source: "/in", dest: "/out",
    format: ofSegy, revision: orSegy21, reversals: true, dropKilled: true, ownFilters: false,
    processing: true, processingSentence: "The written traces will be filtered: " &
    "band-pass 5-10-40-60 Hz.", shifts: true, sortOn: true, sort: "channel", mirror: true,
    correlated: true, reference: "Pilot A", pattern: "Line", textHeader: "Survey")
  let res = BatchResult(written: 1, failed: 1, skipped: 1, cancelled: true, items: @[
    BatchItemResult(relative: "a.sgy", destination: "/out/a.sgy", outcome: boWritten,
      writtenTraces: 10, droppedTraces: 2, lines: @["first note", "second note", "third"]),
    BatchItemResult(relative: "sub\\b.sgy", outcome: boFailed, why: "cannot be read"),
    BatchItemResult(relative: "c.sgy", outcome: boSkipped)])

  block everything:
    let text = logText(rec, res, [185360'i64, -1, -1])
    for want in ["Run: 2026-11-25 14:03:09\n", "Source: /in\n", "Destination: /out\n",
        "Format: SEG-Y\n", "Revision: Rev 2.1\n", "Own filters: off\n",
        "Processing: on (The written traces will be filtered: band-pass 5-10-40-60 Hz.)\n",
        "Sort: channel\n", "Correlated: Pilot A\n", "File names: Line\n",
        "Text header: Survey\n", "1 written, 1 failed, 1 skipped.\n",
        "stopped before every file", "  Written as: /out/a.sgy\n", "(185360 bytes)",
        "  Traces: 10 written, 2 dropped\n", "    - first note\n", "    - second note\n",
        "    - third\n", "File: sub/b.sgy\n", "  Result: failed: cannot be read\n"]:
      doAssert want in text, "the log lacks " & want.escape & ":\n" & text
    doAssert text.count("    - ") == 3, "a note is missing"
    doAssert "File: c.sgy" in text and "  Result: skipped" in text,
      "a skipped file is not in the log"
    doAssert text.find("File: a.sgy") < text.find("File: sub/b.sgy") and
      text.find("File: sub/b.sgy") < text.find("File: c.sgy"), "the files are not in order"
    doAssert text.endsWith("\n")

  block segdAndOff:
    rec.format = ofSegd
    rec.processing = false
    rec.correlated = false
    rec.sortOn = false
    let text = logText(rec, BatchResult(), [])
    doAssert "Format: SEG-D\n" in text and "Processing: off\n" in text
    doAssert "Sort: off\n" in text and "Correlated: off\n" in text
    doAssert "Text header" notin text, "a SEG-D run lists a text header"

  echo "toutputlog: ok"

when isMainModule:
  main()
