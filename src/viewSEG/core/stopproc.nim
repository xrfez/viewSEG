## The give-up callback of the reader thread's long jobs (a sort, a column read).

type StopProc* = proc (): bool {.gcsafe, raises: [].}
  ## True when the work should give up (something newer is waiting).
