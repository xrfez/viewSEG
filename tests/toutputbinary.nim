## SEG-Y binary header sets (`core/outputbinary`): a set's problems in one
## sentence each (no name, an unknown or refused field, a field given twice,
## a value that is not a number, a whole number outside the field's width),
## the entries as the library's overrides for each revision, a Rev 2 field
## and a hidden 16-bit field left out of a file that cannot hold them with a
## sentence, and the list of settable fields agreeing with the library: a
## real writer takes every listed field and refuses every one the list left
## out.
##
## Seen to fail: with `sampleInterval` taken out of `Refused`, `sampleInterval`
## was a field that can be set; with the Rev 2 check
## of `overridesOf` removed, a Rev 1 file got `binary.timeBasisCode` and the
## writer refused; with the 16-bit range taken as 32-bit, 40000 for the
## ensemble fold was kept; with the twin check removed, Rev 2.1 got both
## `ensembleFold` and `extEnsembleFold`, which the writer refuses.

import std/[options, strutils]
import parseSEG
import viewSEG/core/outputbinary

proc set1(entries: varargs[(string, string)]): OutputBinary =
  result = OutputBinary(name: "Survey")
  for (f, v) in entries: result.entries.add BinaryEntry(field: f, value: v)

const R0 = SegyRevision(major: 0, minor: 0)
const R1 = SegyRevision(major: 1, minor: 0)
const R20 = SegyRevision(major: 2, minor: 0)
const R21 = SegyRevision(major: 2, minor: 1)

proc opens(rev: SegyRevision; over: seq[HeaderOverride]): bool =
  ## A real writer takes `over`, for a file of revision `rev`.
  try:
    var w = openSeismicWriterBytes(SegyOutputOptions(revision: rev, binaryOverrides: over))
    var k = initTraceKeys()
    k.intervalUs = 2000
    w.writeTrace(k, @[1'f32, 2])
    discard w.finishBytes()
    result = true
  except ValueError:
    result = false

proc main*() =
  block problems:
    doAssert binaryProblem(set1(("jobId", "7"))) == ""
    doAssert binaryProblem(OutputBinary(name: "Empty")) == ""
    doAssert binaryProblem(OutputBinary(name: "  ")) == "A binary header set needs a name."
    var longName = OutputBinary(name: repeat('a', 65))
    doAssert binaryProblem(longName) ==
      "A binary header set's name is at most 64 characters long."
    doAssert binaryProblem(OutputBinary(name: "a\tb")) ==
      "A binary header set's name holds no control characters."
    doAssert binaryProblem(set1(("nope", "1"))) ==
      "'nope' is not a binary header field that can be set."
    doAssert binaryProblem(set1(("sampleInterval", "1"))) ==
      "'sampleInterval' is not a binary header field that can be set."
    doAssert binaryProblem(set1(("samplesPerTrace", "1"))).contains("can be set")
    doAssert binaryProblem(set1(("jobId", "1"), ("jobId", "2"))) == "Job ID is given twice."
    doAssert binaryProblem(set1(("jobId", "abc"))) == "Job ID: 'abc' is not a whole number."
    doAssert binaryProblem(set1(("jobId", "1.5"))) == "Job ID: '1.5' is not a whole number."
    doAssert binaryProblem(set1(("jobId", ""))) == "Job ID: '' is not a whole number."
    doAssert binaryProblem(set1(("jobId", "1_0"))).contains("not a whole number")
    doAssert binaryProblem(set1(("ensembleFold", "40000"))) ==
      "Ensemble fold: 40000 is not from -32768 to 32767."
    doAssert binaryProblem(set1(("ensembleFold", "-32768"))) == ""
    doAssert binaryProblem(set1(("extEnsembleFold", "-1"))) ==
      "Extended ensemble fold: -1 is not from 0 to 4294967295."
    doAssert binaryProblem(set1(("extEnsembleFold", "4294967295"))) == ""
    doAssert binaryProblem(set1(("extSampleIntervalOrig", "4000.5"))) == ""
    doAssert binaryProblem(set1(("extSampleIntervalOrig", "nan"))) ==
      "Extended sample interval original: 'nan' is not a number."
    doAssert binaryProblem(set1(("extSampleIntervalOrig", "x"))).contains("not a number")

  block fields:
    doAssert fieldInfo("jobId").get.firstByte == 3201 and fieldInfo("jobId").get.bytes == 4
    doAssert fieldInfo("extSampleIntervalOrig").get.kind == bkFloat
    doAssert fieldInfo("timeBasisCode").get.rev2 and not fieldInfo("jobId").get.rev2
    doAssert fieldInfo("sampleInterval").isNone and fieldInfo("unassigned1").isNone
    doAssert fieldInfo("maxAddlTraceHeaders").isNone and fieldInfo("surveyType").isNone
    for i in 1 ..< BinaryFields.len:
      doAssert BinaryFields[i].firstByte > BinaryFields[i - 1].firstByte, "file order"
    for f in BinaryFields:
      doAssert f.firstByte in 3201 .. 3600 and f.label.len > 0

  block agrees_with_the_library:
    # Every listed field is taken, every other one the table has is refused.
    for f in BinaryFields:
      let o = set1((f.name, "1")).overridesOf(R21)
      doAssert o.overrides.len == 1 and o.notes.len == 0
      doAssert opens(R21, o.overrides), "the writer refused a listed field: " & f.name
    for f in binaryHeaderFields:
      if fieldInfo(f.name).isNone and f.kind in {fkInt, fkUInt, fkFloat}:
        doAssert not opens(R21, @[headerOverride("binary." & f.name, 1)]),
          "the writer took a field the list leaves out: " & f.name

  block revisions:
    let s = set1(("jobId", "7"), ("timeBasisCode", "4"), ("extSampleIntervalOrig", "4000.5"),
      ("sweepLength", "-3"))
    for rev in [R0, R1]:
      let o = s.overridesOf(rev)
      doAssert o.overrides.len == 2 and o.overrides[0].name == "binary.jobId" and
        o.overrides[1].name == "binary.sweepLength"
      doAssert o.notes == @[
        "Binary header: Time basis code is not written in SEG-Y revision " &
          (if rev == R0: "0" else: "1") & ".",
        "Binary header: Extended sample interval original is not written in SEG-Y revision " &
          (if rev == R0: "0" else: "1") & "."]
      doAssert opens(rev, o.overrides)
    for rev in [R20, R21]:
      let o = s.overridesOf(rev)
      doAssert o.overrides.len == 4 and o.notes.len == 0
      doAssert o.overrides[0].value == toFieldValue(7)
      doAssert o.overrides[2].value == toFieldValue(4000.5)
      doAssert o.overrides[3].value == toFieldValue(-3)
      doAssert opens(rev, o.overrides)
    doAssert s.overridesOf(R0).notes.len == 2
    # In order given; values as typed with spaces.
    let sp = set1(("lineNumber", " 12 "), ("jobId", "5")).overridesOf(R21)
    doAssert sp.overrides[0].name == "binary.lineNumber" and sp.overrides[0].value == toFieldValue(12)

  block twin_hides:
    let both = set1(("ensembleFold", "5"), ("extEnsembleFold", "70000"))
    doAssert not opens(R21, @[headerOverride("binary.ensembleFold", 5),
      headerOverride("binary.extEnsembleFold", 70000)]), "the library judges the pair"
    let o = both.overridesOf(R21)
    doAssert o.overrides.len == 1 and o.overrides[0].name == "binary.extEnsembleFold"
    doAssert o.notes == @["Binary header: Ensemble fold is not written in SEG-Y revision 2.1: " &
      "Extended ensemble fold is set and replaces it."]
    doAssert opens(R21, o.overrides)
    # Rev 1: the extended field is not written, so the small one is.
    let r1 = both.overridesOf(R1)
    doAssert r1.overrides.len == 1 and r1.overrides[0].name == "binary.ensembleFold"
    doAssert r1.notes.len == 1 and r1.notes[0].contains("Extended ensemble fold")
    doAssert opens(R1, r1.overrides)
    # A twin set to 0 hides nothing.
    let zero = set1(("ensembleFold", "5"), ("extEnsembleFold", "0")).overridesOf(R20)
    doAssert zero.overrides.len == 2 and zero.notes.len == 0
    doAssert opens(R20, zero.overrides)

  block choice:
    let a = set1(("jobId", "1"))
    doAssert chosenBinary([a], "Survey").isSome and chosenBinary([a], "").isNone
    doAssert chosenBinary([a], "other").isNone

  echo "toutputbinary: ok"

when isMainModule:
  main()
