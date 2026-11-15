## The jobs of what is remembered about files (`core/filememory`): each
## reads off the UI thread, through `fs`, and posts what it found.
##
## - `identifyWork` (interactive lane, a few milliseconds): an opened
##   file's quick identity, and the store's documents of that identity.
## - `fullHashWork` (the lane of hashes): the hash of every byte of the file,
##   which confirms the identity or tells the files apart.
## - `listMemoryWork`: every document of the store, for the File memory
##   window; then `lookWork`: whether each file is where it was last seen,
##   folder by folder (a folder whose drive does not answer holds only its
##   own entries).
## - `exportEditsWork`: a file's list, with each edited trace's record and
##   channel from the open file's keys, as NIF or CSV text.
## - `importEditsWork`: a file's list the user imports, read and taken
##   apart here (a CSV of a million rows is half a second's work), so the UI
##   thread only adds its edits.
##
## None of them is given the file in `reads`: they open it themselves (or
## read only the keys in memory), so a close or a step to another file
## never waits for a hash of a large file.

import std/[os, strutils, times]
import parseSEG
import filememory, filesystem, identity, inbox, jobs, nif, threads

proc identifyWork*(path: string; store: Store; to: Poster): JobWork =
  ## Posts `mkIdentified`: the quick identity of the file at `path` and the
  ## documents of `store` with that quick identity. Raises `IOError` or
  ## `OSError` when the file cannot be read.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading its first and last bytes"
    var modified: Time
    let id = quickIdentity(path, modified)
    ctx.setPhase "looking up what is remembered"
    var msg = Msg(job: ctx.id, kind: mkIdentified, identPath: path, identity: id,
      identModified: modified)
    try:
      msg.candidates = store.recordsOf(id, msg.taken, msg.memoryProblems)
    except OSError as e:
      msg.memoryProblems.add "the folder " & store.home & " cannot be read: " & e.msg
    clearCycleRoots()
    to.post move msg

proc fullHashWork*(path: string; id: FileIdentity; modified: Time; to: Poster): JobWork =
  ## Posts `mkHashed`: `id` (the quick identity of the file at `path`, read
  ## when its modification time was `modified`) with the hash of every
  ## byte. Raises `IOError` when the file cannot be read, or when it is not
  ## as it was identified, before or after the read: another size, other
  ## ends or another modification time (`identity`'s documentation says
  ## what that does and does not see); stops at a cancel.
  result = proc (ctx: JobContext) {.gcsafe.} =
    proc same(path: string; id: FileIdentity; modified: Time): bool =
      var now: Time
      quickIdentity(path, now) == id and now == modified
    if not same(path, id, modified): # changed since it was opened
      raise newException(IOError, "it changed since it was opened")
    ctx.setPhase "reading every byte"
    var full = id
    full.full = fullHash(path, proc (done, total: int64): bool =
      ctx.progress(done, total))
    full.fullKnown = true
    if not same(path, id, modified): # changed while it was read
      raise newException(IOError, "it changed while it was read")
    to.post Msg(job: ctx.id, kind: mkHashed, hashedPath: path, hashed: full)

proc listMemoryWork*(store: Store; to: Poster): JobWork =
  ## Posts `mkMemoryList`: every document of `store`, read, and whether its
  ## file is gone.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading what is remembered"
    var msg = Msg(job: ctx.id, kind: mkMemoryList)
    try:
      msg.records = store.listRecords(msg.listProblems, proc (done, total: int): bool =
        ctx.progress(done, total), look = false)
    except OSError as e:
      msg.listProblems.add "the folder " & store.home & " cannot be read: " & e.msg
    ctx.checkCancelled()
    clearCycleRoots()
    to.post move msg

type
  LookFolder* = tuple
    folder: string
    files: seq[tuple[doc, path: string; size: int64]]

proc lookWork*(folders: seq[LookFolder]; to: Poster): JobWork =
  ## Posts an `mkMemoryLooked` for each of `folders` in turn: whether each
  ## file remembered there is where it was last seen (`placeOf`). Before
  ## each folder it reports its place in `folders` as its progress (done of
  ## total), so that the one a drive holds is known (`notAnsweringFor`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "looking for the files"
    for i, f in folders:
      if not ctx.progress(i, folders.len): raise newException(JobCancelledError, "cancelled")
      var msg = Msg(job: ctx.id, kind: mkMemoryLooked, lookedFolder: f.folder)
      for x in f.files:
        let (gone, unreached) = placeOf(x.path, x.size)
        msg.looked.add (x.doc, gone, unreached)
      to.post move msg

proc exportEditsWork*(file: ptr SeismicFile; r: FileRecord; dest: string; to: Poster): JobWork =
  ## Posts `mkEditsList`: `r`'s edits as the text of `dest` (CSV when its
  ## name ends in `.csv`, else NIF), with each edited trace's field record
  ## number and channel from `file`'s keys (in memory). Submitted with the
  ## file in `reads`, so no close takes it away meanwhile.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "writing the list"
    var text = ""
    if dest.toLowerAscii.endsWith(".csv"):
      let rows = csvRows(r.edits)
      var records, channels = newSeq[float64](rows.len)
      var keys = newSeq[TraceKeys](min(rows.len, 4096))
      var i = 0
      while i < rows.len:
        let n = min(keys.len, rows.len - i)
        {.cast(gcsafe).}:
          file[].traceKeysInto(rows.toOpenArray(i, i + n - 1), keys.toOpenArray(0, n - 1))
        for j in 0 ..< n:
          (records[i + j], channels[i + j]) = (keys[j].record, keys[j].channel)
        i += n
        if not ctx.progress(i, rows.len): raise newException(JobCancelledError, "cancelled")
      text = editsCsv(r.edits, records, channels, r.name)
    else:
      text = memoryDocument(r)
    clearCycleRoots()
    to.post Msg(job: ctx.id, kind: mkEditsList, listText: move text, listDest: dest,
      listName: r.name)

proc importEditsWork*(path: string; traces: int; to: Poster): JobWork =
  ## Posts `mkEditsRead`: the edits of the list at `path` (a NIF document
  ## when its name ends in `.nif`, else a CSV table: `readEdits`) on the
  ## first `traces` traces (`importOutside` counts those past them, left
  ## out before any run is expanded), what in it could not be used, or why
  ## none of it could.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "reading the list"
    var msg = Msg(job: ctx.id, kind: mkEditsRead, importedList: path)
    try:
      let size = fs.getFileSize(path)
      if not fs.fileExists(path): # a named pipe would hold this thread until written to
        msg.importFailure = "it is not a regular file"
      elif size > MaxMemoryBytes:
        msg.importFailure = "it is larger than " & $(MaxMemoryBytes shr 20) & " MB"
      else:
        let text = fs.readFile(path)
        let name = path.extractFilename
        var doc: seq[NifNode]
        var docError = ""
        if name.toLowerAscii.endsWith(".nif"):
          try: doc = parseNif(text, name, MaxMemoryBytes)
          except NifError as e: docError = e.msg
        # cut at the file's last trace before a run is expanded: a list
        # from elsewhere may name billions
        msg.importedEdits = readEdits(text, name, doc, docError, traces, msg.importProblems,
          msg.importIdentity, msg.importHasIdentity, msg.importOutside)
    except ValueError as e: # a NifError too
      msg.importFailure = e.msg
    except IOError, OSError:
      msg.importFailure = getCurrentExceptionMsg()
      if msg.importFailure.len == 0: msg.importFailure = "it cannot be read"
    clearCycleRoots()
    to.post move msg
