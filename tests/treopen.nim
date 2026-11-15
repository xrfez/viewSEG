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

proc reopen(st: var AppState; path: string; c: OpenChoice; origin = coWindow) =
  st.apply Command(origin: origin, kind: ckReopen, reopenPath: path, openChoice: c)

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
    doAssert st.log.has(name & " is opened again with read as SEG-Y, not detected; every " &
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
    st.reopen(path, OpenChoice(standard: scSegy))
    doAssert st.settle(not st.shownSession.isNil and
      st.shownSession.facts.opened.choice.standard == scSegy)
    let s = st.shownSession
    doAssert s.file.kind == skSegy and s.facts.opened.kind == skSegy
    doAssert s.facts.opened.detected == skSegd, $s.facts.opened.detected
    let lines = summaryLines(s, 0)
    doAssert lines.valueOf("Read as") == "SEG-Y, as chosen (detection says SEG-D)",
      lines.valueOf("Read as")
    # Read as what it is again.
    st.reopen(path, OpenChoice(standard: scSegd))
    doAssert st.settle(not st.shownSession.isNil and st.shownSession.file.kind == skSegd)
    doAssert summaryLines(st.shownSession, 0).valueOf("Read as") == "SEG-D, as chosen"
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
