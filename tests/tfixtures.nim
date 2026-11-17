## The test fixtures (`fixtures.nim`) hold what their documentation says: every
## file opens through parseSEG, and its trace count, channel sets, sample values
## and coordinates are the known ones. Every sample is compared with the formula
## that wrote it, so a later test can assert on values taken from the same
## formula. The temporary folder is removed afterwards.
##
## Seen to fail, each time with the fixture module broken:
## - the survey written one sample early (`surveySample(shot, data, i + 1)`):
##   `surveyValues` failed at shot 0, channel 1, sample 78;
## - the data swap of `pdSwappedReceivers` left out: `planted` failed at
##   "swapped-receivers";
## - `withFixtures` without its `remove`: the last check found the folder;
## - the pilot written with trace code 6 but no status, as it first was: the
##   writer stored code 0 (it keeps a code only when the status agrees), and
##   `pilot` failed on the trace code.

import std/[math, os, sequtils]
import parseSEG
import utils/fixtures

func at(shot, channel: int): int =
  ## The trace of `shot` (0-based) and `channel` (1-based) in the clean survey.
  shot * Channels + channel - 1

proc keysOf(f: SeismicFile): seq[TraceKeys] =
  f.traceKeys(0 ..< f.len)

proc openClean(path: string): SeismicFile =
  ## `path` with its keys; a fixture opens without a single diagnostic.
  result = openSeismic(path, keys = true)
  doAssert result.log.len == 0, path & ": " & $result.log

proc main*() =

  var dir: string
  withFixtures fx:
    dir = fx.dir
    doAssert dirExists(dir)

    block surveyFacts:
      let path = fx.surveySegy()
      doAssert fx.surveySegy() == path # written once, then the same file
      var f = openClean(path)
      let s = f.summary
      doAssert s.standard == skSegy and $s.revision == "2.1", $s.revision
      doAssert s.formatCode == 5 and s.decodable
      doAssert f.len == SurveyTraces and s.traceCount == SurveyTraces
      doAssert s.samplesPerTrace == Samples and s.sampleIntervalUs == DtMs * 1000
      doAssert s.firstFieldRecord == FirstRecord and
        s.lastFieldRecord == FirstRecord + Shots - 1
      doAssert s.coordinateUnits == cuMeters, $s.coordinateUnits
      let k = f.keysOf
      for shot in 0 ..< Shots:
        for channel in 1 .. Channels:
          let t = k[at(shot, channel)]
          doAssert t.record == float64(FirstRecord + shot) and t.channel == float64(channel)
          doAssert t.srcPoint == FirstSrcPoint + float64(shot)
          doAssert t.srcX == srcX(shot) and t.srcY == OriginY and t.srcZ == Elevation,
            $t.srcX & " " & $t.srcY
          doAssert t.rcvX == rcvX(channel) and t.rcvY == OriginY and t.rcvZ == Elevation
          doAssert t.offset == abs(rcvX(channel) - srcX(shot)), $t.offset
          doAssert t.status == tsLive and t.intervalUs == DtMs * 1000
      doAssert k[at(0, 1)].srcX == 500_112.5 # a coordinate with a fraction
      f.close()

    block surveyValues:
      var f = openSeismic(fx.surveySegy())
      let x = f.readTraces(0 ..< f.len)
      var peak = 0'f32
      for shot in 0 ..< Shots:
        for channel in 1 .. Channels:
          for i in 0 ..< Samples:
            let v = x[at(shot, channel), i]
            doAssert v == surveySample(shot, channel, i),
              "shot " & $shot & ", channel " & $channel & ", sample " & $i & ": " & $v
            peak = max(peak, abs(v))
      doAssert peak > 0.99 # the events are there, not an all-zero file
      # The first arrival at channel 1 of shot 0 (offset 112.5 m): 0.15625 s.
      doAssert x[at(0, 1), 78] == 0 and x[at(0, 1), 79] > 0
      doAssert sample(112.5, 0.15625 + 0.01) == 1 # its first peak, a quarter cycle on
      doAssert surveySample(0, 1, 300) == 0 # between the events
      f.close()

    block planted:
      for p in PlantedDefect:
        var f = openClean(fx.surveySegy(p))
        doAssert f.len == surveyTraces(p), $p & ": " & $f.len
        let k = f.keysOf
        let x = f.readTraces(0 ..< f.len)
        case p
        of pdNone:
          doAssert fx.surveySegy(p) == fx.surveySegy()
        of pdDeadTrace:
          let t = at(1, 5)
          doAssert k[t].status == tsLive and k[t].channel == 5
          doAssert toSeq(0 ..< Samples).allIt(x[t, it] == 0), $p
          doAssert x[at(1, 4), 100] == surveySample(1, 4, 100)
        of pdSpike:
          doAssert x[at(0, 15), 300] == 100 and x[at(0, 15), 299] == surveySample(0, 15, 299)
        of pdMissingTraces:
          doAssert k[^1].record == float64(FirstRecord + 2) and k[^1].channel == 19
          doAssert k.countIt(it.record == float64(FirstRecord + 2)) == 19
        of pdDuplicateStation:
          doAssert k.countIt(it.record == float64(FirstRecord) and it.channel == 12) == 2
          let (a, b) = (k[at(0, 12)], k[at(0, 12) + 1])
          doAssert a.rcvX == b.rcvX and a.srcX == b.srcX and a.offset == b.offset
          doAssert x[at(0, 12), 100] == x[at(0, 12) + 1, 100]
          doAssert k[at(0, 13) + 1].channel == 13 and k[at(1, 1) + 1].record == FirstRecord + 1
        of pdSwappedReceivers:
          for i in 0 ..< Samples:
            doAssert x[at(0, 6), i] == surveySample(0, 10, i), $p & " " & $i
            doAssert x[at(0, 10), i] == surveySample(0, 6, i), $p & " " & $i
          doAssert k[at(0, 6)].rcvX == rcvX(6) and k[at(0, 10)].rcvX == rcvX(10)
          doAssert x[at(1, 6), 100] == surveySample(1, 6, 100)
        of pdZeroCoordinates:
          for channel in 1 .. Channels:
            let t = at(1, channel)
            # A point at exactly (0, 0) reads back as unknown; the fields hold 0.
            doAssert k[t].srcX.isNaN and k[t].srcY.isNaN, $k[t].srcX
            doAssert f.traceField(t, "trace.sourceX").toFloat == 0
            doAssert k[t].rcvX == rcvX(channel)
          doAssert k[at(0, 1)].srcX == srcX(0) and k[at(2, 1)].srcX == srcX(2)
        f.close()

    block sps:
      let (s, r, x) = fx.surveySps()
      let sf = readSps(s)
      let rf = readSps(r)
      let xf = readSps(x)
      for f in [sf, rf, xf]:
        doAssert f.log.count(sevError) == 0 and f.log.count(sevWarning) == 0, $f.log
      doAssert sf.points.len == Shots and rf.points.len == Channels and xf.relations.len == Shots
      doAssert sf.points[1].point == FirstSrcPoint + 1 and sf.points[1].easting == srcX(1)
      doAssert rf.points[^1].point == FirstRcvPoint + float64(Channels - 1) and
        rf.points[^1].easting == rcvX(Channels) and rf.points[^1].northing == OriginY
      doAssert xf.relations[2].fieldRecord == FirstRecord + 2 and
        xf.relations[2].toChannel == Channels
      # They match the survey: the join gives every trace its stations.
      var g: SurveyGeometry
      for p in [s, r, x]: g.addSps(p)
      doAssert g.log.count(sevError) == 0, $g.log
      var f = openSeismic(fx.surveySegy(), keys = true)
      var stats: JoinStats
      doAssert f.applySurvey(g, stats) == SurveyTraces, $stats
      doAssert stats.noSourceXy == 0 and stats.noReceiverXy == 0, $stats
      let k = f.keysOf
      for shot in 0 ..< Shots:
        for channel in 1 .. Channels:
          let t = k[at(shot, channel)]
          doAssert t.srcLine == SrcLine and t.srcPoint == FirstSrcPoint + float64(shot)
          doAssert t.rcvLine == RcvLine and t.rcvPoint == FirstRcvPoint + float64(channel - 1)
          doAssert t.srcX == srcX(shot) and t.rcvX == rcvX(channel)
      f.close()

    block twoSets:
      var f = openClean(fx.twoSetSegd())
      let s = f.summary
      doAssert s.standard == skSegd and $s.revision == "3.0" and s.formatCode == 8058
      doAssert f.len == 2 + 2 * SegdChannels and s.recordCount == 1
      doAssert s.firstFieldRecord == SegdRecordNo
      let sets = f.channelSets
      doAssert sets.mapIt(it.channelType) == @[0x20, 0x98, 0x10, 0x10], $sets
      doAssert sets.mapIt(it.traceCount) == @[1, 1, SegdChannels, SegdChannels]
      doAssert sets.allIt(it.samplesPerTrace == SegdSamples and
        it.sampleIntervalUs == DtMs * 1000)
      let k = f.keysOf
      doAssert k[0].status == tsAuxiliary and k[1].status == tsAuxiliary
      doAssert k[2].status == tsLive and k[^1].status == tsLive
      for t in k:
        doAssert t.record == SegdRecordNo
        doAssert t.srcLine == 1 and t.srcPoint == 1001
        doAssert t.srcX == SegdSourceX and t.srcY == OriginY and t.srcZ == Elevation
      for n in 0 ..< SegdChannels:
        for (row, line, y) in [(2 + n, RcvLine, OriginY),
            (2 + SegdChannels + n, RcvLine + 1, OriginY + 50)]:
          doAssert k[row].rcvLine == line and k[row].rcvPoint == FirstRcvPoint + float64(n)
          doAssert k[row].rcvX == rcvX(n + 1) and k[row].rcvY == y, $k[row].rcvY
      let x = f.readTraces(0 ..< f.len)
      doAssert x[0, 0] == 1 and x[0, 1] == 0 # the time break
      for i in 0 ..< SegdSamples:
        doAssert x[1, i] == pilotSample(i) # the pilot, cut to the record
        for n in 0 ..< SegdChannels:
          doAssert x[2 + n, i] == segdSample(1, RcvLine, float64(n + 1), i)
          doAssert x[2 + SegdChannels + n, i] == segdSample(1, RcvLine + 1, float64(n + 1), i)
      doAssert x[2 + SegdChannels, 100] != x[2, 100] # line 101 is farther away
      f.close()

    block threeComponents:
      var f = openClean(fx.threeComponentSegd())
      doAssert f.len == 1 + 3 * SegdChannels
      let sets = f.channelSets
      doAssert sets.mapIt(it.channelType) == @[0x20, 0x10, 0x10, 0x10], $sets
      let k = f.keysOf
      let x = f.readTraces(0 ..< f.len)
      var peak = 0'f32
      for c in 0 ..< 3:
        for n in 0 ..< SegdChannels:
          let row = 1 + c * SegdChannels + n
          doAssert k[row].component == uint8(c + 1), $k[row].component
          doAssert k[row].rcvLine == RcvLine and k[row].rcvPoint == FirstRcvPoint + float64(n)
          doAssert k[row].rcvX == rcvX(n + 1)
          for i in 0 ..< SegdSamples:
            doAssert x[row, i] == segdSample(ComponentScale[c], RcvLine, float64(n + 1), i)
            if c == 0: peak = max(peak, abs(x[row, i]))
      doAssert peak > 0.99
      doAssert f.componentGroupIds(1 ..< f.len).deduplicate.len == SegdChannels
      f.close()

    block mixedOrder:
      var f = openClean(fx.mixedOrderSegd())
      doAssert f.len == 1 + MixedSets.len * SegdChannels
      let k = f.keysOf
      let x = f.readTraces(0 ..< f.len)
      for s, (line, component) in MixedSets:
        for n in 0 ..< SegdChannels:
          let row = 1 + s * SegdChannels + n
          doAssert k[row].component == uint8(component), $k[row].component
          doAssert k[row].rcvLine == line and k[row].rcvPoint == FirstRcvPoint + float64(n)
          for i in countup(0, SegdSamples - 1, 7):
            doAssert x[row, i] == segdSample(ComponentScale[component - 1], line,
              float64(n + 1), i)
      doAssert not k[0].isSeismic
      f.close()

    block pilot:
      var f = openClean(fx.pilotSegy())
      doAssert f.len == 1 and f.summary.samplesPerTrace == PilotSamples
      let k = f.keysOf
      doAssert k[0].traceCode == 6 and k[0].status == tsAuxiliary, $k[0].status
      let x = f.readTraces(0 .. 0)
      for i in 0 ..< PilotSamples:
        doAssert x[0, i] == pilotSample(i)
      doAssert x[0, 0] == 0 and abs(x[0, 12]) > 0.5 # sin(0), then the sweep
      f.close()

    block demo:
      let counts = [200, 5, 1, 24] # in `demoFileNames` order
      for n, name in demoFileNames:
        let path = fx.demoFile(name)
        doAssert path.parentDir == fx.dir / "demo" and fileExists(path)
        var f = openSeismic(path, keys = true)
        doAssert f.len == counts[n], name & ": " & $f.len
        f.close()
      doAssertRaises ValueError:
        discard fx.demoFile("missing.sgy")

    block noLeftovers:
      # Only the fixtures and parseSEG's demo files: no temporary writer files.
      for kind, path in walkDir(fx.dir):
        if kind == pcFile:
          doAssert path.splitFile.ext in [".sgy", ".sgd", ".s", ".r", ".x"], path

  doAssert dir.len > 0 and not dirExists(dir), "the fixture folder was not removed: " & dir

  block removedOnError:
    # A test that fails inside `withFixtures` still leaves no folder behind.
    var kept: string
    doAssertRaises ValueError:
      withFixtures fx:
        kept = fx.surveySegy().parentDir
        raise newException(ValueError, "a failing test")
    doAssert kept.len > 0 and not dirExists(kept)

  echo "tfixtures: ", SurveyTraces, " survey traces, ", PlantedDefect.high.ord,
    " planted defects, SPS, three SEG-D records, a pilot, ", demoFileNames.len, " demo files"

when isMainModule:
  main()
