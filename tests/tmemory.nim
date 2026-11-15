## What is remembered about a file, through `core/state` with a store
## (`rememberFilesIn`), run after run (each run an `AppState` of its own,
## shut down as at a quit):
##
## - a trace killed, one reversed and the polarity of all traces reversed
##   by the user, and one killed by an agent; the program quits; the file is
##   renamed; the next run opens it under its new name: the user's three
##   edits are back at once (the file's size, first and last 64 KiB and
##   modification time are those remembered), the agent's is not, the plot
##   is reversed as a whole, the history is empty (it is the session's), and
##   the hash of every byte confirms it; the document names the new name;
## - a copy with one byte changed in the middle of a trace is another file:
##   nothing is brought back, also when its modification time is made the
##   same (then what came at once is taken away again when the hash says
##   it is another file, with a warning);
## - edits taken away to nothing remove the document; Ctrl+Z writes it
##   again;
## - a file whose drive does not answer when its identity is read: the plot
##   opens and draws, and the edits come once the drive answers;
## - the data file's bytes and modification time are as they were through
##   all of it.
##
## Seen to fail: with `applyRecord` not called for a document whose time
## matches (only after the hash), "the edits came at once" (they came only
## with the hash); with the kept lists written from what is shown,
## "the agent's kill was remembered"; with `takeHashed` not looking at the
## full hash of what it brought back, "the changed copy shows the edits
## of the file it was copied from".

import std/[os, strutils, times]
import viewSEG/core/state
import utils/[faultyfs, fixtures, steps, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); st.persist(); cond)) # as a frame does

proc start(config: string): AppState =
  result = initAppState()
  result.rememberFilesIn(config)

proc answered(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and not p.pending.isEmpty and st.tiles(0).len > 0 and
    st.tiles(0)[^1].request == p.pending

proc showFile(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path
  st.apply Command(kind: ckView, panel: MainPanel,
    view: fitAll(st.panel(MainPanel).layout, 640, 480))
  doAssert st.settle(st.answered), "not drawn: " & path

proc base(st: AppState): int = st.sessions[^1].base

proc edit(st: var AppState; edit: TraceEdit; trace: int; by = coWindow) =
  st.apply Command(kind: ckEdit, panel: MainPanel, edit: edit, edited: @[st.base + trace],
    on: true, origin: by)

proc docs(config: string): seq[string] =
  if dirExists(config / StoreFolder):
    for kind, p in walkDir(config / StoreFolder):
      if kind == pcFile: result.add p

proc lastWarning(st: AppState): string =
  for e in st.log:
    if e.severity == sevWarning: result = e.text

proc quiet(st: AppState): bool =
  ## Nothing said of the identity's and the hash's jobs ending.
  for e in st.log:
    if e.source == "jobs": return false
  true

install()
installSteps()
withFixtures fx:
  let config = fx.dir / "config"
  let a = fx.surveySegy()
  # a whole second, so that a copy can be given exactly its time (`utimes`)
  setLastModificationTime(a, initTime(getLastModificationTime(a).toUnix - 60, 0))
  let kept = (readFile(a), getLastModificationTime(a))
  block firstRun:
    var st = start(config)
    st.showFile(a)
    doAssert st.settle(st.remembering(a).known)
    doAssert st.remembering(a).doc == "" and st.editsOf(0).isEmpty
    st.edit(teKilled, 3)
    st.edit(teReversed, 5)
    st.apply Command(kind: ckReverseAll, panel: MainPanel, reverse: true)
    st.edit(teKilled, 7, by = coAgent)
    doAssert st.panel(MainPanel).layers[0].reversed and st.editsOf(0).has(teKilled, 7)
    doAssert st.settle(st.remembering(a).confirmed)
    st.shutdown()
    let d = docs(config)
    doAssert d.len == 1, $d
    let text = readFile(d[0])
    doAssert "(killed \"4\")" in text, "the agent's kill was remembered: " & text
    doAssert "(reversed \"6\")" in text and "(allReversed true)" in text and "full" in text, text
  let b = fx.dir / "renamed.sgy"
  moveFile(a, b)
  block renamed:
    var st = start(config)
    st.showFile(b)
    doAssert st.settle(st.remembering(b).known)
    doAssert st.editsOf(0).has(teKilled, 3) and st.editsOf(0).has(teReversed, 5),
      "the edits came at once"
    doAssert not st.editsOf(0).has(teKilled, 7), "the agent's kill came back"
    doAssert st.editsOf(0).allReversed and st.panel(MainPanel).layers[0].reversed
    doAssert not st.editsOf(0).canUndo, "the history is the session's"
    doAssert st.settle(st.answered)
    let t = st.tiles(0)[^1]
    doAssert t.isKilled(t.traces.find(3)), "the tile does not draw the kill"
    doAssert st.settle(st.remembering(b).confirmed and not st.remembering(b).looking)
    doAssert st.editsOf(0).has(teKilled, 3), "the hash took the edits away"
    st.shutdown()
    let text = readFile(docs(config)[0])
    doAssert "renamed.sgy" in text and "survey-" notin text, text
  doAssert (readFile(b), getLastModificationTime(b)) == kept, "the data file changed"
  block changedCopy:
    var bytes = readFile(b)
    let at = bytes.len div 2
    bytes[at] = char(ord(bytes[at]) xor 0x10)
    let c = fx.dir / "changed.sgy"
    writeFile(c, bytes)
    var st = start(config)
    st.showFile(c)
    doAssert st.settle(st.remembering(c).confirmed and not st.remembering(c).looking)
    doAssert st.editsOf(0).isEmpty, "the changed copy shows the edits of the file it was " &
      "copied from"
    st.shutdown()
    # the same, with the time of the file it was copied from: at once, then taken away
    let c2 = fx.dir / "changed-same-time.sgy"
    writeFile(c2, bytes)
    setLastModificationTime(c2, kept[1])
    st = start(config)
    holdStep("reading every byte") # a large file: its hash comes later
    st.showFile(c2)
    doAssert st.settle(st.remembering(c2).known)
    doAssert st.editsOf(0).has(teKilled, 3), "a file of the same size, ends and time is " &
      "taken for the file at once"
    releaseStep("reading every byte")
    doAssert st.settle(st.remembering(c2).confirmed and not st.remembering(c2).looking)
    doAssert st.editsOf(0).isEmpty and not st.panel(MainPanel).layers[0].reversed,
      "the changed copy shows the edits of the file it was copied from"
    doAssert "its content differs" in st.lastWarning, st.lastWarning
    doAssert st.quiet, "the jobs of what is remembered were said to end"
    st.shutdown()
    doAssert docs(config).len == 1, "the copies made documents of their own: " & $docs(config)
  block clearedAndBack:
    var st = start(config)
    st.showFile(b)
    doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3))
    st.apply Command(kind: ckClearEdits, panel: MainPanel)
    st.flushFiles()
    doAssert docs(config).len == 0, "a document that keeps nothing is removed"
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    st.flushFiles()
    doAssert docs(config).len == 1, "the undo did not write it again"
    st.shutdown()
  block driveDoesNotAnswer:
    var st = start(config)
    holdStep("reading its first and last bytes")
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: b)
    doAssert waitUntil((discard st.drainInbox(); inStep("reading its first and last bytes").len == 1))
    doAssert st.settle(st.panel(MainPanel).laidOut)
    st.apply Command(kind: ckView, panel: MainPanel,
      view: fitAll(st.panel(MainPanel).layout, 640, 480))
    fault(b, fkHang, {foOpen, foRead})
    releaseStep("reading its first and last bytes")
    doAssert waitUntil(hung() == 1), "the identity's read does not hang"
    doAssert st.settle(st.answered and st.tiles(0).len > 0), "the plot waits for the identity"
    doAssert not st.remembering(b).known and st.editsOf(0).isEmpty
    release(b)
    doAssert st.settle(st.remembering(b).known and st.editsOf(0).has(teKilled, 3)),
      "the edits did not come once the drive answered"
    st.shutdown()
  doAssert (readFile(b), getLastModificationTime(b)) == kept, "the data file changed"
echo "tmemory: ok"
