## A vibrator controller's `.dat` signature file opens in viewSEG from memory: one record
## of four traces (the reference, the reaction-mass and baseplate force channels, and the
## controller's ground force, their sum; codes 21, 18, 19, 20; all auxiliary), the record the
## file number, 1000 us, the trigger in the keys, the counts bit for bit. `Session.path` is
## the `.dat`'s, its size the file's, and the parseSEG file is in memory. Nothing is written
## (no create, write, rename or remove call, the index cache folder stays empty). A stopped
## recording opens with its samples and a warning in words; a foreign `.dat`, a corrupt
## block and a file with no sample are refused in words and nothing is shown. The Summary
## says the controller, vibrator, trigger, that the interval is assumed, the channels and the
## controller's QC; the agent's `state` carries the signature object. No survey point is
## added. The Vibrator window on the four traces takes its roles from the codes, forms no
## GF (M, B) and is not changed by typed masses.
##
## Seen to fail: with the signature kinds told after `detectKind`, `segyLookalike` found the
## file SEG-Y; with the open job sending a chosen standard to the SEG-Y opener, `reopenAsSegy` found
## the SEG-Y reader's refusal; with `adopt` reading positions for a signature file, `noMapPoint` found a
## layer; with the signature branch of `rolesOf` off, `vibratorWindow` found the hand-made
## swap in the next window's roles; with `vibratorOf` ignoring `forceNote`, the masses made a
## GF (M, B).

import std/[json, os, sequtils, strutils]
import parseSEG
import parseSSDAT
import parseSEG/model/indexwalk
import viewSEG/core/[filejobs, filekinds, openchoice, properties, state]
import viewSEG/remote/tools
import utils/[chosenref, faultyfs, fixtures, sigfiles, waiting]

proc body(answer: string): JsonNode =
  parseJson(parseJson(answer)["content"][0]["text"].getStr)

proc shownSession(st: AppState): int =
  st.shownFile(st.findPanel(MainPanel))

proc samples(f: var SeismicFile; i: int): seq[float32] =
  let x = f.readTraces(i .. i)
  result = newSeq[float32](x.shape[1])
  for j in 0 ..< result.len: result[j] = x[0, j]

func has(log: MessageLog; part: string; severity = sevInfo): bool =
  for e in log:
    if part in e.text and e.severity == severity: return true

proc openIt(st: var AppState; path: string): bool =
  st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
  st.settle(st.sessions.len == 1 and st.panel(MainPanel).laidOut)

proc main*() =
  block layout:
    withFixtures fx:
      let path = datFile(fx.dir / "0042", "0042_x.dat")
      let shot = parseDat(cast[seq[byte]](readFile(path)))
      var st = initAppState(indexCache = fx.dir / "cache")
      doAssert st.openIt(path), $st.log.len
      let s = st.sessions[st.shownSession]
      doAssert s.isSignature and s.signature.kind == sgDat
      doAssert s.path == path and s.size == getFileSize(path)
      doAssert s.file.inMemory
      doAssert s.len == 4 and s.gathers.len == 1
      let fp = s.filePtr
      let codes = [21'i16, 18, 19, 20]
      for t in 0 ..< 4:
        let k = fp[].traceKeys(t)
        doAssert k.traceCode == codes[t], "trace " & $t & " has code " & $k.traceCode
        doAssert k.status == tsAuxiliary and not isSeismic(fp[].index, t)
        doAssert k.record == 7001 and k.intervalUs == 1000
      doAssert fp[].traceKeys(0).time == posixTime(shot.trigger)
      let (ref0, mass, base, force) = (samples(fp[], 0), samples(fp[], 1), samples(fp[], 2),
          samples(fp[], 3))
      doAssert ref0.len == 12000
      for i in 0 ..< 12000:
        doAssert ref0[i] == float32(shot.data[dcReference][i])
        doAssert mass[i] == float32(shot.data[dcMass][i])
        doAssert base[i] == float32(shot.data[dcBaseplate][i])
        doAssert force[i] == mass[i] + base[i], "trace 4 is not trace 2 + trace 3 at " & $i
      doAssert st.log.has("vibrator .dat signature file of controller 4321, vibrator 12, 4 traces")
      doAssert st.log.has("decoded in memory")
      let first = st.panel(MainPanel)
      doAssert first.layers[0].display.gain == dgNormalized and
        first.shownFields == @[hfTraceId, hfTrace], "the first look of a .dat"
      doAssert s.traceNames[0] == "ref\treference"
      doAssert not st.log.has("from the cache")
      st.shutdown()

  block segyLookalike:
    # Some signature files' bytes make parseSEG's `detectKind` say SEG-Y (a plausible binary
    # header at byte 3200, inside a data block): the signature kind is told first.
    withFixtures fx:
      let good = datFile(fx.dir, "plain.dat")
      var b = cast[seq[byte]](readFile(good))
      for i in 3200 ..< 3584: b[i] = 0
      b[3216] = 0x03 # sample interval 1000 (big-endian), 100 samples, format code 5
      b[3217] = 0xE8
      b[3221] = 100
      b[3225] = 5
      fixChecksum(b, 6)
      writeBytes(fx.dir / "lookalike.dat", b)
      doAssert detectKind(b) == skSegy, "the synthetic bytes do not look like SEG-Y"
      doAssert sniff(fx.dir / "lookalike.dat") == fkDat
      var st = initAppState(indexCache = fx.dir / "cache")
      doAssert st.openIt(fx.dir / "lookalike.dat")
      doAssert st.sessions[0].isSignature and st.sessions[0].len == 4
      doAssert not dirExists(fx.dir / "cache") or toSeq(walkDir(fx.dir / "cache")).len == 0
      st.shutdown()

  block dateTooFar:
    withFixtures fx:
      var st = initAppState()
      for year in [2300, 9999]:
        let name = "y" & $year & ".dat"
        let path = datFile(fx.dir, name, SynthDat(samples: 600, trigger: DatTime(year: year,
          month: 2, day: 3, hour: 4, minute: 5, second: 6, nanosecond: 789_000_000)))
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: path)
        doAssert st.settle(st.log.has(name & " could not be opened as a vibrator .dat file: " &
          "its trigger date (the year " & $year & ") is past the year 2262", sevError)), $year
        doAssert st.sessions.len == 0
      st.shutdown()

  block reopenAsSegy:
    # A remembered "read as SEG-Y" never sends a signature file to the SEG-Y reader.
    withFixtures fx:
      let path = datFile(fx.dir, "a.dat")
      var st = initAppState()
      doAssert st.openIt(path)
      st.apply Command(kind: ckReopen, reopenPath: path, openChoice: OpenChoice(standard: scSegy))
      doAssert st.settle(st.log.has("a.dat is opened again") and st.jobs.active.len == 0),
        "the reopen was not taken in"
      doAssert st.sessions[0].isSignature and st.sessions[0].len == 4
      doAssert not st.log.has("is not a SEG-Y", sevError), "the SEG-Y reader was given the file"
      st.shutdown()

  block noMapPoint:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(datFile(fx.dir, "a.dat"))
      doAssert st.settle(st.jobs.active.len == 0)
      doAssert st.survey.layers.len == 0, "a signature file put a layer on the map"
      st.shutdown()

  block stopped:
    withFixtures fx:
      var st = initAppState()
      let path = datFile(fx.dir, "s.dat", SynthDat(samples: 12000, truncateAfter: 40))
      doAssert st.openIt(path)
      let s = st.sessions[0]
      doAssert not s.signature.info.complete
      doAssert s.len == 4 and s.file.traceKeys(0).intervalUs == 1000
      doAssert st.log.has("the recording stopped after", sevWarning), "no warning"
      doAssert st.log.has("Shown as recorded", sevWarning)
      let lines = summaryLines(s, 0)
      var recording, qc = ""
      for l in lines:
        if l.label == "Recording": recording = l.value
        if l.label == "Record": qc = l.value
      doAssert "stopped after" in recording, recording
      doAssert "no QC record" in qc, qc
      st.shutdown()

  block refused:
    withFixtures fx:
      var st = initAppState()
      let good = datFile(fx.dir, "g.dat")
      var bytes = readFile(good)
      bytes[512 * 5 + 30] = char(ord(bytes[512 * 5 + 30]) xor 0x55) # a data block's checksum
      writeFile(fx.dir / "bad.dat", bytes)
      writeFile(fx.dir / "foreign.dat", "this is not a signature file\n".repeat(100))
      writeFile(fx.dir / "empty.dat", "")
      for (name, words) in [("bad.dat", "could not be opened as a vibrator .dat file"),
          ("foreign.dat", "is not a SEG-Y, SEG-D or SEG-2 file"),
          ("empty.dat", "empty.dat is empty: not opened.")]:
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.dir / name)
        doAssert st.settle(st.log.has(words, sevError)), name
        doAssert st.sessions.len == 0, name & " was shown"
      st.shutdown()

  block summaryAndAgent:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(datFile(fx.dir, "a.dat"))
      let text = summaryText(summaryLines(st.sessions[0], 0))
      for part in ["Signature file", "vibrator controller .dat signature file",
          "Controller (serial)\t4321", "Vibrator ID\t12", "assumed", "1 reference (21)",
          "4 ground force (the controller's: the sum of 2 and 3) (20)", "raw counts",
          "as recorded: no sign is changed", "The controller's QC", "Limits tripped"]:
        doAssert part in text, part & " is missing from:\n" & text
      doAssert "real" notin text.toLowerAscii and "measured" notin text
      let sig = st.stateReport(Frontend(), """{"parts":["files"]}""").body["files"][0]["signature"]
      doAssert sig["kind"].getStr == "dat" and sig["controller"].getInt == 4321
      doAssert sig["intervalAssumed"].getBool and sig["decodedAs"].getStr.contains("in memory")
      st.shutdown()

  block vibratorWindow:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(datFile(fx.dir, "a.dat"))
      let base = st.sessions[0].base
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
      doAssert st.settle(st.plots.len == 1 and st.plots[0].result.plots.len > 0),
        st.plots[0].result.problem
      doAssert st.plots[0].traces.len == 4
      let r = st.plots[0].params.roles
      doAssert (r.reference, r.groundForce, r.mass, r.baseplate) == (0, 3, 1, 2), $r
      var p = st.plots[0].params
      p.reactionMassKg = 3600
      p.baseplateMassKg = 1400
      let before = st.plots[0].result.gen
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: p)
      doAssert st.settle(st.plots[0].result.gen > before and not st.plots[0].waiting and
        st.plots[0].result.plots.len > 0)
      doAssert not st.plots[0].result.bothSignals, "GF (M, B) was formed from typed masses"
      doAssert "no masses are applied" in st.plots[0].result.note, st.plots[0].result.note
      # a choice made by hand (mass and baseplate swapped) is remembered for a SEG-Y layout, and
      # never reaches a signature file: the next window takes its roles from the codes again
      var q = st.plots[0].params
      swap(q.roles.mass, q.roles.baseplate)
      (q.roles.source, q.roles.handFile) = (rsHand, st.sessions[0].name)
      st.apply Command(kind: ckPlotDisplay, plot: st.plots[0].id, plotParams: q)
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
      doAssert st.settle(st.plots.len == 2 and st.plots[1].result.plots.len > 0)
      let r2 = st.plots[1].params.roles
      doAssert (r2.reference, r2.groundForce, r2.mass, r2.baseplate) == (0, 3, 1, 2),
        "roles by hand reached the next window: " & $r2
      st.shutdown()

  block storeReference:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(datFile(fx.dir, "a.dat"))
      let id = st.chooseStored(fx.dir / "refs", st.sessions[0].base, "pilot")
      var e = st.references.entries[0]
      doAssert e.intervalUs == 1000 and e.samples == 12000, $(e.intervalUs, e.samples)
      doAssert e.origin.fileName == "a.dat" and e.origin.trace == 1, $e.origin
      doAssert id.len > 0
      st.shutdown()
  block nothingIsWritten:
    withFixtures fx:
      let path = datFile(fx.dir, "a.dat")
      let before = readFile(path)
      install()
      resetCounts()
      var st = initAppState(indexCache = fx.dir / "cache")
      doAssert st.openIt(path)
      doAssert calls(foWrite) == 0, "the open wrote: " & $calls(foWrite)
      doAssert not dirExists(fx.dir / "cache") or toSeq(walkDir(fx.dir / "cache")).len == 0
      doAssert readFile(path) == before
      doAssert uiCalls().len == 0, $uiCalls()
      st.shutdown()

  echo "tdatopen: ok"

when isMainModule:
  main()
