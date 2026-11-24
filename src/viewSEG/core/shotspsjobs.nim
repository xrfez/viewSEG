## Writes a shot log's source points as an SPS file on a job
## (`spsExportWork`), and says what was written and what was left out
## (`spsSentences`). The file is new: an existing one is never replaced.

import std/[os, strutils]
import jobs, shotlog, shotlogsps

type
  SpsSink* = ref object
    ## Filled when the job ends. Read it after the job is no longer running.
    dest*: string
    result*: ShotSpsResult

proc spsExportSpec*(dest: string): JobSpec =
  ## The job that writes `dest`: background, needing `dest` to itself.
  JobSpec(title: "Export SPS " & dest.extractFilename, lane: jlBackground, exclusive: @[dest])

proc spsExportWork*(view: ShotView; opts: ShotSpsOptions; dest: string;
    sink: SpsSink): JobWork =
  ## Writes `view` to the new file `dest` on a job thread (submit it with
  ## `spsExportSpec`). `sink.result` is set before the job returns; its `error`
  ## is empty when the file was written. `view` is a copy: edits made while the
  ## job runs are not in the file.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      var r = writeShotSps(view, opts, dest, replace = false)
      r.text = ""
      r.file.points.setLen 0
      sink.result = r

func plural(n: int; one, many: string): string =
  $n & " " & (if n == 1: one else: many)

func spsSentences*(r: ShotSpsResult; name: string): string =
  ## What an export wrote, in sentences: the rows written to `name`, the rows
  ## left out and why (the first `NamedMax` named, the rest counted as rows), the rows
  ## with no shot point, repeated points and dropped fractions of a second.
  result = "Wrote " & plural(r.written, "row", "rows") & " to " & name & "."
  if r.skipped > 0:
    result.add " " & plural(r.skipped, "row was", "rows were") & " left out"
    if r.problems.len > 0: result.add ": " & problemWords(r)
    result.add "."
  if r.noShotPoint > 0:
    result.add " " & plural(r.noShotPoint, "row has", "rows have") & " no shot point."
  if r.duplicates > 0:
    result.add " " & plural(r.duplicates, "row repeats", "rows repeat") &
      " a line, point and index already written."
  if r.fractionDropped > 0:
    result.add " The fraction of a second was dropped from " &
      plural(r.fractionDropped, "row", "rows") & "."
  if r.yearChanged:
    result.add " The times are not all in one year; SPS has no year."
