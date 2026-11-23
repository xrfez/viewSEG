## A fingerprint of a first-break result, for tests that say two ways of picking one record
## gave the same answer: a hash over the bits of every number and the words the result holds.

import std/math
import processSEG/qc/shotfit
import viewSEG/core/[breakrule, firstbreaks]

type Print* = object
  ## A running FNV-1a hash.
  h*: uint64

proc add(p: var Print; v: uint64) =
  var x = v
  for _ in 0 ..< 8:
    p.h = (p.h xor (x and 0xff)) * 0x100000001b3'u64
    x = x shr 8

proc add(p: var Print; v: float64) = p.add cast[uint64](v)
proc add(p: var Print; v: int) = p.add cast[uint64](int64(v))
proc add(p: var Print; v: bool) = p.add (if v: 1 else: 0)
proc add(p: var Print; s: string) =
  p.add s.len
  for c in s: p.add int(c)
proc add(p: var Print; xs: openArray[float64]) =
  p.add xs.len
  for x in xs: p.add x
proc add(p: var Print; xs: openArray[bool]) =
  p.add xs.len
  for x in xs: p.add x

proc fingerprint*(b: FirstBreaks): uint64 =
  ## Every number and word of `b` that picking, fitting and the rule decide.
  var p = Print(h: 0xcbf29ce484222325'u64)
  p.add int(b.state)
  p.add b.why
  for xs in [b.pickMs, b.modelMs, b.confidence, b.shiftMs, b.offsetAbs, b.geometry.azimuth,
      b.geometry.offsetAbs, b.geometry.firstMs, b.geometry.firstConf, b.fit.modelMs]:
    p.add xs
  p.add b.flagged
  p.add b.geometry.eligible
  p.add b.geometry.lines.len
  for l in b.geometry.lines:
    p.add l.len
    for i in l: p.add i
  for x in [b.dtMs, b.thresholdMs, b.highCutHz, b.pickWindowMs, b.geometry.rangeMax,
      b.geometry.ownSigmaMs, b.fit.interceptMs, b.fit.v1, b.fit.v2, b.fit.crossover,
      b.rule.limitMs, b.rule.sigmaMs, b.rule.misfitSigmaMs, b.rule.medianMs,
      b.rule.constantMs, b.rule.leanMs, b.rule.earlyTowardDeg]:
    p.add x
  for n in [int(b.source), b.used, b.modelled, b.picked, b.geometry.ownComparable,
      b.fit.used, int(b.pickedOn), b.compared, b.offModel, b.rule.nComparable,
      b.rule.nNoBreak, b.rule.nBeyond, b.rule.nFarOff, b.rule.nOffModel,
      b.rule.nOffNeighbours, b.rule.nFlagged, b.rule.nInRange]:
    p.add n
  p.add b.hasFit
  p.add b.twoPass
  p.add b.rule.mismatch
  p.add b.fittedFrom
  p.add b.pickNote
  p.add b.passNote
  p.add b.statusWords
  p.add b.picks.len
  for k in b.picks:
    p.add k.timeMs
    p.add k.confidence
    p.add k.snrDb
    p.add k.col
  for xs in [b.rule.comparable, b.rule.noBreak, b.rule.beyond, b.rule.farOff, b.rule.offModel,
      b.rule.offNeighbours, b.rule.flagged]:
    p.add xs
  p.h
