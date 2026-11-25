## The job that tells each trace of an open file its shot (`buildTraceMap`), so that choosing
## a shot on the map is a look-up.

import parseSEG
import jobs, shotfollow, shotselect

proc traceMapSpec*(name, path: string): JobSpec =
  ## The job that reads the keys of open file `path`: background, reading it.
  JobSpec(title: "Find the shots of " & name, lane: jlBackground, reads: @[path])

proc traceMapWork*(file: ptr SeismicFile; index: ref ShotIndex; rows: int;
    sink: ShotTraceSink): JobWork =
  ## Builds the map of `file` (which stays open until the job ends) against `index`, a log of
  ## `rows` rows, on a job thread. `sink.map` is set when it finishes; a cancel leaves it unset.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      let map = buildTraceMap(file, index, rows, proc () {.gcsafe.} = ctx.checkCancelled())
      ctx.checkCancelled()
      sink.map = map
