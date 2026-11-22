## "Reopen with options": a file opened again with other options goes
## through the same open job as any open, in the panel that shows it, at the
## record it showed, and every later open of it this run takes the options
## too; what the open did is in its properties (`summaryLines`, "How it was
## opened"): the standard detected or named (and what detection says), the
## index from the cache, from a sample or from every header, mapped or not,
## and the options in words.
##
## A SEG-Y file read with every header checked walks every header and
## neither reads nor writes the index cache; a SEG-D file named SEG-Y is
## read as SEG-Y, says that detection says SEG-D, and nothing raises; the
## defaults again read the index cache the first open wrote. A file read
## unmapped says so. A file not open is opened and shown. Agent control may
## not name a folder for a demultiplexed copy (a file written there). The
## seismic files are never changed.
##
## A reopen is opened first, off the UI thread, and replaces the file only
## when it opened with traces: a SEG-Y file named SEG-D leaves the file, the
## record shown, the selection and the kills as they were, says once that it
## failed, and the choice is not kept (a later open reads the file as before).
## A reopen that succeeds with the file's trace count keeps the selection,
## the geometry join, the record and the frozen FFT windows (at the new
## ids); with another count it drops them and says so.
##
## A reopen whose open has already posted is not adopted after the file was
## closed: the close stands, the new session is released. The choice is
## written only when that open is taken in: a second reopen at once, or a
## close while the open is still reading, leaves the choice the file had.
## A frozen correlation whose traces are in one file and whose reference is
## in another shifts only the ids that lay in the reopened file (not frozen,
## it follows the plot to the file opened next, and the file it left
## closes). Traces
## selected in another file, and points selected on the map, stay selected.
## A file that changes on disk while a reopen is reading ends open: with the
## choice asked for when that open succeeds, never silently closed. One cut
## short while that open is kept ends as the file is on disk now, once: the
## watch does not say that new open was cut short and open it again.
## A carried survey join is said to be matching when it starts, and kept
## only once that match succeeds (or dropped, and why, when it fails).
## Every panel showing the file keeps its own record across a successful
## reopen.
##
## Seen to fail (the failing reopen): with the trace-count test taken out of
## `adopt` (`elif false`), "stays as it was"; (the carried state): with
## `carryOver` not called, "the selection was lost"; (the close after a
## posted reopen): with `adopt` adding the new session when the old one is
## gone, "a closed file came back"; (the choice written before the open):
## with `reopenWith` storing the choice before the job, "the untried choice
## was kept"; (a cross-file reference): with every carried id shifted,
## "traces of the other file were shifted"; (the selection replaced whole):
## with `carryOver` selecting `smReplace`, "traces selected in the other
## file were dropped"; (the watch cancelling the reopen): with `closeSession`
## cancelling that open, "the file was gone after it changed"; (the join
## said kept at once): with `carryOver` adding "kept the survey join" when
## the match is only submitted, "said kept before the match"; (a dropped
## join said to leave the file as it was): with the import's cancel and
## failure texts used for a carried join, "is as it was"; (another
## panel's record): with `showPath` showing gather 0 of a file already
## open, "the other panel came back at the first record"; (a cut while a
## reopen is kept): with the size read before the open (`openSession`
## reading it first), "said cut short again"; (the close still having the
## file when the new open is shown): with that panel not shown again when
## the close ends, "not shown once the close ended"; (a carried rematch
## that matches nothing kept): with `changes` alone deciding, "a join that
## matched nothing was said kept".
##
## Seen to fail: with the choice not given to the open job (`openFileWork`
## called without `choice` in `showPath`), "not reopened with every header
## checked"; with the cache used whatever the choice (`openOptions` and
## `openCached` keeping `cache`), "a named standard reads the default
## reading's cache".

import std/[os, strutils, times]
import parseSEG
import viewSEG/core/filejobs
import viewSEG/core/state {.all.}
import viewSEG/core/watch
import viewSEG/view/headerviews
import utils/[faultyfs, fixtures, waiting]

func valueOf(lines: openArray[SummaryLine]; label: string): string =
  for l in lines:
    if not l.heading and l.label == label: return l.value
  ""

func has(log: MessageLog; part: string): bool =
  for e in log:
    if part in e.text: return true
  false

func opens(st: AppState; name: string): int =
  ## How many open jobs `name` had.
  for j in st.jobs.list:
    if j.spec.title == "Open " & name: inc result

proc shownSession(st: AppState): Session =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i] else: nil

proc showIt(st: var AppState; path: string) =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == path and
    st.panel(MainPanel).laidOut), "not shown: " & path

proc jobsIdle(st: AppState): bool =
  for j in st.jobs.list:
    if j.state in {jsQueued, jsRunning}: return false
  true

proc pump(st: var AppState; n = 100) =
  for i in 0 ..< n:
    discard st.drainInbox()
    sleep 10

proc reopen(st: var AppState; path: string; c: OpenChoice; origin = coWindow) =
  st.apply Command(origin: origin, kind: ckReopen, reopenPath: path, openChoice: c)

proc openIds(st: AppState; name: string): seq[JobId] =
  for j in st.jobs.list:
    if j.spec.title == "Open " & name: result.add j.id

proc postedSince(st: AppState; name: string; known: seq[JobId]): bool =
  ## Whether an open of `name` started after `known` has posted (done, not
  ## yet taken in).
  for j in st.jobs.list:
    if j.spec.title == "Open " & name and j.id notin known and j.state == jsDone:
      return true

proc baseOf(st: AppState; path: string): int =
  ## The first survey-wide id of the open file `path`; -1 when it is not open.
  let want = canonical(path)
  result = -1
  for s in st.sessions:
    if s.path == want: return s.base

proc joined(st: var AppState; path, spsS, spsR, spsX: string) =
  st.showIt(path)
  var files: seq[JoinFile]
  for p in [spsS, spsR, spsX]: files.add JoinFile(path: p, kind: jkSps)
  st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files)
  doAssert st.settle(st.joinedOf(st.sessions[0].id) >= 0), "not joined"

func cutShorts(log: MessageLog): int =
  for e in log:
    if "cut short" in e.text: inc result

var
  delayJobEnd: Gate
  hookHeld: Gate

proc delayHook(id: JobId; phase: string; back: bool) {.nimcall, gcsafe, raises: [].} =
  ## Holds the lane after a job's work returns, so a close queued next is
  ## still queued when the new open is shown.
  discard id
  discard phase
  if not back: return
  hookHeld.open()
  var n = 0
  while not delayJobEnd.isOpen and n < 30000:
    sleep 1
    inc n

proc main*() =

  block optionsForParseSEG:
    doAssert OpenChoice().isDefault and OpenChoice().usesCache
    let o = openOptions(OpenChoice(), "/c/x.pidx")
    doAssert o.kind == skUnknown and o.verify == vfSampled and not o.twosComplement8015 and
      o.access == faAuto and o.cache == "/c/x.pidx" and o.demuxDir == ""
    let named = openOptions(OpenChoice(standard: scSegd, verifyAll: true, twosComplement: true,
      access: acUnmapped, demuxDir: "/d"), "/c/x.pidx")
    doAssert named.kind == skSegd and named.verify == vfFull and named.twosComplement8015 and
      named.access == faUnmapped and named.demuxDir == "/d"
    doAssert named.cache == "", "a named standard reads the default reading's cache"
    doAssert OpenChoice(access: acMapped).usesCache, "the access changes no index"
    doAssert not OpenChoice(twosComplement: true).usesCache
    doAssert choiceText(OpenChoice()) == "the defaults"
    doAssert choiceWords(OpenChoice(standard: scSeg2, access: acMapped)) ==
      @["read as SEG-2, not detected", "mapped, wherever it lies"]

  block everyHeaderChecked:
    withFixtures fx:
      let path = fx.surveySegy()
      let name = path.extractFilename
      let before = (readFile(path), getLastModificationTime(path))
      let cacheDir = fx.dir / "cache"
      let cache = indexCacheFile(cacheDir, path)
      var st = initAppState(indexCache = cacheDir)
      st.showIt(path)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1)
      let first = summaryLines(st.shownSession, 1)
      doAssert first.valueOf("Read as") == "SEG-Y, detected", first.valueOf("Read as")
      doAssert first.valueOf("Options").startsWith("the defaults"), first.valueOf("Options")
      doAssert first.valueOf("Reading").startsWith("mapped"), first.valueOf("Reading")
      doAssert fileExists(cache), "the first open wrote no cache"
      let cachedAt = getLastModificationTime(cache)
      sleep 20
      st.reopen(path, OpenChoice(standard: scSegy, verifyAll: true))
      doAssert st.settle(not st.shownSession.isNil and
        st.shownSession.facts.opened.choice.verifyAll), "not reopened with every header checked"
      doAssert st.log.has(name & " is opened again: read as SEG-Y, not detected; every " &
        "trace header checked.")
      let s = st.shownSession
      doAssert st.opens(name) == 2, "not the open job: " & $st.opens(name)
      doAssert not s.facts.opened.fromCache, "the index came from the cache"
      doAssert getLastModificationTime(cache) == cachedAt, "the cache was written"
      doAssert st.panel(MainPanel).layers[0].source.gather == 1, "not shown again at record 2"
      let lines = summaryLines(s, 1)
      doAssert lines.valueOf("Read as") == "SEG-Y, as chosen", lines.valueOf("Read as")
      doAssert lines.valueOf("Index") == "made from every trace header (as chosen)",
        lines.valueOf("Index")
      doAssert lines.valueOf("Options") == "read as SEG-Y, not detected; every trace header " &
        "checked", lines.valueOf("Options")
      doAssert lines.valueOf("Traces") == $SurveyTraces
      # Shown again from the file list: the options hold for this run.
      st.apply Command(kind: ckClose, file: s.id)
      doAssert st.settle(st.sessions.len == 0)
      st.showIt(path)
      doAssert st.shownSession.facts.opened.choice.verifyAll, "the options went with the close"
      # The defaults again: the cache the first open wrote is read.
      st.reopen(path, OpenChoice())
      doAssert st.settle(not st.shownSession.isNil and st.opens(name) == 4 and
        st.shownSession.facts.opened.choice.isDefault)
      doAssert st.shownSession.facts.opened.fromCache, "the defaults did not read the cache"
      doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
      st.shutdown()

  block anotherStandardNamed:
    withFixtures fx:
      let path = fx.twoSetSegd()
      let before = (readFile(path), getLastModificationTime(path))
      var st = initAppState()
      st.showIt(path)
      # Named as what it is.
      st.reopen(path, OpenChoice(standard: scSegd))
      doAssert st.settle(not st.shownSession.isNil and
        st.shownSession.facts.opened.choice.standard == scSegd)
      doAssert summaryLines(st.shownSession, 0).valueOf("Read as") == "SEG-D, as chosen"
      # Named SEG-Y, it has no traces: it stays as it was, with the choice it had.
      st.reopen(path, OpenChoice(standard: scSegy))
      doAssert st.settle(st.log.has("failed") and not st.shownSession.isNil and
        st.shownSession.file.kind == skSegd and st.shownSession.len > 0),
        "the failed reopen did not end"
      doAssert st.openChoiceOf(canonical(path)).standard == scSegd, "the failed choice was kept"
      doAssert (readFile(path), getLastModificationTime(path)) == before, "the file changed"
      st.shutdown()

  block readUnmapped:
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.reopen(path, OpenChoice(access: acUnmapped)) # not open: opened and shown
      doAssert st.settle(not st.shownSession.isNil and st.panel(MainPanel).laidOut),
        "a file not open was not opened"
      let s = st.shownSession
      doAssert s.facts.opened.access == faUnmapped
      doAssert summaryLines(s, 0).valueOf("Reading").startsWith("unmapped") and
        summaryLines(s, 0).valueOf("Reading").endsWith("(as chosen)")
      st.shutdown()

  block agentsWriteNoCopy:
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      st.reopen(path, OpenChoice(demuxDir: fx.dir), coAgent)
      doAssert st.log.has("Ignored \"reopen\": agent control writes no file")
      doAssert st.opens(path.extractFilename) == 1
      st.reopen("", OpenChoice())
      doAssert st.log.has("Ignored \"reopen\": no file was named")
      st.shutdown()

  block failedReopenKeepsTheFile:
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1)
      let (id, base) = (st.sessions[0].id, st.sessions[0].base)
      st.apply Command(kind: ckSelect, traces: @[base + 3, base + 4], mode: smReplace)
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[base + 5],
        on: true)
      let logged = st.log.len
      st.reopen(path, OpenChoice(standard: scSegd))
      doAssert st.settle(st.log.has("stays as it was")), "the failed reopen did not end"
      doAssert st.opens(path.extractFilename) == 2
      doAssert st.sessions.len == 1 and st.sessions[0].id == id, "a failed reopen replaced the file"
      doAssert st.sessions[0].len == SurveyTraces
      doAssert st.panel(MainPanel).layers[0].source.gather == 1, "the record shown was lost"
      doAssert st.selection.selectedCount == 2, "the selection was lost"
      doAssert teKilled in st.editsOf(st.findPanel(MainPanel)).editsOf(5), "the kill was lost"
      doAssert st.openChoiceOf(canonical(path)).isDefault,
        "the failed choice was kept"
      var failures = 0
      var count = 0
      for e in st.log:
        inc count
        if count > logged and e.severity >= sevError and "Reopening" in e.text:
          inc failures
          doAssert "failed" in e.text and "stays as it was" in e.text, e.text
      doAssert failures == 1, "not one message of the failure: " & $failures
      doAssert st.log.len - logged < 8, "a page of messages: " & $(st.log.len - logged)
      # a later open of the file reads it as before
      st.apply Command(kind: ckClose, file: id)
      doAssert st.settle(st.sessions.len == 0)
      st.showIt(path)
      doAssert st.sessions[0].file.kind == skSegy and st.sessions[0].len == SurveyTraces
      st.shutdown()

  block successfulReopenKeepsWhatItCan:
    withFixtures fx:
      let path = fx.surveySegy()
      let sps = fx.surveySps()
      var st = initAppState()
      st.showIt(path)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 2)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 2)
      let base = st.sessions[0].base
      var files: seq[JoinFile]
      for p in [sps.s, sps.r, sps.x]: files.add JoinFile(path: p, kind: jkSps)
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: files)
      doAssert st.settle(st.joinedOf(st.sessions[0].id) >= 0), "not joined"
      st.apply Command(kind: ckSelect, traces: @[base + 3, base + 4], mode: smReplace)
      st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
        spectrumTraces: @[base + 6, base + 7])
      st.pump(50)
      doAssert st.spectra.len == 2
      # frozen, it keeps its traces (unfrozen it would follow the plot's)
      st.apply Command(kind: ckSpectrumDisplay, spectrum: st.spectra[1].id,
        spectrumShow: st.spectra[1].display, frozen: true)
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].facts.opened.choice.verifyAll and
        st.panel(MainPanel).laidOut)
      let s = st.sessions[0]
      doAssert s.base != base, "the file kept its first id"
      doAssert st.selection.selectedCount == 2 and s.base + 3 in st.selection.selected and
        s.base + 4 in st.selection.selected, "the selection was lost"
      doAssert st.panel(MainPanel).layers[0].source.gather == 2, "the record was lost"
      doAssert st.settle(st.joinedOf(s.id) >= 0), "the join was lost"
      doAssert st.spectra[1].traces == @[s.base + 6, s.base + 7],
          "the FFT window kept the old ids: " &
        $st.spectra[1].traces
      doAssert st.log.has("kept the selection")
      # a file of another trace count: all dropped, and said
      st.apply Command(kind: ckSelect, traces: @[s.base + 3], mode: smReplace)
      st.shutdown()

  block anotherTraceCountDropsWhatItKept:
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      let base = st.sessions[0].base
      let count = st.sessions[0].len
      st.apply Command(kind: ckSelect, traces: @[base + 3], mode: smReplace)
      st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel, spectrumTraces: @[base + 6])
      st.pump(50)
      doAssert st.spectra.len == 2
      # the file grows by a trace (a copy of its last) before it is read again
      var bytes = readFile(path)
      let step = (bytes.len - 3600 - 3200) div count # (one extended text header)
      doAssert 3600 + 3200 + step * count == bytes.len
      # appended, as a recorder does: Windows refuses to cut a file that is mapped (and
      # `writeFile` cuts it first), but lets another program append to it
      var more: File
      doAssert open(more, path, fmAppend)
      more.write(bytes[bytes.len - step ..< bytes.len])
      more.close()
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].len == count + 1 and
        st.panel(MainPanel).laidOut), "not reopened"
      doAssert st.selection.selectedCount == 0, "the selection of another file's ids was kept"
      doAssert st.spectra.len == 1, "the FFT window of the old traces was kept"
      doAssert st.log.has("dropped the selection, 1 plot window (it has " & $(count + 1) &
        " traces, it had " & $count & " traces)"), "what was dropped was not said"
      st.shutdown()

  block closedAfterTheOpenPostedStaysClosed:
    # The open job has posted (jsDone) and the inbox has not been drained: closing
    # then does not cancel it. The new session must not undo the close.
    withFixtures fx:
      let path = fx.surveySegy()
      let name = path.extractFilename
      var st = initAppState()
      st.showIt(path)
      let id = st.sessions[0].id
      let known = st.openIds(name)
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert waitUntil(st.postedSince(name, known)), "the reopen did not post"
      st.apply Command(kind: ckClose, file: id)
      doAssert st.sessions.len == 0, "the close did not take the file out"
      doAssert st.settle(st.sessions.len == 0), "a closed file came back"
      doAssert st.sessions.len == 0, "a closed file came back"
      doAssert st.openChoiceOf(canonical(path)).isDefault, "the untried choice was kept"
      st.shutdown()

  block supersededReopenKeepsNoChoice:
    # SEG-D, then SEG-2 at once, on a SEG-Y: both fail. The first's untried
    # choice must not become what a later open uses.
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      st.reopen(path, OpenChoice(standard: scSegd))
      st.reopen(path, OpenChoice(standard: scSeg2))
      doAssert st.settle(st.log.has("stays as it was") and st.jobsIdle and
        st.sessions.len == 1 and st.sessions[0].file.kind == skSegy and
        st.sessions[0].len == SurveyTraces), "the failed reopens did not end"
      doAssert st.openChoiceOf(canonical(path)).isDefault, "the untried choice was kept"
      st.apply Command(kind: ckClose, file: st.sessions[0].id)
      doAssert st.settle(st.sessions.len == 0)
      st.showIt(path)
      doAssert st.sessions[0].file.kind == skSegy and st.sessions[0].facts.opened.choice.isDefault,
        "a later open used a choice that was never in force"
      st.shutdown()

  block closeMidReopenKeepsNoChoice:
    # The open is held in its read, then the file is closed: the choice asked
    # for was never in force.
    install()
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      let id = st.sessions[0].id
      fault(path, fkHang, {foMapped})
      st.reopen(path, OpenChoice(standard: scSegd, verifyAll: true))
      doAssert waitUntil(hung() > 0), "the reopen was not held in its read"
      st.apply Command(kind: ckClose, file: id)
      releaseAll()
      doAssert st.settle(st.sessions.len == 0), "the file came back"
      doAssert st.openChoiceOf(canonical(path)).isDefault, "the untried choice was kept"
      st.shutdown()
    releaseAll()

  block unfrozenWindowFollowsTheNewFile:
    # Not frozen, the plot of `a`'s traces follows the plot to `b`, and `a`,
    # which nothing shows or uses any more, is closed.
    withFixtures fx:
      let a = fx.surveySegy()
      let b = fx.dir / "other.sgy"
      copyFile(a, b)
      var st = initAppState()
      st.showIt(a)
      st.apply Command(kind: ckOpenPlot, plotView: avCorrelation,
        plotTraces: @[st.sessions[0].base + 3, st.sessions[0].base + 4])
      doAssert st.plots.len == 1, "the correlation window was not opened"
      st.apply Command(kind: ckOpen, paths: @[b])
      doAssert st.settle(st.sessions.len == 1 and st.baseOf(b) >= 0 and
        st.plots[0].file == "other.sgy"), "the window did not follow to the new file"
      doAssert st.baseOf(a) < 0, "the file followed away from was kept open"
      st.shutdown()

  block anotherFilesSelectionStays:
    # Traces selected in the other file, and a point selected on the map, are
    # not the reopened file's: they stay.
    withFixtures fx:
      let a = fx.surveySegy()
      let b = fx.dir / "other.sgy"
      copyFile(a, b)
      var st = initAppState()
      st.showIt(a)
      st.apply Command(kind: ckOpen, paths: @[b])
      doAssert st.settle(st.sessions.len == 2), "the second file did not open"
      let (baseA, baseB) = (st.baseOf(a), st.baseOf(b))
      doAssert baseB >= 0 and baseB != baseA
      # a frozen window of the other file keeps it open when this one is shown again
      st.apply Command(kind: ckOpenPlot, plotView: avEnvelope, plotTraces: @[baseB + 1])
      doAssert st.plots.len == 1, "the other file's window was not opened"
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: st.plots[0].params,
        plotFrozen: true)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
      doAssert st.settle(st.sessions.len == 2 and st.baseOf(a) == baseA)
      st.apply Command(kind: ckSelect, traces: @[baseA + 3], mode: smReplace)
      st.apply Command(kind: ckSelect, traces: @[baseB + 5, baseB + 6], mode: smAdd)
      let point = PointRef(layer: SurveyLayerId(1), role: prSource, point: 3)
      st.apply Command(kind: ckSelectPoints, points: @[point], pointMode: smAdd)
      doAssert st.selection.selectedCount == 3 and st.selection.points == @[point]
      st.reopen(a, OpenChoice(verifyAll: true))
      doAssert st.settle(st.baseOf(a) != baseA and st.sessions.len == 2),
        "the file was not opened again"
      let newA = st.baseOf(a)
      doAssert newA + 3 in st.selection.selected, "the reopened file's trace was not kept"
      doAssert baseB + 5 in st.selection.selected and baseB + 6 in st.selection.selected,
        "traces selected in the other file were dropped"
      doAssert st.selection.points == @[point], "the map's selected points were dropped"
      st.shutdown()

  block changedDuringReopenStaysOpen:
    # The open is held in its read when the watch says the file changed: the
    # close that shows it again must not cancel that open and then attach to
    # the cancelled one. The file ends open, with the choice asked for.
    install()
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      let size = st.sessions[0].size
      fault(path, fkHang, {foMapped})
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert waitUntil(hung() > 0), "the reopen was not held in its read"
      st.mailbox.post Msg(kind: mkWatched, watched: @[WatchedFile(path: canonical(path),
        exists: true, kind: fkSegy, size: size + 1, modified: getTime(), changing: false)])
      discard st.drainInbox()
      releaseAll()
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].path == canonical(path) and
        st.sessions[0].facts.opened.choice.verifyAll), "the file was gone after it changed"
      st.shutdown()
    releaseAll()

  block carriedJoinIsKeptWhenItSucceeds:
    withFixtures fx:
      let path = fx.surveySegy()
      let sps = fx.surveySps()
      var st = initAppState()
      st.joined(path, sps.s, sps.r, sps.x)
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert st.settle(st.log.has("matching the survey again")), "the match was not said to start"
      doAssert not st.log.has("kept the survey join"), "said kept before the match"
      doAssert st.settle(st.sessions.len == 1 and st.joinedOf(st.sessions[0].id) >= 0 and
        st.log.has("kept the survey join")), "a join that succeeded was not said kept"
      st.shutdown()

  block carriedJoinIsDroppedWhenItFails:
    withFixtures fx:
      let path = fx.surveySegy()
      let sps = fx.surveySps()
      var st = initAppState()
      st.joined(path, sps.s, sps.r, sps.x)
      removeFile(sps.x) # gone when the match runs again
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert st.settle(st.log.has("matching the survey again"))
      doAssert not st.log.has("kept the survey join"), "said kept before the match"
      doAssert st.settle(st.sessions.len == 1 and st.log.has(path.extractFilename &
        " dropped the survey join: the match failed:")), "a join that failed was not said dropped"
      doAssert st.joinedOf(st.sessions[0].id) < 0, "a failed join was kept"
      doAssert not st.log.has("is as it was"), "a dropped join was said to leave the file as it was"
      doAssert not st.log.has("The survey match"), "the drop was said again in the words"
      doAssert not st.log.has("Import the survey for"), "the failed import was said again"
      var drops = 0
      for e in st.log:
        if "dropped the survey join" in e.text: inc drops
      doAssert drops == 1, "the drop was said " & $drops & " times"
      st.shutdown()

  block eachPanelKeepsItsRecord:
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      let second = st.addPanel()
      st.showIt(path)
      st.apply Command(kind: ckGather, panel: MainPanel, gather: 2)
      doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 2)
      st.apply Command(kind: ckShowFile, panel: second, path: path)
      doAssert st.settle(st.panel(second).layers[0].source.gather == 0)
      st.apply Command(kind: ckGather, panel: second, gather: 1)
      doAssert st.settle(st.panel(second).layers[0].source.gather == 1)
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert st.settle(st.sessions.len == 1 and st.sessions[0].facts.opened.choice.verifyAll and
        st.panel(MainPanel).laidOut and st.panel(second).laidOut), "not reopened"
      doAssert st.panel(MainPanel).layers[0].source.gather == 2, "the first panel lost its record"
      doAssert st.panel(second).layers[0].source.gather == 1,
        "the other panel came back at the first record"
      st.shutdown()

  when not defined(windows):
    # Windows refuses to cut a file that has a mapped view (error 1224): the file this test
    # cuts cannot be cut there.
    block cutDuringKeptReopenIsReadOnce:
      # The open is held after it has read the file's size, the file is cut, and
      # the watch sees it. The kept open comes back as the file is now; the watch's
      # next look must not say that session was cut short and open the file again.
      install()
      withFixtures fx:
        let path = fx.surveySegy()
        let name = path.extractFilename
        var st = initAppState(watchEvery = initDuration(hours = 1))
        st.showIt(path)
        let before = st.sessions[0].len
        st.folderWatch.stop() # the looks below are the test's, not the watch thread's
        fault(path, fkHang, {foMapped})
        st.reopen(path, OpenChoice(verifyAll: true))
        doAssert waitUntil(hung() > 0), "the reopen was not held after it read the size"
        let whole = readFile(path)
        writeFile(path, whole[0 ..< whole.len div 2])
        let nowSize = getFileSize(path)
        let nowTime = getLastModificationTime(path)
        proc postWatch() =
          st.mailbox.post Msg(kind: mkWatched, watched: @[WatchedFile(path: canonical(path),
            exists: true, kind: fkSegy, size: nowSize, modified: nowTime, changing: false)])
        postWatch()
        discard st.drainInbox()
        releaseAll()
        doAssert st.settle(st.sessions.len == 1 and st.sessions[0].facts.opened.choice.verifyAll and
          st.sessions[0].len > 0 and st.sessions[0].len < before), "the reopen did not come back"
        let cuts = st.log.cutShorts
        let opens = st.opens(name)
        postWatch() # the look once the new session is open
        discard st.drainInbox()
        doAssert st.log.cutShorts == cuts, "said cut short again (" & $st.log.cutShorts & ")"
        doAssert st.sessions.len == 1 and st.sessions[0].size == nowSize,
          "not the file as it is now: size " & $(if st.sessions.len == 0: "gone" else:
          $st.sessions[0].size) & ", the file is " & $nowSize
        doAssert st.opens(name) == opens, "opened again (" & $st.opens(name) & ")"
        doAssert st.sessions[0].facts.opened.choice.verifyAll
        st.shutdown()
      releaseAll()

  block shownOnceTheCloseEnds:
    # The open's lane is held after the reopen posts, so the close of the open
    # it replaces is still queued when the new one is shown: the panel cannot
    # take the file, and must be shown once that close ends.
    withFixtures fx:
      let path = fx.surveySegy()
      var st = initAppState()
      st.showIt(path)
      doAssert st.settle(st.jobsIdle), "a job was still running"
      delayJobEnd.close()
      hookHeld.close()
      setJobHook(delayHook)
      try:
        st.reopen(path, OpenChoice(verifyAll: true))
        doAssert waitUntil(hookHeld.isOpen), "the reopen did not finish its work"
        discard st.drainInbox() # taken in while the lane is held in the hook
        doAssert st.log.has("is busy"), "the close did not hold the file"
        doAssert not st.panel(MainPanel).laidOut, "shown while the close still had the file"
        delayJobEnd.open()
        doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
          st.sessions[0].facts.opened.choice.verifyAll), "not shown once the close ended"
      finally:
        delayJobEnd.open()
        setJobHook(nil)
      st.shutdown()

  block carriedJoinIsDroppedWhenNothingMatches:
    # The survey's S and R lines are rewritten (x100) before the reopen. The
    # relation file still fills the stations the headers lack, which counts as
    # a key change, but no seismic trace is in the station lists: the join is
    # dropped, and no trace keeps a survey station.
    withFixtures fx:
      let path = fx.surveySegy()
      let name = path.extractFilename
      let sps = fx.surveySps()
      var st = initAppState()
      st.joined(path, sps.s, sps.r, sps.x)
      proc scaleLines(p: string) =
        var f = readSps(p)
        for pt in f.points.mitems: pt.line = pt.line * 100
        let wrote = writeSps(f, p)
        doAssert wrote.len == 0, $wrote
      scaleLines(sps.s)
      scaleLines(sps.r)
      st.reopen(path, OpenChoice(verifyAll: true))
      let dropped = name & " dropped the survey join: the survey matches none of its traces."
      doAssert st.settle(st.sessions.len == 1 and st.log.has(dropped)),
        "a join that matched nothing was not said dropped"
      doAssert not st.log.has("kept the survey join"), "a join that matched nothing was said kept"
      var drops = 0
      for e in st.log:
        if "dropped the survey join" in e.text: inc drops
      doAssert drops == 1, "the drop was said " & $drops & " times"
      doAssert st.joinedOf(st.sessions[0].id) < 0, "a join that matched nothing was kept"
      let keys = st.sessions[0].file.traceKeys([0, 10, 40, 71])
      for k in keys:
        doAssert k.srcLine.isNaN and k.rcvLine.isNaN, "a trace kept a survey station"
      st.shutdown()

  block carriedJoinIsDroppedWhenCancelled:
    # The rematch reads a survey file of a million receivers, which takes a
    # second or two: the import is cancelled while it reads. The drop line names
    # the cancel once, and the import's own "was cancelled" line is not said.
    withFixtures fx:
      let path = fx.surveySegy()
      let name = path.extractFilename
      let sps = fx.surveySps()
      let own = (s: fx.dir / "cancelled.s", r: fx.dir / "cancelled.r", x: fx.dir / "cancelled.x")
      copyFile(sps.s, own.s)
      copyFile(sps.r, own.r)
      copyFile(sps.x, own.x)
      var st = initAppState()
      st.joined(path, own.s, own.r, own.x)
      copyFile(fx.bigSps(1000, 1000), own.r) # what the rematch reads
      st.reopen(path, OpenChoice(verifyAll: true))
      doAssert st.settle(st.joinUnderWay.job != NoJob and st.joinUnderWay.step == jpReading),
        "the rematch was not reading"
      st.apply Command(kind: ckCancelJob, job: st.joinUnderWay.job)
      let dropped = name & " dropped the survey join: the match was cancelled."
      doAssert st.settle(st.joinUnderWay.job == NoJob and st.log.has(dropped)),
        "a cancelled carried join was not said dropped"
      doAssert not st.log.has("Import the survey for"), "the cancelled import was said again"
      var drops = 0
      for e in st.log:
        if "dropped the survey join" in e.text: inc drops
      doAssert drops == 1, "the drop was said " & $drops & " times"
      doAssert st.joinedOf(st.sessions[0].id) < 0, "a cancelled join was kept"
      st.shutdown()

when isMainModule:
  main()
