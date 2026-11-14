## The file list as a table: the rows the filter lets through, in the order
## the user sorted the table by (name in natural order, type, size or date,
## either way), each cell as text; and stepping from the chosen file to the
## next or previous row, as the arrow keys do. Toolkit-neutral: a frontend
## draws the rows it has room for.

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
    gen: uint64 ## the listing, filter and order the rows were made for
    revision: int
    filter: string
    order: FileOrder
    made: bool

const kindRank = block:
  ## Each kind's place when the types are sorted by the names shown.
  var names: seq[(string, SeismicKind)]
  for k in SeismicKind: names.add ($k, k)
  names.sort()
  var rank: array[SeismicKind, int]
  for i, (_, k) in names: rank[k] = i
  rank

func cmpEntries(a, b: FileEntry; column: FileColumn): int =
  ## By `column` alone: 0 when equal there.
  case column
  of fcName: 0
  of fcType: cmp(kindRank[a.kind], kindRank[b.kind])
  of fcSize: cmp(a.size, b.size)
  of fcModified: cmp(a.modified, b.modified)

proc update*(t: var FileTable; list: FileList; filter: string; order: FileOrder) =
  ## Makes the rows again when the list, the filter or the order changed
  ## since the last call; otherwise does nothing, so it can run every frame.
  ## Making them allocates nothing per file (a scan of a large folder makes
  ## them again with each batch it lists).
  if t.made and t.gen == list.gen and t.revision == list.revision and t.filter == filter and
      t.order == order:
    return
  t.gen = list.gen
  t.revision = list.revision
  t.filter = filter
  t.order = order
  t.made = true
  t.rows.setLen 0
  let words = filterWords(filter)
  for i, e in list.entries:
    if e.matches(words): t.rows.add i
  if order.column != fcName or order.descending:
    # The entries are in natural order of their names, so an entry's index
    # breaks a tie by name. By address: a closure that named `list` would
    # hold a copy of every entry.
    let entries = addr list.entries
    t.rows.sort(proc (a, b: int): int =
      result = cmpEntries(entries[][a], entries[][b], order.column)
      if result == 0: result = cmp(a, b)
      if order.descending: result = -result)

func rowOf*(t: FileTable; list: FileList; path: string): int =
  ## The row showing `path`; -1 when it is not shown.
  for r, i in t.rows:
    if list.entries[i].path == path: return r
  -1

func stepped*(t: FileTable; list: FileList; current: string; delta: int): string =
  ## The file `delta` rows after `current` (before it, for a negative
  ## `delta`), stopping at the first and last row; the first row (the last,
  ## stepping back) when `current` is not shown. "" when no row is shown.
  if t.rows.len == 0: return ""
  let r = t.rowOf(list, current)
  let to = if r < 0: (if delta >= 0: 0 else: t.rows.high)
           else: clamp(r + delta, 0, t.rows.high)
  list.entries[t.rows[to]].path

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
