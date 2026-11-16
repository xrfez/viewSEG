## The file system seam (`core/fs`) and its test side (`tests/utils/faultyfs`):
## a slow, a hung and a failing path behave as a network drive would, and
## no module of `core` or `remote` calls the file system but through the
## seam, however the call is written (`fileExists(p)`, `fileExists p`,
## `p.fileExists`, `os.fileExists(p)`); the calls the program makes past
## it, all of them on its own folders or on a thread of their own, are
## listed (`PastTheSeam`), so a new one fails until it is placed; and no
## module that runs on the UI thread calls parseSEG's readers of a file's
## map, which the seam cannot see.
##
## Seen to fail: with `fs.walkDir` in `core/watch` written back as the
## `std/os` call, `everyCallGoesThroughTheSeam` names that line; with the
## hook's wait taken out of `fkHang`, `aHungCallWaits` fails. The check of
## the calls as they were (a call with its parenthesis, not after a dot,
## in `core` only) let `p.fileExists`, `os.dirExists(p)` and `fileExists p`
## through (`theScanSeesEveryForm`), and did not see the agent's `headers`
## tool read a trace's headers on the UI thread (`s.file.traceHeaders` in
## `remote/tools`, before it read them on a job). The scan is written by
## hand, not with `std/re` (which needs libpcre at run time); with its look
## back for a qualifier left out, `theScanSeesEveryForm` says "not seen: if
## p.fileExists".

import std/[monotimes, os, sequtils, strutils, times]
import viewSEG/core/[filejobs, filekinds, threads]
import utils/[faultyfs, waiting]

install()
let dir = getTempDir() / "viewSEG-tfilesystem-" & $getCurrentProcessId()
createDir(dir)
writeFile(dir / "a.txt", "hello")
let far = dir / "far"
createDir(far)
writeFile(far / "b.txt", "far away")

block aSlowCallMovesTheClockOn:
  fault(far, fkSlow, delay = initDuration(seconds = 3))
  let t0 = fs.now()
  doAssert fs.fileExists(far / "b.txt")
  doAssert fs.now() - t0 >= initDuration(seconds = 3), "a slow stat moves fs.now on"
  doAssert fs.fileExists(dir / "a.txt"), "another path is not slow"
  release(far)

block aFailingCallFails:
  fault(far, fkFail)
  doAssert not fs.fileExists(far / "b.txt"), "a failing drive: no such file"
  doAssert not fs.dirExists(far)
  doAssertRaises OSError: discard fs.getFileInfo(far / "b.txt")
  doAssertRaises IOError: discard fs.readFile(far / "b.txt")
  doAssert sniff(far / "b.txt") == fkUnknown
  doAssert fs.readFile(dir / "a.txt") == "hello"
  release(far)
  doAssert fs.readFile(far / "b.txt") == "far away", "the drive is back"

block aHungCallWaits:
  fault(far, fkHang, {foStat})
  var t: Thread[string]
  proc look(path: string) {.thread.} =
    markWorkerThread()
    doAssert fs.fileExists(path)
  createThread(t, look, far / "b.txt")
  doAssert waitUntil(hung() == 1), "the stat hangs"
  sleep 20
  doAssert hung() == 1, "and stays hung"
  release(far)
  joinThread(t)
  doAssert hung() == 0

block uiCallsAreKept:
  markUiThread()
  discard fs.fileExists(dir / "a.txt")
  doAssert uiCalls().len == 1 and "a.txt" in uiCalls()[0]
  markWorkerThread()

const
  FsCalls = ["fileExists", "dirExists", "getFileInfo", "getFileSize",
    "getLastModificationTime", "setLastModificationTime", "walkDir", "walkFiles", "walkDirRec",
    "walkPattern", "readFile", "writeFile", "readLines", "createDir", "existsOrCreateDir",
    "removeFile", "tryRemoveFile", "moveFile", "copyFile", "removeDir", "copyDir", "moveDir",
    "readBuffer", "expandFilename", "expandSymlink", "symlinkExists", "sameFile",
    "getFilePermissions", "setFilePermissions", "getCreationTime", "getLastAccessTime",
    "fileNewer", "createSymlink", "newFileStream", "openFileStream", "existsFile", "existsDir"]
    ## the std/os (and streams) calls that touch the file system
  MapReaders = ["traceHeaders", "traceKeys", "traceKeysInto", "readTraces", "readTracesInto",
    "newPrefetcher", "textHeader", "binaryHeader", "copyBytes", "openSeismic",
    "saveIndex", "crsText", "startTimeMsInto", "maxSamples", "seg2Trace"]
    ## parseSEG's calls that read a seismic file's map (or the file): a page
    ## a drive does not deliver holds the thread that touches it
  PastTheSeam = [
    ("remote/server.nim", "dirExists createDir setFilePermissions",
      "the agents' socket folder, on the thread that makes the socket"),
    ("remote/client.nim", "writeFile", "`--mcp-call --png`: a process of its own, no window"),
    ("view/theme.nim", "dirExists walkDir getFileInfo readBuffer",
      "theme files (64 KiB at most): at start, and when chosen and changed since"),
    ("ui/imgui/app.nim", "fileExists createDir writeFile",
      "the theme chosen; the start-up failure's log, before any window"),
    ("ui/imgui/fonts.nim", "fileExists readFile", "the bundled fonts, at start"),
    ("platform/paths.nim", "dirExists writeFile removeFile createDir",
      "the program's own folders, probed at start"),
    ("platform/winres.nim", "writeFile", "at compile time"),
    ("core/versions.nim", "fileExists", "the libraries' nimble files, at compile time"),
    ("platform/trayhost.nim", "getFileInfo",
      "the session bus's socket in $XDG_RUNTIME_DIR, a local in-memory folder")]
    ## every call past the seam the program makes, and why it may: each on
    ## the program's own folders, or on a thread of its own
  UiThread = ["core/state.nim", "remote/", "view/", "ui/"]
    ## modules (or folders) whose code runs on the UI thread

proc code(line: string): string =
  ## `line` without its comment and its string literals.
  var inString = false
  for i, c in line:
    if c == '"' and (i == 0 or line[i - 1] != '\\'): inString = not inString
    elif not inString:
      if c == '#': break
      result.add c

proc callsIn(text: string; names: openArray[string]): seq[tuple[line: int; name: string]] =
  ## Each use of a call of `names` in Nim source `text`, however it is
  ## written: a call, a command, a method call, module-qualified; never one
  ## through the seam (`fs.`), nor a declaration of a proc of that name.
  ## A use is the whole word, after an optional `qualifier .` (a word, then
  ## a dot, spaces around it) and before an optional export `*`; one use is
  ## never the qualifier of the next.
  for i, raw in toSeq(text.splitLines).pairs:
    let line = code(raw)
    if line.strip.len == 0: continue
    var at = 0 # where the next use may begin
    var w = 0
    while w < line.len:
      if line[w] notin IdentStartChars or (w > 0 and line[w - 1] in IdentChars):
        inc w
        continue
      var e = w
      while e < line.len and line[e] in IdentChars: inc e
      let name = line[w ..< e]
      if name notin names:
        w = e
        continue
      var a = w # where the use begins: its qualifier, if any
      var qualifier = ""
      var q = w - 1
      while q >= at and line[q] in Whitespace: dec q
      if q >= at and line[q] == '.':
        var s = q - 1
        while s >= at and line[s] in Whitespace: dec s
        let last = s
        while s >= at and line[s] in IdentChars: dec s
        inc s
        if s <= last and line[s] in IdentStartChars and (s == 0 or line[s - 1] notin IdentChars):
          a = s
          qualifier = line[s .. last] & "."
      let exported = e < line.len and line[e] == '*'
      let b = if exported: e else: e - 1 # where the use ends
      at = b + 1
      w = at
      if qualifier == "fs.": continue # through the seam
      if exported or line[0 ..< a].strip.endsWith("proc") or
          line[0 ..< a].strip.endsWith("func") or line[0 ..< a].strip.endsWith("iterator"):
        continue # its declaration
      let after = line[b + 1 .. ^1]
      let called = qualifier.len > 0 or after.startsWith("(") or
        (after.startsWith(" ") and after.strip.len > 0 and after.strip[0] notin {'=', ':', ',', ')', ']'})
      if called: result.add (i + 1, name)

block theScanSeesEveryForm:
  for form in ["if fileExists(p): discard", "if p.fileExists: discard", "discard os.dirExists(p)",
      "discard fileExists p", "for k, f in walkDir(d): discard", "let h = s.file.traceHeaders(i)",
      "let s = newFileStream(p)"]:
    doAssert callsIn(form, @FsCalls & @MapReaders).len == 1, "not seen: " & form
  for fine in ["if fs.fileExists(p): discard", "## fileExists(p) in a doc comment",
      "proc fileExists*(_: FileSystem; path: string): bool =", "say \"fileExists(p)\"",
      "for k, f in fs.walkDir(d): discard", "let exists = fileExists"]:
    doAssert callsIn(fine, @FsCalls & @MapReaders).len == 0, "seen: " & fine

block everyCallGoesThroughTheSeam:
  let src = currentSourcePath().parentDir.parentDir / "src/viewSEG"
  var found: seq[string]
  var used: seq[string]
  for path in walkDirRec(src):
    if not path.endsWith(".nim"): continue
    let rel = path.relativePath(src)
    if rel == "core/filesystem.nim": continue
    var allowed: seq[string]
    for (file, calls, why) in PastTheSeam:
      if rel == file: allowed = calls.splitWhitespace
    for (line, name) in callsIn(readFile(path), FsCalls):
      if name in allowed: used.add rel & " " & name
      elif rel.startsWith("core/") or rel.startsWith("remote/"):
        found.add rel & ":" & $line & ": " & name & " (call it through `fs`)"
      else:
        found.add rel & ":" & $line & ": " & name & " (past the seam: list it in PastTheSeam)"
    if UiThread.anyIt(rel.startsWith(it)):
      for (line, name) in callsIn(readFile(path), MapReaders):
        found.add rel & ":" & $line & ": " & name & " (reads a file's map on the UI thread)"
  doAssert found.len == 0, "file-system calls past the seam:\n" & found.join("\n")
  for (file, calls, why) in PastTheSeam:
    for c in calls.splitWhitespace:
      doAssert file & " " & c in used, "PastTheSeam lists " & c & " in " & file &
        ", which no longer calls it"

removeDir(dir)
echo "tfilesystem: ok"
