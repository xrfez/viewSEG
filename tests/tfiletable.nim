## The file list as a table (`view/filetable`): the rows the filter lets
## through (every word, in any case), sorted by name in natural order, type,
## size or date, either way, with ties in name order; stepping from the
## chosen file stops at the first and last row; and making the rows of a
## large folder allocates nothing per file, so a scan that adds a batch every
## frame, or a word typed in the filter, does not stall the frame.
##
## Seen to fail: with the sort's closure naming `list` (it held a copy of
## every entry), `noAllocationPerFile` counted 40 013 allocations for 20 000
## files sorted by size; with the filter lower-casing each name, 20 012.

import std/[times]
import viewSEG/core/filelist
import viewSEG/view/filetable

func entry(name: string; kind: SeismicKind; size: int64; modified = 0): FileEntry =
  FileEntry(path: "/data/" & name, name: name, kind: kind, size: size,
    modified: fromUnix(modified))

proc allocations(): int =
  ## Allocations so far (`-d:nimAllocStats`, which the tests' config sets).
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc names(t: FileTable; f: FileList): seq[string] =
  for i in t.rows: result.add f.entries[i].name

var f = FileList(gen: 1, revision: 1)
f.merge([entry("Shot1.sgd", skSegd, 300, 3), entry("shot2.sgy", skSegy, 100, 1),
  entry("shot10.sgd", skSegd, 100, 2), entry("shot11.sg2", skSeg2, 900, 2)])

block naturalOrderFirst:
  var t: FileTable
  t.update(f, "", FileOrder())
  doAssert t.names(f) == @["Shot1.sgd", "shot2.sgy", "shot10.sgd", "shot11.sg2"], $t.names(f)
  t.update(f, "", FileOrder(column: fcName, descending: true))
  doAssert t.names(f) == @["shot11.sg2", "shot10.sgd", "shot2.sgy", "Shot1.sgd"], $t.names(f)

block byColumn:
  var t: FileTable
  t.update(f, "", FileOrder(column: fcSize))
  doAssert t.names(f) == @["shot2.sgy", "shot10.sgd", "Shot1.sgd", "shot11.sg2"], $t.names(f)
  t.update(f, "", FileOrder(column: fcSize, descending: true))
  doAssert t.names(f) == @["shot11.sg2", "Shot1.sgd", "shot10.sgd", "shot2.sgy"], $t.names(f)
  t.update(f, "", FileOrder(column: fcType))
  # By the type's name as shown: SEG-2, SEG-D, SEG-Y; a type's files in name order.
  doAssert t.names(f) == @["shot11.sg2", "Shot1.sgd", "shot10.sgd", "shot2.sgy"], $t.names(f)
  t.update(f, "", FileOrder(column: fcType, descending: true))
  doAssert t.names(f) == @["shot2.sgy", "shot10.sgd", "Shot1.sgd", "shot11.sg2"], $t.names(f)
  t.update(f, "", FileOrder(column: fcModified))
  doAssert t.names(f) == @["shot2.sgy", "shot10.sgd", "shot11.sg2", "Shot1.sgd"], $t.names(f)

block filterAndStep:
  var t: FileTable
  t.update(f, "SHOT sgd", FileOrder())
  doAssert t.names(f) == @["Shot1.sgd", "shot10.sgd"], $t.names(f)
  t.update(f, "  1  ", FileOrder())
  doAssert t.names(f) == @["Shot1.sgd", "shot10.sgd", "shot11.sg2"], $t.names(f)
  t.update(f, "", FileOrder())
  doAssert t.stepped(f, "/data/shot2.sgy", 1) == "/data/shot10.sgd"
  doAssert t.stepped(f, "/data/shot2.sgy", -10) == "/data/Shot1.sgd"
  doAssert t.stepped(f, "/data/shot2.sgy", 10) == "/data/shot11.sg2"
  doAssert t.stepped(f, "/elsewhere.sgy", 1) == "/data/Shot1.sgd"
  doAssert t.stepped(f, "/elsewhere.sgy", -1) == "/data/shot11.sg2"
  t.update(f, "nothing like it", FileOrder())
  doAssert t.rows.len == 0 and t.stepped(f, "/data/shot2.sgy", 1) == ""

block noAllocationPerFile:
  var big = FileList(gen: 1, revision: 1)
  var found: seq[FileEntry]
  for i in 0 ..< 20_000:
    found.add entry("shot" & $i & ".sgd", (if i mod 3 == 0: skSegy else: skSegd),
      int64((i * 7919) mod 100_003), i mod 97)
  big.merge(found)
  var t: FileTable
  t.update(big, "", FileOrder()) # the rows' own buffer, once
  for (filter, order) in [("", FileOrder(column: fcSize, descending: true)),
      ("SHOT 1", FileOrder(column: fcType)), ("sgd", FileOrder(column: fcModified)),
      ("", FileOrder(column: fcName, descending: true)), ("7", FileOrder())]:
    inc big.revision
    let before = allocations()
    t.update(big, filter, order)
    let made = allocations() - before
    doAssert made < 100, $made & " allocations for " & $big.entries.len & " files (" &
      filter & ", " & $order & ")"
    doAssert t.rows.len > 0
  # And the order is right at that size: by size, largest first, ties by name.
  inc big.revision
  t.update(big, "", FileOrder(column: fcSize, descending: true))
  for r in 1 ..< t.rows.len:
    doAssert big.entries[t.rows[r - 1]].size >= big.entries[t.rows[r]].size
