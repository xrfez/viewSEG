## The Jobs window's model and the notices of background jobs: running jobs
## with their progress and Cancel; queued jobs of both lanes in the order
## they will run, with up, down and remove where they can act; finished
## jobs, newest first, saying how they ended and how long they took; and a
## notice when a background job ends (not for an interactive one, nor for a
## cancel), the newest `MaxNotices` kept.
##
## Seen to fail: with the queued rows taken in submission order instead of
## each lane's queue, `rowsOfEachKind` found "QC 2" before "QC 3"; with an
## interactive job's end noticed too, `noticesOfBackgroundJobs` found "Quick
## is done." among the notices.

import std/[monotimes, strutils, times]
import viewSEG/core/state
import viewSEG/view/joblist
import utils/waiting

let t0 = getMonoTime()

func secs(s: float): Duration = initDuration(milliseconds = int64(s * 1000))

proc info(id: int; title: string; state: JobState; lane = jlBackground; started = -1.0;
    finished = 0.0; error = ""; cancellable = true): JobInfo =
  JobInfo(id: JobId(id), spec: JobSpec(title: title, lane: lane, cancellable: cancellable),
    state: state, error: error,
    startedAt: (if started >= 0: t0 + secs(started) else: MonoTime()),
    finishedAt: t0 + secs(finished),
    progress: JobProgress(done: 25, total: 100, phase: "reading", since: t0))

block rowsOfEachKind:
  let list = [info(1, "Open a.sgy", jsDone, jlInteractive, 0.0, 1.25),
    info(2, "QC 1", jsRunning, started = 1.0),
    info(3, "QC 2", jsQueued), info(4, "QC 3", jsQueued),
    info(5, "Open b.sgy", jsFailed, jlInteractive, 2.0, 2.5, "there is no such file"),
    info(6, "Close b.sgy", jsQueued, jlInteractive, cancellable = false),
    info(7, "QC 4", jsCancelled)]
  let rows = jobRows(list, [@[JobId(6)], @[JobId(4), JobId(3)], @[], @[], @[]], t0 + secs(3))
  doAssert rows.running.len == 1 and rows.running[0].title == "QC 1"
  doAssert rows.running[0].progress == "reading 25 %, about 9 s left", rows.running[0].progress
  doAssert abs(rows.running[0].fraction - 0.25) < 1e-6 and rows.running[0].canCancel
  doAssert rows.running[0].detail == "running for 2.0 s", rows.running[0].detail
  var titles: seq[string]
  for r in rows.queued: titles.add r.title
  doAssert titles == @["Close b.sgy", "QC 3", "QC 2"], $titles
  let close = rows.queued[0]
  doAssert close.lane == jlInteractive and close.detail == "next"
  doAssert not close.canCancel and not close.canRemove, "a close must run"
  doAssert not close.canRaise and not close.canLower
  doAssert not rows.queued[1].canRaise and rows.queued[1].canLower
  doAssert rows.queued[2].canRaise and not rows.queued[2].canLower
  doAssert rows.queued[2].position == 1 and rows.queued[2].detail == "2. in line"
  titles.setLen 0
  for r in rows.finished: titles.add r.title
  doAssert titles == @["QC 4", "Open b.sgy", "Open a.sgy"], "newest first: " & $titles
  doAssert rows.finished[2].detail == "done in 1.2 s", rows.finished[2].detail
  doAssert rows.finished[1].detail == "failed in 500 ms: there is no such file",
    rows.finished[1].detail
  doAssert rows.finished[0].detail == "cancelled before it started", rows.finished[0].detail
  for r in rows.finished: doAssert r.canRemove and not r.canCancel
  doAssert laneName(jlInteractive) == "foreground" and laneName(jlBackground) == "background" and
    laneName(jlHashes) == "background" and laneName(jlPeeks) == "foreground"

var gates: array[3, Gate]

proc gated(gate: int): JobWork =
  result = proc (ctx: JobContext) {.gcsafe.} = gates[gate].waitAt(ctx)

proc failing(ctx: JobContext) {.gcsafe.} =
  raise newException(IOError, "the disk is full")

block queuedInTheirOrder:
  # The rows follow the lane's queue, so a move shows at once.
  var st = initAppState()
  discard st.jobs.submit(JobSpec(title: "Hold", lane: jlBackground), gated(0))
  doAssert waitUntil(st.jobs.active.len == 1 and st.jobs.active[0].state == jsRunning)
  let a = st.jobs.submit(JobSpec(title: "QC 1", lane: jlBackground), gated(0))
  discard st.jobs.submit(JobSpec(title: "QC 2", lane: jlBackground), gated(0))
  st.apply Command(kind: ckReorderJob, reordered: a, position: 1)
  let rows = jobRows(st.jobs.list, st.jobs.queues, getMonoTime())
  doAssert rows.queued.len == 2 and rows.queued[0].title == "QC 2", $rows.queued
  doAssert rows.running.len == 1 and rows.running[0].title == "Hold"
  gates[0].open()
  st.shutdown()

block noticesOfBackgroundJobs:
  var st = initAppState()
  template settle(cond: untyped): bool = st.settle(cond)
  discard st.jobs.submit(JobSpec(title: "Quick", lane: jlInteractive), gated(1))
  discard st.jobs.submit(JobSpec(title: "Export", lane: jlBackground), failing)
  discard st.jobs.submit(JobSpec(title: "Scan line 7", lane: jlBackground), gated(1))
  let stopped = st.jobs.submit(JobSpec(title: "Stack", lane: jlBackground), gated(2))
  doAssert settle(st.notices.len == 1)
  doAssert st.notices[0].severity == sevError and
    st.notices[0].text == "Export failed: the disk is full", st.notices[0].text
  gates[1].open()
  doAssert settle(st.notices.len == 2)
  doAssert st.notices[1].text == "Scan line 7 is done." and st.notices[1].serial == 1
  st.apply Command(kind: ckCancelJob, job: stopped)
  doAssert settle(st.jobs.active.len == 0)
  discard st.drainInbox()
  doAssert st.notices.len == 2, "a cancel is no news: " & $st.notices
  for e in st.notices: doAssert "Quick" notin e.text
  for i in 0 ..< MaxNotices + 3:
    discard st.jobs.submit(JobSpec(title: "QC " & $i, lane: jlBackground), gated(1))
  doAssert settle(st.notices.len == MaxNotices and st.notices[^1].serial == MaxNotices + 4)
  doAssert st.notices[0].serial == 5, "the oldest go first"
  st.shutdown()
