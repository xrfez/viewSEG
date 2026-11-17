## A preview asked again under the same generation number: the result shown
## is the latest ask, not the one already computed.
##
## Seen to fail: with the worker accepting a result whenever the generation
## number matches, a second ask of generation 1 was never computed.

import std/[os, times]
import viewSEG/core/references
import viewSEG/ui/imgui/genpreview

proc waitPreview(): tuple[samples: seq[float32]; key: string] =
  let deadline = getTime() + initDuration(seconds = 5)
  while getTime() < deadline:
    let ready = takeGeneratePreview()
    if ready.got and ready.samples.len > 0: return (ready.samples, ready.key)
    sleep 5

proc main*() =
  let first = GeneratedReference(law: rlExponential, f1Hz: 8, f2Hz: 80,
    durationMs: 1000, dtMs: 2, taperStartMs: 0, taperEndMs: 0, amplitude: 1,
    taperShape: tpCos2)
  let second = GeneratedReference(law: rlLinear, f1Hz: 12, f2Hz: 36,
    durationMs: 500, dtMs: 2, taperStartMs: 0, taperEndMs: 0, amplitude: 1,
    taperShape: tpLinear)
  let want = generateSamples(second)
  block a_reused_generation_shows_the_latest:
    try:
      askGeneratePreview(1, first)
      let got = waitPreview()
      doAssert got.samples.len > 0, "the first preview never arrived"
      askGeneratePreview(1, second)
      let shown = waitPreview()
      doAssert shown.samples.len > 0, "a second ask with the same generation was dropped"
      doAssert shown.samples == want, "the result is not the latest ask"
      doAssert shown.key == generateSettingsKey(second), shown.key
      doAssert shown.key != generateSettingsKey(first)
    finally:
      stopGeneratePreview()
  block an_in_flight_ask_drops_the_old_sweep:
    let slow = GeneratedReference(law: rlExponential, f1Hz: 8, f2Hz: 80,
      durationMs: 60_000, dtMs: 0.5, taperStartMs: 200, taperEndMs: 200,
      amplitude: 1, taperShape: tpCos2)
    let wantKey = generateSettingsKey(second)
    try:
      askGeneratePreview(1, slow)
      sleep 15
      askGeneratePreview(1, second)
      var shown: seq[float32] = @[]
      let deadline = getTime() + initDuration(seconds = 8)
      while getTime() < deadline:
        let ready = takeGeneratePreview()
        if ready.got and ready.key == wantKey:
          shown = ready.samples
          break
        sleep 5
      doAssert shown == want, "an in-flight ask kept the old sweep"
    finally:
      stopGeneratePreview()
  echo "tgenpreview: ok"

when isMainModule: main()
