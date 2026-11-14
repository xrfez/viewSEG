## The file list in `core`: a folder is listed by a scan on the background
## lane, its seismic files in natural order (the others counted, not
## listed), without opening any; the first file is shown; stepping through
## the folder shows each file in the same plot window with the display
## settings, the order and the scales it had, closes the file stepped away
## from, and reads the index cache when it comes back; a file chosen while
## another is still opening replaces it; one file named lists its folder; a
## folder that does not exist is reported; a named pipe in a folder is never
## opened; the files are never changed, not even by an export named after one.
##
## Seen to fail: with `showReplacing` not closing the file it replaces,
## `stepThroughAFolder` found 2 files open after the first step; with
## `showPath` not cancelling
## the open it supersedes, `aNewChoiceWins` found the opens of `a.sgy` run
## to the end (and dropped); with `takeListed` ignoring `listChosen`,
## `oneFileListsItsFolder` showed the folder's first file instead of the one
## named; with `naturalCmp` comparing digits as text, `naturalOrder` put
## shot10 before shot2; with the scan sniffing every name of the folder,
## `namedPipesAreNotOpened` found the scan stuck in the pipe's open (and
## with it the background lane and the quit); with exports not checking the
## path, `exportsNeverGoOverSeismicFiles` saw the messages export accepted
## over the file shown.

import std/[os, strutils, times]
import viewSEG/core/[filejobs, state]
import utils/[fixtures, waiting]
when not defined(windows):
  from std/posix import nil

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

func count(log: MessageLog; part: string): int =
  for e in log:
    if part in e.text: inc result

type Snapshot = tuple[bytes: string; time: Time]

proc snapshot(path: string): Snapshot = (readFile(path), getLastModificationTime(path))

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc laidOut(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layout.traces > 0

proc makeFolder(fx: Fixtures): string =
  ## A field folder: three seismic files named so that only a natural
  ## order puts them right, a text file, a hidden file and a subfolder.
  result = fx.dir / "line 7"
  createDir(result / "processed")
  copyFile(fx.surveySegy(), result / "shot10.sgy")
  copyFile(fx.twoSetSegd(), result / "shot2.sgd")
  copyFile(fx.threeComponentSegd(), result / "Shot1.sgd")
  writeFile(result / "notes.txt", "Line 7, shot 1 to 10.\n".repeat(300))
  copyFile(fx.surveySegy(), result / ".hidden.sgy")
  copyFile(fx.surveySegy(), result / "processed" / "stack.sgy")

block naturalOrder:
  doAssert naturalCmp("shot2", "shot10") < 0
  doAssert naturalCmp("Shot1", "shot2") < 0
  doAssert naturalCmp("a", "B") < 0
  doAssert naturalCmp("00000151_12900", "00000152_1") < 0
  doAssert naturalCmp("x007.sgd", "x7.sgd") != 0, "two names are never equal"
  doAssert naturalCmp("line9.sgy", "line10.sgy") < 0
  let e = FileEntry(name: "Shot_0151.SGD")
  doAssert e.matches("") and e.matches("shot") and e.matches("151 sgd")
  doAssert not e.matches("152")

block listAFolder:
  withFixtures fx:
    let dir = makeFolder(fx)
    var st = initAppState()
    st.apply Command(kind: ckBrowse, paths: @[dir])
    let job = st.fileList.job
    doAssert job != NoJob and st.jobs.info(job).get.spec.lane == jlBackground
    doAssert st.settle(not st.fileList.scanning)
    let f = st.fileList
    doAssert f.folder == dir and f.title == dir, f.error
    var names: seq[string]
    for e in f.entries: names.add e.name
    doAssert names == @["Shot1.sgd", "shot2.sgd", "shot10.sgy"], $names
    doAssert f.entries[0].kind == skSegd and f.entries[2].kind == skSegy
    doAssert f.entries[2].size == getFileSize(dir / "shot10.sgy")
    doAssert f.entries[2].path == dir / "shot10.sgy"
    doAssert f.others == 1, "the text file is counted, not listed: " & $f.others
    doAssert st.sessions.len == 0, "listing opened a file"
    doAssert st.shownPath == "" and st.panel(MainPanel).layers.len == 0
    doAssert st.settings.recentFolders[0] == dir
    doAssert sniff(dir / "notes.txt") == skUnknown and sniff(dir / "nothing") == skUnknown
    doAssert not st.log.has("is done"), "a listing is no news for the log"
    st.shutdown()

block stepThroughAFolder:
  # The acceptance test of the file list: three files, stepped through as
  # the arrow keys do; the display settings survive, and so does the view.
  withFixtures fx:
    let dir = makeFolder(fx)
    var before: seq[Snapshot]
    for name in ["Shot1.sgd", "shot2.sgd", "shot10.sgy"]: before.add snapshot(dir / name)
    var st = initAppState(indexCache = fx.dir / "cache")
    st.apply Command(kind: ckBrowse, paths: @[dir], showFirst: true)
    doAssert st.settle(st.shownPath == dir / "Shot1.sgd" and st.laidOut)
    doAssert st.fileList.chosen == dir / "Shot1.sgd"
    # The user's display: density, Fixed gain +6 dB, sorted by channel.
    var d = st.panel(MainPanel).layers[0].display
    d.mode = dmDensity
    d.gain = dgFixed
    d = d.withGainDb(6)
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    let order = @[SortKey(field: hfChannel, descending: true)]
    st.apply Command(kind: ckSort, panel: MainPanel, order: order)
    # Zoomed in: four traces, 100 to 300 ms, on a plot of 800 x 600 pixels.
    var v = st.panel(MainPanel).view
    (v.traces, v.timeMs, v.columns, v.rows) = (Span(lo: 1.5, hi: 5.5), Span(lo: 100, hi: 300),
      800, 600)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.panel(MainPanel).layers[0].display.fixedClip > 0)
    let shown = st.panel(MainPanel).layers[0].display
    for name in ["shot2.sgd", "shot10.sgy", "Shot1.sgd", "shot2.sgd"]:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: dir / name)
      doAssert st.fileList.chosen == dir / name
      doAssert st.settle(st.shownPath == dir / name and st.laidOut), name
      let layer = st.panel(MainPanel).layers[0]
      doAssert layer.display.mode == dmDensity and layer.display.gain == dgFixed and
        layer.display.gainDb == 6, name & ": " & $layer.display
      doAssert layer.display.fixedClip == shown.fixedClip, "Fixed keeps its amplitude"
      doAssert layer.order == order, name
      let now = st.panel(MainPanel).view
      doAssert now.traces == v.traces and now.timeMs == v.timeMs and now.columns == 800,
        name & ": the scales changed: " & $now
      doAssert st.settle(st.sessions.len == 1), $st.sessions.len & " files open at " & name
    doAssert st.settle(st.log.count("from the cache") >= 2), "stepping back walked a file again"
    doAssert not st.log.has("Closed "), "a file stepped away from is closed quietly"
    doAssert st.log.count(sevError) == 0 and st.log.count(sevWarning) == 0
    st.shutdown()
    var after: seq[Snapshot]
    for name in ["Shot1.sgd", "shot2.sgd", "shot10.sgy"]: after.add snapshot(dir / name)
    doAssert after == before, "stepping through the folder changed a file"

block aNewChoiceWins:
  # Stepping on before a file is open: the open it superseded is cancelled
  # (or, if it came all the same, dropped), and the last choice is shown.
  withFixtures fx:
    let a = fx.dir / "a.sgy"
    let b = fx.dir / "b.sgd"
    copyFile(fx.longSpreadSegy(), a) # 400 traces: still opening when the next choice comes
    copyFile(fx.twoSetSegd(), b)
    var st = initAppState()
    for i in 0 ..< 5:
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: b)
    doAssert st.fileList.chosen == b
    doAssert st.settle(st.shownPath == b and st.laidOut)
    doAssert st.settle(block:
      var busy = false
      for j in st.jobs.active:
        if j.spec.title.startsWith("Open") or j.spec.title.startsWith("Close"): busy = true
      not busy)
    discard st.drainInbox()
    doAssert st.sessions.len == 1 and st.shownPath == b
    var opens = 0
    for j in st.jobs.list:
      if j.spec.title == "Open a.sgy":
        inc opens
        doAssert j.state == jsCancelled, "a superseded open ran on: " & $j.state
    doAssert opens == 5, $opens
    doAssert not st.log.has("Opening a.sgy was cancelled"), "a superseded open is no news"
    st.shutdown()

block oneFileListsItsFolder:
  withFixtures fx:
    let dir = makeFolder(fx)
    var st = initAppState()
    # As the command line, or a file dropped on the window.
    st.apply Command(kind: ckBrowse, paths: @[dir / "shot2.sgd"], showFirst: true)
    doAssert st.settle(st.shownPath == dir / "shot2.sgd" and not st.fileList.scanning)
    doAssert st.fileList.folder == dir and st.fileList.entries.len == 3
    doAssert st.fileList.chosen == dir / "shot2.sgd"
    # As File > Open file: shown at once, its folder listed beside it.
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy(),
      listFolder: true)
    doAssert st.fileList.folder == fx.dir and st.fileList.scanning
    doAssert st.settle(st.shownPath == fx.surveySegy() and not st.fileList.scanning)
    doAssert st.fileList.find(fx.surveySegy()) >= 0
    # Its own folder again: listed once, not again.
    let gen = st.fileList.gen
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.twoSetSegd(),
      listFolder: true)
    doAssert st.fileList.gen == gen
    st.shutdown()

block chosenFilesAndMissingFolders:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckBrowse, paths: @[fx.twoSetSegd(), fx.surveySegy(),
      fx.dir / "no such.sgy"], showFirst: true)
    doAssert st.settle(not st.fileList.scanning and st.shownPath.len > 0)
    doAssert st.fileList.folder == "" and st.fileList.title == "3 chosen files"
    doAssert st.fileList.entries.len == 2 and st.fileList.unreadable == 1
    doAssert st.shownPath == st.fileList.entries[0].path
    let missing = fx.dir / "gone"
    st.apply Command(kind: ckBrowse, paths: @[missing])
    doAssert st.settle(not st.fileList.scanning and st.fileList.error.len > 0)
    doAssert st.fileList.entries.len == 0
    doAssert st.log.has("Cannot list " & missing, sevError), $st.log.count(sevError)
    st.apply Command(kind: ckBrowse, paths: @[])
    doAssert st.log.has("no file or folder was named", sevWarning)
    # A newer listing replaces one still running, quietly.
    let dir = makeFolder(fx)
    st.apply Command(kind: ckBrowse, paths: @[dir])
    st.apply Command(kind: ckBrowse, paths: @[fx.dir])
    doAssert st.settle(not st.fileList.scanning)
    doAssert st.fileList.folder == fx.dir
    doAssert not st.log.has("cancelled"), "a replaced listing is no news"
    st.shutdown()

when not defined(windows):
  block namedPipesAreNotOpened:
    # A named pipe in the folder: opening it would wait for a writer, maybe
    # forever, holding the scan, the background lane behind it, and the quit.
    withFixtures fx:
      let dir = fx.dir / "with a pipe"
      createDir(dir)
      copyFile(fx.surveySegy(), dir / "a.sgy")
      let pipe = dir / "b.sgy"
      doAssert posix.mkfifo(cstring(pipe), 0o600) == 0
      var st = initAppState()
      st.apply Command(kind: ckBrowse, paths: @[dir])
      let listed = st.settle(not st.fileList.scanning)
      # Free a scan stuck in the pipe's open, so a failure fails and does not hang.
      let fd = posix.open(cstring(pipe), posix.O_WRONLY or posix.O_NONBLOCK)
      if fd >= 0: discard posix.close(fd)
      doAssert listed, "the scan is stuck on the named pipe"
      doAssert st.fileList.entries.len == 1 and st.fileList.entries[0].name == "a.sgy"
      doAssert st.fileList.others == 1, "the pipe is counted, not listed"
      doAssert sniff(pipe) == skUnknown
      st.shutdown()

block exportsNeverGoOverSeismicFiles:
  # The messages, the settings and the layout are written to files the user
  # names: never over a seismic file viewSEG has open, or lists.
  withFixtures fx:
    let dir = makeFolder(fx)
    let shown = dir / "shot2.sgd"
    let listed = dir / "shot10.sgy"
    let before = @[snapshot(shown), snapshot(listed)]
    var st = initAppState()
    st.apply Command(kind: ckBrowse, paths: @[shown], showFirst: true)
    doAssert st.settle(st.shownPath == shown and not st.fileList.scanning)
    st.apply Command(kind: ckLayout, arrangement: "[Window][x]\n")
    let roundabout = dir & DirSep & ".." & DirSep & dir.extractFilename & DirSep & "shot10.sgy"
    for cmd in [Command(kind: ckExportLog, docPath: shown),
        Command(kind: ckExportSettings, docPath: listed),
        Command(kind: ckExportLayout, docPath: shown),
        Command(kind: ckExportLog, docPath: roundabout)]:
      let refused = st.log.count("never writes over one")
      st.apply cmd
      doAssert st.log.count("never writes over one") == refused + 1, $cmd.kind & " " & cmd.docPath
    st.apply Command(kind: ckExportLog, docPath: dir / "messages.log")
    st.flushFiles()
    doAssert st.settle(st.log.has("Messages exported to " & dir / "messages.log"))
    doAssert st.log.count("never writes over one") == 4
    st.shutdown()
    doAssert @[snapshot(shown), snapshot(listed)] == before, "an export wrote over a seismic file"

block closeForgetsTheChoice:
  withFixtures fx:
    var st = initAppState()
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
    doAssert st.settle(st.sessions.len == 1)
    doAssert st.fileList.chosen == fx.surveySegy()
    st.apply Command(kind: ckClose, file: st.sessions[0].id)
    doAssert st.fileList.chosen == ""
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.dir / "missing.sgy")
    doAssert st.settle(st.log.has("Cannot open", sevError))
    doAssert (fx.dir / "missing.sgy") in st.fileList.failed
    doAssert st.fileList.chosen == "", "a failed open leaves the choice on what is shown"
    st.shutdown()
