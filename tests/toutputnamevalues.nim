## Values one open file gives a name pattern (`core/outputnamevalues`).
## A kept trace that does not share a value is mixed; a blank header is
## missing; a signature file is named from its sweep, not from trace keys.
##
## Seen to fail: with only the first trace compared, shots.sgy's Record was
## one value (`Record is one value`); with the file's own keys ignored,
## Source point was the session station (`the session station was used`);
## with the sweep ignored, Controller was not an int 4321. With the clock
## ignored, shots.sgy record 1 was `20260301T000000000000Z` (`a whole-second
## clock kept a fraction`).
##
## Runs on samples/vib/vib_uncorrelated.sgd and samples/land/shots.sgy.

import std/[os, strutils]
import parseSEG
import parseSEG/model/traceindex
import viewSEG/core/[edits, outputnames, outputnamevalues, sigtypes]

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

  echo "toutputnamevalues: ok"

when isMainModule:
  main()
