## A folder of vibrator signature files, in `core`: the list reads each file's header (never a
## sample), pairs a `.dat` with the `.vib` of its sweep, sorts, filters, steps and follows them,
## and "Reopen with options" decodes them again.
##
## The folder is the controller's own layout, `<serial>/<date>/`: three controllers, four
## vibrators, 30 pairs, 5 lone `.dat` and 5 lone `.vib` files, a stopped `.dat`, a stopped
## `.vib`, a pulse record, a foreign `.dat`, a `.vib` of kind 6, an empty file and a SEG-Y.
##
## - **The listing** holds every file with its `SweepInfo` (header only), counts the foreign
##   `.dat`, the kind-6 `.vib` and the empty file under "other files", and opens no session.
## - **Pairs** (`pairSweeps`, on its own): one candidate; two broken by the folder serial; two not
##   broken (no pair, told); a year folder mistaken for a serial still pairs on time alone; two
##   `.vib` files claiming one `.dat` pair with neither.
## - **The table:** by Trigger each `.vib` lies just before its `.dat`; the Controller and
##   Vibrator filters give the right rows; with "Signature files" off no signature row is there,
##   stepping skips them, and no scan runs again.
## - **Searching** (`findPairWork`): a file opened alone finds its partner across
##   `<serial>/<date>/`; with none it says so in the words of the brief; at 5000 files it stops;
##   through a 10 ms drive no call is made on the UI thread.
## - **Offers:** `ckOpenPair` lands on the partner and back in the same panel; with the partner
##   prepared the switch reads no disk; a `.vib` opened with its `.dat` known carries the
##   `.dat`'s trigger to the nanosecond, its samples unchanged.
## - **Following:** "newest" is the trigger, not the modification time; a stopped `.dat` is shown
##   once the controller has moved on, or after `StoppedShowAfter`; never before.
## - **Reopen:** the interval, the swap (traces 2 and 3 change places; the codes stay 21, 18, 19, 20), t = 0 at the first frame, "every
##   file of this listing", and the refusals in the words of the brief; edits by trace number
##   stay.
##
## Seen to fail, each with the behaviour off: `pairSweeps` choosing the first of several
## candidates (`pairRules` found a pair where there must be none); the pair's `.dat` not given to
## the open job (`pairedOpen` found no pair on the session); the Trigger sort key off
## (`pairsOfTheListing` found a `.dat` not just after its `.vib`); `followNewest` by modification
## time (`newestByTrigger` showed the older sweep); the stopped rule off (`stoppedDat` showed the
## stopped `.dat` at once); `openChoiceOf` ignoring the listing's choice (`reopenEvery` found the
## interval 1000); `findPairWork` looking only in the file's own folder (`searching` found no
## `.vib` in the other date folder); the signature tick ignored in `FileTable.update` (`tickOff`
## found 74 rows); the switch reading the prepared file (`preparedSwitch` found an open of it:
## one read of the prepared file in `showPath`); a failed header read left as it was
## (`failedReadRetried` kept "it cannot be read" and no pair).
## Not mutated: the 5000-file stop and the 10 ms drive (they bound a loop and a thread, and
## fail only on a hang or a UI-thread call); "moved on" in `movedOn` (it asserts only that a
## stopped sweep and its successor are followed); the swap, first-frame and refusal lines of
## `reopen` (the refusal is mutated in `tdatopen`).

import std/[json, monotimes, os, sequtils, strutils, tables, times]
import parseSEG
import parseSSDAT
import parseSSVIB
import viewSEG/core/[filelist, filekinds, properties, signatures, state, sweeppairs]
import viewSEG/remote/tools
import viewSEG/view/filetable
import utils/[faultyfs, fixtures, sigfiles, waiting]

const
  Date = "20010203"
  Controllers = [4321, 4322, 4323]
  Look = initDuration(milliseconds = 40) ## the watch's pause in these tests

proc body(answer: string): JsonNode =
  parseJson(parseJson(answer)["content"][0]["text"].getStr)

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc laidOut(st: AppState): bool =
  let p = st.panel(MainPanel)
  p.laidOut and p.layout.traces > 0

proc session(st: AppState; path: string): Session =
  for s in st.sessions:
    if s.path == path: return s

func clock(t: int): tuple[minute, second: int] =
  ## Sweep `t` seconds after 04:05:00.
  (5 + t div 60, t mod 60)

proc datAt(dir, name: string; serial: int; t: int; vibrator = 12; more = SynthDat(samples: 600)):
    string =
  ## A `.dat` whose trigger is half a second into second `t`.
  var s = more
  let (m, sec) = clock(t)
  s.serial = serial
  s.vibrator = vibrator
  s.trigger = DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: m, second: sec,
    nanosecond: 500_000_000)
  datFile(dir, name, s)

proc vibAt(dir, name: string; t: int; more = SynthVib()): string =
  ## A `.vib` that began in second `t`.
  var s = more
  let (m, sec) = clock(t)
  s.start = VibTime(year: 2001, month: 2, day: 3, hour: 4, minute: m, second: sec)
  vibFile(dir, name, s)

func trigNs(t: int): int64 =
  let (m, sec) = clock(t)
  unixNs(2001, 2, 3, 4, m, sec, 500_000_000)

type Folder = object
  root: string
  pairs: seq[tuple[dat, vib: string]]
  loneDats, loneVibs: seq[string]
  stoppedDat, stoppedVib, pulse, foreign, kind6, empty, segy: string

proc build(fx: Fixtures; name: string): Folder =
  ## The 74 listed files of the brief's folder, and the three that are not.
  result.root = fx.dir / name
  for ci, serial in Controllers:
    let dir = result.root / $serial / Date
    for k in 0 ..< 10:
      let t = k * 10 + ci * 3
      let n = k + 1 + 100 * ci
      result.pairs.add (datAt(dir, $serial & "_" & $k & ".dat", serial, t, 11 + k mod 4,
        SynthDat(samples: 600, fileNumber: n)), vibAt(dir, intToStr(n, 4) & ".VIB", t))
  let first = result.root / "4321" / Date
  for k in 0 ..< 5:
    result.loneDats.add datAt(first, "lone" & $k & ".dat", 4321, 300 + 10 * k)
    result.loneVibs.add vibAt(first, intToStr(900 + k, 4) & ".VIB", 400 + 10 * k)
  result.stoppedDat = datAt(first, "stopped.dat", 4321, 500, more = SynthDat(samples: 12000,
    truncateAfter: 5, noQc: true))
  result.stoppedVib = vibAt(first, "0950.VIB", 520, SynthVib(stopAt: 800))
  result.pulse = datAt(first, "pulse.dat", 4321, 540, more = SynthDat(samples: 600,
    sweepNumber: 16))
  result.foreign = result.root / "foreign.dat"
  writeFile(result.foreign, "this is not a signature file\n".repeat(100))
  result.kind6 = result.root / "other.vib"
  writeBytes(result.kind6, synthOtherKind(50))
  result.empty = result.root / "empty.dat"
  writeFile(result.empty, "")
  result.segy = result.root / "shots.sgy"
  copyFile(fx.surveySegy(), result.segy)

proc listed(root: string; fx: Fixtures; recursive = true): AppState =
  result = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
  result.apply Command(kind: ckBrowse, paths: @[root])
  doAssert result.settle(not result.fileList.scanning)
  if recursive:
    result.apply Command(kind: ckSubfolders, subfolders: true)
    doAssert result.settle(not result.fileList.scanning and result.fileList.entries.len > 20)

proc entry(st: AppState; path: string): FileEntry =
  let i = st.fileList.find(path)
  doAssert i >= 0, path & " is not listed"
  st.fileList.entries[i]

proc steady(st: AppState; path: string): bool =
  let i = st.fileList.find(path)
  i >= 0 and st.fileList.entries[i].status == fsSteady

proc rowsOf(st: AppState; filter = SweepFilter(); order = FileOrder(column: fcTrigger)):
    seq[string] =
  var t = FileTable()
  t.update(st.fileList, "", order, filter)
  for r in t.rows: result.add st.fileList.entries[r].path

proc key(path: string; kind: SignatureKind; ns: int64; serial = -1'i64): PairKey =
  result = PairKey(path: path, kind: kind, ns: ns, serial: serial)
  if kind == sgVib: (result.lo, result.hi) = windowOf(ns)

proc main*() =
  install()

  block listing:
    withFixtures fx:
      let f = build(fx, "day")
      var st = listed(f.root, fx)
      template list: untyped = st.fileList
      doAssert list.entries.len == 74, $list.entries.len
      doAssert list.others == 3 and list.unreadable == 0,
        "the foreign .dat, the kind-6 .vib and the empty file are other files: " & $list.others
      # the only job a listing starts is the kinds job, and it reads the seismic file (shots.sgy);
      # a signature file is no seismic file (`startKinds`), so none is opened for its kind
      doAssert st.sessions.len == 0, "listing opened a session"
      doAssert st.jobs.active.allIt(it.spec.title == "Read what the files are"),
        "listing started a job besides the kinds job: " & $st.jobs.active.mapIt(it.spec.title)
      doAssert st.settle(st.jobs.active.len == 0), "the kinds job did not end"
      doAssert st.entry(f.segy).kindState != ksUnread, "the seismic file's kind was not read"
      let (dat, vib) = f.pairs[3]
      let d = st.entry(dat).sweep
      doAssert d.kind == sgDat and d.problem.len == 0 and d.complete, $d
      doAssert d.controller == 4321 and d.vibrator == 11 + 3 mod 4 and d.fileNumber == 4
      doAssert d.triggerNs == trigNs(30) and d.samples == 600 and d.intervalUs == 1000
      let v = st.entry(vib).sweep
      doAssert v.kind == sgVib and v.timeIsStart and v.triggerNs == trigNs(30) - 500_000_000
      doAssert v.controller == 4321 and v.serialFrom == sfFolder and v.fileNumber == 4
      let s = st.entry(f.stoppedDat).sweep
      doAssert not s.complete and s.samples < s.declared and s.blocks < s.blocksDeclared and
        not s.qc.valid and s.vibrator == 0, $s
      doAssert st.entry(f.pulse).sweep.sweepNumber == 16
      doAssert st.entry(f.stoppedVib).sweep.complete # (a list read cannot tell it stopped)
      doAssert st.entry(f.segy).kind == fkSegy and st.entry(f.segy).sweep.kind == sgNone
      # the agent's view of the same rows: `fileList.entries[].sweep`
      let seen = st.stateReport(Frontend(), """{"parts":["fileList"],"limit":200}""").body["fileList"]
      doAssert seen["signatureFiles"].getBool and seen["pairs"].getInt == 30
      for row in seen["entries"]:
        if row["path"].getStr == dat:
          let w = row["sweep"]
          doAssert w["kind"].getStr == "dat" and w["controller"].getInt == 4321 and
            w["vibrator"].getInt == d.vibrator and w["pair"].getStr == vib and
            w["trigger"].getStr == "2001-02-03 04:05:30.500000000" and w["complete"].getBool,
            $w
        elif row["path"].getStr == vib:
          let w = row["sweep"]
          doAssert w["controllerFrom"].getStr == "pair" and w["triggerIsStart"].getBool and
            w["vibrator"].getInt == d.vibrator, $w
        elif row["path"].getStr == f.segy:
          doAssert "sweep" notin row
      st.shutdown()

  block pairRules:
    # one candidate
    var r = pairSweeps([key("a.dat", sgDat, 5_500_000_000, 1), key("a.vib", sgVib, 5_000_000_000,
      1)])
    doAssert r.pairs["a.dat"] == "a.vib" and r.pairs["a.vib"] == "a.dat"
    # two candidates, broken by the folder serial
    r = pairSweeps([key("x1.dat", sgDat, 5_500_000_000, 1), key("x2.dat", sgDat, 5_800_000_000, 2),
      key("x.vib", sgVib, 5_000_000_000, 2)])
    doAssert r.pairs["x.vib"] == "x2.dat" and "x1.dat" notin r.pairs
    # two not broken: no pair, and the .vib is told both
    r = pairSweeps([key("y1.dat", sgDat, 5_500_000_000, 1), key("y2.dat", sgDat, 5_800_000_000, 1),
      key("y.vib", sgVib, 5_000_000_000, 2)])
    doAssert r.pairs.len == 0 and r.candidates["y.vib"].len == 2 and
      "2 .dat files fit" in r.notes["y.vib"], $r
    # a year folder taken for a serial (2023): one candidate pairs on time alone
    r = pairSweeps([key("z.dat", sgDat, 5_500_000_000, 4321), key("z.vib", sgVib, 5_000_000_000,
      2023)])
    doAssert r.pairs["z.vib"] == "z.dat"
    # a .vib with no serial at all and several candidates: none
    r = pairSweeps([key("w1.dat", sgDat, 5_500_000_000, 1), key("w2.dat", sgDat, 5_900_000_000, 2),
      key("w.vib", sgVib, 5_000_000_000)])
    doAssert r.pairs.len == 0
    # two .vib files claim one .dat: neither pairs, both are told
    r = pairSweeps([key("c.dat", sgDat, 5_800_000_000, 1), key("c1.vib", sgVib, 5_000_000_000, 1),
      key("c2.vib", sgVib, 4_700_000_000, 1)])
    doAssert r.pairs.len == 0 and "c1.vib" in r.notes and "c2.vib" in r.notes and
      "c.dat" in r.notes, $r
    # outside the window: nothing
    r = pairSweeps([key("o.dat", sgDat, 9_000_000_000, 1), key("o.vib", sgVib, 5_000_000_000, 1)])
    doAssert r.pairs.len == 0 and r.notes.len == 0
    # 10 000 entries, as the bench of the brief: pairing is not quadratic
    var many: seq[PairKey] = @[]
    for i in 0 ..< 5000:
      many.add key("d" & $i, sgDat, int64(i) * 5_000_000_000 + 500_000_000, 1)
      many.add key("v" & $i, sgVib, int64(i) * 5_000_000_000, 1)
    let began = getMonoTime()
    r = pairSweeps(many)
    doAssert r.pairs.len == 10_000 and getMonoTime() - began < initDuration(seconds = 5)

  block pairsOfTheListing:
    withFixtures fx:
      let f = build(fx, "day")
      var st = listed(f.root, fx)
      template list: untyped = st.fileList
      doAssert list.pairs.len == 60, $list.pairs.len
      for (dat, vib) in f.pairs:
        doAssert list.pairs[dat] == vib and list.pairs[vib] == dat, dat
      for p in f.loneDats & f.loneVibs & @[f.stoppedDat, f.stoppedVib, f.pulse]:
        doAssert p notin list.pairs, p & " paired"
      # By Trigger each .vib lies just before its .dat (it began 0.5 s before the trigger).
      let rows = st.rowsOf()
      for (dat, vib) in f.pairs:
        let at = rows.find(dat)
        doAssert at > 0 and rows[at - 1] == vib, dat & " is not just after " & vib
      # the Controller and the Vibrator drop-downs
      let c22 = st.rowsOf(SweepFilter(controller: 4322))
      doAssert c22.len == 20, $c22.len # (a paired .vib takes its .dat's controller)
      let v11 = st.rowsOf(SweepFilter(vibrator: 11))
      doAssert v11.len == 18, $v11.len
      doAssert st.rowsOf(SweepFilter(controller: 4322, vibrator: 11)).len == 6
      doAssert st.rowsOf(SweepFilter(controller: 4321)).len == 33
      # the name filter combines with them
      var t = FileTable()
      t.update(list, ".dat", FileOrder(column: fcTrigger), SweepFilter(controller: 4322))
      doAssert t.rows.len == 10, $t.rows.len
      st.shutdown()

  block wordsAndDay:
    doAssert fileCountWords(0, 11, 0, true) == "11 signature files"
    doAssert fileCountWords(3, 8, 0, true) == "3 seismic files, 8 signature files"
    doAssert fileCountWords(1, 1, 2, true) == "1 seismic file, 1 signature file, 2 survey files"
    doAssert fileCountWords(0, 11, 0, false) == "11 signature files hidden (tick off)"
    doAssert fileCountWords(4, 0, 0, true) == "4 seismic files" and
      fileCountWords(0, 0, 0, true) == "0 seismic files"
    doAssert fileCountWords(0, 11, 0, false).len <= 40, "must fit the default Files window"
    withFixtures fx:
      let f = build(fx, "day")
      var st = listed(f.root, fx)
      # every sweep is on 2001-02-03: the Trigger column shows the time only
      doAssert singleDay(st.fileList)
      let (dat, vib) = f.pairs[3]
      let d = st.fileList.entries[st.fileList.find(dat)]
      doAssert sweepCell(st.fileList, d, fcTrigger, true).text == "04:05:30.500"
      doAssert sweepCell(st.fileList, d, fcTrigger).text == "2001-02-03 04:05:30.500"
      doAssert sweepCell(st.fileList, d, fcTrigger, true).tip.startsWith("2001-02-03 04:05:30")
      doAssert sweepCell(st.fileList, st.fileList.entries[st.fileList.find(vib)], fcTrigger,
        true).text == "04:05:30.500" # (a paired .vib shows its .dat's trigger)
      # a sweep of another day: the date stays
      discard datFile(f.root / "4321" / Date, "next.dat", SynthDat(samples: 600,
        trigger: DatTime(year: 2001, month: 2, day: 4, hour: 1, minute: 2, second: 3)))
      st.apply Command(kind: ckBrowse, paths: @[f.root])
      doAssert st.settle(not st.fileList.scanning)
      st.apply Command(kind: ckSubfolders, subfolders: false)
      st.apply Command(kind: ckSubfolders, subfolders: true)
      doAssert st.settle(not st.fileList.scanning and st.fileList.entries.len == 75)
      doAssert not singleDay(st.fileList)
      st.shutdown()

  block tickOff:
    withFixtures fx:
      let f = build(fx, "day")
      var st = listed(f.root, fx)
      let gen = st.fileList.gen
      var s = st.settings
      s.files.listSignatureFiles = false
      st.apply Command(kind: ckSettings, settings: s)
      doAssert st.fileList.gen == gen and not st.fileList.scanning, "a new scan ran"
      var t = FileTable()
      t.update(st.fileList, "", FileOrder(), SweepFilter(hide: true))
      doAssert t.rows.len == 1 and st.fileList.entries[t.rows[0]].path == f.segy, $t.rows.len
      doAssert t.stepped(st.fileList, f.segy, 1) == f.segy and
        t.stepped(st.fileList, f.segy, -1) == f.segy
      doAssert st.fileList.pairs.len == 60, "the pairs went with the tick"
      var on = FileTable()
      on.update(st.fileList, "", FileOrder(), SweepFilter())
      doAssert on.rows.len == 74
      doAssert on.stepped(st.fileList, f.pairs[0].dat, 1) != f.pairs[0].dat
      st.shutdown()

  block searching:
    withFixtures fx:
      let f = build(fx, "day")
      # the .dat opened alone, its folder not listed: the search finds the .vib in the
      # controller's folder two levels up (here, the same folder), and a decoy of another sweep
      var st = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
      let (dat, vib) = f.pairs[4]
      st.apply Command(kind: ckOpen, paths: @[dat])
      doAssert st.settle(st.sessions.len == 1)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: dat)
      doAssert st.settle(st.shownPath == dat and st.laidOut)
      doAssert st.pairText(dat) == "not looked for yet", st.pairText(dat)
      st.apply Command(kind: ckOpenPair, panel: MainPanel)
      doAssert st.settle(st.shownPath == vib and st.laidOut),
        "the partner was not shown: " & st.shownPath
      doAssert st.partnerOf(dat) == vib and st.partnerOf(vib) == dat
      doAssert vib.extractFilename in st.pairText(dat), st.pairText(dat)
      doAssert "the .dat of this sweep" in st.pairText(vib), st.pairText(vib)
      st.apply Command(kind: ckOpenPair, panel: MainPanel) # and back
      doAssert st.settle(st.shownPath == dat and st.laidOut)
      st.shutdown()
      # across the controller's date folders (a recording over midnight): <serial>/<date>/ both
      block cross:
        let a = datAt(fx.dir / "cross" / "4321" / "20010203", "x.dat", 4321, 30)
        let b = vibAt(fx.dir / "cross" / "4321" / "20010204", "0042.VIB", 30)
        var far = initAppState(indexCache = fx.dir / "cache",
          watchEvery = initDuration(hours = 1))
        far.apply Command(kind: ckShowFile, panel: MainPanel, path: a)
        doAssert far.settle(far.shownPath == a and far.laidOut)
        far.apply Command(kind: ckOpenPair, panel: MainPanel)
        doAssert far.settle(far.shownPath == b and far.laidOut), "the .vib of another date " &
          "folder was not found: " & far.pairText(a)
        far.shutdown()
      # a lone .dat: no partner, said once, with the numbers
      var lone = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
      let alone = f.loneDats[0]
      lone.apply Command(kind: ckShowFile, panel: MainPanel, path: alone)
      doAssert lone.settle(lone.shownPath == alone and lone.laidOut)
      lone.apply Command(kind: ckOpenPair, panel: MainPanel)
      let folder = alone.parentDir
      doAssert lone.settle(lone.log.has("No .vib of this sweep was found in " & folder & " or " &
        folder.parentDir & " (looked at 16 .vib files: none began 0.2 to 1.5 s before the " &
        "trigger 2001-02-03 04:10:00.500).")), "the words of the brief were not said: " &
        toSeq(lone.log).mapIt(it.text).join(" | ")
      doAssert lone.shownPath == alone
      doAssert lone.pairText(alone).startsWith("not found ("), lone.pairText(alone)
      lone.shutdown()
      # at 5000 files it stops, in words
      let crowd = fx.dir / "crowd" / "4321" / "d1"
      createDir(crowd)
      for i in 0 .. MaxPairFiles + 1: writeFile(crowd / ("f" & $i & ".vib"), "x")
      let big = datAt(crowd, "z.dat", 4321, 3)
      var many = initAppState(indexCache = fx.dir / "cache",
        watchEvery = initDuration(hours = 1))
      many.apply Command(kind: ckShowFile, panel: MainPanel, path: big)
      doAssert many.settle(many.shownPath == big and many.laidOut)
      many.apply Command(kind: ckOpenPair, panel: MainPanel)
      doAssert many.settle(many.log.has("too many files to search: open the controller's " &
        "folder in Files with Include subfolders"))
      many.shutdown()
      # through a drive that takes 10 ms a call: the UI thread makes none, and is not held
      var slow = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
      let (dat2, vib2) = f.pairs[6]
      slow.apply Command(kind: ckShowFile, panel: MainPanel, path: dat2)
      doAssert slow.settle(slow.shownPath == dat2 and slow.laidOut)
      fault(f.root, fkDelay, {foStat, foList, foOpen, foRead}, initDuration(milliseconds = 10))
      let began = getMonoTime()
      slow.apply Command(kind: ckOpenPair, panel: MainPanel)
      doAssert getMonoTime() - began < initDuration(milliseconds = 500),
        "the UI thread waited for the search"
      doAssert slow.settle(slow.shownPath == vib2)
      releaseAll()
      doAssert uiCalls().len == 0, $uiCalls()
      slow.shutdown()

  block pairedOpen:
    withFixtures fx:
      let f = build(fx, "day")
      let (dat, vib) = f.pairs[2]
      let shot = parseDat(cast[seq[byte]](readFile(dat)))
      # alone: the clock is the start second
      var alone = initAppState(indexCache = fx.dir / "cache", watchEvery = initDuration(hours = 1))
      alone.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
      doAssert alone.settle(alone.shownPath == vib and alone.laidOut)
      let a = alone.session(vib)
      doAssert a.signature.pair.len == 0 and a.signature.info.serialFrom == sfFolder
      let startKey = a.filePtr[].traceKeys(0).time
      var aSamples: seq[float32] = @[]
      block:
        let x = a.filePtr[].readTraces(0 .. 3)
        for t in 0 ..< 4:
          aSamples.add x[t, 100]
      let aCodes = (0 ..< a.len).toSeq.mapIt(a.filePtr[].traceKeys(it).traceCode)
      alone.shutdown()
      # listed: its .dat is known, so the open is given its trigger
      var st = listed(f.root, fx)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
      doAssert st.settle(st.shownPath == vib and st.laidOut)
      let p = st.session(vib)
      doAssert p.signature.pair == dat and p.signature.info.serialFrom == sfPair and
        p.signature.info.vibrator == 11 + 2 mod 4 and p.signature.info.controller == 4321
      let key = p.filePtr[].traceKeys(0).time
      doAssert key == posixTime(shot.trigger), $key & " is not the .dat's trigger " &
        $posixTime(shot.trigger)
      doAssert key != startKey, "the clock did not change"
      doAssert p.len == a.len
      let x = p.filePtr[].readTraces(0 .. 3)
      for t in 0 ..< 4: doAssert x[t, 100] == aSamples[t], "a sample changed"
      doAssert (0 ..< p.len).toSeq.mapIt(p.filePtr[].traceKeys(it).traceCode) == aCodes
      let text = summaryText(summaryLines(p, 0, pairText = st.pairText(vib)))
      doAssert "from the .dat of this sweep" in text and
        "Pair\t" & dat.extractFilename in text, text
      # an edit by trace number is kept over a reopen
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled, edited: @[p.base + 2],
        on: true)
      st.apply Command(kind: ckReopen, reopenPath: vib,
        openChoice: OpenChoice(signature: SignatureChoice(intervalUs: 1000)))
      doAssert st.settle(st.log.has("is opened again") and st.jobs.active.len == 0)
      doAssert st.hasEditAt(vib, 2, teKilled), "the edit by trace number went"
      st.shutdown()

  block preparedSwitch:
    # The switch itself reads no disk. The folder watch reads an opened file's header on its
    # own thread; that look may land inside `settle` and is not the switch's, so it is left
    # out (the thread that listed the folder after the file was shown).
    withFixtures fx:
      let f = build(fx, "day")
      let (dat, vib) = f.pairs[5]
      var st = listed(f.root, fx)
      let lists = calls(foList, f.root)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
      doAssert st.settle(st.shownPath == vib and st.laidOut and calls(foList, f.root) > lists),
        "the watch did not list the folder after the file was shown"
      st.apply Command(kind: ckView, panel: MainPanel,
        view: fitAll(st.panel(MainPanel).layout, 800, 600)) # the plot's size, so a tile comes
      doAssert st.settle(st.tiles(st.findPanel(MainPanel)).len > 0)
      st.apply Command(kind: ckPrepare, panel: MainPanel, path: dat)
      doAssert st.settle(st.jobs.active.len == 0 and st.hasPrepared(dat)), "it was not prepared"
      let watch = caller(foList, f.root)
      doAssert watch >= 0, "the watch has not listed the folder"
      resetCounts()
      st.apply Command(kind: ckOpenPair, panel: MainPanel)
      doAssert st.settle(st.shownPath == dat and st.laidOut)
      doAssert callsExcept(foOpen, dat, watch) == 0 and callsExcept(foRead, dat, watch) == 0 and
        callsExcept(foMapped, dat, watch) == 0, "the switch read the drive"
      doAssert st.log.has("Opened " & dat.extractFilename)
      st.shutdown()

  block failedReadRetried:
    # A header read that failed is tried again once the file can be read, with no further
    # change of its size or time. The file is listed first, so its kind is known: failing the
    # open is a failed header read, not a sniff that the watch already retries.
    withFixtures fx:
      let dir = fx.dir / "retry" / "4321" / Date
      let dat = datAt(dir, "a.dat", 4321, 100)
      let vib = vibAt(dir, "0001.VIB", 100)
      var st = initAppState(indexCache = fx.dir / "cache", watchEvery = Look)
      st.apply Command(kind: ckBrowse, paths: @[dir])
      doAssert st.settle(not st.fileList.scanning and st.fileList.pairs.getOrDefault(dat) == vib),
        "the pair was not listed"
      let before = getFileSize(dat)
      fault(dat, fkFail, {foOpen})
      discard datAt(dir, "a.dat", 4321, 100, more = SynthDat(samples: 2400))
      doAssert getFileSize(dat) > before, "the file did not grow"
      doAssert st.settle(st.steady(dat) and st.entry(dat).sweep.problem == "it cannot be read" and
        dat notin st.fileList.pairs), "the failed read was not listed"
      let size = getFileSize(dat)
      let modified = getLastModificationTime(dat)
      release(dat)
      doAssert st.settle(st.entry(dat).sweep.problem.len == 0 and
        st.entry(dat).sweep.triggerNs == trigNs(100) and
        st.fileList.pairs.getOrDefault(dat) == vib), "a readable file was not read again"
      doAssert getFileSize(dat) == size and getLastModificationTime(dat) == modified,
        "the file changed while it was being read again"
      let opens = calls(foOpen, dat)
      let quiet = getMonoTime() + Look * 8
      while getMonoTime() < quiet:
        discard st.drainInbox()
        sleep 5
      doAssert calls(foOpen, dat) == opens, "the header was read again after it had succeeded"
      st.shutdown()

  block newestByTrigger:
    withFixtures fx:
      let dir = fx.dir / "live" / "4321" / Date
      discard datAt(dir, "a.dat", 4321, 100)
      var st = initAppState(indexCache = fx.dir / "cache", watchEvery = Look)
      st.apply Command(kind: ckBrowse, paths: @[dir], showFirst: true)
      doAssert st.settle(st.shownPath == dir / "a.dat" and st.laidOut and
        not st.fileList.scanning)
      var s = st.settings
      s.files.followLatest = true
      st.apply Command(kind: ckSettings, settings: s)
      discard datAt(dir, "b.dat", 4321, 200)
      doAssert st.settle(st.shownPath == dir / "b.dat" and st.laidOut), "the newest was not shown"
      # written later, but its trigger is older than the one shown: not followed back in time
      discard datAt(dir, "c.dat", 4321, 150)
      doAssert st.settle(st.steady(dir / "c.dat"))
      let quiet = getMonoTime() + Look * 8
      while getMonoTime() < quiet:
        discard st.drainInbox()
        sleep 5
      doAssert st.shownPath == dir / "b.dat", "an older sweep was shown: " & st.shownPath
      # a new pair: the watch lists both and pairs them
      discard vibAt(dir, "0777.VIB", 300)
      discard datAt(dir, "d.dat", 4321, 300)
      doAssert st.settle(st.fileList.pairs.getOrDefault(dir / "d.dat") == dir / "0777.VIB"),
        "the watch did not pair the new files"
      doAssert st.entry(dir / "d.dat").sweep.vibrator == 12 and
        st.entry(dir / "0777.VIB").sweep.timeIsStart
      doAssert st.settle(st.shownPath == dir / "d.dat" or st.shownPath == dir / "0777.VIB")
      st.shutdown()

  block stoppedDat:
    block alone:
      withFixtures fx:
        let dir = fx.dir / "stop" / "4321" / Date
        discard datAt(dir, "a.dat", 4321, 100)
        var st = initAppState(indexCache = fx.dir / "cache", watchEvery = Look)
        st.apply Command(kind: ckBrowse, paths: @[dir], showFirst: true)
        doAssert st.settle(st.shownPath == dir / "a.dat" and st.laidOut and
          not st.fileList.scanning)
        var s = st.settings
        s.files.followLatest = true
        st.apply Command(kind: ckSettings, settings: s)
        let stopped = datAt(dir, "s.dat", 4321, 200, more = SynthDat(samples: 12000,
          truncateAfter: 5, noQc: true))
        doAssert st.settle(st.steady(stopped))
        let quiet = getMonoTime() + Look * 8
        while getMonoTime() < quiet:
          discard st.drainInbox()
          sleep 5
        doAssert st.shownPath == dir / "a.dat", "a stopped .dat was shown at once"
        doAssert not st.entry(stopped).sweep.complete
        # alone, it is shown once it has stayed as it is for StoppedShowAfter (the drive's clock)
        advanceFsClock(StoppedShowAfter + initDuration(seconds = 1))
        doAssert st.settle(st.shownPath == stopped and st.laidOut), "never shown"
        doAssert st.log.has("the recording stopped after", sevWarning)
        st.shutdown()
    block movedOn:
      withFixtures fx:
        # the controller has moved on: a newer .dat of the same controller is listed
        let dir = fx.dir / "moved" / "4321" / Date
        discard datAt(dir, "a.dat", 4321, 100)
        var st = initAppState(indexCache = fx.dir / "cache", watchEvery = Look)
        st.apply Command(kind: ckBrowse, paths: @[dir], showFirst: true)
        doAssert st.settle(st.shownPath == dir / "a.dat" and st.laidOut and
          not st.fileList.scanning)
        var s = st.settings
        s.files.followLatest = true
        st.apply Command(kind: ckSettings, settings: s)
        let stopped = datAt(dir, "s.dat", 4321, 200, more = SynthDat(samples: 12000,
          truncateAfter: 5, noQc: true))
        discard datAt(dir, "t.dat", 4321, 250) # (another controller's would not count)
        doAssert st.settle(st.log.has("Opened s.dat") or st.log.has("Opened t.dat")),
          "nothing was followed"
        st.shutdown()

  block reopen:
    withFixtures fx:
      let f = build(fx, "day")
      let (dat, vib) = f.pairs[1]
      var st = listed(f.root, fx)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: dat)
      doAssert st.settle(st.shownPath == dat and st.laidOut)
      let codes = proc (path: string): seq[int16] =
        let s = st.session(path)
        (0 ..< s.len).toSeq.mapIt(s.filePtr[].traceKeys(it).traceCode)
      doAssert codes(dat) == @[21'i16, 18, 19, 20]
      # the interval, edits by trace number kept
      st.apply Command(kind: ckEdit, panel: MainPanel, edit: teKilled,
        edited: @[st.session(dat).base + 1], on: true)
      st.apply Command(kind: ckReopen, reopenPath: dat,
        openChoice: OpenChoice(signature: SignatureChoice(intervalUs: 2000)))
      doAssert st.settle(st.log.has("a vibrator signature file") or
        (st.session(dat).signature.choice.intervalUs == 2000 and st.jobs.active.len == 0))
      let two = st.session(dat)
      doAssert two.signature.choice.intervalUs == 2000 and
        two.filePtr[].traceKeys(0).intervalUs == 2000 and two.len == 4
      doAssert st.hasEditAt(dat, 1, teKilled), "the edit by trace number went"
      # swapped force channels: what the file's second channel holds is now trace 3 and the
      # third's trace 2; the codes stay 21, 18, 19, 20 (the roles follow the data)
      let samples = proc (path: string; t: int): seq[float32] =
        let x = st.session(path).filePtr[].readTraces(t .. t)
        for j in 0 ..< x.shape[1]: result.add x[0, j]
      let (massBefore, plateBefore) = (samples(dat, 1), samples(dat, 2))
      doAssert massBefore != plateBefore
      st.apply Command(kind: ckReopen, reopenPath: dat,
        openChoice: OpenChoice(signature: SignatureChoice(swapForces: true)))
      doAssert st.settle(st.session(dat).signature.choice.swapForces and
        st.jobs.active.len == 0)
      doAssert codes(dat) == @[21'i16, 18, 19, 20], $codes(dat)
      doAssert samples(dat, 1) == plateBefore and samples(dat, 2) == massBefore,
        "the channels were not swapped"
      doAssert "swapped by your choice" in summaryText(summaryLines(st.session(dat), 0))
      # a .vib: t = 0 at the first frame
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
      doAssert st.settle(st.shownPath == vib and st.laidOut)
      doAssert st.session(vib).filePtr[].traceKeys(0).t0Ms != 0 # (t = 0 is the trigger)
      st.apply Command(kind: ckReopen, reopenPath: vib,
        openChoice: OpenChoice(signature: SignatureChoice(fromFirstFrame: true)))
      doAssert st.settle(st.session(vib).signature.choice.fromFirstFrame and
        st.jobs.active.len == 0)
      doAssert st.session(vib).filePtr[].traceKeys(0).t0Ms == 0,
        "t0 is not 0: " & $st.session(vib).filePtr[].traceKeys(0).t0Ms
      # the refusals, in the words of the brief; the files stay as they are
      let before = st.log.len
      st.apply Command(kind: ckReopen, origin: coAgent, reopenPath: dat,
        openChoice: OpenChoice(standard: scSegd))
      st.apply Command(kind: ckReopen, origin: coAgent, reopenPath: vib,
        openChoice: OpenChoice(signature: SignatureChoice(swapForces: true)))
      doAssert st.log.has("a vibrator signature file is decoded, not read as SEG-Y or SEG-D: " &
        "only its sample interval and its force channels (a .dat) or its time zero (a .vib) " &
        "can be chosen", sevWarning)
      doAssert st.log.has("a .vib's channels are named by the file; choose the accelerometer " &
        "set in the Vibrator window", sevWarning)
      doAssert st.log.len == before + 2
      st.shutdown()

  block reopenEvery:
    withFixtures fx:
      let f = build(fx, "day")
      let (dat, _) = f.pairs[1]
      let (other, vib) = f.pairs[7]
      var st = listed(f.root, fx)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: dat)
      doAssert st.settle(st.shownPath == dat and st.laidOut)
      st.apply Command(kind: ckReopen, reopenPath: dat, reopenAll: true,
        openChoice: OpenChoice(signature: SignatureChoice(intervalUs: 2000)))
      doAssert st.settle(st.session(dat).signature.choice.intervalUs == 2000 and
        st.jobs.active.len == 0)
      # another .dat of the listing opens at 2000 us, a .vib at its own 500
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: other)
      doAssert st.settle(st.shownPath == other and st.laidOut)
      doAssert st.session(other).signature.choice.intervalUs == 2000
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: vib)
      doAssert st.settle(st.shownPath == vib and st.laidOut)
      doAssert st.session(vib).signature.choice.intervalUs == 500
      st.shutdown()

  releaseAll()
  echo "tsigfolder: ok"

when isMainModule:
  main()
