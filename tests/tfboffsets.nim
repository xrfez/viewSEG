## Where the first-break overlay's offsets come from, on a synthetic Rev 0 SEG-Y shot (2500 m/s
## half space, offsets 100 to 2550 m) that a recording system writes with its numbers times 100:
##
## - opened through the shipped map `segy-x100-stations.nif`, a file with the offset and the
##   coordinates stored times 100 under the scalar -100 (and times 10 under -10) gives the right
##   offsets (the offset is read through the coordinate scalar), source "file", the model's
##   velocity is the true one and the overlay says nothing of a scale; opened with no map, the
##   same file gives a velocity 100 times too large, and the words say the offsets look wrongly
##   scaled (about 100 times too large) while the model is shown as fitted;
## - the coordinate scalar (bytes 71-72) is applied on the file path: a negative, a positive and
##   a zero scalar all give the true offsets and velocity;
## - a record joined to a survey (both ends set by the join) takes its offsets from the
##   survey's positions, not from a header offset that is wrongly scaled: the source is "survey"
##   and the velocity right; a join that arrives later makes the overlay again, once (at most two
##   overlay jobs for the join), and the first answer said the offsets looked wrongly scaled;
## - "Use this record's fit" refuses a fit above the velocity a given model takes (it was once cut
##   to the cap, a wrong model), and says why.
##
## - a file with coordinates, scalar -100 and an offset in true units, no map, keeps the true
##   velocity (the standard reading);
## - the words and limits: the slowest first-break velocity is 120 m/s, a unit that is not known
##   uses the metre floor and the foot ceiling, a refused fit names its segment and blames the
##   scale only when the scale words do, the offsets' source says how many came from the survey.
##
## Seen to fail: with the offset entry left out of the map, "the velocity is 250000"; with the
## words' guard left out, "no word of a wrong scale"; with the join's positions not used for the
## offset, "the velocity is 2500000" after the join; with the fit cut to the cap instead of
## refused, "a fit above the cap was kept". The scalar blocks pass on parseSEG's reading of the
## scalar; they would fail with a scalar not applied (the velocity 10 or 100 times off).
import std/[math, os, strutils]
import parseSEG
import processSEG/synth
import viewSEG/core/[breakmodel, firstbreakjobs, firstbreaks, join, openchoice, vendormaps]
import viewSEG/core/state {.all.}
import utils/[breakfiles, fixtures, waiting]

const
  Sentence = "C37 SOURCE AND RECEIVER LINE AND POINT NUMBERS ARE X 100 IN TRACE HEADERS"
  MapPath = currentSourcePath().parentDir.parentDir / "vendormaps" / "segy-x100-stations.nif"

type Spec = object
  sentence: bool   ## the textual header says the numbers are times 100
  offsetScale: int ## the offset field holds the offset times this; 0: not set
  scalar: int      ## the coordinate scalar; the coordinates are written when `coords`
  coords: bool
  stations: bool   ## bytes 181-196 hold the line and point numbers times 100

proc put(b: var seq[byte]; at, bytes, v: int) =
  for k in 0 ..< bytes: b[at + k] = byte((v shr (8 * (bytes - 1 - k))) and 0xFF)

proc stored(v: float64; scalar: int): int =
  ## The integer a header holds for `v` under coordinate scalar `scalar`.
  if scalar > 0: int(round(v / float64(scalar)))
  elif scalar < 0: int(round(v * float64(-scalar)))
  else: int(round(v))

proc rawShot(fx: Fixtures; name: string; sp: Spec): string =
  ## Big-endian Rev 0, IEEE floats, in metres: the shot of `breakfiles` (the planted trace
  ## included), the source at (1000, 500), the receivers on a line east of it.
  result = fx.dir / name
  let stride = 240 + 4 * breakfiles.Samples
  var b = newSeq[byte](3600 + Traces * stride)
  if sp.sentence:
    for i, c in Sentence: b[i] = byte(c)
  b.put(3216, 2, int(Dt * 1000))
  b.put(3220, 2, breakfiles.Samples)
  b.put(3224, 2, 5)
  b.put(3254, 2, 1)
  var buf = newSeq[float32](breakfiles.Samples)
  for i in 0 ..< Traces:
    for j in 0 ..< breakfiles.Samples: buf[j] = 0
    let late = if i == PlantedTrace: PlantedMs else: 0.0
    buf.addRicker(Dt, arrivalMs(offsetOf(i)) + late + 25, 30, 1.0)
    buf.addNoise(0.03, int64(i + 1))
    let at = 3600 + i * stride
    b.put(at, 4, i + 1)
    b.put(at + 8, 4, 1)
    b.put(at + 12, 4, i + 1)
    b.put(at + 28, 2, 1)
    if sp.offsetScale > 0: b.put(at + 36, 4, int(offsetOf(i)) * sp.offsetScale)
    if sp.coords:
      b.put(at + 70, 2, sp.scalar and 0xFFFF)
      b.put(at + 72, 4, stored(1000, sp.scalar))
      b.put(at + 76, 4, stored(500, sp.scalar))
      b.put(at + 80, 4, stored(1000 + offsetOf(i), sp.scalar))
      b.put(at + 84, 4, stored(500, sp.scalar))
    b.put(at + 114, 2, breakfiles.Samples)
    b.put(at + 116, 2, int(Dt * 1000))
    if sp.stations:
      for k, v in [100, 101 + i, 519, 136]: b.put(at + 180 + 4 * k, 4, v * 100)
    for j in 0 ..< breakfiles.Samples:
      b.put(at + 240 + 4 * j, 4, int(cast[uint32](buf[j])))
  var text = newString(b.len)
  for i, c in b: text[i] = char(c)
  writeFile(result, text)

proc registry(): VendorRegistry =
  result.addMap loadVendorMap(readFile(MapPath), MapPath)

proc breaksOn(path: string; mapped: bool): FirstBreaks =
  let opts = if mapped: openOptions(OpenChoice(), "", registry()) else: OpenOptions()
  var f = openSeismic(path, keys = true, opts = opts)
  result = breaksOfRecord(addr f, path, 0 ..< f.len, [])
  f.close()

func trueVelocity(b: FirstBreaks): bool = b.hasFit and b.fit.v1 in 2400.0 .. 2600.0

proc writeSurvey(fx: Fixtures): tuple[s, r: string] =
  ## An S file with the source (519, 136) at (1000, 500) and an R file with the receivers
  ## (100, 101 + i) at their true places.
  result = (fx.dir / "fb.s", fx.dir / "fb.r")
  let header = SpsHeader(code: "00", description: "SPS format version num.", data: "SPS 2.1;")
  var s, r = SpsFile(headers: @[header])
  proc point(kind: SpsPointKind; line, pt, x, y: float64): SpsPoint =
    SpsPoint(kind: kind, line: line, point: pt, index: 1, code: "G1", easting: x, northing: y,
      elevation: 10, dayOfYear: -1, hour: -1, minute: -1, second: -1)
  s.points.add point(pkSource, 519, 136, 1000, 500)
  for i in 0 ..< Traces:
    r.points.add point(pkReceiver, 100, float64(101 + i), 1000 + offsetOf(i), 500)
  for (f, path) in [(s, result.s), (r, result.r)]:
    let log = writeSps(f, path)
    doAssert log.len == 0, $log

proc main*() =

  block theMapDividesTheOffsetField:
    withFixtures fx:
      let path = fx.rawShot("x100.sgy", Spec(sentence: true, offsetScale: 100, stations: true,
        coords: true, scalar: -100))
      let mapped = breaksOn(path, true)
      doAssert mapped.source == bsFile and mapped.hasModel, $mapped.source
      doAssert mapped.trueVelocity, "the velocity is " & $mapped.fit.v1
      doAssert mapped.scaleWords(suMetres) == "" and mapped.fitRefusal == "",
        mapped.scaleWords(suMetres)
      doAssert abs(mapped.modelOf(3) - arrivalMs(offsetOf(3))) <= 8
      # the same bytes with no map: read as they are, 100 times too far
      let plain = breaksOn(path, false)
      doAssert plain.hasFit and plain.fit.v1 > 200_000, "the velocity is " & $plain.fit.v1
      let words = plain.modelWords(suMetres)
      doAssert "look wrongly scaled" in words and "about 100 times too large" in words,
        "no word of a wrong scale: " & words
      doAssert "Offsets from the file's own headers" in words, words
      doAssert plain.modelNote == "" and plain.hasModel, "nothing is corrected, nothing hidden"
      # in a unit that is not known the metre floor and the foot ceiling still catch it
      doAssert plain.scaleWords(suNotGiven) != ""
      # a fit in range says nothing; one far too small says so, the other way round
      var slow = mapped
      slow.fit.v1 = 25
      doAssert "about 100 times too small" in slow.scaleWords(suMetres), slow.scaleWords(suMetres)
      slow.fit.v1 = 7000
      doAssert slow.scaleWords(suFeet) == "" and slow.scaleWords(suMetres) == ""
      slow.fit.v1 = 90_000
      doAssert slow.scaleWords(suMetres) != "" and slow.scaleWords(suFeet) == "",
        "the range is in the file's unit: 90000 ft/s is 27 km/s"

  block theCoordinateScalarIsAppliedOnTheFilePath:
    withFixtures fx:
      for scalar in [-100, 10, 0]:
        let path = fx.rawShot("scalar" & $(scalar + 1000) & ".sgy",
          Spec(coords: true, scalar: scalar))
        let b = breaksOn(path, false)
        doAssert b.source == bsFile and b.hasModel, "scalar " & $scalar & ": " & $b.source
        doAssert b.trueVelocity, "scalar " & $scalar & ": the velocity is " & $b.fit.v1
        doAssert abs(b.offsetAbs[5] - offsetOf(5)) <= 0.01, "offset " & $b.offsetAbs[5]
        doAssert b.scaleWords(suMetres) == ""

  block anOffsetInTrueUnitsWithACoordinateScalarIsRead:
    withFixtures fx:
      # the standard reading: the offset is in the file's own units, the scalar is for the
      # coordinates; no map is involved
      let path = fx.rawShot("std.sgy", Spec(coords: true, scalar: -100, offsetScale: 1))
      let b = breaksOn(path, false)
      doAssert b.source == bsFile and b.trueVelocity, "the velocity is " & $b.fit.v1
      doAssert abs(b.offsetAbs[5] - offsetOf(5)) <= 0.01, "offset " & $b.offsetAbs[5]

  block theMapReadsTheOffsetThroughTheCoordinateScalar:
    withFixtures fx:
      for (scalar, scale) in [(-100, 100), (-10, 10)]:
        let sp = Spec(sentence: true, offsetScale: scale, stations: true, coords: true,
          scalar: scalar)
        let path = fx.rawShot("scal" & $scale & ".sgy", sp)
        let mapped = breaksOn(path, true)
        doAssert mapped.source == bsFile and mapped.trueVelocity,
          "scalar " & $scalar & ": the velocity is " & $mapped.fit.v1
        doAssert abs(mapped.offsetAbs[5] - offsetOf(5)) <= 0.01, "offset " & $mapped.offsetAbs[5]
        doAssert mapped.scaleWords(suMetres) == ""
        let plain = breaksOn(path, false)
        doAssert plain.hasFit and not plain.trueVelocity, "no map: " & $plain.fit.v1

  block theWordsAndTheLimits:
    var b = FirstBreaks(hasFit: true, modelled: 5, state: bkDone)
    b.fit.v1 = 150
    b.fit.v2 = NaN
    b.fit.crossover = NaN
    doAssert b.scaleWords(suMetres) == "", "150 m/s is a slow dry weathering layer"
    b.fit.v1 = 100
    doAssert b.scaleWords(suMetres) != ""
    # a unit that is not known: the metre floor and the foot ceiling
    b.fit.v1 = 98_000
    doAssert b.scaleWords(suNotGiven) == ""
    b.fit.v1 = 250_000
    doAssert "about 100 times too large" in b.scaleWords(suNotGiven), b.scaleWords(suNotGiven)
    b.fit.v1 = 25
    doAssert "about 100 times too small" in b.scaleWords(suNotGiven)
    # a refused fit names the segment above the limit, and blames the scale only with the words
    b.fit.v1 = 2_500_000
    var r = b.fitRefusal(suMetres)
    doAssert "The fit's velocity (2500000)" in r and "wrongly scaled" in r, r
    doAssert b.scaleWords(suMetres).len > 0
    b.fit.v1 = 2500
    b.fit.v2 = 2_000_000
    b.fit.crossover = 500
    doAssert b.segments == 2
    r = b.fitRefusal(suMetres)
    doAssert "second velocity (2000000)" in r and "wrongly scaled" notin r, r
    doAssert b.scaleWords(suMetres) == ""
    b.fit.v1 = 2_500_000
    r = b.fitRefusal(suMetres)
    doAssert "first velocity (2500000)" in r and "wrongly scaled" in r, r

  block whereTheOffsetsCameFromIsCounted:
    var b = FirstBreaks(source: bsSurvey, withOffset: 10, fromPositions: 10)
    doAssert b.offsetsSentence == "Offsets from the imported survey.", b.offsetsSentence
    b.fromPositions = 4
    doAssert "the imported survey for 4 of 10 traces" in b.offsetsSentence, b.offsetsSentence
    doAssert "status bar" notin b.offsetsSentence
    b.fromPositions = 0
    doAssert b.offsetsSentence == "Offsets from the file's own headers.", b.offsetsSentence
    b.headerDiffers = true
    doAssert "status bar" notin b.offsetsSentence
    b.fromPositions = 10
    doAssert "the trace table and status bar show the headers' offsets" in b.offsetsSentence

  block aFitAboveTheCapIsRefused:
    withFixtures fx:
      let path = fx.rawShot("x100cap.sgy", Spec(offsetScale: 1000))
      let b = breaksOn(path, false)
      doAssert b.hasFit and b.fit.v1 > MaxBreakVelocity, "the velocity is " & $b.fit.v1
      doAssert "above the 1000000" in b.fitRefusal and "wrongly scaled" in b.fitRefusal,
        b.fitRefusal
      doAssert b.fitAsModel.v1 <= 0 and not b.fitAsModel.given, "a fit above the cap was kept"
      let ok = breaksOn(fx.rawShot("true.sgy", Spec(offsetScale: 1)), false)
      doAssert ok.fitRefusal == "" and ok.fitAsModel.given and ok.fitAsModel.v1 in 2400.0 ..
        2600.0, "a fit in range is kept"

  block aJoinGivesTheOffsetsAndAnOverlayMadeEarlierIsMadeAgain:
    withFixtures fx:
      # the offset field holds 100000 times the offset, the map divides by 100: still 1000
      # times too large; the file has no coordinates, so the survey's are the only ones
      let path = fx.rawShot("late.sgy", Spec(sentence: true, offsetScale: 100_000,
        stations: true))
      let survey = fx.writeSurvey()
      let maps = fx.dir / "maps"
      createDir(maps)
      copyFile(MapPath, maps / "segy-x100-stations.nif")
      var st = initAppState()
      st.setVendorFolders(@[VendorFolder(dir: maps, origin: voProgram)])
      doAssert st.settle(st.vendorGen == 1 and st.vendorLoad.maps.len == 1)
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
      doAssert st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut and
        st.jobs.active.len == 0)
      var d = st.panel(MainPanel).layers[0].display
      d.firstBreaks = true
      st.apply Command(kind: ckDisplay, panel: MainPanel, display: d)
      doAssert st.settle(st.firstBreaks.len >= 1 and st.shownBreaks(0).state == bkDone and
        st.jobs.active.len == 0)
      let early = st.shownBreaks(0)
      doAssert early.source == bsFile and early.hasFit and early.fit.v1 > 1_000_000,
        "the velocity is " & $early.fit.v1
      doAssert "look wrongly scaled" in early.modelWords(suMetres), early.modelWords(suMetres)
      st.apply Command(kind: ckJoin, joinFile: st.sessions[0].id, joinFiles: @[
        JoinFile(path: survey.s, kind: jkSps), JoinFile(path: survey.r, kind: jkSps)])
      var jobs: seq[JobId]
      proc seen(st: AppState; jobs: var seq[JobId]) =
        for b in st.firstBreaks:
          if b.job != NoJob and b.job notin jobs: jobs.add b.job
      doAssert st.settle(st.joinReport.serial > 0 and st.joinUnderWay.job == NoJob),
        "the join did not end"
      doAssert st.joinReport.outcome == joJoined, st.joinReport.words.join(" ")
      doAssert st.settle((st.seen(jobs); st.shownBreaks(0).state == bkDone and
        st.shownBreaks(0).source == bsSurvey and st.jobs.active.len == 0)),
        "the overlay was not made again after the join"
      let late = st.shownBreaks(0)
      doAssert late.trueVelocity, "the velocity is " & $late.fit.v1
      doAssert late.scaleWords(suMetres) == "" and late.fitRefusal == ""
      doAssert abs(late.offsetAbs[7] - offsetOf(7)) <= 0.01, "offset " & $late.offsetAbs[7]
      doAssert "Offsets from the imported survey" in late.modelWords(suMetres)
      doAssert late.fromPositions == late.withOffset and late.headerDiffers, "the header differs"
      doAssert "show the headers' offsets" in late.modelWords(suMetres)
      # made again once, and nothing asks for it again in 200 frames
      for frame in 0 ..< 200:
        discard st.drainInbox()
        st.seen(jobs)
        sleep 2
      doAssert jobs.len <= 2, $jobs.len & " overlay jobs for one join"
      st.shutdown()
  echo "tfboffsets: ok"

when isMainModule:
  main()
