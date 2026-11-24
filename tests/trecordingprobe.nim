## The cheap kind of a file on disk (`kindOfFile`): it reads the start of the file and
## gives the answer of `describeRecording` for every file small enough to be read whole,
## and none for what is not seismic, cannot be read or has no live trace.
##
## Seen to fail with a deliberate fault: the probe's answer made always a shot gather
## ("abut: some(rkShotGather)").

import std/[assertions, options, os, times]
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
  doAssert got.isSome and got.get == want, name & ": " & $got
  doAssert got.get == whole(path, VendorRegistry()).kind, name & " differs from the whole"

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

  block the_same_answer_through_a_vendor_clock:
    let reg = clockRegistry(dir / "reg")
    var raw: seq[int64] = @[]
    for i in 0 ..< ClockSegments: raw.add clockStart(i)
    let path = dir / "clock.sgd"
    writeClockRecording(path, raw)
    let got = kindOfFile(path, reg)
    doAssert got == some(rkReceiverContinuous), $got
    doAssert got.get == whole(path, reg).kind
    # without the map the six traces are six receivers of one station that start together
    let bare = kindOfFile(path, VendorRegistry())
    doAssert bare == some(whole(path, VendorRegistry()).kind) and bare != got, $bare

  block not_seismic_unreadable_or_empty:
    createDir(dir)
    let text = dir / "notes.txt"
    writeFile(text, "this is not a seismic file\n")
    doAssert kindOfFile(text, VendorRegistry()).isNone
    doAssert kindOfFile(dir / "missing.sgy", VendorRegistry()).isNone
    let empty = dir / "empty.sgy"
    writeFile(empty, "")
    doAssert kindOfFile(empty, VendorRegistry()).isNone
    let junk = dir / "junk.bin"
    writeFile(junk, newString(3 * 1024 * 1024))
    doAssert kindOfFile(junk, VendorRegistry()).isNone

  block a_file_cut_short_is_still_told:
    let path = writeSpecs(dir, "cut", [spec(0, 0), spec(0, 1000), spec(0, 2000)])
    let size = getFileSize(path)
    let cut = dir / "cutshort.sgd"
    writeFile(cut, readFile(path)[0 ..< size.int - 1500])
    doAssert kindOfFile(cut, VendorRegistry()).isSome

  block a_large_file_is_decided_from_its_first_traces:
    # 20000 traces of 1000 samples, ~85 MB: well past the bytes the probe may read
    var specs: seq[Spec] = @[]
    for i in 0 ..< 20000: specs.add spec(0, i * 1000)
    let path = writeSpecs(dir, "large", specs)
    doAssert getFileSize(path) > 4 * ProbeMaxBytes
    let t0 = cpuTime()
    let got = kindOfFile(path, VendorRegistry())
    echo "kindOfFile of ", getFileSize(path) div (1024 * 1024), " MB: ", cpuTime() - t0, " s"
    doAssert got == some(rkReceiverContinuous), $got

  removeDir(dir)

when isMainModule:
  main()
