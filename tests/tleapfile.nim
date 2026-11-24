## The leap-second table: a missing file leaves the shipped table and writes
## nothing; a saved file is read back; a broken file is named and not used;
## a file that omits or moves a shipped leap yields to the shipped table; a
## leap added to a SEG-D file's time shifts that time by about a second.
##
## Seen to fail: with `installLeap` returning before it reads, a saved file
## left `gpsMinusUtc` at 18 (`currentLeapTable().entries[^1].gpsMinusUtc == 19`);
## with `refreshKeys` left out of the re-read, `settle` never saw
## `keysRevision` move ("the keys were not read again"). With the earlier-date
## warning put back, an earlier file said "checked-to". With Apply leaving
## `checkedTo` as `withLeap` does, adding 2027-01-01 left it at 2026-06-30.

import std/[math, monotimes, os, strutils, times]
import parseSEG
import viewSEG/core/[leapfile, state]
import utils/[fixtures, waiting]

const
  July2026 = 1782864000'i64
  July2027 = 1814400000'i64

var holdCache: Gate

proc holdCacheHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  if phase == "saving the index cache" and not back:
    let deadline = getMonoTime() + initDuration(seconds = 120)
    while not isOpen(holdCache):
      if getMonoTime() > deadline: return
      sleep 1

proc caching(st: AppState): bool =
  for j in st.jobs.list:
    if j.progress.phase == "saving the index cache": return true

proc said(st: AppState; bit: string): bool =
  for e in st.log:
    if bit in e.text: return true

proc writeSegd(path: string; whenSec: float64; channelType = sctSeismic;
    status = tsLive) =
  var w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: 2000, numSamples: 4,
    time: whenSec))
  var k = initTraceKeys()
  k.record = 1
  k.channel = 1
  k.intervalUs = 2000
  k.t0Ms = 0
  k.status = status
  w.writeTrace(k, newSeq[float32](4), channelType = channelType)
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
        if "does not hold every leap second" in n.text: told = true
      doAssert told, "a shorter file was not refused: " & $notes
      useLeapTable(shipped)

    block moreButEarlier:
      var more = shipped.withLeap(LeapDate(year: 2027, month: 1, day: 1), 1)
      more.checkedTo = LeapDate(year: 2020, month: 1, day: 1)
      writeFile(path, leapTableNif(more))
      let notes = installLeap(dir)
      doAssert currentLeapTable().entries[^1].gpsMinusUtc == 19
      for n in notes:
        doAssert "does not hold every leap second" notin n.text,
          "a file that keeps every shipped leap was refused: " & n.text
      useLeapTable(shipped)

    block movedLeap:
      var moved = shipped
      moved.entries[^1].year = 2018
      moved.checkedTo = LeapDate(year: 2028, month: 1, day: 1)
      writeFile(path, leapTableNif(moved))
      let notes = installLeap(dir)
      doAssert currentLeapTable().entries[^1].year == 2017,
        "a file that moves a shipped leap was used"
      doAssert utcMinusGps(1498867200'i64 * 1_000_000) == -18,
        "2017-07-01 was not read with the shipped offset"
      var told = false
      for n in notes:
        if "does not hold every leap second" in n.text: told = true
      doAssert told, "a moved leap was not refused: " & $notes
      useLeapTable(shipped)

    block droppedLeap:
      var dropped = shipped
      dropped.entries.setLen(dropped.entries.len - 1)
      dropped = dropped.withLeap(LeapDate(year: 2027, month: 1, day: 1), 1)
      dropped = dropped.withLeap(LeapDate(year: 2028, month: 1, day: 1), 1)
      dropped.checkedTo = LeapDate(year: 2020, month: 1, day: 1)
      writeFile(path, leapTableNif(dropped))
      let notes = installLeap(dir)
      doAssert currentLeapTable().entries.len == shipped.entries.len,
        "a file that drops a shipped leap was used"
      var told = false
      for n in notes:
        if "does not hold every leap second" in n.text: told = true
      doAssert told, "a dropped leap was not refused: " & $notes
      useLeapTable(shipped)

    block earlierDate:
      var earlier = shipped
      earlier.checkedTo = LeapDate(year: 2020, month: 1, day: 1)
      writeFile(path, leapTableNif(earlier))
      let notes = installLeap(dir)
      doAssert currentLeapTable().checkedTo == earlier.checkedTo,
        "a file that keeps every shipped leap was not used"
      doAssert currentLeapTable().entries.len == shipped.entries.len
      for n in notes:
        doAssert "checked" notin n.text, "an earlier date was announced: " & n.text
        doAssert n.severity != sevWarning, "an earlier date warned: " & n.text
      var fewer = shipped
      fewer.entries.setLen(fewer.entries.len - 1)
      fewer.checkedTo = LeapDate(year: 2020, month: 1, day: 1)
      writeFile(path, leapTableNif(fewer))
      let fewerNotes = installLeap(dir)
      var toldFewer = false
      for n in fewerNotes:
        doAssert "checked" notin n.text, "an earlier date was announced: " & n.text
        if "does not hold every leap second" in n.text and n.severity == sevWarning:
          toldFewer = true
      doAssert toldFewer, "a shorter file was not refused: " & $fewerNotes
      useLeapTable(shipped)

    block reloadRefused:
      removeFile(path)
      var st = initAppState()
      st.keepSettingsIn(dir, LoadedSettings(saveable: true))
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      st.flushFiles()
      var fewer = shipped
      fewer.entries.setLen(fewer.entries.len - 1)
      let body = leapTableNif(fewer)
      writeFile(path, body)
      st.apply Command(kind: ckReloadLeaps)
      doAssert st.settle(said(st, "does not hold every leap second")),
        "a refused reload was not said"
      st.flushFiles()
      doAssert readFile(path) == body, "a refused file was written over"
      doAssert currentLeapTable().entries.len == shipped.entries.len,
        "a refused reload did not use the shipped table"
      useLeapTable(shipped)

    block commands:
      removeFile(path)
      var st = initAppState()
      st.keepSettingsIn(dir, LoadedSettings(saveable: true))
      st.apply Command(kind: ckAddLeap, leapYear: 2018, leapMonth: 1, leapStep: 1)
      doAssert currentLeapTable().entries[^1].year == 2018
      doAssert currentLeapTable().checkedTo == shipped.checkedTo,
        "a leap before the checked-to date moved it"
      st.apply Command(kind: ckResetLeaps)
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      doAssert said(st, "2027") and said(st, "19"), "the add was not logged"
      doAssert currentLeapTable().entries[^1].gpsMinusUtc == 19
      doAssert currentLeapTable().checkedTo == LeapDate(year: 2027, month: 1, day: 1),
        "Apply left the checked-to date at " & dateText(currentLeapTable().checkedTo)
      st.flushFiles()
      let parsed = parseLeapTable(readFile(path))
      doAssert parsed.problems.len == 0, $parsed.problems
      doAssert parsed.table.entries[^1].gpsMinusUtc == 19
      doAssert parsed.table.checkedTo == LeapDate(year: 2027, month: 1, day: 1)
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

    block openDuringLeap:
      useLeapTable(shipped)
      let segd = fx.dir / "open-during.sgd"
      writeSegd(segd, float64(July2027))
      var before = 0.0
      block:
        var probe = initAppState()
        probe.apply Command(kind: ckOpen, paths: @[segd])
        doAssert probe.settle(probe.sessions.len == 1), "the probe file did not open"
        before = probe.sessions[0].file.traceKeys(0).time
      holdCache.close()
      setJobHook(holdCacheHook)
      defer:
        holdCache.open()
        setJobHook(nil)
      createDir(fx.dir / "cache-open")
      var st = initAppState(indexCache = fx.dir / "cache-open")
      st.apply Command(kind: ckOpen, paths: @[segd])
      doAssert waitUntil(caching(st)), "the open did not reach the cache save"
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      holdCache.open()
      doAssert st.settle(st.sessions.len == 1), "the file opened during the leap did not post"
      let after = st.sessions[0].file.traceKeys(0).time
      doAssert abs(before - after - 1.0) < 0.001, "time moved by " & $(before - after) &
        " from " & $before & " to " & $after
      useLeapTable(shipped)

    block derived:
      useLeapTable(shipped)
      let segd = fx.dir / "derived.sgd"
      writeSegd(segd, float64(July2027))
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[segd])
      doAssert st.settle(st.sessions.len == 1), "the derived file did not open"
      st.sessions[0].asDerived()
      doAssert st.sessions[0].derived
      let before = st.sessions[0].file.traceKeys(0).time
      let rev = st.sessions[0].keysRevision
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      doAssert st.settle(st.sessions[0].keysRevision > rev), "a derived file was not read again"
      let after = st.sessions[0].file.traceKeys(0).time
      doAssert abs(before - after - 1.0) < 0.001, "derived time moved by " & $(before - after)
      useLeapTable(shipped)

    block auxOnly:
      useLeapTable(shipped)
      let segd = fx.dir / "aux.sgd"
      writeSegd(segd, float64(July2027), sctTimeBreak, tsAuxiliary)
      var st = initAppState()
      st.apply Command(kind: ckOpen, paths: @[segd])
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].noSeismic),
        "the aux-only file did not open as aux-only"
      let before = st.sessions[0].file.traceKeys(0).time
      let rev = st.sessions[0].keysRevision
      st.apply Command(kind: ckAddLeap, leapYear: 2027, leapMonth: 1, leapStep: 1)
      doAssert st.settle(st.sessions[0].keysRevision > rev), "an aux-only file was not read again"
      let after = st.sessions[0].file.traceKeys(0).time
      doAssert abs(before - after - 1.0) < 0.001, "aux time moved by " & $(before - after)
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
