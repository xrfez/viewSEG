## What a loaded shot log follows: the trace under the pointer, the selected
## signature, or the selected open file, by time zero.
##
## Seen to fail: with followAnswer always returning sfNone, pointer_matches_row
## got source none. With the query built from keys.time instead of
## recordTimeZeroUs, delay_matches_time_zero matched row 0.

import std/[math, options, os, strutils, times]
import parseSEG
import parseSEG/io/memsink
import viewSEG/core/[shotlog, state]
import utils/[fixtures, sigfiles, waiting]

const Land = currentSourcePath().parentDir.parentDir / "samples" / "land" / "shots.sgd"

proc allocations(): int =
  cast[tuple[allocs, deallocs: int]](getAllocStats()).allocs

proc writeLog(dir, name: string; rows: openArray[string]): string =
  createDir(dir)
  result = dir / name
  var text = "UTC microseconds,file number,source line,shot point\n"
  for r in rows: text.add r & "\n"
  writeFile(result, text)

proc usText(us: int64): string = $us

proc row(us: int64; fileNo: int; line, point: float64): string =
  usText(us) & "," & $fileNo & "," & formatFloat(line, ffDecimal, 2) & "," &
    formatFloat(point, ffDecimal, 2)

proc openLand(st: var AppState) =
  doAssert fileExists(Land), "samples/land/shots.sgd is not there"
  st.apply Command(kind: ckOpen, paths: @[Land])
  doAssert st.settle(st.sessions.len >= 1 and st.jobs.active.len == 0), "the file did not open"

proc importLog(st: var AppState; path: string; n: int) =
  st.apply Command(kind: ckImportShotLog, logPath: path)
  doAssert st.settle(st.shotLogCount == n and st.jobs.active.len == 0), "the log did not load"

proc timeZeroOf(st: AppState; local: int): int64 =
  let t = st.sessions[0].file.recordTimeZeroUs(local)
  doAssert t.isSome, "trace " & $local & " has no time zero"
  t.get

proc laterTrace(st: AppState): int =
  ## A trace whose time zero is not the first trace's.
  let first = timeZeroOf(st, 0)
  for local in 1 ..< st.sessions[0].len:
    let t = st.sessions[0].file.recordTimeZeroUs(local)
    if t.isSome and t.get != first: return local
  doAssert false, "every trace has the first time zero"
  0

proc writeBytes(path: string; b: seq[byte]) =
  var text = newString(b.len)
  for i, x in b: text[i] = char(x)
  writeFile(path, text)

proc delaySegd(): seq[byte] =
  ## Rev 3: GH#3 is T, the Timestamp block is T + 100 ms, so keys.time is
  ## sample 0 and recordTimeZeroUs is T.
  const T = 1_700_000_020_125_000'i64
  const Delay = 100_000'i32
  let gh3 = utcUsToGpsUs(T)
  let stamp = utcUsToGpsUs(T + int64(Delay))
  var r = SegdRecord(layout: slRev3, format: some(sd8058),
    revision: SegdRevision(major: 3, minor: 0))
  r.gh1 = SegdGeneralHeader1(fileNumber: 1, formatCode: 8058, year: 24,
    additionalGhBlocks: 2, julianDay: 1, hour: 0, minute: 0, second: 0,
    baseScanInterval16: 16, recordType: 8, recordLength: BcdAllF,
    scanTypesPerRecord: 1, channelSetsPerScanType: 1, manufacturerCode: 9)
  r.gh2Rev3 = SegdGeneralHeader2Rev3(extFileNumber: 1, revisionMajor: 3,
    revisionMinor: 0, extRecordLength: 1000, blockType: BlockTypeGeneralHeader2)
  r.gh3 = SegdGeneralHeader3(timeZero: gh3, blockType: BlockTypeGeneralHeader3)
  var d = SegdChannelSetDescriptorRev3(scanTypeNumber: 1, channelSetNumber: 1,
    channelType: 0x10, startTime: Delay, endTime: Delay + 1000, numSamples: 1,
    descaleMultiplier: 1.0, channelsInSet: 1, samplingInterval: 1000, arrayForming: 1,
    traceHeaderExtensions: 2, verticalStack: 1, blockType1: BlockTypeChannelSet1,
    blockType2: BlockTypeChannelSet2, blockType3: BlockTypeChannelSet3)
  for i in 0 ..< d.description.len: d.description[i] = ' '
  r.scanTypes = @[SegdScanType(layout: slRev3, descriptorsRev3: @[d])]
  var t = SegdTrace(layout: slRev3, index: 0, numSamples: 1)
  t.header = SegdTraceHeader(fileNumber: 1, scanTypeNumber: 1, channelSetNumber: 1,
    traceNumber: 1, traceHeaderExtensions: 2)
  t.ext1Rev3 = some(SegdTraceHeaderExt1Rev3(receiverLineNumber: 100,
    receiverPointNumber: 200, receiverPointIndex: 1, numSamples: 1, sensorType: 1,
    depthIndex: 1, blockType: BlockTypeTraceHeaderExt1))
  var ts = SegdTimestampHeader(timeZeroOfData: stamp, blockType: 0x42)
  let raw = ts.encoded
  t.extensions = @raw
  t.samples = newSeq[byte](dataBytes(sd8058, 1))
  encodeSamples(sd8058, [1.0'f32], t.samples)
  computeRev3Sizes(r, [t])
  r.traceCount = 1
  let sink = openMemSink("delay")
  var w = openSegdWriter(sink)
  w.writeRecordHeaders(r)
  w.writeTrace(t)
  w.endRecord()
  w.close()
  sink.takeBytes()

proc main*() =
  withFixtures fx:
    block no_log:
      var st = initAppState()
      st.openLand()
      st.apply Command(kind: ckHover, trace: st.sessions[0].base)
      let a = st.followAnswer()
      doAssert a.source == sfNone, "a pointer with no log followed " & $a.source
      doAssert st.selection.hover == st.sessions[0].base
      doAssert st.selection.selectedCount == 0
      st.shutdown()

    block pointer_matches_row:
      var st = initAppState()
      st.openLand()
      let local = laterTrace(st)
      let us = timeZeroOf(st, local)
      let first = timeZeroOf(st, 0)
      doAssert us != first
      let path = writeLog(fx.dir, "pointer.csv", [row(first, 1, 1, 1), row(us, 2, 2, 2)])
      st.importLog(path, 1)
      let hover = st.sessions[0].base + local
      st.apply Command(kind: ckHover, trace: hover)
      let a = st.followAnswer()
      doAssert a.source == sfPointer, $a.source
      doAssert a.match.row == 1, "row " & $a.match.row
      doAssert a.match.count == 1
      let before = allocations()
      let again = st.followAnswer()
      doAssert allocations() - before == 0, "a second call allocated"
      doAssert again.revision == a.revision
      doAssert st.selection.hover == hover
      doAssert st.selection.selectedCount == 0
      # two traces of one record share a time zero: the revision does not move
      var twin = -1
      for t in 0 ..< st.sessions[0].len:
        if t != local and timeZeroOf(st, t) == us:
          twin = t
          break
      doAssert twin >= 0, "no second trace shares that time zero"
      st.apply Command(kind: ckHover, trace: st.sessions[0].base + twin)
      let moved = st.followAnswer()
      doAssert moved.match.row == 1, "a twin trace left row " & $moved.match.row
      doAssert moved.revision == a.revision, "a twin trace bumped the revision"
      st.apply Command(kind: ckHover, trace: st.sessions[0].base)
      let other = st.followAnswer()
      doAssert other.match.row == 0, "row " & $other.match.row
      doAssert other.revision > a.revision
      st.shutdown()

    block repeated_numbers_resolve_by_time:
      var st = initAppState()
      st.openLand()
      let local = laterTrace(st)
      let us = timeZeroOf(st, local)
      let k = st.sessions[0].file.traceKeys(local)
      let path = writeLog(fx.dir, "repeat.csv", [
        row(us - 30_000_000, int(round(k.record)), k.srcLine, k.srcPoint),
        row(us, int(round(k.record)), k.srcLine, k.srcPoint)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: st.sessions[0].base + local)
      let a = st.followAnswer()
      doAssert a.source == sfPointer
      doAssert a.match.row == 1, "time did not pick the later row: " & $a.match.row
      doAssert a.match.count == 1
      st.shutdown()

    block delay_matches_time_zero:
      var st = initAppState()
      let path = fx.dir / "delay.sgd"
      writeBytes(path, delaySegd())
      st.apply Command(kind: ckOpen, paths: @[path])
      doAssert st.settle(st.sessions.len == 1 and st.jobs.active.len == 0), "delay file did not open"
      let zero = st.sessions[0].file.recordTimeZeroUs(0)
      doAssert zero.isSome
      let keys = st.sessions[0].file.traceKeys(0)
      doAssert not keys.time.isNaN
      let sampleUs = int64(round(keys.time * 1_000_000.0))
      doAssert sampleUs != zero.get, "keys.time is time zero, so the delay is not tested"
      let log = writeLog(fx.dir, "delay.csv", [
        row(sampleUs, 1, 0, 0),
        row(zero.get, 1, 0, 0)])
      st.importLog(log, 1)
      st.apply Command(kind: ckHover, trace: st.sessions[0].base)
      let a = st.followAnswer()
      doAssert a.source == sfPointer
      doAssert a.match.row == 1, "matched row " & $a.match.row & " (0 is keys.time)"
      st.shutdown()

    block selected_file:
      var st = initAppState()
      st.openLand()
      let us = timeZeroOf(st, 0)
      let path = writeLog(fx.dir, "file.csv", [row(us - 1_000_000, 9, 9, 9), row(us, 1, 1, 1)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: -1)
      doAssert st.fileList.chosen.len > 0
      let a = st.followAnswer()
      doAssert a.source == sfFile, $a.source
      doAssert a.match.row == 1, "row " & $a.match.row
      st.shutdown()

    block selected_signature:
      var st = initAppState()
      let dat = datFile(fx.dir, "sweep.dat")
      st.apply Command(kind: ckOpen, paths: @[dat])
      doAssert st.settle(st.sessions.len == 1 and st.jobs.active.len == 0), "the signature did not open"
      doAssert st.sessions[0].isSignature
      let trigger = st.sessions[0].signature.info.triggerNs
      doAssert trigger != 0
      let us = trigger div 1000
      let path = writeLog(fx.dir, "sig.csv", [row(us - 5_000_000, 1, 1, 1), row(us, 1, 1, 1)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: -1)
      let a = st.followAnswer()
      doAssert a.source == sfSignature, $a.source
      doAssert a.match.row == 1, "row " & $a.match.row
      st.shutdown()

    block precedence:
      var st = initAppState()
      st.openLand()
      let dat = datFile(fx.dir, "prec.dat")
      st.apply Command(kind: ckOpen, paths: @[dat])
      doAssert st.settle(st.sessions.len == 2 and st.jobs.active.len == 0), "the signature did not open"
      var sig = 0
      for i, s in st.sessions:
        if s.isSignature: sig = i
      var landAt = -1
      for i, s in st.sessions:
        if not s.isSignature: landAt = i
      doAssert landAt >= 0
      let first = st.sessions[landAt].file.recordTimeZeroUs(0).get
      var other = 0
      var otherUs = first
      for t in 1 ..< st.sessions[landAt].len:
        let z = st.sessions[landAt].file.recordTimeZeroUs(t)
        if z.isSome and z.get != first:
          other = t
          otherUs = z.get
          break
      doAssert otherUs != first
      let trigger = st.sessions[sig].signature.info.triggerNs div 1000
      doAssert trigger != first and trigger != otherUs
      let path = writeLog(fx.dir, "prec.csv", [
        row(first, 1, 1, 1), row(otherUs, 2, 2, 2), row(trigger, 3, 3, 3)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: st.sessions[landAt].base + other)
      let pointed = st.followAnswer()
      doAssert pointed.source == sfPointer and pointed.match.row == 1, $pointed.source &
        " row " & $pointed.match.row
      st.apply Command(kind: ckHover, trace: -1)
      let signed = st.followAnswer()
      doAssert signed.source == sfSignature and signed.match.row == 2, $signed.source &
        " row " & $signed.match.row
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: st.sessions[landAt].path)
      doAssert st.settle(st.fileList.chosen == st.sessions[landAt].path)
      let filed = st.followAnswer()
      doAssert filed.source == sfFile and filed.match.row == 0, $filed.source &
        " row " & $filed.match.row
      st.shutdown()

    block several_rows:
      var st = initAppState()
      st.openLand()
      let us = timeZeroOf(st, 0)
      let path = writeLog(fx.dir, "many.csv", [row(us, 1, 1, 1), row(us, 1, 1, 1)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: st.sessions[0].base)
      let a = st.followAnswer()
      doAssert a.source == sfPointer, $a.source
      doAssert a.match.row == -1, "row " & $a.match.row
      doAssert a.match.count >= 2, "count " & $a.match.count
      st.shutdown()

    block cell_edit_moves_the_answer:
      var st = initAppState()
      st.openLand()
      let us = timeZeroOf(st, 0)
      let path = writeLog(fx.dir, "edit.csv", [row(us, 1, 1, 1), row(us + 60_000_000, 2, 2, 2)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: st.sessions[0].base)
      let before = st.followAnswer()
      doAssert before.match.row == 0
      var col = -1
      for c in 0 ..< st.shotLogMap(0).roles.len:
        if st.shotLogMap(0).roles[c] == crUtcMicros: col = c
      doAssert col >= 0, "no UTC microseconds column"
      st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 0, logCol: col,
        logCell: $(us + 120_000_000))
      doAssert st.settle(st.jobs.active.len == 0 and not st.shotLogBusy(0)), "the edit did not finish"
      st.apply Command(kind: ckEditShotCell, logIndex: 0, logRow: 1, logCol: col, logCell: $us)
      doAssert st.settle(st.jobs.active.len == 0 and not st.shotLogBusy(0)), "the second edit did not finish"
      let after = st.followAnswer()
      doAssert after.match.row == 1, "row " & $after.match.row
      doAssert after.revision > before.revision, "revision did not move"
      st.shutdown()

    block removing_the_log:
      var st = initAppState()
      st.openLand()
      let us = timeZeroOf(st, 0)
      let path = writeLog(fx.dir, "gone.csv", [row(us, 1, 1, 1)])
      st.importLog(path, 1)
      st.apply Command(kind: ckHover, trace: st.sessions[0].base)
      doAssert st.followAnswer().source == sfPointer
      st.apply Command(kind: ckRemoveShotLog, logIndex: 0)
      doAssert st.shotLogCount == 0
      let a = st.followAnswer()
      doAssert a.source == sfNone, $a.source
      st.shutdown()

when isMainModule:
  main()
