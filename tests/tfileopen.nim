## Opening files through the interactive job: a SEG-Y and a SEG-D file open
## with progress, then success; the index cache is written under the folder
## the state is given and read back on the next open, a stale one is not
## used, a folder that cannot be written only warns, and the folder keeps its
## size budget; a cancel stops a running open, posts nothing and leaves the
## lane free; a damaged file is reported in the log with where it is damaged,
## and nothing raises; the seismic files are never changed.
##
## Seen to fail: with `openWork` ignoring the cache (`cache` not passed to
## `openSession`), `cacheIsReadBack` found the file indexed again; with
## the save left out, it found no cache file; with `pruneIndexCache` deleting
## newest first, `pruneKeepsTheBudget` deleted the cache just written; with the
## progress hook always returning true and the check after the open left
## out, `cancelStopsARunningOpen` found the job done and a session posted
## (either alone still cancels it); with `openSession` dropping its
## `progress`, `progressReachesTheEnd` saw no calls.
##
## Runs alone: it bounds the time stopping the jobs takes (1 s).

import std/[os, strutils, times]
import parseSEG
import viewSEG/core/[filejobs, state]
import utils/[fixtures, waiting]

var gates: array[2, Gate]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc jobTitled(st: AppState; title: string): JobInfo =
  for j in st.jobs.list:
    if j.spec.title == title: return j
  raise newException(KeyError, "no job " & title)

proc openCmd(paths: varargs[string]): Command = Command(kind: ckOpen, paths: @paths)

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc closeAll(st: var AppState) =
  while st.sessions.len > 0:
    let name = st.sessions[0].name
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.settle(st.log.has("Closed " & name & "."))

block cacheFileNames:
  let a = indexCacheFile("/cache", "/data/a/shot.sgy")
  doAssert a.startsWith("/cache" / "shot.sgy-") and a.endsWith(IndexCacheExt), a
  doAssert a == indexCacheFile("/cache", "/data/a/shot.sgy"), "not the same on every call"
  doAssert a != indexCacheFile("/cache", "/data/b/shot.sgy"), "two folders share a cache"
  doAssert indexCacheFile("", "/data/a/shot.sgy") == ""
  let long = indexCacheFile("/c", "/d/" & 'x'.repeat(300) & ".sgy")
  doAssert long.extractFilename.len < 100, long

block progressReachesTheEnd:
  # The hook runs on the opening thread about every MiB and once at the end.
  withFixtures fx:
    for path in [fx.surveySegy(), fx.twoSetSegd()]:
      var st = initAppState()
      st.apply openCmd(path)
      doAssert st.settle(st.sessions.len == 1)
      let job = st.jobTitled("Open " & path.extractFilename)
      doAssert job.state == jsDone
      let p = job.progress
      doAssert p.phase == "indexing" and p.total == getFileSize(path) and p.done == p.total,
        path.extractFilename & ": " & $p
      doAssert st.log.count(sevWarning) + st.log.count(sevError) + st.log.count(sevFatal) == 0
      st.shutdown()

block cacheIsReadBack:
  withFixtures fx:
    let cacheDir = fx.dir / "cache" / "index"
    for path in [fx.surveySegy(), fx.twoSetSegd()]:
      let name = path.extractFilename
      let before = snapshot(path)
      var st = initAppState(indexCache = cacheDir)
      doAssert st.indexCache == cacheDir
      st.apply openCmd(path)
      doAssert st.settle(st.sessions.len == 1)
      doAssert not st.sessions[0].file.fromCache
      doAssert st.log.has("Opened " & name & ": "), name
      doAssert not st.log.has("(index from the cache)")
      let cache = indexCacheFile(cacheDir, path)
      doAssert fileExists(cache), "no index cache " & cache
      st.closeAll()
      st.apply openCmd(path)
      doAssert st.settle(st.sessions.len == 1)
      doAssert st.sessions[0].file.fromCache, name & " was indexed again"
      doAssert st.log.has("(index from the cache)."), name
      doAssert st.jobTitled("Open " & name).state == jsDone
      doAssert st.sessions[0].len == (if name.endsWith(".sgy"): SurveyTraces else: 2 +
        2 * SegdChannels), $st.sessions[0].len
      st.shutdown()
      doAssert snapshot(path) == before, "opening changed " & name

block staleCacheIsNotUsed:
  # The file changed after its cache was saved: parseSEG walks it again and
  # says why, and the open saves a new cache.
  withFixtures fx:
    let cacheDir = fx.dir / "index"
    let path = fx.dir / "copy.sgy"
    copyFile(fx.surveySegy(), path)
    var st = initAppState(indexCache = cacheDir)
    st.apply openCmd(path)
    doAssert st.settle(st.sessions.len == 1)
    st.closeAll()
    let cache = indexCacheFile(cacheDir, path)
    let saved = getLastModificationTime(cache)
    copyFile(fx.surveySegy(pdSpike), path)
    setLastModificationTime(path, getTime() + initDuration(seconds = 5))
    st.apply openCmd(path)
    doAssert st.settle(st.sessions.len == 1)
    doAssert not st.sessions[0].file.fromCache, "a stale cache was used"
    doAssert st.log.has("was not used"), "the log does not say why the cache was not used"
    doAssert getLastModificationTime(cache) != saved, "no new cache was saved"

block unwritableCacheOnlyWarns:
  withFixtures fx:
    let path = fx.surveySegy()
    writeFile(fx.dir / "a-file", "")
    var st = initAppState(indexCache = fx.dir / "a-file" / "index")
    st.apply openCmd(path)
    doAssert st.settle(st.sessions.len == 1), "the file did not open"
    doAssert st.log.has("Cannot save the index cache of " & path.extractFilename, sevWarning)
    doAssert st.log.count(sevError) == 0

block pruneKeepsTheBudget:
  withFixtures fx:
    let dir = fx.dir / "index"
    createDir(dir)
    let now = getTime()
    for i in 0 ..< 5: # a.pidx used longest ago, e.pidx last
      let p = dir / ($chr(ord('a') + i) & IndexCacheExt)
      writeFile(p, 'x'.repeat(1000))
      setLastModificationTime(p, now - initDuration(hours = 5 - i))
    writeFile(dir / "notes.txt", 'x'.repeat(5000)) # not a cache: never counted or deleted
    let keep = dir / ("a" & IndexCacheExt) # just written
    let gone = pruneIndexCache(dir, budget = 2500, keep = keep)
    doAssert gone == @[dir / ("b" & IndexCacheExt), dir / ("c" & IndexCacheExt),
      dir / ("d" & IndexCacheExt)], $gone
    doAssert fileExists(keep) and fileExists(dir / ("e" & IndexCacheExt))
    doAssert fileExists(dir / "notes.txt")
    doAssert pruneIndexCache(dir, budget = 1_000_000).len == 0
    doAssert pruneIndexCache(fx.dir / "missing", budget = 0).len == 0

proc gatedOpen(path: string; to: Poster): JobWork =
  ## An open that starts only when gate 0 opens, whatever was asked of it
  ## meanwhile: a cancel then reaches it while it runs.
  let open = openWork(path, to)
  result = proc (ctx: JobContext) {.gcsafe.} =
    let deadline = getMonoTime() + Patience * 2
    while not gates[0].isOpen and getMonoTime() < deadline: sleep 1
    open(ctx)

block cancelStopsARunningOpen:
  withFixtures fx:
    let path = fx.surveySegy()
    let jobs = initJobs()
    let box = initInbox()
    let job = jobs.submit(JobSpec(title: "Open", lane: jlInteractive, reads: @[path]),
      gatedOpen(path, box.poster))
    doAssert waitUntil(jobs.info(job).get.state == jsRunning)
    doAssert jobs.cancel(job)
    gates[0].open()
    doAssert waitUntil(jobs.info(job).get.state in {jsDone, jsFailed, jsCancelled})
    doAssert jobs.info(job).get.state == jsCancelled, $jobs.info(job).get.state
    var mail: seq[Msg]
    box.drainInto(mail)
    for m in mail:
      doAssert m.kind != mkOpened, "a cancelled open posted its file"
    # The lane is free: the next open runs, and stopping waits for nothing.
    let next = jobs.submit(JobSpec(title: "Open again", lane: jlInteractive, reads: @[path]),
      openWork(path, box.poster))
    doAssert waitUntil(jobs.info(next).get.state == jsDone)
    box.drainInto(mail)
    doAssert mail.len == 1 and mail[0].kind == mkOpened
    let t0 = getMonoTime()
    jobs.stop()
    doAssert getMonoTime() - t0 < initDuration(seconds = 1), "a job was still running"

block damagedFilesAreReported:
  withFixtures fx:
    let survey = readFile(fx.surveySegy())
    let cut = fx.dir / "cut.sgy"
    writeFile(cut, survey[0 ..< survey.len - 700]) # the last trace loses 700 bytes
    let segd = readFile(fx.twoSetSegd())
    let stub = fx.dir / "stub.sgd"
    writeFile(stub, segd[0 ..< 2000])
    var st = initAppState()
    st.apply openCmd(cut, stub)
    doAssert st.settle(st.sessions.len == 2)
    var found = false
    for e in st.log:
      if e.source == "cut.sgy" and e.severity == sevFatal and "bytes" in e.text:
        doAssert e.loc.trace == SurveyTraces - 1 and e.offset > 0, $e.loc & " " & $e.offset
        doAssert e.loc.file == cut
        found = true
    doAssert found, "no diagnostic for the cut trace"
    doAssert st.log.has("Opened cut.sgy: " & $(SurveyTraces - 1) & " traces")
    var stubbed = false
    for e in st.log:
      if e.source == "stub.sgd" and e.severity == sevFatal: stubbed = true
    doAssert stubbed, "no diagnostic for the cut SEG-D file"
