## The shots of the folder listed: each listed seismic file's records, by
## their FFID and source station, so that the map can tell the survey's
## sources that have a file in the folder from those that have none, name
## the file, and show it at a click (docs/plot-window.md, "The map window").
##
## **Read in the background, never for display** (`shotsWork`, on the
## background lane, a few files a job): each file is opened read-only with
## its keys, through its index cache when that is current (a cache is not
## written: a folder of thousands of files would push the files the user
## opens out of the cache's budget), and of each of its gathers that holds a
## shot the FFID, the source station and the source's coordinates are kept
## (`ShotOf`), from its first seismic trace; then the file is closed, on the
## job's thread. What was found is kept beside the index cache, a small file
## per seismic file (`shotCacheFile`), and taken from there while the file's
## size and time are unchanged, so the folder listed again opens none.
##
## **A drive that does not answer.** The job posts each file as it is done
## (`mkShots`) and beats at each one; the state cancels a job that has not
## answered for `StallAfter` (`Jobs.tend` abandons it), puts the file it was
## on aside to be tried again after `RetryAfter`, and goes on with the rest.
## Each job given up whose work still hangs holds a thread until the drive
## answers, so while `MaxHanging` of them do, no job starts (`waiting`: the
## folder does not answer), and the reading goes on when one comes back: a
## share that stops answering holds `MaxHanging` threads, not one a file.
## Nothing on the UI thread reads a file.
##
## **Matched to the survey** (`ShotIndex.points`): a survey file's source is
## shot in the folder when a listed record's source station is its station
## (as parseSEG's join matches stations: the same index, index 0 any), or,
## for a record whose headers name no source station, when its source's
## coordinates are its place, or else when the relation files plan the
## record's FFID for that source. A source several listed records were shot
## at (a reshoot, a copy of a file) lists them latest first: the newest file
## (by its time), files of one time by path, and in one file its last record
## first; a click shows the first (`ckShowPoints`), the point's menu each.
## A file read again, or gone, takes only its own records out (`unplace`):
## many files changed at once cost what they hold, not a match of all.

import std/[math, monotimes, os, sequtils, sets, tables, times]
import parseSEG
import filejobs, filesystem, inbox, jobs, openchoice, session, shotfiles, spread, survey, threads

export shotfiles

const
  ShotBatch* = 32            ## files a job reads at most
  RetryAfter* = initDuration(seconds = 60)
    ## a file that did not answer is tried again after this long
  MaxShotsPerFile* = 100_000 ## records of one file kept, at most
  MaxHanging* = 2
    ## shots jobs given up whose work still runs (each a thread held by a
    ## drive that does not answer) while no new one starts

type
  ShotPlace* = tuple[path: string; gather: int; record: float64]
    ## a listed file's record shot at a survey source

  ShotIndex* = object
    ## The shots of the folder listed, matched to the survey's sources.
    gen*: uint64                     ## the listing (`FileList.gen`) it is for
    files*: Table[string, FileShots] ## by path
    pending*: seq[string]            ## files to read, in the list's order
    later*: seq[tuple[path: string; at: MonoTime]]
      ## files that did not answer, tried again from `at` (`fs.now`)
    stuck*: seq[tuple[path: string; job: JobId]]
      ## files that did not answer, with the job given up on them: not
      ## tried again while that job's work still runs (each try that hangs
      ## holds a thread until the drive answers)
    job*: JobId = NoJob ## the job reading files now
    jobPaths*: seq[string] ## its files not yet answered, in its order
    queued*: HashSet[string] ## the files in `pending`, `later` and `jobPaths`
    replaced*: seq[JobId] ## jobs given up (a new listing, no answer): they end quietly
    givenUp*: seq[JobId]
      ## jobs given up whose work may still run (also after a new listing),
      ## until it is back (`Jobs.workingOn`)
    waiting*: bool
      ## no job is started: `MaxHanging` jobs given up still hang (the
      ## folder does not answer)
    listedRev*: int ## the file list's `entriesRev` the files to read were found from
    surveyRev*: int ## the survey's revision `points` were matched with
    points*: Table[int, seq[ShotPlace]]
      ## per survey file source point (`PointRef.key`): the listed records shot
      ## there, latest first (`latestFirst`)
    pointRefs*: seq[PointRef] ## those points, each once
    placedAt*: Table[string, seq[int]]
      ## per file: the points (`PointRef.key`) its records are at
    revision*: int ## bumped on every change of `files` or `points`
    started*: MonoTime ## when the listing's first job started (`fs.now`)
    finished*: MonoTime ## when the last file was answered

func shotCacheFile*(dir, path: string): string =
  ## Where the shots of seismic file `path` are kept in the index cache
  ## folder `dir` (beside its index cache, `indexCacheFile`); "" for no folder.
  if dir.len == 0: "" else: indexCacheFile(dir, path).changeFileExt(ShotCacheExt)

proc shotsOf(s: Session): seq[ShotOf] =
  ## The records of open file `s` that hold a shot (a shot gather, or one
  ## the keys do not tell): from the first seismic trace of each.
  {.cast(gcsafe).}:
    template f: untyped = s.file
    let keyed = f.index.keys.len == f.len
    for i, g in s.gathers:
      if result.len < MaxShotsPerFile and g.kind notin {gkReceiver, gkCmp, gkOffset} and
          g.traces.len > 0:
        var r = ShotOf(gather: i, record: s.records[i].record, x: NaN, y: NaN)
        if keyed:
          var t = g.traces.a
          while t < g.traces.b and not isSeismic(f.index, t): inc t
          let k = f.index.keys[t]
          if not (k.srcLine.isNaN or k.srcPoint.isNaN) and not (k.srcLine == 0 and
              k.srcPoint == 0):
            (r.source, r.hasStation) = (stationKey(k.srcLine, k.srcPoint, k.srcIndex), true)
          if abs(k.srcX) < Inf and abs(k.srcY) < Inf and not (k.srcX == 0 and k.srcY == 0):
            (r.x, r.y) = (k.srcX, k.srcY)
        result.add r

proc readShots*(path, cacheDir: string; ctx: JobContext;
    choice = OpenChoice()): FileShots =
  ## The shots of seismic file `path`, from its shot cache in `cacheDir` when
  ## that is of the file as it is now, else from the file (opened through its
  ## index cache when that is current, then closed here), and kept in the
  ## shot cache. The file is read with the options `choice` (its "Reopen with
  ## options"), and a file so read has no shot cache, which is of the default
  ## reading. A file that cannot be read says why (`problem`). Raises
  ## `JobCancelledError` at a cancel. Worker-only.
  assertWorkerThread()
  result = FileShots(path: path)
  var info: FileInfo
  try:
    info = fs.getFileInfo(path)
  except OSError as e:
    result.problem = "cannot be looked at: " & e.msg
    return
  (result.size, result.modified) = (info.size, info.lastWriteTime)
  let cache = if choice.isDefault: shotCacheFile(cacheDir, path) else: ""
  if cache.len > 0 and fs.fileExists(cache):
    try:
      let (ok, kept) = parseCache(fs.readFile(cache), path)
      if ok and kept.size == info.size and kept.modified == info.lastWriteTime: return kept
    except IOError:
      discard # read from the file
  let index = indexCacheFile(cacheDir, path)
  let progress: Progress = proc (done, total: int64): bool {.gcsafe, raises: [].} =
    try:
      fs.mappedRead(path)
    except OSError:
      discard # a real drive that fails here ends the walk in parseSEG
    ctx.progress(done, total)
  try:
    var s = openSession(path, progress, if index.len > 0 and fs.fileExists(index): index else: "",
      choice)
    if s.file.kind == skUnknown: result.problem = "not a SEG-Y, SEG-D or SEG-2 file"
    else: result.shots = shotsOf(s)
    s = nil # closed here, on the thread that opened it
    clearCycleRoots()
  except SegCancelledError:
    raise newException(JobCancelledError, "cancelled")
  except CatchableError as e:
    result.problem = e.msg
  ctx.checkCancelled()
  if cache.len > 0 and result.problem.len == 0:
    try:
      fs.createDir(cacheDir)
      let tmp = cache & ".tmp"
      var f: File
      if fs.open(f, tmp, fmWrite):
        try: f.write(cacheText(result))
        finally: f.close()
        fs.moveFile(tmp, cache)
    except CatchableError:
      discard # kept another time

proc shotsWork*(gen: uint64; paths: seq[string]; cacheDir: string; to: Poster;
    choices: seq[OpenChoice] = @[]): JobWork =
  ## The work of a background job that reads the shots of seismic files
  ## `paths` of listing `gen` (`readShots`), posting each file as it is done
  ## (`mkShots`), so a file that does not answer holds back only itself; each
  ## is read with its options in `choices` (those of `paths`, or none).
  result = proc (ctx: JobContext) {.gcsafe.} =
    for i, path in paths:
      ctx.setPhase "reading " & path.extractFilename
      let f = readShots(path, cacheDir, ctx, if i < choices.len: choices[i] else: OpenChoice())
      discard ctx.progress(i + 1, paths.len)
      to.post Msg(job: ctx.id, kind: mkShots, shotsGen: gen, shots: f)

# --------------------------------------------------------- matching --

func latestFirst(x: ShotIndex; a, b: ShotPlace): bool =
  ## Whether listed record `a` comes before `b` at one source: the newer
  ## file first (a reshoot, a file written again), then by path; in one
  ## file, the later record first.
  let (ta, tb) = (x.files[a.path].modified, x.files[b.path].modified)
  if ta != tb: ta > tb
  elif a.path != b.path: a.path < b.path
  else: a.gather > b.gather

proc place(x: var ShotIndex; p: PointRef; at: ShotPlace) =
  ## Puts listed record `at` at survey source point `p`, in its place in
  ## the order (`latestFirst`).
  let key = p.key
  if key notin x.points:
    x.points[key] = @[]
    x.pointRefs.add p
  x.points.withValue(key, places):
    var i = places[].len
    while i > 0 and x.latestFirst(at, places[][i - 1]): dec i
    places[].insert(at, i)
  x.placedAt.withValue(at.path, keys):
    if key notin keys[]: keys[].add key
  do:
    x.placedAt[at.path] = @[key]

proc unplace(x: var ShotIndex; path: string): bool =
  ## Takes the records of file `path` off the points they are at; true when
  ## a point is left with none (`pointRefs` is then for the caller to prune).
  var keys: seq[int]
  if x.placedAt.pop(path, keys):
    for key in keys:
      x.points.withValue(key, places):
        places[].keepItIf(it.path != path)
        if places[].len == 0: result = true
      if key in x.points and x.points[key].len == 0: x.points.del key

proc pruneRefs(x: var ShotIndex) =
  x.pointRefs.keepItIf(it.key in x.points)

proc matchOne*(x: var ShotIndex; s: Survey; path: string; shot: ShotOf) =
  ## Matches listed record `shot` of file `path` to the survey files'
  ## sources: by its source station; without one, by its source's place
  ## (within `SamePlace`), else by its FFID through the relation files (the
  ## source whose X record has its number).
  var places: seq[PointRef]
  for i in 0 ..< s.layers.len: # by index: `for l in` copies every layer
    template l: untyped = s.layers[i]
    if l.origin == loSurveyFile and l.points[prSource].len > 0:
      if shot.hasStation:
        let p = l.stationPoint(prSource, Station(line: shot.source.line,
          point: shot.source.point, index: shot.source.index))
        if p >= 0: places.add PointRef(layer: l.id, role: prSource, point: p)
  if places.len == 0 and not shot.hasStation and abs(shot.x) < Inf and abs(shot.y) < Inf:
    # No station in the headers: the survey file's source at its place.
    for i in 0 ..< s.layers.len:
      template l: untyped = s.layers[i]
      if l.origin == loSurveyFile and places.len == 0:
        let q = l.points[prSource].index.nearest(shot.x, shot.y, SamePlace)
        if q >= 0: places.add PointRef(layer: l.id, role: prSource, point: q)
  if places.len == 0 and not shot.hasStation and abs(shot.record) < 9e18 and
      shot.record == round(shot.record):
    for i in 0 ..< s.layers.len:
      template m: untyped = s.layers[i]
      if m.origin == loSurveyFile and m.xRuns > 0:
        for run in m.relations[].relationRuns(int64(shot.record)):
          for j in 0 ..< s.layers.len:
            template l: untyped = s.layers[j]
            if l.origin == loSurveyFile and places.len == 0:
              let p = l.stationPoint(prSource, Station(line: run.fixed.line,
                point: run.fixed.point, index: run.fixed.index))
              if p >= 0: places.add PointRef(layer: l.id, role: prSource, point: p)
  for p in places: x.place(p, (path, shot.gather, shot.record))

proc match*(x: var ShotIndex; s: Survey) =
  ## Matches every listed record to the survey files' sources again (the
  ## survey changed): `points`, `pointRefs`.
  x.points.clear()
  x.pointRefs.setLen 0
  x.placedAt.clear()
  x.surveyRev = s.revision
  for path, f in x.files.pairs:
    for shot in f.shots: x.matchOne(s, path, shot)
  inc x.revision

proc forget*(x: var ShotIndex; s: Survey; paths: openArray[string]) =
  ## Takes the records of files `paths` out (no longer listed), each file's
  ## from the points it is at (a folder emptied at once held the window for
  ## seconds when the rest were matched again).
  var (any, emptied) = (false, false)
  for path in paths:
    if path in x.files:
      emptied = x.unplace(path) or emptied
      x.files.del path
      any = true
  if emptied: x.pruneRefs()
  if any: inc x.revision

proc take*(x: var ShotIndex; s: Survey; f: sink FileShots) =
  ## The shots a job read of one file.
  let path = f.path
  let i = x.jobPaths.find(path)
  if i >= 0: x.jobPaths.delete(i)
  # A file read again (changed): its records before taken off, not every
  # file matched again (many files copied over at once).
  if path in x.files and x.unplace(path): x.pruneRefs()
  x.files[path] = f
  for shot in x.files[path].shots: x.matchOne(s, path, shot)
  inc x.revision

func shotsAt*(x: ShotIndex; p: PointRef): seq[ShotPlace] =
  ## The listed records shot at survey source point `p`; none for another point.
  x.points.getOrDefault(p.key)

func shotFiles*(x: ShotIndex): int =
  ## The listed files read, with a shot or not.
  x.files.len
