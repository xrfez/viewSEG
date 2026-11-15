## What the status bar says about the jobs: the job the user is most likely
## waiting for, how far it is, roughly how long it has left, whether it can
## be cancelled, and how many others run or wait. Toolkit-neutral: a
## frontend draws it as a progress bar with a Cancel button.

import std/[math, monotimes, times]
import ../core/jobs

type
  JobStatus* = object
    ## The status bar's job field; `shown` false when nothing runs or waits.
    shown*: bool
    job*: JobId        ## the job the bar shows; `NoJob` when only queued jobs wait
    title*: string     ## in plain words: "Open survey.sgy"
    phase*: string     ## the part it is in: "indexing"; "" when it names none
    fraction*: float32 ## of the phase done, 0 .. 1; -1 when unknown
    percent*: string   ## "42 %"; "" when unknown
    timeLeft*: string  ## "about 12 s left"; "" until an estimate is sound
    cancellable*: bool ## the bar offers Cancel
    cancelling*: bool  ## a cancel was asked for and the job has not stopped yet
    silent*: Duration  ## how long it has not answered (its drive); zero while it answers
    otherRunning*: int ## running jobs besides the one shown
    queued*: int       ## jobs waiting, in both lanes

const
  MinEstimateTime = initDuration(seconds = 1) ## no estimate before this
  MinEstimateFraction = 0.02                  ## nor before this much is done

func formatLeft(left: Duration): string =
  ## "about 12 s left", "about 78 min left" (up to 90), "about 2 h left".
  let s = left.inSeconds
  if s < 60: "about " & $max(s, 1) & " s left"
  elif s < 90 * 60: "about " & $int(round(s.float / 60)) & " min left"
  else: "about " & $int(round(s.float / 3600)) & " h left"

func shownFirst(a, b: JobInfo): bool =
  ## Whether running job `a` goes on the bar before running job `b`: what
  ## the user waits on (interactive) first, then the one running longest.
  if a.spec.lane != b.spec.lane: a.spec.lane == jlInteractive
  else: a.startedAt < b.startedAt

func jobStatus*(active: openArray[JobInfo]; now: MonoTime; drives = now): JobStatus =
  ## The status bar's job field for `active` (`Jobs.active`: the running
  ## and queued jobs) at time `now`; `drives` is `fs.now`, the clock jobs
  ## that do not answer are timed on.
  result = JobStatus(job: NoJob, fraction: -1)
  var best = -1
  for i, j in active:
    case j.state
    of jsRunning:
      if best < 0 or shownFirst(j, active[best]):
        if best >= 0: inc result.otherRunning
        best = i
      else:
        inc result.otherRunning
    of jsQueued: inc result.queued
    of jsDone, jsFailed, jsCancelled: discard
  result.shown = best >= 0 or result.queued > 0
  if best < 0: return
  let j = active[best]
  result.job = j.id
  result.title = j.spec.title
  result.phase = j.progress.phase
  result.cancellable = j.spec.cancellable
  result.cancelling = j.cancelRequested
  result.silent = j.notAnsweringFor(drives)
  let p = j.progress
  if p.total > 0:
    let f = clamp(p.done.float / p.total.float, 0.0, 1.0)
    result.fraction = f.float32
    result.percent = $int(floor(f * 100)) & " %"
    let spent = now - p.since
    if f >= MinEstimateFraction and f < 1 and spent >= MinEstimateTime and
        p.since != MonoTime():
      let left = initDuration(nanoseconds = int64(spent.inNanoseconds.float * (1 - f) / f))
      result.timeLeft = formatLeft(left)

func text*(s: JobStatus): string =
  ## The bar's label: "Open survey.sgy: indexing 42 %, about 3 s left".
  result = s.title
  if s.phase.len > 0: result.add ": " & s.phase
  if s.percent.len > 0:
    result.add (if s.phase.len > 0: " " else: ": ") & s.percent
  if s.timeLeft.len > 0: result.add ", " & s.timeLeft
  if s.silent > initDuration():
    result.add " (not answering for " & $max(1, s.silent.inSeconds) & " s)"
  if s.cancelling: result.add " (cancelling)"

func others*(s: JobStatus): string =
  ## What else runs or waits: "1 more running, 3 queued"; "" for nothing.
  result = ""
  if s.otherRunning > 0: result = $s.otherRunning & " more running"
  if s.queued > 0:
    if result.len > 0: result.add ", "
    result.add $s.queued & " queued"
