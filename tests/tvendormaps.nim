## Vendor header maps (`core/vendormaps`, docs/user/vendor-maps.md), without a
## window, on a SEG-Y file written by the fixtures and maps made here:
##
## - the folders are loaded in order of preference: of two maps of one name the
##   project's is kept (the program's is said to be left out), the others of
##   every folder load, and a broken map is one problem naming its file and
##   parseSEG's reason without stopping the rest;
## - what a map decodes of a file's binary header reaches the Headers window's
##   reader (`ckInspect` with the record headers on screen): the fields by
##   name with their values, and the map that decoded them; a file no map
##   applies to shows none;
## - the program loads them off the UI thread when the folders are given, says
##   one line how many from where, one line per map that failed, and the
##   absence of any map once and as information; opening a project (its own
##   `vendormaps` folder first) and Reload vendor maps load again, and the file
##   already open shows the new decode;
## - a project made by New project holds a `vendormaps` folder with its note and
##   the guide, which a second open does not replace; an older project gets
##   them when opened writable, a read-only one is left alone; the folder
##   beside the program is made when its folder is writable and a read-only
##   one is no failure.
##
## Seen to fail: with the earlier folder's map of a name no longer winning (the
## `seen` check in `loadVendorFolders` removed), "the program's map was taken
## over the project's"; with `reloadVendorMaps` not called after a project
## opens, "the project's map was not loaded"; with `vendorGen` left out of the
## request in `followInspect`, "the open file did not show the new decode";
## with `prepareVendorFolder` run for a project that is read-only, "a read-only
## project was given a folder"; with `makeProject` not writing the notes, "no
## note in a new project"; with the shipped map's record serial read as 8 bits instead of 12, "12-bit record
## serial".
import std/[os, sequtils, strutils]
import parseSEG
import viewSEG/core/[filesystem, state, vendormaps]
import viewSEG/platform/paths
import utils/[fixtures, waiting]

const
  Intervals = 17   ## byte of the binary header holding the sample interval (1-based)
  SampleCount = 21 ## and the samples per trace

proc map(name, interval: string; match = "(format segy)"; extra = ""): string =
  ## A map of the SEG-Y binary header with the field of the sample interval
  ## named `interval`, applying to the files `match` says.
  "(.nif27)\n(vendormap \"" & name & "\" (version 1) (match " & match & ")\n" &
    "  (doc \"a map for the test\")\n" &
    "  (target (kind binaryHeaderBytes) (name binaryInfo)\n    (field " & interval & " (at " &
    $Intervals & ") (enc u16) (unit \"us\"))\n    (field samples (at " & $SampleCount &
    ") (enc u16))" & extra & "))\n"

proc put(dir, name, text: string) =
  createDir(dir)
  writeFile(dir / name, text)

proc said(st: AppState; words: string): bool =
  for e in st.log:
    if words in e.text: return true

proc lines(st: AppState): seq[string] =
  for e in st.log:
    if e.source == "vendor maps": result.add e.text

proc fieldOf(b: VendorBlockFact; name: string): string =
  for f in b.fields:
    if f.name == name: return f.value

proc shows(st: AppState; field: string): bool =
  ## The Headers window's reader answered with `field` decoded, for this load of the maps.
  let v = st.inspection.answer.vendor
  v.blocks.len == 1 and v.gen == st.vendorGen and v.blocks[0].fieldOf(field).len > 0

proc main*() =
  withFixtures fx:
    let sgy = fx.oneTraceSegy()
    let project = fx.dir / "p" / "vendormaps"
    let user = fx.dir / "u"
    let program = fx.dir / "program" / "vendormaps"
    let folders = @[VendorFolder(dir: project, origin: voProject),
      VendorFolder(dir: user, origin: voUser), VendorFolder(dir: program, origin: voProgram),
      VendorFolder(dir: fx.dir / "nowhere", origin: voEnvironment)]
    project.put "same.nif", map("same-name", "fromProject")
    program.put "same.nif", map("same-name", "fromProgram")
    program.put "other.nif", map("other", "otherInterval", "(format segd)")
    program.put "broken.nif", "(.nif27)\n(vendormap \"a\" (target (kind block)))\n("
    user.put "notes.txt", "not a map"

    block loadedInOrderOfPreference:
      let load = loadVendorFolders(folders)
      doAssert load.maps.len == 2, $load.maps
      doAssert load.maps[0].name == "same-name" and load.maps[0].origin == voProject, $load.maps
      doAssert load.maps[1].name == "other" and load.maps[1].origin == voProgram
      doAssert load.registry.maps.len == 2 and load.registry.maps[0].source == project / "same.nif",
        "the program's map was taken over the project's"
      doAssert load.shadowed.len == 1 and "same-name" in load.shadowed[0], $load.shadowed
      doAssert load.problems.len == 1 and load.problems[0].file == program / "broken.nif" and
        not load.problems[0].loaded and load.problems[0].text.len > 0, $load.problems
      doAssert load.summaryLine == "2 vendor header maps loaded: 1 from the project, 1 beside " &
        "the program", load.summaryLine
      doAssert [load.folders[0].loaded, load.folders[1].loaded, load.folders[2].loaded] ==
        [1, 0, 1] and load.folders[1].there and not load.folders[3].there
      doAssert "broken.nif was not loaded" in load.problems[0].problemLine
      doAssert "any file" notin load.maps[0].appliesTo and "SEG-Y" in load.maps[0].appliesTo and
        "binaryInfo" in load.maps[0].appliesTo, load.maps[0].appliesTo

    block decodedByName:
      let load = loadVendorFolders(folders)
      var f = openSeismic(sgy)
      let shown = vendorBlocks(f, -1, load.registry, 3)
      f.close()
      doAssert shown.gen == 3 and shown.blocks.len == 1, $shown.blocks.len
      let b = shown.blocks[0]
      doAssert b.name == "binaryInfo" and b.map == "same-name" and
        b.mapFile == project / "same.nif", b.map
      doAssert b.fieldOf("fromProject") == $int(DtMs * 1000) and
        b.fieldOf("samples") == $LongSamples, $b.fields
      doAssert b.fields[0].unit == "us"
      doAssert b.fieldOf("fromProgram").len == 0, "the program's map decoded it"
      var g = openSeismic(sgy)
      doAssert vendorBlocks(g, -1, VendorRegistry(), 0).blocks.len == 0, "no map, no block"
      g.close()

    block theProgramLoadsReloadsAndSays:
      var st = initAppState()
      st.setVendorFolders(folders[1 .. ^1]) # no project: the user's, the program's
      doAssert st.settle(st.vendorGen == 1), "the maps were not loaded"
      doAssert st.vendorLoad.maps.len == 2 and st.vendorLoad.maps[1].name == "same-name"
      doAssert st.vendorLoad.maps[1].origin == voProgram # (the files of a folder by name)
      doAssert st.lines.len == 2, $st.lines # the count, the broken map
      doAssert st.lines[0] == "2 vendor header maps loaded: 2 beside the program.", $st.lines
      doAssert "broken.nif was not loaded" in st.lines[1], $st.lines
      doAssert st.log.count(sevWarning) == 1, "only the broken map is a warning"
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: sgy)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckInspect, inspect: {ipRecord})
      doAssert st.settle(st.shows("fromProgram")), "the file's vendor block was not decoded"
      let answer = st.inspection.answer.vendor
      doAssert answer.path == sgy and answer.blocks[0].map == "same-name"
      # a map dropped in while the program runs, read by Reload vendor maps
      program.put "late.nif", map("late", "lateInterval", "(format segy) (rev 0.0 9.9)")
      st.apply Command(kind: ckReloadVendors)
      doAssert st.settle(st.vendorGen == 2 and st.vendorLoad.maps.len == 3),
        "the new map was not picked up"
      doAssert st.lines.anyIt(it.startsWith("3 vendor header maps loaded")), $st.lines
      doAssert st.settle(st.shows("lateInterval")), "the open file did not show the new decode"
      # (the map that says more of the file it is for decodes, whatever its folder's place)
      doAssert st.inspection.answer.vendor.blocks[0].map == "late"
      removeFile(program / "late.nif")
      st.shutdown()

    block aProjectsMapsComeFirst:
      var st = initAppState()
      st.setVendorFolders(folders[1 .. ^1])
      doAssert st.settle(st.vendorGen == 1)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: sgy)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)
      st.apply Command(kind: ckInspect, inspect: {ipRecord})
      doAssert st.settle(st.shows("fromProgram"))
      let job = fx.dir / "q"
      let own = job / "vendormaps"
      let made = st.vendorGen
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0), "the project was not made"
      doAssert st.settle(st.vendorGen > made), "no load after the project opened"
      # its note and guide came with the folder, and stay as the user left them
      doAssert fileExists(own / VendorReadmeName) and fileExists(own / VendorGuideName),
        "no note in a new project"
      doAssert readFile(own / VendorGuideName) == VendorGuide
      own.put "same.nif", map("same-name", "fromProject")
      st.apply Command(kind: ckReloadVendors)
      doAssert st.settle(st.vendorLoad.maps.len == 2 and st.vendorLoad.maps[0].origin == voProject),
        "the project's map was not loaded"
      doAssert st.vendorLoad.maps[0].file == own / "same.nif"
      doAssert st.settle(st.shows("fromProject")), "the project's map did not decode the file"
      doAssert st.lines.anyIt(it.startsWith("2 vendor header maps loaded: 1 from the project, " &
        "1 beside the program")), $st.lines
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject and st.vendorLoad.maps.len == 2 and
        st.vendorLoad.maps[0].origin != voProject), "closing the project left its maps in force"
      writeFile(own / VendorReadmeName, "mine")
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      doAssert st.settle(st.vendorLoad.maps[0].origin == voProject),
        "the project's map was not loaded when it opened"
      doAssert readFile(own / VendorReadmeName) == "mine", "a note was written over"
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      st.shutdown()

    block anOlderProjectGetsTheFolderAndAReadOnlyOneDoesNot:
      let job = fx.dir / "older"
      var st = initAppState()
      st.apply Command(kind: ckNewProject, projectPath: job, dataFolders: @[])
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      removeDir(job / "vendormaps")
      var other = initAppState()
      var second = initAppState()
      st.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert st.settle(st.inProject and st.projectOpening.len == 0)
      doAssert fileExists(job / "vendormaps" / VendorReadmeName) and
        fileExists(job / "vendormaps" / VendorGuideName), "an older project was not given them"
      removeDir(job / "vendormaps")
      second.apply Command(kind: ckOpenProject, projectPath: job)
      doAssert second.settle(second.inProject and second.projectOpening.len == 0)
      doAssert second.project.readOnly, "the second program has it open too"
      doAssert not dirExists(job / "vendormaps"), "a read-only project was given a folder"
      second.apply Command(kind: ckCloseProject)
      st.apply Command(kind: ckCloseProject)
      doAssert st.settle(not st.inProject)
      second.shutdown()
      other.shutdown()
      st.shutdown()

    block noMapIsSaidOnceAndQuietly:
      var st = initAppState()
      st.setVendorFolders(@[VendorFolder(dir: fx.dir / "empty", origin: voProgram)])
      doAssert st.settle(st.vendorGen == 1)
      st.apply Command(kind: ckReloadVendors)
      doAssert st.settle(st.vendorGen == 2)
      var said = 0
      for e in st.log:
        if e.source == "vendor maps":
          inc said
          doAssert e.severity == sevInfo, e.text
          doAssert "No vendor header maps found" in e.text
      doAssert said == 1, "said " & $said & " times"
      st.shutdown()

    block everyMapOfTheRepositoryLoadsClean:
      # the maps that ship in the release's vendormaps folder: loaded, and nothing found wrong
      let repo = currentSourcePath().parentDir.parentDir / "vendormaps"
      let load = loadVendorFolders([VendorFolder(dir: repo, origin: voProgram)])
      doAssert load.maps.len >= 1, "no map ships"
      doAssert load.problems.len == 0, $load.problems
      for m in load.registry.maps: doAssert m.checkVendorMap.len == 0, m.name

    block shippedMapFindsModulesByTheirBytes:
      # the code-9 map in the repository, on a generated Rev 2.0 record whose extended header holds a
      # made-up module first and the modules it knows after it: found by their bytes, not by position
      let repo = currentSourcePath().parentDir.parentDir / "vendormaps"
      let load = loadVendorFolders([VendorFolder(dir: repo, origin: voProgram)])
      proc module(head: openArray[int]): seq[byte] =
        result = newSeq[byte](32)
        for i, v in head: result[i] = byte(v)
      var made = module([9, 0, 0, 9, 1, 1, 0, 1]) # content type 9: not a module of the map
      var acq = module([9, 0, 0, 1, 1, 1, 0, 1])
      acq[12] = 0x12; acq[13] = 0x34; acq[14] = 0x56; acq[15] = 0x78 # shot serial 0x12345678
      acq[17] = 0xAB; acq[18] = 0xC4 # record serial 0xABC, trigger method 4
      acq[29] = 3 # trace extension version
      var rec = SegdRecord(layout: slRev2)
      rec.revision = SegdRevision(major: 2, minor: 0)
      rec.gh1.manufacturerCode = 9
      rec.extended = made & acq
      var log: DiagLog
      let blocks = load.registry.decodeVendorAreas(rec, log, "generated")
      var found = ""
      for b in blocks:
        if b.name == "acqDetail":
          doAssert b.blockNumber == 2, "the module was not found at its own place"
          doAssert b["shotSerialNumberId"].intVal == 0x12345678, "shot serial"
          doAssert b["recordSerialNumberId"].intVal == 0xABC, "12-bit record serial"
          doAssert b["triggerMethod"].label == "Hi-resolution Time", "trigger label"
          found = b.name
      doAssert found == "acqDetail", "the module was not decoded"
      doAssert blocks.len == 3 and log.len == 0, "headers of both modules and the contents of one"
      # without the module the map does not apply: nothing decoded, nothing logged
      rec.extended = made
      doAssert load.registry.decodeVendorAreas(rec, log, "generated").len == 0 and log.len == 0

    block oneNoteNotTwo:
      let beside = fx.dir / "note"
      createDir(beside)
      writeFile(beside / "README.md", "already")
      doAssert prepareVendorDir(beside, VendorNotes)
      doAssert not fileExists(beside / VendorReadmeName), "a README.txt beside a README.md"
      doAssert fileExists(beside / VendorGuideName)

    block aProgramFolderThatCannotBeWrittenIsNoFailure:
      let beside = fx.dir / "bin"
      createDir(beside)
      doAssert prepareVendorDir(beside / "vendormaps", VendorNotes)
      doAssert readFile(beside / "vendormaps" / VendorGuideName) == VendorGuide
      writeFile(beside / "vendormaps" / VendorReadmeName, "kept")
      doAssert prepareVendorDir(beside / "vendormaps", VendorNotes)
      doAssert readFile(beside / "vendormaps" / VendorReadmeName) == "kept"
      let locked = fx.dir / "locked"
      createDir(locked)
      setFilePermissions(locked, {fpUserRead, fpUserExec})
      try:
        var canWrite = false # a user who may write there anyway (root): nothing to see
        try:
          writeFile(locked / "probe", "")
          removeFile(locked / "probe")
          canWrite = true
        except IOError, OSError: discard
        if not canWrite:
          doAssert not prepareVendorDir(locked / "vendormaps", VendorNotes)
      finally:
        setFilePermissions(locked, {fpUserRead, fpUserWrite, fpUserExec})

when isMainModule:
  main()
