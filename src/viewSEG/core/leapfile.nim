## The leap-second table the open files' times are read with.
##
## A user file `leapseconds.nif` in the settings folder, read at start and
## from Tools > Leap seconds. One table is chosen, never a merge of the two.
## Problems, or a file that does not hold every leap second this program
## ships, keep the table shipped with the program. A change is written by the
## disk thread and the
## open files' keys are read again on a job (`leapRereadWork`).

import std/[atomics, os]
import parseSEG
import parseSEG/model/traceindex
import filesystem, inbox, jobs, log, persist, session

const LeapFileName* = "leapseconds.nif"
  ## The user table, beside `settings.nif`.

const MaxLeapBytes = 1 shl 20
  ## A user file larger than this is refused without being read.

var leapGenPublished: Atomic[int]
  ## The leap-table generation workers read while they read keys. The state
  ## publishes it on every adopt; it only increases.

proc publishLeapGen*(gen: int) {.gcsafe.} =
  ## Makes `gen` the generation an open job records with the keys it reads.
  leapGenPublished.store(gen, moRelease)

proc leapGenNow*(): int {.gcsafe.} =
  ## The generation published last; 0 before any adopt.
  leapGenPublished.load(moAcquire)

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

proc leapPath*(configDir: string): string =
  ## The user table in `configDir`; "" when there is no settings folder.
  if configDir.len == 0: "" else: configDir / LeapFileName

func coversShipped(user, shipped: LeapTable): bool =
  ## Whether `user` holds every shipped leap, in order, with the same date and
  ## the same offset. Later entries may follow.
  if user.entries.len < shipped.entries.len: return false
  for i in 0 ..< shipped.entries.len:
    let a = user.entries[i]
    let b = shipped.entries[i]
    if a.year != b.year or a.month != b.month or a.day != b.day or
        a.gpsMinusUtc != b.gpsMinusUtc:
      return false
  true

proc chooseLeap*(user: LeapTable; problems: openArray[string]; path: string): ChosenLeap =
  ## One table: `user` when it parses and the shipped table is a prefix of it
  ## (every shipped leap, in order, same date and offset; later leaps may
  ## follow). Otherwise the shipped table, said in one sentence. `problems`
  ## keep the shipped table, said in that same sentence, not one per problem.
  if problems.len > 0:
    result.notes.add (sevWarning, path &
      " was not used. The shipped leap-second table is in use.")
    result.table = defaultLeapTable()
    return
  let shipped = defaultLeapTable()
  if coversShipped(user, shipped):
    result.table = user
  else:
    result.table = shipped
    result.notes.add (sevWarning, path &
      " does not hold every leap second this program ships, so the shipped table is used.")

proc installLeap*(configDir: string): seq[Note] {.raises: [].} =
  ## Reads the user table in `configDir` and makes it the table in use, when
  ## there is one. A missing file changes nothing and writes nothing. A file
  ## larger than 1 MB is not read. A file that cannot be read, or that is not
  ## used, puts the shipped table back (a bad file must not leave an older
  ## table installed).
  let path = leapPath(configDir)
  if path.len == 0 or not fs.fileExists(path): return
  try:
    if fs.getFileSize(path) > MaxLeapBytes:
      try: useLeapTable(defaultLeapTable())
      except ValueError: discard
      return @[(sevWarning, path &
        " was not used. The shipped leap-second table is in use.")]
  except OSError as e:
    try: useLeapTable(defaultLeapTable())
    except ValueError: discard
    return @[(sevWarning, "Cannot read " & path & ": " & e.msg &
      ". The shipped leap-second table is in use.")]
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

func resetSentence*(date: LeapDate): string =
  "The leap-second table is the one shipped with the program (known complete through " &
    dateText(date) & ")."

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
