## The values one open file gives a name pattern. Nothing is read from disk
## here: the caller passes the file the batch already opened, and, when the
## write keeps the file's own positions, the header keys it opened for that.
## A missing or mixed value is left for `render` to refuse. A signature file
## is named from its sweep, not from trace keys a join may have changed.

import std/[math, options, os, sets]
import parseSEG
import edits, outputnames, sigtypes, unitserial, vendormaps

const KeyChunk = 64 ## traces whose keys are compared together

func stemOf(source: string): string =
  source.extractFilename.changeFileExt("")

func ownGeometry(session, own: TraceKeys): TraceKeys =
  ## `session` with the position fields of the file's own header keys.
  ## The same fields the writer copies when it keeps those positions.
  result = session
  result.srcX = own.srcX
  result.srcY = own.srcY
  result.srcZ = own.srcZ
  result.rcvX = own.rcvX
  result.rcvY = own.rcvY
  result.rcvZ = own.rcvZ
  result.offset = own.offset
  result.cmpX = own.cmpX
  result.cmpY = own.cmpY
  result.srcLine = own.srcLine
  result.srcPoint = own.srcPoint
  result.srcIndex = own.srcIndex
  result.rcvLine = own.rcvLine
  result.rcvPoint = own.rcvPoint
  result.rcvIndex = own.rcvIndex
  result.component = own.component

func usOfNs(ns: int64): int64 =
  ## Nanoseconds to microseconds, nearest, half away from zero.
  if ns >= 0: (ns + 500) div 1000
  elif ns == low(int64): ns div 1000
  else: -(((-ns) + 500) div 1000)

type
  FloatAcc = object
    set, miss, mixed: bool
    value: float64
  IntAcc = object
    set, miss, mixed: bool
    value: int64
  TimeAcc = object
    set, miss, mixed: bool
    value: int64
    whole: bool
  TextAcc = object
    set, miss, mixed: bool
    value: string
  PartAcc = object
    rec, srcLine, srcPoint, rcvLine, rcvPoint: FloatAcc
    srcIndex, rcvIndex: IntAcc
    time: TimeAcc

proc considerFloat(a: var FloatAcc; x: float64; zeroMissing: bool) =
  let missing = x.isNaN or abs(x) >= 1e15 or (zeroMissing and x == 0.0)
  if not a.set:
    a.set = true
    a.miss = missing
    if not missing: a.value = x
    return
  if a.mixed: return
  if a.miss:
    if not missing: a.mixed = true
    return
  if missing or a.value != x: a.mixed = true

proc considerInt(a: var IntAcc; x: int64; zeroMissing: bool) =
  let missing = zeroMissing and x == 0
  if not a.set:
    a.set = true
    a.miss = missing
    if not missing: a.value = x
    return
  if a.mixed: return
  if a.miss:
    if not missing: a.mixed = true
    return
  if missing or a.value != x: a.mixed = true

proc considerTime(a: var TimeAcc; us: Option[int64]; origin: TimeOrigin) =
  ## `whole` stays true only when every trace considered so far is a
  ## whole-second clock (`toHeaderSeconds`). Any other origin clears it.
  let missing = not us.isSome
  if not a.set:
    a.set = true
    a.miss = missing
    a.whole = origin == toHeaderSeconds
    if not missing: a.value = us.get
    return
  if origin != toHeaderSeconds: a.whole = false
  if a.mixed: return
  if a.miss:
    if not missing: a.mixed = true
    return
  if missing or a.value != us.get: a.mixed = true

proc considerText(a: var TextAcc; s: Option[string]) =
  let missing = s.isNone
  if not a.set:
    a.set = true
    a.miss = missing
    if not missing: a.value = s.get
    return
  if a.mixed: return
  if a.miss:
    if not missing: a.mixed = true
    return
  if missing or a.value != s.get: a.mixed = true

func asText(a: TextAcc): NameValue =
  if not a.set or (a.miss and not a.mixed): NameValue(state: nvMissing)
  elif a.mixed: NameValue(state: nvMixed)
  else: NameValue(state: nvText, text: a.value)

func asNumber(a: FloatAcc): NameValue =
  if not a.set or (a.miss and not a.mixed): NameValue(state: nvMissing)
  elif a.mixed: NameValue(state: nvMixed)
  else: NameValue(state: nvNumber, number: a.value)

func asInt(a: IntAcc): NameValue =
  if not a.set or (a.miss and not a.mixed): NameValue(state: nvMissing)
  elif a.mixed: NameValue(state: nvMixed)
  else: NameValue(state: nvInt, intValue: a.value)

func asTime(a: TimeAcc): NameValue =
  if not a.set or (a.miss and not a.mixed): NameValue(state: nvMissing)
  elif a.mixed: NameValue(state: nvMixed)
  else: NameValue(state: nvTimeUs, timeUs: a.value, wholeSeconds: a.whole)

proc considerParts(a: var PartAcc; keys: TraceKeys; us: Option[int64];
    origin: TimeOrigin; segd: bool) =
  considerFloat(a.rec, keys.record, true)
  considerFloat(a.srcLine, keys.srcLine, false)
  considerFloat(a.srcPoint, keys.srcPoint, false)
  considerFloat(a.rcvLine, keys.rcvLine, false)
  considerFloat(a.rcvPoint, keys.rcvPoint, false)
  if segd:
    considerInt(a.srcIndex, int64(keys.srcIndex), false)
    considerInt(a.rcvIndex, int64(keys.rcvIndex), false)
  considerTime(a.time, us, origin)

proc writeParts(v: var NameValues; a: PartAcc; segd: bool) =
  v[npRecord] = asNumber(a.rec)
  v[npSrcLine] = asNumber(a.srcLine)
  v[npSrcPoint] = asNumber(a.srcPoint)
  v[npRcvLine] = asNumber(a.rcvLine)
  v[npRcvPoint] = asNumber(a.rcvPoint)
  if segd:
    v[npSrcIndex] = asInt(a.srcIndex)
    v[npRcvIndex] = asInt(a.rcvIndex)
  v[npTime] = asTime(a.time)

proc putInt(v: var NameValues; kind: NamePartKind; n: int64; missing: bool) =
  if not missing: v[kind] = NameValue(state: nvInt, intValue: n)

proc fillSignature(v: var NameValues; facts: SignatureFacts) =
  ## Sweep values. 0 is not given, except a controller whose source is known
  ## and a file number other than -1 (0 can be a real `.dat` file number).
  let info = facts.info
  if info.serialFrom != sfNone:
    v[npController] = NameValue(state: nvInt, intValue: info.controller)
  putInt(v, npVibrator, info.vibrator, info.vibrator == 0)
  putInt(v, npFileNumber, info.fileNumber, info.fileNumber == -1)
  putInt(v, npSigLine, info.line, info.line == 0)
  putInt(v, npSigStation, info.station, info.station == 0)
  putInt(v, npShotId, info.shotId, info.shotId == 0)
  putInt(v, npSweepId, info.sweepId, info.sweepId == 0)
  putInt(v, npSrcIndex, info.sourceIndex, info.sourceIndex == 0)
  var ns = info.triggerNs
  var whole = info.timeIsStart
  if facts.pair.len > 0 and facts.pairTriggerNs != 0:
    ns = facts.pairTriggerNs
    whole = false
  if ns != 0:
    v[npTime] = NameValue(state: nvTimeUs, timeUs: usOfNs(ns), wholeSeconds: whole)

proc fillSeismic(v: var NameValues; file: SeismicFile; edits: FileEdits;
    dropKilled: bool; own: ptr SeismicFile; wanted: set[NamePartKind];
    vendors: VendorRegistry) =
  ## One value when every compared trace shares it. An auxiliary trace is
  ## not compared when a kept trace is not auxiliary; a file of auxiliary
  ## traces only uses them all. The time is whole seconds only when every
  ## compared trace's origin is a whole-second clock (`toHeaderSeconds`: a
  ## SEG-Y header with no fraction, or a SEG-D Rev 0-2 general-header clock).
  ## SEG-D system serial is one value when every record that still has a kept
  ## trace agrees, auxiliary traces included. Record 0 is missing; an index
  ## of 0 is a real value; SEG-Y has no index parts. The sensor serial is
  ## read from each compared trace's header only when `wanted` holds it, and
  ## no longer once the traces of its group differ.
  let segd = file.kind == skSegd
  let useOwn = own != nil and own[].isOpen and own[].len == file.len
  var
    seismic, auxiliary: PartAcc
    serial: IntAcc
    sensor, sensorAux: TextAcc
    wantSensor = npSensorSerial in wanted
    sawNonAux = false
    seenRec = initHashSet[int]()
    buf, ownBuf: array[KeyChunk, TraceKeys]
  var t = 0
  while t < file.len:
    let count = min(KeyChunk, file.len - t)
    let span = t ..< t + count
    file.traceKeysInto(span, buf.toOpenArray(0, count - 1))
    if useOwn: own[].traceKeysInto(span, ownBuf.toOpenArray(0, count - 1))
    for k in 0 ..< count:
      let i = t + k
      if dropKilled and edits.has(teKilled, i): continue
      var keys = buf[k]
      if useOwn: keys = ownGeometry(keys, ownBuf[k])
      let us = file.recordTimeZeroUs(i)
      if keys.status == tsAuxiliary:
        considerParts(auxiliary, keys, us, buf[k].timeOrigin, segd)
        if wantSensor and not sensorAux.mixed:
          considerText(sensorAux, unitSerialOf(file, i, vendors))
      else:
        sawNonAux = true
        considerParts(seismic, keys, us, buf[k].timeOrigin, segd)
        if wantSensor and not sensor.mixed:
          considerText(sensor, unitSerialOf(file, i, vendors))
      if segd:
        let ri = int(file.traceEntry(i).record)
        if ri notin seenRec:
          seenRec.incl ri
          if ri >= 0 and ri < file.index.segdRecords.len:
            considerInt(serial, int64(file.index.segdRecords[ri].gh1.manufacturerSerial), false)
          else:
            considerInt(serial, 0, true)
    t += count
  if sawNonAux: writeParts(v, seismic, segd)
  else: writeParts(v, auxiliary, segd)
  if segd: v[npSystemSerial] = asInt(serial)
  if wantSensor: v[npSensorSerial] = asText(if sawNonAux: sensor else: sensorAux)

proc nameValuesOf*(file: SeismicFile; source: string; facts: SignatureFacts;
    edits: FileEdits; dropKilled: bool; own: ptr SeismicFile = nil;
    wanted: set[NamePartKind] = {}; vendors = VendorRegistry()): NameValues =
  ## The name values of one file. `source` supplies the stem. A signature
  ## file (`facts.isSignature`) is named from the sweep: controller only when
  ## `serialFrom` is known, vibrator 0 and line, station, shot id, sweep id
  ## and source index 0 missing, file number -1 missing, and the time the
  ## pair's trigger when a pair was given, otherwise a start second with no
  ## fraction. Any other file is named from the trace keys, skipping a killed
  ## trace when `dropKilled`. An auxiliary trace does not take part when a
  ## kept trace is not auxiliary; a file of auxiliary traces only uses them
  ## all. `own`, when open and the same length, supplies
  ## the position fields (line, point, index); record and time stay the
  ## session's. The name keeps the value from the keys; a file name may
  ## carry what a header cannot. The sensor serial (one value, or none, as a
  ## file's traces say; a signature file has none) is read only when `wanted`
  ## holds `npSensorSerial`, from the standard Sensor Info block or, with
  ## `vendors`, the field a map names `sensorSerial` (`core/unitserial`). Does not open a file.
  result[npStem] = NameValue(state: nvText, text: stemOf(source))
  if facts.isSignature: fillSignature(result, facts)
  else: fillSeismic(result, file, edits, dropKilled, own, wanted, vendors)
