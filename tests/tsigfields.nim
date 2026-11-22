## The file's own fields of a signature file (the Headers window's ".dat file" and ".vib
## file" tab): every row's value, read from the bytes through the reader's table, equals the
## number the library decoded; offsets are in the file; the hex pane's blocks are the file's
## own bytes at those offsets.
##
## Seen to fail: with the `.dat` table's trigger year read at byte 500, `datRows` found the
## year row different from the decoded trigger; with the `.vib` weights' offsets swapped,
## `vibRows` found the baseplate weight equal to the mass.

import std/[math, os, strutils]
import parseSEG
import parseSSDAT
import parseSSVIB
import viewSEG/core/[headers, session, signatures]
import utils/[fixtures, sigfiles]

proc rowOf(f: SignatureFacts; blk, field: string): FieldRow =
  for r in f.rows:
    if r.blockName == blk and r.field == field: return r
  doAssert false, blk & "." & field & " has no row"

proc decodeFacts(path: string): SignatureFacts =
  let bytes = cast[seq[byte]](readFile(path))
  var log: DiagLog
  let s = decodeToSession(bytes, path, getLastModificationTime(path), SignatureChoice(), log)
  result = s.signature
  doAssert s.signature.rows.len > 0

proc main*() =
  block datRows:
    withFixtures fx:
      let path = datFile(fx.dir, "a.dat")
      let bytes = cast[seq[byte]](readFile(path))
      let shot = parseDat(bytes)
      let f = decodeFacts(path)
      template num(b, n: string): float64 = f.rowOf(b, n).number
      doAssert num("headerRecord", "controllerSerial") == float64(shot.controllerSerial)
      doAssert num("headerRecord", "fileNumber") == float64(shot.fileNumber)
      doAssert num("headerRecord", "triggerYear") == float64(shot.trigger.year)
      doAssert num("headerRecord", "triggerNanosecond") == float64(shot.trigger.nanosecond)
      doAssert num("headerRecord", "declaredSamples") == float64(shot.declaredSamples)
      doAssert num("headerRecord", "firmwareMinor") == float64(shot.firmware.minor)
      doAssert num("fileTrailer", "sweepId") == float64(shot.sweepId)
      doAssert num("fileTrailer", "shotId") == float64(shot.shotId)
      doAssert num("positionRecord", "satellites") == float64(shot.fix.satellites)
      doAssert num("qcRecord", "vibratorId") == float64(shot.qc.vibratorId)
      doAssert num("qcRecord", "forceMaxPct") == float64(shot.qc.forceMaxPct)
      doAssert num("qcRecord", "thdAvgPct") == float64(shot.qc.thdAvgPct)
      doAssert num("qcRecord", "phaseMaxEighthDeg") / 8 == shot.qc.phaseMaxDeg
      doAssert num("qcRecord", "targetForceLbf") == float64(shot.qc.targetForceLbf)
      doAssert num("qcRecord", "heightCm") == float64(shot.qc.heightCm)
      doAssert f.rowOf("headerRecord", "headerText").value.startsWith("9600 bps"),
        f.rowOf("headerRecord", "headerText").value
      for r in f.rows:
        doAssert r.offset == r.blockOffset + (r.first - 1), r.field
        doAssert int(r.offset) + r.size <= bytes.len, r.field
      for b in f.blocks:
        doAssert b.bytes == bytes[int(b.offset) ..< int(b.offset) + b.size], b.blockName
      doAssert f.blocks.len == 4 # header, position, trailer, QC

  block vibRows:
    withFixtures fx:
      let path = vibFile(fx.dir, "0007.VIB")
      let bytes = cast[seq[byte]](readFile(path))
      let shot = parseVib(bytes)
      let f = decodeFacts(path)
      template num(b, n: string): float64 = f.rowOf(b, n).number
      doAssert num("vibHeader", "holdDownLb") == float64(shot.header.holdDownLb)
      doAssert num("vibHeader", "baseplateLb") == float64(shot.header.baseplateLb)
      doAssert num("vibHeader", "massLb") == float64(shot.header.massLb)
      doAssert num("vibHeader", "baseplateLb") != num("vibHeader", "massLb")
      doAssert num("vibHeader", "valveCalibration") == float64(shot.header.valveCal)
      doAssert num("vibHeader", "startYear") == float64(shot.start.year)
      doAssert num("vibHeader", "startSecond") == float64(shot.start.second)
      doAssert num("vibHeader", "valuesPerFrame") == 11
      doAssert f.rowOf("vibHeader", "magic").value == "VIB"
      doAssert num("firstFrame", "reference") == float64(shot.data[vcReference][0])
      doAssert num("firstFrame", "massSetA") == float64(shot.data[vcMassA][0])
      doAssert num("firstFrame", "cycleValue2") == float64(shot.cycle[vvCycle2][0])
      doAssert f.rowOf("firstFrame", "reference").offset == 47
      for b in f.blocks:
        doAssert b.bytes == bytes[int(b.offset) ..< int(b.offset) + b.size], b.blockName
  echo "tsigfields: ok"

when isMainModule:
  main()
