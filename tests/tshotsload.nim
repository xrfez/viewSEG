## Runs alone: measures times.
##
## The shots of a folder of 2000 small shot records (SEG-Y, four traces
## each, their sources' coordinates in the headers) with an S file of their
## 2000 sources, in `core`, without a window: how long reading them takes,
## the first time and again from the shot cache; the listing is not held
## up (it is done before the first shot is read, and a new listing while
## shots are read is done as quickly as the first); and the UI thread's
## work per drained inbox stays small (no frame stalls), the longest said,
## also when half the files are taken out of the folder at once, and when
## the other half are written again at once (each read again).
##
## Seen to fail: with every file's shots matched to the survey again for
## each file read (`match` in place of `matchOne`), "the UI thread's work"
## found a drain of 212 ms; with the shots matched again for each file
## taken out, "files taken out: a drain of 3288 ms" (a debug build); with
## every file's shots matched again for each file read again, "files written
## again: a drain of 57 ms, 2770 ms in all" (129 ms in all now; a debug build)

import std/[monotimes, os, strutils, tables, times]
import parseSEG
import viewSEG/core/state
import utils/[fixtures, owntime, waiting]

const
  Lines = 40
  Points = 50
  Files = Lines * Points

const DrainLimit = when defined(windows): initDuration(milliseconds = 250)
                   else: initDuration(milliseconds = 50)
  ## What one drain of the inbox may take the UI thread. On the Windows CI
  ## runner (where `ownTime` is the plain wall clock and every file call is
  ## slow: listing the 2 000 files takes 1.6 s) the drains took 36, 48 and,
  ## taking 1 000 files out, 104 ms and 106 ms; they do no file call of their
  ## own (`takeWatched` works on the list in memory), so the machine is what
  ## is slow, and the limit there is allowed 5 times as much.

func place(i: int): (float64, float64) =
  (OriginX + 50.0 * float64(i mod Points), OriginY + 100.0 * float64(i div Points))

proc folderOf(fx: Fixtures): (string, string) =
  ## The folder of `Files` shot records, and the S file of their sources.
  let dir = fx.dir / "many"
  createDir(dir)
  var s = SpsFile(headers: @[SpsHeader(code: "00", description: "SPS format version num.",
    data: "SPS 2.1;")])
  for i in 0 ..< Files:
    let (x, y) = place(i)
    s.points.add SpsPoint(kind: pkSource, line: float64(1 + i div Points),
      point: float64(1 + i mod Points), index: 1, code: "E1", easting: x, northing: y,
      elevation: Elevation, dayOfYear: -1, hour: -1, minute: -1, second: -1)
    var w = openSeismicWriter(dir / ("shot" & align($i, 5, '0') & ".sgy"),
      SegyOutputOptions(traceSorting: 1, measurementSystem: 1))
    var buf = newSeq[float32](10)
    for c in 1 .. 4:
      var k = initTraceKeys()
      (k.record, k.channel, k.srcX, k.srcY) = (float64(10_000 + i), float64(c), x, y)
      (k.rcvX, k.rcvY, k.t0Ms, k.intervalUs, k.status) = (x + 25.0 * float64(c), y, 0.0,
        2000.0, tsLive)
      w.writeTrace(k, buf)
    doAssert w.close().len == 0
  let sPath = fx.dir / "many.s"
  doAssert writeSps(s, sPath).len == 0
  (dir, sPath)

proc readAll(st: var AppState; folder: string): tuple[listed, read: Duration; drain: Duration] =
  ## Lists `folder` and waits until every file's shots are read: how long
  ## the listing took, how long the shots, and the longest drain.
  let t0 = getMonoTime()
  st.apply Command(kind: ckBrowse, paths: @[folder])
  var listed = Duration()
  let ok = waitUntil((
    let d0 = ownTime()
    discard st.drainInbox()
    result.drain = max(result.drain, ownTime() - d0)
    if listed == Duration() and not st.fileList.scanning: listed = getMonoTime() - t0
    st.shots.shotFiles == Files and st.shots.pending.len == 0 and st.shots.job == NoJob),
    initDuration(seconds = 300))
  doAssert ok, "read " & $st.shots.shotFiles & " of " & $Files
  (listed, getMonoTime() - t0, result.drain)

func ms(d: Duration): string = $(d.inMicroseconds div 1000) & " ms"

proc main*() =

  withFixtures fx:
    let (folder, sPath) = fx.folderOf()
    let cache = fx.dir / "cache"
    var st = initAppState(indexCache = cache)
    st.apply Command(kind: ckLoadSurvey, paths: @[sPath])
    doAssert waitUntil((discard st.drainInbox(); st.survey.layers.len == 1))
    let first = st.readAll(folder)
    doAssert st.shots.pointRefs.len == Files, $st.shots.pointRefs.len
    echo "tshotsload: ", Files, " files: listed in ", first.listed.ms, ", their shots read in ",
      first.read.ms, "; the longest drain ", first.drain.ms
    # A new listing of the folder, while the shots are read: done as soon.
    var again = initAppState(indexCache = fx.dir / "cache2")
    again.apply Command(kind: ckLoadSurvey, paths: @[sPath])
    doAssert waitUntil((discard again.drainInbox(); again.survey.layers.len == 1))
    again.apply Command(kind: ckBrowse, paths: @[folder])
    doAssert waitUntil((discard again.drainInbox(); again.shots.shotFiles >= 100))
    let t1 = getMonoTime()
    again.apply Command(kind: ckBrowse, paths: @[folder])
    doAssert waitUntil((discard again.drainInbox(); not again.fileList.scanning))
    let relisted = getMonoTime() - t1
    echo "tshotsload: listed again while the shots are read: ", relisted.ms
    doAssert relisted < first.listed * 4 + initDuration(seconds = 1), "the listing waited: " &
      relisted.ms & " against " & first.listed.ms
    again.shutdown()
    # Another run: every file's shots from the shot cache.
    st.shutdown()
    var later = initAppState(indexCache = cache)
    later.apply Command(kind: ckLoadSurvey, paths: @[sPath])
    doAssert waitUntil((discard later.drainInbox(); later.survey.layers.len == 1))
    let cached = later.readAll(folder)
    echo "tshotsload: again, from the shot cache: listed in ", cached.listed.ms,
      ", their shots in ", cached.read.ms, "; the longest drain ", cached.drain.ms
    doAssert first.drain < DrainLimit and cached.drain < DrainLimit,
      "the UI thread's work: a drain of " & max(first.drain, cached.drain).ms
    # Half the files taken out of the folder at once: their shots go, in one
    # small piece of the UI thread's work.
    for i in countup(0, Files - 1, 2): removeFile(folder / ("shot" & align($i, 5, '0') & ".sgy"))
    var gone = Duration()
    let t2 = getMonoTime()
    doAssert waitUntil((
      let d0 = ownTime()
      discard later.drainInbox()
      gone = max(gone, ownTime() - d0)
      later.shots.shotFiles == Files div 2), initDuration(seconds = 60)),
      $later.shots.shotFiles & " files' shots left"
    doAssert later.shots.pointRefs.len == Files div 2
    echo "tshotsload: ", Files div 2, " files taken out: their shots gone in ",
      (getMonoTime() - t2).ms, "; the longest drain ", gone.ms
    doAssert gone < DrainLimit, "files taken out: a drain of " & gone.ms
    # The other half written again at once (a folder copied over): each read
    # again, only its own shots matched again.
    let t3 = getTime()
    for i in countup(1, Files - 1, 2):
      setLastModificationTime(folder / ("shot" & align($i, 5, '0') & ".sgy"),
        t3 + initDuration(seconds = 10))
    var (again2, busy) = (Duration(), Duration())
    let t4 = getMonoTime()
    doAssert waitUntil((
      let d0 = ownTime()
      discard later.drainInbox()
      again2 = max(again2, ownTime() - d0)
      busy += ownTime() - d0
      var fresh = 0
      for f in later.shots.files.values:
        if f.modified > t3: inc fresh
      fresh == Files div 2 and later.shots.pending.len == 0 and later.shots.job == NoJob),
      initDuration(seconds = 120)), "files written again: not all read again"
    doAssert later.shots.pointRefs.len == Files div 2
    echo "tshotsload: ", Files div 2, " files written again: read again in ",
      (getMonoTime() - t4).ms, "; the UI thread's drains ", busy.ms, " in all, the longest ",
      again2.ms
    # The Windows CI machine took 1 316 and 1 342 ms in all, so it gets 3 s.
    let busyLimit = when defined(windows): 3000 else: 1000
    doAssert again2 < DrainLimit and busy < initDuration(milliseconds = busyLimit),
      "files written again: a drain of " & again2.ms & ", " & busy.ms & " in all"
    later.shutdown()

when isMainModule:
  main()
