## The `.vib` reader: the one module that imports parseSSVIB. Pure: bytes in, SEG-Y bytes
## and facts out. It makes no file system call, keeps no global state and lets no library
## type out (`core/sigtypes` holds what the rest of viewSEG may use).
##
## The 13 traces, in the order parseSSVIB's `voForces` writes them (the roles of the
## `.dat`'s four traces come first, so the Vibrator window finds them in either kind):
## 1 reference (21); 2 reaction-mass acceleration, set B (18); 3 baseplate acceleration,
## set B (19); 4 ground force from set B, computed (20); 5, 6 and 7 the same of set A (258,
## 257, 267); 8 torque-motor current (261); 9 valve displacement (262); 10 mass displacement
## (263); 11 drive output (264); 12 and 13 the two per-cycle values (265, 266). Set B is the
## set the `.dat` file records, so it gets the standard codes; set A is the set the
## controller's QC report follows (probable). The ground forces are computed from the
## header's weights and the counts: an estimate, in pound-counts. Samples are raw counts
## exactly as recorded: no sign is changed.
##
## Time zero is the trigger the sweep fit finds in the reference, else the first frame.

import std/[math, strutils]
import parseSEG
import parseSSVIB
import headers, sigtypes

const
  VibKindName = ".vib"
  Shorts = ["ref", "mass B", "plate B", "GF B", "mass A", "plate A", "GF A", "torque", "valve",
      "stroke", "drive", "cycle 1", "cycle 2"]
  Layout = [
    ("reference", 21'i16, "counts"),
    ("reaction-mass acceleration, set B", 18'i16, "counts"),
    ("baseplate acceleration, set B", 19'i16, "counts"),
    ("ground force from set B, computed", 20'i16, "pound-counts"),
    ("reaction-mass acceleration, set A", 258'i16, "counts"),
    ("baseplate acceleration, set A", 257'i16, "counts"),
    ("ground force from set A, computed", 267'i16, "pound-counts"),
    ("torque-motor current", 261'i16, "counts"),
    ("valve displacement", 262'i16, "counts"),
    ("mass displacement", 263'i16, "counts"),
    ("drive output (probable)", 264'i16, "counts"),
    ("per-cycle value 1 (tracks drive / ground force)", 265'i16, "as stored"),
    ("per-cycle value 2 (meaning unknown)", 266'i16, "as stored")]

func vibKindOf*(head: openArray[byte]): SignatureKind =
  ## `sgVib` when `head` (the file's first bytes, at least 47) starts as a signature `.vib`.
  if looksLikeVib(head): sgVib else: sgNone

func isOtherVib*(head: openArray[byte]): bool =
  ## A `.vib` of another kind (kind 6 has been seen): a different file, never decoded.
  vibKind(head) == vkOther

func isBrokenVib*(head: openArray[byte]): bool =
  ## A file that starts as a signature `.vib` (`VIB`, 11) but is not one: cut inside its
  ## header, or with a start time that is no date.
  vibKind(head) == vkSignature and not looksLikeVib(head)

func sigError(name, words: string): ref SignatureError =
  newException(SignatureError, name & " could not be opened as a vibrator " & VibKindName &
    " file: " & words)

func startNs(t: VibTime): int64 =
  unixNs(t.year, t.month, t.day, t.hour, t.minute, t.second, 0)

func infoOf(s: VibInfo; path: string): SweepInfo =
  let serial = serialFromPath(path)
  SweepInfo(kind: sgVib, controller: max(serial, 0),
    serialFrom: (if serial >= 0: sfFolder else: sfNone), fileNumber: nameNumberOf(path),
    triggerNs: startNs(s.start), timeIsStart: true, samples: int32(s.frames),
    declared: int32(s.frames), intervalUs: s.sampleIntervalUs, complete: s.complete)

proc sweepInfo*(head: openArray[byte]; size: int64; path: string): SweepInfo =
  ## What a list knows of the `.vib` at `path` of `size` bytes whose first bytes are `head`
  ## (the 47-byte header): its start second, frames and whether it ends inside a frame. A file
  ## the library refuses gives `problem` in words.
  try:
    result = infoOf(parseVibInfo(head, size), path)
  except VibIncompleteError as e:
    result = SweepInfo(kind: sgVib, problem: if "no samples" in e.msg: "no samples"
      else: e.msg)
  except VibFormatError as e:
    result = SweepInfo(kind: sgVib, problem: e.msg)
  except ValueError as e:
    result = SweepInfo(kind: sgVib, problem: e.msg)

# ------------------------------------------------------------ field rows --

func le(b: openArray[byte]; at, n: int): int64 =
  for i in countdown(n - 1, 0): result = (result shl 8) or int64(b[at + i])

func f32(b: openArray[byte]; at: int): float32 =
  cast[float32](uint32(le(b, at, 4)))

func i16(b: openArray[byte]; at: int): int =
  let v = int(le(b, at, 2))
  if v >= 0x8000: v - 0x10000 else: v

type Field = tuple[name, words: string; at, size: int; kind: char]
  ## `kind`: 'u' unsigned little-endian, 'i' signed 16-bit, 'f' float32, 's' text

func fld(name, words: string; at, size: int; kind: char): Field =
  (name, words, at, size, kind)

const
  HeaderFields = [
    fld("magic", "The file starts with VIB", 0, 3, 's'),
    fld("valuesPerFrame", "Values per frame: 11 for a signature record", 3, 1, 'u'),
    fld("valveCalibration", "Valve displacement calibration", 4, 4, 'f'),
    fld("massCalibration", "Mass displacement calibration", 8, 4, 'f'),
    fld("unknown12", "A value whose meaning is not known", 12, 4, 'f'),
    fld("unknown16", "A value whose meaning is not known", 16, 4, 'f'),
    fld("holdDownLb", "Hold-down weight, pounds", 20, 4, 'f'),
    fld("sensitivity1", "Accelerometer sensitivity (which sensor is not known)", 24, 4, 'f'),
    fld("sensitivity2", "Accelerometer sensitivity (which sensor is not known)", 28, 4, 'f'),
    fld("baseplateLb", "Baseplate weight, pounds", 32, 4, 'f'),
    fld("massLb", "Reaction-mass weight, pounds", 36, 4, 'f'),
    fld("startSecond", "The second the recording began", 40, 1, 'u'),
    fld("startMinute", "The minute", 41, 1, 'u'),
    fld("startHour", "The hour (UTC)", 42, 1, 'u'),
    fld("startDay", "The day", 43, 1, 'u'),
    fld("startMonth", "The month", 44, 1, 'u'),
    fld("startYear", "The year", 45, 2, 'u')]
  FrameFields = [
    fld("reference", "Reference", 0, 2, 'i'),
    fld("baseplateSetA", "Baseplate acceleration, set A", 2, 2, 'i'),
    fld("massSetA", "Reaction-mass acceleration, set A", 4, 2, 'i'),
    fld("baseplateSetB", "Baseplate acceleration, set B", 6, 2, 'i'),
    fld("massSetB", "Reaction-mass acceleration, set B", 8, 2, 'i'),
    fld("torqueMotor", "Torque-motor current", 10, 2, 'i'),
    fld("valve", "Valve displacement", 12, 2, 'i'),
    fld("massDisplacement", "Mass displacement", 14, 2, 'i'),
    fld("drive", "Drive output (probable)", 16, 2, 'i'),
    fld("cycleValue1", "Per-cycle value 1 (tracks drive / ground force)", 18, 4, 'f'),
    fld("cycleValue2", "Per-cycle value 2 (meaning unknown)", 22, 4, 'f')]

proc addRows(rows: var seq[FieldRow]; blockName: string; b: openArray[byte];
    blockOffset: int64; fields: openArray[Field]) =
  for f in fields:
    if f.at + f.size <= b.len:
      var (v, n) = ("", NaN)
      case f.kind
      of 's':
        for i in f.at ..< f.at + f.size:
          v.add(if b[i] in 32'u8 .. 126'u8: char(b[i]) else: '.')
      of 'u':
        let x = le(b, f.at, f.size)
        (v, n) = ($x, float64(x))
      of 'i':
        let x = i16(b, f.at)
        (v, n) = ($x, float64(x))
      else:
        let x = f32(b, f.at)
        (v, n) = ($x, float64(x))
      rows.add sigRow(blockName, f.name, f.words, v, n, blockOffset, b.len, f.at, f.size)

# ----------------------------------------------------------------- decode --

func whyNoFit(s: VibSweep): string =
  if s.crossings < 200:
    "the reference has " & $s.crossings & " zero crossings, and a linear-sweep fit needs " &
      "200: a pulse record, or a sweep too short"
  elif not s.residualCycles.isNaN and s.residualCycles > 0.05:
    "the reference does not fit a linear sweep (its largest residual is " &
      formatFloat(s.residualCycles, ffDecimal, 3) & " cycles)"
  else:
    "the reference does not fit a linear sweep"

proc decode*(bytes: openArray[byte]; name, path: string; choice: SignatureChoice;
    log: var DiagLog; pair = SignaturePair()): tuple[segy: seq[byte]; facts: SignatureFacts] =
  ## Decodes the bytes of the `.vib` file `name` at the interval `choice` says (500 us when
  ## it says none) and writes them as SEG-Y Rev 2.1 into memory, as the file `path`. Raises
  ## `SignatureError` in the library's words.
  let interval = if choice.intervalUs > 0: choice.intervalUs else: VibIntervalUs
  if not (interval > 0 and interval < Inf):
    raise newException(SignatureError, "the sample interval must be more than 0 us")
  var shot = VibShot()
  try:
    decodeInto(shot, bytes, allowIncomplete = true, sampleIntervalUs = interval,
      findTrigger = true)
  except VibFormatError as e:
    raise sigError(name, e.msg)
  except ValueError as e:
    raise sigError(name, e.msg)
  if shot.start.year > MaxYear:
    raise sigError(name, "its start date (the year " & $shot.start.year & ") is past the year " &
      $MaxYear & ", a time this program cannot hold: the file cannot mean it")
  shot.nameNumber = nameNumberOf(path)
  var paired = false
  if pair.path.len > 0:
    # the .dat of this sweep gives the clock time: its trigger, to the nanosecond (the frame
    # stays the estimate)
    let c = civilOf(pair.triggerNs)
    try:
      shot.setTrigger(VibTime(year: c.year, month: c.month, day: c.day, hour: c.hour,
        minute: c.minute, second: c.second, nanosecond: c.nanosecond))
      paired = true
    except ValueError:
      discard # a trigger the library does not take: the .vib stands alone
  var wopts = VibWriteOptions(cycleValues: true, groundForce: {vsA, vsB}, primary: vsB,
    timeAxis: (if choice.fromFirstFrame: vaRecord else: vaTrigger), units: vuCounts,
    traceOrder: voForces, vendorLayout: true)
  if paired:
    wopts.controllerSerial = pair.controller
    wopts.datFileNumber = nameNumberOf(pair.path)
  var o = SegyOutputOptions()
  try:
    o.text = textCards(shot, wopts)
    var w = openSeismicWriterBytes(o, path)
    w.addShotBlock(shot, wopts) # the library's shot block: the vendor maps decode it by name
    w.writeSegyTraces(shot, wopts, extHeader = true, major = 2)
    result.segy = w.finishBytes(log)
  except VibWriteError as e:
    raise sigError(name, "it cannot be written in memory: " & e.msg)
  except ValueError as e:
    raise sigError(name, "it cannot be written in memory: " & e.msg)
  except SegFormatError as e:
    raise sigError(name, "it cannot be written in memory: " & e.msg)
  let h = shot.header
  var f = SignatureFacts(kind: sgVib, info: infoOf(shot, path), choice: choice,
    intervalStated: false, forceChannels: false, groundForceGiven: true,
    masses: (float64(h.baseplateLb), float64(h.massLb), float64(h.holdDownLb)),
    sensitivities: (float64(h.sensitivity1), float64(h.sensitivity2)),
    calibrations: (float64(h.valveCal), float64(h.massCal)),
    unknown: (float64(h.unknown12), float64(h.unknown16)),
    endsInSweep: shot.endsInSweep,
    decodedAs: "SEG-Y Rev 2.1 in memory (no file written)")
  f.choice.intervalUs = interval
  if paired:
    f.pair = pair.path
    f.pairTriggerNs = pair.triggerNs
    f.info.controller = pair.controller
    f.info.serialFrom = sfPair
    f.info.vibrator = pair.vibrator
  for i, (n, code, unit) in Layout:
    f.traces.add SignatureTrace(name: n, short: Shorts[i], code: code, unit: unit)
  let fit = shot.sweep
  f.trigger = SignatureTrigger(source: trNone,
    clockFrom: (if paired and shot.triggerSource != tsNone: "the .dat of this sweep"
    else: "the second the recording began"), # (the library keeps the start second without a frame)
  timeZero: "first frame", crossings: fit.crossings, residualCycles: fit.residualCycles)
  if shot.triggerSource == tsEstimated:
    f.trigger.source = trEstimated
    f.trigger.frame = shot.triggerFrame
    f.trigger.sigmaFrames = shot.triggerSigmaFrames
    f.trigger.startHz = fit.startHz
    f.trigger.rateHzPerS = fit.rateHzPerS
    if not choice.fromFirstFrame: f.trigger.timeZero = "trigger"
  else:
    f.trigger.why = whyNoFit(fit)
  if shot.triggerSource == tsNone:
    f.notes.add name & ": no trigger found in the reference (" & f.trigger.why &
      "): t = 0 is the first frame."
  if not shot.complete:
    f.warnings.add name & ": the file ends " & $shot.tailBytes & " bytes into a frame (a " &
      "copy cut short, or a file still being written); its " & groupDigits(shot.frames) &
      " whole frames are shown."
  if shot.triggerSource == tsEstimated and choice.fromFirstFrame:
    f.notes.add name & ": t = 0 is the first frame, by your choice (the reference gives a " &
      "trigger at frame " & formatFloat(shot.triggerFrame, ffDecimal, 2) & ")."
  if shot.endsInSweep:
    f.warnings.add name & ": the record ends inside the sweep (a stopped recording). " &
      "Shown as recorded."
  f.rows.addRows("vibHeader", bytes.toOpenArray(0, VibHeaderBytes - 1), 0, HeaderFields)
  f.blocks.add RawBlock(blockName: "vibHeader", offset: 0, size: VibHeaderBytes,
    bytes: @(bytes.toOpenArray(0, VibHeaderBytes - 1)))
  f.rows.addRows("firstFrame", bytes.toOpenArray(VibHeaderBytes, VibHeaderBytes + VibFrameBytes - 1),
    VibHeaderBytes, FrameFields)
  f.blocks.add RawBlock(blockName: "firstFrame", offset: VibHeaderBytes,
    size: VibFrameBytes,
    bytes: @(bytes.toOpenArray(VibHeaderBytes, VibHeaderBytes + VibFrameBytes - 1)))
  result.facts = f

proc vibRefusal*(head: openArray[byte]; size: int64): string =
  ## Why a `.vib` of another kind, or one that starts as a signature record but breaks
  ## its header, is not decoded, in the library's words; "" for any other file.
  if not (isOtherVib(head) or isBrokenVib(head)): return ""
  try:
    discard parseVibInfo(head, size)
  except VibFormatError as e:
    result = e.msg
  except ValueError as e:
    result = e.msg
