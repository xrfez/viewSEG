## What the program keeps on disk between runs, and how its files are named:
## the session logs (one file per run in the log folder, the newest kept).
##
## The files are written by the disk thread (`core/diskio`); `AppState`
## decides when (`logTo`, `persist`).

import std/[os, times]

const
  SessionLogPrefix* = "viewSEG-" ## a session log's name: prefix, start time, process id
  SessionLogSuffix* = ".log"
  KeptSessionLogs* = 20          ## session logs kept in the log folder, this run's included

func sessionLogName*(start: DateTime; pid: int): string =
  ## The name of the log of a run that started at `start` (local time) as
  ## process `pid`: "viewSEG-20261114-153012-4711.log". Names sort by start.
  SessionLogPrefix & start.format("yyyyMMdd'-'HHmmss") & "-" & $pid & SessionLogSuffix

proc sessionLogPath*(dir: string): string =
  ## Where this run's log goes in `dir`.
  dir / sessionLogName(now(), getCurrentProcessId())
