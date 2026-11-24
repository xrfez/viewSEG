## Values one open file gives a name pattern (`core/outputnamevalues`).
## A kept trace that does not share a value is mixed; a blank header is
## missing; a signature file is named from its sweep, not from trace keys.
##
## Seen to fail: with only the first trace compared, shots.sgy's Record was
## one value (`Record is one value`); with the file's own keys ignored,
## Source point was the session station (`the session station was used`);
## with the sweep ignored, Controller was not an int 4321. With the clock
## ignored, shots.sgy record 1 was `20260301T000000000000Z` (`a whole-second
## clock kept a fraction`). With an auxiliary trace compared, source line NaN
## beside 2001 was mixed (`an auxiliary trace decided the source line`).
##
## The sensor serial: with two serials compared as equal, `two serials were
## one value`; with the part not asked for still read, `the headers were read
## for no part`. A vendor map's `sensorSerial` field is read: without it, `the vendor field was not
## read`. A trace with a Sensor Info serial and a vendor `sensorSerial` took the vendor one
## (`the vendor field beat the Sensor Info block`, made by trying the vendor field first); a
## record-level `sensorSerial` was used (`a record-level vendor field was used`, made by
## restoring the record fall-back); a field named `unitSerial` was used (`unitSerial was
## used`, made by looking for that name).
##
## Runs on samples/vib/vib_uncorrelated.sgd and samples/land/shots.sgy.

import std/[atomics, math, os, strutils]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[edits, outputnames, outputnamevalues, sigtypes, vendormaps]
import utils/[fixtures, sensorfiles, vendorfile]

const root = currentSourcePath().parentDir.parentDir

proc part(kind: NamePartKind; pad = 0): NamePart =
  NamePart(kind: kind, pad: pad)

proc shotPattern(): OutputPattern =
  OutputPattern(name: "Shot", separator: nsDot, parts: @[
    part(npSrcLine, 4), part(npSrcPoint, 4), part(npRecord, 4)])

proc main*() =
  let vib = root / "samples" / "vib" / "vib_uncorrelated.sgd"
  let segy = root / "samples" / "land" / "shots.sgy"
  doAssert fileExists(vib) and fileExists(segy), "the sample files are not here"

  block oneRecord:
    var f = openSeismic(vib, keys = true)
    let v = nameValuesOf(f, vib, SignatureFacts(), FileEdits(), false, nil)
    doAssert v[npStem].state == nvText and v[npStem].text == "vib_uncorrelated"
    doAssert v[npSrcLine].state == nvNumber and v[npSrcLine].number == 2001.0
    doAssert v[npSrcPoint].state == nvNumber and v[npSrcPoint].number == 103.0
    doAssert v[npRecord].state == nvNumber and v[npRecord].number == 1.0
    doAssert v[npSrcIndex].state == nvInt and v[npSrcIndex].intValue == 1
    doAssert v[npRcvPoint].state == nvMixed, "receiver points differ"
    doAssert v[npSystemSerial].state == nvInt and v[npSystemSerial].intValue == 0,
      "a serial of 0 is a value"
    doAssert v[npTime].state == nvTimeUs and not v[npTime].wholeSeconds
    let named = render(shotPattern(), v, ".sgy")
    doAssert named.problem.len == 0, named.problem
    doAssert named.name == "2001.0103.0001.sgy", named.name
    f.close()

  block twoShots:
    var f = openSeismic(segy, keys = true)
    let v = nameValuesOf(f, segy, SignatureFacts(), FileEdits(), false, nil)
    doAssert v[npRecord].state == nvMixed, "Record is one value"
    doAssert v[npSrcIndex].state == nvMissing, "SEG-Y index was written"
    doAssert v[npRcvIndex].state == nvMissing
    let named = render(OutputPattern(name: "Rec", separator: nsDot,
      parts: @[part(npRecord, 4)]), v, ".sgy")
    doAssert named.name.len == 0
    doAssert named.problem == "Record is not one value in this file.", named.problem
    f.close()

  block wholeSecondClock:
    var f = openSeismic(segy, keys = true)
    var edits = FileEdits()
    var drop = newSeq[int]()
    for t in 0 ..< f.len:
      if f.mindex.keys[t].record != 1.0: drop.add t
    discard edits.change(teKilled, drop, true)
    let v = nameValuesOf(f, segy, SignatureFacts(), edits, true, nil)
    doAssert v[npTime].state == nvTimeUs and v[npTime].wholeSeconds,
      "a whole-second clock kept a fraction"
    let named = render(OutputPattern(name: "Time", separator: nsDot,
      parts: @[part(npTime)]), v, ".sgy")
    doAssert named.problem.len == 0, named.problem
    doAssert named.name == "20260301T000000Z.sgy", named.name
    f.mindex.keys[0].noteRecordedTime(toHeaderSubsec, v[npTime].timeUs)
    let fraction = nameValuesOf(f, segy, SignatureFacts(), edits, true, nil)
    doAssert fraction[npTime].state == nvTimeUs and not fraction[npTime].wholeSeconds,
      "a microsecond clock was dropped"
    let shown = render(OutputPattern(name: "Time", separator: nsDot,
      parts: @[part(npTime)]), fraction, ".sgy")
    doAssert shown.name == "20260301T000000000000Z.sgy", shown.name
    f.close()

  block recordZero:
    var f = openSeismic(vib, keys = true)
    for t in 0 ..< f.len: f.mindex.keys[t].record = 0.0
    let v = nameValuesOf(f, vib, SignatureFacts(), FileEdits(), false, nil)
    doAssert v[npRecord].state == nvMissing, "record 0 was a value"
    f.mindex.keys[0].record = 2.0
    let mixed = nameValuesOf(f, vib, SignatureFacts(), FileEdits(), false, nil)
    doAssert mixed[npRecord].state == nvMixed, "record 0 beside 2 was one value"
    f.close()

  block killedTrace:
    var f = openSeismic(vib, keys = true)
    var edits = FileEdits()
    var drop = newSeq[int]()
    for t in 1 ..< f.len: drop.add t
    discard edits.change(teKilled, drop, true)
    let kept = nameValuesOf(f, vib, SignatureFacts(), edits, true, nil)
    doAssert kept[npRcvPoint].state == nvNumber and kept[npRcvPoint].number == 101.0,
      "a killed trace was compared"
    let all = nameValuesOf(f, vib, SignatureFacts(), edits, false, nil)
    doAssert all[npRcvPoint].state == nvMixed, "a kept kill was skipped"
    f.close()

  block auxiliarySkipped:
    var f = openSeismic(vib, keys = true)
    f.mindex.keys[48].srcLine = NaN
    f.mindex.keys[49].srcLine = 9999.0
    f.mindex.keys[48].record = 9.0
    f.mindex.keys[48].srcIndex = 9
    for t in 0 ..< f.len:
      if f.mindex.keys[t].status != tsAuxiliary:
        f.mindex.keys[t].noteRecordedTime(toHeaderSeconds, 1_772_366_400_000_000)
    let v = nameValuesOf(f, vib, SignatureFacts(), FileEdits(), false, nil)
    doAssert v[npSrcLine].state == nvNumber and v[npSrcLine].number == 2001.0,
      "an auxiliary trace decided the source line"
    let named = render(OutputPattern(name: "Line", separator: nsDot,
      parts: @[part(npSrcLine, 4)]), v, ".sgd")
    doAssert named.problem.len == 0, named.problem
    doAssert named.name == "2001.sgd", named.name
    doAssert v[npRecord].state == nvNumber and v[npRecord].number == 1.0,
      "an auxiliary trace decided the record"
    doAssert v[npSrcIndex].state == nvInt and v[npSrcIndex].intValue == 1,
      "an auxiliary trace decided the source index"
    doAssert v[npTime].wholeSeconds, "an auxiliary clock decided the time"
    for t in 0 ..< f.len: f.mindex.keys[t].status = tsAuxiliary
    let only = nameValuesOf(f, vib, SignatureFacts(), FileEdits(), false, nil)
    doAssert only[npSrcLine].state == nvMixed, "an auxiliary-only file skipped a trace"
    f.close()

  block ownPositions:
    var session = openSeismic(vib, keys = true)
    var own = openSeismic(vib, keys = false)
    for t in 0 ..< session.len: session.mindex.keys[t].srcPoint = 999.0
    let joined = nameValuesOf(session, vib, SignatureFacts(), FileEdits(), false, nil)
    doAssert joined[npSrcPoint].number == 999.0
    let kept = nameValuesOf(session, vib, SignatureFacts(), FileEdits(), false, addr own)
    doAssert kept[npSrcPoint].state == nvNumber and kept[npSrcPoint].number == 103.0,
      "the session station was used"
    doAssert kept[npRecord].number == 1.0, "own keys replaced the record"
    own.close()
    session.close()

  block signature:
    var closed: SeismicFile
    let dat = SignatureFacts(kind: sgDat, info: SweepInfo(kind: sgDat,
      serialFrom: sfFile, controller: 4321, vibrator: 0, fileNumber: 0,
      line: 0, station: 8, shotId: 0, sweepId: 3, sourceIndex: 0,
      triggerNs: 1_000_000_500))
    let v = nameValuesOf(closed, "/line/shot.dat", dat, FileEdits(), false, nil)
    doAssert v[npStem].text == "shot"
    doAssert v[npController].state == nvInt and v[npController].intValue == 4321
    doAssert v[npVibrator].state == nvMissing, "vibrator 0 was written"
    doAssert v[npFileNumber].state == nvInt and v[npFileNumber].intValue == 0
    doAssert v[npSigLine].state == nvMissing and v[npShotId].state == nvMissing
    doAssert v[npSigStation].intValue == 8 and v[npSweepId].intValue == 3
    doAssert v[npSrcIndex].state == nvMissing, "source index 0 was written"
    doAssert v[npTime].state == nvTimeUs and v[npTime].timeUs == 1_000_001 and
      not v[npTime].wholeSeconds
    doAssert v[npRecord].state == nvMissing, "a signature used trace keys"
    let unnamed = SignatureFacts(kind: sgDat, info: SweepInfo(kind: sgDat,
      serialFrom: sfNone, controller: 99, fileNumber: -1))
    let missing = nameValuesOf(closed, "a.dat", unnamed, FileEdits(), false, nil)
    doAssert missing[npController].state == nvMissing, "a controller with no source was written"
    doAssert missing[npFileNumber].state == nvMissing, "file number -1 was written"
    let paired = SignatureFacts(kind: sgVib, pair: "a.dat", pairTriggerNs: 2_500_000_000,
      info: SweepInfo(kind: sgVib, timeIsStart: true, triggerNs: 9_000_000_000,
        serialFrom: sfFolder, controller: 7))
    let pair = nameValuesOf(closed, "a.vib", paired, FileEdits(), false, nil)
    doAssert pair[npController].intValue == 7
    doAssert pair[npTime].timeUs == 2_500_000 and not pair[npTime].wholeSeconds,
      "the start second was used"
    let lone = SignatureFacts(kind: sgVib, info: SweepInfo(kind: sgVib,
      timeIsStart: true, triggerNs: 3_000_000_000, serialFrom: sfNone))
    let start = nameValuesOf(closed, "b.vib", lone, FileEdits(), false, nil)
    doAssert start[npTime].timeUs == 3_000_000 and start[npTime].wholeSeconds,
      "a lone start second kept a fraction"
    doAssert start[npController].state == nvMissing

  block sensorSerial:
    let dir = getTempDir() / "viewseg_tnamevalues_sensor"
    createDir(dir)
    let one = dir / "one.sgd"
    let two = dir / "two.sgd"
    let gap = dir / "gap.sgd"
    let none = dir / "none.sgd"
    writeSensorFile(one, ["N0042", "N0042"])
    writeSensorFile(two, ["N0042", "N0043"])
    writeSensorFile(gap, ["N0042", ""])
    writeSensorFile(none, ["", ""])
    let want = {npSensorSerial}
    proc valueOf(path: string; wanted: set[NamePartKind]): NameValue =
      var f = openSeismic(path, keys = true)
      result = nameValuesOf(f, path, SignatureFacts(), FileEdits(), false, nil,
        wanted)[npSensorSerial]
      f.close()
    let same = valueOf(one, want)
    doAssert same.state == nvText and same.text == "N0042", $same.state
    doAssert valueOf(two, want).state == nvMixed, "two serials were one value"
    doAssert valueOf(gap, want).state == nvMixed, "a trace without one was ignored"
    doAssert valueOf(none, want).state == nvMissing, "no block was a value"
    doAssert valueOf(one, {}).state == nvMissing, "the headers were read for no part"
    doAssert valueOf(one, {npRecord}).state == nvMissing
    # SEG-Y and a signature file have none.
    doAssert valueOf(segy, want).state == nvMissing
    var closed: SeismicFile
    let dat = SignatureFacts(kind: sgDat, info: SweepInfo(kind: sgDat, serialFrom: sfFile,
      controller: 1))
    doAssert nameValuesOf(closed, "a.dat", dat, FileEdits(), false, nil,
      want)[npSensorSerial].state == nvMissing
    removeDir(dir)

  block vendorSerial:
    # a made-up vendor block (type 0xB0, manufacturer 77) holds the serial; the map names
    # the field `sensorSerial`. The fixture's three traces hold 1234, "absent" and 0 there;
    # byte 32 of the block is its type, 176, on every trace.
    withFixtures fx:
      let mine = fx.vendorTraceSegd(77)
      let other = fx.vendorTraceSegd(78)
      let dir = fx.dir / "serialmaps"
      createDir(dir)
      writeFile(dir / "own.nif", """(.nif27)
(vendormap "vendor-s" (version 1) (match (format segd) (rev 3.0 3.1) (manufacturer 77))
  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)
    (field sensorSerial (at 32) (enc u8))))
""")
      writeFile(dir / "real.nif", """(.nif27)
(vendormap "vendor-r" (version 1) (match (format segd) (rev 3.0 3.1) (manufacturer 77))
  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)
    (field sensorSerial (at 3) (enc u32) (sentinel 0xFFFFFFFF))))
""")
      writeFile(dir / "record.nif", """(.nif27)
(vendormap "vendor-g" (version 1) (match (format segd) (rev 3.0 3.1) (manufacturer 77))
  (target (kind block) (type 0x11) (where generalHeader) (name recordInfo)
    (field sensorSerial (at 32) (enc u8))))
""")
      writeFile(dir / "unit.nif", """(.nif27)
(vendormap "vendor-u" (version 1) (match (format segd) (rev 3.0 3.1) (manufacturer 77))
  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)
    (field unitSerial (at 32) (enc u8))))
""")
      proc serialWith(path, map: string): NameValue =
        let load = loadVendorFolders([VendorFolder(dir: dir, origin: voProgram)])
        var reg: VendorRegistry
        for m in load.registry.maps:
          if m.name == map: reg.addMap m
        var f = openSeismic(path, keys = true)
        result = nameValuesOf(f, path, SignatureFacts(), FileEdits(), false, nil,
          {npSensorSerial}, reg)[npSensorSerial]
        f.close()
      let found = serialWith(mine, "vendor-s")
      doAssert found.state == nvText and found.text == "176", "the vendor field was not read"
      doAssert serialWith(mine, "vendor-r").state == nvMixed,
        "traces with different vendor serials were one value"
      doAssert serialWith(other, "vendor-s").state == nvMissing,
        "another manufacturer's file had a serial"
      # a serial of the record's own vendor blocks is not a trace's serial
      doAssert serialWith(mine, "vendor-g").state == nvMissing,
        "a record-level vendor field was used"
      doAssert serialWith(mine, "vendor-u").state == nvMissing, "unitSerial was used"
      doAssert serialWith(mine, "no-such-map").state == nvMissing, "no map, a serial"

  block sensorInfoBeatsVendor:
    # a trace with a Sensor Info serial N0042 and a vendor block holding 9: the standard
    # block is the one used; the same file without the Sensor Info block gives the vendor one
    let dir = getTempDir() / "viewseg_tnamevalues_sensorvendor"
    createDir(dir)
    let both = dir / "both.sgd"
    let vendorOnly = dir / "vendoronly.sgd"
    writeSensorFile(both, ["N0042"], 9)
    writeSensorFile(vendorOnly, [""], 9)
    writeFile(dir / "v.nif", """(.nif27)
(vendormap "vendor-b" (version 1) (match (format segd) (rev 3.0 3.1))
  (target (kind block) (type 0xB0) (where traceHeader) (name vendorStatus)
    (field sensorSerial (at 3) (enc u32))))
""")
    let load = loadVendorFolders([VendorFolder(dir: dir, origin: voProgram)])
    doAssert load.registry.maps.len == 1, load.foldersText
    proc valueOf(path: string): NameValue =
      var f = openSeismic(path, keys = true)
      result = nameValuesOf(f, path, SignatureFacts(), FileEdits(), false, nil,
        {npSensorSerial}, load.registry)[npSensorSerial]
      f.close()
    let first = valueOf(both)
    doAssert first.state == nvText and first.text == "N0042",
      "the vendor field beat the Sensor Info block"
    let second = valueOf(vendorOnly)
    doAssert second.state == nvText and second.text == "9", "the vendor serial was not read"
    removeDir(dir)

  block vendorFields:
    ## Seen to fail (broken, then restored): with a field that differs among traces not
    ## counted as mixed, `batch` of two records was one value (`records 40 and 41 were one
    ## value`); with the column counted for an empty list, `a column was read for no field`.
    const map = """(.nif27)
(vendormap "names-test" (version 1) (match (format segd) (rev 2.0 2.0) (manufacturer 77))
  (target (kind traceExt) (extension 2) (name unitInfo)
    (field counter (at 1) (enc u32))
    (field status (at 5) (enc u16) (sentinel 0xFFFF))
    (field label (at 9) (len 4) (enc ascii) (trim right))
    (field fixed (at 9) (len 2) (enc ascii) (trim right))
    (field never (at 9) (enc u8) (sentinel 0x41)))
  (target (kind extendedHeader) (blockIndex 1) (name session)
    (field batch (at 3) (enc u8))
    (field half (at 3) (enc u8) (scale 0.5))))"""
    var reg: VendorRegistry
    reg.addMap loadVendorMap(map)
    let dir = getTempDir() / "viewseg_tnamevalues_vendor"
    createDir(dir)
    let first = dir / "first.sgd"
    let second = dir / "second.sgd"
    let both = dir / "both.sgd"
    writeRecords(first, [0])
    writeRecords(second, [1])
    writeLines(both)
    proc valuesOf(path: string; fields: openArray[string]; r = reg;
        facts = SignatureFacts()): seq[VendorFieldValue] =
      var f = openSeismic(path, keys = true)
      result = vendorValuesOf(f, facts, FileEdits(), false, fields, r)
      f.close()
    let one = valuesOf(first, ["batch", "fixed", "half"])
    doAssert one.len == 3 and one[0].name == "batch"
    doAssert one[0].value.state == nvInt and one[0].value.intValue == 40, $one[0].value
    doAssert one[1].value.state == nvText and one[1].value.text == "AB", $one[1].value
    doAssert one[2].value.state == nvNumber and one[2].value.number == 20.0, $one[2].value
    let next = valuesOf(second, ["batch", "half"])
    doAssert next[0].value.intValue == 41 and next[1].value.number == 20.5
    doAssert vendorText(next[1].value) == "20.5" and vendorText(next[0].value) == "41"
    # two records disagree: mixed, with the lowest and the highest of a number
    let mixed = valuesOf(both, ["batch", "label", "counter"])
    doAssert mixed[0].value.state == nvMixed, "records 40 and 41 were one value"
    doAssert mixed[0].first.intValue == 40 and mixed[0].last.intValue == 41
    doAssert mixed[1].value.state == nvMixed and mixed[1].first.state == nvMissing,
      "a text has no range"
    doAssert mixed[2].value.state == nvMixed and mixed[2].first.intValue == 0 and
      mixed[2].last.intValue == 1002
    # a trace without the value (the sentinel) among others that have it
    let partial = valuesOf(first, ["status"])
    doAssert partial[0].value.state == nvMixed, "an absent trace was ignored"
    doAssert partial[0].first.intValue == 0 and partial[0].last.intValue == 2
    # absent from every trace, unknown, ambiguous, no maps
    doAssert valuesOf(first, ["never"])[0].value.state == nvMissing
    doAssert valuesOf(first, ["nope"])[0].value.state == nvMissing
    doAssert valuesOf(first, ["batch"], VendorRegistry())[0].value.state == nvMissing
    # a name given twice, and a field the file lacks, are each answered by name
    let pair = valuesOf(first, ["nope", "batch"])
    doAssert pair[0].name == "nope" and pair[0].value.state == nvMissing
    doAssert pair[1].name == "batch" and pair[1].value.intValue == 40
    # no field asked for: no column read, no value
    let reads = vendorColumnReads.load
    doAssert valuesOf(first, []).len == 0
    doAssert vendorColumnReads.load == reads, "a column was read for no field"
    discard valuesOf(first, ["batch"])
    doAssert vendorColumnReads.load > reads, "the counter does not count"
    # a killed trace is skipped when asked
    var f = openSeismic(first, keys = true)
    var edits = FileEdits()
    discard edits.change(teKilled, [0, 2], true)
    doAssert vendorValuesOf(f, SignatureFacts(), edits, true, ["status"], reg)[0].value.state ==
      nvMissing, "a killed trace was read"
    doAssert vendorValuesOf(f, SignatureFacts(), edits, false, ["status"], reg)[0].value.state ==
      nvMixed
    f.close()
    # a signature file has none
    let sig = SignatureFacts(kind: sgDat, info: SweepInfo(kind: sgDat))
    doAssert valuesOf(first, ["batch"], reg, sig)[0].value.state == nvMissing
    removeDir(dir)

  echo "toutputnamevalues: ok"

when isMainModule:
  main()
