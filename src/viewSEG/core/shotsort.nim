## The order the Shot log grid lists its rows in when it is sorted by one or more columns.
## The sort is a list of the log's row numbers: it never changes the log or a row's
## number, so a selection, an edit or a Problems entry keeps pointing at the log's own
## row. It is stable (rows that tie keep their file order, whichever way a key sorts),
## and a row with no value in a key's column comes last, whichever way the key sorts.
## A number column sorts by value, Time (UTC) and GPSTB by instant, anything else by
## text without regard to case; a user defined column whose every filled cell is a
## number sorts by value too.
##
## A `SortBuild` reads the keys' cells a batch of rows at a time, so a long log never
## holds a frame; the last batch sorts. It is kept by its caller, which makes a new one
## when the log, its revision or the sort changes.

import std/[algorithm, options, parseutils, strutils]
import shotlog

type
  RowKind* = enum
    rkNumber, rkInstant, rkText

  RowKey* = object
    col*: int
    kind*: RowKind
    descending*: bool

  SortBuild* = ref object
    ## A sort under way.
    rows: int
    comma: bool
    keys: seq[RowKey]
    at: int
    nums: seq[seq[float64]] ## per key; NaN for a cell with no value
    times: seq[seq[int64]]
    haveTime: seq[seq[bool]]
    texts: seq[seq[string]]
    order*: seq[int32]      ## the sorted rows, once `done`
    done*: bool

func rowKindOf*(map: ShotLogMap; col: int): RowKind =
  ## How column `col` sorts, by its role: numbers by value, the time columns by instant.
  let role = if col < map.roles.len: map.roles[col] else: crText
  case role
  of crSequence, crFileNumber, crSailLine, crSourceLine, crShotPoint, crPointIndex,
      crSourceDepth, crWaterDepth, crX, crY, crZ, crUphole: rkNumber
  of crGpsMicros: rkInstant
  of crTime:
    var gps = false
    for r in map.roles:
      if r == crGpsMicros: gps = true
    # the row's one instant is GPSTB's when the log has that column
    if gps: rkText else: rkInstant
  else: rkText

proc newSortBuild*(rows: int; keys: openArray[RowKey]; decimalComma = false): SortBuild =
  ## A sort of `rows` rows by `keys`, the first key first. No keys: the file order.
  result = SortBuild(rows: rows, keys: @keys, comma: decimalComma)
  let k = keys.len
  result.nums = newSeq[seq[float64]](k)
  result.times = newSeq[seq[int64]](k)
  result.haveTime = newSeq[seq[bool]](k)
  result.texts = newSeq[seq[string]](k)
  for i, key in keys:
    case key.kind
    of rkNumber: result.nums[i] = newSeq[float64](rows)
    of rkInstant:
      result.times[i] = newSeq[int64](rows)
      result.haveTime[i] = newSeq[bool](rows)
    of rkText: result.texts[i] = newSeq[string](rows)
  if k == 0:
    result.order = newSeq[int32](rows)
    for r in 0 ..< rows: result.order[r] = int32(r)
    result.done = true

proc number(text: string; decimalComma: bool): float64 =
  ## The value of a cell, or NaN.
  let t = text.strip
  if t.len == 0: return NaN
  var u = t
  if decimalComma: u = u.replace(',', '.')
  var v = 0.0
  if parseutils.parseFloat(u, v) == u.len: v else: NaN

func isMissing(text: string; map: ShotLogMap): bool =
  if text.strip.len == 0: return true
  for s in map.sentinels:
    if text == s: return true

proc compareRows(b: SortBuild; x, y: int32): int =
  for i, key in b.keys:
    var c = 0
    var missingX, missingY = false
    case key.kind
    of rkNumber:
      missingX = b.nums[i][x] != b.nums[i][x]
      missingY = b.nums[i][y] != b.nums[i][y]
      if not missingX and not missingY: c = cmp(b.nums[i][x], b.nums[i][y])
    of rkInstant:
      missingX = not b.haveTime[i][x]
      missingY = not b.haveTime[i][y]
      if not missingX and not missingY: c = cmp(b.times[i][x], b.times[i][y])
    of rkText:
      missingX = b.texts[i][x].len == 0
      missingY = b.texts[i][y].len == 0
      if not missingX and not missingY: c = cmpIgnoreCase(b.texts[i][x], b.texts[i][y])
    if missingX or missingY:
      if missingX and missingY: continue
      return if missingX: 1 else: -1 # empty cells last, in both directions
    if c != 0: return if key.descending: -c else: c
  cmp(x, y) # a tie keeps the file order

proc finish(b: SortBuild) =
  # a text key whose filled cells are all numbers sorts by value
  for i, key in b.keys.mpairs:
    if key.kind != rkText: continue
    var all = true
    var filled = 0
    var vals = newSeq[float64](b.rows)
    for r in 0 ..< b.rows:
      if b.texts[i][r].len == 0:
        vals[r] = NaN
        continue
      inc filled
      vals[r] = number(b.texts[i][r], b.comma)
      if vals[r] != vals[r]:
        all = false
        break
    if all and filled > 0:
      key.kind = rkNumber
      b.nums[i] = vals
      b.texts[i] = @[]
  b.order = newSeq[int32](b.rows)
  for r in 0 ..< b.rows: b.order[r] = int32(r)
  b.order.sort(proc (x, y: int32): int = compareRows(b, x, y))
  b.done = true

proc advance*(b: SortBuild; log: ShotLog; view: ShotView; map: ShotLogMap; batch: int):
    bool {.discardable.} =
  ## Reads the cells of the next `batch` rows of `log`; true once the sort is done. The
  ## last batch sorts.
  if b.done: return true
  let stop = min(b.rows, b.at + max(1, batch))
  for r in b.at ..< stop:
    for i, key in b.keys:
      case key.kind
      of rkNumber:
        let text = log.cell(r, key.col)
        b.nums[i][r] = if isMissing(text, map): NaN else: number(text, map.decimalComma)
      of rkInstant:
        let us = if r < view.rows.len: view.rows[r].timeUtcUs else: none(int64)
        if us.isSome:
          b.times[i][r] = us.get
          b.haveTime[i][r] = true
      of rkText:
        let text = log.cell(r, key.col)
        b.texts[i][r] = if isMissing(text, map): "" else: text
  b.at = stop
  if b.at >= b.rows: b.finish()
  b.done

func progress*(b: SortBuild): int =
  ## Rows read so far.
  b.at
