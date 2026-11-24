## The kind of a file on disk (`kindOfFile`): a file up to `ProbeWholeBytes` is opened whole
## (headers only) and gets the answer of `describeRecording`; a larger one is not known; none
## for what is not seismic, cannot be read or has no live trace.
##
## Seen to fail with a deliberate fault: the probe's answer made always a shot gather
## ("abut: some(rkShotGather)"); with the start-of-file probe put back for a file above the
## limit, the receiver written last is never seen ("late: (outcome: poKnown, kind:
## rkReceiverContinuous)"); with the multiplexed record not looked for in the first read,
## "mux: (outcome: poKnown, kind: rkShotGather)" (it was opened, a copy demultiplexed).

import std/[assertions, os, strutils, times]
import parseSEG
import viewSEG/core/[recordingkind, recordingprobe, vendormaps]
import utils/[fixtures, kindfiles]

proc whole(path: string; reg: VendorRegistry): RecordingFacts =
  var f = openSeismic(path, keys = true, opts = OpenOptions(vendors: reg))
  try:
    result = describeRecording(planRecording(addr f, path, SpecDtMs, reg))
  finally:
    f.close()

proc same(dir, name: string; specs: openArray[Spec]; want: RecordingKind) =
  let path = writeSpecs(dir, name, specs)
  let got = kindOfFile(path, VendorRegistry())
  doAssert got.outcome == poKnown and got.kind == want, name & ": " & $got
  doAssert got.kind == whole(path, VendorRegistry()).kind, name & " differs from the whole"

proc main*() =
  let dir = getTempDir() / "trecordingprobe"
  removeDir(dir)

  block the_same_answer_as_the_whole_file:
    same(dir, "abut", [spec(0, 0), spec(0, 1000), spec(0, 2000), spec(1, 0), spec(1, 1000),
      spec(1, 2000)], rkReceiverContinuous)
    same(dir, "gap", [spec(0, 0), spec(0, 1000), spec(0, 2150), spec(0, 3150)],
      rkReceiverSliced)
    same(dir, "one", [spec(0, 0)], rkReceiverContinuous)
    same(dir, "two", [spec(0, 0), spec(1, 0)], rkShotGather)
    var shot: seq[Spec] = @[]
    for r in 0 ..< 8:
      for c in 0 ..< 3: shot.add spec(r, 0, c)
    same(dir, "shot", shot, rkShotGather)
    var dense: seq[Spec] = @[]
    for i in 0 ..< 6: dense.add spec(0, i * 250)
    same(dir, "dense", dense, rkReceiverSliced)
    same(dir, "skips", [spec(0, 0), spec(0, 4000), spec(0, 5000), spec(0, 6000),
      spec(0, 47000), spec(0, 48000)], rkReceiverContinuous)

  block every_receiver_needs_its_own_starts:
    # receiver 0 has 57 segments before receiver 1 shows its first; receiver 1 leaves the
    # step at its fifth: 16 segments in all must not decide the kind
    var specs: seq[Spec] = @[]
    for i in 0 ..< 57: specs.add spec(0, i * 1000)
    for i in 0 ..< 40: specs.add spec(1, i * 1000 + (if i >= 4: 333 else: 0))
    same(dir, "perreceiver", specs, rkReceiverSliced)

  block the_same_answer_through_a_vendor_clock:
    let reg = clockRegistry(dir / "reg")
    var raw: seq[int64] = @[]
    for i in 0 ..< ClockSegments: raw.add clockStart(i)
    let path = dir / "clock.sgd"
    writeClockRecording(path, raw)
    let got = kindOfFile(path, reg)
    doAssert got == KindProbe(outcome: poKnown, kind: rkReceiverContinuous), $got
    doAssert got.kind == whole(path, reg).kind
    # without the map the six traces are six receivers of one station that start together
    let bare = kindOfFile(path, VendorRegistry())
    doAssert bare.outcome == poKnown and bare.kind == whole(path, VendorRegistry()).kind and
      bare != got, $bare

  block not_seismic_unreadable_or_empty:
    createDir(dir)
    let text = dir / "notes.txt"
    writeFile(text, "this is not a seismic file\n")
    doAssert kindOfFile(text, VendorRegistry()).outcome == poNone
    doAssert kindOfFile(dir / "missing.sgy", VendorRegistry()).outcome == poNone
    let empty = dir / "empty.sgy"
    writeFile(empty, "")
    doAssert kindOfFile(empty, VendorRegistry()).outcome == poNone
    let junk = dir / "junk.bin"
    writeFile(junk, newString(3 * 1024 * 1024))
    doAssert kindOfFile(junk, VendorRegistry()).outcome == poNone

  block a_file_cut_short_is_still_told:
    let path = writeSpecs(dir, "cut", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    let size = getFileSize(path)
    let cut = dir / "cutshort.sgd"
    writeFile(cut, readFile(path)[0 ..< size.int - 1500])
    doAssert kindOfFile(cut, VendorRegistry()).outcome != poNone

  block a_large_file_is_opened_whole:
    # 20000 traces of 1000 samples, ~85 MB: opened whole, headers only
    var specs: seq[Spec] = @[]
    for i in 0 ..< 20000: specs.add spec(0, i * 1000)
    let path = writeSpecs(dir, "large", specs)
    let t0 = cpuTime()
    let whole = kindOfFile(path, VendorRegistry())
    echo "kindOfFile of ", getFileSize(path) div (1024 * 1024), " MB: ", cpuTime() - t0, " s"
    doAssert whole == KindProbe(outcome: poKnown, kind: rkReceiverContinuous), $whole
    removeFile(path)

  block a_file_above_the_limit_is_not_known:
    # three components of one station, each in a run of its own; the last one leaves the step
    # at its second start: only the whole file tells, so above the limit there is no kind
    var specs: seq[Spec] = @[]
    for c in 0 ..< 3:
      for i in 0 ..< 150: specs.add spec(0, i * 1000 + (if c == 2 and i == 1: 300 else: 0), c)
    let path = writeSpecs(dir, "late", specs)
    let size = getFileSize(path)
    doAssert kindOfFile(path, VendorRegistry()) ==
      KindProbe(outcome: poKnown, kind: rkReceiverSliced)
    for limit in [0'i64, size div 2, size - 1]:
      let got = kindOfFile(path, VendorRegistry(), wholeBytes = limit)
      doAssert got == KindProbe(outcome: poNotKnown), "late: " & $got
    doAssert kindOfFile(path, VendorRegistry(), wholeBytes = size).outcome == poKnown
    # what is not seismic stays without a kind, whatever its size
    let text = dir / "big.txt"
    writeFile(text, "not a seismic file\n")
    doAssert kindOfFile(text, VendorRegistry(), wholeBytes = 0).outcome == poNone

  block multiplexed_segd_is_not_opened:
    # the open would demultiplex a copy of the whole file: the list does not, and says so
    createDir(dir)
    let path = dir / "mux.sgd"
    writeMultiplexed(path)
    var copies = 0
    for kind, f in walkDir(getTempDir()):
      if f.extractFilename.startsWith("parseseg_demux_"): inc copies
    let got = kindOfFile(path, VendorRegistry())
    doAssert got == KindProbe(outcome: poMultiplexed), "mux: " & $got
    var after = 0
    for kind, f in walkDir(getTempDir()):
      if f.extractFilename.startsWith("parseseg_demux_"): inc after
    doAssert after == copies, "a demultiplexed copy was made"

  removeDir(dir)

when isMainModule:
  main()
