## The shot a loaded shot log follows: the trace under the pointer, the
## selected signature, or the selected open file, by time.
##
## Each loaded log's `ShotIndex` is built on the shot-log job and kept here.
## Time zero is not on the keys a tile already holds, so a trace query takes
## it from the open file's index (`recordTimeZeroUs`). That reads no file
## for SEG-D, nor for a SEG-Y opened with keys. A SEG-Y without stored keys
## is skipped, so the UI thread does not read one.

import std/[math, options]
import parseSEG
import shotfollow, sigtypes

type
  ShotFollowSource* = enum
    sfNone = "none"           ## nothing to follow, or no shot log
    sfPointer = "pointer"     ## the trace under the pointer
    sfFile = "file"           ## the selected open file's first trace
    sfSignature = "signature" ## the selected signature

  ShotFollowAnswer* = object
    ## The last follow. `revision` goes up only when `source` or `match` changes.
    source*: ShotFollowSource
    match*: ShotMatch
    revision*: int

  HeldIndex = object
    id: int
    index: ref ShotIndex

  ShotFollow* = object
    ## Per loaded shot log, its index, and the last answer.
    held: seq[HeldIndex]
    answer: ShotFollowAnswer
    ready: bool
    hover, hoverSession, hoverKeys, chosenSession, chosenKeys, filesRev, sessions, logId,
      logRev: int

proc keep*(f: var ShotFollow; id: int; index: ref ShotIndex) =
  ## Keeps `index` for loaded log `id`, replacing one already kept. A nil
  ## index drops `id`. The next answer is worked out again.
  f.ready = false
  var at = -1
  for i, h in f.held:
    if h.id == id: at = i
  if index == nil:
    if at >= 0: f.held.delete(at)
    return
  if at >= 0: f.held[at].index = index
  else: f.held.add HeldIndex(id: id, index: index)

proc drop*(f: var ShotFollow; id: int) =
  ## Drops the index of loaded log `id`.
  f.ready = false
  var at = -1
  for i, h in f.held:
    if h.id == id: at = i
  if at >= 0: f.held.delete(at)

proc dropAll*(f: var ShotFollow) =
  ## Drops every kept index.
  f.ready = false
  f.held.setLen 0

proc indexOf*(f: ShotFollow; id: int): ref ShotIndex =
  ## The index kept for `id`, or nil.
  for h in f.held:
    if h.id == id: return h.index

func unchanged*(f: ShotFollow; hover, hoverSession, hoverKeys, chosenSession, chosenKeys,
    filesRev, sessions, logId, logRev: int): bool {.inline.} =
  ## Whether the last answer was made from these same inputs.
  f.ready and f.hover == hover and f.hoverSession == hoverSession and
    f.hoverKeys == hoverKeys and f.chosenSession == chosenSession and
    f.chosenKeys == chosenKeys and f.filesRev == filesRev and f.sessions == sessions and
    f.logId == logId and f.logRev == logRev

func answer*(f: ShotFollow): ShotFollowAnswer {.inline.} =
  ## The last answer, including when `unchanged` is false.
  f.answer

proc publish*(f: var ShotFollow; source: ShotFollowSource; matched: ShotMatch; hover,
    hoverSession, hoverKeys, chosenSession, chosenKeys, filesRev, sessions, logId,
    logRev: int): ShotFollowAnswer =
  ## Stores `source` and `matched`, and bumps the revision only when they differ
  ## from the answer already stored.
  if not f.ready or f.answer.source != source or f.answer.match.rule != matched.rule or
      f.answer.match.row != matched.row or f.answer.match.count != matched.count:
    inc f.answer.revision
    f.answer.source = source
    f.answer.match = matched
  f.ready = true
  f.hover = hover
  f.hoverSession = hoverSession
  f.hoverKeys = hoverKeys
  f.chosenSession = chosenSession
  f.chosenKeys = chosenKeys
  f.filesRev = filesRev
  f.sessions = sessions
  f.logId = logId
  f.logRev = logRev
  f.answer

proc timeZero(f: SeismicFile; local: int): Option[int64] {.raises: [].} =
  ## Time zero of trace `local`, or none. Skips a SEG-Y without stored keys,
  ## which would read the file.
  if local < 0 or local >= f.len: return none(int64)
  let kind = f.kind
  if kind == skSegy and not f.hasKeys: return none(int64)
  if kind notin {skSegd, skSegy}: return none(int64)
  try:
    f.recordTimeZeroUs(local)
  except ValueError, IOError, SegTruncatedError:
    none(int64)

proc numbersOf(f: SeismicFile; local: int): tuple[record, line, point: float64; index: int]
    {.raises: [].} =
  ## Record number, source line, source point and source index, from stored
  ## keys. Unknown when the file was opened without them.
  result = (NaN, NaN, NaN, 0)
  if local < 0 or local >= f.len or not f.hasKeys: return
  try:
    let k = f.traceKeys(local)
    result = (k.record, k.srcLine, k.srcPoint, int(k.srcIndex))
  except ValueError:
    discard

proc noMatch*(): ShotMatch {.inline.} =
  ## No row.
  ShotMatch(rule: mrNone, row: -1, count: 0)

proc matched*(index: ref ShotIndex; q: ShotQuery): ShotMatch {.raises: [].} =
  ## `match` of `index`, or no row when `index` is nil.
  if index == nil: return noMatch()
  match(index[], q)

proc microsecondClock(f: SeismicFile; local: int): bool {.raises: [].} =
  ## Whether trace `local`'s clock is good to a microsecond. A SEG-Y is when
  ## its stored keys say `toHeaderSubsec`. A SEG-D is when the record is
  ## revision 3. A whole-second clock, or a file opened without keys, is not.
  ## Reads no file.
  if local < 0 or local >= f.len: return false
  case f.kind
  of skSegy:
    if not f.hasKeys: return false
    try:
      f.traceKeys(local).timeOrigin == toHeaderSubsec
    except ValueError:
      false
  of skSegd:
    if local >= f.index.entries.len: return false
    let rec = int(f.index.entries[local].record)
    if rec < 0 or rec >= f.index.segdRecords.len: return false
    f.index.segdRecords[rec].isRev3
  else:
    false

proc traceQuery*(f: SeismicFile; local: int): ShotQuery {.raises: [].} =
  ## A trace's query: time zero, exact when the file's clock is good to a
  ## microsecond, plus the trace's record number, source line, source point
  ## and source index. A whole-second clock is not exact.
  let t = timeZero(f, local)
  let n = numbersOf(f, local)
  queryOfKeys(t, microsecondClock(f, local), n.record, n.line, n.point, n.index)

proc fitsInt(n: int64): bool {.inline.} =
  n > 0 and n <= int64(high(int))

proc signatureQuery*(info: SweepInfo; pairTriggerNs, pairFileNumber: int64): ShotQuery
    {.raises: [].} =
  ## A signature's query. A paired `.vib` uses the pair's trigger and file
  ## number. A lone start second uses the matcher's 0.2 to 1.5 s window.
  let paired = info.kind == sgVib and pairTriggerNs != 0
  let trigger = if paired: pairTriggerNs else: info.triggerNs
  let start = info.kind == sgVib and not paired and info.timeIsStart
  var fileNo = 0
  if paired and fitsInt(pairFileNumber): fileNo = int(pairFileNumber)
  elif not paired and fitsInt(info.fileNumber): fileNo = int(info.fileNumber)
  var index = 0
  if fitsInt(info.sourceIndex): index = int(info.sourceIndex)
  queryOfSweep(trigger, start, fileNo, float64(info.line), float64(info.station), index)
