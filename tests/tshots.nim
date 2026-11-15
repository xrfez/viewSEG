## The folder's shots in `core`, without a window (`core/shots`): a folder
## of five shot records of `mapSps`'s spread (SEG-Y files whose headers give
## the sources' coordinates, not their stations), the survey's S and R
## files loaded from elsewhere.
##
## - Listed, the files' shots are read on background jobs and matched to the
##   survey's sources by place: five sources have a file, the right ones;
##   nothing is read while no survey file with sources is loaded.
## - A click on such a source (`ckShowPoints`) shows its file, not open
##   before, at its record.
## - What was read is kept beside the index cache: the folder listed again by
##   another program run opens none of its files (no mapped read).
## - A file that does not answer holds back only itself: the job given up
##   after `StallAfter`, the rest read by the next one, the file tried again
##   after `RetryAfter` and read then.
## - A file gone from the folder takes its shot off the map.
## - Nothing of it touches the file system on the UI thread, and every file
##   is as it was (bytes and time).
## - A file that does not answer is not tried again while its first try
##   still hangs: each try that hangs holds a thread until the drive answers.
##
## Seen to fail: with the stalled job waited for (no give-up), "the rest
## read" timed out with 2 of 5 files read; with the shot cache not read,
## "listed again" found 3 mapped reads of shot-2.sgy; with a file tried again
## after `RetryAfter` whatever its first try was doing, "2 tries of the file
## hang".

import std/[os, sets, tables, times]
import viewSEG/core/state
import utils/[faultyfs, fixtures, waiting]

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

proc sourcePoint(st: AppState; line, k: int): PointRef =
  for i in 0 ..< st.survey.layers.len:
    template l: untyped = st.survey.layers[i]
    if l.origin == loSurveyFile:
      let p = l.stationPoint(prSource, Station(line: MapSrcLines[line], point: 1001 +
        float64(k), index: 1))
      if p >= 0: return PointRef(layer: l.id, role: prSource, point: p)
  doAssert false, "no source " & $line & "/" & $k

func done(x: ShotIndex; n: int): bool =
  x.shotFiles == n and x.pending.len == 0 and x.jobPaths.len == 0 and x.job == NoJob

install()
const Shot = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 5)]

withFixtures fx:
  let sps = fx.mapSps()
  let folder = fx.dir / "shots"
  createDir(folder)
  var paths: seq[string]
  for (line, k) in Shot:
    paths.add fx.mapShotSegy(line, k, name = "shots" / "shot-" & $mapRecord(line, k) & ".sgy")
  let cache = fx.dir / "cache"

  var before: seq[(string, Time)]
  for p in paths: before.add (readFile(p), getLastModificationTime(p))

  block listedAndMatched:
    var st = initAppState(indexCache = cache)
    st.apply Command(kind: ckBrowse, paths: @[folder])
    doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 5)
    for _ in 0 .. 20: discard st.drainInbox()
    doAssert st.shots.shotFiles == 0 and st.shots.job == NoJob,
      "nothing read without a survey file's sources"
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
    doAssert st.settle(st.shots.done(5)), "the folder's shots: " & $st.shots.shotFiles
    doAssert st.shots.pointRefs.len == 5, $st.shots.pointRefs.len
    for (line, k) in Shot:
      let at = st.shots.shotsAt(st.sourcePoint(line, k))
      doAssert at.len == 1 and at[0].record == float64(MapFfid + mapRecord(line, k)) and
        at[0].gather == 0, $at
    doAssert st.shots.shotsAt(st.sourcePoint(1, 1)).len == 0, "a source with no file"
    # A click on a source whose file is not open: shown, at its record.
    doAssert st.sessions.len == 0
    st.apply Command(kind: ckShowPoints, points: @[st.sourcePoint(1, 5)])
    let want = folder / "shot-" & $mapRecord(1, 5) & ".sgy"
    doAssert st.settle(st.sessions.len == 1 and st.selection.activeGather.file ==
      st.sessions[0].id), "the click showed no file"
    doAssert st.sessions[0].path == want and st.fileList.chosen == want
    for i, p in paths: # read, never written
      doAssert readFile(p) == before[i][0] and getLastModificationTime(p) == before[i][1], p
    # A file gone from the folder: its source no longer has a file.
    removeFile(paths[0])
    st.apply Command(kind: ckBrowse, paths: @[folder])
    doAssert st.settle(not st.fileList.scanning and st.shots.done(4)), $st.shots.shotFiles
    doAssert st.shots.shotsAt(st.sourcePoint(0, 0)).len == 0 and st.shots.pointRefs.len == 4
    discard fx.mapShotSegy(0, 0, name = "shots" / "shot-" & $mapRecord(0, 0) & ".sgy")
    doAssert uiCalls().len == 0, "the UI thread called the file system: " & $uiCalls()
    st.shutdown()

  block listedAgain:
    # Another run: every file's shots from the cache, no file opened.
    resetCounts()
    var st = initAppState(indexCache = cache)
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
    st.apply Command(kind: ckBrowse, paths: @[folder])
    doAssert st.settle(st.shots.done(5)), $st.shots.shotFiles
    doAssert st.shots.pointRefs.len == 5
    for p in paths[1 .. ^1]: # (the first was written again since)
      doAssert calls(foMapped, p) == 0, "listed again: " & $calls(foMapped, p) &
        " mapped reads of " & p
    st.shutdown()

  block aFileThatDoesNotAnswer:
    removeDir(cache)
    resetCounts()
    var st = initAppState(indexCache = cache)
    st.apply Command(kind: ckLoadSurvey, paths: @[sps.s, sps.r])
    let stuck = paths[2]
    fault(stuck, fkHang, {foMapped}) # (the listing reads its first bytes as before)
    st.apply Command(kind: ckBrowse, paths: @[folder])
    doAssert st.settle(hung() == 1), "the file does not answer"
    advanceFsClock(StallAfter + initDuration(seconds = 1))
    doAssert st.settle(st.shots.shotFiles == 4 and st.shots.later.len == 1 and
      st.shots.job == NoJob), "the rest read: " & $st.shots.shotFiles & " of 5"
    doAssert stuck notin st.shots.files and st.shots.later[0].path == stuck
    # Not tried again while the first try still hangs (each try that hangs
    # holds a thread until the drive answers: one a minute, for ever).
    for _ in 1 .. 2:
      advanceFsClock(RetryAfter + initDuration(seconds = 1))
      discard waitUntil((discard st.drainInbox(); hung() > 1), initDuration(seconds = 2))
      doAssert hung() == 1, $hung() & " tries of the file hang"
      doAssert st.shots.later.len == 1 and st.shots.later[0].path == stuck
    release(stuck)
    doAssert waitUntil(hung() == 0)
    advanceFsClock(RetryAfter)
    doAssert st.settle(st.shots.done(5) and st.shots.later.len == 0), "tried again"
    doAssert st.shots.pointRefs.len == 5
    doAssert uiCalls().len == 0, $uiCalls()
    st.shutdown()

echo "tshots: ok"
