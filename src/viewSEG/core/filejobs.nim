## The jobs that open and close files.
##
## Opening reads the whole index (and the keys), so it runs on the
## interactive lane, never on the UI thread; the open session goes back to
## the UI thread through the inbox. Closing waits, by asking for the file
## exclusively, until no job reads it; the UI thread then closes the file
## itself, so that the file's objects are only ever released on the thread
## that holds them (`core/threads`, "Handing objects to another thread").

import std/os
import parseSEG
import inbox, jobs, session, threads

proc openSession*(path: string; progress: Progress = nil): Session =
  ## Opens `path` read-only, with its keys and gathers. Worker-only: it
  ## reads the file. Raises `IOError` or `OSError` when the file cannot be
  ## opened, and parseSEG's `SegCancelledError` when `progress` returns
  ## false; problems with the data are in the file's log instead.
  assertWorkerThread()
  # Checked here too, for a plainer message, and because parseSEG 0.11 loses
  # a small allocation when it cannot open the file it is given.
  if not fileExists(path):
    raise newException(IOError, "there is no such file")
  # parseSEG's record sources are objects with methods, which Nim cannot
  # prove GC-safe. Opening touches no global GC'd memory: parseSEG's viewer
  # guide opens files on a job thread, as here.
  {.cast(gcsafe).}:
    result = newSession(path, openSeismic(path, keys = true, progress = progress))

proc openWork*(path: string; to: Poster): JobWork =
  ## The work of a job that opens `path` and posts its session (`mkOpened`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase "indexing"
    let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
      ctx.progress(done, total)
    var s = openSession(path, progress)
    clearCycleRoots() # the UI thread may release the file's objects at once
    to.post Msg(job: ctx.id, kind: mkOpened, session: move s)

proc closeWork*(): JobWork =
  ## The work of a close job: none. Submitted with the file in `exclusive`,
  ## the job starts only once no job reads the file, and when it has finished
  ## the UI thread closes the file.
  result = proc (ctx: JobContext) {.gcsafe.} =
    discard
