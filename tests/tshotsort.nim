## The Shot log's sort index and layout: a sort by several columns is stable, lists an
## empty cell last whichever way a key goes, sorts numbers by value, times by instant and
## other text without regard to case; it never changes the log or its row numbers; a
## layout places columns by name, keeps what it does not know at the end, and survives
## its NIF form.
##
## Seen to fail: with empty cells compared as the smallest value, `emptyLast` listed a
## blank first in a descending key; with the file order not the last tie-break,
## `stable` reversed equal rows; with a number compared as text, `numbers` put 10 before
## 9; with the layout's unknown columns dropped, `newColumn` lost the new column.

import std/[monotimes, options, strutils, times]
import viewSEG/core/[nif, shotlayout, shotlog, shotsort]

proc build(text: string): tuple[log: ShotLog, view: ShotView, map: ShotLogMap] =
  var map = guessMap(text)
  result.log = parseShotLog(text, map)
  result.map = map
  result.view = result.log.shots(map)

proc sorted(text: string; keys: openArray[RowKey]): seq[int32] =
  let b = build(text)
  let s = newSortBuild(b.log.len, keys)
  while not s.advance(b.log, b.view, b.map, 3): discard
  s.order

proc main*() =
  const text = "shot point,name,Y\n" &
    "9,bravo,5\n" & "10,Alpha,\n" & "9,alpha,5\n" & "11,,7\n" & "10,charlie,1\n"
  let b = build(text)
  doAssert b.log.len == 5

  block numbers:
    let o = sorted(text, [RowKey(col: 0, kind: rkNumber)])
    doAssert o == @[0'i32, 2, 1, 4, 3], $o # 9 before 10 (by value, not by text)

  block stable:
    # rows 0 and 2 tie on the shot point 9; the file order breaks the tie, either way
    let up = sorted(text, [RowKey(col: 0, kind: rkNumber)])
    let down = sorted(text, [RowKey(col: 0, kind: rkNumber, descending: true)])
    doAssert down == @[3'i32, 1, 4, 0, 2], $down
    doAssert up[0] == 0 and up[1] == 2

  block multiKey:
    let o = sorted(text, [RowKey(col: 0, kind: rkNumber),
      RowKey(col: 1, kind: rkText, descending: true)])
    doAssert o == @[0'i32, 2, 4, 1, 3], $o # 9: bravo before alpha; 10: charlie before Alpha

  block emptyLast:
    for desc in [false, true]:
      let o = sorted(text, [RowKey(col: 2, kind: rkNumber, descending: desc)])
      doAssert o[^1] == 1, "the blank Y was not last, descending " & $desc & ": " & $o
    let t = sorted(text, [RowKey(col: 1, kind: rkText)])
    doAssert t[^1] == 3 and t[0] == 1, $t

  block textWithoutCase:
    let o = sorted(text, [RowKey(col: 1, kind: rkText)])
    doAssert o[0] == 1 and o[1] == 2, "Alpha and alpha tie, in file order: " & $o

  block numberTextColumn:
    # a text column of numbers sorts by value
    let o = sorted("a,b\nx,10\ny,9\nz,\n", [RowKey(col: 1, kind: rkText)])
    doAssert o == @[1'i32, 0, 2], $o

  block noKeys:
    doAssert sorted(text, newSeq[RowKey]()) == @[0'i32, 1, 2, 3, 4]

  block rowsUntouched:
    let before = b.log.cell(1, 1)
    discard sorted(text, [RowKey(col: 1, kind: rkText)])
    doAssert b.log.cell(1, 1) == before and b.log.len == 5

  block layoutPlaces:
    let keys = @["A", "B", "C", "D"]
    let l = ShotLayout(columns: @[ShotColumnLayout(name: "C", width: 12),
      ShotColumnLayout(name: "A", hidden: true), ShotColumnLayout(name: "Gone")],
      sort: @[(name: "B", descending: true), (name: "Gone", descending: false)])
    let p = l.places(keys, [true, true, true, true])
    doAssert p.len == 4
    doAssert p[0].col == 2 and p[0].width == 12'f32 and p[1].col == 0 and p[1].hidden
    doAssert p[2].col == 1 and p[3].col == 3 and not p[2].hidden, "newColumn: unknown go last"
    doAssert l.sortColumns(keys) == @[(col: 1, descending: true)]
    let ignored = l.places(keys, [true, false, true, true])
    doAssert ignored.len == 3 and ignored[2].col == 3, "an ignored column stays out"

  block twinNames:
    let keys = @["X", "X"]
    let l = ShotLayout(columns: @[ShotColumnLayout(name: "X", hidden: true),
      ShotColumnLayout(name: "X")])
    let p = l.places(keys, [true, true])
    doAssert p[0].col == 0 and p[0].hidden and p[1].col == 1 and not p[1].hidden

  block nifRoundTrip:
    let l = ShotLayout(columns: @[ShotColumnLayout(name: "Shot \"point\"", width: 10.5),
      ShotColumnLayout(name: "Y", hidden: true)], sort: @[(name: "Y", descending: true)])
    var w = initNifWriter()
    w.writeLayout l
    let nodes = parseNif(w.text, "t")
    var back = ShotLayout()
    for n in nodes:
      if n.kind == nkTree and n.tag == "layout": back = readLayout(n)
    doAssert back == l, $back
    var empty = initNifWriter()
    empty.writeLayout ShotLayout()
    doAssert "layout" notin empty.text

  block savedLayouts:
    var saved: seq[SavedShotLayout]
    let l = ShotLayout(sort: @[(name: "A", descending: false)])
    saved.remember("h1", l)
    saved.remember("h2", l)
    saved.remember("h1", ShotLayout(sort: @[(name: "B", descending: false)]))
    doAssert saved.len == 2 and saved[0].headers == "h1"
    doAssert saved.layoutFor("h1").sort[0].name == "B"
    saved.remember("h1", ShotLayout())
    doAssert saved.len == 1 and saved.layoutFor("h1").isDefault

  block bigLog:
    var big = "shot point,t,name\n"
    for i in 0 ..< 200_000:
      big.add $((i * 7919) mod 100_003) & "," & $(i mod 977) & ",n" & $(i mod 5003) & "\n"
    let g = build(big)
    let t0 = getMonoTime()
    let s = newSortBuild(g.log.len, [RowKey(col: 0, kind: rkNumber),
      RowKey(col: 2, kind: rkText, descending: true)])
    while not s.advance(g.log, g.view, g.map, 20_000): discard
    let ms = (getMonoTime() - t0).inMilliseconds
    echo "sorted 200000 rows by two columns in ", ms, " ms"
    doAssert ms < 5000
    for i in 1 ..< s.order.len:
      doAssert cmp(g.log.cell(s.order[i - 1], 0).parseInt, g.log.cell(s.order[i], 0).parseInt) <= 0

  echo "tshotsort: ok"

when isMainModule:
  main()
