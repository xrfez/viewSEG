## The file list as a table: the rows the filter lets through, in the order
## the user sorted the table by (name in natural order, type, size or date,
## either way), each cell as text; and stepping from the chosen file to the
## next or previous seismic file's row, as the arrow keys do. Toolkit-neutral: a frontend
## draws the rows it has room for. The rows follow the list's changes
## (`FileList.changes`): a scan's batch, or a file that appears, grows or
## goes while the folder is watched, is merged into the rows there are.

import std/[algorithm, strutils, times]
import ../core/filelist

type
  FileColumn* = enum
    fcName = "Name"
    fcType = "Type"
    fcSize = "Size"
    fcModified = "Modified"

  FileOrder* = object
    ## How the table is sorted.
    column*: FileColumn
    descending*: bool

  FileTable* = object
    ## The rows shown: indices into the list's entries.
    rows*: seq[int]
    gen: uint64       ## the listing, filter and order the rows were made for
    entriesRev: int
    filter: string
    words: seq[string]
    order: FileOrder
    made: bool
    rowsRev: int      ## bumped whenever `rows` change
    touched: seq[int] ## `follow`'s own buffer
    chosen: tuple[path: string; row, rowsRev: int]
      ## the row last found for a path

const kindRank = block:
  ## Each kind's place when the types are sorted by the names shown.
  var names: seq[(string, FileKind)]
  for k in FileKind: names.add ($k, k)
  names.sort()
  var rank: array[FileKind, int]
  for i, (_, k) in names: rank[k] = i
  rank

func cmpEntries(a, b: FileEntry; column: FileColumn): int =
  ## By `column` alone: 0 when equal there.
  case column
  of fcName: 0
  of fcType: cmp(kindRank[a.kind], kindRank[b.kind])
  of fcSize: cmp(a.size, b.size)
  of fcModified: cmp(a.modified, b.modified)

func cmpRows(list: FileList; order: FileOrder; a, b: int): int {.inline.} =
  ## The order of entries `a` and `b` in the table. The entries are in
  ## natural order of their names, so an entry's index breaks a tie by name.
  result = cmpEntries(list.entries[a], list.entries[b], order.column)
  if result == 0: result = cmp(a, b)
  if order.descending: result = -result

proc rebuild(t: var FileTable; list: FileList) =
  ## Every row again: the entries the filter lets through, sorted.
  t.rows.setLen 0
  for i, e in list.entries:
    if e.matches(t.words): t.rows.add i
  if t.order.column != fcName or t.order.descending:
    # By address: a closure that named `list` would hold a copy of every entry.
    let entries = addr list
    let order = t.order
    t.rows.sort(proc (a, b: int): int = cmpRows(entries[], order, a, b))

proc dropRow(t: var FileTable; i: int) =
  ## Takes the row of entry `i` out, if there is one.
  let r = t.rows.find(i)
  if r >= 0: t.rows.delete(r)

proc follow(t: var FileTable; list: FileList; changes: openArray[EntryChange]) =
  ## Brings the rows up to the list after `changes`, which came after the
  ## rows were last made: the rows of the entries the changes left alone
  ## keep their order (only their indices move), and the entries added or
  ## changed are sorted alone and merged in. A row moves only when its entry
  ## changed in what the table sorts by.
  let moves = t.order.column in {fcType, fcSize, fcModified}
  t.touched.setLen 0
  for c in changes:
    case c.kind
    of ecAppended:
      for i in c.at ..< c.at + c.count: t.touched.add i
    of ecInserted:
      for r in t.rows.mitems:
        if r >= c.at: inc r
      for x in t.touched.mitems:
        if x >= c.at: inc x
      t.touched.add c.at
    of ecRemoved:
      t.dropRow(c.at)
      for r in t.rows.mitems:
        if r > c.at: dec r
      var k = 0
      while k < t.touched.len:
        if t.touched[k] == c.at: t.touched.delete(k)
        else:
          if t.touched[k] > c.at: dec t.touched[k]
          inc k
    of ecChanged:
      if moves and c.at notin t.touched:
        t.dropRow(c.at)
        t.touched.add c.at
  # The indices are now the list's: the new rows, sorted, merged in.
  var added = newSeqOfCap[int](t.touched.len)
  for i in t.touched:
    if i notin added and list.entries[i].matches(t.words): added.add i
  if added.len == 0: return
  let entries = addr list
  let order = t.order
  added.sort(proc (a, b: int): int = cmpRows(entries[], order, a, b))
  if t.rows.len == 0 or cmpRows(list, order, t.rows[^1], added[0]) < 0:
    t.rows.add added # the usual case: a scan's batch, by name
    return
  # Merged from the back, in place.
  var (r, a) = (t.rows.high, added.high)
  t.rows.setLen t.rows.len + added.len
  var w = t.rows.high
  while a >= 0:
    if r >= 0 and cmpRows(list, order, t.rows[r], added[a]) > 0:
      t.rows[w] = t.rows[r]
      dec r
    else:
      t.rows[w] = added[a]
      dec a
    dec w

proc update*(t: var FileTable; list: FileList; filter: string; order: FileOrder) =
  ## Makes the rows again when the listing, the filter or the order changed
  ## since the last call; follows the entries' changes in the rows it has
  ## (`FileList.changes`) when only they did; otherwise does nothing, so it
  ## can run every frame. Making the rows allocates nothing per file, and a
  ## scan's batch or a file that appears costs a pass over the rows, not a
  ## sort of them.
  if t.made and t.gen == list.gen and t.filter == filter and t.order == order:
    if t.entriesRev == list.entriesRev: return
    let missed = list.entriesRev - t.entriesRev
    if missed > 0 and missed <= list.changes.len:
      t.follow(list, list.changes.toOpenArray(list.changes.len - missed, list.changes.high))
      t.entriesRev = list.entriesRev
      inc t.rowsRev
      return
  t.gen = list.gen
  t.entriesRev = list.entriesRev
  if t.filter != filter or not t.made:
    t.filter = filter
    t.words = filterWords(filter)
  t.order = order
  t.made = true
  t.rebuild(list)
  inc t.rowsRev

func rowOf*(t: FileTable; list: FileList; path: string): int =
  ## The row showing `path`; -1 when it is not shown.
  for r, i in t.rows:
    if list.entries[i].path == path: return r
  -1

proc chosenRow*(t: var FileTable; list: FileList; path: string): int =
  ## `rowOf` for the frame: the row found last, while the rows and the path
  ## are the same (a folder of 100 000 files would compare as many paths
  ## each frame).
  if t.chosen.rowsRev != t.rowsRev or t.chosen.path != path:
    t.chosen = (path, t.rowOf(list, path), t.rowsRev)
  t.chosen.row

func stepped*(t: FileTable; list: FileList; current: string; delta: int): string =
  ## The seismic file `delta` seismic files' rows after `current` (before
  ## it, for a negative `delta`), stopping at the first and last; survey
  ## files are passed by (they are loaded into the survey, not shown). The
  ## first seismic row (the last, stepping back) when `current` is not
  ## shown; "" when no seismic file is.
  let r = t.rowOf(list, current)
  let dir = if delta >= 0: 1 else: -1
  template seismic(row: int): bool = list.entries[t.rows[row]].kind.isSeismic
  if r < 0:
    var i = if dir > 0: 0 else: t.rows.high
    while i in 0 .. t.rows.high:
      if seismic(i): return list.entries[t.rows[i]].path
      i += dir
    return ""
  var (at, left, i) = (r, abs(delta), r + dir)
  while left > 0 and i in 0 .. t.rows.high:
    if seismic(i):
      at = i
      dec left
    i += dir
  list.entries[t.rows[at]].path

func sizeText*(bytes: int64): string =
  ## "812 B", "4.2 KB", "65.1 MB", "1.27 GB" (powers of 1000, as file
  ## managers mostly show them).
  const units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var x = float64(bytes)
  var u = 0
  while x >= 999.95 and u < units.high:
    x /= 1000
    inc u
  if u == 0: $bytes & " B"
  elif x < 9.995: formatFloat(x, ffDecimal, 2) & " " & units[u]
  else: formatFloat(x, ffDecimal, 1) & " " & units[u]

proc dateText*(t: Time): string =
  ## The local date and time to the minute: "2026-10-20 08:03".
  t.local.format("yyyy-MM-dd HH:mm")

proc shortDateText*(t, now: Time): string =
  ## The time alone for a file of today ("08:03"), the date alone for older
  ## ones ("2026-10-20"), as file managers show them in a narrow column.
  let (d, n) = (t.local, now.local)
  if d.year == n.year and d.yearday == n.yearday: d.format("HH:mm")
  else: d.format("yyyy-MM-dd")

func typeText*(e: FileEntry): string = $e.kind
