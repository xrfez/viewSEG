## The records of an open file, as the record list shows them: one row per
## gather (parseSEG's `gathers`), with what tells it apart, taken from its
## first seismic trace (its first trace when it has none): a shot's field
## record number (FFID) and source station, a receiver gather's receiver
## station, a CMP gather's CDP; how many traces it holds, seismic and
## auxiliary apart, and how many of its seismic traces the file marks dead;
## and how many are missing from its patch (`missing`):
##
## - against what the file itself declares for the record (`declared`): a
##   SEG-D record's seismic channel sets (their channel counts), a SEG-Y
##   file's data traces per ensemble (binary header, where it is set);
## - against the survey once a relation file (SPS X) is loaded: the
##   stations its X record plans for the shot that have no trace in the
##   record (processSEG's `recordCompleteness`; `planned`, `plannedMissing`,
##   filled by a job, `surveyjobs.checkWork`), which then takes precedence.
##
## Where nothing says what was expected, `missing` is -1 (an empty cell,
## never 0).
##
## The rows are made once, on the open job's thread, from the index alone
## (no sample is read), so the list costs the UI thread nothing however many
## records a file has; the UI formats only the rows in view.

import std/math
import parseSEG

type
  RecordRow* = object
    ## One gather of a file.
    kind*: GatherKind
    first*: int                  ## its first trace
    traces*: int                 ## how many traces it holds
    record*: float64             ## the FFID; NaN when not known
    ensemble*: float64           ## the CDP; NaN when not known
    srcLine*, srcPoint*: float64 ## NaN when not known
    rcvLine*, rcvPoint*: float64
    seismic*: int                ## its seismic traces
    aux*: int                    ## its auxiliary traces
    dead*: int                   ## its seismic traces the file marks dead
    declared*: int = -1
      ## seismic traces the file declares for it; -1 when it does not say
    planned*: int = -1
      ## stations its X record plans for it (`recordCompleteness`); -1 when
      ## no relation file was checked, or none plans it
    plannedMissing*: int = -1 ## of those, the stations it has no trace of
    unlisted*: int = -1 ## its traces at stations the plan does not list; -1 when not planned
    duplicates*: int = -1 ## its stations recorded more than once; -1 when not planned

  RecordColumn* = enum
    ## The columns of the record list besides the record's place and size.
    rcRecord = "FFID"
    rcEnsemble = "CDP"
    rcSource = "Source"
    rcReceiver = "Receiver"

  MissingSource* = enum
    ## What a record's missing traces are counted against.
    msNone = "nothing"
    msFile = "the file's own count"
    msSurvey = "the survey's relation file"

func known(x: float64): bool {.inline.} = not x.isNaN

func missingSource*(r: RecordRow): MissingSource =
  ## What `missing` counts against: the relation file when it planned the
  ## record, else the file's declared count, else nothing.
  if r.planned >= 0: msSurvey
  elif r.declared >= 0: msFile
  else: msNone

func missing*(r: RecordRow): int =
  ## The record's traces missing from its patch: the planned stations with
  ## no trace, else the declared seismic traces it does not hold (none when
  ## it holds as many or more); -1 when nothing says what was expected.
  case r.missingSource
  of msSurvey: r.plannedMissing
  of msFile: max(0, r.declared - r.seismic)
  of msNone: -1

func seismicSet(rec: SegdRecord; channelType: int): bool {.inline.} =
  ## Whether a channel set of `channelType` holds seismic traces, as parseSEG
  ## tells them apart (Rev 1/2: 1; Rev 3: 0x10 and 0x11).
  if rec.isRev3: channelType in [0x10, 0x11] else: channelType == 1

func declaredSeismic(rec: SegdRecord): int =
  ## The seismic traces a SEG-D record's channel set descriptors announce.
  for st, s in rec.scanTypes:
    case s.layout
    of slRev2:
      for cs, c in s.descriptors:
        if c.channelCount > 0 and rec.seismicSet(rec.channelType(st, cs)):
          result += c.channelCount
    of slRev3:
      for cs, c in s.descriptorsRev3:
        if rec.seismicSet(rec.channelType(st, cs)): result += int(c.channelsInSet)

proc recordRows*(f: SeismicFile; gathers: openArray[Gather]): seq[RecordRow] =
  ## A row for each of `gathers` of `f`. Reads the index only (the keys
  ## when the file was opened with them): call it on the thread that holds
  ## the file.
  result = newSeqOfCap[RecordRow](gathers.len)
  let keyed = f.index.keys.len == f.len
  let perEnsemble = if f.kind == skSegy:
      int(f.index.segy.binary.effectiveDataTracesPerEnsemble) else: 0
  for g in gathers:
    var row = RecordRow(kind: g.kind, first: g.traces.a, traces: g.traces.len, record: NaN,
      ensemble: NaN, srcLine: NaN, srcPoint: NaN, rcvLine: NaN, rcvPoint: NaN)
    if keyed and g.traces.len > 0:
      var t = g.traces.a
      while t < g.traces.b and not isSeismic(f.index, t): inc t
      if not isSeismic(f.index, t): t = g.traces.a
      # Only what the gather's kind holds constant tells records apart: a
      # shot's FFID and source, a receiver gather's receiver, a CMP's CDP.
      let k = f.index.keys[t]
      case g.kind
      of gkShot:
        row.record = k.record
        (row.srcLine, row.srcPoint) = (k.srcLine, k.srcPoint)
      of gkReceiver: (row.rcvLine, row.rcvPoint) = (k.rcvLine, k.rcvPoint)
      of gkCmp: row.ensemble = k.ensemble
      of gkOffset: discard
      of gkUnknown, gkOther: # what the keys cannot tell apart: as a shot
        row.record = k.record
        (row.srcLine, row.srcPoint) = (k.srcLine, k.srcPoint)
    # its traces, seismic, auxiliary and dead; the SEG-D records they are in
    var lastRecord = -1
    for t in g.traces:
      if isSeismic(f.index, t):
        inc row.seismic
        if keyed and f.index.keys[t].status == tsDead: inc row.dead
      else:
        inc row.aux
      if f.kind == skSegd:
        let r = int(f.index.entries[t].record)
        if r != lastRecord and r in 0 ..< f.index.segdRecords.len:
          lastRecord = r
          row.declared = max(row.declared, 0) + declaredSeismic(f.index.segdRecords[r])
    if perEnsemble > 0: row.declared = perEnsemble
    result.add row

func columnsOf*(rows: openArray[RecordRow]): set[RecordColumn] =
  ## The columns some row has a value for.
  for r in rows:
    if r.record.known: result.incl rcRecord
    if r.ensemble.known: result.incl rcEnsemble
    if r.srcLine.known or r.srcPoint.known: result.incl rcSource
    if r.rcvLine.known or r.rcvPoint.known: result.incl rcReceiver

func findRecord*(rows: openArray[RecordRow]; ffid: float64): int =
  ## The first row whose FFID is `ffid`; -1 when none is.
  for i, r in rows:
    if r.record == ffid: return i
  -1

func station*(line, point: float64): string =
  ## "1:1001", "1001" with no line, "" with neither.
  func num(x: float64): string =
    if x == round(x) and abs(x) < 1e15: $int64(x) else: $x
  if line.known and point.known: num(line) & ":" & num(point)
  elif point.known: num(point)
  elif line.known: num(line) & ":"
  else: ""
