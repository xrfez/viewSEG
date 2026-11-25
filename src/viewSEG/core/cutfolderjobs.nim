## Slices every recording of a folder at the times of a shot log. A background job
## (`startFolder`) with two steps: the first opens each file of the folder in name
## order and works out whether it can be sliced and where its segments lie (its facts,
## kept by the caller while the file's size and time and the kind the user forced for it
## stay as they are); the second writes, for each file that can be sliced, the records of
## the shots it takes, with the routine that slices one recording (`cutGather`).
##
## A folder normally holds one continuous recording for each node, all of the same time,
## so every file takes every shot it can: a file takes a shot when the start of the
## shot's window lies inside its span. The start is placed as the single slice places it
## (`planSlices` with the options' alignment, so a start half a sample before the
## first sample is the first sample with the nearest-sample alignment), and a window that
## runs past the end of the file is written zero-padded and counted as gap samples, as
## in a single slice. A shot that no file takes is counted once for the folder and the
## first few are named. A file that is not seismic, is a signature file, is not a
## continuous receiver gather (unless the user forced its kind) or takes no shot is
## skipped, and so is one whose output would be named as another file's, is already there
## or is refused (a destination inside the folder being sliced or the folder of an open
## file is refused once for the folder); the reason is in the result, with the number of
## shots such a file would have taken. One that fails while it is written does not stop
## the others. Each output is named as a single slice names it (`defaultName`), in the
## destination folder, and nothing is ever replaced.
##
## With `write` false the job only does the first step and the placing: what the window
## shows before a run. The result is filled as the job goes, so a cancel leaves what was
## done.
##
## **Threads.** The job shares no `ref` with the UI thread. `startFolder` gives it the
## facts of an earlier job by address (`FolderFacts` is plain data, never changed once
## made) and the result it fills by address too; the `FolderFlight` it returns keeps both
## on the UI thread until the job's work is back (`over`), also when the job was cancelled
## and its work still runs, and gives them up to the process at the quit when it is not
## (`keepForStragglers`). The job posts the facts it read as plain data and, for the
## others, the index of the facts it was lent; `take` makes the next `KnownFacts` from
## them on the UI thread, sharing the unchanged entries without copying them.

import std/[algorithm, math, options, os, sequtils, strutils, tables, times]
import parseSEG
import processSEG/continuous/slice
import cutfile, cutgather, cutgatherjobs, filejobs, filelist, filesystem, jobs, outputjobs,
    recordingkind,
  session, shotlog, threads, treatas, vendormaps

const
  NotRecording* = "not a SEG-Y, SEG-D or SEG-2 file" ## why a file that is not seismic is skipped
  SignatureFile* = "a signature file is not a recording that can be sliced"
  NoShotHeld* = "the start of no shot's record is inside this recording"
  InsideSource* = "The destination is inside the folder being sliced."
  NamedMax* = 5                                      ## how many unplaced shots the result names
  Unit = 1000'i64 ## the job's progress is this many units for each step of a file

type
  FolderFacts* = object
    ## What the first step found out about a file, kept while the file stays as it was. Made
    ## by the job and never changed after it is posted. A file of N traces keeps about 48 bytes
    ## for each trace plus one `TraceKeys` for each receiver in `streams`, gaps or not; nothing
    ## else is large.
    path*: string
    vendorGen*: int ## the vendor header maps' generation it was read under
    size*: int64
    modified*: Time
    forced*: Option[RecordingKind] ## the kind the user set for the file
    skip*: string ## why the file cannot be sliced; "" when it can
    dtMs*: float64
    firstUs*, lastUs*: int64 ## the span of its segments, UTC microseconds
    streams*: SliceStreams ## where its segments lie, for placing the shots

  KnownFacts* = object
    ## The facts of every file of a folder, kept on the UI thread between jobs. A new check
    ## shares the entries of the files that have not changed; only the UI thread ever counts
    ## the references to them (a job reads them by address).
    items*: seq[ref FolderFacts]

  FolderFile* = object
    path*: string
    skip*: string            ## why the file is not sliced; "" when it is
    shots*: int              ## shots the file takes (those it would have taken when it is skipped)
    firstUs*, lastUs*: int64 ## the span of its segments, UTC microseconds
    dest*: string            ## the file its slice is written to
    written*: bool
    reason*: string          ## why writing it failed
    line*: string            ## the slice's own first sentence when it was written
    gaps*: string            ## its sentence about output samples that fall in gaps; "" when none
    shotsWritten*: int

  FolderResult* = object
    folder*: string
    files*: seq[FolderFile]
    reused*: seq[int]           ## per file, the index of the facts it was lent; -1: read again
    fresh*: seq[FolderFacts]    ## per file, the facts read again (an empty entry where lent)
    noTime*: int                ## rows of the log without a time
    unplaced*: int              ## shots no file takes
    unplacedNamed*: seq[string] ## the first few, by their file number or time
    refused*: string            ## why nothing is written into the destination, for the folder
    capped*: bool               ## the list of files stopped at the limit
    listed*: bool               ## the first step and the placing are over
    finished*: bool             ## the job ended well
    reason*: string             ## why the job failed, when it did

  FolderPlan* = object
    ## What the job needs.
    folder*, destFolder*: string
    rows*: seq[Shot]                      ## the rows of the shot log
    opts*: CutOptions
    cacheDir*: string                     ## the folder of the index caches
    others*: seq[string]                  ## the paths of the files that are open: never a destination
    vendorGen*: int                       ## the generation of the vendor header maps in force
    treats*: Table[string, RecordingKind] ## the kinds the user set, by absolute path
    write*: bool
    known: seq[ptr FolderFacts]
      ## the facts of an earlier job, used for a file that has not changed: kept alive and
      ## unchanged by the `FolderFlight` until the job's work is back

  FolderFlight* = object
    ## A folder job and what its work reads and fills in place, kept on the UI thread until the
    ## work is back (`over`), also after a cancel (`retire`). `job` is `NoJob` for none.
    job*: JobId = NoJob
    output: ref FolderResult ## filled by the job through its address
    lent: seq[ref FolderFacts] ## the facts the job reads through their addresses

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
  ## Whether the file will be written: it can be sliced and takes a shot.
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

proc absoluteKey(path: string): string =
  try: absolutePath(path).normalizedPath
  except OSError, ValueError: path.normalizedPath

proc shotWords(s: Shot): string =
  ## A shot by its file number, else its time.
  if s.fileNumber.isSome: "file " & $s.fileNumber.get
  elif s.timeUtcUs.isSome:
    fromUnix(s.timeUtcUs.get div 1_000_000).utc.format("yyyy-MM-dd HH:mm:ss") & " UTC"
  else: "a row"

proc inspect(ctx: JobContext; path, cacheDir: string; forced: Option[RecordingKind];
    vendorGen: int): FolderFacts =
  ## Opens `path` and says whether it can be sliced, and where its segments lie.
  result = FolderFacts(path: path, forced: forced, vendorGen: vendorGen)
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
        result.dtMs = dtMs
        {.cast(gcsafe).}:
          var plan = planRecording(s.filePtr, path, dtMs, currentVendors(),
            proc () {.gcsafe.} = ctx.checkCancelled())
          let why = cutWhy(s.file)
          if why.len > 0: result.skip = why
          else:
            let auto = describeRecording(plan, AllStarts)
            var facts = auto
            if forced.isSome: facts = applied(auto, TreatAs(kind: forced))
            # forced continuous where the traces of a component all carry one start time: they
            # follow one another end to end from the first one's time, as the single slice has it
            let endToEnd = facts.forced and facts.kind == rkReceiverContinuous and
              auto.kind != rkReceiverContinuous and auto.slicedWhy == swSameStart
            if facts.segments == 0: result.skip = NoLiveTraceWords
            elif endToEnd and firstStartMissing(plan):
              result.skip = "its first trace has no start time, so its traces cannot be " &
                "placed in time: load a vendor header map that reads the start time"
            else:
              let refusal = cutRefusal(facts)
              if refusal.len > 0: result.skip = refusal
              else:
                if endToEnd:
                  plan.times = endToEndTimes(plan)
                  facts = applied(describeRecording(plan, AllStarts), TreatAs(kind: forced))
                  result.streams = initSliceStreams(plan.meta, plan.times, plan.receivers)
                else: result.streams = plan.streams
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

func startCovered(plan: SlicePlan; shot: int): bool =
  ## Whether the plan puts a sample of some receiver at column 0 of shot `shot`'s record:
  ## the window starts where the file has data, after the alignment has placed the start.
  let rc = plan.receiverCount
  for r in 0 ..< rc:
    for pc in plan.pieces(shot * rc + r):
      if pc.dst <= 0 and 0 < pc.dst + pc.count:
        if pc.row >= 0: return true
        break

proc place(plan: FolderPlan; facts: openArray[ptr FolderFacts]; files: var seq[FolderFile];
    held: var seq[seq[Shot]]; res: var FolderResult) =
  ## Gives each file the shots whose window start it holds; counts the shots none takes.
  held.setLen files.len
  var timed: seq[Shot] = @[]
  for s in plan.rows:
    if s.timeUtcUs.isNone: inc res.noTime
    else: timed.add s
  let cut = shotsInTime(timed)
  var taken = newSeq[bool](cut.shots.len)
  let window = SliceWindow(startMs: plan.opts.startMs, lengthMs: plan.opts.recordMs)
  let startOffsetUs = int64(round(plan.opts.startMs * 1000))
  for i, f in facts:
    if f.skip.len > 0 or cut.shots.len == 0: continue
    let wrong = checkOptions(plan.opts, f.dtMs)
    if wrong.len > 0:
      files[i].skip = wrong
      continue
    try:
      let sp = planSlices(f.streams, cut.shots, window, soShotRecords, plan.opts.align)
      if sp.receiverCount == 0: continue
      for k in 0 ..< cut.shots.len:
        # the start on the file's grid, as the plan placed it: a start in the last half sample
        # is the sample after the span with the nearest-sample alignment, and no file's
        let at = timed[cut.rows[k]].timeUtcUs.get + startOffsetUs -
          int64(round(sp.fraction(k * sp.receiverCount) * f.dtMs * 1000))
        # a start in a gap between segments of the file is inside it, too
        if sp.startCovered(k) or (at >= f.firstUs and at < f.lastUs):
          held[i].add timed[cut.rows[k]]
          taken[k] = true
    except ValueError as e:
      files[i].skip = e.msg
    files[i].shots = held[i].len
  for k in 0 ..< cut.shots.len:
    if not taken[k]:
      inc res.unplaced
      if res.unplacedNamed.len < NamedMax: res.unplacedNamed.add shotWords(timed[cut.rows[k]])

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
    var clash = ""
    for t in taken:
      if pathsEqual(t.dest, f.dest) or t.dest.toLowerAscii == f.dest.toLowerAscii:
        clash = t.source
    if clash.len > 0:
      f.skip = nameTakenWords(f.dest.extractFilename, clash.extractFilename)
    elif fs.fileExists(f.dest) or fs.dirExists(f.dest):
      f.skip = nameThereWords(f.dest.extractFilename)
    else: taken.add (f.dest, f.path)

proc sliceOne(ctx: JobContext; plan: FolderPlan; f: var FolderFile; shots: seq[Shot];
    forced: Option[RecordingKind]; unit, units: int64) =
  ## Slices one file with `cutGather`; what went wrong is in `f.reason`.
  var s: Session = nil
  let sink = CutSink()
  var opts = plan.opts
  opts.treatKind = forced
  try:
    try:
      let index = indexCacheFile(plan.cacheDir, f.path)
      s = openSession(f.path, nil, if index.len > 0 and fs.fileExists(index): index else: "")
      let report = proc (done, total: int64): bool {.gcsafe.} =
        ctx.progress(Unit * unit + (if total > 0: Unit * min(done, total) div total else: 0'i64),
          Unit * units)
      cutGather(ctx, s.filePtr, f.path, f.dest, shotsInTime(shots), opts, sink, plan.others,
        report)
      f.written = true
      f.shotsWritten = sink.result.shotsWritten
      f.line = if sink.result.lines.len > 0: sink.result.lines[0] else: "Sliced."
      for l in sink.result.lines:
        if "fall in gaps" in l: f.gaps = l
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

proc sameAsKnown(k: FolderFacts; path: string; info: FileInfo;
    forced: Option[RecordingKind]; vendorGen: int): bool =
  k.vendorGen == vendorGen and k.path == path and k.size == info.size and k.modified ==
      info.lastWriteTime and
    k.forced == forced

proc cutFolderWork(plan: FolderPlan; into: ptr FolderResult): JobWork =
  ## The job: see the module's comment. `into[]` is filled as it goes; it and the facts of
  ## `plan.known` stay alive until the work is back (`FolderFlight`).
  result = proc (ctx: JobContext) {.gcsafe.} =
    {.cast(gcsafe).}:
      ctx.checkCancelled()
      ctx.setPhase "listing"
      into[] = FolderResult(folder: plan.folder)
      var paths: seq[string] = @[]
      var capped = false
      try:
        if not fs.dirExists(plan.folder): raise newException(OSError, "not a folder")
        paths = listedNames(@[plan.folder], false, capped)
        if paths.len > MaxTreeFiles:
          paths.setLen MaxTreeFiles
          capped = true
      except OSError:
        into.reason = "The folder could not be listed."
        raise newException(ValueError, into.reason)
      # the facts of each file: lent ones by address, the others read here; `fresh` is
      # never resized below, so the addresses taken of its entries stay good
      var fresh = newSeq[FolderFacts](paths.len)
      var reused = newSeq[int](paths.len)
      var forcedOf: seq[Option[RecordingKind]] = @[]
      for i, path in paths:
        ctx.checkCancelled()
        let forced = block:
          let k = absoluteKey(path)
          if k in plan.treats: some(plan.treats[k]) else: none(RecordingKind)
        forcedOf.add forced
        var info = FileInfo()
        var have = false
        try:
          info = fs.getFileInfo(path)
          have = true
        except OSError: discard
        reused[i] = -1
        if have:
          for j, k in plan.known:
            if reused[i] < 0 and k[].sameAsKnown(path, info, forced, plan.vendorGen):
              reused[i] = j
        if reused[i] < 0:
          ctx.setPhase "reading " & path.extractFilename
          fresh[i] = inspect(ctx, path, plan.cacheDir, forced, plan.vendorGen)
          if have:
            fresh[i].size = info.size
            fresh[i].modified = info.lastWriteTime
        if not ctx.progress(Unit * int64(i + 1), Unit * int64(max(1, paths.len) * 2)):
          raise newException(JobCancelledError, "cancelled")
      var facts = newSeq[ptr FolderFacts](paths.len)
      for i in 0 ..< paths.len:
        facts[i] = if reused[i] >= 0: plan.known[reused[i]] else: addr fresh[i]
      var files: seq[FolderFile] = @[]
      for f in facts:
        files.add FolderFile(path: f.path, skip: f.skip, firstUs: f.firstUs, lastUs: f.lastUs)
      var held: seq[seq[Shot]] = @[]
      var res = FolderResult(folder: plan.folder, capped: capped)
      place(plan, facts, files, held, res)
      if plan.destFolder.len > 0:
        let probe = plan.destFolder / "slice"
        if refuseDestination(probe, @[plan.folder / "x"]).len > 0:
          res.refused = InsideSource
        else:
          let open = refuseDestination(probe, plan.others)
          if open.len > 0: res.refused = open
      nameOutputs(plan, files)
      res.files = files
      res.listed = true
      res.reused = move reused
      res.fresh = move fresh # the addresses in `facts` are not used after this
      into[] = move res
      if not plan.write or into.refused.len > 0:
        into.finished = true
        return
      let total = int64(max(1, paths.len) * 2) # the first step is half of the bar
      var unit = int64(paths.len)
      for i in 0 ..< files.len:
        if files[i].sliceable and files[i].dest.len > 0:
          ctx.setPhase "slicing " & files[i].path.extractFilename
          ctx.checkCancelled()
          sliceOne(ctx, plan, files[i], held[i], forcedOf[i], unit, total)
          inc unit
          into.files = files
      into.finished = true

proc startFolder*(jobs: Jobs; plan: FolderPlan; known: KnownFacts): FolderFlight =
  ## Submits the job of `plan`, which uses the facts of `known` for the files that have not
  ## changed. The UI thread's: keep the flight until it is `over`, then `take` it, or `retire`
  ## it to give the job up.
  result = FolderFlight(output: new FolderResult, lent: known.items)
  var plan = plan
  plan.known = newSeqOfCap[ptr FolderFacts](result.lent.len)
  for k in result.lent: plan.known.add addr k[]
  result.job = jobs.submit(cutFolderSpec(plan.folder, plan.write),
    cutFolderWork(plan, addr result.output[]))

proc ended*(f: FolderFlight; jobs: Jobs): bool =
  ## Whether the job is listed as over (or is gone): done, failed or cancelled. Its work may
  ## still run when it was cancelled and did not stop (`over` tells).
  if f.job == NoJob: return true
  let info = jobs.info(f.job)
  info.isNone or info.get.state notin {jsQueued, jsRunning}

proc over*(f: FolderFlight; jobs: Jobs): bool =
  ## Whether the job's work is back: the job is over and no thread runs its work any more
  ## (`Jobs.workingOn`). Only then may the result be read and the flight be dropped.
  f.ended(jobs) and not jobs.workingOn(f.job)

proc take*(f: var FolderFlight): tuple[res: FolderResult; known: KnownFacts] =
  ## What the job made, once it is `over`: its result, and the facts of the folder's files for
  ## the next job (the entries it was lent and kept, and new ones for those it read). The
  ## flight names no job after.
  if f.output != nil:
    result.res = move f.output[]
    for i, j in result.res.reused:
      if j >= 0 and j < f.lent.len: result.known.items.add f.lent[j]
      elif i < result.res.fresh.len:
        let k = new FolderFacts
        k[] = move result.res.fresh[i]
        result.known.items.add k
    result.res.reused = @[]
    result.res.fresh = @[]
  f = FolderFlight()

proc retire*(left: var seq[FolderFlight]; f: var FolderFlight; jobs: Jobs) =
  ## Gives the job of `f` up: it is cancelled, and what its work uses is kept in `left` until
  ## the work is back (`dropOver`). The flight names no job after.
  if f.job != NoJob:
    discard jobs.cancel(f.job)
    left.add move f
  f = FolderFlight()

proc dropOver*(left: var seq[FolderFlight]; jobs: Jobs) =
  ## Lets go of the flights whose work is back.
  if left.len > 0: left.keepItIf(not it.over(jobs))

proc keepForStragglers*(flights: openArray[FolderFlight]; jobs: Jobs) =
  ## At the quit: what the work of a job left running uses stays to the end of the process,
  ## instead of being released under it.
  for f in flights:
    if f.job != NoJob and not f.over(jobs):
      if f.output != nil: GC_ref(f.output)
      for k in f.lent: GC_ref(k)
