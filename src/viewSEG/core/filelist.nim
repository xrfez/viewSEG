## The file list: the seismic files of a folder, or of files the user chose,
## that the user steps through, one shown at a time, and the survey files
## (SPS, SEG P1) beside them, which are loaded into the survey instead.
##
## A listing is made off the UI thread (`filejobs.scanWork`, a job on the
## background lane): the folder's names are read and put in natural order
## ("shot2" before "shot10"), then the first bytes of each file are read to
## tell whether it is SEG-Y, SEG-D or SEG-2 (parseSEG's `detectKind`), or an
## SPS or P1 file (`core/filekinds`), so a folder of thousands of files is
## listed without opening any of them. The other files are counted, not
## listed. The scan posts what it found in batches (`mkListed`), so the
## first files appear at once.
##
## `chosen` is the file the main plot window shows, or is opening to show:
## the list marks it, and stepping (the arrow keys) goes on from it.
##
## **Changes.** The entries are changed only through `merge`, `insertEntry`,
## `removeAt`, `changedAt` and `replaceEntries`, which note each change
## (`changes`), so that the file table (`view/filetable`) follows a scan's
## batches or a single new file in the rows it already has, instead of
## sorting every row again. Many files gone or new at once (`replaceEntries`)
## are one pass over the entries, and the table makes its rows again.

import std/[algorithm, monotimes, options, os, strutils, tables, times]
import filekinds, jobs, recordingkind, sigtypes, traceorder, treatas

export filekinds

const
  SniffBytes* = 4096 ## the bytes read from each file to tell its standard
  ListBatch* = 64    ## entries a scan posts at a time, at most
  MaxTreeFiles* = 20_000
    ## files a listing with the subfolders included looks at, at most: a tree
    ## with more is cut there, and the list says so
  StoppedShowAfter* = initDuration(seconds = 15)
    ## how long a stopped `.dat` must have stayed as it is before "Follow the latest" shows it
    ## when no newer `.dat` of its controller is listed
  MaxChanges* = 4096 ## changes of the entries kept for the file table, at most
  ManyChanges* = 64
    ## files gone or new in one look beyond which the entries are made again
    ## in one pass (`replaceEntries`) rather than changed one by one

type
  FileStatus* = enum
    ## What the folder's watch knows of a listed file.
    fsSteady = "steady"    ## as listed, or as it was at the look before
    fsWriting = "writing"  ## it changed since the look before, or just appeared: being written
    fsShort = "incomplete" ## steady, but it ends before its last trace (still being written,
                           ## or cut short)

  KindState* = enum
    ksUnread ## not read yet (a job reads it after the listing)
    ksNone   ## read: not a file with a kind (no live trace, or it cannot be read)
    ksNotKnown
      ## read: a seismic file too large to be opened for its kind; opening it tells
    ksMultiplexed
      ## read: multiplexed SEG-D, not opened for its kind (the open demultiplexes a copy of the
      ## whole file); opening it tells
    ksKnown ## read: `FileEntry.recording` is its kind

  KindAnswer* = object
    ## What the job that reads kinds found for one file, as the file was then.
    path*: string
    size*: int64
    modified*: Time
    state*: KindState    ## `ksNone`, `ksNotKnown`, `ksMultiplexed` or `ksKnown`
    kind*: RecordingKind ## when `state` is `ksKnown`
    order*: TraceOrder   ## how its traces are written, when `state` is `ksKnown`
    treat*: TreatAs      ## what the user forced for the file (`core/filememory`), whatever `state`
    treatUnconfirmed*: bool
      ## `treat` is of a document that may be another content's: the file's hash settles it

  FileEntry* = object
    ## One file of the list: a seismic file, or a survey file.
    path*: string             ## absolute and normalized, as files are opened
    name*: string
    folder*: string
      ## the subfolders between the folder listed and the file, "a/b" (always
      ## "/"); "" for a file in the folder itself, or when subfolders are not included
    kind*: FileKind
    size*: int64
    modified*: Time
    status*: FileStatus
    isNew*: bool ## it appeared after the folder was listed, and has not been shown yet
    sweep*: SweepInfo
      ## a signature file's facts from its header, never a decoded sample (`kind` is `fkDat` or
      ## `fkVib`); empty for every other file
    kindState*: KindState
    recording*: RecordingKind ## the kind read from the file, when `kindState` is `ksKnown`
    traceOrder*: TraceOrder ## the order of its traces, read with the kind
    treat*: TreatAs ## what the user forced for the file: kind and order shown instead
    treatPending*: set[TreatPart]
      ## `treat` is, in part, of a document that may be another content's: no job uses that
      ## part until the file's hash confirms it
    steadySince*: MonoTime
      ## when the watch first saw the file as it is now (`fs.now`): a stopped `.dat` is followed
      ## once it has stayed so for `StoppedShowAfter`; unset for a file not being watched

  WatchedFile* = object
    ## A file as a look at the folder (or a scan) found it.
    path*: string
    exists*: bool     ## false: it is gone (removed, renamed)
    kind*: FileKind   ## fkUnknown: neither seismic nor survey, or not yet (too short to tell)
    size*: int64
    modified*: Time
    changing*: bool   ## it changed since the look before, or was not there then
    sweep*: SweepInfo ## a signature file's facts from its header (`fkDat`, `fkVib`)
    listed*: bool     ## one of the files the listing names (else an open file elsewhere)
    unopened*: bool
      ## it could not be opened to tell what it is (no permission): the watch
      ## tries again at each look, as a change of its permissions changes
      ## neither its size nor its time

  EntryChangeKind* = enum
    ecAppended ## `count` entries were added at the end, from `at`
    ecInserted ## an entry was added at `at`: those after it moved one on
    ecRemoved  ## the entry at `at` was taken out: those after it moved one back
    ecChanged  ## the entry at `at` changed (its size, time or marks; never its name)

  EntryChange* = object
    ## One change of a list's entries, at the indices of the list as it was
    ## right after it.
    kind*: EntryChangeKind
    at*: int
    count*: int ## ecAppended: how many

  FileList* = object
    ## What the file list shows. Changed only by `AppState`.
    title*: string           ## the folder listed, or "3 files"; "" before any listing
    folder*: string          ## the folder listed; "" for files chosen one by one
    asked*: seq[string]      ## the paths the listing was asked for (for a refresh)
    entries*: seq[FileEntry] ## the seismic and survey files, in natural order of their names
    others*: int             ## files that are neither, so not listed
    unreadable*: int         ## files that could not be read
    subfolders*: int         ## folders inside the folder listed (not hidden ones)
    recursive*: bool         ## the subfolders' files are listed too ("Include subfolders")
    looked*: int             ## files looked at so far by a scan that goes through subfolders
    capped*: bool            ## the tree has more than `MaxTreeFiles` files: the list stops there
    scanning*: bool          ## the scan has not finished
    job*: JobId              ## the scan's job; `NoJob` for none
    gen*: uint64             ## bumped by each new listing; what a scan posts carries it
    chosen*: string          ## the file the main plot shows or is opening; "" for none
    failed*: seq[string]     ## files of the list that could not be opened
    error*: string           ## why the listing failed; "" when it did not
    revision*: int           ## bumped on every change
    entriesRev*: int         ## bumped on every change of `entries`, once per change noted
    pairs*: Table[string, string]
      ## the `.dat` and `.vib` of one sweep: each path to its partner's, in both directions
      ## (`core/sweeps.pairSweeps`); a file of no pair is not in it
    pairsRev*: int ## bumped when `pairs` changes
    pairNotes*: Table[string, string]
      ## why a signature file has no pair when its list knows something: several `.dat` files
      ## fit, or another `.vib` claims its `.dat`
    changes*: seq[EntryChange]
      ## the newest changes of `entries`, oldest first, at most `MaxChanges`:
      ## the last one made `entriesRev`

func autoRecordingOf*(e: FileEntry): Option[RecordingKind] =
  ## The kind of recording told from the file itself: none while it is not read, for a file
  ## that is not seismic and for one without a kind.
  if e.kindState == ksKnown: some(e.recording) else: none(RecordingKind)

func recordingOf*(e: FileEntry): Option[RecordingKind] =
  ## The kind of recording `e` is treated as, as the Files panel shows it: the one the user
  ## forced, else the one told from the file (`autoRecordingOf`); none while it is not read,
  ## for a file that is not seismic and for one without a kind. Every reader of the kind goes
  ## through here.
  if e.treat.kind.isSome: e.treat.kind else: e.autoRecordingOf

func traceOrderOf*(e: FileEntry): Option[TraceOrder] =
  ## The order of the traces `e` is treated as: what the file says with the parts the user
  ## forced put over it; none while it is not read and for a file without one.
  if e.kindState == ksKnown: some(applied(e.traceOrder, e.treat))
  elif e.treat.orderSet: some(applied(TraceOrder(), e.treat))
  else: none(TraceOrder)

func subfoldersNote*(f: FileList): string =
  ## What an empty listing of a folder that has only subfolders says, so the empty
  ## list is not left unexplained; "" otherwise.
  if f.title.len > 0 and not f.scanning and f.error.len == 0 and f.entries.len == 0 and
      f.subfolders > 0 and not f.recursive:
    result = "No seismic files here; " & $f.subfolders &
      (if f.subfolders == 1: " subfolder" else: " subfolders")

func sweepKey*(e: FileEntry): int64 =
  ## What a list sorts a signature file by: a `.dat`'s trigger, a `.vib`'s start second (a pair
  ## then lies side by side: the `.vib` began 0.2 to 1.5 s before its trigger). A file that is
  ## none, or that its library refuses, sorts first.
  if e.kind in SignatureFileKinds and e.sweep.problem.len == 0: e.sweep.triggerNs
  else: low(int64)

func isDigit(c: char): bool {.inline.} = c in {'0'..'9'}

func naturalCmp*(a, b: string): int =
  ## Compares names as people sort them: case-insensitively, with runs of
  ## digits compared as numbers ("shot2" before "shot10"); names that are
  ## equal so ("a01" and "a1", "A" and "a") as plain text.
  var i, j = 0
  while i < a.len and j < b.len:
    if a[i].isDigit and b[j].isDigit:
      var i2 = i
      var j2 = j
      while i2 < a.len and a[i2].isDigit: inc i2
      while j2 < b.len and b[j2].isDigit: inc j2
      var x = i # skip leading zeros, then the longer run is the larger number
      while x < i2 - 1 and a[x] == '0': inc x
      var y = j
      while y < j2 - 1 and b[y] == '0': inc y
      if i2 - x != j2 - y: return cmp(i2 - x, j2 - y)
      for k in 0 ..< i2 - x:
        if a[x + k] != b[y + k]: return cmp(a[x + k], b[y + k])
      i = i2
      j = j2
    else:
      let (p, q) = (a[i].toLowerAscii, b[j].toLowerAscii)
      if p != q: return cmp(p, q)
      inc i
      inc j
  result = cmp(a.len - i, b.len - j)
  if result == 0: result = cmp(a, b)

func filterWords*(filter: string): seq[string] =
  ## The words of a filter typed by the user, in lower case.
  filter.toLowerAscii.splitWhitespace

func folderOf*(root, path: string): string =
  ## The subfolders `path` is in below `root`, "a/b", with "/" between them whatever
  ## the system's separator; "" for a file in `root` itself or outside it.
  let dir = path.parentDir
  let start = if root.endsWith(DirSep) or root.endsWith(AltSep): root.len else: root.len + 1
  if root.len == 0 or dir.len < start or not dir.startsWith(root): return ""
  result = dir[start .. ^1]
  when DirSep != '/': result = result.replace(DirSep, '/')

func holds(name, word: string): bool =
  ## Whether `name` holds `word` (lower case), in any case. Allocates
  ## nothing: the file table runs it on every file of a folder.
  for i in 0 .. name.len - word.len:
    var j = 0
    while j < word.len and name[i + j].toLowerAscii == word[j]: inc j
    if j == word.len: return true
  false

func matches*(e: FileEntry; words: openArray[string]): bool =
  ## Whether every one of `words` (`filterWords`) is in `e`'s name or in the
  ## subfolders it is in, in any case; no words match every file.
  for word in words:
    if not e.name.holds(word) and not e.folder.holds(word): return false
  true

func matches*(e: FileEntry; filter: string): bool =
  ## Whether every word of `filter` is in `e`'s name or its subfolders, in any
  ## case; an empty filter matches every file.
  e.matches(filterWords(filter))

func entryCmp(name, path: string; e: FileEntry): int =
  ## The order of the entries: by name, in natural order, then by path (the
  ## same name in two folders of a listing of chosen files).
  result = naturalCmp(name, e.name)
  if result == 0: result = cmp(path, e.path)

func place(list: FileList; name, path: string): int =
  ## Where an entry named `name` at `path` goes in the entries: the first
  ## index whose entry is not before it.
  var (lo, hi) = (0, list.entries.len)
  while lo < hi:
    let mid = (lo + hi) div 2
    if entryCmp(name, path, list.entries[mid]) > 0: lo = mid + 1 else: hi = mid
  lo

func find*(list: FileList; path: string): int =
  ## The index of `path` in the list's entries; -1 when it is not listed. A
  ## binary search: the entries are in order (`merge`, `insertEntry`).
  let name = path.extractFilename
  let at = list.place(name, path)
  if at < list.entries.len and list.entries[at].path == path: at else: -1

const MaxCachedKinds* = 4096
  ## the kinds a `KindCache` keeps at least before it drops those of files no longer listed

type
  KindCache* = object
    ## The kinds of recording read this session, by file: a listing of a folder read before
    ## takes them again, and only a file without one is read. An answer holds for the file as
    ## it was read (its size and time) and for the vendor maps' load it was read with.
    answers: Table[string, KindAnswer]
    vendors: int ## the vendor maps' load (`vendorGen`) every answer was read with

func len*(c: KindCache): int {.inline.} = c.answers.len

func cachedKind*(c: KindCache; e: FileEntry; vendors: int): Option[KindAnswer] =
  ## The answer read for `e` as it is now (its size and time) under the vendor maps' load
  ## `vendors`; none when there is none.
  if vendors == c.vendors:
    let a = c.answers.getOrDefault(e.path)
    if a.path.len > 0 and a.size == e.size and a.modified == e.modified: return some(a)
  none(KindAnswer)

proc remember*(c: var KindCache; a: sink KindAnswer; vendors: int; list: FileList) =
  ## Keeps `a`, read under the vendor maps' load `vendors`: answers of another load are
  ## dropped. Past `MaxCachedKinds` (or twice the files listed, if more) the answers of files
  ## `list` does not hold are dropped, so the cache stays the size of what is listed.
  if a.state == ksUnread: return
  if vendors != c.vendors:
    c.answers.clear()
    c.vendors = vendors
  c.answers[a.path] = a
  if c.answers.len > max(MaxCachedKinds, 2 * list.entries.len):
    var gone: seq[string] = @[]
    for path in c.answers.keys:
      if list.find(path) < 0: gone.add path
    for path in gone: c.answers.del path

proc note(list: var FileList; kind: EntryChangeKind; at: int; count = 1) =
  if list.changes.len >= MaxChanges: list.changes = list.changes[MaxChanges div 2 .. ^1]
  list.changes.add EntryChange(kind: kind, at: at, count: count)
  inc list.entriesRev
  inc list.revision

proc insertEntry*(list: var FileList; e: sink FileEntry): int =
  ## Adds `e` (a file not listed yet) in its place in the entries and
  ## returns its index.
  result = list.place(e.name, e.path)
  if result == list.entries.len:
    list.entries.add e
    list.note(ecAppended, result)
  else:
    list.entries.insert(e, result)
    list.note(ecInserted, result)

proc removeAt*(list: var FileList; i: int) =
  ## Takes entry `i` out.
  list.entries.delete(i)
  list.note(ecRemoved, i)

proc replaceEntries*(list: var FileList; removed: openArray[int]; added: sink seq[FileEntry]) =
  ## Takes the entries at `removed` (indices, in any order) out and adds
  ## `added` (files not listed yet) in their places, in one pass over the
  ## entries: what a look that found many files gone or new does, where one
  ## by one each would move every entry after it. Noted as a change the file
  ## table does not follow, so it makes its rows again, once.
  var gone = newSeq[bool](list.entries.len)
  for i in removed:
    if i in 0 ..< gone.len: gone[i] = true
  added.sort(proc (a, b: FileEntry): int = entryCmp(a.name, a.path, b))
  var next = newSeqOfCap[FileEntry](list.entries.len + added.len)
  var a = 0
  for i in 0 ..< list.entries.len:
    if not gone[i]:
      while a < added.len and entryCmp(added[a].name, added[a].path, list.entries[i]) < 0:
        next.add move added[a]
        inc a
      next.add move list.entries[i]
  while a < added.len:
    next.add move added[a]
    inc a
  list.entries = move next
  list.changes.setLen 0 # more than the table would follow one by one
  inc list.entriesRev
  inc list.revision

proc changedAt*(list: var FileList; i: int) =
  ## Notes that entry `i` changed: its size, time or marks (`FileEntry`'s
  ## fields but its name and path).
  list.note(ecChanged, i)

proc merge*(list: var FileList; found: openArray[FileEntry]) =
  ## Adds `found` (files not listed yet: a scan names each file once) to the
  ## entries, keeping them in order. A scan posts in that order, so its
  ## entries go at the end, and a batch is one change.
  var appended = -1 # the first of a run of entries added at the end
  for e in found:
    let at = list.place(e.name, e.path)
    if at == list.entries.len:
      if appended < 0: appended = at
      list.entries.add e
    else:
      if appended >= 0: # the run first: an insertion moves its indices
        list.note(ecAppended, appended, list.entries.len - appended)
        appended = -1
      list.entries.insert(e, at)
      list.note(ecInserted, at)
  if appended >= 0: list.note(ecAppended, appended, list.entries.len - appended)
