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
## - `treatWork` (interactive lane; the lane of hashes when the hash of every
##   byte is needed): which document keeps what the user forced for a file.
##
## None of them is given the file in `reads`: they open it themselves (or
## read only the keys in memory), so a close or a step to another file
## never waits for a hash of a large file.

import std/[os, sequtils, strutils, times]
import parseSEG
import edits, filememory, filesystem, identity, inbox, jobs, nif, threads

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
      # edits made when its identity could not be read, kept by its path
      let pending = store.docPath(pendingName(path))
      if fs.fileExists(pending):
        try:
          var p: seq[string]
          msg.pending = readMemoryFile(pending, p)
          msg.pending.doc = pendingName(path)
          msg.pendingFits = msg.pending.path == path and msg.pending.identity.size == id.size and
            msg.pending.modified == modified
        except NifError, IOError, OSError:
          msg.memoryProblems.add pendingName(path) & ": " & getCurrentExceptionMsg()
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

proc earlierWork*(store: Store; path: string; id: FileIdentity; to: Poster): JobWork =
  ## Posts `mkEarlier`: the documents of `store` whose file was last seen at
  ## `path` but is another file than the one of identity `id` there now (an
  ## earlier output of that name: `earlierOutputs`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "looking for earlier outputs of " & path.extractFilename
    var msg = Msg(job: ctx.id, kind: mkEarlier, earlierPath: path, earlierOf: id)
    try:
      msg.earlier = store.earlierOutputs(path, id, msg.earlierProblems)
    except OSError as e:
      msg.earlierProblems.add "the folder " & store.home & " cannot be read: " & e.msg
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

proc treatWork*(path: string; store: Store; hint: FileRecord; taken: seq[string]; hashing: bool;
    to: Poster): JobWork =
  ## Posts `mkTreated`: the document of `store` that keeps what the user forces for the file at
  ## `path` (`fileDoc`, among the documents of its quick identity), or the name of a new one
  ## (none of `taken`, the names the UI thread has given, nor of the store). `hint` is what the
  ## UI thread knows of the file: its document (`doc`, taken while the file is of that quick
  ## identity) or the hash of every byte. The hash is taken only with `hashing` (the lane of
  ## hashes), and only when the documents need it to be told apart, or the only one knows its
  ## file's; without `hashing` the message then asks for it (`treatHash`). The document itself is
  ## changed by the disk thread (`DiskIo.treat`), with what is forced then.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "looking up what is remembered"
    var msg = Msg(job: ctx.id, kind: mkTreated, treatPath: path)
    try:
      var modified: Time
      var id = quickIdentity(path, modified)
      msg.treatModified = modified
      let same = hint.identity.size == id.size and hint.identity.quick == id.quick
      if same and hint.identity.fullKnown: id = hint.identity
      if same and hint.doc.len > 0:
        msg.treatDoc = hint.doc
      else:
        var names = taken
        var problems: seq[string]
        var found: seq[FileRecord] = @[]
        for r in store.recordsOf(id, names, problems):
          # (edits without a hash, made at another time, are never taken for the file: an open
          # would not find the choice there)
          if not r.unconfirmed and
              (r.identity.fullKnown or r.modified == modified or r.edits.isEmpty):
            found.add r
        if not id.fullKnown and (found.len > 1 or found.anyIt(it.identity.fullKnown)):
          if not hashing:
            msg.treatHash = true
          else:
            ctx.setPhase "reading every byte"
            id.full = fullHash(path, proc (done, total: int64): bool = ctx.progress(done, total))
            id.fullKnown = true
        if not msg.treatHash:
          let pick = fileDoc(found, id)
          if pick.at >= 0: msg.treatDoc = found[pick.at].doc
          elif pick.several:
            msg.treatFailure = "several documents of what is remembered may be its own, so " &
              "the file must be opened once first"
          else: msg.treatDoc = freeDocName(id, names)
      msg.treatIdentity = id
    except IOError, OSError:
      msg.treatFailure = getCurrentExceptionMsg()
    clearCycleRoots()
    to.post move msg
