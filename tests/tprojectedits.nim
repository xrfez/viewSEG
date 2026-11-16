## Edits made on a file while what was remembered about its name is being
## checked (the same size, ends and modification time as an earlier output,
## the hash of every byte not yet in), in a project. The user: "we wouldnt
## want to save anything for files like that. the discriminator for a file
## needs to be more than just its name."
##
## - The user's own edits made during the check are kept apart from the
##   brought-back record: a quit before the hash ends leaves the brought
##   document as it was, and writes the own edits as an unconfirmed record of
##   their own (quick identity and time, no hash of every byte).
## - The next open of a file of that quick identity applies nothing of it,
##   whatever hash the file has: it is listed with the earlier outputs, to
##   apply (one step, Undo takes it back) or to forget. It holds the whole
##   state as the user left it, so an edit taken off is kept too.
## - Two paths of one size, ends and time open at once are not linked while
##   their edits are being checked: each waits for its own hash.
## - When the hash says it is another file, the user's own edits made on it
##   stay as its record; only the brought-back ones are taken away.
## - When the hash agrees, they join the brought-back record.
##
## Seen to fail: with `takePending` applying edits kept by path on path, size and
## time, "edits kept by path were applied"; with `writeMemoryDoc` not routing a check to
## `writeProvisional`, "the brought document holds the edits made on the
## other file"; with `takeHashed` forgetting every edit, "the own edit was
## thrown away".

import std/[os, strutils, times]
import viewSEG/core/[edits, filememory, filesystem, identity, project, projectjobs, state]
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

proc kill(st: var AppState; trace: int) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
    edited: @[st.sessions[0].base + trace], on: true)

proc docs(job: string): seq[FileRecord] =
  ## Every document of the project's store, as on disk.
  for f in walkFiles(job / "files" / "*" & MemorySuffix):
    var problems: seq[string]
    result.add readMemoryFile(f, problems)

proc killedIn(r: FileRecord): seq[int] = r.edits.lists[teKilled]

const Traces = 2000

withFixtures fx:
  let field = fx.dir / "field"
  createDir(field)
  let a = field / "line7.sgy"
  copyFile(fx.manyTracesSegy(Traces, 40), a)
  let original = readFile(a)
  let job = fx.dir / "Job"
  let config = fx.dir / "config"
  var b = original
  let at = 3600 + 1000 * (240 + 40 * 4) + 240 + 8
  b[at] = char(ord(b[at]) xor 0x40)
  let t0 = initTime(getTime().toUnix - 3600, 0)
  setLastModificationTime(a, t0)

  proc made() =
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).known)
    st.kill 5
    doAssert st.settle(st.remembering(a).confirmed)
    st.flushFiles()
    st.shutdown()

  installSteps()
  made()

  proc unconfirmedOf(st: AppState; path: string): seq[FileRecord] =
    for c in st.earlierOf(path):
      if c.unconfirmed: result.add c

  proc applyUnconfirmed(st: var AppState; path: string) =
    let c = st.unconfirmedOf(path)[0]
    st.apply Command(kind: ckImportEdits, panel: MainPanel, listPath: st.store.docPath(c.doc),
      replaceEdits: true)

  block quitDuringCheck: # B, same size/ends/time; kill 9 on B during the check; quit
    writeFile(a, b)
    setLastModificationTime(a, t0)
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.killed(5) and st.editsChecking(a))
    st.kill 9
    doAssert st.settle(st.killed(9))
    st.flushFiles()
    st.shutdown(wait = initDuration(milliseconds = 300))
    releaseStep("reading every byte")
    let all = docs(job)
    doAssert all.len == 2, "expected the brought document and an unconfirmed one: " & $all.len
    for r in all:
      if r.unconfirmed:
        doAssert r.killedIn == @[5, 9], "the unconfirmed record is not the whole state: " &
          $r.killedIn
        doAssert r.modified == t0 and not r.identity.fullKnown and r.traces == Traces
        doAssert r.path == a and r.opened != Time()
      else:
        doAssert r.identity.fullKnown and r.killedIn == @[5],
          "the brought document holds the edits made on the other file: " & $r.killedIn

  block backOnA: # A opened later: only its own [5]; the unconfirmed [5, 9] is offered
    writeFile(a, original)
    setLastModificationTime(a, t0)
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).confirmed and st.jobs.active.len == 0 and
      st.unconfirmedOf(a).len == 1)
    doAssert st.killed(5) and not st.killed(9), "an unconfirmed edit was applied to A"
    doAssert st.said("not yet confirmed as this file's"), "not said"
    st.applyUnconfirmed(a) # only by the user's click, one step
    doAssert st.settle(st.killed(9)), "Apply did not apply it"
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.settle(not st.killed(9) and st.killed(5)), "Undo did not take it back"
    st.flushFiles()
    st.shutdown()
    for r in docs(job):
      if not r.unconfirmed: doAssert r.killedIn == @[5], "A's record changed: " & $r.killedIn

  block backOnB: # B opened later: nothing applied, A's [5] taken off, the unconfirmed offered
    writeFile(a, b)
    setLastModificationTime(a, t0)
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).confirmed and st.jobs.active.len == 0 and
      st.unconfirmedOf(a).len == 1)
    doAssert not st.killed(5) and not st.killed(9), "an edit was applied to B"
    st.applyUnconfirmed(a)
    doAssert st.settle(st.killed(5) and st.killed(9)), "Apply did not apply it"
    st.flushFiles()
    st.shutdown()

  block takenOff: # an edit taken off a brought-back one is kept in the unconfirmed state
    removeDir(job)
    removeDir(config)
    writeFile(a, original)
    setLastModificationTime(a, t0)
    made()
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.editsChecking(a))
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[0].base + 5], on: false)
    doAssert st.settle(not st.killed(5))
    st.flushFiles()
    st.shutdown(wait = initDuration(milliseconds = 300))
    releaseStep("reading every byte")
    var seen = 0
    for r in docs(job):
      if r.unconfirmed:
        inc seen
        doAssert r.killedIn.len == 0
      else: doAssert r.killedIn == @[5]
    doAssert seen == 1, "the taken-off edit was not kept as unconfirmed"
    var again = start(config)
    again.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert again.settle(again.inProject)
    again.showFile(a)
    doAssert again.settle(again.remembering(a).confirmed and again.unconfirmedOf(a).len == 1)
    doAssert again.killed(5), "the taken-off edit was applied by itself"
    again.shutdown()

  block twoPaths: # A and B (same size, ends, time) open at once, under two paths
    removeDir(job)
    removeDir(config)
    writeFile(a, original)
    setLastModificationTime(a, t0)
    made()
    let c = field / "line7-again.sgy"
    writeFile(c, b)
    setLastModificationTime(c, t0)
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.editsChecking(a))
    st.showFile(c)
    doAssert st.settle(st.remembering(c).known and st.editsChecking(c))
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[st.sessions.high].base + 9], on: true)
    doAssert st.settle(st.killed(9))
    st.flushFiles()
    releaseStep("reading every byte")
    doAssert st.settle(st.remembering(c).confirmed and st.remembering(a).confirmed and
      st.jobs.active.len == 0)
    doAssert st.killed(9) and not st.killed(5), "B (the second path) lost its own edit"
    st.showFile(a)
    doAssert not st.killed(9) and st.killed(5), "A took B's edit or lost its own"
    st.flushFiles()
    st.shutdown()
    var sawA, sawB = false
    for r in docs(job):
      doAssert not r.unconfirmed, "an unconfirmed record was left"
      if r.killedIn == @[5]: sawA = true
      if r.killedIn == @[9]: sawB = true
    doAssert sawA and sawB, "A's record is not [5], or B's own is missing"

  block ownKept: # fresh project state: A, then B with a kill 11 during the check; hash differs
    removeDir(job)
    removeDir(config)
    writeFile(a, original)
    setLastModificationTime(a, t0)
    made()
    writeFile(a, b)
    setLastModificationTime(a, t0)
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.editsChecking(a))
    st.kill 11
    doAssert st.settle(st.killed(11))
    releaseStep("reading every byte")
    doAssert st.settle(not st.editsChecking(a) and st.remembering(a).confirmed)
    doAssert st.killed(11), "the own edit was thrown away"
    doAssert not st.killed(5)
    doAssert st.said("your own edits"), "the message does not say the own edits stay"
    st.flushFiles()
    st.shutdown()
    var sawA, sawB = false
    for r in docs(job):
      if r.killedIn == @[5]: sawA = true
      if r.killedIn == @[11]: sawB = true
    doAssert sawA and sawB, "A's document or B's own record is missing"

  block agrees: # the same file, kill 12 during the check: joins the record
    removeDir(job)
    removeDir(config)
    writeFile(a, original)
    setLastModificationTime(a, t0)
    made()
    holdStep("reading every byte")
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.editsChecking(a))
    st.kill 12
    st.flushFiles()
    doAssert docs(job).len >= 1
    releaseStep("reading every byte")
    doAssert st.settle(not st.editsChecking(a) and st.remembering(a).confirmed)
    st.flushFiles()
    st.shutdown()
    let all = docs(job)
    doAssert all.len == 1 and all[0].killedIn == @[5, 12], "not joined: " & $all.len
  block pendingByPath: # edits kept by path, no hash recorded: unconfirmed, never applied
    let c2 = fx.dir / "config-pending"
    let p = field / "pend.sgy"
    copyFile(fx.manyTracesSegy(Traces, 40), p)
    setLastModificationTime(p, t0)
    createDir(c2 / StoreFolder)
    writeFile(c2 / StoreFolder / pendingName(p), memoryDocument(FileRecord(
      identity: FileIdentity(size: getFileSize(p)), name: "pend.sgy", path: p,
      opened: getTime(), modified: getLastModificationTime(p),
      edits: EditLists(lists: [@[], @[4]]))))
    var st = start(c2)
    st.showFile(p)
    doAssert st.settle(st.remembering(p).known and st.said("Apply or Forget"))
    doAssert not st.killed(4), "edits kept by path were applied on path, size and time alone"
    doAssert st.unconfirmedOf(p).len == 1, "they are not offered as an unconfirmed record"
    doAssert st.said("Apply or Forget"), "not said"
    st.flushFiles()
    doAssert not fileExists(c2 / StoreFolder / pendingName(p)), "the pending document stays"
    st.applyUnconfirmed(p)
    doAssert st.settle(st.killed(4)), "Apply did not apply them"
    st.shutdown()
echo "tprojectedits: done"
