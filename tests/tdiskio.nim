## The disk thread and the session log: a document is replaced whole, with
## no temporary file left and only the newest of a burst written; appends
## keep their order; a prune keeps the newest names and the file it spares;
## a file that cannot be written is said once, through the inbox; a named
## pipe is never read; `stop` writes what was left. `AppState` writes each
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
## found the thread stuck in a named pipe's open (it waits for a writer).

import std/[os, sequtils, strutils, times]
import viewSEG/core/[diskio, inbox, log, persist, state]
import utils/waiting
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

block entryWithLocation:
  var e = LogEntry(time: getTime(), severity: sevWarning, source: "a.sgy", text: "short",
    loc: Location(file: "/d/a.sgy", record: 2, trace: 71, field: "GH1.formatCode"),
    offset: 3200)
  doAssert fileLine(e).endsWith(
    "[a.sgy] short  (/d/a.sgy, record 2, trace 71, GH1.formatCode, byte 3200)\n"), fileLine(e)

removeDir(tmp)
