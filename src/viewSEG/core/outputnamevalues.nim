## The values one open file gives a name pattern. Nothing is read from disk
## here: the caller passes the file the batch already opened, and, when the
## write keeps the file's own positions, the header keys it opened for that.
## A missing or mixed value is left for `render` to refuse. A signature file
## is named from its sweep, not from trace keys a join may have changed.

import std/[atomics, math, options, os, sets]
import parseSEG
import edits, outputnames, outputtext, recordtime, sigtypes, unitserial, vendormaps

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
      let us = timeZeroOfRecord(buf[k], file.kind)
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

# --- vendor fields, `{vendor:NAME}` ---

var vendorColumnReads*: Atomic[int]
  ## The vendor columns `vendorValuesOf` has read since the program began; a test reads it to
  ## see that a pattern that names no vendor field reads none.

type
  VendorMode = enum
    vmFloat, vmInt, vmText

  VendorCol = object
    ## One field's value for every trace.
    mode: VendorMode
    numbers: seq[float64] ## `vmFloat`; NaN where the trace has none
    ints: seq[int64]      ## `vmInt`
    present: seq[bool]    ## `vmInt`
    texts: seq[string]    ## `vmText`; "" where the trace has none

  VendorAcc = object
    ## What a group of traces says of one field.
    seen, missing: int
    differs: bool
    f, lo, hi: float64
    n, loN, hiN: int64
    text: string

proc readVendorColumn(file: SeismicFile; vendors: VendorRegistry; name: string;
    col: var VendorCol): bool =
  ## False when the field is not in this file (an unknown or ambiguous name, no map, a
  ## file the maps do not apply to).
  {.cast(gcsafe).}:
    discard vendorColumnReads.fetchAdd(1)
  try:
    let c = file.vendorColumn(vendors, name)
    if c.stopped: return false
    case c.kind
    of vvInt, vvFloat:
      col = VendorCol(mode: vmFloat, numbers: c.numbers)
      if c.kind == vvInt:
        try:
          let exact: VendorColumnInt = file.vendorColumnInt(vendors, name)
          if not exact.stopped:
            col = VendorCol(mode: vmInt, ints: exact.values, present: exact.present)
        except ValueError:
          discard # a scaled integer is a float: the column read first stays
    of vvText, vvBytes:
      col = VendorCol(mode: vmText, texts: c.texts)
    result = true
  except CatchableError:
    result = false

proc consider(a: var VendorAcc; c: VendorCol; i: int) =
  case c.mode
  of vmFloat:
    let x = c.numbers[i]
    if x.isNaN or x == Inf or x == NegInf:
      inc a.missing
    else:
      if a.seen == 0:
        a.f = x
        a.lo = x
        a.hi = x
      else:
        if x != a.f: a.differs = true
        a.lo = min(a.lo, x)
        a.hi = max(a.hi, x)
      inc a.seen
  of vmInt:
    if not c.present[i]:
      inc a.missing
    else:
      let x = c.ints[i]
      if a.seen == 0:
        a.n = x
        a.loN = x
        a.hiN = x
      else:
        if x != a.n: a.differs = true
        a.loN = min(a.loN, x)
        a.hiN = max(a.hiN, x)
      inc a.seen
  of vmText:
    let s = printable(c.texts[i])
    if s.isNone:
      inc a.missing
    else:
      if a.seen == 0: a.text = s.get
      elif s.get != a.text: a.differs = true
      inc a.seen

func valueOf(a: VendorAcc; mode: VendorMode; name: string): VendorFieldValue =
  ## One value; `nvMixed` when the traces differ or some have none (with the lowest and
  ## highest of a number that differs); missing when none has one.
  result = VendorFieldValue(name: name)
  if a.seen == 0: return
  if a.differs or a.missing > 0:
    result.value = NameValue(state: nvMixed)
    if a.differs:
      case mode
      of vmFloat:
        result.first = NameValue(state: nvNumber, number: a.lo)
        result.last = NameValue(state: nvNumber, number: a.hi)
      of vmInt:
        result.first = NameValue(state: nvInt, intValue: a.loN)
        result.last = NameValue(state: nvInt, intValue: a.hiN)
      of vmText: discard
  else:
    result.value = case mode
      of vmFloat: NameValue(state: nvNumber, number: a.f)
      of vmInt: NameValue(state: nvInt, intValue: a.n)
      of vmText: NameValue(state: nvText, text: a.text)

proc vendorValuesOf*(file: SeismicFile; facts: SignatureFacts; edits: FileEdits;
    dropKilled: bool; fields: openArray[string]; vendors: VendorRegistry): seq[VendorFieldValue] =
  ## The value each of `fields` (a vendor field's name, as a display line lists it) takes
  ## over the traces the file's name or header is made from: the same traces the other
  ## values use (a killed trace is skipped when `dropKilled`; an auxiliary trace only when a
  ## kept trace is not auxiliary). One value when every such trace has it and they agree;
  ## `nvMixed` when they differ or some have none (a number that differs also gives its
  ## lowest and highest); missing when no trace has it, the name is unknown or ambiguous,
  ## or no map applies. A text is cleaned as the sensor serial is. A column is read only
  ## for a name in `fields`, so none for an empty list. A signature file has no vendor field.
  result = @[]
  if fields.len == 0: return
  var cols = newSeq[VendorCol](fields.len)
  var found = newSeq[bool](fields.len)
  var any = false
  if not facts.isSignature and file.isOpen and file.hasKeys:
    for j, name in fields:
      found[j] = readVendorColumn(file, vendors, name, cols[j])
      any = any or found[j]
  var seismic = newSeq[VendorAcc](fields.len)
  var auxiliary = newSeq[VendorAcc](fields.len)
  var sawNonAux = false
  if any:
    var buf: array[KeyChunk, TraceKeys]
    var t = 0
    while t < file.len:
      let count = min(KeyChunk, file.len - t)
      file.traceKeysInto(t ..< t + count, buf.toOpenArray(0, count - 1))
      for k in 0 ..< count:
        let i = t + k
        if not (dropKilled and edits.has(teKilled, i)):
          let aux = buf[k].status == tsAuxiliary
          if not aux: sawNonAux = true
          for j in 0 ..< fields.len:
            if found[j]:
              if aux: auxiliary[j].consider(cols[j], i)
              else: seismic[j].consider(cols[j], i)
      t += count
  for j, name in fields:
    if found[j]:
      result.add valueOf(if sawNonAux: seismic[j] else: auxiliary[j], cols[j].mode, name)
    else:
      result.add VendorFieldValue(name: name)

const EndParts = [npRecord, npSrcLine, npSrcPoint, npRcvLine, npRcvPoint, npSrcIndex, npRcvIndex]
  ## the parts a text header token can show as lowest-highest

type Range = object
  ## The lowest and the highest value one part takes in one group of traces.
  seen: bool
  lo, hi: float64

func keyNumber(keys: TraceKeys; kind: NamePartKind): Option[float64] =
  ## One part of one trace's keys; none when the trace gives none.
  func number(x: float64; zeroMissing: bool): Option[float64] =
    if x.isNaN or abs(x) >= 1e15 or (zeroMissing and x == 0.0): none(float64)
    else: some(x)
  case kind
  of npRecord: number(keys.record, true)
  of npSrcLine: number(keys.srcLine, false)
  of npSrcPoint: number(keys.srcPoint, false)
  of npRcvLine: number(keys.rcvLine, false)
  of npRcvPoint: number(keys.rcvPoint, false)
  of npSrcIndex: some(float64(keys.srcIndex))
  of npRcvIndex: some(float64(keys.rcvIndex))
  else: none(float64)

func endValue(kind: NamePartKind; x: float64): NameValue =
  if kind in {npSrcIndex, npRcvIndex}: NameValue(state: nvInt, intValue: int64(x))
  else: NameValue(state: nvNumber, number: x)

proc fillFirstLast(v: var TextValues; file: SeismicFile; edits: FileEdits; dropKilled: bool;
    own: ptr SeismicFile) =
  ## The lowest and the highest value, whatever the trace order, of each part
  ## that is not one value in the file (the trace group `fillSeismic` compares).
  let useOwn = own != nil and own[].isOpen and own[].len == file.len
  var seismic, auxiliary: array[NamePartKind, Range]
  var sawNonAux, sawAux = false
  var buf, ownBuf: array[KeyChunk, TraceKeys]
  var t = 0
  while t < file.len:
    let count = min(KeyChunk, file.len - t)
    let span = t ..< t + count
    file.traceKeysInto(span, buf.toOpenArray(0, count - 1))
    if useOwn: own[].traceKeysInto(span, ownBuf.toOpenArray(0, count - 1))
    for k in 0 ..< count:
      if not (dropKilled and edits.has(teKilled, t + k)):
        var keys = buf[k]
        if useOwn: keys = ownGeometry(keys, ownBuf[k])
        let aux = keys.status == tsAuxiliary
        if aux: sawAux = true
        else: sawNonAux = true
        for kind in EndParts:
          let x = keyNumber(keys, kind)
          if x.isSome:
            let r = if aux: addr auxiliary[kind] else: addr seismic[kind]
            if not r[].seen:
              r[] = Range(seen: true, lo: x.get, hi: x.get)
            else:
              r[].lo = min(r[].lo, x.get)
              r[].hi = max(r[].hi, x.get)
    t += count
  if sawNonAux or sawAux:
    let ranges = if sawNonAux: seismic else: auxiliary
    for kind in EndParts:
      if v.values[kind].state == nvMixed and ranges[kind].seen:
        v.firstLast[kind] = (first: endValue(kind, ranges[kind].lo),
          last: endValue(kind, ranges[kind].hi))

proc textValuesOf*(file: SeismicFile; source: string; facts: SignatureFacts;
    edits: FileEdits; dropKilled: bool; writtenUs: int64; own: ptr SeismicFile = nil;
    wanted: set[NamePartKind] = {}; vendors = VendorRegistry();
    vendorFields: openArray[string] = []): TextValues =
  ## What one file gives the tokens of a text header template: its name
  ## values (`nameValuesOf`), `source`, the time of writing, and, for a
  ## record, line, point or index that is not one value in the file, its
  ## lowest and highest value (`firstLast`), whatever the trace order. A signature file has no
  ## trace keys to compare, so has none. `vendorFields` are the `{vendor:NAME}` names the
  ## template uses: each is read (`vendorValuesOf`) only when listed.
  result.source = source
  result.writtenUs = writtenUs
  result.values = nameValuesOf(file, source, facts, edits, dropKilled, own, wanted, vendors)
  var mixed = false
  for kind in EndParts: mixed = mixed or result.values[kind].state == nvMixed
  if mixed and not facts.isSignature: fillFirstLast(result, file, edits, dropKilled, own)
  result.vendor = vendorValuesOf(file, facts, edits, dropKilled, vendorFields, vendors)
