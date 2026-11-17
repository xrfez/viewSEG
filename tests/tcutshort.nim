## A file cut short while it is open, and a read that fails, never end the
## program, for a file read through a memory map and for one read unmapped
## (`core/cutfile`, `core/reader`, `core/inspector`, `core/spectrumreader`):
## another program truncates a copy of a fixture while it is shown; the
## traces before the cut are still drawn, those past it are drawn blank (the
## tile counts them in `failed`), and Messages says so once, however many
## views are read after it. The Headers window's table and an FFT window of
## a trace past the cut answer with a plain sentence. A read the drive fails
## (the seam's `fkFail` on the reader's read) is said once, the
## panel says its drive is not answering, and the rows are read again with
## Retry once it answers; a mapped read that failed is read again only by a
## new open, which Retry does.
##
## Not tested: a real share (the guard's `dcIo` rows: parseSEG's own test
## covers them), and Windows, where a mapped file cannot be cut.
##
## Seen to fail: against the code before (the reader's own `stat` check
## before each read), `aFileCutWhileOpen` found no tile for a view past the
## cut and not the one line; with the reader's `cutShort` call before a read
## taken out, the unmapped file's cached bytes were drawn past the cut
## (`past.failed == past.traces.len`); with the cut said on every tile, the
## line came 2 times; with a drive's failure said on every request,
## `aReadThatFailsIsReadAgain` found it said again for each view.
##
## Runs alone: it truncates files while the viewer reads them.

import std/[os, strutils, times]
import parseSEG
import viewSEG/core/state
import utils/[faultyfs, fixtures, waiting]

const
  Traces = 2000
  Samples = 1000
  Kept = 1000 ## the traces the cut leaves
  TraceBytes = 240 + Samples * 4
  Reach = 128
    ## the traces before a cut that fail with it: parseSEG fails the chunk
    ## of traces whose read meets the cut

func said(log: MessageLog; part: string): int =
  for e in log:
    if part in e.text: inc result

proc look(st: var AppState; first, last: int) =
  var v = fitAll(st.panel(MainPanel).layout, 800, 600)
  v.traces = Span(lo: float64(first) - 0.5, hi: float64(last) + 0.5)
  st.apply Command(kind: ckView, panel: MainPanel, view: v)

proc read(st: var AppState; first, last: int): Tile =
  ## The tile of a view of traces `first` .. `last`.
  let before = st.tilesTaken
  st.look(first, last)
  doAssert st.settle(st.tilesTaken > before), "the view " & $first & ".." & $last & " was not read"
  st.tiles(0)[^1]

func hasSamples(t: Tile; row: int): bool =
  for i in 0 ..< t.columns:
    if t.data[row * t.columns + i] != 0: return true

proc unreadable(st: AppState): bool = st.waiting(0).kind == wkUnreadable

proc cutAt(path: string; traces: int) =
  ## Truncates `path` (the same file, as another program would) to its
  ## header and `traces` traces.
  let size = 3600 + traces * TraceBytes
  doAssert size < getFileSize(path)
  writeFile(path, readFile(path)[0 ..< size])

proc opened(st: var AppState; path: string; access: AccessChoice) =
  st.apply Command(kind: ckReopen, reopenPath: path, openChoice: OpenChoice(access: access))
  doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)

proc main*() =
  install()
  for access in [acMapped, acUnmapped]:
    when defined(windows):
      if access == acMapped: continue # a mapped file cannot be cut there
    withFixtures fx:
      let path = fx.dir / "cut.sgy"
      copyFile(fx.manyTracesSegy(Traces, Samples), path)
      var st = initAppState(watchEvery = initDuration(hours = 1))           # the watch does not look
      st.opened(path, access)
      let before = st.read(0, 20) # (unmapped, it caches the file's tail: bytes held before
      doAssert before.failed == 0 and before.hasSamples(0) # a cut read as they were, until asked)
      cutAt(path, Kept)
      let past = st.read(1500, 1540)
      doAssert past.failed == past.traces.len, $access & ": " & $past.failed & " failed of " &
        $past.traces.len
      let across = st.read(Kept - 20, Kept + 20)
      var beyond = 0 # (the tile holds the view's margins too)
      for t in across.traces:
        if t >= Kept: inc beyond
      doAssert across.failed >= beyond and across.failed <= beyond + Reach and beyond > 0,
        $access & ": failed " & $across.failed & ", " & $beyond & " lie past the cut"
      for r, t in across.traces:
        if t < Kept - Reach:
          doAssert across.hasSamples(r), $access & ": trace " & $t & " before the cut"
        elif t >= Kept:
          doAssert not across.hasSamples(r), $access & ": trace " & $t & " past it"
      let whole = st.read(400, 440)
      doAssert whole.failed == 0 and whole.hasSamples(0) and whole.hasSamples(whole.traces.high),
        $access & ": the traces before the cut are read"
      # said once, though three views met the cut
      doAssert st.log.said("was cut short while it was open") == 1,
        $access & ": said " & $st.log.said("was cut short while it was open") & " times"
      discard st.read(1700, 1740)
      doAssert st.log.said("was cut short while it was open") == 1, "said again on a later view"
      # the Headers window's table
      st.apply Command(kind: ckSelect, traces: @[st.sessions[0].base + 1600], mode: smReplace)
      let view = TableView(fields: @["keys.channel"], scope: tsFile, rows: 1590 .. 1595)
      st.apply Command(kind: ckInspect, inspect: {ipTraceHeaders, ipTable}, table: view)
      doAssert waitUntil((discard st.drainInbox(); not st.inspection.waiting and
        (st.inspection.answer.table.problems.len > 0 or
        st.inspection.answer.table.rowTraces.len > 0))), "the table did not answer"
      doAssert st.inspection.answer.table.problems.len > 0 or
        st.inspection.answer.traces.len > 0, $access & ": nothing said of the table"
      for p in st.inspection.answer.table.problems:
        doAssert "ssertion" notin p and p.len < 400, p
      if access == acMapped:
        doAssert st.inspection.answer.table.problems.len > 0 and
          "cut short" in st.inspection.answer.table.problems[0],
          $st.inspection.answer.table.problems
      # an FFT window of a trace past the cut
      st.apply Command(kind: ckSpectrum, spectrumOf: MainPanel,
        spectrumTraces: @[st.sessions[0].base + 1600])
      let w = st.spectra.high
      doAssert st.settle(not st.spectra[w].waiting), "the FFT window did not answer"
      if access == acMapped:
        doAssert "cut short" in st.spectra[w].spectrum.problem, st.spectra[w].spectrum.problem
      st.shutdown()

  block aReadThatFailsIsReadAgain:
    # The drive fails the reader's reads (`fkFail`), the read fails, one line says so and the panel says its
    # drive is not answering; once it answers, Retry reads them.
    withFixtures fx:
      let path = fx.dir / "io.sgy"
      copyFile(fx.manyTracesSegy(Traces, Samples), path)
      var st = initAppState(watchEvery = initDuration(hours = 1))
      st.opened(path, acUnmapped)
      discard st.read(0, 20)
      fault(path, fkFail, {foMapped})
      let before = st.tilesTaken
      st.look(500, 540)
      doAssert st.settle(st.log.said("Cannot read io.sgy") == 1 and st.unreadable),
        "the failed read was not said once"
      st.look(700, 740)
      st.look(900, 940)
      discard st.drainInbox()
      sleep 100
      discard st.drainInbox()
      doAssert st.log.said("Cannot read io.sgy") == 1, "said again for each view"
      releaseAll()
      st.apply Command(kind: ckRetry, panel: MainPanel)
      let t = st.read(500, 540)
      doAssert t.failed == 0 and t.hasSamples(0), "not read again"
      doAssert not st.unreadable, "still said to be unreadable"
      discard before
      st.shutdown()
    releaseAll()

when isMainModule: main()
