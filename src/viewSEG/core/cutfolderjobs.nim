## Slices every recording of a folder at the times of a shot log. A background job
## (`cutFolderWork`) with two passes: the first opens each file of the folder in name
## order and works out whether it can be sliced and the time it spans; the second
## writes, for each file that can, the records of the shots whose window it holds, with
## the routine that slices one recording (`cutGather`).
##
## A shot goes to the first file, in name order, whose span holds its whole window
## (the shot's time plus the options' start, for the record length). A shot that no
## file holds is counted once for the folder and the first few are named. A file that
## is not seismic, is a signature file, is not a continuous receiver gather, holds no
## shot or would write a name another file writes or a file that is already there is
## skipped (a destination in the folder of the recording or of an open file is one), and its
## reason is in the result; one that fails while it is written does
## not stop the others. Each output is named as a single slice names it
## (`defaultName`), in the destination folder, and nothing is ever replaced.
##
## With `write` false the job only does the first pass: what the window shows before a
## run. The result is filled as the job goes, so a cancel leaves what was done.

import std/[algorithm, math, options, os, strutils, times]
import parseSEG
import cutfile, cutgather, cutgatherjobs, filejobs, filesystem, jobs, outputjobs, recordingkind,
  session, shotlog, threads, vendormaps

const
  NotRecording* = "not a SEG-Y, SEG-D or SEG-2 file" ## why a file that is not seismic is skipped
  SignatureFile* = "a signature file is not a recording that can be sliced"
  NoShotHeld* = "no shot of the log has its whole record inside this recording"
  NamedMax* = 5                                      ## how many unplaced shots the result names
  Unit = 1000'i64 ## the job's progress is this many units for each step of a file

type
  FolderFile* = object
    path*: string
    skip*: string            ## why the file is not sliced; "" when it is
    shots*: int              ## shots whose window the file holds
    firstUs*, lastUs*: int64 ## the span of its segments, UTC microseconds
    dest*: string            ## the file its slice is written to
    written*: bool
    reason*: string          ## why writing it failed
    line*: string            ## the slice's own first sentence when it was written
    shotsWritten*: int

  FolderResult* = object
    folder*: string
    files*: seq[FolderFile]
    noTime*: int                ## rows of the log without a time
    unplaced*: int              ## shots whose window no file holds
    unplacedNamed*: seq[string] ## the first few, by their file number or time
    listed*: bool               ## the first pass is over
    finished*: bool             ## the job ended well
    reason*: string             ## why the job failed, when it did

  FolderSink* = ref object
    ## Filled as the job goes. Read it after the job is no longer running.
    result*: FolderResult

  FolderPlan* = object
    ## What the job needs.
    folder*, destFolder*: string
    rows*: seq[Shot]     ## the rows of the shot log
    opts*: CutOptions
    cacheDir*: string    ## the folder of the index caches
    others*: seq[string] ## the paths of the files that are open: never a destination
    write*: bool

func nameTakenWords(name, other: string): string =
  ## Why a file's slice is not written: another file's slice has its name.
  "its slice would be named " & name & ", as the slice of " & other & " is: not written"

func nameThereWords(name: string): string =
  ## Why a file's slice is not written: the name is taken in the destination folder.
  name & " is already in the destination folder: not written"

func cutFolderSpec*(folder: string; write: bool): JobSpec =
  ## The job that works on `folder`: background, reading it.
  let name = folder.extractFilename
  JobSpec(title: (if write: "Slice " else: "Check ") & (if name.len == 0: folder else: name),
    lane: jlBackground, reads: @[folder], auto: not write)

func sliceable*(f: FolderFile): bool {.inline.} =
  ## Whether the file will be written: it can be sliced and holds a shot.
  f.skip.len == 0 and f.shots > 0

func countSliceable*(r: FolderResult): int =
  for f in r.files:
    if f.sliceable: inc result

func countWritten*(r: FolderResult): int =
  for f in r.files:
    if f.written: inc result

func countFailed*(r: FolderResult): int =
  for f in r.files:
    if f.reason.len > 0: inc result

proc shotWords(s: Shot): string =
  ## A shot by its file number, else its time.
  if s.fileNumber.isSome: "file " & $s.fileNumber.get
  elif s.timeUtcUs.isSome:
    fromUnix(s.timeUtcUs.get div 1_000_000).utc.format("yyyy-MM-dd HH:mm:ss") & " UTC"
  else: "a row"

proc inspect(ctx: JobContext; path, cacheDir: string): FolderFile =
  ## Opens `path` and says whether it can be sliced, and the time it spans.
  result = FolderFile(path: path)
  var s: Session = nil
  try:
    fs.unmappedFail(path)
    let index = indexCacheFile(cacheDir, path)
    s = openSession(path, nil, if index.len > 0 and fs.fileExists(index): index else: "")
    if s.file.kind == skUnknown: result.skip = NotRecording
    elif s.isSignature: result.skip = SignatureFile
    elif s.file.len == 0: result.skip = "it has no traces"
    else:
      let dtMs = s.file.sampleIntervalUs(0) / 1000
      if dtMs <= 0: result.skip = NoSampleIntervalWords
      else:
        {.cast(gcsafe).}:
          let plan = planRecording(s.filePtr, path, dtMs, currentVendors(),
            proc () {.gcsafe.} = ctx.checkCancelled())
          let why = cutWhy(s.file)
          if why.len > 0: result.skip = why
          else:
            let facts = describeRecording(plan, AllStarts)
            if facts.segments == 0: result.skip = NoLiveTraceWords
            else:
              let refusal = cutRefusal(facts)
              if refusal.len > 0: result.skip = refusal
              else:
                result.firstUs = int64(round(facts.firstTime * 1e6))
                result.lastUs = int64(round(facts.lastTime * 1e6))
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except JobCancelledError:
    raise
  except CatchableError as e:
    result.skip = if e.msg.len > 0: firstLine(e.msg) else: $e.name
  finally:
    if s != nil: discard s.close()
    s = nil
    clearCycleRoots()

func windowUs(s: Shot; opts: CutOptions): tuple[a, b: int64] =
  ## The window of the record of timed shot `s`: from its time plus the start, for the length.
  let a = s.timeUtcUs.get + int64(round(opts.startMs * 1000))
  (a, a + int64(round(opts.recordMs * 1000)))

proc place(plan: FolderPlan; files: var seq[FolderFile]; held: var seq[seq[Shot]];
    res: var FolderResult) =
  ## Gives each shot to the first file that can be sliced and holds its window.
  held.setLen files.len
  for s in plan.rows:
    if s.timeUtcUs.isNone:
      inc res.noTime
      continue
    let w = windowUs(s, plan.opts)
    var at = -1
    for i, f in files:
      if f.skip.len == 0 and w.a >= f.firstUs and w.b <= f.lastUs:
        at = i
        break
    if at >= 0:
      held[at].add s
      inc files[at].shots
    else:
      inc res.unplaced
      if res.unplacedNamed.len < NamedMax: res.unplacedNamed.add shotWords(s)

proc nameOutputs(plan: FolderPlan; files: var seq[FolderFile]) =
  ## The output of each file that will be written: its name, or why it will not be.
  var taken: seq[tuple[dest, source: string]] = @[]
  for f in files.mitems:
    if f.skip.len > 0: continue
    if f.shots == 0:
      f.skip = NoShotHeld
      continue
    if plan.destFolder.len == 0: continue
    f.dest = plan.destFolder / defaultName(f.path.extractFilename, plan.opts.standard)
    let refused = refuseDestination(f.dest, plan.others & f.path)
    if refused.len > 0:
      f.skip = refused
      continue
    var clash = ""
    for t in taken:
      if t.dest == f.dest: clash = t.source
    if clash.len > 0:
      f.skip = nameTakenWords(f.dest.extractFilename, clash.extractFilename)
    elif fs.fileExists(f.dest) or fs.dirExists(f.dest):
      f.skip = nameThereWords(f.dest.extractFilename)
    else: taken.add (f.dest, f.path)

proc sliceOne(ctx: JobContext; plan: FolderPlan; f: var FolderFile; shots: seq[Shot];
    unit, units: int64) =
  ## Slices one file with `cutGather`; what went wrong is in `f.reason`.
  var s: Session = nil
  let sink = CutSink()
  try:
    try:
      let index = indexCacheFile(plan.cacheDir, f.path)
      s = openSession(f.path, nil, if index.len > 0 and fs.fileExists(index): index else: "")
      let report = proc (done, total: int64): bool {.gcsafe.} =
        ctx.progress(Unit * unit + (if total > 0: Unit * min(done, total) div total else: 0'i64),
          Unit * units)
      cutGather(ctx, s.filePtr, f.path, f.dest, shotsInTime(shots), plan.opts, sink,
        plan.others, report)
      f.written = true
      f.shotsWritten = sink.result.shotsWritten
      f.line = if sink.result.lines.len > 0: sink.result.lines[0] else: "Sliced."
    except SegCancelledError:
      raise newException(JobCancelledError, "cancelled")
    except JobCancelledError:
      raise
    except CatchableError as e:
      f.reason = if sink.result.reason.len > 0: sink.result.reason
                 elif e.msg.len > 0: firstLine(e.msg)
                 else: $e.name
  finally:
    if s != nil: discard s.close()
    s = nil
    clearCycleRoots()

proc cutFolderWork*(plan: FolderPlan; sink: FolderSink): JobWork =
  ## The job: see the module's comment. `sink.result` is filled as it goes.
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      ctx.checkCancelled()
      ctx.setPhase "listing"
      sink.result = FolderResult(folder: plan.folder)
      var paths: seq[string] = @[]
      try:
        if not fs.dirExists(plan.folder): raise newException(OSError, "not a folder")
        var capped = false
        paths = listedNames(@[plan.folder], false, capped)
      except OSError:
        sink.result.reason = "The folder could not be listed."
        raise newException(ValueError, sink.result.reason)
      var files: seq[FolderFile] = @[]
      for i, path in paths:
        ctx.setPhase "reading " & path.extractFilename
        ctx.checkCancelled()
        files.add inspect(ctx, path, plan.cacheDir)
        if not ctx.progress(Unit * int64(i + 1), Unit * int64(max(1, paths.len) * 2)):
          raise newException(JobCancelledError, "cancelled")
      var held: seq[seq[Shot]] = @[]
      var res = FolderResult(folder: plan.folder)
      place(plan, files, held, res)
      nameOutputs(plan, files)
      res.files = files
      res.listed = true
      sink.result = res
      if not plan.write:
        sink.result.finished = true
        return
      let total = int64(max(1, paths.len) * 2) # the first pass is half of the bar
      var unit = int64(paths.len)
      for i in 0 ..< files.len:
        if files[i].sliceable and files[i].dest.len > 0:
          ctx.setPhase "slicing " & files[i].path.extractFilename
          ctx.checkCancelled()
          sliceOne(ctx, plan, files[i], held[i], unit, total)
          inc unit
          sink.result.files = files
      sink.result.finished = true
