## The leap-second table: a missing file leaves the shipped table and writes
## nothing; a saved file is read back; a broken file is named and not used;
## an older file yields to the shipped table unless it has more entries; a
## leap added to a SEG-D file's time shifts that time by about a second.
##
## Seen to fail: with `installLeap` returning before it reads, a saved file
## left `gpsMinusUtc` at 18 (`currentLeapTable().entries[^1].gpsMinusUtc == 19`);
## with `refreshKeys` left out of the re-read, `settle` never saw
## `keysRevision` move ("the keys were not read again").

import std/[math, os, strutils]
import parseSEG
import viewSEG/core/[leapfile, state]
import utils/[fixtures, waiting]

const
  July2026 = 1782864000'i64
  July2027 = 1814400000'i64

proc said(st: AppState; bit: string): bool =
  for e in st.log:
    if bit in e.text: return true

proc writeSegd(path: string; whenSec: float64) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4,
    time: whenSec))
  var k = initTraceKeys()
  k.record = 1
  k.channel = 1
  k.intervalUs = 2000
  k.t0Ms = 0
  k.status = tsLive
  w.writeTrace(k, newSeq[float32](4))
  doAssert w.close().len == 0, "the SEG-D file was not written"

proc main*() =
  let shipped = defaultLeapTable()
  defer: useLeapTable(shipped)

  block offsets:
    useLeapTable(shipped)
    doAssert utcMinusGps(July2026 * 1_000_000) == -18
    let next = shipped.withLeap(LeapDate(year: 2027, month: 1, day: 1), 1)
    doAssert next.entries[^1].gpsMinusUtc == 19
    doAssert next.checkedTo == shipped.checkedTo
    useLeapTable(next)
    doAssert utcMinusGps(July2026 * 1_000_000) == -18
    doAssert utcMinusGps(July2027 * 1_000_000) == -19
    useLeapTable(shipped)

  withFixtures fx:
    let dir = fx.dir / "config"
    createDir(dir)
    let path = dir / LeapFileName

    block absent:
      let extra = shipped.withLeap(LeapDate(year: 2027, month: 1, day: 1), 1)
      useLeapTable(extra)
      let notes = installLeap(dir)
      doAssert notes.len == 0, "a missing file said " & $notes
      doAssert currentLeapTable().entries.len == extra.entries.len
      doAssert not fileExists(path), "a missing file was written"
      useLeapTable(shipped)

    block saved:
      let next = shipped.withLeap(LeapDate(year: 2027, month: 1, day: 1), 1)
      writeFile(path, leapTableNif(next))
      let notes = installLeap(dir)
      doAssert notes.len == 0, "a clean file said " & $notes
      doAssert currentLeapTable().entries[^1].gpsMinusUtc == 19
      doAssert currentLeapTable().checkedTo == shipped.checkedTo
      useLeapTable(shipped)

    block broken:
      writeFile(path, "not a leap table")
      let notes = installLeap(dir)
      doAssert currentLeapTable().entries.len == shipped.entries.len
      var named = false
      for n in notes:
        if path in n.text and n.severity == sevWarning: named = true
      doAssert named, "the broken file was not named: " & $notes
      useLeapTable(shipped)

    block older:
      var fewer = shipped
      fewer.entries.setLen(fewer.entries.len - 1)
      writeFile(path, leapTableNif(fewer))
      let notes = installLeap(dir)
      doAssert currentLeapTable().entries.len == shipped.entries.len
      var told = false
      for n in notes:
        if "fewer" in n.text: told = true
      doAssert told, "an older file was not said to have fewer entries: " & $notes
      useLeapTable(shipped)

    block moreButEarlier:
      var more = shipped.withLeap(LeapDate(year: 2027, month: 1, day: 1), 1)
      more.checkedTo = LeapDate(year: 2020, month: 1, day: 1)
      writeFile(path, leapTableNif(more))
      let notes = installLeap(dir)
      doAssert currentLeapTable().entries[^1].gpsMinusUtc == 19
      var told = false
      for n in notes:
        if "more" in n.text: told = true
      doAssert told, "a longer older file was not said to be used: " & $notes
      useLeapTable(shipped)

    block commands:
      removeFile(path)
      var st = initAppState()
      st.keepSettingsIn(dir, LoadedSettings(saveable: true))
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      doAssert said(st, "2027") and said(st, "19"), "the add was not logged"
      doAssert currentLeapTable().entries[^1].gpsMinusUtc == 19
      doAssert currentLeapTable().checkedTo == shipped.checkedTo
      st.flushFiles()
      let parsed = parseLeapTable(readFile(path))
      doAssert parsed.problems.len == 0, $parsed.problems
      doAssert parsed.table.entries[^1].gpsMinusUtc == 19
      doAssert parsed.table.checkedTo == shipped.checkedTo
      st.apply Command(kind: ckRemoveLeap)
      doAssert currentLeapTable().entries.len == shipped.entries.len
      doAssert said(st, "Removed")
      st.apply Command(kind: ckRemoveLeap)
      doAssert said(st, "ships with")
      doAssert currentLeapTable().entries.len == shipped.entries.len
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      st.apply Command(kind: ckResetLeaps)
      doAssert currentLeapTable().entries.len == shipped.entries.len
      doAssert said(st, "shipped with the program")
      useLeapTable(shipped)

    block shift:
      useLeapTable(shipped)
      let segd = fx.dir / "july2027.sgd"
      writeSegd(segd, float64(July2027))
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[segd])
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].len == 1),
        "the SEG-D file did not open"
      let before = st.sessions[0].file.traceKeys(0).time
      let rev = st.sessions[0].keysRevision
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      doAssert st.settle(st.sessions[0].keysRevision > rev),
        "the keys were not read again"
      let after = st.sessions[0].file.traceKeys(0).time
      doAssert abs(before - after - 1.0) < 0.001, "time moved by " & $(before - after) &
        " from " & $before & " to " & $after
      useLeapTable(shipped)

when isMainModule:
  main()
