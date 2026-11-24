## What a slice built from header keys takes from its source's own headers, and what it
## says about itself. The keys of a trace (`TraceKeys`) carry the geometry and the time but
## no filter, gain or sensor facts, so these are read from the source trace an output trace
## was cut from (the segment holding its first sample) and written through the header
## overrides of the keys writer; the provenance lines go in the text header (SEG-Y) or the
## external header (SEG-D).
##
## What the source knows, and where the SEG-Y writer puts it (the same bytes in every
## revision, 0 to 2.1; the slice writes Rev 2.1), by source standard:
##
## | Fact | SEG-D source (channel set descriptor) | SEG-Y source (trace header) | SEG-Y field |
## |---|---|---|---|
## | low-cut frequency, slope | low-cut frequency, slope | bytes 149, 153 | `lowCutFreq`, `lowCutSlope` |
## | alias filter frequency, slope | alias filter frequency, slope | bytes 141, 143 | `aliasFilterFreq`, `aliasFilterSlope` |
## | high-cut frequency, slope | none | bytes 151, 155 | `highCutFreq`, `highCutSlope` |
## | notch frequency, slope | first notch (tenths of Hz, rounded to Hz); no slope | bytes 145, 147 | `notchFilterFreq`, `notchFilterSlope` |
## | gain type | gain control method: 3 fixed is 1, 8 binary is 2, 9 instantaneous floating is 3 | byte 119 | `gainType` |
## | instrument gain, initial gain | none | bytes 121, 123 | `instrumentGainConstant`, `instrumentInitialGain` |
## | sensor | sensor type: hydrophone 11, vertical 12, in-line 14, cross-line 13 | codes 11 to 14 | `traceIdCode` (the keys' `traceCode`) |
## | receiver position | the keys' group X, Y, elevation | likewise | written by the keys writer (`sliceKeys`) |
##
## No home in SEG-Y: a second and a third notch frequency, the filter phase and delay of a
## Rev 3 channel set, a gain control method that is not fixed, binary or floating (individual
## or ganged AGC, programmed gain), a sensor type with no code (5 and 9). In a SEG-D output
## built from keys the channel set descriptor has no field for any filter or gain value.
## A value that rounds to 0 or does not fit 16 bits is left out and said.
##
## Position: the keys writer always writes the coordinate units as length (1), whatever the
## source had; the units are one field of a trace, which the shot's coordinates share, so
## they are not copied from a source in degrees or seconds of arc.

import std/[math, options, strutils, unicode]
import parseSEG
import parseSEG/model/traceindex
import ./versions

type
  FactKind* = enum
    ## One fact of a source trace's recording, in the order the result names them.
    fkLowCutFreq = "low-cut filter frequency"
    fkLowCutSlope = "low-cut filter slope"
    fkAliasFreq = "alias filter frequency"
    fkAliasSlope = "alias filter slope"
    fkHighCutFreq = "high-cut filter frequency"
    fkHighCutSlope = "high-cut filter slope"
    fkNotchFreq = "notch filter frequency"
    fkNotchSlope = "notch filter slope"
    fkExtraNotches = "second and third notch filters"
    fkFilterPhase = "filter phase"
    fkFilterDelay = "filter delay"
    fkGainType = "gain type"
    fkGainMethod = "gain control method"
    fkGainConstant = "instrument gain"
    fkInitialGain = "initial gain"
    fkSensor = "sensor type"
    fkSensorOther = "sensor type without a SEG-Y code"

  Facts* = array[FactKind, float64] ## NaN: the source says nothing

  FillNotes* = object
    ## What the output traces took, and what they could not.
    written*: set[FactKind]
    noField*: set[FactKind] ## the output has no field for them
    notSet*: set[FactKind]
      ## the output's channel set has a field for them, which a writer building headers from
      ## keys does not set
    noFit*: set[FactKind] ## the output has the field but not for the value
    rounded*: bool ## a value was rounded to the whole number the field holds

  TraceFill* = object
    ## What one output trace takes: header overrides, and the trace identification code
    ## (0: the writer derives it from the status).
    overrides*: seq[HeaderOverride]
    traceCode*: int16

const
  SegyFields: array[FactKind, string] = ["trace.lowCutFreq", "trace.lowCutSlope",
    "trace.aliasFilterFreq", "trace.aliasFilterSlope", "trace.highCutFreq",
    "trace.highCutSlope", "trace.notchFilterFreq", "trace.notchFilterSlope", "", "", "",
    "trace.gainType", "", "trace.instrumentGainConstant", "trace.instrumentInitialGain", "",
    ""]
  FilterGain* = {fkLowCutFreq .. fkInitialGain} ## the facts that are filters or gain

func initFacts*(): Facts =
  for k in FactKind: result[k] = NaN

func has*(f: Facts; k: FactKind): bool {.inline.} = not f[k].isNaN

const ChannelSetFacts = {fkLowCutFreq, fkLowCutSlope, fkAliasFreq, fkAliasSlope,
  fkNotchFreq, fkExtraNotches, fkFilterPhase, fkFilterDelay, fkGainType, fkGainMethod}
  ## what a SEG-D channel set descriptor holds of the facts

proc put(f: var Facts; k: FactKind; v: float64) =
  ## Records `v` when a SEG-D source states a value (0, negative and invalid BCD mean none).
  if v.classify in {fcNormal, fcSubnormal} and v > 0: f[k] = v

proc putSigned(f: var Facts; k: FactKind; v: float64) =
  ## Records `v` when a SEG-Y source states a value: any non-zero one (a 16-bit field).
  if v.classify in {fcNormal, fcSubnormal}: f[k] = v

func segdSensorCode(sensor: uint8): int16 =
  ## The SEG-Y trace identification code of a SEG-D sensor type; 0 for none.
  case sensor
  of 1: 11
  of 2, 6: 12
  of 3, 7: 14
  of 4, 8: 13
  else: 0

func gainTypeOfSegd(code: int): int =
  ## The SEG-Y gain type of a SEG-D gain control method; 0 for none.
  case code
  of 3: 1
  of 8: 2
  of 9: 3
  else: 0

proc segdFacts(file: SeismicFile; trace: int; result: var Facts) =
  let e = file.traceEntry(trace)
  let (st, cs) = (int(e.scanType), e.channelSetIndex)
  template rec: untyped = file.index.segdRecords[int(e.record)]
  if st notin 0 ..< rec.scanTypes.len or cs < 0: return
  template scan: untyped = rec.scanTypes[st]
  var gain = 0
  case scan.layout
  of slRev2:
    if cs < scan.descriptors.len:
      let d = scan.descriptors[cs]
      result.put fkLowCutFreq, float64(d.lowCutFreq)
      result.put fkLowCutSlope, float64(d.lowCutSlope)
      result.put fkAliasFreq, float64(d.aliasFilterFreq)
      result.put fkAliasSlope, float64(d.aliasFilterSlope)
      result.put fkNotchFreq, float64(d.notch1Freq) / 10
      if d.notch2Freq > 0 or d.notch3Freq > 0: result[fkExtraNotches] = 1
      gain = int(d.gainControl)
  of slRev3:
    if cs < scan.descriptorsRev3.len:
      let d = scan.descriptorsRev3[cs]
      result.put fkLowCutFreq, float64(d.lowCutFilterFreq)
      result.put fkLowCutSlope, float64(d.lowCutFilterSlope)
      result.put fkAliasFreq, float64(d.aliasFilterFreq)
      result.put fkAliasSlope, float64(d.aliasFilterSlope)
      result.put fkNotchFreq, float64(d.notch1Freq)
      if d.notch2Freq > 0 or d.notch3Freq > 0: result[fkExtraNotches] = 1
      result.put fkFilterPhase, float64(d.filterPhase)
      result.put fkFilterDelay, float64(d.filterDelay)
      gain = int(d.channelGainControl)
  # a slope of 0 says the filter is out: its frequency is not a setting then
  for (freq, slope) in [(fkLowCutFreq, fkLowCutSlope), (fkAliasFreq, fkAliasSlope)]:
    if not result.has(slope): result[freq] = NaN
  if gain > 0:
    let t = gainTypeOfSegd(gain)
    if t > 0: result[fkGainType] = float64(t) else: result[fkGainMethod] = float64(gain)
  # the sensor type byte exists from Rev 2.0
  let sensor = if rec.revision.major >= 2: file.traceKeys(trace).sensorType else: 0'u8
  if sensor > 0:
    let code = segdSensorCode(sensor)
    if code > 0: result[fkSensor] = float64(code) else: result[fkSensorOther] = float64(sensor)

proc segyFacts(file: SeismicFile; trace: int; result: var Facts) =
  for k in FactKind:
    if SegyFields[k].len > 0:
      let v = file.findTraceField(trace, SegyFields[k])
      if v.isSome: result.putSigned k, v.get.toFloat
  let keys = file.traceKeys(trace)
  if keys.traceCodeRev in {tcrRev1, tcrRev2} and keys.traceCode in 11'i16 .. 14'i16:
    result[fkSensor] = float64(keys.traceCode)

proc sourceFacts*(file: SeismicFile; trace: int): Facts =
  ## What trace `trace` of `file` says of its filters, gain and sensor; nothing for a
  ## standard that has no such fields. Reads the trace's own headers.
  result = initFacts()
  case file.kind
  of skSegd: segdFacts(file, trace, result)
  of skSegy: segyFacts(file, trace, result)
  else: discard

proc segyFill*(facts: Facts; notes: var FillNotes): TraceFill =
  ## The overrides and code that write `facts` into a SEG-Y output trace; `notes` takes
  ## note of what was written and what has no field or no room.
  for k in FactKind:
    if facts.has(k):
      let v = facts[k]
      if k == fkSensor:
        result.traceCode = int16(v)
        notes.written.incl k
      elif SegyFields[k].len == 0: notes.noField.incl k
      else:
        let r = round(v)
        if r < -32768 or r > 32767 or r == 0: notes.noFit.incl k
        else:
          if abs(r - v) > 1e-6: notes.rounded = true
          result.overrides.add headerOverride(SegyFields[k], int64(r))
          notes.written.incl k

proc keysOnly*(facts: Facts; notes: var FillNotes) =
  ## Notes the facts of a source whose output is built from keys alone (SEG-D): the keys
  ## carry the sensor type, nothing else of these. The channel set has fields for most, which
  ## the writer does not set; the rest have none.
  for k in FactKind:
    if facts.has(k) and k notin {fkSensor, fkSensorOther}:
      if k in ChannelSetFacts: notes.notSet.incl k else: notes.noField.incl k

func names(s: set[FactKind]): string =
  for k in s:
    if result.len > 0: result.add ", "
    result.add $k

func fillLines*(notes: FillNotes; output: string): seq[string] =
  ## The sentences of the result for a slice built from keys; `output` names where the
  ## facts have no field ("SEG-Y revision 2.1", "SEG-D").
  if notes.written * FilterGain != {}:
    result.add "Filters and gain were taken from the recording's own headers."
  if fkSensor in notes.written:
    result.add "The sensor type of each trace was taken from the recording's own headers."
  if notes.rounded:
    result.add "Filter and gain values were rounded to the whole numbers the output's fields " &
      "hold."
  if notes.noFit != {}:
    result.add "Not written in the output: " & names(notes.noFit) &
      " (the value does not fit the field of " & output & ")."
  if notes.notSet != {}:
    result.add "Not written in the output: " & names(notes.notSet) &
      " (this SEG-D output's headers are built from the trace keys, which do not carry the " &
      "channel set's filter and gain settings)."
  if notes.noField != {}:
    result.add "Not written in the output: " & names(notes.noField) &
      " (no field for them in " & output & ")."

# Provenance

const
  CardWidth = 80
  CardPrefix = 4 ## "C 1 ": the writer's own prefix of a text card

type Provenance* = object
  lines*: seq[string] ## text cards' content (SEG-Y: the writer adds the card prefix)
  replaced*: int      ## characters of the names that the character set cannot hold

func holds(c: char; encoding: TextEncoding): bool =
  if c notin {' ' .. '~'}: return false
  result = true
  for p in checkTextHeader(@[$c], SegyRevision(major: 2, minor: 1), encoding):
    if p.kind == thfBadCharacter: result = false

func plain(name: string; encoding: TextEncoding; replaced: var int): string =
  ## `name` as a card can hold it: a character it cannot hold becomes "?".
  for r in name.runes:
    if r.int < 0x80 and holds(char(r.int), encoding): result.add char(r.int)
    else:
      result.add '?'
      inc replaced

func wrapped(text: string; width: int): seq[string] =
  ## `text` cut into lines of at most `width` characters, at a space where there is one,
  ## continuation lines indented by two.
  var rest = text
  var first = true
  while rest.len > 0:
    let room = if first: width else: width - 2
    var cut = rest.len
    if rest.len > room:
      cut = rest.rfind(' ', 0, room)
      if cut <= 0: cut = room
    let line = rest[0 ..< cut]
    result.add (if first: line else: "  " & line)
    rest = rest[cut .. ^1].strip(trailing = false)
    first = false

func startWords(startMs: float64): string =
  ## How the records' first samples lie to the shot time, as the shot log card says it.
  if startMs == 0: return "RECORDS START AT THE SHOT TIME"
  var n = $abs(startMs)
  if n.endsWith(".0"): n.setLen n.len - 2
  "FIRST SAMPLE " & n & " MS " & (if startMs < 0: "BEFORE" else: "AFTER") & " THE SHOT TIME"

proc sliceProvenance*(source, logName: string; shots: int; startMs: float64;
    encoding: TextEncoding): Provenance =
  ## The lines that say a file was sliced by this program, from `source` (a file name, not
  ## a path) at the `shots` of the log `logName`, the records' first samples `startMs` after
  ## the shot time. Plain ASCII; a longer line goes on in the
  ## next card.
  var replaced = 0
  let fromName = plain(source, encoding, replaced)
  let logWords = if logName.len > 0: " " & plain(logName, encoding, replaced) else: ""
  let width = CardWidth - CardPrefix
  result.lines.add "WRITTEN BY parseSEG " & PackageVersion
  result.lines.add wrapped("SLICED BY viewSEG " & ViewSEGVersion & " FROM " & fromName, width)
  result.lines.add wrapped("SHOT LOG" & logWords & ", " & $shots & " " &
    (if shots == 1: "SHOT" else: "SHOTS") & ", " & startWords(startMs), width)
  result.replaced = replaced

proc externalHeaderOf*(p: Provenance): seq[byte] =
  ## The provenance lines (all but the writer's own) as the whole 32-byte blocks of a SEG-D
  ## external header: ASCII, a line to each 80 bytes' row, spaces after.
  var text = ""
  for i in 1 ..< p.lines.len:
    text.add p.lines[i]
    text.add ' '.repeat(CardWidth - p.lines[i].len)
  let padded = (text.len + 31) div 32 * 32
  text.add ' '.repeat(padded - text.len)
  result = newSeq[byte](text.len)
  for i, c in text: result[i] = byte(c)
