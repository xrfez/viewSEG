## A file system that is slow, hangs or fails on chosen paths: the test side
## of `core/fs`. `install` sets its hook; then, for every call whose path
## starts with a prefix given to `fault`:
##
## - `fkSlow`: moves `fs.now` on by the fault's `delay` (no real wait), so
##   what the viewer measures says the drive is slow;
## - `fkHang`: blocks the calling thread until `release` (or `releaseAll`),
##   as a drive that stops answering holds a thread in the kernel; then the
##   call goes on as the fault then says (`fkFail` if the drive went away);
## - `fkFail`: raises `OSError` ("Input/output error"), as a drive that went
##   away does;
## - `fkPermits`: blocks until the test grants a read (`grant`), one call
##   each: a drive whose every round trip the test times itself.
##
## A fault applies to the calls named in its `ops` (every call by default).
## The hook also **asserts that it is never called on the UI thread**: every
## such call is kept (`uiCalls`) and said on stderr at once, and a test
## checks the list is empty. Calls are counted per kind (`calls`).
##
## Hung calls wait at most `HangLimit` (a forgotten `release` fails a test
## rather than hanging the suite), then fail.

import std/[locks, monotimes, os, strutils, times]
import viewSEG/core/[filesystem, threads]

export filesystem

type
  FaultKind* = enum
    fkNone, fkSlow, fkHang, fkFail, fkPermits

  Fault = object
    prefix: string
    kind: FaultKind
    ops: set[FsOp]
    delay: Duration
    serial: int ## bumped by `release`: the calls hung before it go on

const HangLimit* = initDuration(seconds = 60) ## a hung call fails after this, at the latest

var
  lock: Lock
  changed: Cond
  faults: seq[Fault]
  uiSeen: seq[string]
  counts: array[FsOp, int]
  pathCounts: seq[(FsOp, string)]
  hanging: int
  permits: int

proc find(path: string; op: FsOp): int =
  ## The newest fault whose prefix starts `path` and that covers `op`.
  result = -1
  for i in countdown(faults.high, 0):
    if path.startsWith(faults[i].prefix) and op in faults[i].ops: return i

proc hookCall(op: FsOp; path: string) {.nimcall, gcsafe, raises: [OSError].} =
  {.cast(gcsafe).}:
    var fail = false
    var ui = false
    withLock lock:
      inc counts[op]
      pathCounts.add (op, path)
      if threadRole() == trUi:
        ui = true
        uiSeen.add $op & " " & path
      var i = find(path, op)
      if i >= 0:
        case faults[i].kind
        of fkNone: discard
        of fkSlow: advanceFsClock(faults[i].delay)
        of fkFail: fail = true
        of fkHang:
          let serial = faults[i].serial
          let deadline = getMonoTime() + HangLimit
          inc hanging
          broadcast(changed)
          while i >= 0 and faults[i].kind == fkHang and faults[i].serial == serial and
              getMonoTime() < deadline:
            release(lock)
            sleep 1
            acquire(lock)
            i = find(path, op)
          dec hanging
          broadcast(changed)
          fail = getMonoTime() >= deadline or (i >= 0 and faults[i].kind == fkFail)
          if i >= 0 and faults[i].kind == fkSlow: advanceFsClock(faults[i].delay)
        of fkPermits:
          let deadline = getMonoTime() + HangLimit
          inc hanging
          broadcast(changed)
          while permits == 0 and getMonoTime() < deadline:
            release(lock)
            sleep 1
            acquire(lock)
          dec hanging
          broadcast(changed)
          if permits > 0: dec permits
          else: fail = true
    if ui:
      try:
        stderr.writeLine "faultyfs: called on the UI thread: ", op, " ", path
      except IOError:
        discard
    if fail:
      raise newOSError(OSErrorCode(5), path) # EIO: Input/output error

proc install*() =
  ## Puts this file system in place, with no fault.
  initLock lock
  initCond changed
  setFsHook(hookCall)

proc fault*(prefix: string; kind: FaultKind; ops: set[FsOp] = {low(FsOp) .. high(FsOp)};
    delay = initDuration()) =
  ## From now on, the calls of `ops` on paths starting with `prefix` are
  ## slow, hang, fail or wait for a permit (`kind`); `fkNone` takes such a
  ## fault away. The newest fault that covers a call is the one that holds.
  withLock lock:
    var serial = 0
    for f in faults:
      if f.prefix == prefix: serial = max(serial, f.serial)
    faults.add Fault(prefix: prefix, kind: kind, ops: ops, delay: delay, serial: serial)

proc release*(prefix: string) =
  ## The calls hung on `prefix` go on (as the faults now say): the drive
  ## answers again. Takes its faults away.
  withLock lock:
    var serial = 0
    for f in faults:
      if f.prefix == prefix: serial = max(serial, f.serial)
    var kept: seq[Fault]
    for f in faults:
      if f.prefix != prefix: kept.add f
    faults = kept
    faults.add Fault(prefix: prefix, kind: fkNone, ops: {}, serial: serial + 1)

proc releaseAll*() =
  ## Takes every fault away: every hung call goes on.
  withLock lock:
    faults.setLen 0
    permits = high(int) div 2

proc grant*(n = 1) =
  ## Lets `n` more calls that wait for a permit go on.
  withLock lock:
    permits += n

proc hung*(): int =
  ## How many calls are held now (hung, or waiting for a permit).
  withLock lock:
    result = hanging

proc uiCalls*(): seq[string] =
  ## The calls made on the UI thread, which the viewer must never make.
  withLock lock:
    result = uiSeen

proc calls*(op: FsOp; prefix = ""): int =
  ## How many calls of `op` were made, on paths starting with `prefix`.
  withLock lock:
    if prefix.len == 0: return counts[op]
    for (o, p) in pathCounts:
      if o == op and p.startsWith(prefix): inc result

proc resetCounts*() =
  ## Counts from 0 again.
  withLock lock:
    counts = default(array[FsOp, int])
    pathCounts.setLen 0
