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
## Seen to fail: with `decode` writing the traces in the order 21, 19, 18, 20, `layout` found
## code 19 at trace 2; with `adopt` reading positions for a signature file, `noMapPoint`
## found a layer; with `decodeToSession` writing the index cache, `nothingIsWritten` saw a
## write call; with `rolesOf` not reading the codes of a signature file, `vibratorWindow`
## found the roles by position; with `vibratorOf` ignoring `forceNote`, the masses made a GF
## (M, B).

import std/[json, os, sequtils, strutils]
import parseSEG
import parseSSDAT
import viewSEG/core/[filejobs, properties, state]
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
        doAssert k.status == tsAuxiliary and s.auxLike(k)
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
      doAssert not st.log.has("from the cache")
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
