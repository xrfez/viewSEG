## One rule for lengths: a length in time is N x dt. A record of 12 000 ms at 1 ms is
## 12 000 samples, the first at 0 ms and the last at 11 999 ms; the plots keep their
## 0-based axes. The reference "generate" window, the pilot cut of "use reference", the
## pilot's default length and the length words follow it, whatever the interval.
##
## Seen to fail: with `+ 1` put back in processSEG's `sweepLen` the generated reference had
## 12 001 samples ("a sweep of 12000 ms at 1 ms has 12001 samples"); with `cutPilot` keeping
## both ends of the window, 12 001 samples from a 12 000 ms length; with the pilot's default
## length (`shownLengthMs`) the last sample's time, 11 999 instead of 12 000.

import std/[os, strutils]
import viewSEG/core/[properties, references, state]
import utils/[chosenref, fixtures, waiting]

proc main*() =
  block generated_sweeps_are_n_samples:
    for (dt, want) in [(1.0, 12000), (2.0, 6000), (0.5, 24000), (0.25, 48000), (4.0, 3000)]:
      let g = GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 12000, dtMs: dt,
        taperStartMs: 100, taperEndMs: 100, amplitude: 1, taperShape: tpCos2)
      doAssert generateProblem(g) == "", $dt
      let samples = generateSamples(g)
      doAssert samples.len == want, $dt & ": " & $samples.len
      doAssert samples[0] == 0 # the first at 0 ms
    # a length that is not a whole number of intervals is refused, in the dialog's words
    let odd = GeneratedReference(law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 12000.5,
      dtMs: 1, amplitude: 1)
    doAssert "whole number of samples" in generateProblem(odd), generateProblem(odd)

  block the_generate_window_end_to_end:
    withFixtures fx:
      var st = initAppState()
      st.readyArchive(fx.dir / "refs")
      doAssert waitUntil((discard st.drainInbox(); st.referencesLoaded))
      var made = 0
      for (dt, want) in [(1.0, 12000), (2.0, 6000), (0.5, 24000)]:
        let name = "sweep " & $dt
        st.apply Command(kind: ckGenerateReference, refGenerate: GeneratedReference(name: name,
          law: rlLinear, f1Hz: 8, f2Hz: 80, durationMs: 12000, dtMs: dt, amplitude: 1))
        inc made
        doAssert waitUntil((discard st.drainInbox(); st.references.entries.len >= made)),
          "the sweep was not stored"
        for e in st.references.entries:
          if e.name == name:
            doAssert e.samples == want, name & ": " & $e.samples
            doAssert lengthText(e) == "12000 ms (" & $want & ")", lengthText(e)
            doAssert lengthSaid(st.references, e.id) == ": " & lengthWords(want, dt),
              lengthSaid(st.references, e.id)

  block the_use_reference_window_cuts_the_typed_length:
    for (dt, total, want) in [(1.0, 14000, 12000), (2.0, 7000, 6000), (0.5, 28000, 24000)]:
      var s = newSeq[float32](total)
      for i in 0 ..< s.len: s[i] = float32(i)
      let cut = cutPilot(s, dt, PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 12000), "FFID 1")
      doAssert cut.problem == "" and cut.samples.len == want, $dt & ": " & $cut.samples.len
      doAssert cut.samples[0] == 0 and cut.samples[^1] == float32(want - 1)
    var s = newSeq[float32](14000)
    for i in 0 ..< s.len: s[i] = float32(i)
    # from 1000 ms: 12 000 samples starting at sample 1000
    let late = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 1000, spanMs: 12000), "r")
    doAssert late.samples.len == 12000 and late.samples[0] == 1000 and late.samples[^1] == 12999
    # past the trace's end: clipped
    let clipped = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 5000, spanMs: 12000), "r")
    doAssert clipped.samples.len == 9000 and clipped.samples[^1] == 13999
    # not a whole number of intervals: cut down to whole samples
    let odd = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 12000.9), "r")
    doAssert odd.samples.len == 12000
    let odd2 = cutPilot(s, 2.0, PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 11999), "r")
    doAssert odd2.samples.len == 5999
    # under one interval: nothing, and the problem says why
    let tiny = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 0.4), "r")
    doAssert tiny.samples.len == 0 and "under one sample" in tiny.problem, tiny.problem

  block names_and_tips_say_a_length:
    doAssert defaultPilotName(PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 12000)) ==
      "Pilot: aux 1, 12000 ms from 0 ms"
    let tip = lengthTip(12000, 1, true)
    doAssert "Now: 12 000 samples at 1 ms, the last at 11 999 ms." in tip, tip
    doAssert "must be a whole number of intervals" in tip
    doAssert "cut down to whole samples" in lengthTip(12000.9, 1, false)
    doAssert "Now:" notin lengthTip(0, 1, true)
    doAssert lengthWords(12000, 1) == "12 000 samples at 1 ms = 12 000 ms (12 s)"

  block rules_saved_by_an_earlier_version:
    # The old default length was the last sample's time: 11 999 ms on 12 000 samples at 1 ms.
    # It still means the whole trace. A shorter length is what it says.
    var s = newSeq[float32](12000)
    for i in 0 ..< s.len: s[i] = float32(i)
    let old = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 11999), "r")
    doAssert old.samples.len == 12000 and old.samples[^1] == 11999'f32, $old.samples.len
    let shorter = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 0, spanMs: 11998), "r")
    doAssert shorter.samples.len == 11998
    let late = cutPilot(s, 1.0, PilotRule(aux: true, trace: 1, startMs: 100, spanMs: 11899), "r")
    doAssert late.samples.len == 11900 and late.samples[0] == 100
    # a sweep stored by an earlier version (12 001 samples) does not contradict itself
    var e = ReferenceEntry(samples: 12001, intervalUs: 1000)
    e.origin = ReferenceOrigin(generated: true, durationMs: 12000)
    doAssert lengthText(e) == "12001 ms (12001)", lengthText(e)

  block places_and_store_ends:
    # a start between samples takes the nearest one, in the cut and in its place in time
    doAssert pilotStartIndex(0.3, 1) == 0 and pilotStartIndex(0.7, 1) == 1
    doAssert placedPilot(@[1'f32, 2], 0.3, 1).len == 2
    doAssert placedPilot(@[1'f32, 2], 0.7, 1) == @[0'f32, 1, 2]
    # the store dialog's To for a header sweep: the last sample of N x dt samples
    doAssert sweepStoreToMs(12000, 1) == 11999 and sweepStoreToMs(12000, 2) == 11998
    doAssert sweepStoreToMs(12001, 2) == 11998, "more than the header's 12 001 ms"
    doAssert sweepStoreToMs(0.5, 1) == 0

  block properties_say_the_trace_length:
    let t = traceLengthText(4001, 1000)
    doAssert "x 1 ms = 4001 ms (last sample at 4000 ms)" in t.replace(" 0", "0"), t
    doAssert traceLengthText(0, 1000) == "" and traceLengthText(10, NaN) == ""

when isMainModule: main()
