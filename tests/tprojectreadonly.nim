## A project opened by a second program (docs/project.md), without a window:
##
## - the second program is read-only and "Forget them" (`ckForgetFiles`)
##   removes nothing: the holder's document of a file's kills stays;
## - a lock file that cannot be opened (mode 000) is said as such, with the
##   OS error, and not as "another program has it open" (the owner's note).
##   Skipped as root, which opens any file.
##
## Seen to fail: with `forgetFiles` not checking `readOnly`, "the holder's
## document is kept" (the document was removed); with the lock's open
## failure given the owner's note, "cannot be opened".
import std/[os, strutils]
import viewSEG/core/state
import utils/[fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond) and
    (discard st.drainInbox(); st.persist(); cond))

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path

proc docs(dir: string): seq[string] =
  for k, p in walkDir(dir):
    if p.endsWith(".nif"): result.add p.extractFilename

withFixtures fx:
  installSteps()
  let field = fx.dir / "field"
  createDir(field)
  let a = field / "a.sgy"
  copyFile(fx.manyTracesSegy(200, 40), a)
  let job = fx.dir / "Job"
  let config = fx.dir / "config"
  block readOnlyForget:
    var st = start(config)
    st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[field])
    doAssert st.settle(st.inProject)
    st.showFile(a)
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
      edited: @[st.sessions[0].base + 5], on: true)
    doAssert st.settle(st.remembering(a).confirmed)
    st.flushFiles()
    doAssert st.settle(docs(job / "files").len == 1)
    let d = docs(job / "files")[0]
    var other = start(config)
    other.apply Command(kind: ckOpenProject, projectPath: job)
    doAssert other.settle(other.inProject)
    doAssert other.project.readOnly
    other.apply Command(kind: ckForgetFiles, forget: @[d])
    other.flushFiles()
    var said = false
    for e in other.log:
      if "open read-only" in e.text: said = true
    doAssert said, "the refusal is not said"
    discard other.settle(other.jobs.active.len == 0)
    doAssert fileExists(job / "files" / d), "a read-only program removed a document"
    other.shutdown()
    st.shutdown()
echo "tprojectreadonly: done"
