## The `.dat` reader: the one module that imports parseSSDAT. Pure: bytes in, SEG-Y
## bytes and facts out. It makes no file system call, keeps no global state and lets
## no library type out (`core/sigtypes` holds what the rest of viewSEG may use).
##
## The four traces (spec: the controller's channels): 1 the reference (code 21), 2 the
## reaction-mass force channel (18), 3 the baseplate force channel (19), 4 the
## controller's ground force, the plain sum of 2 and 3 (20). The record is the file
## number. Samples are raw counts, exactly as recorded: no sign is changed.
##
## The file's own fields (`rows`) come from a private table over the raw blocks the
## decoder keeps; a library that exported its field table would be better.

import std/[math, strutils]
import parseSEG
import parseSSDAT
import headers, sigtypes

const
  DatKindName = ".dat"
  TraceNames = ["reference", "reaction-mass force", "baseplate force",
    "ground force (the controller's: the sum of 2 and 3)"]
  TraceShorts = ["ref", "mass F", "plate F", "GF"]
  TraceCodes = [21'i16, 18, 19, 20]

func datKind*(head: openArray[byte]): SignatureKind =
  ## `sgDat` when `head` (the file's first bytes, at least 512) starts as a `.dat`.
  if looksLikeDat(head): sgDat else: sgNone

func sigError(name, words: string): ref SignatureError =
  newException(SignatureError, name & " could not be opened as a vibrator " & DatKindName &
    " file: " & words)

func unixOf(t: DatTime): int64 =
  unixNs(t.year, t.month, t.day, t.hour, t.minute, t.second, t.nanosecond)

func qcOf(q: DatQc): SweepQc =
  if not q.valid: return
  result.valid = true
  result.forceMaxPct = int16(q.forceMaxPct)
  result.forceMinPct = int16(q.forceMinPct)
  result.forceAvgPct = int16(q.forceAvgPct)
  result.thdMaxPct = int16(q.thdMaxPct)
  result.thdAvgPct = int16(q.thdAvgPct)
  result.phaseMaxDeg = float32(q.phaseMaxDeg)
  for l in q.limits:
    result.limits.incl QcLimit(ord(l))

func infoOf(s: DatInfo; size: int64): SweepInfo =
  ## What a list knows of `s`.
  result = SweepInfo(kind: sgDat, controller: s.controllerSerial, serialFrom: sfFile,
    vibrator: (if s.qc.valid: s.qc.vibratorId else: 0), fileNumber: s.fileNumber,
    triggerNs: unixOf(s.trigger), samples: int32(s.samples),
    declared: int32(s.declaredSamples), blocksDeclared: int32(s.blocks),
    intervalUs: s.sampleIntervalUs, complete: s.complete,
    sweepNumber: int16(if s.qc.valid: s.qc.sweepNumber else: 0), line: s.sourceLine,
    station: s.sourceStation, shotId: s.shotId, sweepId: s.sweepId,
    sourceIndex: s.sourceIndex, qc: qcOf(s.qc))
  result.blocks = int32(min(size div DatBlockBytes, int64(s.blocks)))

func controllerQcOf(q: DatQc): ControllerQc =
  if not q.valid: return
  result = ControllerQc(valid: true, crew: q.crew, vibrator: q.vibratorId,
    sweepNumber: q.sweepNumber, sweepId: q.sweepId, shotId: q.shotId,
    sourceLine: q.sourceLine, sourceStation: q.sourceStation,
    sweepChecksum: int(q.sweepChecksum), paramChecksum: int(q.paramChecksum),
    brief: qcOf(q), stiffness: q.stiffness, viscosity: q.viscosity,
    targetForceLbf: q.targetForceLbf, satellites: q.satellites,
    correctionAgeS: q.correctionAgeS, heightCm: q.heightCm, pdop: q.pdop, hdop: q.hdop,
    vdop: q.vdop, correlationMagnitude: q.correlationMagnitude,
    correlationStored: q.correlation.len > 0)
  if q.correlation.len > 64: result.correlationLagZero = int(q.correlation[64])

# ------------------------------------------------------------ field rows --

func be(b: openArray[byte]; at, n: int): int64 =
  for i in 0 ..< n: result = (result shl 8) or int64(b[at + i])

func le(b: openArray[byte]; at, n: int): int64 =
  for i in countdown(n - 1, 0): result = (result shl 8) or int64(b[at + i])

func text(b: openArray[byte]; first, last: int): string =
  ## Printable ASCII of `b[first .. last]`, the rest as dots, trailing blanks and NULs cut.
  for i in first .. min(last, b.high):
    result.add(if b[i] in 32'u8 .. 126'u8: char(b[i]) else: '.')
  result = result.strip(leading = false, chars = {' ', '.'})

type Field = tuple[name, words: string; at, size: int; kind: char]
  ## `kind`: 'l' little-endian number, 'b' big-endian number, 's' text, 'c' one letter

func fld(name, words: string; at, size: int; kind: char): Field =
  (name, words, at, size, kind)

const
  HeaderFields = [
    fld("recordLength", "Length of the record in the block", 0, 2, 'l'),
    fld("recordKind", "Record kind: 0x80 is the header record", 2, 1, 'l'),
    fld("controllerSerial", "The controller's serial number", 4, 4, 'l'),
    fld("fileNumber", "File number", 8, 4, 'l'),
    fld("blockNumber", "Block number", 12, 4, 'l'),
    fld("blockCount", "Blocks the file announces", 16, 4, 'l'),
    fld("firmwareMajor", "Firmware, major", 20, 1, 'l'),
    fld("firmwareMinor", "Firmware, minor", 21, 1, 'l'),
    fld("declaredSamples", "Samples per channel the file announces", 46, 4, 'b'),
    fld("headerText", "The GNSS text the controller stored", 280, 212, 's'),
    fld("triggerNanosecond", "Trigger time, nanoseconds", 492, 4, 'l'),
    fld("triggerSecond", "Trigger time, second", 496, 1, 'l'),
    fld("triggerMinute", "Trigger time, minute", 497, 1, 'l'),
    fld("triggerHour", "Trigger time, hour (UTC)", 498, 1, 'l'),
    fld("triggerDay", "Trigger time, day", 499, 1, 'l'),
    fld("triggerMonth", "Trigger time, month", 500, 1, 'l'),
    fld("triggerYear", "Trigger time, year", 501, 2, 'l')]
  PositionFields = [
    fld("recordLength", "Length of the record in the block", 0, 2, 'l'),
    fld("recordKind", "Record kind: 0x87 is the position record", 2, 1, 'l'),
    fld("latitudeDegrees", "Latitude, whole degrees", 135, 1, 'l'),
    fld("latitudeMinutesE6", "Latitude, minutes in millionths", 136, 4, 'l'),
    fld("latitudeHemisphere", "Latitude, N or S", 140, 1, 'c'),
    fld("longitudeDegrees", "Longitude, whole degrees", 141, 1, 'l'),
    fld("longitudeMinutesE6", "Longitude, minutes in millionths", 142, 4, 'l'),
    fld("longitudeHemisphere", "Longitude, E or W", 146, 1, 'c'),
    fld("height", "Height as stored (its meaning is not certain)", 147, 2, 'l'),
    fld("fixQuality", "Fix quality", 149, 1, 'l'),
    fld("satellites", "Satellites", 150, 1, 'l'),
    fld("hdopTenths", "HDOP in tenths", 151, 1, 'l'),
    fld("blockNumber", "Block number", 12, 4, 'l'),
    fld("blockCount", "Blocks the file announces", 16, 4, 'l')]
  TrailerFields = [
    fld("recordLength", "Length of the record in the block", 0, 2, 'l'),
    fld("recordKind", "Record kind: 0x84 is the trailer", 2, 1, 'l'),
    fld("sourceLine", "Source line (0: not given)", 30, 4, 'b'),
    fld("sourceStation", "Source station (0: not given)", 34, 4, 'b'),
    fld("shotId", "Shot id (0: not given)", 38, 4, 'b'),
    fld("sourceIndex", "Source index (0: not given)", 42, 4, 'b'),
    fld("trailerCounter", "A counter whose meaning is not known", 46, 4, 'b'),
    fld("sweepId", "Sweep id (0: not given)", 50, 4, 'b')]
  QcFields = [
    fld("crew", "Crew", 4, 1, 'b'),
    fld("vibratorId", "Vibrator ID", 6, 1, 'b'),
    fld("sweepId", "Sweep id", 9, 4, 'b'),
    fld("sweepNumber", "Sweep number (16 is a pulse record)", 13, 1, 'b'),
    fld("phaseMaxEighthDeg", "Maximum phase error, in eighths of a degree (probable)", 16, 1, 'b'),
    fld("forceMaxPct", "Force maximum, % of the hold-down weight", 19, 1, 'b'),
    fld("forceMinPct", "Force minimum, % (probable)", 20, 1, 'b'),
    fld("forceAvgPct", "Force average, % (probable)", 21, 1, 'b'),
    fld("thdMaxPct", "Distortion (THD) maximum, %", 22, 1, 'b'),
    fld("thdAvgPct", "Distortion (THD) average, %", 23, 1, 'b'),
    fld("sweepChecksum", "Sweep checksum", 24, 2, 'b'),
    fld("paramChecksum", "Parameter checksum", 26, 2, 'b'),
    fld("limitBits", "Limits tripped, as bits (T M V F R; meanings not known)", 31, 1, 'b'),
    fld("correlationMagnitude", "The controller's own correlation: magnitude (probable)", 36, 2, 'b'),
    fld("heightCm", "Height above the ellipsoid, cm", 185, 4, 'b'),
    fld("satellites", "Satellites", 189, 1, 'b'),
    fld("pdopTenths", "PDOP in tenths", 190, 1, 'b'),
    fld("hdopTenths", "HDOP in tenths", 191, 1, 'b'),
    fld("vdopTenths", "VDOP in tenths", 192, 1, 'b'),
    fld("correctionAge", "Correction age, s", 193, 1, 'b'),
    fld("stiffnessMax", "Stiffness maximum", 203, 1, 'b'),
    fld("stiffnessMin", "Stiffness minimum", 204, 1, 'b'),
    fld("stiffnessAvg", "Stiffness average", 205, 1, 'b'),
    fld("targetForceLbf", "Target force, lbf", 209, 2, 'b'),
    fld("shotId", "Shot id", 218, 4, 'b'),
    fld("sourceLine", "Source line", 222, 4, 'b')]

func valueOf(b: openArray[byte]; f: Field): (string, float64) =
  case f.kind
  of 's': (text(b, f.at, f.at + f.size - 1), NaN)
  of 'c': ($char(b[f.at]), NaN)
  else:
    let v = if f.kind == 'l': le(b, f.at, f.size) else: be(b, f.at, f.size)
    ($v, float64(v))

func addRows(rows: var seq[FieldRow]; blockName: string; b: openArray[byte]; blockOffset: int64;
    fields: openArray[Field]) =
  for f in fields:
    if f.size > 0 and f.at + f.size <= b.len:
      let (v, n) = valueOf(b, f)
      rows.add sigRow(blockName, f.name, f.words, v, n, blockOffset, b.len, f.at, f.size)

func qcStart(trailer: openArray[byte]; length: int): int =
  ## Where the QC record starts in the trailer block, as the decoder finds it (the first
  ## `46 33 00 E7` from byte 97 whose 240 bytes end within the record); -1 when none.
  result = -1
  var at = 97
  while at + 240 <= length + 2 and at + 3 < trailer.len:
    if trailer[at] == 0x46 and trailer[at + 1] == 0x33 and trailer[at + 2] == 0 and
        trailer[at + 3] == 0xE7:
      return at
    inc at

proc fieldsOf(s: DatShot; facts: var SignatureFacts) =
  ## The file's own blocks as rows and bytes, offsets in the file.
  for r in s.records:
    if r.bytes.len != DatBlockBytes: continue
    case r.kind
    of 0x80'u8:
      facts.rows.addRows("headerRecord", r.bytes, r.offset, HeaderFields)
      facts.blocks.add RawBlock(blockName: "headerRecord", offset: r.offset,
        size: DatBlockBytes, bytes: r.bytes)
    of 0x87'u8:
      facts.rows.addRows("positionRecord", r.bytes, r.offset, PositionFields)
      facts.blocks.add RawBlock(blockName: "positionRecord", offset: r.offset,
        size: DatBlockBytes, bytes: r.bytes)
    of 0x84'u8:
      facts.rows.addRows("fileTrailer", r.bytes, r.offset, TrailerFields)
      facts.blocks.add RawBlock(blockName: "fileTrailer", offset: r.offset,
        size: DatBlockBytes, bytes: r.bytes)
      let length = int(le(r.bytes, 0, 2))
      let at = if s.qc.valid: qcStart(r.bytes, length) else: -1
      if at >= 0:
        let q = r.bytes[at ..< at + 240]
        facts.rows.addRows("qcRecord", q, r.offset + at, QcFields)
        facts.blocks.add RawBlock(blockName: "qcRecord", offset: r.offset + at, size: 240,
          bytes: q)
    else: discard

# ----------------------------------------------------------------- decode --

func positionOf(g: DatGga): SignaturePosition =
  SignaturePosition(valid: g.valid, latitudeDeg: g.latitudeDeg, longitudeDeg: g.longitudeDeg,
    altitudeM: g.altitudeM, fixQuality: g.fixQuality, satellites: g.satellites,
    hdop: g.hdop)

func positionOf(g: DatFix): SignaturePosition =
  SignaturePosition(valid: not (g.latitudeDeg.isNaN or g.longitudeDeg.isNaN),
    latitudeDeg: g.latitudeDeg, longitudeDeg: g.longitudeDeg,
    fixQuality: g.fixQuality, satellites: g.satellites, hdop: g.hdop)

func cutPrefix(why: string): string =
  ## "the file holds 50 of the 226 blocks its header announces" out of the library's words.
  let at = why.find(':')
  if at > 0: why[0 ..< at] else: why

proc decode*(bytes: openArray[byte]; name, path: string; choice: SignatureChoice;
    log: var DiagLog): tuple[segy: seq[byte]; facts: SignatureFacts] =
  ## Decodes the bytes of the `.dat` file `name` at the interval `choice` says (1000 us when
  ## it says none) and writes them as SEG-Y Rev 2.1 into memory, as the file `path`. Raises
  ## `SignatureError` in the library's words.
  let interval = if choice.intervalUs > 0: choice.intervalUs else: DatIntervalUs
  if not (interval > 0 and interval < Inf):
    raise newException(SignatureError, "the sample interval must be more than 0 us")
  var shot = DatShot()
  try:
    decodeInto(shot, bytes, allowIncomplete = true, sampleIntervalUs = interval)
  except DatIncompleteError as e:
    if "no samples were recorded" in e.msg:
      raise newException(SignatureError, name & " holds no samples: the recording stopped " &
        "before its first sample.")
    raise sigError(name, e.msg)
  except DatFormatError as e:
    raise sigError(name, e.msg)
  except ValueError as e:
    raise sigError(name, e.msg)
  let wopts = DatWriteOptions(positions: dpGga, swapForces: choice.swapForces)
  var o = SegyOutputOptions()
  try:
    o.text = textCards(shot, wopts, dpGga)
    var w = openSeismicWriterBytes(o, path)
    w.writeSegyTraces(shot, wopts, extHeader = true)
    result.segy = w.finishBytes(log)
  except DatWriteError as e:
    raise sigError(name, "it cannot be written in memory: " & e.msg)
  except ValueError as e:
    raise sigError(name, "it cannot be written in memory: " & e.msg)
  except SegFormatError as e:
    raise sigError(name, "it cannot be written in memory: " & e.msg)
  var f = SignatureFacts(kind: sgDat, info: infoOf(shot, int64(bytes.len)),
    qc: controllerQcOf(shot.qc), choice: choice, intervalStated: false,
    forceChannels: true, groundForceGiven: true, headerText: shot.headerText,
    gga: positionOf(shot.gga), fix: positionOf(shot.fix),
    decodedAs: "SEG-Y Rev 2.1 in memory (no file written)")
  f.choice.intervalUs = interval
  f.trigger = SignatureTrigger(source: trGiven, frame: 0, timeZero: "trigger",
    clockFrom: "the trigger time of the header record")
  for i in 0 ..< 4:
    f.traces.add SignatureTrace(name: TraceNames[i], short: TraceShorts[i], code: TraceCodes[i],
        unit: "counts")
  if not shot.complete:
    let shown = shot.len
    f.warnings.add name & ": the recording stopped after " &
      secondsWords(float64(shown) * interval / 1e6) & " of " &
      secondsWords(float64(shot.declaredSamples) * interval / 1e6) & " (" &
      cutPrefix(shot.incompleteWhy) & "). Shown as recorded."
  fieldsOf(shot, f)
  result.facts = f
