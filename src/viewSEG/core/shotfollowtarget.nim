## The shot a loaded shot log follows: the trace under the pointer, the
## selected signature, or the selected open file, by time. Each loaded log
## has its own answer.
##
## Each loaded log's `ShotIndex` is built on the shot-log job and kept here.
## Time zero is not on the keys a tile already holds, so a trace query takes
## it from the trace's keys (`timeZeroOfRecord`). A SEG-D file or a SEG-Y
## opened with keys has them stored or in its indexed headers. A SEG-Y
## without stored keys is skipped, so the UI thread does not read one.

import std/[math, options]
import parseSEG
import recordtime, shotfollow, sigtypes

type
  ShotFollowSource* = enum
    sfNone = "none"           ## nothing to follow, or no shot log
    sfPointer = "pointer"     ## the trace under the pointer
    sfFile = "file"           ## the selected open file's first trace
    sfSignature = "signature" ## the selected signature

  ShotFollowAnswer* = object
    ## The last follow of one loaded log. `revision` goes up only when
    ## `source` or `match` of this log changes.
    source*: ShotFollowSource
    match*: ShotMatch
    revision*: int
    logId*: int
      ## The loaded log this answer is for, or -1 when none was asked.

  HeldIndex = object
    id: int
    index: ref ShotIndex
    answer: ShotFollowAnswer
    ready: bool
    logRev: int

  ShotFollow* = object
    ## Per loaded shot log, its index and its own last answer.
    held: seq[HeldIndex]
    hover, hoverSession, hoverKeys, chosenSession, chosenKeys, filesRev, sessions: int
    inputsReady: bool

func slot(f: ShotFollow; id: int): int =
  for i, h in f.held:
    if h.id == id: return i
  -1

proc keep*(f: var ShotFollow; id: int; index: ref ShotIndex) =
  ## Keeps `index` for loaded log `id`, replacing one already kept. A nil
  ## index drops `id`. That log's next answer is worked out again.
  let at = f.slot(id)
  if index == nil:
    if at >= 0: f.held.delete(at)
    return
  if at >= 0:
    f.held[at].index = index
    f.held[at].ready = false
  else:
    f.held.add HeldIndex(id: id, index: index)

proc drop*(f: var ShotFollow; id: int) =
  ## Drops the index and answer of loaded log `id`.
  let at = f.slot(id)
  if at >= 0: f.held.delete(at)

proc dropAll*(f: var ShotFollow) =
  ## Drops every kept index and answer.
  f.inputsReady = false
  f.held.setLen 0

proc indexOf*(f: ShotFollow; id: int): ref ShotIndex =
  ## The index kept for `id`, or nil.
  let at = f.slot(id)
  if at >= 0: f.held[at].index else: nil

func unchanged*(f: ShotFollow; id, logRev, hover, hoverSession, hoverKeys, chosenSession,
    chosenKeys, filesRev, sessions: int): bool =
  ## Whether log `id` at `logRev` was already answered from these inputs.
  if not f.inputsReady or f.hover != hover or f.hoverSession != hoverSession or
      f.hoverKeys != hoverKeys or f.chosenSession != chosenSession or
      f.chosenKeys != chosenKeys or f.filesRev != filesRev or f.sessions != sessions:
    return false
  let at = f.slot(id)
  at >= 0 and f.held[at].ready and f.held[at].logRev == logRev

func lastAnswer*(f: ShotFollow; id: int): ShotFollowAnswer =
  ## The last answer stored for `id`, or none.
  let at = f.slot(id)
  if at >= 0: f.held[at].answer else: ShotFollowAnswer(source: sfNone, logId: id)

proc publish*(f: var ShotFollow; id, logRev: int; source: ShotFollowSource;
    matched: ShotMatch; hover, hoverSession, hoverKeys, chosenSession, chosenKeys,
    filesRev, sessions: int): ShotFollowAnswer =
  ## Stores `source` and `matched` for log `id`, and bumps that log's revision
  ## only when they differ from the answer already stored for it. A change of
  ## the shared inputs marks every stored answer stale.
  let sameInputs = f.inputsReady and f.hover == hover and f.hoverSession == hoverSession and
    f.hoverKeys == hoverKeys and f.chosenSession == chosenSession and
    f.chosenKeys == chosenKeys and f.filesRev == filesRev and f.sessions == sessions
  if not sameInputs:
    for i in 0 ..< f.held.len: f.held[i].ready = false
    f.hover = hover
    f.hoverSession = hoverSession
    f.hoverKeys = hoverKeys
    f.chosenSession = chosenSession
    f.chosenKeys = chosenKeys
    f.filesRev = filesRev
    f.sessions = sessions
    f.inputsReady = true
  var at = f.slot(id)
  if at < 0:
    f.held.add HeldIndex(id: id)
    at = f.held.high
  if f.held[at].answer.source != source or
      f.held[at].answer.match.rule != matched.rule or
      f.held[at].answer.match.row != matched.row or
      f.held[at].answer.match.count != matched.count:
    inc f.held[at].answer.revision
    f.held[at].answer.source = source
    f.held[at].answer.match = matched
  f.held[at].answer.logId = id
  f.held[at].ready = true
  f.held[at].logRev = logRev
  f.held[at].answer

proc noMatch*(): ShotMatch {.inline.} =
  ## No row.
  ShotMatch(rule: mrNone, row: -1, count: 0)

proc matched*(index: ref ShotIndex; q: ShotQuery): ShotMatch {.raises: [].} =
  ## `match` of `index`, or no row when `index` is nil.
  if index == nil: return noMatch()
  match(index[], q)

proc microsecondClock(f: SeismicFile; local: int; k: TraceKeys): bool {.raises: [].} =
  ## Whether trace `local`'s clock is good to a microsecond, given its keys `k`. A SEG-Y is when
  ## its stored keys say `toHeaderSubsec`. A SEG-D is when the record is
  ## revision 3. A whole-second clock, or a file opened without keys, is not.
  ## Reads no file.
  if local < 0 or local >= f.len: return false
  case f.kind
  of skSegy: f.hasKeys and k.timeOrigin == toHeaderSubsec
  of skSegd:
    if local >= f.index.entries.len: return false
    let rec = int(f.index.entries[local].record)
    rec >= 0 and rec < f.index.segdRecords.len and f.index.segdRecords[rec].isRev3
  else:
    false

proc queryOfTrace*(f: SeismicFile; local: int; k: TraceKeys): ShotQuery {.raises: [].} =
  ## A trace's query from its keys `k` (as `f.traceKeys(local)` gives them): time zero, exact
  ## when the file's clock is good to a microsecond, plus the trace's record number, source line,
  ## source point and source index. A whole-second clock is not exact. A SEG-Y without stored
  ## keys has no time and no numbers, so the UI thread does not read one.
  var t = none(int64)
  var n = (record: NaN, line: NaN, point: NaN, index: 0)
  if local in 0 ..< f.len:
    if f.kind in {skSegd, skSegy} and (f.kind == skSegd or f.hasKeys):
      t = timeZeroOfRecord(k, f.kind)
    if f.hasKeys: n = (k.record, k.srcLine, k.srcPoint, int(k.srcIndex))
  queryOfKeys(t, microsecondClock(f, local, k), n.record, n.line, n.point, n.index)

proc traceQuery*(f: SeismicFile; local: int): ShotQuery {.raises: [].} =
  ## A trace's query (`queryOfTrace`) from the keys the file holds; a trace out of range or
  ## whose keys cannot be had asks with no time and no numbers.
  var k = initTraceKeys()
  if local in 0 ..< f.len and (f.kind != skSegy or f.hasKeys):
    try: k = f.traceKeys(local)
    except ValueError: discard
  queryOfTrace(f, local, k)

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
