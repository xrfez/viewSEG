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
##  (allReversed true)
##  (filtered
##   (trace 5 (place "after") (band "band-pass") (dc "none")
##    (f1 10.0) (f2 12.0) (f3 55.0) (f4 60.0))))
##  (treat (kind "shot") (grouping "flag") (sub "station")))
## ```
##
## `treat` is what the user forced for the file's kind and order (a part that is not forced is
## left out); a file with nothing but that has a document of its own, without edits.
##
## **Pending documents.** Edits made on a file whose identity cannot be
## read yet (a drive that does not give its first and last 64 KiB) are
## kept by the file's path instead, in `pending-<hash of the path>.nif`
## (`pendingName`), the same document with the file's size and
## modification time and no quick hash. When that file's identity is next
## read, unchanged, they are taken into its own document and the pending
## one goes; a file that changed since does not take them, and they are
## said.
##
## A document with a part that cannot be read (edited by hand) is not
## written again until its edits change, so as not to drop that part; when
## such a file is opened, the time is kept beside it instead, in
## `<document>.seen` (`seenDocument`), which the listing reads.
##
## Trace numbers are the file's, from 1, written as runs (`7-9`) so that a
## long list stays short. `full` is left out until the whole file has been
## hashed. A reader skips what it does not know, so later versions can add
## flags, notes, the join used and filters beside the edits.
##
## **A file's list** handed to a processor is the same document (Edit >
## Export trace edits..., `.nif`), or a CSV table (`.csv`) with a row per
## edited trace: its number in the file, its record (field record number),
## its channel, and the edit. Either can be imported again (`readEdits`),
## here or on another machine.
##
## Everything here runs off the UI thread (a job, or the disk thread): the
## store may be on a drive that does not answer. Every call goes through
## `fs`.

import std/[algorithm, math, options, os, parseutils, strutils, times]
import edits, filesystem, identity, nif, recordingkind, traceorder, treatas

const
  StoreFolder* = "files" ## the store's folder in the configuration folder
  MemoryVersion* = 1     ## the documents' version
  MaxMemoryBytes* = 64 shl 20
    ## the largest document read, and the largest list imported: a document
    ## of a million traces killed one in two is about 7.5 MB, its CSV 25 MB
  MemorySuffix* = ".nif"
  MaxListTraces* = 20_000_000
    ## the traces one list (killed, or reversed) may name, after its runs
    ## are merged (160 MB of indices, as many as an edit history holds,
    ## `MaxHeldTraces`): a list from elsewhere that names more has the rest
    ## left out and said

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
    treat*: TreatAs   ## what the user told viewSEG to treat the file as (kind, order)
    traces*: int      ## the file's traces when its edits were made; 0 when not known
    doc*: string      ## the document's file name in the store; "" until it has one
    bytes*: int64     ## the document's size (a listing)
    unconfirmed*: bool
      ## the edits the user left on a file whose brought-back record was still
      ## being checked when viewSEG closed: the whole state as left, never
      ## applied by itself (offered, to apply or to forget)
    gone*: bool
      ## a listing: no file at `path` any more (in a folder that is there),
      ## or one of another size
    unreached*: bool
      ## a listing: the folder of `path` is not there (a network drive not
      ## connected): not counted as gone
    looking*: bool
      ## a listing: `path` not looked at yet (`placeOf`, on a job of its
      ## folder's: its drive may not answer)
    silent*: bool
      ## a listing: the drive of `path` did not answer the look in time
      ## (`StallAfter`): not counted as gone
    damaged*: bool
      ## the document had parts that could not be read (said as problems)
    later*: seq[NifNode]
      ## what the document holds that this version does not know (a later
      ## version's), written back as it was
    stamp*: DocStamp
      ## the document file's size and modification time when it was read
      ## (`readMemoryFile`): another program's write since moves it

  DocStamp* = tuple[size: int64; modified: Time; file: int64]
    ## A document file's size, modification time and file number (a write
    ## is a new file renamed over it: a new number, also within the time
    ## stamp's own step); size -1 for no file.

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

const SeenSuffix* = ".seen"
  ## a document's side file: when its file was last opened, for a document
  ## that is not written again (`seenDocument`)

func seenName*(doc: string): string {.inline.} = doc & SeenSuffix
  ## The side file of document `doc`.

const PendingPrefix* = "pending-"

func pendingName*(path: string): string =
  ## The pending document of the file at `path`: its edits while its
  ## identity is not known.
  PendingPrefix & hex(xxh64(path)) & MemorySuffix

func isPendingName*(name: string): bool =
  ## Whether `name` can be a pending document of the store.
  name.len == PendingPrefix.len + 16 + MemorySuffix.len and name.startsWith(PendingPrefix) and
    name.endsWith(MemorySuffix) and
    name[PendingPrefix.len ..< PendingPrefix.len + 16].allCharsInSet(HexDigits)

func isStoreName*(name: string): bool =
  ## Whether `name` is one of the store's own files (a document, a pending
  ## one, or a document's side file).
  name.isDocName or name.isPendingName or (name.endsWith(SeenSuffix) and
    name[0 ..< name.len - SeenSuffix.len].isDocName)

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

proc addRuns(text: string; runs: var seq[Slice[int]]; problems: var seq[string];
    what: string; most, upTo: int; beyond: var seq[Slice[int]]) =
  ## The trace numbers from 1 in `text` ("3 7-9 120"), as runs of indices
  ## from 0 added to `runs`, nothing expanded; each part that is not a
  ## number or a run (or past `most`) is a problem, and is passed by. The
  ## indices from `upTo` on (past a file's last trace) are cut off, into
  ## `beyond`.
  for part in text.splitWhitespace:
    var a, b: int
    let dash = part.find('-', start = 1)
    let ok = if dash < 0: part.parseInt(a) == part.len and (b = a; true)
             else: part.parseInt(a) == dash and
               part.parseInt(b, dash + 1) == part.len - dash - 1
    if not ok or a < 1 or b < a or b > most:
      if problems.len < WordedProblems:
        problems.add what & ": \"" & part & "\" is not a trace number or a run of them"
    else:
      let last = min(b - 1, upTo - 1)
      if last >= a - 1: runs.add (a - 1) .. last
      if last < b - 1: beyond.add max(a - 1, last + 1) .. b - 1

proc merge(runs: var seq[Slice[int]]): seq[Slice[int]] =
  ## `runs` sorted and merged: no two overlap or touch.
  runs.sort(proc (x, y: Slice[int]): int = cmp(x.a, y.a))
  for r in runs:
    if result.len > 0 and r.a <= result[^1].b + 1: result[^1].b = max(result[^1].b, r.b)
    else: result.add r

func count(runs: openArray[Slice[int]]): int =
  for r in runs: result += r.len

proc expandRuns(runs: var seq[Slice[int]]; problems: var seq[string]; what: string;
    bound: int): seq[int] =
  ## The indices of `runs`, ascending and each once, at most `bound` of
  ## them: the runs are merged first, so a list that names one trace many
  ## times costs no more than its traces; what is past the bound is left
  ## out and said.
  let merged = merge(runs)
  let total = count(merged)
  result = newSeqOfCap[int](min(total, bound))
  for r in merged:
    for t in r:
      if result.len < bound: result.add t
  if total > bound:
    problems.add what & ": " & $(total - bound) & " traces past the " & $bound &
      " a list may hold are left out"

proc readRuns*(text: string; traces: var seq[int]; problems: var seq[string];
    what: string; most = high(int32); bound = MaxListTraces) =
  ## The trace numbers from 1 in `text` ("3 7-9 120"), as indices from 0,
  ## ascending and each once, into `traces` (at most `bound` of them, the
  ## rest said); each part that is not a number or a run (or past `most`)
  ## is a problem, and is passed by.
  var runs: seq[Slice[int]]
  for t in traces: runs.add t .. t
  var beyond: seq[Slice[int]]
  addRuns(text, runs, problems, what, most, high(int), beyond)
  traces = expandRuns(runs, problems, what, bound)

# ------------------------------------------------------------- documents --

proc timeText(t: Time): string = t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc parseTimeText(s: string; t: var Time): bool =
  try:
    t = parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()).toTime
    true
  except TimeParseError, ValueError:
    false

proc writeFilter(w: var NifWriter; e: FilterEntry) =
  ## One trace's filter: numbers from 1, the words the enums carry.
  w.open "trace"
  w.add int64(e.trace + 1)
  w.open "place"
  w.add $e.filter.place
  w.close
  w.open "dc"
  w.add $e.filter.spec.dc
  w.close
  w.open "band"
  w.add $e.filter.spec.band
  w.close
  for (tag, x) in [("f1", e.filter.spec.f1), ("f2", e.filter.spec.f2),
      ("f3", e.filter.spec.f3), ("f4", e.filter.spec.f4)]:
    w.open tag
    w.add x
    w.close
  if e.filter.spec.notches.len > 0:
    w.open "notches"
    for n in e.filter.spec.notches:
      w.open "notch"
      w.open "on"
      w.add n.on
      w.close
      w.open "hz"
      w.add n.hz
      w.close
      w.open "width"
      w.add n.widthHz
      w.close
      w.open "harmonics"
      w.add int64(n.harmonics)
      w.close
      w.close
    w.close
  w.close

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
  if r.traces > 0:
    w.open "traces"
    w.add int64(r.traces)
    w.close
  if r.unconfirmed:
    w.open "unconfirmed"
    w.add true
    w.close
  for edit in [teKilled, teReversed, teExcluded]:
    if r.edits.lists[edit].len > 0:
      w.open $edit
      w.add runsText(r.edits.lists[edit])
      w.close
  if r.edits.allReversed:
    w.open "allReversed"
    w.add true
    w.close
  if r.treat.isSet:
    w.open "treat"
    if r.treat.kind.isSome:
      w.open "kind"
      w.add kindName(r.treat.kind.get)
      w.close
    if r.treat.grouping.isSome:
      w.open "grouping"
      w.add groupingName(r.treat.grouping.get)
      w.close
    if r.treat.subSort.isSome:
      w.open "sub"
      w.add subSortName(r.treat.subSort.get)
      w.close
    w.close
  if r.edits.filters.len > 0:
    w.open "filtered"
    for e in r.edits.filters: w.writeFilter e
    w.close
  if r.edits.shifts.len > 0:
    w.open "shifted"
    for e in r.edits.shifts:
      w.open "trace"
      w.add int64(e.trace + 1)
      w.open "ms"
      w.add e.ms
      w.close
      w.close
    w.close
  for n in r.later: w.add n
  w.close
  w.finish

proc seenDocument*(opened: Time): string =
  ## The side file of a document not written again: when its file was last
  ## opened.
  var w = initNifWriter(breakDepth = 1)
  w.open "fileSeen"
  w.open "opened"
  w.add timeText(opened)
  w.close
  w.close
  w.finish

proc readSeenFile(path: string): Time =
  ## When a document's side file says its file was last opened; zero when
  ## it cannot be read.
  try:
    if fs.getFileSize(path) <= 4096:
      for n in parseNif(fs.readFile(path), path.extractFilename):
        if n.isTree("fileSeen"):
          for k in n.kids:
            if k.isTree("opened") and k.kids.len == 1 and k.kids[0].kind == nkString:
              discard parseTimeText(k.kids[0].text, result)
  except NifError, IOError, OSError:
    discard

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

proc readTreat(n: NifNode; r: var FileRecord; problems: var seq[string]) =
  for k in n.kids:
    if k.kind == nkTree and k.kids.len >= 1 and k.kids[0].kind in {nkString, nkIdent}:
      let v = k.kids[0].text
      case k.tag
      of "kind":
        var x: RecordingKind
        if parseKindName(v, x): r.treat.kind = some x
        else: problems.add "treat: " & v & " is not a kind"
      of "grouping":
        var x: TraceGrouping
        if parseGroupingName(v, x): r.treat.grouping = some x
        else: problems.add "treat: " & v & " is not a grouping"
      of "sub":
        var x: TraceSubSort
        if parseSubSortName(v, x): r.treat.subSort = some x
        else: problems.add "treat: " & v & " is not a sub-sort"
      else: discard

func enumText(n: NifNode): string =
  ## A string or an identifier a node holds; "" otherwise.
  if n.kids.len >= 1 and n.kids[0].kind in {nkString, nkIdent}: n.kids[0].text else: ""

func parseEnum[T: enum](s: string; v: var T): bool =
  for x in T:
    if s == $x:
      v = x
      return true
  false

func child(n: NifNode; tag: string): NifNode =
  for k in n.kids:
    if k.kind == nkTree and k.tag == tag: return k

func floatChild(n: NifNode; tag: string; x: var float64): bool =
  let k = n.child(tag)
  if k.kind == nkTree and k.kids.len >= 1 and k.kids[0].kind == nkFloat:
    x = k.kids[0].floatVal
    true
  elif k.kind == nkTree and k.kids.len >= 1 and k.kids[0].kind == nkInt:
    x = float64(k.kids[0].intVal)
    true
  else: false

proc readNotch(n: NifNode; problems: var seq[string]): NotchFilter =
  ## One notch. A field this version does not know is skipped, not a refusal.
  result = NotchFilter()
  var onSet = false
  for k in n.kids:
    if k.kind == nkTree:
      case k.tag
      of "on":
        if k.kids.len >= 1 and k.kids[0].kind == nkIdent and k.kids[0].text in ["true", "false"]:
          result.on = k.kids[0].text == "true"
          onSet = true
      of "hz":
        if not n.floatChild("hz", result.hz): problems.add "notch: hz is not a number"
      of "width":
        if not n.floatChild("width", result.widthHz): problems.add "notch: width is not a number"
      of "harmonics":
        if k.kids.len >= 1 and k.kids[0].kind == nkInt: result.harmonics = int(k.kids[0].intVal)
        else: problems.add "notch: harmonics is not a number"
      else: discard
  if not onSet: result.on = true

proc readFilters(n: NifNode; r: var FileRecord; problems: var seq[string]; upTo: int;
    outside: var int) =
  ## The `(filtered ...)` node: one `(trace N ...)` per trace, numbers from
  ## 1. A child this version does not know is skipped. A trace past `upTo`
  ## is left out and counted in `outside`.
  for k in n.kids:
    if k.kind != nkTree: continue
    if k.tag != "trace": continue # a later field beside the traces
    var number = 0
    var got = false
    if k.kids.len >= 1 and k.kids[0].kind == nkInt and k.kids[0].intVal >= 1 and
        k.kids[0].intVal <= high(int32):
      number = int(k.kids[0].intVal)
      got = true
    if not got:
      problems.add "filtered: a trace is not a trace number"
      continue
    if number - 1 >= upTo:
      inc outside
      continue
    var f = OwnFilter()
    let place = k.child("place").enumText
    if place.len > 0 and not parseEnum(place, f.place):
      problems.add "filtered: \"" & place & "\" is not after or instead"
    let band = k.child("band").enumText
    if band.len > 0 and not parseEnum(band, f.spec.band):
      problems.add "filtered: \"" & band & "\" is not a pass band"
    let dc = k.child("dc").enumText
    if dc.len > 0 and not parseEnum(dc, f.spec.dc):
      problems.add "filtered: \"" & dc & "\" is not a DC removal"
    discard k.floatChild("f1", f.spec.f1)
    discard k.floatChild("f2", f.spec.f2)
    discard k.floatChild("f3", f.spec.f3)
    discard k.floatChild("f4", f.spec.f4)
    let notches = k.child("notches")
    if notches.kind == nkTree:
      for c in notches.kids:
        if c.kind == nkTree and c.tag == "notch":
          f.spec.notches.add readNotch(c, problems)
    f = bounded(f)
    r.edits.filters.add FilterEntry(trace: number - 1, filter: f)
  r.edits.filters.sort(proc (a, b: FilterEntry): int = cmp(a.trace, b.trace))
  var n = 0
  for i in 0 ..< r.edits.filters.len:
    if n == 0 or r.edits.filters[n - 1].trace != r.edits.filters[i].trace:
      r.edits.filters[n] = r.edits.filters[i]
      inc n
  r.edits.filters.setLen n

proc readShifts(n: NifNode; r: var FileRecord; problems: var seq[string]; upTo: int;
    outside: var int) =
  ## The `(shifted ...)` node: one `(trace N (ms ...))` per trace, numbers
  ## from 1. A child this version does not know is skipped. A trace past
  ## `upTo` is left out and counted in `outside`. A shift of no milliseconds
  ## is not stored.
  for k in n.kids:
    if k.kind != nkTree or k.tag != "trace": continue
    var number = 0
    var got = false
    if k.kids.len >= 1 and k.kids[0].kind == nkInt and k.kids[0].intVal >= 1 and
        k.kids[0].intVal <= high(int32):
      number = int(k.kids[0].intVal)
      got = true
    if not got:
      problems.add "shifted: a trace is not a trace number"
      continue
    if number - 1 >= upTo:
      inc outside
      continue
    var ms = 0.0
    if not k.floatChild("ms", ms):
      problems.add "shifted: ms is not a number"
      continue
    if not shiftStorable(ms):
      problems.add "shifted: a shift of " & $ms & " ms is not kept"
      continue
    if ms == 0.0: continue
    r.edits.shifts.add ShiftEntry(trace: number - 1, ms: ms)
  r.edits.shifts.sort(proc (a, b: ShiftEntry): int = cmp(a.trace, b.trace))
  var n = 0
  for i in 0 ..< r.edits.shifts.len:
    if n == 0 or r.edits.shifts[n - 1].trace != r.edits.shifts[i].trace:
      r.edits.shifts[n] = r.edits.shifts[i]
      inc n
  r.edits.shifts.setLen n

proc readEditsIn(n: NifNode; r: var FileRecord; problems: var seq[string]; upTo: int;
    outside: var int) =
  ## The edit lists of the document `n` (its top node), into `r.edits`; the
  ## traces from `upTo` on are left out and counted in `outside`, before
  ## any run is expanded.
  var runs, beyond: array[TraceEdit, seq[Slice[int]]]
  for k in n.kids:
    if k.kind == nkTree:
      case k.tag
      of "killed", "reversed", "excluded":
        let edit = case k.tag
          of "killed": teKilled
          of "reversed": teReversed
          else: teExcluded
        for v in k.kids:
          if v.kind == nkString:
            addRuns(v.text, runs[edit], problems, k.tag, high(int32), upTo, beyond[edit])
          elif v.kind == nkInt and v.intVal >= 1 and v.intVal <= high(int32):
            let t = int(v.intVal) - 1
            if t < upTo: runs[edit].add t .. t else: beyond[edit].add t .. t
          else: problems.add k.tag & ": not a list of trace numbers"
      of "allReversed":
        if k.kids.len == 1 and k.kids[0].kind == nkIdent and k.kids[0].text in ["true", "false"]:
          r.edits.allReversed = k.kids[0].text == "true"
        else: problems.add "allReversed: not true or false"
      of "filtered":
        readFilters(k, r, problems, upTo, outside)
      of "shifted":
        readShifts(k, r, problems, upTo, outside)
      else: discard
  for edit in TraceEdit:
    if runs[edit].len > 0: r.edits.lists[edit] = expandRuns(runs[edit], problems, $edit, MaxListTraces)
    outside += count(merge(beyond[edit]))

proc readMemory*(doc: openArray[NifNode]; name: string; problems: var seq[string];
    upTo: int; outside: var int): FileRecord =
  ## The record a document of the store (or a file's list exported as NIF)
  ## holds, its traces from `upTo` on left out (counted in `outside`).
  ## Raises `NifError` when it holds no `fileMemory` node, or one of a
  ## later version that this one cannot read; what else it cannot use is a
  ## problem.
  result = FileRecord(doc: name)
  let before = problems.len
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
          of "traces":
            if k.kids.len == 1 and k.kids[0].kind == nkInt and k.kids[0].intVal in 1 .. high(int32):
              result.traces = int(k.kids[0].intVal)
            else: problems.add "traces: not a count of traces"
          of "unconfirmed":
            result.unconfirmed = k.kids.len == 1 and k.kids[0].kind == nkIdent and
              k.kids[0].text == "true"
          of "treat": readTreat(k, result, problems)
          of "killed", "reversed", "excluded", "allReversed", "filtered", "shifted":
            discard # readEditsIn
          else: result.later.add k # a later version's: kept as it is
      readEditsIn(n, result, problems, upTo, outside)
  if not found:
    raise newException(NifError, name & " holds no trace edits (no fileMemory node)")
  result.damaged = problems.len > before

proc readMemory*(doc: openArray[NifNode]; name: string; problems: var seq[string]): FileRecord =
  ## `readMemory` with every trace kept.
  var outside = 0
  readMemory(doc, name, problems, high(int), outside)

proc readMemoryFile*(path: string; problems: var seq[string]): FileRecord =
  ## The record in the store's document at `path`. Raises `NifError` for a
  ## document that cannot be read (`IOError` when the file cannot).
  var text = ""
  let size = fs.getFileSize(path)
  if size > MaxMemoryBytes:
    raise newException(NifError, path.extractFilename & " is larger than " &
      $(MaxMemoryBytes shr 20) & " MB")
  let info = fs.getFileInfo(path)
  text = fs.readFile(path)
  result = readMemory(parseNif(text, path.extractFilename, MaxMemoryBytes), path.extractFilename,
    problems)
  result.bytes = text.len
  result.stamp = (info.size, info.lastWriteTime, int64(info.id.file))

# ----------------------------------------------------------------- CSV --

const
  CsvHeader* = "trace,record,channel,edit,file"
    ## the first line of a file's list as CSV
  HeaderSearch = 20 ## the lines a table's header is looked for in (title rows above it)

func csvCell(s: string): string =
  ## `s` as a CSV cell: quoted when it holds a separator, a quote or a line
  ## break.
  if s.contains({',', ';', '\t', '"', '\n', '\r'}): "\"" & s.replace("\"", "\"\"") & "\""
  else: s

func csvCells*(line: string; sep: char): seq[string] =
  ## The cells of the CSV line `line`, separated by `sep`: a cell in double
  ## quotes may hold `sep` and doubled quotes, as spreadsheets write them;
  ## each cell stripped of the blanks around it.
  var cell = ""
  var quoted = false
  var i = 0
  while i < line.len:
    let c = line[i]
    if quoted:
      if c == '"':
        if i + 1 < line.len and line[i + 1] == '"':
          cell.add '"'
          inc i
        else: quoted = false
      else: cell.add c
    elif c == '"' and cell.strip.len == 0:
      cell.setLen 0
      quoted = true
    elif c == sep:
      result.add cell.strip
      cell.setLen 0
    else: cell.add c
    inc i
  result.add cell.strip

proc rowsOf(l: EditLists): seq[(int, TraceEdit)] =
  ## A row per trace and edit: by trace, a kill before a reversal.
  for edit in [teKilled, teReversed, teExcluded]:
    for t in l.lists[edit]: result.add (t, edit)
  result.sort(proc (a, b: (int, TraceEdit)): int =
    if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(ord(a[1] == teReversed) + 2 * ord(a[1] ==
        teExcluded),
      ord(b[1] == teReversed) + 2 * ord(b[1] == teExcluded)))

proc notchText(n: NotchFilter): string =
  ## `hz/width/harmonics`, with `/0` when the notch is off.
  result = formatFloat(n.hz, ffDecimal, 4).strip(trailing = true, chars = {'0'}).strip(
    trailing = true,
    chars = {'.'}) & "/" & formatFloat(n.widthHz, ffDecimal, 4).strip(trailing = true,
    chars = {'0'}).strip(trailing = true, chars = {'.'}) & "/" & $n.harmonics
  if not n.on: result.add "/0"

proc notchesText(ns: openArray[NotchFilter]): string =
  var parts: seq[string]
  for n in ns: parts.add notchText(n)
  parts.join(";")

func msText(ms: float64): string =
  ## A shift in milliseconds: a whole number as an integer, else 3 decimals.
  if ms == trunc(ms) and abs(ms) < 1e15: $int64(ms)
  else: formatFloat(ms, ffDecimal, 3)

proc editsCsv*(l: EditLists; records, channels: openArray[float64]; file: string): string =
  ## `l` as a CSV table: a row per trace and edit, ascending; `records`
  ## and `channels` are each edited trace's field record number and channel
  ## (in the order of the rows, NaN for none), as the file's keys have them,
  ## and every row names the file the list is for (`file`, its name), so a
  ## table handed on says what it is about. A file whose every trace is
  ## reversed has a row with trace "all". A trace's own filter is a row
  ## whose edit is `filtered`, with the filter's columns after the file's
  ## name (left out when no trace has one, so an older table is unchanged).
  ## A time shift is a row whose edit is `shifted`, with an `ms` column
  ## (left out when no trace has one).
  let f = csvCell(file)
  let extra = l.filters.len > 0
  let shifted = l.shifts.len > 0
  result = CsvHeader & (if extra: ",place,band,dc,f1,f2,f3,f4,notches" else: "") &
    (if shifted: ",ms" else: "") & "\n"
  if l.allReversed: result.add "all,,,reversed," & f & "\n"
  for i, (t, edit) in rowsOf(l):
    let rec = if i < records.len and records[i] == records[i]: $int64(records[i]) else: ""
    let chan = if i < channels.len and channels[i] == channels[i]: $int64(channels[i]) else: ""
    result.add $(t + 1) & "," & rec & "," & chan & "," & $edit & "," & f
    if extra: result.add ",,,,,,,"
    if shifted: result.add ","
    result.add "\n"
  let base = rowsOf(l).len
  for j, e in l.filters:
    let i = base + j
    let rec = if i < records.len and records[i] == records[i]: $int64(records[i]) else: ""
    let chan = if i < channels.len and channels[i] == channels[i]: $int64(channels[i]) else: ""
    result.add $(e.trace + 1) & "," & rec & "," & chan & ",filtered," & f & "," &
      $e.filter.place & "," & $e.filter.spec.band & "," & $e.filter.spec.dc & "," &
      formatFloat(e.filter.spec.f1, ffDecimal, 4) & "," &
      formatFloat(e.filter.spec.f2, ffDecimal, 4) & "," &
      formatFloat(e.filter.spec.f3, ffDecimal, 4) & "," &
      formatFloat(e.filter.spec.f4, ffDecimal, 4) & "," &
      csvCell(notchesText(e.filter.spec.notches))
    if shifted: result.add ","
    result.add "\n"
  let shiftBase = base + l.filters.len
  for j, e in l.shifts:
    let i = shiftBase + j
    let rec = if i < records.len and records[i] == records[i]: $int64(records[i]) else: ""
    let chan = if i < channels.len and channels[i] == channels[i]: $int64(channels[i]) else: ""
    result.add $(e.trace + 1) & "," & rec & "," & chan & ",shifted," & f
    if extra: result.add ",,,,,,,"
    result.add "," & msText(e.ms) & "\n"

proc parseNotches(s: string; problems: var seq[string]; at: string): seq[NotchFilter] =
  if s.len == 0: return
  for part in s.split(';'):
    let bits = part.split('/')
    if bits.len notin 3 .. 4:
      problems.add at & ": \"" & part & "\" is not a notch"
      continue
    var n = NotchFilter(on: bits.len == 3 or bits[3] != "0")
    var hz, width: float
    var h: int
    if bits[0].parseFloat(hz) == bits[0].len and bits[1].parseFloat(width) == bits[1].len and
        bits[2].parseInt(h) == bits[2].len:
      n.hz = hz
      n.widthHz = width
      n.harmonics = h
      result.add n
    else: problems.add at & ": \"" & part & "\" is not a notch"

proc csvRows*(l: EditLists): seq[int] =
  ## The traces of the rows `editsCsv` writes, in their order.
  for (t, _) in rowsOf(l): result.add t
  for e in l.filters: result.add e.trace
  for e in l.shifts: result.add e.trace

func csvTrace(t: string; v: var int): bool =
  ## Whether `t` is a trace number from 1 ("12", or "12.0" as a spreadsheet
  ## may write it), into `v`.
  if t.len == 0: return false
  if t.parseInt(v) == t.len: return v >= 1 and v <= high(int32)
  var x: float
  if t.parseFloat(x) == t.len and x >= 1 and x <= float(high(int32)) and x == x.trunc:
    v = int(x)
    return true
  false

proc readEditsCsv*(text, name: string; problems: var seq[string]; upTo: int;
    outside: var int): EditLists =
  ## The edits of a CSV table (`editsCsv`'s, or one made by hand or saved
  ## from a spreadsheet: a UTF-8 byte order mark, CRLF line ends, cells in
  ## quotes, `;` or tabs between them, title rows above the header and
  ## columns it does not know are all fine): a header line naming a `trace`
  ## column (the trace's number in the file, from 1, or "all") and an
  ## `edit` column (`killed` or `reversed`; "kill" and "reverse" too);
  ## without an `edit` column every trace listed is killed. Lines it cannot
  ## use are problems; traces from `upTo` on (past the file's last) are
  ## left out and counted in `outside`.
  var lines = text.splitLines
  if lines.len > 0 and lines[0].startsWith("\xEF\xBB\xBF"): lines[0] = lines[0][3 .. ^1]
  var traceCol, editCol, placeCol, bandCol, dcCol = -1
  var fCol: array[4, int] = [-1, -1, -1, -1]
  var notchCol, msCol = -1
  var sep = ','
  var first = -1
  var looked = 0
  var n = 0
  while first < 0 and n < lines.len and looked < HeaderSearch:
    if lines[n].strip.len > 0:
      inc looked
      for s in [',', ';', '\t']:
        if first < 0:
          let names = csvCells(lines[n], s)
          for i, c in names:
            case c.toLowerAscii
            of "trace", "traceno", "trace number": traceCol = i
            of "edit", "action": editCol = i
            of "place": placeCol = i
            of "band": bandCol = i
            of "dc": dcCol = i
            of "f1": fCol[0] = i
            of "f2": fCol[1] = i
            of "f3": fCol[2] = i
            of "f4": fCol[3] = i
            of "notches": notchCol = i
            of "ms": msCol = i
            else: discard
          if traceCol >= 0: (first, sep) = (n, s)
          else: editCol = -1
    inc n
  if traceCol < 0:
    problems.add name & ": no line at its start names a \"trace\" column"
    return
  var lists: array[TraceEdit, seq[int]]
  for n in first + 1 ..< lines.len:
    let line = lines[n].strip
    if line.len > 0 and not line.startsWith('#'):
      let cells = csvCells(line, sep)
      let at = name & " line " & $(n + 1)
      var edit = teKilled
      var ok = true
      if editCol >= 0:
        let e = if editCol < cells.len: cells[editCol].toLowerAscii else: ""
        case e
        of "killed", "kill", "k": edit = teKilled
        of "reversed", "reverse", "r", "polarity": edit = teReversed
        of "excluded", "exclude", "e": edit = teExcluded
        of "filtered", "filter": edit = teKilled # not used: a filter row, below
        of "shifted", "shift": edit = teKilled # not used: a shift row, below
        else:
          ok = false
          if problems.len < WordedProblems: problems.add at & ": \"" & e & "\" is not an edit"
      let filterRow = editCol >= 0 and editCol < cells.len and
        cells[editCol].toLowerAscii in ["filtered", "filter"]
      let shiftRow = editCol >= 0 and editCol < cells.len and
        cells[editCol].toLowerAscii in ["shifted", "shift"]
      if shiftRow:
        ok = false
        let t = if traceCol < cells.len: cells[traceCol] else: ""
        var v: int
        if csvTrace(t, v) and v - 1 < upTo:
          let s = if msCol >= 0 and msCol < cells.len: cells[msCol] else: ""
          var ms: float
          if s.len == 0 or s.parseFloat(ms) != s.len:
            if problems.len < WordedProblems:
              problems.add at & ": \"" & s & "\" is not a shift in milliseconds"
          elif not shiftStorable(ms):
            if problems.len < WordedProblems:
              problems.add at & ": \"" & s & "\" is not a shift in milliseconds"
          elif ms != 0.0:
            result.shifts.add ShiftEntry(trace: v - 1, ms: ms)
        elif v - 1 >= upTo and csvTrace(t, v): inc outside
        elif problems.len < WordedProblems:
          problems.add at & ": \"" & t & "\" is not a trace number"
      elif filterRow:
        ok = false # not a kill or a reversal
        let t = if traceCol < cells.len: cells[traceCol] else: ""
        var v: int
        if csvTrace(t, v) and v - 1 < upTo:
          var f = OwnFilter()
          template cellAt(col: int): string =
            if col >= 0 and col < cells.len: cells[col] else: ""
          if not parseEnum(cellAt(placeCol), f.place) and cellAt(placeCol).len > 0:
            if problems.len < WordedProblems:
              problems.add at & ": \"" & cellAt(placeCol) & "\" is not after or instead"
          if not parseEnum(cellAt(bandCol), f.spec.band) and cellAt(bandCol).len > 0:
            if problems.len < WordedProblems:
              problems.add at & ": \"" & cellAt(bandCol) & "\" is not a pass band"
          if not parseEnum(cellAt(dcCol), f.spec.dc) and cellAt(dcCol).len > 0:
            if problems.len < WordedProblems:
              problems.add at & ": \"" & cellAt(dcCol) & "\" is not a DC removal"
          var corners = [f.spec.f1, f.spec.f2, f.spec.f3, f.spec.f4]
          for i in 0 .. 3:
            let s = cellAt(fCol[i])
            var x: float
            if s.len > 0 and s.parseFloat(x) == s.len: corners[i] = x
          (f.spec.f1, f.spec.f2, f.spec.f3, f.spec.f4) = (corners[0], corners[1], corners[2],
            corners[3])
          f.spec.notches = parseNotches(cellAt(notchCol), problems, at)
          result.filters.add FilterEntry(trace: v - 1, filter: bounded(f))
        elif v - 1 >= upTo and csvTrace(t, v): inc outside
        elif problems.len < WordedProblems:
          problems.add at & ": \"" & t & "\" is not a trace number"
      elif ok:
        let t = if traceCol < cells.len: cells[traceCol] else: ""
        var v: int
        if t.toLowerAscii == "all" and edit == teReversed: result.allReversed = true
        elif csvTrace(t, v):
          if v - 1 < upTo: lists[edit].add v - 1 else: inc outside
        elif problems.len < WordedProblems:
          problems.add at & ": \"" & t & "\" is not a trace number"
  for edit in TraceEdit: result.lists[edit] = sortedTraces(lists[edit])
  if result.filters.len > 1:
    result.filters.sort(proc (a, b: FilterEntry): int = cmp(a.trace, b.trace))
  if result.shifts.len > 1:
    result.shifts.sort(proc (a, b: ShiftEntry): int = cmp(a.trace, b.trace))

proc readEditsCsv*(text, name: string; problems: var seq[string]): EditLists =
  ## `readEditsCsv` with every trace kept.
  var outside = 0
  readEditsCsv(text, name, problems, high(int), outside)

proc readEdits*(content, name: string; doc: openArray[NifNode]; docError: string;
    traces: int; problems: var seq[string]; identity: var FileIdentity; hasIdentity: var bool;
    outside: var int): EditLists =
  ## The edits in a file's list the user imports onto a file of `traces`
  ## traces: a NIF document (`.nif`: the store's form, with the identity of
  ## the file it was made on) or a CSV table (any other name). The traces
  ## past the file's last are left out before any run is expanded, and
  ## counted in `outside`, so a list from elsewhere costs no more than the
  ## file's traces. Raises `ValueError` (a `NifError` for NIF) when it
  ## holds none it can use.
  hasIdentity = false
  if name.toLowerAscii.endsWith(".nif"):
    if docError.len > 0: raise newException(NifError, docError)
    let r = readMemory(doc, name, problems, traces, outside)
    identity = r.identity
    hasIdentity = r.identity.size > 0 or r.identity.quick != 0
    result = r.edits
  else:
    result = readEditsCsv(content, name, problems, traces, outside)
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
        if r.identity.size == id.size and r.identity.quick == id.quick:
          for x in p:
            problems.add name & ": " & x & " (passed by; the rest is brought back)"
          result.add r
      except NifError, IOError, OSError:
        problems.add name & ": " & getCurrentExceptionMsg()

proc seenPathOf(path: string): string =
  ## The path a document of the store last saw its file at, from its first
  ## bytes only ("" when they do not say): `(seen ... (path "..."))` comes
  ## before the lists, so a large document is not read whole.
  var f: File
  if not fs.open(f, path): return ""
  var head = newString(8192)
  try:
    head.setLen fs.readBuffer(f, path, addr head[0], head.len)
  except IOError:
    head.setLen 0
  finally:
    close(f)
  let at = head.find("(path ")
  if at < 0: return ""
  let tail = head[at + 6 .. ^1]
  let close = tail.find(")")
  if close < 0: return ""
  try:
    for n in parseNif("(path " & tail[0 .. close], "head"):
      if n.isTree("path") and n.kids.len == 1 and n.kids[0].kind == nkString:
        return n.kids[0].text
  except NifError:
    discard
  ""

proc earlierOutputs*(s: Store; path: string; id: FileIdentity;
    problems: var seq[string]): seq[FileRecord] =
  ## The documents of the store whose file was last seen at `path` but is
  ## not the file of identity `id` (another size or other ends: a file
  ## output again under the same name): earlier outputs, whose edits are
  ## not this file's. Each document's first bytes are read for its path;
  ## only those of `path` are read whole.
  result = @[]
  if s.isNowhere or not fs.dirExists(s.home): return
  for kind, doc in fs.walkDir(s.home):
    let name = doc.extractFilename
    if kind == pcFile and name.isDocName and not name.startsWith(id.key & "-") and
        seenPathOf(doc) == path:
      try:
        var p: seq[string] = @[]
        let r = readMemoryFile(doc, p)
        if r.path == path and not sameData(r.identity, id) and not r.edits.isEmpty:
          result.add r
      except NifError, IOError, OSError:
        problems.add name & ": " & getCurrentExceptionMsg()

proc placeOf*(path: string; size: int64): tuple[gone, unreached: bool] =
  ## Whether the file last seen at `path`, of `size` bytes, is gone
  ## (nothing at `path`, in a folder that is there, or a file of another
  ## size), or its folder is not there or cannot be looked at (`unreached`,
  ## as a network drive not connected). Holds the calling thread for as
  ## long as the drive does not answer: call it on a job.
  try:
    if path.len == 0: (true, false)
    elif fs.fileExists(path): (fs.getFileSize(path) != size, false)
    elif fs.dirExists(path.parentDir): (true, false)
    else: (false, true) # a drive not connected is no file gone
  except OSError:
    (false, true)

proc listRecords*(s: Store; problems: var seq[string];
    progress: proc (done, total: int): bool {.gcsafe.} = nil; look = true): seq[FileRecord] =
  ## Every document of the store, read, the newest opened first; with
  ## `look`, each with whether its file is gone (`placeOf`), else each
  ## `looking` (the files' drives looked at apart, folder by folder, so
  ## that one that does not answer holds none of the listing). A document
  ## that cannot be read is a problem. Raises `OSError` when the folder
  ## cannot be listed.
  if s.isNowhere or not fs.dirExists(s.home): return
  var names, seen: seq[string]
  for kind, path in fs.walkDir(s.home):
    if kind == pcFile and path.extractFilename.isDocName: names.add path
    elif kind == pcFile and path.endsWith(SeenSuffix): seen.add path
  names.sort()
  seen.sort()
  for i, path in names:
    if progress != nil and not progress(i, names.len): break
    try:
      var p: seq[string]
      var r = readMemoryFile(path, p)
      for x in p:
        if problems.len < WordedProblems: problems.add path.extractFilename & ": " & x
      if seen.binarySearch(path.seenName) >= 0: # opened since, not written again
        r.opened = max(r.opened, readSeenFile(path.seenName))
      if look: (r.gone, r.unreached) = placeOf(r.path, r.identity.size)
      elif r.path.len == 0: r.gone = true
      else: r.looking = true
      result.add r
    except NifError, IOError, OSError:
      problems.add path.extractFilename & ": " & getCurrentExceptionMsg()
  result.sort(proc (a, b: FileRecord): int = cmp(b.opened, a.opened))

func merged*(base, ours, theirs: EditLists): EditLists =
  ## The edits of a document two programs changed from `base`: `ours` and
  ## `theirs`, each change of either kept (a trace one gave and the other
  ## took away from `base` is the giver's, as is all reversed when only
  ## one changed it).
  result = theirs.minus(base.minus(ours))
  for edit in TraceEdit:
    result.lists[edit] = sortedTraces(result.lists[edit] & ours.minus(base).lists[edit])
  result.allReversed = if ours.allReversed != base.allReversed: ours.allReversed
                       else: theirs.allReversed
  result.filters = mergedFilters(base, ours, theirs)
  result.shifts = mergedShifts(base, ours, theirs)

func keptWords*(l: EditLists): string =
  ## What `l` keeps, in words: "3 killed, 1 reversed, all reversed";
  ## "nothing" for none.
  var parts: seq[string]
  if l.lists[teKilled].len > 0: parts.add $l.lists[teKilled].len & " killed"
  if l.lists[teReversed].len > 0: parts.add $l.lists[teReversed].len & " reversed"
  if l.lists[teExcluded].len > 0: parts.add $l.lists[teExcluded].len & " excluded"
  if l.filters.len > 0: parts.add $l.filters.len & " filtered"
  if l.shifts.len > 0: parts.add $l.shifts.len & " shifted"
  if l.allReversed: parts.add "all reversed"
  if parts.len == 0: "nothing" else: parts.join(", ")

func fileDoc*(docs: openArray[FileRecord]; id: FileIdentity): tuple[at: int; several: bool] =
  ## Which of `docs` (documents of the quick identity of the file `id`, none unconfirmed) is the
  ## file's (`at`, -1 for none): one whose hash of every byte is not the file's never is; of the
  ## others, the one with the file's hash (the newest when several have it), else the only one.
  ## `several`: more than one may be, and the file's hash does not say which.
  var may, exact: seq[int]
  for i, d in docs:
    if not (d.identity.fullKnown and id.fullKnown and d.identity.full != id.full):
      may.add i
      if d.identity.fullKnown and id.fullKnown: exact.add i
  result = (-1, false)
  for i in exact:
    if result.at < 0 or docs[i].opened > docs[result.at].opened: result.at = i
  if exact.len == 0:
    if may.len == 1: result.at = may[0]
    elif may.len > 1: result.several = true

proc treatsOf*(s: Store; ids: openArray[FileIdentity]; modified: openArray[Time];
    unconfirmed: var seq[bool]): seq[TreatAs] =
  ## What the store holds of each file of identity `ids[i]`, modified at `modified[i]`, that the
  ## user forced (`result[i]`), from the file's document (`fileDoc`; the hash of every byte, when
  ## `ids[i]` has it, tells the documents of one quick identity apart). A document the hash does
  ## not say is the file's gives its choice only when it saw the file at that modification time
  ## (one touched or copied since is automatic until it is identified). Nothing forced for a
  ## file with no document, for one whose document cannot be told, or that cannot be read. One
  ## look at the store's folder serves them all. `unconfirmed[i]` says that the choice is of a
  ## document that knows a hash of every byte the file has not been given: it may be another
  ## content's. Reads the documents: worker-only.
  result = newSeq[TreatAs](ids.len)
  unconfirmed = newSeq[bool](ids.len)
  if s.isNowhere or ids.len == 0 or not fs.dirExists(s.home): return
  var names: seq[string] = @[]
  try:
    for kind, path in fs.walkDir(s.home):
      let name = path.extractFilename
      if kind == pcFile and name.isDocName: names.add name
  except OSError:
    return
  for i, id in ids:
    let start = id.key & "-"
    var docs: seq[FileRecord] = @[]
    for name in names:
      if name.startsWith(start):
        try:
          var p: seq[string]
          let r = readMemoryFile(s.docPath(name), p)
          if not r.unconfirmed and r.identity.size == id.size and r.identity.quick == id.quick:
            docs.add r
        except NifError, IOError, OSError:
          discard # said where the document is used
    let at = fileDoc(docs, id).at
    if at >= 0:
      let d = docs[at].identity
      if (id.fullKnown and d.fullKnown and d.full == id.full) or docs[at].modified == modified[i]:
        result[i] = docs[at].treat
        unconfirmed[i] = d.fullKnown and not (id.fullKnown and d.full == id.full)
