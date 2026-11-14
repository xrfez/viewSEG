## The records of an open file, as the record list shows them: one row per
## gather (parseSEG's `gathers`), with what tells it apart, taken from its
## first seismic trace (its first trace when it has none): a shot's field
## record number (FFID) and source station, a receiver gather's receiver
## station, a CMP gather's CDP; and how many traces it holds.
##
## The rows are made once, on the open job's thread, so the list costs the
## UI thread nothing however many records a file has; the UI formats only
## the rows in view.

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

  RecordColumn* = enum
    ## The columns of the record list besides the record's place and size.
    rcRecord = "FFID"
    rcEnsemble = "CDP"
    rcSource = "Source"
    rcReceiver = "Receiver"

func known(x: float64): bool {.inline.} = not x.isNaN

proc recordRows*(f: SeismicFile; gathers: openArray[Gather]): seq[RecordRow] =
  ## A row for each of `gathers` of `f`. Reads the index only (the keys
  ## when the file was opened with them): call it on the thread that holds
  ## the file.
  result = newSeqOfCap[RecordRow](gathers.len)
  let keyed = f.index.keys.len == f.len
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
