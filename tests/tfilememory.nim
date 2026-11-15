## The store of what is remembered about files (`core/filememory`): a
## document read back as written (identity, where and when the file was
## seen, the lists, all reversed), trace numbers from 1 in runs, a damaged
## or later document said and never raising anything else, the documents
## of one quick identity found and the rest left, the listing with a file
## gone, and a file's list as CSV read back, with one made by hand.
##
## Seen to fail: with `runsText` writing trace indices from 0, "the runs
## are 2 6-9 119"; with `recordsOf` taking every document of the folder (by
## neither its name nor its identity),
## "another file's document was found".

import std/[os, sequtils, strutils, times]
import viewSEG/core/[edits, filememory, identity, nif]

func lists(killed, reversed: openArray[int]; all = false): EditLists =
  result.lists[teKilled] = @killed
  result.lists[teReversed] = @reversed
  result.allReversed = all

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
    doAssert not readMemory(parseNif(memoryDocument(noFull), "x"), "x", problems).identity.fullKnown
  block damaged:
    var problems: seq[string]
    doAssertRaises NifError: discard readMemory(parseNif("(settings)", "x"), "x", problems)
    doAssertRaises NifError:
      discard readMemory(parseNif("(fileMemory (version 9))", "x"), "x", problems)
    let r = readMemory(parseNif("(fileMemory (identity (size -1) (quick \"zz\")) " &
      "(killed \"1 two 3\" 7) (allReversed maybe) (later (things 1)))", "x"), "x", problems)
    doAssert r.edits.lists[teKilled] == @[0, 2, 6] and not r.edits.allReversed
    doAssert problems.len == 4, $problems
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
    problems.setLen 0
    writeFile(rec.path, newString(123_456))
    let listed = s.listRecords(problems)
    doAssert listed.len == 2 and problems.len == 1, $listed.len & " " & $problems
    for r in listed:
      doAssert r.gone == (r.doc == other.doc), r.doc
      doAssert r.bytes > 0
    writeFile(rec.path, "shorter")
    doAssert s.listRecords(problems).allIt(it.gone), "a file of another size is not this one"
  block csv:
    let l = lists([2, 6], [6], all = true)
    doAssert csvRows(l) == @[2, 6, 6]
    let text = editsCsv(l, [1001.0, 1001, 1001], [3.0, 7, 7])
    doAssert text == CsvHeader & "\nall,,,reversed\n3,1001,3,killed\n7,1001,7,killed\n" &
      "7,1001,7,reversed\n", text
    var problems: seq[string]
    doAssert readEditsCsv(text, "a.csv", problems) == l and problems.len == 0, $problems
    let hand = "Trace;Edit\n5;kill\n6;R\n\n# a note\n9;mute\nx;kill\n"
    let h = readEditsCsv(hand, "hand.csv", problems)
    doAssert h.lists[teKilled] == @[4] and h.lists[teReversed] == @[5]
    doAssert problems.len == 2, $problems
    problems.setLen 0
    doAssert readEditsCsv("5\n6\n", "bare.csv", problems).isEmpty and problems.len == 1
    var fid: FileIdentity
    var has: bool
    doAssertRaises ValueError:
      discard readEdits("5\n6\n", "bare.csv", [], "", problems, fid, has)
    problems.setLen 0
    let fromNif = readEdits("", "x.nif", parseNif(memoryDocument(rec), "x.nif"), "", problems,
      fid, has)
    doAssert fromNif == rec.edits and has and fid == id
  block words:
    doAssert keptWords(lists([1, 2], [], all = true)) == "2 killed, all reversed"
    doAssert keptWords(EditLists()) == "nothing"
finally:
  removeDir(dir)
echo "tfilememory: ok"
