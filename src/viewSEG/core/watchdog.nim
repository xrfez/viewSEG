## The frame watchdog: notices each frame whose work takes longer than its
## budget, and says what the UI thread was doing in it.
##
## The frame loop names its parts as it goes:
##
## ```nim
## var dog = initFrameWatchdog()
## dog.beginFrame()
## dog.phase "events"
## ... handle events ...
## dog.phase "draw"
## ... draw ...
## dog.phase("swap", waiting = true) # waits for the display under vsync
## ... swap the buffers ...
## let slow = dog.endFrame()
## if slow.isSome: log.add sevWarning, "frame", describe(slow.get)
## ```
##
## The budget is for work: a part marked `waiting` (the buffer swap, a sleep
## while the window is minimized) is kept in the record but not counted.
## Every call takes an optional clock reading, so tests can feed exact times.
## The watchdog works in every build; whether the frame loop uses it in a
## release build is the frontend's choice (`FrameWatchdogOn`).

import std/[algorithm, monotimes, options, strutils, times]

export options, monotimes, times

const
  DefaultFrameBudget* = initDuration(milliseconds = 50)
    ## Three frames at 60 Hz: a frame longer than this is a visible stall.
  FrameWatchdogOn* = not defined(release) or defined(frameWatchdog)
    ## Whether the frame loop runs the watchdog: debug builds, or
    ## `-d:frameWatchdog`.

type
  FramePhase* = object
    ## A named part of a frame and how long it took.
    label*: string
    took*: Duration
    waiting*: bool ## waiting, not working: not counted against the budget

  SlowFrame* = object
    ## A frame over budget.
    frame*: int              ## the frame's number, 0 for the first
    took*: Duration          ## the work: the parts that were not waiting
    budget*: Duration
    phases*: seq[FramePhase] ## every part, in the order they ran

  FrameWatchdog* = object
    ## Times the frames of one frame loop.
    budget: Duration
    frame: int ## the number of the frame being timed (or the next one)
    open: bool
    phaseStart: MonoTime
    current: string
    waiting: bool
    phases: seq[FramePhase]
    slow: int

func initFrameWatchdog*(budget = DefaultFrameBudget): FrameWatchdog =
  ## A watchdog that reports frames whose work takes longer than `budget`.
  FrameWatchdog(budget: budget)

func budget*(w: FrameWatchdog): Duration {.inline.} =
  ## The most work a frame may take without being reported.
  w.budget

func frames*(w: FrameWatchdog): int {.inline.} =
  ## The number of frames ended so far.
  w.frame

func slowFrames*(w: FrameWatchdog): int {.inline.} =
  ## The number of frames that were over budget.
  w.slow

proc closePhase(w: var FrameWatchdog; now: MonoTime) =
  w.phases.add FramePhase(label: move w.current, took: now - w.phaseStart,
    waiting: w.waiting)
  w.phaseStart = now

proc beginFrame*(w: var FrameWatchdog; now = getMonoTime()) =
  ## Starts timing a frame. Time until the first `phase` call counts as
  ## "start". Calling it again before `endFrame` restarts the frame.
  w.open = true
  w.phaseStart = now
  w.current = "start"
  w.waiting = false
  w.phases.setLen 0

proc phase*(w: var FrameWatchdog; label: string; now = getMonoTime(); waiting = false) =
  ## Ends the current part of the frame and starts the part named `label`;
  ## `waiting` when the thread waits in it rather than works. A call outside
  ## a frame is ignored.
  if w.open:
    w.closePhase(now)
    w.current = label
    w.waiting = waiting

proc endFrame*(w: var FrameWatchdog; now = getMonoTime()): Option[SlowFrame] =
  ## Ends the frame. When its work took longer than the budget, the frame and
  ## its parts; nothing otherwise, or outside a frame.
  if not w.open:
    return none(SlowFrame)
  w.closePhase(now)
  w.open = false
  var took = DurationZero
  for p in w.phases:
    if not p.waiting: took += p.took
  if took > w.budget:
    inc w.slow
    result = some(SlowFrame(frame: w.frame, took: took, budget: w.budget,
      phases: move w.phases))
  inc w.frame

func ms(d: Duration): string =
  ## `d` in whole milliseconds; "< 1 ms" below one.
  let n = d.inMilliseconds
  if n == 0 and d > DurationZero: "< 1 ms" else: $n & " ms"

func describe*(s: SlowFrame): string =
  ## The frame in plain words, its longest parts first, waits and empty parts
  ## left out: "Frame 12 took 120 ms (budget 50 ms): draw 110 ms, render 8 ms."
  var parts: seq[FramePhase]
  for p in s.phases:
    if not p.waiting and p.took > DurationZero: parts.add p
  parts.sort(proc (a, b: FramePhase): int = cmp(b.took, a.took))
  var named: seq[string]
  for p in parts:
    named.add p.label & " " & ms(p.took)
  result = "Frame " & $s.frame & " took " & ms(s.took) & " (budget " & ms(s.budget) & ")"
  if named.len > 0:
    result.add ": " & named.join(", ")
  result.add "."

type
  SlowFrameDigest* = object
    ## Slow frames gathered so that the log hears of them at most once per
    ## interval: a frame loop that stalls again and again would otherwise add
    ## a line per frame, and every line makes the log window longer.
    interval: Duration
    told: MonoTime ## when the log was last told; zero before that
    count: int ## slow frames since then
    worst: SlowFrame

func initSlowFrameDigest*(interval = initDuration(seconds = 1)): SlowFrameDigest =
  ## A digest that reports at most once per `interval`.
  SlowFrameDigest(interval: interval)

proc note*(d: var SlowFrameDigest; s: sink SlowFrame) =
  ## Counts slow frame `s`, keeping the slowest one.
  if d.count == 0 or s.took > d.worst.took:
    d.worst = s
  inc d.count

proc take*(d: var SlowFrameDigest; now = getMonoTime()): Option[string] =
  ## The line for the log, once per interval when frames were slow: the
  ## first slow frame at once, then the count since the last line and the
  ## slowest of them. Call it every frame.
  if d.count > 0 and (d.told == MonoTime() or now - d.told >= d.interval):
    result = some(if d.count == 1: describe(d.worst)
      else: $d.count & " slow frames since the last report; the slowest: " &
        describe(d.worst))
    d.count = 0
    d.told = now
