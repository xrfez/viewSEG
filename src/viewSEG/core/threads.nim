## Thread roles, and the guards that check them.
##
## The UI thread owns `AppState`, draws and makes every OpenGL call. Workers
## (the job runners, later the panel threads) do every read and processing
## call that can block (docs/architecture.md, "Threads"). A proc that belongs
## to one side says so in its first line:
##
## ```nim
## proc openSession*(path: string): Session =
##   assertWorkerThread() # reads the file: never on the UI thread
## ```
##
## A thread says what it is with `markUiThread` or `markWorkerThread` before
## its first guarded call; `initAppState` marks the thread that calls it, and
## the job runners mark themselves. A thread that never says (a test's main
## thread, a library's own thread) is `trUnknown`: it passes
## `assertWorkerThread` and fails `assertUiThread`.
##
## The guards are checked in debug builds. Release builds compile them out
## unless `-d:threadGuards` keeps them (`ThreadGuards`). A failed guard is a
## bug in the caller and raises `AssertionDefect`, naming the call site.
##
## **Handing objects to another thread under ORC.** ORC lists the objects
## that may be part of a cycle per thread, but it marks each listed object
## itself, with its place in that thread's list. An object listed by one
## thread and released by another corrupts the second thread's list and
## leaves a dangling entry in the first. A worker therefore calls
## `clearCycleRoots` after making what it hands over and before handing it
## over (the open job does, before it posts its file), and the job runners
## call it after every job. The UI thread closes the files itself, so a
## file's objects are never released on a worker.

type
  ThreadRole* = enum
    trUnknown = "unmarked" ## never marked
    trUi = "UI"            ## the thread that owns the application state
    trWorker = "worker"    ## a job runner, a panel thread

const ThreadGuards* = not defined(release) or defined(threadGuards)
  ## Whether `assertUiThread` and `assertWorkerThread` check anything.

type
  JobCancelledError* = object of CatchableError
    ## Raised by `checkCancelled` of a job's or an item's context; work that
    ## raises it is cancelled (`core/jobs`).

var role {.threadvar.}: ThreadRole
var inItemRun {.threadvar.}: bool

proc markUiThread*() =
  ## Marks the calling thread as the UI thread.
  role = trUi

proc markWorkerThread*() =
  ## Marks the calling thread as a worker.
  role = trWorker

proc threadRole*(): ThreadRole =
  ## The calling thread's role, as last marked.
  role

proc markItemThread*(on: bool) =
  ## Says that the calling thread now runs (or no longer runs) an item of an
  ## item batch (`core/itempool`): a pool worker for good, a job's thread
  ## while it runs one of its own batch's items.
  inItemRun = on

proc inItemThread*(): bool =
  ## Whether the calling thread is running an item of a batch: a batch must
  ## not start another one from there.
  inItemRun

proc clearCycleRoots*() =
  ## Empties the calling thread's list of possible cycle roots, by running
  ## ORC's cycle collector over it, and frees the list. Every object stays
  ## alive unless it was garbage. Nothing to do under ARC.
  when defined(gcOrc):
    GC_runOrc()

proc wrongThread(want, file: string; line: int) {.noinline, noreturn.} =
  # Only constants are passed in: the message is built here, so that nothing
  # the caller made is left behind when this raises.
  raise newException(AssertionDefect, file & "(" & $line & "): this call must run " &
    want & ", but it ran on a thread marked " & $role)

template assertUiThread*() =
  ## Fails unless the calling thread is marked as the UI thread.
  when ThreadGuards:
    if threadRole() != trUi:
      const site = instantiationInfo(-1, fullPaths = false)
      wrongThread("on the UI thread", site.filename, site.line)

template assertWorkerThread*() =
  ## Fails when the calling thread is the UI thread: the call may block.
  when ThreadGuards:
    if threadRole() == trUi:
      const site = instantiationInfo(-1, fullPaths = false)
      wrongThread("off the UI thread", site.filename, site.line)
