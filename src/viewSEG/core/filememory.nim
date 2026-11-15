## What is remembered about a file: its trace edits, kept by the file's
## identity (`core/identity`) and never in the file, in a store that has
## one home at a time.
##
## **The store** is a folder (`Store.home`): by default `files/` in the
## program's configuration folder; a project (a folder the user makes for
## one job) can be the home instead, through the same procs. It holds one
## NIF document per identity, named after the quick identity
## (`<size>-<hash>-<n>.nif`, `n` from 1 telling apart files whose first and
## last 64 KiB agree but whose content does not):
##
## ```
## (.nif27)
## (.vendor "viewSEG")
## (fileMemory
##  (version 1)
##  (identity (size 1048576) (quick "9a0c...") (full "51f3..."))
##  (seen (name "shot12.sgd") (path "/data/shot12.sgd") (opened "2026-11-15T10:02:41Z")
##   (modified 1763200961 120000000))
##  (killed "3 7-9 120")
##  (reversed "12")
##  (allReversed true))
## ```
##
## Trace numbers are the file's, from 1, written as runs (`7-9`) so that a
## long list stays short. `full` is left out until the whole file has been
## hashed. A reader skips what it does not know, so later versions can add
## flags, notes, the join used and filters beside the edits.
##
## **A file's list** handed to a processor is the same document (File >
## Export > Trace edits..., `.nif`), or a CSV table (`.csv`) with a row per
## edited trace: its number in the file, its record (field record number),
## its channel, and the edit. Either can be imported again (`readEdits`),
## here or on another machine.
##
## Everything here runs off the UI thread (a job, or the disk thread): the
## store may be on a drive that does not answer. Every call goes through
## `fs`.

import std/[algorithm, os, parseutils, strutils, times]
import edits, filesystem, identity, nif

const
  StoreFolder* = "files"         ## the store's folder in the configuration folder
  MemoryVersion* = 1             ## the documents' version
  MaxMemoryBytes* = MaxNifBytes  ## the largest document read
  MemorySuffix* = ".nif"

type
  Store* = object
    ## Where what is remembered about files is kept: one home at a time.
    home*: string ## the folder; "" for nowhere (nothing is remembered)

  FileRecord* = object
    ## What is remembered about one file (one identity).
    identity*: FileIdentity
    name*: string     ## the file's name last seen
    path*: string     ## where it was last seen
    opened*: Time     ## when it was last opened
    modified*: Time   ## its modification time then: a file moved keeps it
    edits*: EditLists ## what is kept, by trace index from 0
    doc*: string      ## the document's file name in the store; "" until it has one
    bytes*: int64     ## the document's size (a listing)
    gone*: bool
      ## a listing: no file at `path` any more, or one of another size

func isNowhere*(s: Store): bool {.inline.} = s.home.len == 0
  ## Whether nothing is remembered (tests, a run without settings).

func docPath*(s: Store; doc: string): string =
  ## The document `doc` of the store.
  s.home / doc

func docName*(id: FileIdentity; n: int): string =
  ## The name of the `n`th document (from 1) of quick identity `id`.
  id.key & "-" & $n & MemorySuffix

func isDocName*(name: string): bool =
  ## Whether `name` can be a document of the store.
  if not name.endsWith(MemorySuffix): return false
  let parts = name[0 ..< name.len - MemorySuffix.len].split('-')
  parts.len == 3 and parts[0].len in 1..16 and parts[0].allCharsInSet(HexDigits) and
    parts[1].len == 16 and parts[1].allCharsInSet(HexDigits) and
    parts[2].len in 1..6 and parts[2].allCharsInSet(Digits)

func freeDocName*(id: FileIdentity; taken: openArray[string]): string =
  ## The first document name of `id` that none of `taken` has.
  var n = 1
  result = docName(id, n)
  while result in taken:
    inc n
    result = docName(id, n)

# ----------------------------------------------------------------- runs --

func runsText*(traces: openArray[int]): string =
  ## `traces` (indices from 0, ascending) as trace numbers from 1, in runs:
  ## "3 7-9 120".
  var i = 0
  while i < traces.len:
    var j = i
    while j + 1 < traces.len and traces[j + 1] == traces[j] + 1: inc j
    if result.len > 0: result.add ' '
    result.add $(traces[i] + 1)
    if j > i: result.add "-" & $(traces[j] + 1)
    i = j + 1

proc readRuns*(text: string; traces: var seq[int]; problems: var seq[string];
    what: string; most = high(int32)) =
  ## The trace numbers from 1 in `text` ("3 7-9 120"), as indices from 0,
  ## ascending and each once, into `traces`; each part that is not a number
  ## or a run (or past `most`) is a problem, and is passed by.
  var parts = 0
  for part in text.splitWhitespace:
    inc parts
    var a, b: int
    let dash = part.find('-', start = 1)
    let ok = if dash < 0: part.parseInt(a) == part.len and (b = a; true)
             else: part.parseInt(a) == dash and
               part.parseInt(b, dash + 1) == part.len - dash - 1
    if not ok or a < 1 or b < a or b > most:
      if problems.len < WordedProblems:
        problems.add what & ": \"" & part & "\" is not a trace number or a run of them"
    elif b - a > 50_000_000:
      problems.add what & ": the run " & part & " is too long"
    else:
      for t in a .. b: traces.add t - 1
  traces = sortedTraces(traces)

# ------------------------------------------------------------- documents --

proc timeText(t: Time): string = t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc parseTimeText(s: string; t: var Time): bool =
  try:
    t = parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime
    true
  except TimeParseError, ValueError:
    false

proc memoryDocument*(r: FileRecord): string =
  ## `r` as the store's document (the module's documentation).
  var w = initNifWriter(breakDepth = 1)
  w.open "fileMemory"
  w.open "version"
  w.add MemoryVersion
  w.close
  w.open "identity"
  w.open "size"
  w.add r.identity.size
  w.close
  w.open "quick"
  w.add hex(r.identity.quick)
  w.close
  if r.identity.fullKnown:
    w.open "full"
    w.add hex(r.identity.full)
    w.close
  w.close
  w.open "seen"
  w.open "name"
  w.add r.name
  w.close
  w.open "path"
  w.add r.path
  w.close
  w.open "opened"
  w.add timeText(r.opened)
  w.close
  w.open "modified"
  w.add r.modified.toUnix
  w.add int64(r.modified.nanosecond)
  w.close
  w.close
  for edit in [teKilled, teReversed]:
    if r.edits.lists[edit].len > 0:
      w.open $edit
      w.add runsText(r.edits.lists[edit])
      w.close
  if r.edits.allReversed:
    w.open "allReversed"
    w.add true
    w.close
  w.close
  w.finish

proc hexValue(s: string; x: var uint64): bool =
  s.len == 16 and s.allCharsInSet(HexDigits) and (x = fromHex[uint64](s); true)

proc readIdentity(n: NifNode; id: var FileIdentity; problems: var seq[string]) =
  for k in n.kids:
    if k.kind == nkTree and k.kids.len == 1:
      let v = k.kids[0]
      case k.tag
      of "size":
        if v.kind == nkInt and v.intVal >= 0: id.size = v.intVal
        else: problems.add "identity: the size is not a number of bytes"
      of "quick":
        if v.kind != nkString or not hexValue(v.text, id.quick):
          problems.add "identity: the quick hash is not 16 hexadecimal digits"
      of "full":
        if v.kind == nkString and hexValue(v.text, id.full): id.fullKnown = true
        else: problems.add "identity: the full hash is not 16 hexadecimal digits"
      else: discard # a later version's

proc readSeen(n: NifNode; r: var FileRecord; problems: var seq[string]) =
  for k in n.kids:
    if k.kind == nkTree and k.kids.len >= 1:
      let v = k.kids[0]
      case k.tag
      of "name":
        if v.kind == nkString: r.name = v.text
      of "path":
        if v.kind == nkString: r.path = v.text
      of "opened":
        if v.kind != nkString or not parseTimeText(v.text, r.opened):
          problems.add "seen: the time it was opened is not a time"
      of "modified":
        if v.kind == nkInt and k.kids.len == 2 and k.kids[1].kind == nkInt and
            k.kids[1].intVal in 0 ..< 1_000_000_000:
          r.modified = initTime(v.intVal, int(k.kids[1].intVal))
        else: problems.add "seen: the modification time is not a time"
      else: discard

proc readEditsIn(n: NifNode; r: var FileRecord; problems: var seq[string]) =
  ## The edit lists of the document `n` (its top node), into `r.edits`.
  for k in n.kids:
    if k.kind == nkTree:
      case k.tag
      of "killed", "reversed":
        let edit = if k.tag == "killed": teKilled else: teReversed
        var traces: seq[int]
        for v in k.kids:
          if v.kind == nkString: readRuns(v.text, traces, problems, k.tag)
          elif v.kind == nkInt and v.intVal >= 1 and v.intVal <= high(int32):
            traces.add int(v.intVal) - 1
          else: problems.add k.tag & ": not a list of trace numbers"
        r.edits.lists[edit] = sortedTraces(r.edits.lists[edit] & traces)
      of "allReversed":
        if k.kids.len == 1 and k.kids[0].kind == nkIdent and k.kids[0].text in ["true", "false"]:
          r.edits.allReversed = k.kids[0].text == "true"
        else: problems.add "allReversed: not true or false"
      else: discard

proc readMemory*(doc: openArray[NifNode]; name: string; problems: var seq[string]): FileRecord =
  ## The record a document of the store (or a file's list exported as NIF)
  ## holds. Raises `NifError` when it holds no `fileMemory` node, or one of
  ## a later version that this one cannot read; what else it cannot use is
  ## a problem.
  result = FileRecord(doc: name)
  var found = false
  for n in doc:
    if n.isTree("fileMemory") and not found:
      found = true
      for k in n.kids:
        if k.kind == nkTree:
          case k.tag
          of "version":
            if k.kids.len != 1 or k.kids[0].kind != nkInt:
              problems.add "version: not a number"
            elif k.kids[0].intVal > MemoryVersion:
              var e = newException(NifError, name & " was written by a later version of " &
                "viewSEG (version " & $k.kids[0].intVal & ")")
              raise e
          of "identity": readIdentity(k, result.identity, problems)
          of "seen": readSeen(k, result, problems)
          else: discard
      readEditsIn(n, result, problems)
  if not found:
    raise newException(NifError, name & " holds no trace edits (no fileMemory node)")

proc readMemoryFile*(path: string; problems: var seq[string]): FileRecord =
  ## The record in the store's document at `path`. Raises `NifError` for a
  ## document that cannot be read (`IOError` when the file cannot).
  var text = ""
  let size = fs.getFileSize(path)
  if size > MaxMemoryBytes:
    raise newException(NifError, path.extractFilename & " is larger than " &
      $(MaxMemoryBytes shr 20) & " MB")
  text = fs.readFile(path)
  result = readMemory(parseNif(text, path.extractFilename), path.extractFilename, problems)
  result.bytes = text.len

# ----------------------------------------------------------------- CSV --

const CsvHeader* = "trace,record,channel,edit"
  ## the first line of a file's list as CSV

proc rowsOf(l: EditLists): seq[(int, TraceEdit)] =
  ## A row per trace and edit: by trace, a kill before a reversal.
  for edit in [teKilled, teReversed]:
    for t in l.lists[edit]: result.add (t, edit)
  result.sort(proc (a, b: (int, TraceEdit)): int =
    if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1] == teReversed, b[1] == teReversed))

proc editsCsv*(l: EditLists; records, channels: openArray[float64]): string =
  ## `l` as a CSV table: a row per trace and edit, ascending; `records`
  ## and `channels` are each edited trace's field record number and channel
  ## (in the order of the rows, NaN for none), as the file's keys have them.
  ## A file whose every trace is reversed has a row with trace "all".
  result = CsvHeader & "\n"
  if l.allReversed: result.add "all,,,reversed\n"
  for i, (t, edit) in rowsOf(l):
    let rec = if i < records.len and records[i] == records[i]: $int64(records[i]) else: ""
    let chan = if i < channels.len and channels[i] == channels[i]: $int64(channels[i]) else: ""
    result.add $(t + 1) & "," & rec & "," & chan & "," & $edit & "\n"

proc csvRows*(l: EditLists): seq[int] =
  ## The traces of the rows `editsCsv` writes, in their order.
  for (t, _) in rowsOf(l): result.add t

proc readEditsCsv*(text, name: string; problems: var seq[string]): EditLists =
  ## The edits of a CSV table (`editsCsv`'s, or one made by hand): a header
  ## line naming a `trace` column (the trace's number in the file, from 1,
  ## or "all") and an `edit` column (`killed` or `reversed`; "kill" and
  ## "reverse" too); without an `edit` column every trace listed is killed.
  ## Lines it cannot use are problems.
  var lines = text.splitLines
  var traceCol, editCol = -1
  var first = 0
  while first < lines.len and lines[first].strip.len == 0: inc first
  if first < lines.len:
    let names = lines[first].split({',', ';', '\t'})
    for i, c in names:
      case c.strip.toLowerAscii
      of "trace", "traceno", "trace number": traceCol = i
      of "edit", "action": editCol = i
      else: discard
  if traceCol < 0:
    problems.add name & ": the first line names no \"trace\" column"
    return
  var lists: array[TraceEdit, seq[int]]
  for n in first + 1 ..< lines.len:
    let line = lines[n].strip
    if line.len > 0 and not line.startsWith('#'):
      let cells = line.split({',', ';', '\t'})
      let at = name & " line " & $(n + 1)
      var edit = teKilled
      var ok = true
      if editCol >= 0:
        let e = if editCol < cells.len: cells[editCol].strip.toLowerAscii else: ""
        case e
        of "killed", "kill", "k": edit = teKilled
        of "reversed", "reverse", "r", "polarity": edit = teReversed
        else:
          ok = false
          if problems.len < WordedProblems: problems.add at & ": \"" & e & "\" is not an edit"
      if ok:
        let t = if traceCol < cells.len: cells[traceCol].strip else: ""
        var v: int
        if t.toLowerAscii == "all" and edit == teReversed: result.allReversed = true
        elif t.parseInt(v) == t.len and t.len > 0 and v >= 1 and v <= high(int32):
          lists[edit].add v - 1
        elif problems.len < WordedProblems:
          problems.add at & ": \"" & t & "\" is not a trace number"
  for edit in TraceEdit: result.lists[edit] = sortedTraces(lists[edit])

proc readEdits*(content, name: string; doc: openArray[NifNode]; docError: string;
    problems: var seq[string]; identity: var FileIdentity; hasIdentity: var bool): EditLists =
  ## The edits in a file's list the user imports: a NIF document (`.nif`:
  ## the store's form, with the identity of the file it was made on) or a
  ## CSV table (any other name). Raises `ValueError` (a `NifError` for NIF)
  ## when it holds none it can use.
  hasIdentity = false
  if name.toLowerAscii.endsWith(".nif"):
    if docError.len > 0: raise newException(NifError, docError)
    let r = readMemory(doc, name, problems)
    identity = r.identity
    hasIdentity = r.identity.size > 0 or r.identity.quick != 0
    result = r.edits
  else:
    result = readEditsCsv(content, name, problems)
    if result.isEmpty and problems.len > 0:
      raise newException(ValueError, problems[0])

# --------------------------------------------------------------- listing --

proc recordsOf*(s: Store; id: FileIdentity; taken: var seq[string];
    problems: var seq[string]): seq[FileRecord] =
  ## The documents of the store that may be about the file of quick
  ## identity `id`, read; `taken` gets every document name of that quick
  ## identity. A document that cannot be read is a problem. Raises
  ## `OSError` only when the store's folder cannot be listed (one that is
  ## not there yet holds nothing).
  if s.isNowhere or not fs.dirExists(s.home): return
  let start = id.key & "-"
  for kind, path in fs.walkDir(s.home):
    let name = path.extractFilename
    if kind == pcFile and name.startsWith(start) and name.isDocName:
      taken.add name
      try:
        var p: seq[string]
        let r = readMemoryFile(path, p)
        if r.identity.size == id.size and r.identity.quick == id.quick: result.add r
      except NifError, IOError, OSError:
        problems.add name & ": " & getCurrentExceptionMsg()

proc listRecords*(s: Store; problems: var seq[string];
    progress: proc (done, total: int): bool {.gcsafe.} = nil): seq[FileRecord] =
  ## Every document of the store, read, each with whether its file is gone
  ## (`gone`: nothing at the path it was last seen at, or a file of another
  ## size), the newest opened first. A document that cannot be read is a
  ## problem. Raises `OSError` when the folder cannot be listed.
  if s.isNowhere or not fs.dirExists(s.home): return
  var names: seq[string]
  for kind, path in fs.walkDir(s.home):
    if kind == pcFile and path.extractFilename.isDocName: names.add path
  names.sort()
  for i, path in names:
    if progress != nil and not progress(i, names.len): break
    try:
      var p: seq[string]
      var r = readMemoryFile(path, p)
      try:
        r.gone = r.path.len == 0 or not fs.fileExists(r.path) or
          fs.getFileSize(r.path) != r.identity.size
      except OSError:
        r.gone = true
      result.add r
    except NifError, IOError, OSError:
      problems.add path.extractFilename & ": " & getCurrentExceptionMsg()
  result.sort(proc (a, b: FileRecord): int = cmp(b.opened, a.opened))

func keptWords*(l: EditLists): string =
  ## What `l` keeps, in words: "3 killed, 1 reversed, all reversed";
  ## "nothing" for none.
  var parts: seq[string]
  if l.lists[teKilled].len > 0: parts.add $l.lists[teKilled].len & " killed"
  if l.lists[teReversed].len > 0: parts.add $l.lists[teReversed].len & " reversed"
  if l.allReversed: parts.add "all reversed"
  if parts.len == 0: "nothing" else: parts.join(", ")
