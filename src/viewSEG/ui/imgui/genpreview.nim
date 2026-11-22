## The Generate dialog's preview, computed off the UI thread.
##
## A long sweep (a minute at a fraction of a millisecond) is a sweep and a
## spectrum, and that must not stall a frame. One worker takes the newest
## request, the way a reference job takes its work, and the dialog keeps the
## last good picture until the new one is ready. The worker does not read a
## file and is not a listed job: a preview is not something the Jobs window
## should queue.

import std/[locks, math]
import ../../core/[references, threads]

type
  GenAsk = object
    gen: int
    serial: int
    g: GeneratedReference ## the settings, the name left empty

  GenReady = object
    samples: seq[float32]
    hz, db: seq[float64]
    problem: string
    delay: float64

  PreviewBox = object
    lock: Lock
    changed: Cond
    ask: GenAsk
    askSerial, takenSerial: int
    ready: GenReady
    readyGen, readySerial, givenSerial: int
    readyKey: string
    quit, started: bool
    thread: Thread[ptr PreviewBox]

var box: ptr PreviewBox

proc toGenerated(a: GenAsk): GeneratedReference =
  a.g

proc takeAsk(p: ptr PreviewBox): GenAsk =
  withLock p.lock:
    while not p.quit and p.askSerial == p.takenSerial:
      wait(p.changed, p.lock)
    if p.quit: return
    result = p.ask
    p.takenSerial = p.askSerial

proc runPreview(p: ptr PreviewBox) {.thread.} =
  markWorkerThread()
  while true:
    let ask = p.takeAsk()
    if ask.gen == 0: break
    var made = GenReady(samples: @[], hz: @[], db: @[], delay: NaN)
    try:
      let built = buildGeneratePreview(ask.toGenerated)
      made.samples = built.samples
      made.hz = built.hz
      made.db = built.db
      made.problem = built.problem
      made.delay = built.delay
    except CatchableError as e:
      made.problem = e.msg
    clearCycleRoots()
    let key = generateSettingsKey(ask.toGenerated)
    withLock p.lock:
      if p.quit: break
      # A newer ask, even one that reused this generation number, wins.
      if p.askSerial == ask.serial:
        p.ready = move made
        p.readyGen = ask.gen
        p.readyKey = key
        p.readySerial = ask.serial

proc ensureWorker() =
  if box != nil: return
  let p = cast[ptr PreviewBox](allocShared0(sizeof(PreviewBox)))
  initLock p.lock
  initCond p.changed
  createThread(p.thread, runPreview, p)
  p.started = true
  box = p

proc askGeneratePreview*(gen: int; g: GeneratedReference) =
  ## Asks for a preview of `g`, numbered `gen`. A newer ask wins even when it
  ## reuses `gen`; a finished result is kept only while its settings are still
  ## the latest ask. The name is not copied: the worker does not need it.
  if gen <= 0: return
  ensureWorker()
  withLock box.lock:
    inc box.askSerial
    var copy = g
    copy.name = ""
    box.ask = GenAsk(gen: gen, serial: box.askSerial, g: copy)
    signal box.changed

proc takeGeneratePreview*(): tuple[gen: int; samples: seq[float32]; hz, db: seq[float64];
    problem, key: string; got: bool; delay: float64] =
  ## The newest preview the worker has finished and this thread has not taken,
  ## or `got` false. `key` is the settings it was computed for. UI thread.
  result.samples = @[]
  result.hz = @[]
  result.db = @[]
  result.delay = NaN
  if box == nil: return
  withLock box.lock:
    if box.readySerial == 0 or box.readySerial == box.givenSerial: return
    result.gen = box.readyGen
    result.samples = move box.ready.samples
    result.hz = move box.ready.hz
    result.db = move box.ready.db
    result.problem = move box.ready.problem
    result.delay = box.ready.delay
    result.key = box.readyKey
    result.got = true
    box.givenSerial = box.readySerial
    box.ready = GenReady(samples: @[], hz: @[], db: @[], delay: NaN)
    box.readyKey = ""

proc stopGeneratePreview*() =
  ## Ends the worker and waits for it. Idempotent. A preview still computing
  ## finishes first: it does not read a file, so the wait is the sweep.
  if box == nil or not box.started: return
  withLock box.lock:
    box.quit = true
    signal box.changed
  joinThread(box.thread)
  box.started = false
  box.ready = GenReady()
  deinitCond box.changed
  deinitLock box.lock
  deallocShared(box)
  box = nil
