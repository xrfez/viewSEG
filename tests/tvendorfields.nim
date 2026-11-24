## The list of vendor fields the display-line menu offers (`core/vendorfieldlist`,
## `core/vendorfieldjobs`, `view/vendorfieldmenu`), on the synthetic file and map of
## `utils/vendorfile`.
##
## - the names: a field's name is the bare one, or `block.name` when two blocks have it
##   (parseSEG's), and also when the bare name is a built-in line's (which `headerRefOf`
##   would choose); a text field and a repeat are not numeric;
## - the menu: numeric fields come first and are ticked when they are lines; text and repeat
##   fields are listed disabled with their reason; a record-level field says so; a chosen line
##   the file lacks is kept, ticked, "(not in this file)"; at the most lines, unticked fields
##   are disabled and say why; more than 25 fields ask for a filter, which matches in any case;
##   no field and no answer yet are told apart; a tick adds the vendor line, an untick removes it;
## - the names arrive by a job, not from a read on the UI thread: none before `watchVendorFields`
##   runs, the file's fields after, one job at a time; an answer for older maps is dropped; the
##   maps loaded again drop the list and it is listed again; a closed file's list is let go.
##
## Seen to fail: with `isBuiltInName` always false, `names` found the field `channel` under the
## built-in's name; with the list kept across a load of the maps (`vendors` not compared in
## `vendorFields`), `reloaded` found the old list; with `takeVendorFields` not comparing the
## load, `stale` found the answer for older maps; with the cap not checked, `cap` found a
## fresh tick enabled.
import std/[options, os, sequtils, strutils]
import parseSEG
import viewSEG/core/[panels, session, vendorfieldlist, vendormaps]
import viewSEG/core/state {.all.}
import viewSEG/view/vendorfieldmenu
import utils/[fixtures, vendorfile, waiting]

func info(name, blk: string; kind = vvInt; level = vlTrace; repeat = false): VendorFieldInfo =
  VendorFieldInfo(name: name, blockName: blk, fieldName: name, kind: kind, level: level,
    isRepeat: repeat)

func entry(name: string; kind = vvInt; level = vlTrace; repeated = false): VendorFieldEntry =
  VendorFieldEntry(name: name, kind: kind, level: level, repeated: repeated)

func names(m: VendorFieldMenu): seq[string] =
  for i in m.items: result.add i.name

proc item(m: VendorFieldMenu; name: string): VendorFieldItem =
  for i in m.items:
    if i.name == name: return i
  raise newException(KeyError, name & " is not listed")

proc main*() =
  block names:
    let e = vendorFieldEntries([info("counter", "unitInfo"), info("channel", "unitInfo"),
      info("TRACE", "unitInfo"), info("aux.serial", "aux", kind = vvText),
      info("rep", "aux", repeat = true)])
    doAssert e.mapIt(it.name) == @["counter", "unitInfo.channel", "unitInfo.TRACE",
      "aux.serial", "rep"], $e
    doAssert e[0].isNumeric and not e[3].isNumeric and not e[4].isNumeric
    doAssert headerRefOf(e[1].name) == vendorRef("unitInfo.channel"), "the field is chosen"

  block menu:
    let list = some(VendorFieldList(entries: @[entry("counter"), entry("label", vvText),
      entry("batch", vvInt, vlRecord), entry("rep", repeated = true), entry("status")]))
    let lines = @[headerRef(hfTrace), vendorRef("counter"), vendorRef("gone")]
    let m = vendorFieldMenu(list, lines, "")
    doAssert m.kind == vmItems and not m.filtered
    doAssert m.names == @["counter", "batch", "status", "label", "rep", "gone"], $m.names
    doAssert m.item("counter").ticked and m.item("counter").enabled
    doAssert not m.item("status").ticked and m.item("status").enabled
    doAssert "(record)" in m.item("batch").tip and "(record)" notin m.item("status").tip
    doAssert not m.item("label").enabled and m.item("label").tip == TextTip
    doAssert not m.item("rep").enabled and m.item("rep").tip == RepeatTip
    doAssert m.item("gone").ticked and m.item("gone").enabled and
      m.item("gone").label == "gone  (not in this file)", "a line the file lacks is kept"
    doAssert vendorFieldMenu(none(VendorFieldList), lines, "").kind == vmReading
    doAssert vendorFieldMenu(some(VendorFieldList()), [headerRef(hfTrace)], "").kind == vmNone
    doAssert vendorFieldMenu(list, lines, "ZZZ").kind == vmNoMatch
    doAssert vendorFieldMenu(list, lines, "COUN").names == @["counter"], "any case"

  block cap:
    var lines: seq[HeaderRef]
    for i in 1 .. MaxHeaderLines: lines.add vendorRef("f" & $i)
    let list = some(VendorFieldList(entries: @[entry("f1"), entry("other")]))
    let m = vendorFieldMenu(list, lines, "")
    doAssert m.item("f1").enabled, "a line at the cap can be unticked"
    doAssert not m.item("other").enabled and m.item("other").tip == CapTip
    doAssert vendorFieldMenu(list, lines[0 ..< 31], "").item("other").enabled

  block filter:
    var entries: seq[VendorFieldEntry]
    for i in 1 .. FilterAbove: entries.add entry("f" & $i)
    doAssert not vendorFieldMenu(some(VendorFieldList(entries: entries)), [], "").filtered
    entries.add entry("speed")
    let m = vendorFieldMenu(some(VendorFieldList(entries: entries)), [], "")
    doAssert m.filtered
    doAssert vendorFieldMenu(some(VendorFieldList(entries: entries)), [], "SPE").names ==
      @["speed"]

  block ticks:
    let lines = @[headerRef(hfTrace), vendorRef("a")]
    doAssert lines.withVendorLine("b", true) == @[headerRef(hfTrace), vendorRef("a"),
      vendorRef("b")]
    doAssert lines.withVendorLine("a", false) == @[headerRef(hfTrace)]
    doAssert lines.withVendorLine("a", true) == lines, "a line is not added twice"

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
    doAssert st.settle(st.sessions.len == 1 and st.shownFile(st.findPanel(MainPanel)) >= 0)
    let id = st.sessions[0].id

    block byJob:
      doAssert st.vendorFields(id).isNone, "listed before anything asked"
      st.watchVendorFields()
      doAssert st.vendorFieldsBusy, "no job started"
      doAssert st.vendorFields(id).isNone, "answered without the job"
      let jobs = st.jobs.list.len
      st.watchVendorFields()
      doAssert st.jobs.list.len == jobs, "a second job started"
      doAssert st.settle((st.watchVendorFields(); st.vendorFields(id).isSome))
      let list = st.vendorFields(id).get
      let listed = list.entries.mapIt(it.name)
      doAssert "counter" in listed and "unitInfo.serial" in listed and "aux.serial" in listed and
        "batch" in listed and "serial" notin listed, $listed
      let batchEntry = list.entries[listed.find("batch")]
      doAssert batchEntry.level == vlRecord and batchEntry.isNumeric
      doAssert not list.entries[listed.find("label")].isNumeric
      doAssert list.entries[listed.find("rep")].repeated
      doAssert st.settle((st.watchVendorFields(); not st.vendorFieldsBusy))
      st.watchVendorFields()
      doAssert not st.vendorFieldsBusy, "a file with its answer is asked again"

    block stale:
      # an answer made with older maps arrives late: it is dropped
      st.mailbox.post Msg(kind: mkVendorFields, vendorFields: VendorFieldList(
        session: id, vendors: st.vendorGen - 1, entries: @[entry("bogus")]))
      for _ in 0 ..< 5:
        discard st.drainInbox()
        sleep 5
      doAssert "bogus" notin st.vendorFields(id).get.entries.mapIt(it.name),
        "an answer for older maps was kept"

    block reloaded:
      st.setVendorFolders(@[])
      doAssert st.settle(st.vendorGen == 2)
      doAssert st.vendorFields(id).isNone, "the list of the old maps was kept"
      doAssert st.settle((st.watchVendorFields(); st.vendorFields(id).isSome))
      doAssert st.vendorFields(id).get.entries.len == 0, "no map loaded: no field"
      st.setVendorFolders(@[VendorFolder(dir: maps, origin: voProgram)])
      doAssert st.settle(st.vendorGen == 3)
      doAssert st.settle((st.watchVendorFields(); st.vendorFields(id).isSome))
      doAssert st.vendorFields(id).get.entries.len > 0

    block closed:
      st.apply Command(kind: ckClose, file: id)
      st.watchVendorFields()
      doAssert st.vendorFields(id).isNone, "the list of a closed file was kept"
      doAssert not st.vendorFieldsBusy

  echo "tvendorfields: ok"

when isMainModule:
  main()
