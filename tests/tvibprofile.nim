## The job's vibrator QC profile (`core/vibprofile`, stored on the project):
##
## - `profileOf` takes the window's settings as parameters and keeps none of a
##   file's own facts (no controller, serial, header weight, polarity, fitted
##   top, alignment, residual, `swapForces` or `fromFirstFrame`);
## - `applied` gives those settings back for a QC run on another file, and names
##   a missing reference and a missing 100 % force instead of failing;
## - the project document keeps one profile beside the other vibrator fields, an
##   older document has none, and a field this version does not know is kept;
## - the job's hold-down, baseplate and reaction mass are stored once, in
##   kilograms, and are not read from a file header.
##
## Seen to fail: with `applied` not naming a reference absent from the archive,
## `gone.problems.len == 1`; with the job's weights left out of the document,
## `"(vibWeights" in text`. With the typed force's unit left out of the
## document, `unit` does not find `(forceHundredUnit "counts")`.
##
## What is kept: `vibProfile` on the project (`hasVibProfile` when one was stored);
## `vibWeights` for the job's weights (`jobWeights`).

import std/[math, strutils]
import viewSEG/core/[analysis, nif, project, projectnif, settings, vibprofile]

proc roundTrip(d: ProjectDoc): ProjectDoc =
  var problems: seq[string]
  result = readProject(projectDocument(d), "project.nif", problems)
  doAssert problems.len == 0, $problems

proc main*() =

  block taken:
    let limits = QcLimits(avgPhaseDeg: 4, peakPhaseDeg: 8, avgDistortionPct: 12,
      peakDistortionPct: 20, avgForcePct: 70, peakForcePct: NaN)
    let scale = ForceScale(datCountsPerLbf: 12.5)
    let p = profileOf(limits, 250.0, 7, asA, scale, 40000.0, 80.0, "r1763200961-2", 88.0)
    doAssert p.limits.avgPhaseDeg == 4 and p.limits.peakForcePct.isNaN
    doAssert p.qcWindowMs == 250 and p.harmonics == 7 and p.accelSet == asA
    doAssert p.forceScale.datCountsPerLbf == 12.5 and p.forceScale.vibAccMvPerCount.isNaN
    doAssert p.forceHundredPct == 40000 and p.targetPct == 80
    doAssert p.forceHundredUnit.len == 0
    doAssert p.referenceId == "r1763200961-2" and p.topHz == 88
    doAssert compiles(VibQcProfile(harmonics: 5))
    doAssert not compiles(VibQcProfile(swapForces: true))
    doAssert not compiles(VibQcProfile(fromFirstFrame: true))
    doAssert not compiles(VibQcProfile(controller: 1))
    doAssert not compiles(VibQcProfile(serial: "x"))
    doAssert not compiles(VibQcProfile(holdDownLb: 1.0))
    doAssert not compiles(VibQcProfile(holdDownKg: 1.0))
    doAssert not compiles(VibQcProfile(polarity: 1))
    doAssert not compiles(VibQcProfile(fittedTop: 1.0))
    doAssert not compiles(VibQcProfile(alignment: 1))
    doAssert not compiles(VibQcProfile(residual: 1.0))
    for name, _ in fieldPairs(p):
      doAssert name notin ["swapForces", "fromFirstFrame", "controller", "serial",
        "holdDownLb", "holdDownKg", "reactionMassKg", "baseplateMassKg", "polarity",
        "fittedTop", "alignment", "residual"], name

  block apply:
    let limits = QcLimits(avgPhaseDeg: 3, peakPhaseDeg: NaN, avgDistortionPct: 11,
      peakDistortionPct: 22, avgForcePct: 75, peakForcePct: 110)
    let scale = ForceScale(vibAccMvPerCount: 2.5)
    let p = profileOf(limits, 400.0, 4, asB, scale, 18000.0, NaN, "r1", 60.0)
    let ask = applied(p, ["r0", "r1"])
    doAssert ask.problems.len == 0, $ask.problems
    let back = profileOf(ask.options.qc, ask.options.qcWindowMs, ask.options.harmonics,
      ask.accelSet, ask.forceScale, ask.options.forceHundredPct, ask.options.targetPct,
      ask.referenceId, ask.topHz, ask.forceHundredUnit)
    doAssert back == p
    doAssert ask.options.reactionMassKg.isNaN and ask.options.baseplateMassKg.isNaN
    let gone = applied(p, ["r0"])
    doAssert gone.problems.len == 1
    doAssert "not in the archive" in gone.problems[0], gone.problems[0]
    doAssert "r1" in gone.problems[0]
    let none = applied(profileOf(limits, 400.0, 4, asB, scale, NaN, 90.0, "", NaN), ["r1"])
    doAssert none.problems.len == 2, $none.problems
    doAssert "not in the archive" in none.problems[0]
    doAssert none.problems[1] == ForceNotJudged
    doAssert none.options.forceHundredPct.isNaN
    doAssert none.options.qc.avgPhaseDeg == 3 and none.options.qc.peakForcePct == 110
    doAssert none.options.qc.peakPhaseDeg.isNaN
    let both = applied(profileOf(limits, 400.0, 4, asB, scale, 0.0, NaN, "missing", NaN), [])
    doAssert both.problems.len == 2
    doAssert "not in the archive" in both.problems[0]
    doAssert both.problems[1] == ForceNotJudged

  block document:
    let limits = QcLimits(avgPhaseDeg: 4, peakPhaseDeg: 9, avgDistortionPct: 15,
      peakDistortionPct: 40, avgForcePct: 80, peakForcePct: NaN)
    let p = profileOf(limits, 250.0, 6, asA, ForceScale(datCountsPerLbf: 9.0), NaN, 70.0,
      "r1763200961-2", 88.0)
    var d = ProjectDoc(name: "Land 2026", hasVibProfile: true, vibProfile: p)
    d.vibTops = @["88.0 r1763200961-2"]
    let text = projectDocument(d)
    doAssert "(vibProfile" in text and "(referenceId \"r1763200961-2\")" in text, text
    doAssert "(topHz 88.0)" in text and "(accelSet A)" in text and "(harmonics 6)" in text
    doAssert "forceHundredPct" notin text and "forceHundredUnit" notin text
    doAssert "peakForcePct" notin text
    doAssert "(avgPhaseDeg 4.0)" in text and "(datCountsPerLbf 9.0)" in text
    doAssert "vibAccMvPerCount" notin text
    let back = roundTrip(d)
    doAssert back.hasVibProfile and back.vibProfile == p, $back.vibProfile
    doAssert back.vibTops == d.vibTops
    var old: seq[string]
    let bare = readProject(projectDocument(ProjectDoc(name: "old")), "project.nif", old)
    doAssert old.len == 0 and not bare.hasVibProfile
    let injected = text.replace("(vibProfile", "(vibProfile (futureNote 1)")
    var problems: seq[string]
    let kept = readProject(injected, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert kept.vibProfile.later.len == 1 and kept.vibProfile.later[0].tag == "futureNote"
    doAssert "futureNote" in projectDocument(kept)
    let sibling = text.replace("(version 1)", "(version 1)\n (picks (file \"x\"))")
    let side = readProject(sibling, "project.nif", problems)
    doAssert side.later.len == 1 and side.later[0].tag == "picks"
    doAssert side.hasVibProfile and side.vibProfile == p
    let bad = text.replace("(harmonics 6)", "(harmonics 99)")
    let refused = readProject(bad, "project.nif", problems)
    doAssert problems.len > 0
    doAssert refused.hasVibProfile and refused.vibProfile.harmonics == 5

  block unit:
    let limits = QcLimits()
    let p = profileOf(limits, 500.0, 5, asB, ForceScale(datCountsPerLbf: 8.0), 1000.0,
      NaN, "", NaN, "counts")
    doAssert p.forceHundredUnit == "counts"
    let ask = applied(p, [])
    doAssert ask.forceHundredUnit == "counts"
    doAssert ask.problems.len == 1 and ask.problems[0] == "The reference is not in the archive."
    var d = ProjectDoc(name: "Land 2026", hasVibProfile: true, vibProfile: p)
    let text = projectDocument(d)
    doAssert "(forceHundredUnit \"counts\")" in text, text
    doAssert "(forceHundredPct 1000.0)" in text
    let back = roundTrip(d)
    doAssert back.vibProfile.forceHundredUnit == "counts"
    doAssert back.vibProfile == p
    let older = text.replace(" (forceHundredUnit \"counts\")", "")
    var problems: seq[string]
    let read = readProject(older, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert read.vibProfile.forceHundredUnit.len == 0
    doAssert read.hasVibProfile

  block weights:
    var d = ProjectDoc(name: "Land 2026")
    d.jobWeights = VibJobWeights(holdDownKg: 1200.0, baseplateMassKg: 1800.0,
      reactionMassKg: NaN)
    doAssert d.jobWeights.weightsSet
    doAssert not VibJobWeights().weightsSet
    let text = projectDocument(d)
    doAssert "(vibWeights" in text and "(holdDownKg 1200.0)" in text, text
    doAssert "(baseplateMassKg 1800.0)" in text and "reactionMassKg" notin text
    doAssert "holdDownLb" notin text
    let back = roundTrip(d)
    doAssert back.jobWeights == d.jobWeights
    doAssert back.jobWeights.reactionMassKg.isNaN
    var problems: seq[string]
    let none = readProject(projectDocument(ProjectDoc(name: "old")), "project.nif", problems)
    doAssert problems.len == 0 and not none.jobWeights.weightsSet
    let injected = text.replace("(vibWeights", "(vibWeights (futureMass 1)")
    let kept = readProject(injected, "project.nif", problems)
    doAssert problems.len == 0, $problems
    doAssert kept.jobWeights.later.len == 1 and kept.jobWeights.later[0].tag == "futureMass"
    doAssert kept.jobWeights.holdDownKg == 1200
    doAssert "futureMass" in projectDocument(kept)
    let bad = text.replace("(holdDownKg 1200.0)", "(holdDownKg 0)")
    let refused = readProject(bad, "project.nif", problems)
    doAssert problems.len > 0
    doAssert refused.jobWeights.holdDownKg.isNaN
    doAssert refused.jobWeights.baseplateMassKg == 1800

  echo "tvibprofile: done"

when isMainModule:
  main()
