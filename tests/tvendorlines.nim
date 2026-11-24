## A vendor field chosen by name as a display line (`hfVendor`, `HeaderRef`), on a synthetic
## SEG-D Rev 2 file of two records of three traces, read through a made-up vendor map:
## a trace-level counter (u32), a status that holds a sentinel in one trace, a serial
## that two blocks both define, and a record-level batch number.
##
## - the line of a trace-level field shows the values the file holds, per trace and per record
##   (the second record's traces are the file's 3 to 5); a record-level field is spread to each
##   trace of its record; a trace that holds the sentinel shows NaN (unknown), never 0;
## - an unknown name, and a text field, show unknown; the other lines of the header are as
##   before and a built-in name wins a clash (`headerRefOf`); a name the file has no field of
##   is said so, a field that cannot be read so (a repeat named without `[i]`, an element of
##   a field not in a repeat) is said with the library's reason, and a text field is said
##   to be text, once;
## - two fields sharing a bare name are told apart as `block.name`;
## - the lines are written to the settings as `(vendor "name")`, read back, an unknown name
##   kept, and the header of an older file (idents only) loads as it did;
## - the command takes the lines as names (`display header`), a built-in field given twice
##   counts once;
## - the maps loaded again (here: none offered) drop the column: the line shows unknown, with
##   no stale values; `VendorLines` builds again after a new load, and for another open file
##   (`SessionId`) of the same path, size and traces, and every time for a file with no
##   session;
## - a file closed, written again with the same size and opened again shows its new values;
##   the columns of a file no longer shown are let go (`columnsHeld`);
## - a row's value is read in place: 2000 values of a column of a million take under 50 ms;
## - a settings name longer than 200 characters is a problem and its line is dropped.
##
## Seen to fail: with `valueAt` giving 0 for an absent trace, `absent` found 0; with the spread
## left out of the column (record-level read per trace of the first record only), `record`
## found the second record's batch wrong; with the stamp not compared in `build`, `reload`
## found the old column; with `headerRefOf` not testing the built-in names first, `names`
## found a vendor line called "channel"; with `valueAt` copying the column, `noCopy` took 433
## ms; with the session left out of `build`'s key, `reload` kept the column of another open
## file, and with `NoSession` compared as a session, it kept the column of a file with none;
## with the session left out and the reader dropping its columns only for no file (as before),
## `reopened` showed the old column, and with the latter alone it found the columns of a
## file no longer shown held; with `usableLineName` not asked, `limits` kept the long name;
## with every library error said as "not a field", `unknown` missed the reason, and with no
## note for a text field, it found none.
import std/[json, math, monotimes, options, os, sequtils, strutils, times]
import parseSEG
import parseSEG/io/diskio
import parseSEG/segd/blocks
import viewSEG/core/[log, panels, session, settingsnif, tiles, vendormaps, viewport]
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
  ## The newest tile answers the panel's request, with `fields` as its lines.
  let p = st.panel(MainPanel)
  not p.pending.isEmpty and st.tiles(0).len > 0 and st.tiles(0)[^1].request == p.pending and
    st.tiles(0)[^1].fields == fields

proc choose(st: var AppState; fields: seq[HeaderRef]): Tile =
  st.apply Command(kind: ckHeader, panel: MainPanel,
    header: HeaderChoice(auto: false, fields: fields))
  doAssert st.settle(st.shows(fields)), "no tile with the lines " & $fields
  st.tiles(0)[^1]

proc showing(st: AppState; path: string): bool =
  ## The main panel shows the open file at `path`.
  let i = st.sessions.findIt(it.path == path)
  st.mainReady and i >= 0 and st.panel(MainPanel).layers[0].source.file == st.sessions[i].id

proc gather(st: var AppState; g: int) =
  st.apply Command(kind: ckGather, panel: MainPanel, gather: g)
  doAssert st.settle(st.mainReady and st.panel(MainPanel).layers[0].source.gather == g)

proc main*() =
  block names:
    doAssert headerRefOf("channel") == HeaderRef(field: hfChannel)
    doAssert headerRefOf("FFID") == HeaderRef(field: hfRecord)
    doAssert headerRefOf("counter") == vendorRef("counter")
    doAssert headerRefOf("vendor field") == vendorRef("vendor field"), "the enum's own name"
    doAssert vendorRef("a") != vendorRef("b") and vendorRef("a") != HeaderRef(field: hfTrace)
    doAssert $vendorRef("counter") == "counter" and $HeaderRef(field: hfTrace) == "trace"

  withFixtures fx:
    let path = fx.dir / "lines.sgd"
    writeLines(path)
    block listing:
      # two fields called serial: told apart by their blocks
      var f = openSeismic(path, keys = true)
      var listed: seq[string]
      for i in registry().vendorFieldNames(f): listed.add i.name
      f.close()
      doAssert "unitInfo.serial" in listed and "aux.serial" in listed and "counter" in listed and
        "serial" notin listed, $listed
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
    doAssert st.panel(MainPanel).layout.traces == PerRecord

    let builtBefore = columnsBuilt()
    block trace:
      let t = st.choose(@[vendorRef("counter"), headerRef(hfTrace)])
      for j in 0 ..< PerRecord:
        doAssert t.header[0][j] == float64(counter(0, j)), $t.header[0]
        doAssert t.header[1][j] == float64(j + 1), "the built-in line changed: " & $t.header[1]
      # the next record: the file's traces 3 to 5
      st.gather(1)
      let u = st.choose(@[vendorRef("counter")])
      for j in 0 ..< PerRecord:
        doAssert u.header[0][j] == float64(counter(1, j)), $u.header[0]
      st.gather(0)

    block keptAcrossSteps:
      # a record step does not read the file's column again
      for g in [1, 0, 1, 0]:
        st.gather(g)
        let t = st.choose(@[vendorRef("counter")])
        doAssert t.header[0][2] == float64(counter(g, 2)), $t.header[0]
      doAssert columnsBuilt() - builtBefore == 1, "built " & $(columnsBuilt() - builtBefore)

    block anotherFile:
      let other = fx.dir / "other.sgd"
      writeLines(other)
      let before = columnsBuilt()
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
      doAssert st.settle(st.mainReady and st.sessions.anyIt(it.path == other))
      discard st.choose(@[vendorRef("counter")])
      doAssert columnsBuilt() - before == 1, "another file built " & $(columnsBuilt() - before)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.mainReady)
      let t = st.choose(@[vendorRef("counter")])
      doAssert t.header[0][1] == float64(counter(0, 1))
      doAssert columnsBuilt() - before == 2, "back to the first file: a new column"

    block sorted:
      # each trace shows its own value in the order shown
      st.apply Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfTrace, descending: true)])
      doAssert st.settle(st.panel(MainPanel).layers[0].order.len == 1)
      let t = st.choose(@[vendorRef("counter"), headerRef(hfTrace)])
      for row in 0 ..< PerRecord:
        doAssert t.header[1][row] == float64(PerRecord - row), $t.header[1]
        doAssert t.header[0][row] == float64(counter(0, PerRecord - 1 - row)), $t.header[0]
      st.apply Command(kind: ckSort, panel: MainPanel, order: @[])
      doAssert st.settle(st.panel(MainPanel).layers[0].order.len == 0)

    block absent:
      let t = st.choose(@[vendorRef("status")])
      doAssert t.header[0][0] == 0 and t.header[0][2] == 2, $t.header[0]
      doAssert t.header[0][1].isNaN, "a sentinel shows as a value: " & $t.header[0][1]

    block record:
      let t = st.choose(@[vendorRef("batch")])
      doAssert t.header[0] == @[float64(batch(0)), float64(batch(0)), float64(batch(0))],
        $t.header[0]
      st.gather(1)
      let u = st.choose(@[vendorRef("batch")])
      doAssert u.header[0] == @[float64(batch(1)), float64(batch(1)), float64(batch(1))],
        $u.header[0]
      st.gather(0)

    block clash:
      let t = st.choose(@[vendorRef("unitInfo.serial"), vendorRef("aux.serial"),
        vendorRef("serial")])
      for j in 0 ..< PerRecord:
        doAssert t.header[0][j] == float64(serialOf(0, j)), $t.header[0]
        doAssert t.header[1][j] == float64(900 + j), $t.header[1]
      doAssert t.header[2][0].isNaN, "the bare name of a clashing field is not a field"

    block unknown:
      let t = st.choose(@[vendorRef("noSuchField"), vendorRef("label"), headerRef(hfTrace),
        vendorRef("rep"), vendorRef("counter[1]")])
      doAssert st.log.said("'noSuchField' is not a header line or a vendor field of lines.sgd"),
        "the unknown name was not said"
      for j in 0 ..< PerRecord:
        doAssert t.header[0][j].isNaN, "an unknown name shows a value"
        doAssert t.header[1][j].isNaN, "a text field shows a number"
        doAssert t.header[3][j].isNaN and t.header[4][j].isNaN
      doAssert t.header[2][1] == 2
      # a field the file has, but that cannot be read so, is said with the library's reason
      doAssert st.log.said("The vendor field 'rep' could not be read from lines.sgd: " &
        "vendor field rep is in a repeat"), "a repeat named without [i]"
      doAssert st.log.said("The vendor field 'counter[1]' could not be read from lines.sgd: " &
        "vendor field counter is not in a repeat"), "an element of a field not in a repeat"
      doAssert not st.log.said("'rep' is not a header line") and
        not st.log.said("'counter[1]' is not a header line")
      # a text field is said as text, once while the file is shown
      st.gather(1)
      discard st.choose(@[vendorRef("label"), headerRef(hfTrace)])
      st.gather(0)
      discard st.choose(@[vendorRef("label")])
      var text = 0
      for e in st.log:
        if e.text == "The vendor field 'label' is text; a display line shows numbers, " &
            "so it shows as unknown.":
          inc text
      doAssert text == 1, "the text field said " & $text & " times"

    block command:
      # the command takes names; a field given twice counts once
      st.apply(Command(kind: ckHeader, panel: MainPanel,
        header: HeaderChoice(auto: false, fields: @[vendorRef("counter"), vendorRef("counter"),
        headerRef(hfChannel), headerRef(hfChannel)])))
      doAssert st.panel(MainPanel).header.fields ==
        @[vendorRef("counter"), headerRef(hfChannel)], $st.panel(MainPanel).header.fields
      var problems: seq[string]
      var c = Command(kind: ckHeader)
      decode(%*{"auto": false, "fields": ["counter", "channel", "serial"]}, c.header,
        "header", problems)
      doAssert problems.len == 0, $problems
      doAssert c.header.fields == @[vendorRef("counter"), headerRef(hfChannel),
        vendorRef("serial")], $c.header.fields
      doAssert toJson(c.header.fields) == %*["counter", "channel", "serial"]
      decode(%*{"fields": [3]}, c.header, "header", problems)
      doAssert problems.len == 1, $problems

    block limits:
      let was = st.panel(MainPanel).header.fields
      var many: seq[HeaderRef]
      for i in 0 .. MaxHeaderLines: many.add vendorRef("f" & $i)
      st.apply Command(kind: ckHeader, panel: MainPanel,
        header: HeaderChoice(auto: false, fields: many))
      doAssert st.panel(MainPanel).header.fields == was, "more than the most lines taken"
      st.apply Command(kind: ckHeader, panel: MainPanel,
        header: HeaderChoice(auto: false, fields: @[vendorRef("a\nb")]))
      doAssert st.panel(MainPanel).header.fields == was, "a name with a newline taken"
      var problems: seq[string]
      var c = Command(kind: ckHeader)
      decode(%*{"fields": ["bad\nname"]}, c.header, "header", problems)
      doAssert problems.len == 1, $problems
      problems.setLen 0
      decode(%*{"fields": ["x".repeat(201)]}, c.header, "header", problems)
      doAssert problems.len == 1, $problems
      # a vendor field is not a sort key: refused, not taken
      var keys: seq[SortKey]
      problems.setLen 0
      decode(%*[{"field": "vendor field"}], keys, "order", problems)
      doAssert problems.len == 1, $problems
      st.apply Command(kind: ckSort, panel: MainPanel,
        order: @[SortKey(field: hfVendor)])
      doAssert st.panel(MainPanel).layers[0].order.len == 0
      doAssert "channel" in $schemaOf(HeaderRef) and "vendor field" notin $schemaOf(HeaderField)
      # the settings file keeps at most that many
      var doc = "(settings (version 1) (plot (header"
      for i in 0 .. MaxHeaderLines: doc.add " (vendor \"f" & $i & "\")"
      doc.add ")))"
      problems.setLen 0
      let got = readSettings(doc, "many", Settings(), problems)
      doAssert got.plot.header.fields.len == MaxHeaderLines and problems.len > 0, $problems
      # a name longer than a line's is a problem, and its line is not kept
      problems.setLen 0
      let long = readSettings("(settings (version 1) (plot (header trace (vendor \"" &
        "x".repeat(201) & "\"))))", "long", Settings(), problems)
      doAssert long.plot.header.fields == @[headerRef(hfTrace)], $long.plot.header.fields
      doAssert problems.len == 1 and "1 to 200 characters" in problems[0], $problems
      problems.setLen 0
      discard readSettings("(settings (version 1) (plot (header bogus)))", "bad", Settings(),
        problems)
      doAssert problems.len > 0 and not problems.anyIt(", vendor" in it), $problems

    block settings:
      discard st.choose(@[vendorRef("counter"), headerRef(hfTrace), vendorRef("noSuchField")])
      let doc = settingsDocument(st.settings)
      doAssert "(vendor \"counter\")" in doc, doc
      var problems: seq[string]
      let again = readSettings(doc, "s", Settings(), problems)
      doAssert problems.len == 0, $problems
      doAssert again.plot.header.fields == st.settings.plot.header.fields and
        not again.plot.header.auto
      doAssert vendorRef("noSuchField") in again.plot.header.fields, "an unknown name dropped"
      # a header of an older file: idents only, as it was
      let old = readSettings("(settings (version 1) (plot (header rcvLine trace)))", "old",
        Settings(), problems)
      doAssert old.plot.header.fields == @[headerRef(hfRcvLine), headerRef(hfTrace)]
      doAssert problems.len == 0, $problems
      # a vendor name without a name is not a line
      problems.setLen 0
      discard readSettings("(settings (version 1) (plot (header trace vendor)))", "bad",
        Settings(), problems)
      doAssert problems.len > 0

    block reopened:
      # a file closed, written again (the same size and traces) and opened again is read
      # again, though its file may take the old one's address; the columns of a file that is
      # no longer shown are let go
      let c = fx.dir / "c.sgd"
      writeLines(c)
      discard st.choose(@[headerRef(hfTrace)]) # (c's first tile has no vendor line)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: c)
      doAssert st.settle(st.showing(c))
      st.gather(0)
      discard st.choose(@[headerRef(hfTrace)])
      let held = columnsHeld()
      var t = st.choose(@[vendorRef("counter")])
      doAssert t.header[0][1] == float64(counter(0, 1)), $t.header[0]
      doAssert columnsHeld() == held + 1, "held " & $(columnsHeld() - held)
      discard st.choose(@[headerRef(hfTrace)])
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.showing(path))
      discard st.choose(@[headerRef(hfTrace)])
      doAssert columnsHeld() == held, "the columns of a file no longer shown are held: " &
        $(columnsHeld() - held)
      let ic = st.sessions.findIt(it.path == c)
      if ic >= 0: st.apply Command(kind: ckClose, file: st.sessions[ic].id)
      doAssert st.settle(not st.sessions.anyIt(it.path == c))
      bump = 7
      let size = getFileSize(c)
      writeLines(c)
      doAssert getFileSize(c) == size
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: c)
      doAssert st.settle(st.showing(c))
      st.gather(0)
      t = st.choose(@[vendorRef("counter")])
      doAssert t.header[0][1] == float64(counter(0, 1)), "the old column shown: " & $t.header[0]
      bump = 0
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.showing(path))
      st.gather(0)

    block noCopy:
      # a row's value is read where the column is held: a column copied at each call (here
      # 8 MB, a thousand times) takes seconds
      var lines = VendorLines()
      lines.put("big", newSeq[float64](1_000_000), 0)
      let at = lines.slot("big")
      var sum = 0.0
      let t0 = getMonoTime()
      for i in 0 ..< 1000:
        sum += lines.valueAt("big", 997 * i) + lines.valueAt(at, 991 * i)
      let ms = (getMonoTime() - t0).inMilliseconds
      doAssert ms < 50 and sum == 0, "2000 values of a column took " & $ms & " ms"
      doAssert lines.valueAt(at, 1_000_000).isNaN and lines.valueAt(-1, 0).isNaN
      lines.drop()

    block reload:
      let t = st.choose(@[vendorRef("counter")])
      doAssert t.header[0][1] == float64(counter(0, 1))
      # the maps in force are loaded again (none this time): the column is dropped, not shown stale
      st.setVendorFolders(@[])
      doAssert st.settle(st.vendorGen == 2 and st.shows(@[vendorRef("counter")]) and
        st.tiles(0)[^1].header[0][1].isNaN), "the old column was kept after the maps changed"
      st.setVendorFolders(@[VendorFolder(dir: maps, origin: voProgram)])
      doAssert st.settle(st.vendorGen == 3 and st.shows(@[vendorRef("counter")]) and
        st.tiles(0)[^1].header[0][1] == float64(counter(0, 1))), "the maps' return did not show"
      # and the library level: a new load builds the column again
      var lines: VendorLines
      var f = openSeismic(path, keys = true)
      publishVendors(registry())
      let one = SessionId(1)
      doAssert lines.build(addr f, one, path, 0, ["counter"])
      doAssert lines.valueAt("counter", 4) == float64(counter(1, 1)) and
        lines.absentCount("counter") == 0
      let n = columnsBuilt()
      doAssert lines.build(addr f, one, path, 0, ["counter"]) and columnsBuilt() == n,
        "built twice"
      doAssert lines.build(addr f, one, path, 99, ["counter"]) and columnsBuilt() == n + 1,
        "a file of another size kept the column"
      doAssert lines.build(addr f, one, path & "x", 99, ["counter"]) and
        columnsBuilt() == n + 2, "another path kept the column"
      doAssert lines.build(addr f, SessionId(2), path & "x", 99, ["counter"]) and
        columnsBuilt() == n + 3, "another open file (the same path, size and traces) kept it"
      # a file with no session is not known to be the same: read again each time
      doAssert lines.build(addr f, NoSession, path, 0, ["counter"]) and
        lines.build(addr f, NoSession, path, 0, ["counter"]) and columnsBuilt() == n + 5,
        "a file with no session kept its column"
      publishVendors(VendorRegistry())
      doAssert lines.build(addr f, one, path, 0, ["counter"])
      doAssert lines.valueAt("counter", 4).isNaN, "a column of an older load was kept"
      lines.drop()
      f.close()
    st.shutdown()

  echo "tvendorlines: ok"

when isMainModule:
  main()
