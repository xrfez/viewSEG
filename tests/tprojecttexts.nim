## Text header templates in the project open (`ckOutputText`), as name
## patterns are (`tnamepatterns`): saved under a name (the same name in any
## case replaces that template in its place), deleted, chosen (an empty name
## is the writer's own text). A template that cannot be kept is refused with
## `textProblem`'s sentence; no project and a read-only project are refused
## and not marked changed; at most 32 are kept; a child of a template this
## version does not know stays on replace and goes on delete. The choice and
## the list are written into the project document. Like a name pattern, the
## command is not an edit that Undo takes back: the project is the only copy.
##
## Seen to fail: with `findText` comparing by `==`, "Survey and survey are two
## templates: 2"; with the chosen name left after its template was deleted,
## "deleting the chosen text left it chosen"; with the refusal not checked, a
## 39-line template was saved.

import std/[os, sequtils, strutils]
import parseSEG
import viewSEG/core/[nif, outputtext, project, projectnif, state]
import utils/[fixtures, waiting]

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if e.severity == sevWarning and e.source == "commands" and e.text == text:
      return true

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc tmpl(name: string; lines: varargs[string]): OutputText =
  OutputText(name: name, encoding: teEbcdic, lines: @lines)

proc save(st: var AppState; t: OutputText; by = coWindow) =
  st.apply Command(kind: ckOutputText, origin: by, textAction: otaSave, textTemplate: t)

proc act(st: var AppState; action: OutputTextAction; name: string) =
  st.apply Command(kind: ckOutputText, textAction: action, textTemplate: OutputText(name: name))

proc main*() =

  block noProject:
    var st = initAppState()
    let rev = st.project.revision
    st.save tmpl("Survey", "C 1")
    st.act otaDelete, "Survey"
    st.act otaChoose, "Survey"
    doAssert st.project.revision == rev and st.said(NeedProjectTexts)

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

    st.save tmpl("  Survey  ", "C 1 {stem}")
    doAssert st.project.doc.outputTexts.len == 1 and st.project.doc.hasOutputTexts
    doAssert st.project.doc.outputTexts[0].name == "Survey"
    doAssert st.project.revision > openRev
    st.act otaChoose, "Survey"
    doAssert st.project.doc.outputText == "Survey"
    st.save tmpl("survey", "C 1 {date}")
    doAssert st.project.doc.outputTexts.len == 1, "Survey and survey are two templates: " &
      $st.project.doc.outputTexts.len
    doAssert st.project.doc.outputTexts[0].lines == @["C 1 {date}"]
    doAssert st.project.doc.outputText == "survey", "the chosen name kept the old spelling"
    st.act otaChoose, "SURVEY"
    doAssert st.project.doc.outputText == "survey"
    st.save tmpl("Second", "C 1")
    doAssert st.project.doc.outputTexts.mapIt(it.name) == @["survey", "Second"]

    let beforeBad = st.project.revision
    st.save tmpl("   ")
    doAssert st.said("An output text needs a name.") and st.project.revision == beforeBad
    st.save tmpl("Bad", "{nope}")
    doAssert st.said("Line 1 has the token {nope}, which is not one.")
    var many: seq[string] = @[]
    for i in 1 .. 39: many.add "x"
    st.save OutputText(name: "Long", lines: many)
    doAssert st.said("An output text has at most 38 lines.") and
      st.project.doc.outputTexts.len == 2 and st.project.revision == beforeBad
    st.act otaDelete, "missing"
    st.act otaChoose, "missing"
    doAssert st.said(noOutputText("missing")) and st.project.revision == beforeBad
    st.act otaDelete, "  "
    doAssert st.project.revision == beforeBad

    st.act otaDelete, "SURVEY"
    doAssert st.project.doc.outputTexts.mapIt(it.name) == @["Second"]
    doAssert st.project.doc.outputText == "", "deleting the chosen text left it chosen"
    st.act otaChoose, "second"
    doAssert st.project.doc.outputText == "Second"
    st.act otaChoose, ""
    doAssert st.project.doc.outputText == ""
    let cleared = st.project.revision
    st.act otaChoose, "   "
    doAssert st.project.revision == cleared, "choosing the writer's own text again changed it"

    st.save tmpl("From agent", "C 1"), coAgent
    st.act otaChoose, "from AGENT"
    doAssert st.project.doc.outputText == "From agent"
    st.flushFiles()
    var problems: seq[string] = @[]
    let back = readProject(readFile(job / "project.nif"), "project.nif", problems)
    doAssert back.outputText == "From agent" and back.outputTexts.len == 2, $problems

    block full:
      var n = st.project.doc.outputTexts.len
      while n < MaxOutputTexts:
        st.save tmpl("t" & $n, "x")
        inc n
      let rev = st.project.revision
      st.save tmpl("one more", "x")
      doAssert st.said(outputTextCap()) and st.project.revision == rev
      st.save OutputText(name: "T2", encoding: teAscii, lines: @["y"])
      doAssert st.project.doc.outputTexts.len == MaxOutputTexts
      doAssert st.project.doc.outputTexts.anyIt(it.name == "T2" and it.encoding == teAscii),
        "a full list refused a replace"

    block readOnly:
      var other = initAppState()
      other.rememberFilesIn(fx.dir / "config")
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject and other.project.readOnly),
        "the second program did not open it read-only"
      let rev = other.project.revision
      other.save tmpl("Nope", "x")
      doAssert other.said(ReadOnlyPatterns) and other.project.revision == rev
      other.shutdown()
    st.shutdown()

    let nif = job / "project.nif"
    writeFile(nif, readFile(nif).replace("(text \"Second\"", "(text \"Second\" kept"))
    var again = initAppState()
    again.rememberFilesIn(fx.dir / "config")
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and not again.project.readOnly),
      "the project did not open again"
    var ix = -1
    for i, t in again.project.doc.outputTexts:
      if t.name == "Second": ix = i
    doAssert ix >= 0 and again.project.doc.outputTextLater[ix].anyIt(
      it.kind == nkIdent and it.text == "kept"), "the extra child was not read"
    again.save tmpl("second", "C 2")
    doAssert again.project.doc.outputTexts[ix].lines == @["C 2"]
    doAssert again.project.doc.outputTextLater[ix].anyIt(
      it.kind == nkIdent and it.text == "kept"), "a later child moved"
    again.act otaDelete, "SECOND"
    doAssert not again.project.doc.outputTextLater.anyIt(
      it.anyIt(it.kind == nkIdent and it.text == "kept")), "the deleted template's child stayed"
    again.shutdown()
    echo "tprojecttexts: ok"

when isMainModule:
  main()
