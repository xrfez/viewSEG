## Physical units: the exact factors, a value typed in pounds read back as
## typed, the mass range and the notes and axis labels in both systems, and
## an f-k velocity that follows the file when the file names a length.
##
## Seen to fail: with `KgPerLb` set to 0.45, `factors` found
## "1 lb is 0.45 kg"; with `sensible` printing the raw float, `roundTrip`
## found "3968.320000001"; with the imperial note left in kilograms,
## `notes` found "2450 kg·M". With `massBoxValue` returning the raw conversion,
## `massBox` found 7936.658599999999 where the box shows 7936.6. With `massTyped` storing the
## number the box showed, `massTyped` found 3600 kg moved after the unit was switched.

import std/[math, strutils]
import viewSEG/core/[analysis, units]
import viewSEG/authorship
import viewSEG/view/[analysisview, theme]

proc main*() =

  block factors:
    doAssert KgPerLb == 0.45359237, "1 lb is " & $KgPerLb & " kg"
    doAssert MPerFt == 0.3048, "1 ft is " & $MPerFt & " m"
    doAssert NPerLbf == 4.4482216152605, "1 lbf is " & $NPerLbf & " N"
    doAssert abs(storeMass(1.0, usImperial) - KgPerLb) < 1e-15
    doAssert abs(storeVelocity(1.0, usImperial) - MPerFt) < 1e-15
    doAssert abs(storeForce(1.0, usImperial) - NPerLbf) < 1e-12
    doAssert abs(showMass(KgPerLb, usImperial) - 1.0) < 1e-12
    doAssert abs(showVelocity(MPerFt, usImperial) - 1.0) < 1e-12
    doAssert abs(showForce(NPerLbf, usImperial) - 1.0) < 1e-9
    doAssert abs(showAccel(MPerFt, usImperial) - 1.0) < 1e-12
    # 1 psi = 1 lbf / in², the inch the defined 0.0254 m
    doAssert abs(showPressure(PaPerPsi, usImperial) - 1.0) < 1e-9
    doAssert showMass(2450.0, usMetric) == 2450.0
    doAssert storeMass(NaN, usImperial).isNaN and showMass(NaN, usImperial).isNaN

  block roundTrip:
    # A value typed in pounds, stored in kilograms, shown again in pounds.
    for typed in ["1", "0.5", "2450", "3968.32", "5401.33", "8750.5", "100000", "2204622622"]:
      let shown = parseFloat(typed)
      let back = sensible(showMass(storeMass(shown, usImperial), usImperial))
      doAssert back == typed, typed & " came back as " & back
    doAssert sensible(showMass(storeMass(3968.32, usImperial), usImperial)) != "3968.320000001"
    # Switching the unit keeps the stored kilograms; the box shows them again.
    let kg = 2450.0
    doAssert abs(storeMass(showMass(kg, usImperial), usImperial) - kg) < 1e-8
    doAssert storeMass(kg, usMetric) == kg

  block massBox:
    # the mass box: 3600 kg shows 7936.6 lb; switching the unit shows another number
    # and stores nothing, so any number of switches leaves exactly 3600 kg; a number
    # typed in pounds stores the kilograms it is
    doAssert massBoxValue(3600, usMetric) == 3600
    doAssert massBoxValue(3600, usImperial) == 7936.6
    doAssert massBoxValue(1800, usImperial) == 3968.3
    doAssert massBoxValue(NaN, usImperial).isNaN
    var stored = 3600.0
    for i in 0 ..< 1000:
      let u = if i mod 2 == 0: usImperial else: usMetric
      discard massBoxValue(stored, u) # what the box shows; nothing is stored back
    doAssert stored == 3600.0
    doAssert abs(storeMass(showMass(3600, usImperial), usImperial) - 3600) < 1e-9
    doAssert abs(storeMass(7936.6, usImperial) - 3600) < 0.03 # the box's rounding, typed back
    doAssert abs(storeMass(100, usImperial) - 45.359237) < 1e-12
    doAssert massBoxValue(storeMass(100, usImperial), usImperial) == 100

  block massTyped:
    # what a mass box does with a number typed: always kept in kilograms; 3600 lb is
    # 1632.932532 kg and shows back as 3600 lb; the box left as it showed (a unit switched, any
    # number of times) stores nothing, so 3600 kg stays exactly 3600 kg; out of range is refused
    let lb = massTyped(3600, massBoxValue(2000, usImperial), 2000, usImperial)
    doAssert lb.changed and abs(lb.kg - 1632.932532) < 1e-9, $lb.kg
    doAssert lb.kg == 3600 * KgPerLb and massBoxValue(lb.kg, usImperial) == 3600
    doAssert formatFloat(massBoxValue(lb.kg, usMetric), ffDecimal, 2) == "1632.93"
    var stored = 3600.0
    for i in 0 ..< 1000:
      let u = if i mod 2 == 0: usImperial else: usMetric
      let shown = massBoxValue(stored, u)
      let got = massTyped(shown, shown, stored, u) # the box returned what it showed
      doAssert not got.changed and not got.refused
      stored = got.kg
    doAssert stored == 3600.0, $stored
    # 7936.6 lb typed on purpose is a mass of its own (the box's rounding, typed back)
    let typedBack = massTyped(7936.6, 7936.5, 3600, usImperial)
    doAssert typedBack.changed and abs(typedBack.kg - 3600) < 0.03 and typedBack.kg != 3600
    doAssert not massTyped(3600, 3600, 3600, usMetric).changed
    doAssert massTyped(0, 3600, 3600, usMetric).refused and
      massTyped(0, 3600, 3600, usMetric).kg == 3600
    doAssert massTyped(3e9, 1, 1, usImperial).refused
    let cleared = massTyped(NaN, 3600, 3600, usMetric)
    doAssert cleared.changed and cleared.kg.isNaN
    doAssert not massTyped(NaN, NaN, NaN, usImperial).changed

  block about:
    # the About window's strings: one place, the licence read from the repository's file
    doAssert CopyrightLine == "Copyright © 2026 Joshua Fenner", CopyrightLine
    doAssert AuthorEmail == "Joshua.R.Fenner@gmail.com"
    doAssert LicenseText.startsWith("MIT License") and "Joshua Fenner" in LicenseText
    doAssert LicenseDisclaimer.startsWith("THE SOFTWARE IS PROVIDED \"AS IS\"") and
      LicenseDisclaimer.endsWith("DEALINGS IN THE SOFTWARE.") and '\n' notin LicenseDisclaimer,
      LicenseDisclaimer

  block names:
    doAssert massName(usMetric) == "kg" and massName(usImperial) == "lb"
    doAssert velocityName(usMetric) == "m/s" and velocityName(usImperial) == "ft/s"
    doAssert forceName(usMetric) == "N" and forceName(usImperial) == "lbf"
    doAssert accelName(usMetric) == "m/s²" and accelName(usImperial) == "ft/s²"
    doAssert pressureName(usMetric) == "Pa" and pressureName(usImperial) == "psi"
    doAssert systemName(usMetric) == "Metric" and systemName(usImperial) == "Imperial"
    doAssert UnitNames[usMetric] == "metric" and UnitNames[usImperial] == "imperial"
    doAssert massLimitWords(usMetric) == "above 0 and at most 1000000000 kg"
    doAssert "lb" in massLimitWords(usImperial) and "kg" notin massLimitWords(usImperial)
    doAssert MassKgRange.words == "above 0 and at most 1000000000 kg",
      "a command's range stays in kilograms"

  block imperialMassCap:
    # The pounds the tooltip names must store. sensible(showMass(1e9)) rounds
    # up to a pound MassKgRange refuses, so the words said a maximum they
    # would not take.
    # Seen to fail: with the cap taken from that rounding, "2204622622 lb"
    # stored 1000000000.069 kg and MassKgRange refused it.
    let words = massLimitWords(usImperial)
    doAssert words.startsWith("above 0 and at most ") and words.endsWith(" lb"), words
    let capText = words["above 0 and at most ".len ..< words.len - " lb".len]
    let cap = parseFloat(capText)
    doAssert cap == floor(cap) and cap > 0, words
    doAssert MassKgRange.allows(storeMass(cap, usImperial)),
      words & " stores " & $storeMass(cap, usImperial) & " kg"
    doAssert not MassKgRange.allows(storeMass(cap + 1, usImperial)),
      words & " the next pound also stores"

  block notes:
    let metric = "Ref t1 · GF t2; GF (M, B) = 2450 kg·M + 1180 kg·B; values as recorded; " &
      "GF (M, B) is uncalibrated without accelerometer sensitivities: in kg × as recorded, " &
      "on an axis of its own (the force limits are in N and are not applied to it)"
    doAssert shownNote(metric, 2450, 1180, usMetric) == metric
    let imperial = shownNote(metric, 2450, 1180, usImperial)
    doAssert "2450 kg·M" notin imperial, imperial
    doAssert "lb·M" in imperial and "lb·B" in imperial, imperial
    doAssert "lb × as recorded" in imperial and "kg ×" notin imperial, imperial
    doAssert " in lbf " in imperial and " in N " notin imperial, imperial
    doAssert shownMassClause(2450, 1180, usMetric) == "2450 kg·M + 1180 kg·B"

  block noteKeepsNames:
    # An archive name is prepended to the generated note. The rewrite must
    # touch only the generated mass clause and the unit phrases it emits.
    # Seen to fail: with the splice taken from the first "GF (M, B) = " and a
    # global " in N ", "shot in N 12.sgd" became "shot in lbf 12.sgd" and
    # "GF (M, B) = pilot.sgd" ate "Ref t1 · GF t2".
    let body = "Ref t1 · GF t2; GF (M, B) = 2450 kg·M + 1180 kg·B; values as recorded; " &
      "GF (M, B) is uncalibrated without accelerometer sensitivities: in kg × as recorded, " &
      "on an axis of its own (the force limits are in N and are not applied to it)"
    let shot = shownNote("Reference: shot in N 12.sgd (archive). " & body, 2450, 1180, usImperial)
    doAssert "shot in N 12.sgd" in shot, shot
    doAssert "shot in lbf" notin shot, shot
    doAssert "Ref t1 · GF t2" in shot and "lb·M" in shot, shot
    let named = shownNote("Reference: GF (M, B) = pilot.sgd (archive). " & body, 2450, 1180,
      usImperial)
    doAssert "GF (M, B) = pilot.sgd" in named, named
    doAssert "Ref t1 · GF t2" in named, named
    doAssert "2450 kg·M" notin named and "lb·M" in named, named
    # A fragment of a generated phrase, outside that phrase, is a name.
    let stray = shownNote("Reference: file kg × as recorded, in N 3.sgd. " & body, 2450, 1180,
      usImperial)
    doAssert "file kg × as recorded, in N 3.sgd" in stray, stray
    doAssert "in lb × as recorded, on an axis" in stray, stray
    let accel = shownNote("x; in kg × m/s², on an axis of its own " &
      "(the force limits are in m/s and are not applied to it)", 1, 1, usImperial)
    doAssert "in lb × ft/s², on an axis of its own" in accel, accel
    doAssert "in ft/s and are not applied" in accel, accel
    doAssert "m/s²" notin accel and " in m/s " notin accel, accel

  block axes:
    let force = axisDisplay("Force (N)", usImperial)
    doAssert force.label == "Force (lbf)" and abs(force.divisor - NPerLbf) < 1e-9
    let weighted = axisDisplay("GF (M, B) (kg × as recorded)", usImperial)
    doAssert weighted.label == "GF (M, B) (lb × as recorded)" and
      abs(weighted.divisor - KgPerLb) < 1e-12
    let accel = axisDisplay("Acceleration (m/s²)", usImperial)
    doAssert accel.label == "Acceleration (ft/s²)" and abs(accel.divisor - MPerFt) < 1e-12
    let vel = axisDisplay("Velocity (m/s)", usImperial)
    doAssert vel.label == "Velocity (ft/s)"
    let pressure = axisDisplay("Pressure (Pa)", usImperial)
    doAssert pressure.label == "Pressure (psi)" and abs(pressure.divisor - PaPerPsi) < 1e-6
    let product = axisDisplay("GF (M, B) (kg × m/s²)", usImperial)
    doAssert product.label == "GF (M, B) (lb × ft/s²)"
    doAssert axisDisplay("Force (N)", usMetric).label == "Force (N)"
    doAssert axisDisplay("Force (as recorded)", usImperial).divisor == 1.0

  block fkVelocity:
    # A file in metres or feet keeps that unit, whichever Units is.
    for setting in UnitSystem:
      doAssert "file's metres" in fkVelocityTip("m/s", setting), $setting
      doAssert "not the Units setting" in fkVelocityTip("m/s", setting)
      doAssert "file's feet" in fkVelocityTip("ft/s", setting)
      doAssert "not the Units setting" in fkVelocityTip("ft/s", setting)
    let metric = fkVelocityTip("traces/s", usMetric)
    let imperial = fkVelocityTip("traces/s", usImperial)
    # traces/s names no length, so Units does not apply, whichever it is.
    # Seen to fail: with the tip saying the setting "applies only when the
    # file names no length", imperial contained "applies only" and named Imperial.
    doAssert "traces/s" in metric and "traces/s" in imperial, metric
    doAssert "does not apply" in imperial and "no length to convert" in imperial, imperial
    doAssert "applies only" notin imperial and "Imperial" notin imperial, imperial
    doAssert metric == imperial
    doAssert fkVelocityTip("", usImperial).len == 0

  block forceLimitBox:
    # The box shows the unit the force axis shows and stores in the stored unit.
    # A typed 1000 lbf is 1000*NPerLbf newtons: the line is drawn at 1000, and a
    # peak of 500 lbf passes. Toggle without a new number does not drift.
    # Seen to fail: with the box storing the typed number as newtons, forceLimitOf
    # was not applied, 1000 stored 1000, and 2224 N (500 lbf) failed that limit.
    let imp = forceLimitOf("Force (N)", usImperial)
    doAssert imp.unit == "lbf" and abs(imp.divisor - NPerLbf) < 1e-9, $imp
    let met = forceLimitOf("Force (N)", usMetric)
    doAssert met.unit == "N" and met.divisor == 1.0
    let counts = forceLimitOf("Force (as recorded)", usImperial)
    doAssert counts.unit == "counts" and counts.divisor == 1.0, $counts
    doAssert forceLimitOf("Force (as recorded)", usMetric).unit == "counts"
    let weighted = forceLimitOf("GF (M, B) (kg × as recorded)", usImperial)
    doAssert weighted.unit == "lb × as recorded" and abs(weighted.divisor - KgPerLb) < 1e-12,
      $weighted
    let weightedN = forceLimitOf("GF (M, B) (N)", usImperial)
    doAssert weightedN.unit == "lbf" and abs(weightedN.divisor - NPerLbf) < 1e-9
    doAssert forceLimitOf("GF (M, B) (kg × m/s²)", usImperial).unit == "lb × ft/s²"
    doAssert forceLimitOf("", usImperial).unit == "" and forceLimitOf("", usImperial).divisor == 1.0
    let stored = storeScaled(1000.0, imp.divisor)
    doAssert abs(stored - 1000.0 * NPerLbf) < 1e-6, $stored
    doAssert sensible(showScaled(stored, imp.divisor)) == "1000"
    let again = storeScaled(parseFloat(sensible(showScaled(stored, imp.divisor))), imp.divisor)
    doAssert again == stored, "toggle stored " & $again & " from " & $stored
    # 500 lbf passes a limit the user typed as 1000; storing 1000 N would fail it.
    let peakN = 500.0 * NPerLbf
    doAssert peakN < stored and peakN > 1000.0, $peakN
    let plot = AnalysisPlot(title: "Force", yLabel: "Force (N)", xs: @[0.0, 1.0],
      curves: @[AnalysisCurve(name: "lowest force", style: csLimit, xs: @[0.0, 1.0],
        ys: @[stored, stored])])
    doAssert forceAxisLabel(@[plot]) == "Force (N)"
    doAssert forceAxisLabel(@[AnalysisPlot(title: "Force from M and B",
      yLabel: "GF (M, B) (kg × as recorded)")]) == "GF (M, B) (kg × as recorded)"
    let drawn = AnalysisResult(plots: @[plot]).curvePlots(builtinTheme(tmDark), usImperial)
    doAssert drawn[0].yLabel == "Force (lbf)", drawn[0].yLabel
    doAssert abs(drawn[0].curves[0].ys[0] - 1000.0) < 1e-4, $drawn[0].curves[0].ys[0]

  block vibratorTable:
    # The table's force columns follow the axis, and the header names the unit
    # when every row shares it. A row in another unit names its own.
    # Seen to fail: with the table left in stored newtons, "4448.222" stayed
    # under "Max peak" while the axis was Force (lbf).
    let head = @["Signal", "Mean force", "Min force", "Max peak"]
    let row = @["GF", "4448.222", "4000.000", "4448.222"]
    let imperial = shownTable(@[head, row], @["N"], usImperial)
    doAssert imperial[0][1] == "Mean force (lbf)", imperial[0][1]
    doAssert imperial[0][3] == "Max peak (lbf)", imperial[0][3]
    doAssert imperial[1][1] == "1000.000", imperial[1][1]
    doAssert imperial[1][3] == "1000.000", imperial[1][3]
    let metric = shownTable(@[head, row], @["N"], usMetric)
    doAssert metric[0][1] == "Mean force (N)", metric[0][1]
    doAssert metric[1][1] == "4448.222"
    let counts = shownTable(@[head, row], @["as recorded"], usImperial)
    doAssert counts[0][3] == "Max peak (as recorded)", counts[0][3]
    doAssert counts[1][3] == "4448.222"
    let mixed = shownTable(@[head, row, @["GF (M, B)", "2267.962", "2000.000", "2300.000"]],
      @["N", "kg × as recorded"], usImperial)
    doAssert mixed[0][1] == "Mean force", mixed[0][1]
    doAssert mixed[1][1].endsWith(" lbf"), mixed[1][1]
    doAssert "lb × as recorded" in mixed[2][1], mixed[2][1]
    doAssert shownTable(@[head, row], newSeq[string](), usImperial)[1][1] == "4448.222"
    # A readout of a converted axis names that axis's unit, not the stored one.
    let plot = AnalysisPlot(title: "Force", yLabel: "Force (N)", xs: @[0.0, 1.0],
      curves: @[AnalysisCurve(name: "GF fundamental", ys: @[4448.2216152605, 4448.2216152605])])
    let drawn = AnalysisResult(plots: @[plot]).curvePlots(builtinTheme(tmDark), usImperial)
    doAssert drawn[0].yLabel == "Force (lbf)" and drawn[0].yUnit == "lbf", drawn[0].yUnit
    doAssert abs(drawn[0].curves[0].ys[0] - 1000.0) < 1e-6, $drawn[0].curves[0].ys[0]

  block protocolStaysMetric:
    # A command's mass is kilograms, and a value out of range is said in kilograms.
    let bad = settingProblem(AnalysisParams(reactionMassKg: 1e20), avVibrator)
    doAssert "1000000000 kg" in bad and "lb" notin bad, bad
    let p = AnalysisParams(reactionMassKg: 2450.0, baseplateMassKg: 1180.0)
    doAssert p.reactionMassKg == 2450.0 and massName(usMetric) == "kg"

  echo "tunits: ok"

when isMainModule:
  main()
