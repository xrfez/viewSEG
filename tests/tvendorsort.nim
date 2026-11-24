## A vendor field as a sort key (`SortKey` with `hfVendor` and a name), on the synthetic SEG-D
## file of `utils/vendorfile` read through a made-up vendor map:
##
## - sorting by a trace-level field ascending and descending, by a record-level one (equal in
##   the whole gather: the file's order stays), and by a field with an absent value (the
##   trace holding the sentinel comes last both ways);
## - a vendor key under a built-in key and the reverse; an unknown name is all absent, so the
##   order is the file's, and is said once in Messages;
## - the key through the command (a name by `headerRefOf`: a built-in name wins), the schema,
##   and the settings (`(key (vendor "name") descending)`, an unknown name kept, the old form
##   unchanged, a name over 200 characters a problem);
## - the column is read once across record steps and sorts (`columnsBuilt`), and the maps loaded
##   again sort by the new values;
## - the kernel: absent values last and stable among themselves, a missing column sorts as all
##   absent, and a sort by a column does not copy it.
##
## Seen to fail: with `sortRowsInto` reading no column (every vendor value NaN), `kernel`
## found the file's order; with `refetchVendorLines` asking for the view without sorting
## again, `reload` timed out on the old order; with `uniqueKeys` comparing only the field,
## `command` kept one of two vendor keys.
import std/[json, math, monotimes, os, sequtils, strutils, times]
import parseSEG
import viewSEG/core/[log, panels, settingsnif, sorting, vendormaps, viewport]
import viewSEG/core/vendorlines {.all.}
import viewSEG/core/state {.all.}
import viewSEG/remote/schema
import utils/[fixtures, vendorfile, waiting]

func said(log: MessageLog; part: string): bool =
  for e in log:
    if part in e.text: return true
  false

proc mainReady(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layers.len > 0

proc shows(st: AppState; fields: seq[HeaderRef]): bool =
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending and
    st.tiles(0)[^1].fields == fields

proc sorted(st: var AppState; order: seq[SortKey]; lines: seq[HeaderRef]): Tile =
  ## The tile in `order`, with the trace number and then `lines`.
  st.apply Command(kind: ckHeader, panel: MainPanel,
    header: HeaderChoice(auto: false, fields: @[headerRef(hfTrace)] & lines))
  st.apply Command(kind: ckSort, panel: MainPanel, order: order)
  let fields = @[headerRef(hfTrace)] & lines
  doAssert st.settle(st.panel(MainPanel).layers[0].order == order and st.shows(fields)),
    "no tile in the order " & $order
  st.tiles(0)[^1]

func seen(t: Tile): seq[int] =
  for v in t.header[0]: result.add int(v)

func key(f: HeaderField; descending = false): SortKey = SortKey(field: f, descending: descending)

proc main*() =
  withFixtures fx:
    let path = fx.dir / "lines.sgd"
    writeLines(path)
    let maps = fx.dir / "maps"
    createDir(maps)
    writeFile(maps / "lines.nif", MapText)
    var st = initAppState()
    st.setVendorFolders(@[VendorFolder(dir: maps, origin: voProgram)])
    doAssert st.settle(st.vendorGen == 1 and st.vendorLoad.maps.len == 1)
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.mainReady)
    let lay = st.panel(MainPanel).layout
    st.apply Command(kind: ckView, panel: MainPanel, view: fitAll(lay, 640, 2 * lay.samples))
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 0)
    doAssert st.settle(st.mainReady)
    let builtBefore = columnsBuilt()

    block kernel:
      # the whole file (two records): the absent traces 1 and 4 come last, in file order, both ways
      var f = openSeismic(path, keys = true)
      publishVendors(registry())
      var lines: VendorLines
      doAssert lines.build(addr f, NoSession, path, 0, ["status", "noSuchField"])
      var perm: seq[int]
      let rows = f.rowsOf(0 ..< 6)
      doAssert sortRowsInto(rows, [vendorKey("status")], perm, vendor = lines)
      doAssert perm == @[0, 2, 3, 5, 1, 4], $perm
      doAssert sortRowsInto(rows, [vendorKey("status", true)], perm, vendor = lines)
      doAssert perm == @[5, 3, 2, 0, 1, 4], $perm
      doAssert sortRowsInto(rows, [vendorKey("noSuchField", true)], perm, vendor = lines)
      doAssert perm == @[0, 1, 2, 3, 4, 5], "a column with no value moved the rows"
      doAssert sortRowsInto(rows, [vendorKey("neverBuilt")], perm, vendor = lines)
      doAssert perm == @[0, 1, 2, 3, 4, 5], "a name with no column moved the rows"
      doAssert sortRowsInto(rows, [vendorKey("status"), key(hfTrace, true)], perm, vendor = lines)
      doAssert perm == @[0, 2, 3, 5, 4, 1], "ties among the absent keep the later key: " & $perm
      lines.drop()
      f.close()

    block trace:
      let up = st.sorted(@[vendorKey("counter")], @[vendorRef("counter")])
      doAssert up.seen == @[1, 2, 3], $up.header
      let down = st.sorted(@[vendorKey("counter", true)], @[vendorRef("counter")])
      doAssert down.seen == @[3, 2, 1], $down.header
      doAssert down.header[1] == @[float64(counter(0, 2)), float64(counter(0, 1)),
        float64(counter(0, 0))], "the line does not follow the order: " & $down.header[1]

    block absent:
      # `status` holds a sentinel in the second trace: unknown, last in both directions
      let up = st.sorted(@[vendorKey("status")], @[vendorRef("status")])
      doAssert up.seen == @[1, 3, 2], $up.seen
      let down = st.sorted(@[vendorKey("status", true)], @[vendorRef("status")])
      doAssert down.seen == @[3, 1, 2], $down.seen

    block record:
      # a record-level field is the same on every trace of the record: nothing moves
      let t = st.sorted(@[vendorKey("batch", true)], @[vendorRef("batch")])
      doAssert t.seen == @[1, 2, 3], $t.seen
      # ... and it is the first key, with a built-in key as the tie-break
      let u = st.sorted(@[vendorKey("batch"), key(hfTrace, true)], @[])
      doAssert u.seen == @[3, 2, 1], $u.seen

    block secondary:
      let a = st.sorted(@[key(hfRecord), vendorKey("counter", true)], @[])
      doAssert a.seen == @[3, 2, 1], "a vendor key under a built-in key: " & $a.seen
      let b = st.sorted(@[vendorKey("status"), key(hfTrace, true)], @[])
      doAssert b.seen == @[1, 3, 2], "a built-in key under a vendor key: " & $b.seen
      let c = st.sorted(@[key(hfTrace, true), vendorKey("counter")], @[])
      doAssert c.seen == @[3, 2, 1], $c.seen

    block unknown:
      let t = st.sorted(@[vendorKey("noSuchField", true)], @[])
      doAssert t.seen == @[1, 2, 3], "an unknown name moved the traces: " & $t.seen
      doAssert st.log.said("'noSuchField' is not a header line or a vendor field of lines.sgd"),
        "the unknown name was not said"

    block once:
      # the columns of the keys are read once across record steps and sorts
      let before = columnsBuilt()
      for g in [1, 0, 1, 0]:
        st.apply Command(kind: ckGather, panel: MainPanel, gather: g)
        doAssert st.settle(st.mainReady and st.panel(MainPanel).layers[0].source.gather == g)
        discard st.sorted(@[vendorKey("counter", true)], @[])
      doAssert columnsBuilt() == before, "built " & $(columnsBuilt() - before)
      # the kernel's two, then one each of counter, status, batch and the unknown name
      doAssert columnsBuilt() - builtBefore == 6, "built " & $(columnsBuilt() - builtBefore)

    block command:
      doAssert uniqueKeys(@[vendorKey("a"), vendorKey("b"), vendorKey("a", true), key(hfTrace),
        key(hfTrace, true)]) == @[vendorKey("a"), vendorKey("b"), key(hfTrace)]
      var c = Command(kind: ckSort)
      var problems: seq[string]
      decode(%*[{"field": "counter", "descending": true}, {"field": "Offset"},
        {"field": "channel"}], c.order, "order", problems)
      doAssert problems.len == 0, $problems
      doAssert c.order == @[vendorKey("counter", true), key(hfOffset), key(hfChannel)], $c.order
      doAssert toJson(c.order) == %*[{"field": "counter", "descending": true},
        {"field": "offset", "descending": false}, {"field": "channel", "descending": false}],
        $toJson(c.order)
      decode(%*[{"field": 3}, {"field": ""}, {"nope": 1}], c.order, "order", problems)
      doAssert problems.len == 3, $problems
      st.apply Command(kind: ckSort, panel: MainPanel,
        order: @[vendorKey("counter"), vendorKey("counter", true), vendorKey("serial")])
      doAssert st.panel(MainPanel).layers[0].order == @[vendorKey("counter"), vendorKey("serial")]
      st.apply Command(kind: ckSort, panel: MainPanel, order: @[vendorKey("a\n")])
      doAssert st.panel(MainPanel).layers[0].order == @[vendorKey("counter"), vendorKey("serial")],
        "an unusable name was taken"

    block cap:
      let was = st.panel(MainPanel).layers[0].order
      let msgs = st.log.len
      var many: seq[SortKey]
      for i in 0 ..< MaxSortKeys + 1: many.add vendorKey("f" & $i)
      st.apply Command(kind: ckSort, panel: MainPanel, order: many)
      doAssert st.panel(MainPanel).layers[0].order == was, "25 keys were taken"
      doAssert st.log.len == msgs + 1 and st.log.said("a sort has at most 24 keys"),
        "one message wanted"
      var problems: seq[string]
      var c = Command(kind: ckSort)
      decode(toJson(many), c.order, "order", problems)
      doAssert problems.len == 1 and c.order.len == 0, $problems
      decode(toJson(many[0 ..< MaxSortKeys]), c.order, "order", problems)
      doAssert problems.len == 1 and c.order.len == MaxSortKeys, $problems
      var doc = "(settings (version 1) (plot (order"
      for k in many: doc.add " (key (vendor \"" & k.name & "\"))"
      let over = readSettings(doc & ")))", "over", Settings(), problems)
      doAssert problems.len == 2 and over.plot.order.len == 0, $problems
      let at = doc.rfind(" (key")
      let fit = readSettings(doc[0 ..< at] & ")))", "fit", Settings(), problems)
      doAssert problems.len == 2 and fit.plot.order.len == MaxSortKeys, $problems
      st.apply Command(kind: ckSort, panel: MainPanel, order: many[0 ..< MaxSortKeys])
      doAssert st.panel(MainPanel).layers[0].order.len == MaxSortKeys
      st.apply Command(kind: ckSort, panel: MainPanel, order: was)

    block settings:
      var problems: seq[string]
      st.apply Command(kind: ckSort, panel: MainPanel,
        order: @[vendorKey("counter", true), key(hfOffset), vendorKey("zzz")])
      doAssert st.settle(st.settings.plot.order.len == 3)
      let doc = settingsDocument(st.settings)
      doAssert "(key (vendor \"counter\") descending)" in doc and
        "(key (vendor \"zzz\"))" in doc, doc
      let again = readSettings(doc, "round", Settings(), problems)
      doAssert again.plot.order == st.settings.plot.order, $again.plot.order
      let old = readSettings("(settings (version 1) (plot (order (key offset descending) " &
        "(key trace))))", "old", Settings(), problems)
      doAssert old.plot.order == @[key(hfOffset, true), key(hfTrace)], $old.plot.order
      let long = readSettings("(settings (version 1) (plot (order (key (vendor \"" &
        'x'.repeat(201) & "\")) (key trace))))", "long", Settings(), problems)
      doAssert long.plot.order == @[key(hfTrace)], $long.plot.order
      let bad = readSettings("(settings (version 1) (plot (order (key vendor))))", "bad",
        Settings(), problems)
      doAssert bad.plot.order.len == 0

    block reload:
      let t = st.sorted(@[vendorKey("counter", true)], @[vendorRef("counter")])
      doAssert t.seen == @[3, 2, 1]
      # no maps: the key has no values, the order is the file's
      st.setVendorFolders(@[])
      doAssert st.settle(st.vendorGen == 2 and st.shows(@[headerRef(hfTrace), vendorRef(
          "counter")]) and
        st.tiles(0)[^1].seen == @[1, 2, 3]), "the old column sorted after the maps changed"
      st.setVendorFolders(@[VendorFolder(dir: maps, origin: voProgram)])
      doAssert st.settle(st.vendorGen == 3 and st.shows(@[headerRef(hfTrace), vendorRef(
          "counter")]) and
        st.tiles(0)[^1].seen == @[3, 2, 1]), "the maps' return did not sort"
    st.shutdown()

  echo "tvendorsort: ok"

when isMainModule:
  main()
