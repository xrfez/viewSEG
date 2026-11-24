## The leap-second table the open files' times are read with.
##
## A user file `leapseconds.nif` in the settings folder, read at start and
## from Tools > Leap seconds. One table is chosen, never a merge of the two.
## Problems, or a file that is older and does not know more, keep the table
## shipped with the program. A change is written by the disk thread and the
## open files' keys are read again on a job (`leapRereadWork`).

import std/[math, os]
import parseSEG
import parseSEG/model/traceindex
import filesystem, inbox, jobs, log, persist, session

const LeapFileName* = "leapseconds.nif"
  ## The user table, beside `settings.nif`.

type
  ChosenLeap* = object
    ## The table to use, and what to say about the choice.
    table*: LeapTable
    notes*: seq[Note]

func two(n: int): string =
  if n < 10: "0" & $n else: $n

func dateText*(d: LeapDate): string =
  ## `d` as `2027-01-01`.
  $d.year & "-" & two(d.month) & "-" & two(d.day)

func before(a, b: LeapDate): bool =
  (a.year, a.month, a.day) < (b.year, b.month, b.day)

proc leapPath*(configDir: string): string =
  ## The user table in `configDir`; "" when there is no settings folder.
  if configDir.len == 0: "" else: configDir / LeapFileName

proc chooseLeap*(user: LeapTable; problems: openArray[string]; path: string): ChosenLeap =
  ## One table: `user` when it parses and is not older than the shipped table,
  ## or when it is older and has more entries. Otherwise the shipped table.
  ## `problems` (each named with `path`) keep the shipped table.
  if problems.len > 0:
    for p in problems:
      result.notes.add (sevWarning, path & ": " & p)
    result.notes.add (sevWarning, path &
      " was not used. The shipped leap-second table is in use.")
    result.table = defaultLeapTable()
    return
  let shipped = defaultLeapTable()
  let fewer = user.entries.len < shipped.entries.len
  let earlier = before(user.checkedTo, shipped.checkedTo)
  let more = user.entries.len > shipped.entries.len
  if (fewer or earlier) and more:
    result.table = user
    result.notes.add (sevInfo, path & " is older than the shipped table and has more " &
      "leap seconds, so it is used.")
  elif fewer or earlier:
    result.table = shipped
    var why = ""
    if fewer: why.add "fewer leap seconds"
    if earlier:
      if why.len > 0: why.add " and "
      why.add "an earlier checked-to date"
    result.notes.add (sevWarning, path & " has " & why &
      " than the shipped table, so the shipped table is used.")
  else:
    result.table = user

proc installLeap*(configDir: string): seq[Note] {.raises: [].} =
  ## Reads the user table in `configDir` and makes it the table in use, when
  ## there is one. A missing file changes nothing and writes nothing. A file
  ## that cannot be read, or that is not used, puts the shipped table back
  ## (a bad file must not leave an older table installed).
  let path = leapPath(configDir)
  if path.len == 0 or not fs.fileExists(path): return
  var text = ""
  try:
    text = fs.readFile(path)
  except IOError as e:
    try: useLeapTable(defaultLeapTable())
    except ValueError: discard
    return @[(sevWarning, "Cannot read " & path & ": " & e.msg &
      ". The shipped leap-second table is in use.")]
  let parsed = parseLeapTable(text)
  let chosen = chooseLeap(parsed.table, parsed.problems, path)
  try:
    useLeapTable(chosen.table)
    result = chosen.notes
  except ValueError as e:
    try: useLeapTable(defaultLeapTable())
    except ValueError: discard
    result.add (sevWarning, path & " was not used: " & e.msg &
      ". The shipped leap-second table is in use.")

proc addLeapProblem*(year, month, step: int): string =
  ## Why a leap at the first of `year`-`month` with `step` cannot be added;
  ## "" when it can. Does not change the table in use.
  try:
    discard currentLeapTable().withLeap(LeapDate(year: year, month: month, day: 1), step)
  except ValueError as e:
    result = e.msg

proc checkedProblem*(year, month, day: int): string =
  ## Why the table cannot be known complete through `year`-`month`-`day`;
  ## "" when it can.
  var next = currentLeapTable()
  next.checkedTo = LeapDate(year: year, month: month, day: day)
  let parsed = parseLeapTable(leapTableNif(next))
  if parsed.problems.len > 0: result = parsed.problems[0]

proc removeLeapProblem*(): string =
  ## Why the last entry cannot be removed: only one added here, strictly
  ## after the shipped table's last, and not when either table is empty.
  let user = currentLeapTable()
  let shipped = defaultLeapTable()
  if user.entries.len == 0 or shipped.entries.len == 0:
    return "The leap-second table has no entry to remove."
  if user.entries.len <= shipped.entries.len:
    return "Only a leap second added here can be removed, not one the program ships with."
  let last = user.entries[^1]
  let ship = shipped.entries[^1]
  if (last.year, last.month, last.day) <= (ship.year, ship.month, ship.day):
    return "Only a leap second added here, after the shipped table's last, can be removed."

func addedSentence*(date: LeapDate; offset: int): string =
  ## What an added leap is called in the log.
  "Added a leap second of " & dateText(date) & ": GPS is " & $offset &
    " seconds ahead of UTC from then."

func removedSentence*(date: LeapDate): string =
  "Removed the leap second of " & dateText(date) & "."

func checkedSentence*(date: LeapDate): string =
  "The leap-second table is known complete through " & dateText(date) & "."

func resetSentence*(date: LeapDate): string =
  "The leap-second table is the one shipped with the program (known complete through " &
    dateText(date) & ")."

proc uncheckedNote*(utcSec: float64): string =
  ## The warning when `utcSec` (UTC POSIX seconds) is after the table was
  ## last checked; "" when the table covers it, or the time is not a number.
  if utcSec.isNaN: return ""
  let us = int64(round(utcSec * 1_000_000.0))
  if leapKnownAt(us): return ""
  "The leap-second table was last checked through " & dateText(currentLeapTable().checkedTo) &
    ", before this file's time."

proc leapRereadWork*(file: ptr SeismicFile; path: string; session: SessionId;
    holds: HoldRelease; to: Poster): JobWork =
  ## Reads `file`'s stored keys again (`refreshKeys`) after the leap table
  ## changed, and posts `mkLeap`. Submitted with the file in `exclusive`.
  ## A reader still holding the file fails the job. A cancel before the
  ## read stops it; once committed, the read runs to its end.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    let held = holds.held(path)
    if held > 0:
      raise newException(IOError, "a reader still reads the file, so its times were not read again")
    if not ctx.commit(): raise newException(JobCancelledError, "cancelled")
    ctx.setPhase "reading times again"
    var changed = false
    var revision = 0
    const Chunk = 4096
    {.cast(gcsafe).}:
      let n = file[].len
      var at = 0
      while at < n:
        let last = min(at + Chunk, n)
        var traces = newSeq[int](last - at)
        for i in 0 ..< traces.len: traces[i] = at + i
        if file[].refreshKeys(traces): changed = true
        at = last
        if n > 0: discard ctx.progress(at, n)
      revision = file[].keysRevision
    to.post Msg(job: ctx.id, kind: mkLeap, leapSession: session, leapChanged: changed,
      leapRevision: revision)
