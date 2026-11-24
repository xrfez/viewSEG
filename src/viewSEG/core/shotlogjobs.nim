## Background jobs that read a shot log and write its copy (`core/shotlog`).
##
## `importShotLog` reads a file through the file-system layer, refuses one
## larger than 256 MiB without reading it, guesses a map unless one is given,
## and parses. `loadShotLog` reads a project copy with the map stored for it.
## `saveShotLog` writes `toText` to the copy, to a temporary file that is then
## renamed. The file the log was imported from is never named here.
##
## The sink is filled when the job ends, and not when it is cancelled. Read
## it after the job is no longer running. A failed read is one sentence.

import std/os
import filesystem, jobs, project, shotlog

const
  ShotLogCap* = 256'i64 * 1024 * 1024 ## a larger file is refused, and not read
  ReadChunk = 1 shl 20

type
  ShotLogJobResult* = object
    ## What the job did. `ok` false: `reason` is a sentence for the user.
    ## A cancel does not fill this.
    ok*: bool
    reason*: string
    log*: ShotLog
    view*: ShotView
    map*: ShotLogMap
    text*: string ## the text that was parsed, for a later re-map
    dropped*: bool ## a re-map dropped edited cells

  ShotLogSink* = ref object
    ## Filled when the job ends, except when it is cancelled. Read it after
    ## the job is no longer running.
    result*: ShotLogJobResult

proc fileName(path: string): string =
  let name = path.extractFilename
  if name.len > 0: name else: path

proc tooLarge(name: string): string =
  name & " is larger than 256 MiB and was not read."

proc cannotRead(name: string): string =
  name & " could not be read."

proc cannotSave(name: string): string =
  name & " could not be saved."

proc importSpec*(path: string): JobSpec =
  ## The job that reads `path` as a shot log.
  let name = path.fileName
  JobSpec(title: if name.len == 0: "Import shot log" else: "Import " & name,
    lane: jlBackground, reads: @[path])

proc loadSpec*(path: string): JobSpec =
  ## The job that reads a project copy at `path`.
  let name = path.fileName
  JobSpec(title: if name.len == 0: "Load shot log" else: "Load " & name,
    lane: jlBackground, reads: @[path])

proc saveSpec*(path: string): JobSpec =
  ## The job that writes a shot log's copy at `path`.
  let name = path.fileName
  JobSpec(title: if name.len == 0: "Save shot log" else: "Save " & name,
    lane: jlBackground, exclusive: @[path])

proc remapSpec*(path: string): JobSpec =
  ## The job that parses a shot log again with another map.
  let name = path.fileName
  JobSpec(title: if name.len == 0: "Re-map shot log" else: "Re-map " & name,
    lane: jlBackground)

proc fail(sink: ShotLogSink; why: string) =
  if sink != nil: sink.result = ShotLogJobResult(ok: false, reason: why)
  raise newException(ValueError, why)

proc readCapped(ctx: JobContext; path: string; sink: ShotLogSink): string =
  ## The text of `path`, or a sentence and a raise when it is too large or
  ## cannot be read. A cancel leaves `sink` as it was.
  let name = path.fileName
  ctx.checkCancelled()
  var size = 0'i64
  try:
    size = fs.getFileSize(path)
  except OSError:
    fail(sink, cannotRead(name))
  if size > ShotLogCap: fail(sink, tooLarge(name))
  ctx.setPhase("reading")
  ctx.checkCancelled()
  var f = File(nil)
  if not fs.open(f, path, fmRead): fail(sink, cannotRead(name))
  var text = ""
  try:
    var buf = newString(ReadChunk)
    var done = 0
    while true:
      ctx.checkCancelled()
      let n = fs.readBuffer(f, path, addr buf[0], buf.len)
      if n <= 0: break
      if int64(done) + int64(n) > ShotLogCap: fail(sink, tooLarge(name))
      let at = text.len
      text.setLen(at + n)
      if n > 0: copyMem(addr text[at], addr buf[0], n)
      done += n
      discard ctx.progress(int64(done), if size > 0: size else: int64(done))
  except JobCancelledError:
    raise
  except ValueError:
    raise
  except CatchableError:
    fail(sink, cannotRead(name))
  finally:
    close(f)
  text

proc fill(sink: ShotLogSink; log: ShotLog; view: ShotView; map: ShotLogMap; text: string;
    dropped = false) =
  if sink != nil:
    sink.result = ShotLogJobResult(ok: true, log: log, view: view, map: map, text: text,
      dropped: dropped)

proc importShotLog*(path: string; map: ShotLogMap; given: bool; sink: ShotLogSink): JobWork =
  ## The work of a job that reads `path` (`importSpec` is the spec to submit
  ## it with). `given`: use `map`; otherwise guess one. Worker-only. A cancel
  ## raises `JobCancelledError` and leaves `sink` as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let text = readCapped(ctx, path, sink)
    ctx.checkCancelled()
    let used = if given: map else: guessMap(text)
    let log = parseShotLog(text, used)
    ctx.checkCancelled()
    let view = shots(log, used)
    ctx.checkCancelled()
    fill(sink, log, view, used, text)

proc loadShotLog*(path: string; map: ShotLogMap; sink: ShotLogSink): JobWork =
  ## The work of a job that reads the project copy at `path` with `map`
  ## (`loadSpec` is the spec). Worker-only. A cancel leaves `sink` as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let text = readCapped(ctx, path, sink)
    ctx.checkCancelled()
    let log = parseShotLog(text, map)
    ctx.checkCancelled()
    let view = shots(log, map)
    ctx.checkCancelled()
    fill(sink, log, view, map, text)

proc writeCopy(ctx: JobContext; dest, text: string; sink: ShotLogSink) =
  ## Writes `text` to `dest` through a temporary file, then renames. A cancel
  ## removes the temporary file and leaves `sink` as it was.
  let name = dest.fileName
  let tmp = dest & "." & $int(ctx.id) & ".tmp"
  var aside = ""
  try:
    fs.createDir(dest.parentDir)
    var f = File(nil)
    if not fs.open(f, tmp, fmWrite): fail(sink, cannotSave(name))
    try:
      if text.len > 0 and fs.writeBuffer(f, tmp, unsafeAddr text[0], text.len) != text.len:
        fail(sink, cannotSave(name))
      flushFile(f)
    finally:
      close(f)
    ctx.checkCancelled()
    if fs.fileExists(dest):
      aside = dest & "." & $int(ctx.id) & ".old"
      fs.moveFile(dest, aside)
    fs.moveFile(tmp, dest)
    if aside.len > 0: discard fs.tryRemoveFile(aside)
  except JobCancelledError:
    discard fs.tryRemoveFile(tmp)
    if aside.len > 0:
      try: fs.moveFile(aside, dest)
      except CatchableError: discard
    raise
  except ValueError:
    discard fs.tryRemoveFile(tmp)
    raise
  except CatchableError:
    discard fs.tryRemoveFile(tmp)
    if aside.len > 0:
      try: fs.moveFile(aside, dest)
      except CatchableError: discard
    fail(sink, cannotSave(name))

proc saveShotLog*(dir, name: string; log: ShotLog; map: ShotLogMap; sink: ShotLogSink):
    JobWork =
  ## The work of a job that writes `log` as `shotlogs/name` under `dir`
  ## (`saveSpec` is the spec, of that path). Worker-only. A cancel leaves
  ## `sink` as it was and does not replace the copy.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if log == nil or not name.isShotLogFile: fail(sink, cannotSave(name))
    ctx.setPhase("writing")
    ctx.checkCancelled()
    let text = log.toText()
    ctx.checkCancelled()
    writeCopy(ctx, dir.partOf(name.shotLogCopy), text, sink)
    ctx.checkCancelled()
    let view = shots(log, map)
    ctx.checkCancelled()
    fill(sink, log, view, map, text)

proc remapShotLog*(original: string; log: ShotLog; map: ShotLogMap; sink: ShotLogSink):
    JobWork =
  ## The work of a job that parses `original` with `map`. When `log` has
  ## edits and the column count is unchanged, those edits are kept; when the
  ## count changes they are dropped and `dropped` is set. Worker-only. A
  ## cancel leaves `sink` as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase("reading")
    ctx.checkCancelled()
    let parsed = parseShotLog(original, map)
    var dropped = false
    var outLog = parsed
    if log != nil and log.changed:
      if parsed.width == log.width: outLog = parseShotLog(log.toText(), map)
      else: dropped = true
    ctx.checkCancelled()
    let view = shots(outLog, map)
    ctx.checkCancelled()
    fill(sink, outLog, view, map, original, dropped)

proc rebuildShotLog*(log: ShotLog; map: ShotLogMap; sink: ShotLogSink): JobWork =
  ## The work of a job that builds `shots` of `log` again. Worker-only.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if log == nil: fail(sink, "The shot log could not be read.")
    let view = shots(log, map)
    ctx.checkCancelled()
    fill(sink, log, view, map, "")
