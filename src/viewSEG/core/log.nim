## The message log: what the program, its jobs and parseSEG reported, in the
## order it was reported, for the log window and the status bar.
##
## The log is bounded: past its capacity the oldest entries are dropped, and
## `dropped` counts them. Every entry has a serial number, one more than the
## entry before it, so a reader that keeps the last serial it saw (the log
## window, a file sink) finds what is new with `since`, even after drops.
##
## The log belongs to the UI thread (`AppState` holds it). Workers do not
## write to it directly: they post entries through the inbox.

import std/[deques, times]
import parseSEG/common/diagnostics

export Severity, Location

const DefaultLogCapacity* = 10_000 ## entries kept by `initMessageLog()`

type
  LogEntry* = object
    ## One message.
    serial*: int        ## 0 for the first entry of a log; then one more each
    time*: Time         ## when it was reported
    severity*: Severity
    source*: string     ## who reported it, in plain words: "open", "jobs", a file name
    text*: string       ## the message, in plain words
    loc*: Location      ## the file, record, trace or header field it is about, when known
    offset*: int64 = -1 ## the byte offset in that file; -1 when unknown

  MessageLog* = object
    ## The newest `capacity` entries, oldest first.
    entries: Deque[LogEntry]
    capacity: int
    next: int                    ## serial of the next entry
    dropped: int
    counts: array[Severity, int] ## of the entries kept

func initMessageLog*(capacity: Positive = DefaultLogCapacity): MessageLog =
  ## An empty log that keeps the newest `capacity` entries.
  MessageLog(entries: initDeque[LogEntry](min(capacity, 64)), capacity: capacity)

proc add*(log: var MessageLog; entry: sink LogEntry) =
  ## Appends `entry`, giving it the next serial number, and drops the oldest
  ## entry when the log is full.
  if log.capacity == 0: # a default-constructed log
    log.capacity = DefaultLogCapacity
  entry.serial = log.next
  inc log.next
  inc log.counts[entry.severity]
  log.entries.addLast entry
  if log.entries.len > log.capacity:
    dec log.counts[log.entries.popFirst().severity]
    inc log.dropped

proc add*(log: var MessageLog; severity: Severity; source, text: string;
    loc = Location(); offset = -1'i64) =
  ## Appends a message reported now.
  log.add LogEntry(time: getTime(), severity: severity, source: source, text: text,
    loc: loc, offset: offset)

proc add*(log: var MessageLog; diags: DiagLog; source: string) =
  ## Appends each of parseSEG's diagnostics in `diags`, oldest first, with
  ## its severity, location and offset; `source` names who read it (usually
  ## the file's name).
  let now = getTime()
  for d in diags:
    log.add LogEntry(time: now, severity: d.severity, source: source, text: d.msg,
      loc: d.loc, offset: d.offset)

func len*(log: MessageLog): int {.inline.} =
  ## The number of entries kept.
  log.entries.len

func capacity*(log: MessageLog): int {.inline.} =
  ## The most entries the log keeps.
  if log.capacity == 0: DefaultLogCapacity else: log.capacity

func dropped*(log: MessageLog): int {.inline.} =
  ## How many entries were dropped to keep the log within its capacity.
  log.dropped

func nextSerial*(log: MessageLog): int {.inline.} =
  ## The serial number the next entry will get.
  log.next

func count*(log: MessageLog; severity: Severity): int {.inline.} =
  ## The number of kept entries with exactly `severity`.
  log.counts[severity]

func `[]`*(log: MessageLog; i: Natural): lent LogEntry {.inline.} =
  ## Entry `i` of those kept, oldest first. As for a `seq`, an `i` outside
  ## `0 ..< len` is a bug.
  log.entries[i]

iterator items*(log: MessageLog): lent LogEntry =
  ## The entries kept, oldest first.
  for e in log.entries: yield e

iterator since*(log: MessageLog; serial: int): lent LogEntry =
  ## The kept entries whose serial is `serial` or later, oldest first.
  let first = max(0, serial - (log.next - log.entries.len))
  for i in first ..< log.entries.len:
    yield log.entries[i]
