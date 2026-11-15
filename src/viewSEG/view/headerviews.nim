## What the Headers window shows, as plain lines and tables: the Summary
## tab's lines (what the file is and the counts of the record shown, in
## plain words), the rows of the header tables, and the lines of a block's
## bytes. Made from `core` (a session's `facts`, its records), never from
## the toolkit, so that any frontend shows the same words.

import std/[math, os, strutils, times]
import parseSEG
import ../core/state

type
  SummaryLine* = object
    ## One line of the Summary tab: a value and what it is, or a heading.
    label*: string
    value*: string ## "" for a heading
    heading*: bool

func grouped*(n: int64): string =
  ## `n` with its thousands apart: "1 234 567".
  let digits = $abs(n)
  for i, c in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: result.add ' '
    result.add c
  if n < 0: result = "-" & result

func bytesText*(n: int64): string =
  ## A size in bytes, and in KiB, MiB or GiB past a thousand.
  const units = ["KiB", "MiB", "GiB", "TiB"]
  result = grouped(n) & (if n == 1: " byte" else: " bytes")
  var x = float64(n)
  var u = -1
  while x >= 1024 and u < units.high:
    x /= 1024
    inc u
  if u >= 0: result.add " (" & formatFloat(x, ffDecimal, 1) & " " & units[u] & ")"

func msText*(ms: float64): string =
  ## A time in ms in its shortest form; "" when not known.
  if ms.isNaN: "" else: exactText(ms) & " ms"

func gatherWord(k: GatherKind): string =
  case k
  of gkShot: "shot record"
  of gkReceiver: "receiver gather"
  of gkCmp: "CMP gather"
  of gkOffset: "common-offset gather"
  of gkUnknown, gkOther: "record"

func standardText(s: FileSummary): string =
  result = case s.standard
    of skSegy: "SEG-Y"
    of skSegd: "SEG-D"
    of skSeg2: "SEG-2"
    of skUnknown: "not recognised"
  if s.standard in {skSegy, skSegd}: result.add " revision " & $s.revision
  elif s.standard == skSeg2: result.add " revision " & $s.revision.major
  if s.mixedRevisions: result.add " (its records are of several revisions)"

proc add(lines: var seq[SummaryLine]; label, value: string) =
  if value.len > 0: lines.add SummaryLine(label: label, value: value)

proc heading(lines: var seq[SummaryLine]; label: string) =
  lines.add SummaryLine(label: label, heading: true)

func firstLine(text: string): string =
  let i = text.find('\n')
  result = (if i >= 0: text[0 ..< i] else: text).strip
  if result.len > 100: result = result[0 ..< 100] & "..."

proc summaryLines*(s: Session; gather: int): seq[SummaryLine] =
  ## The Summary tab of file `s` with its gather `gather` shown (-1 for
  ## none): the file, its format, its traces and timing, its coordinates,
  ## and the record shown with its counts (the Records window's), and for
  ## SEG-D that record's channel sets.
  template facts: untyped = s.facts
  let sm = facts.summary
  result.heading "File"
  result.add "Name", s.name
  result.add "Folder", s.path.parentDir
  if s.size >= 0: result.add "Size", bytesText(s.size)
  if s.modified != Time(): result.add "Modified", s.modified.local.format("yyyy-MM-dd HH:mm:ss")
  result.heading "Format"
  result.add "Standard", standardText(sm)
  if sm.standard in {skSegy, skSeg2}:
    result.add "Byte order", (if sm.byteOrder == boBig: "big-endian" else: "little-endian")
  if facts.textEncoding.len > 0: result.add "Textual header", facts.textEncoding
  if facts.extendedText.len > 0:
    result.add "Extended textual headers", $facts.extendedText.len
  if sm.formatCode >= 0:
    let name = formatName(sm.standard, sm.formatCode)
    result.add "Sample format", $sm.formatCode & (if name.len > 0: ": " & name else: "")
  elif sm.standard == skSegd:
    result.add "Sample format", "differs between records"
  result.add "Samples decodable", (if sm.decodable: "yes"
    else: "no: some traces are in a sample format that cannot be decoded")
  result.heading "Traces"
  result.add "Traces", grouped(sm.traceCount)
  result.add "Records", grouped(s.gathers.len) &
    (if sm.standard == skSegd: " (" & grouped(sm.recordCount) & " SEG-D records)" else: "")
  if sm.firstFieldRecord >= 0:
    let what = if sm.standard == skSegd: "File numbers" else: "Field records (FFID)"
    result.add what, (if sm.lastFieldRecord == sm.firstFieldRecord: $sm.firstFieldRecord
      else: $sm.firstFieldRecord & " to " & $sm.lastFieldRecord)
  result.add "Samples per trace", (if sm.samplesPerTrace >= 0: grouped(sm.samplesPerTrace)
    else: "differ between traces")
  result.add "Sample interval", (if sm.sampleIntervalUs.isNaN: "differs between " &
    (if sm.standard == skSegd: "channel sets" else: "traces")
    else: exactText(sm.sampleIntervalUs / 1000) & " ms")
  result.add "Record length", msText(sm.recordLengthMs)
  result.heading "Coordinates"
  result.add "Units", (case sm.coordinateUnits
    of cuUnknown: "not given"
    of cuMeters: "metres"
    of cuFeet: "feet"
    of cuLength: "length (metres or feet not said)"
    of cuArcSeconds: "arc seconds"
    of cuDegrees: "degrees"
    of cuDms: "degrees, minutes and seconds")
  result.add "Coordinate reference", (if facts.crs.len == 0: "none in the file"
    else: $sm.crsFormat & ": " & firstLine(facts.crs))
  if gather in 0 ..< s.records.len:
    let r = s.records[gather]
    result.heading "The record shown: " & $(gather + 1) & " of " & $s.records.len
    result.add "Kind", gatherWord(r.kind)
    if not r.record.isNaN: result.add "FFID", exactText(r.record)
    result.add "Source", station(r.srcLine, r.srcPoint)
    result.add "Receiver", station(r.rcvLine, r.rcvPoint)
    if not r.ensemble.isNaN: result.add "CDP", exactText(r.ensemble)
    result.add "Traces", $r.traces & " (from trace " & $(r.first + 1) & ")"
    result.add "Seismic", $r.seismic
    result.add "Auxiliary", $r.aux
    result.add "Dead", $r.dead
    result.add "Missing", (case r.missingSource
      of msSurvey: $r.plannedMissing & " of the " & $r.planned & " stations its X record in " &
        s.checkedAgainst & " plans"
      of msFile: $r.missing & " of the " & $r.declared & " seismic traces the file declares"
      of msNone: "not known (the file declares no count; load the relation file to check)")
    let rec = s.file.segdRecordOf(r.first)
    if rec >= 0:
      var sets = 0
      for c in facts.channelSets:
        if c.record == rec: inc sets
      if sets > 0:
        result.heading "Channel sets of the record shown (SEG-D record " & $(rec + 1) & ")"
        let rev3 = sm.revision.major >= 3
        for c in facts.channelSets:
          if c.record == rec:
            result.add "Set " & $c.number & (if c.scanType > 0: " (scan type " &
              $(c.scanType + 1) & ")" else: ""),
              channelTypeName(rev3, c.channelType) & ", " & $c.traceCount &
              (if c.traceCount == 1: " trace, " else: " traces, ") & $c.samplesPerTrace &
              " samples at " & msText(c.sampleIntervalUs / 1000) & ", " &
              exactText(c.startTimeMs) & " to " & msText(c.endTimeMs)
  for p in facts.problems:
    result.add "Not read", p

func summaryText*(lines: openArray[SummaryLine]): string =
  ## The lines as text, as Copy puts them on the clipboard: a heading on a
  ## line of its own, a value after its label and a tab.
  for l in lines:
    if l.heading:
      if result.len > 0: result.add '\n'
      result.add l.label & '\n'
    else: result.add l.label & '\t' & l.value & '\n'
