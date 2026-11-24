## The pure first part of cutting a continuous gather by a shot log: the
## options, the shots in time order, the record numbers, the size of the
## output and the checks on the window. No file is read or written here.
##
## The output has one record per shot, holding the node's components as
## channels 1..C.

import std/[algorithm, math, options]
import processSEG/continuous/slice
import ./shotlog

type
  CutStandard* = enum
    csSegdRev3 ## SEG-D Rev 3.
    csSegy     ## SEG-Y.

  CutOptions* = object
    ## What to cut at each shot.
    recordMs*: float64 ## Record length, ms; a whole number of samples.
    startMs*: float64  ## Start relative to the shot time, ms; may be negative.
    align*: SliceAlign
    standard*: CutStandard

  CutShots* = object
    ## The timed shots of a log, in time order.
    shots*: seq[SliceShot]
    rows*: seq[int]      ## For each shot, the index of its row in the log.
    dropped*: int        ## Rows without a time.
    duplicateTimes*: int ## Shots with the time of the shot before them (kept).
    increasing*: bool    ## The file numbers strictly increase in time order.

const
  MaxRecordNumber* = 0xFF_FFFF    ## The writer's largest record number.
  MaxEndUs = float64(high(int32)) ## The writer's limit on a window end, µs.

func initCutOptions*(recordMs: float64, startMs = 0.0, align = saNearest,
    standard = csSegdRev3): CutOptions =
  ## Options for a record of `recordMs`.
  CutOptions(recordMs: recordMs, startMs: startMs, align: align, standard: standard)

func sliceShotOf*(shot: Shot): SliceShot =
  ## The planner's shot for a log row. The time is UTC, so it goes through
  ## `initSliceShot` and the exact microseconds are set on top; the GPS
  ## constructor would shift it by the leap seconds. A shot with no time
  ## gets time 0. A missing file number or value is NaN.
  let us = shot.timeUtcUs.get(0)
  let id =
    if shot.fileNumber.isSome: float64(shot.fileNumber.get)
    else: NaN
  let index =
    if shot.pointIndex.isSome and shot.pointIndex.get in 0'i64..255'i64:
      int16(shot.pointIndex.get)
    else: 0'i16
  result = initSliceShot(toPosixSeconds(us), id, shot.sourceLine, shot.shotPoint,
    shot.x, shot.y, shot.z, index)
  result.timeUs = us
  result.timeUsKnown = shot.timeUtcUs.isSome

func shotsInTime*(rows: openArray[Shot]): CutShots =
  ## The rows with a time, sorted by it (equal times keep the log order).
  ## Rows without a time are counted in `dropped`; equal times are kept and
  ## counted in `duplicateTimes`.
  result = CutShots(increasing: true)
  var keyed: seq[tuple[us: int64, row: int]] = @[]
  for i, r in rows:
    if r.timeUtcUs.isSome: keyed.add (r.timeUtcUs.get, i)
    else: inc result.dropped
  keyed.sort() # the row index breaks ties, so the log order is kept
  var order: seq[int] = @[]
  for k in keyed: order.add k.row
  var prevFile = NaN
  for n, i in order:
    let s = sliceShotOf(rows[i])
    if n > 0:
      if rows[order[n - 1]].timeUtcUs.get == rows[i].timeUtcUs.get:
        inc result.duplicateTimes
      if s.id.isNaN or prevFile.isNaN or not (s.id > prevFile):
        result.increasing = false
    elif s.id.isNaN:
      result.increasing = false
    prevFile = s.id
    result.shots.add s
    result.rows.add i

func recordNumbers*(shots: CutShots): tuple[numbers: seq[int], fromFileNumber: bool] =
  ## The record number of each shot: its file number when all are whole
  ## numbers within the writer's range and strictly increase in time order,
  ## else 1..N (`fromFileNumber` false).
  var ok = shots.increasing
  for s in shots.shots:
    if s.id.isNaN or s.id != round(s.id) or s.id < 0 or s.id > float64(MaxRecordNumber):
      ok = false
  result.fromFileNumber = ok
  result.numbers = newSeq[int](shots.shots.len)
  for i in 0 ..< result.numbers.len:
    result.numbers[i] = if ok: int(shots.shots[i].id) else: i + 1

func estimateBytes*(opts: CutOptions, shots, components, samplesPerTrace: int,
    withSourceStation, withSourceXY, withReceiverXY: bool): int64 =
  ## The size of the output, one record per shot of `components` traces.
  ## SEG-D Rev 3: per record 96 bytes of general headers, 96 of channel-set
  ## descriptor, 32 for a source station and 96 for a source position; per
  ## trace 20 bytes, 32 per header extension (2, or 5 with a receiver
  ## position) and 4 per sample. CRS blocks are not counted. SEG-Y: 3600
  ## bytes, then per trace 240 and 4 per sample.
  let traces = int64(shots) * int64(components)
  let samples = int64(samplesPerTrace)
  case opts.standard
  of csSegy:
    result = 3600'i64 + traces * (240'i64 + samples * 4)
  of csSegdRev3:
    var record = 96'i64 + 96
    if withSourceStation: record += 32
    if withSourceXY: record += 96
    let exts = if withReceiverXY: 5'i64 else: 2'i64
    result = int64(shots) * record + traces * (20'i64 + exts * 32 + samples * 4)

func checkOptions*(opts: CutOptions, dtMs: float64): string =
  ## "" when the options can be cut at sample interval `dtMs`, else a
  ## sentence saying what is wrong.
  if dtMs.isNaN or dtMs <= 0:
    result = "The sample interval is not known."
  elif opts.recordMs.isNaN or opts.startMs.isNaN or opts.recordMs.classify == fcInf or
      opts.startMs.classify in {fcInf, fcNegInf}:
    result = "The start and the length must be numbers."
  elif opts.recordMs <= 0:
    result = "The record length must be more than zero."
  else:
    let n = opts.recordMs / dtMs
    if abs(n - round(n)) > 1e-6 * max(1.0, abs(n)):
      result = "The record length must be a whole number of samples (" & $dtMs &
        " ms each)."
    elif (opts.startMs + opts.recordMs) * 1000 > MaxEndUs:
      result = "The window ends too late for the file: its end must be under 2147 s."
