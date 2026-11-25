## The fold layers restricted to one offset class or one azimuth sector (`core/foldsplit`, and
## the count in `core/foldactual` and `core/foldjobs`), on the synthetic land survey's six shots
## written here one file each, and on a copy of the survey turned by 33 degrees:
##
## - With 3 offset classes and with 8 azimuth sectors the pre-plot tensor of every class and
##   sector equals the library's `offsetFold` / `azimuthFold` slice, and the recorded count of
##   every class equals the library's `addFold` with the same options on the same files, bin by
##   bin: with traces exactly on a class edge (and on the top edge, in no class), on a sector
##   boundary (due east, north, west and south), with an offset outside every class, with only
##   a header offset (negative too) and a NaN bearing. The difference is planned less recorded of
##   the same class, `totals` hold the fold of all of them, the classes and the traces in none
##   add up to the traces binned, and it is the same on 1, 2, 4 and 8 item threads.
## - The rule that puts a trace in a class (`classOf`) is the library's: each trace of the
##   edge-case file lands in the class the library's tensors put it in.
## - Drawing another class or sector, or all, reads no file again (every file's part holds all
##   classes and sectors); other class edges or another sector count read every file once.
## - The edges are kept exactly (100000.4, 1234567, 1000.0001) and "-0" is 0.
## - Class edges that are not numbers, not ascending, negative, one alone or more than 16 classes
##   are refused with a sentence; sectors outside 2 to 36 too.
##
## Seen to fail: with the class's upper edge taken as inclusive (`<=`) "the edge traces" found
## the class counts off by the edge traces; with the bearing taken from the receiver to the source
## the sector counts differed; with the offset taken from the header alone the classes of the
## traces with coordinates differed; with the class missing from the key, "another class" found
## the first class's map; with the parts' key leaving out the edges, "other edges" read no file.

import std/[algorithm, atomics, locks, math, os, sequtils, strformat, strutils, tables]
import parseSEG
import processSEG/adapters
import processSEG/qc/fold
import processSEG/stack/binning
import arraymancer/tensor
import viewSEG/core/[filesystem, foldactual, foldgrid, foldjobs, geometry, jobs, state]
import utils/[fixtures, waiting]

const Land = "samples/land/land"

type Spot = tuple[x, y: float64]

var
  readsLock: Lock
  reads: seq[string]

proc noteRead(path: string) {.nimcall, gcsafe, raises: [IOError].} =
  {.cast(gcsafe).}:
    withLock readsLock: reads.add path.extractFilename

proc readNow(): seq[string] =
  withLock readsLock: result = reads.sorted

proc forgetReads() =
  withLock readsLock: reads.setLen 0

proc rotatedCopy(src, dest: string; degrees: float64) =
  ## `src`, an SPS S or R file, with its coordinates turned `degrees` about the middle of
  ## `samples/land` (easting in columns 47 to 55, northing in 56 to 65).
  let (cx, cy) = (2_001_000.0, 500_000.0)
  let (s, c) = (sin(degToRad(degrees)), cos(degToRad(degrees)))
  var text = ""
  for line in readFile(src).splitLines:
    var l = line
    if l.len >= 65 and l[0] in {'S', 'R'}:
      let (dx, dy) = (parseFloat(l[46 .. 54].strip) - cx, parseFloat(l[55 .. 64].strip) - cy)
      l = l[0 .. 45] & &"{cx + dx * c - dy * s:>9.1f}" & &"{cy + dx * s + dy * c:>10.1f}" &
        l[65 .. ^1]
    text.add l & "\n"
  writeFile(dest, text)

proc spots(path: string; role: char): Table[(int, int), Spot] =
  ## The stations of an SPS S or R file, by line and point.
  for line in lines(path):
    if line.len >= 65 and line[0] == role:
      result[(int(parseFloat(line[1 .. 10].strip)), int(parseFloat(line[11 .. 20].strip)))] =
        (parseFloat(line[46 .. 54].strip), parseFloat(line[55 .. 64].strip))

const
  Edges = [0.0, 1000.0, 2000.0, 2800.0] ## the offset classes: three
  Sectors = 8

type Extra = tuple[name: string; src, rcv: Spot; cmp: Spot; offset: float64]

proc extras(p: Spot): seq[Extra] =
  ## Traces without stations, around the whole-number position `p`, that land on the edges of
  ## the classes and the sectors: their positions are whole numbers, so the arithmetic is exact.
  let nan = NaN
  let none: Spot = (nan, nan)
  @[("east", p, (p.x + 300, p.y), none, nan), ("north", p, (p.x, p.y + 300), none, nan),
    ("west", p, (p.x - 300, p.y), none, nan), ("south", p, (p.x, p.y - 300), none, nan),
    ("on the edge 1000", p, (p.x + 1000, p.y), none, nan),
    ("on the edge 2000", p, (p.x, p.y + 2000), none, nan),
    ("on the top edge", p, (p.x - 2800, p.y), none, nan),
    ("on the first edge", p, p, none, nan),
    ("outside every class", (p.x - 50000, p.y), (p.x + 50000, p.y), none, nan),
    ("header offset 2000", none, none, p, 2000.0),
    ("header offset -1500", none, none, p, -1500.0),
    ("header offset 1000", none, none, p, 1000.0),
    ("coordinates before a header offset", p, (p.x + 300, p.y + 300), none, 1500.0),
    ("no offset", none, none, p, nan)]

proc shotFile(path: string; shot: int; sources, receivers: Table[(int, int), Spot];
    withExtras: bool) =
  ## Shot `shot` (1 to 6) of the sample: a trace for each of its 96 receivers, the stations and
  ## positions in the headers; with `withExtras` also the traces `extras` lists.
  var w = openSeismicWriter(path, SegyOutputOptions(traceSorting: 1, measurementSystem: 2))
  var ch = 0
  let src = sources[(2001, 100 + shot)]
  for line in [1001, 1002]:
    for point in 101 .. 148:
      inc ch
      var k = initTraceKeys()
      k.record = float64(shot)
      k.channel = float64(ch)
      (k.srcLine, k.srcPoint, k.srcIndex) = (2001.0, float64(100 + shot), 1'i16)
      (k.rcvLine, k.rcvPoint, k.rcvIndex) = (float64(line), float64(point), 1'i16)
      let r = receivers[(line, point)]
      (k.srcX, k.srcY, k.rcvX, k.rcvY) = (src.x, src.y, r.x, r.y)
      (k.intervalUs, k.status) = (2000.0, tsLive)
      w.writeTrace(k, @[0'f32, 0, 0, 0])
  if withExtras:
    # a whole-number position at the middle of the first shot's spread
    let mid = receivers[(1001, 124)]
    let p: Spot = (round((mid.x + src.x) / 2), round((mid.y + src.y) / 2))
    for e in extras(p):
      inc ch
      var k = initTraceKeys()
      k.record = float64(9000 + shot)
      k.channel = float64(ch)
      (k.srcX, k.srcY, k.rcvX, k.rcvY) = (e.src.x, e.src.y, e.rcv.x, e.rcv.y)
      (k.cmpX, k.cmpY, k.offset) = (e.cmp.x, e.cmp.y, e.offset)
      (k.intervalUs, k.status) = (2000.0, tsLive)
      w.writeTrace(k, @[0'f32, 0, 0, 0])
  doAssert w.close().len == 0, "shot file was not written: " & path

proc loaded(st: var AppState; paths: varargs[string]): bool =
  st.apply Command(kind: ckLoadSurvey, paths: @paths)
  st.settle(st.jobs.active.len == 0 and st.survey.layers.len >= paths.len)

proc folder(st: var AppState; dir: string): bool =
  st.apply Command(kind: ckBrowse, paths: @[dir])
  st.settle(not st.fileList.scanning and st.fileList.folder == dir)

proc sizeOf(path: string): int64 = (if fileExists(path): getFileSize(path) else: 0)

proc inputsOf(paths: seq[string]): ref ActualInputs =
  result = new ActualInputs
  for p in paths:
    result.files.add ActualFile(path: p, size: sizeOf(p))
    result.key.add p & "|" & $sizeOf(p) & ";"

proc count(st: var AppState; actual: ref ActualInputs; kind: FoldKind; split: FoldSplit;
    threads = 0): FoldSink =
  ## Runs the job that counts the files and waits for it.
  if threads > 0: st.jobs.setItemThreads(threads)
  let inp = foldInputs(st.survey, NaN, NaN, kind, actual, split)
  result = FoldSink()
  discard st.jobs.submit(foldSpec(kind), foldWork(inp, result))
  doAssert waitUntil(st.jobs.active.len == 0)

func slice(t: Tensor[int32]; k: int): seq[int32] =
  ## Class `k` of a `[classes, inlines, crosslines]` tensor.
  let all = t.toFlatSeq
  let n = all.len div t.shape[0]
  all[k * n ..< (k + 1) * n]

func minus(a, b: seq[int32]): seq[int32] =
  for i in 0 ..< a.len: result.add a[i] - b[i]

func total(v: seq[int32]): int =
  for x in v: result += int(x)

proc libraryMap(grid: Binning; opts: FoldOptions; paths: seq[string]): FoldMap =
  ## What the library's `addFold` makes of the files' own header positions.
  result = initFoldMap(grid, opts)
  for p in paths:
    var f = openSeismic(p, keys = true)
    var traces: seq[int] = @[]
    for t in 0 ..< f.len: traces.add t
    result.addFold(chunkMeta(f, traces, dtMs = 2.0))
    f.close()

proc splitCase(name: string; sFile, rFile, xFile: string; files: seq[string]; both = false) =
  ## Every class and sector of the files, counted by the job, against the library.
  var st = initAppState()
  doAssert st.loaded(sFile, rFile, xFile)
  var g = initSurveyGeometry()
  for f in [sFile, rFile, xFile]: g.addSps(f)
  let grid = surveyGrid(g)
  let size = grid.len
  proc mk(kind: SplitKind; pick: int): FoldSplit =
    ## With `both`, the parts hold the offset classes and the sectors, whichever is drawn.
    FoldSplit(kind: kind, edges: (if kind == spOffset or both: @Edges else: @[]),
      sectors: (if kind == spAzimuth or both: Sectors else: 0), pick: pick)
  for kind in [spOffset, spAzimuth]:
    let opts = if both: FoldOptions(offsetBounds: @Edges, azimuthSectors: Sectors)
      elif kind == spOffset: FoldOptions(offsetBounds: @Edges)
      else: FoldOptions(azimuthSectors: Sectors)
    let plan = g.preplotFold(grid, opts)
    let rec = libraryMap(grid, opts, files)
    let classes = if kind == spOffset: Edges.len - 1 else: Sectors
    let planTensor = if kind == spOffset: plan.offsetFold else: plan.azimuthFold
    let recTensor = if kind == spOffset: rec.offsetFold else: rec.azimuthFold
    let label = name & " " & $kind & (if both: " with both" else: "")
    var classTotal = 0
    for k in 0 ..< classes: classTotal += recTensor.slice(k).total
    var inClasses = 0
    for pick in -1 ..< classes:
      let split = mk(kind, pick)
      let sink = st.count(inputsOf(files), fkActual, split)
      let (a, d) = (sink.result, sink.other)
      doAssert a.ok and d.ok, label & ": " & a.reason
      doAssert a.kind == fkActual and d.kind == fkDifference
      let (wantRec, wantPlan) = if pick < 0: (rec.fold.toFlatSeq, plan.fold.toFlatSeq)
        else: (recTensor.slice(pick), planTensor.slice(pick))
      doAssert a.counts == wantRec, label & " class " & $pick & ": the recorded counts differ"
      doAssert a.planned == wantPlan, label & " class " & $pick & ": the planned counts differ"
      doAssert d.counts == wantPlan.minus(wantRec), label & ": the difference is not planned " &
        "less recorded of the same class"
      doAssert a.split.pick == pick and d.split.pick == pick
      if pick >= 0:
        doAssert a.totals == rec.fold.toFlatSeq and a.plannedTotals == plan.fold.toFlatSeq,
          label & ": the totals are not the fold of all classes"
        inClasses += wantRec.total
      else:
        doAssert a.totals.len == 0
      doAssert a.binned == rec.binned and a.outside == rec.outside and
        a.noCoordinates == rec.noCoordinates, label & ": the totals differ from the library's"
      doAssert a.noClass == rec.binned - classTotal, label & ": the traces in no class"
      # the preplot layer of the same class
      let pre = st.count(inputsOf(files), fkPreplot, split)
      doAssert pre.result.ok and pre.result.counts == wantPlan, label & ": the pre-plot differs"
      if pick >= 0: doAssert pre.result.totals == plan.fold.toFlatSeq
    doAssert inClasses == classTotal and rec.binned - classTotal > 0,
      label & ": no trace fell in no class"
    # the sum over the classes and the traces in none is the traces binned
    let all = st.count(inputsOf(files), fkActual, mk(kind, -1))
    doAssert all.result.noClass + inClasses == all.result.binned, label
    # the same on any number of threads
    let one = st.count(inputsOf(files), fkActual, mk(kind, 1), threads = 1)
    for n in [2, 4, 8]:
      let many = st.count(inputsOf(files), fkActual, mk(kind, 1), threads = n)
      doAssert many.result.counts == one.result.counts and many.other.counts ==
        one.other.counts and many.result.noClass == one.result.noClass and
        many.result.totals == one.result.totals, label & ": differs on " & $n & " threads"
    # the rule on its own, at the edges: the traces `extras` lists, in the order it lists them
    let split = mk(kind, 0)
    var f = openSeismic(files[0], keys = true)
    var keys = newSeq[TraceKeys](f.len)
    f.traceKeysInto(0 ..< f.len, keys)
    f.close()
    let tail = keys[^14 .. ^1].mapIt(split.classOf(it))
    let (want, wantAll) = if kind == spOffset:
        (@[0, 0, 0, 0, 1, 2, -1, 0, -1, 2, 1, 1, 0], 13)
      else: (@[2, 0, 6, 4, 2, 0, 6, 0, 2, -1, -1, -1, 1], 13)
    doAssert tail[0 ..< wantAll] == want, label & ": the edge traces: " & $tail

proc main*() =
  initLock readsLock
  block parsing:
    doAssert parseEdges("").edges.len == 0 and parseEdges("   ").error == ""
    let ok = parseEdges("0, 1000, 2000 4000")
    doAssert ok.error == "" and ok.edges == @[0.0, 1000, 2000, 4000]
    doAssert edgesText(ok.edges) == "0, 1000, 2000, 4000"
    doAssert parseEdges("0;1.5e3,2000").edges == @[0.0, 1500, 2000]
    for bad in ["0, a, 2", "5", "0, 1000, 1000", "0, 2000, 1000", "-5, 100", "0, nan, 5",
        "0, inf", "1000 x"]:
      let r = parseEdges(bad)
      doAssert r.error.len > 0 and r.edges.len == 0, "refused: " & bad
    doAssert parseEdges((0 .. 16).toSeq.mapIt($it).join(",")).error == "", "16 classes"
    doAssert parseEdges((0 .. 17).toSeq.mapIt($it).join(",")).error.len > 0, "17 classes"
    doAssert parseSectors("").sectors == 0 and parseSectors("0").error == ""
    doAssert parseSectors("8").sectors == 8 and parseSectors(" 36 ").sectors == 36
    for bad in ["1", "37", "-2", "x", "2.5"]:
      doAssert parseSectors(bad).error.len > 0, "refused: " & bad
    # the edges are kept exactly
    for text in ["0, 100000.4, 100000.6", "0, 1234567", "0, 1000.0001, 1000.0002",
        "0, 0.00001, 1e14"]:
      let e = parseEdges(text)
      doAssert e.error == "", text
      let kept = edgesText(e.edges)
      doAssert "e" notin kept and parseEdges(kept).edges == e.edges, "exact: " & kept
      doAssert splitOf(kept, e.edges.len - 1, 0, 0).drawn and
        splitOf(kept, 0, 0, 0).offsetClasses == e.edges.len - 1,
        "stays restricted: " & kept
    doAssert edgesText(parseEdges("0, 100000.4, 100000.6").edges) == "0, 100000.4, 100000.6"
    doAssert edgesText(parseEdges("0, 1234567").edges) == "0, 1234567"
    doAssert edgesText(parseEdges("-0, 10").edges) == "0, 10" and
      splitOf("-0, 10", 1, 0, 0).drawnLabel("ft") == "offsets 0–10 ft", "-0 is 0"
    # which restriction the settings ask for
    doAssert splitOf("", 0, 0, 0).kind == spNone
    doAssert splitOf("0, 1000, 2000", 0, 0, 0).shownKind == spOffset and
      not splitOf("0, 1000, 2000", 0, 0, 0).drawn
    doAssert splitOf("0, 1000, 2000", 2, 0, 0).pick == 1
    doAssert splitOf("0, 1000, 2000", 3, 0, 0).pick == -1, "a class that is not there is all"
    doAssert splitOf("", 0, 8, 3) == FoldSplit(kind: spAzimuth, sectors: 8, pick: 2)
    doAssert splitOf("0, 1000", 0, 8, 3).kind == spAzimuth, "a sector drawn wins over edges"
    doAssert splitOf("0, 1000", 1, 8, 3).kind == spOffset, "a class drawn wins"
    doAssert splitOf("0, 1000", 0, 8, 0).shownKind == spOffset, "edges stand before sectors"
    doAssert splitOf("0, 1000", 0, 8, 0).offsetClasses == 1 and splitOf("0, 1000", 0, 8,
        0).sectors == 8,
      "both are kept"
    let sp = splitOf("0, 1000, 2000", 2, 0, 0)
    doAssert sp.drawnLabel("ft") == "offsets 1000–2000 ft"
    doAssert splitOf("", 0, 8, 2).drawnLabel("ft") == "azimuth 45–90°"
    doAssert splitOf("0, 1000", 0, 0, 0).drawnLabel("ft") == ""
    doAssert sp.pickId != splitOf("0, 1000, 2000", 1, 0, 0).pickId and
      sp.specId == splitOf("0, 1000, 2000", 1, 0, 0).specId

  block words:
    # the legend's title, the hover and the totals line name the restriction
    var r = FoldResult(kind: fkPreplot, ok: true, counts: @[3'i32], totals: @[12'i32],
      inlines: 1, crosslines: 1, firstInline: 1, firstCrossline: 1, binAlong: 25, binAcross: 25,
      binned: 12, maxFold: 3, split: FoldSplit(kind: spOffset, edges: @[0.0, 1000, 2000], pick: 1))
    doAssert r.layerTitle("ft") == "Pre-plot fold, offsets 1000–2000 ft"
    doAssert r.foldText(0, "ft") ==
      "fold 3 in offsets 1000–2000 ft, 12 in all (inline 1, crossline 1)", r.foldText(0, "ft")
    r.kind = fkActual
    (r.planned, r.plannedTotals, r.noClass) = (@[2'i32], @[10'i32], 5)
    r.split = FoldSplit(kind: spAzimuth, sectors: 8, pick: 1)
    doAssert r.layerTitle("ft") == "Actual fold, azimuth 45–90°"
    doAssert r.foldText(0, "ft") == "recorded 3 in azimuth 45–90°, 12 in all (planned 2 in " &
      "azimuth 45–90°, 10 in all) at inline 1, crossline 1", r.foldText(0, "ft")
    doAssert "5 traces of the 12 binned fell in no azimuth sector." in r.totalsText("ft") and
      "Drawn: azimuth 45–90°." in r.totalsText("ft"), r.totalsText("ft")
    r.split.pick = -1
    r.totals = @[]
    doAssert r.layerTitle("ft") == "Actual fold" and
      r.foldText(0) == "recorded 3 (planned 2) at inline 1, crossline 1"
    r.split = FoldSplit()
    doAssert "fell in" notin r.totalsText("ft")

  withFixtures fx:
    let (stationsS, stationsR) = (spots(Land & ".s", 'S'), spots(Land & ".r", 'R'))
    let xFile = absolutePath(Land & ".x")
    for (name, turn) in [("straight", 0.0), ("turned 33 degrees", 33.0)]:
      let dir = fx.dir / ("shots" & $int(turn))
      createDir dir
      var (sFile, rFile) = (absolutePath(Land & ".s"), absolutePath(Land & ".r"))
      var (sources, receivers) = (stationsS, stationsR)
      if turn != 0:
        (sFile, rFile) = (fx.dir / "turn.s", fx.dir / "turn.r")
        rotatedCopy(Land & ".s", sFile, turn)
        rotatedCopy(Land & ".r", rFile, turn)
        (sources, receivers) = (spots(sFile, 'S'), spots(rFile, 'R'))
      var files: seq[string] = @[]
      for s in 1 .. 6:
        files.add dir / ("shot" & $s & ".sgy")
        shotFile(files[^1], s, sources, receivers, withExtras = s in {1, 4})
      splitCase(name, sFile, rFile, xFile, files)
      splitCase(name, sFile, rFile, xFile, files, both = true)

    block tracker:
      let rec = fx.dir / "recording"
      createDir rec
      for s in 1 .. 6: shotFile(rec / ("shot" & $s & ".sgy"), s, stationsS, stationsR, s == 1)
      var r = initAppState()
      doAssert r.loaded(Land & ".s", Land & ".r", Land & ".x")
      doAssert r.folder(rec)
      var t: FoldTracker
      proc want(edges: seq[float64]; pick: int; kind = fkActual; sectors = 0;
          by = spOffset): FoldWant =
        FoldWant(kind: kind, on: true, actual: actualInputs(r), stamp: actualStamp(r),
          scope: rec, split: FoldSplit(kind: by, edges: edges, sectors: sectors, pick: pick))
      proc settled(w: FoldWant): bool =
        waitUntil((t.follow(r.jobs, r.survey, w, NaN, NaN); t.status != fmComputing))
      setIoHook(noteRead)
      forgetReads()
      doAssert settled(want(@Edges, 0)) and t.status == fmReady, t.reason
      doAssert readNow().len == 6 and t.partsKept == 6
      doAssert t.shown.split.pick == 0 and t.shown.split.kind == spOffset
      let first = t.shown.counts
      # another class: no file is read again, and the class's map is the one a count of its own gives
      forgetReads()
      doAssert settled(want(@Edges, 1)) and t.status == fmReady, t.reason
      doAssert readNow().len == 0, "another class: no file is read: " & $readNow()
      doAssert t.shown.split.pick == 1 and t.shown.counts != first, "another class: its own map"
      let alone = r.count(inputsOf(actualInputs(r).files.mapIt(it.path)), fkActual,
        FoldSplit(kind: spOffset, edges: @Edges, pick: 1))
      doAssert t.shown.counts == alone.result.counts and t.shown.planned == alone.result.planned
      forgetReads()
      # every class drawn, and back: still no file
      doAssert settled(want(@Edges, -1)), t.reason
      doAssert readNow().len == 0, $readNow()
      doAssert t.shown.counts.total == t.shown.binned
      doAssert settled(want(@Edges, 2)) and readNow().len == 0
      # the same class again is held: no job
      let held = t.shown
      doAssert settled(want(@Edges, 2)) and t.shown == held
      # other edges: every file is read once
      forgetReads()
      doAssert settled(want(@[0.0, 500, 2000], 0)) and t.status == fmReady
      doAssert readNow().len == 6, "other edges: every file is read: " & $readNow()
      # sectors defined as well: every file again; then class, sector, all, class: none
      forgetReads()
      doAssert settled(want(@Edges, 0, sectors = 4)) and t.status == fmReady
      doAssert readNow().len == 6
      for (by, pick) in [(spAzimuth, 3), (spOffset, 1), (spNone, -1), (spAzimuth, 0),
          (spOffset, 2), (spAzimuth, 3)]:
        forgetReads()
        doAssert settled(want(@Edges, pick, sectors = 4, by = by)) and t.status == fmReady
        doAssert readNow().len == 0, "switching what is drawn reads no file: " & $readNow()
        doAssert t.shown.split.kind == by and t.shown.split.pick == pick
      # the difference layer of a sector is of the same sector
      doAssert settled(want(@Edges, 3, fkDifference, sectors = 4, by = spAzimuth)) and
        readNow().len == 0
      doAssert t.shown.kind == fkDifference and t.shown.split.pick == 3
      # the sector count changed: every file is read once; sectors alone: again
      forgetReads()
      doAssert settled(want(@Edges, 3, sectors = 8, by = spAzimuth)) and readNow().len == 6
      forgetReads()
      doAssert settled(want(@[], 3, sectors = 4, by = spAzimuth)) and t.status == fmReady
      doAssert readNow().len == 6 and t.shown.split.kind == spAzimuth
      # no restriction: the plain counts, and a part that holds no classes is read again
      forgetReads()
      var plain = want(@[], -1, sectors = 0)
      plain.split = FoldSplit()
      doAssert settled(plain) and t.status == fmReady and t.shown.split.kind == spNone
      doAssert readNow().len == 6, "no restriction: the parts are of classes: " & $readNow()
      setIoHook(nil)
      discard r.shutdown()
  echo "tfoldsplit: ok"

when isMainModule:
  main()
