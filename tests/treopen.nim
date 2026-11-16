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
## the geometry join, the record and the FFT windows (at the new ids); with
## another count it drops them and says so.
##
## A reopen whose open has already posted is not adopted after the file was
## closed: the close stands, the new session is released.
##
## Seen to fail (the failing reopen): with the trace-count test taken out of
## `adopt` (`elif false`), "stays as it was"; (the carried state): with
## `carryOver` not called, "the selection was lost"; (the close after a
## posted reopen): with `adopt` adding the new session when the old one is
## gone, "a closed file came back".
##
## Seen to fail: with the choice not given to the open job (`openFileWork`
## called without `choice` in `showPath`), "not reopened with every header
## checked"; with the cache used whatever the choice (`openOptions` and
## `openCached` keeping `cache`), "a named standard reads the default
## reading's cache".

import std/[os, strutils, times]
import parseSEG
import viewSEG/core/[filejobs, state]
import viewSEG/view/headerviews
import utils/[fixtures, waiting]

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
    doAssert st.log.has(name & " is opened again: read as SEG-Y, not detected; every " &
      "trace header checked.")
    doAssert st.settle(not st.shownSession.isNil and
      st.shownSession.facts.opened.choice.verifyAll), "not reopened with every header checked"
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
    st.pump(150)
    doAssert st.shownSession.file.kind == skSegd and st.shownSession.len > 0
    doAssert st.openChoiceOf(canonical(path)).standard == scSegd, "the failed choice was kept"
    doAssert st.log.has("failed")
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
    st.pump(150)
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
    writeFile(path, bytes & bytes[bytes.len - step ..< bytes.len])
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
    st.shutdown()
