## The folder's watch, through `AppState`: a fixture added to a listed
## folder is listed and marked new while the plot stays on the file the user
## chose, and with "Follow the latest" it is shown once it is whole; a file
## being written is listed and marked as being written, and is not shown
## early, neither while it grows nor while it stays cut short; a listed file
## that grows is marked until it stops; a file removed goes from the list;
## an open file another program cuts short is let go of before anything
## reads past its new end, and shown again once it stops changing (and the
## reader itself reads nothing of a file shorter than it was opened, before
## the watch looks); a file rewritten under the same name is shown again as
## it is now, with its edits set aside (Ctrl+Z brings them back); a named
## pipe in the folder and a folder that cannot be read hold nothing, and a
## file that cannot be read is listed once it can; with several new files
## waiting, Follow shows the newest and stays on it; a look at a folder of
## 5 000 files costs a few milliseconds, on the watch's own thread, and 4 000
## files gone or new at once cost a few frames, not one each; the files
## listed are never changed.
##
## Seen to fail: with the new file's entry not marked new (`isNew` false in
## `takeWatched`), `newFilesAreListed` found it unmarked; with the follow
## open not dropped when the file is cut short (`adopt` not looking at
## `cutShort`), `halfWrittenIsNotShownEarly` found the half file shown; with
## the watch not sniffing a file again when it changes (a file too short to
## tell at first), `newFilesAreListed` never showed the file written in two
## parts; with `onDisk` not letting go of a file that was cut short,
## `openFileCutShort` found the file as it was opened still shown; with the
## reader not looking at the file's size (`cutShort` in `serve`),
## `readerReadsNothingPastTheEnd` ended in "Bus error" (SIGBUS, the crash of
## the original finding).
##
## Runs alone: it bounds the time the quit takes (3 s), a look at 5 000 files
##   (250 ms), the frame that takes in a new file (10 ms) and those that take
##   in 4 000 (100 ms).

import std/[algorithm, monotimes, os, strutils, times]
import viewSEG/core/state
import viewSEG/view/filetable
import utils/[fixtures, waiting]
when not defined(windows):
  from std/posix import nil

const Look = initDuration(milliseconds = 40) ## the watch's pause in these tests

template settle(st: var AppState; cond: untyped): bool =
  waitUntil((discard st.drainInbox(); cond))

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true
  false

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc laidOut(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layout.traces > 0

proc entry(st: AppState; path: string): FileEntry =
  let i = st.fileList.find(path)
  if i >= 0: st.fileList.entries[i] else: FileEntry(path: "")

proc listed(st: AppState; path: string): bool = st.fileList.find(path) >= 0

proc steady(st: AppState; path: string): bool =
  st.listed(path) and st.entry(path).status == fsSteady

proc follow(st: var AppState; on: bool) =
  var s = st.settings
  s.files.followLatest = on
  st.apply Command(kind: ckSettings, settings: s)

proc listing(fx: Fixtures; name: string): string =
  ## A folder with two files, listed, the first shown.
  result = fx.dir / name
  createDir(result)
  copyFile(fx.surveySegy(), result / "shot1.sgy")
  copyFile(fx.twoSetSegd(), result / "shot2.sgd")

proc start(dir: string; fx: Fixtures): AppState =
  result = initAppState(indexCache = fx.dir / "cache", watchEvery = Look)
  result.apply Command(kind: ckBrowse, paths: @[dir], showFirst: true)
  doAssert result.settle(result.shownPath == dir / "shot1.sgy" and result.laidOut and
    not result.fileList.scanning)

block newFilesAreListed:
  # The acceptance test: a fixture added to a watched folder is listed and
  # marked new, the plot staying on the file shown; with "Follow the
  # latest", it is shown, and so is the next one, once each is whole.
  withFixtures fx:
    let dir = fx.listing("line 1")
    var st = start(dir, fx)
    copyFile(fx.threeComponentSegd(), dir / "shot3.sgd")
    doAssert st.settle(st.steady(dir / "shot3.sgd"))
    let e = st.entry(dir / "shot3.sgd")
    doAssert e.isNew and e.kind == fkSegd and e.size == getFileSize(dir / "shot3.sgd"), $e
    doAssert not st.entry(dir / "shot1.sgy").isNew and not st.entry(dir / "shot2.sgd").isNew
    doAssert st.shownPath == dir / "shot1.sgy" and st.fileList.chosen == dir / "shot1.sgy",
      "the plot left the file chosen"
    # Follow: the new file is shown now, and its mark goes.
    st.follow(true)
    doAssert st.settle(st.shownPath == dir / "shot3.sgd" and st.laidOut)
    doAssert st.settle(not st.entry(dir / "shot3.sgd").isNew)
    # A file too short to tell at first (written in two parts) is listed once it is one.
    let whole = readFile(fx.longSpreadSegy())
    writeFile(dir / "shot4.sgy", whole[0 ..< 100])
    let quiet = getMonoTime() + Look * 5
    while getMonoTime() < quiet:
      discard st.drainInbox()
      sleep 5
    doAssert not st.listed(dir / "shot4.sgy"), "100 bytes cannot tell a standard"
    writeFile(dir / "shot4.sgy", whole)
    doAssert st.settle(st.shownPath == dir / "shot4.sgy" and st.laidOut)
    doAssert st.fileList.entries.len == 4
    doAssert st.log.count(sevError) == 0 and st.log.count(sevWarning) == 0
    st.shutdown()

block followStaysOnTheNewest:
  # Three new files wait, steady, when "Follow the latest" is turned on: the
  # newest is shown, and stays shown as the looks go on; the older ones are
  # not shown one after another, back in time. A newer file after it is.
  # Seen to fail: with every new file not followed yet a candidate (as it
  # was), "followed back to shotA.sgd" (then shotC).
  withFixtures fx:
    let dir = fx.listing("line 9")
    var st = start(dir, fx)
    let now = getTime()
    for (name, ago) in [("shotA.sgd", 20), ("shotB.sgd", 5), ("shotC.sgd", 40)]:
      copyFile(fx.twoSetSegd(), dir / name)
      setLastModificationTime(dir / name, now - initDuration(seconds = ago))
    doAssert st.settle(st.steady(dir / "shotA.sgd") and st.steady(dir / "shotB.sgd") and
      st.steady(dir / "shotC.sgd"))
    doAssert st.shownPath == dir / "shot1.sgy"
    st.follow(true)
    doAssert st.settle(st.shownPath == dir / "shotB.sgd" and st.laidOut)
    let quiet = getMonoTime() + Look * 12
    while getMonoTime() < quiet:
      discard st.drainInbox()
      doAssert st.fileList.chosen == dir / "shotB.sgd", "followed back to " &
        st.fileList.chosen.extractFilename
      sleep 5
    copyFile(fx.threeComponentSegd(), dir / "shotD.sgd")
    doAssert st.settle(st.shownPath == dir / "shotD.sgd" and st.laidOut)
    st.shutdown()

block halfWrittenIsNotShownEarly:
  # Follow on. A file growing in parts is listed and marked as being written,
  # and not shown; a file that stops half written is opened (it looks
  # whole) but not shown, and marked incomplete; once the rest is written,
  # it is shown.
  withFixtures fx:
    let dir = fx.listing("line 2")
    var st = start(dir, fx)
    st.follow(true)
    let whole = readFile(fx.longSpreadSegy())
    let path = dir / "shot5.sgy"
    var f = open(path, fmWrite)
    var written = 0
    var sawWriting = false
    while written < whole.len div 2: # faster than the watch can call it steady
      let n = min(8192, whole.len div 2 - written)
      f.write whole[written ..< written + n]
      f.flushFile()
      written += n
      discard st.drainInbox()
      if st.entry(path).status == fsWriting: sawWriting = true
      doAssert st.shownPath != path, "shown while it was being written"
      sleep 5
    f.close()
    doAssert sawWriting or st.settle(st.entry(path).status == fsWriting) or
      st.listed(path), "never listed while it was written"
    # Half of it, steady: opened, found cut short, not shown.
    doAssert st.settle(st.entry(path).status == fsShort)
    doAssert st.shownPath == dir / "shot1.sgy" and st.fileList.chosen == dir / "shot1.sgy"
    doAssert st.log.has("is not shown yet")
    doAssert st.entry(path).isNew
    # The rest: shown.
    writeFile(path, whole)
    doAssert st.settle(st.shownPath == path and st.laidOut)
    doAssert st.sessions[st.shownFile(0)].len == LongSpread
    st.shutdown()

block growingFileIsMarked:
  # A listed file that grows (an acquisition writing it) is marked as being
  # written, with its new size, until it stops; then it is steady again.
  # Removed, it goes from the list.
  withFixtures fx:
    let dir = fx.listing("line 3")
    var st = start(dir, fx)
    let path = dir / "shot2.sgd"
    let size = getFileSize(path)
    var f = open(path, fmAppend)
    f.write "x".repeat(1000)
    f.close()
    doAssert st.settle(st.entry(path).status == fsWriting)
    doAssert st.entry(path).size == size + 1000 and not st.entry(path).isNew
    doAssert st.settle(st.steady(path))
    removeFile(path)
    doAssert st.settle(not st.listed(path))
    doAssert st.fileList.entries.len == 1
    st.shutdown()

block openFileCutShort:
  # The file shown is cut short by another program (as `cp` over it does
  # first): the plot lets go of it before the next view reads past its new
  # end, and shows it again, opened anew, once it stops changing, at the
  # same gather and display.
  withFixtures fx:
    let dir = fx.listing("line 4")
    var st = start(dir, fx)
    let path = dir / "shot1.sgy"
    st.apply Command(kind: ckGather, panel: MainPanel, gather: 1)
    doAssert st.settle(st.panel(MainPanel).layers[0].source.gather == 1 and st.laidOut)
    var d = st.panel(MainPanel).layers[0].display
    d.gainDb = 4
    st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
    let whole = readFile(path)
    writeFile(path, whole[0 ..< whole.len div 2]) # same inode, cut
    for i in 0 ..< 10: # views that read: nothing reads past the end
      var v = st.panel(MainPanel).view
      v.timeMs = Span(lo: float64(i * 20), hi: float64(i * 20 + 200))
      st.apply Command(kind: ckView, panel: MainPanel, view: v)
      discard st.drainInbox()
      sleep 5
    doAssert st.settle(st.log.has("was cut short", sevWarning))
    # Shown again as it is now (half the traces), at the same gather, gain kept.
    doAssert st.settle(st.shownPath == path and st.laidOut)
    let i = st.shownFile(0)
    doAssert st.sessions[i].size == getFileSize(path)
    doAssert st.panel(MainPanel).layers[0].source.gather == 1 # of the two left
    doAssert st.panel(MainPanel).layers[0].display.gainDb == 4
    st.shutdown()

block readerReadsNothingPastTheEnd:
  # Before the watch looks (here it never does), the reader itself does not
  # read a file shorter than it was opened.
  withFixtures fx:
    let path = fx.dir / "alone.sgy"
    copyFile(fx.surveySegy(), path)
    var st = initAppState(watchEvery = initDuration(hours = 1))
    st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
    doAssert st.settle(st.shownPath == path and st.laidOut)
    # three traces in view, so the next view (past their read-ahead of a view and
    # a half on each side) must be read
    var v = st.panel(MainPanel).view
    (v.traces, v.columns, v.rows) = (Span(lo: -0.5, hi: 2.5), 800, 600)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.tiles(0).len > 0)
    writeFile(path, readFile(path)[0 ..< 6080])
    v.traces = Span(lo: 20, hi: 23)
    st.apply Command(kind: ckView, panel: MainPanel, view: v)
    doAssert st.settle(st.log.has("is shorter than when it was opened", sevWarning))
    st.shutdown()

block changedFileIsShownAgain:
  # The file shown is written again under its name (another shot): it is
  # shown again as it is now; the traces killed in the old one are set
  # aside, and Ctrl+Z brings them back.
  withFixtures fx:
    let dir = fx.listing("line 5")
    var st = start(dir, fx)
    let path = dir / "shot1.sgy"
    let s0 = st.sessions[st.shownFile(0)]
    st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[s0.base + 3],
      on: true)
    doAssert not st.editsOf(0).isEmpty
    sleep 20 # a later modification time, whatever the file system's resolution
    copyFile(fx.longSpreadSegy(), path)
    doAssert st.settle(st.shownPath == path and st.laidOut and
      st.sessions[st.shownFile(0)].len == LongSpread)
    doAssert st.log.has("changed on disk")
    doAssert st.log.has("set aside", sevWarning)
    doAssert st.editsOf(0).isEmpty
    st.apply Command(kind: ckUndoEdit, panel: MainPanel)
    doAssert st.editsOf(0).has(teKilled, 3)
    st.shutdown()

when not defined(windows):
  block slowPaths:
    # A named pipe in the folder is never opened, so the watch goes on; a
    # folder that cannot be read is said once, keeps its list, and is read
    # again when it can be.
    withFixtures fx:
      let dir = fx.listing("line 6")
      var st = start(dir, fx)
      doAssert posix.mkfifo(cstring(dir / "pipe.sgy"), 0o600) == 0
      copyFile(fx.threeComponentSegd(), dir / "shot3.sgd")
      doAssert st.settle(st.steady(dir / "shot3.sgd"))
      doAssert not st.listed(dir / "pipe.sgy")
      if posix.geteuid() != 0: # root reads any folder
        setFilePermissions(dir, {})
        defer: setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
        doAssert st.settle(st.log.has("Cannot look at the folder now", sevWarning))
        sleep 200
        discard st.drainInbox()
        doAssert st.fileList.entries.len == 3, "a folder that cannot be read lost its list: " &
          $st.fileList.entries.len
        var said = 0
        for e in st.log:
          if "Cannot look at the folder now" in e.text: inc said
        doAssert said == 1, $said & " warnings"
        setFilePermissions(dir, {fpUserRead, fpUserWrite, fpUserExec})
        doAssert st.settle(st.log.has("can be looked at again"))
        copyFile(fx.surveySegy(), dir / "shot4.sgy")
        doAssert st.settle(st.listed(dir / "shot4.sgy"))
        # A file that cannot be read, then can (its permissions changed, not its
        # size or time), is listed once it can. Seen to fail with the watch
        # sniffing a file only when its size or time changes (as it did):
        # "made readable, not listed".
        copyFile(fx.twoSetSegd(), dir / "locked.sgd")
        setFilePermissions(dir / "locked.sgd", {})
        doAssert st.settle(st.listed(dir / "shot4.sgy") and
          st.watchLook > initDuration()) # looked at since
        let quiet = getMonoTime() + Look * 6
        while getMonoTime() < quiet:
          discard st.drainInbox()
          sleep 5
        doAssert not st.listed(dir / "locked.sgd"), "a file that cannot be read was listed"
        setFilePermissions(dir / "locked.sgd", {fpUserRead, fpUserWrite})
        doAssert st.settle(st.listed(dir / "locked.sgd")), "made readable, not listed"
      let t0 = getMonoTime()
      st.shutdown()
      doAssert getMonoTime() - t0 < initDuration(seconds = 3), "the quit waited"

block fiveThousandFiles:
  # A field folder of 5 000 files: a look stats them all on the watch's
  # thread in a few milliseconds, and the frame that takes in a new file
  # costs well under a millisecond's worth of the frame budget.
  withFixtures fx:
    let dir = fx.dir / "big"
    createDir(dir)
    let segd = readFile(fx.twoSetSegd())
    for i in 0 ..< 5_000:
      if i mod 100 == 0: writeFile(dir / ("shot" & $i & ".sgd"), segd)
      else: writeFile(dir / ("note" & $i & ".txt"), "line " & $i & "\n")
    var st = initAppState(watchEvery = Look)
    st.apply Command(kind: ckBrowse, paths: @[dir])
    doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 50)
    doAssert st.settle(st.watchLook > Duration()) # the first look done
    sleep 300
    discard st.drainInbox()
    let look = st.watchLook
    echo "  a look at 5 000 files: ", look.inMicroseconds, " us"
    doAssert look < initDuration(milliseconds = 250), $look
    writeFile(dir / "shot5000.sgd", segd)
    var longest = Duration()
    doAssert waitUntil((
      let t0 = getMonoTime()
      discard st.drainInbox()
      longest = max(longest, getMonoTime() - t0)
      st.listed(dir / "shot5000.sgd")))
    doAssert longest < initDuration(milliseconds = 10), $longest
    st.shutdown()

block manyAtOnce:
  # A folder of 20 000 seismic files (links to one), its table kept as the
  # Files window keeps it, sorted by size: 4 000 removed at once, then 4 000
  # new ones, are taken in by frames of tens of milliseconds at most (the
  # table's rows made again once), not one file's change at a time. Seen to
  # fail with each file gone or new taken out or put in one by one (as it
  # was): "4 000 gone: the longest frame took 576 ms" (debug; 35 ms now).
  withFixtures fx:
    let dir = fx.dir / "many"
    createDir(dir)
    let one = fx.twoSetSegd()
    for i in 0 ..< 20_000: createHardlink(one, dir / ("shot" & align($i, 5, '0') & ".sgd"))
    var st = initAppState(watchEvery = Look)
    st.apply Command(kind: ckBrowse, paths: @[dir])
    doAssert waitUntil((discard st.drainInbox(); not st.fileList.scanning and
      st.fileList.entries.len == 20_000), initDuration(seconds = 60))
    doAssert st.settle(st.watchLook > Duration()) # the first look done
    var table: FileTable
    table.update(st.fileList, "", FileOrder(column: fcSize, descending: true))
    proc frames(st: var AppState; table: var FileTable; done: proc (st: AppState): bool): Duration =
      ## The longest frame (the inbox and the table) until `done`.
      doAssert waitUntil((
        let t0 = getMonoTime()
        discard st.drainInbox()
        table.update(st.fileList, "", FileOrder(column: fcSize, descending: true))
        result = max(result, getMonoTime() - t0)
        done(st)), initDuration(seconds = 60))
    for i in 0 ..< 4_000: removeFile(dir / ("shot" & align($(i * 5), 5, '0') & ".sgd"))
    let removed = st.frames(table, proc (st: AppState): bool = st.fileList.entries.len == 16_000)
    doAssert removed < initDuration(milliseconds = 100), "4 000 gone: the longest frame took " &
      $removed.inMilliseconds & " ms"
    doAssert table.rows.len == 16_000 and st.fileList.find(dir / "shot00005.sgd") < 0 and
      st.fileList.find(dir / "shot00001.sgd") >= 0
    for i in 0 ..< 4_000: createHardlink(one, dir / ("new" & align($i, 5, '0') & ".sgd"))
    let added = st.frames(table, proc (st: AppState): bool = st.fileList.entries.len == 20_000)
    doAssert added < initDuration(milliseconds = 100), "4 000 new: the longest frame took " &
      $added.inMilliseconds & " ms"
    var names: seq[string]
    for e in st.fileList.entries: names.add e.name
    doAssert names == names.sorted(proc (a, b: string): int = naturalCmp(a, b)), "out of order"
    doAssert st.fileList.entries[0].name == "new00000.sgd" and st.fileList.entries[0].isNew
    doAssert table.rows.len == 20_000
    echo "  20 000 files: 4 000 gone in frames of at most ", removed.inMilliseconds,
      " ms, 4 000 new in ", added.inMilliseconds, " ms"
    st.shutdown()
