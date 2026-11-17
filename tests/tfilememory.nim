## The store of what is remembered about files (`core/filememory`): a
## document read back as written (identity, where and when the file was
## seen, the lists, all reversed), trace numbers from 1 in runs, a damaged
## or later document said and never raising anything else, the documents
## of one quick identity found and the rest left (a part edited by hand
## that cannot be read said, the rest brought back), a later version's
## parts written back as they were, the listing with a file gone and one
## whose folder is not there (not gone), and a file's list as CSV read back
## (naming its file on every row), with one made by hand and one as a
## spreadsheet saves it; a list naming far more traces than the file has
## cut at its last before anything is expanded, and a list's total bounded.
##
## Seen to fail: with `runsText` writing trace indices from 0, "the runs
## are 2 6-9 119"; with `recordsOf` taking every document of the folder (by
## neither its name nor its identity),
## "another file's document was found"; with the problems of a document
## read dropped in `recordsOf`, "a part not read was not said"; with
## `later` not written, "a later version's part is dropped"; with a missing
## folder taken as a file gone, "a file on a drive not connected counts as
## gone"; with the byte order mark left on the header, "a byte order mark:
## no line at its start names a trace column"; the old reader (cells split
## at every `,`, `;` and tab, no quotes) took the spreadsheet's table as
## having no trace column; with the runs expanded first and cut at the
## file's last trace after, "the runs were expanded before the cut: 39 MB
## more" (merged; as `readRuns` was, each run on its own, 320 MB).

import std/[os, sequtils, strutils, times]
import viewSEG/core/[edits, filememory, identity, nif]

func lists(killed, reversed: openArray[int]; all = false): EditLists =
  result.lists[teKilled] = @killed
  result.lists[teReversed] = @reversed
  result.allReversed = all

proc main*() =

  block runs:
    doAssert runsText([2, 6, 7, 8, 119]) == "3 7-9 120", "the runs are " & runsText([2, 6, 7, 8, 119])
    doAssert runsText([]) == "" and runsText([0]) == "1"
    var t: seq[int]
    var problems: seq[string]
    readRuns("3 7-9 120 9 x 5-2 0", t, problems, "killed")
    doAssert t == @[2, 6, 7, 8, 119], $t
    doAssert problems.len == 3 and "\"x\"" in problems[0], $problems

  let dir = getTempDir() / "viewSEG-tfilememory-" & $getCurrentProcessId()
  createDir(dir)
  try:
    let id = FileIdentity(size: 123_456, quick: 0x1234_5678_9abc_def0'u64, full: 42,
      fullKnown: true)
    let rec = FileRecord(identity: id, name: "shot 12.sgd", path: dir / "shot 12.sgd",
      opened: initTime(1_763_200_961, 0), modified: initTime(1_763_100_000, 120_000_000),
      edits: lists([2, 6, 7, 8, 119], [11], all = true), doc: docName(id, 1))
    block document:
      let text = memoryDocument(rec)
      doAssert "(killed \"3 7-9 120\")" in text and "(reversed \"12\")" in text, text
      var problems: seq[string]
      let back = readMemory(parseNif(text, "x"), rec.doc, problems)
      doAssert problems.len == 0, $problems
      doAssert back.identity == id and back.name == rec.name and back.path == rec.path
      doAssert back.opened == rec.opened and back.modified == rec.modified
      doAssert back.edits == rec.edits and back.doc == rec.doc
      var noFull = rec
      noFull.identity.fullKnown = false
      doAssert "full" notin memoryDocument(noFull)
      doAssert not readMemory(parseNif(memoryDocument(noFull), "x"), "x",
          problems).identity.fullKnown
    block damaged:
      var problems: seq[string]
      doAssertRaises NifError: discard readMemory(parseNif("(settings)", "x"), "x", problems)
      doAssertRaises NifError:
        discard readMemory(parseNif("(fileMemory (version 9))", "x"), "x", problems)
      let r = readMemory(parseNif("(fileMemory (identity (size -1) (quick \"zz\")) " &
        "(killed \"1 two 3\" 7) (allReversed maybe) (later (things 1)))", "x"), "x", problems)
      doAssert r.edits.lists[teKilled] == @[0, 2, 6] and not r.edits.allReversed
      doAssert problems.len == 4, $problems
    block later:
      # what a later version adds to a document is written back as it was
      var problems: seq[string]
      let text = memoryDocument(rec).replace("(allReversed true)",
        "(allReversed true)\n (processing (band lowCut) (corners 4.5 8 \"x\" (f bad)))")
      let r = readMemory(parseNif(text, "x"), "x", problems)
      doAssert problems.len == 0 and not r.damaged, $problems
      let again = memoryDocument(r)
      doAssert "(processing (band lowCut) (corners 4.5 8 \"x\" (f bad)))" in again,
        "a later version's part is dropped: " & again
      doAssert memoryDocument(readMemory(parseNif(again, "x"), "x", problems)) == again
    block names:
      doAssert docName(id, 2) == "1e240-123456789abcdef0-2.nif"
      doAssert docName(id, 1).isDocName and not "settings.nif".isDocName and
        not "1e240-123-1.nif".isDocName
      doAssert freeDocName(id, [docName(id, 1), docName(id, 3)]) == docName(id, 2)
    block store:
      let s = Store(home: dir / StoreFolder)
      var taken: seq[string]
      var problems: seq[string]
      doAssert s.recordsOf(id, taken, problems).len == 0, "a store not made yet holds nothing"
      createDir(s.home)
      writeFile(s.docPath(rec.doc), memoryDocument(rec))
      var other = rec
      other.identity.quick = 7
      other.doc = docName(other.identity, 1)
      other.path = dir / "gone.sgd"
      writeFile(s.docPath(other.doc), memoryDocument(other))
      writeFile(s.docPath(docName(id, 2)), "(fileMemory (version")
      writeFile(s.home / "notes.txt", "a person's notes")
      let found = s.recordsOf(id, taken, problems)
      doAssert found.len == 1 and found[0].edits == rec.edits, "another file's document was found"
      doAssert taken.len == 2 and problems.len == 1 and docName(id, 2) in problems[0], $problems
      # a document edited by hand with a part that is not a trace number: the
      # rest is brought back, the part said, the document marked damaged
      var hand = memoryDocument(rec).replace("(killed \"3 7-9 120\")", "(killed \"3 7-9 x 120\")")
      writeFile(s.docPath(rec.doc), hand)
      problems.setLen 0
      taken.setLen 0
      let handFound = s.recordsOf(id, taken, problems)
      doAssert handFound.len == 1 and handFound[0].edits.lists[teKilled] == @[2, 6, 7, 8, 119]
      doAssert handFound[0].damaged and problems.len == 2 and
        problems.anyIt("\"x\"" in it and rec.doc in it), "a part not read was not said: " & $problems
      writeFile(s.docPath(rec.doc), memoryDocument(rec))
      problems.setLen 0
      writeFile(rec.path, newString(123_456))
      let listed = s.listRecords(problems)
      doAssert listed.len == 2 and problems.len == 1, $listed.len & " " & $problems
      for r in listed:
        doAssert r.gone == (r.doc == other.doc), r.doc
        doAssert r.bytes > 0
      writeFile(rec.path, "shorter")
      doAssert s.listRecords(problems).allIt(it.gone), "a file of another size is not this one"
      # a file in a folder that is not there (a network drive not connected)
      # is not gone: "Remove the gone" must not take it
      var away = rec
      away.path = dir / "share not connected" / "shot 12.sgd"
      away.doc = docName(id, 3)
      writeFile(s.docPath(away.doc), memoryDocument(away))
      let three = s.listRecords(problems)
      doAssert three.len == 3
      for r in three:
        if r.doc == away.doc:
          doAssert not r.gone and r.unreached, "a file on a drive not connected counts as gone"
      removeFile(s.docPath(away.doc))
    block csv:
      let l = lists([2, 6], [6], all = true)
      doAssert csvRows(l) == @[2, 6, 6]
      let text = editsCsv(l, [1001.0, 1001, 1001], [3.0, 7, 7], "shot, 12.sgd")
      doAssert text == CsvHeader & "\nall,,,reversed,\"shot, 12.sgd\"\n" &
        "3,1001,3,killed,\"shot, 12.sgd\"\n7,1001,7,killed,\"shot, 12.sgd\"\n" &
        "7,1001,7,reversed,\"shot, 12.sgd\"\n", "the export does not name its file: " & text
      var problems: seq[string]
      doAssert readEditsCsv(text, "a.csv", problems) == l and problems.len == 0, $problems
      # as a spreadsheet saves it: a byte order mark, CRLF, every cell quoted,
      # a title row above the header, a column of notes with commas in them
      let sheet = "\xEF\xBB\xBF\"Bad traces, line 7\",,\r\n\"Trace\",\"Note\",\"Edit\"\r\n" &
        "\"3\",\"noisy, \"\"very\"\"\",\"killed\"\r\n7.0,,Reversed\r\n"
      let fromSheet = readEditsCsv(sheet, "sheet.csv", problems)
      doAssert problems.len == 0 and fromSheet.lists[teKilled] == @[2] and
        fromSheet.lists[teReversed] == @[6], "a spreadsheet's table: " & $problems & " " & $fromSheet
      doAssert csvCells("a;\"b;c\";d", ';') == @["a", "b;c", "d"]
      let bom = readEditsCsv("\xEF\xBB\xBFtrace,edit\r\n4,kill\r\n", "bom.csv", problems)
      doAssert problems.len == 0 and bom.lists[teKilled] == @[3], "a byte order mark: " & $problems
      let hand = "Trace;Edit\n5;kill\n6;R\n\n# a note\n9;mute\nx;kill\n"
      let h = readEditsCsv(hand, "hand.csv", problems)
      doAssert h.lists[teKilled] == @[4] and h.lists[teReversed] == @[5]
      doAssert problems.len == 2, $problems
      problems.setLen 0
      doAssert readEditsCsv("5\n6\n", "bare.csv", problems).isEmpty and problems.len == 1
      var fid: FileIdentity
      var has: bool
      var outside = 0
      doAssertRaises ValueError:
        discard readEdits("5\n6\n", "bare.csv", [], "", high(int), problems, fid, has, outside)
      problems.setLen 0
      let fromNif = readEdits("", "x.nif", parseNif(memoryDocument(rec), "x.nif"), "", high(int),
        problems, fid, has, outside)
      doAssert fromNif == rec.edits and has and fid == id and outside == 0
    block bounded:
      # a list from elsewhere naming far more traces than the file has: cut
      # at the file's last trace before anything is expanded (eight runs of
      # five million were 40 million indices, 320 MB, before the cut), and a
      # list's total bounded, what is past the bound said
      var problems: seq[string]
      var fid: FileIdentity
      var has: bool
      var outside = 0
      let text = "(fileMemory (version 1) (killed" & " \"1-5000000\"".repeat(8) & " 7))"
      let peak = getMaxMem()
      let l = readEdits("", "far.nif", parseNif(text, "far.nif"), "", 1000, problems, fid, has,
        outside)
      doAssert getMaxMem() - peak < 32 shl 20, "the runs were expanded before the cut: " &
        $((getMaxMem() - peak) shr 20) & " MB more"
      doAssert l.lists[teKilled].len == 1000 and l.lists[teKilled][^1] == 999, $l.lists[teKilled].len
      doAssert outside == 5_000_000 - 1000, "the traces past the file's last are not counted: " &
        $outside
      doAssert problems.len == 0, $problems
      outside = 0
      let csv = readEdits("trace\n3\n2000\n4\n", "far.csv", [], "", 1000, problems, fid, has,
        outside)
      doAssert csv.lists[teKilled] == @[2, 3] and outside == 1, $outside
      var t: seq[int]
      readRuns("1-30 41-50 20-35", t, problems, "killed", bound = 25)
      doAssert t.len == 25 and t[^1] == 24, $t
      doAssert problems.len == 1 and "left out" in problems[0], $problems
    block mergedFromTwo:
      # a document two programs changed from one base: each change kept
      let base = lists([1, 2, 3], [7])
      let ours = lists([1, 3, 4], [7], all = true) # 2 restored, 4 killed, all reversed
      let theirs = lists([1, 2, 3, 9], []) # 9 killed, 7 put back
      let m = merged(base, ours, theirs)
      doAssert m.lists[teKilled] == @[1, 3, 4, 9] and m.lists[teReversed].len == 0 and
        m.allReversed, $m
    block words:
      doAssert keptWords(lists([1, 2], [], all = true)) == "2 killed, all reversed"
      doAssert keptWords(EditLists()) == "nothing"
  finally:
    removeDir(dir)
  echo "tfilememory: ok"

when isMainModule:
  main()
