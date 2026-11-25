## The status bar's job field: nothing when no job runs or waits; the
## interactive job before a background one; progress as a fraction and a
## percentage; time left only once it can be estimated, from the start of
## the current phase; Cancel only for jobs that can be cancelled; and counts
## of the other running and queued jobs.
##
## Seen to fail: with time left estimated from the job's start instead of
## its phase's, `timeLeftFromThePhase` read "about 30 s left"; with the
## running jobs taken in list order, `interactiveFirst` showed the QC pass.

import std/[monotimes, times]
import viewSEG/core/jobs
import viewSEG/view/jobstatus

let t0 = getMonoTime()

func secs(s: float): Duration = initDuration(milliseconds = int64(s * 1000))

proc running(id: int; title: string; lane = jlInteractive; started = 0.0;
    phaseAt = 0.0; done, total = 0'i64; phase = ""): JobInfo =
  JobInfo(id: JobId(id), spec: JobSpec(title: title, lane: lane), state: jsRunning,
    startedAt: t0 + secs(started),
    progress: JobProgress(done: done, total: total, phase: phase, since: t0 + secs(phaseAt)))

proc queued(id: int; title: string): JobInfo =
  JobInfo(id: JobId(id), spec: JobSpec(title: title), state: jsQueued)

proc main*() =

  block nothingRuns:
    let s = jobStatus([], t0)
    doAssert not s.shown and s.job == NoJob
    let waiting = jobStatus([queued(1, "Open a.sgy")], t0)
    doAssert waiting.shown and waiting.job == NoJob and waiting.queued == 1
    doAssert waiting.others == "1 queued"

  block progressAndText:
    let s = jobStatus([running(3, "Open survey.sgy", done = 421, total = 1000,
      phase = "indexing")], t0 + secs(0.2))
    doAssert s.shown and s.job == JobId(3) and s.cancellable and not s.cancelling
    doAssert abs(s.fraction - 0.421) < 1e-6 and s.percent == "42 %"
    doAssert s.timeLeft == "", "an estimate after 0.2 s: " & s.timeLeft
    doAssert s.text == "Open survey.sgy: indexing 42 %", s.text
    doAssert s.others == ""
    let unknown = jobStatus([running(4, "Scan", phase = "listing")], t0)
    doAssert unknown.fraction < 0 and unknown.percent == "" and unknown.text == "Scan: listing"

  block timeLeftFromThePhase:
    # 10 s into the job, 2 s into its phase, a quarter of the phase done.
    let s = jobStatus([running(1, "Open big.sgd", started = 0, phaseAt = 8, done = 25,
      total = 100, phase = "reading keys")], t0 + secs(10))
    doAssert s.timeLeft == "about 6 s left", s.timeLeft
    let long = jobStatus([running(1, "Stack", done = 1, total = 40)], t0 + secs(120))
    doAssert long.timeLeft == "about 78 min left", long.timeLeft
    let slow = jobStatus([running(1, "Scan", done = 2, total = 100)], t0 + secs(300))
    doAssert slow.timeLeft == "about 4 h left", slow.timeLeft
    let tiny = jobStatus([running(1, "Scan", done = 1, total = 1000)], t0 + secs(60))
    doAssert tiny.timeLeft == "", "an estimate from 0.1 %: " & tiny.timeLeft

  block interactiveFirst:
    let jobs = [running(1, "QC pass", jlBackground, started = 0), queued(5, "Open c.sgy"),
      running(2, "Open a.sgy", started = 5), running(3, "Open b.sgy", started = 6),
      queued(6, "Stack")]
    let s = jobStatus(jobs, t0 + secs(7))
    doAssert s.title == "Open a.sgy", s.title
    doAssert s.otherRunning == 2 and s.queued == 2
    doAssert s.others == "2 more running, 2 queued", s.others

  block cancelState:
    var close = running(7, "Close a.sgy")
    close.spec.cancellable = false
    doAssert not jobStatus([close], t0).cancellable
    var asked = running(8, "Open a.sgy", phase = "indexing")
    asked.cancelRequested = true
    let s = jobStatus([asked], t0)
    doAssert s.cancelling and s.text == "Open a.sgy: indexing (cancelling)", s.text

  block stickyChoice:
    let a = running(1, "Open a.sgy", started = 5)
    let b = running(2, "Open b.sgy", started = 6)
    let o = running(3, "Open c.sgy", started = 1)
    doAssert jobStatus([a, b], t0 + secs(7)).job == JobId(1)
    doAssert jobStatus([b, a], t0 + secs(7), prefer = JobId(2)).job == JobId(2)
    let s = jobStatus([a, b, o], t0 + secs(7), prefer = JobId(2))
    doAssert s.job == JobId(2) and s.otherRunning == 2, "the shown job is kept"
    # The one shown last has ended: the oldest running one takes over.
    doAssert jobStatus([a, o], t0 + secs(7), prefer = JobId(2)).job == JobId(3)
    var waiting = b
    waiting.state = jsQueued
    doAssert jobStatus([a, waiting], t0, prefer = JobId(2)).job == JobId(1)

  block labelAndElision:
    let s = jobStatus([running(1, "Scan", done = 1, total = 4, phase = "reading")], t0)
    doAssert s.label == "Scan: reading" and s.percent == "25 %", s.label
    doAssert s.text == "Scan: reading 25 %"
    doAssert elide("short", 10) == "short"
    doAssert elide("a longer title", 10) == "a longe..."
    doAssert elide("a longer title", 10).len == 10
    doAssert elide("abcdef", 2) == ".." and elide("abc", 0) == ""
    doAssert elide("äöüäöüäöü", 6) == "äöü..."

when isMainModule:
  main()
