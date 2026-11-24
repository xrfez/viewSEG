## The file list as a table: the rows the filter lets through, in the order
## the user sorted the table by (name in natural order, type, size or date,
## either way), each cell as text; and stepping from the chosen file to the
## next or previous seismic file's row, as the arrow keys do. Toolkit-neutral: a frontend
## draws the rows it has room for. The rows follow the list's changes
## (`FileList.changes`): a scan's batch, or a file that appears, grows or
## goes while the folder is watched, is merged into the rows there are.

import std/[algorithm, math, options, os, strutils, tables, times]
import ../core/[filelist, recordingkind, sigtypes]
import ./recordingwords

type
  FileColumn* = enum
    fcName = "Name"
    fcType = "Type"
    fcSize = "Size"
    fcModified = "Modified"
    fcFolder = "Folder"         ## the subfolders below the folder listed; shown when they are included
    fcTrigger = "Trigger (UTC)" ## signature files: the trigger, or the second a `.vib` began
    fcController = "Controller"
    fcVibrator = "Vibrator"
    fcLine = "Line"
    fcStation = "Station"
    fcShot = "Shot"
    fcSweepId = "Sweep id"
    fcLength = "Length"
    fcState = "State"
    fcPair = "Pair"
    fcForce = "Force avg %"
    fcThd = "THD max %"
    fcLimits = "Limits"
    fcKind = "Kind"
      ## shot, continuous or time-sliced receiver gather; shown after Type (ImGui matches a
      ## saved column by the hash of its label, not by its number: the place here is free)

  SweepFilter* = object
    ## What the Files window's tick and drop-downs ask of the signature files.
    hide*: bool             ## "Signature files" is off: they are left out of the table
    controller*: int64 = -1 ## only this controller's; -1 for all
    vibrator*: int = -1     ## only this vibrator's; -1 for all

  SweepFacts* = object
    ## What a row shows of a signature file: its own header's facts, and for a `.vib` the
    ## `.dat` of its sweep's where the pair has them.
    info*: SweepInfo
    triggerNs*: int64
    triggerFromPair*: bool ## `triggerNs` is the pair's `.dat`'s trigger
    controllerFrom*: SerialFrom
    pair*: string ## the partner's path; "" for none

  SweepCell* = object
    ## One cell of a signature column.
    text*: string
    tip*: string
    muted*, warn*: bool


  FileOrder* = object
    ## How the table is sorted.
    column*: FileColumn
    descending*: bool

  FileTable* = object
    ## The rows shown: indices into the list's entries.
    rows*: seq[int]
    gen: uint64       ## the listing, filter and order the rows were made for
    entriesRev: int
    filter: string
    words: seq[string]
    order: FileOrder
    sweep: SweepFilter
    pairsRev: int
    made: bool
    rowsRev: int      ## bumped whenever `rows` change
    touched: seq[int] ## `follow`'s own buffer
    chosen: tuple[path: string; row, rowsRev: int]
      ## the row last found for a path
    rebuilt: int      ## how often the rows were made from scratch

const SweepColumns* = {fcTrigger .. fcLimits}
  ## the columns of a signature file's facts, offered when the list holds one

const kindRank = block:
  ## Each kind's place when the types are sorted by the names shown.
  var names: seq[(string, FileKind)]
  for k in FileKind: names.add ($k, k)
  names.sort()
  var rank: array[FileKind, int]
  for i, (_, k) in names: rank[k] = i
  rank

func kindRankOf(e: FileEntry): int =
  ## Each kind's place when the kinds are sorted by the words shown: a file with none first,
  ## then those not known ("?").
  let k = e.recordingOf
  if k.isNone: (if e.kindState == ksNotKnown: 1 else: 0)
  else:
    case k.get
    of rkReceiverContinuous: 2
    of rkShotGather: 3
    of rkReceiverSliced: 4

func cmpEntries(a, b: FileEntry; column: FileColumn): int =
  ## By `column` alone: 0 when equal there.
  case column
  of fcName: 0
  of fcType: cmp(kindRank[a.kind], kindRank[b.kind])
  of fcKind: cmp(kindRankOf(a), kindRankOf(b))
  of fcSize: cmp(a.size, b.size)
  of fcModified: cmp(a.modified, b.modified)
  of fcFolder: naturalCmp(a.folder, b.folder)
  of fcTrigger: cmp(sweepKey(a), sweepKey(b))
  of fcController: cmp(a.sweep.controller, b.sweep.controller)
  of fcVibrator: cmp(a.sweep.vibrator, b.sweep.vibrator)
  of fcLine: cmp(a.sweep.line, b.sweep.line)
  of fcStation: cmp(a.sweep.station, b.sweep.station)
  of fcShot: cmp(a.sweep.shotId, b.sweep.shotId)
  of fcSweepId: cmp(a.sweep.sweepId, b.sweep.sweepId)
  of fcLength: cmp(float64(a.sweep.samples) * a.sweep.intervalUs,
    float64(b.sweep.samples) * b.sweep.intervalUs)
  of fcState: cmp(ord(not a.sweep.complete), ord(not b.sweep.complete))
  of fcPair: 0
  of fcForce: cmp(a.sweep.qc.forceAvgPct, b.sweep.qc.forceAvgPct)
  of fcThd: cmp(a.sweep.qc.thdMaxPct, b.sweep.qc.thdMaxPct)
  of fcLimits: cmp(card(a.sweep.qc.limits), card(b.sweep.qc.limits))

func sweepFacts*(list: FileList; e: FileEntry): SweepFacts =
  ## What a row shows of `e`: its own facts, and the pair's `.dat`'s for a `.vib` that has one.
  result = SweepFacts(info: e.sweep, triggerNs: e.sweep.triggerNs,
    controllerFrom: e.sweep.serialFrom, pair: list.pairs.getOrDefault(e.path))
  if e.kind == fkVib and result.pair.len > 0:
    let at = list.find(result.pair)
    if at >= 0 and list.entries[at].kind == fkDat:
      let d = list.entries[at].sweep
      result.info.controller = d.controller
      result.info.vibrator = d.vibrator
      result.info.qc = d.qc
      result.controllerFrom = sfPair
      result.triggerNs = d.triggerNs
      result.triggerFromPair = true

func passes(list: FileList; e: FileEntry; f: SweepFilter): bool =
  ## Whether the signature drop-downs and the tick let `e` through.
  let sig = e.kind in SignatureFileKinds
  if sig and f.hide: return false
  if f.controller >= 0 or f.vibrator >= 0:
    if not sig: return false
    let w = sweepFacts(list, e)
    if f.controller >= 0 and (w.controllerFrom == sfNone or w.info.controller != f.controller):
      return false
    if f.vibrator >= 0 and w.info.vibrator != f.vibrator: return false
  true

func cmpRows(list: FileList; order: FileOrder; a, b: int): int {.inline.} =
  ## The order of entries `a` and `b` in the table. The entries are in
  ## natural order of their names, so an entry's index breaks a tie by name.
  result = cmpEntries(list.entries[a], list.entries[b], order.column)
  if result == 0: result = cmp(a, b)
  if order.descending: result = -result

proc rebuild(t: var FileTable; list: FileList) =
  ## Every row again: the entries the filter lets through, sorted.
  t.rows.setLen 0
  for i, e in list.entries:
    if e.matches(t.words) and passes(list, e, t.sweep): t.rows.add i
  if t.order.column != fcName or t.order.descending:
    # By address: a closure that named `list` would hold a copy of every entry.
    let entries = addr list
    let order = t.order
    t.rows.sort(proc (a, b: int): int = cmpRows(entries[], order, a, b))

proc dropRow(t: var FileTable; i: int) =
  ## Takes the row of entry `i` out, if there is one.
  let r = t.rows.find(i)
  if r >= 0: t.rows.delete(r)

proc follow(t: var FileTable; list: FileList; changes: openArray[EntryChange]) =
  ## Brings the rows up to the list after `changes`, which came after the
  ## rows were last made: the rows of the entries the changes left alone
  ## keep their order (only their indices move), and the entries added or
  ## changed are sorted alone and merged in. A row moves only when its entry
  ## changed in what the table sorts by.
  let moves = t.order.column in {fcType, fcKind, fcSize, fcModified, fcFolder}
  t.touched.setLen 0
  for c in changes:
    case c.kind
    of ecAppended:
      for i in c.at ..< c.at + c.count: t.touched.add i
    of ecInserted:
      for r in t.rows.mitems:
        if r >= c.at: inc r
      for x in t.touched.mitems:
        if x >= c.at: inc x
      t.touched.add c.at
    of ecRemoved:
      t.dropRow(c.at)
      for r in t.rows.mitems:
        if r > c.at: dec r
      var k = 0
      while k < t.touched.len:
        if t.touched[k] == c.at: t.touched.delete(k)
        else:
          if t.touched[k] > c.at: dec t.touched[k]
          inc k
    of ecChanged:
      if moves and c.at notin t.touched:
        t.dropRow(c.at)
        t.touched.add c.at
  # The indices are now the list's: the new rows, sorted, merged in.
  var added = newSeqOfCap[int](t.touched.len)
  for i in t.touched:
    if i notin added and list.entries[i].matches(t.words) and
        passes(list, list.entries[i], t.sweep): added.add i
  if added.len == 0: return
  let entries = addr list
  let order = t.order
  added.sort(proc (a, b: int): int = cmpRows(entries[], order, a, b))
  if t.rows.len == 0 or cmpRows(list, order, t.rows[^1], added[0]) < 0:
    t.rows.add added # the usual case: a scan's batch, by name
    return
  # Merged from the back, in place.
  var (r, a) = (t.rows.high, added.high)
  t.rows.setLen t.rows.len + added.len
  var w = t.rows.high
  while a >= 0:
    if r >= 0 and cmpRows(list, order, t.rows[r], added[a]) > 0:
      t.rows[w] = t.rows[r]
      dec r
    else:
      t.rows[w] = added[a]
      dec a
    dec w

proc update*(t: var FileTable; list: FileList; filter: string; order: FileOrder;
    sweep = SweepFilter()) =
  ## Makes the rows again when the listing, the filter or the order changed
  ## since the last call; follows the entries' changes in the rows it has
  ## (`FileList.changes`) when only they did; otherwise does nothing, so it
  ## can run every frame. Making the rows allocates nothing per file, and a
  ## scan's batch or a file that appears costs a pass over the rows, not a
  ## sort of them.
  let wholly = t.sweep != sweep or (sweep.controller >= 0 and t.pairsRev != list.pairsRev)
  if t.made and t.gen == list.gen and t.filter == filter and t.order == order and not wholly:
    if t.entriesRev == list.entriesRev: return
    let missed = list.entriesRev - t.entriesRev
    if missed > 0 and missed <= list.changes.len:
      t.follow(list, list.changes.toOpenArray(list.changes.len - missed, list.changes.high))
      t.entriesRev = list.entriesRev
      inc t.rowsRev
      return
  t.gen = list.gen
  t.entriesRev = list.entriesRev
  if t.filter != filter or not t.made:
    t.filter = filter
    t.words = filterWords(filter)
  t.order = order
  t.sweep = sweep
  t.pairsRev = list.pairsRev
  t.made = true
  t.rebuild(list)
  inc t.rebuilt
  inc t.rowsRev

func rebuilds*(t: FileTable): int {.inline.} =
  ## How often `update` made the rows from scratch (a sort of them all),
  ## rather than following the list's changes (for tests).
  t.rebuilt

func rowOf*(t: FileTable; list: FileList; path: string): int =
  ## The row showing `path`; -1 when it is not shown.
  for r, i in t.rows:
    if list.entries[i].path == path: return r
  -1

proc chosenRow*(t: var FileTable; list: FileList; path: string): int =
  ## `rowOf` for the frame: the row found last, while the rows and the path
  ## are the same (a folder of 100 000 files would compare as many paths
  ## each frame).
  if t.chosen.rowsRev != t.rowsRev or t.chosen.path != path:
    t.chosen = (path, t.rowOf(list, path), t.rowsRev)
  t.chosen.row

func stepped*(t: FileTable; list: FileList; current: string; delta: int): string =
  ## The seismic file `delta` seismic files' rows after `current` (before
  ## it, for a negative `delta`), stopping at the first and last; survey
  ## files are passed by (they are loaded into the survey, not shown). The
  ## first seismic row (the last, stepping back) when `current` is not
  ## shown; "" when no seismic file is.
  let r = t.rowOf(list, current)
  let dir = if delta >= 0: 1 else: -1
  template seismic(row: int): bool = list.entries[t.rows[row]].kind.isSeismic
  if r < 0:
    var i = if dir > 0: 0 else: t.rows.high
    while i in 0 .. t.rows.high:
      if seismic(i): return list.entries[t.rows[i]].path
      i += dir
    return ""
  var (at, left, i) = (r, abs(delta), r + dir)
  while left > 0 and i in 0 .. t.rows.high:
    if seismic(i):
      at = i
      dec left
    i += dir
  list.entries[t.rows[at]].path

func limitsText(q: SweepQc): string =
  for l in q.limits: result.add $l

func lengthText(i: SweepInfo): string =
  if i.samples > 0 and i.intervalUs > 0: secondsWords(float64(i.samples) * i.intervalUs / 1e6)
  else: ""

func sweepCell*(list: FileList; e: FileEntry; column: FileColumn; timeOnly = false): SweepCell =
  ## What `column`, one of `SweepColumns`, shows of signature file `e` (empty cells for any
  ## other file, and for what a kind does not give). Reads nothing but the list.
  if e.kind notin SignatureFileKinds: return
  let w = sweepFacts(list, e)
  let i = w.info
  let own = e.sweep
  if own.problem.len > 0:
    if column == fcState:
      result = SweepCell(text: own.problem, warn: true,
        tip: e.name & " holds no readable sweep: " & own.problem & ". It is listed, and a " &
          "click says why it cannot be shown.")
    return
  case column
  of fcTrigger:
    if e.kind == fkDat:
      result = SweepCell(text: timeText(own.triggerNs, 3), tip: timeText(own.triggerNs, 9) &
        " UTC")
      if timeOnly: result.text = result.text[11 .. ^1]
    elif w.triggerFromPair:
      result = SweepCell(text: timeText(w.triggerNs, 3), tip: timeText(w.triggerNs, 9) &
        " UTC, from the .dat of this sweep")
      if timeOnly: result.text = result.text[11 .. ^1]
    else:
      result = SweepCell(text: "began " & timeText(own.triggerNs, 0)[11 .. ^1], muted: true,
        tip: "a .vib file states only the second its recording began; the trigger is 0.2 to " &
          "1.5 s after it")
  of fcController:
    if w.controllerFrom != sfNone:
      result.text = intToStr(int(i.controller), 4)
      result.tip = case w.controllerFrom
        of sfFile: "from the file"
        of sfFolder: "from the folder name, not in the file"
        of sfPair: "from the .dat of this sweep"
        of sfNone: ""
  of fcVibrator:
    if i.vibrator > 0: result.text = $i.vibrator
  of fcLine:
    if e.kind == fkDat and own.line > 0: result.text = $own.line
  of fcStation:
    if e.kind == fkDat and own.station > 0: result.text = $own.station
  of fcShot:
    if e.kind == fkDat and own.shotId > 0: result.text = $own.shotId
  of fcSweepId:
    if e.kind == fkDat and own.sweepId > 0: result.text = $own.sweepId
  of fcLength:
    result.text = lengthText(own)
    if e.kind == fkVib: result.tip = "the frames of the file at the interval in force, the " &
      "pre-trigger included"
  of fcState:
    if e.kind == fkDat and not own.complete:
      let at = float64(own.samples) * own.intervalUs / 1e6
      let full = float64(own.declared) * own.intervalUs / 1e6
      result = SweepCell(text: "stopped " & formatFloat(at, ffDecimal, 1) & " s", warn: true,
        tip: "the recording stopped after " & secondsWords(at) & " of " & secondsWords(full) &
          ": the file holds " & $own.blocks & " of the " & $own.blocksDeclared &
          " blocks its header announces")
    elif e.kind == fkDat and own.sweepNumber == 16:
      result.text = "pulse"
    elif e.kind == fkVib and not own.complete:
      result = SweepCell(text: "cut short", warn: true,
        tip: "the file ends inside a frame: a copy cut short, or a file still being written")
  of fcPair:
    if w.pair.len > 0:
      result = SweepCell(text: (if e.kind == fkDat: ".vib" else: ".dat"),
        tip: "the " & (if e.kind == fkDat: ".vib" else: ".dat") & " of this sweep: " &
          w.pair.extractFilename)
    elif e.path in list.pairNotes:
      result.tip = list.pairNotes[e.path]
  of fcForce:
    if i.qc.valid and i.qc.forceAvgPct >= 0: result.text = $i.qc.forceAvgPct
  of fcThd:
    if i.qc.valid and i.qc.thdMaxPct >= 0: result.text = $i.qc.thdMaxPct
  of fcLimits:
    if i.qc.valid:
      result.text = limitsText(i.qc)
      result.warn = i.qc.limits.card > 0
      result.tip = "the limits the controller's report prints as tripped (T M V F R). " &
        LimitsProbable
  else: discard

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func fileCountWords*(seismic, signatures, surveys: int; listed: bool): string =
  ## What the list holds, under the table: "11 signature files", "3 seismic files, 8 signature
  ## files", with the survey files; with the tick off the signature files are said not to be
  ## listed (short: the line must fit the default Files window).
  var parts: seq[string] = @[]
  if seismic > 0 or (signatures == 0 and surveys == 0): parts.add plural(seismic, "seismic file", "seismic files")
  if signatures > 0:
    parts.add plural(signatures, "signature file", "signature files") &
      (if listed: "" else: " hidden (tick off)")
  if surveys > 0: parts.add plural(surveys, "survey file", "survey files")
  parts.join(", ")

func dayOf*(ns: int64): int64 =
  ## The UTC day (since 1970) of `ns`.
  floorDiv(ns, 86_400_000_000_000'i64)

func singleDay*(list: FileList): bool =
  ## Whether every signature file of the list that has a readable header lies on one UTC day:
  ## the Trigger column then drops the date and keeps the time, which tells the sweeps apart.
  var day = low(int64)
  for e in list.entries:
    if e.kind in SignatureFileKinds and e.sweep.problem.len == 0:
      let d = dayOf(e.sweep.triggerNs)
      if day == low(int64): day = d
      elif d != day: return false
  day != low(int64)

func sizeText*(bytes: int64): string =
  ## "812 B", "4.2 KB", "65.1 MB", "1.27 GB" (powers of 1000, as file
  ## managers mostly show them).
  const units = ["B", "KB", "MB", "GB", "TB", "PB"]
  var x = float64(bytes)
  var u = 0
  while x >= 999.95 and u < units.high:
    x /= 1000
    inc u
  if u == 0: $bytes & " B"
  elif x < 9.995: formatFloat(x, ffDecimal, 2) & " " & units[u]
  else: formatFloat(x, ffDecimal, 1) & " " & units[u]

proc dateText*(t: Time): string =
  ## The local date and time to the minute: "2026-10-20 08:03".
  t.local.format("yyyy-MM-dd HH:mm")

proc shortDateText*(t, now: Time): string =
  ## The time alone for a file of today ("08:03"), the date alone for older
  ## ones ("2026-10-20"), as file managers show them in a narrow column.
  let (d, n) = (t.local, now.local)
  if d.year == n.year and d.yearday == n.yearday: d.format("HH:mm")
  else: d.format("yyyy-MM-dd")

func typeText*(e: FileEntry): string = $e.kind

func kindText*(e: FileEntry): string =
  ## What the Kind column shows: the kind read from the file ("Shot"); "?" for a file whose kind
  ## is not known until it is opened; "" while it is not read and for a file with none.
  let k = e.recordingOf
  if k.isSome: kindShort(k.get)
  elif e.kindState == ksNotKnown: "?"
  else: ""

func kindTip*(e: FileEntry): string =
  ## What the tooltip of a row says of its kind: the full words ("Shot gather"), or why it is
  ## not known; "" while it is not read and for a file with none.
  let k = e.recordingOf
  if k.isSome: kindTitle(k.get)
  elif e.kindState == ksNotKnown: NotKnownWords
  else: ""
