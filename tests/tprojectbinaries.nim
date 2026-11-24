## Binary header sets in the project open (`ckOutputBinary`), as text header
## templates are (`tprojecttexts`): saved under a name (the same name in any
## case replaces that set in its place), deleted, chosen (an empty name sets
## no binary header value). A set that cannot be kept is refused with
## `binaryProblem`'s sentence; no project and a read-only project are refused
## and not marked changed; at most 32 are kept; a child of a set this version
## does not know stays on replace and goes on delete. The choice and the list
## are written into the project document and read back; a set the file holds
## that is not valid, a name given twice, a field given twice, and a chosen
## name that names no set are said and left out; an old project holds none.
##
## Seen to fail: with `findBinary` comparing by `==`, "Survey and survey are
## two sets: 2"; with the chosen name left after its set was deleted,
## "deleting the chosen set left it chosen"; with the refusal not checked, a
## set with `sampleInterval` was saved; with the reader not checking
## `binaryProblem`, the bad set of the file was kept; with the overflow of a
## number not caught, the save raised; with `(field "a" "b" extra)` read as a
## field, the "Extra" set was kept.

import std/[os, sequtils, strutils]
import viewSEG/core/[nif, outputbinary, project, projectnif, state]
import utils/[fixtures, waiting]

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if e.severity == sevWarning and e.source == "commands" and e.text == text:
      return true

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc one(name: string; entries: varargs[(string, string)]): OutputBinary =
  result = OutputBinary(name: name)
  for (f, v) in entries: result.entries.add BinaryEntry(field: f, value: v)

proc save(st: var AppState; b: OutputBinary; by = coWindow) =
  st.apply Command(kind: ckOutputBinary, origin: by, binaryAction: obaSave, binarySet: b)

proc act(st: var AppState; action: OutputBinaryAction; name: string) =
  st.apply Command(kind: ckOutputBinary, binaryAction: action, binarySet: OutputBinary(name: name))

proc main*() =
  block noProject:
    var st = initAppState()
    let rev = st.project.revision
    st.save one("Survey", ("jobId", "7"))
    st.act obaDelete, "Survey"
    st.act obaChoose, "Survey"
    doAssert st.project.revision == rev and st.said(NeedProjectBinaries)

  block oldProject:
    var problems: seq[string] = @[]
    let d = readProject("(project (version 1) (name \"old\"))", "p", problems)
    doAssert d.outputBinaries.len == 0 and not d.hasOutputBinaries and d.outputBinary == ""
    doAssert problems.len == 0, $problems

  block fileRead:
    var problems: seq[string] = @[]
    let text = """(project (version 1) (name "x")
  (outputBinaries
    (binary "Good" (field "jobId" "7") (field "extSampleIntervalOrig" "4000.5") kept)
    (binary "good" (field "jobId" "8"))
    (binary "Bad" (field "sampleInterval" "1"))
    (binary "Twice" (field "jobId" "1") (field "jobId" "2"))
    (binary "Range" (field "ensembleFold" "40000"))
    (binary (field "jobId" "1"))
    (binary "Open" (field "jobId"))
    (binary "Huge" (field "jobId" "99999999999999999999"))
    (binary "Extra" (field "jobId" "1" "2"))
    (binary "Second" (field "lineNumber" "3"))
    (somethingNew "stays"))
  (outputBinary "SECOND"))"""
    let d = readProject(text, "p", problems)
    doAssert d.outputBinaries.mapIt(it.name) == @["Good", "Second"], $d.outputBinaries
    doAssert d.outputBinary == "Second"
    doAssert problems.len == 8, $problems
    doAssert problems.anyIt("the binary header set \"good\" is given twice" in it)
    doAssert problems.anyIt("\"Twice\"" in it and "Job ID is given twice" in it)
    doAssert problems.anyIt("sampleInterval" in it and "Bad" in it)
    doAssert problems.anyIt("\"Huge\"" in it and "99999999999999999999" in it)
    doAssert problems.anyIt("\"Extra\"" in it and "nothing else" in it)
    doAssert d.outputBinaries[0].entries[1].value == "4000.5"
    doAssert d.outputBinaryLater[0].len == 1 and d.outputBinariesLater.len == 1
    let back = projectDocument(d)
    var p2: seq[string] = @[]
    let d2 = readProject(back, "p", p2)
    doAssert d2.outputBinaries == d.outputBinaries and d2.outputBinary == "Second" and
      d2.outputBinariesLater.len == 1 and d2.outputBinaryLater[0].len == 1 and p2.len == 0, $p2
    var stray: seq[string] = @[]
    let d3 = readProject(
      "(project (version 1) (outputBinaries (binary \"A\" (field \"jobId\" \"1\"))) " &
      "(outputBinary \"Nope\"))", "p", stray)
    doAssert d3.outputBinary == "" and stray.anyIt("\"Nope\" is not in this project" in it)

  withFixtures fx:
    let field = fx.dir / "field"
    let job = fx.dir / "job"
    createDir(field)
    var st = initAppState()
    st.rememberFilesIn(fx.dir / "config")
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject and st.projectOpening.len == 0 and not st.project.readOnly),
      "the project was not made"
    let openRev = st.project.revision

    st.save one("  Survey  ", ("jobId", "7"))
    doAssert st.project.doc.outputBinaries.len == 1 and st.project.doc.hasOutputBinaries
    doAssert st.project.doc.outputBinaries[0].name == "Survey"
    doAssert st.project.revision > openRev
    st.act obaChoose, "Survey"
    doAssert st.project.doc.outputBinary == "Survey"
    st.save one("survey", ("jobId", "8"), ("lineNumber", "2"))
    doAssert st.project.doc.outputBinaries.len == 1, "Survey and survey are two sets: " &
      $st.project.doc.outputBinaries.len
    doAssert st.project.doc.outputBinaries[0].entries.len == 2
    doAssert st.project.doc.outputBinary == "survey", "the chosen name kept the old spelling"
    st.act obaChoose, "SURVEY"
    doAssert st.project.doc.outputBinary == "survey"
    st.save one("Second", ("reelNumber", "1"))
    doAssert st.project.doc.outputBinaries.mapIt(it.name) == @["survey", "Second"]

    let beforeBad = st.project.revision
    st.save one("   ")
    doAssert st.said("A binary header set needs a name.") and st.project.revision == beforeBad
    st.save one("Bad", ("sampleInterval", "1"))
    doAssert st.said("'sampleInterval' is not a binary header field that can be set.")
    st.save one("Bad", ("jobId", "x"))
    doAssert st.said("Job ID: 'x' is not a whole number.")
    doAssert st.project.doc.outputBinaries.len == 2 and st.project.revision == beforeBad
    st.save one("Huge", ("jobId", "99999999999999999999"))
    doAssert st.said("Job ID: '99999999999999999999' is not a whole number from " &
      "-2147483648 to 2147483647.") and st.project.doc.outputBinaries.len == 2
    st.act obaDelete, "missing"
    st.act obaChoose, "missing"
    doAssert st.said(noOutputBinary("missing")) and st.project.revision == beforeBad
    st.act obaDelete, "  "
    doAssert st.project.revision == beforeBad

    st.act obaDelete, "SURVEY"
    doAssert st.project.doc.outputBinaries.mapIt(it.name) == @["Second"]
    doAssert st.project.doc.outputBinary == "", "deleting the chosen set left it chosen"
    st.act obaChoose, "second"
    doAssert st.project.doc.outputBinary == "Second"
    st.act obaChoose, ""
    doAssert st.project.doc.outputBinary == ""
    let cleared = st.project.revision
    st.act obaChoose, "   "
    doAssert st.project.revision == cleared, "choosing no set again changed it"

    st.save one("From agent", ("jobId", "3")), coAgent
    st.act obaChoose, "from AGENT"
    doAssert st.project.doc.outputBinary == "From agent"
    st.flushFiles()
    var problems: seq[string] = @[]
    let back = readProject(readFile(job / "project.nif"), "project.nif", problems)
    doAssert back.outputBinary == "From agent" and back.outputBinaries.len == 2, $problems

    block full:
      var n = st.project.doc.outputBinaries.len
      while n < MaxOutputBinaries:
        st.save one("t" & $n, ("jobId", "1"))
        inc n
      let rev = st.project.revision
      st.save one("one more", ("jobId", "1"))
      doAssert st.said(outputBinaryCap()) and st.project.revision == rev
      st.save one("T2", ("jobId", "2"))
      doAssert st.project.doc.outputBinaries.len == MaxOutputBinaries
      doAssert st.project.doc.outputBinaries.anyIt(it.name == "T2" and it.entries[0].value == "2"),
        "a full list refused a replace"

    block readOnly:
      var other = initAppState()
      other.rememberFilesIn(fx.dir / "config")
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject and other.project.readOnly),
        "the second program did not open it read-only"
      let rev = other.project.revision
      other.save one("Nope", ("jobId", "1"))
      doAssert other.said(ReadOnlyPatterns) and other.project.revision == rev
      other.shutdown()
    st.shutdown()

    let nif = job / "project.nif"
    writeFile(nif, readFile(nif).replace("(binary \"Second\"", "(binary \"Second\" kept"))
    var again = initAppState()
    again.rememberFilesIn(fx.dir / "config")
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and not again.project.readOnly),
      "the project did not open again"
    var ix = -1
    for i, b in again.project.doc.outputBinaries:
      if b.name == "Second": ix = i
    doAssert ix >= 0 and again.project.doc.outputBinaryLater[ix].anyIt(
      it.kind == nkIdent and it.text == "kept"), "the extra child was not read"
    again.save one("second", ("jobId", "5"))
    doAssert again.project.doc.outputBinaries[ix].entries[0].field == "jobId"
    doAssert again.project.doc.outputBinaryLater[ix].anyIt(
      it.kind == nkIdent and it.text == "kept"), "a later child moved"
    again.act obaDelete, "SECOND"
    doAssert not again.project.doc.outputBinaryLater.anyIt(
      it.anyIt(it.kind == nkIdent and it.text == "kept")), "the deleted set's child stayed"
    again.shutdown()
    echo "tprojectbinaries: ok"

when isMainModule:
  main()
