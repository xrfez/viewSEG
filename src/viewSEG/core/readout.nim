## The cursor readout in the status bar: fields the user chooses and orders,
## each formatted from a `Pick` (`core/pick`). A value that is not known (a
## NaN key, the cursor off the traces) is shown blank, never as "NaN" or 0.
##
## The defaults (`DefaultReadout`): the time at the cursor, trace and
## channel, receiver line and point, source line and point, field record
## (FFID), offset, amplitude, and the shot time (the record's UTC time; the
## cursor's time within the record is the first field). Every trace key can
## be added, and the raw amplitude: the sample as the file has it, before
## polarity, edits, processing and gain (off by default; while it is on, the
## tiles carry their raw samples too, `ReaderRequest.raw`). Whatever the fields, the readout says when the trace under the
## pointer is dead in the file, killed or its polarity reversed (`editNote`),
## and, for a trace that is not seismic data, which trace identification code it
## has, in words ("vibrator baseplate (19)").

import std/[math, options, strutils, times]
import parseSEG
import components, edits, pick, sensors, sigtypes, traceids

type
  ReadoutField* = enum
    rfTime = "time"                   ## the cursor's time in the record
    rfTrace = "trace"                 ## the trace's number in its file, from 1
    rfChannel = "channel"
    rfReceiver = "receiver"           ## receiver line / point
    rfSource = "source"               ## source line / point
    rfRecord = "FFID"                 ## field record
    rfOffset = "offset"
    rfAmplitude = "amplitude"         ## as displayed, after processing and gain
    rfRawAmplitude = "raw amplitude"  ## as the file has it, before everything (off by default)
    rfShotTime = "shot time"          ## the record's UTC time
    rfCursorUtc = "UTC at the cursor" ## the shot time plus the cursor's time
    rfSample = "sample"               ## the nearest sample's number, from 1
    rfEnsemble = "CDP"
    rfInline = "inline"
    rfCrossline = "crossline"
    rfSourceXY = "source x, y"
    rfReceiverXY = "receiver x, y"
    rfMidpointXY = "midpoint x, y"
    rfSourceZ = "source elevation"
    rfReceiverZ = "receiver elevation"
    rfComponent = "component"
    rfStatus = "trace status"         ## live, dead or auxiliary
    rfTraceId = "trace ID code"       ## the SEG-Y code in words: "vibrator baseplate (19)"
    rfChannelSet = "channel set"      ## SEG-D: its number and type: "2 · signature, filtered"

const
  DefaultReadout* = [rfTime, rfTrace, rfChannel, rfReceiver, rfSource, rfRecord, rfOffset,
    rfAmplitude, rfShotTime]
    ## The status bar's fields until the user chooses others.

func caption*(f: ReadoutField): string =
  ## A field's short name, as it stands before its value in the status bar.
  case f
  of rfTime: "t"
  of rfTrace: "trace"
  of rfChannel: "chan"
  of rfReceiver: "rcv"
  of rfSource: "src"
  of rfRecord: "FFID"
  of rfOffset: "offset"
  of rfAmplitude: "amp"
  of rfRawAmplitude: "raw"
  of rfShotTime: "shot"
  of rfCursorUtc: "UTC"
  of rfSample: "sample"
  of rfEnsemble: "CDP"
  of rfInline: "inline"
  of rfCrossline: "xline"
  of rfSourceXY: "src x,y"
  of rfReceiverXY: "rcv x,y"
  of rfMidpointXY: "mid x,y"
  of rfSourceZ: "src z"
  of rfReceiverZ: "rcv z"
  of rfComponent: "comp"
  of rfStatus: "status"
  of rfTraceId: "id"
  of rfChannelSet: "set"

func known(v: float64): bool {.inline.} = v.classify notin {fcNan, fcInf, fcNegInf}

func numberText*(v: float64): string =
  ## A header value: whole numbers without decimals, others with up to two;
  ## "" when unknown.
  if not known(v): ""
  elif v == floor(v) and abs(v) < 1e15: $int64(v)
  else: formatFloat(v, ffDecimal, 2).strip(leading = false, chars = {'0'}).strip(
    leading = false, chars = {'.'})

func numberChars*(v: float64): int =
  ## The length of `numberText(v)`; a whole number's is counted, not made.
  if not known(v): result = 0
  elif v == floor(v) and abs(v) < 1e15:
    var n = abs(int64(v))
    result = if v < 0: 2 else: 1
    while n >= 10:
      n = n div 10
      inc result
  else: result = numberText(v).len

func significant*(v: float64; digits = 4): string =
  ## `v` to `digits` significant digits, without trailing zeros ("0.04123",
  ## "1.235e+04", "2"); "" when unknown.
  if not known(v): return ""
  result = formatFloat(v, ffDefault, digits)
  let e = result.find('e')
  var mantissa = if e >= 0: result[0 ..< e] else: result
  let exponent = if e >= 0: result[e .. ^1] else: ""
  if '.' in mantissa:
    mantissa = mantissa.strip(leading = false, chars = {'0'}).strip(leading = false,
      chars = {'.'})
  result = mantissa & exponent

func pair(a, b: float64; sep: string): string =
  ## "a<sep>b"; the known one alone; "" when neither is known.
  if known(a) and known(b): numberText(a) & sep & numberText(b)
  elif known(b): numberText(b)
  elif known(a): numberText(a) & sep & "?"
  else: ""

proc utcText*(seconds: float64): string =
  ## UTC POSIX seconds as a date and time to the millisecond; "" when
  ## unknown.
  if not known(seconds) or abs(seconds) > 1e11: return ""
  fromUnixFloat(seconds).utc.format("yyyy-MM-dd HH:mm:ss'.'fff")

const
  MissingScaleFields =
    "SEG-D: the channel set's descale multiplier (Rev 2: the MP factor); SEG-Y: the " &
    "trace weighting factor; SEG-2: DESCALING_FACTOR"

func sensitivityBase(unit: AmplitudeUnit): string =
  ## The quantity a file's sensitivity is per, in words.
  case unit
  of auVelocity: "m/s"
  of auAcceleration: "m/s²"
  of auPressure: "Pa"
  else: "unit"

proc convertRaw*(p: var Pick; table: SensorTable; want: AmplitudeIn; imperial: bool) =
  ## Sets what the raw amplitude of `p` says (`rawText`, `rawTip`) when it is read in volts or
  ## physical units (`want`): the sample as the file has it, converted with its file's own
  ## scale and the sensor of its component, with a readable prefix (and inches when
  ## `imperial`), or the words for what is missing: never a guessed number. Reads no file.
  p.rawText = ""
  p.rawTip = ""
  if want == aiCounts or not p.inside or not p.found or p.raw.isNaN: return
  if not p.hasScale:
    p.rawText = "not converted for this view"
    p.rawTip = "This view's samples are not the file's counts (a correlated view, say), so " &
      "they are not converted."
    return
  let plan = initCalibrationPlan(table.calibrationOf(
    if want == aiVolts: ctVolts else: ctPhysical))
  let s = scaleSample(plan, p.keys, p.scale, float64(p.raw), want)
  let peak = if p.binned > 1: " (peak of " & $p.binned & ")" else: ""
  case s.kind
  of skCounts: discard
  of skKept:
    p.rawText = significant(p.raw) & " counts" & peak
    p.rawTip = "A dead or auxiliary trace without a descale is shown as recorded."
  of skValue:
    let (number, unit) = s.scaledParts(imperial)
    let sensor = s.unit != auVolt # volts name no sensor
    let fromFile = sensor and s.source == ssFile
    p.rawText = significant(number) & " " & unit & (if fromFile: " (file)" else: "") & peak
    p.rawTip = "The file's sample " & significant(p.raw) & " converted " &
      (if not sensor: "to volts at the recorder's input with the file's own descale"
        elif not fromFile: "with the file's own descale and the sensor typed for " &
          componentName(s.component)
        elif p.scale.physical: "with the file's own descale: its headers say the samples " &
          "are already in " & unit & "; none is typed for " & componentName(s.component) &
          " in Project > Sensors"
        else: "with the sensitivity in the file's headers (" &
          significant(p.scale.sensitivity) & " V per " & sensitivityBase(p.scale.unit) & "); " &
          "none is typed for " & componentName(s.component) & " in Project > Sensors") &
      "; flat band only."
    let typed = table.get(s.component)
    if s.conflict and typed.isSome:
      let row = typed.get
      p.rawTip.add (if fromFile:
        " The file's headers differ from the sensor typed (" & significant(row.value) & " " &
          $row.unit & "): the file's was used."
      else:
        " The file's headers give " & (if p.scale.physical: "samples already physical"
          else: significant(p.scale.sensitivity) & " V per " &
            sensitivityBase(p.scale.unit)) & ", which differs: the typed " &
          significant(row.value) & " " & $row.unit & " was used.")
  of skNoVolts, skNoSensor, skNotFitting:
    p.rawText = s.problemText
    p.rawTip = s.problemTip(MissingScaleFields)

proc text*(p: Pick; f: ReadoutField): string =
  ## Field `f` of the readout at `p`, without its caption; "" when the
  ## value is not known.
  let k = p.keys
  if not p.inside: return ""
  case f
  of rfTime: (if known(p.at.tMs): formatFloat(p.at.tMs, ffDecimal, 1) & " ms" else: "")
  of rfSample: (if p.sample >= 0: $(p.sample + 1) else: "")
  of rfAmplitude:
    if p.amplitude.isNaN: ""
    elif p.binned > 1: significant(p.amplitude) & " (peak of " & $p.binned & ")"
    else: significant(p.amplitude)
  of rfRawAmplitude:
    if p.raw.isNaN: ""
    elif p.rawText.len > 0: p.rawText
    elif p.binned > 1: significant(p.raw) & " (peak of " & $p.binned & ")"
    else: significant(p.raw)
  else:
    if not p.found: return ""
    case f
    of rfTrace: (if p.trace >= 0: $(p.trace + 1) else: "")
    of rfChannel: numberText(k.channel)
    of rfReceiver: pair(k.rcvLine, k.rcvPoint, " / ")
    of rfSource: pair(k.srcLine, k.srcPoint, " / ")
    of rfRecord: numberText(k.record)
    of rfOffset: numberText(k.offset)
    of rfShotTime: utcText(k.time)
    of rfCursorUtc: (if known(p.at.tMs): utcText(k.time + p.at.tMs / 1000) else: "")
    of rfEnsemble: numberText(k.ensemble)
    of rfInline: numberText(k.inline)
    of rfCrossline: numberText(k.crossline)
    of rfSourceXY: pair(k.srcX, k.srcY, ", ")
    of rfReceiverXY: pair(k.rcvX, k.rcvY, ", ")
    of rfMidpointXY: pair(k.cmpX, k.cmpY, ", ")
    of rfSourceZ: numberText(k.srcZ)
    of rfReceiverZ: numberText(k.rcvZ)
    of rfComponent: (if componentOf(k) > 0: $componentOf(k) else: "")
    of rfStatus:
      case k.status
      of tsUnknown: ""
      of tsLive: "live"
      of tsDead: "dead"
      of tsAuxiliary: "auxiliary"
    of rfTraceId: (if p.channelSet.len > 0 and k.traceCode != 0: p.channelSet & " (" &
        $k.traceCode & ")"
      else: traceIdText(int(k.traceCode), k.status != tsUnknown))
    of rfChannelSet: fullName(p.channelSet)
    of rfTime, rfSample, rfAmplitude, rfRawAmplitude: "" # handled above

func joinGroupsOf*(f: ReadoutField): set[JoinGroup] =
  ## The groups of a trace's keys field `f` shows: what a geometry join may
  ## have given it.
  case f
  of rfReceiver: {jgReceiverStation}
  of rfSource: {jgSourceStation}
  of rfOffset: {jgDerived}
  of rfSourceXY: {jgSourceXy}
  of rfReceiverXY: {jgReceiverXy}
  of rfMidpointXY: {jgDerived}
  of rfSourceZ: {jgSourceZ}
  of rfReceiverZ: {jgReceiverZ}
  of rfComponent: {jgComponent}
  else: {}

func joined*(p: Pick; f: ReadoutField): bool =
  ## Whether the value field `f` shows at `p` was given by a geometry join
  ## (not by the trace's header).
  p.inside and p.found and (p.joined * joinGroupsOf(f)) != {}

func editNote*(p: Pick): string =
  ## What the readout says of the trace at `p` beyond its fields: "dead"
  ## when the file marks it dead (it is drawn blank), then its edits,
  ## "killed", "polarity reversed", each after a comma; "" for none (or no
  ## trace). A trace that is not seismic data and is not dead (an auxiliary
  ## one, or one with a code the standard does not know) says its
  ## identification code first: "vibrator baseplate (19)".
  if not (p.inside and p.found): return ""
  if p.keys.status == tsDead: result = "dead"
  elif p.keys.status in {tsAuxiliary, tsUnknown} and p.keys.traceCode != 0:
    result = if p.channelSet.len > 0: fullName(p.channelSet) & " (" & $p.keys.traceCode & ")"
             else: traceIdText(int(p.keys.traceCode), p.keys.status != tsUnknown)
  for (edit, word) in [(teKilled, "killed"), (teReversed, "polarity reversed"),
      (teExcluded, "excluded from the plot's filters")]:
    if edit in p.edits: result.add (if result.len > 0: ", " else: "") & word
  if p.filterNote.len > 0: result.add (if result.len > 0: ", " else: "") & p.filterNote
  if p.shiftNote.len > 0: result.add (if result.len > 0: ", " else: "") & p.shiftNote

func cleaned*(fields: openArray[ReadoutField]): seq[ReadoutField] =
  ## `fields` in their order, each once.
  for f in fields:
    if f notin result: result.add f
