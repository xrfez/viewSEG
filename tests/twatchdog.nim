## The frame watchdog, fed exact clock readings: frames within budget pass,
## a frame over budget is reported with its parts in order and described
## longest part first, and calls out of order do no harm.
##
## Seen to fail: with `endFrame` not closing the last part, `slowFrame`
## lost "render"; with the over-budget test turned into `>=`, `atBudget`
## reported a frame of exactly 50 ms; with waiting parts counted as work,
## `waitsDoNotCount` reported a frame that mostly waited for the display;
## with `take` reporting every time, `digestReportsOncePerSecond` got "two
## reports within a second".

import std/strutils
import viewSEG/core/watchdog

let t0 = getMonoTime()

proc at(ms: int): MonoTime = t0 + initDuration(milliseconds = ms)

proc main*() =

  block withinBudget:
    var dog = initFrameWatchdog()
    dog.beginFrame(at(0))
    dog.phase("draw", at(5))
    doAssert dog.endFrame(at(20)).isNone
    doAssert dog.frames == 1 and dog.slowFrames == 0

  block slowFrame:
    var dog = initFrameWatchdog()
    dog.beginFrame(at(0))
    doAssert dog.endFrame(at(10)).isNone # frame 0
    dog.beginFrame(at(100))
    dog.phase("events", at(101))
    dog.phase("draw", at(103))
    dog.phase("render", at(163))
    let slow = dog.endFrame(at(166))
    doAssert slow.isSome
    let s = slow.get
    doAssert s.frame == 1 and s.took == initDuration(milliseconds = 66)
    doAssert s.budget == DefaultFrameBudget
    var labels: seq[string]
    for p in s.phases: labels.add p.label
    doAssert labels == @["start", "events", "draw", "render"], $labels
    doAssert s.phases[2].took == initDuration(milliseconds = 60)
    doAssert describe(s) ==
      "Frame 1 took 66 ms (budget 50 ms): draw 60 ms, render 3 ms, events 2 ms, start 1 ms.",
      describe(s)
    doAssert dog.frames == 2 and dog.slowFrames == 1

  block atBudget:
    var dog = initFrameWatchdog(initDuration(milliseconds = 50))
    dog.beginFrame(at(0))
    doAssert dog.endFrame(at(50)).isNone, "a frame of exactly the budget is not slow"
    dog.beginFrame(at(50))
    doAssert dog.endFrame(at(101)).isSome

  block outOfOrder:
    var dog = initFrameWatchdog(initDuration(milliseconds = 10))
    dog.phase("ignored", at(0)) # no frame yet
    doAssert dog.endFrame(at(100)).isNone
    doAssert dog.frames == 0
    dog.beginFrame(at(0))
    dog.beginFrame(at(100)) # restarts
    let slow = dog.endFrame(at(115))
    doAssert slow.isSome and slow.get.took == initDuration(milliseconds = 15)
    doAssert slow.get.phases.len == 1 and slow.get.phases[0].label == "start"

  block waitsDoNotCount:
    var dog = initFrameWatchdog()
    dog.beginFrame(at(0))
    dog.phase("draw", at(0))
    dog.phase("swap", at(10), waiting = true)
    doAssert dog.endFrame(at(200)).isNone, "190 ms waiting for the display is not work"
    dog.beginFrame(at(200))
    dog.phase("draw", at(200))
    dog.phase("swap", at(260), waiting = true)
    dog.phase("actions", at(290))
    let s = dog.endFrame(at(291)).get
    doAssert s.took == initDuration(milliseconds = 61)
    doAssert s.phases.len == 4 and s.phases[2].waiting and not s.phases[3].waiting
    doAssert describe(s) == "Frame 1 took 61 ms (budget 50 ms): draw 60 ms, actions 1 ms.",
      describe(s)

  block underAMillisecond:
    var dog = initFrameWatchdog(DurationZero)
    dog.beginFrame(at(0))
    dog.phase("tiny", t0 + initDuration(microseconds = 1))
    let s = dog.endFrame(t0 + initDuration(microseconds = 1500)).get
    doAssert describe(s) == "Frame 0 took 1 ms (budget 0 ms): tiny 1 ms, start < 1 ms.", describe(s)

  block digestReportsOncePerSecond:
    # A loop that stalls every frame tells the log once a second, with a
    # count and the slowest frame, not once a frame.
    proc slow(frame, ms: int): SlowFrame =
      SlowFrame(frame: frame, took: initDuration(milliseconds = ms),
        budget: DefaultFrameBudget)
    var d = initSlowFrameDigest()
    doAssert d.take(at(0)).isNone, "a report with nothing slow"
    d.note slow(3, 80)
    let first = d.take(at(10))
    doAssert first.isSome and first.get.startsWith("Frame 3 took 80 ms"), $first
    for i in 4 .. 9:
      d.note slow(i, if i == 6: 300 else: 60)
      doAssert d.take(at(10 + 100 * (i - 3))).isNone, "two reports within a second"
    let digest = d.take(at(1010))
    doAssert digest.isSome, "no report after a second"
    doAssert digest.get.startsWith("6 slow frames since the last report; the slowest: " &
      "Frame 6 took 300 ms"), digest.get
    doAssert d.take(at(5000)).isNone, "a report with nothing new"

when isMainModule:
  main()
