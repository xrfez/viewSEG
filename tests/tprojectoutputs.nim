## A file output again under the same name, in a project (the user: "It is
## common for files to be output then an issue discovered and re-output. we
## wouldnt want to save anything for files like that. the discriminator for
## a file needs to be more than just its name."). What a project keeps for a
## file is keyed by the file's content, never its name:
##
## - the pair the quick identity cannot tell apart: the same size and the
##   same first and last 64 KiB, one trace in the middle re-processed;
##   - with the same modification time: the edits come back at once marked
##     "being checked" (`editsChecking`), and are taken back with a message
##     when the hash of every byte differs;
##   - with another modification time: they wait for that hash, and are
##     never applied;
##   either way the earlier output's edits are said once ("is not the file
##   your edits were made on ... are not applied"), kept, and listed with
##   the file (`earlierOf`);
## - "Apply them to this file" (an import of the earlier output's document,
##   one step) puts them on, and Undo takes them off;
## - a re-output with another number of traces: listed, its trace count kept
##   so that applying it is not offered;
## - a survey original touched (a new time, the same content) is as copied;
##   one whose content changed, the same size and ends, is changed.
##
## Seen to fail: with `sayEarlier` not called for the documents that waited
## for the hash, "the earlier output is not listed"; with the earlier
## outputs looked up by name alone (no identity check in
## `earlierOutputs`), "the file's own document listed as an earlier output";
## with `lookOriginal` judging by the modification time, "a touched
## original is offered as changed".

import std/[os, strutils, times]
import viewSEG/core/[filesystem, identity, project, projectjobs, state]
import utils/[fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc said(st: AppState; part: string): bool =
  for e in st.log:
    if part in e.text: return true
  false

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path

proc killed(st: AppState; trace: int): bool = st.editsOf(0).has(teKilled, trace)

const Traces = 2000

withFixtures fx:
  let field = fx.dir / "field"
  createDir(field)
  let a = field / "line7.sgy"
  copyFile(fx.manyTracesSegy(Traces, 40), a)
  let original = readFile(a)
  doAssert original.len > 4 * QuickSpan
  let job = fx.dir / "Job"
  let config = fx.dir / "config"
  # the re-output: one sample of a trace in the middle changed
  var b = original
  let at = 3600 + 1000 * (240 + 40 * 4) + 240 + 8
  b[at] = char(ord(b[at]) xor 0x40)
  doAssert b.len == original.len and b[0 ..< QuickSpan] == original[0 ..< QuickSpan] and
    b[^QuickSpan .. ^1] == original[^QuickSpan .. ^1]
  # a time the file system keeps exactly (a write of times keeps microseconds)
  let t0 = initTime(getTime().toUnix - 3600, 0)
  setLastModificationTime(a, t0)
  block made:
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).known)
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[0].base + 5, st.sessions[0].base + 6], on: true)
    doAssert st.settle(st.remembering(a).confirmed)
    st.flushFiles()
    st.shutdown()

  block sameTime: # the same size, ends and time: brought back, checked, taken back
    writeFile(a, b)
    setLastModificationTime(a, t0)
    installSteps()
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.killed(5) and st.editsChecking(a)),
      "the edits were not brought back marked as being checked"
    doAssert st.said("being checked")
    releaseStep("reading every byte")
    doAssert st.settle(not st.killed(5) and not st.editsChecking(a)),
      "the edits of the other contents stayed"
    doAssert st.settle(st.earlierOf(a).len == 1), "the earlier output is not listed"
    doAssert st.said("line7.sgy is not the file your edits were made on"), "not said"
    st.shutdown()

  block otherTime: # the same size and ends, a new time: never applied
    writeFile(a, b)
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).known)
    doAssert not st.killed(5) and not st.editsChecking(a), "applied before the hash"
    releaseStep("reading every byte")
    doAssert st.settle(st.earlierOf(a).len == 1 and st.remembering(a).confirmed),
      "the earlier output is not listed"
    doAssert not st.killed(5)
    doAssert st.said("2 killed are not applied") or st.said("are not applied"), "not said"
    let c = st.earlierOf(a)[0]
    doAssert c.traces == Traces and c.path == a, $c.traces
    # Apply them to this file: one step, which Undo takes back
    st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: st.store.docPath(c.doc))
    doAssert st.settle(st.killed(5) and st.killed(6)), "Apply did not apply them"
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(not st.killed(5)), "Undo did not take them back"
    st.shutdown()

  block appliedThenReopened:
    # Output again with other ends (another quick identity): the earlier
    # output is listed and said; after "Apply them to this file" it is not
    # said or listed again at the next run.
    var d = original
    d[10] = char(ord(d[10]) xor 0x01)
    writeFile(a, d)
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.earlierOf(a).len >= 1 and st.said("not applied")),
      "not listed and said the first time"
    var doc = ""
    for c in st.earlierOf(a):
      if c.edits.lists[teKilled].len == 2: doc = c.doc
    doAssert doc.len > 0, "the earlier output with the two kills is not listed"
    st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: st.store.docPath(doc))
    doAssert st.settle(st.killed(5) and st.killed(6)), "Apply did not apply them"
    doAssert st.settle(st.remembering(a).known and st.jobs.active.len == 0)
    st.flushFiles()
    st.shutdown()
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject)
    again.showFile(a)
    doAssert again.settle(again.killed(5) and again.remembering(a).known and
      again.jobs.active.len == 0)
    doAssert not again.said("not applied"), "the applied earlier output is said again"
    for c in again.earlierOf(a):
      doAssert c.edits.lists[teKilled].len != 2, "the applied earlier output is listed again"
    again.shutdown()

  block otherTraces: # output again with fewer traces: listed, not offered
    copyFile(fx.manyTracesSegy(Traces - 1, 40), a)
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.earlierOf(a).len >= 1), "the earlier output is not listed"
    for c in st.earlierOf(a):
      doAssert c.traces == Traces and st.sessions[0].len == Traces - 1
      doAssert not sameData(c.identity, st.remembering(a).identity),
        "the file's own document listed as an earlier output"
    doAssert not st.killed(5)
    # edits of its own: theirs, and never listed as an earlier output's
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[0].base + 9], on: true)
    doAssert st.settle(st.remembering(a).confirmed)
    st.flushFiles()
    st.shutdown()
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject)
    again.showFile(a)
    doAssert again.settle(again.killed(9) and again.remembering(a).confirmed and
      again.jobs.active.len == 0)
    for c in again.earlierOf(a):
      doAssert not sameData(c.identity, again.remembering(a).identity),
        "the file's own document listed as an earlier output"
    again.shutdown()

  block surveyOriginals: # by content, not by time
    let src = fx.dir / "s.sps"
    writeFile(src, original)
    var t: Time
    let id = quickIdentity(src, t)
    let copy = SurveyCopy(kind: jkSps, copy: "survey/files/s.sps",
      original: ProjectPath(absolute: src), size: id.size, modified: t, quick: id.quick,
      full: fullHash(src))
    setLastModificationTime(src, t + initDuration(seconds = 30))
    doAssert lookOriginal(copy, job).state == osAsCopied, "a touched original is offered as changed"
    writeFile(src, b)
    doAssert lookOriginal(copy, job).state == osChanged, "a changed middle is not seen"
    # found changed by a read of every byte: not read again until its time moves
    var reads = 0
    let counting = proc (done, total: int64): bool {.gcsafe.} =
      {.cast(gcsafe).}:
        inc reads
      true
    let first = lookOriginal(copy, job, counting)
    doAssert first.state == osChanged and first.readChanged and reads > 0, "not read whole"
    var known = copy
    known.changedModified = first.modified
    reads = 0
    let second = lookOriginal(known, job, counting)
    doAssert second.state == osChanged and reads == 0, "read whole again at the next open"
    setLastModificationTime(src, first.modified + initDuration(seconds = 30))
    reads = 0
    discard lookOriginal(known, job, counting)
    doAssert reads > 0, "not read after its time moved"
echo "tprojectoutputs: done"
