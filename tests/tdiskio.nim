## The disk thread and the session log: a document is replaced whole, with
## no temporary file left and only the newest of a burst written; appends
## keep their order; a prune keeps the newest names and the file it spares;
## a file that cannot be written is said once, through the inbox; a named
## pipe is never read; `stop` writes what was left; two writes under a
## name no file has (two backups asked for under one name) are both kept;
## the store's temporary files a write cut short left are removed at the
## start, only those. `AppState` writes each
## log entry to this run's
## session log, one line each, the entries logged before `logTo` first,
## prunes the old session logs, and writes the last entries at shutdown.
##
## Seen to fail: with `logTo` starting at the newest serial instead of the
## first kept entry, `sessionLog` lost the entry logged before it; with
## `shutdown` not calling `persist`, `lastWords` found no session log at
## all; with `appendTo` trying a failed file again, `unwritable` got 4
## warnings, not 2; under AddressSanitizer (`nim asan`), with the disk
## thread ending without `clearCycleRoots`, LeakSanitizer found the thread's
## list of cycle roots (16 KB, made by the exceptions `unwritable` causes)
## never freed; with `readFor` reading whatever it is given, `pipeIsNotRead`
## found the thread stuck in a named pipe's open (it waits for a writer);
## with a `fresh` write taken for an older document of its path (the
## newest-only rule of `leave`), `freshNeverDropped` found "a backup was
## dropped: @["second"]" (the cause of `tsettings`'s `twoResetsKeepBoth`
## failing about one run in nine under load: one backup, the settings before
## the first reset lost); with no sweep at the start, "a temporary file a
## write cut short left stays".

import std/[os, sequtils, strutils, times]
import viewSEG/core/[diskio, filememory, identity, inbox, log, nif, persist, state]
import utils/[faultyfs, waiting]
when not defined(windows):
  from std/posix import nil

let tmp = getTempDir() / ("viewseg_tdiskio_" & $getCurrentProcessId())
removeDir(tmp)
createDir(tmp)

proc warnings(box: Inbox): seq[string] =
  var mail: seq[Msg]
  box.drainInto(mail)
  for m in mail:
    if m.kind == mkLog and m.entry.severity == sevWarning: result.add m.entry.text

block replaceWhole:
  let box = initInbox()
  var d = newDiskIo(box.poster)
  let path = tmp / "a" / "doc.nif"
  d.replace(path, "first\n", "the document")
  d.flush()
  doAssert readFile(path) == "first\n"
  d.replace(path, "second\n", "the document")
  d.flush()
  doAssert readFile(path) == "second\n"
  for kind, f in walkDir(tmp / "a"):
    doAssert not f.endsWith(".tmp"), "a temporary file was left: " & f
  doAssert box.warnings.len == 0

block burst:
  let box = initInbox()
  var d = newDiskIo(box.poster)
  let path = tmp / "burst.nif"
  for i in 0 ..< 200:
    d.replace(path, "version " & $i & "\n", "the document")
  d.stop() # writes what was left
  doAssert readFile(path) == "version 199\n"

block appendsInOrder:
  let box = initInbox()
  var d = newDiskIo(box.poster)
  let path = tmp / "log" / "x.log"
  var want = ""
  for i in 0 ..< 500:
    let line = "line " & $i & "\n"
    want.add line
    d.append(path, line, "the log")
  d.flush()
  doAssert readFile(path) == want

block entriesAreLinesInOrder:
  # Log entries given to an append become the session log's lines on the
  # disk thread, after the append's own text, in the order given, also when
  # appends are merged into one write.
  let box = initInbox()
  var d = newDiskIo(box.poster)
  let path = tmp / "log" / "entries.log"
  proc entry(text: string): LogEntry =
    LogEntry(time: getTime(), severity: sevInfo, source: "test", text: text)
  d.append(path, "A\n", "the log")
  d.append(path, "", "the log", @[entry("one")])
  d.append(path, "B\n", "the log", @[entry("two"), entry("three")])
  d.append(path, "", "the log", @[entry("four")])
  let five = entry("five")
  d.replace(tmp / "log" / "whole.log", "head\n", "the export", entries = @[five])
  d.flush()
  var got: seq[string]
  for line in readFile(path).splitLines:
    if line.len > 0: got.add(if "[test] " in line: line.split("[test] ")[1] else: line)
  doAssert got == @["A", "one", "B", "two", "three", "four"], $got
  let whole = readFile(tmp / "log" / "whole.log")
  doAssert whole == "head\n" & fileLine(five), whole

block documentsComeAsTrees:
  # A document read for an import comes with its NIF tree, made on the disk
  # thread, or with why it is not NIF.
  let box = initInbox()
  var d = newDiskIo(box.poster)
  writeFile(tmp / "good.nif", "(.nif27)\n(settings (version 1) (theme \"x\"))\n")
  writeFile(tmp / "bad.nif", "(settings (theme")
  d.read(tmp / "good.nif", rpImportSettings, 1 shl 20)
  d.read(tmp / "bad.nif", rpLoadLayout, 1 shl 20)
  d.flush()
  var mail: seq[Msg]
  box.drainInto(mail)
  var reads: seq[Msg]
  for m in mail.mitems:
    if m.kind == mkRead: reads.add move m
  doAssert reads.len == 2
  doAssert reads[0].docError == "" and reads[0].doc.len == 2 and
    reads[0].doc[1].isTree("settings"), reads[0].docError
  doAssert reads[1].doc.len == 0 and "bad.nif" in reads[1].docError, reads[1].docError

block pruneKeepsTheNewest:
  let box = initInbox()
  var d = newDiskIo(box.poster)
  let dir = tmp / "prune"
  createDir(dir)
  for i in 10 .. 29:
    writeFile(dir / ("viewSEG-202611" & $i & "-000000-1.log"), "")
  writeFile(dir / "other.txt", "")
  let spare = dir / "viewSEG-20261110-000000-1.log" # the oldest name
  d.prune(dir, "viewSEG-", ".log", 5, spare)
  d.flush()
  var left: seq[string]
  for kind, f in walkDir(dir): left.add f.extractFilename
  doAssert "other.txt" in left
  doAssert spare.extractFilename in left
  for i in 25 .. 29:
    doAssert ("viewSEG-202611" & $i & "-000000-1.log") in left
  doAssert left.len == 7, $left

block unwritable:
  let box = initInbox()
  var d = newDiskIo(box.poster)
  writeFile(tmp / "plain", "a file, not a folder")
  d.replace(tmp / "plain" / "settings.nif", "x", "the settings")
  for i in 0 ..< 3:
    d.append(tmp / "plain" / "session.log", "line\n", "the session log")
    d.flush()
  let w = box.warnings
  doAssert w.len == 2, $w
  doAssert w[0].startsWith("Could not save the settings in " & tmp / "plain" / "settings.nif"), w[0]
  doAssert w[1].startsWith("Could not write the session log to "), w[1]
  doAssert "Messages window" in w[1]

when not defined(windows):
  block pipeIsNotRead:
    let box = initInbox()
    var d = newDiskIo(box.poster)
    let pipe = tmp / "chosen.nif"
    doAssert posix.mkfifo(cstring(pipe), 0o600) == 0
    d.read(pipe, rpImportSettings, 1 shl 20)
    var got: seq[Msg]
    let answered = waitUntil((box.drainInto(got); got.anyIt(it.kind == mkRead)))
    # Free a thread stuck in the pipe's open, so a failure fails and does not hang.
    let fd = posix.open(cstring(pipe), posix.O_WRONLY or posix.O_NONBLOCK)
    if fd >= 0: discard posix.close(fd)
    doAssert answered, "the disk thread is stuck on the named pipe"
    for m in got:
      if m.kind == mkRead:
        doAssert m.readError == "it is not a regular file" and m.content == "", m.readError
    d.stop()
    removeFile(pipe)

block noDisk:
  var d: DiskIo # none: work is dropped, nothing waits
  d.replace(tmp / "never.nif", "x", "nothing")
  d.flush()
  d.stop()
  doAssert not fileExists(tmp / "never.nif")

block sessionLog:
  let dir = tmp / "logs"
  createDir(dir)
  for i in 0 ..< KeptSessionLogs + 5: # older runs' logs
    writeFile(dir / ("viewSEG-20200101-0000" & align($i, 2, '0') & "-1.log"), "old\n")
  var st = initAppState()
  st.report(sevInfo, "", "before the file") # logged before logTo
  st.logTo(dir)
  doAssert st.logFile.startsWith(dir / SessionLogPrefix) and
    st.logFile.endsWith(SessionLogSuffix), st.logFile
  st.report(sevWarning, "frame", "two lines\nof text")
  st.flushFiles()
  let text = readFile(st.logFile)
  let lines = text.splitLines
  doAssert lines.len == 4 and lines[3] == "", $lines # three lines, then the final line break
  doAssert lines[0].endsWith("info     before the file"), lines[0]
  doAssert lines[1].endsWith("warning  [frame] two lines"), lines[1]
  doAssert lines[2] == "    of text", lines[2]
  discard parse(lines[0][0 ..< 23], "yyyy-MM-dd HH:mm:ss'.'fff") # a time first
  var logs = 0
  for kind, f in walkDir(dir):
    if f.extractFilename.startsWith(SessionLogPrefix): inc logs
  doAssert logs == KeptSessionLogs, $logs & " session logs kept"
  st.shutdown()

block lastWords:
  let dir = tmp / "logs2"
  var st = initAppState()
  st.logTo(dir)
  st.report(sevError, "x", "the last thing said")
  st.shutdown() # no persist after the report: shutdown writes it
  doAssert readFile(st.logFile).contains("error    [x] the last thing said")

block freshNeverDropped:
  # Two writes under a name no file has (`fresh`, as two resets in one
  # second ask for one backup name) while the disk thread is busy: both are
  # kept, neither drops the other as an older document of the path.
  let box = initInbox()
  var d = newDiskIo(box.poster)
  let dir = tmp / "fresh"
  createDir(dir)
  install()
  fault(dir / "busy", fkHang, {foOpen})
  d.replace(dir / "busy", "x", "a file the disk thread is held on")
  doAssert waitUntil(hung() == 1)
  d.replace(dir / "settings.nif.bak", "first", "a copy", fresh = true)
  d.replace(dir / "settings.nif.bak", "second", "a copy", fresh = true)
  release(dir / "busy")
  d.flush()
  var kept: seq[string]
  for kind, f in walkDir(dir):
    if "settings" in f.extractFilename: kept.add readFile(f)
  doAssert kept.len == 2 and "first" in kept and "second" in kept,
    "a backup was dropped: " & $kept
  releaseAll()

block leftoverTemporaryFiles:
  # the temporary files of the store's documents that a write cut short
  # left (a kill between the write and the rename) go at the start; one
  # written since the program started (another viewSEG's, in flight), a
  # file of another name, and one outside the store's folder stay
  let config = tmp / "sweep"
  let store = config / StoreFolder
  createDir(store)
  let id = FileIdentity(size: 123_456, quick: 0x1234_5678_9abc_def0'u64)
  let old = store / docName(id, 1) & ".4242.tmp"
  let fresh = store / docName(id, 2) & ".4243.tmp"
  let notOurs = store / "notes.4242.tmp"
  let outside = config / docName(id, 1) & ".4242.tmp"
  for f in [old, fresh, notOurs, outside]: writeFile(f, "x")
  let hourAgo = getTime() - initDuration(hours = 1)
  for f in [old, notOurs, outside]: setLastModificationTime(f, hourAgo)
  var st = initAppState()
  st.rememberFilesIn(config)
  st.flushFiles()
  doAssert not fileExists(old), "a temporary file a write cut short left stays"
  doAssert fileExists(fresh), "a temporary file written since the start was removed"
  doAssert fileExists(notOurs) and fileExists(outside), "another file was removed"
  st.shutdown()

block entryWithLocation:
  var e = LogEntry(time: getTime(), severity: sevWarning, source: "a.sgy", text: "short",
    loc: Location(file: "/d/a.sgy", record: 2, trace: 71, field: "GH1.formatCode"),
    offset: 3200)
  doAssert fileLine(e).endsWith(
    "[a.sgy] short  (/d/a.sgy, record 2, trace 71, GH1.formatCode, byte 3200)\n"), fileLine(e)

removeDir(tmp)
