## What the Jobs window shows: the running jobs with their progress, the
## queued ones of both lanes in the order they will run, and the finished
## ones, newest first; each as text, with what can be done to it (cancel a
## running job; move a queued one up or down its lane, or remove it; clear
## a finished one). Toolkit-neutral: a frontend draws the rows and turns
## the buttons into `Command`s.

import std/[monotimes, strutils, times]
import ../core/jobs
import jobstatus

type
  JobRow* = object
    id*: JobId
    title*: string     ## in plain words: "Open survey.sgy"
    lane*: JobLane
    state*: JobState
    fraction*: float32 ## running: of the phase done, 0 .. 1; -1 when unknown
    progress*: string  ## running: "indexing 42 %, about 3 s left"; "" when it says nothing
    detail*: string    ## queued: "next"; finished: "done in 1.2 s", "failed: ..."
    position*: int     ## queued: its place in its lane, 0 runs next
    canCancel*: bool   ## running or queued, and cancellable, and not being cancelled
    canRaise*: bool    ## queued, and not first in its lane
    canLower*: bool    ## queued, and not last in its lane
    canRemove*: bool   ## finished, or queued and cancellable

  JobRows* = object
    running*, queued*, finished*: seq[JobRow]

func laneName*(lane: JobLane): string =
  ## How a lane is named to the user.
  case lane
  of jlInteractive, jlPeeks: "foreground"
  of jlBackground, jlHashes, jlOriginals: "background"

func seconds(d: Duration): string =
  let ms = d.inMilliseconds
  if ms < 1000: $ms & " ms"
  elif ms < 60_000: formatFloat(ms.float / 1000, ffDecimal, 1) & " s"
  else: $(ms div 60_000) & " min " & $((ms div 1000) mod 60) & " s"

func jobRows*(list: openArray[JobInfo]; queues: array[JobLane, seq[JobId]];
    now: MonoTime): JobRows =
  ## The rows for `list` (`Jobs.list`: every job listed, oldest first) and
  ## `queues` (`Jobs.queued` of each lane) at time `now`.
  for lane in JobLane:
    for pos, id in queues[lane]:
      for j in list:
        if j.id == id and j.state == jsQueued:
          let place = if pos == 0: "next" else: $(pos + 1) & ". in line"
          result.queued.add JobRow(id: id, title: j.spec.title, lane: lane, state: jsQueued,
            fraction: -1, position: pos, detail: place, canCancel: j.spec.cancellable,
            canRaise: pos > 0, canLower: pos < queues[lane].high,
            canRemove: j.spec.cancellable)
  for i in countdown(list.high, 0):
    let j = list[i]
    case j.state
    of jsRunning:
      let s = jobStatus([j], now)
      var text = s.text
      if text.startsWith(s.title): text = text[s.title.len .. ^1]
      if text.startsWith(": "): text = text[2 .. ^1]
      result.running.insert(JobRow(id: j.id, title: j.spec.title, lane: j.spec.lane,
        state: jsRunning, fraction: s.fraction, progress: text,
        detail: "running for " & seconds(now - j.startedAt),
        canCancel: j.spec.cancellable and not j.cancelRequested), 0)
    of jsDone, jsFailed, jsCancelled:
      let took = if j.startedAt != MonoTime(): " in " & seconds(j.finishedAt - j.startedAt)
                 else: ""
      let detail = case j.state
        of jsDone: "done" & took
        of jsFailed: "failed" & took & ": " & j.error
        elif j.startedAt != MonoTime(): "cancelled after" & took[3 .. ^1]
        else: "cancelled before it started"
      result.finished.add JobRow(id: j.id, title: j.spec.title, lane: j.spec.lane,
        state: j.state, fraction: -1, detail: detail, canRemove: true)
    of jsQueued: discard
