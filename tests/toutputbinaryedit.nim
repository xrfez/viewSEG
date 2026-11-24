## The edit state of a binary header set (`view/outputbinaryedit`), without a
## window: a set loaded and read back in file order, only the fields with a
## value in the set, the set's problems, the note each field shows (a value
## that is not a number, one out of the field's range, a Rev 2 field, a field
## that its extended twin replaces), the filter and the "only fields that are
## set" switch, the count, and the byte ranges shown.
##
## Seen to fail: with the values not trimmed, " 7 " made a set with a value
## that the library took but the saved set held the spaces; with the filter
## matching names only, "ensemble" found no label; with the twin note
## dropped, `ensembleFold` beside a set `extEnsembleFold` had no note; with
## the set built in the order typed, not the file's, `toSet` of two fields
## came back reversed.

import std/[os, strutils]
import viewSEG/core/outputbinary
import viewSEG/view/outputbinaryedit

proc at(name: string): int =
  for i, f in BinaryFields:
    if f.name == name: return i
  -1

proc main*() =
  block roundTrip:
    let b = OutputBinary(name: "Survey", entries: @[BinaryEntry(field: "jobId", value: "7"),
      BinaryEntry(field: "sweepLength", value: "10000")])
    let e = initBinaryEdit(b)
    doAssert e.values.len == BinaryFields.len and e.original == "Survey"
    doAssert e.values[at("jobId")] == "7" and e.values[at("sweepLength")] == "10000"
    doAssert e.toSet == b, "a set changed in the editor"
    doAssert e.problem == "" and e.setCount == 2 and e.setNote == "2 fields set"
    doAssert initBinaryEdit().problem == "A binary header set needs a name."
    doAssert initBinaryEdit().setNote == "0 fields set"

  block builtInFileOrder:
    var e = initBinaryEdit()
    e.name = "  x  "
    e.values[at("sweepLength")] = " 5 "
    e.values[at("jobId")] = "1"
    e.values[at("lineNumber")] = "   "
    let s = e.toSet
    doAssert s.name == "x"
    doAssert s.entries == @[BinaryEntry(field: "jobId", value: "1"),
      BinaryEntry(field: "sweepLength", value: "5")], $s.entries
    doAssert e.setNote == "2 fields set" and not e.isSet(at("lineNumber"))
    var one = initBinaryEdit()
    one.values[0] = "3"
    doAssert one.setNote == "1 field set"

  block problems:
    var e = initBinaryEdit()
    e.name = "x"
    e.values[at("ensembleFold")] = "40000"
    doAssert e.problem == "Ensemble fold: 40000 is not from -32768 to 32767.", e.problem
    e.values[at("ensembleFold")] = "4"
    e.values[at("jobId")] = "abc"
    doAssert e.problem == "Job ID: 'abc' is not a whole number.", e.problem
    e.values[at("jobId")] = "9"
    doAssert e.problem == ""

  block notes:
    var e = initBinaryEdit()
    e.name = "x"
    let fold = at("ensembleFold")
    let ext = at("extEnsembleFold")
    doAssert e.fieldNote(fold) == FieldNote(), "an unset field says nothing"
    doAssert e.fieldNote(ext) == FieldNote(text: Rev2Note, warn: false), "a Rev 2 field is said"
    e.values[fold] = "40000"
    doAssert e.fieldNote(fold) == FieldNote(text: "40000 is not from -32768 to 32767.", warn: true)
    e.values[fold] = "x"
    doAssert e.fieldNote(fold).text == "'x' is not a whole number." and e.fieldNote(fold).warn
    e.values[fold] = "4"
    doAssert e.fieldNote(fold) == FieldNote()
    e.values[ext] = "70000"
    doAssert e.fieldNote(ext) == FieldNote(text: Rev2Note, warn: true)
    doAssert e.fieldNote(fold).text == "replaced by Extended ensemble fold in SEG-Y revision " &
      "2, as that is set", e.fieldNote(fold).text
    e.values[ext] = "0"
    doAssert e.fieldNote(fold) == FieldNote(), "a twin set to 0 replaces nothing"
    e.values[ext] = "-1"
    doAssert e.fieldNote(ext).text == "-1 is not from 0 to 4294967295."
    doAssert e.fieldNote(fold) == FieldNote(), "a twin that is not a value replaces nothing"

  block filterAndOnlySet:
    var e = initBinaryEdit()
    doAssert e.shownCount == BinaryFields.len
    e.filter = "ENSEMBLE"
    doAssert e.isShown(at("ensembleFold")) and e.isShown(at("extEnsembleFold"))
    doAssert not e.isShown(at("jobId"))
    e.filter = "job id"
    doAssert e.isShown(at("jobId")) and e.shownCount == 1, "the label is searched too"
    e.filter = "  sweep "
    doAssert e.isShown(at("sweepLength")) and e.isShown(at("sweepFreqStart"))
    e.filter = "nothing like it"
    doAssert e.shownCount == 0
    e.filter = ""
    e.onlySet = true
    doAssert e.shownCount == 0
    e.values[at("jobId")] = "1"
    doAssert e.shownCount == 1 and e.isShown(at("jobId"))
    e.filter = "line"
    doAssert e.shownCount == 0, "the filter and the switch both apply"

  block bytes:
    doAssert bytesLabel(BinaryFields[at("jobId")]) == "3201-3204"
    doAssert bytesLabel(BinaryFields[at("measurementSystem")]) == "3255-3256"
    doAssert bytesLabel(BinaryFields[at("extSampleIntervalOrig")]) == "3281-3288"

  block names:
    doAssert matchingSet(["Survey", "Other"], " survey ")
    doAssert not matchingSet(["Survey"], "")

  block pageListsEveryField:
    let page = readFile(currentSourcePath().parentDir.parentDir / "docs" / "user" /
      "binary-header.md")
    for f in BinaryFields:
      doAssert ("| " & f.label & " | `" & f.name & "` | " & bytesLabel(f) & " |") in page,
        f.name & " is not in binary-header.md as: | " & f.label & " | `" & f.name & "` | " &
          bytesLabel(f) & " |"
    for r in Refused:
      doAssert ("`" & r & "`") in page, r & " (refused) is not named in binary-header.md"

  echo "toutputbinaryedit: ok"

when isMainModule:
  main()
