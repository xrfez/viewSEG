## The file list as a table (`view/filetable`): the rows the filter lets
## through (every word, in any case), sorted by name in natural order, type,
## size or date, either way, with ties in name order; stepping from the
## chosen file stops at the first and last row; and making the rows of a
## large folder allocates nothing per file, so a scan that adds a batch every
## frame, or a word typed in the filter, does not stall the frame.
##
## The rows follow the list's changes: a scan's batch, or a file that
## appears, changes or goes, is merged into the rows there are, so a folder
## of 100 000 files sorted by size is not sorted again with each batch; the
## rows so followed are those made from scratch, whatever the changes; and
## the chosen file's row is found once, not every frame.
##
## Seen to fail: with the shot gather ranked before the continuous one in the Kind sort
## (`kindColumn` found the rows differing); with the sort's closure naming `list` (it held a copy of
## every entry), `noAllocationPerFile` counted 40 013 allocations for 20 000
## files sorted by size; with the filter lower-casing each name, 20 012; with
## `update` making every row again after a change, `aScanIsMerged` found "the
## rows were made from scratch 156 times" and, with that count taken out,
## "the median merge took 130011 us, a sort of all the rows 223950 us";
## with `follow` not moving the indices of the rows after an inserted entry,
## `changesAreFollowed` found the rows differing from those made from
## scratch at its first insertion.
##
## Runs alone: it compares the time of a merge with that of a sort.

import std/[algorithm, monotimes, random, times]
import viewSEG/core/[filelist, recordingkind]
import viewSEG/view/filetable

func entry(name: string; kind: FileKind; size: int64; modified = 0): FileEntry =
  FileEntry(path: "/data/" & name, name: name, kind: kind, size: size,
    modified: fromUnix(modified))

proc allocations(): int =
  ## Allocations so far (`-d:nimAllocStats`, which the tests' config sets).
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc names(t: FileTable; f: FileList): seq[string] =
  for i in t.rows: result.add f.entries[i].name

var f = FileList(gen: 1, revision: 1)

proc main*() =
  f.merge([entry("Shot1.sgd", fkSegd, 300, 3), entry("shot2.sgy", fkSegy, 100, 1),
    entry("shot10.sgd", fkSegd, 100, 2), entry("shot11.sg2", fkSeg2, 900, 2)])

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
      found.add entry("shot" & $i & ".sgd", (if i mod 3 == 0: fkSegy else: fkSegd),
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

  block aScanIsMerged:
    # 100 000 files, listed in batches and shown sorted by size: each update
    # merges the batch into the rows (it used to sort them all again). The
    # work is counted: the rows are made from scratch once, for the first
    # batch. And the time is compared with what making them from scratch
    # takes in the same run, under the same load (not with a fixed bound,
    # which a busy machine passed): the median merge takes a small part of a
    # sort of all the rows.
    var big = FileList(gen: 1, revision: 1)
    var t: FileTable
    var batch: seq[FileEntry]
    var merges: seq[Duration]
    let order = FileOrder(column: fcSize, descending: true)
    for i in 0 ..< 100_000:
      batch.add entry("shot" & $i & ".sgd", fkSegd, int64((i * 7919) mod 100_003), i mod 97)
      if batch.len == 640:
        big.merge(batch)
        batch.setLen 0
        let t0 = getMonoTime()
        t.update(big, "", order)
        merges.add getMonoTime() - t0
    doAssert t.rebuilds == 1, "the rows were made from scratch " & $t.rebuilds & " times"
    var sort = initDuration(days = 1)
    for _ in 1 .. 3:
      var fresh: FileTable
      let t0 = getMonoTime()
      fresh.update(big, "", order)
      sort = min(sort, getMonoTime() - t0)
      doAssert t.rows == fresh.rows
    merges.sort()
    let median = merges[merges.len div 2]
    doAssert median.inMicroseconds * 4 < sort.inMicroseconds, "the median merge took " &
      $median.inMicroseconds & " us, a sort of all the rows " & $sort.inMicroseconds & " us"
    echo "tfiletable: the median merge ", median.inMicroseconds, " us, a sort of all the rows ",
      sort.inMicroseconds, " us"

  block changesAreFollowed:
    # Files added, changed and taken out at random, a few at a time between
    # updates (as the folder's watch reports them), under every order and a
    # filter: the rows followed are the rows made from scratch.
    var r = initRand(20261114)
    for order in [FileOrder(), FileOrder(column: fcName, descending: true),
        FileOrder(column: fcSize), FileOrder(column: fcModified, descending: true),
        FileOrder(column: fcType)]:
      for filter in ["", "3"]:
        var list = FileList(gen: 1, revision: 1)
        var next = 0
        proc fresh(r: var Rand; next: var int): FileEntry =
          inc next
          entry("f" & $r.rand(5_000) & "_" & $next & ".sgy", FileKind(1 + r.rand(2)),
            r.rand(1000), r.rand(50))
        var first: seq[FileEntry]
        for i in 0 ..< 300: first.add r.fresh(next)
        list.merge(first)
        var t: FileTable
        t.update(list, filter, order)
        for round in 0 ..< 200:
          for k in 0 .. r.rand(12):
            case r.rand(3)
            of 0, 1: discard list.insertEntry(r.fresh(next))
            of 2:
              if list.entries.len > 0: list.removeAt(r.rand(list.entries.high))
            else:
              if list.entries.len > 0:
                let i = r.rand(list.entries.high)
                list.entries[i].size = r.rand(1000)
                list.entries[i].modified = fromUnix(r.rand(50))
                list.changedAt(i)
          if r.rand(9) == 0: # a scan's batch, at the end
            var tail: seq[FileEntry]
            for j in 0 ..< 5:
              inc next
              tail.add entry("zz" & $next & ".sgd", fkSegd, r.rand(1000), r.rand(50))
            list.merge(tail)
          t.update(list, filter, order)
          var made: FileTable
          made.update(list, filter, order)
          doAssert t.rows == made.rows, "round " & $round & ", " & $order & ", filter " & filter

  block chosenRowIsKept:
    var t: FileTable
    var list = FileList(gen: 1, revision: 1)
    list.merge([entry("a.sgy", fkSegy, 1), entry("b.sgy", fkSegy, 2)])
    t.update(list, "", FileOrder())
    doAssert t.chosenRow(list, "/data/b.sgy") == 1
    discard list.insertEntry(entry("a0.sgy", fkSegy, 3))
    t.update(list, "", FileOrder())
    doAssert t.chosenRow(list, "/data/b.sgy") == 2
    doAssert t.chosenRow(list, "/data/none.sgy") == -1
    doAssert list.find("/data/a0.sgy") == 1 and list.find("/data/none.sgy") == -1

  block kindColumn:
    # the Kind cell says the kind read from the first traces; empty while unread and for a file
    # with none; sorted by the words shown, the empty first; a kind that arrives moves its row
    var list = FileList(gen: 1, revision: 1)
    var shot = entry("a.sgd", fkSegd, 1)
    shot.kindState = ksKnown
    shot.recording = rkShotGather
    var sliced = entry("b.sgd", fkSegd, 1)
    sliced.kindState = ksKnown
    sliced.recording = rkReceiverSliced
    var cont = entry("c.sgd", fkSegd, 1)
    cont.kindState = ksKnown
    cont.recording = rkReceiverContinuous
    var none = entry("d.sgd", fkSegd, 1)
    none.kindState = ksNone
    list.merge([shot, sliced, cont, none, entry("e.sgd", fkSegd, 1)])
    doAssert kindText(list.entries[0]) == "Shot gather"
    doAssert kindText(list.entries[1]) == "Time-sliced receiver gather"
    doAssert kindText(list.entries[2]) == "Continuous receiver gather"
    doAssert kindText(list.entries[3]) == "" and kindText(list.entries[4]) == ""
    var t: FileTable
    t.update(list, "", FileOrder(column: fcKind))
    doAssert t.names(list) == @["d.sgd", "e.sgd", "c.sgd", "a.sgd", "b.sgd"], $t.names(list)
    t.update(list, "", FileOrder(column: fcKind, descending: true))
    doAssert t.names(list) == @["b.sgd", "a.sgd", "c.sgd", "e.sgd", "d.sgd"], $t.names(list)
    t.update(list, "", FileOrder(column: fcKind))
    list.entries[4].kindState = ksKnown # e.sgd is read: a shot gather
    list.entries[4].recording = rkShotGather
    list.changedAt(4)
    t.update(list, "", FileOrder(column: fcKind))
    doAssert t.names(list) == @["d.sgd", "c.sgd", "a.sgd", "e.sgd", "b.sgd"], $t.names(list)

when isMainModule:
  main()
