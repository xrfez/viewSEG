## A project's vendor map rule (docs/user/vendor-maps.md), in `core`, on a SEG-Y
## file and maps made here:
##
## - Automatic is the default; a named map is kept in the project's document and
##   read back by a new run; a project document without the rule reads as
##   Automatic;
## - two maps equally specific for a file: Automatic uses the first, the one named
##   decodes when chosen; None decodes nothing, and the rule is said in the answer;
## - a named map that does not match the file decodes nothing, and Messages says
##   once, for that file, that it does not apply (a second look says nothing more);
## - a named map that is not loaded: one warning naming it, nothing decoded, and the
##   choice is kept in the project; outside a project the command is refused.
##
## Seen to fail: with a load that says what the last did not kept quiet, "maps loaded said
## twice"; with the rule not published (`publishVendors` without the choice),
## "the chosen map did not decode"; with `sayMismatch` not remembering files, "said
## twice"; with the choice not written to the document, "the choice was not kept".
import std/[os, sequtils, strutils]
import parseSEG
import viewSEG/core/[projectnif, state, vendormaps]
import utils/[fixtures, waiting]

proc map(name, field: string; match = "(format segy)"): string =
  "(.nif27)\n(vendormap \"" & name & "\" (version 1) (match " & match & ")\n" &
    "  (target (kind binaryHeaderBytes) (name binaryInfo)\n" &
    "    (field " & field & " (at 21) (enc u16))))\n"

proc said(st: AppState; words: string): int =
  for e in st.log:
    if e.source == "vendor maps" and words in e.text: inc result

proc fieldNames(st: AppState): seq[string] =
  let v = st.inspection.answer.vendor
  if v.blocks.len == 1:
    for f in v.blocks[0].fields: result.add f.name

proc looking(st: var AppState; path: string; rule: string) =
  ## The File headers part on screen for `path`, answered under the rule `rule` says.
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len >= 1 and st.sessions[^1].path == path and
    st.panel(MainPanel).laidOut)
  st.apply Command(kind: ckInspect, inspect: {ipRecord})
  doAssert st.settle(st.inspection.answer.vendor.path == path and
    st.inspection.answer.vendor.gen == st.vendorGen and
    st.inspection.answer.vendor.rule == rule), "no answer under the rule"

proc main*() =
  withFixtures fx:
    let sgy = fx.oneTraceSegy()
    let maps = fx.dir / "maps"
    createDir(maps)
    writeFile(maps / "a.nif", map("map-a", "fromA"))
    writeFile(maps / "b.nif", map("map-b", "fromB"))
    writeFile(maps / "c.nif", map("map-c", "fromC", "(format segd) (manufacturer 99)"))
    let folders = @[VendorFolder(dir: maps, origin: voUser)]
    let job = fx.dir / "job"
    let config = fx.dir / "config"
    block automaticAndNamed:
      var st = initAppState()
      st.rememberFilesIn(config)
      st.setVendorFolders(folders)
      doAssert st.settle(st.vendorGen == 1)
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      doAssert st.vendorChoice.mode == vmAutomatic
      st.looking(sgy, "")
      doAssert st.fieldNames == @["fromA"], $st.fieldNames # equally specific: the first
      st.apply Command(kind: ckVendorMap, vendorMap: "map-b")
      st.looking(sgy, "The project's vendor map rule: only the map map-b is used.")
      doAssert st.fieldNames == @["fromB"], "the chosen map did not decode: " & $st.fieldNames
      doAssert st.project.doc.vendorChoice == VendorChoice(mode: vmNamed, name: "map-b"),
        "the choice was not kept"
      st.flushFiles()
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject and st.vendorChoice.mode == vmAutomatic)
      st.shutdown()
      let text = readFile(job / "project.nif")
      doAssert "map-b" in text, text
      var problems: seq[string]
      doAssert readProject(text, "project.nif", problems).vendorChoice ==
        VendorChoice(mode: vmNamed, name: "map-b")
      doAssert readProject(text.replace("(vendorMap \"map-b\")", ""), "project.nif",
        problems).vendorChoice.mode == vmAutomatic, "an old project is not Automatic"

    block reloadedWithTheProject:
      var st = initAppState()
      st.rememberFilesIn(config)
      st.setVendorFolders(folders)
      doAssert st.settle(st.vendorGen == 1) # (the start's own load, then the project's)
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject and st.projectOpening.len == 0 and
        st.vendorChoice == VendorChoice(mode: vmNamed, name: "map-b")),
        "the choice was not read back"
      # the start and the project's open found the same maps: one line, not two
      doAssert st.settle(st.vendorGen >= 2), "the project's load did not come"
      doAssert st.said("vendor header maps loaded") == 1, "maps loaded said twice"
      st.looking(sgy, "The project's vendor map rule: only the map map-b is used.")
      doAssert st.fieldNames == @["fromB"]
      # None
      st.apply Command(kind: ckVendorMap, vendorMap: "none")
      st.looking(sgy, "The project's vendor map rule: none; no vendor block is decoded.")
      doAssert st.fieldNames.len == 0 and st.inspection.answer.vendor.blocks.len == 0
      # a map that does not match the file: nothing, and said once for the file
      st.apply Command(kind: ckVendorMap, vendorMap: "map-c")
      st.looking(sgy, "The project's vendor map rule: only the map map-c is used.")
      doAssert st.inspection.answer.vendor.blocks.len == 0 and st.inspection.answer.vendor.mismatch
      doAssert st.settle(st.said("does not apply to one-trace.sgy") == 1),
        "not said once: " & $st.said("does not apply")
      let seen = st.inspection.answer.gen
      st.apply Command(kind: ckInspect, inspect: {})
      st.apply Command(kind: ckInspect, inspect: {ipRecord})
      doAssert st.settle(st.inspection.answer.gen > seen and
        st.inspection.answer.vendor.mismatch), "no second answer"
      doAssert st.said("does not apply to one-trace.sgy") == 1, "said twice"
      let loads = st.vendorGen
      st.apply Command(kind: ckReloadVendors) # a new load: the files are looked at again
      doAssert st.settle(st.vendorGen > loads)
      st.looking(sgy, "The project's vendor map rule: only the map map-c is used.")
      doAssert st.settle(st.said("does not apply to one-trace.sgy") == 2),
        "not said again for the new load"
      # a map that is not loaded: one warning naming it, nothing decoded, the choice kept
      st.apply Command(kind: ckVendorMap, vendorMap: "map-gone")
      st.looking(sgy, "The project's vendor map rule: only the map map-gone is used.")
      doAssert st.inspection.answer.vendor.blocks.len == 0
      doAssert st.said("map-gone is not among") == 1, $st.said("map-gone is not among")
      doAssert st.project.doc.vendorChoice == VendorChoice(mode: vmNamed, name: "map-gone")
      st.apply Command(kind: ckVendorMap, vendorMap: "automatic")
      st.looking(sgy, "")
      doAssert st.fieldNames == @["fromA"]
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      # outside a project: refused
      let before = st.vendorChoice
      st.apply Command(kind: ckVendorMap, vendorMap: "map-b")
      doAssert st.vendorChoice == before
      st.shutdown()

when isMainModule:
  main()
