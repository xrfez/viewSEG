## An open file and what the viewer keeps of it.
##
## A `Session` is made on a job thread (`filejobs.openSession`), moved to the
## UI thread through the inbox, and kept by `AppState`, which gives it a
## `SessionId` and the survey-wide number of its first trace. Its fields do not
## change after that, apart from the file being closed.
##
## Trace ids are survey-wide: `base + index`. Bases are never reused, so an id
## kept by a view never names a trace of a file opened later.

import std/os
import parseSEG

type
  SessionId* = distinct int
    ## Names an open file; never reused. `NoSession` (0) names none.

  Session* {.acyclic.} = ref object
    ## An open seismic file. A `ref`, so that workers can hold a stable
    ## `ptr SeismicFile` into it (docs/architecture.md, "Threads"); only the
    ## UI thread holds the `ref` itself once it is adopted.
    id: SessionId
    base: int
    path: string
    file: SeismicFile
    gathers: seq[Gather]

const NoSession* = SessionId(0)

func `==`*(a, b: SessionId): bool {.borrow.}
func `$`*(id: SessionId): string = "file " & $int(id)

proc newSession*(path: string; file: sink SeismicFile): Session =
  ## A session for `file`, opened from `path`, with its gathers.
  result = Session(path: path, file: file)
  result.gathers = result.file.gathers

proc register*(s: Session; id: SessionId; base: int) =
  ## Gives `s` its id and the survey-wide id of its first trace (`AppState`
  ## does this when it adopts the session).
  s.id = id
  s.base = base

func id*(s: Session): SessionId {.inline.} = s.id
func base*(s: Session): int {.inline.} = s.base
  ## The survey-wide id of trace 0.
func path*(s: Session): lent string {.inline.} = s.path
func name*(s: Session): string = s.path.extractFilename
  ## The file's name, for messages and titles.
func file*(s: Session): lent SeismicFile {.inline.} = s.file
func gathers*(s: Session): lent seq[Gather] {.inline.} = s.gathers
func len*(s: Session): int {.inline.} = s.file.len
  ## The number of traces.

func traceIds*(s: Session): Slice[int] {.inline.} =
  ## The survey-wide ids of the file's traces.
  s.base ..< s.base + s.file.len

func contains*(s: Session; trace: int): bool {.inline.} =
  ## Whether survey-wide trace id `trace` is one of this file's.
  trace in s.traceIds

proc filePtr*(s: Session): ptr SeismicFile {.inline.} =
  ## The file, for a worker that reads it while the UI thread keeps the
  ## session (and closes it only once no job uses it).
  addr s.file
