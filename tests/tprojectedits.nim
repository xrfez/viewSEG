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
## - The next open of a file of that size, ends and time brings them back as
##   provisional; with another time they are listed as an earlier output and
##   not applied.
## - When the hash says it is another file, the user's own edits made on it
##   stay as its record; only the brought-back ones are taken away.
## - When the hash agrees, they join the brought-back record.
##
## Seen to fail: with `writeMemoryDoc` not routing a check to
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
      if r.identity.fullKnown:
        doAssert r.killedIn == @[5], "the brought document holds the edits made on the " &
          "other file: " & $r.killedIn
      else:
        doAssert r.killedIn == @[9], "the unconfirmed record is wrong: " & $r.killedIn
        doAssert r.modified == t0

  block otherTime: # the unconfirmed record, a file of another time: listed, not applied
    writeFile(a, b)
    setLastModificationTime(a, initTime(t0.toUnix - 600, 0))
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).confirmed and st.jobs.active.len == 0)
    doAssert not st.killed(9) and not st.killed(5), "applied on another time"
    doAssert st.settle(st.earlierOf(a).len >= 1)
    st.shutdown()

  block backOnB: # B again, same time: 9 is provisional, bound to B's hash; 5 is taken off
    writeFile(a, b)
    setLastModificationTime(a, t0)
    var st = start(config)
    st.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert st.settle(st.inProject)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).confirmed and st.jobs.active.len == 0)
    doAssert st.killed(9), "the provisional edit was not brought back"
    doAssert not st.killed(5), "the other file's edit stayed"
    st.flushFiles()
    st.shutdown()
    var mine = 0
    for r in docs(job):
      if r.killedIn == @[5]: doAssert r.identity.fullKnown
      if r.killedIn == @[9]:
        inc mine
        doAssert r.identity.fullKnown, "bound to no hash"
    doAssert mine == 1, "one record holds 9: " & $mine

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
echo "tprojectedits: done"
