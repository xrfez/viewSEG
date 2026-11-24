## Background jobs that read a shot log and write its copy (`core/shotlog`).
##
## `importShotLog` reads a file through the file-system layer, refuses one
## larger than 256 MiB without reading it, and parses. A map given is used;
## otherwise a remembered map is used when `remember` is set and it fits the
## file, and a guess otherwise. A header name longer than a shot log's name,
## after trimming, does not fit. `loadShotLog` reads a project copy with the
## map stored for it.
## `saveShotLog` writes `toText` to the copy, to a temporary file that is then
## renamed onto it. The file the log was imported from is never named here.
##
## The sink is filled when the job ends, and not when it is cancelled. Read
## it after the job is no longer running. A failed read is one sentence.

import std/[os, strutils]
import filesystem, jobs, project, shotfollow, shotlog, shotmap, survey

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
    text*: string ## the text parsed into `log`; the state does not keep another copy
    dropped*: bool ## a re-map dropped edited cells
    usedLast*: bool ## the project's last column map was used; a guess leaves this false
    index*: ref ShotIndex ## the view arranged for follow; nil when there is no log
    layer*: ref SurveyLayer
      ## the shots as a map layer (`core/shotmap`), its log's id not set yet; nil when the
      ## log has no positions

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

proc cannotRemove(name: string): string =
  name & " could not be removed."

func isJobTemporary(name: string): bool =
  ## Whether `name` ends as a shot-log copy's temporary file does:
  ## `.<digits of a job>.tmp`.
  if not name.endsWith(".tmp"): return false
  let stem = name[0 ..< name.len - 4]
  var n = 0
  while n < stem.len and stem[stem.len - 1 - n] in {'0' .. '9'}: inc n
  n > 0 and n < stem.len and stem[stem.len - 1 - n] == '.'

proc sweepShotLogTemps*(dir: string; recorded: openArray[StoredShotLog]) =
  ## Removes temporary copies an earlier run left in `shotlogs/` (it was cut
  ## short). Only a name made as a job makes it, and never one that is a
  ## recorded copy: a shot log may be named `day1.tmp`.
  let folder = dir.partOf(ShotLogsFolder)
  var names: seq[string] = @[]
  for s in recorded: names.add s.file
  try:
    if fs.dirExists(folder):
      for kind, path in fs.walkDir(folder):
        if kind == pcFile and path.extractFilename.isJobTemporary and
            path.extractFilename notin names: discard fs.tryRemoveFile(path)
  except OSError:
    discard

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

proc removeSpec*(path: string): JobSpec =
  ## The job that removes a project copy at `path`. It needs the path to
  ## itself, so it waits for a save of that copy. Its end is not announced
  ## when it went well.
  let name = path.fileName
  JobSpec(title: if name.len == 0: "Remove shot log" else: "Remove " & name,
    lane: jlBackground, exclusive: @[path], auto: true)

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

proc boxedIndex(view: ShotView): ref ShotIndex =
  ## The view arranged for follow. A ref so the UI thread takes it without
  ## copying the tables.
  new result
  result[] = buildShotIndex(view)

proc fill(sink: ShotLogSink; log: ShotLog; view: ShotView; map: ShotLogMap; text: string;
    dropped = false; usedLast = false) =
  if sink != nil:
    var index: ref ShotIndex = nil
    var layer: ref SurveyLayer = nil
    if log != nil:
      index = boxedIndex(view)
      layer = shotLayer(view, map)
    sink.result = ShotLogJobResult(ok: true, log: log, view: view, map: map, text: text,
      dropped: dropped, usedLast: usedLast, index: index, layer: layer)

proc clippedHeader(name: string): string =
  ## `name` as a remembered header is compared: ends trimmed, capitals ignored.
  name.strip().toLowerAscii

proc sameHeader(a, b: string): bool =
  clippedHeader(a) == clippedHeader(b)

proc rememberedFits(log: ShotLog; map: ShotLogMap; headers: openArray[string]): bool =
  ## The remembered map fits when the column count is the same and, when
  ## there is a header, the header names are the same. A file with any header
  ## name longer than a shot log's name, after trimming, does not fit.
  if log == nil or log.width != map.roles.len: return false
  if not map.hasHeader: return true
  if headers.len != log.width: return false
  for col in 0 ..< log.width:
    let name = log.columnName(col)
    if name.len > MaxShotLogName: return false
    if not sameHeader(name, headers[col]): return false
  true

proc importShotLog*(path: string; map: ShotLogMap; given: bool; sink: ShotLogSink;
    remembered: ShotLogMap; remember: bool; headers: seq[string]): JobWork =
  ## The work of a job that reads `path` (`importSpec` is the spec to submit
  ## it with). `given`: use `map`. Otherwise, when `remember` is set and
  ## `remembered` fits the file (same column count, and the same header names
  ## when there is a header; a header name longer than a shot log's name does
  ## not fit), use that; else guess one. `headers` are the
  ## names beside `remembered`. Worker-only. A cancel raises
  ## `JobCancelledError` and leaves `sink` as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    let text = readCapped(ctx, path, sink)
    ctx.checkCancelled()
    var used = map
    var usedLast = false
    var log: ShotLog = nil
    if given:
      var parsed = text
      log = parseShotLog(parsed, map)
    elif remember:
      var first = text
      let tried = parseShotLog(first, remembered)
      if rememberedFits(tried, remembered, headers):
        log = tried
        used = remembered
        usedLast = true
      else:
        used = guessMap(text)
        var again = text
        log = parseShotLog(again, used)
    else:
      used = guessMap(text)
      var parsed = text
      log = parseShotLog(parsed, used)
    ctx.checkCancelled()
    let view = shots(log, used)
    ctx.checkCancelled()
    fill(sink, log, view, used, text, usedLast = usedLast)

proc importShotLog*(path: string; map: ShotLogMap; given: bool; sink: ShotLogSink): JobWork =
  ## `importShotLog` that guesses a map when `given` is false.
  importShotLog(path, map, given, sink, ShotLogMap(), false, newSeq[string]())

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
  ## Writes `text` to a temporary file beside `dest`, then renames it onto
  ## `dest`. The copy already there is not moved aside: one rename replaces
  ## it. A cancel removes the temporary file and leaves `dest` and `sink`
  ## as they were.
  let name = dest.fileName
  let tmp = dest & "." & $int(ctx.id) & ".tmp"
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
    fs.moveFile(tmp, dest)
  except JobCancelledError:
    discard fs.tryRemoveFile(tmp)
    raise
  except ValueError:
    discard fs.tryRemoveFile(tmp)
    raise
  except CatchableError:
    discard fs.tryRemoveFile(tmp)
    fail(sink, cannotSave(name))

proc removeShotLogCopy*(path: string; sink: ShotLogSink): JobWork =
  ## The work of a job that removes the project copy at `path` (`removeSpec`
  ## is the spec). A file that is already gone is success. Worker-only. A
  ## cancel leaves the file as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    ctx.setPhase("removing")
    ctx.checkCancelled()
    if fs.fileExists(path) and (not fs.tryRemoveFile(path) or fs.fileExists(path)):
      fail(sink, cannotRemove(path.fileName))
    ctx.checkCancelled()
    fill(sink, nil, ShotView(), ShotLogMap(), "")

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

proc remapShotLog*(log: ShotLog; map: ShotLogMap; sink: ShotLogSink): JobWork =
  ## The work of a job that parses `log`'s own text with `map`. When `log`
  ## has edits and the column count is unchanged, those edits are kept; when
  ## the count changes they are dropped and `dropped` is set. The new log's
  ## text is what was parsed, so a later re-map sees the edits that were
  ## kept. Worker-only. A cancel leaves `sink` as it was.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.setPhase("reading")
    ctx.checkCancelled()
    if log == nil: fail(sink, "The shot log could not be read.")
    let original = log.text
    let parsed = parseShotLog(original, map)
    var dropped = false
    var outLog = parsed
    var carried = original
    if log.changed:
      if parsed.width == log.width:
        carried = log.toText()
        outLog = parseShotLog(carried, map)
      else: dropped = true
    ctx.checkCancelled()
    let view = shots(outLog, map)
    ctx.checkCancelled()
    fill(sink, outLog, view, map, carried, dropped)

proc rebuildShotLog*(log: ShotLog; map: ShotLogMap; sink: ShotLogSink): JobWork =
  ## The work of a job that builds `shots` of `log` again. Worker-only.
  result = proc (ctx: JobContext) {.gcsafe.} =
    ctx.checkCancelled()
    if log == nil: fail(sink, "The shot log could not be read.")
    let view = shots(log, map)
    ctx.checkCancelled()
    fill(sink, log, view, map, "")
