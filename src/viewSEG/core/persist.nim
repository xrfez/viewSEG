## What the program keeps on disk between runs, and how its files are named:
## the settings (`settings.nif` in the configuration folder), their
## backups, and the session logs (one file per run in the log folder, the
## newest kept).
##
## **Reading the settings** (`loadSettings`, at start-up, before the window
## opens: where it opens is one of them). A file that is not there gives
## the defaults and says nothing (a first run). A file that cannot be read
## at all, being damaged, cut short or not NIF, is moved aside as a backup
## and the defaults are used; one that reads but holds settings that cannot
## be used (unknown, out of range) gives everything else, and a copy of it
## as it was is kept beside it, since the next save writes over it. Either
## way the log says so, with the line and the backup's name: settings are
## never lost without a word. A release may carry *site defaults*
## (`config/settings.nif` next to a program that is not portable): they
## stand in for the built-in defaults under the user's own file.
##
## The files are written by the disk thread (`core/diskio`); `AppState`
## decides when (`logTo`, `keepSettingsIn`, `persist`).

import std/[algorithm, os, times]
import log, nif, settings, settingsnif

export settingsnif

const
  SessionLogPrefix* = "viewSEG-" ## a session log's name: prefix, start time, process id
  SessionLogSuffix* = ".log"
  KeptSessionLogs* = 20          ## session logs kept in the log folder, this run's included
  SettingsFileName* = "settings.nif"
  BackupSuffix* = ".bak"
  KeptBackups* = 5               ## backups kept of a document
  MaxProblemLines = 20           ## problems listed one by one; the rest are counted

type
  Note* = tuple[severity: Severity, text: string]
    ## Something to say in the log.

  LoadedSettings* = object
    ## What `loadSettings` found.
    settings*: Settings
    defaults*: Settings ## what a reset goes back to: the built-in defaults, or the site's
    notes*: seq[Note]   ## what to log about it
    saveable*: bool
      ## false when the file could neither be read nor moved aside: saving
      ## would write over it
    rewrite*: bool
      ## the file is to be written again soon, without what could not be
      ## used (or afresh, after it was moved aside)

func sessionLogName*(start: DateTime; pid: int): string =
  ## The name of the log of a run that started at `start` (local time) as
  ## process `pid`: "viewSEG-20261114-153012-4711.log". Names sort by start.
  SessionLogPrefix & start.format("yyyyMMdd'-'HHmmss") & "-" & $pid & SessionLogSuffix

proc sessionLogPath*(dir: string): string =
  ## Where this run's log goes in `dir`.
  dir / sessionLogName(now(), getCurrentProcessId())

proc backupPath*(path: string; at = now()): string =
  ## A name for a backup of `path` that no file has yet:
  ## "settings.nif.20261114-153012.bak", then "...-2.bak" and on.
  let stem = path & "." & at.format("yyyyMMdd'-'HHmmss")
  result = stem & BackupSuffix
  var n = 2
  while fileExists(result):
    result = stem & "-" & $n & BackupSuffix
    inc n

proc pruneBackups*(path: string; keep = KeptBackups) =
  ## Removes all but the newest `keep` backups of `path` (by name). Files
  ## that cannot be removed are left.
  var names: seq[string]
  let prefix = path.extractFilename & "."
  for kind, f in walkDir(path.parentDir):
    let name = f.extractFilename
    if kind == pcFile and name.len > prefix.len + BackupSuffix.len and
        name[0 ..< prefix.len] == prefix and name[^BackupSuffix.len .. ^1] == BackupSuffix:
      names.add f
  names.sort() # by name: by time
  for i in 0 ..< names.len - keep:
    try:
      removeFile(names[i])
    except OSError:
      discard

proc readDocument*(path: string; text: var string): string =
  ## Reads the document at `path` into `text`: "" when it was read, else
  ## why not, in plain words. One larger than `MaxNifBytes` is not read.
  result = ""
  try:
    let size = getFileSize(path)
    if size > MaxNifBytes:
      result = "it is larger than " & $(MaxNifBytes shr 20) & " MB"
    else:
      text = readFile(path)
  except IOError, OSError:
    result = getCurrentExceptionMsg()
    if result.len == 0: result = "it cannot be read"

proc addProblems(notes: var seq[Note]; problems: openArray[string]) =
  for i, p in problems:
    if i < MaxProblemLines: notes.add (sevWarning, p)
  if problems.len > MaxProblemLines:
    notes.add (sevWarning, $(problems.len - MaxProblemLines) & " more problems in the " &
      "same file are not listed.")

proc loadSettings*(file: string; site = ""): LoadedSettings =
  ## The settings in `file` over the site defaults in `site` ("" or a file
  ## that is not there: the built-in defaults), as the module documentation
  ## says. Never raises: what went wrong is in `notes`.
  result = LoadedSettings(saveable: true)
  if site.len > 0 and fileExists(site):
    var text = ""
    let why = readDocument(site, text)
    if why.len > 0:
      result.notes.add (sevWarning, "The site's default settings in " & site &
        " could not be read (" & why & "); the built-in defaults stand in for them.")
    else:
      var problems: seq[string]
      try:
        result.defaults = readSettings(text, site, Settings(), problems)
        result.notes.addProblems(problems)
      except NifError as e:
        result.notes.add (sevWarning, "The site's default settings could not be read (" &
          e.msg & "); the built-in defaults stand in for them.")
  result.settings = result.defaults
  if not fileExists(file): return
  var text = ""
  var why = readDocument(file, text)
  var problems: seq[string]
  if why.len == 0:
    try:
      result.settings = readSettings(text, file.extractFilename, result.defaults, problems)
    except NifError as e:
      why = e.msg
  if why.len > 0:
    let backup = backupPath(file)
    try:
      moveFile(file, backup)
      result.rewrite = true
      result.notes.add (sevWarning, "The settings could not be read: " & why & ". The " &
        "file was moved to " & backup & ", and this run starts from the default settings.")
    except OSError, IOError:
      result.saveable = false
      result.notes.add (sevWarning, "The settings in " & file & " could not be read (" &
        why & ") nor moved aside (" & getCurrentExceptionMsg() & "). This run uses the " &
        "default settings and does not save them, so the file stays as it is.")
  elif problems.len > 0:
    let backup = backupPath(file)
    result.rewrite = true
    try:
      copyFile(file, backup)
      result.notes.add (sevWarning, "Some of the settings in " & file & " could not be " &
        "used; a copy of the file as it was is in " & backup & ":")
    except OSError, IOError:
      result.notes.add (sevWarning, "Some of the settings in " & file & " could not be " &
        "used (no copy of the file could be kept: " & getCurrentExceptionMsg() & "):")
    result.notes.addProblems(problems)
  pruneBackups(file)
