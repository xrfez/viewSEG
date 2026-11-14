## The cursor readout in the status bar: fields the user chooses and orders,
## each formatted from a `Pick` (`core/pick`). A value that is not known (a
## NaN key, the cursor off the traces) is shown blank, never as "NaN" or 0.
##
## The defaults (`DefaultReadout`): the time at the cursor, trace and
## channel, receiver line and point, source line and point, field record
## (FFID), offset, amplitude, and the shot time (the record's UTC time; the
## cursor's time within the record is the first field). Every trace key can
## be added.

import std/[math, strutils, times]
import parseSEG
import pick

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

func known(v: float64): bool {.inline.} = v.classify notin {fcNan, fcInf, fcNegInf}

func numberText*(v: float64): string =
  ## A header value: whole numbers without decimals, others with up to two;
  ## "" when unknown.
  if not known(v): ""
  elif v == floor(v) and abs(v) < 1e15: $int64(v)
  else: formatFloat(v, ffDecimal, 2).strip(leading = false, chars = {'0'}).strip(
    leading = false, chars = {'.'})

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
    of rfComponent: (if k.component > 0: $k.component else: "")
    of rfStatus:
      case k.status
      of tsUnknown: ""
      of tsLive: "live"
      of tsDead: "dead"
      of tsAuxiliary: "auxiliary"
    of rfTime, rfSample, rfAmplitude: "" # handled above

func cleaned*(fields: openArray[ReadoutField]): seq[ReadoutField] =
  ## `fields` in their order, each once.
  for f in fields:
    if f notin result: result.add f
