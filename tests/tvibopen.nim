## A vibrator controller's `.vib` signature record opens in viewSEG from memory: one record of
## 13 traces in the pinned order (the `.dat`'s four roles first: reference 21, reaction-mass
## 18, baseplate 19, ground force 20, all of set B; then set A's 258, 257, 267; torque motor,
## valve, mass displacement, drive, the two per-cycle values), every trace auxiliary to
## viewSEG, the record the file counter, 500 us, t = 0 at the trigger the sweep fit finds (t0
## within 0.05 ms of the synthetic one), the counts bit for bit and both ground forces the
## header's weights times the counts. A stopped, a cut-short and a no-trigger file open with
## their words; a file of another kind, an empty one, 46 bytes, a wrong magic and month 13 are
## refused in words and nothing is shown. Nothing is written. The Summary and the agent say
## the start second, the trigger, the weights, both sets, "pound-counts" and that the QC is in
## the .dat; the readout names trace 5 "reaction-mass acceleration, set B"'s twin, set A. The
## Vibrator window on trace 1 takes traces 1-4, is not changed by typed masses and says the
## file's weights. The four field signature recordings in samples/vib/field open as SEG-Y.
##
## The first look: a signature file opens with each trace scaled on its own (normalized) and
## the trace's name in the display header; a SEG-Y file shown after it has the defaults back.
##
## Seen to fail: with the signature kinds told after `detectKind`, `segyLookalike` found SEG-Y; with
## the first-look defaults off in `show`, `firstLook` found gain "automatic";
## with the writer asked for `voFile` order, `layout` found code 257 at trace 2;
## with the keys' status not set to auxiliary at the open, `layout` found trace 5 seismic; with `vibratorOf`
## ignoring `forceNote`, the masses made a GF (M, B); with the shot block not added to the
## in-memory SEG-Y, `shotBlock` found no block for the shipped maps to decode.

import std/[json, os, sequtils, strutils]
import parseSEG
import parseSSVIB
import parseSEG/model/indexwalk
import viewSEG/core/[filejobs, filekinds, properties, readout, sigtypes, state, vendormaps]
import viewSEG/remote/tools
import utils/[chosenref, faultyfs, fixtures, sigfiles, waiting]

const root = currentSourcePath().parentDir.parentDir

proc body(answer: string): JsonNode =
  parseJson(parseJson(answer)["content"][0]["text"].getStr)

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

proc shownPath(st: AppState): string =
  let i = st.shownFile(st.findPanel(MainPanel))
  if i >= 0: st.sessions[i].path else: ""

proc main*() =
  block layout:
    withFixtures fx:
      let path = vibFile(fx.dir / "0042" / "20010203", "0007.VIB")
      let shot = parseVib(cast[seq[byte]](readFile(path)))
      var st = initAppState(indexCache = fx.dir / "cache")
      doAssert st.openIt(path)
      let s = st.sessions[0]
      doAssert s.signature.kind == sgVib and s.path == path and s.file.inMemory
      doAssert s.noSeismic and s.records[0].seismic == 0 and s.records[0].aux == 13
      doAssert s.len == 13 and s.gathers.len == 1
      let fp = s.filePtr
      let codes = [21'i16, 18, 19, 20, 258, 257, 267, 261, 262, 263, 264, 265, 266]
      for t in 0 ..< 13:
        let k = fp[].traceKeys(t)
        doAssert k.traceCode == codes[t], "trace " & $(t + 1) & " has code " & $k.traceCode
        doAssert k.status == tsAuxiliary and not isSeismic(fp[].index, t),
          "allAuxiliary: trace " & $(t + 1)
        doAssert k.record == 7 and k.intervalUs == 500
      doAssert abs(fp[].traceKeys(0).t0Ms + 600.37 * 0.5) < 0.05, $fp[].traceKeys(0).t0Ms
      doAssert s.signature.trigger.source == trEstimated and
        abs(s.signature.trigger.frame - 600.37) < 0.02 and
        not s.signature.trigger.sigmaFrames.isNaN
      let wanted = [shot.data[vcReference], shot.data[vcMassB], shot.data[vcBaseplateB],
        @[], shot.data[vcMassA], shot.data[vcBaseplateA], @[], shot.data[vcTorqueMotor],
        shot.data[vcValve], shot.data[vcMassStroke], shot.data[vcDrive]]
      for t in [0, 1, 2, 4, 5, 7, 8, 9, 10]:
        let got = samples(fp[], t)
        let want = wanted[if t < 7: t else: t]
        for i in 0 ..< want.len:
          doAssert got[i] == float32(want[i]), "trace " & $(t + 1) & " sample " & $i
      block groundForces:
        for (t, which) in [(3, vsB), (6, vsA)]:
          let got = samples(fp[], t)
          let want = groundForce(shot, which)
          doAssert got.len == want.len
          for i in 0 ..< want.len: doAssert got[i] == want[i], "ground force " & $which
      doAssert samples(fp[], 11) == shot.cycle[vvDriveRatio]
      doAssert st.log.has("vibrator .vib signature record, 13 traces at 0.5 ms (assumed)")
      doAssert st.log.has("decoded in memory")
      st.shutdown()

  block kindByContent:
    withFixtures fx:
      let path = vibFile(fx.dir, "plain.bin")
      doAssert sniff(path) == fkVib
      doAssert sniff(datFile(fx.dir, "x.dat")) == fkDat
      doAssert sniff(datFile(fx.dir, "x.vib")) == fkDat, "the extension decided"
      for sgy in walkFiles(root / "samples" / "vib" / "field" / "*.sgy"):
        doAssert sniff(sgy) == fkSegy, sgy

  block noFit:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir, "0001.VIB", SynthVib(cubicHzPerS2: 40.0)))
      let s = st.sessions[0]
      doAssert s.signature.trigger.source == trNone and s.signature.trigger.timeZero == "first frame"
      doAssert s.filePtr[].traceKeys(0).t0Ms == 0
      doAssert st.log.has("no trigger found in the reference")
      doAssert st.log.has("t = 0 is the first frame")
      let text = summaryText(summaryLines(s, 0))
      doAssert "Trigger\tnot found" in text, text
      st.shutdown()
  block stopped:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir, "0003.VIB", SynthVib(stopAt: 2000)))
      doAssert st.sessions[0].signature.endsInSweep
      doAssert st.log.has("the record ends inside the sweep", sevWarning)
      st.shutdown()

  block cutShort:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir, "0004.VIB", SynthVib(tailBytes: 12)))
      doAssert st.log.has("the file ends 12 bytes into a frame", sevWarning)
      doAssert st.log.has("whole frames are shown", sevWarning)
      st.shutdown()

  block refused:
    withFixtures fx:
      var st = initAppState()
      let good = readFile(vibFile(fx.dir, "g.VIB"))
      var month13 = good
      month13[44] = char(13)
      var magic = good
      magic[0] = 'X'
      writeBytes(fx.dir / "other.VIB", synthOtherKind(50))
      writeFile(fx.dir / "short.VIB", good[0 ..< 46])
      writeFile(fx.dir / "magic.VIB", magic)
      writeFile(fx.dir / "month.VIB", month13)
      writeFile(fx.dir / "empty.VIB", "")
      for (name, words) in [("other.VIB", "a .vib file of another kind (6 values per record, 36-byte records)"),
          ("short.VIB", "could not be opened as a vibrator .vib file"),
          ("magic.VIB", "is not a SEG-Y, SEG-D or SEG-2 file"),
          ("month.VIB", "start time is not a valid date"),
          ("empty.VIB", "empty.VIB is empty: not opened.")]:
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.dir / name)
        doAssert st.settle(st.log.has(words, sevError)), name & ": " & words
        doAssert st.sessions.len == 0, name & " was shown"
      st.shutdown()

  block summaryAgentReadout:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir / "0042" / "20010203", "0007.VIB"))
      let s = st.sessions[0]
      let text = summaryText(summaryLines(s, 0))
      for part in ["vibrator controller .vib signature record",
          "2001-02-03 04:05:06 (to the second", "Trigger\tframe", "estimated from the reference",
          "baseplate weight 6000 lb", "reaction-mass weight 4000 lb",
          "set B (traces 2-4): the set the .dat file records",
          "set A (traces 5-7): the set the controller's QC report follows (probable)",
          "pound-counts", "not in a .vib file: it is in the .dat of this sweep",
          "0042 (from the folder name, not in the file)", "File counter\t7",
          "5 reaction-mass acceleration, set A (258)", "assumed"]:
        doAssert part in text, part & " is missing from:\n" & text
      for bad in ["real", "true", "measured", "simulated"]:
        for w in text.toLowerAscii.split({' ', '\n', '\t', ',', '.', ';', ':', '(', ')'}):
          doAssert w != bad, "the Summary says \"" & bad & "\""
      let sig = st.stateReport(Frontend(), """{"parts":["files"]}""").body["files"][0]["signature"]
      doAssert sig["kind"].getStr == "vib" and sig["primarySet"].getStr == "B"
      doAssert sig["trigger"]["source"].getStr == "estimated" and sig["timeZero"].getStr == "trigger"
      doAssert sig["controllerFrom"].getStr == "folder" and sig["fileCounter"].getInt == 7
      doAssert sig["traces"][4]["name"].getStr == "reaction-mass acceleration, set A"
      st.shutdown()

  block vibratorWindow:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir, "0007.VIB"))
      let base = st.sessions[0].base
      st.apply Command(kind: ckOpenPlot, plotView: avVibrator, plotTraces: @[base])
      doAssert st.settle(st.plots.len == 1 and st.plots[0].result.plots.len > 0),
        st.plots[0].result.problem
      doAssert st.plots[0].traces.len == 4, $st.plots[0].traces
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
      let note = st.plots[0].result.note
      doAssert "no typed masses are applied" in note and "baseplate 6000 lb" in note, note
      st.shutdown()

  block storeReference:
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir, "0007.VIB"))
      discard st.chooseStored(fx.dir / "refs", st.sessions[0].base, "pilot")
      let e = st.references.entries[0]
      doAssert e.intervalUs == 500 and e.origin.fileName == "0007.VIB", $e.origin
      # the whole trace, its pre-trigger included; the archive keeps a reference's samples
      # from its first one, as it does for a SEG-Y file (it holds no t0)
      doAssert e.samples == 6601 and e.origin.fromMs == 0, $(e.samples, e.origin.fromMs)
      st.shutdown()

  block segyLookalike:
    withFixtures fx:
      var b = cast[seq[byte]](readFile(vibFile(fx.dir, "plain.VIB")))
      b[3216] = 0x03 # a plausible SEG-Y binary header at byte 3200, in the frames
      b[3217] = 0xE8
      b[3221] = 100
      b[3225] = 5
      writeBytes(fx.dir / "lookalike.VIB", b)
      doAssert detectKind(b) == skSegy, "the synthetic bytes do not look like SEG-Y"
      doAssert sniff(fx.dir / "lookalike.VIB") == fkVib
      var st = initAppState(indexCache = fx.dir / "cache")
      doAssert st.openIt(fx.dir / "lookalike.VIB")
      doAssert st.sessions[0].isSignature and st.sessions[0].len == 13
      doAssert not dirExists(fx.dir / "cache") or toSeq(walkDir(fx.dir / "cache")).len == 0
      st.shutdown()

  block seismicSamplesNotClaimed:
    var n = 0
    for pattern in ["*.sgy", "*.segy", "*.sgd", "*.segd", "*.sg2"]:
      for f in walkDirRec(root / "samples", yieldFilter = {pcFile}):
        if f.extractFilename.endsWith(pattern[1 .. ^1]):
          doAssert sniff(f) notin {fkDat, fkVib}, f & " was taken for a signature file"
          inc n
    doAssert n > 0
    withFixtures fx:
      doAssert sniff(fx.surveySegy()) == fkSegy and sniff(fx.twoSetSegd()) == fkSegd

  block dateTooFar:
    withFixtures fx:
      var st = initAppState()
      for year in [2300, 9999]:
        var b = cast[seq[byte]](readFile(vibFile(fx.dir, "g.VIB")))
        b[45] = byte(year and 0xFF)
        b[46] = byte(year shr 8)
        let name = $year & ".VIB"
        writeBytes(fx.dir / name, b)
        st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.dir / name)
        doAssert st.settle(st.log.has(name & " could not be opened as a vibrator .vib file: " &
          "its start date (the year " & $year & ") is past the year 2262", sevError)), $year
        doAssert st.sessions.len == 0
      st.shutdown()

  block firstLook:
    # A signature file's traces differ in scale by orders of magnitude: each is scaled on its own
    # at first and the display header names it; a SEG-Y file keeps the defaults.
    withFixtures fx:
      var st = initAppState()
      doAssert st.openIt(vibFile(fx.dir, "0007.VIB"))
      let p = st.panel(MainPanel)
      doAssert p.layers[0].display.gain == dgNormalized, $p.layers[0].display.gain
      doAssert p.layers[0].display.overlap < 1 and p.layers[0].display.fills == {}
      doAssert p.shownFields == @[hfTraceId, hfTrace], $p.shownFields
      doAssert st.sessions[0].traceNames[4] == "mass A\treaction-mass acceleration, set A"
      doAssert headerName(st.sessions[0].traceNames[4]) == "mass A"
      doAssert fullName(st.sessions[0].traceNames[4]) == "reaction-mass acceleration, set A"
      st.apply Command(kind: ckShowFile, panel: MainPanel, path: fx.surveySegy())
      doAssert st.settle(st.shownPath == fx.surveySegy() and st.panel(MainPanel).laidOut)
      let q = st.panel(MainPanel)
      doAssert q.layers[0].display.gain == dgAuto and q.header.auto, "a SEG-Y file was changed"
      st.shutdown()

  block nothingIsWritten:
    withFixtures fx:
      let path = vibFile(fx.dir, "0009.VIB")
      let before = readFile(path)
      install()
      resetCounts()
      var st = initAppState(indexCache = fx.dir / "cache")
      doAssert st.openIt(path)
      doAssert calls(foWrite) == 0, "the open wrote: " & $calls(foWrite)
      doAssert not dirExists(fx.dir / "cache") or toSeq(walkDir(fx.dir / "cache")).len == 0
      doAssert readFile(path) == before
      doAssert st.survey.layers.len == 0
      doAssert uiCalls().len == 0, $uiCalls()
      st.shutdown()
  block shotBlock:
    # the library's shot block rides in the in-memory SEG-Y: the shipped maps decode it by name
    withFixtures fx:
      var st = initAppState()
      let path = vibFile(fx.dir / "0042" / "20010203", "0007.VIB")
      let shot = parseVib(cast[seq[byte]](readFile(path)))
      doAssert st.openIt(path)
      let maps = currentSourcePath.parentDir.parentDir / "vendormaps"
      let load = loadVendorFolders([VendorFolder(dir: maps, origin: voProgram)])
      let s = st.sessions[0]
      let shown = vendorBlocks(s.filePtr[], -1, load.registry)
      doAssert shown.blocks.len == 1 and shown.blocks[0].name == "parseSSVIBShot",
        $shown.blocks.len
      var frames = ""
      for f in shown.blocks[0].fields:
        if f.name == "frames": frames = f.value
      doAssert frames == $shot.frames, frames
      st.shutdown()
  echo "tvibopen: ok"

when isMainModule:
  main()
