## Whether a destination is already taken, asked of the disk on a job and
## never on the UI thread, so that a drive that does not answer cannot hold a
## window.
##
## A window keeps one `DestWatch` and calls `follow` every frame with the
## destination and a key. The key stands for everything the answer depends on
## (the path, and whether an export has ended since): when it changes, the
## question in flight is let go and the disk is asked again; an answer to an
## older key is never used. While the answer is pending, `pending` is true and
## `exists` is false.

import std/[options, os]
import filesystem, jobs

type
  DestSink = ref object
    ## Filled by the job when it ends; read once the job is done.
    taken: bool

  DestWatch* = object
    key: string
    job: JobId = NoJob
    sink: DestSink
    asked: bool ## a question was put for `key` and its answer is not in yet
    taken: bool

proc lookWork(path: string; sink: DestSink): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    let found = fs.fileExists(path) or fs.dirExists(path)
    ctx.checkCancelled()
    sink.taken = found

proc letGo(w: var DestWatch; jobs: Jobs) =
  ## Forgets the question in flight; its answer, if it ever comes, is dropped.
  if w.job != NoJob:
    if not jobs.cancel(w.job): discard jobs.remove(w.job)
  w.job = NoJob
  w.sink = nil
  w.asked = false

func pending*(w: DestWatch): bool {.inline.} =
  ## Whether the disk has not yet answered for the current key.
  w.asked

func exists*(w: DestWatch): bool {.inline.} =
  ## Whether a file or folder is at the destination: false while `pending`.
  w.taken and not w.asked

proc follow*(w: var DestWatch; jobs: Jobs; dest, key: string) =
  ## Call once per frame. `dest` is the path to look at, "" for none; `key`
  ## changes whenever the answer must be asked for again.
  if key != w.key:
    w.letGo(jobs)
    w.key = key
    w.taken = false
    if dest.len > 0:
      w.sink = DestSink()
      w.job = jobs.submit(JobSpec(title: "Look at " & dest.extractFilename,
        lane: jlInteractive, auto: true), lookWork(dest, w.sink))
      w.asked = true
  elif w.asked:
    let info = jobs.info(w.job)
    if info.isNone:
      w.key = "" # the job is gone without an answer: ask again
      w.asked = false
    elif info.get.state == jsDone:
      w.taken = w.sink.taken
      w.asked = false
      discard jobs.remove(w.job)
      w.job = NoJob
      w.sink = nil
    elif info.get.state in {jsFailed, jsCancelled}:
      discard jobs.remove(w.job)
      w.key = ""
      w.asked = false
      w.job = NoJob
