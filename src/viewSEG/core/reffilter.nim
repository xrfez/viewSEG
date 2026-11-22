## The recording filter of a generated reference: what the user types in the
## Generate dialog's "Recording filter" section, and the plain-words checks
## around it. The maths is processSEG's (`vibroseis/recfilter`).
##
## Every parameter is typed: nothing is read from a file's headers. The
## default kind is `rfNone`, which leaves the sweep exactly as it was. A
## filter and its shift exist only here: a reference stored from a record
## is never filtered or shifted (the recorder did that).

import std/[math, parseutils, strutils]
import processSEG/vibroseis/recfilter
import processSEG/vibroseis/pilot

type
  RefFilterKind* = enum
    rfNone = "none"
    rfLinear = "linear phase"
    rfMinimum = "minimum phase"

  RefFilterFamily* = enum
    rfButterworth = "Butterworth"
    rfChebyshev = "Chebyshev"

  RefFilter* = object
    ## A recording filter, as typed. Cutoffs of 0 Hz are off.
    kind*: RefFilterKind
    taps*: int                        ## linear phase: the number of coefficients
    highCutHz*, highSlopeDb*: float64 ## linear phase: cutoff and roll-off (dB/octave)
    lowCutHz*, lowSlopeDb*: float64
    coefficients*: seq[float64]
      ## the filter's coefficients (taps), either kind; empty: design it (taps and
      ## cutoffs for linear phase, the family for minimum phase)
    family*: RefFilterFamily ## minimum phase, without coefficients
    highOrder*, lowOrder*: int ## the family's poles per cut; its cutoffs are the Hz above
    rippleDb*: float64 ## Chebyshev: passband ripple
    shiftSamples*: int
      ## the bulk delay to back out, in whole samples (negative: later). Used when
      ## `shiftTyped`; else linear phase uses (taps - 1) / 2, a minimum-phase filter 0
    shiftTyped*: bool

const
  RefFilterKinds* = [rfNone, rfLinear, rfMinimum]

func filterOn*(f: RefFilter): bool {.inline.} =
  f.kind != rfNone

func tapCount*(f: RefFilter): int {.inline.} =
  ## The number of coefficients: the typed ones, else the designed filter's `taps`.
  if f.coefficients.len > 0: f.coefficients.len else: f.taps

func effectiveShift*(f: RefFilter): int =
  ## The whole samples the shift moves: the typed number, or for linear phase
  ## (taps - 1) / 2 rounded down (an even tap count leaves half a sample), or 0.
  if f.kind == rfNone: 0
  elif f.shiftTyped: f.shiftSamples
  elif f.kind == rfLinear: linearShiftSamples(tapCount(f))
  else: 0

func recordingFilter*(f: RefFilter): RecordingFilter =
  ## The processSEG filter `f` names.
  if f.kind == rfNone: return RecordingFilter()
  result = RecordingFilter(highCutHz: f.highCutHz, lowCutHz: f.lowCutHz,
    coefficients: f.coefficients, shiftSamples: effectiveShift(f))
  case f.kind
  of rfLinear:
    result.kind = rfkLinearPhase
    result.taps = f.taps
    result.highSlopeDbPerOctave = f.highSlopeDb
    result.lowSlopeDbPerOctave = f.lowSlopeDb
  of rfMinimum:
    result.kind = rfkMinimumPhase
    result.family = if f.family == rfChebyshev: rffChebyshev else: rffButterworth
    result.highOrder = f.highOrder
    result.lowOrder = f.lowOrder
    result.rippleDb = f.rippleDb
  of rfNone: discard

func numberWords(x: float64): string =
  if x.isNaN: "?"
  elif abs(x - round(x)) < 1e-6 and abs(x) < 1e9: $int(round(x))
  else:
    var s = formatFloat(x, ffDecimal, 3)
    while s.len > 1 and s[^1] == '0': s.setLen s.len - 1
    if s[^1] == '.': s.setLen s.len - 1
    s

func filterKey*(f: RefFilter): string =
  ## The filter's part of a preview's settings key.
  if f.kind == rfNone: return "nofilter"
  result = $f.kind & " " & $f.taps & " " & $f.highCutHz & " " & $f.highSlopeDb & " " &
    $f.lowCutHz & " " & $f.lowSlopeDb & " " & $f.family & " " & $f.highOrder & " " &
    $f.lowOrder & " " & $f.rippleDb & " " & $effectiveShift(f) & " " & $f.coefficients.len
  var h = 0'u64 # the coefficients' values, folded
  for c in f.coefficients: h = h * 1099511628211'u64 + cast[uint64](c)
  result.add " " & $h

func filterNameSuffix*(f: RefFilter): string =
  ## ", 207 Hz min. phase, shift 1": appended to a default name; "" for none.
  case f.kind
  of rfNone: ""
  of rfLinear:
    ", " & $tapCount(f) & "-tap linear phase" &
      (if f.coefficients.len == 0 and f.highCutHz > 0: ", " & numberWords(f.highCutHz) & " Hz"
        else: "") &
      ", shift " & $effectiveShift(f)
  of rfMinimum:
    if f.coefficients.len > 0:
      ", " & $f.coefficients.len & "-tap min. phase, shift " & $effectiveShift(f)
    else:
      (if f.highCutHz > 0: ", " & numberWords(f.highCutHz) & " Hz min. phase" else:
        ", min. phase") & ", shift " & $effectiveShift(f)

func filterWords*(f: RefFilter): string =
  ## The filter in a sentence, for the explain text; "" for none.
  case f.kind
  of rfNone: ""
  of rfLinear:
    "Recording filter: linear phase, " & $tapCount(f) & " taps" &
      (if f.coefficients.len > 0: " (typed)" else: "") &
      (if f.coefficients.len == 0 and f.highCutHz > 0: ", high-cut " & numberWords(f.highCutHz) &
          " Hz at " &
        numberWords(f.highSlopeDb) & " dB/octave" else: "") &
      (if f.coefficients.len == 0 and f.lowCutHz > 0: ", low-cut " & numberWords(f.lowCutHz) &
        " Hz at " & numberWords(f.lowSlopeDb) & " dB/octave" else: "") &
      "; the delay of " & $effectiveShift(f) & " samples is backed out."
  of rfMinimum:
    if f.coefficients.len > 0:
      "Recording filter: minimum phase, " & $f.coefficients.len & " typed coefficients; " &
        "the delay of " & $effectiveShift(f) & " samples is backed out."
    else:
      "Recording filter: minimum phase " & $f.family &
        (if f.highCutHz > 0: ", high-cut " & numberWords(f.highCutHz) & " Hz, " &
          $f.highOrder & " poles" else: "") &
        (if f.lowCutHz > 0: ", low-cut " & numberWords(f.lowCutHz) & " Hz, " &
          $f.lowOrder & " poles" else: "") &
        (if f.family == rfChebyshev: ", " & numberWords(f.rippleDb) & " dB ripple" else: "") &
        "; the delay of " & $effectiveShift(f) & " samples is backed out."

func evenTapsNote*(f: RefFilter): string =
  ## Said beside a linear-phase filter with an even tap count: its delay is
  ## half a sample, which a whole-sample shift cannot back out.
  let n = tapCount(f)
  if f.kind == rfLinear and n >= 2 and n mod 2 == 0:
    "An even number of taps delays by " & numberWords(float64(n - 1) / 2) &
      " samples; the shift backs out " & $((n - 1) div 2) &
      ", so half a sample of delay is left."
  else: ""

func symmetryNote*(f: RefFilter): string =
  ## Said when typed linear-phase coefficients are not symmetric: the filter is
  ## then not linear phase and (taps - 1) / 2 is not its delay.
  if f.kind == rfLinear and f.coefficients.len > 1 and not coefficientsSymmetric(f.coefficients):
    "These coefficients are not symmetric, so the filter is not linear phase: " &
      "(taps - 1) / 2 is not its delay. Type the delay yourself."
  else: ""

func lowCutNote*(f: RefFilter; dtMs: float64): string =
  ## Said when a designed linear-phase filter has too few taps for its low-cut.
  if f.kind != rfLinear or f.coefficients.len > 0 or f.lowCutHz <= 0 or f.taps < 3 or
      not (dtMs > 0 and dtMs < Inf): return ""
  let lowest = 2 * (1000 / dtMs) / float64(f.taps)
  if f.lowCutHz < lowest:
    $f.taps & " taps cannot make a low-cut as low as " & numberWords(f.lowCutHz) &
      " Hz: with this sample interval the lowest is about " & numberWords(lowest) &
      " Hz (twice the sampling rate over the taps). Use more taps."
  else: ""

func plainFilterMessage(msg: string): string =
  msg.replace("shiftSamples", "the delay")

proc filterProblem*(f: RefFilter; dtMs: float64; samples: int): string =
  ## Why the filter cannot be applied to a sweep of `samples` samples at
  ## `dtMs`, in plain words; "" when it can (and for none).
  if f.kind == rfNone: return ""
  if not (dtMs > 0 and dtMs < Inf): return ""
  try:
    f.recordingFilter.checkFilter(dtMs, samples)
    ""
  except CatchableError as e:
    plainFilterMessage(e.msg)

proc topWarning*(f: RefFilter; topHz: float64): string =
  ## A warning (not a refusal): the sweep's top frequency within 0.8 of the
  ## filter's high-cut, where its phase changes fast.
  if f.kind == rfNone or f.coefficients.len > 0 or f.highCutHz <= 0: return ""
  if topHz > 0.8 * f.highCutHz:
    "The sweep's top frequency, " & numberWords(topHz) & " Hz, is above 0.8 of the high-cut: " &
      "the filter's phase changes fast there, so its delay must be exact."
  else: ""

proc suggestedDelay*(f: RefFilter; dtMs, f1Hz, f2Hz: float64): float64 =
  ## The filter's bulk delay in samples over the sweep's band (a suggestion
  ## beside the delay field); NaN for none or when it cannot be worked out.
  if f.kind == rfNone: return NaN
  try:
    let lo = max(min(f1Hz, f2Hz), 0.1)
    let hi = min(max(f1Hz, f2Hz), 500 / dtMs * 0.999)
    if f.kind == rfLinear: return linearDelaySamples(tapCount(f))
    f.recordingFilter.bulkDelaySamples(dtMs, lo, hi)
  except CatchableError: NaN

proc filteredSamples*(samples: seq[float32]; dtMs: float64; f: RefFilter): seq[float32]
    {.gcsafe.} =
  ## `samples` through the filter and shift, from rest, the same length.
  ## Raises `ValueError` as processSEG's `checkFilter`. None: `samples` as they are.
  if f.kind == rfNone: return samples
  let p = initPilot(samples, dtMs)
  p.applyRecordingFilter(f.recordingFilter).samples

proc parseCoefficients*(text: string): tuple[taps: seq[float64]; problem: string] =
  ## The numbers of a pasted or loaded list: one per line, or separated by
  ## spaces, commas or semicolons. A line's text after `#` is a comment. The
  ## first thing that is not a number is named, and no taps are returned.
  result.taps = @[]
  var line = 0
  for raw in text.splitLines:
    inc line
    var s = raw
    let hash = s.find('#')
    if hash >= 0: s.setLen hash
    for word in s.split({' ', '\t', ',', ';', '\r'}):
      if word.len == 0: continue
      var v = 0.0
      var ok = false
      try:
        let used = parseFloat(word, v)
        ok = used == word.len and v == v and abs(v) < Inf
      except ValueError: discard
      if not ok:
        result.taps.setLen 0
        result.problem = "line " & $line & ": \"" & word.substr(0, 30) & "\" is not a number"
        return
      result.taps.add v
      if result.taps.len > maxCoefficients:
        result.taps.setLen 0
        result.problem = "more than " & $maxCoefficients & " coefficients"
        return

func coefficientsText*(taps: seq[float64]): string =
  ## The numbers as one line, each exactly (it is read back by `parseCoefficients`).
  result = ""
  for i, c in taps:
    if i > 0: result.add ' '
    result.add $c
