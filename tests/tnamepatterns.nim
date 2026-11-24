## File-name patterns (`name pattern`): saved under a label (the same label
## in any case replaces that pattern in its place, and the stored spelling
## becomes the new one), deleted by label, chosen by label (an empty label is
## today's naming). A pattern that cannot be kept is refused with
## `patternProblem`'s sentence. No project, and a read-only project, are
## refused and not marked changed. At most 32 are kept. A child of a pattern
## this version does not know stays on replace and goes on delete. The choice
## and the list are written into the project document.
##
## Seen to fail: with `findPattern` comparing by `==`, "Line and line are two
## patterns: 2".

import std/[os, sequtils, strutils]
import viewSEG/core/[nif, projectnif, state]
import utils/[fixtures, waiting]

proc said(st: AppState; text: string): bool =
  for e in st.log:
    if e.severity == sevWarning and e.source == "commands" and e.text == text:
      return true

proc lastSaid(st: AppState): string =
  if st.log.len == 0: return ""
  st.log[st.log.len - 1].text

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc linePattern(name: string; pad = 5): OutputPattern =
  OutputPattern(name: name, separator: nsDot, parts: @[
    NamePart(kind: npSrcLine, pad: pad), NamePart(kind: npSrcPoint),
    NamePart(kind: npStem)])

proc save(st: var AppState; p: OutputPattern; by = coWindow) =
  st.apply Command(kind: ckNamePattern, origin: by, patternAction: npaSave,
    namePattern: p)

proc main*() =

  block noProject:
    var st = initAppState()
    let rev = st.project.revision
    st.save linePattern("Line")
    doAssert st.project.revision == rev and st.said(NeedProjectPatterns), st.lastSaid
    st.apply Command(kind: ckNamePattern, patternAction: npaDelete,
      namePattern: OutputPattern(name: "Line"))
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "Line"))
    doAssert st.project.revision == rev and st.said(NeedProjectPatterns)

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

    st.save linePattern("  Line  ")
    doAssert st.project.doc.outputPatterns.len == 1
    doAssert st.project.doc.outputPatterns[0].name == "Line"
    doAssert st.project.doc.hasOutputPatterns
    doAssert st.project.revision > openRev
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "Line"))
    doAssert st.project.doc.outputPattern == "Line"
    var other = linePattern("line", pad = 3)
    other.separator = nsUnderscore
    st.save other
    doAssert st.project.doc.outputPatterns.len == 1, "Line and line are two patterns: " &
      $st.project.doc.outputPatterns.len
    doAssert st.project.doc.outputPatterns[0].name == "line"
    doAssert st.project.doc.outputPatterns[0].separator == nsUnderscore
    doAssert st.project.doc.outputPatterns[0].parts[0].pad == 3
    doAssert st.project.doc.outputPattern == "line", "the chosen label kept the old spelling"
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "LINE"))
    doAssert st.project.doc.outputPattern == "line"
    let chosenRev = st.project.revision
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "Line"))
    doAssert st.project.revision == chosenRev, "choosing the pattern already chosen changed it"

    st.save linePattern("Second")
    doAssert st.project.doc.outputPatterns.len == 2
    doAssert st.project.doc.outputPatterns[0].name == "line"
    doAssert st.project.doc.outputPatterns[1].name == "Second"

    st.save OutputPattern(name: "ä", separator: nsHyphen, parts: @[NamePart(kind: npStem)])
    st.save OutputPattern(name: "Ä", separator: nsDot, parts: @[NamePart(kind: npRecord)])
    doAssert st.project.doc.outputPatterns.len == 3, "ä and Ä are two patterns: " &
      $st.project.doc.outputPatterns.len
    doAssert st.project.doc.outputPatterns[2].name == "Ä"
    doAssert st.project.doc.outputPatterns[2].parts[0].kind == npRecord

    let beforeBad = st.project.revision
    let beforeLen = st.project.doc.outputPatterns.len
    st.save OutputPattern(name: "   ")
    doAssert st.said("A name pattern needs a name.") and st.project.revision == beforeBad
    st.save OutputPattern(name: "Bare")
    doAssert st.said("A name pattern needs a part.") and st.project.revision == beforeBad
    st.save OutputPattern(name: "Wide", parts: @[NamePart(kind: npSrcLine, pad: 13)])
    doAssert st.said("Source line's width is from 0 to 12.") and
      st.project.doc.outputPatterns.len == beforeLen

    st.apply Command(kind: ckNamePattern, patternAction: npaDelete,
      namePattern: OutputPattern(name: "missing"))
    doAssert st.said(noNamePattern("missing")) and st.project.revision == beforeBad
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "missing"))
    doAssert st.said(noNamePattern("missing"))
    st.apply Command(kind: ckNamePattern, patternAction: npaDelete,
      namePattern: OutputPattern(name: "  "))
    doAssert st.said("A name pattern needs a name.")

    st.apply Command(kind: ckNamePattern, patternAction: npaDelete,
      namePattern: OutputPattern(name: "LINE"))
    doAssert st.project.doc.outputPatterns.len == 2
    doAssert st.project.doc.outputPatterns[0].name == "Second"
    doAssert st.project.doc.outputPattern == "", "deleting the chosen pattern left it chosen"

    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "second"))
    doAssert st.project.doc.outputPattern == "Second"
    let had = st.project.revision
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: ""))
    doAssert st.project.doc.outputPattern == "" and st.project.revision > had
    let cleared = st.project.revision
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "   "))
    doAssert st.project.revision == cleared, "choosing today's naming again changed the project"

    st.save OutputPattern(name: "From control", parts: @[NamePart(kind: npFileNumber)]), coAgent
    doAssert st.project.doc.outputPatterns.anyIt(it.name == "From control")
    st.apply Command(kind: ckNamePattern, patternAction: npaChoose,
      namePattern: OutputPattern(name: "from control"))
    doAssert st.project.doc.outputPattern == "From control"
    st.flushFiles()
    var problems: seq[string] = @[]
    let back = readProject(readFile(job / "project.nif"), "project.nif", problems)
    doAssert back.hasOutputPatterns and back.outputPattern == "From control", $problems
    doAssert back.outputPatterns.anyIt(it.name == "From control" and
      it.parts[0].kind == npFileNumber), $back.outputPatterns
    doAssert back.outputPatterns.anyIt(it.name == "Second")

    block full:
      var n = st.project.doc.outputPatterns.len
      while n < MaxOutputPatterns:
        st.save OutputPattern(name: "p" & $n, parts: @[NamePart(kind: npStem)])
        inc n
      doAssert st.project.doc.outputPatterns.len == MaxOutputPatterns
      let rev = st.project.revision
      st.save OutputPattern(name: "one more", parts: @[NamePart(kind: npStem)])
      doAssert st.said(namePatternCap()) and st.project.revision == rev and
        st.project.doc.outputPatterns.len == MaxOutputPatterns
      st.save OutputPattern(name: "P31", separator: nsHyphen, parts: @[NamePart(kind: npTime)])
      doAssert st.project.doc.outputPatterns.len == MaxOutputPatterns
      doAssert st.project.doc.outputPatterns.anyIt(it.name == "P31" and
        it.separator == nsHyphen and it.parts[0].kind == npTime), "a full list refused a replace"

    block readOnly:
      var other = initAppState()
      other.rememberFilesIn(fx.dir / "config")
      other.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert other.settle(other.inProject and other.project.readOnly),
        "the second program did not open it read-only: " & other.project.whyReadOnly
      let rev = other.project.revision
      let n = other.project.doc.outputPatterns.len
      other.save linePattern("Nope")
      doAssert other.said(ReadOnlyPatterns) and other.project.revision == rev and
        other.project.doc.outputPatterns.len == n, other.lastSaid
      other.shutdown()
    st.shutdown()

    let nif = job / "project.nif"
    var text = readFile(nif)
    let key = "(pattern \"Second\""
    doAssert key in text, "Second is not in the document"
    writeFile(nif, text.replace(key, key & " kept"))
    var again = initAppState()
    again.rememberFilesIn(fx.dir / "config")
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject and not again.project.readOnly),
      "the project did not open again"
    var ix = -1
    for i, p in again.project.doc.outputPatterns:
      if p.name == "Second": ix = i
    doAssert ix >= 0 and again.project.doc.outputPatternLater[ix].anyIt(
      it.kind == nkIdent and it.text == "kept"), "the extra child was not read"
    again.save OutputPattern(name: "second", separator: nsHyphen,
      parts: @[NamePart(kind: npStem)])
    doAssert again.project.doc.outputPatterns[ix].name == "second"
    doAssert again.project.doc.outputPatternLater[ix].anyIt(
      it.kind == nkIdent and it.text == "kept"), "a later child moved"
    again.apply Command(kind: ckNamePattern, patternAction: npaDelete,
      namePattern: OutputPattern(name: "SECOND"))
    var still = false
    for kids in again.project.doc.outputPatternLater:
      for n in kids:
        if n.kind == nkIdent and n.text == "kept": still = true
    doAssert not still, "the deleted pattern's child stayed"
    again.shutdown()
    echo "tnamepatterns: ok"

when isMainModule:
  main()
