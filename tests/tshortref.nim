## A trace that cannot be matched to the whole of its reference, in the three windows that
## compare a trace with one: Vibrator signature (`vibratorOf`), Cross-correlation
## (`correlationOf`) and Envelope (`envelopeOf`), on synthetic 8 to 80 Hz sweeps of 12 s
## at 2 ms with 300 ms tapers:
##
## - the trace is 9 840 ms, the reference 12 000 ms: the warning's first line says
##   "trace is 9 840 ms, the reference is 12 000 ms: the last 2 160 ms of the reference
##   have no data" (in the Vibrator signature, where the reference is a row of the same
##   kind, too);
## - the trace is as long as the reference but its signal stops at 7 600 ms: "signal ends
##   at about 7 6xx ms; the reference runs to 12 000 ms" (the tracker's own end of the
##   force's fundamental, in the Vibrator signature);
## - a trace of 100 ms lead-in, the sweep and two seconds of quiet, longer than the
##   reference, and one that is just the reference: no warning;
## - `spaced` writes the times as the words do.
##
## Seen to fail: with `shortWords` returning "", the first block failed ("vibrator: ");
## with `endWords` taking every end as no stop (`endMs >= 0`), the second block failed
## ("vibrator: ").

import std/[math, strutils]
import viewSEG/core/[analysis, signalend, vibanalysis]

const
  Dt = 2.0
  SweepMs = 12000.0

proc sweep(ms: float64; leadMs = 0.0; tailMs = 0.0; stopAtMs = Inf): seq[float32] =
  ## 8 to 80 Hz over `ms`, 300 ms cos² tapers, after `leadMs` of quiet and followed by `tailMs`;
  ## silent from `stopAtMs` on (counted from the start of the record).
  let n = int(ms / Dt)
  let lead = int(leadMs / Dt)
  result = newSeq[float32](lead + n + int(tailMs / Dt))
  for i in 0 ..< n:
    let t = float64(i) * Dt / 1000
    let total = ms / 1000
    let phase = 2 * PI * (8 * t + 0.5 * (72 / total) * t * t)
    let edge = min(float64(i) * Dt, ms - float64(i) * Dt)
    let w = if edge >= 300: 1.0 else: sin(PI / 2 * edge / 300) ^ 2
    if float64(lead + i) * Dt < stopAtMs: result[lead + i] = float32(w * sin(phase))

proc aboutMs(text: string): float64 =
  ## The number after "signal ends at about " (spaces in it are thousands).
  let at = text.find("signal ends at about ")
  doAssert at >= 0, text
  var digits = ""
  for c in text[at + 21 .. ^1]:
    if c in {'0' .. '9', '.'}: digits.add c
    elif c == ' ' and digits.len > 0 and digits.len < 5: continue
    else: break
  parseFloat(digits)

proc roles(): array[VibRole, int] = [vsReference: 0, vsGroundForce: 1, vsMass: -1, vsBaseplate: -1]

proc vibrator(trace, reference: seq[float32]): AnalysisResult =
  vibratorOf(@[reference, trace], @["Ref", "GF"], roles(), Dt, AnalysisParams())

proc correlation(trace, reference: seq[float32]): AnalysisResult =
  correlationOf([("GF", trace)], reference, "the reference", Dt, AnalysisParams())

proc envelope(trace, reference: seq[float32]): AnalysisResult =
  envelopeOf(trace, "GF", Dt, 0.0, AnalysisParams(), reference, "the reference")

proc main*() =
  doAssert spaced(12000) == "12 000" and spaced(9840) == "9 840" and spaced(2160) == "2 160"
  doAssert spaced(120) == "120" and spaced(9840.5) == "9 840.5" and spaced(1234567) == "1 234 567"
  let reference = sweep(SweepMs)

  block traceShorterThanTheReference:
    let trace = sweep(SweepMs)[0 ..< 4920] # 9 840 ms
    let line = "trace is 9 840 ms, the reference is 12 000 ms: the last 2 160 ms of the " &
      "reference have no data"
    for (view, r) in [("vibrator", vibrator(trace, reference)),
        ("correlation", correlation(trace, reference)),
        ("envelope", envelope(trace, reference))]:
      doAssert r.problem == "", view & ": " & r.problem
      doAssert r.warning.splitLines[0] == line, view & ": " & r.warning

  block signalStopsEarly:
    let trace = sweep(SweepMs, stopAtMs = 7600)
    for (view, r) in [("vibrator", vibrator(trace, reference)),
        ("correlation", correlation(trace, reference)),
        ("envelope", envelope(trace, reference))]:
      doAssert r.problem == "", view & ": " & r.problem
      doAssert "the reference runs to 1" in r.warning, view & ": " & r.warning
      doAssert "trace is" notin r.warning, view & ": a whole-length trace is not short"
      let ends = r.warning.aboutMs
      doAssert ends in 7500.0 .. 7900.0, view & ": the signal ends at about " & $ends

  block aLeadInAndAQuietTail:
    # longer than the reference by a lead-in and a tail: neither short nor stopped early
    let trace = sweep(SweepMs, leadMs = 100, tailMs = 2000)
    for (view, r) in [("correlation", correlation(trace, reference)),
        ("envelope", envelope(trace, reference))]:
      doAssert r.problem == "", view & ": " & r.problem
      doAssert r.warning == "", view & ": " & r.warning
    let same = [("correlation", correlation(reference, reference)),
      ("envelope", envelope(reference, reference))]
    for (view, r) in same: doAssert r.warning == "", view & ": " & r.warning

  echo "tshortref: ok"

when isMainModule:
  main()
